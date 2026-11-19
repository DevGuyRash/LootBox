local Opening = {}
local safeName, sharpName = "OpenCannedFood", "OpenCannedFoodWithKnifeOrSharpStoneFlake"
local prepared = setmetatable({}, {__mode = "k"})

local function offline()
    return isClient and isServer and not isClient() and not isServer()
end

local function carried(main, item)
    return item and item:getContainer() == main and main:getItems():contains(item)
end

local function canOpen(main, item)
    return carried(main, item) and instanceof(item, "Food")
        and (item:isSealed() == true or item:getScriptItem():isCantEat() == true)
        and item:isFavorite() == false and item:getOpeningRecipe() == safeName
        and not item:isRotten() and not item:isBurnt() and not item:isFrozen() and not item:isTainted()
        and not item:isPoison() and item:getPoisonPower() <= 0 and item:getFoodSicknessChange() <= 0
        and not item:isAlcoholic() and (not item:isbDangerousUncooked() or item:isCooked())
end

local function findRecipe(player, item, name, risky)
    local recipe = getScriptManager():getCraftRecipe(name)
    if not recipe or not recipe:isVanilla() or recipe:getName() ~= name
        or (risky and not recipe:isAnySurfaceCraft()) or (not risky and not recipe:isInHandCraftCraft())
        or recipe:getOutputCount() ~= 1 then return end
    local inputs = recipe:getInputs()
    if inputs:size() ~= 2 then return end
    local itemSlot, toolSlot
    for i = 0, 1 do
        local slot = inputs:get(i)
        if slot:getResourceType() ~= ResourceType.Item then return end
        if CraftRecipeManager.isItemValidForInputScript(slot, item, player) then
            if itemSlot then return end
            itemSlot = slot
        else toolSlot = slot end
    end
    if not itemSlot or not toolSlot then return end
    return recipe, itemSlot, toolSlot
end

local function allowedTool(main, tool, callbacks)
    return carried(main, tool) and tool:isFavorite() == false and callbacks.toolAccessible(tool) == true
end

local function withinReach(player, surface)
    if not surface then return false end
    local square, here = surface:getSquare(), player:getCurrentSquare()
    if not square or not here or square:getZ() ~= here:getZ() then return false end
    local distance = math.abs(square:getX() - here:getX()) + math.abs(square:getY() - here:getY())
    return distance <= 1 and (distance == 0 or here:isBlockedTo(square) == false)
        and square:getObjects():contains(surface)
end

local function craftSurface(player)
    local surface = HandcraftLogic.new(player, nil, nil):findCraftSurface(player, 2)
    if withinReach(player, surface) then return surface end
end

local function plan(player, opts, kind, item, callbacks)
    if opts.autoConsumeCarried ~= true or kind ~= "food" or not offline() then return end
    local main = player:getInventory()
    if not canOpen(main, item) then return end
    local function find(name, risky)
        local recipe, itemSlot, toolSlot = findRecipe(player, item, name, risky)
        if not recipe then return end
        local items = main:getItems()
        for i = 0, math.min(items:size(), 1024) - 1 do
            local tool = items:get(i)
            if tool ~= item and allowedTool(main, tool, callbacks)
                and CraftRecipeManager.isItemValidForInputScript(toolSlot, tool, player) then
                if risky and not craftSurface(player) then return end
                return {item = item, itemId = item:getID(), tool = tool, toolId = tool:getID(), kind = kind,
                    source = main, recipe = recipe, itemSlot = itemSlot, toolSlot = toolSlot, risky = risky}
            end
        end
    end
    local safe = find(safeName, false)
    if safe then return safe end
    if opts.autoConsumeRiskyOpen == true then return find(sharpName, true) end
end

function Opening.plan(player, opts, kind, _, item, callbacks)
    local ok, value = pcall(plan, player, opts, kind, item, callbacks)
    if ok then return value end
end

function Opening.validate(player, opts, kind, _, item, selected, callbacks)
    local ok, valid = pcall(function()
        if not selected or selected.kind ~= kind or selected.item ~= item or opts.autoConsumeCarried ~= true
            or (selected.risky and opts.autoConsumeRiskyOpen ~= true) or not offline() then return false end
        local main = player:getInventory()
        if main ~= selected.source or not canOpen(main, item) or not allowedTool(main, selected.tool, callbacks)
            or item:getID() ~= selected.itemId or selected.tool:getID() ~= selected.toolId then return false end
        local recipe, itemSlot, toolSlot = findRecipe(player, item, selected.risky and sharpName or safeName,
            selected.risky)
        return recipe == selected.recipe and itemSlot == selected.itemSlot and toolSlot == selected.toolSlot
            and CraftRecipeManager.isItemValidForInputScript(toolSlot, selected.tool, player)
    end)
    return ok and valid == true
end

local function single(value)
    local l = ArrayList.new()
    l:add(value)
    return l
end

local function exact(list, first, second)
    if not list then return false end
    if not second then return list:size() == 1 and list:get(0) == first end
    return list:size() == 2 and ((list:get(0) == first and list:get(1) == second)
        or (list:get(0) == second and list:get(1) == first))
end

-- Construct only. The caller must validate the live option/protection/idle
-- state again when admitting, tracking and stopping this exact native action.
local function action(player, selected, guard)
    if not offline() or guard() ~= true then return end
    local main = player:getInventory()
    local item, tool, recipe = selected.item, selected.tool, selected.recipe
    if main ~= selected.source or not canOpen(main, item) or not carried(main, tool)
        or item:getID() ~= selected.itemId or tool:getID() ~= selected.toolId then return end
    local surface
    if selected.risky then
        surface = craftSurface(player)
        if not surface then return end
    end
    require "Entity/TimedActions/ISHandcraftAction"
    local logic = HandcraftLogic.new(player, nil, surface)
    logic:setContainers(single(main))
    logic:setRecipeFromContextClick(recipe, item)
    logic:setManualSelectInputs(true)
    logic:clearManualInputs()
    if not logic:setManualInputsFor(selected.itemSlot, single(item))
        or not logic:setManualInputsFor(selected.toolSlot, single(tool))
        or not logic:canPerformCurrentRecipe()
        or not exact(logic:getRecipeData():getAllInputItems(), item, tool) then return end
    local native = ISHandcraftAction.FromLogic(logic, 0)
    if not native or native.Type ~= "ISHandcraftAction" or native.character ~= player or native.craftRecipe ~= recipe
        or native.eatPercentage ~= 0 or native.isoObject ~= surface
        or not exact(native.containers, main) or not exact(native.items, item, tool) then return end
    local itemIndex, toolIndex = recipe:getIndexForIO(selected.itemSlot), recipe:getIndexForIO(selected.toolSlot)
    if itemIndex == toolIndex or not exact(native.manualInputs[itemIndex], item)
        or not exact(native.manualInputs[toolIndex], tool) then return end
    for index in pairs(native.manualInputs) do
        if index ~= itemIndex and index ~= toolIndex then return end
    end
    if guard() ~= true then return end
    prepared[native] = {selected = selected, surface = surface}
    return native
end

function Opening.action(player, selected, guard)
    local ok, native = pcall(action, player, selected, guard)
    if ok then return native end
end

-- Stock start rebuilds its native crafting logic; check the real bindings
-- immediately before the owned action can invoke the native recipe.
function Opening.ready(player, selected, native)
    local ok, bound = pcall(function()
        local receipt, logic = prepared[native], native.logic
        if not offline() or not receipt or receipt.selected ~= selected or native.character ~= player
            or native.craftRecipe ~= selected.recipe or native.eatPercentage ~= 0 or not logic
            or logic:getRecipe() ~= selected.recipe or native.isoObject ~= receipt.surface
            or (selected.risky and not withinReach(player, receipt.surface)) then return false end
        local main, item, tool = player:getInventory(), selected.item, selected.tool
        return main == selected.source and canOpen(main, item) and carried(main, tool)
            and item:getID() == selected.itemId and tool:getID() == selected.toolId
            and exact(logic:getContainers(), main) and exact(logic:getRecipeData():getAllInputItems(), item, tool)
    end)
    return ok and bound == true
end

-- Use only the native action's own output receipt, never "another can of
-- the same kind" from an inventory rescan. AddOrDrop may put it on the floor.
function Opening.output(player, selected, native)
    local ok, item = pcall(function()
        local receipt = prepared[native]
        if not offline() or not receipt or receipt.selected ~= selected or native.character ~= player or native.craftRecipe ~= selected.recipe
            or not native.logic then return end
        local main = player:getInventory()
        if selected.source ~= main or carried(main, selected.item) then return end
        local outputs = native.logic:getRecipeData():getAllCreatedItems()
        if outputs:size() ~= 1 then return end
        local created = outputs:get(0)
        if created ~= selected.item and carried(main, created)
            and require("LootBox/TillFull").automaticEffects(created, "food") then return created end
    end)
    if ok then return item end
end

return Opening
