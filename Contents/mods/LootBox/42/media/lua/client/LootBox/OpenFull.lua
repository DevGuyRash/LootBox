-- Identify what the vanilla inventory callback can actually open. A recipe or
-- mapped script type is never an item receipt; portions use the real result.
local Log = require "LootBox/Log"
local OpenFull = {}
local packaged={
    OpenWaterRationCan={input="Base.WaterRationCan",kind="fluid"},
    OpenUnlabeledCan={input="Base.MysteryCan",kind="food",event="OpenMysteryCan"},
    OpenDentedUnlabeledCan={input="Base.DentedCan",kind="food",event="OpenDentedCan"},
}
-- Build 42's RecipeCodeOnCreate.mysteryCans list. The cosmetic ID notice
-- still has to match the sole fresh carried food; this is not a selector.
local mysteryOutputs={"CannedBologneseOpen","CannedCarrotsOpen","CannedChiliOpen","CannedCornOpen",
    "CannedFruitCocktailOpen","CannedPeachesOpen","CannedPeasOpen","CannedPineappleOpen",
    "CannedPotatoOpen","CannedTomatoOpen","DogfoodOpen","OpenBeans"}

local function checked(f, ...)
    local ok, value = pcall(f, ...)
    if ok then return value end
    Log.fault(nil, "OpenFull", value)
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
    elseif packaged[name] then
        local p=packaged[name]
        local slot=CraftRecipeManager.getValidInputScriptForItem(recipe,item,player)
        if instanceof(item,"Food") and item:getFullType()==p.input and recipe:getOutputCount()==0
            and slot and not slot:isKeep() then return p.kind end
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

function OpenFull.opensNewFluid(player,item,recipe)
    return checked(function()
        local p=packaged[recipe:getName()]
        return p and p.kind=="fluid" and recipeKind(player,item,recipe)=="fluid"
    end)==true
end

local function stockScript(fullType)
    local item=getScriptManager():getItem(fullType)
    if item and item:getFullName()==fullType then return item end
end

local function scriptWeight(script)
    local weight=script and script:getActualWeight()
    if type(weight)=="number" and weight>=0 and weight<math.huge then return weight end
end

-- Only vetted one-input stock recipes. For ordinary mapped results use the
-- game's actual mapper. A known OnCreate-only result or companion is a
-- separate explicit producer contract, never inferred from the display name.
local function replacement(player, item, recipe)
    local kind = recipeKind(player,item,recipe)
    if not kind or not recipe:isInHandCraftCraft() then return end
    local recipeName=recipe:getName()
    local side=packaged[recipeName]
    if not side and recipeName~="OpenCannedFood" and recipeName~="OpenCannedFood2" and recipeName~="OpenJarOfFood" then return end
    local slot=CraftRecipeManager.getValidInputScriptForItem(recipe,item,player)
    local inputs,outputs=recipe:getInputs(),recipe:getOutputs()
    if inputs:size()<1 or inputs:size()>2 or outputs:size()~=(side and 0 or 1) then return end
    local inputIndex,kept=nil,{}
    for i=0,inputs:size()-1 do
        local input=inputs:get(i)
        if input:getResourceType()~=ResourceType.Item or input:getAmount()~=1 then return end
        local index=recipe:getIndexForIO(input)
        if input==slot and not input:isKeep() and not inputIndex then inputIndex=index
        elseif input:isKeep() and type(index)=="number" then kept[index]=true
        else return end
    end
    if type(inputIndex)~="number" then return end
    local plan={recipe=recipe,kind=kind,inputIndex=inputIndex,kept=kept,scripts={},weight=0}
    if kind=="fluid" then
        -- RecipeCodeOnCreate.openWaterCan creates this 0.300 L can and
        -- sends it after filling. Reserve space for the can and the water.
        local output=stockScript("Base.WaterRationCanEmpty")
        local weight=scriptWeight(output)
        if not weight then return end
        plan.scripts["Base.WaterRationCanEmpty"]=output
        plan.weight,plan.sideEffect,plan.ration=weight+.3,true,true
        return plan
    end
    if side and side.event then
        -- Stock OpenMysteryCan/OpenDentedCan messages contain an output ID
        -- but no local player index. Never bind them on split-screen.
        if isClient() and (not getNumActivePlayers or getNumActivePlayers()~=1 or player:getPlayerNum()~=0
            or not Events or not Events.OnServerCommand or not Events.OnServerCommand.Add
            or not Events.OnServerCommand.Remove) then return end
        for _,name in ipairs(mysteryOutputs) do
            local fullType="Base."..name
            local output=stockScript(fullType)
            local weight=scriptWeight(output)
            if not weight or output:isCantEat() then return end
            plan.scripts[fullType]=output
            plan.weight=math.max(weight,plan.weight)
        end
        plan.sideEffect,plan.unlabeled,plan.event=true,true,side.event
        return plan
    end
    local output=outputs:get(0)
    if output:getResourceType()~=ResourceType.Item or output:getAmount()~=1 then return end
    local mapper=output:getOutputMapper()
    local candidates=mapper and mapper:getResultItems()
    if not candidates or candidates:size()<1 or candidates:size()>64 then return end
    local source,expected=item:getScriptItem(),nil
    for i=0,candidates:size()-1 do
        local script=candidates:get(i)
        local pattern=mapper:getPatternForResult(script)
        if pattern and pattern:size()==1 and pattern:get(0)==source then
            if expected then return end
            expected=script
        end
    end
    local name=expected and expected:getFullName()
    local weight=scriptWeight(expected)
    if type(name)~="string" or name=="" or name==item:getFullType() or expected:isCantEat() or not weight then return end
    plan.scripts[name]=expected
    plan.script,plan.fullType,plan.weight,plan.mapper=expected,name,weight,mapper
    if recipeName=="OpenJarOfFood" then
        -- applyLidCondition adds exactly one lid before server input retirement.
        local lid=stockScript("Base.JarLid")
        local lidWeight=scriptWeight(lid)
        if not lidWeight or lid:getConditionMax()~=10 then return end
        plan.lid,plan.weight=lid,weight+lidWeight
    end
    return plan
end

function OpenFull.replacement(player,item,recipe)
    return checked(replacement,player,item,recipe)
end

-- The visible recipe can remain craftable even when the game will not offer
-- its Eat/Drink action (full moodle, large vessel). Match those native gates.
function OpenFull.recipeMenuAllowed(player, item, kind, actualFluid, recipe)
    return checked(function()
        local full = player:getMoodles():getMoodleLevel(MoodleType.FOOD_EATEN) >= 3
        if kind ~= "fluid" then return not full end
        if recipe and OpenFull.opensNewFluid(player,item,recipe) then return not full end
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
