package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local modules = {
    "TimedActions/ISTimedActionQueue", "TimedActions/ISInventoryTransferUtil",
    "Vehicles/TimedActions/ISPathFindAction", "Vehicles/TimedActions/ISEnterVehicle",
    "Vehicles/TimedActions/ISExitVehicle", "Vehicles/TimedActions/ISSwitchVehicleSeat",
    "Vehicles/TimedActions/ISUnlockVehicleDoor", "Vehicles/TimedActions/ISLockVehicleDoor", "Vehicles/TimedActions/ISOpenVehicleDoor",
    "Vehicles/TimedActions/ISCloseVehicleDoor", "Vehicles/TimedActions/ISLockDoors",
    "TimedActions/ISWearClothing", "TimedActions/ISClothingExtraAction",
    "TimedActions/ISEquipWeaponAction", "TimedActions/ISUnequipAction",
}
for _, name in ipairs(modules) do package.preload[name] = function() return true end end

local clock, client, allowTrash, requests, transfers, corpseQueries, queues, rehydrate, loadedSquares, nearestRequests, nearestChoice, floorDropSquare
local besideRequests, transactions
local passed, failures = 0, {}

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function includes(text, fragment)
    assert(type(text) == "string" and text:find(fragment, 1, true), "Missing failure detail " .. fragment .. " in " .. tostring(text))
end

local function list(items)
    return {
        size = function() return #items end,
        get = function(_, index) return items[index + 1] end,
        isEmpty = function() return #items == 0 end,
    }
end

local function square(x, y, z)
    local value = { x = x, y = y, z = z or 0, reachable = true, dropAllowed = true, worldObjects = {} }
    function value:getX() return self.x end
    function value:getY() return self.y end
    function value:getZ() return self.z end
    function value:canReachTo(other) return self.reachable and other.reachable end
    function value:isFree() return self.blocked ~= true end
    function value:getWorldObjects() return list(self.worldObjects) end
    if loadedSquares then loadedSquares[x .. ":" .. y .. ":" .. value.z] = value end
    return value
end

local function container(kind, location)
    local value = { kind = kind or "crate", items = {}, room = true, location = location }
    function value:getType() return self.kind end
    function value:getParent() return self.parent end
    function value:getSourceGrid() return self.location end
    function value:getVehiclePart() return self.part end
    function value:getContainingItem() return self.bag end
    function value:getOutermostContainer()
        local root = self
        while root.bag and root.bag:getContainer() do root = root.bag:getContainer() end
        return root
    end
    function value:isInCharacterInventory(player) return self:getOutermostContainer() == player.inventory end
    function value:isLockedToCharacter() return self.locked == true end
    function value:hasRoomFor() return self.room end
    function value:isRemoveItemAllowed() return not self.refuseRemoval end
    function value:isItemAllowed() return not self.refuseItems end
    function value:isInside() return false end
    function value:isOccupiedVehicleSeat() return self.occupied == true end
    function value:contains(item)
        for _, current in ipairs(self.items) do if current == item then return true end end
        return false
    end
    function value:getItemWithID(id)
        for _, current in ipairs(self.items) do if current:getID() == id then return current end end
    end
    function value:containsID(id) return self:getItemWithID(id) ~= nil end
    function value:getItems() return list(self.items) end
    function value:isEmpty() return #self.items == 0 end
    return value
end

local function put(item, destination)
    if item.container then
        for index, current in ipairs(item.container.items) do
            if current == item then table.remove(item.container.items, index); break end
        end
    end
    item.container = destination
    if destination then destination.items[#destination.items + 1] = item end
end

local function item(id, destination)
    local value = { id = id }
    function value:getID() return self.id end
    function value:getFullType() return self.fullType or "Base.Nails" end
    function value:getContainer() return self.container end
    function value:getWorldItem() return self.world end
    function value:isHumanCorpse() return self.corpse == true end
    function value:hasTag() return self.heavy == true end
    if destination then put(value, destination) end
    return value
end

local function player()
    local value = { location = square(0, 0), inventory = container("inventory") }
    function value:isDead() return self.dead == true end
    function value:isLocalPlayer() return true end
    function value:isShoving() return self.shoving == true end
    function value:isClimbing() return false end
    function value:isKnockedDown() return false end
    function value:hasTimedActions() return queues[self] ~= nil and #queues[self].queue > 0 end
    function value:isAsleep() return self.asleep == true end
    function value:pressedMovement() return self.movementInput == true end
    function value:isPlayerMoving() return self.moving == true end
    function value:pressedAim() return self.aimInput == true end
    function value:isAiming() return self.aiming == true end
    function value:isAttacking() return self.attacking == true end
    function value:isPerformingShoveAnimation() return self.shoving == true end
    function value:isRunning() return self.running == true end
    function value:isSprinting() return self.sprinting == true end
    function value:pressedCancelAction() return self.cancelInput == true end
    function value:getInventory() return self.inventory end
    function value:getCurrentSquare() return self.location end
    function value:getX() return self.location.x + 0.5 end
    function value:getY() return self.location.y + 0.5 end
    function value:getZ() return self.location.z end
    function value:getCharacterActions() return list(self.characterActions or (queues[self] and queues[self].queue or {})) end
    function value:getVehicle() return self.vehicle end
    function value:getPrimaryHandItem() return self.primary end
    function value:getSecondaryHandItem() return self.secondary end
    return value
end

local prototypes = {}

local function gearPlayer()
    local actor = player()
    actor.worn = {}
    local group = {slots = {"base:Back", "custom:LowerBack"}, exclusive = {}, multi = {}}
    function group:size() return #self.slots end
    function group:getLocationByIndex(index) return {getId = function() return self.slots[index + 1] end} end
    function group:isExclusive(left, right) return self.exclusive[left .. ":" .. right] == true end
    function group:isMultiItem(slot) return self.multi[slot] == true end
    function actor:getWornItems()
        local worn = list(self.worn)
        function worn:getBodyLocationGroup() return group end
        function worn:contains(wanted)
            for _, entry in ipairs(actor.worn) do if entry.item == wanted then return true end end
            return false
        end
        return worn
    end
    function actor:getWornItem(slot)
        for _, entry in ipairs(self.worn) do if entry.slot == slot then return entry.item end end
    end
    function actor:isEquipped(wanted)
        return self.primary == wanted or self.secondary == wanted or self:getWornItems():contains(wanted)
    end
    function actor:getClothingItem_Back() return self:getWornItem("base:Back") end
    actor.group = group
    return actor
end

local function wear(actor, selected, slot)
    for index = #actor.worn, 1, -1 do
        if actor.worn[index].item == selected then table.remove(actor.worn, index) end
    end
    if actor.primary == selected then actor.primary = nil end
    if actor.secondary == selected then actor.secondary = nil end
    if not slot then return end
    local entry = {item = selected, slot = slot}
    function entry:getItem() return self.item end
    function entry:getLocation() return self.slot end
    actor.worn[#actor.worn + 1] = entry
end

local function gearBag(id, destination, slot, capacity, fullType)
    local selected = item(id, destination)
    selected.fullType, selected.slot, selected.capacity = fullType or "Base.Bag_Test", slot, capacity or 20
    selected.inventory, selected.extras = container("bag"), {}
    selected.inventory.bag = selected
    function selected:IsInventoryContainer() return true end
    function selected:getInventory() return self.inventory end
    function selected:canBeEquipped() return self.slot end
    function selected:getBodyLocation() return self.slot end
    function selected:getClothingItemExtra() return list(self.extras) end
    function selected:getModule() return "Base" end
    function selected:getWeightReduction() return 80 end
    function selected:getContentsWeight()
        local total = 0
        for _, child in ipairs(self.inventory.items) do total = total + (child.mass or 1) end
        return total
    end
    function selected:isForceDropHeavyItem() return false end
    function selected.inventory:getEffectiveCapacity() return selected.capacity end
    return selected
end

local function action(character, kind, effect)
    local value = { character = character, kind = kind, starts = 0, cancellations = 0 }
    function value:begin()
        self.starts = self.starts + 1
        self.action = { forceStop = function() self:stop() end }
    end
    function value:forceStop() self.action:forceStop() end
    function value:forceCancel() self.cancellations = self.cancellations + 1 end
    function value:setOnComplete(callback) self.onComplete = callback end
    function value:setOnFail(callback) self.onFail = callback end
    function value:stop()
        self.stops = (self.stops or 0) + 1
        ISTimedActionQueue.getTimedActionQueue(character):resetQueue()
    end
    function value:complete()
        if effect then effect() end
        ISTimedActionQueue.getTimedActionQueue(character):onCompleted(self)
        if self.onComplete then self.onComplete() end
    end
    function value:reject()
        if self.onFail then self.onFail() end
        self:forceStop()
    end
    return value
end

ISTimedActionQueue = {}
function ISTimedActionQueue.getTimedActionQueue(character)
    if queues[character] then return queues[character] end
    local value = { queue = {} }
    function value:indexOf(wanted)
        for index, current in ipairs(self.queue) do if current == wanted then return index end end
        return -1
    end
    function value:removeFromQueue(wanted)
        local index = self:indexOf(wanted)
        if index >= 0 then table.remove(self.queue, index) end
    end
    function value:addToQueue(nextAction)
        self.queue[#self.queue + 1] = nextAction
        if #self.queue == 1 then self.current = nextAction; nextAction:begin() end
    end
    function value:resetQueue()
        for _, pending in ipairs(self.queue) do if pending ~= self.current then pending:forceCancel() end end
        self.queue, self.current = {}, nil
    end
    function value:onCompleted(completed)
        self:removeFromQueue(completed)
        self.current = self.queue[1]
        if self.current then self.current:begin() end
    end
    queues[character] = value
    return value
end
function ISTimedActionQueue.add(nextAction)
    local queue = ISTimedActionQueue.getTimedActionQueue(nextAction.character)
    queue:addToQueue(nextAction)
    return queue
end

ISInventoryTransferUtil = {}
function ISInventoryTransferUtil.isCharacterGrabbingCorpseItem(character, selected, source, destination)
    corpseQueries = corpseQueries + 1
    return selected.corpse == true and destination == character:getInventory()
end
function ISInventoryTransferUtil.newInventoryTransferAction(character, selected, source, destination)
    transfers = transfers + 1
    if selected.corpse then character.equipmentChanged = true end
    local transfer = action(character, "transfer", function()
        if selected.world then
            local objects = selected.world:getSquare().worldObjects
            for index, object in ipairs(objects) do
                if object:getItem() == selected then table.remove(objects, index); break end
            end
            selected.world = nil
        end
        local current = selected
        if rehydrate then
            current = item(selected:getID())
            current.fullType = selected:getFullType()
            put(selected, nil)
        end
        put(current, destination)
        if destination:getType() == "floor" then
            local square = floorDropSquare or character:getCurrentSquare()
            local object = { getSquare = function() return square end, getItem = function() return current end }
            current.world = object
            square.worldObjects[#square.worldObjects + 1] = object
        end
    end)
    function transfer:canDropOnFloor(target) return target and target.dropAllowed == true end
    return transfer
end

ISPathFindAction = {}
function ISPathFindAction:pathToLocationF(character, x, y, z)
    return action(character, "path", function() character.location = square(math.floor(x), math.floor(y), z) end)
end
function ISPathFindAction:pathToNearest(character, locations)
    local copy = {}
    for index, value in ipairs(locations) do copy[index] = value end
    nearestRequests[#nearestRequests + 1] = copy
    return action(character, "path", function()
        local first = (nearestChoice - 1) * 3 + 1
        character.location = square(math.floor(locations[first]), math.floor(locations[first + 1]), locations[first + 2])
    end)
end
-- The game stands the player beside the tile, never on it.
function ISPathFindAction:pathAdjacentToSquares(character, squares, diagonal)
    assert(diagonal == true and #squares == 1)
    local target = squares[1]
    besideRequests[#besideRequests + 1] = target
    if target.walled then return nil end
    local near = target.beside or {x = target.x - 1, y = target.y, z = target.z}
    return action(character, "path", function() character.location = square(near.x, near.y, near.z) end)
end
function ISPathFindAction:pathToVehicleArea(character, vehicle)
    return self:pathToLocationF(character, vehicle.location.x + 0.5, vehicle.location.y + 0.5, vehicle.location.z)
end
function ISPathFindAction:pathToVehicleSeat(character, vehicle) return self:pathToVehicleArea(character, vehicle) end

ISEnterVehicle = { new = function(_, character, vehicle, seat)
    return action(character, "enter", function()
        character.vehicle, character.seat = vehicle, seat
        vehicle.occupants[seat] = character
    end)
end }
ISExitVehicle = { new = function(_, character)
    return action(character, "exit", function()
        character.vehicle.occupants[character.seat] = nil
        character.vehicle, character.seat = nil, nil
    end)
end }
ISSwitchVehicleSeat = { new = function(_, character, seat)
    return action(character, "switch", function()
        character.vehicle.occupants[character.seat] = nil
        character.seat = seat
        character.vehicle.occupants[seat] = character
    end)
end }
ISUnlockVehicleDoor = { new = function(_, character, part)
    return action(character, "unlock", function() part.door.locked = false end)
end }
ISLockVehicleDoor = { new = function(_, character, part)
    return action(character, "lock", function() part.door.locked = true end)
end }
ISOpenVehicleDoor = { new = function(_, character, vehicle, part)
    return action(character, "open", function() part.door.open = true end)
end }
ISCloseVehicleDoor = { new = function(_, character, vehicle, part)
    return action(character, "close", function() part.door.open = false end)
end }
ISLockDoors = { new = function(_, character, vehicle, locked)
    return action(character, "unlockDoors", function() vehicle.driver.door.locked = locked end)
end }

ISWearClothing = {new = function(_, actor, selected)
    return action(actor, "wear", function() wear(actor, selected, selected:canBeEquipped()) end)
end}
ISUnequipAction = {new = function(_, actor, selected)
    return action(actor, "unequip", function() wear(actor, selected, nil) end)
end}
ISEquipWeaponAction = {new = function(_, actor, selected, _, primary, twoHands)
    return action(actor, "equip", function()
        wear(actor, selected, nil)
        if primary or twoHands then actor.primary = selected end
        if not primary or twoHands then actor.secondary = selected end
    end)
end}
ISClothingExtraAction = {new = function(_, actor, selected, fullType)
    return action(actor, "clothingExtra", function()
        local prototype = prototypes[fullType]
        local replacement = gearBag(selected:getID() + 10000, nil, prototype.slot, prototype.capacity, fullType)
        local children = {}
        for _, child in ipairs(selected.inventory.items) do children[#children + 1] = child end
        for _, child in ipairs(children) do if not selected.loseContents then put(child, replacement.inventory) end end
        put(selected, nil)
        put(replacement, actor.inventory)
        wear(actor, selected, nil)
        wear(actor, replacement, replacement.slot)
    end)
end}
ISInventoryPaneContextMenu = {getItemInstance = function(fullType) return prototypes[fullType] end}

getTimestampMs = function() return clock end
getCell = function()
    return {getGridSquare = function(_, x, y, z) return loadedSquares[x .. ":" .. y .. ":" .. z] end}
end
isClient = function() return client end
-- Like the game, an unknown transaction counts as rejected.
isItemTransactionRejected = function(id) return transactions[id] == nil or transactions[id] == "rejected" end
getServerOptions = function() return { getBoolean = function() return allowTrash end } end
instanceof = function(object, class) return object.class == class end
sendClientCommand = function(character, module, command, args)
    requests[#requests + 1] = { character = character, module = module, command = command, args = args }
end
ItemTag = { HEAVY_ITEM = "HeavyItem" }

local Native = require "LootBox/Native"

local function trash(location)
    local destination = container("bin", location)
    local object = { class = "IsoObject", index = 7 }
    function object:getSquare() return location end
    function object:getX() return location.x end
    function object:getY() return location.y end
    function object:getZ() return location.z end
    function object:getObjectIndex() return self.index end
    function object:getContainer() return destination end
    function object:getSprite() return { getProperties = function() return { has = function(_, name) return name == "IsTrashCan" end } end } end
    destination.parent = object
    return destination
end

local function vehicle()
    local value = { location = square(3, 0), occupants = {} }
    local function part(id, locked)
        local result = { id = id, door = { locked = locked, open = false } }
        function result:getId() return self.id end
        function result:getInventoryItem() return true end
        function result:getDoor() return self.door end
        function result.door:isLocked() return self.locked end
        function result.door:isOpen() return self.open end
        function result.door:isLockBroken() return self.lockBroken == true end
        function result:getArea() return self.id end
        return result
    end
    value.driver, value.trunk = part("DoorFrontLeft", false), part("TrunkDoor", true)
    function value:getSquare() return self.location end
    function value:isStopped() return not self.moving end
    function value:getPartCount() return 1 end
    function value:getPartByIndex() return { getItemContainer = function() return true end } end
    function value:getPassengerDoor() return self.driver end
    function value:getPartById(id) return id == "TrunkDoor" and self.trunk or id == "DoorFrontLeft" and self.driver or nil end
    function value:isInArea() return self.away ~= true end
    function value:canLockDoor(part, character)
        return not part.door.locked and (character.vehicle == self or self.noKey ~= true or part == self.driver)
    end
    function value:getMaxPassengers() return 1 end
    function value:isAnyDoorLocked() return self.driver.door.locked end
    function value:isTrunkLocked() return self.trunk.door.locked end
    function value:getSeat(character) return character.vehicle == self and character.seat or -1 end
    function value:isSeatOccupied(seat) return self.occupants[seat] ~= nil end
    function value:isSeatInstalled() return true end
    function value:getPassengerPosition() return true end
    function value:isEnterBlocked() return false end
    function value:isExitBlocked() return self.blockExit == true end
    function value:canSwitchSeat() return true end
    function value:canUnlockDoor() return true end
    function value:updateHasExtendOffsetForExit() end
    return value
end

local function case(name, run)
    clock, client, allowTrash, requests, transfers, corpseQueries, queues, rehydrate = 0, false, true, {}, 0, 0, {}, false
    loadedSquares, nearestRequests, nearestChoice, floorDropSquare = {}, {}, 1, nil
    prototypes, besideRequests, transactions = {}, {}, {}
    local ok, err = pcall(run)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failures[#failures + 1] = name .. ": " .. tostring(err); print("FAIL " .. failures[#failures]) end
end

-- Time passes in frames; a single long gap does not count against a deadline.
local function advance(adapter, milliseconds)
    local finish = clock + milliseconds
    while clock < finish do
        clock = math.min(finish, clock + 100)
        local done, reason, code = adapter:poll()
        if done ~= nil then return done, reason, code end
    end
end

local function assertRejected(adapter, op, detail)
    local accepted, reason = adapter:begin(op)
    equal(accepted, nil)
    includes(reason, detail)
    equal(adapter:isBusy(), false)
end

case("An item already at its destination completes without another transfer", function()
    local actor, source, destination = player(), container("crate", square(0, 0)), container("crate", square(0, 0))
    local selected = item(1, destination)
    local adapter = Native.new(actor)
    equal(adapter:begin({ kind = "transfer", item = selected, source = source, destination = destination }), true)
    equal(adapter:poll(), true)
    equal(adapter:isBusy(), false)
    equal(transfers, 0)
end)

case("A queued transfer reports pending until the native result is visible", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(2, actor.inventory)
    local adapter = Native.new(actor)
    equal(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }), true)
    equal(adapter:poll(), nil)
    equal(selected:getContainer(), actor.inventory)
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(selected:getContainer(), destination)
    equal(transfers, 1)
end)

case("Native rejection is a failure and leaves the item in its source", function()
    client = true
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(3, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    queues[actor].current.transactionId, transactions[7] = 7, "rejected"
    queues[actor].current:reject()
    local done, reason, code = adapter:poll()
    equal(done, false, "Nothing is on its way after a rejection")
    includes(reason, "stopped")
    equal(code, "refused")
    equal(selected:getContainer(), actor.inventory)
    equal(adapter:isBusy(), false)
end)

case("A stopped transfer the server had accepted is given two seconds to show up", function()
    client = true
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(3, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    queues[actor].current.transactionId, transactions[8] = 8, "accepted"
    queues[actor].current:reject()
    equal(advance(adapter, 1900), nil)
    put(selected, destination)
    equal(adapter:poll(), true)
end)

case("A multiplayer transfer resolves the recreated destination item by immutable identity", function()
    client, rehydrate = true, true
    local actor, destination = player(), container("crate", square(0, 0))
    local original = item(201, actor.inventory)
    local operation = { kind = "transfer", item = original, source = actor.inventory, destination = destination }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    assert(operation.resultItem ~= original)
    equal(operation.resultItem:getID(), original:getID())
    equal(operation.resultItem:getFullType(), original:getFullType())
    equal(operation.resultItem:getContainer(), destination)
    equal(actor.inventory:containsID(original:getID()), false)
    equal(destination:contains(original), false)
end)

case("A delayed source refresh binds only the same ID and type in the original container", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local original = item(202, actor.inventory)
    put(original, nil)
    local refreshed = item(202, actor.inventory)
    local operation = { kind = "transfer", item = original, source = actor.inventory, destination = destination }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(operation.resultItem, refreshed)
    equal(original:getContainer(), nil)
end)

case("A duplicate destination ID cannot complete while the source still owns the identity", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local original = item(203, actor.inventory)
    item(203, destination)
    local operation = { kind = "transfer", item = original, source = actor.inventory, destination = destination }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor]:onCompleted(queues[actor].current)
    equal(adapter:poll(), false)
    equal(operation.resultItem, nil)
    equal(original:getContainer(), actor.inventory)
end)

case("A different item type reusing a destination ID is not a completed transfer", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local original = item(204, actor.inventory)
    local operation = { kind = "transfer", item = original, source = actor.inventory, destination = destination }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor]:onCompleted(queues[actor].current)
    put(original, nil)
    local other = item(204, destination)
    other.fullType = "Base.WrongType"
    equal(adapter:poll(), false)
    equal(operation.resultItem, nil)
end)

case("Multiplayer floor drop and pickup resolve recreated objects in the exact square", function()
    client, rehydrate = true, true
    local actor = player()
    local floor = container("floor", actor:getCurrentSquare())
    local original = item(205, actor.inventory)
    local adapter = Native.new(actor)
    local drop = { kind = "transfer", item = original, source = actor.inventory, destination = floor }
    assert(adapter:begin(drop))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    local dropped = drop.resultItem
    assert(dropped ~= original)
    equal(dropped:getWorldItem():getSquare(), actor:getCurrentSquare())
    equal(#actor.location.worldObjects, 1)
    local pickup = { kind = "transfer", item = dropped, source = floor, destination = actor.inventory }
    assert(adapter:begin(pickup))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    assert(pickup.resultItem ~= dropped)
    equal(pickup.resultItem:getID(), original:getID())
    equal(pickup.resultItem:getContainer(), actor.inventory)
    equal(#actor.location.worldObjects, 0)
end)

case("A native-permitted adjacent floor fallback completes at the original drop zone", function()
    local actor = player()
    local floor, adjacent = container("floor", actor:getCurrentSquare()), square(1, 0)
    actor.location.dropAllowed = false
    floorDropSquare = adjacent
    local original = item(206, actor.inventory)
    local operation = { kind = "transfer", item = original, source = actor.inventory, destination = floor }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    equal(adapter:transferResult(operation, 206, "Base.Nails"), nil)
    queues[actor].current:complete()
    equal(adapter:transferResult(operation, 206, "Base.Nails"), original)
    equal(adapter:poll(), true)
    equal(operation.resultItem, original)
    equal(original:getWorldItem():getSquare(), adjacent)
end)

case("A stale floor view cannot hide a physically completed pickup", function()
    local actor = player()
    local floor = container("floor", actor:getCurrentSquare())
    local original = item(207, floor)
    local world = { getSquare = function() return actor.location end, getItem = function() return original end }
    original.world = world
    actor.location.worldObjects[1] = world
    local operation = { kind = "transfer", item = original, source = floor, destination = actor.inventory }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor]:onCompleted(queues[actor].current)
    actor.location.worldObjects = {}
    local current = item(207, actor.inventory)
    actor.location = square(8, 0)
    equal(floor:containsID(207), true)
    equal(adapter:poll(), true)
    equal(operation.resultItem, current)
end)

case("A disappearing queue entry cannot masquerade as a completed transfer", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(4, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    local queue = queues[actor]
    queue:onCompleted(queue.current)
    local done, reason, code = adapter:poll()
    equal(done, false, "Single player has nobody to wait for")
    includes(reason, "without doing anything")
    equal(code, "refused")
    equal(selected:getContainer(), actor.inventory)
end)

case("In multiplayer a completed transfer has two seconds to show its result", function()
    client = true
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(4, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    queues[actor]:onCompleted(queues[actor].current)
    equal(advance(adapter, 1900), nil)
    equal(advance(adapter, 300), false)
end)

case("Carried nested bags transfer directly without an equipment operation", function()
    local actor = player()
    local outer, inner = item(10, actor.inventory), item(11)
    local outerBag, innerBag = container("bag"), container("bag")
    outerBag.bag, innerBag.bag = outer, inner
    put(inner, outerBag)
    local selected = item(12, innerBag)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "approach", container = innerBag }))
    equal(adapter:poll(), true)
    assert(adapter:begin({ kind = "transfer", item = selected, source = innerBag, destination = actor.inventory }))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(selected:getContainer(), actor.inventory)
    equal(outer:getContainer(), actor.inventory)
    equal(inner:getContainer(), outerBag)
    equal(actor.equipmentChanged, nil)
end)

case("Floor bags use their containing item's location for approach and transfer", function()
    local actor, outer = player(), item(20)
    local outerBag = container("bag")
    outerBag.bag = outer
    local location = square(8, 0)
    outer.world = { getSquare = function() return location end }
    local inner = item(21, outerBag)
    local innerBag = container("bag")
    innerBag.bag = inner
    local selected = item(22, innerBag)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "approach", container = innerBag }))
    equal(adapter:poll(), nil)
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor:getCurrentSquare():getX(), 7)
    equal(besideRequests[1], location, "A bag on furniture is approached from beside it")
    assert(adapter:begin({ kind = "transfer", item = selected, source = innerBag, destination = actor.inventory }))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(selected:getContainer(), actor.inventory)
    equal(inner:getContainer(), outerBag)
    equal(outer:getWorldItem():getSquare(), location)
end)

case("Human corpse pickup is refused before native equipment side effects", function()
    local actor, source = player(), container("floor", square(0, 0))
    local selected = item(30, source)
    selected.corpse = true
    local adapter = Native.new(actor)
    assertRejected(adapter, { kind = "transfer", item = selected, source = source, destination = actor.inventory }, "corpse hauling")
    equal(corpseQueries, 1)
    equal(transfers, 0)
    equal(actor.equipmentChanged, nil)
    equal(selected:getContainer(), source)
end)

case("Trash deletion requires approval of every current bin item", function()
    local actor, bin = player(), trash(square(0, 0))
    item(40, bin); item(41, bin)
    local adapter = Native.new(actor)
    assertRejected(adapter, { kind = "trash", container = bin, approved = { ["40"] = true } }, "outside the approved cleanup")
    equal(#requests, 0)
    equal(bin:getItems():size(), 2)
    assert(adapter:begin({ kind = "trash", container = bin, approved = { ["40"] = true, ["41"] = true } }))
    equal(#requests, 1)
    equal(requests[1].module, "object")
    equal(requests[1].command, "emptyTrash")
    equal(requests[1].args.index, 7)
    equal(requests[1].args.x, 0)
    equal(adapter:poll(), nil)
    bin.items = {}
    equal(adapter:poll(), true)
    equal(#requests, 1)
end)

case("A multiplayer host can disable native trash deletion", function()
    client, allowTrash = true, false
    local actor, bin = player(), trash(square(0, 0))
    item(42, bin)
    assertRejected(Native.new(actor), { kind = "trash", container = bin, approved = { ["42"] = true } }, "does not let players empty")
    equal(#requests, 0)
    equal(bin:getItems():size(), 1)
end)

case("A transfer timeout cancels owned work and reports the unchanged source", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(50, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    equal(advance(adapter, 119900), nil)
    local done, reason = advance(adapter, 300)
    equal(done, false)
    includes(reason, "timed out")
    equal(#queues[actor].queue, 0)
    equal(selected:getContainer(), actor.inventory)
    equal(adapter:isBusy(), false)
end)

case("Cancel preserves foreign pending actions by reference, order, and execution", function()
    local actor, destination, executed = player(), container("crate", square(0, 0)), {}
    local selected = item(60, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    local first = action(actor, "foreign1", function() executed[#executed + 1] = "first" end)
    local second = action(actor, "foreign2", function() executed[#executed + 1] = "second" end)
    ISTimedActionQueue.add(first); ISTimedActionQueue.add(second)
    equal(adapter:cancel(), true)
    equal(adapter:cancel(), true)
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "Cancelled")
    equal(#queues[actor].queue, 0) -- the engine would clear whatever started inside stop
    require("LootBox/Act").restore()
    equal(queues[actor].queue[1], first)
    equal(queues[actor].queue[2], second)
    equal(first.cancellations, 0)
    equal(second.cancellations, 0)
    equal(first.starts, 1)
    equal(second.starts, 0)
    equal(first.stops, nil)
    first:complete(); second:complete()
    equal(table.concat(executed, ","), "first,second")
    equal(selected:getContainer(), actor.inventory)
end)

case("Busy admission preserves the current player action and the untouched operation", function()
    local actor = player()
    local foreign = action(actor, "foreign")
    ISTimedActionQueue.add(foreign)
    local adapter = Native.new(actor)
    local priorTravel = { distance = 9 }
    local operation = { kind = "approach", container = actor.inventory, travel = priorTravel }
    local accepted, reason, code = adapter:begin(operation)
    equal(accepted, nil)
    includes(reason, "current action")
    equal(code, "busy")
    equal(adapter:isBusy(), false)
    equal(operation.travel, priorTravel)
    equal(adapter:isPlayerBusy(), true)
    equal(adapter:cancel(), true)
    equal(queues[actor].current, foreign)
    equal(foreign.stops, nil)
    equal(foreign.cancellations, 0)
end)

case("Vehicle preparation unlocks storage and restores the original outside state", function()
    local actor, selected = player(), vehicle()
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "vehicle", vehicle = selected }))
    local result, reason
    for _ = 1, 40 do
        local queue = queues[actor]
        if queue.current then queue.current:complete() end
        result, reason = adapter:poll()
        clock = clock + 10
        if not adapter:isBusy() then break end
    end
    equal(result, true, reason)
    equal(adapter:isBusy(), false)
    equal(actor:getVehicle(), nil)
    equal(selected.trunk.door.locked, false)
    equal(selected.driver.door.open, false)
end)

local function run(adapter, actor, limit)
    local result, reason, code
    for _ = 1, limit or 60 do
        local queue = queues[actor]
        if queue and queue.current then queue.current:complete() end
        result, reason, code = adapter:poll()
        clock = clock + 10
        if not adapter:isBusy() then break end
    end
    return result, reason, code
end

case("Unlocked parts are reported and locked again in place with the key", function()
    local actor, selected = player(), vehicle()
    selected.driver.door.locked = true
    local adapter, operation = Native.new(actor), { kind = "vehicle", vehicle = selected }
    assert(adapter:begin(operation))
    equal(run(adapter, actor), true)
    equal(selected.driver.door.locked, false); equal(selected.trunk.door.locked, false)
    local ids = {}
    for _, entry in ipairs(operation.unlocked) do equal(entry.vehicle, selected); ids[#ids + 1] = entry.partId end
    equal(table.concat(ids, ","), "DoorFrontLeft,TrunkDoor")
    selected.trunk.door.open = true
    assert(adapter:begin({ kind = "vehicle", vehicle = selected, relock = ids }))
    equal(run(adapter, actor), true)
    equal(selected.driver.door.locked, true); equal(selected.trunk.door.locked, true)
    equal(selected.trunk.door.open, false, "An open door is closed before it is locked")
    equal(actor:getVehicle(), nil)
end)

case("Without a key the trunk is locked from the driver seat and the driver door last", function()
    local actor, selected = player(), vehicle()
    selected.noKey, selected.trunk.door.locked = true, false
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "vehicle", vehicle = selected, relock = { "DoorFrontLeft", "TrunkDoor" } }))
    local result, reason = run(adapter, actor)
    equal(result, true, reason)
    equal(selected.trunk.door.locked, true); equal(selected.driver.door.locked, true)
    equal(actor:getVehicle(), nil)
end)

case("A broken lock and an already locked part need no work", function()
    local actor, selected = player(), vehicle()
    selected.driver.door.lockBroken = true
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "vehicle", vehicle = selected, relock = { "DoorFrontLeft", "TrunkDoor" } }))
    equal(run(adapter, actor), true)
    equal(selected.driver.door.locked, false)
end)

case("A seated player gets one typed answer for every kind of walk", function()
    local actor, far = player(), square(9, 9)
    actor.vehicle = {}
    local crate, object = container("crate", far), { getSquare = function() return far end }
    crate.parent = object
    for _, operation in ipairs({ { kind = "approach", container = crate }, { kind = "approach", square = far },
        { kind = "approach", location = { x = 9, y = 9, z = 0 } } }) do
        local accepted, reason, code = Native.new(actor):begin(operation)
        equal(accepted, nil); includes(reason, "Get out of the vehicle"); equal(code, "seated")
    end
    equal(Native.new(actor):reachable(crate), false)
    equal(Native.new(actor):reachable(actor.inventory), true)
end)

case("A failed path is reported as unreachable", function()
    local actor, far = player(), square(9, 9)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "approach", square = far }))
    local current = queues[actor].current
    current.onFail(); current:reject()
    local result, reason, code = adapter:poll()
    equal(result, false); includes(reason, "No path"); equal(code, "unreachable")
end)

case("Items on furniture and fixtures are approached from beside their own tile", function()
    local table, crate = square(9, 9), container("crate", square(5, 5))
    table.blocked, table.beside = true, {x = 9, y = 8, z = 0}
    crate.parent = {getSquare = function() return crate.location end}
    for _, target in ipairs({{op = {kind = "approach", square = table}, tile = table},
        {op = {kind = "approach", location = {x = 9, y = 9, z = 0}}, tile = table}, {op = {kind = "approach", container = crate}, tile = crate.location}}) do
        local actor = player()
        local adapter = Native.new(actor)
        besideRequests = {}
        assert(adapter:begin(target.op))
        equal(besideRequests[1], target.tile)
        queues[actor].current:complete()
        equal(adapter:poll(), true)
    end
end)

case("A tile nobody can stand beside is walked to itself", function()
    local actor, closet = player(), square(4, 4)
    closet.walled = true
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "approach", square = closet}))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor:getCurrentSquare():getX(), 4)
end)

case("A walk that ends out of reach of the container is unreachable at once", function()
    local actor, dumpster = player(), container("dumpster", square(6, 6))
    dumpster.parent = {getSquare = function() return dumpster.location end}
    dumpster.location.beside = {x = 9, y = 6, z = 0}
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "approach", container = dumpster}))
    queues[actor].current:complete()
    local done, _, code = adapter:poll()
    equal(done, false)
    equal(code, "unreachable")
end)

case("Dragging a corpse or trading is named before anything is queued", function()
    local actor, destination = player(), container("crate", square(0, 0))
    function actor:isDraggingCorpse() return true end
    local adapter = Native.new(actor)
    local accepted, reason, code = adapter:begin({kind = "transfer", item = item(60, actor.inventory), source = actor.inventory, destination = destination})
    equal(accepted, nil); includes(reason, "corpse"); equal(code, "corpse"); equal(transfers, 0)
    function actor:isDraggingCorpse() return false end
    client, ISTradingUI = true, {GetUIForPlayer = function() return {isVisible = function() return true end} end}
    accepted, reason, code = adapter:begin({kind = "transfer", item = item(61, actor.inventory), source = actor.inventory, destination = destination})
    equal(accepted, nil); includes(reason, "trading"); equal(code, "trading"); equal(transfers, 0)
    ISTradingUI = nil
end)

case("Time that passes without ticks does not use up an operation's deadline", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(51, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    clock = 120001
    equal(adapter:poll(), nil)
    queues[actor].current:complete()
    equal(adapter:poll(), true)
end)

case("Standing at a game-paused screen does not use up a deadline", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = item(52, actor.inventory), source = actor.inventory, destination = destination }))
    isGamePaused = function() return true end
    equal(advance(adapter, 130000), nil)
    isGamePaused = nil
    equal(advance(adapter, 119000), nil)
    equal(advance(adapter, 1200), false)
end)

case("The pause trigger is named for the log", function()
    for flag, trigger in pairs({ aimInput = "aim", aiming = "aim", attacking = "attack", shoving = "shove", dead = "death", asleep = "sleep" }) do
        local actor = player()
        actor[flag] = true
        local _, _, found = Native.new(actor):takeoverReason()
        equal(found, trigger)
    end
    local actor = player()
    actor.movementInput, actor.running = true, true
    local _, _, found = Native.new(actor):takeoverReason()
    equal(found, "run")
end)

case("Cancel keeps polling vehicle restoration and exposes an unavailable original seat", function()
    local actor, selected = player(), vehicle()
    actor.vehicle, actor.seat, selected.occupants[1] = selected, 1, actor
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "vehicle", vehicle = selected }))
    queues[actor].current:complete()
    equal(actor.seat, 0)
    selected.occupants[1] = { anotherPlayer = true }
    equal(adapter:cancel(), true)
    equal(adapter:isBusy(), true)
    local done, reason
    for _ = 1, 5 do
        done, reason = adapter:poll()
        if not adapter:isBusy() then break end
    end
    equal(done, false)
    includes(reason, "Cancelled")
    includes(reason, "original vehicle seat")
    equal(actor:getVehicle(), selected)
    equal(actor.seat, 0)
    equal(adapter:isBusy(), false)
    equal(selected.occupants[1].anotherPlayer, true)
end)

case("An exact floor destination walks onto an adjacent tile instead of stopping within reach", function()
    local actor, target = player(), square(1, 0)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "approach", square = target, exact = true }))
    equal(adapter:poll(), nil)
    equal(actor.location.x, 0)
    assert(queues[actor].current)
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor.location.x, 1)
    equal(actor.location.y, 0)
end)

case("A denied safehouse blocks trash deletion at the final native command boundary", function()
    local actor = player()
    local destination = trash(square(0, 0))
    local selected = item(91, destination)
    local prior = SafeHouse
    client = true
    SafeHouse = { isSafehouseAllowLoot = function() return false end }
    local adapter = Native.new(actor)
    local accepted, reason = adapter:begin({ kind = "trash", container = destination, approved = { [tostring(selected:getID())] = true } })
    SafeHouse = prior
    equal(accepted, nil)
    includes(reason, "Safehouse")
    equal(#requests, 0)
    equal(selected:getContainer(), destination)
end)

case("A coordinate approach can start unloaded and records the completed cross-floor walk", function()
    local actor, operation = player(), {kind = "approach", location = {x = 5, y = 0, z = 1}}
    local adapter = Native.new(actor)
    equal(getCell():getGridSquare(5, 0, 1), nil)
    assert(adapter:begin(operation))
    actor.location = square(2, 0, 0)
    equal(advance(adapter, 500), nil)
    equal(operation.travel, nil)
    equal(advance(adapter, 900), nil)
    clock = clock + 100
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor:getCurrentSquare():getZ(), 1)
    equal(operation.travel.from.x, 0.5)
    equal(operation.travel.from.z, 0)
    equal(operation.travel.to.x, 5.5)
    equal(operation.travel.to.z, 1)
    assert(math.abs(operation.travel.distance - (2 + math.sqrt(10))) < 0.000001)
    equal(operation.travel.elapsedMs, 1500)
end)

case("Frontier approaches pass every centered native XYZ goal and accept an alternate arrival", function()
    local actor = player()
    square(5, 3, 1)
    square(8, 4, 0)
    nearestChoice = 2
    local operation = {kind = "approach", locations = {{x = 5, y = 3, z = 1}, {x = 8, y = 4, z = 0}}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    equal(#nearestRequests, 1)
    local expected = {5.5, 3.5, 1, 8.5, 4.5, 0}
    equal(#nearestRequests[1], #expected)
    for index, value in ipairs(expected) do equal(nearestRequests[1][index], value) end
    clock = 1000
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor:getCurrentSquare():getX(), 8)
    equal(actor:getCurrentSquare():getY(), 4)
    equal(actor:getCurrentSquare():getZ(), 0)
end)

case("A coordinate target does not complete on the wrong floor or without native reach", function()
    for _, result in ipairs({"wrong floor", "out of reach", "blocked reach", "unloaded"}) do
        local actor = player()
        local operation = {kind = "approach", location = {x = 3, y = 0, z = 1}}
        local adapter = Native.new(actor)
        clock = 0
        assert(adapter:begin(operation))
        queues[actor].current:complete()
        if result == "wrong floor" then actor.location = square(3, 0, 0)
        elseif result == "out of reach" then actor.location = square(8, 0, 1)
        elseif result == "blocked reach" then actor.location.reachable = false
        else loadedSquares["3:0:1"] = nil end
        local done, _, code = adapter:poll()
        equal(done, false, result)
        equal(code, "unreachable")
        equal(operation.travel, nil)
    end
end)

case("An exact coordinate approach walks onto an adjacent target", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 1, y = 0, z = 0}, exact = true}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    equal(adapter:poll(), nil)
    equal(actor:getCurrentSquare():getX(), 0)
    assert(queues[actor].current)
    clock = 500
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor:getCurrentSquare():getX(), 1)
end)

case("An exact target nobody can stand on is reached from beside it", function()
    local actor, counter = player(), square(1, 0)
    counter.blocked = true
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "approach", location = {x = 1, y = 0, z = 0}, exact = true}))
    equal(adapter:poll(), true)
    equal(actor:getCurrentSquare():getX(), 0)
    local floor, selected = container("floor", actor.location), item(62, actor.inventory)
    local drop = {kind = "transfer", item = selected, source = actor.inventory, destination = floor, destinationPoint = {x = 1, y = 0, z = 0}}
    assert(adapter:begin(drop))
    queues[actor].current:complete()
    equal(adapter:poll(), true, "The game drops on the player's own tile")
    equal(drop.resultItem:getWorldItem():getSquare():getX(), 0)
end)

case("Coordinate and frontier inputs reject invalid numbers mixed targets and unloaded candidates", function()
    local actor = player()
    local adapter = Native.new(actor)
    for _, field in ipairs({"x", "y", "z"}) do
        for _, invalid in ipairs({0 / 0, math.huge, 2147483648, 1.5, "1", false}) do
            local point = {x = 0, y = 0, z = 0}
            point[field] = invalid
            assertRejected(adapter, {kind = "approach", location = point}, "coordinates")
        end
    end
    local point = {x = 0, y = 0, z = 0}
    for _, operation in ipairs({
        {kind = "approach", location = point, square = actor.location},
        {kind = "approach", location = point, container = actor.inventory},
        {kind = "approach", location = point, locations = {point}},
    }) do assertRejected(adapter, operation, "one approach") end
    assertRejected(adapter, {kind = "approach", locations = {}}, "sixteen")
    local tooMany = {}
    for index = 1, 17 do tooMany[index] = point end
    assertRejected(adapter, {kind = "approach", locations = tooMany}, "sixteen")
    assertRejected(adapter, {kind = "approach", locations = {[1] = point, [3] = point}}, "dense")
    assertRejected(adapter, {kind = "approach", locations = {{x = 5, y = 0, z = 1}}}, "no longer loaded")
    equal(#nearestRequests, 0)
end)

case("Cancelling a sampled walk publishes no completed-route observation", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 5, y = 0, z = 1}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    clock, actor.location = 500, square(2, 0, 0)
    equal(adapter:poll(), nil)
    assert(adapter:cancel())
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "Cancelled")
    equal(operation.travel, nil)
end)

case("A foreign action yields walking without being cancelled or learned", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 5, y = 0, z = 1}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    clock, actor.location = 500, square(2, 0, 0)
    equal(adapter:poll(), nil)
    local foreign = action(actor, "user action")
    queues[actor]:addToQueue(foreign)
    local done, reason, code = adapter:poll()
    equal(done, false)
    includes(reason, "queued action")
    equal(code, "yielded")
    equal(operation.travel, nil)
    equal(adapter:isPlayerBusy(), true)
    require("LootBox/Act").restore()
    equal(queues[actor].current, foreign)
    equal(foreign.cancellations, 0)
    equal(foreign.starts, 1)
end)

case("A rejected native path does not create a successful travel observation", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 5, y = 0, z = 1}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    clock, actor.location = 500, square(2, 0, 0)
    equal(adapter:poll(), nil)
    queues[actor].current:reject()
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "path")
    equal(operation.travel, nil)
end)

case("A walk making sampled progress can finish after more than sixty seconds", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 200, y = 0, z = 0}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    local walking = queues[actor].current
    for step = 1, 3 do
        actor.location = square(step * 10, 0)
        equal(advance(adapter, 30000), nil)
        equal(adapter:isBusy(), true)
        equal(queues[actor].current, walking)
        equal(operation.travel, nil)
    end
    equal(advance(adapter, 29900), nil)
    clock = clock + 100
    walking:complete()
    equal(adapter:poll(), true)
    equal(adapter:isBusy(), false)
    equal(actor:getCurrentSquare():getX(), 200)
    equal(operation.travel.elapsedMs, 120000)
    assert(operation.travel.distance > 0)
    equal(walking.stops, nil)
end)

case("Sixty seconds without walking progress stops owned work without learning it", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 200, y = 0, z = 0}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    local walking = queues[actor].current
    equal(advance(adapter, 29900), nil)
    actor.location = square(10, 0)
    equal(advance(adapter, 60000), nil)
    local done, reason = advance(adapter, 200)
    equal(done, false)
    includes(reason, "timed out")
    equal(adapter:isBusy(), false)
    equal(#queues[actor].queue, 0)
    equal(walking.stops, 1)
    equal(operation.travel, nil)
end)

case("Continued walking cannot extend one approach beyond ten minutes", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 2000, y = 0, z = 0}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    local walking = queues[actor].current
    for step = 1, 20 do
        actor.location = square(step * 10, 0)
        equal(advance(adapter, 29990), nil)
    end
    actor.location = square(201, 0)
    local done, reason = advance(adapter, 400)
    equal(done, false)
    includes(reason, "timed out")
    equal(adapter:isBusy(), false)
    equal(walking.stops, 1)
    equal(operation.travel, nil)
end)

case("Held gentle movement waits before admission without becoming a takeover", function()
    local actor = player()
    actor.movementInput, actor.moving = true, true
    local adapter = Native.new(actor)
    local operation = {kind = "vehicle", vehicle = vehicle()}
    equal(adapter:takeoverReason(), nil)
    equal(adapter:isPlayerBusy(), true)
    local accepted, _, code = adapter:begin(operation)
    equal(accepted, nil)
    equal(code, "busy")
    equal(operation.vehicleOrigin, nil)
    equal(adapter:isBusy(), false)
    equal(#ISTimedActionQueue.getTimedActionQueue(actor).queue, 0)
    actor.movementInput, actor.moving = false, false
    equal(adapter:isPlayerBusy(), false)
    assert(adapter:begin(operation))
    equal(queues[actor].current.kind, "path")
end)

case("Native character actions outside the Lua queue also defer admission", function()
    local actor = player()
    local foreign = {kind = "native character action"}
    actor.characterActions = {foreign}
    local adapter = Native.new(actor)
    local accepted, _, code = adapter:begin({kind = "approach", container = actor.inventory})
    equal(accepted, nil)
    equal(code, "busy")
    equal(adapter:isBusy(), false)
    equal(actor.characterActions[1], foreign)
    equal(#queues[actor].queue, 0)
end)

case("Explicit takeover distinguishes aiming combat and manual running from ordinary input", function()
    for _, entry in ipairs({
        {"aimInput", "Aiming"}, {"aiming", "Aiming"},
        {"attacking", "Attacking"}, {"shoving", "shoving"},
        {"dead", "died"}, {"asleep", "Sleeping"},
    }) do
        local actor = player()
        actor[entry[1]] = true
        includes(Native.new(actor):takeoverReason(), entry[2])
    end
    for _, state in ipairs({"running", "sprinting"}) do
        local actor = player()
        actor[state], actor.moving, actor.cancelInput = true, true, true
        local adapter = Native.new(actor)
        equal(adapter:takeoverReason(), nil, "Automatic motion and Escape must not imply manual takeover")
        actor.movementInput = true
        includes(adapter:takeoverReason(), "Running or sprinting")
    end
end)

case("Arbitrary queued preparation consumption and restoration yield in original order", function()
    local actor, destination, executed = player(), container("crate", square(0, 0)), {}
    local selected = item(300, actor.inventory)
    local adapter = Native.new(actor)
    local operation = {kind = "transfer", item = selected, source = actor.inventory, destination = destination}
    assert(adapter:begin(operation))
    local foreign = {}
    for _, name in ipairs({"modded preparation", "consume", "restore equipment"}) do
        local label = name
        local entry = action(actor, label, function() executed[#executed + 1] = label end)
        foreign[#foreign + 1] = entry
        ISTimedActionQueue.add(entry)
    end
    local done, _, code = adapter:poll()
    equal(done, false)
    equal(code, "yielded")
    equal(adapter:isBusy(), false)
    equal(selected:getContainer(), actor.inventory)
    require("LootBox/Act").restore()
    for index, entry in ipairs(foreign) do
        equal(queues[actor].queue[index], entry)
        equal(entry.cancellations, 0)
        equal(entry.stops, nil)
    end
    local accepted, _, admissionCode = adapter:begin(operation)
    equal(accepted, nil)
    equal(admissionCode, "busy")
    for _, entry in ipairs(foreign) do entry:complete() end
    equal(table.concat(executed, ","), "modded preparation,consume,restore equipment")
    clock = 1000000
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(selected:getContainer(), destination)
end)

case("A movement-stopped native action yields without recording a failed or completed walk", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 9, y = 0, z = 0}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    clock, actor.location, actor.movementInput, actor.moving = 1000, square(2, 0), true, true
    queues[actor].current:forceStop()
    actor.movementInput, actor.moving = false, false
    local done, _, code = adapter:poll()
    equal(done, false)
    equal(code, "yielded")
    equal(operation.travel, nil)
    equal(adapter:isBusy(), false)
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(actor.location.x, 9)
end)

case("A genuine path failure stays a failure even when foreign work arrives", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 9, y = 0, z = 0}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor].current:reject()
    local foreign = action(actor, "unrelated user action")
    ISTimedActionQueue.add(foreign)
    local done, reason, code = adapter:poll()
    equal(done, false)
    includes(reason, "path")
    equal(code, "unreachable")
    equal(operation.travel, nil)
    equal(queues[actor].current, foreign)
    equal(foreign.stops, nil)
    equal(foreign.cancellations, 0)
end)

case("A stopped multiplayer transfer waits for a late immutable-ID result before yielding", function()
    client = true
    local actor, destination = player(), container("crate", square(0, 0))
    local original = item(301, actor.inventory)
    local operation = {kind = "transfer", item = original, source = actor.inventory, destination = destination}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    actor.movementInput = true
    queues[actor].current:forceStop()
    actor.movementInput = false
    equal(adapter:poll(), nil)
    clock = 1500
    put(original, nil)
    local current = item(301, destination)
    local done, _, code = adapter:poll()
    equal(done, true)
    equal(code, nil)
    equal(operation.resultItem, current)
    equal(transfers, 1)
end)

case("A stopped multiplayer transfer yields only after its observation window settles", function()
    client = true
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(302, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "transfer", item = selected, source = actor.inventory, destination = destination}))
    actor.movementInput = true
    queues[actor].current:forceStop()
    actor.movementInput = false
    equal(advance(adapter, 1900), nil)
    local done, _, code = advance(adapter, 300)
    equal(done, false)
    equal(code, "yielded")
    equal(selected:getContainer(), actor.inventory)
    equal(adapter:isBusy(), false)
end)

case("A completed transfer wins over cancellation and is not transferred twice", function()
    client, rehydrate = true, true
    local actor, destination = player(), container("crate", square(0, 0))
    local original = item(303, actor.inventory)
    local operation = {kind = "transfer", item = original, source = actor.inventory, destination = destination}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    assert(adapter:cancel())
    equal(adapter:poll(), true)
    local current = operation.resultItem
    assert(current ~= original)
    equal(current:getID(), 303)
    assert(adapter:begin(operation))
    equal(adapter:poll(), true)
    equal(transfers, 1)
    equal(destination:getItems():size(), 1)
end)

case("Completed work and the following foreign action are both preserved", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(304, actor.inventory)
    local operation = {kind = "transfer", item = selected, source = actor.inventory, destination = destination}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    local foreign = action(actor, "food preparation")
    ISTimedActionQueue.add(foreign)
    queues[actor].current:complete()
    equal(adapter:poll(), true)
    equal(operation.resultItem, selected)
    equal(queues[actor].current, foreign)
    equal(foreign.starts, 1)
    equal(foreign.stops, nil)
    equal(foreign.cancellations, 0)
end)

case("An original floor destination is not silently replaced by the player's new tile", function()
    local actor = player()
    local origin = actor.location
    local floor, selected = container("floor", origin), item(305, actor.inventory)
    actor.location = square(3, 0)
    local operation = {kind = "transfer", item = selected, source = actor.inventory, destination = floor,
        destinationPoint = {x = origin.x, y = origin.y, z = origin.z}}
    assertRejected(Native.new(actor), operation, "selected floor location")
    equal(transfers, 0)
    equal(selected:getContainer(), actor.inventory)
    equal(#actor.location.worldObjects, 0)
    equal(#origin.worldObjects, 0)
end)

case("A completed floor drop is recognized at its original tile after the player moves away", function()
    local actor = player()
    local origin = actor.location
    local floor, selected = container("floor", origin), item(306, actor.inventory)
    local operation = {kind = "transfer", item = selected, source = actor.inventory, destination = floor,
        destinationPoint = {x = origin.x, y = origin.y, z = origin.z}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    actor.location = square(8, 0)
    assert(adapter:cancel())
    equal(adapter:poll(), true)
    equal(operation.resultItem:getWorldItem():getSquare(), origin)
    assert(adapter:begin(operation))
    equal(adapter:poll(), true)
    equal(transfers, 1)
    equal(#origin.worldObjects, 1)
    equal(#actor.location.worldObjects, 0)
end)

case("Floor completion rejects remote wrong-floor forbidden and mismatched identity outcomes", function()
    for _, outcome in ipairs({"remote", "wrong floor", "native policy denied", "source still owns ID", "wrong item type"}) do
        clock = 0
        local actor = player()
        local origin = actor.location
        local candidate = square(outcome == "remote" and 2 or 1, 0, outcome == "wrong floor" and 1 or 0)
        if outcome == "native policy denied" then candidate.dropAllowed = false end
        local floor, original = container("floor", origin), item(309, actor.inventory)
        local operation = {kind = "transfer", item = original, source = actor.inventory, destination = floor,
            destinationPoint = {x = origin.x, y = origin.y, z = origin.z}}
        local adapter = Native.new(actor)
        assert(adapter:begin(operation))
        queues[actor]:onCompleted(queues[actor].current)
        if outcome ~= "source still owns ID" then put(original, nil) end
        local other = item(309, floor)
        if outcome == "wrong item type" then other.fullType = "Base.WrongType" end
        local world = {getSquare = function() return candidate end, getItem = function() return other end}
        other.world, candidate.worldObjects[1] = world, world
        equal(adapter:transferResult(operation, 309, "Base.Nails"), nil, outcome)
        local done, _, code = adapter:poll()
        equal(done, false, outcome)
        equal(code, "refused")
        equal(operation.resultItem, nil)
    end
end)

case("An admitted adjacent floor result stays bound to its original zone after movement", function()
    local actor = player()
    local origin, adjacent = actor.location, square(1, 1)
    local floor, selected = container("floor", origin), item(310, actor.inventory)
    origin.dropAllowed, floorDropSquare = false, adjacent
    local operation = {kind = "transfer", item = selected, source = actor.inventory, destination = floor,
        destinationPoint = {x = origin.x, y = origin.y, z = origin.z}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor].current:complete()
    actor.location, adjacent.dropAllowed = square(8, 0), false
    equal(adapter:transferResult(operation, 310, "Base.Nails"), selected)
    assert(adapter:cancel())
    equal(adapter:poll(), true)
    equal(operation.resultItem, selected)
    assert(adapter:begin(operation))
    equal(adapter:poll(), true)
    equal(transfers, 1)
    equal(#adjacent.worldObjects, 1)
    equal(#actor.location.worldObjects, 0)
end)

case("An issued trash command remains under observation while unrelated work runs", function()
    local actor, bin = player(), trash(square(0, 0))
    item(307, bin)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "trash", container = bin, approved = {["307"] = true}}))
    local foreign = action(actor, "drink and restore container")
    ISTimedActionQueue.add(foreign)
    equal(adapter:poll(), nil)
    equal(adapter:isBusy(), true)
    equal(#requests, 1)
    equal(queues[actor].current, foreign)
    equal(foreign.stops, nil)
    equal(foreign.cancellations, 0)
    bin.items = {}
    equal(adapter:poll(), true)
    equal(#requests, 1)
    equal(queues[actor].current, foreign)
    foreign:complete()
    equal(#requests, 1)
end)

case("A cancelled trash command observes a completed empty without issuing another command", function()
    local actor, bin = player(), trash(square(0, 0))
    item(308, bin)
    local operation = {kind = "trash", container = bin, approved = {["308"] = true}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    assert(adapter:cancel())
    bin.items = {}
    equal(adapter:poll(), true)
    assert(adapter:begin(operation))
    equal(adapter:poll(), true)
    equal(#requests, 1)
end)

case("Vehicle retries keep the original outside or passenger-seat restoration target", function()
    for _, originalSeat in ipairs({-1, 1}) do
        local actor, selected = player(), vehicle()
        if originalSeat >= 0 then actor.vehicle, actor.seat, selected.occupants[originalSeat] = selected, originalSeat, actor end
        local operation = {kind = "vehicle", vehicle = selected}
        local adapter = Native.new(actor)
        assert(adapter:begin(operation))
        for _ = 1, 20 do
            local queue = queues[actor]
            if queue.current then queue.current:complete() end
            adapter:poll()
            if actor.vehicle == selected and actor.seat == 0 and queue.current then break end
        end
        equal(actor:getVehicle(), selected)
        equal(actor.seat, 0)
        local foreign = action(actor, "eat before restoring seat")
        ISTimedActionQueue.add(foreign)
        local done, _, code = adapter:poll()
        equal(done, false)
        equal(code, "yielded")
        require("LootBox/Act").restore()
        equal(queues[actor].current, foreign)
        equal(foreign.cancellations, 0)
        foreign:complete()
        clock = clock + 200000
        assert(adapter:begin(operation))
        local result, reason
        for _ = 1, 40 do
            local queue = queues[actor]
            if queue.current then queue.current:complete() end
            result, reason = adapter:poll()
            clock = clock + 10
            if not adapter:isBusy() then break end
        end
        equal(result, true, reason)
        if originalSeat < 0 then equal(actor:getVehicle(), nil)
        else equal(actor:getVehicle(), selected); equal(actor.seat, originalSeat) end
        equal(selected.trunk.door.locked, false)
        equal(selected.driver.door.open, false)
    end
end)

case("Vehicle cancellation waits for foreign work before restoring the original outside state", function()
    local actor, selected = player(), vehicle()
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "vehicle", vehicle = selected}))
    for _ = 1, 20 do
        local queue = queues[actor]
        if queue.current then queue.current:complete() end
        adapter:poll()
        if actor.vehicle == selected and actor.seat == 0 and queue.current then break end
    end
    equal(actor:getVehicle(), selected)
    local foreign = action(actor, "finish drinking")
    ISTimedActionQueue.add(foreign)
    assert(adapter:cancel())
    equal(adapter:poll(), nil)
    require("LootBox/Act").restore()
    equal(adapter:poll(), nil)
    clock = 200000
    equal(adapter:poll(), nil)
    equal(actor:getVehicle(), selected)
    equal(queues[actor].current, foreign)
    equal(foreign.stops, nil)
    equal(foreign.cancellations, 0)
    foreign:complete()
    local done, reason
    for _ = 1, 40 do
        done, reason = adapter:poll()
        local queue = queues[actor]
        if queue.current then queue.current:complete() end
        if not adapter:isBusy() then break end
    end
    equal(done, false)
    includes(reason, "Cancelled")
    equal(actor:getVehicle(), nil)
    equal(selected.driver.door.open, false)
end)

case("Cancelling a yielded vehicle operation restores its retained outside or passenger state", function()
    for _, originalSeat in ipairs({-1, 1}) do
        local actor, selected = player(), vehicle()
        if originalSeat >= 0 then actor.vehicle, actor.seat, selected.occupants[originalSeat] = selected, originalSeat, actor end
        local operation = {kind = "vehicle", vehicle = selected}
        local adapter = Native.new(actor)
        assert(adapter:begin(operation))
        for _ = 1, 20 do
            local queue = queues[actor]
            if queue.current then queue.current:complete() end
            adapter:poll()
            if actor.vehicle == selected and actor.seat == 0 and queue.current then break end
        end
        equal(actor:getVehicle(), selected)
        equal(actor.seat, 0)
        local foreign = action(actor, "finish food preparation")
        ISTimedActionQueue.add(foreign)
        local done, _, code = adapter:poll()
        equal(done, false)
        equal(code, "yielded")
        require("LootBox/Act").restore()
        equal(adapter:isBusy(), false)
        assert(adapter:cancel(operation))
        equal(adapter:isBusy(), true)
        equal(adapter:poll(), nil)
        clock = clock + 200000
        equal(adapter:poll(), nil)
        equal(actor:getVehicle(), selected)
        equal(actor.seat, 0)
        equal(queues[actor].current, foreign)
        equal(foreign.stops, nil)
        equal(foreign.cancellations, 0)
        foreign:complete()
        local reason
        for _ = 1, 40 do
            done, reason = adapter:poll()
            local queue = queues[actor]
            if queue.current then queue.current:complete() end
            if not adapter:isBusy() then break end
        end
        equal(done, false)
        includes(reason, "Cancelled")
        if originalSeat < 0 then equal(actor:getVehicle(), nil)
        else equal(actor:getVehicle(), selected); equal(actor.seat, originalSeat) end
        equal(selected.driver.door.open, false)
    end
end)

local function finishGear(adapter, actor)
    for _ = 1, 20 do
        local queue = queues[actor]
        if queue and queue.current then queue.current:complete() end
        local done, reason, code = adapter:poll()
        if done ~= nil then return done, reason, code end
    end
    error("Gear did not settle within twenty native actions")
end

case("A carried bag is worn only after the native clothing action completes", function()
    local actor = gearPlayer()
    local selected = gearBag(500, actor.inventory, "base:Back")
    local adapter = Native.new(actor)
    local op = {kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "base:Back"}
    assert(adapter:begin(op))
    equal(actor:getWornItem("base:Back"), nil)
    equal(queues[actor].current.kind, "wear")
    equal(finishGear(adapter, actor), true)
    equal(actor:getWornItem("base:Back"), selected)
    equal(op.resultItem, selected)
    equal(transfers, 0)
end)

case("A nested carried bag is retrieved once and then worn with its contents intact", function()
    local actor = gearPlayer()
    local outer = gearBag(501, actor.inventory, "custom:LowerBack")
    local selected = gearBag(502, outer.inventory, "base:Back")
    local child = item(503, selected.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = outer.inventory, mode = "wear", slot = "base:Back"}))
    equal(queues[actor].current.kind, "transfer")
    equal(finishGear(adapter, actor), true)
    equal(transfers, 1)
    equal(selected:getContainer(), actor.inventory)
    equal(actor:getWornItem("base:Back"), selected)
    equal(child:getContainer(), selected.inventory)
end)

case("A found bag in distant furniture uses native approach then retrieval and wear", function()
    local actor, source = gearPlayer(), container("crate", square(8, 4))
    source.parent = {getSquare = function() return source.location end}
    local selected = gearBag(504, source, "base:Back")
    local child = item(505, selected.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = source, mode = "wear", slot = "base:Back"}))
    equal(queues[actor].current.kind, "path")
    equal(finishGear(adapter, actor), true)
    equal(transfers, 1)
    equal(actor:getWornItem("base:Back"), selected)
    equal(child:getContainer(), selected.inventory)
end)

case("Native gear preparation refuses a newly occupied or exclusive worn location", function()
    for _, exclusive in ipairs({false, true}) do
        local actor = gearPlayer()
        local existing = gearBag(506, actor.inventory, exclusive and "custom:LowerBack" or "base:Back")
        wear(actor, existing, existing.slot)
        if exclusive then actor.group.exclusive["base:Back:custom:LowerBack"] = true end
        local selected = gearBag(507, actor.inventory, "base:Back")
        assertRejected(Native.new(actor), {kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "base:Back"}, "occupied")
        equal(actor:getWornItem(existing.slot), existing)
        equal(#queues[actor].queue, 0)
    end
end)

case("A declared native lower location variant produces an observed new bag with the same contents", function()
    local actor = gearPlayer()
    local selected = gearBag(508, actor.inventory, "base:Back")
    selected.extras = {"Bag_Lower"}
    prototypes["Base.Bag_Lower"] = gearBag(-1, nil, "custom:LowerBack", 20, "Base.Bag_Lower")
    local child = item(509, selected.inventory)
    local adapter = Native.new(actor)
    local op = {kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "custom:LowerBack", variant = "Base.Bag_Lower"}
    assert(adapter:begin(op))
    equal(queues[actor].current.kind, "clothingExtra")
    equal(op.resultItem, nil)
    equal(finishGear(adapter, actor), true)
    local result = actor:getWornItem("custom:LowerBack")
    assert(result and result:getID() ~= selected:getID())
    equal(result:getFullType(), "Base.Bag_Lower")
    equal(op.resultItem, result)
    equal(child:getContainer(), result.inventory)
    equal(actor.inventory:containsID(selected:getID()), false)
end)

case("A bag variant too small for existing contents is rejected before conversion", function()
    local actor = gearPlayer()
    local selected = gearBag(510, actor.inventory, "base:Back")
    selected.extras = {"Bag_Tiny"}
    prototypes["Base.Bag_Tiny"] = gearBag(-1, nil, "custom:LowerBack", 1, "Base.Bag_Tiny")
    item(511, selected.inventory).mass = 2
    assertRejected(Native.new(actor), {kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "custom:LowerBack", variant = "Base.Bag_Tiny"}, "too small")
    equal(selected.inventory:getItems():size(), 1)
    equal(#queues[actor].queue, 0)
end)

case("A conversion that loses a contained identity cannot claim a successful replacement", function()
    local actor = gearPlayer()
    local selected = gearBag(512, actor.inventory, "base:Back")
    selected.extras, selected.loseContents = {"Bag_Lower"}, true
    prototypes["Base.Bag_Lower"] = gearBag(-1, nil, "custom:LowerBack", 20, "Base.Bag_Lower")
    item(513, selected.inventory)
    local adapter = Native.new(actor)
    local op = {kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "custom:LowerBack", variant = "Base.Bag_Lower"}
    assert(adapter:begin(op))
    queues[actor].current:complete()
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "without doing anything")
    equal(op.resultItem, nil)
end)

case("Pausing after bag retrieval resumes equipment without retrieving the bag twice", function()
    local actor, source = gearPlayer(), container("crate", square(0, 0))
    local selected = gearBag(514, source, "base:Back")
    local adapter = Native.new(actor)
    local op = {kind = "gear", item = selected, source = source, mode = "wear", slot = "base:Back"}
    assert(adapter:begin(op))
    queues[actor].current:complete()
    equal(adapter:poll(), nil)
    equal(queues[actor].current.kind, "wear")
    assert(adapter:cancel(op))
    equal(adapter:poll(), false)
    equal(selected:getContainer(), actor.inventory)
    assert(adapter:begin(op))
    equal(finishGear(adapter, actor), true)
    equal(transfers, 1)
    equal(actor:getWornItem("base:Back"), selected)
end)

case("Gear pickup capacity failure stays typed after a completed approach", function()
    local actor, source = gearPlayer(), container("crate", square(8, 4))
    local selected = gearBag(515, source, "base:Back")
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = source, mode = "wear", slot = "base:Back"}))
    actor.inventory.room = false
    queues[actor].current:complete()
    local done, reason, code = adapter:poll()
    equal(done, false)
    includes(reason, "hard carrying limit")
    equal(code, "capacity")
    equal(selected:getContainer(), source)
    equal(transfers, 0)
end)

case("A hand bag can use free primary while preserving an occupied one-handed secondary", function()
    local actor = gearPlayer()
    actor.secondary = item(516, actor.inventory)
    local selected, existing = gearBag(517, actor.inventory, "base:Back"), actor.secondary
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = actor.inventory, mode = "primary"}))
    equal(finishGear(adapter, actor), true)
    equal(actor.primary, selected)
    equal(actor.secondary, existing)
end)

case("Gear restoration can restore one item to both original hand slots", function()
    local actor = gearPlayer()
    local selected = item(518, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = actor.inventory, mode = "primary", twoHands = true}))
    equal(finishGear(adapter, actor), true)
    equal(actor.primary, selected)
    equal(actor.secondary, selected)
end)

case("A foreign queued action yields bag preparation without cancelling the player's action", function()
    local actor = gearPlayer()
    local selected = gearBag(519, actor.inventory, "base:Back")
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "base:Back"}))
    local foreign = action(actor, "eat")
    ISTimedActionQueue.add(foreign)
    local done, _, code = adapter:poll()
    equal(done, false)
    equal(code, "yielded")
    require("LootBox/Act").restore()
    equal(queues[actor].current, foreign)
    equal(foreign.cancellations, 0)
    equal(foreign.stops, nil)
    equal(actor:getWornItem("base:Back"), nil)
end)

case("A sent trash command stays pending after cancellation until the delayed native result arrives", function()
    client = true
    local previousSafeHouse = SafeHouse
    SafeHouse = {isSafehouseAllowLoot = function() return true end}
    local actor, bin = player(), trash(square(0, 0))
    local selected = item(520, bin)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "trash", container = bin, approved = {["520"] = true}}))
    assert(adapter:cancel())
    equal(adapter:poll(), nil)
    equal(adapter:isBusy(), true)
    actor.location = square(20, 20, 1)
    clock = 1000
    equal(adapter:poll(), nil)
    put(selected, nil)
    equal(adapter:poll(), true)
    equal(adapter:isBusy(), false)
    equal(#requests, 1)
    SafeHouse = previousSafeHouse
end)

case("A sent trash command confirms only its dispatched identities when new contents remain", function()
    local actor, bin = player(), trash(square(0, 0))
    local selected = item(521, bin)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "trash", container = bin, approved = {["521"] = true}}))
    local added = item(522, bin)
    put(selected, nil)
    equal(adapter:poll(), true)
    equal(added:getContainer(), bin)
    equal(#requests, 1)
end)

case("A cancelled unconfirmed trash operation times out without inventing an empty result", function()
    local actor, bin = player(), trash(square(0, 0))
    local selected = item(523, bin)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "trash", container = bin, approved = {["523"] = true}}))
    assert(adapter:cancel())
    equal(adapter:poll(), nil)
    local done, reason = advance(adapter, 15100)
    equal(done, false)
    includes(reason, "could not be confirmed")
    equal(selected:getContainer(), bin)
    equal(#requests, 1)
end)

case("A replaced trash destination cannot confirm the original sent deletion", function()
    local actor, bin = player(), trash(square(0, 0))
    local selected = item(524, bin)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "trash", container = bin, approved = {["524"] = true}}))
    put(selected, nil)
    bin.parent.index = -1
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "changed")
end)

case("Combat takeover has a structured pause classification", function()
    for _, flag in ipairs({"aimInput", "aiming", "attacking", "shoving"}) do
        local actor = player()
        actor[flag] = true
        local _, category = Native.new(actor):takeoverReason()
        equal(category, "combat")
    end
    local actor = player()
    actor.dead = true
    local _, category = Native.new(actor):takeoverReason()
    equal(category, nil)
end)

case("A full destination exposes the typed capacity outcome used by deferred hauling", function()
    local actor, destination = player(), container("crate", square(0, 0))
    destination.room = false
    local selected = item(525, actor.inventory)
    local done, reason, code = Native.new(actor):begin({kind = "transfer", item = selected, source = actor.inventory, destination = destination})
    equal(done, nil)
    includes(reason, "full")
    equal(code, "capacity")
    equal(transfers, 0)
    equal(selected:getContainer(), actor.inventory)
end)

case("Unequipping a personal bag leaves the whole bag and its contents together", function()
    local actor = gearPlayer()
    local selected = gearBag(526, actor.inventory, "base:Back")
    local child = item(527, selected.inventory)
    wear(actor, selected, selected.slot)
    local adapter = Native.new(actor)
    assert(adapter:begin({kind = "gear", item = selected, source = actor.inventory, mode = "unequip"}))
    equal(finishGear(adapter, actor), true)
    equal(actor:isEquipped(selected), false)
    equal(selected:getContainer(), actor.inventory)
    equal(child:getContainer(), selected.inventory)
end)

case("A native multi-item worn location observes the newly worn bag without replacing the first", function()
    local actor = gearPlayer()
    actor.group.multi["base:Back"] = true
    local existing, selected = gearBag(528, actor.inventory, "base:Back"), gearBag(529, actor.inventory, "base:Back")
    wear(actor, existing, existing.slot)
    local adapter = Native.new(actor)
    local op = {kind = "gear", item = selected, source = actor.inventory, mode = "wear", slot = "base:Back"}
    assert(adapter:begin(op))
    equal(finishGear(adapter, actor), true)
    equal(actor:getWornItems():contains(existing), true)
    equal(actor:getWornItems():contains(selected), true)
    equal(op.resultItem, selected)
end)

-- The game's own merge: the running action takes over the queued ones behind it
-- that share its containers, and empties their tables.
local function merging(body)
    local original = ISInventoryTransferUtil.newInventoryTransferAction
    ISInventoryTransferUtil.newInventoryTransferAction = function(character, selected, source, destination)
        local transfer = original(character, selected, source, destination)
        transfer.item, transfer.source, transfer.destination = selected, source, destination
        local complete = transfer.complete
        function transfer:complete(moves)
            local queue, merged = queues[character], {self.item}
            while queue.queue[2] and queue.queue[2].source == self.source and queue.queue[2].destination == self.destination do
                local action = table.remove(queue.queue, 2)
                merged[#merged + 1] = action.item
                for key in pairs(action) do action[key] = nil end
            end
            for index = 2, #merged do if not moves or moves(merged[index]) then put(merged[index], destination) end end
            complete(self)
        end
        return transfer
    end
    local ok, err = pcall(body)
    ISInventoryTransferUtil.newInventoryTransferAction = original
    if not ok then error(err, 0) end
end

local function nails(actor, count)
    local result = {}
    for index = 1, count do
        result[index] = item(700 + index, actor.inventory)
        result[index].getWeight = function() return 0.01 end
    end
    return result
end

case("Twenty nails go as one action and each is confirmed by its identity", function()
    merging(function()
        local actor, destination = player(), container("crate", square(0, 0))
        local items = nails(actor, 20)
        local op = {kind = "transfer", item = items[1], items = items, source = actor.inventory, destination = destination}
        local adapter = Native.new(actor)
        assert(adapter:begin(op))
        equal(#queues[actor].queue, 20)
        equal(queues[actor].current.item, items[1])
        equal(adapter:poll(), nil)
        queues[actor].current:complete()
        equal(adapter:poll(), true)
        equal(#destination.items, 20)
        equal(op.resultItem, items[1])
        for _, value in ipairs(items) do equal(adapter:transferResult(op, value:getID(), "Base.Nails"), value) end
        equal(adapter:isBusy(), false)
    end)
end)

case("A run the game moves only in part is reported as failed, with the moved ones visible", function()
    merging(function()
        local actor, destination = player(), container("crate", square(0, 0))
        local items = nails(actor, 3)
        local op = {kind = "transfer", item = items[1], items = items, source = actor.inventory, destination = destination}
        local adapter = Native.new(actor)
        assert(adapter:begin(op))
        queues[actor].current:complete(function(value) return value ~= items[2] end)
        local done, _, code = adapter:poll()
        equal(done, false)
        equal(code, "refused")
        equal(adapter:transferResult(op, 701, "Base.Nails"), items[1])
        equal(adapter:transferResult(op, 702, "Base.Nails"), nil)
        equal(adapter:transferResult(op, 703, "Base.Nails"), items[3])
    end)
end)

case("What can no longer move is left out of a run; cancelling takes all of it off the queue", function()
    merging(function()
        local actor, destination = player(), container("crate", square(0, 0))
        local items = nails(actor, 4)
        put(items[3], container("elsewhere", square(0, 0)))
        local op = {kind = "transfer", item = items[1], items = items, source = actor.inventory, destination = destination}
        local adapter = Native.new(actor)
        assert(adapter:begin(op))
        equal(#queues[actor].queue, 3)
        local foreign = action(actor, "user action")
        ISTimedActionQueue.add(foreign)
        assert(adapter:cancel())
        equal(adapter:poll(), false)
        require("LootBox/Act").restore()
        equal(#queues[actor].queue, 1)
        equal(queues[actor].current, foreign)
        equal(foreign.cancellations, 0)
        equal(#destination.items, 0)
    end)
end)

case("Only items the game itself would merge count as light", function()
    for weight, light in pairs({[0.01] = true, [0.1] = true, [0.1004] = true, [0.101] = false, [1] = false}) do
        equal(Native.light({getWeight = function() return weight end}), light, tostring(weight))
    end
end)

print(tostring(passed) .. " native adapter boundary-double cases passed")
assert(#failures == 0, table.concat(failures, "\n"))
