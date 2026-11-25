-- Plan a job: what, from where, to where, with a live look at what would move.
require "ISUI/ISTextBox"
local K = require "LootBox/UIKit"
local App = require "LootBox/App"
local Describe = require "LootBox/Describe"
local PlanList = require "LootBox/PlanList"
local AreaPicker = require "LootBox/AreaPicker"
local Log = require "LootBox/Log"

local Page = { id = "plan", title = "Plan a job" }

local slow = { building = true, area = true }

local function blank()
    return { scope = "inventory", includeInventory = false, includeBags = true, filter = { ids = {}, types = {}, all = false },
        sourceLabels = {}, destination = { kind = "labels", labels = {} } }
end

-- Native references stay references; only the player's own choices are copied.
local function copy(request)
    local function list(values) local result = {}; for index, value in ipairs(values or {}) do result[index] = value end; return result end
    local result = {}
    for key, value in pairs(request) do result[key] = value end
    local filter, destination = request.filter or {}, request.destination or {}
    result.filter = { all = filter.all == true, ids = list(filter.ids), types = list(filter.types) }
    result.destination = {}
    for key, value in pairs(destination) do result.destination[key] = value end
    result.destination.labels = list(destination.labels)
    result.sourceLabels = list(request.sourceLabels)
    result.includeBags = request.includeBags ~= false
    result.scope = request.scope or "inventory"
    return result
end

local function indexOf(list, value)
    for index, entry in ipairs(list or {}) do if entry == value then return index end end
end

local function toggle(list, value)
    local index = indexOf(list, value)
    if index then table.remove(list, index) else list[#list + 1] = value end
end

function Page.app(win) return getSpecificPlayer(win.playerIndex) and App.get(win.playerIndex) or nil end

function Page.build(win, body)
    local page = { win = win, body = body }
    page.what = K.card(body, "WHAT", page, Page.whatMenu)
    page.from = K.card(body, "FROM", page, Page.fromMenu)
    page.to = K.card(body, "TO", page, Page.toMenu)
    page.bags = K.toggle(body, "Look inside bags", true, page, function(p, on) p.request.includeBags = on; Page.changed(p) end)
    page.carried = K.toggle(body, "Also what I carry", false, page, function(p, on) p.request.includeInventory = on; Page.changed(p) end)
    page.presets = K.button(body, "Presets", page, Page.presetMenu, "ghost", "Save this job, or load one you saved.")
    page.summary = K.label(body, "", "dim")
    page.rows = K.list(body, page)
    page.message = K.text(body, "", "bad")
    page.look = K.button(body, "Look now", page, function(p) Page.refresh(p, true) end, "plain", "Check what would move, without starting.")
    page.start = K.button(body, "Start", page, Page.start, "primary")
    page.request = blank()
    return page
end

function Page.layout(page)
    local body, gap = page.body, K.GAP
    local card = math.floor((body.width - 2 * gap) / 3)
    for index, widget in ipairs({ page.what, page.from, page.to }) do K.place(widget, (index - 1) * (card + gap), 0, card) end
    local y = page.what.height + gap
    K.place(page.bags, 0, y)
    K.place(page.carried, page.bags.width + gap, y)
    K.place(page.presets, body.width - page.presets.width, y)
    y = y + K.ROW + gap
    local footer = body.height - K.ROW
    K.place(page.message, 0, footer + 4, body.width - page.start.width - page.look.width - 3 * gap, 2 * K.LINE)
    K.place(page.start, body.width - page.start.width, footer)
    K.place(page.look, body.width - page.start.width - gap - page.look.width, footer)
    K.place(page.summary, 0, y)
    K.place(page.rows, 0, y + K.LINE + 6, body.width, footer - y - K.LINE - 6 - gap)
end

function Page.opened(page, context)
    local app = Page.app(page.win)
    page.context = context or page.context or {}
    if page.context.request then
        page.request = copy(page.context.request)
        page.context.request, page.presetId = nil, nil
    elseif app and not page.loaded then
        local last = app:lastSetup(page.context)
        if last then page.request = last end
    end
    page.loaded = true
    page.message:set(page.context.message or "")
    page.context.message = nil
    Page.changed(page)
end

local function chosen(request)
    local f = request.filter
    return f.all or #f.ids > 0 or #f.types > 0
end

-- Cards ------------------------------------------------------------------

function Page.paint(page)
    local request, filter = page.request, page.request.filter
    local count = #filter.ids + #filter.types
    page.what:set(filter.all and "Everything" or (count == 0 and "Choose..." or Describe.what(filter, App.category)),
        filter.all and "Protected items always stay" or (count == 0 and "Categories or items" or PlanList.plural(count, "selection")),
        not chosen(request) and "accent" or "text")
    local matching = request.destination.kind == "matching"
    local from = matching and "What I carry" or Describe.from(request)
    from = from:sub(1, 1):upper() .. from:sub(2)
    local detail = ""
    if request.scope == "area" then
        local a = request.area
        detail = a and (a.x2 - a.x1 + 1) .. " x " .. (a.y2 - a.y1 + 1) .. " tiles, floor " .. a.z or "Not marked yet"
    elseif request.scope == "labeled" then
        local names = {}
        for _, id in ipairs(request.sourceLabels or {}) do names[#names + 1] = App.categoryName(id) end
        detail = #names > 0 and ("for " .. table.concat(names, ", ")) or "Choose a label"
    elseif request.scope == "lootPane" then detail = PlanList.plural(#(request.sourceContainers or {}), "container") end
    page.from:set(from, detail)
    local to = Describe.to(request)
    to = to:sub(1, 1):upper() .. to:sub(2)
    local toDetail = ({ inventory = "Bags first, then main inventory", labels = "Storage that has matching labels", trash = "Deleted for good",
        vehicle = "Trunk first, then seats", matching = "Containers that already hold the same items" })[request.destination.kind] or ""
    if request.destination.kind == "labels" and #(request.destination.labels or {}) > 0 then
        local names = {}
        for _, id in ipairs(request.destination.labels) do names[#names + 1] = App.categoryName(id) end
        toDetail = "Only storage for " .. table.concat(names, ", ")
    end
    page.to:set(to, toDetail, request.destination.kind == "trash" and "bad" or "text")
    page.bags.on, page.carried.on = request.includeBags ~= false, request.includeInventory == true
    page.bags:setVisible(not matching and request.scope ~= "lootPane")
    page.carried:setVisible(not matching and request.scope ~= "inventory" and request.scope ~= "lootPane" and request.destination.kind ~= "inventory")
    local trash = request.destination.kind == "trash"
    page.start:setTitle(trash and "Throw away" or "Start")
    page.start:setWidth(math.max(90, K.width(page.start.title) + 3 * K.PAD))
    page.start:setTone(trash and "danger" or "primary")
    Page.layout(page)
end

function Page.changed(page)
    Page.paint(page)
    page.plan, page.dueAt = nil, nil
    page.start:setEnable(chosen(page.request))
    if not Page.app(page.win) then
        page.summary:set("")
        page.rows.emptyText = "Enter a game to plan a job. The loot list and categories work here already."
        page.rows:fill({})
        page.start:setEnable(false); page.look:setEnable(false)
        return
    end
    page.look:setEnable(chosen(page.request))
    if not chosen(page.request) then
        page.summary:set("")
        page.rows.emptyText = "Choose what to move."
        page.rows:fill({})
    elseif slow[page.request.scope] and not (page.request.scope == "area" and not page.request.area) then
        page.summary:set("")
        page.rows.emptyText = "This covers a lot of ground. Press Look now for a preview, or just start."
        page.rows:fill({})
    else
        page.dueAt = getTimestampMs() + 200
    end
end

function Page.tick(page)
    if page.dueAt and getTimestampMs() >= page.dueAt then Page.refresh(page) end
end

function Page.ready(page)
    local request = page.request
    if not chosen(request) then return nil, "Choose what to move." end
    if request.scope == "area" and not request.area then return nil, "Mark the area first." end
    if request.scope == "labeled" and #(request.sourceLabels or {}) == 0 then return nil, "Choose which labelled containers to use." end
    if request.scope == "container" and not request.sourceContainer then return nil, "Right-click the container to take from, or choose another source." end
    if request.destination.kind == "container" and not request.destination.ref then return nil, "Choose a destination container." end
    if request.destination.kind == "floor" then
        local player = getSpecificPlayer(page.win.playerIndex)
        request.destination.ref = request.destination.ref or page.context.square or (player and player:getCurrentSquare())
    end
    if request.scope == "lootPane" then
        local sources, err = Page.app(page.win).world:smartLootSources(nil, true)
        if not sources then return nil, err end
        request.sourceContainers = sources
    end
    return true
end

function Page.refresh(page, asked)
    page.dueAt = nil
    local app = Page.app(page.win)
    local ok, err = Page.ready(page)
    local plan
    if ok then plan, err = app:preview(page.request) end
    page.plan = plan
    if not plan then
        page.summary:set("")
        page.rows.emptyText = tostring(err or "Nothing to show.")
        page.rows:fill({})
        return
    end
    page.message:set("")
    page.summary:set(PlanList.summary(plan))
    page.rows.emptyText = "Nothing here matches."
    page.rows:fill(PlanList.rows(plan, { tone = page.request.destination.kind == "trash" and "bad" or nil }))
    page.start:setEnable(#plan.moves > 0 or (plan.pending or 0) > 0)
    if asked then Log.trace(nil, "plan-look", "request", Log.request(page.request), "moves", #plan.moves, "staying", #plan.skipped) end
end

function Page.start(page)
    local app = Page.app(page.win)
    local ok, err = Page.ready(page)
    if not ok then page.message:set(err, "bad"); return end
    local id = Log.intent("window.plan", Describe.title(page.request, App.category), app.player, "request", Log.request(page.request))
    page.request.interaction = id
    local plan
    plan, err = app:preview(page.request)
    if plan and #plan.moves == 0 and (plan.pending or 0) == 0 then
        Page.refresh(page)
        page.message:set("There is nothing to move right now.", "warn")
        return
    end
    if plan then ok, err = app:start(plan, { interaction = id }) else ok = nil end
    if not ok then page.message:set(tostring(err), "bad"); return end
    app:rememberSetup(page.request)
    page.win:close()
    require("LootBox/UI").showJob(page.win.playerIndex)
end

-- Menus ------------------------------------------------------------------

local function checked(menu, option, on) if option and on then menu:setOptionChecked(option, true) end end

-- Long category lists become a few alphabetical submenus.
function Page.categoryMenu(menu, categories, isOn, action)
    local size = 14
    if #categories <= size + 4 then
        for _, category in ipairs(categories) do
            checked(menu, K.option(menu, category.name, function() action(category.id) end), isOn(category.id))
        end
        return
    end
    for first = 1, #categories, size do
        local last = math.min(#categories, first + size - 1)
        local a, b = categories[first].name:sub(1, 3), categories[last].name:sub(1, 3)
        local child = K.submenu(menu, a .. " - " .. b)
        for index = first, last do
            local category = categories[index]
            checked(child, K.option(child, category.name, function() action(category.id) end), isOn(category.id))
        end
    end
end

function Page.whatMenu(page)
    local menu = K.menu(page.win.playerIndex, page.what)
    local filter, app = page.request.filter, Page.app(page.win)
    checked(menu, K.option(menu, "Everything", function()
        filter.all = not filter.all
        Page.changed(page)
    end), filter.all)
    local list = app and app:getChecklist()
    if list and #list.ids + #list.types > 0 then
        K.option(menu, "My loot list (" .. (#list.ids + #list.types) .. ")", function()
            page.request.filter = { ids = list.ids, types = list.types, all = false }
            Page.changed(page)
        end)
    end
    local catalog = App.catalog()
    local custom, native = {}, {}
    for _, category in ipairs(catalog and catalog.categories or {}) do
        local into = category.kind == "custom" and custom or native
        into[#into + 1] = category
    end
    local function pick(id)
        filter.all = false
        toggle(filter.ids, id)
        Page.changed(page)
    end
    local function on(id) return not filter.all and indexOf(filter.ids, id) ~= nil end
    if #custom > 0 then Page.categoryMenu(K.submenu(menu, "My categories"), custom, on, pick) end
    Page.categoryMenu(K.submenu(menu, "Game categories"), native, on, pick)
    K.option(menu, "Pick several...", function()
        page.win:pick("What to move", filter, function(selection)
            page.request.filter = { ids = selection.ids, types = selection.types, all = false }
            Page.changed(page)
        end)
    end)
    if chosen(page.request) then K.option(menu, "Clear", function() page.request.filter = { ids = {}, types = {}, all = false }; Page.changed(page) end) end
end

local function openContainers(playerIndex)
    local result, seen = {}, {}
    local loot = getPlayerLoot and getPlayerLoot(playerIndex)
    for _, button in ipairs(loot and loot.backpacks or {}) do
        local container = button.inventory
        if container and not seen[container] then seen[container] = true; result[#result + 1] = container end
    end
    return result
end
Page.openContainers = openContainers

local function carriedContainers(playerIndex)
    local result = {}
    local page = getPlayerInventory and getPlayerInventory(playerIndex)
    for _, button in ipairs(page and page.backpacks or {}) do if button.inventory then result[#result + 1] = button.inventory end end
    return result
end

local function numbered(containers)
    local names, counts, seen = {}, {}, {}
    for index, container in ipairs(containers) do
        local name = Describe.container(container)
        name = name:sub(1, 1):upper() .. name:sub(2)
        names[index] = name
        counts[name] = (counts[name] or 0) + 1
    end
    for index, name in ipairs(names) do
        if counts[name] > 1 then seen[name] = (seen[name] or 0) + 1; names[index] = name .. " " .. seen[name] end
    end
    return names
end
Page.numbered = numbered

function Page.fromMenu(page)
    local menu = K.menu(page.win.playerIndex, page.from)
    local request, app = page.request, Page.app(page.win)
    if not app then K.option(menu, "Enter a game first"); return end
    local player = app.player
    local function scope(name, extra)
        return function()
            request.scope = name
            if request.destination.kind == "matching" and name ~= "inventory" then request.destination = { kind = "inventory", labels = {} } end
            if extra then extra() end
            Page.changed(page)
        end
    end
    checked(menu, K.option(menu, "What I carry", scope("inventory")), request.scope == "inventory")
    local here = openContainers(page.win.playerIndex)
    if #here > 0 then
        local child = K.submenu(menu, "Containers here")
        if #here > 1 then checked(child, K.option(child, "All of them", scope("lootPane")), request.scope == "lootPane") end
        for index, name in ipairs(numbered(here)) do
            local container = here[index]
            if container:getType() ~= "floor" then
                checked(child, K.option(child, name, scope("container", function() request.sourceContainer = container end)),
                    request.scope == "container" and request.sourceContainer == container)
            end
        end
    end
    checked(menu, K.option(menu, "Within reach", scope("reach")), request.scope == "reach")
    local square = player:getCurrentSquare()
    if square and square:getRoom() then checked(menu, K.option(menu, "This room", scope("room")), request.scope == "room") end
    if square and square:getBuilding() then checked(menu, K.option(menu, "This building", scope("building")), request.scope == "building") end
    K.option(menu, request.area and "Mark a different area..." or "Mark an area...", function()
        page.win:setVisible(false)
        local picker, err = AreaPicker.start(page.win.playerIndex, function(area)
            if page.win.closed then return end
            if area then request.scope, request.area = "area", area end
            page.win:setVisible(true); page.win:bringToTop()
            Page.changed(page)
        end)
        if not picker then page.win:setVisible(true); page.message:set(err, "bad") end
    end)
    if request.area and request.scope ~= "area" then K.option(menu, "The area I marked", scope("area")) end
    local used, seen = {}, {}
    for _, labels in pairs(app.state.containerLabels) do
        for _, id in ipairs(labels) do if not seen[id] then seen[id] = true; used[#used + 1] = { id = id, name = App.categoryName(id) } end end
    end
    if #used > 0 then
        table.sort(used, function(a, b) return a.name < b.name end)
        local child = K.submenu(menu, "Containers labelled")
        Page.categoryMenu(child, used, function(id) return request.scope == "labeled" and indexOf(request.sourceLabels, id) ~= nil end,
            function(id)
                if request.scope ~= "labeled" then request.scope, request.sourceLabels = "labeled", {} end
                toggle(request.sourceLabels, id)
                Page.changed(page)
            end)
    end
end

function Page.toMenu(page)
    local menu = K.menu(page.win.playerIndex, page.to)
    local request, app = page.request, Page.app(page.win)
    if not app then K.option(menu, "Enter a game first"); return end
    local destination = request.destination
    local function to(value)
        return function() value.labels = value.labels or {}; request.destination = value; Page.changed(page) end
    end
    if request.scope ~= "inventory" then
        checked(menu, K.option(menu, "My bags", to({ kind = "inventory" })), destination.kind == "inventory")
    end
    local carried = carriedContainers(page.win.playerIndex)
    if #carried > 0 then
        local child = K.submenu(menu, "One of my bags")
        for index, name in ipairs(numbered(carried)) do
            local container = carried[index]
            checked(child, K.option(child, name, to({ kind = "container", ref = container })), destination.kind == "container" and destination.ref == container)
        end
    end
    local here = openContainers(page.win.playerIndex)
    local names = numbered(here)
    local child
    for index, container in ipairs(here) do
        if container:getType() ~= "floor" and container ~= request.sourceContainer then
            child = child or K.submenu(menu, "A container here")
            checked(child, K.option(child, names[index], to({ kind = "container", ref = container })), destination.kind == "container" and destination.ref == container)
        end
    end
    if app:labelCount() > 0 then
        checked(menu, K.option(menu, "Where it belongs", to({ kind = "labels" }), nil, "Storage whose labels match each item."), destination.kind == "labels")
    end
    local match = K.submenu(menu, "Containers with the same items")
    checked(match, K.option(match, "All nearby", function() request.scope = "inventory"; to({ kind = "matching", mode = "nearby" })() end),
        destination.kind == "matching" and destination.mode == "nearby")
    checked(match, K.option(match, "Only the open one", function() request.scope = "inventory"; to({ kind = "matching", mode = "displayed" })() end),
        destination.kind == "matching" and destination.mode == "displayed")
    local vehicles = app:knownVehicles()
    if app.state.vehicle or #vehicles > 0 then
        local cars = K.submenu(menu, "A vehicle")
        if app.state.vehicle then checked(cars, K.option(cars, "My vehicle", to({ kind = "vehicle" })), destination.kind == "vehicle" and not destination.ref) end
        for _, vehicle in ipairs(vehicles) do
            checked(cars, K.option(cars, Describe.vehicle(vehicle), to({ kind = "vehicle", ref = vehicle })), destination.kind == "vehicle" and destination.ref == vehicle)
        end
    end
    checked(menu, K.option(menu, "The floor here", to({ kind = "floor" })), destination.kind == "floor")
    if app.world:hasKnownBins() then
        checked(menu, K.option(menu, "A trash can (deletes)", to({ kind = "trash" })), destination.kind == "trash")
    end
end

local function ask(page, title, text, done)
    local width, height = 320, 150
    local box = ISTextBox:new((getCore():getScreenWidth() - width) / 2, (getCore():getScreenHeight() - height) / 2, width, height, title, text or "",
        nil, function(_, button) if button.internal == "OK" then done(button.parent.entry:getText()) end end, page.win.playerIndex)
    box:initialise()
    box:addToUIManager()
    box:bringToTop()
    box.entry:focus()
end

function Page.presetMenu(page)
    local menu = K.menu(page.win.playerIndex, page.presets)
    local app = Page.app(page.win)
    if not app then K.option(menu, "Enter a game first"); return end
    local saved = app:getSetups()
    local current
    for _, preset in ipairs(saved.presets) do
        local id, name = preset.id, preset.name
        if id == page.presetId then current = preset end
        checked(menu, K.option(menu, name, function()
            local request, err = app:loadSetup(id, page.context)
            if not request then page.message:set(err, "bad"); return end
            page.request, page.presetId = request, id
            Page.changed(page)
        end), id == page.presetId)
    end
    K.option(menu, "Save as a preset...", function()
        ask(page, "Name this preset", "", function(name)
            local id, err = app:saveSetup(name, page.request)
            if id then page.presetId = id; page.message:set("Saved. It also appears when you right-click, where it fits.", "good") else page.message:set(err, "bad") end
        end)
    end)
    if current then
        K.option(menu, "Update " .. current.name, function()
            local id, err = app:saveSetup(current.name, page.request, current.id)
            page.message:set(id and "Preset updated." or err, id and "good" or "bad")
        end)
    end
    if #saved.presets > 0 then
        local child = K.submenu(menu, "Delete")
        for _, preset in ipairs(saved.presets) do
            local id = preset.id
            K.option(child, preset.name, function()
                app:deleteSetup(id)
                if page.presetId == id then page.presetId = nil end
                page.message:set("Preset deleted.", "dim")
            end)
        end
    end
end

return Page
