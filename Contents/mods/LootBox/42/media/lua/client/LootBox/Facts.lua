-- Cheap questions for menus and pages, available as World methods. They read
-- loaded objects and saved state only: no discover(), no disk, no search of the
-- loaded world, and nothing is remembered or changed.
--
-- world:hasKnownBins()                  -> boolean
-- world:hasStorageLabels()              -> boolean, any container has a label
-- world:storageAccepts(descriptor)      -> boolean, some labelled container takes this item
-- world:rememberedVehicleLoaded()       -> boolean
-- world:isRememberedVehicle(vehicle)    -> boolean
-- world:containerFacts(container)       -> {kind, items, takeable, explored, locked, owned, used, capacity,
--                                           types = {fullType = count}, categories = {native or custom id = count}, truncated}
--                                          kind: main, bag, fixture, vehicle, corpse, floor or bin.
--                                          items counts everything; takeable, types and categories leave out
--                                          protected and unwanted items. Bags inside are not opened.
-- world:countMatching(container, filter)       -> number of takeable items the filter {ids, types, all} selects
-- world:countCarried(fullType, exclude)        -> number of unprotected carried items; nil fullType counts every type
-- world:countCarriedCategory(id, exclude)      -> the same for a native or custom category
-- world:countCarriedFilter(filter)             -> the same for a filter
--                                          exclude leaves out what lies inside that container.
-- world:roomFacts(square)               -> {name, containers, groundItems, truncated}, or nil outside a room
-- world:labelledContainers()            -> list of {key, labels, container or nil, name, point or nil}
-- world:knownBins()                     -> list of {key, container or nil, name, point, capacity, used or nil}

local Log = require "LootBox/Log"
local call = require "LootBox/Safe"
local Sort = require "LootBox/Sort"

local MAX_ITEMS, MAX_SQUARES, SNAPSHOT_MS = 400, 150, 50
local Facts = {}

local function size(list) return call(list, "size") or 0 end

local function inVehicle(container) return call(container, "getVehiclePart") ~= nil end

local function kindOf(self, container)
    if container == call(self.player, "getInventory") then return "main" end
    if call(container, "getType") == "floor" then return "floor" end
    if call(container, "getContainingItem") then return "bag" end
    if inVehicle(container) then return "vehicle" end
    if instanceof and instanceof(call(container, "getParent"), "IsoDeadBody") then return "corpse" end
    return self:isTrash(container) and "bin" or "fixture"
end

function Facts:hasKnownBins()
    for _ in pairs(self.state.trash) do return true end
    return false
end

local function storageLabel(key, labels) return #labels > 0 and key:sub(1, 7) ~= "player:" end

function Facts:hasStorageLabels()
    for key, labels in pairs(self.state.containerLabels) do if storageLabel(key, labels) then return true end end
    return false
end

function Facts:storageAccepts(descriptor)
    local tried = {}
    for key, labels in pairs(self.state.containerLabels) do
        if storageLabel(key, labels) then
            for _, id in ipairs(labels) do
                if not tried[id] then
                    tried[id] = true
                    if self.graph and self.graph:matches(id, descriptor) then return true end
                end
            end
        end
    end
    return false
end

function Facts:rememberedVehicleLoaded()
    local remembered = self.state.vehicle
    if type(remembered) ~= "table" then return false end
    local square = getCell():getGridSquare(remembered.x, remembered.y, remembered.z)
    for _, vehicle in ipairs({getVehicleById and getVehicleById(remembered.id) or false,
        self.vehicles[tostring(remembered.id)] or false, call(square, "getVehicleContainer") or false}) do
        if vehicle and self:isRememberedVehicle(vehicle) and call(vehicle, "isRemovedFromWorld") ~= true and call(vehicle, "getSquare") then return true end
    end
    return false
end

function Facts:isRememberedVehicle(vehicle)
    local remembered = self.state.vehicle
    return type(remembered) == "table" and remembered.keyId ~= nil and vehicle ~= nil and call(vehicle, "getKeyId") == remembered.keyId
        and call(vehicle, "getScriptName") == remembered.script
end

local function eachTakeable(self, list, visit)
    for index = 0, math.min(size(list), MAX_ITEMS) - 1 do
        local item = call(list, "get", index)
        if item and not self:protected(item) then visit(item) end
    end
end

function Facts:containerFacts(container)
    local list = call(container, "getItems")
    local count = size(list)
    local result = {kind = kindOf(self, container), items = count, takeable = 0, types = {}, categories = {},
        explored = call(container, "isExplored") ~= false, locked = call(container, "isLockedToCharacter", self.player) == true,
        owned = self:owns(container), used = call(container, "getCapacityWeight") or 0,
        capacity = call(container, "getEffectiveCapacity", self.player) or 0, truncated = count > MAX_ITEMS}
    local custom = {}
    eachTakeable(self, list, function(item)
        if call(item, "isUnwanted", self.player) == true then return end
        local descriptor = self:describe(item)
        local key = descriptor.fullType .. "|" .. tostring(descriptor.categoryId) .. "|" .. table.concat(descriptor.labels, "|")
        custom[key] = custom[key] or self.graph and self.graph:customMatches(descriptor) or {}
        result.takeable = result.takeable + 1
        result.types[descriptor.fullType] = (result.types[descriptor.fullType] or 0) + 1
        result.categories[descriptor.categoryId] = (result.categories[descriptor.categoryId] or 0) + 1
        for _, id in ipairs(custom[key]) do result.categories[id] = (result.categories[id] or 0) + 1 end
    end)
    return result
end

function Facts:countMatching(container, filter)
    local total = 0
    eachTakeable(self, call(container, "getItems"), function(item)
        if call(item, "isUnwanted", self.player) ~= true
            and (filter.all or self.graph and self.graph:matchesFilter(filter, self:describe(item))) then total = total + 1 end
    end)
    return total
end

-- One menu asks many of these questions at once, so a snapshot answers them all for a moment.
local function carriedItems(self)
    local stamp = getTimestampMs and getTimestampMs()
    local snapshot = self.carriedSnapshot
    if stamp and snapshot and stamp >= snapshot.stamp and stamp - snapshot.stamp < SNAPSHOT_MS then return snapshot.entries end
    local entries, seen, cursor = {}, {}, 1
    local pending = {{container = call(self.player, "getInventory"), within = {}}}
    while pending[cursor] do
        local container, within = pending[cursor].container, {}
        cursor = cursor + 1
        for outer in pairs(pending[cursor - 1].within) do within[outer] = true end
        within[container] = true
        local list = not seen[container] and call(container, "getItems")
        seen[container] = true
        for index = 0, (list and size(list) or 0) - 1 do
            local item = call(list, "get", index)
            if item and not self:protected(item) then entries[#entries + 1] = {descriptor = self:describe(item), within = within} end
            local inside = call(item, "getInventory")
            if inside then pending[#pending + 1] = {container = inside, within = within} end
        end
    end
    if stamp then self.carriedSnapshot = {stamp = stamp, entries = entries} end
    return entries
end

local function countCarried(self, exclude, matches)
    local total = 0
    for _, entry in ipairs(carriedItems(self)) do
        if not (exclude and entry.within[exclude]) and matches(entry.descriptor) then total = total + 1 end
    end
    return total
end

function Facts:countCarried(fullType, exclude)
    return countCarried(self, exclude, function(descriptor) return fullType == nil or descriptor.fullType == fullType end)
end

function Facts:countCarriedCategory(id, exclude)
    return countCarried(self, exclude, function(descriptor)
        if self.graph then return self.graph:matches(id, descriptor) end
        return descriptor.categoryId == id
    end)
end

function Facts:countCarriedFilter(filter)
    return countCarried(self, nil, function(descriptor)
        return filter.all == true or self.graph ~= nil and self.graph:matchesFilter(filter, descriptor)
    end)
end

-- One pcall around the whole room: a guarded call per tile would cost more than the answer is worth.
local function readRoom(room, result)
    local squares = room:getSquares()
    local count = squares:size()
    result.truncated = count > MAX_SQUARES
    local function add(container)
        if container and (not container:isExplored() or not container:getItems():isEmpty()) then
            result.containers = result.containers + 1
        end
    end
    for index = 0, math.min(count, MAX_SQUARES) - 1 do
        local tile = squares:get(index)
        local objects, corpses = tile:getObjects(), tile:getStaticMovingObjects()
        for slot = 0, objects:size() - 1 do
            local object = objects:get(slot)
            for compartment = 0, object:getContainerCount() - 1 do add(object:getContainerByIndex(compartment)) end
        end
        for slot = 0, corpses:size() - 1 do add(call(corpses:get(slot), "getContainer")) end
        result.groundItems = result.groundItems + tile:getWorldObjects():size()
    end
end

function Facts:roomFacts(square)
    local room = call(square, "getRoom")
    if not room then return nil end
    local result = {name = call(room, "getName"), containers = 0, groundItems = 0, truncated = false}
    local ok, err = pcall(readRoom, room, result)
    if not ok then Log.fault(nil, "Facts.roomFacts", err) end
    return result
end

-- An endpoint that has since been removed or reloaded must not be offered.
local function endpoint(self, key)
    local container = self.endpoints[key]
    if container and self:valid(container) then return container end
end

local function pointOf(key)
    local x, y, z = key:match("^%a+:(%-?%d+):(%-?%d+):(%-?%d+):")
    if key:sub(1, 6) == "world:" or key:sub(1, 7) == "corpse:" then
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        return x and {x = x, y = y, z = z} or nil
    end
end

local function squarePoint(square)
    if square then return {x = square:getX(), y = square:getY(), z = square:getZ()} end
end

function Facts:labelledContainers()
    local result = {}
    for key, labels in pairs(self.state.containerLabels) do
        if storageLabel(key, labels) then
            local container, copy = endpoint(self, key), {}
            for index, id in ipairs(labels) do copy[index] = id end
            -- Saved keys end in the part ID for vehicles and the container type for fixtures.
            local kind = key:sub(1, 4) == "bag:" and "Bag" or key:match("([^:]+)$") or "Container"
            result[#result + 1] = {key = key, labels = copy, container = container,
                name = container and self:name(container) or getTextOrNull and (getTextOrNull("IGUI_ContainerTitle_" .. kind)
                    or getTextOrNull("IGUI_VehiclePart" .. kind)) or kind,
                point = container and squarePoint(self:square(container)) or pointOf(key)}
        end
    end
    return Sort(result, function(entry) return entry.name, entry.key end)
end

function Facts:knownBins()
    local result = {}
    for key, memory in pairs(self.state.trash) do
        if type(memory) == "table" then
            local container = endpoint(self, key)
            result[#result + 1] = {key = key, container = container,
                name = container and self:name(container) or getTextOrNull and getTextOrNull("IGUI_ContainerTitle_" .. tostring(memory.kind))
                    or tostring(memory.kind),
                point = {x = memory.x, y = memory.y, z = memory.z}, capacity = memory.capacity,
                used = container and call(container, "getCapacityWeight") or self.binUsed[key]}
        end
    end
    return Sort(result, function(entry) return entry.key end)
end

return Facts
