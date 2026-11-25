local call = require "LootBox/Safe"
local Sort = require "LootBox/Sort"

-- The part of a building or marked area that still has to be searched, in small pieces, nearest first.
local Survey = {}
Survey.__index = Survey

local SECTION_SIZE, FLOOR_TILES = 8, 12

local function integer(value)
    return type(value) == "number" and value == value and math.abs(value) <= 2147483647 and value == math.floor(value)
end

local function new(fields)
    fields.sections, fields.left, fields.roomsDone, fields.complete = {}, {}, 0, false
    fields.sectionsSearched, fields.sectionsUnsearched, fields.failures, fields.failureOrder = 0, 0, {}, {}
    return setmetatable(fields, Survey)
end

function Survey:failure(room, reason)
    local record = self.failures[room.roomId]
    if not record then
        record = {roomId = room.roomId, roomName = room.roomName, z = room.z, sections = 0, reason = reason}
        self.failures[room.roomId] = record
        self.failureOrder[#self.failureOrder + 1] = record
    end
    record.sections = record.sections + 1
    self.sectionsUnsearched = self.sectionsUnsearched + 1
end

function Survey:rectangle(room, x1, y1, x2, y2)
    for y = y1, y2 - 1, SECTION_SIZE do for x = x1, x2 - 1, SECTION_SIZE do
        self.sections[#self.sections + 1] = {building = room.building, room = room.room, roomId = room.roomId, roomName = room.roomName,
            z = room.z, x1 = x, y1 = y, x2 = math.min(x + SECTION_SIZE, x2), y2 = math.min(y + SECTION_SIZE, y2)}
        self.left[room.roomId] = (self.left[room.roomId] or 0) + 1
    end end
end

function Survey:addRoom(native, index)
    local id, name, z, rects = call(native, "getIDString"), call(native, "getName"), call(native, "getZ"), call(native, "getRects")
    local known, count = type(id) == "string" and id ~= "", call(rects, "size")
    local room = {building = self.building, room = native, roomId = known and id or "room:" .. index,
        roomName = type(name) == "string" and name or "Room " .. (index + 1), z = integer(z) and z or nil}
    if not known or not integer(z) or not integer(count) or count < 0 or call(native, "getBuilding") ~= self.building then
        self:failure(room, "Room metadata is missing or no longer belongs to this building")
    elseif count == 0 then self:failure(room, "Room metadata has no searchable geometry")
    else
        for at = 0, count - 1 do
            local rect = call(rects, "get", at)
            local x1, y1, x2, y2 = call(rect, "getX"), call(rect, "getY"), call(rect, "getX2"), call(rect, "getY2")
            if integer(x1) and integer(y1) and integer(x2) and integer(y2) and x2 > x1 and y2 > y1 then self:rectangle(room, x1, y1, x2, y2)
            else self:failure(room, "Room metadata has invalid rectangle coordinates") end
        end
    end
    if not self.left[room.roomId] then self.roomsDone = self.roomsDone + 1 end
end

function Survey.ofBuilding(building)
    local rooms, id = call(building, "getRooms"), call(building, "getIDString")
    local count = call(rooms, "size")
    if not integer(count) or count < 0 or type(id) ~= "string" or id == "" then
        return nil, "The building has no usable room metadata"
    end
    local self = new({building = building, roomsTotal = count})
    for index = 0, count - 1 do self:addRoom(call(rooms, "get", index), index) end
    self.complete = #self.sections == 0
    return self
end

function Survey.ofArea(area, limit)
    if type(area) ~= "table" then return nil, "Choose an area first" end
    for _, name in ipairs({"x1", "x2", "y1", "y2", "z"}) do
        if not integer(area[name]) then return nil, "Area coordinates must be whole numbers within the native integer range" end
    end
    local x1, x2 = math.min(area.x1, area.x2), math.max(area.x1, area.x2)
    local y1, y2 = math.min(area.y1, area.y2), math.max(area.y1, area.y2)
    if (x2 - x1 + 1) * (y2 - y1 + 1) > limit then return nil, "Area is too large; choose at most " .. limit .. " tiles" end
    local self = new({roomsTotal = 1})
    self:rectangle({roomId = "area", roomName = "the marked area", z = area.z}, x1, y1, x2 + 1, y2 + 1)
    return self
end

local function apart(section, point)
    local dx = math.max(section.x1 - point.x, 0, point.x - section.x2 + 1)
    local dy = math.max(section.y1 - point.y, 0, point.y - section.y2 + 1)
    return math.sqrt(dx * dx + dy * dy) + math.abs(section.z - point.z) * FLOOR_TILES
end

function Survey:nearest(point)
    local result = {}
    for index, section in ipairs(self.sections) do result[index] = section end
    return Sort(result, function(section) return point and apart(section, point) or 0 end)
end

function Survey:next(point)
    local best, bestApart
    for _, section in ipairs(self.sections) do
        local value = point and apart(section, point) or 0
        if not best or value < bestApart then best, bestApart = section, value end
    end
    return best
end

function Survey:report(section, ok, reason)
    for index, value in ipairs(self.sections) do
        if value == section then
            table.remove(self.sections, index)
            self.left[section.roomId] = self.left[section.roomId] - 1
            if self.left[section.roomId] == 0 then self.roomsDone = self.roomsDone + 1 end
            self.complete = #self.sections == 0
            if ok then self.sectionsSearched = self.sectionsSearched + 1
            else
                self:failure(section, tostring(reason or "Section could not be searched") .. " at "
                    .. section.x1 .. ", " .. section.y1 .. " on floor " .. section.z)
            end
            return
        end
    end
end

function Survey:status()
    local failures = {}
    for _, record in ipairs(self.failureOrder) do
        failures[#failures + 1] = {roomId = record.roomId, roomName = record.roomName,
            z = record.z, sections = record.sections, reason = record.reason}
    end
    return {roomsTotal = self.roomsTotal, roomsDone = self.roomsDone, sectionsSearched = self.sectionsSearched,
        sectionsUnsearched = self.sectionsUnsearched, unsearchedRooms = failures, complete = self.complete}
end

return Survey
