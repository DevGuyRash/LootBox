-- Cheap questions for menus and pages, available as World methods. They read
-- loaded objects and saved state only: no discover(), no disk, no search of the
-- loaded world, and nothing is remembered or changed.
--
-- world:hasKnownBins()                  -> boolean
-- world:hasStorageLabels()              -> boolean, any container has a label
-- world:storageAccepts(descriptor)      -> boolean, some labelled container takes this item
-- world:rememberedVehicleLoaded()       -> boolean
-- world:containerFacts(container)       -> {kind, items, takeable, explored, locked, owned, used, capacity,
--                                           types = {fullType = count}, categories = {native id = count}, truncated}
--                                          kind: main, bag, fixture, vehicle, corpse, floor or bin.
--                                          Counts cover the container itself, not bags inside it.
-- world:countCarried(fullType)          -> number over main inventory and carried bags
-- world:countCarriedCategory(id)        -> number, native or custom category
-- world:roomFacts(square)               -> {name, containers, groundItems, truncated}, or nil outside a room
-- world:labelledContainers()            -> list of {key, labels, container or nil, name, point or nil}
-- world:knownBins()                     -> list of {key, container or nil, name, point, capacity, used or nil}

local Catalog = require "LootBox/Catalog"
local Log = require "LootBox/Log"
local call = require "LootBox/Safe"
local Sort = require "LootBox/Sort"

local MAX_ITEMS, MAX_SQUARES = 400, 150
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
        if vehicle and call(vehicle, "getKeyId") == remembered.keyId and call(vehicle, "getScriptName") == remembered.script
            and call(vehicle, "isRemovedFromWorld") ~= true and call(vehicle, "getSquare") then return true end
    end
    return false
end

function Facts:containerFacts(container)
    local list = call(container, "getItems")
    local count = size(list)
    local result = {kind = kindOf(self, container), items = count, takeable = 0, types = {}, categories = {},
        explored = call(container, "isExplored") ~= false, locked = call(container, "isLockedToCharacter", self.player) == true,
        owned = self:owns(container), used = call(container, "getCapacityWeight") or 0,
        capacity = call(container, "getEffectiveCapacity", self.player) or 0, truncated = count > MAX_ITEMS}
    for index = 0, math.min(count, MAX_ITEMS) - 1 do
        local item = call(list, "get", index)
        local fullType, category = tostring(call(item, "getFullType")), Catalog.categoryId(item)
        result.types[fullType] = (result.types[fullType] or 0) + 1
        result.categories[category] = (result.categories[category] or 0) + 1
        if call(item, "isUnwanted", self.player) ~= true and not self:protected(item) then result.takeable = result.takeable + 1 end
    end
    return result
end

local function carried(self, matches)
    local pending, seen, cursor, total = {call(self.player, "getInventory")}, {}, 1, 0
    while pending[cursor] do
        local list = not seen[pending[cursor]] and call(pending[cursor], "getItems")
        seen[pending[cursor]] = true
        for index = 0, (list and size(list) or 0) - 1 do
            local item = call(list, "get", index)
            if matches(item) then total = total + 1 end
            pending[#pending + 1] = call(item, "getInventory")
        end
        cursor = cursor + 1
    end
    return total
end

function Facts:countCarried(fullType)
    return carried(self, function(item) return tostring(call(item, "getFullType")) == fullType end)
end

function Facts:countCarriedCategory(id)
    return carried(self, function(item)
        local descriptor = self:describe(item)
        if self.graph then return self.graph:matches(id, descriptor) end
        return descriptor.categoryId == id
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
