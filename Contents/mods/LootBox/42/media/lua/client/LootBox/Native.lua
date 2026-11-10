require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISInventoryTransferUtil"
require "Vehicles/TimedActions/ISPathFindAction"
require "Vehicles/TimedActions/ISEnterVehicle"
require "Vehicles/TimedActions/ISExitVehicle"
require "Vehicles/TimedActions/ISSwitchVehicleSeat"
require "Vehicles/TimedActions/ISUnlockVehicleDoor"
require "Vehicles/TimedActions/ISOpenVehicleDoor"
require "Vehicles/TimedActions/ISCloseVehicleDoor"
require "Vehicles/TimedActions/ISLockDoors"

local Native = {}
Native.__index = Native

local timeouts = { approach = 60000, transfer = 120000, trash = 15000, vehicle = 180000 }

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

local function worldItem(square, state)
    if not square then return nil end
    local objects = square:getWorldObjects()
    for index = 0, objects:size() - 1 do
        local item = objects:get(index):getItem()
        if sameItem(item, state) then return item end
    end
end

local function transferred(state)
    local op = state.op
    if op.source == op.destination then return false end
    if state.sourceSquare then
        if worldItem(state.sourceSquare, state) then return false end
    elseif op.source:containsID(state.itemId) then return false end
    local item
    if state.destinationSquare then item = worldItem(state.destinationSquare, state)
    else item = op.destination:getItemWithID(state.itemId) end
    if not sameItem(item, state) then return false end
    op.resultItem = item
    return true
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

local function finish(self, state, success, reason)
    self.active = nil
    if success then return true end
    return false, (reason or "The native action failed") .. restoreDescription(self, state)
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
    state.actionGoneAt = nil
    state.pathFailed = false
    ISTimedActionQueue.add(action)
    if queue:indexOf(action) < 0 then return nil, "The game refused to start the native action" end
    return true
end

local function submitPath(self, state, action, check, nextPhase)
    if not action then return nil, "No reachable approach is available" end
    action:setOnFail(function() state.pathFailed = true end)
    return submit(self, state, action, check, nextPhase)
end

local function observeAction(self, state)
    if not state.action then return true end
    if queueFor(self):indexOf(state.action) >= 0 then return nil end
    if state.pathFailed then return false, "No path to the destination" end
    if state.stepStopped then return false, "The native action was interrupted or rejected" end
    if state.check() then
        state.action = nil
        state.phase = state.nextPhase
        return true
    end
    state.actionGoneAt = state.actionGoneAt or now()
    if now() - state.actionGoneAt < 2000 then return nil end
    return false, "The native action ended without the expected result"
end

local function approach(self, state)
    local op = state.op
    if op.container then
        if containerReachable(self.player, op.container) then return true end
        local anchor = containerAnchor(self.player, op.container)
        if not anchor then return nil, "The container is locked or has no live outer location" end
        local part = anchor.container:getVehiclePart()
        if part then
            if self.player:getVehicle() then return nil, "Exit the vehicle before approaching another storage part" end
            if not part:getArea() then return nil, "The vehicle storage has no native access area" end
            state.pathArrived = false
            local action = ISPathFindAction:pathToVehicleArea(self.player, part:getVehicle(), part:getArea())
            action:setOnComplete(function() state.pathArrived = true end)
            return submitPath(self, state, action, function() return state.pathArrived end, "access")
        end
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
    if self.player:getVehicle() then return nil, "Exit the vehicle before walking to the destination" end
    return submitPath(self, state,
        ISPathFindAction:pathToLocationF(self.player, op.square:getX() + 0.5, op.square:getY() + 0.5, op.square:getZ()),
        function() return arrived(self.player, op.square) end, "done")
end

local function approachAccess(self, state)
    local container = state.op.container
    if containerReachable(self.player, container) then state.phase = "done"; return true end
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
            return submit(self, state, ISUnlockVehicleDoor:new(self.player, doorPart),
                function() return not door:isLocked() end, "access")
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
        if not vehicle:isAnyDoorLocked() and not vehicle:isTrunkLocked() then state.phase = "restore"; return true end
        if current == vehicle then
            if vehicle:getSeat(self.player) == 0 then state.phase = "unlockDoors"; return true end
            if vehicle:isSeatOccupied(0) or not vehicle:canSwitchSeat(vehicle:getSeat(self.player), 0) then
                return nil, "The driver seat is unavailable for unlocking storage"
            end
            return submit(self, state, ISSwitchVehicleSeat:new(self.player, 0),
                function() return self.player:getVehicle() == vehicle and vehicle:getSeat(self.player) == 0 end, "unlockDoors")
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
            return submit(self, state, ISUnlockVehicleDoor:new(self.player, part),
                function() return not part:getDoor():isLocked() end, "driverOpen")
        end
        state.phase = "driverOpen"
    elseif state.phase == "driverOpen" then
        return openDriverDoor(self, state, "enter")
    elseif state.phase == "enter" then
        if vehicle:isSeatOccupied(0) then return nil, "The driver seat became occupied" end
        return submit(self, state, ISEnterVehicle:new(self.player, vehicle, 0),
            function() return self.player:getVehicle() == vehicle and vehicle:getSeat(self.player) == 0 end, "closeEntry")
    elseif state.phase == "closeEntry" then
        return closeDriverDoor(self, state, "unlockDoors")
    elseif state.phase == "unlockDoors" then
        if current ~= vehicle or vehicle:getSeat(self.player) ~= 0 then return nil, "The driver seat is no longer available" end
        if vehicle:isAnyDoorLocked() then
            return submit(self, state, ISLockDoors:new(self.player, vehicle, false),
                function() return not vehicle:isAnyDoorLocked() end, "unlockTrunk")
        end
        state.phase = "unlockTrunk"
    elseif state.phase == "unlockTrunk" then
        local part = vehicle:getPartById("TrunkDoor") or vehicle:getPartById("DoorRear") or vehicle:getPartById("TrunkDoorOpened")
        if part and part:getDoor() and part:getDoor():isLocked() then
            return submit(self, state, ISUnlockVehicleDoor:new(self.player, part),
                function() return not part:getDoor():isLocked() end, "restore")
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
        return closeDriverDoor(self, state, "done")
    end
    return true
end

function Native.new(player)
    return setmetatable({ player = player }, Native)
end

function Native:isBusy()
    return self.active ~= nil
end

function Native:begin(op)
    if self.active then return nil, "A native operation is already running" end
    if not self.player or self.player:isDead() or self.player:isAsleep() then return nil, "The player cannot act" end
    if type(op) ~= "table" or not timeouts[op.kind] then return nil, "Unknown native operation" end
    if #queueFor(self).queue > 0 or not self.player:getCharacterActions():isEmpty() then
        return nil, "Finish the current player action first"
    end
    local state = { op = op, owned = {}, deadline = now() + timeouts[op.kind], phase = "prepare" }
    self.active = state
    local ok, result, reason = pcall(function()
        if op.kind == "approach" then
            local accepted, err = approach(self, state)
            if accepted and not state.action then state.phase = "done" end
            return accepted, err
        elseif op.kind == "transfer" then
            if not op.item or not op.source or not op.destination then return nil, "A transfer needs an item, source, and destination" end
            op.resultItem = nil
            state.itemId, state.fullType = op.item:getID(), tostring(op.item:getFullType())
            local world = op.item:getWorldItem()
            if op.source:getType() == "floor" and world then state.sourceSquare = world:getSquare() end
            if op.destination:getType() == "floor" then state.destinationSquare = self.player:getCurrentSquare() end
            if transferred(state) then state.phase = "done"; return true end
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
            if op.destination:getType() ~= "floor" and not op.destination:hasRoomFor(self.player, op.item) then return nil, "The destination is full" end
            if op.destination:isOccupiedVehicleSeat() then return nil, "The destination vehicle seat is occupied" end
            if not op.source:isRemoveItemAllowed(op.item) or not op.destination:isItemAllowed(op.item) or op.destination:isInside(op.item) then
                return nil, "The native container rules refuse this item"
            end
            return submit(self, state,
                ISInventoryTransferUtil.newInventoryTransferAction(self.player, op.item, op.source, op.destination),
                function() return transferred(state) end, "done")
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
            sendClientCommand(self.player, "object", "emptyTrash", {
                x = object:getX(), y = object:getY(), z = object:getZ(), index = object:getObjectIndex()
            })
            state.phase = "trashPending"
            return true
        elseif op.kind == "vehicle" then
            if not op.vehicle then return nil, "No vehicle was selected" end
            state.originalVehicle = self.player:getVehicle()
            if state.originalVehicle and state.originalVehicle ~= op.vehicle then return nil, "Exit your current vehicle first" end
            state.originalSeat = state.originalVehicle and op.vehicle:getSeat(self.player) or nil
            local part = driverDoor(op.vehicle)
            state.driverDoorWasOpen = part and part:getDoor():isOpen() or false
            return vehicleStep(self, state)
        end
    end)
    if not ok or not result then
        stopOwned(self, state)
        self.active = nil
        return nil, ok and reason or tostring(result)
    end
    return true
end

function Native:cancel()
    local state = self.active
    if not state then return true end
    state.cancelled = true
    state.failure = state.failure or "Cancelled"
    local ok, err = pcall(stopOwned, self, state)
    if not ok then return false, "Could not stop the owned native action: " .. tostring(err) end
    return true
end

local function poll(self, state)
    if self.player:isDead() then return finish(self, state, false, "The player died") end
    if now() > state.deadline then
        state.failure = state.failure or "The native operation timed out"
        stopOwned(self, state)
        if state.op.kind ~= "vehicle" or state.restoring then return finish(self, state, false, state.failure) end
    end
    if hasForeign(self, state) then
        stopOwned(self, state)
        if state.action and queueFor(self):indexOf(state.action) >= 0 then return nil end
        return finish(self, state, false, state.failure or "Another player action interrupted this operation")
    end
    local observed, reason = observeAction(self, state)
    if observed == nil then return nil end
    if observed == false then
        state.failure = state.failure or reason
        state.action = nil
    end
    if state.failure then
        if state.op.kind ~= "vehicle" then return finish(self, state, false, state.failure) end
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
    return finish(self, state, false, "The native operation has no completion state")
end

function Native:poll()
    local state = self.active
    if not state then return true end
    local ok, result, reason = pcall(poll, self, state)
    if ok then return result, reason end
    pcall(stopOwned, self, state)
    return finish(self, state, false, "Native operation error: " .. tostring(result))
end

return Native
