-- Til Full, beside the game's own Eat and Drink amounts and only where the
-- item would be consumed right now.
local TillFull = require "LootBox/TillFull"
local Opening = require "LootBox/Opening"
local Log = require "LootBox/Log"

local Menu = {}

local function call(object, method)
    if not object then return nil end
    local ok, value = pcall(function() return object[method](object) end)
    if ok then return value end
end

local function native(object, class) return object and instanceof(object, class) end

local function inventoryItem(value)
    if native(value, "InventoryItem") then return value end
    if native(value, "IsoWorldInventoryObject") then
        local item = call(value, "getItem")
        if native(item, "InventoryItem") then return item end
    end
end

local function run(selection)
    local player = getSpecificPlayer(selection.playerIndex)
    local id = Log.intent(selection.origin, selection.title, player, "item", Log.item(selection.items[1], player),
        "stack", #selection.items, "kind", selection.kind, "source", Log.container(selection.source, player))
    selection.items.interaction = id
    local app, err = require("LootBox/App").get(selection.playerIndex)
    local ok
    if app then ok, err = app:tillFull(selection.items, selection.kind, selection.openingRecipe, selection.source) end
    if not ok then
        local message = "Til Full: " .. tostring(err or "The native action could not start")
        Log.warn(id, "REFUSED", "at", "start", "reason", message, "player", Log.player(player))
        if player and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(player, message) end
    end
    return ok, err
end

-- A native submenu names one item. Multi-selection is not permission to
-- consume every selected row or find replacement items in other containers.
local function selectedStack(items, anchor)
    if not native(anchor, "InventoryItem") then return nil end
    local source, fullType = call(anchor, "getContainer"), call(anchor, "getFullType")
    if not source or not fullType then return nil end
    local candidates = {}
    -- Collapsed stacks carry a group row; expanded selected stack children
    -- arrive as individual references. Never discover peers from a container.
    for _, row in ipairs(items or {}) do
        if not native(row, "InventoryItem") and type(row) == "table" and row.items then
            local group = ISInventoryPane.getActualItems({row}) or {}
            for _, item in ipairs(group) do
                if item == anchor then candidates = group; break end
            end
            if #candidates > 0 then break end
        end
    end
    if #candidates == 0 then
        for _, row in ipairs(items or {}) do
            local item = inventoryItem(row)
            if item then candidates[#candidates + 1] = item end
        end
    end
    local snapshot, seen, contains = {}, {}, false
    for _, item in ipairs(candidates) do
        if native(item, "InventoryItem") and not seen[item]
            and call(item, "getContainer") == source and call(item, "getFullType") == fullType then
            seen[item] = true
            snapshot[#snapshot + 1] = item
            contains = contains or item == anchor
        end
    end
    return contains and snapshot or nil
end

local function add(playerIndex, parent, items, app, preferences)
    local nativeMenu = ISInventoryPaneContextMenu
    if not preferences.tillFullEnabled or not nativeMenu or not ISInventoryPane or not ISInventoryPane.getActualItems
        or not parent.getSubMenu then return false end
    local player = getSpecificPlayer(playerIndex)
    local present, plain, added = {}, {}, false
    local function extend(menu, root, anchor, kind, recipe)
        local snapshot = selectedStack(items, anchor)
        if not snapshot or #snapshot == 0 then return end
        local source = anchor:getContainer()
        local offered, why = Log.guard("TillFull.offers", TillFull.offers, player, app.world, snapshot,
            { kind = kind, both = preferences.tillFullBothNeeds, recipe = recipe, source = source })
        if not offered then
            Log.trace(nil, "MENU", "menu", "til-full", "item", Log.item(anchor, player), "kind", kind, "omitted", why)
            return
        end
        local drink = kind ~= "food"
        local title = recipe and (drink and "Open and Drink Til Full" or "Open and Eat Til Full") or "Til Full"
        local option = menu:addOption(title, {playerIndex = playerIndex, items = snapshot, title = title,
            origin = native(items[1], "IsoWorldInventoryObject") and "menu.world" or "menu.item",
            kind = kind, openingRecipe = recipe, source = source}, run)
        if not option then return end
        added = true
        option.itemForTexture = root.itemForTexture or anchor
        if recipe and nativeMenu.addToolTip then
            local tip = nativeMenu.addToolTip()
            tip.description = "Opens the selected item, then " .. (drink and "drinks for your thirst" or "eats for your hunger") .. " at that moment."
            option.toolTip = tip
        end
    end
    -- Prefer the enabled native amount submenu. Some packages (soda cans,
    -- fruit beverage, jars) expose only a separate stock crafting callback.
    -- Collect those *existing* rows, then decorate just once after the walk.
    local visited, remaining = {}, 256
    local function visit(menu, root)
        if visited[menu] or remaining <= 0 then return end
        visited[menu], remaining = true, remaining - 1
        local kind, anchor, openingRecipe, already, ambiguous
        for _, option in ipairs(menu.options or {}) do
            if option.onSelect == run then already = true end
            if not option.notAvailable then
                local action, item
                if nativeMenu.onEatItems and option.onSelect == nativeMenu.onEatItems then
                    item = inventoryItem((ISInventoryPane.getActualItems(option.target) or {})[1])
                    action = item and Opening.drinks(item, option.param3) and "drinkFood" or "food"
                elseif nativeMenu.onDrinkFluid and option.onSelect == nativeMenu.onDrinkFluid then
                    action, item = "fluid", inventoryItem(option.target)
                    if option.param4 and item ~= option.param4 then item = nil end
                elseif nativeMenu.OnNewCraft and option.onSelect == nativeMenu.OnNewCraft
                    and option.param2 == playerIndex and option.param3 == false then
                    local selected = inventoryItem(option.target)
                    local r = option.param1
                    local k = selected and r and Opening.kind(player, selected, r)
                    if k and Opening.allowed(player, selected, k) then
                        local p = plain[selected]
                        if p and p.recipe ~= r then p.ambiguous = true
                        elseif not p then plain[selected] = {menu = menu, root = option, recipe = r, kind = k} end
                    end
                end
                if item then
                    local recipe = option.param3
                    local name = recipe and call(item, "getOpeningRecipe")
                    if not recipe or (name and getScriptManager():getCraftRecipe(name) == recipe) then
                        if kind and (kind ~= action or anchor ~= item or openingRecipe ~= recipe) then ambiguous = true end
                        kind, anchor, openingRecipe = action, item, recipe
                    end
                end
                local child = option.subOption and parent:getSubMenu(option.subOption)
                if child then visit(child, option) end
            end
        end
        -- A direct stock callback is not an amount submenu. Do not confuse
        -- arbitrary unrelated top-level rows with native amount choices.
        if menu == parent or not kind then return end
        if anchor then present[anchor] = true end
        if not ambiguous and not already then extend(menu, root, anchor, kind, openingRecipe) end
    end
    visit(parent, nil)
    if remaining <= 0 then return added end
    for item, option in pairs(plain) do
        if not present[item] and not option.ambiguous then
            local duplicate = false
            for _, row in ipairs(option.menu.options or {}) do
                if row.onSelect == run then duplicate = true; break end
            end
            if not duplicate then extend(option.menu, option.root, item, option.kind, option.recipe) end
        end
    end
    return added
end

function Menu.add(playerIndex, parent, items, app, preferences)
    return Log.guard("ConsumeMenu.add", add, playerIndex, parent, items, app, preferences) == true
end

return Menu
