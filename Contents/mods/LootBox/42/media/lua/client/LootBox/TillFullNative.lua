require "TimedActions/ISTimedActionQueue"
require "ISUI/ISInventoryPaneContextMenu"

-- Own one native wrapper's actions, never the player's entire queue. Consumption
-- and its server effects remain native; a completed client action is not an MP ack.
local Native = {}
Native.__index = Native
local TIMEOUT = 120000
local function now() return getTimestampMs() end
local function queueFor(self) return ISTimedActionQueue.getTimedActionQueue(self.player) end
local function present(queue, action)
    for _, value in ipairs(queue.queue) do if value == action then return true end end
    return false
end
local function flag(player, name)
    return player[name] and player[name](player) == true
end
local function interrupted(player)
    return flag(player, "isDead") or flag(player, "isAsleep") or flag(player, "isRunning")
        or flag(player, "isSprinting") or flag(player, "isAiming") or flag(player, "isAttacking")
end

function Native.new(player) return setmetatable({player = player}, Native) end
function Native:isBusy() return self.active ~= nil end

local function hook(self, state, action)
    local originalStop, originalPerform, originalStart = action.stop, action.perform, action.start
    local originalCancel = action.forceCancel
    if type(originalStop) ~= "function" or type(originalPerform) ~= "function" then
        return nil, "Unsupported native action lifecycle"
    end
    if action == state.consume and type(originalStart) == "function" then
        action.start = function(started)
            state.reachedConsumption = true
            return originalStart(started)
        end
    end
    if type(originalCancel) == "function" then
        action.forceCancel = function(cancelled)
            state.reason = state.reason or "Native action cancelled before completion"
            return originalCancel(cancelled)
        end
    end
    action.stop = function(stopped)
        local queue, preserve = queueFor(self), {}
        -- Preparation may already have removed a mask or moved an item. Preserve
        -- native restoration even when consumption itself has not started.
        for _, pending in ipairs(queue.queue) do
            if pending ~= stopped and (not state.owned[pending]
                or state.restore[pending]) then
                preserve[#preserve + 1] = pending
            end
        end
        for _, pending in ipairs(preserve) do queue:removeFromQueue(pending) end
        local ok, problem = pcall(originalStop, stopped)
        -- A broken stop must not duplicate still-present actions or discard backups.
        for _, pending in ipairs(preserve) do
            if not present(queue, pending) then queue:addToQueue(pending) end
        end
        state.reason = state.reason or "Native action interrupted"
        if not ok then state.reason = "Native stop failed: " .. tostring(problem) end
    end
    action.perform = function(performed)
        if performed == state.consume then state.performed = true end
        local queue, foreign = queueFor(self), {}
        for _, pending in ipairs(queue.queue) do
            if not state.owned[pending] then foreign[#foreign + 1] = pending end
        end
        -- onCompleted can reset the queue when the next native action refuses
        -- admission. Foreign work must survive that path as well as stop().
        for _, pending in ipairs(foreign) do queue:removeFromQueue(pending) end
        local ok, problem = pcall(originalPerform, performed)
        for _, pending in ipairs(foreign) do
            if not present(queue, pending) then queue:addToQueue(pending) end
        end
        if not ok then state.reason = "Native completion failed: " .. tostring(problem) end
        return ok
    end
    return true
end

function Native:cancel(reason)
    local state = self.active
    if not state then return true end
    state.reason = state.reason or reason or "Cancelled"
    local queue = queueFor(self)
    -- Remove only our pending preparation/consumption; leave native restoration
    -- and all other people's queued actions intact.
    for i = #queue.queue, 1, -1 do
        local action = queue.queue[i]
        if state.owned[action] and action ~= queue.current
            and not state.restore[action] then
            action:forceCancel()
            queue:removeFromQueue(action)
        end
    end
    local current = queue.current
    if current and state.owned[current] and not state.restore[current] and not state.stopRequested then
        state.stopRequested = true
        if current.action then current:forceStop()
        else state.reason = "Waiting for native action admission before stopping"; state.stopRequested = false end
    end
    return true
end

function Native:begin(item, kind, portion, atTarget)
    if self.active then return nil, "A consumption action is already active" end
    if kind ~= "food" and kind ~= "fluid" then return nil, "Unsupported consumption kind" end
    if type(portion) ~= "number" or portion ~= portion or portion <= 0 or portion > 1 then
        return nil, "Invalid native portion"
    end
    if type(atTarget) ~= "function" then return nil, "A live stop predicate is required" end
    if not item or (item.isSealed and item:isSealed()) then return nil, "Open the item before using Til Full" end
    if interrupted(self.player) then return nil, "The player cannot begin consumption now" end
    if kind == "food" and item.getRequireInHandOrInventory then
        local required = item:getRequireInHandOrInventory()
        if required and required:size() > 0 then return nil, "Use the normal Eat action for food requiring another item" end
    end
    local queue = queueFor(self)
    if #queue.queue > 0 or queue.current then return nil, "Finish the current player action first" end
    local ok, target = pcall(atTarget)
    if not ok then return nil, "Could not read current fullness" end
    if target then return nil, "Already at the requested limit" end
    local state = {owned = {}, restore = {}, started = now(), atTarget = atTarget}
    self.active = state
    local dispatched, err = pcall(function()
        if kind == "food" then
            ISInventoryPaneContextMenu.eatItem(item, portion, self.player:getPlayerNum())
        else
            ISInventoryPaneContextMenu.onDrinkFluid(item, portion, self.player)
        end
    end)
    local seenConsume = false
    for _, action in ipairs(queue.queue) do
        state.owned[action] = true
        if action.Type == (kind == "food" and "ISEatFoodAction" or "ISDrinkFluidAction") then
            if state.consume then state.reason = "Unexpected multiple native consumption actions" end
            state.consume, seenConsume = action, true
        elseif seenConsume then state.restore[action] = true end
    end
    state.reachedConsumption = queue.current == state.consume and state.consume ~= nil
    for action in pairs(state.owned) do
        local supported, problem = hook(self, state, action)
        if not supported then state.reason = problem end
    end
    if not dispatched then state.reason = "Native preparation failed: " .. tostring(err) end
    if not state.consume then state.reason = state.reason or "The game did not queue a consumption action" end
    if state.reason then self:cancel(state.reason); return nil, state.reason end
    return true
end

function Native:poll()
    local state = self.active
    if not state then return false, "No consumption action is active" end
    local queue = queueFor(self)
    if queue.current == state.consume then state.reachedConsumption = true end
    if not state.reason then
        local ok, target = pcall(state.atTarget)
        if not ok then state.reason = "Could not read current fullness"
        elseif target then state.reason = "Requested limit reached"
        elseif interrupted(self.player) then state.reason = "Player interrupted consumption"
        elseif now() - state.started >= TIMEOUT then state.reason = "Native consumption timed out" end
        for _, action in ipairs(queue.queue) do
            if not state.owned[action] then state.reason = state.reason or "Another player action was queued" end
        end
    end
    if state.reason then self:cancel(state.reason) end
    for action in pairs(state.owned) do if present(queue, action) then return nil end end
    self.active = nil
    if state.reason then return false, state.reason end
    if not state.performed then return false, "Native consumption ended without completion" end
    return true, "complete"
end

return Native
