local Catalog = require "LootBox/Catalog"
local Survey = require "LootBox/Survey"

local World = {}
World.__index = World

local MAX_SQUARES = 16384
local DISCOVERY_RADIUS = 12

local function nativeInteger(value)
    return type(value) == "number" and value == value and math.abs(value) <= 2147483647 and value == math.floor(value)
end

local function call(object, method, ...)
    if not object then return nil end
    local args = {...}
    local ok, value = pcall(function()
        local fn = object[method]
        if not fn then return nil end
        return fn(object, unpack(args))
    end)
    if ok then return value end
end

local function size(list)
    if not list then return 0 end
    if type(list) == "table" and not list.size then return #list end
    return call(list, "size") or 0
end

local function at(list, index)
    if type(list) == "table" and not list.get then return list[index + 1] end
    return call(list, "get", index)
end

local function instance(object, class)
    return object and instanceof and instanceof(object, class) or false
end

local function copy(array)
    local result = {}
    for _, value in ipairs(array or {}) do result[#result + 1] = value end
    return result
end

local function contains(array, value)
    for _, entry in ipairs(array or {}) do if entry == value then return true end end
    return false
end

local function selectedLabels(labels, selected)
    if #selected == 0 then return #labels > 0 end
    for _, id in ipairs(selected) do if contains(labels, id) then return true end end
    return false
end

local function position(square)
    if not square then return nil end
    return {x = call(square, "getX"), y = call(square, "getY"), z = call(square, "getZ")}
end

local function squareId(square)
    local point = position(square)
    if not point or not point.x or not point.y or not point.z then return nil end
    return tostring(point.x) .. ":" .. tostring(point.y) .. ":" .. tostring(point.z)
end

local function loaded(square)
    if not square or not getCell then return false end
    return call(getCell(), "getGridSquare", call(square, "getX"), call(square, "getY"), call(square, "getZ")) == square
end

local function vehicleIdentity(vehicle)
    local keyId, script = call(vehicle, "getKeyId"), call(vehicle, "getScriptName")
    if not nativeInteger(keyId) or keyId < 0 or type(script) ~= "string" or script == "" then return nil end
    return keyId, script
end

local function liveVehicles(hint)
    local iterator = call(call(getCell and getCell(), "getVehicles"), "iterator")
    if not iterator then return nil, "Loaded vehicle registry is unavailable" end
    local result, seen = {}, {}
    local function add(vehicle)
        if vehicle and not seen[vehicle] and loaded(call(vehicle, "getSquare"))
            and call(vehicle, "isRemovedFromWorld") ~= true then
            seen[vehicle] = true
            result[#result + 1] = vehicle
        end
    end
    while true do
        local more = call(iterator, "hasNext")
        if more == false then break end
        if more ~= true then return nil, "Loaded vehicle registry changed during lookup" end
        local vehicle = call(iterator, "next")
        if not vehicle then return nil, "Loaded vehicle registry changed during lookup" end
        add(vehicle)
    end
    add(hint)
    return result
end

local function uniqueVehicle(keyId, script, hint)
    local vehicles, err = liveVehicles(hint)
    if not vehicles then return nil, err end
    local found
    for _, vehicle in ipairs(vehicles) do
        local candidateKey, candidateScript = vehicleIdentity(vehicle)
        if candidateKey == keyId and candidateScript == script then
            if found then return nil, "Multiple loaded vehicles share this key and model; select a vehicle explicitly" end
            found = vehicle
        end
    end
    if found then return found end
    return nil, "Remembered vehicle is not loaded or its key or model changed"
end

local function spriteName(object)
    return tostring(call(object, "getSpriteName") or call(call(object, "getSprite"), "getName") or "")
end

local function permitted(player, square)
    if isClient and isClient() and SafeHouse and SafeHouse.isSafehouseAllowLoot then
        return SafeHouse.isSafehouseAllowLoot(square, player)
    end
    return true
end

local function isBag(item)
    return call(item, "getCategory") == "Container" or instance(item, "InventoryContainer")
end

local function distance(player, square)
    if not square then return math.huge end
    local dx = (call(player, "getX") or 0) - (call(square, "getX") or 0)
    local dy = (call(player, "getY") or 0) - (call(square, "getY") or 0)
    local dz = (call(player, "getZ") or 0) - (call(square, "getZ") or 0)
    return dx * dx + dy * dy + dz * dz * 100
end

function World.new(player, state)
    state.containerLabels = state.containerLabels or {}
    state.itemLabels = state.itemLabels or {}
    state.keep = state.keep or {}
    state.trash = state.trash or {}
    return setmetatable({player = player, state = state, endpoints = {}, anchors = {}, vehicles = {}, containerKeys = {}, inspectedTrash = {}}, World)
end

function World:itemId(item)
    local id = call(item, "getID")
    if id == nil then return nil end
    return tostring(id)
end

function World:owns(container)
    local inventory = call(self.player, "getInventory")
    return container == inventory or call(container, "getOutermostContainer") == inventory
end

function World:canAccess(container)
    local square = call(container, "getType") == "floor" and call(self.player, "getCurrentSquare") or self:square(container)
    return self:valid(container) and (self:owns(container) or (square ~= nil and permitted(self.player, square)))
        and call(container, "isLockedToCharacter", self.player) ~= true
end

-- Consumption authorizes one exact item, not a container search or a walk-to job.
function World:consumptionSource(item, source)
    local function member(container, value)
        local items = call(container, "getItems")
        -- This is the direct item list, not ItemContainer's recursive/type lookup.
        local present = call(items, "contains", value)
        if type(present) == "boolean" then return present end
        local count = size(items)
        if count > 4096 then return false end
        for index = 0, count - 1 do if at(items, index) == value then return true end end
        return false
    end
    local function nearby(square)
        local current = call(self.player, "getCurrentSquare")
        return current and loaded(square) and call(current, "getZ") == call(square, "getZ")
            and math.abs(call(current, "getX") - call(square, "getX")) <= 1
            and math.abs(call(current, "getY") - call(square, "getY")) <= 1
            and (current == square or call(current, "canReachTo", square) == true)
            and permitted(self.player, square)
    end
    local function ground(value)
        local object = call(value, "getWorldItem")
        local square = call(object, "getSquare")
        local index = call(object, "getWorldObjectIndex")
        return object and nativeInteger(index) and index >= 0 and call(object, "getItem") == value
            and nearby(square) and at(call(square, "getWorldObjects"), index) == object
    end
    if not item or not source or call(item, "getContainer") ~= source then
        return nil, "The selected item moved or changed"
    end
    if call(source, "getType") == "floor" then
        if not self:valid(source) then return nil, "The floor selection is stale" end
        if member(source, item) and ground(item) then return true end
        return nil, "The selected ground item is no longer nearby and reachable"
    end
    if not member(source, item) then return nil, "The selected item is no longer in its source" end
    -- Validate every bag link instead of trusting getOutermostContainer alone.
    local inventory, current, seen = call(self.player, "getInventory"), source, {}
    local claimsPlayerOwner = false
    for _ = 1, 64 do
        if seen[current] or call(current, "isLockedToCharacter", self.player) == true then
            return nil, "The selected source is locked or invalid"
        end
        seen[current] = true
        if current == inventory then return true end
        local owner = call(current, "getParent")
        claimsPlayerOwner = claimsPlayerOwner or owner == self.player
        if owner ~= self.player and (instance(owner, "IsoGameCharacter")
            or instance(owner, "IsoPlayer") or instance(owner, "IsoZombie")) then
            return nil, "Another character's inventory is not a loot source"
        end
        local bag = call(current, "getContainingItem")
        if not bag then break end
        if not isBag(bag) or call(bag, "getInventory") ~= current then
            return nil, "The selected bag changed"
        end
        local parent = call(bag, "getContainer")
        if not parent or call(parent, "getType") == "floor" then
            if not ground(bag) then return nil, "The selected bag is no longer reachable" end
            break
        end
        if not member(parent, bag) then return nil, "The selected bag moved" end
        current = parent
        if _ == 64 then return nil, "The selected bag nesting is too deep" end
    end
    if claimsPlayerOwner then return nil, "The selected bag no longer belongs to the player inventory" end
    local loot = getPlayerLoot and getPlayerLoot(call(self.player, "getPlayerNum"))
    local visible = loot and loot.inventoryPane and loot.inventoryPane.inventory == source
    for index, button in ipairs(loot and loot.backpacks or {}) do
        if index > 256 then break end
        if button.inventory == source then visible = true; break end
    end
    local reachable = nearby(self:square(source))
    local part = call(current, "getVehiclePart")
    if part then
        -- Vanilla uses this for both seated storage and outside vehicle parts.
        -- Vehicle center distance is not the access point of a long vehicle.
        local vehicle, index = call(part, "getVehicle"), call(part, "getIndex")
        reachable = vehicle and nativeInteger(index) and index >= 0
            and call(vehicle, "getPartByIndex", index) == part
            and call(part, "getItemContainer") == current
            and call(vehicle, "canAccessContainer", index, self.player) == true
    end
    if not visible or not self:canAccess(source) or not reachable then
        return nil, "The selected loot source is no longer displayed, accessible, and nearby"
    end
    return true
end

function World:carryFactor(container)
    local inventory, seen = call(self.player, "getInventory"), {}
    while container and container ~= inventory and not seen[container] do
        seen[container] = true
        local bag = call(container, "getContainingItem")
        if not bag then return 1 end
        local parent = call(bag, "getContainer")
        if parent == inventory then
            local equipped = call(self.player, "isEquipped", bag) == true
            if (call(bag, "getAttachedSlot") or -1) >= 0 and not equipped then
                local raw, attached = call(bag, "getUnequippedWeight"), call(bag, "getHotbarEquippedWeight")
                return raw and raw > 0 and attached and math.max(0, attached / raw) or 1
            end
            if equipped or call(bag, "isFakeEquipped", self.player) == true then
                return math.max(0, 1 - (call(bag, "getWeightReduction") or 0) / 100)
            end
            return 1
        end
        container = parent
    end
    return 1
end

function World:carryDelta(item, destination)
    if not self:owns(destination) then return 0 end
    local source = call(item, "getContainer")
    local previous = self:owns(source) and self:carryFactor(source) or 0
    return math.max(0, call(item, "getUnequippedWeight") or 0) * (self:carryFactor(destination) - previous)
end

function World:carrying()
    local inventory = self.player:getInventory()
    local maximum = call(self.player, "isUnlimitedCarry") == true and math.huge or inventory:getEffectiveCapacity(self.player)
    return inventory:getCapacityWeight(), maximum
end

function World:gearRecords(sources)
    local result, seen = {}, {}
    local function add(container)
        if not self:valid(container) or (self.recovery and self.recovery:isReservedContainer(container)) then return end
        if not self:owns(container) and not permitted(self.player, self:square(container)) then return end
        for _, record in ipairs(self:records(container, true)) do
            local id = self:itemId(record.item)
            if id and not seen[id] then seen[id] = true; result[#result + 1] = record end
        end
    end
    add(call(self.player, "getInventory"))
    for _, container in ipairs(sources or {}) do add(container) end
    return result
end

function World:replaceGear(oldId, oldType, item)
    local id = self:itemId(item)
    oldId = tostring(oldId)
    if not id or id == oldId then return end
    for _, field in ipairs({"keep", "itemLabels"}) do
        local values = self.state[field]
        if values[oldId] ~= nil then values[id], values[oldId] = values[oldId], nil; self.dirty = true end
    end
    local labels = self.state.containerLabels
    if labels["bag:" .. oldId] then
        labels["bag:" .. id], labels["bag:" .. oldId] = labels["bag:" .. oldId], nil
        self.dirty = true
    end
    if self.recovery then self.recovery:replaceIdentity(oldId, oldType, item) end
end

function World:safeStagingContainers()
    self:discover()
    local result = {}
    for key, container in pairs(self.endpoints) do
        local anchor = self:sourceAnchor(container)
        if self:valid(container) and self:key(container) == key and anchor and anchor.kind == "world"
            and not self:isTrash(container) and permitted(self.player, self:square(container))
            and call(container, "isLockedToCharacter", self.player) ~= true then
            result[#result + 1] = container
        end
    end
    table.sort(result, function(a, b)
        local first, second = distance(self.player, self:square(a)), distance(self.player, self:square(b))
        if first ~= second then return first < second end
        return (self:key(a) or "") < (self:key(b) or "")
    end)
    return result
end

function World:square(container)
    local visited = {}
    while container and not visited[container] do
        visited[container] = true
        if self:owns(container) then return call(self.player, "getCurrentSquare") or call(self.player, "getSquare") end
        local item = call(container, "getContainingItem")
        if item then
            local square = call(call(item, "getWorldItem"), "getSquare") or call(item, "getSquare")
            if square then return square end
            container = call(item, "getContainer")
        else
            return call(container, "getSourceGrid") or call(container, "getSquare")
                or call(call(container, "getParent"), "getSquare")
        end
    end
end

function World:valid(container)
    if not container then return false end
    if self:owns(container) then return true end
    if call(container, "getType") == "floor" then
        local number = call(self.player, "getPlayerNum")
        return ISInventoryPage and ISInventoryPage.GetFloorContainer
            and container == ISInventoryPage.GetFloorContainer(number)
    end
    local item = call(container, "getContainingItem")
    if item then
        if not isBag(item) or call(item, "getInventory") ~= container then return false end
        local parent = call(item, "getContainer")
        if parent and parent ~= container and self:valid(parent) and call(parent, "contains", item) == true then return true end
        local worldItem = call(item, "getWorldItem")
        local square = call(worldItem, "getSquare")
        local index = call(worldItem, "getWorldObjectIndex") or -1
        return worldItem ~= nil and loaded(square) and index >= 0 and call(worldItem, "getItem") == item
            and at(call(square, "getWorldObjects"), index) == worldItem
    end
    local part = call(container, "getVehiclePart")
    if part then
        local vehicle = call(part, "getVehicle")
        return vehicle ~= nil and loaded(call(vehicle, "getSquare")) and call(vehicle, "isRemovedFromWorld") ~= true
            and call(part, "getItemContainer") == container
            and call(vehicle, "getPartByIndex", call(part, "getIndex")) == part
    end
    local parent = call(container, "getParent")
    local square = self:square(container)
    if not parent or not loaded(square) then return false end
    local slot = call(parent, "getContainerIndex", container)
    if slot == nil or slot < 0 or call(parent, "getContainerByIndex", slot) ~= container then return false end
    if instance(parent, "IsoDeadBody") then return (call(parent, "getStaticMovingObjectIndex") or -1) >= 0 end
    local index = call(parent, "getObjectIndex")
    return index ~= nil and index >= 0 and at(call(square, "getObjects"), index) == parent
end

function World:_rawKey(container)
    if not container then return nil, "No container selected" end
    local bag = call(container, "getContainingItem")
    if bag then
        local id = self:itemId(bag)
        return id and "bag:" .. id or nil, id and nil or "Bag has no stable item ID"
    end
    if container == call(self.player, "getInventory") then return "player:" .. tostring(call(self.player, "getPlayerNum") or 0) end
    local part = call(container, "getVehiclePart")
    if part then
        local vehicle = call(part, "getVehicle")
        if not vehicle then return nil, "Vehicle no longer exists" end
        local keyId, script = vehicleIdentity(vehicle)
        if not keyId then return nil, "Vehicle has no usable native key identity" end
        local resolved, err = uniqueVehicle(keyId, script, vehicle)
        if resolved ~= vehicle then return nil, err end
        return "vehicle:" .. tostring(keyId) .. ":" .. script .. ":" .. tostring(call(part, "getId"))
    end
    if call(container, "getType") == "floor" then return nil, "Floor locations cannot carry container labels" end
    local parent = call(container, "getParent")
    local square = self:square(container)
    local point = squareId(square)
    if not parent or not point then return nil, "Container has no loaded world anchor" end
    local slot = call(parent, "getContainerIndex", container)
    local index = instance(parent, "IsoDeadBody") and call(parent, "getStaticMovingObjectIndex") or call(parent, "getObjectIndex")
    if slot == nil or index == nil or slot < 0 or index < 0 then return nil, "Container is no longer in the world" end
    local kind = instance(parent, "IsoDeadBody") and "corpse" or "world"
    return kind .. ":" .. point .. ":" .. tostring(index) .. ":" .. spriteName(parent)
        .. ":" .. tostring(slot) .. ":" .. tostring(call(container, "getType"))
end

function World:key(container)
    local key, failure = self:_rawKey(container)
    if not key then return nil, failure end
    local previous = self.containerKeys[container]
    if previous and previous ~= key then
        if previous:sub(1, 8) ~= "vehicle:" then
            for _, store in ipairs({self.state.containerLabels, self.state.trash}) do
                if store[previous] ~= nil then self.dirty = true end
                if store[previous] ~= nil and store[key] == nil then store[key] = store[previous] end
                store[previous] = nil
            end
            self.inspectedTrash[previous] = nil
        end
        self.endpoints[previous] = nil
        self.anchors[previous] = nil
    end
    self.containerKeys[container] = key
    return key
end

function World:name(container)
    if self:owns(container) then
        local bag = call(container, "getContainingItem")
        return bag and tostring(call(bag, "getName") or "Carried bag") or "Inventory"
    end
    if call(container, "getType") == "floor" then return "Floor" end
    local bag = call(container, "getContainingItem")
    if bag then return tostring(call(bag, "getName") or "Bag") end
    local part = call(container, "getVehiclePart")
    if part then
        local id = tostring(call(part, "getId") or "Vehicle storage")
        return (getTextOrNull and getTextOrNull("IGUI_VehiclePart" .. id)) or id
    end
    local kind = tostring(call(container, "getType") or "Container")
    local translated = getTextOrNull and getTextOrNull("IGUI_ContainerTitle_" .. kind)
    return translated or kind
end

function World:describe(item)
    local id = self:itemId(item)
    return {fullType = tostring(call(item, "getFullType") or ""), categoryId = Catalog.categoryId(item),
        labels = copy(id and self.state.itemLabels[id] or {})}
end

function World:protected(item, options)
    if not item then return true, "Item is missing" end
    if self.recovery and self.recovery:isProtected(item) then return true, "Personal gear reserved for recovery" end
    local id = self:itemId(item)
    if id and self.state.keep[id] then return true, "Keep" end
    if call(item, "isFavorite") and not (type(options) == "table" and options.allowFavorite == true) then return true, "Favorite" end
    -- Explicit consumption may use held food or a worn vessel in main inventory. This
    -- permission never authorizes moving equipment or bypassing Keep/recovery.
    local equippedConsumption = type(options) == "table" and options.allowEquippedConsumption == true
        and (instance(item, "Food") or call(item, "getFluidContainer") ~= nil)
        and call(item, "getContainer") ~= nil
        and call(item, "getContainer") == call(self.player, "getInventory")
    if not equippedConsumption then
        if call(self.player, "isEquipped", item) or call(item, "isEquipped") or call(item, "isWorn") then return true, "Equipped" end
        if item == call(self.player, "getPrimaryHandItem") or item == call(self.player, "getSecondaryHandItem") then return true, "Held" end
        local attached = call(item, "getAttachedSlot")
        if attached and attached >= 0 then return true, "Attached" end
    end
    if isBag(item) and size(call(call(item, "getInventory"), "getItems")) > 0 then return true, "Bag contains items" end
    return false
end

function World:isTrash(container)
    local parent = call(container, "getParent")
    if not parent or call(parent, "getContainer") ~= container then return false end
    local properties = call(call(parent, "getSprite"), "getProperties")
    return call(properties, "has", "IsTrashCan") == true
end

function World:_observeVehicle(vehicle)
    local id = call(vehicle, "getId")
    if id == nil then return end
    self.vehicles[tostring(id)] = vehicle
    local previous = self.state.vehicle
    local keyId, script = vehicleIdentity(vehicle)
    if type(previous) == "table" and previous.keyId == keyId and previous.script == script then self:vehicle() end
end

function World:_observe(container)
    if not self:valid(container) or container == call(self.player, "getInventory") then return end
    local key = self:key(container)
    if not key then return end
    local parent = call(container, "getParent")
    local square = self:square(container)
    local previous = self.anchors[key]
    if previous and previous.square == square and previous.parent ~= parent and key:sub(1, 8) ~= "vehicle:" then
        if self.state.containerLabels[key] ~= nil or self.state.trash[key] ~= nil then self.dirty = true end
        self.state.containerLabels[key] = nil
        self.state.trash[key] = nil
        self.inspectedTrash[key] = nil
    end
    self.anchors[key] = {parent = parent, square = square}
    self.endpoints[key] = container
    local part = call(container, "getVehiclePart")
    if part then
        local vehicle = call(part, "getVehicle")
        if vehicle then self:_observeVehicle(vehicle) end
    end
    if self:isTrash(container) then
        local point = position(square)
        local memory = {x = point.x, y = point.y, z = point.z, sprite = spriteName(parent),
            index = call(parent, "getObjectIndex"), slot = call(parent, "getContainerIndex", container),
            kind = tostring(call(container, "getType")), capacity = call(container, "getEffectiveCapacity", self.player),
            used = call(container, "getCapacityWeight")}
        local saved = self.state.trash[key]
        for field, value in pairs(memory) do
            if type(saved) ~= "table" or saved[field] ~= value then self.dirty = true; break end
        end
        self.state.trash[key] = memory
    end
end

function World:_containers(square, observe)
    local result, seen = {}, {}
    if not square or not permitted(self.player, square) then return result end
    local function add(container)
        if container and not seen[container] and call(container, "isLockedToCharacter", self.player) ~= true then
            seen[container] = true
            result[#result + 1] = container
            if observe then self:_observe(container) end
        end
    end
    local objects = call(square, "getObjects")
    for index = 0, size(objects) - 1 do
        local object = at(objects, index)
        for slot = 0, (call(object, "getContainerCount") or 0) - 1 do add(call(object, "getContainerByIndex", slot)) end
    end
    local corpses = call(square, "getStaticMovingObjects")
    for index = 0, size(corpses) - 1 do add(call(at(corpses, index), "getContainer")) end
    local moving = call(square, "getMovingObjects")
    for index = 0, size(moving) - 1 do
        local object = at(moving, index)
        if instance(object, "BaseVehicle") then
            if observe then self:_observeVehicle(object) end
            for slot = 0, (call(object, "getPartCount") or 0) - 1 do add(call(call(object, "getPartByIndex", slot), "getItemContainer")) end
        end
    end
    local ground = call(square, "getWorldObjects")
    for index = 0, size(ground) - 1 do
        local item = call(at(ground, index), "getItem")
        if isBag(item) then add(call(item, "getInventory")) end
    end
    return result
end

function World:_scope(request)
    local current = call(self.player, "getCurrentSquare") or call(self.player, "getSquare")
    if not current then return nil, "Player is not in a loaded world" end
    local scope = request.scope or "inventory"
    if scope == "inventory" or scope == "container" or scope == "lootPane" or scope == "labeled" then return {} end
    local squares, seen = {}, {}
    local function add(square)
        local key = squareId(square)
        if key and loaded(square) and not seen[key] and #squares < MAX_SQUARES then
            seen[key] = true
            squares[#squares + 1] = square
        end
    end
    if scope == "reach" then
        local cell = getCell()
        local x, y, z = call(current, "getX"), call(current, "getY"), call(current, "getZ")
        for dy = -1, 1 do for dx = -1, 1 do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            if square and (square == current or call(current, "canReachTo", square)) then add(square) end
        end end
    elseif scope == "room" then
        local room = call(current, "getRoom")
        if not room then return nil, "You are not inside a room" end
        local list = call(room, "getSquares")
        if size(list) > MAX_SQUARES then return nil, "Room exceeds the loaded-scope limit" end
        for index = 0, size(list) - 1 do add(at(list, index)) end
    elseif scope == "area" then
        local area = request.area
        if type(area) ~= "table" then return nil, "Choose an area first" end
        for _, name in ipairs({"x1", "x2", "y1", "y2", "z"}) do
            local value = area[name]
            if not nativeInteger(value) then
                return nil, "Area coordinates must be whole numbers within the native integer range"
            end
        end
        local x1, x2 = math.min(area.x1, area.x2), math.max(area.x1, area.x2)
        local y1, y2 = math.min(area.y1, area.y2), math.max(area.y1, area.y2)
        if (x2 - x1 + 1) * (y2 - y1 + 1) > MAX_SQUARES then return nil, "Area is too large; choose at most 16384 tiles" end
        local cell = getCell()
        for y = y1, y2 do for x = x1, x2 do add(cell:getGridSquare(x, y, area.z)) end end
    else return nil, "Unknown source scope" end
    table.sort(squares, function(a, b)
        local da, db = distance(self.player, a), distance(self.player, b)
        if da == db then return squareId(a) < squareId(b) end
        return da < db
    end)
    return squares
end

function World:records(container, includeBags)
    local result, visited, seen, pending = {}, {}, {}, {container}
    local cursor = 1
    while cursor <= #pending do
        local source = pending[cursor]
        cursor = cursor + 1
        if source and not visited[source] then
            visited[source] = true
            local items = call(source, "getItems")
            for index = 0, size(items) - 1 do
                local item = at(items, index)
                local id = self:itemId(item)
                if item and not seen[id or item] then
                    seen[id or item] = true
                    result[#result + 1] = {item = item, source = source, descriptor = self:describe(item),
                        groundSquare = call(call(item, "getWorldItem"), "getSquare"),
                        itemName = tostring(call(item, "getName") or call(item, "getFullType") or "Item"), from = self:name(source)}
                    if includeBags and isBag(item) then pending[#pending + 1] = call(item, "getInventory") end
                end
            end
        end
    end
    return result
end

function World:sourceMatches(container, request)
    if self:owns(container) then return true end
    local selected = request.sourceLabels or {}
    if request.scope ~= "labeled" and #selected == 0 then return true end
    local key = self:key(container)
    local labels = key and self.state.containerLabels[key] or {}
    return selectedLabels(labels, selected)
end

function World:scan(request)
    request = request or {}
    if request.sourceLabels ~= nil then
        if type(request.sourceLabels) ~= "table" then return nil, "Source labels must be a list" end
        local count = 0
        for index, id in pairs(request.sourceLabels) do
            if not nativeInteger(index) or index < 1 or index > #request.sourceLabels or type(id) ~= "string" then
                return nil, "Source labels must be a dense list of category IDs"
            end
            count = count + 1
        end
        if count ~= #request.sourceLabels then return nil, "Source labels must be a dense list of category IDs" end
    end
    if request.scope == "lootPane" then
        if type(request.sourceContainers) ~= "table" then return nil, "Choose the visible loot containers" end
        local count = 0
        for index in pairs(request.sourceContainers) do
            if not nativeInteger(index) or index < 1 or index > #request.sourceContainers then
                return nil, "Visible loot containers must form a dense list"
            end
            count = count + 1
        end
        if count ~= #request.sourceContainers then return nil, "Visible loot containers must form a dense list" end
    end
    if request.scope == "building" then
        local current = call(self.player, "getCurrentSquare")
        local definition = call(call(current, "getBuilding"), "getDef")
        if not definition then return nil, "Stand inside the building to survey all its rooms and floors" end
        local survey, err = Survey.new(definition, call(call(current, "getRoom"), "getRoomDef"))
        if not survey then return nil, err end
        local result = self:_scan(request, {})
        result.survey = survey
        return result
    end
    local squares, failure = self:_scope(request)
    if not squares then return nil, failure end
    return self:_scan(request, squares)
end

function World:_scan(request, squares)
    local result = {items = {}, sources = {}, groundSquares = {}, warnings = {}}
    local seen, itemSeen = {}, {}
    local function source(container)
        if not container or seen[container] or not self:valid(container) or not self:sourceMatches(container, request) then return end
        if self.recovery and self.recovery:isReservedContainer(container) then return end
        local accessSquare = call(container, "getType") == "floor" and call(self.player, "getCurrentSquare") or self:square(container)
        if not self:owns(container) and not permitted(self.player, accessSquare) then
            result.warnings[#result.warnings + 1] = "Safehouse permissions do not allow this source: " .. self:name(container)
            return
        end
        seen[container] = true
        result.sources[#result.sources + 1] = container
        if call(container, "isExplored") == false and not self:owns(container) then
            result.warnings[#result.warnings + 1] = self:name(container) .. " needs native exploration after approach"
            return
        end
        for _, record in ipairs(self:records(container, request.includeBags == true and request.scope ~= "lootPane")) do
            local key = self:itemId(record.item) or record.item
            if not itemSeen[key] then
                itemSeen[key] = true
                if record.groundSquare and not permitted(self.player, record.groundSquare) then
                    result.warnings[#result.warnings + 1] = "Safehouse permissions do not allow this floor item: " .. record.itemName
                else result.items[#result.items + 1] = record end
            end
        end
    end
    if request.scope == "inventory" or request.scope == nil or (request.includeInventory and request.scope ~= "lootPane") then source(call(self.player, "getInventory")) end
    if request.scope == "container" then
        if not request.sourceContainer then return nil, "Choose a source container" end
        if not self:valid(request.sourceContainer) then return nil, "Source container is no longer available" end
        source(request.sourceContainer)
    elseif request.scope == "lootPane" then
        if type(request.sourceContainers) ~= "table" then return nil, "Choose the visible loot containers" end
        local visible, err = self:smartLootSources(nil, true)
        if not visible then return nil, err end
        local eligible = {}
        for _, container in ipairs(visible) do eligible[container] = true end
        for _, container in ipairs(request.sourceContainers) do
            if eligible[container] then source(container)
            else result.warnings[#result.warnings + 1] = "A selected loot-pane source is no longer visible or eligible; it was left untouched" end
        end
    elseif request.scope == "reach" then
        local list = ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers(self.player)
        for index = 0, size(list) - 1 do
            local container = at(list, index)
            if request.includeInventory or not self:owns(container) then source(container) end
        end
    elseif request.scope == "labeled" then
        self:discover()
        local candidates = {}
        for _, container in pairs(self.endpoints) do
            if not self:owns(container) then candidates[#candidates + 1] = container end
        end
        table.sort(candidates, function(a, b)
            local da, db = distance(self.player, self:square(a)), distance(self.player, self:square(b))
            if da == db then return (self:key(a) or "") < (self:key(b) or "") end
            return da < db
        end)
        for _, container in ipairs(candidates) do source(container) end
        local unavailable = 0
        for key, labels in pairs(self.state.containerLabels) do
            if not key:match("^player:") and selectedLabels(labels, request.sourceLabels or {}) then
                local container = self.endpoints[key]
                if not container or not self:valid(container) then unavailable = unavailable + 1 end
            end
        end
        if unavailable > 0 then
            result.warnings[#result.warnings + 1] = tostring(unavailable) .. " matching labeled sources are not loaded or could not be resolved"
        end
    end
    for _, square in ipairs(squares) do
        if permitted(self.player, square) then
            local observed = call(square, "isSeen", call(self.player, "getPlayerNum")) == true
            local containers = self:_containers(square, observed)
            if request.scope ~= "reach" then for _, container in ipairs(containers) do source(container) end end
            if not request.sourceLabels or #request.sourceLabels == 0 then
                if size(call(square, "getWorldObjects")) > 0 then result.groundSquares[#result.groundSquares + 1] = square end
            end
        end
    end
    return result
end

function World:point()
    return position(call(self.player, "getCurrentSquare"))
end

function World:locationLoaded(point)
    return point and getCell():getGridSquare(point.x, point.y, point.z) ~= nil
end

function World:sourceAnchor(container, visited)
    visited = visited or {}
    if not container or visited[container] then return nil end
    visited[container] = true
    if self:owns(container) then
        local bag = call(container, "getContainingItem")
        return {kind = "carried", bagId = bag and self:itemId(bag)}
    end
    local bag = call(container, "getContainingItem")
    if bag then
        local world = call(bag, "getWorldItem")
        local anchor = {kind = world and "groundBag" or "bag", itemId = call(bag, "getID"),
            fullType = tostring(call(bag, "getFullType")), point = position(self:square(container))}
        if not world then anchor.parent = self:sourceAnchor(call(bag, "getContainer"), visited) end
        return (world or anchor.parent) and anchor or nil
    end
    local part = call(container, "getVehiclePart")
    if part then
        local vehicle = call(part, "getVehicle")
        local keyId, model = vehicleIdentity(vehicle)
        if not keyId then return {kind = "live", container = container, point = position(call(vehicle, "getSquare"))} end
        return {kind = "vehicle", keyId = keyId, model = model, partId = call(part, "getId"),
            vehicleId = call(vehicle, "getId"), point = position(call(vehicle, "getSquare"))}
    end
    local parent, square = call(container, "getParent"), self:square(container)
    if not parent or not square then return nil end
    local corpse = instance(parent, "IsoDeadBody")
    return {kind = corpse and "corpse" or "world", point = position(square), sprite = spriteName(parent), parent = parent, square = square,
        index = call(parent, corpse and "getStaticMovingObjectIndex" or "getObjectIndex"),
        slot = call(parent, "getContainerIndex", container), containerType = call(container, "getType")}
end

function World:resolveSource(anchor)
    if not anchor then return nil, "Source has no stable location" end
    if anchor.kind == "live" then
        if self:valid(anchor.container) then return anchor.container end
        return nil, "The unkeyed source vehicle changed or unloaded; select it again"
    end
    if anchor.kind == "carried" then
        local inventory = call(self.player, "getInventory")
        if not anchor.bagId then return inventory end
        for _, record in ipairs(self:records(inventory, true)) do
            if self:itemId(record.item) == anchor.bagId and isBag(record.item) then return call(record.item, "getInventory") end
        end
        return nil, "Carried source bag is no longer present"
    end
    if anchor.kind == "bag" then
        local parent, reason = self:resolveSource(anchor.parent)
        if not parent then return nil, reason end
        local item = call(parent, "getItemWithID", anchor.itemId)
        if item and tostring(call(item, "getFullType")) == anchor.fullType and isBag(item) then return call(item, "getInventory") end
        return nil, "Source bag changed after preview"
    end
    if anchor.kind == "vehicle" then
        local hint = getVehicleById and getVehicleById(anchor.vehicleId)
        local vehicle, reason = uniqueVehicle(anchor.keyId, anchor.model, hint)
        if vehicle then
            local container = call(call(vehicle, "getPartById", anchor.partId), "getItemContainer")
            if container and self:valid(container) then return container end
        end
        if anchor.point and not self:locationLoaded(anchor.point) then return nil, "unloaded" end
        return nil, reason or "Source vehicle storage is unavailable"
    end
    local point = anchor.point
    local square = point and getCell():getGridSquare(point.x, point.y, point.z)
    if not square then return nil, "unloaded" end
    if anchor.kind == "groundBag" then
        local objects = call(square, "getWorldObjects")
        for index = 0, size(objects) - 1 do
            local item = call(at(objects, index), "getItem")
            if call(item, "getID") == anchor.itemId and tostring(call(item, "getFullType")) == anchor.fullType and isBag(item) then
                return call(item, "getInventory")
            end
        end
        return nil, "Ground source bag changed after preview"
    end
    local objects = call(square, anchor.kind == "corpse" and "getStaticMovingObjects" or "getObjects")
    local object = nativeInteger(anchor.index) and at(objects, anchor.index)
    local container = object and nativeInteger(anchor.slot) and call(object, "getContainerByIndex", anchor.slot)
    if container and spriteName(object) == anchor.sprite and call(container, "getType") == anchor.containerType
        and self:valid(container) then
        if anchor.square == square and anchor.parent ~= object then return nil, "Source storage was replaced after preview" end
        return container
    end
    return nil, "Source storage changed after preview"
end

function World:sectionTarget(section)
    local best, score
    local cx, cy = (section.x1 + section.x2 - 1) / 2, (section.y1 + section.y2 - 1) / 2
    for y = section.y1, section.y2 - 1 do for x = section.x1, section.x2 - 1 do
        local square = getCell():getGridSquare(x, y, section.z)
        if square and call(call(square, "getRoom"), "getRoomDef") == section.room
            and permitted(self.player, square) and call(square, "getFloor") and call(square, "isFree", false) then
            local value = (x - cx) ^ 2 + (y - cy) ^ 2
            if not score or value < score then best, score = {x = x, y = y, z = section.z}, value end
        end
    end end
    return best or {x = math.floor(cx), y = math.floor(cy), z = section.z}
end

function World:walkTargets(point, visited, building)
    local current = self:point()
    if not current then return nil, "Player has no loaded location" end
    local cell = getCell()
    local direct = cell:getGridSquare(point.x, point.y, point.z)
    if direct then
        if not permitted(self.player, direct) then return nil, "Permission does not allow this destination" end
        local owner = call(call(call(direct, "getRoom"), "getRoomDef"), "getBuilding")
        if building and owner ~= building then return nil, "The survey waypoint is outside the original building" end
        return {point}, true
    end
    local z = point.z
    if math.abs(z - current.z) > 1 then z = current.z + (z > current.z and 1 or -1) end
    local candidates = {}
    local before = (point.x - current.x) ^ 2 + (point.y - current.y) ^ 2
    local levels = z == current.z and {z} or {z, current.z}
    for _, level in ipairs(levels) do
        for dy = -24, 24, 3 do for dx = -24, 24, 3 do
            local x, y = current.x + dx, current.y + dy
            local id = x .. ":" .. y .. ":" .. level
            local remaining = (point.x - x) ^ 2 + (point.y - y) ^ 2
            if not visited[id] and (level ~= current.z or remaining + 9 < before) then
                local square = cell:getGridSquare(x, y, level)
                local owner = square and call(call(call(square, "getRoom"), "getRoomDef"), "getBuilding")
                if square and (not building or owner == building or (level == 0 and owner == nil)) and permitted(self.player, square)
                    and call(square, "getFloor") and call(square, "isFree", false) then
                    candidates[#candidates + 1] = {x = x, y = y, z = level, score = remaining + (dx * dx + dy * dy) * 0.05}
                end
            end
        end end
        if #candidates > 0 then break end
    end
    table.sort(candidates, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    local result = {}
    for index = 1, math.min(16, #candidates) do
        local value = candidates[index]
        result[index] = {x = value.x, y = value.y, z = value.z}
    end
    if #result == 0 then return nil, "No loaded walking frontier reaches the unsearched location" end
    return result, false
end

function World:scanSection(section, request)
    local squares, missing, denied = {}, 0, 0
    for y = section.y1, section.y2 - 1 do for x = section.x1, section.x2 - 1 do
        if call(section.room, "getBuilding") ~= section.building then missing = missing + 1
        elseif call(section.room, "contains", x, y) ~= false then
            local square = getCell():getGridSquare(x, y, section.z)
            if not square or call(call(square, "getRoom"), "getRoomDef") ~= section.room then missing = missing + 1
            elseif not permitted(self.player, square) then denied = denied + 1
            else squares[#squares + 1] = square end
        end
    end end
    local scoped = {}
    for key, value in pairs(request) do scoped[key] = value end
    scoped.includeInventory = false
    return self:_scan(scoped, squares), missing, denied
end

function World:discoveryLevels()
    local point, levels, seen = self:point(), {}, {}
    if not point then return levels end
    local function add(z)
        if nativeInteger(z) and z >= -32 and z <= 31 and not seen[z] then seen[z] = true; levels[#levels + 1] = z end
    end
    add(point.z); add(0)
    local definition = call(call(call(self.player, "getCurrentSquare"), "getBuilding"), "getDef")
    local first, last = call(definition, "getMinLevel"), call(definition, "getMaxLevel")
    if nativeInteger(first) and nativeInteger(last) then
        for z = math.max(-32, first), math.min(31, last) do add(z) end
    end
    return levels
end

function World:discover()
    local current = call(self.player, "getCurrentSquare") or call(self.player, "getSquare")
    if not current then return end
    local cell = getCell()
    local x, y, z = call(current, "getX"), call(current, "getY"), call(current, "getZ")
    for _, level in ipairs(self:discoveryLevels()) do
    for dy = -DISCOVERY_RADIUS, DISCOVERY_RADIUS do for dx = -DISCOVERY_RADIUS, DISCOVERY_RADIUS do
        local square = cell:getGridSquare(x + dx, y + dy, level)
        if square and call(square, "isSeen", call(self.player, "getPlayerNum")) == true then self:_containers(square, true)
        elseif square and permitted(self.player, square) then
            for _, container in ipairs(self:_containers(square, false)) do
                if self:isTrash(container) then self:_observe(container) end
            end
        end
    end end
    end
    for _, vehicle in ipairs(liveVehicles() or {}) do
        local square = call(vehicle, "getSquare")
        if permitted(self.player, square) and call(square, "isSeen", call(self.player, "getPlayerNum")) == true then
            local nearby = distance(self.player, square) <= DISCOVERY_RADIUS * DISCOVERY_RADIUS
            if nearby then self:_observeVehicle(vehicle) end
            for index = 0, (call(vehicle, "getPartCount") or 0) - 1 do
                local container = call(call(vehicle, "getPartByIndex", index), "getItemContainer")
                local key = container and self:_rawKey(container)
                if key and (nearby or self.state.containerLabels[key] ~= nil) then self:_observe(container) end
            end
        end
    end
    local labeledSquares = {}
    for key in pairs(self.state.containerLabels) do
        local kind, x, y, floor = tostring(key):match("^([^:]+):([^:]+):([^:]+):([^:]+):")
        x, y, floor = tonumber(x), tonumber(y), tonumber(floor)
        if (kind == "world" or kind == "corpse") and nativeInteger(x) and nativeInteger(y) and nativeInteger(floor) then
            local id = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(floor)
            if not labeledSquares[id] then
                labeledSquares[id] = true
                local square = cell:getGridSquare(x, y, floor)
                if square and call(square, "isSeen", call(self.player, "getPlayerNum")) == true then self:_containers(square, true) end
            end
        end
    end
    for _, record in ipairs(self:records(call(self.player, "getInventory"), true)) do
        if isBag(record.item) then self:_observe(call(record.item, "getInventory")) end
    end
    for key, container in pairs(self.endpoints) do
        if not self:valid(container) then
            self.endpoints[key] = nil
            self.containerKeys[container] = nil
            self.inspectedTrash[key] = nil
            if self.state.containerLabels[key] == nil and self.state.trash[key] == nil then self.anchors[key] = nil end
        end
    end
end

function World:observeNearby()
    local changed = self.dirty == true
    self.dirty = false
    local current = call(self.player, "getCurrentSquare") or call(self.player, "getSquare")
    local tile = squareId(current)
    if not tile or tile == self.observedTile then return changed end
    self.observedTile = tile
    local cell = getCell()
    local x, y, z = call(current, "getX"), call(current, "getY"), call(current, "getZ")
    local inspected = {}
    for dy = -1, 1 do for dx = -1, 1 do
        local square = cell:getGridSquare(x + dx, y + dy, z)
        if square and (square == current or call(current, "canReachTo", square))
            and call(square, "isSeen", call(self.player, "getPlayerNum")) == true and permitted(self.player, square) then
            inspected[squareId(square)] = true
            self:_containers(square, true)
        end
    end end
    for key, memory in pairs(self.state.trash) do
        if type(memory) == "table" and inspected[tostring(memory.x) .. ":" .. tostring(memory.y) .. ":" .. tostring(memory.z)] then
            local container, reason = self:_resolveTrash(memory, key)
            if not container and reason == "missing" then
                self.state.trash[key] = nil
                self.state.containerLabels[key] = nil
                self.endpoints[key] = nil
                self.anchors[key] = nil
                self.inspectedTrash[key] = nil
                self.dirty = true
            end
        end
    end
    changed = changed or self.dirty == true
    self.dirty = false
    return changed
end

function World:rememberVehicle(vehicle)
    if not vehicle or call(vehicle, "isRemovedFromWorld") == true then return nil, "Vehicle is no longer available" end
    local id = call(vehicle, "getId")
    local keyId, script = vehicleIdentity(vehicle)
    if not nativeInteger(id) or not keyId then return nil, "Vehicle has no usable native key identity" end
    local resolved, err = uniqueVehicle(keyId, script, vehicle)
    if resolved ~= vehicle then return nil, err end
    local point = position(call(vehicle, "getSquare"))
    if not point then return nil, "Vehicle is not in a loaded square" end
    self.vehicles[tostring(id)] = vehicle
    local remembered = {id = id, keyId = keyId, x = point.x, y = point.y, z = point.z, script = script}
    for field, value in pairs(remembered) do
        if type(self.state.vehicle) ~= "table" or self.state.vehicle[field] ~= value then self.dirty = true; break end
    end
    self.state.vehicle = remembered
    return true
end

function World:vehicle()
    local remembered = self.state.vehicle
    if not remembered then return nil end
    if type(remembered) ~= "table" or not nativeInteger(remembered.id) or not nativeInteger(remembered.keyId) or remembered.keyId < 0
        or type(remembered.script) ~= "string" then return nil, "Remember this vehicle again to confirm its native identity" end
    local hint = getVehicleById and getVehicleById(remembered.id) or self.vehicles[tostring(remembered.id)]
    local vehicle, err = uniqueVehicle(remembered.keyId, remembered.script, hint)
    if not vehicle then return nil, err end
    local point, id = position(call(vehicle, "getSquare")), call(vehicle, "getId")
    if not nativeInteger(id) then return nil, "Vehicle has no usable native network ID" end
    if remembered.id ~= id or remembered.x ~= point.x or remembered.y ~= point.y or remembered.z ~= point.z then
        remembered.id, remembered.x, remembered.y, remembered.z = id, point.x, point.y, point.z
        self.dirty = true
    end
    self.vehicles[tostring(id)] = vehicle
    return vehicle
end

function World:knownVehicles()
    self:discover()
    local result, seen = {}, {}
    for id, vehicle in pairs(self.vehicles) do
        if call(vehicle, "isRemovedFromWorld") == true or not loaded(call(vehicle, "getSquare"))
            or tostring(call(vehicle, "getId")) ~= id then
            self.vehicles[id] = nil
        elseif not seen[vehicle] then result[#result + 1] = vehicle; seen[vehicle] = true end
    end
    table.sort(result, function(a, b)
        local da, db = distance(self.player, call(a, "getSquare")), distance(self.player, call(b, "getSquare"))
        if da == db then return tostring(call(a, "getId")) < tostring(call(b, "getId")) end
        return da < db
    end)
    return result
end

function World:_resolveTrash(memory, key)
    if type(memory) ~= "table" or not nativeInteger(memory.x) or not nativeInteger(memory.y) or not nativeInteger(memory.z)
        or not nativeInteger(memory.index) or memory.index < 0 or not nativeInteger(memory.slot) or memory.slot < 0
        or type(memory.sprite) ~= "string" or type(memory.kind) ~= "string" then
        self.inspectedTrash[key] = nil
        return nil, "invalid"
    end
    local previous = self.endpoints[key]
    if previous and self:valid(previous) and self:isTrash(previous) then return previous end
    local square = getCell():getGridSquare(memory.x, memory.y, memory.z)
    if not square then self.inspectedTrash[key] = nil; return nil, "unloaded" end
    local object = at(call(square, "getObjects"), memory.index)
    if object and spriteName(object) == memory.sprite then
        local container = call(object, "getContainerByIndex", memory.slot)
        if container and tostring(call(container, "getType")) == memory.kind and self:isTrash(container) then return container end
    end
    self.inspectedTrash[key] = nil
    return nil, "missing"
end

function World:trashCandidates()
    self:discover()
    local result, warnings, seen = {}, {}, {}
    for key, memory in pairs(self.state.trash) do
        local container, reason = self:_resolveTrash(memory, key)
        if container and self:valid(container) then
            if permitted(self.player, self:square(container)) then
                if not seen[container] then result[#result + 1] = container; seen[container] = true end
                self.endpoints[key] = container
            else warnings[#warnings + 1] = "Safehouse permissions block a remembered trash can" end
        elseif reason == "unloaded" then warnings[#warnings + 1] = "Remembered trash can at " .. memory.x .. ", " .. memory.y .. " is not loaded"
        elseif reason == "invalid" then warnings[#warnings + 1] = "A remembered trash can has invalid saved identity data"
        else
            self.state.trash[key], self.endpoints[key], self.inspectedTrash[key] = nil, nil, nil
            self.dirty = true
        end
    end
    table.sort(result, function(a, b)
        local da, db = distance(self.player, self:square(a)), distance(self.player, self:square(b))
        if da == db then return (self:key(a) or "") < (self:key(b) or "") end
        return da < db
    end)
    return result, warnings
end

function World:trashTarget(container)
    self:_observe(container)
    local key = self:key(container)
    local memory = key and self.state.trash[key]
    if not memory then return nil end
    local snapshot = {}
    for field, value in pairs(memory) do snapshot[field] = value end
    local target = {key = key, memory = snapshot, point = {x = memory.x, y = memory.y, z = memory.z}, container = container,
        capacity = container:getEffectiveCapacity(self.player), used = container:getCapacityWeight(),
        anchor = {parent = call(container, "getParent"), square = self:square(container)}}
    local inspected = self.inspectedTrash[key]
    local same = inspected and inspected.parent == target.anchor.parent and inspected.square == target.anchor.square
    target.needsInspection = not same and not self:binReachable(target) or nil
    return target
end

function World:binReachable(target)
    local current, point = call(self.player, "getCurrentSquare"), target.point
    local square = point and getCell():getGridSquare(point.x, point.y, point.z)
    return current and square and call(current, "getZ") == point.z
        and permitted(self.player, square)
        and math.abs(call(current, "getX") - point.x) <= 1 and math.abs(call(current, "getY") - point.y) <= 1
        and (current == square or call(current, "canReachTo", square) == true)
end

function World:markTrashInspected(target)
    if self:binReachable(target) then
        local bin = self:resolveTrashTarget(target)
        if not bin then return nil end
        self.inspectedTrash[target.key] = {parent = call(bin, "getParent"), square = self:square(bin)}
        return true
    end
end

function World:unloadedTrashTargets()
    local result = {}
    for key, memory in pairs(self.state.trash) do
        local _, reason = self:_resolveTrash(memory, key)
        if reason == "unloaded" then
            local snapshot = {}
            for field, value in pairs(memory) do snapshot[field] = value end
            result[#result + 1] = {key = key, memory = snapshot, point = {x = memory.x, y = memory.y, z = memory.z},
                capacity = memory.capacity or 0, used = memory.used or 0, needsInspection = true}
        end
    end
    local origin = self:point()
    table.sort(result, function(a, b)
        local function score(target)
            return (target.point.x - origin.x) ^ 2 + (target.point.y - origin.y) ^ 2 + (target.point.z - origin.z) ^ 2 * 100
        end
        local first, last = score(a), score(b)
        return first < last or (first == last and a.key < b.key)
    end)
    return result
end

function World:resolveTrashTarget(target)
    local container, reason = self:_resolveTrash(target.memory, target.key)
    if container and self:valid(container) then
        if not permitted(self.player, self:square(container)) then return nil, "Safehouse permissions block this trash can" end
        local square, parent = self:square(container), call(container, "getParent")
        if target.anchor and target.anchor.square == square and target.anchor.parent ~= parent then
            return nil, "The trash can was replaced after preview"
        end
        target.container = container
        target.anchor = {parent = parent, square = square}
        target.point = position(self:square(container))
        target.capacity, target.used = container:getEffectiveCapacity(self.player), container:getCapacityWeight()
        return container
    end
    return nil, reason
end

function World:matchingOrder(records)
    local loot = getPlayerLoot and getPlayerLoot(call(self.player, "getPlayerNum"))
    local pane = loot and loot.inventoryPane
    if not pane or type(pane.sortItemsByTypeAndWeight) ~= "function" then return records end
    local items, byItem = {}, {}
    for _, record in ipairs(records) do
        items[#items + 1] = record.item
        byItem[record.item] = record
    end
    local ok = pcall(pane.sortItemsByTypeAndWeight, pane, items)
    if not ok then return nil, "The game's matching-transfer order could not be read" end
    local result = {}
    for _, item in ipairs(items) do result[#result + 1] = byItem[item] end
    return result
end

function World:matchingTargets(mode, records)
    if mode ~= "displayed" and mode ~= "nearby" then return nil, "Choose the displayed container or nearby containers" end
    local rules = ISInventoryWindowControlHandler_TransferSameType
    if not rules or type(rules.getItemsTable) ~= "function" then return nil, "The game's matching-transfer rules are unavailable" end
    local loot = getPlayerLoot and getPlayerLoot(call(self.player, "getPlayerNum"))
    if not loot or not loot.inventoryPane then return {} end
    local containers, eligible, sourceMaps, aliases = {}, {}, {}, {}
    local function itemMap(container)
        local ok, result = pcall(rules.getItemsTable, rules, container)
        if not ok or type(result) ~= "table" then return nil, "The game's matching-transfer rules could not read this container" end
        return result
    end
    for _, record in ipairs(records or {}) do
        if record.item and self:canAccess(record.source) and not self:protected(record.item) then
            eligible[record.item] = true
            if not sourceMaps[record.source] then
                local map, err = itemMap(record.source)
                if not map then return nil, err end
                sourceMaps[record.source] = map
            end
        end
    end
    for _, map in pairs(sourceMaps) do
        for fullType, items in pairs(map) do
            aliases[fullType] = aliases[fullType] or {}
            for _, item in ipairs(items) do if eligible[item] then aliases[fullType][item] = true end end
        end
    end
    local seen = {}
    local function add(container)
        if not container or seen[container] or self:owns(container) or not self:canAccess(container) then return end
        if self.recovery and self.recovery:isReservedContainer(container) then return end
        seen[container] = true
        containers[#containers + 1] = container
    end
    if mode == "displayed" then add(loot.inventoryPane.inventory)
    else for _, button in ipairs(loot.backpacks or {}) do add(button.inventory) end end
    local result = {}
    for _, container in ipairs(containers) do
        local map, err = itemMap(container)
        if not map then return nil, err end
        local types = {}
        for fullType in pairs(map) do
            for item in pairs(aliases[fullType] or {}) do types[tostring(item:getFullType())] = true end
        end
        local floor = call(container, "getType") == "floor"
        local anchor = not floor and self:sourceAnchor(container) or nil
        local point = floor and self:point() or nil
        if anchor or point then result[#result + 1] = {ref = container, anchor = anchor, point = point, types = types} end
    end
    return result
end

function World:matchingRecords(mode)
    local scan, err = self:scan({scope = "inventory", includeBags = true})
    if not scan then return nil, nil, err end
    local ordered
    ordered, err = self:matchingOrder(scan.items)
    if not ordered then return nil, nil, err end
    local targets
    targets, err = self:matchingTargets(mode, ordered)
    if not targets then return nil, nil, err end
    local records, seen = {}, {}
    for _, record in ipairs(ordered) do
        if not seen[record.item] and not self:protected(record.item) then
            for _, target in ipairs(targets) do
                if target.types[tostring(record.item:getFullType())] then
                    seen[record.item] = true
                    records[#records + 1] = record
                    break
                end
            end
        end
    end
    return records, targets
end

function World:smartLootSources(container, allContainers)
    if not allContainers then
        if not container or self:owns(container) or not self:valid(container) or not self:canAccess(container) then
            return nil, "The displayed loot container is no longer accessible"
        end
        if self.recovery and self.recovery:isReservedContainer(container) then
            return nil, "Recover staged personal gear before looting this container"
        end
        return {container}
    end
    local loot = getPlayerLoot and getPlayerLoot(call(self.player, "getPlayerNum"))
    if not loot or not loot.inventoryPane then return nil, "The loot pane is unavailable" end
    local result, seen = {}, {}
    local function add(source)
        if not source or seen[source] or self:owns(source) or not self:canAccess(source) then return end
        if self.recovery and self.recovery:isReservedContainer(source) then return end
        seen[source], result[#result + 1] = true, source
    end
    add(loot.inventoryPane.inventory)
    for _, button in ipairs(loot.backpacks or {}) do add(button.inventory) end
    return result
end

function World:smartLootRecords(mode, container, allContainers)
    if mode ~= "all" and mode ~= "matching" then return nil, "Choose Smart Take All or Smart Take Matching" end
    local sources, err = self:smartLootSources(container, allContainers == true)
    if not sources then return nil, err end
    local records, seenItems = {}, {}
    for _, source in ipairs(sources) do
        for _, record in ipairs(self:records(source, false)) do
            local id = self:itemId(record.item) or record.item
            if not seenItems[id] then seenItems[id] = true; records[#records + 1] = record end
        end
    end
    if mode == "matching" then
        local rules = ISInventoryWindowControlHandler_TransferSameType
        if not rules or type(rules.getItemsTable) ~= "function" then return nil, "The game's matching-transfer rules are unavailable" end
        local carried, seen, selected = {}, {}, {}
        local inventory = self.player:getInventory()
        local containers = {inventory}
        for _, record in ipairs(self:records(inventory, true)) do
            if isBag(record.item) then containers[#containers + 1] = call(record.item, "getInventory") end
        end
        for _, source in ipairs(containers) do
            if not seen[source] then
                seen[source] = true
                local ok, map = pcall(rules.getItemsTable, rules, source)
                if not ok or type(map) ~= "table" then return nil, "The game's matching-transfer rules could not read carried storage" end
                for fullType in pairs(map) do carried[fullType] = true end
            end
        end
        for _, source in ipairs(sources) do
            local ok, map = pcall(rules.getItemsTable, rules, source)
            if not ok or type(map) ~= "table" then return nil, "The game's matching-transfer rules could not read this container" end
            for fullType, items in pairs(map) do
                if carried[fullType] then for _, item in ipairs(items) do selected[item] = true end end
            end
        end
        local matching = {}
        for _, record in ipairs(records) do if selected[record.item] then matching[#matching + 1] = record end end
        records = matching
    end
    local eligible = {}
    for _, record in ipairs(records) do
        if not self:protected(record.item) and call(record.item, "isUnwanted", self.player) ~= true
            and (not record.groundSquare or permitted(self.player, record.groundSquare)) then eligible[#eligible + 1] = record end
    end
    local ordered, problem = self:matchingOrder(eligible)
    return ordered, problem, sources
end

function World:matchingPoint(request, container)
    if request.destination.kind ~= "matching" or call(container, "getType") ~= "floor" then return nil end
    for _, target in ipairs(request.destination.targets or {}) do
        if target.point then return {x = target.point.x, y = target.point.y, z = target.point.z} end
    end
end

function World:destinations(request, item)
    local destination = request.destination or {}
    local result, seen = {}, {}
    local function add(container)
        if not container or seen[container] or not self:valid(container) then return end
        if self.recovery and self.recovery:isReservedContainer(container) then return end
        if item and ((container == call(item, "getContainer") and call(container, "getType") ~= "floor")
            or call(container, "isInside", item)) then return end
        seen[container] = true
        result[#result + 1] = container
    end
    if destination.kind == "inventory" then
        local inventory = call(self.player, "getInventory")
        for _, record in ipairs(self:records(inventory, true)) do
            if isBag(record.item) then add(call(record.item, "getInventory")) end
        end
        local order, factors, similar = {}, {}, {}
        local rules = ISInventoryWindowControlHandler_TransferSameType
        local sourceMap
        if item and rules and type(rules.getItemsTable) == "function" then
            local ok, map = pcall(rules.getItemsTable, rules, call(item, "getContainer"))
            if ok and type(map) == "table" then
                sourceMap = {}
                for fullType, items in pairs(map) do
                    for _, candidate in ipairs(items) do if candidate == item then sourceMap[fullType] = true; break end end
                end
            end
        end
        for index, container in ipairs(result) do
            order[container], factors[container] = index, self:carryFactor(container)
            if item then
                if sourceMap then
                    local ok, map = pcall(rules.getItemsTable, rules, container)
                    if ok and type(map) == "table" then
                        for fullType in pairs(sourceMap) do if map[fullType] then similar[container] = true; break end end
                    end
                else
                    for _, record in ipairs(self:records(container, false)) do
                        if record.item ~= item and tostring(record.item:getFullType()) == tostring(item:getFullType()) then similar[container] = true; break end
                    end
                end
            end
        end
        table.sort(result, function(a, b)
            if (similar[a] == true) ~= (similar[b] == true) then return similar[a] == true end
            if factors[a] ~= factors[b] then return factors[a] < factors[b] end
            return order[a] < order[b]
        end)
        add(inventory)
    elseif destination.kind == "floor" then
        if ISInventoryPage and ISInventoryPage.GetFloorContainer then add(ISInventoryPage.GetFloorContainer(call(self.player, "getPlayerNum"))) end
    elseif destination.kind == "container" then
        if not self:valid(destination.ref) then return nil, "Destination container is no longer available" end
        add(destination.ref)
    elseif destination.kind == "matching" then
        for _, target in ipairs(destination.targets or {}) do
            if item and target.types[tostring(call(item, "getFullType"))] then
                local container = target.ref
                if target.anchor then container = self:resolveSource(target.anchor)
                elseif target.point and ISInventoryPage and ISInventoryPage.GetFloorContainer then
                    local square = getCell():getGridSquare(target.point.x, target.point.y, target.point.z)
                    if not square or permitted(self.player, square) then container = ISInventoryPage.GetFloorContainer(call(self.player, "getPlayerNum"))
                    else container = nil end
                end
                if container and not self:owns(container) and self:canAccess(container) then add(container) end
            end
        end
    elseif destination.kind == "vehicle" then
        local vehicle, err = destination.ref
        if not vehicle then vehicle, err = self:vehicle() end
        if not vehicle or call(vehicle, "isRemovedFromWorld") == true then return nil, err or "Remember or select a loaded vehicle first" end
        local parts = {}
        for index = 0, (call(vehicle, "getPartCount") or 0) - 1 do
            local part = call(vehicle, "getPartByIndex", index)
            local container = call(part, "getItemContainer")
            if container and call(container, "isOccupiedVehicleSeat") ~= true then
                local id = tostring(call(part, "getId") or "")
                local priority = call(part, "isVehicleTrunk") and 0 or (string.sub(id, 1, 4) == "Seat" and 1 or 2)
                parts[#parts + 1] = {container = container, priority = priority, index = index}
            end
        end
        table.sort(parts, function(a, b) if a.priority == b.priority then return a.index < b.index end; return a.priority < b.priority end)
        for _, part in ipairs(parts) do add(part.container) end
    elseif destination.kind == "labels" then
        self:discover()
        local descriptor = item and self:describe(item)
        local candidates = {}
        for key, container in pairs(self.endpoints) do
            local labels = self.state.containerLabels[key]
            if labels and self:key(container) == key and descriptor and self.graph then
                for _, id in ipairs(labels) do
                    if (not destination.labels or #destination.labels == 0 or contains(destination.labels, id)) and self.graph:matches(id, descriptor) then
                        candidates[#candidates + 1] = container
                        break
                    end
                end
            end
        end
        table.sort(candidates, function(a, b)
            local da, db = distance(self.player, self:square(a)), distance(self.player, self:square(b))
            if da == db then return (self:key(a) or "") < (self:key(b) or "") end
            return da < db
        end)
        for _, container in ipairs(candidates) do add(container) end
    elseif destination.kind == "trash" then
        local candidates = self:trashCandidates()
        for _, container in ipairs(candidates) do add(container) end
    else return nil, "Choose a destination" end
    return result
end

return World
