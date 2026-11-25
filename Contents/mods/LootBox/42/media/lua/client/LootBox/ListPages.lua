-- Loot list, categories and storage. All three are "choose entries" screens, so
-- all three use the same picker.
local K = require "LootBox/UIKit"
local App = require "LootBox/App"
local Describe = require "LootBox/Describe"
local Picker = require "LootBox/Picker"

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
    page.message:set("Saved.", "good")
end

function Categories.remove(page)
    if not page.definition.id then return end
    local ok, err = App.deleteCategory(page.definition.id)
    if not ok then page.message:set(err, "bad"); return end
    Categories.edit(page, nil)
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
    K.place(page.name, x, 0, width)
    K.place(page.save, x + width - page.save.width, body.height - K.ROW)
    K.place(page.remove, x, body.height - K.ROW)
    K.place(page.message, x + page.remove.width + K.GAP, body.height - K.ROW + 6, width - page.save.width - page.remove.width - 2 * K.GAP, K.LINE)
    page.picker:layout(x, K.ROW + K.GAP, width, body.height - 2 * (K.ROW + K.GAP))
end

-- Storage ------------------------------------------------------------------

function Storage.build(win, body)
    local page = { win = win, body = body }
    page.list = K.list(body, page, function(p, row) Storage.choose(p, row.container, row.key, row.labels) end)
    page.list.emptyText = "Label a container and sorting knows what goes in it. Right-click one, or open it and pick it here."
    page.title = K.label(body, "", "text")
    page.car = K.button(body, "Forget vehicle", page, function(p)
        local instance = app(p)
        instance.state.vehicle = nil
        instance:persist()
        Storage.refresh(p)
    end, "ghost")
    page.picker = Picker.new(body, { owner = page, onlyCategories = true, chosenTitle = "Belongs in here", emptyText = "Nothing is sorted into this container yet.",
        changed = function(p, selection)
            local instance = app(p)
            if not instance or not p.container then return end
            local ok, err = instance:setLabels(p.container, selection.ids)
            if not ok then p.title:set(tostring(err), "bad") end
            Storage.refresh(p)
        end })
    return page
end

function Storage.refresh(page)
    local instance = app(page)
    local rows = {}
    if instance then
        local PlanPage = require "LootBox/PlanPage"
        local open, names, here = PlanPage.openContainers(page.win.playerIndex), nil, {}
        names = PlanPage.numbered(open)
        for index, container in ipairs(open) do
            local key = container:getType() ~= "floor" and instance.world:key(container)
            if key then
                here[key] = true
                local labels = instance:labels(container)
                rows[#rows + 1] = { title = names[index], sub = #labels > 0 and Storage.names(labels) or "No labels", container = container, key = key,
                    labels = labels, current = key == page.key, subTone = #labels > 0 and "info" or "faint" }
            end
        end
        if #rows > 0 then table.insert(rows, 1, { heading = true, title = "Open right now" }) end
        local others = {}
        for _, entry in ipairs(instance.world:labelledContainers()) do
            if not here[entry.key] then
                local at = entry.point and (entry.point.x .. ", " .. entry.point.y .. (entry.point.z ~= 0 and (", floor " .. entry.point.z) or ""))
                others[#others + 1] = { title = tostring(entry.name or "Container"), sub = Storage.names(entry.labels), subTone = "info", right = at,
                    container = entry.container, key = entry.key, labels = entry.labels, current = entry.key == page.key }
            end
        end
        if #others > 0 then
            rows[#rows + 1] = { heading = true, title = "Labelled elsewhere", right = tostring(#others) }
            for _, row in ipairs(others) do rows[#rows + 1] = row end
        end
        local vehicle = instance.state.vehicle
        page.car:setVisible(vehicle ~= nil)
        if vehicle then page.car:setTitle("Forget my vehicle"); page.car:setWidth(K.width(page.car.title) + 2 * K.PAD) end
    else page.car:setVisible(false) end
    page.list:fill(rows, true)
end

function Storage.names(ids)
    local names = {}
    for _, id in ipairs(ids or {}) do names[#names + 1] = App.categoryName(id) end
    return table.concat(names, ", ")
end

function Storage.choose(page, container, key, labels)
    page.container, page.key = container, key
    if container then
        page.title:set(Describe.container(container), "text")
        page.picker:setSelection({ ids = listOf(labels), types = {} })
    elseif key then
        page.title:set("Not loaded. Go near it to change its labels.", "dim")
        page.picker:setSelection({ ids = listOf(labels), types = {} }, true)
    else
        page.title:set("Choose a container on the left.", "dim")
        page.picker:setSelection({ ids = {}, types = {} }, true)
    end
    Storage.refresh(page)
end

function Storage.opened(page, context)
    local instance = app(page)
    page.picker:setVisible(instance ~= nil)
    if not instance then
        page.title:set("")
        page.list.emptyText = "Enter a game to label storage."
        page.list:fill({})
        page.car:setVisible(false)
        return
    end
    local container = context and context.container
    if container then
        context.container = nil
        Storage.choose(page, container, instance.world:key(container), instance:labels(container))
    elseif page.container and instance.world:key(page.container) == page.key then
        Storage.choose(page, page.container, page.key, instance:labels(page.container))
    else Storage.choose(page, nil) end
end

function Storage.layout(page)
    local body, left = page.body, math.floor(page.body.width * 0.34)
    K.place(page.list, 0, 0, left, body.height - (page.car:isVisible() and (K.ROW + K.GAP) or 0))
    K.place(page.car, 0, body.height - K.ROW)
    local x, width = left + K.GAP, body.width - left - K.GAP
    K.place(page.title, x, 5)
    page.picker:layout(x, K.ROW, width, body.height - K.ROW)
end

return { Loot = Loot, Categories = Categories, Storage = Storage }
