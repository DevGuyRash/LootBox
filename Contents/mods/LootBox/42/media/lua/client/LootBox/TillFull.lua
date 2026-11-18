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

function TillFull.new(player, world, items, kind, both, openingRecipe)
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
            records[#records + 1] = record
            if #records > 4096 then return nil, "Choose a bounded item stack" end
        end
    end
    if #records == 0 or #records > 4096 then return nil, "Choose a nonempty bounded item stack" end
    return setmetatable({player = player, world = world, records = records, kind = kind, both = both == true,
        index = 1, count = 0, native = Adapter.new(player), state = "running", attempts = 0, openingRecipe = openingRecipe}, TillFull)
end

function TillFull:inspect(record)
    local item, source = record.item, record.item:getContainer()
    if item:getID() ~= record.id or tostring(item:getFullType()) ~= record.fullType or not source
        or (source ~= record.source and source ~= self.player:getInventory()) then return nil, "The selected item moved or changed" end
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
        local fluid = item:getFluidContainer()
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
local function remaining(item, kind)
    if not item:getContainer() then return 0 end
    if kind == "food" then return math.max(0, -item:getHungChange()) end
    local fluid = item:getFluidContainer()
    if not fluid or fluid:isEmpty() then return 0 end
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
        local done, reason, opened = self.native:poll()
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
            if opened == previous.item and opened:getID() == previous.id then source = previous.source end
            self.records[self.index] = {item = opened, id = opened:getID(), fullType = tostring(opened:getFullType()),
                source = source, opened = true}
        else
            self.confirmation = getTimestampMs() + 2000
        end
    end
    if self.state == "cancelling" then self:finish("cancelled", self.reason); return end
    if self.player:isDead() or self.player:isAsleep() then self:finish("cancelled", "The player cannot consume now"); return end
    if self.confirmation then
        local before = self.inflight
        local hungerConfirmed = hunger <= before.expectedHunger + before.hungerDrift + 0.000001
        local thirstConfirmed = thirst <= before.expectedThirst + before.thirstDrift + 0.000001
        local improved = self.kind == "food" and hungerConfirmed or self.kind == "fluid" and thirstConfirmed
        if self.both then
            improved = (before.hrelief <= 0 or hungerConfirmed) and (before.trelief <= 0 or thirstConfirmed)
        end
        local quantity = remaining(before.item, self.kind)
        local consumed = finite(quantity) and quantity <= before.expectedRemaining + 0.000001
        -- Need and item packets may arrive in either order. Never advance from
        -- an intermediate progress update or an unrelated need improvement.
        if not improved or not consumed then
            if getTimestampMs() < self.confirmation then return end
            self:finish("failed", "Consumption was not fully confirmed; no more items were queued"); return
        end
        self.count = self.count + 1
        self.confirmation, self.inflight = nil, nil
        local current = self.records[self.index]
        local depleted = not current.item:getContainer()
        if self.kind == "fluid" and current.item:getFluidContainer() then depleted = depleted or current.item:getFluidContainer():isEmpty() end
        if self.kind == "food" then depleted = depleted or current.item:getHungChange() >= 0 end
        if depleted then self.index = self.index + 1 end
    end
    local record = self.records[self.index]
    if not record then self:finish("finished", "The selected stack is exhausted"); return end
    local effects, reason = self:inspect(record)
    if not effects then self:finish("cancelled", reason); return end
    -- A closed can has no native hunger relief until its replacement exists.
    local portion = effects.opening and self.kind == "food" and (hunger > 0 and 1 or 0)
        or TillFull.portion(hunger, thirst, effects.hunger, effects.thirst, self.both, self.kind)
    if portion == nil then self:finish("cancelled", "This item cannot restore the need selected by Eat or Drink"); return end
    if portion <= 0 then self:finish("finished", "The selected need target is satisfied"); return end
    if self.attempts >= 256 then self:finish("cancelled", "Til Full reached its bounded action limit"); return end
    if effects.opening then
        self.opening = true
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
    local quantity = remaining(record.item, self.kind)
    if not finite(quantity) or quantity <= 0 then self:finish("cancelled", "The selected quantity is unavailable"); return end
    local expectedRemaining = quantity * (1 - portion)
    local expectedHunger = math.max(0, hunger - math.max(0, effects.hunger) * portion)
    local expectedThirst = math.max(0, thirst - math.max(0, effects.thirst) * portion)
    if self.kind == "food" then
        local base, remaining = record.item:getBaseHunger(), record.item:getHungChange()
        if not finite(base) or not finite(remaining) or base >= 0 or remaining >= 0 then
            self:finish("cancelled", "The native food portion cannot be measured safely"); return
        end
        portion = math.min(1, portion * remaining / base)
    end
    if not finite(portion) or portion <= 0 then self:finish("cancelled", "The native portion is invalid"); return end
    self.inflight = {hunger = hunger, thirst = thirst, hrelief = effects.hunger, trelief = effects.thirst,
        item = record.item, expectedRemaining = expectedRemaining,
        lastHunger = hunger, lastThirst = thirst, hungerDrift = 0, thirstDrift = 0,
        expectedHunger = expectedHunger, expectedThirst = expectedThirst}
    local ok, failure = self.native:begin(record.item, self.kind, portion, function()
        local item = record.item
        local protected = self.world:protected(item, {allowFavorite = true, allowEquippedConsumption = true})
        local source = item:getContainer()
        local changed = item:getID() ~= record.id or tostring(item:getFullType()) ~= record.fullType
            or (source and source ~= record.source and source ~= self.player:getInventory())
        local unsafe = item:isSealed() or (instanceof(item, "Food") and not safeFood(item))
        if self.kind == "fluid" then
            local fluid = item:getFluidContainer()
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
    end)
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

