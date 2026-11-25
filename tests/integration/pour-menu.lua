-- Item Pour Into and Fill From from the native right-click selection, with the
-- real selection, snapshot, plan and row modules. Panes, items and the native
-- menu are doubles.
package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Menu = {}
Menu.__index = Menu
function Menu:new() return setmetatable({ options = {} }, self) end
function Menu:addOption(name, target, action)
    local option = { name = name, target = target, onSelect = action }
    self.options[#self.options + 1] = option
    return option
end
function Menu:insertOptionAfter(after, name, target, action)
    local option = { name = name, target = target, onSelect = action }
    for index, existing in ipairs(self.options) do
        if existing.name == after then table.insert(self.options, index + 1, option); return option end
    end
    self.options[#self.options + 1] = option
    return option
end
function Menu:addSubMenu(option, child) option.child = child end
ISContextMenu = { getNew = function() return Menu:new() end }
function getTimestampMs() return 1 end
function isClient() return false end
function isServer() return false end
function instanceof(object, class) return type(object) == "table" and object.physical == true and class == "InventoryItem" end
function getText(key) return key end
local f
function getTexture(key) if not (f.noDropIcon and key == "Item_WaterDrop") then return key end end
function getActivatedMods() return { contains = function(_, id) return f.legacy and id == "PourIntoContainer" end } end
function getSpecificPlayer() return f.player end
function getPlayerInventory() return f.inventoryPage end
function getPlayerLoot() return f.lootPage end
package.loaded["LootBox/App"] = { get = function() return f.app end }
local PourMenu = require "LootBox/PourMenu"
local PourStacks = require "LootBox/PourStacks"

local function container(kind, bag)
    local c = { kind = kind, contents = {} }
    function c:getType() return self.kind end
    function c:getContainingItem() return bag end
    function c:isLockedToCharacter() return false end
    function c:getItems() return { size = function() return #c.contents end, get = function(_, i) return c.contents[i + 1] end } end
    function c:contains(candidate)
        for _, entry in ipairs(self.contents) do if entry == candidate then return true end end
        return false
    end
    return c
end
local nextId
local function item(c, kind, name)
    nextId = nextId + 1
    local i = { physical = true, source = c, id = nextId, name = name }
    function i:getID() return self.id end
    function i:getName() return self.name end
    function i:getFullType() return kind end
    function i:getContainer() return self.source end
    function i:isSealed() return self.sealed == true end
    function i:getInventory() return self.bag end
    c.contents[#c.contents + 1] = i
    return i
end
local milk = {}
local function vessel(c, kind, name, capacity, amount)
    local i = item(c, kind, name)
    local fluid = { amount = amount, capacity = capacity }
    function fluid:getAmount() return self.amount end
    function fluid:getCapacity() return self.capacity end
    function fluid:getFreeCapacity() return self.capacity - self.amount end
    function fluid:getOwner() return i end
    function fluid:canPlayerEmpty() return true end
    function fluid:createFluidSample()
        self.sampled = (self.sampled or 0) + 1
        if self.unreadable then return nil end
        return { size = function() return self.amount > 0 and 1 or 0 end, getFluid = function() return milk end,
            getPercentage = function() return 1 end, release = function() end }
    end
    function i:getFluidContainer() return fluid end
    return i, fluid
end
local function pane(page, holder)
    page.inventoryPane = { inventory = holder, player = 0, itemindex = {}, collapsed = {}, itemslist = {}, items = {},
        getIsVisible = page.getIsVisible }
    page.inventoryPane.inventoryPage = page
end
local function fixture()
    nextId = 10
    f = { preferences = {}, calls = {} }
    f.main, f.crate = container("inventory"), container("crate")
    local square = {}
    f.player = { getInventory = function() return f.main end, getSquare = function() return square end,
        getPrimaryHandItem = function() return f.pack end }
    f.pack = item(f.main, "Base.Bag", "Field Bag")
    f.pouch = container("bag", f.pack)
    f.pack.bag = f.pouch
    f.lootPage = { getIsVisible = function() return f.visible ~= false end }
    f.inventoryPage = { getIsVisible = function() return true end }
    pane(f.inventoryPage, f.main); pane(f.lootPage, f.crate)
    f.app = { world = {
        protected = function() return false end,
        name = function(_, c) return c == f.crate and "Kitchen Shelf" or nil end,
        consumptionSource = function(_, i, c) return f.sourceDenied ~= true and c == f.crate and i.source == c end,
        pourShelfAnchor = function(_, c) return not f.noAnchor and c == f.crate and { c } or nil end } }
    function f.app:startPour(source, targets, options, receiver)
        f.calls[#f.calls + 1] = { source = source, targets = targets, options = options, receiver = receiver }
        return not f.refuse, f.refuse
    end
    FluidContainer = { CanTransfer = function(from, to) return from ~= to end }
    FluidUtil = { roundTransfer = function(n) return n end }
    f.source = vessel(f.main, "Base.Milk", "Milk", 2, 1.5)
    f.bottle = vessel(f.main, "Base.Bottle", "Bottle", 1, 0)
    f.bagged = vessel(f.pouch, "Base.Bottle", "Bottle", 2, 0)
    f.shelf = vessel(f.crate, "Base.Milk", "Shelf Milk", 2, 1)
    f.shelfTarget = vessel(f.crate, "Base.Bottle", "Shelf Bottle", .5, 0)
    return f
end
local function open(items, parent)
    parent = parent or Menu:new()
    f.branded = nil
    local added = PourMenu.add({ playerIndex = 0, parent = parent, items = items, app = f.app, preferences = f.preferences,
        tooltip = function(option, title, text) option.tip = text end,
        branded = function() f.branded = f.branded or Menu:new(); return f.branded end,
        interaction = function(origin, label) f.asked = { origin, label }; return 5 end })
    return parent, added
end
local function option(menu, name)
    for _, candidate in ipairs(menu.options) do if candidate.name == name then return candidate end end
end
local function needed(menu, name) return assert(option(menu, name), "Missing menu action: " .. name) end
local function click(row) return row.onSelect(row.target) end
local function names(menu)
    local out = {}
    for index, row in ipairs(menu.options) do out[index] = row.name end
    return table.concat(out, "|")
end
local function icon(row) return (row.iconTexture ~= nil) ~= (row.itemForTexture ~= nil) end
local function stack(pane_, key, representative, ...)
    local row = { invPanel = pane_, name = key, items = { representative, ... } }
    pane_.itemindex[key], pane_.collapsed[key] = row, true
    pane_.itemslist[#pane_.itemslist + 1] = row
    pane_.items[#pane_.items + 1] = row
    return row
end
local tests = 0
local function test(name, fn)
    fixture()
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err), 0) end
    tests = tests + 1
    print("PASS " .. name)
end

test("one Pour Into after the native Fluid entry dispatches one frozen batch in the player's order", function()
    f.preferences.pourEquippedFirst, f.preferences.pourMostRoomFirst = true, true
    local parent = Menu:new()
    local native = Menu:new()
    parent:addSubMenu(parent:addOption("ContextMenu_Fluid"), native)
    parent:addOption("Drop")
    local rows = { f.source }
    local _, added = open(rows, parent)
    assert(added and not f.branded and names(parent) == "ContextMenu_Fluid|Pour Into|Drop" and #native.options == 0)
    local root = needed(parent, "Pour Into")
    assert(root.iconTexture == "Item_WaterDrop" and root.tip:find("Milk, 1.5 / 2 L", 1, true))
    assert(names(root.child) == "Pour into all (2)|Bottle, 0 / 1 L|Bottle, 0 / 2 L")
    local one, two = needed(root.child, "Bottle, 0 / 1 L"), needed(root.child, "Bottle, 0 / 2 L")
    assert(one.itemForTexture == f.bottle and two.itemForTexture == f.bagged and not one.iconTexture)
    assert(one.tip:find("Main inventory", 1, true) and two.tip:find("Field Bag", 1, true))
    for _, row in ipairs(root.child.options) do assert(icon(row)) end
    rows[1] = f.bottle -- callbacks must not re-flatten new UI rows
    local all = needed(root.child, "Pour into all (2)")
    click(all); click(all); click(one)
    assert(#f.calls == 1 and f.calls[1].source.item == f.source and #f.calls[1].targets == 2)
    assert(f.calls[1].targets[1].item == f.bagged and f.calls[1].targets[2].item == f.bottle)
    local options = f.calls[1].options
    assert(options.pourFillScope == "equipped-first" and options.pourFillOrder == "largest-first"
        and options.pourRoute == "fill-all" and options.interaction == 5)
    assert(f.asked[1] == "menu.item" and f.asked[2] == "Pour Into > Pour into all (2)")
    assert(not package.loaded["Fluids/ISFluidTransferAction"], "native actions must remain lazy at menu render")
    local again
    _, again = open({ f.source }, parent)
    assert(not again and #parent.options == 3)
end)

test("a refused start tells the player and frees nothing to click twice", function()
    local said
    HaloTextHelper = { addBadText = function(_, text) said = text end }
    f.refuse = "Pour settings changed."
    local parent = open({ f.source })
    local row = needed(needed(parent, "Pour Into").child, "Bottle, 0 / 1 L")
    local ok, reason = click(row)
    HaloTextHelper = nil
    assert(not ok and reason == f.refuse and said == "Pour Into: Pour settings changed.")
end)

test("identical vessels share a row per place and every row keeps its exact vessel", function()
    local a = vessel(f.main, "Base.Canteen", "Canteen", 1, .6)
    local b = vessel(f.pouch, "Base.Canteen", "Canteen", 1, .6)
    local c = vessel(f.main, "Base.Canteen", "Canteen", 1, .6)
    local function child() return needed(open({ f.source }), "Pour Into").child end
    assert(names(child()) == "Pour into all (5)|Canteen, 0.6 / 1 L - Main inventory (2)|Canteen, 0.6 / 1 L - Field Bag"
        .. "|Bottle, 0 / 1 L|Bottle, 0 / 2 L", names(child()))
    local group = needed(child(), "Canteen, 0.6 / 1 L - Main inventory (2)")
    assert(names(group.child) == "All (2)|One" and group.itemForTexture == a)
    click(needed(group.child, "All (2)"))
    assert(#f.calls[1].targets == 2 and f.calls[1].targets[1].item == a and f.calls[1].targets[2].item == c)
    click(needed(needed(child(), "Canteen, 0.6 / 1 L - Main inventory (2)").child, "One"))
    assert(#f.calls[2].targets == 1 and f.calls[2].targets[1].item == a and f.calls[2].options.pourRoute == "single")
    click(needed(child(), "Canteen, 0.6 / 1 L - Field Bag"))
    assert(f.calls[3].targets[1].item == b)
end)

test("third-party entries keep their place and ours moves into LootBox with a fallback icon", function()
    f.noDropIcon = true
    for _, mode in ipairs({ "legacy", "foreign", "ellipsis" }) do
        local parent, foreignRan = Menu:new(), false
        f.legacy = mode == "legacy"
        local foreign = mode ~= "legacy" and parent:addOption(mode == "ellipsis" and "Pour into ..." or "Pour Into", nil, function() foreignRan = true end)
        open({ f.source }, parent)
        if foreign then click(foreign); assert(foreignRan and #parent.options == 1) else assert(#parent.options == 0) end
        local root = needed(f.branded, "Pour Into")
        assert(root.itemForTexture == f.source)
        click(needed(root.child, "Bottle, 0 / 1 L"))
        assert(f.calls[#f.calls].targets[1].item == f.bottle)
    end
    f.legacy, f.noDropIcon = nil, nil
end)

test("two selections, hidden loot and loot-to-loot stay exact, and nothing is shown without an action", function()
    local function root(items) return option(open(items), "Pour Into") end
    assert(not root({ { items = { f.source, f.source, f.bottle } } }))
    assert(not root({ f.source, f.bottle }))
    f.visible = false; assert(not root({ f.shelf })); f.visible = true
    assert(not option(root({ f.shelf }).child, "Shelf Bottle, 0 / 0.5 L"))
    f.preferences.pourLootToLoot = true
    click(needed(root({ f.shelf }).child, "Shelf Bottle, 0 / 0.5 L"))
    assert(f.calls[1].source.item == f.shelf and f.calls[1].targets[1].item == f.shelfTarget and f.calls[1].options.pourLootToLoot == true)
    f.preferences.pourLootToLoot = nil
    for _, v in ipairs({ f.source, f.bottle, f.bagged }) do v:getFluidContainer().amount = v:getFluidContainer().capacity end
    assert(not root({ f.shelf }))
    f.bottle:getFluidContainer().amount = 0
    assert(needed(root({ f.shelf }).child, "Bottle, 0 / 1 L"))
    f.noAnchor = true; assert(not root({ f.shelf }), "a vessel that cannot be put back is not offered"); f.noAnchor = nil
    f.sourceDenied = true; assert(not root({ f.shelf }))
end)

test("loot Fill From on one exact receiver lists allowed donors and one frozen click", function()
    f.preferences.pourMainOnly = true -- a batch policy cannot hide an explicit bagged donor
    f.bagged:getFluidContainer().amount = .75
    local anchor = { f.crate }
    f.app.world.pourShelfAnchor = function(_, c) if c == f.crate then return anchor end end
    local items = { f.shelfTarget }
    local parent = open(items)
    assert(not option(parent, "Pour Into"))
    local root = needed(parent, "Fill From")
    assert(names(root.child) == "Milk, 1.5 / 2 L|Bottle, 0.75 / 2 L" and root.tip:find("Shelf Bottle, 0 / 0.5 L", 1, true))
    items[1] = f.bottle
    assert(click(needed(root.child, "Bottle, 0.75 / 2 L")))
    click(needed(root.child, "Milk, 1.5 / 2 L"))
    assert(#f.calls == 1 and f.calls[1].source.item == f.bagged and f.calls[1].receiver == f.shelfTarget and #f.calls[1].targets == 1
        and f.calls[1].targets[1].item == f.shelfTarget and f.calls[1].targets[1].pourAnchor == anchor
        and f.calls[1].options.pourRoute == "portable-fill-from")
    f.preferences.pourLootToLoot = true
    f.shelfTarget:getFluidContainer().amount = .1
    click(needed(needed(open({ f.shelfTarget }), "Fill From").child, "Shelf Milk, 1 / 2 L"))
    assert(f.calls[2].source.item == f.shelf)
    f.preferences.pourLootToLoot = nil
    assert(not option(open({ f.shelfTarget, f.shelf }), "Fill From"), "a mixed selection cannot fill a guessed receiver")
    assert(not option(open({ stack(f.lootPage.inventoryPane, "Shelf stack", f.shelfTarget, f.shelfTarget, f.shelf) }), "Fill From"))
    f.shelfTarget:getFluidContainer().amount = .5; assert(not option(open({ f.shelfTarget }), "Fill From"))
    f.shelfTarget:getFluidContainer().amount = 0
    parent = Menu:new(); parent:addOption("Fill from ...")
    open({ f.shelfTarget }, parent)
    assert(#parent.options == 1 and needed(f.branded, "Fill From"))
    f.visible = false; assert(not option(open({ f.shelfTarget }), "Fill From")); f.visible = true
    f.app.world.pourShelfAnchor = function() return nil end
    assert(not option(open({ f.shelfTarget }), "Fill From"))
end)

test("carried receivers: one fills from any carried donor, a stack fills all or one", function()
    click(needed(needed(open({ f.bottle }), "Fill From").child, "Milk, 1.5 / 2 L"))
    assert(f.calls[1].source.item == f.source and f.calls[1].targets[1].item == f.bottle and not f.calls[1].receiver)
    click(needed(needed(open({ f.bagged }), "Fill From").child, "Milk, 1.5 / 2 L"))
    assert(f.calls[2].targets[1].item == f.bagged)
    local second = vessel(f.main, "Base.Bottle", "Bottle", 1, .2)
    local row = stack(f.inventoryPage.inventoryPane, "Bottle", f.bottle, f.bottle, second)
    local child = needed(needed(open({ row }), "Fill From").child, "Milk, 1.5 / 2 L").child
    assert(names(child) == "Fill all (2)|Fill one")
    click(needed(child, "Fill all (2)"))
    assert(#f.calls[3].targets == 2)
    f.source:getFluidContainer().amount, second:getFluidContainer().amount = 0, 0
    f.preferences.pourLootToLoot = true
    assert(not option(open({ f.bottle }), "Fill From"), "a shelf is never searched for a carried receiver")
end)

test("a visible composite loot section authorizes only the actual clicked holder", function()
    local page, oven = f.lootPage, f.crate
    local pane_ = page.inventoryPane
    pane_.inventory = f.main -- UI retains an unrelated backing holder
    local button = { inventory = oven }
    page.backpacks = { button }
    local row = stack(pane_, "Milk", f.shelf, f.shelf)
    pane_.itemindex.Milk = {} -- overwritten by the last rendered group
    local function root(items) return option(open(items), "Pour Into") end
    assert(needed(root({ row }).child, "Bottle, 0 / 1 L"))
    local section = { index = 1, container = oven, button = button, folded = false }
    pane_.ninvSections, pane_.ninvSectionOf, pane_.ninvCombinedBuilt = { section }, { [oven] = section }, false
    pane_.items = {}
    assert(PourStacks.displayedLoot(0, oven) == oven, "a retained section allows restoration after its last item is borrowed")
    assert(not root({ row }), "stale row not currently rendered")
    pane_.items = { row }
    click(needed(root({ row }).child, "Bottle, 0 / 1 L"))
    assert(f.calls[1].source.container == oven)
    row.items = { f.shelf, f.shelf, f.source }
    assert(not root({ row }), "a merged cross-holder row is not a single stack")
    row.items = { f.shelf, f.shelf }
    section.folded = true
    pane_.items = {}
    assert(not root({ row }) and not root({ f.shelf }) and PourStacks.displayedLoot(0, oven) == nil)
    section.folded = false
    pane_.items = { row }
    page.backpacks = {}
    assert(not root({ row }) and not root({ f.shelf }), "view cannot authorize a detached native holder")
end)

test("a collapsed source picks the least filled eligible exact vessel and freezes it", function()
    local pane_ = f.inventoryPage.inventoryPane
    local small = vessel(f.main, "Base.Milk", "Milk", 1, .4)
    local winner, winnerFluid = vessel(f.main, "Base.Milk", "Milk", 10, 2)
    local higherId = vessel(f.main, "Base.Milk", "Milk", 10, 2)
    local sealed = vessel(f.main, "Base.Milk", "Milk", 10, .01); sealed.sealed = true
    local empty = vessel(f.main, "Base.Milk", "Milk", 1, 0)
    local odd, oddFluid = vessel(f.main, "Base.Milk", "Milk", 10, .02)
    FluidContainer.CanTransfer = function(from, to) return from ~= to and from ~= oddFluid end
    local row = stack(pane_, "Milk", f.bottle, empty, sealed, odd, higherId, small, winner, f.source)
    local function root(items) return option(open(items), "Pour Into") end
    assert(not root({ row, f.bottle }), "mixed selection is not a single stack")
    assert(not root({ { name = row.name, invPanel = pane_, items = row.items } }), "unregistered row is not native")
    pane_.collapsed.Milk = false
    assert(not root({ row }), "expanded group is not permission to pick a sibling")
    assert(not root({ empty }), "expanded singleton must stay exact")
    assert(root({ small }).tip:find("0.4 / 1 L", 1, true))
    pane_.collapsed.Milk = true
    local top = root({ row })
    assert(top.tip:find("2 / 10 L", 1, true) and top.tip:find("least filled", 1, true))
    local all = top.child.options[1]
    assert(all.name:find("^Pour into all %("))
    winnerFluid.amount = 0
    row.items = { f.bottle, small }
    click(all)
    assert(#f.calls == 1 and f.calls[1].source.item == winner, "click must retain exact preview even after change")
end)

test("each mixture is sampled once per menu, unreadable ones are skipped and never substituted later", function()
    local bad, badFluid = vessel(f.main, "Base.Milk", "Milk", 2, .1); badFluid.unreadable = true
    local winner, fluid = vessel(f.main, "Base.Milk", "Milk", 2, .5)
    local row = stack(f.inventoryPage.inventoryPane, "Milk", bad, bad, winner, f.source)
    local root = needed(open({ row }), "Pour Into")
    assert(root.tip:find("0.5 / 2 L", 1, true))
    assert(fluid.sampled == 1 and badFluid.sampled == 1 and f.source:getFluidContainer().sampled == 1)
    local direct = needed(root.child, "Bottle, 0 / 1 L")
    fluid.unreadable = true
    click(direct)
    assert(f.calls[1].source.item == winner and fluid.sampled == 1, "the click must not rebuild the captured plan")
end)

test("a collapsed source moves past targets whose mixtures cannot be captured", function()
    local first, firstFluid = vessel(f.main, "Base.Milk", "Milk", 2, .1)
    local second, secondFluid = vessel(f.main, "Base.Milk", "Milk", 2, .2)
    local badTarget, targetFluid = vessel(f.main, "Base.Jar", "Jar", 2, .25); targetFluid.unreadable = true
    local sourceFluid, bottleFluid = f.source:getFluidContainer(), f.bottle:getFluidContainer()
    FluidContainer.CanTransfer = function(from, to)
        if from == firstFluid or from == secondFluid then return to == targetFluid end
        return from == sourceFluid and to == bottleFluid
    end
    local row = stack(f.inventoryPage.inventoryPane, "Milk", first, first, second, f.source)
    local root = needed(open({ row }), "Pour Into")
    assert(root.tip:find("1.5 / 2 L", 1, true) and targetFluid.sampled == 1)
    assert(names(root.child) == "Bottle, 0 / 1 L")
    click(root.child.options[1])
    assert(f.calls[1].source.item == f.source and f.calls[1].targets[1].item == f.bottle and badTarget)
end)

test("cargo without liquid costs no selection, no snapshot and no row", function()
    local nails = item(f.main, "Base.Nails", "Nails")
    local scans = 0
    local items = f.main.getItems
    function f.main:getItems() scans = scans + 1; return items(self) end
    local parent, added = open({ nails })
    assert(not added and #parent.options == 0 and scans == 0)
    parent, added = open({ stack(f.inventoryPage.inventoryPane, "Nails", nails, nails, item(f.main, "Base.Nails", "Nails")) })
    assert(not added and scans == 0)
    open({ f.source })
    assert(scans == 1, "one right click reads the inventory once, not " .. scans)
end)
print("PASS " .. tests .. " pour menu scenarios")
