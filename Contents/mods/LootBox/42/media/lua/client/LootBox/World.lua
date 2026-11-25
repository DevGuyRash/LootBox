local Catalog = require "LootBox/Catalog"
local Survey = require "LootBox/Survey"
local Facts = require "LootBox/Facts"
local Items = require "LootBox/Items"
local Labels = require "LootBox/Labels"
local Log = require "LootBox/Log"
local call = require "LootBox/Safe"
local Sort = require "LootBox/Sort"
local Storage = require "LootBox/Storage"

local World = {}
World.__index = World
for name, method in pairs(Facts) do World[name] = method end
for name, method in pairs(Storage) do World[name] = method end

local MAX_SQUARES, PLAN_SQUARES = 16384, 4096
local DISCOVERY_RADIUS, SIGHT, SMALLEST_BIN = 12, 8, 10
local PRUNE_MS = 60000

local function nativeInteger(value)
    return type(value) == "number" and value == value and math.abs(value) <= 2147483647 and value == math.floor(value)
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

local asking
local function ask(object, method, ...)
    if not object then return nil end
    asking = method
    local fn = object[method]
    if fn then return fn(object, ...) end
end

local function position(square)
    if not square then return nil end
    return {x = call(square, "getX"), y = call(square, "getY"), z = call(square, "getZ")}
end

local function squareKey(point)
    if not point or not point.x or not point.y or not point.z then return nil end
    return tostring(point.x) .. ":" .. tostring(point.y) .. ":" .. tostring(point.z)
end
local function squareId(square) return squareKey(position(square)) end

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

-- Looking up one compartment scans every loaded vehicle, so a pass over many
-- containers resolves all identities once. false marks an ambiguous key.
local function vehicleIdentities()
    local result = {}
    for _, vehicle in ipairs(liveVehicles() or {}) do
        local keyId, script = vehicleIdentity(vehicle)
        if keyId then
            local id = keyId .. ":" .. script
            if result[id] == nil then result[id] = vehicle else result[id] = false end
        end
    end
    return result
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

local function distanceFrom(player)
    local px, py, pz = call(player, "getX") or 0, call(player, "getY") or 0, call(player, "getZ") or 0
    return function(square)
        if not square then return math.huge end
        local dx, dy = px - (call(square, "getX") or 0), py - (call(square, "getY") or 0)
        local dz = pz - (call(square, "getZ") or 0)
        return dx * dx + dy * dy + dz * dz * 100
    end
end

local function distance(player, square) return distanceFrom(player)(square) end

local function byDistance(self, containers)
    local away = distanceFrom(self.player)
    return Sort(containers, function(container) return away(self:square(container)), self:key(container) or "" end)
end

local function itemTypes(container)
    local rules = ISInventoryWindowControlHandler_TransferSameType
    if not rules or type(rules.getItemsTable) ~= "function" then return nil end
    local ok, map = pcall(rules.getItemsTable, rules, container)
    if ok and type(map) == "table" then return map end
    Log.fault(nil, "World.itemTypes", map)
end

-- A can is remembered as its place and the room it had when last seen. Older saves kept a whole record.
local function savedBins(saved)
    local result, dropped = {}, 0
    for key, entry in pairs(type(saved) == "table" and saved or {}) do
        if type(entry) == "table" then key, entry = squareKey(entry), entry.capacity or SMALLEST_BIN end
        if Facts.binPoint(key) and type(entry) == "number" then result[key] = entry else dropped = dropped + 1 end
    end
    if dropped > 0 then Log.warn(nil, "TRASH-CANS", "unreadable", dropped) end
    return result
end

-- Identical objects on one tile are told apart by their order among themselves.
local function rankOf(objects, object, sprite)
    local rank = 0
    for index = 0, size(objects) - 1 do
        local other = at(objects, index)
        if other == object then return rank end
        if spriteName(other) == sprite then rank = rank + 1 end
    end
    return 0
end

local function objectsOf(square, corpse) return call(square, corpse and "getStaticMovingObjects" or "getObjects") end

-- Saved keys once held the object's index, which any dropped item shifts.
local function oldKey(key)
    local where, index, rest = tostring(key):match("^(%a+:%-?%d+:%-?%d+:%-?%d+:)(%d+)(:.*)$")
    return where, tonumber(index), rest
end

-- lower lists the indexes other saved keys give to objects that look the same.
local function currentKey(key, lower)
    local where, index, rest = oldKey(key)
    if not where then return key end
    local rank = 0
    for _, other in ipairs(lower or {}) do if other < index then rank = rank + 1 end end
    local kind, x, y, z = where:match("^(%a+):(.-):(.-):(.-):")
    local cell = getCell and getCell()
    local square = cell and cell:getGridSquare(tonumber(x), tonumber(y), tonumber(z))
    local objects, sprite = square and objectsOf(square, kind == "corpse"), rest:match("^:(.*):%d+:[^:]*$")
    local object = index < size(objects) and at(objects, index) or nil
    if object and spriteName(object) == sprite then rank = rankOf(objects, object, sprite) end
    return where .. "#" .. rank .. rest
end

local function upgradeKeys(labels)
    local alike, renamed, count = {}, {}, 0
    for key in pairs(labels) do
        local where, index, rest = oldKey(key)
        if where then
            alike[where .. rest] = alike[where .. rest] or {}
            table.insert(alike[where .. rest], index)
        end
    end
    for key in pairs(labels) do
        local where, _, rest = oldKey(key)
        if where then renamed[key], count = currentKey(key, alike[where .. rest]), count + 1 end
    end
    for old, key in pairs(renamed) do
        if labels[key] == nil then labels[key] = labels[old] end
        labels[old] = nil
    end
    return count
end

function World.new(player, state)
    state.containerLabels = state.containerLabels or {}
    state.itemLabels = state.itemLabels or {}
    state.storage = state.storage or {}
    state.keep = state.keep or {}
    state.keepTypes = state.keepTypes or {}
    state.trash = savedBins(state.trash)
    for _, field in ipairs({"containerLabels", "itemLabels"}) do
        for key, ids in pairs(state[field]) do
            if type(ids) == "table" and #ids == 0 then state[field][key] = nil end
        end
    end
    local upgraded = upgradeKeys(state.containerLabels)
    if upgraded > 0 then Log.info(nil, "KEYS-UPGRADED", "count", upgraded, "reason", "the object index is now the order among identical objects") end
    return setmetatable({player = player, state = state, endpoints = {}, anchors = {}, vehicles = {}, containerKeys = {}, moving = {},
        binRevision = 0, dirty = upgraded > 0 or nil}, World)
end

World.currentKey = currentKey

-- Runs fn with vehicle identities resolved at most once for every key it asks for.
function World:pass(fn)
    if self.passing then return fn() end
    self.passing = true
    local ok, a, b = pcall(fn)
    self.passing, self.identities = nil, nil
    if not ok then error(a, 0) end
    return a, b
end

-- A carried item by its identity, in whatever object now represents it, and its container.
function World:carried(id, fullType)
    return Items.eachCarried(self.player, function(item) return item:getID() == id and tostring(item:getFullType()) == fullType end)
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

local function directMember(container, item)
    local items=call(container,"getItems")
    local found=call(items,"contains",item)
    if type(found)=="boolean" then return found end
    local count=size(items)
    if count>4096 then return false end
    for i=0,count-1 do if at(items,i)==item then return true end end
    return false
end

-- Consumption authorizes one exact item, not a container search or a walk-to job.
function World:consumptionSource(item, source)
    local member=directMember
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

-- A server compares exact weights where hasRoomFor rounds, and refuses in
-- silence; the game lets us ask its own question first.
function World:serverAccepts(item, source, destination)
    if not isClient() or type(isItemTransactionConsistent) ~= "function" then return true end
    return isItemTransactionConsistent(item, source, destination, nil, self.player) == true
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

-- The bags in what the player carries and in these containers, once each.
function World:gearRecords(sources)
    local result, seen = {}, {}
    local function scan(container)
        if not container or seen[container] then return end
        seen[container] = true
        local items = call(container, "getItems")
        for index = 0, size(items) - 1 do
            local item = at(items, index)
            if isBag(item) then
                result[#result + 1] = {item = item, source = container}
                scan(call(item, "getInventory"))
            end
        end
    end
    local function add(container)
        if not container or seen[container] or not self:valid(container)
            or (self.recovery and self.recovery:isReservedContainer(container)) then return end
        if self:owns(container) or permitted(self.player, self:square(container)) then scan(container) end
    end
    add(call(self.player, "getInventory"))
    for _, container in ipairs(sources or {}) do add(container) end
    return result
end

-- The carried bags that count as storage, outermost first: worn, held and key
-- rings. The player's settings can add bags that are not worn and bags inside bags.
function World:bags(settings)
    local result, seen = {}, {}
    local function scan(container, root)
        if seen[container] then return end
        seen[container] = true
        local items = call(container, "getItems")
        for index = 0, size(items) - 1 do
            local item = at(items, index)
            local inside = isBag(item) and call(item, "getInventory")
            if inside then
                local ring = call(item, "isFakeEquipped", self.player) == true
                local worn = ring or call(self.player, "isEquipped", item) == true
                local wanted = worn or (call(item, "getAttachedSlot") or -1) < 0
                    and (root and settings.useUnequipped or not root and settings.nested)
                if wanted and self:owns(inside) and self:valid(inside) and call(inside, "isLockedToCharacter", self.player) ~= true
                    and not (self.recovery and self.recovery:isReservedContainer(inside)) then
                    local key = self:key(inside)
                    result[#result + 1] = {item = item, container = inside, source = container, worn = worn, ring = ring,
                        factor = self:carryFactor(inside), labels = key and self.state.containerLabels[key]}
                    scan(inside, false)
                end
            end
        end
    end
    scan(self.player:getInventory(), true)
    return result
end

-- Whether one of bags() is for this item. The game looks for a key only in main
-- inventory and on key rings, and a labelled bag is for what its label says
-- unless the item is only passing through.
function World:meantFor(bag, item, passing)
    if instance(item, "Key") and not bag.ring then return false end
    if passing or not bag.labels or not self.graph then return true end
    local descriptor, dedicated = self:describe(item), false
    for _, id in ipairs(bag.labels) do
        if self.graph:matches(id, descriptor) then return true end
        -- A place for one item keeps nothing else out.
        dedicated = dedicated or Labels.itemOf(id) == nil
    end
    return not dedicated
end

function World:replaceGear(oldId, oldType, item)
    local id = self:itemId(item)
    oldId = tostring(oldId)
    if not id or id == oldId then return end
    for _, field in ipairs({"keep", "itemLabels"}) do
        local values = self.state[field]
        if values[oldId] ~= nil then values[id], values[oldId] = values[oldId], nil; self.dirty = true end
    end
    if Labels.renameItem(self.state, oldId, id, tostring(call(item, "getFullType"))) then self.dirty = true end
    if Labels.move(self.state, "bag:" .. oldId, "bag:" .. id) then self.dirty = true end
    if self.recovery then self.recovery:replaceIdentity(oldId, oldType, item) end
end

function World:safeStagingContainers()
    self:discover()
    local result = {}
    for key, container in pairs(self.endpoints) do
        local anchor = self:sourceAnchor(container)
        if self:valid(container) and self:key(container) == key and anchor and anchor.kind == "world"
            and not self:isTrash(container) and permitted(self.player, self:square(container))
            and call(container, "isExplored") ~= false and call(container, "isLockedToCharacter", self.player) ~= true then
            result[#result + 1] = container
        end
    end
    return byDistance(self, result)
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
        local resolved, err
        if self.passing then
            self.identities = self.identities or vehicleIdentities()
            resolved, err = self.identities[keyId .. ":" .. script], "Vehicle key is ambiguous or no longer loaded"
        else resolved, err = uniqueVehicle(keyId, script, vehicle) end
        if resolved ~= vehicle then return nil, err end
        return "vehicle:" .. tostring(keyId) .. ":" .. script .. ":" .. tostring(call(part, "getId"))
    end
    if call(container, "getType") == "floor" then return nil, "Floor locations cannot carry container labels" end
    local parent = call(container, "getParent")
    local square = self:square(container)
    local point = squareId(square)
    if not parent or not point then return nil, "Container has no loaded world anchor" end
    local slot, corpse = call(parent, "getContainerIndex", container), instance(parent, "IsoDeadBody")
    local index = call(parent, corpse and "getStaticMovingObjectIndex" or "getObjectIndex")
    if slot == nil or index == nil or slot < 0 or index < 0 then return nil, "Container is no longer in the world" end
    local sprite = spriteName(parent)
    return (corpse and "corpse:" or "world:") .. point .. ":#" .. rankOf(objectsOf(square, corpse), parent, sprite) .. ":" .. sprite
        .. ":" .. tostring(slot) .. ":" .. tostring(call(container, "getType"))
end

function World:key(container)
    local key, failure = self:_rawKey(container)
    if not key then return nil, failure end
    local previous = self.containerKeys[container]
    if previous and previous ~= key and not self.moving[container] then
        self.moving[container] = true
        local holder = self.endpoints[key]
        if holder and holder ~= container then self:key(holder); holder = self.endpoints[key] end
        -- A container that moved up takes its labels along, in place of the removed twin's.
        if previous:sub(1, 8) ~= "vehicle:" and (not holder or holder == container or not self:valid(holder)) then
            if Labels.move(self.state, previous, key) then self.dirty = true end
            self.anchors[key] = self.anchors[previous]
        end
        if self.endpoints[previous] == container then self.endpoints[previous], self.anchors[previous] = nil, nil end
        self.moving[container] = nil
    end
    self.containerKeys[container] = key
    return key
end

function World:name(container)
    local given = self:givenName(container)
    if given then return given end
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
    return Storage.plainName(container)
end

function World:describe(item)
    local id = self:itemId(item)
    return {fullType = tostring(call(item, "getFullType") or ""), categoryId = Catalog.categoryId(item),
        labels = copy(id and self.state.itemLabels[id] or {})}
end

local function guarded(self, item, options)
    asking = "recovery"
    if self.recovery and self.recovery:isProtected(item) then return true, "Personal gear reserved for recovery" end
    local id = ask(item, "getID")
    if id and self.state.keep[tostring(id)] then return true, "Keep" end
    if ask(item, "isFavorite") and not (type(options) == "table" and options.allowFavorite == true) then return true, "Favorite" end
    local discard = type(options) == "table" and options.discard == true
    local receive = type(options) == "table" and options.allowMainInventoryFluidReceive == true
    local consume = type(options) == "table" and options.allowEquippedConsumption == true
    local food = consume and instance(item, "Food")
    local fluid = (receive or consume and not food) and ask(item, "getFluidContainer")
    local holder, inventory = ask(item, "getContainer"), ask(self.player, "getInventory")
    local main = holder ~= nil and holder == inventory
    local carried = main or (holder ~= nil and ask(holder, "getOutermostContainer") == inventory)
    -- Keeping every one of a kind holds on to what is carried, and never throws one away. Picking up and sorting the rest goes on.
    local passing = type(options) == "table" and options.passing == true
    local using = type(options) == "table" and options.using == true
    local keepTypes = not using and (discard or carried and not passing) and self.state.keepTypes or nil
    if keepTypes and keepTypes[tostring(ask(item, "getFullType"))] then return true, "Keep" end
    -- Filling in place does not move the worn item or the contents of a bag.
    local receivesInPlace = receive and fluid and main
    local equippedConsumption = consume and main and (food or fluid)
    if not receivesInPlace and not equippedConsumption then
        -- Items worn by a corpse report themselves as equipped; only the player's own count.
        local own = carried or holder == nil
        if ask(self.player, "isEquipped", item) or own and (ask(item, "isEquipped") or ask(item, "isWorn")) then return true, "Equipped" end
        if item == ask(self.player, "getPrimaryHandItem") or item == ask(self.player, "getSecondaryHandItem") then return true, "Held" end
        -- A key ring in main inventory counts as worn without being put on.
        if main and ask(item, "isFakeEquipped", self.player) then return true, "Equipped" end
        local attached = own and ask(item, "getAttachedSlot")
        if attached and attached >= 0 then return true, "Attached" end
    end
    if receivesInPlace or not (ask(item, "getCategory") == "Container" or instance(item, "InventoryContainer")) then return false end
    local pending, seen, cursor = {ask(item, "getInventory")}, {}, 1
    while pending[cursor] do
        local contents = not seen[pending[cursor]] and ask(pending[cursor], "getItems")
        seen[pending[cursor]] = true
        for index = 0, (contents and ask(contents, "size") or 0) - 1 do
            if carried and not (type(options) == "table" and options.hauled == true) then return true, "Bag contains items" end
            local child = ask(contents, "get", index)
            local childId = ask(child, "getID")
            if childId and (self.state.keep[tostring(childId)] or keepTypes and keepTypes[tostring(ask(child, "getFullType"))]) then
                return true, "Bag holds a Keep item"
            end
            if ask(child, "isFavorite") then return true, "Bag holds a Favorite item" end
            if self.recovery and self.recovery:isProtected(child) then return true, "Bag holds personal gear reserved for recovery" end
            pending[#pending + 1] = ask(child, "getInventory")
        end
        cursor = cursor + 1
    end
    return false
end

-- options.hauled: a world bag this job picked up whole may stay full while carried.
-- options.passing: the item came from the world and is only carried to where it goes.
-- options.discard: it would be thrown away. options.using: it would be eaten, drunk or poured, which keeping a kind allows.
local protectionFaults = {}
function World:protected(item, options)
    if not item then return true, "Item is missing" end
    local ok, protected, reason = pcall(guarded, self, item, options)
    if ok then return protected, reason end
    if not protectionFaults[asking] then
        protectionFaults[asking] = true
        Log.fault(nil, "World.protected:" .. tostring(asking), protected, "item", Log.item(item, self.player))
    end
    return true, "Protection could not be checked"
end

-- The contents of a bag that holds anything.
function World:filledBag(item)
    local inside = isBag(item) and call(item, "getInventory")
    if inside and size(call(inside, "getItems")) > 0 then return inside end
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
        if Labels.clear(self.state, key) then self.dirty = true end
    end
    self.anchors[key] = {parent = parent, square = square}
    self.endpoints[key] = container
    local part = call(container, "getVehiclePart")
    if part then
        local vehicle = call(part, "getVehicle")
        if vehicle then self:_observeVehicle(vehicle) end
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
    local cell = getCell()
    local function add(square)
        local key = squareId(square)
        if key and loaded(square) and not seen[key] and #squares < MAX_SQUARES then
            seen[key] = true
            squares[#squares + 1] = square
        end
    end
    if scope == "reach" then
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
    else return nil, "Unknown source scope" end
    return Sort(squares, distanceFrom(self.player))
end

function World:records(container, includeBags)
    local result, visited, seen, pending = {}, {}, {}, {container}
    local cursor = 1
    while cursor <= #pending do
        local source = pending[cursor]
        cursor = cursor + 1
        if source and not visited[source] then
            visited[source] = true
            local items, from = call(source, "getItems"), nil
            for index = 0, size(items) - 1 do
                local item = at(items, index)
                local id = self:itemId(item)
                if item and not seen[id or item] then
                    from = from or self:name(source)
                    seen[id or item] = true
                    result[#result + 1] = {item = item, source = source, descriptor = self:describe(item),
                        groundSquare = call(call(item, "getWorldItem"), "getSquare"),
                        itemName = tostring(call(item, "getName") or call(item, "getFullType") or "Item"), from = from}
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
    return self:pass(function() return self:_request(request or {}) end)
end

function World:_request(request)
    if request.scope == "building" or request.scope == "area" then
        local survey, err
        if request.scope == "area" then survey, err = Survey.ofArea(request.area, MAX_SQUARES)
        else
            local definition = call(call(call(self.player, "getCurrentSquare"), "getBuilding"), "getDef")
            if not definition then return nil, "Stand inside the building to survey all its rooms and floors" end
            survey, err = Survey.ofBuilding(definition)
        end
        if not survey then return nil, err end
        return self:_seen(request, survey)
    end
    local squares, failure = self:_scope(request)
    if not squares then return nil, failure end
    return self:_scan(request, squares)
end

-- What the player has already seen is planned now. The survey keeps the rest for the job to walk to.
function World:_seen(request, survey)
    local squares, left = {}, request.scope == "area" and MAX_SQUARES or PLAN_SQUARES
    local playerNum = call(self.player, "getPlayerNum")
    for _, section in ipairs(survey:nearest(self:point())) do
        if left <= 0 then break end
        local found, missing, denied = self:_section(section)
        left = left - #found - missing - denied
        local whole = missing == 0 and denied == 0
        for _, square in ipairs(found) do whole = whole and call(square, "isSeen", playerNum) == true end
        if whole then
            for _, square in ipairs(found) do squares[#squares + 1] = square end
            survey:report(section, true)
        end
    end
    local result = self:_scan(request, Sort(squares, distanceFrom(self.player)))
    if not survey.complete or survey.sectionsUnsearched > 0 then result.survey = survey end
    return result
end

function World:_scan(request, squares)
    local result = {items = {}, sources = {}, warnings = {}}
    local seen, itemSeen = {}, {}
    local labeled = request.scope == "labeled" or (request.sourceLabels ~= nil and #request.sourceLabels > 0)
    local floor = ISInventoryPage and ISInventoryPage.GetFloorContainer
        and ISInventoryPage.GetFloorContainer(call(self.player, "getPlayerNum")) or nil
    local function ground(square)
        local objects = call(square, "getWorldObjects")
        for index = 0, size(objects) - 1 do
            local item = call(at(objects, index), "getItem")
            local key = item and (self:itemId(item) or item)
            if key and not itemSeen[key] then
                itemSeen[key] = true
                result.items[#result.items + 1] = {item = item, source = floor, descriptor = self:describe(item), groundSquare = square,
                    itemName = tostring(call(item, "getName") or call(item, "getFullType") or "Item"), from = "Floor"}
            end
        end
    end
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
        for _, container in ipairs(byDistance(self, candidates)) do source(container) end
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
            if request.scope ~= "reach" then
                for _, container in ipairs(containers) do
                    -- A floor bag that is not opened for its contents is itself a floor item.
                    if request.includeBags == true or labeled or not call(container, "getContainingItem") then source(container) end
                end
            end
            if not labeled then ground(square) end
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
    local corpse, sprite = instance(parent, "IsoDeadBody"), spriteName(parent)
    return {kind = corpse and "corpse" or "world", point = position(square), sprite = sprite, parent = parent, square = square,
        index = call(parent, corpse and "getStaticMovingObjectIndex" or "getObjectIndex"),
        rank = rankOf(objectsOf(square, corpse), parent, sprite),
        slot = call(parent, "getContainerIndex", container), containerType = call(container, "getType")}
end

local function findObject(square, anchor)
    local objects, same = objectsOf(square, anchor.kind == "corpse"), {}
    for index = 0, size(objects) - 1 do
        local object = at(objects, index)
        if spriteName(object) == anchor.sprite then
            -- Saved receipts name the index.
            if not anchor.rank and index == anchor.index then return object end
            same[#same + 1] = object
        end
    end
    if anchor.rank then return same[anchor.rank + 1] end
    return #same == 1 and same[1] or nil
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
    local object = anchor.square == square and anchor.parent or findObject(square, anchor)
    local container = object and nativeInteger(anchor.slot) and call(object, "getContainerByIndex", anchor.slot)
    if container and spriteName(object) == anchor.sprite and call(container, "getType") == anchor.containerType
        and self:valid(container) then return container end
    return nil, "That storage was replaced or removed"
end

function World:sectionTarget(section)
    local best, score
    local cx, cy = (section.x1 + section.x2 - 1) / 2, (section.y1 + section.y2 - 1) / 2
    for y = section.y1, section.y2 - 1 do for x = section.x1, section.x2 - 1 do
        local square = getCell():getGridSquare(x, y, section.z)
        if square and (not section.room or call(call(square, "getRoom"), "getRoomDef") == section.room)
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
    Sort(candidates, function(value) return value.score, value.y, value.x end)
    local result = {}
    for index = 1, math.min(16, #candidates) do
        local value = candidates[index]
        result[index] = {x = value.x, y = value.y, z = value.z}
    end
    if #result == 0 then return nil, "No loaded walking frontier reaches the unsearched location" end
    return result, false
end

-- The tiles of a section that can be read, and how many cannot be seen yet or are not allowed.
function World:_section(section)
    local squares, missing, denied, cell = {}, 0, 0, getCell()
    local room = section.room
    local lost = room and call(room, "getBuilding") ~= section.building
    for y = section.y1, section.y2 - 1 do for x = section.x1, section.x2 - 1 do
        if lost then missing = missing + 1
        elseif not room or call(room, "contains", x, y) ~= false then
            local square = cell:getGridSquare(x, y, section.z)
            if room and call(call(square, "getRoom"), "getRoomDef") ~= room then square = nil end
            if square and permitted(self.player, square) then squares[#squares + 1] = square
            elseif square then denied = denied + 1
            -- Open air above a loaded tile is not a place.
            elseif room or not cell:getGridSquare(x, y, 0) then missing = missing + 1 end
        end
    end end
    return squares, missing, denied
end

function World:scanSection(section, request)
    local squares, missing, denied = self:_section(section)
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
    return self:pass(function() return self:_discover() end)
end

function World:_discover()
    local current = call(self.player, "getCurrentSquare") or call(self.player, "getSquare")
    if not current then return end
    local cell = getCell()
    local x, y, z = call(current, "getX"), call(current, "getY"), call(current, "getZ")
    for _, level in ipairs(self:discoveryLevels()) do
    for dy = -DISCOVERY_RADIUS, DISCOVERY_RADIUS do for dx = -DISCOVERY_RADIUS, DISCOVERY_RADIUS do
        local square = cell:getGridSquare(x + dx, y + dy, level)
        if square and call(square, "isSeen", call(self.player, "getPlayerNum")) == true then self:_containers(square, true) end
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
    self:findLabelled()
    for _, record in ipairs(self:records(call(self.player, "getInventory"), true)) do
        if isBag(record.item) then self:_observe(call(record.item, "getInventory")) end
    end
    self:prune()
end

-- The labelled fixtures in the loaded world, wherever they are.
function World:findLabelled()
    local labeledSquares, cell = {}, getCell()
    local keys = {}
    for _, field in ipairs({"containerLabels", "storage"}) do for key in pairs(self.state[field]) do keys[#keys + 1] = key end end
    for _, key in ipairs(keys) do
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
end

-- Forgets containers that are gone or unloaded. Kahlua has no weak tables to do it.
function World:prune()
    for key, container in pairs(self.endpoints) do
        if not self:valid(container) then
            self.endpoints[key] = nil
            if self.state.containerLabels[key] == nil then self.anchors[key] = nil end
        end
    end
    for container in pairs(self.containerKeys) do
        if not self:valid(container) then self.containerKeys[container] = nil end
    end
    self.prunedAt = getTimestampMs()
end

-- Trash cans ---------------------------------------------------------------

-- Remembers the can on a loaded tile, or forgets the one that is no longer there.
function World:noteBin(square, key)
    local bin = call(call(square, "getTrashReceptacle"), "getContainer")
    local before, now = self.state.trash[key], bin and call(bin, "getEffectiveCapacity", self.player) or nil
    if before ~= now then
        self.state.trash[key], self.dirty, self.binRevision = now, true, self.binRevision + 1
        Log.trace(nil, "TRASH-CAN", "at", key, "holds", now or "gone", "before", before or "unknown")
    end
    return bin
end

function World:lookForBins(radius, levels, seenOnly)
    local here, cell, playerNum = self:point(), getCell(), call(self.player, "getPlayerNum")
    if not here then return end
    for _, z in ipairs(levels) do for dy = -radius, radius do for dx = -radius, radius do
        local x, y = here.x + dx, here.y + dy
        local square = cell:getGridSquare(x, y, z)
        if square and (not seenOnly or call(square, "isSeen", playerNum) == true) and permitted(self.player, square) then
            self:noteBin(square, x .. ":" .. y .. ":" .. z)
        end
    end end end
end

-- The container of a can, or nil and why not; "unloaded" when it is out of sight.
function World:resolveBin(bin)
    local square = getCell():getGridSquare(bin.point.x, bin.point.y, bin.point.z)
    if not square then return nil, "unloaded" end
    if not permitted(self.player, square) then return nil, "This trash can is in a safehouse you may not use" end
    local container = self:noteBin(square, bin.key)
    if not container then return nil, "The trash can is gone" end
    bin.capacity = call(container, "getEffectiveCapacity", self.player)
    return container
end

-- The cans a request may use, nearest first, or nil and why there are none.
function World:bins(request, noLook)
    if not noLook then self:lookForBins(DISCOVERY_RADIUS, self:discoveryLevels()) end
    local area, near, result, nearest = request.scope == "area" and request.area, nil, {}, nil
    if area then near = {x = (area.x1 + area.x2) / 2, y = (area.y1 + area.y2) / 2}
    elseif request.sourceContainer then near = position(self:square(request.sourceContainer)) end
    for _, bin in ipairs(self:knownBins(near)) do
        local container, reason = self:resolveBin(bin)
        if container or reason == "unloaded" then
            nearest = nearest or bin.away
            if bin.away <= Facts.BIN_RANGE then result[#result + 1] = bin end
        end
    end
    if #result > 0 then return result end
    return nil, nearest and "The nearest known trash can is " .. Facts.awayText(nearest) .. ", too far to use"
        or "No trash can is known yet. Walk past one first"
end

-- The can this container is, or lies in.
function World:binKey(container)
    local seen = {}
    while container and not seen[container] do
        seen[container] = true
        if self:isTrash(container) then
            local square = self:square(container)
            local key = squareId(square)
            return self:noteBin(square, key) == container and key or nil
        end
        container = call(call(container, "getContainingItem"), "getContainer")
    end
end

function World:observeNearby()
    if getTimestampMs() - (self.prunedAt or 0) >= PRUNE_MS then self:prune() end
    return self:pass(function() return self:_observeNearby() end)
end

function World:_observeNearby()
    local changed = self.dirty == true
    self.dirty = false
    local current = call(self.player, "getCurrentSquare") or call(self.player, "getSquare")
    local tile = squareId(current)
    if not tile or tile == self.observedTile then return changed end
    self.observedTile = tile
    local cell = getCell()
    local x, y, z = call(current, "getX"), call(current, "getY"), call(current, "getZ")
    for dy = -1, 1 do for dx = -1, 1 do
        local square = cell:getGridSquare(x + dx, y + dy, z)
        if square and (square == current or call(current, "canReachTo", square))
            and call(square, "isSeen", call(self.player, "getPlayerNum")) == true and permitted(self.player, square) then
            self:_containers(square, true)
        end
    end end
    self:lookForBins(SIGHT, {z}, true)
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
    local away = distanceFrom(self.player)
    return Sort(result, function(vehicle) return away(call(vehicle, "getSquare")), tostring(call(vehicle, "getId")) end)
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
    local ok, err = pcall(pane.sortItemsByTypeAndWeight, pane, items)
    if not ok then Log.fault(nil, "World.matchingOrder", err); return nil, "The game's matching-transfer order could not be read" end
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
        local map = itemTypes(container)
        return map, not map and "The game's matching-transfer rules could not read this container" or nil
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

-- Everything carried, in the order the game's own matching buttons use.
function World:matchingSources()
    local scan, err = self:scan({scope = "inventory", includeBags = true})
    if not scan then return nil, err end
    return self:matchingOrder(scan.items)
end

function World:matchingRecords(mode, ordered)
    local err
    if not ordered then
        ordered, err = self:matchingSources()
        if not ordered then return nil, nil, err end
    end
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
                local map = itemTypes(source)
                if not map then return nil, "The game's matching-transfer rules could not read carried storage" end
                for fullType in pairs(map) do carried[fullType] = true end
            end
        end
        for _, source in ipairs(sources) do
            local map = itemTypes(source)
            if not map then return nil, "The game's matching-transfer rules could not read this container" end
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

function World:storageSettings()
    local preference = self.preference or function() end
    return {useUnequipped = preference("condenseUseUnequipped"), nested = preference("condenseNested")}
end

-- Everything destinations() needs that does not depend on the item. Build it
-- once for a plan or one delivery; it reads the world as it is at that moment.
function World:destinationPass(request, graph)
    local destination = request.destination or {}
    local pass = {graph = graph or self.graph, accepted = {}, types = {}, kinds = {}}
    if destination.kind == "inventory" then
        -- A load on its way elsewhere fills worn and held bags, whatever their labels:
        -- other bags carry no better, and may be part of the load.
        pass.load = destination.cargo ~= nil
        pass.bags = self:bags(pass.load and {} or self:storageSettings())
    elseif destination.kind == "matching" then
        pass.matching = {}
        for _, target in ipairs(destination.targets or {}) do
            local container = target.ref
            if target.anchor then container = self:resolveSource(target.anchor)
            elseif target.point and ISInventoryPage and ISInventoryPage.GetFloorContainer then
                local square = getCell():getGridSquare(target.point.x, target.point.y, target.point.z)
                container = (not square or permitted(self.player, square))
                    and ISInventoryPage.GetFloorContainer(call(self.player, "getPlayerNum")) or nil
            end
            if container and not self:owns(container) and self:canAccess(container) then
                pass.matching[#pass.matching + 1] = {container = container, types = target.types}
            end
        end
    elseif destination.kind == "vehicle" then
        local vehicle, err = destination.ref
        if not vehicle then vehicle, err = self:vehicle() end
        if not vehicle or call(vehicle, "isRemovedFromWorld") == true then return nil, err or "Remember or select a loaded vehicle first" end
        pass.parts = {}
        for index = 0, (call(vehicle, "getPartCount") or 0) - 1 do
            local part = call(vehicle, "getPartByIndex", index)
            local container = call(part, "getItemContainer")
            if container and call(container, "isOccupiedVehicleSeat") ~= true then
                local id = tostring(call(part, "getId") or "")
                pass.parts[#pass.parts + 1] = {container = container, index = index,
                    priority = call(part, "isVehicleTrunk") and 0 or (string.sub(id, 1, 4) == "Seat" and 1 or 2)}
            end
        end
        Sort(pass.parts, function(part) return part.priority, part.index end)
    elseif destination.kind == "labels" then
        self:pass(function()
            self:_discover()
            pass.storages = {}
            for _, storage in ipairs(self:storages()) do
                if storage.container and #storage.labels > 0 and (not destination.near or storage.carried and not destination.near.fixed or self:atHand(storage, destination.near)) then pass.storages[#pass.storages + 1] = storage end
            end
        end)
    end
    return pass
end

-- Whether a request is about what the player already carried.
function World:fromPlayer(request)
    return request.scope == "inventory" or request.scope == "container" and request.sourceContainer ~= nil and self:owns(request.sourceContainer)
end

-- In storage with a requested label, or in a bag or kit that is, and none with room is meant for it more closely.
function World:alreadySorted(request, item, graph, pass)
    if request.destination.kind ~= "labels" then return false end
    local placed = self:placement(item, request.destination, graph)
    if not placed or placed == 0 then return placed == 0 end
    for _, container in ipairs(self:destinations(request, item, pass or self:glance()) or {}) do
        if call(container, "hasRoomFor", self.player, item) ~= false then return false end
    end
    return true
end

-- What the game's matching transfer counts each item in a container as.
function World:kinds(container)
    local byItem = {}
    for fullType, items in pairs(itemTypes(container) or {}) do
        for _, item in ipairs(items) do
            byItem[item] = byItem[item] or {}
            table.insert(byItem[item], fullType)
        end
    end
    return function(item) return byItem[item] and Sort(byItem[item]) or {tostring(call(item, "getFullType"))} end
end

function World:similarTypes(pass, item)
    local source = call(item, "getContainer")
    if not source then return {tostring(call(item, "getFullType"))} end
    if not pass.kinds[source] then pass.kinds[source] = self:kinds(source) end
    return pass.kinds[source](item)
end

function World:holdsSimilar(pass, container, types)
    local map = pass.types[container]
    if not map then
        map = itemTypes(container)
        if not map then
            map = {}
            for _, record in ipairs(self:records(container, false)) do map[record.descriptor.fullType] = true end
        end
        pass.types[container] = map
    end
    for _, fullType in ipairs(types) do if map[fullType] then return true end end
    return false
end

function World:destinations(request, item, pass)
    local destination = request.destination or {}
    local err
    if not pass then
        pass, err = self:destinationPass(request)
        if not pass then return nil, err end
    end
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
        local factors = {}
        for _, bag in ipairs(pass.bags) do
            factors[bag.container] = bag.factor
            if not item or self:meantFor(bag, item, pass.load) then add(bag.container) end
        end
        local types = item and not pass.load and self:similarTypes(pass, item)
        Sort(result, function(container)
            return types and self:holdsSimilar(pass, container, types) and 0 or 1, factors[container]
        end)
        add(call(self.player, "getInventory"))
    elseif destination.kind == "floor" then
        if ISInventoryPage and ISInventoryPage.GetFloorContainer then add(ISInventoryPage.GetFloorContainer(call(self.player, "getPlayerNum"))) end
    elseif destination.kind == "container" then
        if not self:valid(destination.ref) then return nil, "Destination container is no longer available" end
        add(destination.ref)
    elseif destination.kind == "matching" then
        for _, target in ipairs(pass.matching) do
            if item and target.types[tostring(call(item, "getFullType"))] then add(target.container) end
        end
    elseif destination.kind == "vehicle" then
        for _, part in ipairs(pass.parts) do add(part.container) end
    elseif destination.kind == "labels" then
        for _, entry in ipairs(item and self:placesFor(item, pass, destination, self:fromPlayer(request)) or {}) do add(entry.storage.container) end
    else return nil, "Choose a destination" end
    return result
end

return World
