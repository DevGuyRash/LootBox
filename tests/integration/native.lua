package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local modules = {
    "TimedActions/ISTimedActionQueue", "TimedActions/ISInventoryTransferUtil",
    "Vehicles/TimedActions/ISPathFindAction", "Vehicles/TimedActions/ISEnterVehicle",
    "Vehicles/TimedActions/ISExitVehicle", "Vehicles/TimedActions/ISSwitchVehicleSeat",
    "Vehicles/TimedActions/ISUnlockVehicleDoor", "Vehicles/TimedActions/ISOpenVehicleDoor",
    "Vehicles/TimedActions/ISCloseVehicleDoor", "Vehicles/TimedActions/ISLockDoors",
}
for _, name in ipairs(modules) do package.preload[name] = function() return true end end

local clock, client, allowTrash, requests, transfers, corpseQueries, queues, rehydrate, loadedSquares, nearestRequests, nearestChoice
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
    local value = { x = x, y = y, z = z or 0, reachable = true, worldObjects = {} }
    function value:getX() return self.x end
    function value:getY() return self.y end
    function value:getZ() return self.z end
    function value:canReachTo(other) return self.reachable and other.reachable end
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
    function value:isDead() return false end
    function value:isAsleep() return false end
    function value:getInventory() return self.inventory end
    function value:getCurrentSquare() return self.location end
    function value:getX() return self.location.x + 0.5 end
    function value:getY() return self.location.y + 0.5 end
    function value:getZ() return self.location.z end
    function value:getCharacterActions() return list(queues[self] and queues[self].queue or {}) end
    function value:getVehicle() return self.vehicle end
    function value:getPrimaryHandItem() return self.primary end
    function value:getSecondaryHandItem() return self.secondary end
    return value
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
    return action(character, "transfer", function()
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
            local square = character:getCurrentSquare()
            local object = { getSquare = function() return square end, getItem = function() return current end }
            current.world = object
            square.worldObjects[#square.worldObjects + 1] = object
        end
    end)
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
function ISPathFindAction:pathAdjacentToMultiTileObject(character, object)
    local target = object:getSquare()
    return self:pathToLocationF(character, target:getX() + 0.5, target:getY() + 0.5, target:getZ())
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
ISOpenVehicleDoor = { new = function(_, character, vehicle, part)
    return action(character, "open", function() part.door.open = true end)
end }
ISCloseVehicleDoor = { new = function(_, character, vehicle, part)
    return action(character, "close", function() part.door.open = false end)
end }
ISLockDoors = { new = function(_, character, vehicle, locked)
    return action(character, "unlockDoors", function() vehicle.driver.door.locked = locked end)
end }

getTimestampMs = function() return clock end
getCell = function()
    return {getGridSquare = function(_, x, y, z) return loadedSquares[x .. ":" .. y .. ":" .. z] end}
end
isClient = function() return client end
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
        function result:getInventoryItem() return true end
        function result:getDoor() return self.door end
        function result.door:isLocked() return self.locked end
        function result.door:isOpen() return self.open end
        return result
    end
    value.driver, value.trunk = part("DoorFrontLeft", false), part("TrunkDoor", true)
    function value:getSquare() return self.location end
    function value:isStopped() return not self.moving end
    function value:getPartCount() return 1 end
    function value:getPartByIndex() return { getItemContainer = function() return true end } end
    function value:getPassengerDoor() return self.driver end
    function value:getPartById(id) return id == "TrunkDoor" and self.trunk or nil end
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
    loadedSquares, nearestRequests, nearestChoice = {}, {}, 1
    local ok, err = pcall(run)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failures[#failures + 1] = name .. ": " .. tostring(err); print("FAIL " .. failures[#failures]) end
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
    queues[actor].current:reject()
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "rejected")
    equal(selected:getContainer(), actor.inventory)
    equal(adapter:isBusy(), false)
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
    equal(adapter:poll(), nil)
    clock = 2001
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
    equal(adapter:poll(), nil)
    clock = 2001
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

case("An item on an adjacent floor square is not completion at the chosen destination", function()
    local actor = player()
    local floor, adjacent = container("floor", actor:getCurrentSquare()), square(1, 0)
    local original = item(206, actor.inventory)
    local operation = { kind = "transfer", item = original, source = actor.inventory, destination = floor }
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    queues[actor]:onCompleted(queues[actor].current)
    put(original, nil)
    local other = item(206, floor)
    local world = { getSquare = function() return adjacent end, getItem = function() return other end }
    other.world = world
    adjacent.worldObjects[1] = world
    equal(adapter:poll(), nil)
    clock = 2001
    equal(adapter:poll(), false)
    equal(operation.resultItem, nil)
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
    equal(adapter:poll(), nil)
    clock = 2001
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "without the expected result")
    equal(selected:getContainer(), actor.inventory)
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
    equal(actor:getCurrentSquare():getX(), 8)
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
    assertRejected(Native.new(actor), { kind = "trash", container = bin, approved = { ["42"] = true } }, "TrashDeleteAll")
    equal(#requests, 0)
    equal(bin:getItems():size(), 1)
end)

case("A transfer timeout cancels owned work and reports the unchanged source", function()
    local actor, destination = player(), container("crate", square(0, 0))
    local selected = item(50, actor.inventory)
    local adapter = Native.new(actor)
    assert(adapter:begin({ kind = "transfer", item = selected, source = actor.inventory, destination = destination }))
    clock = 120001
    local done, reason = adapter:poll()
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

case("Begin refuses existing player actions without stopping the current action", function()
    local actor = player()
    local foreign = action(actor, "foreign")
    ISTimedActionQueue.add(foreign)
    local adapter = Native.new(actor)
    assertRejected(adapter, { kind = "approach", container = actor.inventory }, "current player action")
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
    clock, actor.location = 500, square(2, 0, 0)
    equal(adapter:poll(), nil)
    equal(operation.travel, nil)
    clock = 1500
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
        equal(adapter:poll(), nil)
        clock = 2101
        local done, reason = adapter:poll()
        equal(done, false, result)
        includes(reason, "expected result")
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

case("A foreign action interrupts walking without being cancelled or learned", function()
    local actor = player()
    local operation = {kind = "approach", location = {x = 5, y = 0, z = 1}}
    local adapter = Native.new(actor)
    assert(adapter:begin(operation))
    clock, actor.location = 500, square(2, 0, 0)
    equal(adapter:poll(), nil)
    local foreign = action(actor, "user action")
    queues[actor]:addToQueue(foreign)
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "player action")
    equal(operation.travel, nil)
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
        clock, actor.location = step * 30000, square(step * 10, 0)
        equal(adapter:poll(), nil)
        equal(adapter:isBusy(), true)
        equal(queues[actor].current, walking)
        equal(operation.travel, nil)
    end
    clock = 120000
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
    clock, actor.location = 30000, square(10, 0)
    equal(adapter:poll(), nil)
    clock = 89999
    equal(adapter:poll(), nil)
    clock = 90001
    local done, reason = adapter:poll()
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
    for step = 1, 19 do
        clock, actor.location = step * 30000, square(step * 10, 0)
        equal(adapter:poll(), nil)
    end
    clock, actor.location = 599999, square(200, 0)
    equal(adapter:poll(), nil)
    clock, actor.location = 600001, square(201, 0)
    local done, reason = adapter:poll()
    equal(done, false)
    includes(reason, "timed out")
    equal(adapter:isBusy(), false)
    equal(walking.stops, 1)
    equal(operation.travel, nil)
end)

print(tostring(passed) .. " native adapter boundary-double cases passed")
assert(#failures == 0, table.concat(failures, "\n"))
