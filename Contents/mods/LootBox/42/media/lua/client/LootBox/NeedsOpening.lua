local CreatedItemReceipt = require "LootBox/CreatedItemReceipt"
local Log = require "LootBox/Log"
local Opening = {}
local safeName, sharpName = "OpenCannedFood", "OpenCannedFoodWithKnifeOrSharpStoneFlake"
local prepared = setmetatable({}, {__mode = "k"})

local function localController()
    return isClient and isServer and not isServer()
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

local function hasLight(player, recipe)
    return recipe:canBeDoneInDark() == true or player:tooDarkToRead() == false
end

local function findRecipe(player, item, name, risky)
    local recipe = getScriptManager():getCraftRecipe(name)
    if not recipe or not recipe:isVanilla() or recipe:getName() ~= name
        or (risky and not recipe:isAnySurfaceCraft()) or (not risky and not recipe:isInHandCraftCraft())
        or recipe:getOutputCount() ~= 1 or not hasLight(player, recipe) then return end
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
    if opts.autoConsumeCarried ~= true or kind ~= "food" or not localController() then return end
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
    return Log.guard("NeedsOpening.plan", plan, player, opts, kind, item, callbacks)
end

function Opening.validate(player, opts, kind, _, item, selected, callbacks)
    local ok, valid = pcall(function()
        if not selected or selected.kind ~= kind or selected.item ~= item or opts.autoConsumeCarried ~= true
            or (selected.risky and opts.autoConsumeRiskyOpen ~= true) or not localController() then return false end
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

-- The server resolves manual inputs by ID. Reject duplicate carried IDs
-- before sending a stock action, and require complete, bounded absence later.
local function matchesIds(main, expected)
    local seen, queue, found, visited = {[main]=true}, {main}, {}, 0
    for _, container in ipairs(queue) do
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            visited = visited + 1
            local item = items:get(i)
            if visited > 1024 or not item then return false end
            local id = item:getID()
            if expected[id] ~= nil then
                if item ~= expected[id] or found[id] then return false end
                found[id] = true
            end
            local nested = item.getInventory and item:getInventory()
            if nested and not seen[nested] then
                if #queue >= 64 then return false end
                seen[nested], queue[#queue + 1] = true, nested
            end
        end
    end
    for id, item in pairs(expected) do
        if item and not found[id] then return false end
    end
    return true
end

local function uniqueInputs(main, selected)
    return selected.itemId ~= selected.toolId
        and matchesIds(main, {[selected.itemId]=selected.item, [selected.toolId]=selected.tool})
end

-- Construct only. The caller must validate the live option/protection/idle
-- state again when admitting, tracking and stopping this exact native action.
local function action(player, selected, guard)
    if not localController() or guard() ~= true then return end
    local main = player:getInventory()
    local item, tool, recipe = selected.item, selected.tool, selected.recipe
    if main ~= selected.source or not canOpen(main, item) or not carried(main, tool)
        or item:getID() ~= selected.itemId or tool:getID() ~= selected.toolId
        or (isClient() and not uniqueInputs(main, selected)) then return end
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
    if not native then return end
    prepared[native] = {selected = selected, surface = surface, multiplayer = isClient()}
    if not Opening.preflight(player, selected, native) or guard() ~= true then return end
    if not isClient() then
        -- Only SP exposes the result of the native producer in this Lua VM.
        -- Attach the watcher to the owned action, not the weak-key registry.
        native.lootboxCreatedItemReceipt = CreatedItemReceipt.begin(native, {
            inventory = function() return player:getInventory() end,
            matches = function(created) return instanceof(created, "Food") == true end,
            anchor = function()
                return selected.source == player:getInventory()
                    and not (selected.item.getWorldItem and selected.item:getWorldItem())
                    and matchesIds(selected.source, {[selected.itemId]=false})
            end,
            clock = getTimestampMs,
        })
        if not native.lootboxCreatedItemReceipt then return end
    end
    return native
end

function Opening.action(player, selected, guard)
    return Log.guard("NeedsOpening.action", action, player, selected, guard)
end

-- Last client-side check in waitToStart, before stock builds the request.
-- Native start has not yet rebuilt logic; validate the actual serialized inputs.
function Opening.preflight(player, selected, native)
    local ok, allowed = pcall(function()
        local receipt = native and prepared[native]
        if not localController() or not receipt or receipt.selected ~= selected
            or receipt.multiplayer ~= isClient() or native.Type ~= "ISHandcraftAction"
            or native.character ~= player or native.craftRecipe ~= selected.recipe
            or native.eatPercentage ~= 0 or native.isoObject ~= receipt.surface
            or not hasLight(player, selected.recipe)
            or (selected.risky and not withinReach(player, receipt.surface)) then return false end
        local main, item, tool, recipe = player:getInventory(), selected.item, selected.tool, selected.recipe
        if main ~= selected.source or not canOpen(main, item) or not carried(main, tool)
            or item:getID() ~= selected.itemId or tool:getID() ~= selected.toolId
            or not exact(native.containers, main) or not exact(native.items, item, tool)
            or (receipt.multiplayer and not uniqueInputs(main, selected)) then return false end
        local itemIndex, toolIndex = recipe:getIndexForIO(selected.itemSlot), recipe:getIndexForIO(selected.toolSlot)
        if itemIndex == toolIndex or not exact(native.manualInputs[itemIndex], item)
            or not exact(native.manualInputs[toolIndex], tool) then return false end
        for index in pairs(native.manualInputs) do
            if index ~= itemIndex and index ~= toolIndex then return false end
        end
        return true
    end)
    return ok and allowed == true
end

-- Stock start rebuilds its native crafting logic; check the real bindings
-- immediately before the owned action can invoke the native recipe.
function Opening.ready(player, selected, native)
    local ok, bound = pcall(function()
        local receipt, logic = prepared[native], native.logic
        if not localController() or not receipt or receipt.selected ~= selected or native.character ~= player
            or receipt.multiplayer ~= isClient()
            or native.craftRecipe ~= selected.recipe or native.eatPercentage ~= 0 or not logic
            or logic:getRecipe() ~= selected.recipe or native.isoObject ~= receipt.surface
            or not hasLight(player, selected.recipe)
            or (selected.risky and not withinReach(player, receipt.surface)) then return false end
        local main, item, tool = player:getInventory(), selected.item, selected.tool
        return main == selected.source and canOpen(main, item) and carried(main, tool)
            and item:getID() == selected.itemId and tool:getID() == selected.toolId
            and exact(logic:getContainers(), main) and exact(logic:getRecipeData():getAllInputItems(), item, tool)
    end)
    return ok and bound == true
end

local function multiplayerReceipt(player, selected, native)
    local receipt = native and prepared[native]
    if localController() and isClient() and receipt and receipt.multiplayer == true
        and receipt.selected == selected and native.character == player and native.craftStarted == true
        and native.craftRecipe == selected.recipe and native.eatPercentage == 0 then return receipt end
end

-- Called after native start rebuilt its actual manual inputs.
function Opening.markStarted(player, selected, native)
    local receipt = multiplayerReceipt(player, selected, native)
    if not receipt or not Opening.ready(player, selected, native) then return false end
    if not Log.guard("NeedsOpening.inputs", uniqueInputs, selected.source, selected) then return false end
    receipt.started = true
    return true
end

-- Only call from this exact owned action's native perform, not stop/UI callbacks.
-- The server's Done state confirms the transaction ended, not its output.
function Opening.markDone(player, selected, native)
    local receipt = multiplayerReceipt(player, selected, native)
    if not receipt or not receipt.started then return false end
    receipt.done = true
    return true
end

-- Poll separate normal inventory synchronization. No recipe or output proof is
-- available, so callers may only begin a new independent ready-food decision.
function Opening.openOnly(player, selected, native)
    local ok, settled = pcall(function()
        local receipt = multiplayerReceipt(player, selected, native)
        if not receipt or not receipt.done then return false end
        local main, item = player:getInventory(), selected.item
        return main == selected.source and item:getID() == selected.itemId
            and item:getContainer() == nil and not (item.getWorldItem and item:getWorldItem())
            and matchesIds(main, {[selected.itemId]=false})
    end)
    return ok and settled == true
end

-- Use only the native action's own output receipt, never "another can of
-- the same kind" from an inventory rescan. AddOrDrop may put it on the floor.
function Opening.output(player, selected, native)
    local ok, item = pcall(function()
        local receipt = prepared[native]
        if not localController() or isClient() or not receipt or receipt.multiplayer
            or receipt.selected ~= selected or native.character ~= player or native.craftRecipe ~= selected.recipe
            or not native.logic then return end
        local main = player:getInventory()
        if selected.source ~= main or carried(main, selected.item) then return end
        local data, creation = native.logic:getRecipeData(), native.lootboxCreatedItemReceipt
        if not creation then return end
        local outputs = data:getAllCreatedItems()
        if outputs:size() ~= 1 or not data:getAllConsumedItems():contains(selected.item) then return end
        local created = outputs:get(0)
        if created == selected.item or created:getID() == selected.itemId
            or not carried(main, created) or not creation:complete(native, {item=created}) then return end
        local confirmed, output = creation:poll()
        if confirmed and require("LootBox/TillFull").automaticEffects(output, "food") then return output end
    end)
    if ok then return item end
end

return Opening
