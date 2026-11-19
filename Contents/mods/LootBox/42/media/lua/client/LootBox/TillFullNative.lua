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

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function pack(...) return {n = select("#", ...), ...} end

local function liveCancellation(self, state)
    return state.reason or interrupted(self.player)
        or (Keyboard and isKeyDown and isKeyDown(Keyboard.KEY_ESCAPE))
end

local function exactFoodReturn(self, state, action, queue)
    if isClient() or isServer() or state.opening or state.kind ~= "food"
        or liveCancellation(self, state) or not state.reachedConsumption
        or not state.restore[action] or action.Type ~= "ISInventoryTransferAction"
        or queue.current == action or action.action or type(action.isStarted) ~= "function"
        or action:isStarted() or not state.nativeCancel or not state.nativeCancel[action] then return false end
    local item, source = state.item, state.source
    if not source or source:getType() ~= "floor"
        or action.item ~= item or item:getID() ~= state.itemId
        or action.srcContainer ~= self.player:getInventory() or action.destContainer ~= source then return false end
    -- Stock constructor shape only; never defer a merged batch or another tool.
    local list = action.queueList
    return action.items == nil and type(list) == "table" and #list == 1
        and type(list[1].items) == "table" and #list[1].items == 1 and list[1].items[1] == item
end

local function depletedFood(self, state)
    local item, receipt = state.item, state.receipt
    if not state.performSucceeded or not receipt or state.receiptInvalid or receipt.item ~= item
        or not finite(receipt.hunger) or not finite(receipt.thirst)
        or receipt.hunger <= 0 or receipt.thirst < 0
        or item:getContainer() or (item.getWorldItem and item:getWorldItem()) then return false end
    for _, container in ipairs({state.source, self.player:getInventory()}) do
        local items = container:getItems()
        for index = 0, items:size() - 1 do
            if items:get(index):getID() == state.itemId then return false end
        end
    end
    return true
end

local function settleReturn(self, state, completed)
    local action = state.deferredReturn
    if not action then return end
    state.deferredReturn = nil
    local queue = queueFor(self)
    local checked, obsolete = pcall(function()
        return completed and #queue.queue == 0 and not queue.current
            and exactFoodReturn(self, state, action, queue) and depletedFood(self, state)
    end)
    if checked and obsolete then
        local cleaned, problem = pcall(state.nativeCancel[action], action)
        if cleaned then
            state.owned[action], state.restore[action] = nil, nil
            return
        end
        state.reason = "Native return cleanup failed: " .. tostring(problem)
    end
    state.reason = state.reason or "Food completion was not confirmed; returning the item without consuming more"
    -- Use the unchanged stock action. Never cancel/reorder unrelated work that
    -- appeared while complete ran. No other actions are permitted at deferral.
    if not present(queue, action) then queue:addToQueue(action) end
end

local function deferReturn(self, state, queue)
    if not state.allFood or not state.observesComplete or state.receipt or state.deferredReturn
        or #queue.queue ~= 2 or queue.queue[1] ~= state.consume or queue.current ~= state.consume then return end
    local action = queue.queue[2]
    local checked, exact = pcall(exactFoodReturn, self, state, action, queue)
    if checked and exact then
        queue:removeFromQueue(action)
        state.deferredReturn = action
    end
end

-- SP nutrition callbacks are synchronous. Native perform advances the queue
-- BEFORE complete applies Eat; briefly hold only the simple full-Floor-food
-- return so it cannot start against an item that complete is about to remove.
local function observeNeeds(self, state, action)
    local name = state.kind == "food" and "complete" or "updateEat"
    local previous = action[name]
    if type(previous) ~= "function" then return end
    if name == "complete" then state.observesComplete = true end
    action[name] = function(current, ...)
        local beforeOK, beforeH, beforeT = pcall(state.needSampler)
        local exact = current == state.consume and current.item == state.item
        local result = pack(pcall(previous, current, ...))
        if not result[1] then
            state.receiptInvalid, state.receipt = true, nil
            settleReturn(self, state, false)
            error(result[2], 0)
        end
        local afterOK, afterH, afterT = pcall(state.needSampler)
        if not exact or current.item ~= state.item or not beforeOK or not afterOK
            or not finite(beforeH) or not finite(beforeT) or not finite(afterH) or not finite(afterT) then
            state.receiptInvalid, state.receipt = true, nil
        elseif not state.receiptInvalid then
            local receipt = state.receipt or {item = state.item, hunger = 0, thirst = 0}
            receipt.hunger = receipt.hunger + math.max(0, beforeH - afterH)
            receipt.thirst = receipt.thirst + math.max(0, beforeT - afterT)
            state.receipt = receipt
        end
        if name == "complete" then settleReturn(self, state, true) end
        return unpack(result, 2, result.n)
    end
end

local function hook(self, state, action)
    local originalStop, originalPerform, originalStart = action.stop, action.perform, action.start
    local originalCancel = action.forceCancel
    if type(originalStop) ~= "function" or type(originalPerform) ~= "function" then
        return nil, "Unsupported native action lifecycle"
    end
    if action == state.consume and state.needSampler and not isClient() and not isServer() then
        observeNeeds(self, state, action)
    end
    if action == state.consume and type(originalStart) == "function" then
        action.start = function(started)
            state.reachedConsumption = true
            return originalStart(started)
        end
    end
    if type(originalCancel) == "function" then
        state.nativeCancel = state.nativeCancel or {}
        state.nativeCancel[action] = originalCancel
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
        if performed == state.consume then deferReturn(self, state, queue) end
        for _, pending in ipairs(queue.queue) do
            if not state.owned[pending] then foreign[#foreign + 1] = pending end
        end
        -- onCompleted can reset the queue when the next native action refuses
        -- admission. Foreign work must survive that path as well as stop().
        for _, pending in ipairs(foreign) do queue:removeFromQueue(pending) end
        local ok, problem = pcall(originalPerform, performed)
        if performed == state.consume then
            state.performSucceeded = ok
            if not ok then
                state.reason = "Native completion failed: " .. tostring(problem)
                settleReturn(self, state, false)
            end
        end
        if ok and performed == state.consume and state.opening and not isClient() then
            local captured, captureProblem = pcall(function()
                local outputs = performed.logic:getRecipeData():getAllCreatedItems()
                for index = 0, outputs:size() - 1 do
                    local item = outputs:get(index)
                    if (state.kind == "food" and instanceof(item, "Food"))
                        or (state.kind == "fluid" and item:getFluidContainer()) then
                        if state.output then error("Opening produced multiple consumable items") end
                        state.output = item
                    end
                end
            end)
            if not captured then state.reason = "Could not identify the opened item: " .. tostring(captureProblem) end
        end
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
    settleReturn(self, state, false)
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

local function fluidTarget(item)
    local source = item:getContainer()
    local ground = item.getWorldItem and item:getWorldItem()
    if source and source.getType and source:getType() == "floor"
        and ground and ground:getItem() == item and ground:getSquare()
        and ground.getFluidContainer and ground:getFluidContainer() then
        return ground
    end
    return item
end

local function missingSource(item)
    if item and item.getContainer and item:getContainer() then return end
    local ground = item and item.getWorldItem and item:getWorldItem()
    if ground and ground:getItem() == item and ground:getSquare() then
        return "Open the nearby Floor pane and try again"
    end
    return "The selected item is no longer in an available container"
end

local function checkAuto(self, state, phase, validateEffect)
    local player, queue, item = self.player, queueFor(self), state.item
    if state.reason or interrupted(player) or flag(player, "isPlayerMoving")
        or (Keyboard and isKeyDown and isKeyDown(Keyboard.KEY_ESCAPE))
        or not ISInventoryPaneContextMenu.getEatingMask
        or ISInventoryPaneContextMenu.getEatingMask(player, false) then return false end
    for _, action in ipairs(queue.queue) do if not state.owned[action] then return false end end
    if queue.current and not state.owned[queue.current] then return false end
    local source = item:getContainer()
    local expected = phase == "prepare" and state.source or player:getInventory()
    if source ~= expected or item:getID() ~= state.itemId
        or (item.getWorldItem and item:getWorldItem()) then return false end
    if state.autoGuard(phase, validateEffect) ~= true then return false end
    if (phase == "consume" or phase == "open") and state.atTarget() then
        state.reason = "Requested limit reached"
        return false
    end
    return true
end

local function autoAllowed(self, state, phase, validateEffect)
    local ok, accepted = pcall(checkAuto, self, state, phase, validateEffect)
    return ok and accepted == true
end

local function dispatchAuto(self, state, phase)
    if not autoAllowed(self, state, phase, true) then return nil, "Automatic intake yielded to a player action or unsafe item" end
    local queue, player, item, main = queueFor(self), self.player, state.item, self.player:getInventory()
    if queue.current or #queue.queue > 0 then return nil, "Finish the current player action first" end
    local action
    if phase == "open" then
        local opening = require "LootBox/NeedsOpening"
        local problem
        action, problem = opening.action(player, state.openingPlan, function() return autoAllowed(self, state, "open") end)
        if not action or action.Type ~= "ISHandcraftAction" or action.character ~= player then
            return nil, problem or "Native opening could not bind one exact handcraft action"
        end
        state.openingAdapter = opening
    elseif phase == "consume" then
        local ctor = state.kind == "food" and ISEatFoodAction or ISDrinkFluidAction
        if not ctor or type(ctor.new) ~= "function" then return nil, "Native consumption is unavailable" end
        local expected = state.kind == "food" and "ISEatFoodAction" or "ISDrinkFluidAction"
        action = ctor:new(player, item, state.portion)
        if not action or action.Type ~= expected or action.item ~= item or action.character ~= player then
            return nil, "Native consumption could not bind the exact selected item"
        end
        state.consume = action
    else
        local source, dest = state.source, main
        if phase == "return" then source, dest = main, state.source end
        if not ISInventoryTransferUtil or type(ISInventoryTransferUtil.newInventoryTransferAction) ~= "function" then
            return nil, "Native inventory transfer is unavailable"
        end
        action = ISInventoryTransferUtil.newInventoryTransferAction(player, item, source, dest)
        if not action or action.Type ~= "ISInventoryTransferAction" or action.item ~= item or action.character ~= player
            or action.srcContainer ~= source or action.destContainer ~= dest then
            return nil, "Native transfer could not bind the exact selected item"
        end
        -- Stock transfer can coalesce adjacent same-endpoint actions at start
        -- and completion. An automatic action must remain exactly one item.
        function action:canMergeAction() return false end
    end
    local hooked, problem = hook(self, state, action)
    if not hooked then return nil, problem end
    state.owned[action] = true
    state.autoPhase, state.autoAction = phase, action
    state.autoDone = nil
    action.stopOnWalk, action.stopOnAim = true, true
    local function emptyDrink()
        return phase == "consume" and state.kind == "fluid" and action.fluidContainer and action.fluidContainer:isEmpty()
    end
    local function verify(allowEmpty, validateEffect)
        local sameFluid = phase ~= "consume" or state.kind ~= "fluid" or action.fluidContainer == state.item:getFluidContainer()
        if (phase == "open" or action.item == state.item) and sameFluid and autoAllowed(self, state, allowEmpty and emptyDrink() and "settle" or phase, validateEffect) then
            return true
        end
        state.reason = state.reason or "Automatic intake yielded to a player action or unsafe item"
        return false
    end
    local valid, validStart = action.isValid, action.isValidStart
    local update, start, perform = action.update, action.start, action.perform
    local complete = action.complete
    if type(valid) ~= "function" or type(validStart) ~= "function" then return nil, "Unsupported native admission" end
    function action:isValid()
        -- Finish the native UI cleanup when our own progress drained a bottle.
        if emptyDrink() and state.receipt and state.receipt.thirst > 0 then return verify(true) end
        return verify(false, phase == "consume" and state.kind == "food") and valid(self)
    end
    function action:isValidStart() return verify() and validStart(self) end
    if type(start) == "function" then
        function action:start() if verify(false, false) then return start(self) end end
    end
    if type(update) == "function" then
        function action:update() if not emptyDrink() and verify() then return update(self) end end
    end
    function action:perform()
        -- perform also retires the native action. If it is too late to stop
        -- normally, let that cleanup run but do not apply unsafe SP nutrition.
        verify(true)
        local ok = perform(self)
        state.autoDone = ok == true
        return ok
    end
    if phase == "open" then
        local recipe = action.performRecipe
        if type(recipe) ~= "function" then return nil, "Unsupported native recipe lifecycle" end
        function action:performRecipe(...)
            if not verify() or not state.openingAdapter.ready(player, state.openingPlan, self) then
                return false
            end
            local result = pack(recipe(self, ...))
            local checked, output = pcall(state.openingAdapter.output, player, state.openingPlan, self)
            if checked then state.openOutput = output end
            return unpack(result, 1, result.n)
        end
    elseif phase == "consume" then
        if state.kind == "food" then
            -- Vanilla can apply a partial bite on stop; automatic intake must
            -- not do that after the owner/safety check has failed.
            function action:serverStop() end
        end
        if type(complete) ~= "function" then return nil, "Unsupported native completion" end
        if state.kind == "fluid" then
            local updateEat = action.updateEat
            if type(updateEat) ~= "function" then return nil, "Unsupported native drink lifecycle" end
            function action:updateEat(...)
                -- Exactly one deep check at each native liquid mutation, not
                -- repeated samples in poll, isValid, and animation updates.
                if not emptyDrink() and verify(false, true) then return updateEat(self, ...) end
            end
        end
        function action:complete(...)
            -- A drink that was exhausted by its own update has nothing left
            -- for complete() to do, and no longer passes the safety sampler.
            if emptyDrink() then return verify(true) end
            if not verify(false, state.kind == "food") then return false end
            return complete(self, ...)
        end
    end
    if not action:isValidStart() then return nil, "The game refused automatic intake" end
    if not verify() or queue.current or #queue.queue > 0 then return nil, "Another player action was queued" end
    ISTimedActionQueue.add(action)
    if not present(queue, action) then return nil, "The game did not queue the automatic action" end
    return true
end

function Native:begin(item, kind, portion, atTarget, needSampler, autoGuard)
    if self.active then return nil, "A consumption action is already active" end
    if kind ~= "food" and kind ~= "fluid" then return nil, "Unsupported consumption kind" end
    if type(portion) ~= "number" or portion ~= portion or portion <= 0 or portion > 1 then
        return nil, "Invalid native portion"
    end
    if type(atTarget) ~= "function" then return nil, "A live stop predicate is required" end
    local sourceProblem = missingSource(item)
    if sourceProblem then return nil, sourceProblem end
    if item.isSealed and item:isSealed() then return nil, "Open the item before using Til Full" end
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
    local state = {owned = {}, restore = {}, started = now(), atTarget = atTarget,
        item = item, itemId = item:getID(), source = item:getContainer(), kind = kind, needSampler = type(needSampler) == "function" and needSampler or nil}
    if kind == "food" and item.getHungChange and item.getBaseHunger then
        local remaining, base = item:getHungChange(), item:getBaseHunger()
        state.allFood = finite(remaining) and finite(base) and remaining < 0 and base < 0
            and portion >= remaining / base
    end
    self.active = state
    if autoGuard then
        state.autoGuard, state.portion = autoGuard, portion
        local phase = state.source == self.player:getInventory() and "consume" or "prepare"
        local dispatched, admitted, reason = pcall(dispatchAuto, self, state, phase)
        if dispatched and admitted then return true end
        local problem = dispatched and reason or "Native automatic admission failed: " .. tostring(admitted)
        if state.autoAction and present(queue, state.autoAction) then self:cancel(problem)
        else self.active = nil end
        return nil, problem
    end
    local dispatched, err = pcall(function()
        if kind == "food" then
            ISInventoryPaneContextMenu.eatItem(item, portion, self.player:getPlayerNum())
        else
            ISInventoryPaneContextMenu.onDrinkFluid(fluidTarget(item), portion, self.player)
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

function Native:beginExactOpen(item, plan, atTarget, guard)
    if self.active then return nil, "A consumption action is already active" end
    if isClient() or isServer() or item:getContainer() ~= self.player:getInventory() then
        return nil, "Automatic opening requires exact main-inventory inputs in single-player"
    end
    local state = {owned = {}, restore = {}, started = now(), atTarget = atTarget, autoGuard = guard,
        item = item, itemId = item:getID(), source = item:getContainer(), openingPlan = plan, kind = "food"}
    self.active = state
    local checked, ok, failure = pcall(dispatchAuto, self, state, "open")
    if checked and ok then return true end
    local problem = checked and failure or "Native automatic opening failed"
    if state.autoAction and present(queueFor(self), state.autoAction) then self:cancel(problem)
    else self.active = nil end
    return nil, problem
end

function Native:beginOpen(item, kind, recipe, atTarget)
    if self.active then return nil, "A consumption action is already active" end
    if kind ~= "food" and kind ~= "fluid" then return nil, "Unsupported consumption kind" end
    if type(atTarget) ~= "function" then return nil, "A live stop predicate is required" end
    local sourceProblem = missingSource(item)
    if sourceProblem then return nil, sourceProblem end
    if not recipe
        or not item:getOpeningRecipe() or getScriptManager():getCraftRecipe(item:getOpeningRecipe()) ~= recipe then
        return nil, "The selected opening recipe changed"
    end
    if interrupted(self.player) then return nil, "The player cannot begin opening now" end
    if not ISEntityUI or type(ISEntityUI.HandcraftStart) ~= "function" then
        return nil, "The native opening action is unavailable"
    end
    local queue = queueFor(self)
    if #queue.queue > 0 or queue.current then return nil, "Finish the current player action first" end
    local ok, target = pcall(atTarget)
    if not ok then return nil, "Could not read current fullness" end
    if target then return nil, "Already at the requested limit" end
    local state = {owned = {}, restore = {}, started = now(), atTarget = atTarget,
        opening = true, kind = kind, item = item, itemId = item:getID(), fullType = item:getFullType(), source = item:getContainer(),
        wasSealed = item:isSealed(), chooseOpened = kind == "food" and isClient()}
    self.active = state
    -- Zero means opening only. Native Open-and-Eat percentages enqueue a
    -- separate, unowned consumption action, including through the MP server.
    local startCraft = ISEntityUI.HandcraftStart
    ISEntityUI.HandcraftStart = function(player, logic, force, addToQueue, eatPercentage)
        local action = startCraft(player, logic, force, false, eatPercentage)
        local bound = false
        if action and action.character == self.player and action.craftRecipe == recipe
            and action.manualInputs and action.eatPercentage == 0 then
            for _, inputs in pairs(action.manualInputs) do
                for index = 0, inputs:size() - 1 do
                    if inputs:get(index) == item then bound = true end
                end
            end
        end
        if not bound then
            state.reason = "The native recipe could not bind the selected item"
            state.restoreFrom = #queue.queue
            return nil
        end
        if addToQueue then ISTimedActionQueue.add(action) end
        return action
    end
    local dispatched, err = pcall(function()
        -- Stock Open-and-Drink first transfers its world wrapper, then gives
        -- crafting the canonical selected inventory item, never the wrapper.
        local target = kind == "fluid" and fluidTarget(item) or item
        if target ~= item then ISInventoryPaneContextMenu.transferIfNeeded(self.player, target) end
        ISInventoryPaneContextMenu.OnNewCraft(item, recipe, self.player:getPlayerNum(), false, 0)
    end)
    ISEntityUI.HandcraftStart = startCraft
    local seenCraft = false
    for index, action in ipairs(queue.queue) do
        state.owned[action] = true
        if action.Type == "ISHandcraftAction" then
            if state.consume then state.reason = "Unexpected multiple native opening actions" end
            state.consume, seenCraft = action, true
        elseif seenCraft or (state.restoreFrom and index > state.restoreFrom) then state.restore[action] = true end
    end
    for action in pairs(state.owned) do
        local supported, problem = hook(self, state, action)
        if not supported then state.reason = problem end
    end
    if not dispatched then state.reason = "Native opening failed: " .. tostring(err) end
    if not state.consume then state.reason = state.reason or "The game did not queue an opening action" end
    if state.reason then self:cancel(state.reason); return nil, state.reason end
    return true
end

-- Network pickup can reconstruct a vessel. Match only the original network ID
-- among direct source/main-inventory members, never by type or food output.
local function openedNetworkVessel(self, state)
    local found, seen = nil, {}
    for _, container in ipairs({state.source, self.player:getInventory()}) do
        if not seen[container] then
            seen[container] = true
            local items = container:getItems()
            for index = 0, items:size() - 1 do
                local item = items:get(index)
                if item:getContainer() == container and item:getID() == state.itemId then
                    if found and found ~= item then return nil, "Ambiguous opened vessel identity" end
                    if item:getFullType() ~= state.fullType then return nil, "Opened vessel identity changed" end
                    found = item
                end
            end
        end
    end
    if found and not found:isSealed() and found:getFluidContainer() then return found end
end

local function pollAuto(self, state, queue)
    if state.reason then self:cancel(state.reason) end
    if state.autoAction and present(queue, state.autoAction) then
        if not state.reason then
            if now() - state.started >= TIMEOUT then self:cancel("Native automatic action timed out")
            elseif not autoAllowed(self, state, state.autoPhase)
                and not (state.autoPhase == "consume" and state.kind == "fluid" and state.receipt and state.receipt.thirst > 0
                    and state.autoAction.fluidContainer:isEmpty() and autoAllowed(self, state, "settle"))
                and (state.autoPhase ~= "consume" or not state.performed) then
                self:cancel("Automatic intake yielded to a player action or unsafe item")
            end
        end
        return nil
    end
    if state.reason or not state.autoDone then
        self.active = nil
        return false, state.reason or "Native automatic action ended without completion"
    end
    if state.autoPhase == "open" then
        self.active = nil
        if #queue.queue > 0 or queue.current then return false, "Another player action was queued" end
        if not state.openOutput then return false, "The exact native opening output was not confirmed" end
        return true, "opened", state.openOutput
    end
    if state.autoPhase == "prepare" then
        if #queue.queue > 0 or queue.current then
            self.active = nil
            return false, "Another player action was queued"
        end
        if state.item:getContainer() ~= self.player:getInventory() then
            -- A client transfer can retire before its authoritative update.
            -- Wait briefly for this exact reference; do not choose a replacement.
            state.transferUntil = state.transferUntil or now() + 2000
            if state.item:getContainer() == state.source and now() < state.transferUntil then return nil end
            self.active = nil
            return false, "The exact carried item transfer was not confirmed"
        end
        local sampled, target = pcall(state.atTarget)
        if not sampled or target then
            self.active = nil
            return false, sampled and "Requested limit reached" or "Could not read current fullness"
        end
        local checked, ok, failure = pcall(dispatchAuto, self, state, "consume")
        if checked and ok then return nil end
        state.reason = checked and failure or "Native automatic consumption failed"
        if state.autoAction and present(queue, state.autoAction) then self:cancel(state.reason); return nil end
        self.active = nil
        return false, state.reason
    end
    if state.autoPhase == "consume" and state.source ~= self.player:getInventory()
        and #queue.queue == 0 and not queue.current and state.item:getContainer() == self.player:getInventory()
        and CharacterTrait and CharacterTrait.DISORGANIZED and self.player.hasTrait
        and not self.player:hasTrait(CharacterTrait.DISORGANIZED) then
        -- Only the original exact carried bag is a valid return. If a player
        -- takes over or the bag changes, leave the item in carried inventory.
        local checked, ok = pcall(dispatchAuto, self, state, "return")
        if checked and ok then return nil end
        if state.autoAction and present(queue, state.autoAction) then self:cancel("Native automatic return failed"); return nil end
    end
    self.active = nil
    return true, "complete", nil, state.receipt
end

function Native:poll()
    local state = self.active
    if not state then return false, "No consumption action is active" end
    -- The engine normally calls complete immediately after perform. Never
    -- leave a detached return behind if completion did not arrive.
    settleReturn(self, state, false)
    local queue = queueFor(self)
    if state.autoGuard then return pollAuto(self, state, queue) end
    if queue.current == state.consume then state.reachedConsumption = true end
    if not state.reason then
        -- Native consumption has already ended after perform. Its restoration
        -- may move the item back to Floor or replace the original opened food.
        -- Let cleanup drain; the controller verifies final quantity/fullness.
        local ok, target = true, false
        if not state.performed then ok, target = pcall(state.atTarget) end
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
    if state.reason then self.active = nil; return false, state.reason end
    if not state.performed then self.active = nil; return false, "Native consumption ended without completion" end
    if state.opening then
        if state.chooseOpened then
            self.active = nil
            return true, "chooseOpened"
        end
        local item = state.output or state.item
        if isClient() and state.kind == "fluid" then
            local problem
            item, problem = openedNetworkVessel(self, state)
            if problem then self.active = nil; return false, problem end
        end
        local source = item and item:getContainer()
        if source and not item:isSealed()
            and (state.output or (state.wasSealed and item:getID() == state.itemId))
            and (source == state.source or source == self.player:getInventory()) then
            self.active = nil
            return true, "opened", item
        end
        state.confirmUntil = state.confirmUntil or now() + 2000
        if now() < state.confirmUntil then return nil end
        self.active = nil
        return false, "Opening result was not confirmed; no consumption was queued"
    end
    self.active = nil
    return true, "complete", nil, state.receipt
end

return Native
