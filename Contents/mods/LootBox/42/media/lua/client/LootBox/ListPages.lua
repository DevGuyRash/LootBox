-- Loot list, categories and storage. All three are "choose entries" screens, so
-- all three use the same picker.
local K = require "LootBox/UIKit"
local App = require "LootBox/App"
local Describe = require "LootBox/Describe"
local Facts = require "LootBox/Facts"
local Labels = require "LootBox/Labels"
local Picker = require "LootBox/Picker"
local StorageMenu = require "LootBox/StorageMenu"
local View = require "LootBox/StorageView"

local Loot = { id = "loot", title = "Loot list" }
local Categories = { id = "categories", title = "Categories" }
local Storage = { id = "storage", title = "Storage" }

local function app(page) return getSpecificPlayer(page.win.playerIndex) and App.get(page.win.playerIndex) or nil end

-- Loot list ----------------------------------------------------------------

function Loot.build(win, body)
    local page = { win = win, body = body }
    page.hint = K.text(body, "Things to pick up whenever you loot. Right-click any item to add or remove it here.", "dim")
    page.picker = Picker.new(body, { owner = page, chosenTitle = "On my loot list", emptyText = "Nothing yet. Add categories or items from the left.",
        changed = function(p, selection)
            local instance = app(p)
            if instance then instance:setChecklist({ ids = selection.ids, types = selection.types }) end
        end })
    page.empty = K.text(body, "The loot list belongs to a character. Enter a game to edit it.", "dim")
    return page
end

function Loot.opened(page)
    local instance = app(page)
    page.picker:setVisible(instance ~= nil)
    page.empty:setVisible(instance == nil)
    if instance then
        local list = instance:getChecklist()
        page.picker:setSelection({ ids = list.ids, types = list.types })
    end
end

function Loot.layout(page)
    K.place(page.hint, 0, 4, page.body.width, K.LINE)
    K.place(page.empty, 0, K.ROW + K.GAP, page.body.width, K.LINE)
    page.picker:layout(0, K.ROW, page.body.width, page.body.height - K.ROW)
end

-- Categories ---------------------------------------------------------------

function Categories.build(win, body)
    local page = { win = win, body = body, definition = { types = {}, includes = {} } }
    page.list = K.list(body, page, function(p, row) Categories.edit(p, row.definition) end)
    page.list.emptyText = "Group items your own way. A category can hold items, game categories, and your other categories."
    page.add = K.button(body, "New category", page, function(p) Categories.edit(p, nil); p.name:focus() end, "plain")
    page.name = K.entry(body, "Category name")
    page.save = K.button(body, "Save", page, Categories.save, "primary")
    page.remove = K.button(body, "Delete", page, Categories.remove, "danger")
    page.message = K.text(body, "", "dim")
    page.picker = Picker.new(body, { owner = page, chosenTitle = "In this category", changed = function(p) Categories.count(p) end })
    return page
end

local function listOf(values) local result = {}; for index, value in ipairs(values or {}) do result[index] = value end; return result end

function Categories.refresh(page)
    local rows = {}
    for _, definition in ipairs(App.customCategories()) do
        rows[#rows + 1] = { title = definition.name, definition = definition, current = definition.id == page.definition.id,
            right = tostring(#definition.types + #definition.includes), tone = "info" }
    end
    page.list:fill(rows, true)
end

function Categories.edit(page, definition)
    page.definition = definition and { id = definition.id, name = definition.name, types = listOf(definition.types), includes = listOf(definition.includes) }
        or { types = {}, includes = {} }
    if not definition and page.seed then table.insert(page.definition.types, page.seed); page.seed = nil end
    page.name:setText(page.definition.name or "")
    page.remove:setVisible(page.definition.id ~= nil)
    page.message:set("")
    page.picker.options.exclude = page.definition.id
    page.picker:setSelection({ ids = page.definition.includes, types = page.definition.types })
    Categories.refresh(page)
    Categories.count(page)
end

function Categories.count(page)
    local total = #page.definition.types
    if #page.definition.includes > 0 then
        page.message:set(total > 0 and (total .. " items, plus everything in the included categories.") or "Everything in the included categories.", "dim")
    else page.message:set(total == 0 and "" or (total .. (total == 1 and " item." or " items.")), "dim") end
end

function Categories.save(page)
    local id, err = App.saveCategory({ id = page.definition.id, name = page.name:getText(), types = page.definition.types, includes = page.definition.includes })
    if not id then page.message:set(err, "bad"); return end
    for _, definition in ipairs(App.customCategories()) do if definition.id == id then Categories.edit(page, definition) end end
    if getSpecificPlayer(page.win.playerIndex) then View.refresh(page.win.playerIndex) end
    page.message:set("Saved.", "good")
end

function Categories.remove(page)
    if not page.definition.id then return end
    local ok, err = App.deleteCategory(page.definition.id)
    if not ok then page.message:set(err, "bad"); return end
    Categories.edit(page, nil)
    if getSpecificPlayer(page.win.playerIndex) then View.refresh(page.win.playerIndex) end
    page.message:set("Deleted, and removed wherever it was used.", "dim")
end

function Categories.opened(page, context)
    if context and context.type then
        page.seed = context.type
        context.type = nil
        Categories.edit(page, nil)
    elseif context and context.category then
        for _, definition in ipairs(App.customCategories()) do if definition.id == context.category then Categories.edit(page, definition) end end
        context.category = nil
    elseif not page.shown then
        Categories.edit(page, App.customCategories()[1])
    else Categories.refresh(page); page.picker:refresh(true) end
    page.shown = true
end

function Categories.layout(page)
    local body, left = page.body, math.floor(page.body.width * 0.26)
    K.place(page.list, 0, 0, left, body.height - K.ROW - K.GAP)
    K.place(page.add, 0, body.height - K.ROW, left)
    local x, width = left + K.GAP, body.width - left - K.GAP
    K.place(page.name, x, 2, width)
    K.place(page.save, x + width - page.save.width, body.height - K.ROW)
    K.place(page.remove, x, body.height - K.ROW)
    K.place(page.message, x + page.remove.width + K.GAP, body.height - K.ROW + 6, width - page.save.width - page.remove.width - 2 * K.GAP, K.LINE)
    page.picker:layout(x, K.ROW + K.GAP, width, body.height - 2 * (K.ROW + K.GAP))
end

-- Storage ------------------------------------------------------------------

local CHECK_MS = 1000

function Storage.build(win, body)
    local page = { win = win, body = body, orders = {} }
    page.list = K.list(body, page, function(p, row) Storage.choose(p, row.container, row.key) end)
    page.list.emptyText = "Label a container and LootBox knows what goes in it. Right-click one, or open it and pick it here."
    page.car = K.button(body, "Forget vehicle", page, function(p)
        local instance = app(p)
        instance.state.vehicle = nil
        instance:persist()
        Storage.refresh(p)
    end, "ghost")
    page.title = K.label(body, "", "dim")
    page.name = K.entry(body, "Name")
    page.name.onCommandEntered = function() K.unfocus(win); Storage.saveName(page) end
    page.show = K.button(body, "Show me", page, Storage.showMe, "plain", "Points the way to it.")
    page.more = K.button(body, "More...", page, Storage.menu, "ghost")
    page.fill = K.label(body, "When to fill it", "dim")
    for _, order in ipairs(StorageMenu.orders) do
        local button = K.button(body, order.title, page, function(p) Storage.change(p, "setStorage", { order = order.id }) end, "ghost", order.tip)
        button.order = order.id
        page.orders[#page.orders + 1] = button
    end
    page.rest = K.toggle(body, "Anything else", false, page, function(p) Storage.saveLabels(p) end, "Takes what no other storage is labelled for.")
    page.picker = Picker.new(body, { owner = page, chosenTitle = "Belongs in here", emptyText = "Nothing is put away in here yet.",
        changed = function(p) Storage.saveLabels(p) end })
    page.parts = { page.name, page.show, page.more, page.fill, page.rest, page.picker }
    for _, button in ipairs(page.orders) do page.parts[#page.parts + 1] = button end
    return page
end

local function target(page) return page.container or page.key end

-- The entry this page is about, or a plain one for a container without labels.
local function chosen(page, instance)
    for _, entry in ipairs(instance.world:storages()) do if entry.key == page.key then return entry end end
    if not page.container then return nil end
    local square = instance.world:square(page.container)
    return { key = page.key, container = page.container, name = Describe.container(page.container), tiles = 0,
        kind = page.container:getContainingItem() and Describe.container(page.container) or instance.world.plainName(page.container), nameable = page.container:getContainingItem() == nil, carried = instance.world:owns(page.container),
        point = square and { x = square:getX(), y = square:getY(), z = square:getZ() } }
end

function Storage.change(page, method, value)
    local instance = app(page)
    -- Clicking the picker takes the focus from a name that was just typed.
    Storage.saveName(page)
    if not instance or not page.key then return end
    local ok, err = instance[method](instance, target(page), value)
    if ok then View.refresh(page.win.playerIndex) end
    Storage.load(page, true)
    if not ok then page.title:set(tostring(err), "bad") end
end

function Storage.saveLabels(page) Storage.change(page, "setLabels", Labels.join(page.picker.selection, page.rest.on)) end

function Storage.saveName(page)
    local text = page.name:getText()
    if not page.key or not page.nameable or text == page.saved then return end
    page.saved = text
    Storage.change(page, "setStorage", { name = text })
end

function Storage.showMe(page)
    local instance = app(page)
    local entry = instance and page.key and chosen(page, instance)
    if not entry then return end
    local ok, text = View.show(page.win.playerIndex, entry)
    page.title:set(text, ok and "good" or "warn")
end

function Storage.menu(page)
    local instance = app(page)
    if not instance or not page.key then return end
    Storage.saveName(page)
    local rows, labels = StorageMenu.changes(instance, target(page), page.container)
    local copy = #StorageMenu.copyable(labels) > 0
    if #rows == 0 and not copy then page.title:set("Nothing to copy or paste yet.", "dim"); return end
    local menu = K.menu(page.win.playerIndex, page.more)
    if not menu then return end
    if copy then K.option(menu, "Copy labels", function() StorageMenu.copy(labels) end) end
    for _, entry in ipairs(rows) do
        K.option(menu, entry.title, function()
            if entry.clear then Storage.change(page, "setStorage", { order = "usual" }) end
            Storage.change(page, "setLabels", entry.labels)
        end, nil, entry.tip)
    end
end

function Storage.refresh(page)
    local instance = app(page)
    local rows = {}
    if instance then
        local PlanPage = require "LootBox/PlanPage"
        local session, open, here = { player = instance.player, world = instance.world }, {}, {}
        for _, container in ipairs(PlanPage.openContainers(page.win.playerIndex)) do
            if StorageMenu.labelable(session, container) then open[#open + 1] = container end
        end
        local names = PlanPage.numbered(open)
        for index, container in ipairs(open) do
            local key, labels = instance.world:key(container), instance:labels(container)
            here[key] = true
            rows[#rows + 1] = { title = names[index], sub = #labels > 0 and Describe.labels(labels, App.category, 4) or "No labels",
                container = container, key = key, current = key == page.key, subTone = #labels > 0 and "info" or "faint" }
        end
        if #rows > 0 then table.insert(rows, 1, { heading = true, title = "Open right now" }) end
        local others = {}
        for _, entry in ipairs(instance.world:storages()) do
            if not here[entry.key] then
                local away = entry.carried and "carried" or entry.tiles == math.huge and "" or math.floor(entry.tiles + 0.5) .. " tiles"
                others[#others + 1] = { title = entry.name, sub = #entry.labels > 0 and Describe.labels(entry.labels, App.category, 4) or "No labels",
                    subTone = #entry.labels > 0 and "info" or "faint", right = away, rightTone = entry.container and "dim" or "faint",
                    container = entry.container, key = entry.key, current = entry.key == page.key }
            end
        end
        if #others > 0 then
            rows[#rows + 1] = { heading = true, title = "My other storage", right = tostring(#others) }
            for _, row in ipairs(others) do rows[#rows + 1] = row end
        end
        local vehicle = instance.state.vehicle
        page.car:setVisible(vehicle ~= nil)
        if vehicle then page.car:setTitle("Forget my vehicle"); page.car:setWidth(K.width(page.car.title) + 2 * K.PAD) end
    else page.car:setVisible(false) end
    page.list:fill(rows, true)
end

-- Shows what is saved for the chosen container. keep leaves the lists where they are scrolled.
function Storage.load(page, keep)
    local instance = app(page)
    local entry = instance and page.key and chosen(page, instance)
    -- Out of sight and without anything saved, there is nothing left to show.
    if not entry then page.container, page.key = nil, nil end
    page.nameable = entry ~= nil and entry ~= false and entry.nameable == true
    for _, part in ipairs(page.parts) do part:setVisible(entry and true or false) end
    if not entry then
        page.title:set(instance and "Choose a container on the left." or "", "dim")
        if instance then Storage.refresh(page) end
        return
    end
    page.revision = instance.storageRevision
    local selection, rest = Labels.split(instance:labels(target(page)))
    page.picker:setSelection(selection, keep)
    page.rest.on = rest
    local order = instance:storageDetails(target(page)).order or "usual"
    for _, button in ipairs(page.orders) do button:setTone(button.order == order and "primary" or "ghost") end
    page.name:setEditable(page.nameable)
    page.name:setClearButton(page.nameable)
    local name = entry.given or page.container and instance.world:givenName(page.container)
        or entry.key:sub(1, 4) == "bag:" and entry.name or ""
    if not page.name:isFocused() then page.name:setText(name) end
    page.saved = name
    local away = entry.carried and "carried" or entry.tiles and entry.tiles < math.huge and Facts.awayText(entry.tiles)
    local why = not page.nameable and (entry.key:sub(1, 4) == "bag:" and ". Rename the bag from its own menu." or ". Go near it to rename it.") or ""
    page.title:set(entry.kind .. (away and ", " .. away or "") .. why, "dim")
    Storage.refresh(page)
end

function Storage.choose(page, container, key)
    Storage.saveName(page)
    K.unfocus(page.win)
    page.container, page.key = container, key
    Storage.load(page)
end

function Storage.opened(page, context)
    local instance = app(page)
    if page.key then Storage.saveName(page) end
    if not instance then
        page.container, page.key = nil, nil
        page.list.emptyText = "Enter a game to label storage."
        page.list:fill({})
        page.car:setVisible(false)
    else
        local container = context and context.container
        if container then
            context.container = nil
            page.container, page.key = container, instance.world:key(container)
        elseif page.container and instance.world:key(page.container) ~= page.key then page.container, page.key = nil, nil end
    end
    Storage.load(page)
end

-- A name is saved when the player is done with it, not at every letter. Labels changed elsewhere,
-- and a container that went out of sight, show within a second.
function Storage.tick(page)
    local instance = app(page)
    if not instance or not page.key then return end
    if not page.name:isFocused() then Storage.saveName(page) end
    local stamp = getTimestampMs()
    if page.checked and stamp >= page.checked and stamp - page.checked < CHECK_MS then return end
    page.checked = stamp
    local lost = page.container and not instance.world:valid(page.container)
    if lost then page.container = nil end
    local entry = not page.container and chosen(page, instance)
    if entry and entry.container then page.container, lost = entry.container, true end
    if lost or page.revision ~= instance.storageRevision then Storage.load(page, true) end
end

function Storage.layout(page)
    local body, left = page.body, math.floor(page.body.width * 0.3)
    K.place(page.list, 0, 0, left, body.height - (page.car:isVisible() and (K.ROW + K.GAP) or 0))
    K.place(page.car, 0, body.height - K.ROW)
    local x, width = left + K.GAP, body.width - left - K.GAP
    K.place(page.title, x, 5)
    local y = K.ROW
    K.place(page.more, x + width - page.more.width, y)
    K.place(page.show, x + width - page.more.width - K.GAP - page.show.width, y)
    K.place(page.name, x, y + math.floor((K.ROW - K.ENTRY) / 2), width - page.more.width - page.show.width - 2 * K.GAP)
    y = y + K.ROW + 4
    K.place(page.fill, x, y + 5)
    local at = x + K.width(page.fill.name) + K.PAD
    for _, button in ipairs(page.orders) do
        K.place(button, at, y)
        at = at + button.width + 2
    end
    K.place(page.rest, x + width - page.rest.width, y)
    y = y + K.ROW + K.GAP
    page.picker:layout(x, y, width, body.height - y)
end

return { Loot = Loot, Categories = Categories, Storage = Storage }
