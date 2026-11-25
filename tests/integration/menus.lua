package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

-- Contextual rows: what is offered must follow from the facts of the moment.
-- Native menus and the job engine are doubles; Menus, Describe and Log are real.
local passed = 0
function getTimestampMs() return 1 end
Events = {}
for _, name in ipairs({"OnFillInventoryObjectContextMenu", "OnFillInventoryContextMenuNoItems", "OnRefreshInventoryWindowContainers", "OnFillWorldObjectContextMenu"}) do
    Events[name] = {Add = function(fn) Events[name].fn = fn end}
end
LuaEventManager = {AddEvent = function() end}
local classes = setmetatable({}, {__mode = "k"})
function instanceof(object, class) return type(object) == "table" and classes[object] == class end
function getText(key) return key end
function getTextOrNull() return nil end
function getTexture(path) return {path = path} end
function getItemNameFromFullType(value) return (value:gsub("^Base%.", "")) end
function getCore() return {isTutorial = function() return false end} end
function isGamePaused() return false end
function triggerEvent() end
for _, name in ipairs({"ISUI/ISContextMenu", "ISUI/ISToolTip"}) do package.loaded[name] = true end
ISToolTip = {new = function() return {initialise = function() end, setVisible = function() end, setName = function() end} end}
local Menu = {}
Menu.__index = Menu
local function newMenu() return setmetatable({options = {}}, Menu) end
function Menu:addOption(name, target, onSelect) local o = {name = name, target = target, onSelect = onSelect}; self.options[#self.options + 1] = o; return o end
function Menu:addSubMenu(option, child) option.child = child end
function Menu:setOptionChecked(option, on) option.checked = on end
ISContextMenu = {getNew = function() return newMenu() end}
ISInventoryPane = {getActualItems = function(rows)
    local result = {}
    for _, row in ipairs(rows) do if row.items then for index = 2, #row.items do result[#result + 1] = row.items[index] end else result[#result + 1] = row end end
    return result
end}

local f
local categories = {}
package.loaded["LootBox/App"] = {
    get = function() return f.app end, getPreferences = function() return f.preferences end, customCategories = function() return categories end,
    category = function(id) for _, c in ipairs(categories) do if c.id == id then return c end end end,
    categoryName = function(id) for _, c in ipairs(categories) do if c.id == id then return c.name end end return (id:gsub("^native:", "")) end,
    saveCategory = function(definition) f.saved = definition; return definition.id end,
}
package.loaded["LootBox/Catalog"] = {categoryId = function(item) return "native:" .. item.category end}
package.loaded["LootBox/Selection"] = {install = function() end, attach = function() end, capture = function() return f.amount end, open = function() end}
package.loaded["LootBox/ObjectMenu"] = {building = function() return f.building end, append = function(_, menu, container) f.objectFor = container; menu:addOption("Disassemble", nil, function() end); return 1 end}
package.loaded["LootBox/ContainerFocus"] = {select = function() return false end, button = function() end}
package.loaded["LootBox/PaneClicks"] = {attach = function() end}
package.loaded["LootBox/ConsumeMenu"] = {add = function() end}
package.loaded["LootBox/PourMenu"] = {add = function() end}
package.loaded["LootBox/MountedDispenserMenu"] = {add = function() end}
local Menus = require "LootBox/Menus"
Menus.install({act = function(_, request, options) f.acted, f.options = request, options end, say = function(_, text) f.said = text end,
    open = function(_, page, context) f.opened, f.openContext = page, context end, showJob = function() f.shown = true end})

local function container(kind, fields)
    local c = {kind = kind, facts = {kind = kind, items = 0, takeable = 0, explored = true, locked = false, owned = false, capacity = 50, types = {}, categories = {}}}
    for key, value in pairs(fields or {}) do c.facts[key] = value end
    function c:getType() return kind == "floor" and "floor" or kind end
    function c:getContainingItem() return self.item end
    function c:getVehiclePart() end
    function c:getParent() return nil end
    function c:getItems() return {size = function() return 1 end, get = function() return {} end} end
    function c:isItemAllowed() return not self.refuses end
    function c:isInside() return false end
    function c:isLockedToCharacter() return false end
    return c
end
local function item(name, where, category)
    local i = {category = category or "Material", where = where, name = name}
    classes[i] = "InventoryItem"
    function i:getFullType() return "Base." .. name end
    function i:getName() return name end
    function i:getContainer() return self.where end
    return i
end
local function setup()
    local main = container("main", {owned = true})
    local square = {getRoom = function() return f.room end, getBuilding = function() return f.room end, getX = function() return 1 end, getY = function() return 2 end, getZ = function() return 0 end}
    local player = {getInventory = function() return main end, getCurrentSquare = function() return square end, isDead = function() return false end, getVehicle = function() end}
    f = {main = main, square = square, player = player, carried = {}, carriedCategory = {}, matching = 0, jobs = {state = "idle"}, presets = {},
        checklist = {ids = {}, types = {}}, labels = {}, preferences = {contextMenus = true, inventoryShortcuts = true, worldShortcuts = true, vehicleShortcuts = true, categoryShortcuts = true, savedShortcuts = true, tillFullEnabled = true}}
    local world = {graph = {list = function() return {} end, matches = function() return false end}}
    function world:owns(c) return c.facts.owned end
    function world:containerFacts(c) return c.facts end
    function world:hasKnownBins() return f.bins == true end
    function world:hasStorageLabels() return f.storage == true end
    function world:storageAccepts() return f.storage == true end
    function world:rememberedVehicleLoaded() return f.car == true end
    function world:isRememberedVehicle() return f.car == true end
    function world:countCarried(fullType) if fullType then return f.carried[fullType] or 0 end local n = 0; for _, v in pairs(f.carried) do n = n + v end return n end
    function world:countCarriedCategory(id) return f.carriedCategory[id] or 0 end
    function world:countCarriedFilter() return f.matching end
    function world:countMatching() return f.matching end
    function world:roomFacts() return f.roomFacts end
    function world:key(c) return c.kind ~= "corpse" and c or nil end
    function world:describe() return {} end
    f.app = {world = world, state = {}}
    function f.app:status() return f.jobs end
    function f.app:getChecklist() return f.checklist end
    function f.app:getSetups() return {presets = f.presets} end
    function f.app:labels(c) return f.labels[c] or {} end
    function f.app:setLabels(c, ids) f.labels[c] = ids; return true end
    function f.app:onChecklist() return f.listed == true end
    function f.app:toggleChecklist() f.toggled = true; return true end
    function f.app:isKept() return false end
    function f.app:protect(i) f.kept = (f.kept or 0) + 1; return true end
    function f.app:itemLabels() return {} end
    function f.app:currentContainer() return f.open end
    function f.app:rememberVehicle() f.remembered = true; return true end
    categories = {}
    getSpecificPlayer = function() return player end
    local pages = {inventory = {backpacks = {{inventory = main}}}, loot = {backpacks = {}}}
    f.pages = pages
    getPlayerInventory = function() return pages.inventory end
    getPlayerLoot = function() return pages.loot end
end
local function open(...)
    for _, c in ipairs({...}) do table.insert(f.pages.loot.backpacks, {inventory = c}) end
    f.open = (...)
end
local function tree(menu, into, prefix)
    into, prefix = into or {}, prefix or ""
    for _, option in ipairs(menu.options) do
        into[#into + 1] = prefix .. option.name
        into[prefix .. option.name] = option
        if option.child then tree(option.child, into, prefix .. option.name .. " > ") end
    end
    return into
end
local function has(t, text) for _, name in ipairs(t) do if name:find(text, 1, true) then return t[name] end end end
local function test(name, run) setup(); run(); passed = passed + 1; print("PASS " .. name) end
local function every(menu, check)
    for _, option in ipairs(menu.options) do
        check(option)
        if option.child then every(option.child, check) end
    end
end

test("an ordinary item with nothing to do beyond itself gets no bulk rows", function()
    f.carried["Base.Hammer"] = 1
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Hammer", f.main, "Tool")})
    local t = tree(menu)
    assert(not has(t, "All Hammer") and not has(t, "Drop") and not has(t, "Sort") and not has(t, "Settings") and not has(t, "help"))
    assert(has(t, "LootBox > On my loot list") and has(t, "LootBox > Keep this one"))
end)

test("more of the same elsewhere offers them as one submenu named for the item", function()
    local crate = container("crate", {takeable = 3})
    open(crate)
    f.carried["Base.Nails"] = 40
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)})
    local t = tree(menu)
    assert(has(t, "All Nails (40) > Put in Crate") and has(t, "All Nails (40) > Drop"))
    assert(not has(t, "Put away") and not has(t, "Throw away") and not has(t, "vehicle"), "No labels, bins or car are known")
    has(t, "All Nails (40) > Put in Crate").onSelect()
    assert(f.acted.scope == "inventory" and f.acted.destination.ref == crate and f.acted.filter.types[1] == "Base.Nails" and type(f.options.interaction) == "number")
end)

test("rows follow what is known: labels, bins and the car", function()
    f.carried["Base.Nails"] = 40
    f.storage, f.bins, f.car = true, true, true
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)})
    local t = tree(menu)
    assert(has(t, "All Nails (40) > Put away") and has(t, "All Nails (40) > Throw away") and has(t, "All Nails (40) > To my vehicle"))
    has(t, "All Nails (40) > Throw away").onSelect()
    assert(f.acted.destination.kind == "trash" and f.acted.scope == "inventory")
end)

test("a single choice is one row, not a submenu", function()
    f.carried["Base.Nails"] = 1
    f.storage = true
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)})
    local t = tree(menu)
    assert(has(t, "LootBox > Put away all Nails (1)") and not has(t, "All Nails (1) >"))
end)

test("loot items offer taking only when there is more than what was clicked", function()
    local crate, shelf = container("crate", {takeable = 5, types = {["Base.Nails"] = 5}}), container("shelves", {takeable = 2, types = {["Base.Nails"] = 2}})
    open(crate, shelf)
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", crate)})
    local t = tree(menu)
    assert(has(t, "All Nails (5) > Take") and has(t, "All Nails (5) > Take from all open containers (7)"))
    crate.facts.types["Base.Nails"], shelf.facts.types["Base.Nails"] = 1, nil
    menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", crate)})
    assert(not has(tree(menu), "Take"))
end)

test("several selected types act as one selection", function()
    f.carried["Base.Nails"], f.carried["Base.Screws"] = 30, 12
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main), item("Screws", f.main)})
    local row = has(tree(menu), "LootBox > Drop all 2 selected types (42)")
    row.onSelect()
    assert(#f.acted.filter.types == 2)
end)

test("a container offers only what its contents allow", function()
    local crate = container("crate")
    open(crate)
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    local t = tree(menu)
    assert(not has(t, "Take") and not has(t, "Move contents") and not has(t, "Throw"), "Empty")
    crate.facts.takeable, crate.facts.types = 4, {["Base.Nails"] = 4}
    f.bins = true
    menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    t = tree(menu)
    assert(has(t, "Take everything (4)") and has(t, "Throw away contents (4)") and has(t, "Move contents > The floor"))
    has(t, "Take everything (4)").onSelect()
    assert(f.acted.scope == "container" and f.acted.sourceContainer == crate and f.acted.destination.kind == "inventory")
    assert(f.acted.includeBags == false, "A filled bag is taken as it is, like any other item")
    f.checklist = {ids = {}, types = {"Base.Nails"}}; f.matching = 2
    menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    has(tree(menu), "Take my loot list (2)").onSelect()
    assert(f.acted.includeBags == true, "Only a search looks inside bags")
end)

test("contents are dropped where the player can stand, not inside the fixture", function()
    local crate = container("crate", {takeable = 4, types = {["Base.Nails"] = 4}})
    open(crate)
    local solid, free = {isFree = function() return false end}, {isFree = function() return true end}
    for tile, expected in pairs({[solid] = f.square, [free] = free}) do
        local menu = newMenu()
        Menus.containerMenu(0, menu, crate, tile)
        local row = has(tree(menu), "Move contents > The floor") or has(tree(menu), "Drop contents here")
        row.onSelect()
        assert(f.acted.destination.kind == "floor" and f.acted.destination.ref == expected)
    end
end)

test("a locked container, and the player's own inventory, get no destructive or useless rows", function()
    local crate = container("crate", {takeable = 4, locked = true})
    open(crate)
    local menu = newMenu()
    assert(Menus.containerMenu(0, menu, crate) == false and #menu.options == 0)
    f.main.facts.takeable, f.bins = 9, true
    menu = newMenu()
    Menus.containerMenu(0, menu, f.main)
    local t = tree(menu)
    assert(not has(t, "Throw") and not has(t, "Take everything") and not has(t, "Belongs here"))
end)

test("unopened containers can be taken from before their contents are known", function()
    local crate = container("crate", {explored = false})
    open(crate)
    f.checklist = {ids = {"native:Food"}, types = {}}
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    local t = tree(menu)
    assert(t["LootBox > Take everything"] and t["LootBox > Take my loot list"])
end)

test("a key ring is not offered for planks", function()
    local crate, ring = container("crate", {takeable = 1}), container("KeyRing", {owned = true})
    ring.refuses = true
    open(crate)
    table.insert(f.pages.inventory.backpacks, {inventory = ring})
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    assert(not has(tree(menu), "KeyRing"))
end)

test("labels are ticked in place, starting with what is already inside", function()
    local crate = container("crate", {takeable = 5, categories = {["native:Food"] = 4, ["native:Tool"] = 1}})
    open(crate)
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    local t = tree(menu)
    assert(has(t, "Belongs here > Food") and has(t, "Belongs here > Tool") and has(t, "Belongs here > More..."))
    has(t, "Belongs here > Food").onSelect()
    assert(f.labels[crate][1] == "native:Food" and not f.acted, "Labelling starts no job")
    menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    t = tree(menu)
    local row = has(t, "Belongs here: Food > Food")
    assert(row.checked)
    row.onSelect()
    assert(#f.labels[crate] == 0)
end)

test("what is carried that fits a container is offered by count", function()
    local crate = container("crate", {takeable = 5, types = {["Base.Nails"] = 5}})
    open(crate)
    f.carried["Base.Nails"], f.labels[crate], f.carriedCategory["native:Food"] = 7, {"native:Food"}, 3
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    local t = tree(menu)
    assert(has(t, "Put in > More of what is inside (7)") and has(t, "Put in > What belongs here (3)"))
end)

test("the ground outdoors with nothing in reach adds no LootBox entry at all", function()
    local menu = newMenu()
    Menus.worldMenu(0, menu, {})
    assert(#menu.options == 0)
end)

test("indoors, place actions live under one row and only for places with something in them", function()
    f.room, f.roomFacts = {}, {containers = 0, groundItems = 0}
    local menu = newMenu()
    Menus.worldMenu(0, menu, {})
    local t = tree(menu)
    assert(not has(t, "This room"), "An empty room")
    f.roomFacts, f.checklist = {containers = 2, groundItems = 0}, {ids = {"native:Food"}, types = {}}
    menu = newMenu()
    Menus.worldMenu(0, menu, {})
    t = tree(menu)
    assert(#menu.options == 1 and #menu.options[1].child.options == 1 and menu.options[1].child.options[1].name == "Around here")
    assert(has(t, "This room > Take my loot list") and has(t, "This building > Take everything") and has(t, "Mark an area"))
    assert(not has(t, "Throw"), "No trash can is known")
    has(t, "This room > Take my loot list").onSelect()
    assert(f.acted.scope == "room" and f.acted.filter.ids[1] == "native:Food")
end)

test("a clicked vehicle replaces place actions with its own", function()
    local trunk = container("trunk", {takeable = 2, kind = "vehicle"})
    local car = {getPartCount = function() return 1 end, getPartByIndex = function() return {getItemContainer = function() return trunk end} end,
        canAccessContainer = function() return true end}
    IsoObjectPicker = {Instance = {PickVehicle = function() return car end}}
    getMouseXScaled, getMouseYScaled = function() return 0 end, function() return 0 end
    f.room, f.roomFacts = {}, {containers = 2, groundItems = 0}
    f.carried["Base.Nails"] = 2
    local menu = newMenu()
    Menus.worldMenu(0, menu, {})
    local t = tree(menu)
    assert(has(t, "Load everything I carry") and has(t, "My vehicle") and has(t, "Trunk > Take everything (2)") and not has(t, "Around here"))
    IsoObjectPicker = nil
end)

test("a job in progress is one row in the world menu and never on containers or items", function()
    local crate = container("crate", {takeable = 1})
    open(crate)
    f.jobs = {state = "running", hasJob = true, canPause = true, label = "Clean kitchen"}
    function f.app:pause() f.paused = true; return true end
    function f.app:cancel() f.cancelled = true; return true end
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    assert(not has(tree(menu), "Job:"))
    menu = newMenu()
    Menus.worldMenu(0, menu, {})
    local t = tree(menu)
    assert(menu.options[1].child.options[1].name == "Job: Clean kitchen")
    has(t, "Job: Clean kitchen > Pause").onSelect()
    assert(f.paused and not has(t, "Resume"))
end)

test("presets appear where they can run", function()
    f.presets = {{id = "setup:1", name = "Crate to car", setup = {scope = "container", destination = {kind = "vehicle"}}},
        {id = "setup:2", name = "Room food", setup = {scope = "room", destination = {kind = "inventory"}}}}
    local crate = container("crate", {takeable = 1})
    open(crate)
    f.room, f.roomFacts = {}, {containers = 2, groundItems = 0}
    local menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    local t = tree(menu)
    assert(has(t, "Presets > Crate to car") and not has(t, "Room food"))
    menu = newMenu()
    Menus.worldMenu(0, menu, {})
    t = tree(menu)
    assert(has(t, "Presets > Room food") and not has(t, "Crate to car"))
end)

test("a refused action is told to the player", function()
    local menu = newMenu()
    function f.app:toggleChecklist() return nil, "The disk is full" end
    f.carried["Base.Nails"] = 1
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)})
    has(tree(menu), "On my loot list").onSelect()
    assert(f.said == "The disk is full")
end)

test("no row is disabled, every row has an icon, and submenus are never empty", function()
    local crate = container("crate", {takeable = 5, types = {["Base.Nails"] = 5}, categories = {["native:Material"] = 5}})
    open(crate, container("shelves", {takeable = 1}))
    categories = {{id = "custom:1", name = "Workshop", types = {"Base.Nails"}, includes = {}}}
    f.storage, f.bins, f.car, f.carried["Base.Nails"], f.room, f.roomFacts = true, true, true, 30, {}, {containers = 3, groundItems = 2}
    f.checklist = {ids = {"native:Food"}, types = {}}
    for _, build in ipairs({function(m) Menus.containerMenu(0, m, crate) end, function(m) Menus.inventoryMenu(0, m, {item("Nails", f.main)}) end,
        function(m) Menus.worldMenu(0, m, {}) end}) do
        local menu = newMenu()
        build(menu)
        every(menu, function(option)
            assert(not option.notAvailable, option.name)
            assert(option.iconTexture or option.itemForTexture, "No icon: " .. option.name)
            assert(option.onSelect or (option.child and #option.child.options > 0), "Dead row: " .. option.name)
        end)
    end
end)

test("an icon shows the object's options, then mods' container options, then LootBox once", function()
    local crate = container("crate", {takeable = 2})
    local page = {player = 0, onCharacter = false}
    local button = {inventory = crate, parent = {parent = page}}
    page.backpacks = {button}
    local menu = newMenu()
    function menu:setVisible() end
    function menu:bringToTop() end
    getPlayerContextMenu = function() return menu end
    button.onRightMouseDown = function() menu:addOption("Rename", nil, function() end) end
    triggerEvent = function(_, _, m) m:addOption("Mod: sort", nil, function() end); Menus.paneMenu(0, m, true) end
    f.pages.loot = {backpacks = {button}, inventoryPane = {inventory = crate}}
    Menus.refreshContainers(page, "end")
    button:onRightMouseDown(1, 1)
    local names = {}
    for _, option in ipairs(menu.options) do names[#names + 1] = option.name end
    assert(table.concat(names, "|") == "Rename|Disassemble|Mod: sort|LootBox", table.concat(names, "|"))
    triggerEvent = function() end
end)

test("the empty space of a container gives the same options as its icon", function()
    local crate = container("crate", {takeable = 2})
    f.pages.loot = {backpacks = {{inventory = crate}}, inventoryPane = {inventory = crate}}
    local menu = newMenu()
    Menus.paneMenu(0, menu, true)
    assert(menu.options[1].name == "Disassemble" and menu.options[2].name == "LootBox" and f.objectFor == crate)
end)

test("category rows and presets can be switched off on their own", function()
    f.carried["Base.Nails"], f.carriedCategory["native:Material"] = 30, 50
    f.presets = {{id = "setup:1", name = "Crate to car", setup = {scope = "container", destination = {kind = "vehicle"}}}}
    local crate = container("crate", {takeable = 1})
    open(crate)
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)})
    assert(has(tree(menu), "All Material (50)"))
    f.preferences.categoryShortcuts, f.preferences.savedShortcuts = false, false
    menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)})
    assert(not has(tree(menu), "All Material") and has(tree(menu), "All Nails"))
    menu = newMenu()
    Menus.containerMenu(0, menu, crate)
    assert(not has(tree(menu), "Presets"))
end)

test("switching menus off removes every entry", function()
    local crate = container("crate", {takeable = 2})
    open(crate)
    f.preferences.contextMenus = false
    local menu = newMenu()
    Menus.inventoryMenu(0, menu, {item("Nails", f.main)}); Menus.containerMenu(0, menu, crate); Menus.worldMenu(0, menu, {})
    assert(#menu.options == 0)
end)

print(passed .. " contextual menu cases passed (native menu and engine doubles)")
