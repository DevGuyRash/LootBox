-- Eats or drinks the chosen stack until the chosen need is met, opening items
-- first where needed. Every portion comes from the live item and need.
local Flow = require "LootBox/Flow"
local Items = require "LootBox/Items"
local Opening = require "LootBox/Opening"
local Vessels = require "LootBox/Vessels"
local Log = require "LootBox/Log"
local TillFull = Flow.class()
local MAX_STACK = 512

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

local restrictedFluidCategories = {"Medical", "Fuel", "Industrial", "Colors", "Dyes", "HairDyes",
    "Paint", "Poisons", "Drug", "Blood"}

local function safeFluidPart(part, strict)
    local beverage = part:isCategory(FluidCategory.Beverage)
    local water = part:isCategory(FluidCategory.Water)
    local props = part:getProperties()
    if not (beverage or water) or part:isCategory(FluidCategory.Hazardous) or part:isCategory(FluidCategory.Alcoholic)
        or part:isPoisonous() or props:getPoison() > 0 or props:getAlcohol() > 0
        or props:getFoodSicknessChange() > 0 then return false end
    if strict then
        for _, name in ipairs(restrictedFluidCategories) do
            local category = FluidCategory[name]
            if category and part:isCategory(category) then return false end
        end
        -- When this build exposes the Java collection, fail closed on other
        -- categories even if a beverage flag is also present.
        if part.getCategories then
            local known, size = pcall(function() return part:getCategories():size() end)
            if known and size ~= (beverage and 1 or 0) + (water and 1 or 0) then return false end
        end
    end
    return true
end

local function fluidEffects(fluid, opening, strict)
    local properties = fluid:getProperties()
    if properties:getAlcohol() > 0 then return nil, "Til Full does not drink alcohol; choose a normal Drink amount instead" end
    if fluid:isEmpty() or (not opening and not fluid:canPlayerEmpty()) or fluid:isPoisonous() or fluid:isTainted()
        or properties:getPoison() > 0 or properties:getFoodSicknessChange() > 0 then
        return nil, "This drink is empty, sealed, or unsafe"
    end
    if strict and fluid.isMixture and fluid.getPrimaryFluid and fluid:isMixture() == false then
        local primary = fluid:getPrimaryFluid()
        if not primary or not safeFluidPart(primary, true) then return nil, "This fluid cannot be safely consumed automatically" end
    else
        local sample = fluid:createFluidSample()
        local ok, safe = pcall(function()
            local observed = false
            for index = 0, sample:size() - 1 do
                local proportion = sample:getPercentage(index)
                if strict and (not finite(proportion) or proportion < 0) then return false end
                if proportion > 0 then
                    observed = true
                    if not safeFluidPart(sample:getFluid(index), strict) then return false end
                end
            end
            return not strict or observed
        end)
        sample:release()
        if not ok then Log.fault(nil, "TillFull.fluidEffects", safe) end
        if not ok or not safe then return nil, "This fluid mixture cannot be safely consumed automatically" end
    end
    return -properties:getHungerChange(), -properties:getThirstChange()
end

-- Automatic intake needs positive relief and must not apply a second harmful
-- need effect or bypass a scripted Eat/Drink requirement. Manual choices retain
-- their existing item and recipe policy.
function TillFull.automaticEffects(item, kind, opening)
    local ok, hunger, thirst = pcall(function()
        if not item or opening or item:isSealed() or (item.isMedical and item:isMedical()) then return end
        if ItemTag and item.hasTag and ((ItemTag.SMOKABLE and item:hasTag(ItemTag.SMOKABLE))
            or (ItemTag.MEDICAL and item:hasTag(ItemTag.MEDICAL))) then return end
        local menu = item.getCustomMenuOption and item:getCustomMenuOption()
        if menu and menu ~= "" and (not getText or (menu ~= getText("ContextMenu_Eat") and menu ~= getText("ContextMenu_Drink"))) then return end
        local food = instanceof(item, "Food")
        if food then
            local onEat = item.getOnEat and item:getOnEat()
            local required = item.getRequireInHandOrInventory and item:getRequireInHandOrInventory()
            if not safeFood(item) or (onEat and onEat ~= "") or (required and required:size() ~= 0) then return end
        end
        if kind == "food" and food then
            if item:getScriptItem():isCantEat() then return end
            return -item:getHungerChange(), -item:getThirstChange()
        elseif kind == "fluid" then
            local fluid = item:getFluidContainer()
            if fluid and finite(fluid:getCapacity()) and fluid:getCapacity() <= 3 then
                return fluidEffects(fluid, false, true)
            end
        end
    end)
    if not ok then Log.fault(nil, "TillFull.automaticEffects", hunger) end
    if not ok or not finite(hunger) or not finite(thirst) or hunger < 0 or thirst < 0
        or (kind == "food" and hunger <= 0) or (kind == "fluid" and thirst <= 0) then return end
    return {hunger = hunger, thirst = thirst}
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

local GONE = "The selected item moved or is gone"

-- opts: kind ("food", "drinkFood" or "fluid"), both, recipe, source (where the
-- menu saw the stack) and, for background intake, automatic = { guard, plan }.
function TillFull.new(player, world, items, opts)
    local drinkFood = opts.kind == "drinkFood"
    local kind = drinkFood and "food" or opts.kind
    local records, seen = {}, {}
    for _, item in ipairs(items) do
        local id = item:getID()
        if not seen[id] and #records < MAX_STACK then
            seen[id] = true
            records[#records + 1] = { id = id, item = item, fullType = item:getFullType(), source = opts.source or item:getContainer() }
        end
    end
    if #records == 0 then return nil, "Choose an item" end
    local self = Flow.begin(TillFull, player, items.interaction or opts.interaction, { world = world, records = records, index = 1,
        kind = kind, goal = drinkFood and "fluid" or kind, drinkFood = drinkFood, both = opts.both == true, recipe = opts.recipe,
        automatic = opts.automatic, action = "consume", name = "Til Full", total = #records })
    return self
end

function TillFull:status()
    local status = Flow.status(self)
    status.intent, status.moved = "consume:" .. self.goal, 0
    return status
end

-- Whether consuming this selection now would do anything at all.
function TillFull.offers(player, world, items, opts)
    local job, problem = TillFull.new(player, world, items, opts)
    if not job then return false, problem end
    local effects, reason = job:inspect(job.records[1])
    if not effects then return false, reason end
    local hunger, thirst = needs(player)
    local portion = job:plannedPortion(hunger, thirst, effects)
    if portion == nil then return false, "This item cannot restore the need selected by Eat or Drink" end
    return portion > 0, string.format("no need: hunger %.3f, thirst %.3f", hunger, thirst)
end

-- The item as it is now, if it can still be reached.
function TillFull:locate(record)
    local item, holder, place = Items.find(self.player, record.id, { record.source })
    if not item or item:getFullType() ~= record.fullType then return nil, GONE end
    if place == "ground" and not holder then
        -- The loot window adopts what the game has just dropped.
        local page = getPlayerLoot(self.player:getPlayerNum())
        if page then page:refreshBackpacks() end
        holder = item:getContainer()
    end
    if place ~= "carried" then
        if not holder then return nil, "It is on the ground beside you; pick it up first" end
        local ok, reason = self.world:consumptionSource(item, holder)
        if not ok then return nil, reason or GONE end
        if not self.player:getInventory():hasRoomFor(self.player, item) then
            return nil, place == "ground" and "You carry too much: it is at your feet" or "You carry too much to take it"
        end
    end
    record.item = item
    return item, holder, place
end

-- What the item would do now, or that it must be opened, or why not.
function TillFull:inspect(record)
    local item, why = self:locate(record)
    if not item then return nil, why end
    if self.automatic then
        local guarded, reason = self.automatic.guard(item, record.source, not record.opened and self.automatic.plan or nil)
        if not guarded then return nil, reason or "Automatic intake is no longer permitted" end
        if self.automatic.plan and not record.opened then return { opening = true } end
        local effects = TillFull.automaticEffects(item, self.kind)
        return effects, effects == nil and "This is not safe to consume automatically" or nil
    end
    local protected, reason = self.world:protected(item, { allowFavorite = true, allowEquippedConsumption = true })
    if protected then return nil, "Protected: " .. tostring(reason or "selected item") end
    local opening = self.recipe ~= nil and not record.opened
    if opening and not Opening.allowed(self.player, item, self.kind) then return nil, "You are too full" end
    if not opening and item:isSealed() then return nil, "Open this item first" end
    if instanceof(item, "Food") and not safeFood(item) then return nil, "This food is not safe" end
    if self.kind == "food" then
        if opening then return { opening = true } end
        if not instanceof(item, "Food") or item:getScriptItem():isCantEat() then return nil, "This cannot be eaten" end
        local required = item:getRequireInHandOrInventory()
        if required and required:size() > 0 then return nil, "Use the normal Eat action for food that needs another item" end
        if self.drinkFood and not Opening.drinks(item) then return nil, "This cannot be drunk" end
        return { hunger = -item:getHungerChange(), thirst = -item:getThirstChange() }
    end
    local fluid = Vessels.fluid(item)
    if opening and not fluid then return { opening = true } end
    if not fluid or fluid:getCapacity() > 3 then return nil, "Use a drinking vessel" end
    local hunger, thirst = fluidEffects(fluid, opening)
    if hunger == nil then return nil, thirst end
    return { hunger = hunger, thirst = thirst, opening = opening or nil }
end

function TillFull:plannedPortion(hunger, thirst, effects)
    -- A closed package has no nutrition of its own: open it when it can help.
    if effects.opening and effects.hunger == nil then return (self.goal == "fluid" and thirst or hunger) > 0 and 1 or 0 end
    return TillFull.portion(hunger, thirst, effects.hunger, effects.thirst, self.both, self.goal)
end

function TillFull:alreadySatisfied()
    local hunger, thirst = needs(self.player)
    if not self.both then return (self.goal == "food" and hunger or thirst) <= 0 end
    local effects = self:inspect(self.records[self.index])
    local portion = effects and self:plannedPortion(hunger, thirst, effects)
    return portion ~= nil and portion <= 0
end

function TillFull:next()
    local hunger, thirst = needs(self.player)
    local record = self.records[self.index]
    if not self.logged then
        self.logged = true
        self.interaction = self.interaction or Log.intent("consume", "Til Full", self.player)
        Log.info(self.interaction, "START", "op", "consume", "kind", self.goal, "both", self.both, "automatic", self.automatic ~= nil,
            "opening", self.recipe and self.recipe:getName() or self.automatic and self.automatic.plan ~= nil, "stack", self.total,
            "hunger", hunger, "thirst", thirst, "item", Log.item(record.item, self.player),
            "source", Log.container(record.source, self.player), "player", Log.player(self.player))
    end
    if not record then return self:finish("finished", "Nothing is left of what you chose", "exhausted") end
    -- A server reports needs late: never plan past what was already consumed.
    if self.left then hunger, thirst = math.min(hunger, self.left.hunger), math.min(thirst, self.left.thirst) end
    local effects, why = self:inspect(record)
    local drunk = not effects and record.opened and self.kind == "fluid" and Vessels.fluid(record.item)
    if drunk and drunk:isEmpty() then return self:finish("finished", "You drank it as it was opened", "exhausted") end
    if not effects then return self:finish(self.count > 0 and "finished" or "cancelled", why) end
    local portion = self:plannedPortion(hunger, thirst, effects)
    if portion == nil then return self:finish("cancelled", "This does not help with what you chose") end
    if portion <= 0 then return self:finish("finished", self.goal == "food" and "You are no longer hungry" or "You are no longer thirsty", "target") end
    if effects.opening then return self:open(record) end
    return self:consume(record, portion, effects, hunger, thirst)
end

-- While ours runs, background intake gives way to anything the player does.
function TillFull:permitted()
    local automatic = self.automatic
    if not automatic then return true end
    if self.run and self.run:foreign() then return false, "You started something else" end
    return automatic.guard() == true, "Automatic intake is no longer permitted"
end

function TillFull:open(record)
    local player, automatic = self.player, self.automatic
    local item, recipe = record.item, self.recipe or automatic.plan.recipe
    local watch = Opening.watch(player, item, recipe, self.kind, self.interaction)
    self:act({ op = "open", keepAfter = true,
        main = function(action) return action.Type == "ISHandcraftAction" end,
        allow = function(phase, action)
            if phase == "run" then return self:permitted() end
            if not self:inspect(record) then return false, GONE end
            return Opening.binds(action, record.id), "The game chose a different item to open"
        end,
        begin = function()
            if automatic then Opening.queueAutomatic(player, automatic.plan) else Opening.queue(player, item, recipe) end
        end,
    }, function()
        self:await(function() return watch:find() end, function(made, holder)
            self.records[self.index] = { id = made:getID(), item = made, fullType = made:getFullType(),
                source = holder or made:getContainer() or record.source, opened = true }
        end, function()
            if watch:retired() then return self:finish("failed", "It was opened, but the result is not within reach") end
            return self:finish("failed", "The game did not open it")
        end)
    end)
end

function TillFull:consume(record, portion, effects, hunger, thirst)
    local player, item = self.player, record.item
    local food, whole = self.kind == "food", portion >= 1
    local share = portion
    if food then
        -- The game counts a bite as a share of the whole food, not of the rest.
        local base, rest = item:getBaseHunger(), item:getHungChange()
        if base < 0 and rest < 0 then share = math.min(1, portion * rest / base) end
    end
    Log.trace(self.interaction, "PLAN", "n", self.count + 1, "item", Log.item(item, player), "portion", portion, "share", share,
        "hunger", hunger, "hungerRelief", effects.hunger, "thirst", thirst, "thirstRelief", effects.thirst)
    self:act({ op = "consume", keepAfter = true,
        main = function(action) return action.Type == (food and "ISEatFoodAction" or "ISDrinkFluidAction") end,
        allow = function(phase)
            if phase == "run" then return self:permitted() end
            local now, why = self:inspect(record)
            return now ~= nil and not now.opening, why
        end,
        begin = function()
            if food then ISInventoryPaneContextMenu.eatItem(item, share, player:getPlayerNum())
            else
                local ground = item:getWorldItem()
                local standing = ground and ground:getFluidContainer() and ground or item
                ISInventoryPaneContextMenu.onDrinkFluid(standing, share, player)
            end
        end,
    }, function()
        self.count = self.count + 1
        self.left = { hunger = math.max(0, hunger - math.max(0, effects.hunger) * portion),
            thirst = math.max(0, thirst - math.max(0, effects.thirst) * portion) }
        local newHunger, newThirst = needs(player)
        Log.trace(self.interaction, "CONSUMED", "n", self.count, "whole", whole, "hunger", newHunger, "thirst", newThirst)
        if not whole then return self:finish("finished", self.goal == "food" and "You ate enough" or "You drank enough", "target") end
        self.index = self.index + 1
    end)
end

function TillFull:finish(state, reason, outcome)
    self.outcome = outcome
    return Flow.finish(self, state, reason)
end

function TillFull:card()
    if self.outcome == "target" and self.count == 0 then return nil end
    local portions = self.count .. (self.count == 1 and " portion" or " portions")
    local title = self.outcome == "target" and (self.goal == "food" and "Hunger satisfied" or "Thirst satisfied")
        or self.outcome == "exhausted" and "Stack finished" or self.state == "finished" and "Til Full done" or "Til Full stopped"
    return { title = title, detail = self.count > 0 and { portions } or {}, note = self.outcome == nil and self.reason or nil }
end

return TillFull
