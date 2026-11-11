local Survey = {}
Survey.__index = Survey

local SECTION_SIZE, STEPS_PER_CALL = 8, 8

local function integer(value)
    return type(value) == "number" and value == value and math.abs(value) <= 2147483647 and value == math.floor(value)
end

local function call(object, method, ...)
    if not object then return nil end
    local arguments = { ... }
    local ok, result = pcall(function() return object[method](object, unpack(arguments)) end)
    if ok then return result end
end

local function size(list)
    return call(list, "size")
end

function Survey.new(building, currentRoom)
    local rooms = call(building, "getRooms")
    local count, id = size(rooms), call(building, "getIDString")
    if not integer(count) or count < 0 or type(id) ~= "string" or id == "" then
        return nil, "The building has no usable room metadata"
    end
    return setmetatable({ building = building, buildingId = id, rooms = rooms, roomCount = count,
        roomIndex = 0, preferredRoom = currentRoom, preferredIndex = nil, lookupIndex = 0,
        phase = currentRoom and "find" or "room", roomsDone = 0, sectionsSearched = 0,
        sectionsUnsearched = 0, failures = {}, failureOrder = {}, complete = false }, Survey)
end

function Survey:failure(room, reason)
    local record = self.failures[room.roomId]
    if not record then
        record = { roomId = room.roomId, roomName = room.roomName, z = room.z, sections = 0, reason = reason }
        self.failures[room.roomId] = record
        self.failureOrder[#self.failureOrder + 1] = record
    end
    record.sections = record.sections + 1
    self.sectionsUnsearched = self.sectionsUnsearched + 1
end

function Survey:finishRoom()
    self.roomsDone = self.roomsDone + 1
    self.room, self.rects, self.rect = nil, nil, nil
    self.phase = "room"
end

function Survey:selectRoom(index)
    local native = call(self.rooms, "get", index)
    local id = call(native, "getIDString")
    local name, z = call(native, "getName"), call(native, "getZ")
    local rects = call(native, "getRects")
    local count = size(rects)
    self.room = { room = native, roomId = type(id) == "string" and id ~= "" and id or "room:" .. tostring(index),
        roomName = type(name) == "string" and name or "Room " .. tostring(index + 1), z = integer(z) and z or nil }
    if not native or type(id) ~= "string" or id == "" or not integer(z)
        or not integer(count) or count < 0 or call(native, "getBuilding") ~= self.building then
        self:failure(self.room, "Room metadata is missing or no longer belongs to this building")
        self:finishRoom()
        return
    end
    self.rects, self.rectCount, self.rectIndex = rects, count, 0
    if count == 0 then
        self:failure(self.room, "Room metadata has no searchable geometry")
        self:finishRoom()
    else self.phase = "rect" end
end

function Survey:selectRect()
    local native = call(self.rects, "get", self.rectIndex)
    self.rectIndex = self.rectIndex + 1
    local x1, y1 = call(native, "getX"), call(native, "getY")
    local x2, y2 = call(native, "getX2"), call(native, "getY2")
    if not integer(x1) or not integer(y1) or not integer(x2) or not integer(y2) or x2 <= x1 or y2 <= y1 then
        self:failure(self.room, "Room metadata has invalid rectangle coordinates")
        return
    end
    self.rect = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    self.x, self.y, self.direction, self.phase = x1, y1, 1, "section"
end

function Survey:next()
    assert(not self.pending, "Report the current building section before requesting another")
    if self.complete then return nil end
    for _ = 1, STEPS_PER_CALL do
        if self.phase == "find" then
            if self.lookupIndex >= self.roomCount then
                self.preferredRoom, self.phase = nil, "room"
            else
                local index = self.lookupIndex
                self.lookupIndex = index + 1
                if call(self.rooms, "get", index) == self.preferredRoom then
                    self.preferredIndex, self.phase = index, "room"
                end
            end
        elseif self.phase == "room" then
            if self.preferredIndex and not self.preferredVisited then
                self.preferredVisited = true
                self:selectRoom(self.preferredIndex)
            elseif self.roomIndex >= self.roomCount then
                self.complete = true
                return nil
            else
                local index = self.roomIndex
                self.roomIndex = index + 1
                if index ~= self.preferredIndex then self:selectRoom(index) end
            end
        elseif self.phase == "rect" then
            if self.rectIndex >= self.rectCount then self:finishRoom()
            else self:selectRect() end
        elseif self.phase == "section" then
            local room, rect = self.room, self.rect
            local left = self.direction == 1 and self.x or math.max(rect.x1, self.x - SECTION_SIZE)
            local right = self.direction == 1 and math.min(self.x + SECTION_SIZE, rect.x2) or self.x
            local section = { building = self.building, room = room.room, roomId = room.roomId, roomName = room.roomName, z = room.z,
                x1 = left, y1 = self.y, x2 = right,
                y2 = math.min(self.y + SECTION_SIZE, rect.y2) }
            self.x = self.direction == 1 and right or left
            if self.direction == 1 and self.x >= rect.x2 then
                self.direction, self.x, self.y = -1, rect.x2, section.y2
            elseif self.direction == -1 and self.x <= rect.x1 then
                self.direction, self.x, self.y = 1, rect.x1, section.y2
            end
            if self.y >= rect.y2 then self.rect, self.phase = nil, "rect" end
            self.pending = section
            return section
        else error("Unknown building survey phase") end
    end
    return false
end

function Survey:report(section, ok, reason)
    assert(self.pending and section == self.pending, "Only the current building section can be reported")
    if ok then self.sectionsSearched = self.sectionsSearched + 1
    else
        local message = tostring(reason or "Section could not be searched") .. " at "
            .. tostring(section.x1) .. ", " .. tostring(section.y1) .. " on floor " .. tostring(section.z)
        self:failure(section, message)
    end
    self.pending = nil
end

function Survey:status()
    local failures = {}
    for _, record in ipairs(self.failureOrder) do
        failures[#failures + 1] = { roomId = record.roomId, roomName = record.roomName,
            z = record.z, sections = record.sections, reason = record.reason }
    end
    return { roomsTotal = self.roomCount, roomsDone = self.roomsDone,
        sectionsSearched = self.sectionsSearched, sectionsUnsearched = self.sectionsUnsearched,
        unsearchedRooms = failures, complete = self.complete }
end

return Survey
