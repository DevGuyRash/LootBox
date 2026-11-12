require "ISUI/ISContextMenu"
require "ISUI/ISToolTip"

local App = require "LootBox/App"
local Catalog = require "LootBox/Catalog"
local Guides = require "LootBox/Guides"
local Selection = require "LootBox/Selection"
local Menus = {}
local interface
local containerCallbacks = setmetatable({}, { __mode = "k" })
local iconPaths = {
    root = "media/ui/LootableMaps/map_lightbulb.png",
    manager = "media/ui/LootableMaps/map_door.png",
    help = "media/ui/LootableMaps/map_book.png",
    settings = "media/ui/LootableMaps/map_gears.png",
    saved = "media/ui/LootableMaps/map_vhs.png",
    runSetup = "media/ui/LootableMaps/map_arroweast.png",
    loot = "media/ui/LootableMaps/map_arrowsoutheast.png",
    unpack = "media/ui/inventoryPanes/TakeSameTypeOneContainer.png",
    drop = "media/ui/LootableMaps/map_arrowsouth.png",
    sort = "media/ui/Entity/BTN_Swap_Icon_48x48.png",
    move = "media/ui/LootableMaps/map_arrowsouthwest.png",
    store = "media/ui/inventoryPanes/TransferSameTypeOneContainer.png",
    vehicle = "media/ui/LootableMaps/map_steeringwheel.png",
    clean = "media/ui/LootableMaps/map_garbage.png",
    choose = "media/ui/craftingMenus/Icon_List.png",
    label = "Item_Pencil",
    vehicleLabels = "Item_Clipboard",
    categories = "media/ui/craftingMenus/Icon_Grid.png",
    customCategories = "media/ui/LootableMaps/map_star.png",
    createCategory = "media/ui/Entity/BTN_Plus_Icon_48x48.png",
    keep = "media/ui/LootableMaps/map_lock.png",
    tag = "media/ui/Entity/icon_link_io.png",
    find = "media/ui/Search_Icon_Off.png",
    reach = "media/ui/LootableMaps/map_eye.png",
    room = "media/ui/LootableMaps/map_house.png",
    building = "media/ui/LootableMaps/map_skyscraper.png",
    area = "media/ui/LootableMaps/map_target.png",
    delete = "media/ui/LootableMaps/map_exclamation.png",
    sortCarried = "media/ui/inventoryPanes/TransferSameTypeMultiContainer.png",
    rememberVehicle = "media/ui/LootableMaps/map_key.png",
    contents = "media/ui/Container_Crate.png",
    selectAmount = "media/ui/LootableMaps/map_checkmark.png",
}

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

local function add(menu, iconRole, title, action, description, unavailable)
    local iconPath = assert(iconPaths[iconRole], "Unknown LootBox context icon: " .. tostring(iconRole))
    local option = menu:addOption(title, nil, action)
    if not option then return nil end
    option.notAvailable = unavailable ~= nil
    if unavailable or description then tooltip(option, title, unavailable or description) end
    option.iconTexture = getTexture(iconPath)
    return option
end

local function submenu(menu, iconRole, title, container)
    local option = add(menu, iconRole, title)
    if iconRole == "contents" and container then
        local item = call(container, "getContainingItem")
        if item then
            option.iconTexture, option.itemForTexture = nil, item
        else
            local texture = ContainerButtonIcons and ContainerButtonIcons[call(container, "getType")]
            if texture then option.iconTexture = texture end
        end
    end
    local child = ISContextMenu:getNew(menu)
    menu:addSubMenu(option, child)
    child.lootBoxSources, child.lootBoxCommon = {}, false
    return child
end

local function rootMenu(parent)
    for _, option in ipairs(parent.options or {}) do
        if option.name == "LootBox" and option.lootBoxMenu then return option.lootBoxMenu end
    end
    local option = add(parent, "root", "LootBox")
    local menu = ISContextMenu:getNew(parent)
    parent:addSubMenu(option, menu)
    option.lootBoxMenu = menu
    menu.lootBoxSources, menu.lootBoxCommon = {}, false
    return menu
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
    local parent = call(container, "getParent")
    if native(parent, "IsoPlayer") then return "My inventory" end
    if native(parent, "IsoDeadBody") then return "Corpse inventory" end
    local raw = tostring(call(container, "getType") or "storage")
    local translated = getTextOrNull and getTextOrNull("IGUI_ContainerTitle_" .. raw)
    local custom = parent and call(container, "getCustomName")
    local name = (custom and custom ~= "" and custom) or translated or raw:gsub("^%l", string.upper)
    if (call(parent, "getContainerCount") or 0) > 1 then
        local slot = call(parent, "getContainerIndex", container)
        if slot then name = name .. " [compartment " .. tostring(slot + 1) .. "]" end
    end
    return name
end

local function menuAllowed(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    if not player or call(player, "isDead") then return false end
    if isGamePaused and isGamePaused() then return false end
    if getCore and call(getCore(), "isTutorial") then return false end
    if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.dontCreateMenu then return false end
    return true
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
    if menu.lootBoxCommon then return end
    menu.lootBoxCommon = true
    local setups, problem = app:getSetups()
    if preferences.savedShortcuts and setups and #setups.presets > 0 then
        local saved = submenu(menu, "saved", "Saved setups")
        for _, preset in ipairs(setups.presets) do
            local id, name = preset.id, preset.name
            add(saved, "runSetup", name, function()
                local setup, err = app:loadSetup(id, context)
                if not setup then open(playerIndex, context, "compose", err); return end
                quick(playerIndex, context, setup, setup.scope == "area" and not setup.area)
            end, "Run " .. name .. " with freshly bound targets. Cleanup always requires a new review.")
        end
    end
    add(menu, "manager", "Open LootBox", function() open(playerIndex, context, "home", problem) end,
        "Open common workflows, saved setups, the detailed composer, and current progress.")
    add(menu, "help", "Workflow help", function() open(playerIndex, context, "help") end,
        "Read complete walkthroughs for looting, labels and sorting, nested bags, vehicles, cleanup, and reusable setups.")
    add(menu, "settings", "Settings", function() open(playerIndex, context, "settings") end,
        "Choose which context shortcuts appear, quick-move confirmation, tips, and remembered setups.")
end

local function containerContext(playerIndex, source)
    local player = getSpecificPlayer(playerIndex)
    return { playerIndex = playerIndex, kind = "container", scope = "container",
        container = source, sourceContainer = source, targetContainer = source,
        containers = { source }, square = player:getCurrentSquare() }
end

local function routeContext(context, destination)
    local result = {}
    for key, value in pairs(context) do result[key] = value end
    result.containers = { context.sourceContainer }
    if destination then
        result.targetContainer = destination
        if destination ~= context.sourceContainer then result.containers[#result.containers + 1] = destination end
    end
    return result
end

local function visibleContainers(playerIndex, source)
    local result, seen = {}, {}
    if source then seen[source] = true end
    local function collect(page, pane)
        for index, button in ipairs(page and page.backpacks or {}) do
            local container = button.inventory
            if storage(container) and not seen[container] then
                seen[container] = true
                result[#result + 1] = { container = container, name = containerName(container), pane = pane, index = index }
            end
        end
    end
    collect(getPlayerInventory and getPlayerInventory(playerIndex), "Inventory")
    collect(getPlayerLoot and getPlayerLoot(playerIndex), "Loot")
    local counts = {}
    for _, entry in ipairs(result) do counts[entry.name] = (counts[entry.name] or 0) + 1 end
    for _, entry in ipairs(result) do
        if counts[entry.name] > 1 then
            entry.name = entry.name .. " (" .. entry.pane .. " icon " .. tostring(entry.index) .. ")"
        end
    end
    return result
end

local function worldContainerNames(playerIndex, containers)
    local names, counts, visible = {}, {}, {}
    for _, container in ipairs(containers) do
        local name = containerName(container)
        names[container], counts[name] = name, (counts[name] or 0) + 1
    end
    for _, entry in ipairs(visibleContainers(playerIndex)) do visible[entry.container] = entry end
    for index, container in ipairs(containers) do
        local name = names[container]
        if counts[name] > 1 then
            local entry, parent = visible[container], call(container, "getParent")
            local square = call(parent, "getSquare")
            if entry then
                names[container] = name .. " (" .. entry.pane .. " icon " .. tostring(entry.index) .. ")"
            elseif square then
                names[container] = name .. " (" .. tostring(call(square, "getX")) .. ", " .. tostring(call(square, "getY"))
                    .. ", floor " .. tostring(call(square, "getZ")) .. "; object " .. tostring((call(parent, "getObjectIndex") or index - 1) + 1) .. ")"
            else
                names[container] = name .. " (source " .. tostring(index) .. ")"
            end
        end
    end
    return names
end

local function containerActions(menu, playerIndex, context, app)
    local source = context.sourceContainer
    menu.lootBoxSources = menu.lootBoxSources or {}
    if menu.lootBoxSources[source] then return end
    menu.lootBoxSources[source] = true
    local player = getSpecificPlayer(playerIndex)
    local inventory, carried = player:getInventory(), app.world:owns(source)
    local name = containerName(source)
    local function setup(kind, destination)
        local target = routeContext(context, destination)
        local action = request("container", kind, allItems(), target)
        if kind == "container" then action.destination.ref = destination end
        return action, target
    end
    local function move(kind, destination)
        local action, target = setup(kind, destination)
        quick(playerIndex, target, action)
    end
    if source ~= inventory then
        add(menu, carried and "unpack" or "loot", carried and "Unpack contents to main inventory..." or "Loot contents...", function()
            move(carried and "container" or "inventory", carried and inventory or nil)
        end, carried and ("Move eligible contents of " .. name .. " into your main inventory. The bag itself stays where it is.")
            or ("Take eligible contents of " .. name .. " into your carried storage. Other open containers are excluded."))
    end
    if call(source, "getType") ~= "floor" then
        add(menu, "drop", "Empty contents onto floor here...", function() move("floor") end,
            "Place eligible contents of " .. name .. " on the floor at your current position. Nothing is deleted and the container stays in place.")
    end
    add(menu, "sort", "Sort contents...", function() move("labels") end,
        "Move eligible contents of " .. name .. " to storage with matching category labels. Unmatched or protected items stay with a reason.")
    local moveMenu = submenu(menu, "move", "Move contents to")
    for _, entry in ipairs(visibleContainers(playerIndex, source)) do
        local destination = entry.container
        if not (carried and source ~= inventory and destination == inventory) then
            add(moveMenu, "store", entry.name .. "...", function() move("container", destination) end,
                "Move eligible contents of " .. name .. " into " .. entry.name .. ". Icon positions count from the top of the named sidebar. Review access and capacity before starting.")
        end
    end
    add(moveMenu, "vehicle", "My remembered vehicle...", function() move("vehicle") end,
        "Haul eligible contents of " .. name .. " to your remembered car, using trunk storage before available seats.")
    add(menu, "clean", "Clean contents...", function() move("trash") end,
        "Haul eligible contents of " .. name .. " to real trash cans for deletion. The source container stays in place. Existing bin contents require fresh approval.")
    add(menu, "choose", "Choose items and categories...", function()
        local action, target = setup(source == inventory and "labels" or (carried and "container" or "inventory"),
            carried and source ~= inventory and inventory or nil)
        action.filter = { ids = {}, types = {}, all = false }
        target.request = action
        open(playerIndex, target, "compose")
    end, "Open Actions with " .. name .. " as the source. Narrow the selection, change the destination, or choose whether to search inside bags.")
    if storage(source) then
        if source ~= inventory then
            add(menu, "store", "Put carried items in " .. name .. "...", function()
                quick(playerIndex, context, request("inventory", "container", allItems(), context))
            end, "Move eligible carried items into this exact container. Review the selection, protection, and capacity before starting.")
        end
        add(menu, "label", "Label this container...", function()
            local target = routeContext(context)
            target.labelKind = "container"
            open(playerIndex, target, "labels")
        end, "Choose every category that belongs in " .. name .. ". These labels describe the container, not its individual items.")
    end
end

local function typeActions(menu, playerIndex, context, app, filter, suffix)
    local exactType = #filter.types > 0
    if not context.carried then
        add(menu, "loot", "Take all " .. suffix, function() quick(playerIndex, context, request("container", "inventory", filter, context)) end,
            "Take eligible matches from the clicked source into carried storage. Review includes nested contents when enabled.")
    end
    local target = context.targetContainer or context.container
    if storage(target) then
        add(menu, "store", (exactType and "Put all of this type in " or "Put carried " .. suffix .. " in ") .. containerName(target), function()
            quick(playerIndex, context, request("inventory", "container", filter, context))
        end, "Move eligible carried matches, including nested bags, to this named container.")
    end
    add(menu, "drop", exactType and "Drop all of this type here" or "Drop carried " .. suffix .. " here", function()
        quick(playerIndex, context, request("inventory", "floor", filter, context))
    end, "Place eligible carried matches on the clicked or current floor tile. This is an explicit floor destination.")
    add(menu, "sort", exactType and "Sort this item type" or "Sort carried " .. suffix, function()
        quick(playerIndex, context, request("inventory", "labels", filter, context))
    end, "Move eligible carried matches to loaded storage with matching labels. Items without a destination remain with a reason.")
end

local function categoryActions(menu, playerIndex, context, app)
    local item = context.item
    local nativeId = Catalog.categoryId(item)
    local categories = submenu(menu, "categories", "Category: " .. categoryName(nativeId))
    typeActions(categories, playerIndex, context, app, filterForCategory(nativeId), categoryName(nativeId))
    local matches = {}
    local descriptor = app.world:describe(item)
    for _, definition in ipairs(app.world.graph:list()) do
        if app.world.graph:matches(definition.id, descriptor) then matches[#matches + 1] = definition end
    end
    if #matches > 0 then
        local custom = submenu(menu, "customCategories", "My matching categories")
        for index = 1, math.min(6, #matches) do
            local definition = matches[index]
            local id, name = definition.id, definition.name
            local title = "Take " .. name
            if context.carried then
                title = storage(context.targetContainer) and ("Put carried " .. name .. " in " .. containerName(context.targetContainer))
                    or ("Sort carried " .. name)
            end
            local iconRole = context.carried and (storage(context.targetContainer) and "store" or "sort") or "loot"
            add(custom, iconRole, title, function()
                local destination = context.carried and (storage(context.targetContainer) and "container" or "labels") or "inventory"
                local scope = context.carried and "inventory" or "container"
                quick(playerIndex, context, request(scope, destination, filterForCategory(id), context))
            end, context.carried and "Move carried matches using this custom category. Adjust the route in the review if needed."
                or "Take matches from this source using this custom category.")
        end
        if #matches > 6 then
            add(custom, "choose", "More categories in Actions...", function() open(playerIndex, context, "compose") end,
                "Open the full category picker; the context menu keeps only a short list.")
        end
    end
end

local function itemMenu(menu, playerIndex, context, app, preferences)
    typeActions(menu, playerIndex, context, app, filterForType(context.item), "of this type")
    if preferences.categoryShortcuts then categoryActions(menu, playerIndex, context, app) end
    local keep = add(menu, "keep", "Keep this copy", function()
        local ok, err = app:protect(context.item, not app:isKept(context.item))
        if not ok then context.labelKind = "item"; open(playerIndex, context, "labels", err) end
    end, "Protect only this copy from automatic movement and deletion. Turn this off to make it eligible again.")
    menu:setOptionChecked(keep, app:isKept(context.item))
    add(menu, "tag", "Tag this copy...", function()
        context.labelKind = "item"
        open(playerIndex, context, "labels")
    end, "Add only this particular copy to custom or native categories. Keep is managed alongside its tags.")
    add(menu, "createCategory", "Create a category with this type...", function() open(playerIndex, context, "categories") end,
        "Start a custom category containing every copy of this item type. You can add more items and nested categories.")
    if storage(context.targetContainer) then
        add(menu, "label", "Label " .. containerName(context.targetContainer) .. "...", function()
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
    local loot = submenu(menu, "find", "Loot supplies")
    add(loot, "reach", "Within reach...", function()
        quick(playerIndex, context, request("reach", "inventory", app:getChecklist(), context))
    end, "Inspect reachable sources and collect your checklist. Choose supplies first if no checklist is saved.")
    local function workflow(iconRole, title, taskId, area, unavailable)
        add(loot, iconRole, title, function()
            local setup, err = Guides.prepare(taskId, app, context)
            if not setup then open(playerIndex, context, "compose", err); return end
            quick(playerIndex, context, setup, area)
        end, "Collect your checklist; choose supplies first if none is saved.", unavailable)
    end
    workflow("room", "Current room...", "loot-room", false, not room and "Stand inside the room, or choose an area." or nil)
    add(loot, "building", "Current building...", function()
        quick(playerIndex, context, request("building", "inventory", app:getChecklist(), context))
    end, "Walk and inspect your building section by section across its floors. Blocked and unloaded sections remain reported as unsearched.",
        not building and "Stand inside the building, or choose an area." or nil)
    workflow("area", "Select an area...", "loot-area", true)
    local clean = submenu(menu, "delete", "Clean and delete")
    add(clean, "room", "Clean current room...", function()
        quick(playerIndex, context, request("room", "trash", allItems(), context))
    end, "Select all unprotected items in the current room. Carried items are excluded. Review includes existing bin contents.",
        not room and "Stand inside the room, or use Clean an area." or nil)
    add(clean, "building", "Clean current building...", function()
        quick(playerIndex, context, request("building", "trash", allItems(), context))
    end, "Search this building across its floors, then haul unprotected items to eligible trash cans. Carried items are excluded. Deletion needs a fresh review.",
        not building and "Stand inside the building, or choose an area." or nil)
    add(clean, "area", "Clean an area...", function()
        quick(playerIndex, context, request("area", "trash", allItems(), context), true)
    end, "Choose two corners on the current floor, then review unprotected items and whole-bin deletion contents.")
    add(menu, "sortCarried", "Sort my carried items...", function()
        quick(playerIndex, context, request("inventory", "labels", allItems(), context))
    end, "Route eligible carried and nested-bag contents to matching labeled storage. Keep and favorites stay protected.")
end

local function vehicleActions(menu, playerIndex, context, app)
    add(menu, "rememberVehicle", "Remember this vehicle", function()
        local ok, err = app:rememberVehicle(context.vehicle)
        if not ok then open(playerIndex, context, "labels", err) end
    end, "Use this loaded vehicle as the destination for future hauling setups. The native key association and model are checked again.")
    add(menu, "vehicle", "Haul my checklist to this vehicle...", function()
        local setup = request("inventory", "vehicle", app:getChecklist(), context)
        setup.destination.ref = context.vehicle
        quick(playerIndex, context, setup)
    end, "Move your selected supplies into this car, preferring trunk then available seat storage. Choose supplies in Actions if no checklist is saved.")
    add(menu, "vehicleLabels", "Label this vehicle's storage...", function()
        context.labelKind = "container"
        open(playerIndex, context, "labels")
    end, "Choose a storage compartment and assign the categories it should accept.")
end

function Menus.inventoryMenu(playerIndex, parent, items)
    local preferences = App.getPreferences()
    if not preferences.contextMenus or not menuAllowed(playerIndex) then return end
    local app, item = App.get(playerIndex), selectedItem(items)
    if not app or not item then return end
    if preferences.inventoryShortcuts then
        local selection = Selection.capture(playerIndex, items)
        if selection then
            add(parent, "selectAmount", "Select amount...", function() Selection.open(selection) end,
                "Choose how many items to highlight in this stack, then drag or right-click the highlighted rows for a normal game action.")
        end
    end
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
    local menu = rootMenu(parent)
    if preferences.inventoryShortcuts then
        itemMenu(menu, playerIndex, context, app, preferences)
        if native(item, "InventoryContainer") then
            local contents = item:getInventory()
            if contents then
                local child = submenu(menu, "contents", "Contents of " .. containerName(contents), contents)
                containerActions(child, playerIndex, containerContext(playerIndex, contents), app)
            end
        end
    end
    common(menu, playerIndex, context, app, preferences)
end

function Menus.containerMenu(playerIndex, parent, container)
    local preferences = App.getPreferences()
    if not preferences.contextMenus or not container or not parent or not menuAllowed(playerIndex) then return end
    local app = App.get(playerIndex)
    if not app then return end
    local context = containerContext(playerIndex, container)
    local menu = rootMenu(parent)
    if preferences.inventoryShortcuts then containerActions(menu, playerIndex, context, app) end
    common(menu, playerIndex, context, app, preferences)
    return menu
end

function Menus.inventoryBackgroundMenu(playerIndex, parent, isLoot)
    local page
    if isLoot then page = getPlayerLoot(playerIndex) else page = getPlayerInventory(playerIndex) end
    local container = page and page.inventoryPane and page.inventoryPane.inventory
    Menus.containerMenu(playerIndex, parent, container)
end

function Menus.refreshContainers(page, phase)
    if phase ~= "end" then return end
    Selection.attach(page.inventoryPane)
    for _, button in ipairs(page.backpacks or {}) do
        local previous = button.onRightMouseDown
        if previous and previous ~= containerCallbacks[button] then
            local function onRightMouseDown(clicked, x, y)
                local result = previous(clicked, x, y)
                local owner = clicked.parent and clicked.parent.parent
                local container = clicked.inventory
                if not owner or not container or call(container, "getContainingItem") then return result end
                local parent = getPlayerContextMenu(owner.player)
                if Menus.containerMenu(owner.player, parent, container) then
                    parent.forceVisible, parent.visibleCheck = true, true
                    parent:setVisible(true)
                    parent:bringToTop()
                end
                return result
            end
            button.onRightMouseDown = onRightMouseDown
            containerCallbacks[button] = onRightMouseDown
        end
    end
end

function Menus.worldMenu(playerIndex, parent, objects, test)
    local preferences = App.getPreferences()
    if not preferences.contextMenus or not menuAllowed(playerIndex) then return end
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
    local menu = rootMenu(parent)
    if context.container and preferences.worldShortcuts then
        local names = worldContainerNames(playerIndex, context.containers)
        for _, container in ipairs(context.containers) do
            local source = container
            local target = containerContext(playerIndex, source)
            local contents = #context.containers > 1 and submenu(menu, "contents", "Contents of " .. names[source], source) or menu
            containerActions(contents, playerIndex, target, app)
        end
    end
    if preferences.vehicleShortcuts and context.vehicle then vehicleActions(menu, playerIndex, context, app) end
    if preferences.worldShortcuts then worldActions(menu, playerIndex, context, app) end
    common(menu, playerIndex, context, app, preferences)
end

function Menus.install(ui)
    if interface then return end
    interface = ui
    Selection.install()
    Events.OnFillInventoryObjectContextMenu.Add(Menus.inventoryMenu)
    LuaEventManager.AddEvent("OnFillInventoryContextMenuNoItems")
    Events.OnFillInventoryContextMenuNoItems.Add(Menus.inventoryBackgroundMenu)
    Events.OnRefreshInventoryWindowContainers.Add(Menus.refreshContainers)
    Events.OnFillWorldObjectContextMenu.Add(Menus.worldMenu)
end

return Menus
