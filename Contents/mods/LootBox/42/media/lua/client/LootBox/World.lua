local Catalog = require "LootBox/Catalog"

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
    return setmetatable({player = player, state = state, endpoints = {}, anchors = {}, vehicles = {}, containerKeys = {}}, World)
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

function World:protected(item)
    if not item then return true, "Item is missing" end
    local id = self:itemId(item)
    if id and self.state.keep[id] then return true, "Keep" end
    if call(item, "isFavorite") then return true, "Favorite" end
    if call(self.player, "isEquipped", item) or call(item, "isEquipped") or call(item, "isWorn") then return true, "Equipped" end
    if item == call(self.player, "getPrimaryHandItem") or item == call(self.player, "getSecondaryHandItem") then return true, "Held" end
    local attached = call(item, "getAttachedSlot")
    if attached and attached >= 0 then return true, "Attached" end
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
            kind = tostring(call(container, "getType"))}
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
    if scope == "inventory" or scope == "container" or scope == "labeled" then return {} end
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
    elseif scope == "building" then
        local building = call(current, "getBuilding")
        local definition = call(building, "getDef")
        if not definition then return nil, "You are not inside a building" end
        local list = call(definition, "getSquares")
        for index = 0, size(list) - 1 do
            local square = at(list, index)
            if call(square, "getBuilding") == building then
                if #squares >= MAX_SQUARES then return nil, "Building exceeds the loaded-scope limit" end
                add(square)
            end
        end
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
    local squares, failure = self:_scope(request)
    if not squares then return nil, failure end
    local result = {items = {}, sources = {}, groundSquares = {}, warnings = {}}
    local seen, itemSeen = {}, {}
    local function source(container)
        if not container or seen[container] or not self:valid(container) or not self:sourceMatches(container, request) then return end
        if not self:owns(container) and not permitted(self.player, self:square(container)) then
            result.warnings[#result.warnings + 1] = "Safehouse permissions do not allow this source: " .. self:name(container)
            return
        end
        seen[container] = true
        result.sources[#result.sources + 1] = container
        if call(container, "isExplored") == false and not self:owns(container) then
            result.warnings[#result.warnings + 1] = self:name(container) .. " needs native exploration after approach"
            return
        end
        for _, record in ipairs(self:records(container, request.includeBags == true)) do
            local key = self:itemId(record.item) or record.item
            if not itemSeen[key] then itemSeen[key] = true; result.items[#result.items + 1] = record end
        end
    end
    if request.scope == "inventory" or request.scope == nil or request.includeInventory then source(call(self.player, "getInventory")) end
    if request.scope == "container" then
        if not request.sourceContainer then return nil, "Choose a source container" end
        if not self:valid(request.sourceContainer) then return nil, "Source container is no longer available" end
        source(request.sourceContainer)
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

function World:discover()
    local current = call(self.player, "getCurrentSquare") or call(self.player, "getSquare")
    if not current then return end
    local cell = getCell()
    local x, y, z = call(current, "getX"), call(current, "getY"), call(current, "getZ")
    for dy = -DISCOVERY_RADIUS, DISCOVERY_RADIUS do for dx = -DISCOVERY_RADIUS, DISCOVERY_RADIUS do
        local square = cell:getGridSquare(x + dx, y + dy, z)
        if square and call(square, "isSeen", call(self.player, "getPlayerNum")) == true then self:_containers(square, true) end
    end end
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
        or type(memory.sprite) ~= "string" or type(memory.kind) ~= "string" then return nil, "invalid" end
    local previous = self.endpoints[key]
    if previous and self:valid(previous) and self:isTrash(previous) then return previous end
    local square = getCell():getGridSquare(memory.x, memory.y, memory.z)
    if not square then return nil, "unloaded" end
    local object = at(call(square, "getObjects"), memory.index)
    if object and spriteName(object) == memory.sprite then
        local container = call(object, "getContainerByIndex", memory.slot)
        if container and tostring(call(container, "getType")) == memory.kind and self:isTrash(container) then return container end
    end
    return nil, "missing"
end

function World:trashCandidates()
    self:discover()
    local result, warnings, seen = {}, {}, {}
    for key, memory in pairs(self.state.trash) do
        local container, reason = self:_resolveTrash(memory, key)
        if container and self:valid(container) then
            if not seen[container] then result[#result + 1] = container; seen[container] = true end
            self.endpoints[key] = container
        elseif reason == "unloaded" then warnings[#warnings + 1] = "Remembered trash can at " .. memory.x .. ", " .. memory.y .. " is not loaded"
        elseif reason == "invalid" then warnings[#warnings + 1] = "A remembered trash can has invalid saved identity data"
        else self.state.trash[key] = nil; self.endpoints[key] = nil; self.dirty = true end
    end
    table.sort(result, function(a, b)
        local da, db = distance(self.player, self:square(a)), distance(self.player, self:square(b))
        if da == db then return (self:key(a) or "") < (self:key(b) or "") end
        return da < db
    end)
    return result, warnings
end

function World:destinations(request, item)
    local destination = request.destination or {}
    local result, seen = {}, {}
    local function add(container)
        if not container or seen[container] or not self:valid(container) then return end
        if item and ((container == call(item, "getContainer") and call(container, "getType") ~= "floor")
            or call(container, "isInside", item)) then return end
        seen[container] = true
        result[#result + 1] = container
    end
    if destination.kind == "inventory" then
        local inventory = call(self.player, "getInventory")
        add(inventory)
        if request.includeBags then
            for _, record in ipairs(self:records(inventory, true)) do
                if isBag(record.item) then add(call(record.item, "getInventory")) end
            end
        end
    elseif destination.kind == "floor" then
        if ISInventoryPage and ISInventoryPage.GetFloorContainer then add(ISInventoryPage.GetFloorContainer(call(self.player, "getPlayerNum"))) end
    elseif destination.kind == "container" then
        if not self:valid(destination.ref) then return nil, "Destination container is no longer available" end
        add(destination.ref)
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
