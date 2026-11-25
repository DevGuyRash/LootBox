-- The Storage page: names, orders and labels, with the real Picker. Widgets and the app are doubles.
if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end
next = nil -- Kahlua has none

local f
function getTimestampMs() return f.now end
function getSpecificPlayer() return f.player end
function instanceof() return false end
function getItemNameFromFullType(value) return value end
function getTextOrNull() return nil end
local function widget(fields)
    local w = {width = 10, height = 10, x = 0, visible = true}
    for key, value in pairs(fields or {}) do w[key] = value end
    function w:setVisible(on) self.visible = on end
    function w:isVisible() return self.visible end
    function w:setTone(tone) self.tone = tone end
    function w:setTitle(text) self.title = text end
    function w:setWidth(width) self.width = width end
    function w:set(text, tone) self.text, self.tone = text, tone or self.tone end
    return w
end
local K = {PAD = 1, GAP = 1, ROW = 10, LINE = 10, ENTRY = 10, width = function(text) return #text end, place = function() end}
function K.button(_, title, owner, action) return widget({title = title, click = function() if action then action(owner) end end}) end
function K.toggle(_, _, on, owner, action) local w = widget({on = on}); function w.click() w.on = not w.on; action(owner, w.on) end return w end
function K.label(_, text) return widget({name = text}) end
K.text = K.label
function K.list(_, owner, action)
    local w = widget({rows = {}})
    function w:fill(rows, keep) self.rows, self.kept = rows, keep == true end
    function w:click(title)
        for _, row in ipairs(self.rows) do if row.title == title then return action(owner, row) end end
        error("No row " .. title)
    end
    return w
end
function K.entry()
    local w = widget({value = ""})
    function w:getText() return self.value end
    function w:setText(text) self.value = text end
    function w:isFocused() return self.focused == true end
    function w:unfocus() self.focused = false end
    function w:setEditable(on) self.editable = on end
    function w:setClearButton(on) self.clearable = on end
    f.entries[#f.entries + 1] = w
    return w
end
function K.unfocus() for _, entry in ipairs(f.entries) do entry.focused = false end end
function K.menu() f.menu = {}; return f.menu end
function K.option(menu, title, action) menu[title] = action end
package.loaded["LootBox/UIKit"] = K
package.loaded["LootBox/PlanPage"] = {openContainers = function() return f.open end, numbered = function(list)
    local names = {}
    for index, container in ipairs(list) do names[index] = container.name end
    return names
end}
package.loaded["LootBox/StorageView"] = {refresh = function() f.refreshed = (f.refreshed or 0) + 1 end, show = function(_, entry) f.shown = entry; return true, entry.name end}
package.loaded["LootBox/App"] = {get = function() return f.app end, category = function() end,
    categoryName = function(id) return id end, customCategories = function() return {} end,
    catalog = function() return {items = {}, categories = {{id = "native:Food", name = "Food"}, {id = "native:Tool", name = "Tool"}}} end}
package.loaded["LootBox/Log"] = {}
local Storage = require("LootBox/ListPages").Storage

local function container(name, key)
    local c = {name = name, key = key}
    function c:getType() return "crate" end
    function c:getParent() return {} end
    function c:getContainingItem() return self.item end
    function c:isLockedToCharacter() return self.locked == true end
    return c
end
local function fixture()
    f = {now = 1000, entries = {}, labels = {}, storage = {}, valid = true, player = {}}
    function f.player:getInventory() return f.main end
    f.crate, f.other, f.bin = container("Crate", "k1"), container("Shelves", "k2"), container("Bin", "k3")
    f.open = {f.crate, f.other, f.bin}
    local world = {}
    function world:key(c) return c.key end
    function world:isTrash(c) return c == f.bin end
    function world:owns() return false end
    function world:valid() return f.valid end
    function world:square() return {getX = function() return 3 end, getY = function() return 4 end, getZ = function() return 0 end} end
    function world.plainName() return "Crate" end
    function world:givenName(c) return f.storage[c.key] and f.storage[c.key].name end
    function world:labelsInside(c) return c.types or {}, c.categories or {} end
    function world:storages()
        local result = {}
        for _, key in ipairs({"k1", "k2", "far"}) do
            local labels, details = f.labels[key] or {}, f.storage[key] or {}
            if #labels > 0 or details.name or details.order then
                local live = f.valid and key ~= "far" and (key == "k1" and f.crate or f.other) or nil
                result[#result + 1] = {key = key, labels = labels, given = details.name, name = details.name or "Crate", kind = "Crate", container = live,
                    tiles = live and 1 or 40, nameable = live ~= nil}
            end
        end
        return result
    end
    f.app = {player = f.player, world = world, state = {}, storageRevision = 0}
    local function key(target) return type(target) == "string" and target or target.key end
    function f.app:labels(target) local r = {}; for i, id in ipairs(f.labels[key(target)] or {}) do r[i] = id end return r end
    function f.app:setLabels(target, ids) f.labels[key(target)] = #ids > 0 and ids or nil; self.storageRevision = self.storageRevision + 1; return true end
    function f.app:storageDetails(target) return f.storage[key(target)] or {} end
    function f.app:setStorage(target, details)
        if f.refuse then return nil, f.refuse end
        local now = f.storage[key(target)] or {}
        for field, value in pairs(details) do now[field] = value end
        if now.order == "usual" then now.order = nil end
        if now.name == "" then now.name = nil end
        f.storage[key(target)] = now
        self.storageRevision = self.storageRevision + 1
        return true
    end
    f.page = Storage.build({playerIndex = 0}, {width = 500, height = 300})
    Storage.opened(f.page)
end
local function typed(text) f.page.name.focused, f.page.name.value = true, text end
local passed = 0
local function test(name, run) fixture(); run(); passed = passed + 1; print("PASS " .. name) end

test("open containers that can be labelled are listed, and trash cans are not", function()
    f.other.locked = true
    Storage.opened(f.page)
    local names = {}
    for _, row in ipairs(f.page.list.rows) do names[#names + 1] = row.title end
    assert(table.concat(names, " ") == "Open right now Crate", table.concat(names, " "))
end)

test("a name typed before a click in the picker is saved, not lost", function()
    f.page.list:click("Crate")
    typed("Workshop")
    f.page.name.focused = false -- the game takes the focus before the list is told
    f.page.picker.list:click("Food")
    assert(f.storage.k1.name == "Workshop" and f.labels.k1[1] == "native:Food" and f.page.name.value == "Workshop")
end)

test("a name goes to the container it was typed for", function()
    f.page.list:click("Crate")
    typed("Workshop")
    f.page.list:click("Shelves")
    assert(f.storage.k1.name == "Workshop" and (f.storage.k2 == nil or f.storage.k2.name == nil))
    typed("Pantry")
    Storage.opened(f.page, {container = f.crate})
    assert(f.storage.k2.name == "Pantry" and f.storage.k1.name == "Workshop")
end)

test("clearing the box takes the name off, and typing saves nothing until it is done", function()
    f.page.list:click("Crate")
    typed("W")
    Storage.tick(f.page)
    assert(f.storage.k1 == nil)
    f.page.name.focused = false
    Storage.tick(f.page)
    assert(f.storage.k1.name == "W")
    f.page.name.value = ""
    Storage.tick(f.page)
    assert(f.storage.k1.name == nil)
end)

test("a refused name is not left standing", function()
    f.page.list:click("Crate")
    f.refuse = "This storage is in a safehouse you may not use"
    typed("Mine")
    f.page.name.onCommandEntered()
    assert(f.page.name.value == "" and f.page.title.text == f.refuse)
end)

test("choosing labels keeps both lists where they are scrolled", function()
    f.page.list:click("Crate")
    f.page.picker.list:click("Food")
    assert(f.page.picker.list.kept and f.page.picker.chosen.kept and f.refreshed == 1)
end)

test("order and anything else are kept beside the labels", function()
    f.page.list:click("Crate")
    f.page.picker.list:click("Food")
    f.page.rest.click()
    assert(table.concat(f.labels.k1, " ") == "native:Food rest:")
    f.page.orders[3].click()
    assert(f.storage.k1.order == "last" and f.page.orders[3].tone == "primary" and f.page.orders[1].tone == "ghost")
    f.page.picker.list:click("Food")
    assert(table.concat(f.labels.k1, " ") == "rest:")
end)

test("storage out of sight can be labelled and ordered but not named, and clearing it lets go of it", function()
    f.labels.far = {"native:Food"}
    Storage.opened(f.page)
    f.page.list:click("Crate") -- the open one
    for _, row in ipairs(f.page.list.rows) do if row.key == "far" then Storage.choose(f.page, row.container, row.key) end end
    assert(f.page.name.editable == false and f.page.name.clearable == false and f.page.title.text:find("Go near it", 1, true))
    f.page.picker.list:click("Tool")
    assert(table.concat(f.labels.far, " ") == "native:Food native:Tool")
    f.page.more.click()
    f.menu["Clear labels"]()
    assert(f.page.key == nil and not f.page.picker.list.visible and f.page.title.text == "Choose a container on the left.")
end)

test("labels changed elsewhere show, and a container that is gone is let go", function()
    f.page.list:click("Crate")
    f.app:setLabels(f.crate, {"native:Tool"})
    f.now = f.now + 1000
    Storage.tick(f.page)
    assert(f.page.picker.selection.ids[1] == "native:Tool")
    f.valid, f.now = false, f.now + 1000
    Storage.tick(f.page)
    assert(f.page.container == nil and f.page.key == "k1")
end)

test("More offers only what would change something", function()
    f.page.list:click("Shelves")
    f.page.more.click()
    assert(f.menu == nil and f.page.title.text == "Nothing to copy or paste yet.")
    f.crate.categories, f.labels.k1 = {"native:Food"}, {"native:Food", "item:3:Base.Axe"}
    Storage.opened(f.page, {container = f.crate})
    f.page.more.click()
    assert(f.menu["Copy labels"] and f.menu["Clear labels"] and not f.menu["Label with the categories inside (1)"] and not f.menu["Paste labels"])
    f.menu["Copy labels"]()
    f.menu = nil
    f.page.list:click("Shelves")
    f.page.more.click()
    f.menu["Paste labels"]()
    assert(table.concat(f.labels.k2, " ") == "native:Food")
    f.page.show.click()
    assert(f.shown.key == "k2")
end)

print(passed .. " storage page cases passed")
