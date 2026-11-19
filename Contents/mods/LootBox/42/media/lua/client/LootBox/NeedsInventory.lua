local TillFull = require "LootBox/TillFull"
local Opening = require "LootBox/NeedsOpening"
local Inventory = {}

local MAX_ITEMS, MAX_CONTAINERS, MAX_DEPTH, MAX_OPENINGS = 1024, 64, 8, 16

local function call(object, name, arg)
    if not object then return nil end
    local ok, value = pcall(function()
        local fn = object[name]
        if fn then
            if arg == nil then return fn(object) end
            return fn(object, arg)
        end
    end)
    if ok then return value end
end

local function count(items)
    local n = call(items, "size")
    if type(n) == "number" and n >= 0 then return math.min(n, MAX_ITEMS) end
    return 0
end

local function member(items, item)
    local found = call(items, "contains", item)
    if type(found) == "boolean" then return found end
    for index = 0, count(items) - 1 do
        if call(items, "get", index) == item then return true end
    end
    return false
end

local function actualEquipment(player, item)
    return item == call(player, "getPrimaryHandItem") or item == call(player, "getSecondaryHandItem")
        or call(player, "isAttachedItem", item) == true
        or call(call(player, "getAttachedItems"), "contains", item) == true
        or call(player, "isEquippedClothing", item) == true
        or call(call(player, "getWornItems"), "contains", item) == true
end

local function usableContainer(container, player)
    return container and call(container, "getType") ~= "floor"
        and call(container, "isLockedToCharacter", player) == false
end

local function canTraverse(world, item)
    if call(item, "isFavorite") ~= false then return false end
    local protected, reason = world:protected(item)
    return protected == false or protected == true and (reason == "Bag contains items" or reason == "Equipped"
        or reason == "Held" or reason == "Attached")
end

local function itemAllowed(world, item, kind, equipped)
    if call(item, "isFavorite") ~= false then return false end
    local bag
    if kind == "fluid" then
        local fluid = call(item, "getFluidContainer")
        if fluid == nil then return false end
        if equipped then
            bag = call(item, "getInventory")
            if fluid == bag then return false end
        end
    end
    local protected, reason = world:protected(item, {allowEquippedConsumption = equipped == true})
    return protected == false or (equipped == true and bag ~= nil and protected == true and reason == "Bag contains items")
end

local function optionsFor(options, kind)
    if type(options) ~= "table" or (kind ~= "food" and kind ~= "fluid") then return false, false, 0 end
    local carried = options.autoConsumeCarried == true
    local equipped = kind == "fluid" and options.autoDrinkEquipped == true
    return carried, equipped, carried and (options.autoConsumeNested == true and MAX_DEPTH or 1) or 0
end

local function sourcePath(player, main, current, world, depthLimit)
    local seen = {}
    for depth = 0, depthLimit do
        if not usableContainer(current, player) or seen[current] then return false end
        if current == main then return true end
        if depth == depthLimit then return false end
        seen[current] = true
        local bag = call(current, "getContainingItem")
        if not bag or call(bag, "getInventory") ~= current or not canTraverse(world, bag) then return false end
        current = call(bag, "getContainer")
        if not member(call(current, "getItems"), bag) then return false end
    end
    return false
end

function Inventory.sourceAccessible(player, options, world, source)
    if not world or not source then return false end
    local _, _, depthLimit = optionsFor(options, "food")
    local ok, allowed = pcall(sourcePath, player, call(player, "getInventory"), source, world, depthLimit)
    return ok and allowed == true
end

local function toolAccessible(player, world, tool)
    local main = call(player, "getInventory")
    return tool ~= nil and usableContainer(main, player) and call(tool, "getContainer") == main
        and member(call(main, "getItems"), tool) and call(tool, "isFavorite") == false and world:protected(tool) == false
end

local function openingCallbacks(player, world)
    return {toolAccessible = function(tool) return toolAccessible(player, world, tool) end}
end

local function accessible(player, options, kind, world, item, plan)
    local carried, equipped, depthLimit = optionsFor(options, kind)
    local main, current = call(player, "getInventory"), call(item, "getContainer")
    if not world or not main or not current then return false end
    local isGear = actualEquipment(player, item)
    local gear = current == main and isGear and equipped
    if isGear and not gear or not gear and not carried or not itemAllowed(world, item, kind, gear) then return false end
    if plan ~= nil then
        if type(plan) ~= "table" or current ~= main or plan.item ~= item or plan.kind ~= kind
            or (plan.risky and options.autoConsumeRiskyOpen ~= true)
            or not toolAccessible(player, world, plan.tool) then return false end
    elseif call(item, "isSealed") ~= false then return false end
    return member(call(current, "getItems"), item) and sourcePath(player, main, current, world, depthLimit)
end

function Inventory.accessible(player, options, kind, world, item, plan)
    local ok, allowed = pcall(accessible, player, options, kind, world, item, plan)
    return ok and allowed == true
end

local function hasSafeEffects(item, kind)
    local ok, effects = pcall(TillFull.automaticEffects, item, kind, false)
    return ok and effects ~= nil and effects ~= false
end

function Inventory.eligible(player, options, kind, world, item, plan)
    if not Inventory.accessible(player, options, kind, world, item, plan) then return false end
    if not plan then return hasSafeEffects(item, kind) end
    local ok, valid = pcall(Opening.validate, player, options, kind, world, item, plan, openingCallbacks(player, world))
    return ok and valid == true
end

local function selectItem(player, options, kind, world, excluded, allowed)
    local carried, equipped, depthLimit = optionsFor(options, kind)
    if not world or not carried and not equipped then return nil end
    local main = call(player, "getInventory")
    if not usableContainer(main, player) then return nil end
    local pending, seenContainers, seenItems = {{container=main, depth=0}}, {[main]=true}, {}
    local openings = {}
    local visited = 0
    for index = 1, MAX_CONTAINERS do
        local step = pending[index]
        if not step then break end
        local source, depth = step.container, step.depth
        local fallback
        local items = call(source, "getItems")
        for i = 0, count(items) - 1 do
            if visited >= MAX_ITEMS then break end
            visited = visited + 1
            local item = call(items, "get", i)
            if item and not seenItems[item] and call(item, "getContainer") == source then
                seenItems[item] = true
                local isGear = actualEquipment(player, item)
                local gear = source == main and isGear and equipped
                if not (excluded and excluded[item]) and (gear or carried and not isGear)
                    and (gear or not fallback) and itemAllowed(world, item, kind, gear) then
                    if call(item, "isSealed") == false and hasSafeEffects(item, kind) and (not allowed or allowed(item,source)) then
                        if gear or source ~= main or not equipped then return item end
                        fallback = item
                    elseif source == main and #openings < MAX_OPENINGS then
                        local recipe = call(item, "getOpeningRecipe")
                        if type(recipe) == "string" and recipe ~= "" then openings[#openings + 1] = item end
                    end
                end
                if depth < depthLimit and #pending < MAX_CONTAINERS then
                    local child = call(item, "getInventory")
                    if child and not seenContainers[child] and call(child, "getContainingItem") == item
                        and usableContainer(child, player) and canTraverse(world, item) then
                        seenContainers[child] = true
                        pending[#pending + 1] = {container=child, depth=depth+1}
                    end
                end
            end
        end
        if fallback then return fallback end
        if visited >= MAX_ITEMS then break end
    end
    local callbacks = openingCallbacks(player, world)
    local riskyItem, riskyPlan
    for _, item in ipairs(openings) do
        local ok, plan = pcall(Opening.plan, player, options, kind, world, item, callbacks)
        if ok and plan and Inventory.accessible(player, options, kind, world, item, plan) then
            if not plan.risky then return item, plan end
            if not riskyPlan then riskyItem, riskyPlan = item, plan end
        end
    end
    return riskyItem, riskyPlan
end

function Inventory.select(player, options, kind, world, excluded, allowed)
    local ok, item, plan = pcall(selectItem, player, options, kind, world, excluded, allowed)
    if ok then return item, plan end
end

return Inventory
