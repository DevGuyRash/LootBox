-- Right-click menus. A row exists only when choosing it would do something to
-- the thing that was clicked, right now. Submenus are created by their first
-- row, so an empty one cannot appear, and neither can an empty LootBox entry.
require "ISUI/ISContextMenu"
require "ISUI/ISToolTip"

local App = require "LootBox/App"
local Catalog = require "LootBox/Catalog"
local Describe = require "LootBox/Describe"
local Log = require "LootBox/Log"
local Selection = require "LootBox/Selection"
local ObjectMenu = require "LootBox/ObjectMenu"
local Focus = require "LootBox/ContainerFocus"
local PaneClicks = require "LootBox/PaneClicks"

local Menus = {}
local UI
local wrapped = setmetatable({}, { __mode = "k" })
local invoking = setmetatable({}, { __mode = "k" })
local ownNoItems = false

local icons = {
    root = "media/ui/LootableMaps/map_lightbulb.png", job = "media/ui/craftingMenus/BuildProperty_Clock_16.png",
    pause = "media/ui/LootableMaps/map_columns.png", resume = "media/ui/LootableMaps/map_arroweast.png",
    stop = "media/ui/LootableMaps/map_x.png", show = "media/ui/LootableMaps/map_eye.png",
    take = "media/ui/LootableMaps/map_arrowsoutheast.png", takeSome = "media/ui/LootableMaps/map_star.png",
    takeSame = "media/ui/inventoryPanes/TakeSameTypeOneContainer.png", put = "media/ui/inventoryPanes/TransferSameTypeOneContainer.png",
    putMenu = "media/ui/LootableMaps/map_arrowsouthwest.png", sort = "media/ui/Entity/BTN_Swap_Icon_48x48.png",
    drop = "media/ui/LootableMaps/map_arrowsouth.png", vehicle = "media/ui/LootableMaps/map_steeringwheel.png",
    myVehicle = "media/ui/LootableMaps/map_key.png", trash = "media/ui/LootableMaps/map_garbage.png",
    unpack = "media/ui/Container_Crate.png", move = "media/ui/LootableMaps/map_arrownortheast.png",
    all = "media/ui/LootableMaps/map_asterisk.png", category = "media/ui/craftingMenus/Icon_Grid.png",
    label = "Item_Pencil", more = "media/ui/craftingMenus/Icon_List.png", keep = "media/ui/LootableMaps/map_lock.png",
    list = "media/ui/LootableMaps/map_checkmark.png", newCategory = "media/ui/Entity/BTN_Plus_Icon_48x48.png",
    tag = "media/ui/Entity/icon_link_io.png", around = "media/ui/LootableMaps/map_target.png", reach = "media/ui/LootableMaps/map_o.png",
    room = "media/ui/LootableMaps/map_house.png", building = "media/ui/LootableMaps/map_skyscraper.png",
    area = "media/ui/LootableMaps/map_diamond.png", preset = "media/ui/LootableMaps/map_vhs.png", plan = "media/ui/LootableMaps/map_gears.png",
    amount = "media/ui/LootableMaps/map_spade.png", inside = "media/ui/LootableMaps/map_door.png", belongs = "Item_Clipboard",
}
Menus.icons = icons

local function iconOf(name) return getTexture((assert(icons[name], "missing LootBox icon " .. tostring(name)))) end

local function call(object, method, ...)
    if not object then return nil end
    local ok, value = pcall(function(...)
        local fn = object[method]
        if fn == nil then return nil end
        return fn(object, ...)
    end, ...)
    if ok then return value end
end

local function native(object, class) return object ~= nil and instanceof(object, class) end

-- Menu building ------------------------------------------------------------

local function tooltip(option, title, text)
    if not option or not text then return end
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip:setName(title)
    tip.maxLineWidth = 420
    tip.description = tostring(text):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\n", " <LINE> ")
    option.toolTip = tip
end
Menus.tooltip = tooltip

local Node = {}
Node.__index = Node

local function node(make) return setmetatable({ make = make }, Node) end

function Node:menu()
    if not self.context then self.context = self.make() end
    return self.context
end

function Node:row(icon, title, action, tip, texture)
    local menu = self:menu()
    local option = menu:addOption(title, nil, action)
    if not option then return nil end
    option.iconTexture = texture or iconOf(icon)
    tooltip(option, title, tip)
    return option
end

function Node:check(icon, title, on, action, tip)
    local option = self:row(icon, title, action, tip)
    if option and on then self:menu():setOptionChecked(option, true) end
    return option
end

function Node:sub(icon, title, item)
    return node(function()
        local menu = self:menu()
        local option = menu:addOption(title, nil, nil)
        if item then option.itemForTexture = item else option.iconTexture = iconOf(icon) end
        local child = ISContextMenu:getNew(menu)
        menu:addSubMenu(option, child)
        return child
    end)
end

-- One choice needs no submenu.
local function group(host, icon, title, rows, item)
    if #rows == 0 then return end
    if #rows == 1 then
        local row = rows[1]
        host:row(row.icon, row.single or row.title, row.run, row.tip)
        return
    end
    local child = host:sub(icon, title, item)
    for _, row in ipairs(rows) do child:row(row.icon, row.title, row.run, row.tip) end
end

local function root(parent)
    return node(function()
        for _, option in ipairs(parent.options or {}) do
            if option.lootBoxMenu then return option.lootBoxMenu end
        end
        local option = parent:addOption("LootBox", nil, nil)
        option.iconTexture = getTexture(icons.root)
        local menu = ISContextMenu:getNew(parent)
        parent:addSubMenu(option, menu)
        option.lootBoxMenu = menu
        return menu
    end)
end

-- Shared facts -------------------------------------------------------------

local function allowed(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    if not player or call(player, "isDead") then return false end
    if isGamePaused and isGamePaused() then return false end
    if getCore and call(getCore(), "isTutorial") then return false end
    return not (ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.dontCreateMenu)
end

local function storage(container) return container ~= nil and call(container, "getType") ~= "floor" end

local function openContainers(playerIndex)
    local result, seen = {}, {}
    local function collect(page, pane)
        for _, button in ipairs(page and page.backpacks or {}) do
            local container = button.inventory
            if container and not seen[container] then
                seen[container] = true
                result[#result + 1] = { container = container, pane = pane }
            end
        end
    end
    collect(getPlayerInventory and getPlayerInventory(playerIndex), "inventory")
    collect(getPlayerLoot and getPlayerLoot(playerIndex), "loot")
    return result
end

-- "Cupboard 2" in the same order as the icons, only when names repeat.
local function nameAll(entries)
    local counts, seen = {}, {}
    for _, entry in ipairs(entries) do
        entry.name = Describe.container(entry.container)
        entry.name = entry.name:sub(1, 1):upper() .. entry.name:sub(2)
        counts[entry.name] = (counts[entry.name] or 0) + 1
    end
    for _, entry in ipairs(entries) do
        if counts[entry.name] > 1 then
            local name = entry.name
            seen[name] = (seen[name] or 0) + 1
            entry.name = name .. " " .. seen[name]
        end
    end
    return entries
end

local function session(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    local app = App.get(playerIndex)
    if not app then return nil end
    return { playerIndex = playerIndex, player = player, app = app, world = app.world, preferences = App.getPreferences() }
end

local function listFilter(app)
    local list = app:getChecklist()
    return #list.ids + #list.types > 0 and list or nil
end

local function everything() return { ids = {}, types = {}, all = true } end
local function oneType(fullType) return { ids = {}, types = { fullType }, all = false } end
local function oneCategory(id) return { ids = { id }, types = {}, all = false } end

local function request(scope, kind, filter, extra)
    local result = { scope = scope, includeInventory = false, includeBags = true, filter = filter, sourceLabels = {}, destination = { kind = kind, labels = {} } }
    for key, value in pairs(extra or {}) do
        if key == "ref" or key == "mode" then result.destination[key] = value else result[key] = value end
    end
    return result
end

-- Every LootBox click becomes one logged interaction.
local function act(s, origin, label, what, clicked, options)
    return function()
        local id = Log.intent(origin, label, s.player, "clicked", clicked, "request", Log.request(what))
        what.interaction = id
        options = options or {}
        options.interaction, options.label = id, label
        UI.act(s.playerIndex, what, options)
    end
end

local function ask(s, origin, label, clicked, action)
    return function()
        local id = Log.intent(origin, label, s.player, "clicked", clicked)
        local ok, err = action(id)
        if ok == nil and err then
            Log.warn(id, "REFUSED", "reason", err)
            UI.say(s.playerIndex, err)
        end
    end
end

local function floorHere(s) return s.square or s.player:getCurrentSquare() end

-- The job in progress ------------------------------------------------------

local function jobRows(host, s)
    local status = s.app:status()
    if not (status.hasJob or status.consuming or status.previous) then return end
    local label = status.label or "Current job"
    if not status.hasJob and not status.consuming then
        local child = host:sub("job", "Set aside: " .. tostring(status.previous.label))
        child:row("resume", "Resume it", ask(s, "menu.job", "resume previous", nil, function() return s.app:resumePrevious() end))
        child:row("stop", "Discard it", ask(s, "menu.job", "discard previous", nil, function() s.app:discardPrevious(); return true end))
        return
    end
    local child = host:sub("job", "Job: " .. label)
    if status.canResume then child:row("resume", "Resume", ask(s, "menu.job", "resume", nil, function() return s.app:resume() end)) end
    if status.canPause then child:row("pause", "Pause", ask(s, "menu.job", "pause", nil, function() return s.app:pause() end)) end
    child:row("stop", "Stop", ask(s, "menu.job", "stop", nil, function() return s.app:cancel() end))
    child:row("show", "Show progress", function() UI.showJob(s.playerIndex) end)
end

-- Containers ---------------------------------------------------------------

local function presetRows(host, s, fits, context)
    local saved = s.app:getSetups()
    local child = host:sub("preset", "Presets")
    for _, preset in ipairs(saved.presets) do
        if fits(preset.setup) then
            local id, name = preset.id, preset.name
            child:row("preset", name, function()
                local what, err = s.app:loadSetup(id, context)
                if not what then UI.say(s.playerIndex, err); return end
                act(s, "menu.preset", name, what, name, { context = context, area = what.scope == "area" and not what.area })()
            end)
        end
    end
end

local function labelRows(host, s, container, facts)
    if not storage(container) or facts.kind == "main" or facts.kind == "corpse" or facts.kind == "bin" then return end
    if not s.world:key(container) then return end
    local current = s.app:labels(container)
    local on, shown = {}, {}
    for _, id in ipairs(current) do on[id] = true end
    local title = "Belongs here"
    if #current > 0 then
        title = title .. ": " .. App.categoryName(current[1]) .. (#current > 1 and (" +" .. (#current - 1)) or "")
    end
    local child = host:sub("belongs", title)
    local function toggle(id)
        return ask(s, "menu.label", (on[id] and "unlabel " or "label ") .. id, Log.container(container, s.player), function()
            local labels = {}
            for _, value in ipairs(s.app:labels(container)) do if value ~= id then labels[#labels + 1] = value end end
            if not on[id] then labels[#labels + 1] = id end
            return s.app:setLabels(container, labels)
        end)
    end
    for _, id in ipairs(current) do
        shown[id] = true
        child:check("label", App.categoryName(id), true, toggle(id))
    end
    local suggestions = {}
    for id, count in pairs(facts.categories or {}) do if not shown[id] then suggestions[#suggestions + 1] = { id = id, count = count } end end
    table.sort(suggestions, function(a, b) if a.count ~= b.count then return a.count > b.count end return a.id < b.id end)
    for index = 1, math.min(5, #suggestions) do
        shown[suggestions[index].id] = true
        child:check("category", App.categoryName(suggestions[index].id), false, toggle(suggestions[index].id), "Already in here.")
    end
    local custom = 0
    for _, definition in ipairs(App.customCategories()) do
        if not shown[definition.id] and custom < 6 then
            custom = custom + 1
            child:check("tag", definition.name, false, toggle(definition.id))
        end
    end
    child:row("more", "More...", function() UI.open(s.playerIndex, "storage", { container = container }) end)
end

-- A key ring is no place for planks.
local function accepts(destination, items)
    for _, item in ipairs(items) do
        if call(destination, "isItemAllowed", item) ~= false and call(destination, "isInside", item) ~= true then return true end
    end
    return false
end

local function destinations(s, container)
    local result, sample = {}, {}
    local items = call(container, "getItems")
    for index = 0, math.min(12, call(items, "size") or 0) - 1 do sample[#sample + 1] = call(items, "get", index) end
    for _, entry in ipairs(openContainers(s.playerIndex)) do
        if entry.container ~= container and storage(entry.container) and call(entry.container, "isLockedToCharacter", s.player) ~= true
            and accepts(entry.container, sample) then
            result[#result + 1] = entry
        end
    end
    return nameAll(result)
end

local function containerRows(host, s, container, origin)
    local facts = s.world:containerFacts(container)
    if not facts or facts.locked then return end
    local name, clicked = Describe.container(container), Log.container(container, s.player)
    local from = { sourceContainer = container }
    local has = facts.takeable > 0
    local maybe = has or (facts.explored == false and not facts.owned)
    local count = has and (" (" .. facts.takeable .. (facts.truncated and "+" or "") .. ")") or ""
    local inventory = s.player:getInventory()
    local function go(label, what, options) return act(s, origin, label .. " - " .. name, what, clicked, options) end

    if not facts.owned and maybe then
        host:row("take", "Take everything" .. count, go("take everything", request("container", "inventory", everything(), from)),
            "Into your bags first, then your main inventory.")
        local list = listFilter(s.app)
        local wanted = list and s.world:countMatching(container, list) or 0
        if list and (wanted > 0 or not facts.explored) then
            host:row("takeSome", "Take my loot list" .. (wanted > 0 and (" (" .. wanted .. ")") or ""),
                go("take loot list", request("container", "inventory", list, from)))
        end
        local same, types = 0, {}
        for fullType, amount in pairs(facts.types or {}) do
            if s.world:countCarried(fullType) > 0 then same = same + amount; types[#types + 1] = fullType end
        end
        if same > 0 and same < facts.takeable then
            host:row("takeSame", "Take what I already carry (" .. same .. ")",
                go("take matching", request("container", "inventory", { ids = {}, types = types, all = false }, from)))
        end
    end
    if facts.kind == "bag" and facts.owned and has then
        host:row("unpack", "Unpack" .. count, go("unpack", request("container", "container", everything(), { sourceContainer = container, ref = inventory })),
            "Into your main inventory. The bag stays where it is.")
    end

    if has then
        local rows = {}
        if s.world:hasStorageLabels() then
            rows[#rows + 1] = { icon = "sort", title = "Where it belongs", single = "Put contents away", tip = "Storage with matching labels.",
                run = go("sort contents", request("container", "labels", everything(), from)) }
        end
        for _, entry in ipairs(destinations(s, container)) do
            if not (facts.owned and entry.container == inventory) then
                rows[#rows + 1] = { icon = "put", title = entry.name, single = "Move contents to " .. entry.name,
                    run = go("move contents to " .. entry.name, request("container", "container", everything(), { sourceContainer = container, ref = entry.container })) }
            end
        end
        if s.world:rememberedVehicleLoaded() and facts.kind ~= "vehicle" then
            rows[#rows + 1] = { icon = "vehicle", title = "My vehicle", single = "Move contents to my vehicle",
                run = go("haul contents", request("container", "vehicle", everything(), from)) }
        end
        if facts.kind ~= "floor" then
            rows[#rows + 1] = { icon = "drop", title = "The floor", single = "Drop contents here",
                run = go("drop contents", request("container", "floor", everything(), { sourceContainer = container, ref = floorHere(s) })) }
        end
        group(host, "move", "Move contents", rows)
    end

    if storage(container) and container ~= inventory and facts.kind ~= "corpse" and facts.kind ~= "bin" then
        local rows, same, types = {}, 0, {}
        for fullType in pairs(facts.types or {}) do
            local amount = s.world:countCarried(fullType, container)
            if amount > 0 then same = same + amount; types[#types + 1] = fullType end
        end
        if same > 0 then
            rows[#rows + 1] = { icon = "takeSame", title = "More of what is inside (" .. same .. ")", single = "Put in more of the same (" .. same .. ")",
                run = go("put in matching", request("inventory", "container", { ids = {}, types = types, all = false }, { ref = container })) }
        end
        local labels = s.app:labels(container)
        local fits = 0
        for _, id in ipairs(labels) do fits = fits + s.world:countCarriedCategory(id, container) end
        if fits > 0 then
            rows[#rows + 1] = { icon = "belongs", title = "What belongs here (" .. fits .. ")", single = "Put in what belongs here (" .. fits .. ")",
                run = go("put in labelled", request("inventory", "container", { ids = labels, types = {}, all = false }, { ref = container })) }
        end
        if not facts.owned and (facts.capacity or 0) >= 20 and s.world:countCarried(nil, container) > 0 then
            rows[#rows + 1] = { icon = "all", title = "Everything I carry", single = "Put in everything I carry",
                run = go("put in everything", request("inventory", "container", everything(), { ref = container })),
                tip = "Worn, held, favorite and Keep items stay with you." }
        end
        group(host, "putMenu", "Put in", rows)
    end

    if has and facts.kind ~= "main" and facts.kind ~= "bin" and s.world:hasKnownBins() then
        host:row("trash", "Throw away contents" .. count, go("throw away contents", request("container", "trash", everything(), from), { review = facts.owned }),
            "Carried to a trash can and deleted for good.")
    end
    labelRows(host, s, container, facts)
    presetRows(host, s, function(setup) return setup.scope == "container" or setup.destination.kind == "container" end,
        { container = container, sourceContainer = container, targetContainer = container, square = floorHere(s) })
end

-- Items --------------------------------------------------------------------

local function selectedItems(items)
    local result, seen = {}, {}
    local actual = ISInventoryPane and ISInventoryPane.getActualItems and ISInventoryPane.getActualItems(items or {}) or {}
    for _, item in ipairs(actual) do
        if native(item, "InventoryItem") and not seen[item] then seen[item] = true; result[#result + 1] = item end
    end
    return result
end

-- What can be done with "all of these": one rule set for a type, a selection of
-- types, a game category and a custom category.
local function allRows(s, what, label, carried, total, picked, source, target, descriptor)
    local rows, clicked = {}, what.clicked
    local function add(icon, title, single, made, options)
        rows[#rows + 1] = { icon = icon, title = title, single = single, run = act(s, "menu.item", single, made, clicked, options) }
    end
    local beyond = total > picked
    if carried then
        if target and beyond then
            local name = Describe.container(target)
            add("put", "Put in " .. name, "Put all " .. label .. " in " .. name, request("inventory", "container", what.filter, { ref = target }))
        end
        if s.world:storageAccepts(descriptor) then
            add("sort", "Put away", "Put away all " .. label, request("inventory", "labels", what.filter))
        end
        if s.world:rememberedVehicleLoaded() then
            add("vehicle", "To my vehicle", "Haul all " .. label .. " to my vehicle", request("inventory", "vehicle", what.filter))
        end
        if beyond then add("drop", "Drop", "Drop all " .. label, request("inventory", "floor", what.filter, { ref = floorHere(s) })) end
        if s.world:hasKnownBins() then add("trash", "Throw away", "Throw away all " .. label, request("inventory", "trash", what.filter), { review = true }) end
    else
        if beyond then add("take", "Take", "Take all " .. label, request("container", "inventory", what.filter, { sourceContainer = source })) end
        if what.everywhere and what.everywhere > total then
            add("all", "Take from all open containers (" .. what.everywhere .. ")", "Take all " .. label .. " from here",
                request("lootPane", "inventory", what.filter, { includeBags = false, excludeUnwanted = true }))
        end
        local mine = what.mine or 0
        if mine > 0 and storage(source) then
            add("put", "Put mine in here (" .. mine .. ")", "Put my " .. label .. " in here (" .. mine .. ")",
                request("inventory", "container", what.filter, { ref = source }))
        end
    end
    return rows
end

local function sumOpen(s, count)
    local total = 0
    for _, entry in ipairs(openContainers(s.playerIndex)) do
        if entry.pane == "loot" and not s.world:owns(entry.container) then
            local facts = s.world:containerFacts(entry.container)
            if facts and not facts.locked then total = total + count(facts) end
        end
    end
    return total
end

local function itemRows(host, s, items, item)
    local source = item:getContainer()
    local carried = s.world:owns(source)
    local viewed = s.app:currentContainer()
    local target = carried and storage(viewed) and not s.world:owns(viewed) and call(viewed, "isLockedToCharacter", s.player) ~= true and viewed or nil
    local facts = not carried and s.world:containerFacts(source) or nil
    local descriptor, clicked = s.world:describe(item), Log.item(item, s.player)
    local types, order, picked = {}, {}, #items
    for _, entry in ipairs(items) do
        local fullType = entry:getFullType()
        if not types[fullType] then types[fullType] = true; order[#order + 1] = fullType end
    end
    local function ofTypes(list)
        local total, mine, everywhere = 0, 0, 0
        for _, fullType in ipairs(list) do
            local held = s.world:countCarried(fullType)
            mine = mine + held
            total = total + (carried and held or (facts and facts.types and facts.types[fullType] or 0))
        end
        if not carried then everywhere = sumOpen(s, function(f) local n = 0; for _, t in ipairs(list) do n = n + (f.types and f.types[t] or 0) end return n end) end
        return total, mine, everywhere
    end
    local total, mine, everywhere = ofTypes(order)
    local label = #order == 1 and tostring(item:getName()) or (#order .. " selected types")
    group(host, "all", "All " .. label .. " (" .. total .. ")",
        allRows(s, { filter = { ids = {}, types = order, all = false }, clicked = clicked, mine = mine, everywhere = everywhere },
            label .. " (" .. total .. ")", carried, total, picked, source, target, descriptor), item)

    if #order == 1 then
        local groups = { { id = Catalog.categoryId(item) } }
        for _, definition in ipairs(s.world.graph:list()) do
            if #groups < 4 and s.world.graph:matches(definition.id, descriptor) then groups[#groups + 1] = { id = definition.id } end
        end
        for _, entry in ipairs(groups) do
            local held = s.world:countCarriedCategory(entry.id)
            local here = facts and s.world:countMatching(source, oneCategory(entry.id)) or 0
            local amount = carried and held or here
            if amount > total then
                local name = App.categoryName(entry.id)
                local open = carried and 0 or sumOpen(s, function(f) return f.categories and f.categories[entry.id] or 0 end)
                group(host, "category", "All " .. name .. " (" .. amount .. ")",
                    allRows(s, { filter = oneCategory(entry.id), clicked = clicked, mine = held, everywhere = open },
                        name .. " (" .. amount .. ")", carried, amount, total, source, target, descriptor))
            end
        end
    end

    local fullType = order[1]
    local listed = #order == 1 and s.app:onChecklist("types", fullType)
    if #order == 1 then
        host:check("list", "On my loot list", listed, ask(s, "menu.list", listed and "unlist" or "list", clicked,
            function() return s.app:toggleChecklist("types", fullType) end), "Looting picks up everything on the list.")
    end
    local kept = s.app:isKept(item)
    host:check("keep", picked > 1 and "Keep these" or "Keep this one", kept, ask(s, "menu.keep", kept and "unkeep" or "keep", clicked, function()
        for _, entry in ipairs(items) do
            local ok, err = s.app:protect(entry, not kept)
            if not ok then return nil, err end
        end
        return true
    end), "LootBox never moves or deletes a kept item.")

    if #order == 1 then
        local child = host:sub("category", "Categories")
        local custom = App.customCategories()
        for index = 1, math.min(12, #custom) do
            local definition = custom[index]
            local inside = false
            for _, value in ipairs(definition.types) do if value == fullType then inside = true end end
            child:check("tag", definition.name, inside, ask(s, "menu.category", (inside and "remove from " or "add to ") .. definition.name, clicked, function()
                local kinds = {}
                for _, value in ipairs(definition.types) do if value ~= fullType then kinds[#kinds + 1] = value end end
                if not inside then kinds[#kinds + 1] = fullType end
                return App.saveCategory({ id = definition.id, name = definition.name, types = kinds, includes = definition.includes })
            end))
        end
        if #custom > 0 and picked == 1 then
            local single = child:sub("label", "Only this one")
            local labels = {}
            for _, id in ipairs(s.app:itemLabels(item)) do labels[id] = true end
            for index = 1, math.min(12, #custom) do
                local definition = custom[index]
                single:check("tag", definition.name, labels[definition.id], ask(s, "menu.tag", "tag " .. definition.name, clicked, function()
                    local ids = {}
                    for _, id in ipairs(s.app:itemLabels(item)) do if id ~= definition.id then ids[#ids + 1] = id end end
                    if not labels[definition.id] then ids[#ids + 1] = definition.id end
                    return s.app:setItemLabels(item, ids)
                end))
            end
        end
        child:row("newCategory", "New category...", function() UI.open(s.playerIndex, "categories", { type = fullType }) end)
    end
end

-- The world around the player ------------------------------------------------

local function aroundRows(host, s)
    local square = s.player:getCurrentSquare()
    if not square then return end
    local list, bins, clicked = listFilter(s.app), s.world:hasKnownBins(), Log.point(square)
    local child = host:sub("around", "Around here")
    local function place(target, icon, title, scope, options)
        local rows = {}
        local function add(rowIcon, text, kind, filter)
            rows[#rows + 1] = { icon = rowIcon, title = text, single = title .. ": " .. text:sub(1, 1):lower() .. text:sub(2),
                run = act(s, "menu.around", text .. " - " .. title, request(scope, kind, filter), clicked, options) }
        end
        if list then add("takeSome", "Take my loot list", "inventory", list) end
        add("take", "Take everything", "inventory", everything())
        if s.world:hasStorageLabels() then add("sort", "Put away loose items", "labels", everything()) end
        if bins then add("trash", "Throw everything away", "trash", everything()) end
        group(target, icon, title, rows)
    end
    local loot = getPlayerLoot and getPlayerLoot(s.playerIndex)
    local reachable = false
    for _, button in ipairs(loot and loot.backpacks or {}) do
        local facts = button.inventory and not s.world:owns(button.inventory) and s.world:containerFacts(button.inventory)
        if facts and not facts.locked and (facts.takeable > 0 or facts.explored == false) then reachable = true; break end
    end
    if reachable then place(child, "reach", "Within reach", "reach") end
    if square:getRoom() then
        local room = s.world:roomFacts(square)
        if room and (room.containers > 0 or room.groundItems > 0) then place(child, "room", "This room", "room") end
        if square:getBuilding() then place(child, "building", "This building", "building") end
    end
    if s.world:hasStorageLabels() and s.world:countCarried(nil) > 0 then
        child:row("sort", "Put away what I carry", act(s, "menu.around", "put away carried", request("inventory", "labels", everything()), clicked))
    end
    if child.context then
        place(child, "area", "Mark an area", "area", { area = true })
        presetRows(child, s, function(setup) return setup.scope ~= "container" and setup.destination.kind ~= "container" end, { square = floorHere(s) })
        child:row("plan", "Plan a job...", function() UI.open(s.playerIndex, "plan") end)
    end
end

local function vehicleRows(host, s, vehicle, containers)
    local clicked = Log.vehicle(vehicle)
    local mine = s.app.state.vehicle ~= nil and s.world:isRememberedVehicle(vehicle)
    local list = listFilter(s.app)
    if s.world:countCarried(nil) > 0 then
        local rows = {}
        if list and s.world:countCarriedFilter(list) > 0 then
            rows[#rows + 1] = { icon = "takeSome", title = "My loot list", single = "Load my loot list into this vehicle",
                run = act(s, "menu.vehicle", "load loot list", request("inventory", "vehicle", list, { ref = vehicle }), clicked) }
        end
        rows[#rows + 1] = { icon = "all", title = "Everything I carry", single = "Load everything I carry",
            run = act(s, "menu.vehicle", "load everything", request("inventory", "vehicle", everything(), { ref = vehicle }), clicked) }
        group(host, "putMenu", "Load", rows)
    end
    host:check("myVehicle", "My vehicle", mine, ask(s, "menu.vehicle", mine and "forget vehicle" or "remember vehicle", clicked, function()
        if mine then s.app.state.vehicle = nil; return s.app:persist() end
        return s.app:rememberVehicle(vehicle)
    end), "Hauling jobs go to this vehicle.")
    for _, entry in ipairs(nameAll(containers)) do
        containerRows(host:sub("inside", entry.name), s, entry.container, "menu.vehicle-part")
    end
end

-- Entry points ----------------------------------------------------------------

local function guarded(site, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then Log.fault(nil, site, err) end
    end
end

local function fluids(s, parent, branded, extra)
    local context = { playerIndex = s.playerIndex, parent = parent, branded = function() return branded:menu() end, app = s.app,
        preferences = s.preferences, tooltip = tooltip,
        interaction = function(origin, label) return Log.intent(origin, label, s.player) end }
    for key, value in pairs(extra) do context[key] = value end
    return context
end

Menus.inventoryMenu = guarded("menu.item", function(playerIndex, parent, items)
    local preferences = App.getPreferences()
    if not preferences.contextMenus or not allowed(playerIndex) then return end
    local s = session(playerIndex)
    if not s then return end
    local chosen = selectedItems(items)
    local item = chosen[1]
    if not item then return end
    s.square = s.player:getCurrentSquare()
    if preferences.tillFullEnabled then Log.guard("ConsumeMenu", require("LootBox/ConsumeMenu").add, playerIndex, parent, items, s.app, preferences) end
    if not preferences.inventoryShortcuts then return end
    local amount = Selection.capture(playerIndex, items)
    if amount then
        local option = parent:addOption("Select amount...", nil, function()
            Log.intent("menu.amount", "select amount", s.player, "item", Log.item(item, s.player))
            Selection.open(amount)
        end)
        option.iconTexture = getTexture(icons.amount)
        tooltip(option, "Select amount", "Highlight part of this stack, then drag it or right-click it.")
    end
    local host = root(parent)
    Log.guard("PourMenu", require("LootBox/PourMenu").add, fluids(s, parent, host, { items = items }))
    jobRows(host, s)
    itemRows(host, s, chosen, item)
    if #chosen == 1 and native(item, "InventoryContainer") then
        local contents = item:getInventory()
        if contents then containerRows(host:sub("inside", "Inside " .. tostring(item:getName()), item), s, contents, "menu.bag") end
    end
end)

-- Shared by a container's icon, its title pill and the empty space in its list.
local function containerMenu(playerIndex, parent, container, square)
    local preferences = App.getPreferences()
    if not preferences.contextMenus or not preferences.inventoryShortcuts or not container or not allowed(playerIndex) then return false end
    local s = session(playerIndex)
    if not s then return false end
    s.square = square or s.player:getCurrentSquare()
    local host = root(parent)
    jobRows(host, s)
    containerRows(host, s, container, "menu.container")
    return host.context ~= nil
end
Menus.containerMenu = containerMenu

Menus.paneMenu = guarded("menu.pane", function(playerIndex, parent, isLoot)
    if ownNoItems then return end
    local page = isLoot and getPlayerLoot(playerIndex) or (not isLoot and getPlayerInventory(playerIndex)) or nil
    local container = page and page.inventoryPane and page.inventoryPane.inventory
    if not container then return end
    if container:getType() ~= "floor" and not container:getContainingItem() then ObjectMenu.append(playerIndex, parent, container) end
    containerMenu(playerIndex, parent, container)
end)

local function pack(...) return { n = select("#", ...), ... } end

-- A container icon: the game's own entry, then the object's own options, then
-- anything mods add to a container, then LootBox.
local function iconMenu(page, container)
    local playerIndex = page.player
    local parent = getPlayerContextMenu(playerIndex)
    local before = #parent.options
    local id
    if Log.detailed then
        id = Log.intent("icon", "open container menu", getSpecificPlayer(playerIndex), "container", Log.container(container, getSpecificPlayer(playerIndex)))
    end
    if not container:getContainingItem() then
        ObjectMenu.append(playerIndex, parent, container, id)
        ownNoItems = true
        Log.guard("OnFillInventoryContextMenuNoItems", triggerEvent, "OnFillInventoryContextMenuNoItems", playerIndex, parent, not page.onCharacter)
        ownNoItems = false
    end
    Log.guard("containerMenu", containerMenu, playerIndex, parent, container, call(call(container, "getParent"), "getSquare"))
    if #parent.options > 0 and #parent.options ~= before then
        parent.forceVisible, parent.visibleCheck = true, true
        parent:setVisible(true)
        parent:bringToTop()
    end
end

function Menus.refreshContainers(page, phase)
    if phase ~= "end" then return end
    Selection.attach(page.inventoryPane)
    PaneClicks.attach(page.inventoryPane)
    for _, button in ipairs(page.backpacks or {}) do
        local previous = button.onRightMouseDown
        if previous and previous ~= wrapped[button] then
            local function onRightMouseDown(clicked, x, y, ...)
                if invoking[clicked] then return previous(clicked, x, y, ...) end
                local owner, container = clicked.parent and clicked.parent.parent, clicked.inventory
                local callback = previous
                if Focus.select(owner, container, clicked) then
                    -- Selecting rebuilds the sidebar; carry on with the widget that now owns this container.
                    local live = Focus.button(owner, container, clicked)
                    if not live or not live.onRightMouseDown then return true end
                    if live ~= clicked then
                        clicked, callback = live, live.onRightMouseDown
                        x, y = live:getMouseX(), live:getMouseY()
                    end
                end
                invoking[clicked] = true
                local result = pack(pcall(callback, clicked, x, y, ...))
                invoking[clicked] = nil
                if not result[1] then error(result[2], 0) end
                -- A bag's icon opens the bag's item menu, which already has everything.
                if owner and container and clicked.inventory == container and clicked.parent and clicked.parent.parent == owner
                    and not call(container, "getContainingItem") and allowed(owner.player) then
                    Log.guard("iconMenu", iconMenu, owner, container)
                end
                return unpack(result, 2, result.n)
            end
            button.onRightMouseDown = onRightMouseDown
            wrapped[button] = onRightMouseDown
        end
    end
end

Menus.worldMenu = guarded("menu.world", function(playerIndex, parent, objects, test)
    if ObjectMenu.building() then return end
    local preferences = App.getPreferences()
    if not preferences.contextMenus or not allowed(playerIndex) then return end
    if test then return end
    local s = session(playerIndex)
    if not s then return end
    if preferences.tillFullEnabled then
        local ground = {}
        for _, object in ipairs(objects or {}) do if native(object, "IsoWorldInventoryObject") then ground[#ground + 1] = object end end
        if #ground > 0 then Log.guard("ConsumeMenu", require("LootBox/ConsumeMenu").add, playerIndex, parent, ground, s.app, preferences) end
    end
    local containers, seen = {}, {}
    local function found(container)
        if storage(container) and not seen[container] then seen[container] = true; containers[#containers + 1] = { container = container } end
    end
    for _, object in ipairs(objects or {}) do
        s.square = s.square or call(object, "getSquare")
        for index = 0, (call(object, "getContainerCount") or 0) - 1 do found(call(object, "getContainerByIndex", index)) end
        if native(object, "IsoDeadBody") then found(call(object, "getContainer")) end
    end
    local host = root(parent)
    if preferences.worldShortcuts then
        Log.guard("MountedDispenserMenu", require("LootBox/MountedDispenserMenu").add, fluids(s, parent, host, { objects = objects }))
        jobRows(host, s)
        if #containers == 1 then containerRows(host, s, containers[1].container, "menu.world-container")
        else
            for _, entry in ipairs(nameAll(containers)) do
                containerRows(host:sub("inside", entry.name), s, entry.container, "menu.world-container")
            end
        end
    end
    local vehicle = call(s.player, "getVehicle")
    if not vehicle and IsoObjectPicker and IsoObjectPicker.Instance then
        vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
    end
    if vehicle and preferences.vehicleShortcuts then
        local parts = {}
        for index = 0, vehicle:getPartCount() - 1 do
            local container = vehicle:getPartByIndex(index):getItemContainer()
            if container and vehicle:canAccessContainer(index, s.player) then parts[#parts + 1] = { container = container } end
        end
        vehicleRows(host, s, vehicle, parts)
    end
    if preferences.worldShortcuts and not vehicle then aroundRows(host, s) end
end)

function Menus.install(ui)
    if UI then return end
    UI = ui
    Selection.install()
    Events.OnFillInventoryObjectContextMenu.Add(Menus.inventoryMenu)
    LuaEventManager.AddEvent("OnFillInventoryContextMenuNoItems")
    Events.OnFillInventoryContextMenuNoItems.Add(Menus.paneMenu)
    Events.OnRefreshInventoryWindowContainers.Add(Menus.refreshContainers)
    Events.OnFillWorldObjectContextMenu.Add(Menus.worldMenu)
end

return Menus
