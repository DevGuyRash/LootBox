local Adapter = require "LootBox/TillFullNative"
local TillFull = {}
TillFull.__index = TillFull

local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function needs(player)
    local stats = player:getStats()
    local hunger, thirst = stats:get(CharacterStat.HUNGER), stats:get(CharacterStat.THIRST)
    local hmin, tmin = CharacterStat.HUNGER:getMinimumValue(), CharacterStat.THIRST:getMinimumValue()
    if not finite(hunger) or not finite(thirst) or not finite(hmin) or not finite(tmin) then error("The game's need values are unavailable") end
    -- Zero hunger is satisfied, not the negative stuffed range. Never target
    -- below the native minimum on builds with different stat bounds.
    return math.max(0, hunger - math.max(0, hmin)), math.max(0, thirst - math.max(0, tmin))
end

local function safeFood(item)
    return not item:isRotten() and not item:isBurnt() and not item:isFrozen() and not item:isTainted()
        and not item:isPoison() and item:getPoisonPower() <= 0 and item:getFoodSicknessChange() <= 0
        and not item:isAlcoholic() and (not item:isbDangerousUncooked() or item:isCooked())
end

local function fluidEffects(fluid, opening)
    local properties = fluid:getProperties()
    if properties:getAlcohol() > 0 then return nil, "Til Full does not drink alcohol; choose a normal Drink amount instead" end
    if fluid:isEmpty() or (not opening and not fluid:canPlayerEmpty()) or fluid:isPoisonous() or fluid:isTainted()
        or properties:getPoison() > 0 or properties:getFoodSicknessChange() > 0 then
        return nil, "This drink is empty, sealed, or unsafe"
    end
    local sample = fluid:createFluidSample()
    local ok, safe = pcall(function()
        for index = 0, sample:size() - 1 do
            if sample:getPercentage(index) > 0 then
                local part = sample:getFluid(index)
                local props = part:getProperties()
                if not (part:isCategory(FluidCategory.Beverage) or part:isCategory(FluidCategory.Water))
                    or part:isCategory(FluidCategory.Hazardous) or part:isCategory(FluidCategory.Alcoholic)
                    or part:isPoisonous() or props:getPoison() > 0 or props:getAlcohol() > 0
                    or props:getFoodSicknessChange() > 0 then return false end
            end
        end
        return true
    end)
    sample:release()
    if not ok or not safe then return nil, "This fluid mixture cannot be safely consumed automatically" end
    return -properties:getHungerChange(), -properties:getThirstChange()
end

function TillFull.portion(hunger, thirst, hrelief, trelief, both, kind)
    if not finite(hunger) or not finite(thirst) or not finite(hrelief) or not finite(trelief) then return nil end
    local h = hrelief > 0 and math.max(0, hunger) / hrelief or nil
    local t = trelief > 0 and math.max(0, thirst) / trelief or nil
    local fraction
    if kind == "food" then fraction = h elseif kind == "fluid" then fraction = t end
    -- Never silently substitute the other need for the native action selected.
    if fraction == nil then return nil end
    if both and h ~= nil and t ~= nil then fraction = math.max(h, t) end
    return math.min(1, fraction)
end

function TillFull.new(player, world, items, kind, both, openingRecipe, menuSource)
    if kind ~= "food" and kind ~= "fluid" then return nil, "Unsupported consumption action" end
    if type(items) ~= "table" then return nil, "Choose an item stack" end
    local records, seen = {}, {}
    for _, item in ipairs(items) do
        if not seen[item] then
            seen[item] = true
            local ok, record = pcall(function()
                return {item = item, id = item:getID(), fullType = tostring(item:getFullType()), source = item:getContainer()}
            end)
            if not ok then return nil, "The selected item is unavailable" end
            if menuSource then
                if not world.consumptionSource then return nil, "The selected source cannot be verified" end
                local accessible, reason = world:consumptionSource(item, menuSource)
                if not accessible then return nil, reason or "The selected source is unavailable" end
                record.source = menuSource
            end
            records[#records + 1] = record
            if #records > 4096 then return nil, "Choose a bounded item stack" end
        end
    end
    if #records == 0 or #records > 4096 then return nil, "Choose a nonempty bounded item stack" end
    return setmetatable({player = player, world = world, records = records, kind = kind, both = both == true,
        index = 1, count = 0, native = Adapter.new(player), state = "running", attempts = 0, openingRecipe = openingRecipe, menuSource = menuSource}, TillFull)
end

-- Native multiplayer transfers may replace a Java object while retaining its
-- immutable item ID. Resolve only the two endpoints of our dispatched action.
function TillFull:resolveTransferred(record, confirming)
    if not (isClient and isClient()) or not record.dispatched then return end
    local main, source = self.player:getInventory(), record.source
    local direct = record.item:getContainer()
    record.identityUnresolved, record.absentAtEndpoints = nil, nil
    if not main.getItemWithID or not source or not source.getItemWithID then
        if direct == main then record.seenInMain = true; return end
        if direct == source then return end
        record.identityUnresolved = true
        return
    end
    local original = source:getItemWithID(record.id)
    local carried = source == main and original or main:getItemWithID(record.id)
    local candidate = carried or original
    -- Native lookup is enough while the dispatched reference stays coherent.
    -- Walk direct lists only for a replacement or the first final confirmation
    -- of this endpoint identity, not on every native action tick.
    local audit = candidate and candidate ~= record.item
        or (confirming and (not record.confirmationAudited
            or record.auditedOriginal ~= original or record.auditedCarried ~= carried))
    if audit then
        local function unique(container)
            if not container.getItems then return true end
            local found
            local items = container:getItems()
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                if item:getID() == record.id then
                    if found and found ~= item then return false end
                    found = item
                end
            end
            return true
        end
        if not unique(source) or (source ~= main and not unique(main)) then
            return "The selected item identity is ambiguous"
        end
        if confirming then
            record.confirmationAudited = true
            record.auditedOriginal, record.auditedCarried = original, carried
        end
    end
    if original and carried and original ~= carried then return "The selected item identity is ambiguous" end
    local item = carried or original
    if item then
        if item:getID() ~= record.id or tostring(item:getFullType()) ~= record.fullType then
            return "The selected item identity changed"
        end
        local container = item:getContainer()
        if (container ~= main or carried ~= item) and (container ~= source or original ~= item) then
            return "The selected item is no longer in its exact source or inventory"
        end
        record.item = item
        if self.inflight then self.inflight.item = item end
        if container == main then record.seenInMain = true end
    else
        record.identityUnresolved = true
        record.absentAtEndpoints = source.containsID and main.containsID
            and not source:containsID(record.id) and not main:containsID(record.id)
            and self.world.canAccess and self.world:canAccess(source) and self.world:canAccess(main)
    end
end

function TillFull:sourceProblem(record, allowConsumed)
    local resolutionProblem = self:resolveTransferred(record)
    if resolutionProblem then return resolutionProblem end
    if record.identityUnresolved then
        if allowConsumed then return end
        return "The selected item transfer is not yet confirmed"
    end
    local item, source = record.item, record.item:getContainer()
    if item:getID() ~= record.id or tostring(item:getFullType()) ~= record.fullType then
        return "The selected item moved or changed"
    end
    if self.menuSource then
        if record.dispatched and source == self.player:getInventory() then return end
        if allowConsumed and record.dispatched and not source then
            -- A native consume may remove the item. A still-present floor item
            -- remains subject to its original exact membership and reach checks.
            local ground = item.getWorldItem and item:getWorldItem()
            if not ground then return end
        end
        local accessible, reason = self.world:consumptionSource(item, record.source)
        if not accessible then return reason or "The selected source is unavailable" end
    elseif not source or (source ~= record.source and source ~= self.player:getInventory()) then
        if not (allowConsumed and not source) then return "The selected item moved or changed" end
    end
end

-- Floor fluids live on the exact world wrapper until vanilla picks them up.
-- Never borrow another object's fluid, or authorize a stale floor association.
function TillFull:fluidFor(item)
    local fluid = item:getFluidContainer()
    if fluid then return fluid end
    local source = item:getContainer()
    local ground = item.getWorldItem and item:getWorldItem()
    if source and source.getType and source:getType() == "floor" and ground
        and ground.getItem and ground:getItem() == item and ground.getFluidContainer
        and self.world.consumptionSource and self.world:consumptionSource(item, source) then
        return ground:getFluidContainer()
    end
end

function TillFull:inspect(record)
    local sourceProblem = self:sourceProblem(record)
    if sourceProblem then return nil, sourceProblem end
    local item = record.item
    local protected, reason = self.world:protected(item, {allowFavorite = true, allowEquippedConsumption = true})
    if protected then return nil, "Protected: " .. tostring(reason or "selected item") end
    local opening = self.openingRecipe and not record.opened and (item:isSealed()
        or (self.kind == "food" and item:getScriptItem():isCantEat()))
    if item:isSealed() and not opening then return nil, "Open this item normally before using Til Full" end
    local hunger, thirst
    if self.kind == "food" then
        if not instanceof(item, "Food") or not safeFood(item) or (not opening and item:getScriptItem():isCantEat()) then return nil, "This food is not safe to consume automatically" end
        local required = item.getRequireInHandOrInventory and item:getRequireInHandOrInventory()
        if required and required:size() > 0 then return nil, "Use the normal Eat action for food requiring another item" end
        if opening then return {opening = true} end
        hunger, thirst = -item:getHungerChange(), -item:getThirstChange()
    else
        if instanceof(item, "Food") and not safeFood(item) then return nil, "This fluid's food container is unsafe" end
        local fluid = self:fluidFor(item)
        if not fluid or fluid:getCapacity() > 3 then return nil, "Use an open drinking vessel" end
        hunger, thirst = fluidEffects(fluid, opening)
        if hunger == nil then return nil, thirst end
    end
    if not finite(hunger) or not finite(thirst) then return nil, "The item's nutrition is unavailable" end
    return {hunger = hunger, thirst = thirst, opening = opening}
end

function TillFull:alreadySatisfied()
    local hunger, thirst = needs(self.player)
    if not self.both then return (self.kind == "food" and hunger <= 0) or (self.kind == "fluid" and thirst <= 0) end
    local effects = self:inspect(self.records[self.index])
    if not effects then return false end
    -- Closed cans expose no relief values. Do not open one solely to discover
    -- whether it helps thirst after hunger is already satisfied.
    if effects.opening and self.kind == "food" then return hunger <= 0 end
    local portion = TillFull.portion(hunger, thirst, effects.hunger, effects.thirst, true, self.kind)
    return portion ~= nil and portion <= 0
end

function TillFull:finish(state, reason)
    self.state, self.reason = state, reason
    self.records, self.inflight, self.confirmation, self.opening = nil, nil, nil, nil
end

function TillFull:isBusy() return self.state == "running" or self.state == "cancelling" end
function TillFull:status()
    return {state = self.state, reason = self.reason, done = self.count, total = self.total or (self.records and #self.records or self.count),
        moved = 0, skipped = 0, reasons = {}, hasJob = self:isBusy(), canPreview = not self:isBusy(), canResume = false, canPause = false,
        action = "consume", intent = "consume:" .. self.kind}
end
function TillFull:cancel()
    if not self:isBusy() then return true end
    self.state, self.reason = "cancelling", "Til Full cancelled"
    if self.native:isBusy() then self.native:cancel() else self:finish("cancelled", self.reason) end
    return true
end

-- Native perform() only retires the client action. In multiplayer, complete()
-- applies nutrition and item changes later. A stat fluctuation alone is not an
-- acknowledgement of our requested portion; wait for that exact item quantity.
function TillFull:remaining(item, kind)
    if not item:getContainer() then
        if item.getWorldItem and item:getWorldItem() then return nil end
        return 0
    end
    if kind == "food" then return math.max(0, -item:getHungChange()) end
    local fluid = self:fluidFor(item)
    if not fluid then return nil end
    if fluid:isEmpty() then return 0 end
    return fluid:getFilledRatio()
end

function TillFull:step()
    if not self:isBusy() then return end
    self.total = self.total or #self.records
    local hunger, thirst = needs(self.player)
    if self.inflight then
        local before = self.inflight
        -- Native metabolism continues while an action is running. Account only
        -- for increases actually observed, not a guessed nutrition allowance.
        before.hungerDrift = before.hungerDrift + math.max(0, hunger - before.lastHunger)
        before.thirstDrift = before.thirstDrift + math.max(0, thirst - before.lastThirst)
        before.lastHunger, before.lastThirst = hunger, thirst
    end
    if self.native:isBusy() then
        local done, reason, opened, receipt = self.native:poll()
        if done == nil then return end
        if self.state == "cancelling" then self:finish("cancelled", self.reason); return end
        if self.stopReason then self:finish("cancelled", self.stopReason); return end
        if self.targetReached then self:finish("finished", "The selected need target is satisfied"); return end
        if not done then self:finish("cancelled", reason or "Native consumption was interrupted"); return end
        if self.opening then
            self.opening = nil
            if reason == "chooseOpened" and not opened and self.kind == "food" and self.openingRecipe
                and isClient and isClient() and self.count == 0 then
                if hunger <= 0 then self:finish("finished", "The selected need target is satisfied"); return end
                if self.player:isDead() or self.player:isAsleep() then
                    self:finish("cancelled", "The player cannot consume now"); return
                end
                self.openedFoodPrompt = "When the opened food appears, right-click it and choose Eat > Til Full."
                self:finish("finished", self.openedFoodPrompt)
                return
            end
            if reason ~= "opened" or not opened then
                self:finish("failed", "The opened item was not confirmed"); return
            end
            -- The adapter supplies only the causally identified native output.
            -- Never discover another item by type or position in the inventory.
            local previous = self.records[self.index]
            local source = self.player:getInventory()
            if opened:getID() == previous.id and tostring(opened:getFullType()) == previous.fullType
                and (opened == previous.item or self.kind == "fluid") then source = previous.source end
            self.records[self.index] = {item = opened, id = opened:getID(), fullType = tostring(opened:getFullType()),
                source = source, opened = true, dispatched = true}
        else
            self.inflight.receipt = receipt
            self.confirmation = getTimestampMs() + 2000
        end
    end
    if self.state == "cancelling" then self:finish("cancelled", self.reason); return end
    if self.player:isDead() or self.player:isAsleep() then self:finish("cancelled", "The player cannot consume now"); return end
    if self.confirmation then
        local record = self.records[self.index]
        local resolutionProblem = self:resolveTransferred(record, true)
        if resolutionProblem then self:finish("failed", resolutionProblem); return end
        local before = self.inflight
        local hungerConfirmed = hunger <= before.expectedHunger + before.hungerDrift + 0.000001
        local thirstConfirmed = thirst <= before.expectedThirst + before.thirstDrift + 0.000001
        local improved = self.kind == "food" and hungerConfirmed or self.kind == "fluid" and thirstConfirmed
        if self.both then
            improved = (before.hrelief <= 0 or hungerConfirmed) and (before.trelief <= 0 or thirstConfirmed)
        end
        local receipt = before.receipt
        local measured = receipt and (not isClient or not isClient()) and receipt.item == before.item
            and before.item:getID() == before.id and finite(receipt.hunger) and finite(receipt.thirst)
            and receipt.hunger >= 0 and receipt.thirst >= 0
        if receipt then
            -- Single-player native consumption can coincide with metabolism in
            -- the same frame. Only direct native-call relief resolves that gap;
            -- client action completion never serves as a multiplayer receipt.
            hungerConfirmed = measured and receipt.hunger + 0.000001 >= before.requiredHunger
            thirstConfirmed = measured and receipt.thirst + 0.000001 >= before.requiredThirst
            improved = self.kind == "food" and hungerConfirmed or self.kind == "fluid" and thirstConfirmed
            if self.both then
                improved = (before.hrelief <= 0 or hungerConfirmed) and (before.trelief <= 0 or thirstConfirmed)
            end
        end
        local quantity = self:remaining(before.item, self.kind)
        if record.identityUnresolved then
            quantity = record.seenInMain and record.absentAtEndpoints and before.expectedRemaining <= 0 and 0 or nil
        end
        local consumed = finite(quantity) and quantity <= before.expectedRemaining + 0.000001
        if before.partial then
            consumed = not record.identityUnresolved and finite(quantity)
                and math.abs(quantity - before.expectedRemaining) <= 0.000001
        end
        -- Only complete items may continue the bounded selected stack. A
        -- delayed client stat acknowledgement may be accepted at display
        -- precision, but cannot increase the original remaining need budget.
        if not improved and consumed and quantity == 0 and not before.partial and before.expectedRemaining <= 0
            and (record.identityUnresolved or not self:sourceProblem(record))
            and isClient and isClient() and not receipt and getTimestampMs() >= self.confirmation then
            local function displayAck(strict, initial, current, expected, required)
                return strict or (initial >= 0.01 and required >= 0.01
                    and math.floor((initial - current) * 100 + 0.5) >= 1
                    and math.floor(math.abs(current - expected) * 100 + 0.5) == 0)
            end
            local h = displayAck(hungerConfirmed, before.hunger, hunger, before.expectedHunger, before.requiredHunger)
            local t = displayAck(thirstConfirmed, before.thirst, thirst, before.expectedThirst, before.requiredThirst)
            local acknowledged = self.kind == "food" and h or self.kind == "fluid" and t
            if self.both then acknowledged = (before.hrelief <= 0 or h) and (before.trelief <= 0 or t) end
            if acknowledged then
                improved = true
                self.needCap = {hunger = math.min(self.needCap and self.needCap.hunger or math.huge, before.budgetHunger),
                    thirst = math.min(self.needCap and self.needCap.thirst or math.huge, before.budgetThirst)}
            end
        end
        -- Need and item packets may arrive in either order. Never advance from
        -- an intermediate progress update or an unrelated need improvement.
        if not improved or not consumed then
            if getTimestampMs() < self.confirmation then return end
            -- Client updates conceal metabolism. This terminal-only outcome
            -- never permits another bite, and never claims literal fullness.
            local substantialHunger = hungerConfirmed or (before.hunger >= 0.01
                and hunger < before.hunger and math.floor(hunger * 100 + 0.5) == 0)
            local substantialThirst = thirstConfirmed or (before.thirst >= 0.01
                and thirst < before.thirst and math.floor(thirst * 100 + 0.5) == 0)
            local substantial = self.kind == "food" and substantialHunger or self.kind == "fluid" and substantialThirst
            if self.both then
                substantial = (before.hrelief <= 0 or substantialHunger) and (before.trelief <= 0 or substantialThirst)
            end
            if isClient and isClient() and not receipt and before.partial
                and not record.identityUnresolved and not self:sourceProblem(record)
                and finite(quantity) and math.abs(quantity - before.expectedRemaining) <= 0.000001
                and substantial then
                self.count = self.count + 1
                self:finish("finished", "Requested portion consumed; no more items were queued"); return
            end
            self:finish("failed", "Consumption was not fully confirmed; no more items were queued"); return
        end
        self.count = self.count + 1
        if self.needCap then
            self.needCap.hunger = math.min(self.needCap.hunger, before.budgetHunger)
            self.needCap.thirst = math.min(self.needCap.thirst, before.budgetThirst)
        end
        -- A planned partial had enough nutrition by construction. Floating
        -- subtraction or new metabolism is never permission for another bite.
        if before.partial then
            self:finish("finished", measured and "The requested portion satisfied the need measured before consumption"
                or "Requested portion consumed; no more items were queued")
            return
        end
        self.confirmation, self.inflight = nil, nil
        local current = self.records[self.index]
        local depleted = not current.item:getContainer()
        if self.kind == "fluid" then
            local fluid = self:fluidFor(current.item)
            depleted = depleted or (fluid and fluid:isEmpty())
        end
        if self.kind == "food" then depleted = depleted or current.item:getHungChange() >= 0 end
        if depleted then self.index = self.index + 1 end
    end
    local record = self.records[self.index]
    if not record then self:finish("finished", "The selected stack is exhausted"); return end
    local effects, reason = self:inspect(record)
    if not effects then self:finish("cancelled", reason); return end
    local planHunger = math.min(hunger, self.needCap and self.needCap.hunger or hunger)
    local planThirst = math.min(thirst, self.needCap and self.needCap.thirst or thirst)
    -- A closed can has no native hunger relief until its replacement exists.
    local portion = effects.opening and self.kind == "food" and (planHunger > 0 and 1 or 0)
        or TillFull.portion(planHunger, planThirst, effects.hunger, effects.thirst, self.both, self.kind)
    if portion == nil then self:finish("cancelled", "This item cannot restore the need selected by Eat or Drink"); return end
    if portion <= 0 then self:finish("finished", "The selected need target is satisfied"); return end
    if self.attempts >= 256 then self:finish("cancelled", "Til Full reached its bounded action limit"); return end
    if effects.opening then
        self.opening = true
        record.dispatched = true
        local ok, failure = self.native:beginOpen(record.item, self.kind, self.openingRecipe, function()
            local current, problem = self:inspect(record)
            if not current then
                self.stopReason = problem or "The selected item is no longer safe to open"
                return true
            end
            local h, t = needs(self.player)
            local fraction = current.opening and self.kind == "food" and (h > 0 and 1 or 0)
                or TillFull.portion(h, t, current.hunger, current.thirst, self.both, self.kind)
            self.targetReached = fraction ~= nil and fraction <= 0
            return self.targetReached
        end)
        self.attempts = self.attempts + 1
        if not ok then
            self.reason = failure or "The native opening action could not start"
            if self.native:isBusy() then self.state = "cancelling" else self:finish("cancelled", self.reason) end
        end
        return
    end
    local quantity = self:remaining(record.item, self.kind)
    if not finite(quantity) or quantity <= 0 then self:finish("cancelled", "The selected quantity is unavailable"); return end
    local expectedRemaining = quantity * (1 - portion)
    local expectedHunger = math.max(0, hunger - math.max(0, effects.hunger) * portion)
    local expectedThirst = math.max(0, thirst - math.max(0, effects.thirst) * portion)
    local partial = portion < 1
    if self.kind == "food" then
        local base, remaining = record.item:getBaseHunger(), record.item:getHungChange()
        if not finite(base) or not finite(remaining) or base >= 0 or remaining >= 0 then
            self:finish("cancelled", "The native food portion cannot be measured safely"); return
        end
        portion = math.min(1, portion * remaining / base)
    end
    if not finite(portion) or portion <= 0 then self:finish("cancelled", "The native portion is invalid"); return end
    self.inflight = {hunger = hunger, thirst = thirst, hrelief = effects.hunger, trelief = effects.thirst,
        item = record.item, id = record.id, expectedRemaining = expectedRemaining,
        partial = partial,
        budgetHunger = math.max(0, planHunger - math.max(0, effects.hunger) * (quantity - expectedRemaining) / quantity),
        budgetThirst = math.max(0, planThirst - math.max(0, effects.thirst) * (quantity - expectedRemaining) / quantity),
        requiredHunger = hunger - expectedHunger, requiredThirst = thirst - expectedThirst,
        lastHunger = hunger, lastThirst = thirst, hungerDrift = 0, thirstDrift = 0,
        expectedHunger = expectedHunger, expectedThirst = expectedThirst}
    record.dispatched = true
    record.confirmationAudited = nil
    record.seenInMain = record.item:getContainer() == self.player:getInventory()
    local ok, failure = self.native:begin(record.item, self.kind, portion, function()
        local changed = self:sourceProblem(record, true) ~= nil
        local item = record.item
        local protected = self.world:protected(item, {allowFavorite = true, allowEquippedConsumption = true})
        local unsafe = item:isSealed() or (instanceof(item, "Food") and not safeFood(item))
        if self.kind == "fluid" then
            local fluid = self:fluidFor(item)
            if not fluid then unsafe = true
            elseif not fluid:isEmpty() then
                local hrelief, trelief = fluidEffects(fluid)
                unsafe = unsafe or not finite(hrelief) or not finite(trelief)
                    or (finite(hrelief) and (hrelief > 0) ~= (effects.hunger > 0))
                    or (finite(trelief) and (trelief > 0) ~= (effects.thirst > 0))
            end
        end
        if protected or changed or unsafe then
            self.stopReason = "The selected item is no longer safe to consume automatically"
            return true
        end
        local h, t = needs(self.player)
        local fraction = TillFull.portion(h, t, effects.hunger, effects.thirst, self.both, self.kind)
        self.targetReached = fraction ~= nil and fraction <= 0
        return self.targetReached
    end, function() return needs(self.player) end)
    self.attempts = self.attempts + 1
    if not ok then
        self.reason = failure or "The native action could not start"
        if self.native:isBusy() then self.state = "cancelling" else self:finish("cancelled", self.reason) end
    end
end

function TillFull:tick()
    local ok, reason = pcall(self.step, self)
    if not ok then
        self.reason = "Til Full stopped safely: " .. tostring(reason)
        self.state = "cancelling"
        if self.native:isBusy() then self.native:cancel() else self:finish("failed", self.reason) end
    end
end

return TillFull

