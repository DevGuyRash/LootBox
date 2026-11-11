require "ISUI/ISContextMenu"
require "ISUI/ISToolTip"

local App = require "LootBox/App"
local Catalog = require "LootBox/Catalog"
local Guides = require "LootBox/Guides"
local Menus = {}
local interface

local function call(object, method, ...)
    if not object then return nil end
    local args = { ... }
    local ok, value = pcall(function() return object[method](object, unpack(args)) end)
    if ok then return value end
end

local function native(object, class)
    return object and instanceof(object, class)
end

local function plain(text)
    return tostring(text or ""):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\n", " <LINE> ")
end

local function tooltip(option, title, description)
    if not option then return end
    local tip = ISToolTip:new()
    tip:initialise()
    tip:setVisible(false)
    tip:setName(title)
    tip.maxLineWidth = 430
    tip.description = plain(description)
    option.toolTip = tip
end

local function add(menu, title, action, description, unavailable, icon)
    local option = menu:addOption(title, nil, action)
    if not option then return nil end
    option.notAvailable = unavailable ~= nil
    if unavailable or description then tooltip(option, title, unavailable or description) end
    if icon and getTexture then option.iconTexture = getTexture("media/ui/LootableMaps/" .. icon .. ".png") end
    return option
end

local function submenu(menu, title, icon)
    local option = add(menu, title, nil, nil, nil, icon)
    local child = ISContextMenu:getNew(menu)
    menu:addSubMenu(option, child)
    return child
end

local function open(playerIndex, context, mode, message)
    local window = interface.open(playerIndex, context, mode)
    if message and window and window.messageText then window:messageText(message) end
    return window
end

local function selectedItem(items)
    for _, selected in ipairs(items or {}) do
        if native(selected, "InventoryItem") then return selected end
        if type(selected) == "table" then
            for _, item in ipairs(selected.items or {}) do if native(item, "InventoryItem") then return item end end
        end
    end
end

local function storage(container)
    return container and call(container, "getType") ~= "floor"
end

local function containerName(container)
    local item = call(container, "getContainingItem")
    if item then return tostring(call(item, "getName") or "bag") end
    local part = call(container, "getVehiclePart")
    if part then
        local id = tostring(call(part, "getId") or "vehicle storage")
        return (getTextOrNull and getTextOrNull("IGUI_VehiclePart" .. id)) or id
    end
    local raw = tostring(call(container, "getType") or "storage")
    local translated = getTextOrNull and getTextOrNull("IGUI_ContainerTitle_" .. raw)
    return translated or raw:gsub("^%l", string.upper)
end

local function categoryName(id)
    if id:sub(1, 7) == "native:" then
        local raw = id:sub(8)
        local key = "IGUI_ItemCat_" .. raw
        local translated = getText(key)
        return translated and translated ~= key and translated or raw
    end
    local definition = App.category(id)
    return definition and definition.name or id
end

local function filterForType(item)
    return { ids = {}, types = { item:getFullType() }, all = false }
end

local function filterForCategory(id)
    return { ids = { id }, types = {}, all = false }
end

local function allItems()
    return { ids = {}, types = {}, all = true }
end

local function request(scope, destination, filter, context)
    local result = { scope = scope, includeInventory = false, includeBags = true,
        filter = filter, destination = { kind = destination } }
    if scope == "container" then result.sourceContainer = context.sourceContainer or context.container end
    if destination == "container" then result.destination.ref = context.targetContainer or context.container end
    if destination == "floor" then result.destination.ref = context.square or getSpecificPlayer(context.playerIndex):getSquare() end
    return result
end

local function quick(playerIndex, context, setup, area)
    return interface.quickAction(playerIndex, context, setup, area)
end

local function storageTargets(context, container)
    if not storage(container) then return end
    for _, existing in ipairs(context.containers) do if existing == container then return end end
    context.containers[#context.containers + 1] = container
end

local function common(menu, playerIndex, context, app, preferences)
    local setups, problem = app:getSetups()
    if preferences.savedShortcuts and setups and #setups.presets > 0 then
        local saved = submenu(menu, "Saved setups", "map_vhs")
        for _, preset in ipairs(setups.presets) do
            local id, name = preset.id, preset.name
            add(saved, name, function()
                local setup, err = app:loadSetup(id, context)
                if not setup then open(playerIndex, context, "compose", err); return end
                quick(playerIndex, context, setup, setup.scope == "area" and not setup.area)
            end, "Run " .. name .. " with freshly bound targets. Cleanup always requires a new review.")
        end
    end
    add(menu, "Open LootBox", function() open(playerIndex, context, "home", problem) end,
        "Open common workflows, saved setups, the detailed composer, and current progress.", nil, "map_lightbulb")
    add(menu, "Workflow help", function() open(playerIndex, context, "help") end,
        "Read complete walkthroughs for looting, labels and sorting, nested bags, vehicles, cleanup, and reusable setups.", nil, "map_exclamation")
    add(menu, "Settings", function() open(playerIndex, context, "settings") end,
        "Choose which context shortcuts appear, quick-move confirmation, tips, and remembered setups.")
end

local function typeActions(menu, playerIndex, context, app, filter, suffix)
    local exactType = #filter.types > 0
    if not context.carried then
        add(menu, "Take all " .. suffix, function() quick(playerIndex, context, request("container", "inventory", filter, context)) end,
            "Take eligible matches from the clicked source into carried storage. Review includes nested contents when enabled.", nil, "map_arrowsoutheast")
    end
    local target = context.targetContainer or context.container
    if storage(target) then
        add(menu, (exactType and "Put all of this type in " or "Put carried " .. suffix .. " in ") .. containerName(target), function()
            quick(playerIndex, context, request("inventory", "container", filter, context))
        end, "Move eligible carried matches, including nested bags, to this named container.", nil, "map_arrowsouthwest")
    end
    add(menu, exactType and "Drop all of this type here" or "Drop carried " .. suffix .. " here", function()
        quick(playerIndex, context, request("inventory", "floor", filter, context))
    end, "Place eligible carried matches on the clicked or current floor tile. This is an explicit floor destination.")
    add(menu, exactType and "Sort this item type" or "Sort carried " .. suffix, function()
        quick(playerIndex, context, request("inventory", "labels", filter, context))
    end, "Move eligible carried matches to loaded storage with matching labels. Items without a destination remain with a reason.")
end

local function categoryActions(menu, playerIndex, context, app)
    local item = context.item
    local nativeId = Catalog.categoryId(item)
    local categories = submenu(menu, "Category: " .. categoryName(nativeId))
    typeActions(categories, playerIndex, context, app, filterForCategory(nativeId), categoryName(nativeId))
    local matches = {}
    local descriptor = app.world:describe(item)
    for _, definition in ipairs(app.world.graph:list()) do
        if app.world.graph:matches(definition.id, descriptor) then matches[#matches + 1] = definition end
    end
    if #matches > 0 then
        local custom = submenu(menu, "My matching categories")
        for index = 1, math.min(6, #matches) do
            local definition = matches[index]
            local id, name = definition.id, definition.name
            local title = "Take " .. name
            if context.carried then
                title = storage(context.targetContainer) and ("Put carried " .. name .. " in " .. containerName(context.targetContainer))
                    or ("Sort carried " .. name)
            end
            add(custom, title, function()
                local destination = context.carried and (storage(context.targetContainer) and "container" or "labels") or "inventory"
                local scope = context.carried and "inventory" or "container"
                quick(playerIndex, context, request(scope, destination, filterForCategory(id), context))
            end, context.carried and "Move carried matches using this custom category. Adjust the route in the review if needed."
                or "Take matches from this source using this custom category.")
        end
        if #matches > 6 then
            add(custom, "More categories in Actions...", function() open(playerIndex, context, "compose") end,
                "Open the full category picker; the context menu keeps only a short list.")
        end
    end
end

local function itemMenu(menu, playerIndex, context, app, preferences)
    typeActions(menu, playerIndex, context, app, filterForType(context.item), "of this type")
    if preferences.categoryShortcuts then categoryActions(menu, playerIndex, context, app) end
    local keep = add(menu, "Keep this copy", function()
        local ok, err = app:protect(context.item, not app:isKept(context.item))
        if not ok then context.labelKind = "item"; open(playerIndex, context, "labels", err) end
    end, "Protect only this copy from automatic movement and deletion. Turn this off to make it eligible again.", nil, "map_lock")
    menu:setOptionChecked(keep, app:isKept(context.item))
    add(menu, "Tag this copy...", function()
        context.labelKind = "item"
        open(playerIndex, context, "labels")
    end, "Add only this particular copy to custom or native categories. Keep is managed alongside its tags.")
    add(menu, "Create a category with this type...", function() open(playerIndex, context, "categories") end,
        "Start a custom category containing every copy of this item type. You can add more items and nested categories.")
    if storage(context.targetContainer) then
        add(menu, "Label " .. containerName(context.targetContainer) .. "...", function()
            context.container, context.labelKind = context.targetContainer, "container"
            open(playerIndex, context, "labels")
        end, "Choose which categories belong in the currently selected storage container.")
    end
end

local function worldActions(menu, playerIndex, context, app)
    local player = getSpecificPlayer(playerIndex)
    local square = player:getCurrentSquare()
    local room = call(square, "getRoom")
    local building = call(square, "getBuilding")
    local loot = submenu(menu, "Loot supplies", "map_pill")
    add(loot, "Within reach...", function()
        quick(playerIndex, context, request("reach", "inventory", app:getChecklist(), context))
    end, "Inspect reachable sources and collect your checklist. Choose supplies first if no checklist is saved.")
    local function workflow(title, taskId, area, unavailable)
        add(loot, title, function()
            local setup, err = Guides.prepare(taskId, app, context)
            if not setup then open(playerIndex, context, "compose", err); return end
            quick(playerIndex, context, setup, area)
        end, "Collect your checklist; choose supplies first if none is saved.", unavailable)
    end
    workflow("Current room...", "loot-room", false, not room and "Stand inside the room, or choose an area." or nil)
    add(loot, "Current building...", function()
        quick(playerIndex, context, request("building", "inventory", app:getChecklist(), context))
    end, "Inspect sources belonging to your current building. Only loaded, permitted locations can be searched.",
        not building and "Stand inside the building, or choose an area." or nil)
    workflow("Select an area...", "loot-area", true)
    local clean = submenu(menu, "Clean and delete", "map_exclamation")
    add(clean, "Clean current room...", function()
        quick(playerIndex, context, request("room", "trash", allItems(), context))
    end, "Select all unprotected items in the current room. Carried items are excluded. Review includes existing bin contents.",
        not room and "Stand inside the room, or use Clean an area." or nil)
    add(clean, "Clean an area...", function()
        quick(playerIndex, context, request("area", "trash", allItems(), context), true)
    end, "Choose two corners on the current floor, then review unprotected items and whole-bin deletion contents.")
    add(menu, "Sort my carried items...", function()
        quick(playerIndex, context, request("inventory", "labels", allItems(), context))
    end, "Route eligible carried and nested-bag contents to matching labeled storage. Keep and favorites stay protected.")
end

local function vehicleActions(menu, playerIndex, context, app)
    add(menu, "Remember this vehicle", function()
        local ok, err = app:rememberVehicle(context.vehicle)
        if not ok then open(playerIndex, context, "labels", err) end
    end, "Use this loaded vehicle as the destination for future hauling setups. The native key association and model are checked again.", nil, "map_steeringwheel")
    add(menu, "Haul my checklist to this vehicle...", function()
        local setup = request("inventory", "vehicle", app:getChecklist(), context)
        setup.destination.ref = context.vehicle
        quick(playerIndex, context, setup)
    end, "Move your selected supplies into this car, preferring trunk then available seat storage. Choose supplies in Actions if no checklist is saved.")
    add(menu, "Label this vehicle's storage...", function()
        context.labelKind = "container"
        open(playerIndex, context, "labels")
    end, "Choose a storage compartment and assign the categories it should accept.")
end

function Menus.inventoryMenu(playerIndex, parent, items)
    local preferences = App.getPreferences()
    if not preferences.contextMenus then return end
    local app, item = App.get(playerIndex), selectedItem(items)
    if not app or not item then return end
    local player = getSpecificPlayer(playerIndex)
    local source = item:getContainer()
    local carried = app.world:owns(source)
    local viewed = app:currentContainer()
    local target
    if carried then target = storage(viewed) and viewed or nil else target = source end
    local context = { playerIndex = playerIndex, kind = "item", item = item, carried = carried,
        scope = carried and "inventory" or "container", sourceContainer = source,
        targetContainer = target, container = target, containers = {}, square = player:getCurrentSquare() }
    storageTargets(context, target)
    if native(item, "InventoryContainer") then storageTargets(context, item:getInventory()) end
    local menu = submenu(parent, "LootBox", "map_lightbulb")
    if preferences.inventoryShortcuts then itemMenu(menu, playerIndex, context, app, preferences) end
    common(menu, playerIndex, context, app, preferences)
end

function Menus.worldMenu(playerIndex, parent, objects, test)
    local preferences = App.getPreferences()
    if not preferences.contextMenus then return end
    local app = App.get(playerIndex)
    if not app then return end
    if test then return ISWorldObjectContextMenu.setTest() end
    local player = getSpecificPlayer(playerIndex)
    local context = { playerIndex = playerIndex, kind = "world", containers = {} }
    for _, object in ipairs(objects or {}) do
        if not context.square then context.square = call(object, "getSquare") end
        for index = 0, (call(object, "getContainerCount") or 0) - 1 do
            storageTargets(context, call(object, "getContainerByIndex", index))
        end
    end
    context.vehicle = player:getVehicle()
    if not context.vehicle and IsoObjectPicker and IsoObjectPicker.Instance then
        context.vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
    end
    if context.vehicle then
        context.kind = "vehicle"
        for index = 0, context.vehicle:getPartCount() - 1 do
            storageTargets(context, context.vehicle:getPartByIndex(index):getItemContainer())
        end
    end
    context.square = context.square or player:getCurrentSquare()
    context.container = context.containers[1]
    context.sourceContainer, context.targetContainer = context.container, context.container
    context.scope = context.container and "container" or "reach"
    local menu = submenu(parent, "LootBox", "map_lightbulb")
    if context.container and preferences.worldShortcuts then
        local name = containerName(context.container)
        add(menu, "Take all unprotected contents...", function()
            quick(playerIndex, context, request("container", "inventory", allItems(), context))
        end, "Take eligible contents of " .. name .. " into carried storage. Use Adjust setup to choose categories instead.")
        add(menu, "Put carried items in " .. name .. "...", function()
            quick(playerIndex, context, request("inventory", "container", allItems(), context))
        end, "Move eligible carried items to " .. name .. ". Preview the selection and capacity before starting.")
        add(menu, "Label this storage...", function()
            context.labelKind = "container"
            open(playerIndex, context, "labels")
        end, "Assign multiple categories to this actual clicked container. Other open loot panes are not used as a substitute.")
    end
    if preferences.vehicleShortcuts and context.vehicle then vehicleActions(menu, playerIndex, context, app) end
    if preferences.worldShortcuts then worldActions(menu, playerIndex, context, app) end
    common(menu, playerIndex, context, app, preferences)
end

function Menus.install(ui)
    if interface then return end
    interface = ui
    Events.OnFillInventoryObjectContextMenu.Add(Menus.inventoryMenu)
    Events.OnFillWorldObjectContextMenu.Add(Menus.worldMenu)
end

return Menus
