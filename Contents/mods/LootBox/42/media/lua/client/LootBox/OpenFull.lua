-- Identify what the vanilla inventory callback can actually open. A recipe or
-- mapped script type is never an item receipt; portions use the real result.
local OpenFull = {}

local function checked(f, ...)
    local ok, value = pcall(f, ...)
    if ok then return value end
end

function OpenFull.vesselFluid(item)
    local fluid = item:getFluidContainer()
    if fluid then return fluid end
    local source = item:getContainer()
    local ground = item.getWorldItem and item:getWorldItem()
    if source and source.getType and source:getType() == "floor" and ground and ground:getItem() == item
        and ground:getSquare() and ground.getFluidContainer then return ground:getFluidContainer() end
end

local function unsealsSelected(player, item, recipe)
    if not item:isSealed() then return false end
    local slot = CraftRecipeManager.getValidInputScriptForItem(recipe, item, player)
    return slot and slot:isKeep() and slot:hasFlag(InputFlag.IsSealed) and slot:hasFlag(InputFlag.Unseal)
end

function OpenFull.keeps(player, item, recipe)
    return checked(unsealsSelected, player, item, recipe) == true
end

-- These two canned drinks are Food, not FluidContainer. Their opened stock
-- script says Drink, so thirst is the goal but ISEatFoodAction is the adapter.
local function cannedDrink(item, recipe)
    local t = item:getFullType()
    return (t == "Base.CannedMilk" or t == "Base.CannedFruitBeverage") and recipe:isVanilla()
        and recipe:getName() == "OpenCannedFood" and getScriptManager():getCraftRecipe("OpenCannedFood") == recipe
end

function OpenFull.drinkFood(item, recipe)
    if recipe and checked(cannedDrink, item, recipe) then return true end
    return checked(function()
        local cmd = item:getCustomMenuOption()
        return cmd and cmd == getText("ContextMenu_Drink")
    end) == true
end

-- A few installed recipes show as a plain OnNewCraft callback only: notably
-- sealed soda cans and canned fruit beverage have no OpeningRecipe field.
-- Never treat any arbitrary craft, unpack-many, knife, or translated "Open"
-- row as permission. Stock has already tested this recipe on the clicked item.
local function recipeKind(player, item, recipe)
    if not recipe:isVanilla() then return end
    local name = recipe:getName()
    if getScriptManager():getCraftRecipe(name) ~= recipe then return end
    if name == "OpenCanOfBeverage" then
        if recipe:getOutputCount() == 0 and OpenFull.vesselFluid(item)
            and unsealsSelected(player, item, recipe) then return "fluid" end
    elseif name == "OpenCannedFood" or name == "OpenCannedFood2" or name == "OpenJarOfFood" then
        if not instanceof(item, "Food") or recipe:getOutputCount() ~= 1 then return end
        local slot = CraftRecipeManager.getValidInputScriptForItem(recipe, item, player)
        if not slot or slot:isKeep() then return end
        if name == "OpenJarOfFood" or item:getOpeningRecipe() == name
            or (name == "OpenCannedFood" and item:getFullType() == "Base.CannedFruitBeverage") then
            return OpenFull.drinkFood(item, recipe) and "drinkFood" or "food"
        end
    end
end

function OpenFull.recipeKind(player, item, recipe)
    return checked(recipeKind, player, item, recipe)
end

-- The visible recipe can remain craftable even when the game will not offer
-- its Eat/Drink action (full moodle, large vessel). Match those native gates.
function OpenFull.recipeMenuAllowed(player, item, kind, actualFluid)
    return checked(function()
        local full = player:getMoodles():getMoodleLevel(MoodleType.FOOD_EATEN) >= 3
        if kind ~= "fluid" then return not full end
        local fluid = actualFluid or OpenFull.vesselFluid(item)
        return fluid and not fluid:isEmpty() and fluid:getCapacity() <= 3
            and (not full or fluid:getProperties():getHungerChange() == 0)
    end) == true
end

-- Stock fixMovedItems looks up IDs recursively through carried containers.
-- Audit both endpoints, including carried bags that might shadow this ID,
-- without ever selecting a different item by type or looking for "new" rows.
function OpenFull.networkItem(main, source, id, fullType)
    local seen, todo, found, count = {[main]=true}, {main}, nil, 0
    if source ~= main then seen[source], todo[#todo + 1] = true, source end
    for _, container in ipairs(todo) do
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            count = count + 1
            if not item or count > 4096 then return nil, "Could not verify this package's unique identity" end
            if item:getID() == id then
                if found then return nil, "Ambiguous opened item identity" end
                if item:getFullType() ~= fullType or item:getContainer() ~= container
                    or (container ~= main and container ~= source) then return nil, "The selected item identity changed" end
                found = item
            end
            local nested = item.getInventory and item:getInventory()
            if nested and not seen[nested] then
                if #todo >= 128 then return nil, "Could not verify this package's unique identity" end
                seen[nested], todo[#todo + 1] = true, nested
            end
        end
    end
    return found
end

return OpenFull
