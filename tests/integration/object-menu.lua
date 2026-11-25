package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

-- The native menu tree and providers are doubles built from the observed 42.22
-- behaviour: Java builders require a ROOT menu (they read its instanceMap),
-- list every object on the tile under Disassemble, and add global rows.
local passed = 0
local function test(name, run) run(); passed = passed + 1; print("PASS " .. name) end

function getTimestampMs() return 1 end
Events = nil
local classes = {}
function instanceof(object, class) local c = classes[object]; return c ~= nil and (c == class or (type(c) == "table" and c[class] == true)) end
local function native(class, fields) local object = setmetatable({}, {__index = fields or {}}); classes[object] = class; return object end

local Menu = {}
Menu.__index = Menu
local function menuNew(root)
    local menu = setmetatable({options = {}, numOptions = 1, optionPool = {}, root = root}, Menu)
    if not root then menu.instanceMap, menu.x, menu.y = {}, 5, 6 else table.insert(root.instanceMap, menu) end
    return menu
end
function Menu:addOption(name, target, onSelect, p1, p2, p3)
    local option = {id = self.numOptions, name = name, target = target, onSelect = onSelect, param1 = p1, param2 = p2, param3 = p3}
    self.options[self.numOptions] = option
    self.numOptions = self.numOptions + 1
    return option
end
function Menu:addSubMenu(option, child) option.subOption = child end
function Menu:getSubMenu(child) return child end
function Menu:calcHeight() end
function Menu:calcWidth() return 10 end
function Menu:setWidth() end
function Menu:setX(x) self.x = x end
function Menu:setY(y) self.y = y end

local root, square, floor, crate, radio, container, player, providers, fetched
ISContextMenu = {get = function() root = menuNew(); return root end, getNew = function(_, parent) return menuNew(parent.root or parent) end}
SafeHouse = {getSafeHouse = function() end, isSafehouseAllowInteract = function() return true end, isSafehouseAllowLoot = function() return true end}
JoypadState = {players = {}}
ISWorldObjectContextMenu = {fetchSquares = {}}
ISDisassembleMenu = {disassemble = function() end}
local scrapFinds
ISWorldObjectContextMenuLogic = {
    fetch = function(fetch, object, _, scan) fetched[#fetched + 1] = {object = object, scan = scan} end,
    createMenuEntries = function() end,
}
local world = {getObjectsSquare = function(data, where) data.squares[1] = where end}
local manager = {getWorldMenu = function() return world end}
function manager.createWorldMenu(index, object, objects, x, y)
    local menu = ISContextMenu.get(index, x, y)
    assert(menu.instanceMap, "NullPointerException: ISContextMenuWrapper.getContextFromOption")
    ISWorldObjectContextMenuLogic.fetch({}, object, index, true)
    menu:addOption("Walk to", nil, function() end, object == crate and crate or floor)
    menu:addOption("Sit on ground", 0, function() end)
    local disassemble = menu:addOption("Disassemble", player)
    local list = menuNew(root)
    menu:addSubMenu(disassemble, list)
    for _, entry in ipairs({{"Crate", crate}, {"Radio", radio}}) do
        list:addOption(entry[1], player, ISDisassembleMenu.disassemble, {object = entry[2], square = square,
            moveProps = {spriteName = "s", findOnSquare = function() return scrapFinds or entry[2] end}})
    end
    for _, provider in ipairs(providers) do provider(menu, object, objects) end
    return menu
end
ISContextManager = {getInstance = function() return manager end}
function getSpecificPlayer() return player end

local ObjectMenu = require "LootBox/ObjectMenu"

local function setup()
    fetched, providers, scrapFinds = {}, {}, nil
    floor, radio = native("IsoObject", {}), native("IsoObject", {})
    player = native({IsoPlayer = true, IsoObject = true}, {isDead = function() return false end, isAsleep = function() return false end, getVehicle = function() end})
    local objects = {}
    square = {getObjects = function() return {size = function() return #objects end, get = function(_, i) return objects[i + 1] end} end,
        getFloor = function() return floor end, getBuilding = function() end}
    crate = native("IsoObject", {getSquare = function() return square end, getObjectIndex = function() return 1 end,
        getContainerIndex = function(_, c) return c == container and 0 or -1 end, getContainerByIndex = function() return container end})
    objects[1], objects[2], objects[3] = floor, crate, radio
    container = native("ItemContainer", {getContainingItem = function() end, getVehiclePart = function() end, getType = function() return "crate" end,
        getParent = function() return crate end})
    ISContextMenu.get(0)
    root:addOption("Rename", container, function() end)
    return root
end
local function names(menu, into, prefix)
    into, prefix = into or {}, prefix or ""
    for _, option in ipairs(menu.options) do
        into[#into + 1] = prefix .. option.name
        if option.subOption then names(option.subOption, into, prefix .. option.name .. " > ") end
    end
    return into
end
local function expect(menu, list)
    local actual = names(menu)
    assert(table.concat(actual, "|") == table.concat(list, "|"), table.concat(actual, "|"))
end

test("a container icon gets its own object's options and nothing global", function()
    local menu = setup()
    assert(ObjectMenu.append(0, menu, container) == 1)
    expect(menu, {"Rename", "Disassemble", "Disassemble > Crate"})
end)

test("the game's builder always receives a root menu", function()
    local menu, seen = setup(), {}
    providers[1] = function(m) seen[#seen + 1] = m end
    ObjectMenu.append(0, menu, container)
    for _, m in ipairs(seen) do assert(m == menu and m.instanceMap) end
end)

test("object actions that hide their target in a callback survive; other mods' global rows do not", function()
    local menu = setup()
    providers[1] = function(m, object)
        m:addOption("Mod: teleport home", nil, function() end)
        if object == crate then m:addOption("Turn on", nil, function() return crate end) end
    end
    ObjectMenu.append(0, menu, container)
    expect(menu, {"Rename", "Disassemble", "Disassemble > Crate", "Turn on"})
end)

test("rows that act on another object of the tile are dropped, wherever they are nested", function()
    local menu = setup()
    providers[1] = function(m, object)
        if object ~= crate then return end
        local option = m:addOption("Electronics")
        local child = menuNew(root)
        m:addSubMenu(option, child)
        child:addOption("Radio settings", nil, function() end, radio)
    end
    ObjectMenu.append(0, menu, container)
    expect(menu, {"Rename", "Disassemble", "Disassemble > Crate"})
end)

test("only the clicked object is inspected, never the whole tile", function()
    local menu = setup()
    ObjectMenu.append(0, menu, container)
    assert(#fetched == 2)
    for _, entry in ipairs(fetched) do assert(entry.scan == false and (entry.object == crate or entry.object == floor)) end
end)

test("dismantling is unavailable when the game would pick a lookalike", function()
    local menu = setup()
    scrapFinds = native("IsoObject", {})
    ObjectMenu.append(0, menu, container)
    assert(menu.options[2].subOption.options[1].notAvailable == true)
end)

test("a failing provider is reported and leaves the menu usable and hooks restored", function()
    local menu = setup()
    local get, fetch = ISContextMenu.get, ISWorldObjectContextMenuLogic
    providers[1] = function(_, object) if object == crate then error("provider bug") end end
    ObjectMenu.append(0, menu, container)
    assert(menu.options[1].name == "Rename" and not ObjectMenu.building())
    assert(ISContextMenu.get == get and ISWorldObjectContextMenuLogic == fetch)
end)

test("moved furniture, the ground and bags add nothing", function()
    local menu = setup()
    local before = #menu.options
    getmetatable(crate).__index.getObjectIndex = function() return 9 end
    assert(ObjectMenu.append(0, menu, container) == 0)
    getmetatable(container).__index.getType = function() return "floor" end
    assert(ObjectMenu.append(0, menu, container) == 0 and #menu.options == before)
end)

test("a vehicle part shows the vehicle's own menu, only from outside", function()
    local menu = setup()
    local car = native("BaseVehicle", {})
    getmetatable(container).__index.getVehiclePart = function() return {getVehicle = function() return car end} end
    ISVehicleMenu = {FillMenuOutsideVehicle = function(_, m, vehicle) assert(vehicle == car); m:addOption("Siphon gas", nil, function() end) end}
    assert(ObjectMenu.append(0, menu, container) == 1)
    getmetatable(player).__index.getVehicle = function() return car end
    assert(ObjectMenu.append(0, menu, container) == 0)
    ISVehicleMenu = nil
end)

print(passed .. " object menu cases passed (native menu and provider doubles)")
