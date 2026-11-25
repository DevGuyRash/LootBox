require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISInventoryTransferUtil"
require "Vehicles/TimedActions/ISPathFindAction"
require "Vehicles/TimedActions/ISEnterVehicle"
require "Vehicles/TimedActions/ISExitVehicle"
require "Vehicles/TimedActions/ISSwitchVehicleSeat"
require "Vehicles/TimedActions/ISUnlockVehicleDoor"
require "Vehicles/TimedActions/ISLockVehicleDoor"
require "Vehicles/TimedActions/ISOpenVehicleDoor"
require "Vehicles/TimedActions/ISCloseVehicleDoor"
require "Vehicles/TimedActions/ISLockDoors"
require "TimedActions/ISWearClothing"
require "TimedActions/ISClothingExtraAction"
require "TimedActions/ISEquipWeaponAction"
require "TimedActions/ISUnequipAction"

local Carry = require "LootBox/Carry"
local Log = require "LootBox/Log"

local Native = {}
Native.__index = Native

local WALK_IDLE_TIMEOUT, WALK_MAX_TIMEOUT = 60000, 600000
local timeouts = { approach = WALK_IDLE_TIMEOUT, transfer = 120000, trash = 15000, vehicle = 180000, gear = 180000 }

local function now()
    return getTimestampMs()
end

local function queueFor(self)
    return ISTimedActionQueue.getTimedActionQueue(self.player)
end

local function hasForeign(self, state)
    for _, action in ipairs(queueFor(self).queue) do
        if not state.owned[action] then return true end
    end
    return false
end

local function playerFlag(player, name, ...)
    local method = player and player[name]
    return method and method(player, ...) == true or false
end

local function manualMovement(player)
    return playerFlag(player, "pressedMovement", false) or playerFlag(player, "isPlayerMoving")
end

local function nearSquare(player, square)
    local current = player:getCurrentSquare()
    return current and square and current:getZ() == square:getZ()
        and math.abs(player:getX() - square:getX() - 0.5) <= 1.6
        and math.abs(player:getY() - square:getY() - 0.5) <= 1.6
        and current:canReachTo(square)
end

local function onSquare(player, square)
    local current = player:getCurrentSquare()
    return current and square and current:getX() == square:getX()
        and current:getY() == square:getY() and current:getZ() == square:getZ()
end

local function location(value)
    if type(value) ~= "table" then return nil end
    local result = {}
    for _, field in ipairs({ "x", "y", "z" }) do
        local coordinate = value[field]
        if type(coordinate) ~= "number" or coordinate ~= coordinate or math.abs(coordinate) > 2147483647
            or coordinate ~= math.floor(coordinate) then return nil end
        result[field] = coordinate
    end
    return result
end

local function approachLocations(op)
    if op.location == nil and op.locations == nil then return nil end
    if op.container or op.square or (op.location ~= nil and op.locations ~= nil) then
        return nil, "Choose one approach target"
    end
    if op.location ~= nil then
        local point = location(op.location)
        if not point then return nil, "Approach coordinates must be finite native integers" end
        return { point }
    end
    if type(op.locations) ~= "table" or #op.locations < 1 or #op.locations > 16 then
        return nil, "Choose between one and sixteen loaded frontier locations"
    end
    local count, result = 0, {}
    for index in pairs(op.locations) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #op.locations then
            return nil, "Frontier locations must form a dense list"
        end
        count = count + 1
    end
    if count ~= #op.locations then return nil, "Frontier locations must form a dense list" end
    for _, entry in ipairs(op.locations) do
        local point = location(entry)
        if not point then return nil, "Approach coordinates must be finite native integers" end
        if not getCell():getGridSquare(point.x, point.y, point.z) then
            return nil, "A frontier location is no longer loaded"
        end
        result[#result + 1] = point
    end
    return result
end

local function position(player)
    return { x = player:getX(), y = player:getY(), z = player:getZ() }
end

local function observeWalk(self, state)
    if not state.walking or state.cancelled or state.failure or state.stepStopped
        or state.action ~= state.walking then return end
    local point, stamp = position(self.player), now()
    local observation = state.walkObservation
    local previous = observation.to
    local dx, dy, dz = point.x - previous.x, point.y - previous.y, point.z - previous.z
    observation.distance = observation.distance + math.sqrt(dx * dx + dy * dy + dz * dz)
    observation.elapsedMs = observation.elapsedMs + math.max(0, stamp - state.walkStamp)
    observation.to, state.walkStamp = point, stamp
    if observation.distance - state.walkProgressDistance >= 0.05 then
        state.walkProgressDistance = observation.distance
        state.deadline = math.min(state.walkHardDeadline, stamp + WALK_IDLE_TIMEOUT)
    end
end

local function containerAnchor(player, container)
    local visited = {}
    while container and not visited[container] do
        visited[container] = true
        if container == player:getInventory() or container:getOutermostContainer() == player:getInventory()
            or container:isInCharacterInventory(player) then
            return { carried = true, container = container }
        end
        if container:isLockedToCharacter(player) then return nil end
        local item = container:getContainingItem()
        if item then
            local world = item:getWorldItem()
            if world and world:getSquare() then
                return { square = world:getSquare(), object = world, floorBag = true, container = container }
            end
            container = item:getContainer()
        else
            local object = container:getParent()
            return { container = container, object = object,
                square = object and object:getSquare() or container:getSourceGrid() }
        end
    end
end

local function containerReachable(player, container)
    local anchor = containerAnchor(player, container)
    if not anchor then return false end
    if anchor.carried then return true end
    local part = anchor.container:getVehiclePart()
    if part then return part:getVehicle():canAccessContainer(part:getIndex(), player) end
    return nearSquare(player, anchor.square)
end

local function trashObject(self, state)
    local container = state.op.container
    local object = container and container:getParent()
    if not object or not instanceof(object, "IsoObject") or object:getObjectIndex() < 0
        or object:getContainer() ~= container then
        return nil, "The selected trash can is no longer present"
    end
    local sprite = object:getSprite()
    if not sprite or not sprite:getProperties() or not sprite:getProperties():has("IsTrashCan") then
        return nil, "The destination is not a native trash can"
    end
    if isClient() and not getServerOptions():getBoolean("TrashDeleteAll") then
        return nil, "The server disables trash deletion (TrashDeleteAll)"
    end
    if isClient() and (not SafeHouse or not SafeHouse.isSafehouseAllowLoot
        or not SafeHouse.isSafehouseAllowLoot(object:getSquare(), self.player)) then
        return nil, "Safehouse permissions do not allow emptying this trash can"
    end
    if container:isLockedToCharacter(self.player) or not containerReachable(self.player, container) then
        return nil, "The trash can is locked or out of reach"
    end
    return object
end

local function sameItem(item, state)
    return item and item:getID() == state.itemId and tostring(item:getFullType()) == state.fullType
end

local function trashObserved(state)
    local object, container, square = state.trashObject, state.trashContainer, state.trashSquare
    if not object or not square then return false, "The sent trash operation has no stable destination" end
    if getCell():getGridSquare(square:getX(), square:getY(), square:getZ()) ~= square then return nil end
    if object:getObjectIndex() < 0 or object:getSquare() ~= square or object:getContainer() ~= container
        or container:getParent() ~= object or state.op.container ~= container then
        return false, "The trash can changed before the sent deletion could be confirmed"
    end
    for _, original in ipairs(state.trashItems) do
        local present = container:getItemWithID(original.itemId)
        if sameItem(present, original) then return nil end
    end
    return true
end

local function worldItem(square, state)
    if not square then return nil end
    local objects = square:getWorldObjects()
    for index = 0, objects:size() - 1 do
        local item = objects:get(index):getItem()
        if sameItem(item, state) then return item end
    end
end

local function transferred(self, state)
    local item = self:transferResult(state.op, state.itemId, state.fullType)
    if not item then return false end
    local op = state.op
    op.resultItem = item
    return true
end

local function freezeFloorDestinations(op, action)
    local point = op.destinationPoint
    local result = {}
    for dy = -1, 1 do
        for dx = -1, 1 do
            local square = getCell():getGridSquare(point.x + dx, point.y + dy, point.z)
            if square and action:canDropOnFloor(square) then
                result[#result + 1] = {x = point.x + dx, y = point.y + dy, z = point.z}
            end
        end
    end
    op.floorDestinations = result
end

local function restoreDescription(self, state)
    if state.op.kind ~= "vehicle" then return "" end
    local current = self.player:getVehicle()
    if state.originalVehicle == nil and current == state.op.vehicle then
        return "; you are still in the selected vehicle"
    end
    if current == state.originalVehicle and current and current:getSeat(self.player) ~= state.originalSeat then
        return "; your original vehicle seat could not be restored"
    end
    return ""
end

local function finish(self, state, success, reason, code)
    if success and state.op.kind == "approach" and state.walkObservation and not state.cancelled
        and not state.stepStopped and not state.yieldReason and not state.pathFailed then
        state.op.travel = state.walkObservation
    end
    self.active = nil
    if success then return true end
    return false, (reason or "The native action failed") .. restoreDescription(self, state), code
end

local function stopOwned(self, state)
    local queue = queueFor(self)
    local current = queue.current
    for index = #queue.queue, 1, -1 do
        local action = queue.queue[index]
        if state.owned[action] and action ~= current then
            action:forceCancel()
            queue:removeFromQueue(action)
        end
    end
    if current and state.owned[current] and current.action then current:forceStop() end
end

local function submit(self, state, action, check, nextPhase)
    if hasForeign(self, state) then return nil, "Another player action is queued" end
    local queue = queueFor(self)
    if #queue.queue > 0 then return nil, "The previous native action is still running" end
    local nativeStop = action.stop
    action.stop = function(stopped)
        local pending = {}
        local current = queue.current
        for _, candidate in ipairs(queue.queue) do
            if candidate ~= current and not state.owned[candidate] then
                pending[#pending + 1] = candidate
            end
        end
        state.stepYielded = state.stepYielded or #pending > 0 or manualMovement(self.player)
        -- Native stop resets its queue. Temporarily detach only foreign pending work.
        for _, candidate in ipairs(pending) do queue:removeFromQueue(candidate) end
        local ok, err = pcall(nativeStop, stopped)
        for _, candidate in ipairs(pending) do queue:addToQueue(candidate) end
        state.stepStopped = true
        if not ok then error(err) end
    end
    state.owned[action] = true
    state.action = action
    state.check = check
    state.nextPhase = nextPhase
    state.stepStopped = false
    state.stepYielded = false
    state.actionGoneAt = nil
    state.pathFailed = false
    ISTimedActionQueue.add(action)
    if queue:indexOf(action) < 0 then return nil, "The game refused to start the native action" end
    return true
end

local function submitPath(self, state, action, check, nextPhase)
    if not action then return nil, "No reachable approach is available" end
    action:setOnFail(function() state.pathFailed = true end)
    local accepted, reason = submit(self, state, action, check, nextPhase)
    if accepted and state.op.kind == "approach" then
        local point = position(self.player)
        state.walking, state.walkStamp = action, now()
        state.walkObservation = state.walkObservation or { from = point, to = point, distance = 0, elapsedMs = 0 }
        state.walkObservation.to = point
        state.walkProgressDistance = state.walkObservation.distance
        state.walkHardDeadline = state.walkHardDeadline or now() + WALK_MAX_TIMEOUT
    end
    return accepted, reason
end

local function observeAction(self, state)
    if not state.action then return true end
    if queueFor(self):indexOf(state.action) >= 0 then return nil end
    if state.check() then
        state.walking = nil
        state.action = nil
        state.phase = state.nextPhase
        return true
    end
    state.actionGoneAt = state.actionGoneAt or now()
    if state.stepStopped and state.op.kind == "transfer" and isClient()
        and now() - state.actionGoneAt < 2000 then return nil end
    if state.pathFailed then return false, "No path to the destination" end
    if state.stepStopped then
        if state.stepYielded then return false, "Waiting for your movement or queued action to finish", "yielded" end
        return false, "The game stopped the native action before completing it"
    end
    if now() - state.actionGoneAt < 2000 then return nil end
    return false, "The native action ended without the expected result"
end

local SEATED = "Get out of the vehicle to continue"

local function approach(self, state)
    local op = state.op
    if op.location ~= nil or op.locations ~= nil then
        local points, reason = approachLocations(op)
        if not points then return nil, reason end
        local arrived = op.exact and onSquare or nearSquare
        local function reached()
            for _, point in ipairs(points) do
                local square = getCell():getGridSquare(point.x, point.y, point.z)
                if square and arrived(self.player, square) then return true end
            end
            return false
        end
        if reached() then return true end
        if self.player:getVehicle() then return nil, SEATED, "seated" end
        local action
        if op.locations then
            local targets = {}
            for _, point in ipairs(points) do
                targets[#targets + 1], targets[#targets + 2], targets[#targets + 3] = point.x + 0.5, point.y + 0.5, point.z
            end
            action = ISPathFindAction:pathToNearest(self.player, targets)
        else
            local point = points[1]
            action = ISPathFindAction:pathToLocationF(self.player, point.x + 0.5, point.y + 0.5, point.z)
        end
        return submitPath(self, state, action, reached, "done")
    end
    if op.container then
        if containerReachable(self.player, op.container) then return true end
        local anchor = containerAnchor(self.player, op.container)
        if not anchor then return nil, "The container is locked or has no live outer location" end
        local part = anchor.container:getVehiclePart()
        if part then
            if self.player:getVehicle() then return nil, SEATED, "seated" end
            if not part:getArea() then return nil, "The vehicle storage has no native access area" end
            state.pathArrived = false
            local action = ISPathFindAction:pathToVehicleArea(self.player, part:getVehicle(), part:getArea())
            action:setOnComplete(function() state.pathArrived = true end)
            return submitPath(self, state, action, function() return state.pathArrived end, "access")
        end
        if self.player:getVehicle() then return nil, SEATED, "seated" end
        local object = anchor.object
        if anchor.floorBag then
            local square = anchor.square
            return submitPath(self, state,
                ISPathFindAction:pathToLocationF(self.player, square:getX() + 0.5, square:getY() + 0.5, square:getZ()),
                function() return containerReachable(self.player, op.container) end, "done")
        elseif object and anchor.square then
            return submitPath(self, state,
                ISPathFindAction:pathAdjacentToMultiTileObject(self.player, object, true),
                function() return containerReachable(self.player, op.container) end, "done")
        end
        return nil, "The source container has no reachable location"
    end
    if not op.square then return nil, "No approach location was supplied" end
    local arrived = op.exact and onSquare or nearSquare
    if arrived(self.player, op.square) then return true end
    if self.player:getVehicle() then return nil, SEATED, "seated" end
    return submitPath(self, state,
        ISPathFindAction:pathToLocationF(self.player, op.square:getX() + 0.5, op.square:getY() + 0.5, op.square:getZ()),
        function() return arrived(self.player, op.square) end, "done")
end

-- The operation remembers what it unlocked so the owner can lock it again afterwards.
local function unlock(self, state, vehicle, part, nextPhase)
    state.op.unlocked = state.op.unlocked or {}
    table.insert(state.op.unlocked, {vehicle = vehicle, partId = part:getId()})
    return submit(self, state, ISUnlockVehicleDoor:new(self.player, part),
        function() return not part:getDoor():isLocked() end, nextPhase)
end

local function approachAccess(self, state, container, arrivedPhase)
    container = container or state.op.container
    if containerReachable(self.player, container) then state.phase = arrivedPhase or "done"; return true end
    local anchor = containerAnchor(self.player, container)
    local part = anchor and anchor.container:getVehiclePart()
    if not part then return nil, "The container is no longer reachable" end
    local vehicle = part:getVehicle()
    if not vehicle:isStopped() then return nil, "The selected vehicle must remain parked" end
    local doorPart
    local seat = part:getContainerSeatNumber()
    if seat >= 0 then
        if vehicle:getCharacter(seat) then return nil, "The destination seat is occupied" end
        doorPart = vehicle:getPassengerDoor(seat)
    elseif part:getId() == "GloveBox" then
        doorPart = vehicle:getPartById("DoorFrontRight")
    elseif part:getId() == "TruckBed" then
        doorPart = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear") or vehicle:getPartById("TrunkDoorOpened")
    elseif part:getDoor() then
        doorPart = part
    end
    if doorPart and doorPart:getInventoryItem() and doorPart:getDoor() then
        local door = doorPart:getDoor()
        if door:isLocked() then
            if not vehicle:canUnlockDoor(doorPart, self.player) then return nil, "The storage door is locked; prepare the remembered vehicle first" end
            return unlock(self, state, vehicle, doorPart, "access")
        end
        if not door:isOpen() then
            return submit(self, state, ISOpenVehicleDoor:new(self.player, vehicle, doorPart),
                function() return door:isOpen() end, "access")
        end
    end
    return nil, "The native vehicle rules do not permit access to this storage part"
end

local function vehicleChanged(self, state)
    local vehicle = state.op.vehicle
    if not vehicle:getSquare() then return "The selected vehicle is no longer loaded" end
    if not vehicle:isStopped() then return "The selected vehicle must remain parked" end
    local current = self.player:getVehicle()
    if current and current ~= vehicle then return "You entered a different vehicle" end
end

local function driverDoor(vehicle)
    local part = vehicle:getPassengerDoor(0)
    return part and part:getInventoryItem() and part:getDoor() and part or nil
end

local function openDriverDoor(self, state, nextPhase)
    local vehicle = state.op.vehicle
    local part = driverDoor(vehicle)
    if part and not part:getDoor():isOpen() then
        return submit(self, state, ISOpenVehicleDoor:new(self.player, vehicle, part),
            function() return part:getDoor():isOpen() end, nextPhase)
    end
    state.phase = nextPhase
    return true
end

local function closeDriverDoor(self, state, nextPhase)
    local vehicle = state.op.vehicle
    local part = driverDoor(vehicle)
    if part and not state.driverDoorWasOpen and part:getDoor():isOpen() then
        return submit(self, state, ISCloseVehicleDoor:new(self.player, vehicle, part),
            function() return not part:getDoor():isOpen() end, nextPhase)
    end
    state.phase = nextPhase
    return true
end

-- Locks the parts in op.relock. Parts that refuse a lock from outside are locked
-- from the driver seat first; the driver door is always last, from outside, because
-- a locked one would trap the exit.
local function relockStep(self, state)
    local vehicle, player = state.op.vehicle, self.player
    local inside, driver = player:getVehicle() == vehicle, driverDoor(vehicle)
    local ready, refused = nil, false
    for _, partId in ipairs(state.op.relock) do
        local part = vehicle:getPartById(partId)
        local door = part and part:getInventoryItem() and part:getDoor()
        if door and not door:isLocked() and not door:isLockBroken()
            and not (inside and part == driver and state.originalVehicle ~= vehicle) then
            if vehicle:canLockDoor(part, player) then ready = ready or part
            elseif part ~= driver then refused = true end
        end
    end
    if refused and not inside and not state.lockedInside then return nil, "seat" end
    if not ready then
        state.lockedInside = state.lockedInside or inside
        state.phase = "restore"
        return true
    end
    local door = ready:getDoor()
    if not inside and not state.atVehicle and ready:getArea() and not vehicle:isInArea(ready:getArea(), player) then
        local action = ISPathFindAction:pathToVehicleArea(player, vehicle, ready:getArea())
        action:setOnComplete(function() state.atVehicle = true end)
        return submitPath(self, state, action, function() return state.atVehicle == true end, "relock")
    elseif door:isOpen() then
        return submit(self, state, ISCloseVehicleDoor:new(player, vehicle, ready), function() return not door:isOpen() end, "relock")
    end
    return submit(self, state, ISLockVehicleDoor:new(player, ready), function() return door:isLocked() end, "relock")
end

local function vehicleStep(self, state)
    local vehicle = state.op.vehicle
    local changed = vehicleChanged(self, state)
    if changed then return nil, changed end
    local current = self.player:getVehicle()
    if state.phase == "prepare" then
        local hasStorage = false
        for index = 0, vehicle:getPartCount() - 1 do
            if vehicle:getPartByIndex(index):getItemContainer() then hasStorage = true end
        end
        if not hasStorage then return nil, "The selected vehicle has no item storage" end
        if state.op.relock then
            local accepted, reason = relockStep(self, state)
            if accepted or reason ~= "seat" then return accepted, reason end
        elseif not vehicle:isAnyDoorLocked() and not vehicle:isTrunkLocked() then state.phase = "restore"; return true end
        local seated = state.op.relock and "relock" or "unlockDoors"
        if current == vehicle then
            if vehicle:getSeat(self.player) == 0 then state.phase = seated; return true end
            if vehicle:isSeatOccupied(0) or not vehicle:canSwitchSeat(vehicle:getSeat(self.player), 0) then
                return nil, "The driver seat is unavailable for unlocking storage"
            end
            return submit(self, state, ISSwitchVehicleSeat:new(self.player, 0),
                function() return self.player:getVehicle() == vehicle and vehicle:getSeat(self.player) == 0 end, seated)
        end
        if not vehicle:isSeatInstalled(0) or vehicle:isSeatOccupied(0)
            or not vehicle:getPassengerPosition(0, "outside") or vehicle:isEnterBlocked(self.player, 0) then
            return nil, "The driver seat is occupied, removed, or blocked"
        end
        local part = driverDoor(vehicle)
        if part and part:getDoor():isLocked() and not vehicle:canUnlockDoor(part, self.player) then
            return nil, "The driver door is locked and you cannot unlock it"
        end
        local primary, secondary = self.player:getPrimaryHandItem(), self.player:getSecondaryHandItem()
        if (primary and primary:hasTag(ItemTag.HEAVY_ITEM)) or (secondary and secondary:hasTag(ItemTag.HEAVY_ITEM)) then
            return nil, "Put down the held heavy item before entering the vehicle"
        end
        state.pathArrived = false
        local action = ISPathFindAction:pathToVehicleSeat(self.player, vehicle, 0)
        action:setOnComplete(function() state.pathArrived = true end)
        return submitPath(self, state, action, function() return state.pathArrived end, "driverUnlock")
    elseif state.phase == "driverUnlock" then
        local part = driverDoor(vehicle)
        if part and part:getDoor():isLocked() then
            if not vehicle:canUnlockDoor(part, self.player) then return nil, "You cannot unlock the driver door" end
            return unlock(self, state, vehicle, part, "driverOpen")
        end
        state.phase = "driverOpen"
    elseif state.phase == "driverOpen" then
        return openDriverDoor(self, state, "enter")
    elseif state.phase == "enter" then
        if vehicle:isSeatOccupied(0) then return nil, "The driver seat became occupied" end
        return submit(self, state, ISEnterVehicle:new(self.player, vehicle, 0),
            function() return self.player:getVehicle() == vehicle and vehicle:getSeat(self.player) == 0 end, "closeEntry")
    elseif state.phase == "closeEntry" then
        return closeDriverDoor(self, state, state.op.relock and "relock" or "unlockDoors")
    elseif state.phase == "relock" then
        local accepted, reason = relockStep(self, state)
        if reason == "seat" then return nil, "A vehicle door cannot be locked from here" end
        return accepted, reason
    elseif state.phase == "unlockDoors" then
        if current ~= vehicle or vehicle:getSeat(self.player) ~= 0 then return nil, "The driver seat is no longer available" end
        if vehicle:isAnyDoorLocked() then
            state.op.unlocked = state.op.unlocked or {}
            for seat = 0, vehicle:getMaxPassengers() - 1 do
                local part = vehicle:getPassengerDoor(seat)
                if part and part:getDoor() and part:getDoor():isLocked() then
                    table.insert(state.op.unlocked, {vehicle = vehicle, partId = part:getId()})
                end
            end
            return submit(self, state, ISLockDoors:new(self.player, vehicle, false),
                function() return not vehicle:isAnyDoorLocked() end, "unlockTrunk")
        end
        state.phase = "unlockTrunk"
    elseif state.phase == "unlockTrunk" then
        local part = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear") or vehicle:getPartById("TrunkDoorOpened")
        if part and part:getDoor() and part:getDoor():isLocked() then
            return unlock(self, state, vehicle, part, "restore")
        end
        if vehicle:isTrunkLocked() then return nil, "The vehicle's trunk cannot be unlocked through native door actions" end
        state.phase = "restore"
    elseif state.phase == "restore" then
        if state.originalVehicle == nil and current == vehicle then
            if vehicle:isExitBlocked(self.player, vehicle:getSeat(self.player)) then return nil, "The vehicle exit is blocked" end
            vehicle:updateHasExtendOffsetForExit(self.player)
            return openDriverDoor(self, state, "exit")
        end
        if state.originalVehicle == nil and current == nil then return closeDriverDoor(self, state, "done") end
        if current == vehicle and vehicle:getSeat(self.player) ~= state.originalSeat then
            local seat = vehicle:getSeat(self.player)
            if vehicle:isSeatOccupied(state.originalSeat) or not vehicle:canSwitchSeat(seat, state.originalSeat) then
                return nil, "Your original vehicle seat became unavailable"
            end
            return submit(self, state, ISSwitchVehicleSeat:new(self.player, state.originalSeat),
                function() return self.player:getVehicle() == vehicle and vehicle:getSeat(self.player) == state.originalSeat end, "done")
        end
        state.phase = "done"
    elseif state.phase == "exit" then
        if current ~= vehicle then return nil, "The vehicle changed before exit" end
        return submit(self, state, ISExitVehicle:new(self.player),
            function() return self.player:getVehicle() == nil end, "closeExit")
    elseif state.phase == "closeExit" then
        return closeDriverDoor(self, state, state.op.relock and "relock" or "done")
    end
    return true
end

local function gearResult(self, state)
    local op, player = state.op, self.player
    if op.mode == "wear" and not state.slot then
        local target = op.variant and Carry.prototype(op.variant) or op.item
        state.slot = Carry.slot(player, op.slot or Carry.wornSlot(target))
        if not state.slot then return false end
    end
    local item = op.resultItem or player:getInventory():getItemWithID(state.itemId)
    if op.variant then
        if not op.gearIdentity.conversionDispatched then return false end
        if player:getInventory():containsID(state.itemId) then return false end
        item = nil
        local worn = player:getWornItems()
        for index = 0, worn:size() - 1 do
            local entry, current = worn:get(index), worn:get(index):getItem()
            if entry:getLocation() == state.slot and tostring(current:getFullType()) == op.variant
                and not state.previousIds[tostring(current:getID())] then item = current; break end
        end
        if not item then return false end
        local contents = item:getInventory()
        if contents:getItems():size() ~= #state.contents then return false end
        for _, original in ipairs(state.contents) do
            local present = contents:getItemWithID(original.id)
            if not present or tostring(present:getFullType()) ~= original.fullType then return false end
        end
    elseif not sameItem(item, state) then return false end
    local complete = op.mode == "unequip" and not player:isEquipped(item)
        or op.mode == "wear" and Carry.wornAt(player, state.slot, item) == item
        or op.mode == "primary" and player:getPrimaryHandItem() == item and (not op.twoHands or player:getSecondaryHandItem() == item)
        or op.mode == "secondary" and player:getSecondaryHandItem() == item and (not op.twoHands or player:getPrimaryHandItem() == item)
    if complete then op.resultItem = item end
    return complete
end

local function gearStep(self, state)
    local op, player = state.op, self.player
    if gearResult(self, state) then state.phase = "done"; return true end
    local main = player:getInventory()
    local item = main:getItemWithID(state.itemId)
    if not sameItem(item, state) then item = op.source and op.source:getItemWithID(state.itemId) end
    if not sameItem(item, state) then return nil, "The selected gear is no longer in its source" end
    if op.mode == "wear" then
        local target = op.variant and Carry.prototype(op.variant) or item
        if not target then return nil, "The native gear variant is unavailable" end
        local declared = Carry.wornSlot(target)
        if not declared or tostring(declared) ~= tostring(op.slot or declared) then return nil, "The native worn location changed" end
        local available, slot = Carry.slotAvailable(player, declared, item)
        if not available then return nil, "The worn location is occupied or conflicts with existing gear" end
        state.slot = slot
        if ItemTag and ItemTag.REPLACE_PRIMARY and target:hasTag(ItemTag.REPLACE_PRIMARY) then
            return nil, "This gear would replace your primary hand item"
        end
        if op.variant then
            if not item:IsInventoryContainer() or not target:IsInventoryContainer()
                or not Carry.permittedVariant(item, op.variant) then return nil, "This is not a declared native bag variant" end
            if item:getContentsWeight() > target:getInventory():getEffectiveCapacity(player) then
                return nil, "The native bag variant is too small for its existing contents"
            end
        end
    elseif op.mode == "primary" or op.mode == "secondary" then
        if not Carry.handAvailable(player, op.mode, item) then return nil, "Your hand equipment changed; existing gear was retained" end
        if op.twoHands and (not Carry.handAvailable(player, "primary", item) or not Carry.handAvailable(player, "secondary", item)) then
            return nil, "Both hands must remain free to restore this item"
        end
    elseif op.mode ~= "unequip" then return nil, "Choose a native gear action" end
    if item:getContainer() ~= main then
        if op.mode == "unequip" then return nil, "The gear to remove is no longer carried directly" end
        local source = item:getContainer()
        if not source or not source:isRemoveItemAllowed(item) or source:isLockedToCharacter(player)
            or not main:isItemAllowed(item) or main:isInside(item) then return nil, "The native container rules refuse this gear" end
        if not containerReachable(player, source) then
            local anchor = containerAnchor(player, source)
            if player:getVehicle() then return nil, SEATED, "seated" end
            if not anchor or not anchor.square then return nil, "The gear source is unreachable" end
            local part = anchor.container:getVehiclePart()
            if part then
                if state.phase == "access" then return approachAccess(self, state, source, "prepare") end
                if not part:getArea() then return nil, "The gear source has no native vehicle access area" end
                state.gearPathArrived = false
                local action = ISPathFindAction:pathToVehicleArea(player, part:getVehicle(), part:getArea())
                action:setOnComplete(function() state.gearPathArrived = true end)
                return submitPath(self, state, action, function() return state.gearPathArrived end, "access")
            end
            local point = anchor.square
            local action
            if anchor.object and not anchor.floorBag then
                action = ISPathFindAction:pathAdjacentToMultiTileObject(player, anchor.object, true)
            else action = ISPathFindAction:pathToLocationF(player, point:getX() + 0.5, point:getY() + 0.5, point:getZ()) end
            return submitPath(self, state,
                action,
                function() return containerReachable(player, source) end, "prepare")
        end
        local anchor = containerAnchor(player, source)
        if isClient() and anchor and not anchor.carried and (not SafeHouse
            or not SafeHouse.isSafehouseAllowLoot or not SafeHouse.isSafehouseAllowLoot(anchor.square, player)) then
            return nil, "Safehouse permissions do not allow taking this gear"
        end
        if not main:hasRoomFor(player, item) then return nil, "The native hard carrying limit prevents taking this bag", "capacity" end
        return submit(self, state, ISInventoryTransferUtil.newInventoryTransferAction(player, item, source, main),
            function()
                local present = main:getItemWithID(state.itemId)
                return sameItem(present, state) and present:getContainer() == main
            end, "prepare")
    end
    if op.mode == "unequip" then
        if item:isForceDropHeavyItem() then return nil, "Put down the held heavy item manually before staging it" end
        return submit(self, state, ISUnequipAction:new(player, item, 50), function() return gearResult(self, state) end, "done")
    elseif op.mode == "wear" then
        if op.variant then
            local contents = item:getInventory():getItems()
            state.contents = {}
            for index = 0, contents:size() - 1 do
                local child = contents:get(index)
                state.contents[#state.contents + 1] = {id = child:getID(), fullType = tostring(child:getFullType())}
            end
            local accepted, reason = submit(self, state, ISClothingExtraAction:new(player, item, op.variant), function() return gearResult(self, state) end, "done")
            if accepted then op.gearIdentity.conversionDispatched = true end
            return accepted, reason
        end
        return submit(self, state, ISWearClothing:new(player, item), function() return gearResult(self, state) end, "done")
    end
    return submit(self, state, ISEquipWeaponAction:new(player, item, 50, op.mode == "primary", op.twoHands == true),
        function() return gearResult(self, state) end, "done")
end

function Native.new(player)
    return setmetatable({ player = player }, Native)
end

function Native:isBusy()
    return self.active ~= nil
end

function Native:transferResult(op, itemId, fullType)
    if not op or (op.source and op.source == op.destination) then return nil end
    local identity = {itemId = itemId, fullType = fullType}
    if op.sourcePoint then
        local point = location(op.sourcePoint)
        if not point then return nil end
        local square = getCell():getGridSquare(point.x, point.y, point.z)
        if not square or worldItem(square, identity) then return nil end
    elseif not op.source or op.source:containsID(itemId) then return nil end
    if op.destinationPoint then
        local origin = location(op.destinationPoint)
        if not origin then return nil end
        local points = op.floorDestinations or {origin}
        for _, candidate in ipairs(points) do
            local point = location(candidate)
            if point and point.z == origin.z and math.abs(point.x - origin.x) <= 1 and math.abs(point.y - origin.y) <= 1 then
                local item = worldItem(getCell():getGridSquare(point.x, point.y, point.z), identity)
                if item then return item end
            end
        end
        return nil
    end
    local item = op.destination and op.destination:getItemWithID(itemId)
    return sameItem(item, identity) and item or nil
end

function Native:isPlayerBusy()
    if not self.player then return false end
    if self.active then return hasForeign(self, self.active) end
    return playerFlag(self.player, "pressedMovement", false) or #queueFor(self).queue > 0
        or not self.player:getCharacterActions():isEmpty()
end

-- Returns what the player was told, "combat" when it was a fight, and the trigger for the log.
function Native:takeoverReason()
    local player = self.player
    if not player then return "The player is no longer available", nil, "no-player" end
    if playerFlag(player, "isDead") then return "The player died", nil, "death" end
    if playerFlag(player, "isAsleep") then return "Sleeping stopped the job", nil, "sleep" end
    if playerFlag(player, "pressedAim") or playerFlag(player, "isAiming") then
        return "Aiming paused the job", "combat", "aim"
    end
    if playerFlag(player, "isAttacking") or playerFlag(player, "isPerformingShoveAnimation") then
        return "Attacking or shoving paused the job", "combat", playerFlag(player, "isAttacking") and "attack" or "shove"
    end
    if playerFlag(player, "pressedMovement", false)
        and (playerFlag(player, "isRunning") or playerFlag(player, "isSprinting")) then
        return "Running or sprinting stopped the job", nil, "run"
    end
end

-- True when the player can already use this container without walking.
function Native:reachable(container)
    local ok, reachable = pcall(containerReachable, self.player, container)
    if ok then return reachable == true end
    Log.fault(self.interaction, "Native.reachable", reachable)
    return false
end

-- Deadlines are wall clock, but a paused game runs no ticks.
function Native:extend(milliseconds)
    local state = self.active
    if not state then return end
    for _, field in ipairs({"deadline", "walkHardDeadline", "walkStamp", "actionGoneAt"}) do
        if state[field] then state[field] = state[field] + milliseconds end
    end
end

function Native:begin(op)
    if self.active then return nil, "A native operation is already running" end
    if not self.player or self.player:isDead() or self.player:isAsleep() then return nil, "The player cannot act" end
    if type(op) ~= "table" or not timeouts[op.kind] then return nil, "Unknown native operation" end
    if self:isPlayerBusy() then
        return nil, "Waiting for your current action to finish", "busy"
    end
    local state = { op = op, owned = {}, deadline = now() + timeouts[op.kind], phase = "prepare" }
    self.active = state
    local ok, result, reason, code = pcall(function()
        if op.kind == "approach" then
            op.travel = nil
            local accepted, err, code = approach(self, state)
            if accepted and not state.action then state.phase = "done" end
            return accepted, err, code
        elseif op.kind == "transfer" then
            if not op.item or not op.source or not op.destination then return nil, "A transfer needs an item, source, and destination" end
            op.resultItem = nil
            state.itemId, state.fullType = op.item:getID(), tostring(op.item:getFullType())
            local world = op.item:getWorldItem()
            if op.source:getType() == "floor" and world and not op.sourcePoint then
                local square = world:getSquare()
                op.sourcePoint = {x = square:getX(), y = square:getY(), z = square:getZ()}
            end
            if op.destination:getType() == "floor" then
                if not op.destinationPoint then
                    local square = self.player:getCurrentSquare()
                    if not square then return nil, "The destination floor is no longer loaded" end
                    op.destinationPoint = {x = square:getX(), y = square:getY(), z = square:getZ()}
                end
                local point = location(op.destinationPoint)
                if not point then return nil, "The destination floor coordinates are invalid" end
                state.destinationSquare = getCell():getGridSquare(point.x, point.y, point.z)
                if not state.destinationSquare then return nil, "The destination floor is no longer loaded" end
            end
            if transferred(self, state) then state.phase = "done"; return true end
            if state.destinationSquare and not onSquare(self.player, state.destinationSquare) then
                return nil, "Return to the selected floor location before placing this item"
            end
            local current = op.source:getItemWithID(state.itemId)
            if not sameItem(current, state) then return nil, "The item is no longer in its selected source" end
            op.item = current
            if ISInventoryTransferUtil.isCharacterGrabbingCorpseItem(self.player, op.item, op.source, op.destination)
                or op.item:isHumanCorpse() then
                return nil, "Human corpse hauling is not supported by this item job"
            end
            if op.source == op.destination or op.item:getContainer() ~= op.source or not op.source:contains(op.item) then
                return nil, "The item is no longer in its selected source"
            end
            if op.source:getType() == "floor" then
                local world = op.item:getWorldItem()
                if not world or not nearSquare(self.player, world:getSquare()) then return nil, "The floor item is out of reach" end
            elseif not containerReachable(self.player, op.source) then return nil, "The source is out of reach" end
            if not containerReachable(self.player, op.destination) and op.destination:getType() ~= "floor" then return nil, "The destination is out of reach" end
            if op.destination:getType() ~= "floor" and not op.destination:hasRoomFor(self.player, op.item) then return nil, "The destination is full", "capacity" end
            if op.destination:isOccupiedVehicleSeat() then return nil, "The destination vehicle seat is occupied" end
            if not op.source:isRemoveItemAllowed(op.item) or not op.destination:isItemAllowed(op.item) or op.destination:isInside(op.item) then
                return nil, "The native container rules refuse this item"
            end
            local action = ISInventoryTransferUtil.newInventoryTransferAction(self.player, op.item, op.source, op.destination)
            if op.destinationPoint then freezeFloorDestinations(op, action) end
            return submit(self, state, action, function() return transferred(self, state) end, "done")
        elseif op.kind == "gear" then
            if not op.item then return nil, "Choose an item to equip or remove" end
            state.itemId, state.fullType = op.item:getID(), tostring(op.item:getFullType())
            if not op.gearIdentity then
                op.gearIdentity = {previousIds = {}, contents = {}}
                local items = self.player:getInventory():getItems()
                for index = 0, items:size() - 1 do op.gearIdentity.previousIds[tostring(items:get(index):getID())] = true end
                if op.variant and op.item:IsInventoryContainer() then
                    local contents = op.item:getInventory():getItems()
                    for index = 0, contents:size() - 1 do
                        local child = contents:get(index)
                        op.gearIdentity.contents[#op.gearIdentity.contents + 1] = {id = child:getID(), fullType = tostring(child:getFullType())}
                    end
                end
            end
            state.previousIds, state.contents = op.gearIdentity.previousIds, op.gearIdentity.contents
            return gearStep(self, state)
        elseif op.kind == "trash" then
            local object, err = trashObject(self, state)
            if not object then return nil, err end
            local items = op.container:getItems()
            for index = 0, items:size() - 1 do
                if not op.approved or not op.approved[tostring(items:get(index):getID())] then
                    return nil, "The trash can contains an item outside the approved cleanup"
                end
            end
            if items:isEmpty() then state.phase = "done"; return true end
            state.trashObject, state.trashContainer, state.trashSquare = object, op.container, object:getSquare()
            state.trashItems = {}
            for index = 0, items:size() - 1 do
                local item = items:get(index)
                state.trashItems[#state.trashItems + 1] = {itemId = item:getID(), fullType = tostring(item:getFullType())}
            end
            sendClientCommand(self.player, "object", "emptyTrash", {
                x = object:getX(), y = object:getY(), z = object:getZ(), index = object:getObjectIndex()
            })
            state.phase = "trashPending"
            return true
        elseif op.kind == "vehicle" then
            if not op.vehicle then return nil, "No vehicle was selected" end
            local origin = op.vehicleOrigin
            if origin and origin.target ~= op.vehicle then return nil, "The selected vehicle changed during this operation" end
            if not origin then
                local vehicle = self.player:getVehicle()
                if vehicle and vehicle ~= op.vehicle then return nil, "Exit your current vehicle first" end
                local part = driverDoor(op.vehicle)
                origin = {target = op.vehicle, vehicle = vehicle, seat = vehicle and vehicle:getSeat(self.player),
                    driverDoorWasOpen = part and part:getDoor():isOpen() or false}
                op.vehicleOrigin = origin
            end
            state.originalVehicle = origin.vehicle
            if state.originalVehicle and state.originalVehicle ~= op.vehicle then return nil, "Exit your current vehicle first" end
            state.originalSeat, state.driverDoorWasOpen = origin.seat, origin.driverDoorWasOpen
            return vehicleStep(self, state)
        end
    end)
    if not ok then Log.fault(self.interaction, "Native.begin:" .. op.kind, result, "trace", reason) end
    if not ok or not result then
        stopOwned(self, state)
        self.active = nil
        return nil, ok and reason or tostring(result), ok and code or nil
    end
    return true
end

function Native:cancel(op)
    local state = self.active
    if not state and op and op.kind == "vehicle" and op.vehicleOrigin then
        local origin = op.vehicleOrigin
        if origin.target ~= op.vehicle then return false, "The selected vehicle changed before restoration" end
        state = {op = op, owned = {}, phase = "restore", deadline = now() + 30000,
            originalVehicle = origin.vehicle, originalSeat = origin.seat, driverDoorWasOpen = origin.driverDoorWasOpen}
        self.active = state
    end
    if not state then return true end
    state.cancelled = true
    state.failure = state.failure or "Cancelled"
    local ok, err = pcall(stopOwned, self, state)
    if not ok then Log.fault(self.interaction, "Native.stopOwned", err) end
    if not ok then return false, "Could not stop the owned native action: " .. tostring(err) end
    return true
end

local function poll(self, state)
    if state.op.kind == "trash" and state.phase == "trashPending" then
        local observed, reason = trashObserved(state)
        if observed then return finish(self, state, true) end
        if observed == false then return finish(self, state, false, reason) end
        if now() > state.deadline then
            return finish(self, state, false, (state.failure and state.failure .. "; " or "")
                .. "The sent trash deletion could not be confirmed before timeout")
        end
        return nil
    end
    if self.player:isDead() then return finish(self, state, false, "The player died") end
    if now() > state.deadline then
        state.failure = state.failure or "The native operation timed out"
        stopOwned(self, state)
    end
    local foreign = hasForeign(self, state)
    if foreign and state.op.kind ~= "trash" then
        if not state.cancelled and not state.failure then
            state.yieldReason = "Waiting for your queued action to finish"
        end
        stopOwned(self, state)
    end
    if not foreign then observeWalk(self, state) end
    local observed, reason, code = observeAction(self, state)
    if observed == nil then return nil end
    if observed and state.phase == "done" and (not state.failure or state.op.kind ~= "vehicle") then
        return finish(self, state, true)
    end
    if not state.cancelled and not state.failure and not state.pathFailed
        and (state.yieldReason or code == "yielded") then
        return finish(self, state, false, state.yieldReason or reason, "yielded")
    end
    if observed == false then
        state.failure = state.failure or reason
        state.action = nil
    end
    if state.failure then
        if state.op.kind ~= "vehicle" then return finish(self, state, false, state.failure) end
        if foreign then return nil end
        if not state.restoring then
            state.restoring = true
            state.phase = "restore"
            state.action = nil
            state.deadline = now() + 30000
        elseif observed == false then
            return finish(self, state, false, state.failure .. "; restoration failed: " .. reason)
        end
    end
    if state.phase == "done" then return finish(self, state, not state.failure, state.failure) end
    if state.op.kind == "approach" and state.phase == "access" then
        local accepted, err = approachAccess(self, state)
        if not accepted then return finish(self, state, false, err) end
        if state.phase == "done" then return finish(self, state, true) end
        return nil
    end
    if state.op.kind == "trash" then
        local object, err = trashObject(self, state)
        if not object then return finish(self, state, false, err) end
        if state.op.container:isEmpty() then return finish(self, state, true) end
        return nil
    end
    if state.op.kind == "vehicle" then
        local accepted, err = vehicleStep(self, state)
        if not accepted then
            if state.restoring then return finish(self, state, false, (state.failure or err) .. "; restoration blocked: " .. err) end
            state.failure = err
            return nil
        end
        if state.phase == "done" then return finish(self, state, not state.failure, state.failure) end
        return nil
    end
    if state.op.kind == "gear" then
        local accepted, err, code = gearStep(self, state)
        if not accepted then return finish(self, state, false, err, code) end
        if state.phase == "done" then return finish(self, state, true) end
        return nil
    end
    return finish(self, state, false, "The native operation has no completion state")
end

function Native:poll()
    local state = self.active
    if not state then return true end
    local ok, result, reason, code = pcall(poll, self, state)
    if ok then return result, reason, code end
    Log.fault(self.interaction, "Native.poll:" .. state.op.kind, result, "trace", reason)
    local stopped, problem = pcall(stopOwned, self, state)
    if not stopped then Log.fault(self.interaction, "Native.stopOwned", problem) end
    return finish(self, state, false, "Native operation error: " .. tostring(result))
end

return Native
