package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local current
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local Menu = {}
Menu.__index = Menu
function Menu:new(root) return setmetatable({ options = {}, optionPool = {}, submenus = {}, root = root }, self) end
function Menu:clear()
    for _, option in ipairs(self.options) do self.optionPool[#self.optionPool + 1] = option end
    self.options = {}
    if not self.root then self.menuCursor = 0 end
    self.visible = false
end
function Menu:setVisible(visible) self.visible = visible end
function Menu:bringToTop() self.raised = true end
function Menu:addOption(name, target, action)
    local option = table.remove(self.optionPool) or {}
    local keys = {}
    for key in pairs(option) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do option[key] = nil end
    option.name, option.target, option.onSelect = name, target, action
    self.options[#self.options + 1] = option
    return option
end
function Menu:addSubMenu(option, child) option.child = child end
function Menu:setOptionChecked(option, checked) option.checkMark = checked end
ISContextMenu = { getNew = function(_, parent)
    local root = parent.root or parent
    root.menuCursor = (root.menuCursor or 0) + 1
    local child = root.submenus[root.menuCursor]
    if not child then child = Menu:new(root); root.submenus[root.menuCursor] = child end
    child:clear()
    return child
end }
ISToolTip = { new = function()
    return { initialise = function() end, setVisible = function() end,
        setName = function(self, name) self.name = name end }
end }
package.loaded["ISUI/ISContextMenu"] = true
package.loaded["ISUI/ISToolTip"] = true

local registrations = { inventory = {}, world = {}, background = {}, refresh = {} }
local eventDeclarations = 0
Events = {
    OnFillInventoryObjectContextMenu = { Add = function(fn) registrations.inventory[#registrations.inventory + 1] = fn end },
    OnFillWorldObjectContextMenu = { Add = function(fn) registrations.world[#registrations.world + 1] = fn end },
    OnRefreshInventoryWindowContainers = { Add = function(fn) registrations.refresh[#registrations.refresh + 1] = fn end },
}
LuaEventManager = { AddEvent = function(name)
    assert(name == "OnFillInventoryContextMenuNoItems")
    eventDeclarations = eventDeclarations + 1
    if not Events[name] then Events[name] = { Add = function(fn) registrations.background[#registrations.background + 1] = fn end } end
end }
assert(Events.OnFillInventoryContextMenuNoItems == nil)
function getPlayerInventory() return current.inventoryPage end
function getPlayerLoot() return current.lootPage end
function getPlayerContextMenu(playerIndex) current.contextPlayer = playerIndex; return current.contextMenu end
function isGamePaused() return current.paused end
function getCore() return { isTutorial = function() return current.tutorial end } end
ISInventoryPaneContextMenu = {}
function instanceof(object, class) return type(object) == "table" and object.classes and object.classes[class] == true end
function getSpecificPlayer() return current.player end
function getText(key) return key == "IGUI_ItemCat_Food" and "Food" or key end
function getTextOrNull() return nil end
function getTexture(path)
    assert(type(path) == "string" and path ~= "", "Native texture keys must be nonempty strings")
    return path
end
function getMouseXScaled() return 10 end
function getMouseYScaled() return 20 end
ISWorldObjectContextMenu = { setTest = function() current.tested = current.tested + 1; return "available" end }
IsoObjectPicker = { Instance = { PickVehicle = function() return current.pickedVehicle end } }

local defaults = { contextMenus = true, inventoryShortcuts = true, worldShortcuts = true,
    vehicleShortcuts = true, categoryShortcuts = true, savedShortcuts = true,
    confirmQuickMoves = true, rememberLastSetup = true, showTips = true }
local App = {
    getPreferences = function() return copy(current.preferences) end,
    get = function() return current.app end,
    category = function(id)
        for _, definition in ipairs(current.definitions) do if definition.id == id then return definition end end
    end,
}
package.loaded["LootBox/App"] = App
local selectionInstalls = 0
package.loaded["LootBox/Selection"] = {
    install = function() selectionInstalls = selectionInstalls + 1 end,
    capture = function(playerIndex, items)
        current.selectionCapture = {playerIndex = playerIndex, items = items}
        return current.selectionTarget
    end,
    open = function(target) current.selectionOpened = target end,
    attach = function(pane) current.selectionAttached = pane end,
}
local Menus = require "LootBox/Menus"
local Guides = require "LootBox/Guides"
local interface = {
    showProgress = function(playerIndex) current.progressPlayer = playerIndex end,
    open = function(playerIndex, context, mode)
        local opened = { playerIndex = playerIndex, context = context, mode = mode }
        current.opened = opened
        return { messageText = function(_, message) opened.message = message end }
    end,
    quickAction = function(playerIndex, context, request, pickArea)
        current.quick = { playerIndex = playerIndex, context = context, request = request, pickArea = pickArea }
    end,
}
Menus.install(interface)

local function container(kind, owned)
    return { kind = kind, owned = owned,
        getType = function(self) return self.kind end,
        getContainingItem = function(self) return self.item end,
        getParent = function(self) return self.parent end,
        getCustomName = function(self) return self.customName end,
        getVehiclePart = function(self) return self.part end }
end

local function item(source, kind)
    return { classes = { InventoryItem = true }, source = source,
        getContainer = function(self) return self.source end,
        getFullType = function() return kind or "Base.Apple" end,
        getDisplayCategory = function() return "Food" end,
        getName = function(self) return self.name or kind or "Apple" end }
end

local function fixture()
    local f = { preferences = copy(defaults), definitions = {}, matches = {}, presets = {}, kept = {}, tested = 0,
        jobStatus = {state = "idle"}, recovery = {pending = false} }
    current = f
    ISInventoryPaneContextMenu.dontCreateMenu = false
    ContainerButtonIcons = nil
    f.inventory, f.crate, f.floor = container("inventory", true), container("crate", false), container("floor", false)
    f.square = { getRoom = function() return f.room end, getBuilding = function() return f.building end }
    f.room, f.building = {}, {}
    f.player = { classes = { IsoPlayer = true }, getInventory = function() return f.inventory end,
        isDead = function() return f.dead end, getCurrentSquare = function() return f.square end, getSquare = function() return f.square end,
        getVehicle = function() return f.seatedVehicle end }
    f.inventory.parent = f.player
    f.inventoryPage = { player = 0, inventoryPane = { inventory = f.inventory }, backpacks = {} }
    f.lootPage = { player = 0, inventoryPane = { inventory = f.crate }, backpacks = {} }
    f.contextMenu = Menu:new()
    f.viewed = f.crate
    f.checklist = { ids = { "native:Food" }, types = { "Base.Bandage" }, all = false }
    f.app = {
        status = function() return f.jobStatus end,
        recoveryStatus = function() return f.recovery end,
        recoverPersonalGear = function() f.recoveries = (f.recoveries or 0) + 1; return not f.recoveryError, f.recoveryError end,
        world = {
            owns = function(_, source) return source and source.owned == true end,
            describe = function(_, selected) return { fullType = selected:getFullType(), categoryId = "native:Food" } end,
            graph = { list = function() return f.definitions end,
                matches = function(_, id) return f.matches[id] == true end },
        },
        currentContainer = function() return f.viewed end,
        getChecklist = function() return copy(f.checklist) end,
        getSetups = function() return { presets = f.presets }, f.setupError end,
        isKept = function(_, selected) return f.kept[selected] == true end,
        protect = function(_, selected, keep) f.kept[selected] = keep; return true end,
        rememberVehicle = function(_, selected) f.remembered = selected; return true end,
        resolveSetup = function(_, setup, context)
            f.resolvedContext = context
            local request = copy(setup)
            if request.scope == "container" then request.sourceContainer = context.sourceContainer or context.container end
            if request.destination.kind == "container" then request.destination.ref = context.targetContainer or context.container end
            return request
        end,
        loadSetup = function(self, id, context)
            f.loadedId = id
            for _, preset in ipairs(f.presets) do
                if preset.id == id then return self:resolveSetup(preset.setup, context) end
            end
            return nil, "Saved setup is unavailable"
        end,
        start = function() error("Context menus must hand requests to the review interface") end,
    }
    f.apple = item(f.inventory)
    return f
end

local function option(menu, name)
    for _, candidate in ipairs(menu.options) do if candidate.name == name then return candidate end end
end
local function needed(menu, name) return assert(option(menu, name), "Missing menu action: " .. name) end
local function click(menu, name)
    local selected = needed(menu, name)
    assert(not selected.notAvailable, "Action unexpectedly unavailable: " .. name)
    assert(selected.onSelect, "Action is not selectable: " .. name)
    selected.onSelect(selected.target)
    return selected
end
local function icon(selected)
    assert(selected.iconTexture ~= nil or selected.itemForTexture ~= nil, "Missing icon: " .. selected.name)
    assert(selected.iconTexture == nil or selected.itemForTexture == nil, "Conflicting icon renderers: " .. selected.name)
    return selected.iconTexture or selected.itemForTexture
end
local function iconTree(menu)
    local total = 0
    for _, selected in ipairs(menu.options) do
        icon(selected)
        total = total + 1
        if selected.child then total = total + iconTree(selected.child) end
    end
    return total
end
local function ownedIcons(parent)
    local root = option(parent, "LootBox")
    if not root then return end
    icon(root)
    assert(iconTree(root.child) > 0)
    assert(icon(root) ~= icon(needed(root.child, "Open LootBox")), "Root and manager actions must have different symbols")
end
local function distinctIcons(menu)
    local seen = {}
    for _, selected in ipairs(menu.options) do
        local image = icon(selected)
        assert(not seen[image], "Unrelated actions share an icon: " .. tostring(seen[image]) .. " / " .. selected.name)
        seen[image] = selected.name
    end
end
local function inventoryMenu(f, selected)
    local parent = Menu:new()
    parent:addOption("Foreign action", nil, function() f.foreignClicked = true end)
    Menus.inventoryMenu(0, parent, selected or { f.apple })
    ownedIcons(parent)
    return parent, option(parent, "LootBox") and option(parent, "LootBox").child
end
local function worldMenu(f, objects)
    local parent = Menu:new()
    parent:addOption("Foreign action", nil, function() f.foreignClicked = true end)
    Menus.worldMenu(0, parent, objects or {}, false)
    ownedIcons(parent)
    return parent, option(parent, "LootBox") and option(parent, "LootBox").child
end
local function fixtureObject(f, target)
    return { getSquare = function() return f.square end, getContainerCount = function() return 1 end,
        getContainerByIndex = function(_, index) if index == 0 then return target end end }
end
local function vehicle(f)
    local storage = container("TruckBed", false)
    local part = { getItemContainer = function() return storage end, getId = function() return "TruckBed" end }
    storage.part = part
    return { getPartCount = function() return 1 end, getPartByIndex = function(_, index) if index == 0 then return part end end }
end

local function bag(f, owned, name)
    local contents = container("bag", owned)
    local selected = item(owned and f.inventory or f.crate, "Base.Bag_Schoolbag")
    selected.classes.InventoryContainer = true
    selected.name = name or "School Bag"
    selected.getInventory = function() return contents end
    contents.item = selected
    return selected, contents
end

local function sidebar(f, page, source, original)
    local button = { inventory = source, parent = { parent = page } }
    button.onRightMouseDown = original or function(clicked, x, y)
        f.nativeCalls = (f.nativeCalls or 0) + 1
        f.nativeCoordinates = { x, y }
        f.contextMenu:clear()
        f.contextMenu:addOption("Native rename", nil, function() f.nativeRenamed = true end)
        f.contextMenu:addOption("Foreign action", nil, function() f.foreignClicked = true end)
        f.contextMenu.forceVisible, f.contextMenu.visibleCheck = false, false
        return "native-result"
    end
    page.backpacks[#page.backpacks + 1] = button
    return button
end

local function contentsMenu(f, source)
    local parent = Menu:new()
    Menus.containerMenu(0, parent, source)
    ownedIcons(parent)
    return parent, option(parent, "LootBox") and option(parent, "LootBox").child
end

local function count(menu, name)
    local total = 0
    for _, candidate in ipairs(menu.options) do if candidate.name == name then total = total + 1 end end
    return total
end

local passed, failures = 0, {}
local function test(name, run)
    local ok, err = pcall(run, fixture())
    if ok then passed = passed + 1; print("PASS " .. name)
    else failures[#failures + 1] = name .. ": " .. tostring(err); print("FAIL " .. name .. ": " .. tostring(err)) end
end

print("Menu integration uses explicit native context/tooltip/App doubles; it does not prove native rendering or gameplay")

test("install is idempotent and preserves foreign menu actions", function(f)
    Menus.install(interface)
    assert(#registrations.inventory == 1 and #registrations.world == 1)
    assert(eventDeclarations == 1 and #registrations.background == 1 and #registrations.refresh == 1)
    local parent, menu = inventoryMenu(f)
    assert(menu)
    click(parent, "Foreign action")
    assert(f.foreignClicked)
end)

test("the master context option hides both entry points", function(f)
    f.preferences.contextMenus = false
    local _, inventory = inventoryMenu(f)
    local _, world = worldMenu(f)
    assert(not inventory and not world)
end)

test("disabling item shortcuts retains the full manager help and settings", function(f)
    f.preferences.inventoryShortcuts = false
    local _, menu = inventoryMenu(f)
    assert(not option(menu, "Drop all of this type here"))
    assert(not option(menu, "Keep this copy"))
    click(menu, "Open LootBox")
    assert(f.opened.mode == "home")
    click(menu, "Workflow help")
    assert(f.opened.mode == "help")
    click(menu, "Settings")
    assert(f.opened.mode == "settings")
end)

test("an exact-type drop spans carried bags and uses the current floor", function(f)
    local _, menu = inventoryMenu(f, { { items = { f.apple } } })
    click(menu, "Drop all of this type here")
    local request = f.quick.request
    assert(request.scope == "inventory" and request.includeBags == true)
    assert(request.destination.kind == "floor" and request.destination.ref == f.square)
    assert(request.filter.all == false and #request.filter.ids == 0)
    assert(#request.filter.types == 1 and request.filter.types[1] == "Base.Apple")
end)

test("a selected storage destination receives carried type matches", function(f)
    local _, menu = inventoryMenu(f)
    click(menu, "Put all of this type in Crate")
    assert(f.quick.request.scope == "inventory")
    assert(f.quick.request.destination.kind == "container" and f.quick.request.destination.ref == f.crate)
    assert(f.quick.context.targetContainer == f.crate)
end)

test("a selected floor does not become a storage destination", function(f)
    f.viewed = f.floor
    local _, menu = inventoryMenu(f)
    assert(not option(menu, "Put all of this type in Floor"))
    assert(not option(menu, "Label Floor..."))
    click(menu, "Tag this copy...")
    assert(f.opened.context.labelKind == "item" and #f.opened.context.containers == 0)
    assert(f.opened.context.targetContainer == nil and f.opened.context.container == nil)
end)

test("external item transfer uses its actual clicked source", function(f)
    local other = container("locker", false)
    local selected = item(other, "Base.CannedSardines")
    local _, menu = inventoryMenu(f, { selected })
    click(menu, "Take all of this type")
    assert(f.quick.request.scope == "container" and f.quick.request.sourceContainer == other)
    assert(f.quick.request.destination.kind == "inventory")
    assert(f.quick.request.filter.types[1] == "Base.CannedSardines")
end)

test("category actions select the native group instead of the clicked type", function(f)
    local _, menu = inventoryMenu(f)
    local category = needed(menu, "Category: Food").child
    click(category, "Drop carried Food here")
    assert(f.quick.request.filter.ids[1] == "native:Food" and #f.quick.request.filter.types == 0)
    assert(f.quick.request.filter.all == false)
end)

test("matching custom categories provide reusable group actions", function(f)
    f.definitions = { { id = "custom:7", name = "Run supplies" } }
    f.matches["custom:7"] = true
    local _, menu = inventoryMenu(f)
    click(needed(menu, "My matching categories").child, "Put carried Run supplies in Crate")
    assert(f.quick.request.filter.ids[1] == "custom:7")
    assert(f.quick.request.destination.ref == f.crate)
end)

test("category shortcuts can be hidden independently", function(f)
    f.preferences.categoryShortcuts = false
    f.definitions = { { id = "custom:7", name = "Run supplies" } }
    f.matches["custom:7"] = true
    local _, menu = inventoryMenu(f)
    assert(not option(menu, "Category: Food") and not option(menu, "My matching categories"))
    assert(option(menu, "Drop all of this type here"))
end)

test("Keep changes only the clicked copy and exposes its checked state", function(f)
    local other = item(f.inventory)
    local _, menu = inventoryMenu(f)
    assert(needed(menu, "Keep this copy").checkMark == false)
    local keepIcon = icon(needed(menu, "Keep this copy"))
    click(menu, "Keep this copy")
    assert(f.kept[f.apple] and not f.kept[other])
    local _, reopened = inventoryMenu(f)
    assert(needed(reopened, "Keep this copy").checkMark == true)
    assert(icon(needed(reopened, "Keep this copy")) == keepIcon)
    click(reopened, "Keep this copy")
    assert(f.kept[f.apple] == false)
end)

test("copy tags and storage labels focus their distinct targets", function(f)
    local _, menu = inventoryMenu(f)
    click(menu, "Tag this copy...")
    assert(f.opened.mode == "labels" and f.opened.context.labelKind == "item")
    click(menu, "Label Crate...")
    assert(f.opened.mode == "labels" and f.opened.context.labelKind == "container")
    assert(f.opened.context.container == f.crate)
end)

test("a floor click never borrows the unrelated open loot pane", function(f)
    f.viewed = f.crate
    local _, menu = worldMenu(f, { { getSquare = function() return f.square end, getContainerCount = function() return 0 end } })
    assert(not option(menu, "Loot contents (Smart Load)") and not option(menu, "Label this container..."))
    click(menu, "Open LootBox")
    assert(f.opened.context.container == nil and f.opened.context.targetContainer == nil)
    assert(#f.opened.context.containers == 0)
end)

test("a clicked fixture exposes its own take put and label actions", function(f)
    local locker = container("locker", false)
    local _, menu = worldMenu(f, { fixtureObject(f, locker) })
    click(menu, "Loot contents (Smart Load)")
    assert(f.quick.request.sourceContainer == locker and f.quick.request.filter.all)
    click(menu, "Put carried items in Locker...")
    assert(f.quick.request.destination.ref == locker and f.quick.request.scope == "inventory")
    click(menu, "Label this container...")
    assert(f.opened.context.container == locker and f.opened.context.labelKind == "container")
end)

test("room and area cleanup exclude carried inventory and request review", function(f)
    local _, menu = worldMenu(f)
    local clean = needed(menu, "Clean and delete").child
    click(clean, "Clean current room...")
    local request = f.quick.request
    assert(request.scope == "room" and request.destination.kind == "trash")
    assert(request.filter.all and request.includeInventory == false and request.includeBags == true)
    assert(not request.approval and not request.approved)
    click(clean, "Clean an area...")
    assert(f.quick.request.scope == "area" and f.quick.pickArea == true)
end)

test("loot shortcuts reuse the checklist for the chosen current scope", function(f)
    local _, menu = worldMenu(f)
    local loot = needed(menu, "Loot supplies").child
    for _, choice in ipairs({ { "Within reach...", "reach" }, { "Current room...", "room" },
        { "Current building...", "building" }, { "Select an area...", "area" } }) do
        click(loot, choice[1])
        local request = f.quick.request
        assert(request.scope == choice[2] and request.destination.kind == "inventory")
        assert(request.filter.all == false and request.filter.ids[1] == "native:Food")
        assert(request.filter.types[1] == "Base.Bandage" and request.includeInventory == false)
        if choice[2] == "area" then assert(f.quick.pickArea == true and request.area == nil) end
    end
end)

test("room and building shortcuts explain unavailable locations", function(f)
    f.room, f.building = nil, nil
    local _, menu = worldMenu(f)
    local loot = needed(menu, "Loot supplies").child
    local room = needed(loot, "Current room...")
    local building = needed(loot, "Current building...")
    local clean = needed(needed(menu, "Clean and delete").child, "Clean current room...")
    local cleanBuilding = needed(needed(menu, "Clean and delete").child, "Clean current building...")
    assert(room.notAvailable and room.toolTip.description:find("Stand inside", 1, true))
    assert(building.notAvailable and clean.notAvailable and cleanBuilding.notAvailable)
    assert(not needed(loot, "Select an area...").notAvailable)
end)

test("building cleanup requests the full building without carried items or an area picker", function(f)
    local _, menu = worldMenu(f)
    click(needed(menu, "Clean and delete").child, "Clean current building...")
    local request = f.quick.request
    assert(request.scope == "building" and request.destination.kind == "trash")
    assert(request.filter.all and #request.filter.ids == 0 and #request.filter.types == 0)
    assert(request.includeInventory == false and request.includeBags == true)
    assert(not f.quick.pickArea)
end)

test("world shortcuts can be hidden without hiding the manager", function(f)
    f.preferences.worldShortcuts = false
    local _, menu = worldMenu(f, { fixtureObject(f, f.crate) })
    assert(not option(menu, "Loot supplies") and not option(menu, "Clean and delete"))
    assert(not option(menu, "Loot contents (Smart Load)"))
    click(menu, "Open LootBox")
    assert(f.opened.mode == "home")
end)

test("vehicle shortcuts remember and haul to the actual selected vehicle", function(f)
    local selected = vehicle(f)
    f.pickedVehicle = selected
    local _, menu = worldMenu(f)
    click(menu, "Remember this vehicle")
    assert(f.remembered == selected)
    click(menu, "Haul my checklist to this vehicle...")
    assert(f.quick.request.destination.kind == "vehicle" and f.quick.request.destination.ref == selected)
    assert(f.quick.request.filter.ids[1] == "native:Food")
    click(menu, "Label this vehicle's storage...")
    assert(f.opened.context.vehicle == selected and #f.opened.context.containers == 1)
end)

test("vehicle shortcuts can be hidden while other world actions remain", function(f)
    f.pickedVehicle = vehicle(f)
    f.preferences.vehicleShortcuts = false
    local _, menu = worldMenu(f)
    assert(not option(menu, "Remember this vehicle") and not option(menu, "Haul my checklist to this vehicle..."))
    assert(option(menu, "Loot supplies"))
end)

test("saved setups receive fresh clicked targets and can be hidden", function(f)
    f.presets = { { id = "setup:9", name = "Food to clicked storage", setup = {
        scope = "inventory", filter = { ids = { "native:Food" }, types = {}, all = false },
        destination = { kind = "container" } } } }
    local target = container("locker", false)
    local _, menu = worldMenu(f, { fixtureObject(f, target) })
    click(needed(menu, "Saved setups").child, "Food to clicked storage")
    assert(f.loadedId == "setup:9" and f.resolvedContext.container == target)
    assert(f.quick.request.destination.ref == target)
    f.preferences.savedShortcuts = false
    local _, hidden = worldMenu(f, { fixtureObject(f, target) })
    assert(not option(hidden, "Saved setups"))
end)

test("native world availability probing respects the master setting", function(f)
    local parent = Menu:new()
    assert(Menus.worldMenu(0, parent, {}, true) == "available")
    assert(f.tested == 1 and #parent.options == 0)
    f.preferences.contextMenus = false
    assert(Menus.worldMenu(0, parent, {}, true) == nil)
    assert(f.tested == 1 and #parent.options == 0)
end)

test("guide starters reuse a checklist while clean and sort select unprotected items", function(f)
    local context = { square = f.square, container = f.crate }
    local loot = assert(Guides.prepare("loot-room", f.app, context))
    assert(loot.scope == "room" and loot.destination.kind == "inventory")
    assert(loot.filter.ids[1] == "native:Food" and loot.filter.types[1] == "Base.Bandage")
    assert(loot.filter.all == false and loot.includeInventory == false and loot.includeBags)
    local clean = assert(Guides.prepare("clean-area", f.app, context))
    assert(clean.scope == "area" and clean.area == nil and clean.destination.kind == "trash")
    assert(clean.filter.all and #clean.filter.ids == 0 and #clean.filter.types == 0 and clean.includeInventory == false)
    local sort = assert(Guides.prepare("sort-carried", f.app, context))
    assert(sort.scope == "inventory" and sort.destination.kind == "labels" and sort.filter.all)
    assert(f.resolvedContext == context)
end)

test("building guide starters keep the loot checklist distinct from whole-building cleanup", function(f)
    local context = { square = f.square }
    local loot = assert(Guides.prepare("loot-building", f.app, context))
    assert(loot.scope == "building" and loot.destination.kind == "inventory")
    assert(loot.filter.ids[1] == "native:Food" and loot.filter.types[1] == "Base.Bandage" and not loot.filter.all)
    assert(loot.includeInventory == false and loot.includeBags == true)
    local clean = assert(Guides.prepare("clean-building", f.app, context))
    assert(clean.scope == "building" and clean.destination.kind == "trash" and clean.filter.all)
    assert(#clean.filter.ids == 0 and #clean.filter.types == 0 and clean.includeInventory == false)
    assert(f.resolvedContext == context)
end)

test("vehicle guide starter keeps remembered-car semantics and invalid tasks return errors", function(f)
    local haul = assert(Guides.prepare("haul-car", f.app, { vehicle = vehicle(f) }))
    assert(haul.scope == "inventory" and haul.destination.kind == "vehicle" and haul.destination.ref == nil)
    local missing, reason = Guides.prepare("not-a-task", f.app, {})
    assert(missing == nil and type(reason) == "string")
    missing, reason = Guides.prepare("loot-room", nil, {})
    assert(missing == nil and type(reason) == "string")
end)

test("container contents shortcuts capture B even when A stays selected", function(f)
    local clicked = container("locker", false)
    local _, menu = contentsMenu(f, clicked)
    for _, route in ipairs({ { "Loot contents (Smart Load)", "inventory" },
        { "Empty contents onto floor here...", "floor" }, { "Sort contents...", "labels" },
        { "Clean contents (delete)", "trash" } }) do
        click(menu, route[1])
        local request = f.quick.request
        assert(request.scope == "container" and request.sourceContainer == clicked)
        assert(request.sourceContainer ~= f.viewed and request.destination.kind == route[2])
        assert(request.filter.all and #request.filter.ids == 0 and #request.filter.types == 0)
        assert(request.includeBags and request.includeInventory == false)
        assert(not request.approval and not request.approved and not request.binReview)
        if route[2] == "floor" then assert(request.destination.ref == f.square) end
    end
    assert(f.viewed == f.crate)
end)

test("container composer and labels retain the exact clicked source", function(f)
    local clicked = container("locker", false)
    local _, menu = contentsMenu(f, clicked)
    click(menu, "Choose items and categories...")
    local context = f.opened.context
    assert(f.opened.mode == "compose" and context.sourceContainer == clicked)
    assert(context.request.scope == "container" and context.request.sourceContainer == clicked)
    assert(context.request.includeBags and context.request.filter.all == false)
    assert(#context.request.filter.ids == 0 and #context.request.filter.types == 0)
    click(menu, "Label this container...")
    assert(f.opened.mode == "labels" and f.opened.context.labelKind == "container")
    assert(f.opened.context.container == clicked and f.opened.context.targetContainer == clicked)
    click(menu, "Open LootBox")
    assert(f.opened.mode == "home" and f.opened.context.sourceContainer == clicked)
end)

test("inbound carried transfers target the clicked container", function(f)
    local clicked = container("locker", false)
    local _, menu = contentsMenu(f, clicked)
    click(menu, "Put carried items in Locker...")
    assert(f.quick.request.scope == "inventory" and f.quick.request.sourceContainer == nil)
    assert(f.quick.request.destination.kind == "container" and f.quick.request.destination.ref == clicked)
    assert(f.quick.context.targetContainer == clicked and f.quick.request.includeBags)
end)

test("unpacking a carried bag explicitly targets main inventory", function(f)
    local selected, contents = bag(f, true)
    local _, menu = inventoryMenu(f, { selected })
    local inside = needed(menu, "Contents of School Bag").child
    click(inside, "Unpack contents to main inventory...")
    local request = f.quick.request
    assert(request.scope == "container" and request.sourceContainer == contents)
    assert(request.destination.kind == "container" and request.destination.ref == f.inventory)
    assert(request.sourceContainer ~= selected:getContainer() and request.includeBags)
    assert(not option(inside, "Loot contents (Smart Load)"))
    click(inside, "Choose items and categories...")
    assert(f.opened.context.request.sourceContainer == contents)
    assert(f.opened.context.request.destination.kind == "container" and f.opened.context.request.destination.ref == f.inventory)
end)

test("external bag contents loot separately from the bag item", function(f)
    local selected, contents = bag(f, false, "Store bag")
    local _, menu = inventoryMenu(f, { selected })
    local inside = needed(menu, "Contents of Store bag").child
    click(inside, "Loot contents (Smart Load)")
    assert(f.quick.request.sourceContainer == contents and f.quick.request.destination.kind == "inventory")
    assert(f.quick.context.item == nil)
    click(menu, "Take all of this type")
    assert(f.quick.request.sourceContainer == f.crate and f.quick.request.filter.types[1] == "Base.Bag_Schoolbag")
    click(inside, "Label this container...")
    assert(f.opened.context.container == contents)
    click(menu, "Tag this copy...")
    assert(f.opened.context.item == selected and f.opened.context.container == f.crate)
    assert(f.opened.context.sourceContainer == f.crate and f.opened.context.labelKind == "item")
end)

test("visible destination choices retain distinct exact references", function(f)
    local clicked = container("locker", false)
    local cupboard, trunk = container("cupboard", false), container("TruckBed", false)
    local part = { getId = function() return "TruckBed" end }
    trunk.part = part
    sidebar(f, f.inventoryPage, f.inventory)
    sidebar(f, f.lootPage, clicked)
    sidebar(f, f.lootPage, cupboard)
    sidebar(f, f.lootPage, trunk)
    sidebar(f, f.lootPage, cupboard)
    local _, menu = contentsMenu(f, clicked)
    local moves = needed(menu, "Move contents to").child
    assert(not option(moves, "Locker..."))
    assert(count(moves, "Cupboard...") == 1)
    for _, route in ipairs({ { "Main inventory only...", f.inventory }, { "Cupboard...", cupboard }, { "TruckBed...", trunk } }) do
        click(moves, route[1])
        assert(f.quick.request.scope == "container" and f.quick.request.sourceContainer == clicked)
        assert(f.quick.request.destination.kind == "container" and f.quick.request.destination.ref == route[2])
        assert(f.quick.context.targetContainer == route[2])
    end
    click(moves, "My remembered vehicle...")
    assert(f.quick.request.sourceContainer == clicked and f.quick.request.destination.kind == "vehicle")
    assert(f.quick.request.destination.ref == nil)
end)

test("same-name destinations expose their native sidebar positions", function(f)
    local first, second = container("crate", false), container("crate", false)
    sidebar(f, f.lootPage, f.floor)
    sidebar(f, f.lootPage, first)
    sidebar(f, f.lootPage, second)
    local _, menu = contentsMenu(f, f.inventory)
    local moves = needed(menu, "Move contents to").child
    assert(not option(moves, "Crate..."))
    click(moves, "Crate (Loot icon 2)...")
    assert(f.quick.request.destination.ref == first)
    click(moves, "Crate (Loot icon 3)...")
    assert(f.quick.request.destination.ref == second)
    assert(needed(moves, "Crate (Loot icon 2)...").toolTip.description:find("top", 1, true))
end)

test("unpack avoids a redundant main-inventory move choice", function(f)
    local _, contents = bag(f, true)
    sidebar(f, f.inventoryPage, f.inventory)
    sidebar(f, f.inventoryPage, contents)
    sidebar(f, f.lootPage, f.crate)
    local _, menu = contentsMenu(f, contents)
    local moves = needed(menu, "Move contents to").child
    assert(not option(moves, "Main inventory only...") and not option(moves, "School Bag..."))
    assert(option(moves, "Crate..."))
    click(menu, "Unpack contents to main inventory...")
    assert(f.quick.request.destination.ref == f.inventory)
end)

test("main inventory omits self-looting and starts composer with sorting", function(f)
    local _, menu = contentsMenu(f, f.inventory)
    assert(not option(menu, "Loot contents (Smart Load)") and not option(menu, "Unpack contents to main inventory..."))
    assert(not option(menu, "Put carried items in My inventory..."))
    assert(option(menu, "Empty contents onto floor here...") and option(menu, "Clean contents (delete)"))
    click(menu, "Choose items and categories...")
    assert(f.opened.context.request.sourceContainer == f.inventory)
    assert(f.opened.context.request.destination.kind == "labels")
end)

test("floor contents offer pickup sorting cleanup but no floor-to-self or labels", function(f)
    local unsafeNames = 0
    f.floor.getCustomName = function() unsafeNames = unsafeNames + 1; error("Native custom names require a parent object") end
    local _, menu = contentsMenu(f, f.floor)
    assert(not option(menu, "Empty contents onto floor here...") and not option(menu, "Label this container..."))
    assert(not option(menu, "Put carried items in Floor...") and unsafeNames == 0)
    for _, route in ipairs({ { "Loot contents (Smart Load)", "inventory" }, { "Sort contents...", "labels" }, { "Clean contents (delete)", "trash" } }) do
        click(menu, route[1])
        assert(f.quick.request.sourceContainer == f.floor and f.quick.request.destination.kind == route[2])
    end
end)

test("native no-item pane events use their own displayed container without opposite-pane fallback", function(f)
    local _, contents = bag(f, true)
    f.inventoryPage.inventoryPane.inventory = contents
    local inventoryParent, lootParent = Menu:new(), Menu:new()
    registrations.background[1](0, inventoryParent, false)
    registrations.background[1](0, lootParent, true)
    click(needed(inventoryParent, "LootBox").child, "Empty contents onto floor here...")
    assert(f.quick.request.sourceContainer == contents)
    click(needed(lootParent, "LootBox").child, "Loot contents (Smart Load)")
    assert(f.quick.request.sourceContainer == f.crate)
    f.inventoryPage = nil
    local missing = Menu:new()
    registrations.background[1](0, missing, false)
    assert(not option(missing, "LootBox"))
    f.inventoryPage = { inventoryPane = { inventory = f.inventory } }
    f.lootPage = nil
    registrations.background[1](0, missing, true)
    assert(not option(missing, "LootBox"))
end)

test("sidebar callback preserves native entries result and clicked B source", function(f)
    local clicked = container("locker", false)
    local button = sidebar(f, f.lootPage, clicked)
    registrations.refresh[1](f.lootPage, "end")
    assert(button.onRightMouseDown(button, 7, 9) == "native-result")
    assert(f.nativeCalls == 1 and f.nativeCoordinates[1] == 7 and f.nativeCoordinates[2] == 9)
    click(f.contextMenu, "Native rename"); click(f.contextMenu, "Foreign action")
    assert(f.nativeRenamed and f.foreignClicked)
    assert(f.contextMenu.visible and f.contextMenu.raised and f.contextMenu.forceVisible and f.contextMenu.visibleCheck)
    local menu = needed(f.contextMenu, "LootBox").child
    click(menu, "Loot contents (Smart Load)")
    assert(f.quick.request.sourceContainer == clicked and f.viewed == f.crate)
    assert(count(f.contextMenu, "LootBox") == 1)
end)

test("refresh waits until native buttons are complete and repeated refresh does not duplicate callbacks", function(f)
    local button = sidebar(f, f.lootPage, f.crate)
    local original = button.onRightMouseDown
    for _, phase in ipairs({ "begin", "beforeFloor", "buttonsAdded" }) do registrations.refresh[1](f.lootPage, phase) end
    assert(button.onRightMouseDown == original)
    registrations.refresh[1](f.lootPage, "end")
    registrations.refresh[1](f.lootPage, "end")
    button.onRightMouseDown(button, 0, 0)
    assert(f.nativeCalls == 1 and count(f.contextMenu, "LootBox") == 1)
    local menu = needed(f.contextMenu, "LootBox").child
    assert(count(menu, "Loot contents (Smart Load)") == 1 and count(menu, "Open LootBox") == 1)
end)

test("pooled sidebar buttons read current container and current owning page", function(f)
    local button = sidebar(f, f.lootPage, f.crate)
    registrations.refresh[1](f.lootPage, "end")
    button.onRightMouseDown(button, 0, 0)
    click(needed(f.contextMenu, "LootBox").child, "Loot contents (Smart Load)")
    assert(f.quick.request.sourceContainer == f.crate)
    local replacement = container("locker", false)
    button.inventory = replacement
    button.parent.parent = f.inventoryPage
    f.inventoryPage.player = 1
    button.onRightMouseDown(button, 0, 0)
    click(needed(f.contextMenu, "LootBox").child, "Loot contents (Smart Load)")
    assert(f.quick.request.sourceContainer == replacement and f.nativeCalls == 2)
    assert(f.contextPlayer == 1 and f.quick.playerIndex == 1)
end)

test("pooled context submenus repopulate all contents actions on reopening", function(f)
    local selected = bag(f, true)
    local parent = Menu:new()
    for _ = 1, 3 do
        parent:clear()
        Menus.inventoryMenu(0, parent, { selected })
        local menu = needed(parent, "LootBox").child
        local contents = needed(menu, "Contents of School Bag").child
        assert(count(parent, "LootBox") == 1 and count(contents, "Sort contents...") == 1)
        click(contents, "Clean contents (delete)")
        assert(f.quick.request.sourceContainer == selected:getInventory())
    end
end)

test("cooperative wrapper chains append one contents group without removing foreign behavior", function(f)
    local button = sidebar(f, f.lootPage, f.crate)
    registrations.refresh[1](f.lootPage, "end")
    local wrapped = button.onRightMouseDown
    button.onRightMouseDown = function(clicked, x, y)
        local result = wrapped(clicked, x, y)
        f.foreignWrapper = (f.foreignWrapper or 0) + 1
        return result
    end
    registrations.refresh[1](f.lootPage, "end")
    assert(button.onRightMouseDown(button, 0, 0) == "native-result")
    assert(f.nativeCalls == 1 and f.foreignWrapper == 1)
    local menu = needed(f.contextMenu, "LootBox").child
    assert(count(f.contextMenu, "LootBox") == 1 and count(menu, "Loot contents (Smart Load)") == 1)
    assert(count(menu, "Open LootBox") == 1)
end)

test("portable-bag sidebar uses one native item-event menu instead of appending a second root", function(f)
    local selected, contents = bag(f, true)
    local button = sidebar(f, f.inventoryPage, contents, function()
        f.contextMenu:clear()
        f.contextMenu:addOption("Equip on back", nil, function() f.equipped = true end)
        registrations.inventory[1](0, f.contextMenu, { selected })
        return "bag-result"
    end)
    registrations.refresh[1](f.inventoryPage, "end")
    assert(button.onRightMouseDown(button, 0, 0) == "bag-result")
    local menu = needed(f.contextMenu, "LootBox").child
    assert(count(f.contextMenu, "LootBox") == 1 and count(menu, "Contents of School Bag") == 1)
    assert(not option(menu, "Clean contents (delete)"))
    click(f.contextMenu, "Equip on back"); assert(f.equipped)
    click(needed(menu, "Contents of School Bag").child, "Sort contents...")
    assert(f.quick.request.sourceContainer == contents and f.quick.request.destination.kind == "labels")
end)

test("portable-bag wrapper never resurrects a deliberately suppressed native menu", function(f)
    local _, contents = bag(f, true)
    local button = sidebar(f, f.inventoryPage, contents, function()
        f.contextMenu:clear()
        return "suppressed"
    end)
    registrations.refresh[1](f.inventoryPage, "end")
    assert(button.onRightMouseDown(button, 0, 0) == "suppressed")
    assert(#f.contextMenu.options == 0 and not f.contextMenu.visible)
end)

test("container shortcuts respect preferences without removing native entries", function(f)
    local button = sidebar(f, f.lootPage, f.crate)
    registrations.refresh[1](f.lootPage, "end")
    f.preferences.inventoryShortcuts = false
    button.onRightMouseDown(button, 0, 0)
    local menu = needed(f.contextMenu, "LootBox").child
    assert(not option(menu, "Loot contents (Smart Load)") and not option(menu, "Clean contents (delete)"))
    click(menu, "Settings"); assert(f.opened.mode == "settings")
    f.preferences.contextMenus = false
    button.onRightMouseDown(button, 0, 0)
    assert(not option(f.contextMenu, "LootBox") and option(f.contextMenu, "Native rename"))
    assert(not f.contextMenu.forceVisible and not f.contextMenu.visibleCheck)
end)

test("container entry points respect native paused tutorial dead and suppressed-menu states", function(f)
    for _, key in ipairs({ "paused", "tutorial", "dead", "suppressed" }) do
        f[key] = true
        ISInventoryPaneContextMenu.dontCreateMenu = f.suppressed
        local parent = Menu:new()
        Menus.containerMenu(0, parent, f.crate)
        Menus.inventoryMenu(0, parent, { f.apple })
        Menus.worldMenu(0, parent, {}, false)
        assert(#parent.options == 0)
        f[key] = false
        ISInventoryPaneContextMenu.dontCreateMenu = false
    end
end)

test("world fixtures offer separate exact contents contexts for every compartment", function(f)
    local first, second = container("crate", false), container("crate", false)
    local object = { getSquare = function() return f.square end, getContainerCount = function() return 2 end,
        getContainerByIndex = function(_, index) return index == 0 and first or second end,
        getContainerIndex = function(_, selected) return selected == first and 0 or 1 end }
    first.parent, second.parent = object, object
    local _, menu = worldMenu(f, { object })
    for index, source in ipairs({ first, second }) do
        local contents = needed(menu, "Contents of Crate [compartment " .. tostring(index) .. "]").child
        click(contents, "Sort contents...")
        assert(f.quick.request.sourceContainer == source and f.quick.request.destination.kind == "labels")
        click(contents, "Clean contents (delete)")
        assert(f.quick.request.sourceContainer == source and f.quick.request.destination.kind == "trash")
        click(contents, "Put carried items in Crate [compartment " .. tostring(index) .. "]...")
        assert(f.quick.request.destination.ref == source)
    end
end)

test("separate same-name world sources identify their sidebar icon and preserve the exact source", function(f)
    local first, second = container("crate", false), container("crate", false)
    sidebar(f, f.lootPage, f.floor)
    sidebar(f, f.lootPage, first)
    sidebar(f, f.lootPage, second)
    local _, menu = worldMenu(f, {fixtureObject(f, first), fixtureObject(f, second)})
    for index, source in ipairs({first, second}) do
        local contents = needed(menu, "Contents of Crate (Loot icon " .. tostring(index + 1) .. ")").child
        click(contents, "Loot contents (Smart Load)")
        assert(f.quick.request.sourceContainer == source)
    end
    local point = {getX = function() return 100 end, getY = function() return 200 end, getZ = function() return 1 end}
    for index, source in ipairs({first, second}) do
        local slot = index
        source.parent = {getSquare = function() return point end, getObjectIndex = function() return slot end}
    end
    f.lootPage.backpacks = {}
    _, menu = worldMenu(f, {fixtureObject(f, first), fixtureObject(f, second)})
    for index, source in ipairs({first, second}) do
        local contents = needed(menu, "Contents of Crate (100, 200, floor 1; object " .. tostring(index + 1) .. ")").child
        click(contents, "Clean contents (delete)")
        assert(f.quick.request.sourceContainer == source and f.quick.request.destination.kind == "trash")
    end
end)

test("container help provides a complete workflow with explicit nondeletion and cleanup guidance", function()
    local guide
    for _, candidate in ipairs(Guides.list) do if candidate.id == "container-contents" then guide = candidate end end
    assert(guide and guide.prerequisites and #guide.steps >= 6 and guide.expected and #guide.troubleshooting > 0)
    local text = table.concat(guide.steps, " ")
    assert(text:find("never deletes", 1, true) and text:find("directly", 1, true) and text:find("separately optional", 1, true))
    assert(text:find("Sort contents", 1, true) and text:find("Choose items and categories", 1, true))
end)

test("item menus include distinct action icons and icons on every generated choice", function(f)
    for index = 1, 8 do
        local id = "custom:" .. tostring(index)
        f.definitions[index] = { id = id, name = "Supplies " .. tostring(index) }
        f.matches[id] = true
    end
    f.presets = {
        { id = "setup:1", name = "Sorting", setup = {scope = "inventory", destination = {kind = "labels"}, filter = {all = true}} },
        { id = "setup:2", name = "Dropping", setup = {scope = "inventory", destination = {kind = "floor"}, filter = {all = true}} },
    }
    local selected, source = bag(f, true)
    local locker = container("locker", false)
    sidebar(f, f.inventoryPage, f.inventory)
    sidebar(f, f.inventoryPage, source)
    sidebar(f, f.lootPage, f.crate)
    sidebar(f, f.lootPage, locker)
    local parent, menu = inventoryMenu(f, {selected})
    distinctIcons(menu)
    distinctIcons(needed(menu, "Category: Food").child)
    local contentsHeader = needed(menu, "Contents of School Bag")
    assert(contentsHeader.itemForTexture == selected and contentsHeader.iconTexture == nil)
    distinctIcons(contentsHeader.child)
    local moves = needed(contentsHeader.child, "Move contents to").child
    assert(icon(needed(moves, "Crate...")) == icon(needed(moves, "Locker...")))
    assert(icon(needed(moves, "Crate...")) ~= icon(needed(moves, "My remembered vehicle...")))
    local custom = needed(menu, "My matching categories").child
    local more = needed(custom, "More categories in Actions...")
    local storeIcon = icon(needed(menu, "Put all of this type in Crate"))
    for _, selectedCategory in ipairs(custom.options) do
        if selectedCategory ~= more then assert(icon(selectedCategory) == storeIcon) end
    end
    assert(icon(more) ~= storeIcon)
    local saved = needed(menu, "Saved setups").child
    assert(#saved.options == 2 and icon(saved.options[1]) == icon(saved.options[2]))
    assert(icon(needed(menu, "Saved setups")) ~= icon(saved.options[1]))
    assert(iconTree(needed(parent, "LootBox").child) > #menu.options)
end)

test("container floor and carried inventory operations use distinct action symbols", function(f)
    for _, source in ipairs({f.crate, f.floor, f.inventory}) do
        local _, menu = contentsMenu(f, source)
        distinctIcons(menu)
    end
    local selected = item(f.crate)
    local _, menu = inventoryMenu(f, {selected})
    distinctIcons(menu)
    distinctIcons(needed(menu, "Category: Food").child)
    assert(icon(needed(menu, "Take all of this type")) ~= icon(needed(menu, "Put all of this type in Crate")))
end)

test("vehicle and unavailable world actions retain distinct icons", function(f)
    f.pickedVehicle = vehicle(f)
    f.room, f.building = nil, nil
    local _, menu = worldMenu(f)
    distinctIcons(menu)
    assert(icon(needed(menu, "Label this container...")) ~= icon(needed(menu, "Label this vehicle's storage...")))
    assert(icon(needed(menu, "Remember this vehicle")) ~= icon(needed(menu, "Haul my checklist to this vehicle...")))
    local loot, clean = needed(menu, "Loot supplies").child, needed(menu, "Clean and delete").child
    distinctIcons(loot)
    distinctIcons(clean)
    for _, choice in ipairs({needed(loot, "Current room..."), needed(loot, "Current building..."),
        needed(clean, "Clean current room..."), (needed(clean, "Clean current building..."))}) do
        assert(choice.notAvailable and choice.toolTip and icon(choice))
    end
end)

test("contents groups use native container imagery and retain unknown-storage fallback", function(f)
    local nativeCrate, nativeTrunk = {}, {}
    ContainerButtonIcons = {crate = nativeCrate, TruckBed = nativeTrunk}
    f.pickedVehicle = vehicle(f)
    local unknown = container("moddedbox", false)
    local _, menu = worldMenu(f, {fixtureObject(f, f.crate), fixtureObject(f, unknown)})
    local crate = needed(menu, "Contents of Crate")
    local trunk = needed(menu, "Contents of TruckBed")
    local fallback = needed(menu, "Contents of Moddedbox")
    assert(crate.iconTexture == nativeCrate and crate.itemForTexture == nil)
    assert(trunk.iconTexture == nativeTrunk and trunk.itemForTexture == nil)
    assert(fallback.iconTexture ~= nil and fallback.itemForTexture == nil)
    assert(iconTree(crate.child) > 0 and iconTree(trunk.child) > 0 and iconTree(fallback.child) > 0)
end)

test("sidebar no-item and preference-only menus keep complete icon coverage", function(f)
    local button = sidebar(f, f.lootPage, f.crate)
    registrations.refresh[1](f.lootPage, "end")
    button.onRightMouseDown(button, 0, 0)
    ownedIcons(f.contextMenu)
    assert(option(f.contextMenu, "Native rename") and option(f.contextMenu, "Foreign action"))
    for _, isLoot in ipairs({false, true}) do
        local parent = Menu:new()
        registrations.background[1](0, parent, isLoot)
        ownedIcons(parent)
        distinctIcons(needed(parent, "LootBox").child)
    end
    f.preferences.inventoryShortcuts, f.preferences.worldShortcuts, f.preferences.vehicleShortcuts = false, false, false
    local parent, menu = inventoryMenu(f)
    distinctIcons(menu)
    assert(not option(menu, "Keep this copy") and option(menu, "Settings"))
    parent, menu = worldMenu(f, {fixtureObject(f, f.crate)})
    distinctIcons(menu)
    assert(not option(menu, "Loot contents (Smart Load)") and option(menu, "Workflow help"))
end)

test("pooled menu options switch between bag and native storage images without stale state", function(f)
    local selected = bag(f, true)
    local first, second = container("crate", false), container("locker", false)
    local nativeCrate, nativeLocker = {}, {}
    ContainerButtonIcons = {crate = nativeCrate, locker = nativeLocker}
    local parent = Menu:new()
    for _ = 1, 3 do
        parent:clear()
        Menus.inventoryMenu(0, parent, {selected})
        ownedIcons(parent)
        local header = needed(needed(parent, "LootBox").child, "Contents of School Bag")
        assert(header.itemForTexture == selected and header.iconTexture == nil)
        parent:clear()
        Menus.worldMenu(0, parent, {fixtureObject(f, first), fixtureObject(f, second)}, false)
        ownedIcons(parent)
        local menu = needed(parent, "LootBox").child
        for _, choice in ipairs({{ "Contents of Crate", nativeCrate }, { "Contents of Locker", nativeLocker }}) do
            local storage = needed(menu, choice[1])
            assert(storage.iconTexture == choice[2] and storage.itemForTexture == nil)
        end
    end
end)

test("an eligible amount action is top-level and opens the exact captured native stack", function(f)
    f.selectionTarget = {pane = f.inventoryPage.inventoryPane, marker = "exact clicked stack"}
    local items = {{items = {f.apple}}}
    local parent, menu = inventoryMenu(f, items)
    local amount = needed(parent, "Select amount...")
    assert(not option(menu, "Select amount..."))
    assert(amount.iconTexture and amount.iconTexture ~= needed(parent, "LootBox").iconTexture)
    assert(f.selectionCapture.playerIndex == 0 and f.selectionCapture.items == items)
    click(parent, "Select amount...")
    assert(f.selectionOpened == f.selectionTarget and f.quick == nil and f.opened == nil)
end)

test("amount actions stay hidden for unresolved stacks and disabled shortcut preferences", function(f)
    local parent = inventoryMenu(f)
    assert(not option(parent, "Select amount..."))
    f.selectionTarget = {pane = f.inventoryPage.inventoryPane}
    f.preferences.inventoryShortcuts = false
    parent = inventoryMenu(f)
    assert(not option(parent, "Select amount..."))
    f.preferences.inventoryShortcuts = true
    f.preferences.contextMenus = false
    parent = inventoryMenu(f)
    assert(not option(parent, "Select amount..."))
end)

test("selection adapter installation and pane attachment follow native menu lifecycle", function(f)
    Menus.install(interface)
    assert(selectionInstalls == 1)
    registrations.refresh[1](f.lootPage, "begin")
    assert(f.selectionAttached == nil)
    registrations.refresh[1](f.lootPage, "end")
    assert(f.selectionAttached == f.lootPage.inventoryPane)
    registrations.refresh[1](f.inventoryPage, "end")
    assert(f.selectionAttached == f.inventoryPage.inventoryPane)
end)

test("Current job appears for active paused and finished work and keeps a distinct icon", function(f)
    for _, state in ipairs({"running", "needs_review", "paused", "cancelled", "finished_with_skips", "finished"}) do
        f.jobStatus.state = state
        local _, menu = inventoryMenu(f)
        local currentJob = needed(menu, "Current job")
        distinctIcons(menu)
        assert(currentJob.toolTip.description:find("Key bindings", 1, true))
        click(menu, "Current job")
        assert(f.progressPlayer == 0 and not f.quick and not f.opened)
    end
    f.jobStatus.state = "idle"
    local _, menu = inventoryMenu(f)
    assert(not option(menu, "Current job"))
end)

test("pending personal gear is accessible from idle inventory world and empty-pane menus", function(f)
    f.recovery = {pending = true, count = 2}
    local _, inventory = inventoryMenu(f)
    needed(inventory, "Current job")
    local _, world = worldMenu(f, {fixtureObject(f, f.crate)})
    needed(world, "Current job")
    for _, isLoot in ipairs({false, true}) do
        local parent = Menu:new()
        registrations.background[1](0, parent, isLoot)
        local menu = needed(parent, "LootBox").child
        needed(menu, "Current job")
        distinctIcons(menu)
        click(menu, "Current job")
        assert(f.progressPlayer == 0)
    end
    assert(f.recoveries == nil and f.quick == nil)
end)

test("Current job follows context preferences without re-enabling hidden shortcut actions", function(f)
    f.jobStatus.state = "paused"
    f.preferences.inventoryShortcuts = false
    f.preferences.worldShortcuts = false
    local _, menu = inventoryMenu(f)
    needed(menu, "Current job")
    assert(not option(menu, "Keep this copy"))
    f.preferences.contextMenus = false
    local parent = inventoryMenu(f)
    assert(not option(parent, "LootBox"))
end)

test("Smart Load contents and an individual main-inventory target stay distinct", function(f)
    local clicked = container("crate", false)
    sidebar(f, f.inventoryPage, f.inventory)
    sidebar(f, f.lootPage, clicked)
    local _, menu = contentsMenu(f, clicked)
    local smart = needed(menu, "Loot contents (Smart Load)")
    assert(smart.toolTip.description:find("bags first", 1, true))
    click(menu, smart.name)
    assert(f.quick.request.scope == "container" and f.quick.request.sourceContainer == clicked)
    assert(f.quick.request.destination.kind == "inventory" and f.quick.request.destination.ref == nil)
    local moves = needed(menu, "Move contents to").child
    click(moves, "Main inventory only...")
    assert(f.quick.request.destination.kind == "container" and f.quick.request.destination.ref == f.inventory)
    assert(count(menu, "Loot contents (Smart Load)") == 1)
end)

test("workflow help explains optional reviews and the paired all-source transfer buttons", function()
    local settings, matching
    for _, guide in ipairs(Guides.list) do
        if guide.id == "settings" then settings = guide end
        if guide.id == "matching-transfers" then matching = guide end
    end
    assert(settings and matching and #matching.steps >= 5 and #matching.troubleshooting > 0)
    local choices = table.concat(settings.steps, " ")
    assert(choices:find("separate optional settings", 1, true) and choices:find("existing saved preferences", 1, true))
    local steps = table.concat(matching.steps, " ")
    assert(steps:find("Match Displayed", 1, true) and steps:find("Match Nearby", 1, true))
    assert(steps:find("every carried", 1, true) and steps:find("optional", 1, true))
end)

test("Til Full extends native callback submenus without changing native options", function(f)
    local oldPane = ISInventoryPane
    f.bandage = item(f.inventory)
    ISInventoryPane = {getActualItems = function(items) return {f.apple, f.apple, f.bandage} end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    ISInventoryPaneContextMenu.onDrinkFluid = function() end
    f.preferences.tillFullEnabled = true
    f.app.tillFull = function(_, items, kind) f.consumed, f.consumeKind = items, kind; return true end
    for _, kind in ipairs({"food", "fluid"}) do
        local parent, child = Menu:new(), Menu:new()
        local root = parent:addOption("Localized native label", nil, nil)
        root.subOption = 37
        if kind == "fluid" then root.itemForTexture = f.bandage end
        parent.getSubMenu = function(_, id) assert(id == 37); return child end
        local callback = kind == "food" and ISInventoryPaneContextMenu.onEatItems or ISInventoryPaneContextMenu.onDrinkFluid
        local original = child:addOption("Localized fraction", {}, callback)
        Menus.inventoryMenu(0, parent, {f.apple})
        assert(#child.options == 2 and child.options[1] == original and original.onSelect == callback)
        local added = child.options[2]
        assert(added.name == "Til Full")
        assert(added.itemForTexture == (kind == "fluid" and f.bandage or f.apple))
        assert(added.iconTexture == nil and original.itemForTexture == nil)
        assert(root.itemForTexture == (kind == "fluid" and f.bandage or nil))
        assert(added.child == nil and added.subOption == nil)
        added.onSelect(added.target)
        assert(f.progressPlayer == nil, "Til Full must start directly without opening Current job")
        assert(f.consumeKind == kind and #f.consumed == 2 and f.consumed[1] == f.apple and f.consumed[2] == f.bandage)
        Menus.inventoryMenu(0, parent, {f.apple})
        assert(#child.options == 2)
    end
    ISInventoryPane = oldPane
end)

test("Til Full refusal uses compact native feedback without another window", function(f)
    local oldPane, oldHalo = ISInventoryPane, HaloTextHelper
    ISInventoryPane = {getActualItems = function() return {f.apple} end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    f.preferences.tillFullEnabled = true
    f.app.tillFull = function() return nil, "Keep" end
    local message, recipient
    HaloTextHelper = {addBadText = function(player, text) recipient, message = player, text end}
    local parent, child = Menu:new(), Menu:new()
    local root = parent:addOption("Eat", nil, nil); root.subOption = 1
    parent.getSubMenu = function() return child end
    child:addOption("All", {}, ISInventoryPaneContextMenu.onEatItems)
    Menus.inventoryMenu(0, parent, {f.apple})
    local added = child.options[2]
    local ok, err = added.onSelect(added.target)
    assert(not ok and err == "Keep" and message == "Til Full: Keep" and recipient == getSpecificPlayer(0))
    assert(f.progressPlayer == nil and f.opened == nil and added.child == nil)
    HaloTextHelper = nil
    assert(not added.onSelect(added.target))
    assert(f.progressPlayer == nil and f.opened == nil)
    ISInventoryPane, HaloTextHelper = oldPane, oldHalo
end)

test("Til Full respects disabled, unavailable and opening-recipe native actions", function(f)
    local oldPane = ISInventoryPane
    ISInventoryPane = {getActualItems = function() return {f.apple} end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    for _, mode in ipairs({"disabled", "parent", "child", "recipe", "foreign"}) do
        local parent, child = Menu:new(), Menu:new()
        local root = parent:addOption("Eat", nil, nil)
        root.subOption = 1
        parent.getSubMenu = function() return child end
        local original = child:addOption("All", {}, mode == "foreign" and function() end or ISInventoryPaneContextMenu.onEatItems)
        f.preferences.tillFullEnabled = mode ~= "disabled"
        root.notAvailable = mode == "parent"
        original.notAvailable = mode == "child"
        original.param3 = mode == "recipe" and {} or nil
        Menus.inventoryMenu(0, parent, {f.apple})
        assert(#child.options == 1, mode)
    end
    ISInventoryPane = oldPane
end)

assert(#failures == 0, table.concat(failures, "\n"))
print(passed .. " menu and guide integration cases passed (native rendering and App boundaries are doubles)")
