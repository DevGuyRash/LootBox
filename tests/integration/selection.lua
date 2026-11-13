package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
package.loaded["ISUI/ISInventoryPane"] = true
package.loaded["ISUI/ISTextBox"] = true

local current
local actualByGroup = setmetatable({}, {__mode = "k"})
ISInventoryPane = {MAX_ITEMS_IN_STACK_TO_RENDER = 50}
function ISInventoryPane.getActualItems(values)
    local result, seen = {}, {}
    for _, value in ipairs(values) do
        local actual = actualByGroup[value] or {value}
        for _, item in ipairs(actual) do
            if not seen[item] then result[#result + 1] = item; seen[item] = true end
        end
    end
    return result
end
function instanceof(object, class) return type(object) == "table" and object.classes and object.classes[class] == true end
function getSpecificPlayer() return current.player end
function getPlayerInventory() return current.inventoryPage end
function getPlayerLoot() return current.lootPage end
function getMouseX() return current.mouseX end
function getMouseY() return current.mouseY end
function getMouseXScaled() return current.mouseX * current.zoom end
function getMouseYScaled() return current.mouseY * current.zoom end
function getCore() return {getScreenWidth = function() return 1280 end, getScreenHeight = function() return 900 end} end
Keyboard = {KEY_ESCAPE = 1}
ISMouseDrag = {}
local registrations = {disconnect = {}, menu = {}}
Events = {
    OnDisconnect = {Add = function(fn) registrations.disconnect[#registrations.disconnect + 1] = fn end},
    OnMainMenuEnter = {Add = function(fn) registrations.menu[#registrations.menu + 1] = fn end},
}

local function geometry(widget, x, y, width, height)
    widget.x, widget.y, widget.width, widget.height = x or 0, y or 0, width or 0, height or 20
    function widget:setX(value) self.x = value end
    function widget:setY(value) self.y = value end
    function widget:setHeight(value) self.height = value end
    function widget:getHeight() return self.height end
    function widget:getBottom() return self.y + self.height end
    return widget
end
local function button(box, internal)
    local value = geometry({target = box, internal = internal, enabled = true}, 0, 150, 80, 25)
    function value:isEnabled() return self.enabled end
    return value
end
ISTextBox = {}
function ISTextBox:derive()
    local class = {}; class.__index = class
    return setmetatable(class, {__index = self})
end
function ISTextBox:new(x, y, width, height, text, defaultText, target, callback, playerIndex)
    local box = geometry({text = text, defaultText = defaultText, target = target, onclick = callback, playerIndex = playerIndex}, x, y, width, height)
    return setmetatable(box, {__index = self})
end
function ISTextBox:initialise()
    local entry = geometry({text = self.defaultText, focused = false, focusCalls = 0, unfocusCalls = 0}, 10, 80, self.width - 20, 25)
    function entry:getText() return self.text end
    function entry:setText(text) self.text = text end
    function entry:isFocused() return self.focused end
    function entry:focus() self.focused = true; self.focusCalls = self.focusCalls + 1 end
    function entry:unfocus() self.focused = false; self.unfocusCalls = self.unfocusCalls + 1 end
    function entry:selectAll() self.allSelected = true end
    self.entry, self.yes, self.no = entry, button(self, "OK"), button(self, "CANCEL")
    self.colorPicker = {visible = false, removed = 0,
        setVisible = function(self, value) self.visible = value end,
        removeFromUIManager = function(self) self.removed = self.removed + 1 end}
end
function ISTextBox:titleBarHeight() return 20 end
function ISTextBox:setOnlyNumbers(value) self.onlyNumbers = value end
function ISTextBox:setValidateFunction(target, fn) self.validateTarget, self.validateFn = target, fn end
function ISTextBox:setValidateTooltipText(text) self.validationTooltip = text end
function ISTextBox:updateButtons() self.yes.enabled = self.validateFn(self.validateTarget, self.entry:getText()) end
function ISTextBox:addToUIManager() self.registered = true end
function ISTextBox:bringToTop() self.raised = true end
function ISTextBox:destroy() self.registered, self.removed = false, true; self.nativeDestroys = (self.nativeDestroys or 0) + 1 end
package.loaded["LootBox/Widgets"] = {
    color = function(role) return {role = role} end,
    text = function(_, x, y, width, height, text)
        local panel = geometry({text = text}, x, y, width, height)
        function panel:getScrollHeight() return 64 end
        return panel
    end,
    setText = function(panel, text) panel.text = text end,
}
local Selection = require "LootBox/Selection"

local function item(index)
    return {classes = {InventoryItem = true}, id = index, name = "Nails",
        getName = function(self) return self.name end}
end
local function pane(left)
    local result = {inventory = {}, items = {}, itemslist = {}, selected = {}, collapsed = {}, mouseOverOption = 1,
        left = left, top = 0, width = 300, height = 200, itemHgt = 20, calls = {}, hooks = {}, rows = {}, headers = {}, scroll = 0}
    function result:getAbsoluteX() return self.left end
    function result:getAbsoluteY() return self.top end
    function result:getWidth() return self.width end
    function result:getHeight() return self.height end
    function result:getScrollHeight() return self.scrollHeight or 1000 end
    function result:setYScroll(value) self.scroll = value end
    function result:refreshContainer()
        self.refreshes = (self.refreshes or 0) + 1
        if self.refreshHook then self:refreshHook() end
        if self.refreshSelection then self:restoreSelection(self.refreshSelection) end
    end
    for _, name in ipairs({"selectIndex", "onMouseDown", "restoreSelection", "renderdetails"}) do
        local method = name
        result[method] = function(self, ...)
            local args = {...}
            self.calls[#self.calls + 1] = {name = method, cap = ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER, args = args}
            if method == "restoreSelection" then
                self.restored = {}
                for member, marker in pairs(args[1]) do
                    self.restored[member] = marker
                    local row = marker == "group" and self.headers[member] or self.rows[member]
                    if row then self.selected[row] = marker == "group" and self.headerGroups[member] or member end
                end
            end
            if self.hooks[method] then return self.hooks[method](self, ...) end
            return method, nil, "native-tail"
        end
    end
    return result
end
local function group(p, count, name, start)
    local members = {}
    for index = 1, count do members[index] = item((start or 0) + index) end
    local value = {name = name or "Base.Nails", invPanel = p, items = {members[1]}}
    for _, member in ipairs(members) do value.items[#value.items + 1] = member end
    actualByGroup[value] = members
    p.itemslist[#p.itemslist + 1] = value
    p.items[#p.items + 1] = value
    p.collapsed[value.name] = true
    p.headerGroups = p.headerGroups or {}
    local firstRow = (start or 0) + 1
    p.headers[members[1]], p.headerGroups[members[1]] = firstRow, value
    for index, member in ipairs(members) do p.rows[member] = firstRow + index end
    return value, members
end
local function updateMembers(value, members)
    actualByGroup[value] = members
    value.items = {members[1]}
    for _, member in ipairs(members) do value.items[#value.items + 1] = member end
end
local function fixture(count)
    if current then Selection.closeAll() end
    NeatInventory = nil
    ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER = 50
    ISMouseDrag = {}
    local f = {mouseX = 20, mouseY = 20, zoom = 1, dead = false, joypad = -1}
    f.player = {isDead = function() return f.dead end, getJoypadBind = function() return f.joypad end}
    f.inventory, f.loot = pane(0), pane(400)
    f.inventoryPage, f.lootPage = {inventoryPane = f.inventory}, {inventoryPane = f.loot}
    f.group, f.members = group(f.inventory, count or 4)
    f.otherGroup, f.otherMembers = group(f.loot, 4, "Base.Other", 10000)
    current = f
    return f
end
local function capture(f, p, g, context)
    p, g = p or f.inventory, g or f.group
    f.mouseX, f.mouseY = p.left + 20, p.top + 20
    return Selection.capture(0, context or {g})
end
local function target(f) return assert(capture(f), "Fixture native stack should be capturable") end
local function mapSize(value)
    local count = 0
    for _ in pairs(value or {}) do count = count + 1 end
    return count
end
local function assertExact(p, members, count)
    local selected = {}
    for _, row in pairs(p.selected) do
        for _, item in ipairs(ISInventoryPane.getActualItems({row})) do selected[item] = true end
    end
    assert(mapSize(selected) == count)
    for index, member in ipairs(members) do
        assert(selected[member] == (index <= count and true or nil))
    end
end

local function grid(p, g)
    local views = {isGrid = function(pane) return pane == p end}
    function views.buildItems(pane)
        assert(pane == p)
        pane.items = {g}
        if pane.gridOpen then
            for index = 1, math.min(#actualByGroup[g], ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER) do
                pane.items[#pane.items + 1] = actualByGroup[g][index]
            end
        end
    end
    function views.setOpen(pane, index, open)
        assert(pane == p and pane.items[index] == g)
        pane.gridOpen = open
        views.buildItems(pane)
    end
    function views.itemTop(pane, index)
        assert(pane == p and index == 2)
        pane.layoutCap = ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER
        return 80, 20
    end
    function p:restoreSelection(selected)
        self.restored = selected
        if selected[g.items[1]] == "group" then self.selected[1] = g end
        if self.gridOpen then
            for index = 1, math.min(#actualByGroup[g], ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER) do
                local member = actualByGroup[g][index]
                if selected[member] == "item" then self.selected[index + 1] = member end
            end
        end
    end
    p.headerHgt = 20
    p.hooks.renderdetails = function(pane, dragged) if not dragged then views.buildItems(pane) end end
    NeatInventory = {Views = views}
end
local function lastCap(p, method)
    for index = #p.calls, 1, -1 do if p.calls[index].name == method then return p.calls[index].cap end end
end
local function press(box, buttonName)
    local b = assert(box[buttonName])
    if buttonName == "yes" then box:updateButtons(); assert(b.enabled, "Expected enabled native OK") end
    b.onclick(b.target, b)
end
local passed, failures = 0, {}
local function test(name, run)
    local ok, problem = pcall(run, fixture())
    if ok then passed = passed + 1; print("PASS " .. name)
    else failures[#failures + 1] = name .. ": " .. tostring(problem); print("FAIL " .. name .. ": " .. tostring(problem)) end
    assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50, "A test leaked the shared native cap")
end

print("Selection integration uses native pane, textbox and item-reference boundary doubles; it does not prove native rendering or transfers")

test("collapsed stacks bind their exact native pane and count actual instances", function(f)
    local selected = target(f)
    assert(selected.pane == f.inventory and selected.inventory == f.inventory.inventory and selected.player == f.player)
    assert(selected.maxCount == 4 and selected.groupName == f.group.name)
    assert(selected.members[f.members[1]] and mapSize(selected.members) == 4)
end)

test("expanded child rows resolve the same native stack without changing its selection", function(f)
    f.inventory.items = {f.group, f.members[1], f.members[2]}
    f.inventory.mouseOverOption = 3
    local before = f.inventory.selected
    local selected = assert(capture(f, f.inventory, f.group, {f.members[2]}))
    assert(selected.groupName == f.group.name and selected.maxCount == 4 and f.inventory.selected == before)
end)

test("loot bag and floor sources bind the clicked pane rather than the carried pane", function(f)
    for _, kind in ipairs({"crate", "bag", "floor"}) do
        f.loot.inventory.kind = kind
        local selected = assert(capture(f, f.loot, f.otherGroup))
        assert(selected.pane == f.loot and selected.inventory == f.loot.inventory)
    end
end)

test("stack capture uses UI coordinates independently of camera zoom", function(f)
    for _, zoom in ipairs({0.5, 1, 1.25, 2}) do
        f.zoom = zoom
        for _, source in ipairs({{pane = f.inventory, group = f.group}, {pane = f.loot, group = f.otherGroup}}) do
            f.mouseX, f.mouseY = source.pane.left + source.pane.width - 20, source.pane.top + 20
            local selected = assert(Selection.capture(0, {source.group}))
            assert(selected.pane == source.pane and selected.maxCount == 4)
        end
    end
end)

test("singletons sidebar clicks mismatched references and unresolved rows have no amount action", function(f)
    f.mouseX = 350
    assert(Selection.capture(0, {f.group}) == nil)
    assert(capture(f, f.inventory, f.group, {f.otherMembers[1]}) == nil)
    f.inventory.mouseOverOption = 999
    assert(capture(f) == nil)
    f.inventory.mouseOverOption = 1
    local only = group(f.inventory, 1, "single", 20000)
    f.inventory.items = {only}
    assert(capture(f, f.inventory, only) == nil)
end)

test("dead controller and ambiguous overlapping panes do not capture mouse selections", function(f)
    f.dead = true; assert(capture(f) == nil); f.dead = false
    f.joypad = 0; assert(capture(f) == nil); f.joypad = -1
    f.loot.left = 0
    local shared = {name = f.group.name, invPanel = f.loot, items = f.group.items}
    actualByGroup[shared] = f.members
    f.loot.items, f.loot.itemslist = {shared}, {shared}
    assert(capture(f) == nil)
end)

test("partial amounts select only exact child references and leave other panes alone", function(f)
    local originalInventory, originalLoot = f.inventory.inventory, f.loot.selected
    local originalCount = #actualByGroup[f.group]
    assert(Selection.apply(target(f), "2"))
    assertExact(f.inventory, f.members, 2)
    assert(f.inventory.collapsed[f.group.name] == false and f.inventory.selected[1] == nil)
    assert(f.loot.selected == originalLoot and f.inventory.inventory == originalInventory)
    assert(#actualByGroup[f.group] == originalCount and #f.members == 4)
end)

test("one item remains a partial selection while the whole count uses the native group marker", function(f)
    local selected = target(f)
    assert(Selection.apply(selected, "1")); assertExact(f.inventory, f.members, 1)
    assert(Selection.apply(selected, "4"))
    assert(mapSize(f.inventory.restored) == 1 and f.inventory.restored[f.members[1]] == "group")
    assert(f.inventory.collapsed[f.group.name] == true)
end)

test("large partial amounts include an unselected sentinel row beyond the chosen items", function()
    local f = fixture(101)
    assert(Selection.apply(target(f), "100"))
    assertExact(f.inventory, f.members, 100)
    assert(lastCap(f.inventory, "restoreSelection") >= 101)
    assert(f.inventory.restored[f.members[101]] == nil)
    f.inventory:renderdetails(false)
    assert(lastCap(f.inventory, "renderdetails") >= 101)
end)

test("selecting fifty from fifty-one exposes the native sentinel instead of stopping at fifty", function()
    local f = fixture(51)
    assert(Selection.apply(target(f), "50"))
    assertExact(f.inventory, f.members, 50)
    assert(lastCap(f.inventory, "restoreSelection") == 51 and f.inventory.restored[f.members[51]] == nil)
end)

test("very large partial amounts keep exact membership without a small artificial ceiling", function()
    local f = fixture(10001)
    assert(Selection.apply(target(f), "9999"))
    assertExact(f.inventory, f.members, 9999)
    assert(lastCap(f.inventory, "restoreSelection") >= 10000)
end)

test("whole stacks above the display cap stay collapsed without raising the cap", function()
    local f = fixture(250)
    assert(Selection.apply(target(f), "250"))
    assert(mapSize(f.inventory.restored) == 1 and f.inventory.restored[f.members[1]] == "group")
    assert(f.inventory.collapsed[f.group.name] and lastCap(f.inventory, "restoreSelection") == 50)
end)

test("invalid or out-of-range text never refreshes or changes the current selection", function(f)
    local selected = target(f)
    local before = f.inventory.selected
    for _, value in ipairs({"", "0", "-1", "1.5", "1e2", " 2", "2 ", "5", "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999"}) do
        local ok, problem = Selection.apply(selected, value)
        assert(not ok and type(problem) == "string" and f.inventory.selected == before and not f.inventory.refreshes)
    end
end)

test("native count shrink refuses the old amount and permits an explicit smaller retry", function(f)
    local selected = target(f)
    f.inventory.refreshHook = function(self)
        updateMembers(f.group, {f.members[1], f.members[2]})
        self.refreshHook = nil
    end
    local before = f.inventory.selected
    local ok, problem = Selection.apply(selected, "3")
    assert(not ok and problem and selected.maxCount == 2 and f.inventory.selected == before)
    assert(Selection.apply(selected, "2"))
    assert(f.inventory.restored[f.members[1]] == "group" and f.inventory.collapsed[f.group.name])
end)

test("new source members do not silently increase the prompt's captured numeric range", function(f)
    local selected = target(f)
    local grown = {f.members[1], f.members[2], f.members[3], f.members[4], item(5)}
    updateMembers(f.group, grown)
    local ok = Selection.apply(selected, "5")
    assert(not ok and not f.inventory.refreshes)
end)

test("changed panes players sources and group identities refuse without selection mutation", function()
    for _, kind in ipairs({"page", "player", "source", "group", "dead", "controller"}) do
        local f = fixture()
        local selected, before = target(f), f.inventory.selected
        if kind == "page" then f.inventoryPage = {inventoryPane = {}}
        elseif kind == "player" then f.player = {}
        elseif kind == "source" then f.inventory.inventory = {}
        elseif kind == "group" then f.group.name = "renamed"
        elseif kind == "dead" then f.dead = true
        else f.joypad = 0 end
        local ok, problem = Selection.apply(selected, "2")
        assert(not ok and problem and f.inventory.selected == before and not f.inventory.refreshes)
    end
end)

test("a reused floor container cannot adopt unrelated same-name item instances", function(f)
    f.loot.inventory.kind = "floor"
    local selected = assert(capture(f, f.loot, f.otherGroup))
    local originals = f.loot.selected
    local replacement, members = group(f.loot, 4, selected.groupName, 30000)
    f.loot.itemslist, f.loot.items = {replacement}, {replacement}
    local ok, problem = Selection.apply(selected, "2")
    assert(not ok and problem and f.loot.selected == originals and not f.loot.refreshes)
    assert(members[1] ~= f.otherMembers[1])
end)

test("source replacement during a native refresh cannot silently retarget the amount", function(f)
    local selected = target(f)
    f.inventory.refreshHook = function(self)
        local replacement = group(self, 4, selected.groupName, 30000)
        self.itemslist = {replacement}
    end
    local before = f.inventory.selected
    local ok, problem = Selection.apply(selected, "2")
    assert(not ok and problem and f.inventory.selected == before and f.inventory.restored == nil)
end)

test("native saved item markers cannot reintroduce a whole expanded-stack header", function(f)
    assert(Selection.apply(target(f), "2"))
    local nativeSaved = {[f.members[1]] = "item", [f.members[2]] = "item"}
    f.inventory.selected = {}
    f.inventory:restoreSelection(nativeSaved)
    assert(f.inventory.restored[f.members[1]] == true and f.inventory.restored[f.members[2]] == "item")
    assert(nativeSaved[f.members[1]] == "item" and f.inventory.selected[1] == nil)
    f.inventory:restoreSelection({[f.members[1]] = "group"})
    assert(f.inventory.restored[f.members[1]] == "group")
end)

test("collapsed and single-item native markers retain their normal meaning", function(f)
    assert(Selection.apply(target(f), "2"))
    f.inventory.collapsed[f.group.name] = true
    f.inventory:restoreSelection({[f.members[1]] = "item"})
    assert(f.inventory.restored[f.members[1]] == "item")
    local singleton, members = group(f.inventory, 1, "single", 20000)
    f.inventory.collapsed[singleton.name] = false
    f.inventory:restoreSelection({[members[1]] = "item"})
    assert(f.inventory.restored[members[1]] == "item")
end)

test("all four adapted native methods restore the shared cap and preserve return values", function()
    local f = fixture(101)
    assert(Selection.apply(target(f), "100"))
    for _, name in ipairs({"selectIndex", "onMouseDown", "restoreSelection", "renderdetails"}) do
        local a, b, c
        if name == "restoreSelection" then a, b, c = f.inventory[name](f.inventory, {})
        else a, b, c = f.inventory[name](f.inventory, false, "argument") end
        assert(a == name and b == nil and c == "native-tail")
        assert(lastCap(f.inventory, name) == 101 and ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50)
    end
end)

test("native errors restore cap scope before propagating and later calls still work", function()
    local f = fixture(101)
    assert(Selection.apply(target(f), "100"))
    f.inventory.hooks.renderdetails = function() error("native callback failure") end
    local ok, problem = pcall(function() f.inventory:renderdetails(false) end)
    assert(not ok and tostring(problem):find("native callback failure", 1, true))
    assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50)
    f.inventory.hooks.renderdetails = nil
    f.inventory:renderdetails(false)
    assert(lastCap(f.inventory, "renderdetails") == 101)
end)

test("a default pane nested inside a raised pane uses its external native base cap", function()
    local f = fixture(101)
    Selection.attach(f.inventory); Selection.attach(f.loot)
    assert(Selection.apply(target(f), "100"))
    f.inventory.hooks.renderdetails = function()
        assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 101)
        f.loot:renderdetails(false)
        assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 101)
    end
    f.inventory:renderdetails(false)
    assert(lastCap(f.loot, "renderdetails") == 50 and ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50)
end)

test("an error from a nested default pane restores every outer cap scope", function()
    local f = fixture(101)
    Selection.attach(f.inventory); Selection.attach(f.loot)
    assert(Selection.apply(target(f), "100"))
    f.inventory.hooks.renderdetails = function() f.loot:renderdetails(false) end
    f.loot.hooks.renderdetails = function() error("nested native failure") end
    assert(not pcall(function() f.inventory:renderdetails(false) end))
    assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50)
    f.loot.hooks.renderdetails = nil
    f.loot:renderdetails(false)
    assert(lastCap(f.loot, "renderdetails") == 50)
end)

test("nested amount application creates its own cap instead of inheriting the caller's cap", function()
    local f = fixture(101)
    local b, members = group(f.loot, 80, "Base.Second", 40000)
    f.loot.items, f.loot.itemslist = {b}, {b}
    local aTarget, bTarget = target(f), assert(capture(f, f.loot, b))
    Selection.attach(f.inventory); Selection.attach(f.loot)
    assert(Selection.apply(aTarget, "100"))
    f.inventory.hooks.renderdetails = function() assert(Selection.apply(bTarget, "75")) end
    f.inventory:renderdetails(false)
    f.loot:renderdetails(false)
    assert(lastCap(f.loot, "renderdetails") == 76)
    assertExact(f.loot, members, 75)
    assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50)
end)

test("an existing external cap remains authoritative and owned caps never shrink", function()
    local f = fixture(101)
    local selected = target(f)
    assert(Selection.apply(selected, "100"))
    assert(Selection.apply(selected, "2"))
    f.inventory:renderdetails(false)
    assert(lastCap(f.inventory, "renderdetails") == 101)
    ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER = 150
    f.inventory:renderdetails(false)
    assert(lastCap(f.inventory, "renderdetails") == 150 and ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 150)
    ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER = 50
end)

test("adapter attachment is idempotent and preserves a foreign native wrapper", function(f)
    local calls = 0
    local original = f.inventory.onMouseDown
    f.inventory.onMouseDown = function(self, ...) calls = calls + 1; return original(self, ...) end
    Selection.attach(f.inventory)
    local wrapped = f.inventory.onMouseDown
    Selection.attach(f.inventory)
    assert(f.inventory.onMouseDown == wrapped)
    local a, b, c = f.inventory:onMouseDown(20, 40)
    assert(calls == 1 and a == "onMouseDown" and b == nil and c == "native-tail")
end)

test("applying an amount clears only the matching pane's old drag state", function(f)
    f.inventory.dragging, f.inventory.dragStarted = true, true
    ISMouseDrag.dragging, ISMouseDrag.draggingFocus = {f.members[4]}, f.loot
    assert(Selection.apply(target(f), "2"))
    assert(ISMouseDrag.draggingFocus == f.loot and ISMouseDrag.dragging[1] == f.members[4])
    ISMouseDrag.draggingFocus = f.inventory
    assert(Selection.apply(target(f), "2"))
    assert(ISMouseDrag.dragging == nil and ISMouseDrag.draggingFocus == nil)
    assert(f.inventory.dragging == nil and f.inventory.dragStarted == false)
end)

test("native rendering reveals the selected rows without changing their item membership", function(f)
    assert(Selection.apply(target(f), "2"))
    f.inventory.selected = {[20] = f.members[1], [21] = f.members[2]}
    f.inventory.smoothScrollY, f.inventory.smoothScrollTargetY = 100, 120
    f.inventory:renderdetails(false)
    assert(f.inventory.scroll < 0 and f.inventory.smoothScrollY == nil and f.inventory.smoothScrollTargetY == nil)
    assert(f.inventory.selected[20] == f.members[1] and f.inventory.selected[21] == f.members[2])
end)

test("Cancel leaves the source selection alone and removes owned prompt focus and picker", function(f)
    local before = f.inventory.selected
    local box = Selection.open(target(f))
    assert(box.registered and box.onlyNumbers and box.entry:isFocused() and box.entry.allSelected)
    box.entry:setText("2")
    press(box, "no")
    assert(box.removed and box.entry.unfocusCalls == 1 and box.colorPicker.removed == 1)
    assert(f.inventory.selected == before and not f.inventory.refreshes and not f.inventory.restored)
    box:destroy()
    assert(box.nativeDestroys == 1 and box.entry.unfocusCalls == 1 and box.colorPicker.removed == 1)
end)

test("native Enter confirms the typed exact amount and Escape cancels even invalid input", function(f)
    local box = Selection.open(target(f))
    box.entry:setText("2")
    box.entry.onCommandEntered(box.entry)
    assert(box.removed); assertExact(f.inventory, f.members, 2)
    local before = f.inventory.selected
    box = Selection.open(target(f)); box.entry:setText("0")
    box.entry.onOtherKey(box.entry, Keyboard.KEY_ESCAPE)
    assert(box.removed and f.inventory.selected == before)
end)

test("native grid Enter opens exact children in either pane and preserves their native markers", function()
    for _, kind in ipairs({"inventory", "loot"}) do
        local f = fixture(4)
        local pane = f[kind]
        local g, members = kind == "inventory" and f.group or f.otherGroup, kind == "inventory" and f.members or f.otherMembers
        grid(pane, g)
        local selected = assert(capture(f, pane, g))
        local box = Selection.open(selected)
        box.entry:setText("2"); box.entry.onCommandEntered(box.entry)
        assert(box.removed and pane.gridOpen and pane.collapsed[g.name])
        assertExact(pane, members, 2)
        assert(pane.selected[1] == nil)
        pane.refreshSelection = {[members[1]] = "item", [members[2]] = "item"}
        pane.selected = {}; pane:refreshContainer()
        assertExact(pane, members, 2)
        assert(Selection.apply(selected, "4") and not pane.gridOpen)
        assert(pane.selected[1] == g and mapSize(pane.selected) == 1)
    end
end)

test("large grid partial selection renders its sentinel and reveals actual view coordinates", function()
    local f = fixture(120)
    grid(f.inventory, f.group)
    assert(Selection.apply(target(f), "100"))
    f.inventory:renderdetails(false)
    assertExact(f.inventory, f.members, 100)
    assert(#f.inventory.items == 102 and f.inventory.selected[102] == nil)
    assert(f.inventory.scroll == -40 and f.inventory.layoutCap == 101)
    assert(ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER == 50)
end)

test("invalid prompt values disable native OK and cannot trigger selection through Enter", function(f)
    local box = Selection.open(target(f))
    for _, text in ipairs({"", "0", "-1", "1.5", "1e2", "5"}) do
        box.entry:setText(text); box:updateButtons()
        assert(not box.yes.enabled and box.validationTooltip)
        box.entry.onCommandEntered(box.entry)
        assert(not box.removed and not f.inventory.refreshes)
    end
    press(box, "no")
end)

test("a stale source keeps the prompt recoverable and Cancel still closes it", function(f)
    local box = Selection.open(target(f))
    local before = f.inventory.selected
    f.inventory.inventory = {}
    box:updateButtons()
    assert(not box.yes.enabled and box.validationTooltip)
    box.entry.focused, box.entry.allSelected = false, false
    box:onChoice(box.yes)
    assert(box.selectionError and not box.removed and box.entry:isFocused())
    assert(f.inventory.selected == before)
    press(box, "no"); assert(box.removed)
end)

test("a live count reduction shows an error and a smaller explicit retry succeeds", function(f)
    local box = Selection.open(target(f))
    box.entry:setText("3")
    f.inventory.refreshHook = function(self)
        updateMembers(f.group, {f.members[1], f.members[2]}); self.refreshHook = nil
    end
    box.entry.focused, box.entry.allSelected = false, false
    press(box, "yes")
    assert(not box.removed and box.selectionError and box.description.text:find("2", 1, true))
    assert(box.entry.allSelected and box.entry:isFocused())
    box.entry:setText("1"); press(box, "yes")
    assert(box.removed); assertExact(f.inventory, f.members, 1)
end)

test("destroying an unfocused prompt does not call native unfocus", function(f)
    local box = Selection.open(target(f))
    box.entry.focused = false
    press(box, "no")
    assert(box.entry.unfocusCalls == 0)
end)

test("replacement prompts and disconnect cleanup release every owned dialog once", function(f)
    Selection.install(); Selection.install()
    assert(#registrations.disconnect == 1 and #registrations.menu == 1)
    local selected = target(f)
    local first, second = Selection.open(selected), Selection.open(selected)
    assert(first.removed and first.nativeDestroys == 1 and second.registered)
    registrations.disconnect[1]()
    assert(second.removed and second.nativeDestroys == 1)
    local third = Selection.open(selected)
    registrations.menu[1]()
    assert(third.removed and third.entry.unfocusCalls == 1 and third.colorPicker.removed == 1)
end)

Selection.closeAll()
assert(#failures == 0, table.concat(failures, "\n"))
print(passed .. " selection workflow cases passed (explicit native pane, selection and modal boundary doubles)")
