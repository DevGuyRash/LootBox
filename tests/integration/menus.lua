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
function Menu:new() return setmetatable({ options = {} }, self) end
function Menu:addOption(name, target, action)
    local option = { name = name, target = target, onSelect = action }
    self.options[#self.options + 1] = option
    return option
end
function Menu:addSubMenu(option, child) option.child = child end
function Menu:setOptionChecked(option, checked) option.checkMark = checked end
ISContextMenu = { getNew = function() return Menu:new() end }
ISToolTip = { new = function()
    return { initialise = function() end, setVisible = function() end,
        setName = function(self, name) self.name = name end }
end }
package.loaded["ISUI/ISContextMenu"] = true
package.loaded["ISUI/ISToolTip"] = true

local registrations = { inventory = {}, world = {} }
Events = {
    OnFillInventoryObjectContextMenu = { Add = function(fn) registrations.inventory[#registrations.inventory + 1] = fn end },
    OnFillWorldObjectContextMenu = { Add = function(fn) registrations.world[#registrations.world + 1] = fn end },
}
function instanceof(object, class) return type(object) == "table" and object.classes and object.classes[class] == true end
function getSpecificPlayer() return current.player end
function getText(key) return key == "IGUI_ItemCat_Food" and "Food" or key end
function getTextOrNull() return nil end
function getTexture(path) return path end
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
local Menus = require "LootBox/Menus"
local Guides = require "LootBox/Guides"
local interface = {
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
        getContainingItem = function() return nil end,
        getVehiclePart = function(self) return self.part end }
end

local function item(source, kind)
    return { classes = { InventoryItem = true }, source = source,
        getContainer = function(self) return self.source end,
        getFullType = function() return kind or "Base.Apple" end,
        getDisplayCategory = function() return "Food" end }
end

local function fixture()
    local f = { preferences = copy(defaults), definitions = {}, matches = {}, presets = {}, kept = {}, tested = 0 }
    current = f
    f.inventory, f.crate, f.floor = container("inventory", true), container("crate", false), container("floor", false)
    f.square = { getRoom = function() return f.room end, getBuilding = function() return f.building end }
    f.room, f.building = {}, {}
    f.player = { getCurrentSquare = function() return f.square end, getSquare = function() return f.square end,
        getVehicle = function() return f.seatedVehicle end }
    f.viewed = f.crate
    f.checklist = { ids = { "native:Food" }, types = { "Base.Bandage" }, all = false }
    f.app = {
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
local function inventoryMenu(f, selected)
    local parent = Menu:new()
    parent:addOption("Foreign action", nil, function() f.foreignClicked = true end)
    Menus.inventoryMenu(0, parent, selected or { f.apple })
    return parent, option(parent, "LootBox") and option(parent, "LootBox").child
end
local function worldMenu(f, objects)
    local parent = Menu:new()
    parent:addOption("Foreign action", nil, function() f.foreignClicked = true end)
    Menus.worldMenu(0, parent, objects or {}, false)
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
    click(menu, "Keep this copy")
    assert(f.kept[f.apple] and not f.kept[other])
    local _, reopened = inventoryMenu(f)
    assert(needed(reopened, "Keep this copy").checkMark == true)
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
    assert(not option(menu, "Take all unprotected contents...") and not option(menu, "Label this storage..."))
    click(menu, "Open LootBox")
    assert(f.opened.context.container == nil and f.opened.context.targetContainer == nil)
    assert(#f.opened.context.containers == 0)
end)

test("a clicked fixture exposes its own take put and label actions", function(f)
    local locker = container("locker", false)
    local _, menu = worldMenu(f, { fixtureObject(f, locker) })
    click(menu, "Take all unprotected contents...")
    assert(f.quick.request.sourceContainer == locker and f.quick.request.filter.all)
    click(menu, "Put carried items in Locker...")
    assert(f.quick.request.destination.ref == locker and f.quick.request.scope == "inventory")
    click(menu, "Label this storage...")
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
    assert(room.notAvailable and room.toolTip.description:find("Stand inside", 1, true))
    assert(building.notAvailable and clean.notAvailable)
    assert(not needed(loot, "Select an area...").notAvailable)
end)

test("world shortcuts can be hidden without hiding the manager", function(f)
    f.preferences.worldShortcuts = false
    local _, menu = worldMenu(f, { fixtureObject(f, f.crate) })
    assert(not option(menu, "Loot supplies") and not option(menu, "Clean and delete"))
    assert(not option(menu, "Take all unprotected contents..."))
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

test("vehicle guide starter keeps remembered-car semantics and invalid tasks return errors", function(f)
    local haul = assert(Guides.prepare("haul-car", f.app, { vehicle = vehicle(f) }))
    assert(haul.scope == "inventory" and haul.destination.kind == "vehicle" and haul.destination.ref == nil)
    local missing, reason = Guides.prepare("not-a-task", f.app, {})
    assert(missing == nil and type(reason) == "string")
    missing, reason = Guides.prepare("loot-room", nil, {})
    assert(missing == nil and type(reason) == "string")
end)

assert(#failures == 0, table.concat(failures, "\n"))
print(passed .. " menu and guide integration cases passed (native rendering and App boundaries are doubles)")
