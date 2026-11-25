-- Labels on container titles, icons and tooltips, the line under an item's tooltip, and the marker.
-- Windows, buttons, tooltips and the world's answers are doubles; Describe and Labels are real.
if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end
next = nil -- Kahlua has none

local f
function getTimestampMs() return f.now end
function instanceof(object, class) return type(object) == "table" and object.class == class end
function getTextOrNull() return nil end
function getItemNameFromFullType(value) return (value:gsub("^Base%.", "")) end
function getSpecificPlayer(index) return f.players[index] end
function getCore() return {getScreenWidth = function() return 1000 end, getScreenHeight = function() return 600 end} end
Events = {}
for _, name in ipairs({"OnRefreshInventoryWindowContainers", "OnGameStart"}) do Events[name] = {Add = function(fn) Events[name].fn = fn end} end
package.loaded["LootBox/Log"] = {guard = function(_, run, ...) return run(...) end}
package.loaded["LootBox/UIKit"] = {LINE = 10, FONT = "small", colors = setmetatable({}, {__index = function() return {r = 1, g = 1, b = 1, a = 1} end}),
    width = function(text) return #text * 10 end, fit = function(text, width) return text:sub(1, math.floor(width / 10)) end}
package.loaded["LootBox/App"] = {
    get = function(index) return f.apps[index] end, peek = function(index) return f.apps[index] end,
    category = function() end, preference = function(key) return f.preferences[key] ~= false end,
}
local function marker() return {
    addPlayerHomingPoint = function(_, player, x, y) f.marks[#f.marks + 1] = {player = player, x = x, y = y}; return f.marks[#f.marks] end,
    removePlayerHomingPoint = function(_, _, mark) mark.gone = true end} end
function getWorldMarkers() return f.markers end
ISToolTipInv = {render = function(tip) tip.rendered = (tip.rendered or 0) + 1 end}
local View = require "LootBox/StorageView"
View.install()
Events.OnGameStart.fn()

local function container(kind, fields)
    local c = {kind = kind}
    for key, value in pairs(fields or {}) do c[key] = value end
    function c:getType() return self.kind end
    function c:getContainingItem() return self.item end
    function c:getParent() return self.parent end
    function c:getVehiclePart() end
    return c
end
local function fixture()
    f = {now = 100000, marks = {}, preferences = {}, labels = {}, details = {}}
    f.markers = marker()
    f.main = container("main")
    local square = {getX = function() return f.x or 0 end, getY = function() return 0 end, getZ = function() return 0 end}
    local player = {getInventory = function() return f.main end, getCurrentSquare = function() return square end}
    f.players = {[0] = player}
    local world = {graph = {matchesFilter = function() return f.wanted == true end}}
    function world:pass(run) return run() end
    function world:givenName(c) return f.details[c] and f.details[c].name end
    function world:owns(c) return c == f.main end
    function world:home() return f.home, f.placed, f.full end
    function world:describe() return {} end
    f.app = {player = player, world = world}
    function f.app:labels(c) return f.labels[c] or {} end
    function f.app:storageDetails(c) return f.details[c] or {} end
    function f.app:isKept() return f.kept == true end
    function f.app:isTypeKept() return false end
    function f.app:getChecklist() return {ids = {}, types = {}} end
    f.apps = {[0] = f.app}
    f.page = {player = 0, width = 600, backpacks = {}}
end
local function icon(c, name)
    local button = {inventory = c, name = name, tooltip = name, height = 40, draws = 0}
    function button:render() self.draws = self.draws + 1 end
    function button:drawRect() self.marked = true end
    f.page.backpacks[#f.page.backpacks + 1] = button
    return button
end
local function refresh(phase) Events.OnRefreshInventoryWindowContainers.fn(f.page, phase or "buttonsAdded") end
local function item(where)
    return {class = "InventoryItem", getContainer = function() return where or f.main end, getFullType = function() return "Base.Nails" end}
end
local passed = 0
local function test(name, run) fixture(); run(); passed = passed + 1; print("PASS " .. name) end

test("a labelled container says what belongs in it, in its title, tooltip and icon", function()
    local crate, plain = container("crate"), container("crate")
    f.labels[crate], f.details[crate] = {"type:Base.Nails", "native:Tool", "rest:"}, {name = "Workshop", order = "last"}
    local a, b, main = icon(crate, "Crate"), icon(plain, "Crate"), icon(f.main, "Inventory")
    refresh("end")
    assert(a.name == "Crate", "Only once the icons are there and before the window reads their names")
    refresh()
    assert(a.name == "Workshop: Nails, Tool +1" and b.name == "Crate" and main.name == "Inventory")
    assert(a.tooltip == "Workshop\nBelongs here: Nails, Tool, Anything else\nFilled when others are full")
    a:render(); b:render()
    assert(a.marked and not b.marked and a.draws == 1)
end)

test("an icon used again for another container loses the mark, and is wrapped once", function()
    local crate, plain = container("crate"), container("crate")
    f.labels[crate] = {"native:Tool"}
    local button = icon(crate, "Crate")
    refresh(); refresh()
    button:render()
    assert(button.draws == 1)
    button.inventory, button.name, button.marked = plain, "Crate", nil
    refresh()
    button:render()
    assert(not button.marked and button.name == "Crate")
end)

test("the window that shows a labelled bag says what belongs in it", function()
    local bag = container("bag", {item = {}})
    f.labels[bag] = {"native:Food"}
    f.page.title, f.page.inventoryPane = "Duffel", {inventory = bag}
    refresh("end")
    assert(f.page.title == "Duffel: Food")
end)

test("a bag keeps its own name, which the game compares, and a long title is cut", function()
    local bag, crate = container("bag", {item = {}}), container("crate")
    f.labels[bag], f.labels[crate] = {"native:Food"}, {"native:AVeryLongCategoryNameThatWouldRunOverTheButtons", "native:Tool"}
    local a, b = icon(bag, "Duffel"), icon(crate, "Crate")
    refresh()
    assert(a.name == "Duffel" and a.tooltip == "Duffel\nBelongs here: Food" and #b.name == 30)
end)

test("turned off, nothing is changed", function()
    local crate = container("crate")
    f.labels[crate], f.preferences.storageTitles = {"native:Tool"}, false
    local button = icon(crate, "Crate")
    refresh()
    assert(button.name == "Crate" and button.tooltip == "Crate" and not button.lootBoxLabelled)
end)

test("an item's tooltip says where it goes, that it is in its place, or that its place is full", function()
    f.home = {name = "Pantry", tiles = 12, container = {}}
    assert(View.lines(item())[1].text == "Goes to Pantry (12 tiles away)")
    f.home = {name = "Pantry", tiles = 1, container = {}}
    assert(View.lines(item())[1].text == "Goes to Pantry")
    f.home, f.full = nil, {name = "Pantry"}
    assert(View.lines(item())[1].text == "Goes to Pantry, which is full")
    f.full, f.placed = nil, true
    assert(View.lines(item())[1].text == "In its place")
    f.placed, f.kept = nil, true
    local lines = View.lines(item())
    assert(#lines == 1 and lines[1].text == "Keep")
    f.kept, f.wanted = nil, true
    assert(#View.lines(item()) == 0 and View.lines(item(container("crate")))[1].text == "On your loot list")
    f.preferences.storageTips, f.kept = false, true
    assert(#View.lines(item()) == 0)
end)

test("each player's tooltip answers from their own storage, and not at every frame", function()
    local asked, one = 0, item()
    function f.app.world:home() asked = asked + 1; return f.home end
    for _ = 1, 20 do View.lines(one, 0) end
    assert(asked == 1)
    assert(#View.lines(one, 1) == 0 and asked == 1, "A player without a session has no storage")
end)

test("lines are drawn under the tooltip, above it at the bottom of the screen, and not over a menu", function()
    f.home = {name = "Pantry", tiles = 1, container = {}}
    local tip = {item = item(), width = 100, height = 50, y = 100, boxes = {}, backgroundColor = {}, borderColor = {}}
    function tip:isVisible() return true end
    function tip:getAbsoluteX() return 10 end
    function tip:getAbsoluteY() return self.y end
    function tip:drawRect(x, y) self.boxes[#self.boxes + 1] = y end
    function tip:drawRectBorder() end
    function tip:drawText(text) self.text = text end
    ISContextMenu = {instance = {visibleCheck = false}}
    ISToolTipInv.render(tip)
    assert(tip.rendered == 1 and tip.boxes[1] == 50 and tip.text == "Goes to Pantry")
    tip.y = 580
    ISToolTipInv.render(tip)
    assert(tip.boxes[2] == -18)
    ISContextMenu.instance.visibleCheck = true
    ISToolTipInv.render(tip)
    assert(#tip.boxes == 2)
    Events.OnGameStart.fn()
    ISContextMenu.instance.visibleCheck = false
    ISToolTipInv.render(tip)
    assert(#tip.boxes == 3, "The tooltip is wrapped once")
    tip.contextMenu = {}
    ISToolTipInv.render(tip)
    assert(#tip.boxes == 3, "A menu's own tooltip is left alone")
    tip.contextMenu, tip.y, tip.anchorBottomLeft = nil, 300, {}
    ISToolTipInv.render(tip)
    assert(tip.boxes[4] == -18, "A controller's tooltip hangs over the window")
end)

test("NeatUI draws the lines itself, unless another mod draws that tooltip without it", function()
    f.home = {name = "Pantry", tiles = 1, container = {}}
    View.hooked, NeatInventory = nil, {enabled = true, Tooltip = {extraLines = function() return {{text = "Worn"}} end}}
    local neat = true
    ISToolTipInv.render = function(tip) if neat then tip.lines = NeatInventory.Tooltip.extraLines(tip) end end
    View.hookTooltip()
    local tip = {item = item(), width = 100, height = 50, boxes = 0, backgroundColor = {}, borderColor = {}}
    function tip:isVisible() return true end
    function tip:getAbsoluteX() return 10 end
    function tip:getAbsoluteY() return 100 end
    function tip:drawRect() self.boxes = self.boxes + 1 end
    function tip:drawRectBorder() end
    function tip:drawText() end
    ISContextMenu = {}
    ISToolTipInv.render(tip)
    assert(#tip.lines == 2 and tip.lines[2].text == "Goes to Pantry" and tip.boxes == 0)
    neat = false
    ISToolTipInv.render(tip)
    assert(tip.boxes == 1)
    NeatInventory = nil
end)

test("show me marks the way, outlines what is loaded, and stops on arrival or after a while", function()
    local object = {}
    function object:setOutlineHighlight(_, on) self.on = on end
    function object:setOutlineHighlightCol() end
    local storage = {name = "Pantry", tiles = 12, point = {x = 12, y = 0, z = 1}, container = container("crate", {parent = object})}
    local ok, text = View.show(0, storage)
    assert(ok and text == "Pantry (12 tiles away), upstairs" and f.marks[1].x == 12 and object.on)
    View.tick()
    assert(not f.marks[1].gone)
    storage.point.z, f.x = 0, 11
    View.tick()
    assert(f.marks[1].gone and object.on, "The outline stays a moment to tell it from its neighbours")
    f.now = f.now + 5000
    View.tick()
    assert(not object.on)
    f.x = 0
    View.show(0, storage)
    View.show(0, storage)
    assert(f.marks[2].gone and not f.marks[3].gone, "One marker at a time")
    f.now = f.now + 20000
    View.tick()
    assert(f.marks[3].gone)
    ok, text = View.show(0, {name = "Pack", carried = true})
    assert(ok and text == "You are carrying Pack" and #f.marks == 3)
    assert(View.show(0, {name = "Truck", tiles = math.huge}) == nil)
end)

print(passed .. " storage view cases passed")
