-- Opening a closed food or drink with the game's own recipe, and recognising
-- what came out: the same item unsealed, or a new one.
local Items = require "LootBox/Items"
local Vessels = require "LootBox/Vessels"
local Log = require "LootBox/Log"

local Opening = {}
-- The game shows these as a plain craft row, not among its Eat and Drink
-- amounts. Knives can injure and bulk packs hold many, so neither is here.
local plain = { OpenCanOfBeverage = "fluid", OpenWaterRationCan = "fluid", OpenUnlabeledCan = "food", OpenDentedUnlabeledCan = "food",
    OpenCannedFood = "food", OpenCannedFood2 = "food", OpenJarOfFood = "food" }
local SAFE, SHARP = "OpenCannedFood", "OpenCannedFoodWithKnifeOrSharpStoneFlake"

local function call(site, fn, ...) return Log.guard("Opening." .. site, fn, ...) end

local function slotOf(player, item, recipe) return CraftRecipeManager.getValidInputScriptForItem(recipe, item, player) end

-- The recipe unseals the item it is given instead of replacing it.
function Opening.keeps(player, item, recipe)
    return call("keeps", function()
        local slot = slotOf(player, item, recipe)
        return slot ~= nil and slot:isKeep() == true
    end) == true
end

-- Some opened foods are drunk: eaten with the food action, but for thirst.
function Opening.drinks(item, recipe)
    return call("drinks", function()
        if recipe and (item:getFullType() == "Base.CannedMilk" or item:getFullType() == "Base.CannedFruitBeverage")
            and recipe:getName() == SAFE then return true end
        local option = item:getCustomMenuOption()
        return option ~= nil and option == getText("ContextMenu_Drink")
    end) == true
end

-- "food", "drinkFood" or "fluid" when a plain craft row opens this item.
function Opening.kind(player, item, recipe)
    return call("kind", function()
        local kind = recipe:isVanilla() and plain[recipe:getName()]
        local slot = kind and slotOf(player, item, recipe)
        if not slot or recipe:getOutputCount() > 1 then return nil end
        if slot:isKeep() then
            return kind == "fluid" and item:isSealed() and slot:hasFlag(InputFlag.Unseal) and Vessels.fluid(item) and "fluid" or nil
        end
        if not instanceof(item, "Food") then return nil end
        return kind == "food" and Opening.drinks(item, recipe) and "drinkFood" or kind
    end)
end

-- The game hides Eat and Drink from a full stomach even where Open stays.
function Opening.allowed(player, item, kind)
    return call("allowed", function()
        local full = player:getMoodles():getMoodleLevel(MoodleType.FOOD_EATEN) >= 3
        local fluid = kind == "fluid" and Vessels.fluid(item)
        if not fluid then return not full end
        return not fluid:isEmpty() and fluid:getCapacity() <= 3 and (not full or fluid:getProperties():getHungerChange() == 0)
    end) == true
end

-- Ready to be consumed as this kind.
function Opening.usable(item, kind)
    if item:isSealed() then return false end
    if kind == "fluid" then
        local fluid = Vessels.fluid(item)
        return fluid ~= nil and not fluid:isEmpty()
    end
    return instanceof(item, "Food") == true and not item:getScriptItem():isCantEat()
end

-- The one type the recipe turns this item into, when it says so.
local function expected(item, recipe)
    local outputs = recipe:getOutputs()
    if outputs:size() ~= 1 then return nil end
    local mapper = outputs:get(0):getOutputMapper()
    local results = mapper and mapper:getResultItems()
    for index = 0, (results and results:size() or 0) - 1 do
        local script = results:get(index)
        local pattern = mapper:getPatternForResult(script)
        if pattern and pattern:contains(item:getScriptItem()) then return script:getFullName() end
    end
end

-- Follows what opening this item produces. Begin before the recipe starts.
function Opening.watch(player, item, recipe, kind, interaction)
    local keeps, only = Opening.keeps(player, item, recipe), call("expected", expected, item, recipe)
    return Items.watch(player, { item = item, interaction = interaction,
        ready = keeps and function(survivor) return Opening.usable(survivor, kind) end or nil,
        makes = not keeps and function(made)
            -- The game may auto-drink a vessel the moment it appears, so it may be empty.
            local right = kind == "fluid" and Vessels.fluid(made) ~= nil and not made:isSealed() or Opening.usable(made, kind)
            if not right or only and made:getFullType() ~= only then return false end
            return made:getModData().NoLabel and 2 or only and 1 or 0
        end or nil })
end

-- The recipe the game bound really uses this item.
function Opening.binds(action, id)
    local found = false
    for _, list in pairs(action.manualInputs or {}) do
        for index = 0, list:size() - 1 do found = found or list:get(index):getID() == id end
    end
    local items = action.items
    for index = 0, (items and items:size() or 0) - 1 do found = found or items:get(index):getID() == id end
    return found
end

-- Queues the game's own opening, which also fetches and returns the opener.
function Opening.queue(player, item, recipe)
    ISInventoryPaneContextMenu.OnNewCraft(item, recipe, player:getPlayerNum(), false, 0)
end

local function single(value)
    local list = ArrayList.new()
    list:add(value)
    return list
end

local function surface(player)
    local found = HandcraftLogic.new(player, nil, nil):findCraftSurface(player, 2)
    local square, here = found and found:getSquare(), player:getCurrentSquare()
    if not square or not here or square:getZ() ~= here:getZ() then return nil end
    local distance = math.abs(square:getX() - here:getX()) + math.abs(square:getY() - here:getY())
    return distance <= 1 and (distance == 0 or not here:isBlockedTo(square)) and found or nil
end

local function slots(player, item, name)
    local recipe = getScriptManager():getCraftRecipe(name)
    if not recipe or not recipe:isVanilla() or not (recipe:canBeDoneInDark() or not player:tooDarkToRead()) then return nil end
    local mine, tool
    for index = 0, recipe:getInputs():size() - 1 do
        local slot = recipe:getInputs():get(index)
        if CraftRecipeManager.isItemValidForInputScript(slot, item, player) then mine = slot else tool = slot end
    end
    return recipe, mine, tool
end

-- What automatic intake may open by itself: a can in the main inventory, with
-- an opener there too, or a knife when the player allows the risk.
function Opening.automatic(player, item, risky, toolAllowed)
    return call("automatic", function()
        local main = player:getInventory()
        if not Items.holds(main, item) or not instanceof(item, "Food") or item:getOpeningRecipe() ~= SAFE
            or not (item:isSealed() or item:getScriptItem():isCantEat()) then return nil end
        for _, name in ipairs(risky and { SAFE, SHARP } or { SAFE }) do
            local recipe, mine, slot = slots(player, item, name)
            local top = name == SHARP and surface(player) or nil
            if recipe and mine and slot and (name == SAFE or top) then
                for index = 0, main:getItems():size() - 1 do
                    local tool = main:getItems():get(index)
                    if tool ~= item and not tool:isFavorite() and CraftRecipeManager.isItemValidForInputScript(slot, tool, player)
                        and toolAllowed(tool) then
                        return { item = item, kind = "food", recipe = recipe, tool = tool, itemSlot = mine, toolSlot = slot, surface = top,
                            risky = name == SHARP }
                    end
                end
            end
        end
    end)
end

function Opening.queueAutomatic(player, plan)
    require "Entity/TimedActions/ISHandcraftAction"
    local logic = HandcraftLogic.new(player, nil, plan.surface)
    logic:setContainers(single(player:getInventory()))
    logic:setRecipeFromContextClick(plan.recipe, plan.item)
    logic:setManualSelectInputs(true)
    logic:clearManualInputs()
    if not logic:setManualInputsFor(plan.itemSlot, single(plan.item)) or not logic:setManualInputsFor(plan.toolSlot, single(plan.tool))
        or not logic:canPerformCurrentRecipe() then return end
    ISTimedActionQueue.add(ISHandcraftAction.FromLogic(logic, 0))
end

return Opening
