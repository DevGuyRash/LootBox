-- What belongs in a container, and where an item goes. The two halves of the
-- same question, asked from either end.
local App = require "LootBox/App"
local Catalog = require "LootBox/Catalog"
local Describe = require "LootBox/Describe"
local Labels = require "LootBox/Labels"
local Log = require "LootBox/Log"
local View = require "LootBox/StorageView"

local Menu = {}
local MAX_LABELS, MAX_OPEN, MAX_OTHER, MAX_CUSTOM, MAX_SINGLES = 5, 6, 4, 4, 20
-- Copied labels last until something else is copied.
local copied

local function call(object, method, ...)
    if not object then return nil end
    local ok, value = pcall(function(...) return object[method](object, ...) end, ...)
    if ok then return value end
end

-- Whether a container can be labelled at all.
function Menu.labelable(s, container)
    if not container or call(container, "getType") == "floor" or container == s.player:getInventory()
        or call(container, "isLockedToCharacter", s.player) == true then return false end
    local parent = call(container, "getParent")
    return not (parent and instanceof(parent, "IsoDeadBody")) and not s.world:isTrash(container) and s.world:key(container) ~= nil
end

-- An item has one place, so its mark is not copied to a second one.
function Menu.copyable(labels)
    local result = {}
    for _, id in ipairs(labels) do if not Labels.itemOf(id) then result[#result + 1] = id end end
    return result
end

function Menu.copy(labels)
    copied = Menu.copyable(labels)
    return true
end

-- What was copied and still exists, or nil.
function Menu.copied()
    local labels = {}
    for _, id in ipairs(copied or {}) do
        if Labels.direct(id) or id:match("^native:") or App.category(id) then labels[#labels + 1] = id end
    end
    return #labels > 0 and labels or nil
end

-- Adds labels to a list, each once. Returns nil when that adds nothing.
function Menu.merged(labels, extra)
    local result = {}
    for _, list in ipairs({ labels, extra or {} }) do
        for _, id in ipairs(list) do if not Labels.has(result, id) then result[#result + 1] = id end end
    end
    return #result > #labels and result or nil
end

-- The rows a container's menu and its page have in common: {title, labels, tip}.
function Menu.changes(app, target, container)
    local labels, rows = app:labels(target), {}
    local function add(title, extra)
        local merged = Menu.merged(labels, extra)
        if merged then rows[#rows + 1] = { title = title, labels = merged, tip = "Adds " .. Describe.labels(extra, App.category, 12) .. "." } end
    end
    if container then
        local types, categories = app.world:labelsInside(container)
        add("Label with the categories inside (" .. #categories .. ")", categories)
        add("Label with exactly these items (" .. #types .. ")", types)
    end
    add("Paste labels", Menu.copied())
    if #labels > 0 then rows[#rows + 1] = { title = "Clear labels", labels = {}, clear = true } end
    return rows, labels
end

Menu.orders = {
    { id = "usual", title = "As usual", tip = "Where the same thing already is, then the closest label, then the nearest." },
    { id = Labels.FIRST, title = "First", tip = "Before other storage for the same things." },
    { id = Labels.LAST, title = "Last", tip = "Only when the others are full." },
}

local function changed(s, ok, err)
    if ok then View.refresh(s.playerIndex) end
    return ok, err
end

-- Containers ---------------------------------------------------------------

function Menu.container(host, s, container, facts, tools)
    if not Menu.labelable(s, container) then return end
    local clicked = Log.container(container, s.player)
    local current, details = s.app:labels(container), s.app:storageDetails(container)
    local title = "Belongs here"
    if #current > 0 then title = title .. ": " .. Describe.labels(current, App.category, 1) end
    local child = host:sub("belongs", title)
    local shown = {}
    local function toggle(id)
        return tools.ask(s, "menu.label", "toggle " .. id, clicked, function() return changed(s, s.app:toggleLabel(container, id)) end)
    end
    for index, id in ipairs(current) do
        shown[id] = true
        if index <= MAX_LABELS or id == Labels.REST then child:check(id == Labels.REST and "all" or "label", App.categoryName(id), true, toggle(id)) end
    end
    local changes = Menu.changes(s.app, container, container)
    local function change(entry, icon)
        child:row(icon, entry.title, tools.ask(s, "menu.label", entry.title, clicked, function()
            if entry.clear then
                local ok, err = s.app:setStorage(container, { order = "usual" })
                if not ok then return nil, err end
            end
            return changed(s, s.app:setLabels(container, entry.labels))
        end), entry.tip)
    end
    for _, entry in ipairs(changes) do if entry.title:find("^Label with") then change(entry, "inside") end end
    local custom = 0
    for _, definition in ipairs(App.customCategories()) do
        if not shown[definition.id] and custom < MAX_CUSTOM then
            custom = custom + 1
            child:check("tag", definition.name, false, toggle(definition.id))
        end
    end
    if not shown[Labels.REST] then
        child:check("all", "Anything else", false, toggle(Labels.REST), "Takes what no other storage is labelled for.")
    end
    if #current > 0 then
        local order = child:sub("sort", "When to fill it")
        for _, entry in ipairs(Menu.orders) do
            order:check("sort", entry.title, (details.order or "usual") == entry.id, tools.ask(s, "menu.label", "fill " .. entry.id, clicked, function()
                return changed(s, s.app:setStorage(container, { order = entry.id }))
            end), entry.tip)
        end
    end
    if #Menu.copyable(current) > 0 then
        child:row("more", "Copy labels", tools.ask(s, "menu.label", "copy", clicked, function() return Menu.copy(s.app:labels(container)) end))
    end
    for _, entry in ipairs(changes) do if not entry.title:find("^Label with") then change(entry, entry.clear and "stop" or "put") end end
    child:row("more", "Name and more...", function() tools.ui().open(s.playerIndex, "storage", { container = container }) end)
end

-- Items ----------------------------------------------------------------------

-- What is open first, then known storage elsewhere, each with a way to look at it.
local function places(s, tools)
    if s.places then return s.places end
    local open, seen, others = {}, {}, {}
    for _, pane in ipairs({ "loot", "inventory" }) do
        for _, entry in ipairs(tools.openContainers(s.playerIndex)) do
            if entry.pane == pane and Menu.labelable(s, entry.container) then
                seen[s.world:key(entry.container)] = true
                open[#open + 1] = { container = entry.container, target = entry.container }
            end
        end
    end
    tools.nameAll(open)
    for _, storage in ipairs(s.world:glance().storages) do
        if not seen[storage.key] and not storage.carried then others[#others + 1] = { name = View.where(storage), target = storage.key, container = storage.container } end
    end
    s.places = { open = open, others = others }
    return s.places
end

local function highlight(option, s, container)
    local parent = container and container:getParent()
    if not option or not parent or not parent.setOutlineHighlight or instanceof(parent, "IsoPlayer") then return end
    option.onHighlightParams = {}
    option.onHighlight = function(_, _, on)
        parent:setOutlineHighlight(s.playerIndex, on == true)
        if on then
            local color = getCore():getWorldItemHighlightColor()
            parent:setOutlineHighlightCol(s.playerIndex, color:getR(), color:getG(), color:getB(), 1)
        end
    end
end

-- has(target) and set(target, on) say what a tick means.
local function placeRows(host, s, tools, item, has, set)
    local listed = places(s, tools)
    -- A key ring is no place for planks.
    local function takes(place)
        local container = place.container
        return not container or call(container, "isItemAllowed", item) ~= false and call(container, "isInside", item) ~= true
    end
    local function add(icon, place)
        local on = has(place.target)
        highlight(host:check(icon, place.name, on, function() set(place, not on) end), s, place.container)
    end
    local count = 0
    for _, place in ipairs(listed.open) do
        -- A ticked one is always listed, so that it can be unticked.
        if has(place.target) then add("put", place)
        elseif count < MAX_OPEN and takes(place) then count = count + 1; add("put", place) end
    end
    count = 0
    for _, place in ipairs(listed.others) do
        if has(place.target) then add("belongs", place)
        elseif count < MAX_OTHER and takes(place) then count = count + 1; add("belongs", place) end
    end
end

function Menu.hasLabels(s, target, ids)
    local labels = s.app:labels(target)
    for _, id in ipairs(ids) do if not Labels.has(labels, id) then return false end end
    return #ids > 0
end

local function setLabels(s, target, ids, on)
    local labels = s.app:labels(target)
    for _, id in ipairs(ids) do
        labels = Labels.without(labels, id)
        if on then labels[#labels + 1] = id end
    end
    return changed(s, s.app:setLabels(target, labels))
end

function Menu.item(host, s, items, item, order, tools)
    local carried = s.world:owns(item:getContainer())
    local clicked, picked = Log.item(item, s.player), #items
    -- One apple may be rotten or renamed; what is chosen here is for apples.
    local name, single = Describe.type(order[1]), #order == 1
    local typeIds = {}
    for index, fullType in ipairs(order) do typeIds[index] = Labels.ofType(fullType) end
    local every = single and "Every " .. name or "All of these kinds"
    local ones = picked == 1 and "Only this one" or "Only these " .. picked

    -- One click: the container it lies in, or the open one when it is carried.
    local here = carried and s.app:currentContainer() or item:getContainer()
    if Menu.labelable(s, here) and not (carried and s.world:owns(here)) and call(here, "isItemAllowed", item) ~= false then
        local on = Menu.hasLabels(s, here, typeIds)
        host:check("belongs", carried and "Belongs in " .. Describe.container(here) or "Belongs here", on,
            tools.ask(s, "menu.place", on and "not here" or "here", clicked, function() return setLabels(s, here, typeIds, not on) end),
            (single and "Every " .. name or "Every item of these kinds") .. " is put away there.")
    end

    local best, _, full = s.world:home(item)
    local known = best or full
    local child = host:sub("sort", known and "Where it goes: " .. known.name or "Where it goes")
    local function rows(target, ids)
        placeRows(target, s, tools, item, function(place) return Menu.hasLabels(s, place, ids) end, function(place, on)
            tools.ask(s, "menu.place", (on and "put in " or "take from ") .. place.name, clicked, function() return setLabels(s, place.target, ids, on) end)()
        end)
    end
    -- Ticks here speak for every one of the kind; narrower and wider choices follow.
    rows(child, typeIds)
    if single then
        local ids = { Catalog.categoryId(item) }
        for _, id in ipairs(s.world.graph:customMatches(s.world:describe(item))) do if #ids <= MAX_CUSTOM then ids[#ids + 1] = id end end
        local whole = #ids > 1 and child:sub("category", "A whole category") or child
        for _, id in ipairs(ids) do rows(whole:sub(id:match("^custom:") and "tag" or "category", "All of " .. App.categoryName(id)), { id }) end
    end
    if picked <= MAX_SINGLES then
        placeRows(child:sub("label", ones), s, tools, item, function(target)
            for _, entry in ipairs(items) do
                local mark = s.app:markOf(entry)
                if not mark or not Labels.has(s.app:labels(target), mark) then return false end
            end
            return true
        end, function(place, on)
            tools.ask(s, "menu.place", (on and "only these in " or "not these in ") .. place.name, clicked, function()
                for _, entry in ipairs(items) do
                    local ok, err = s.app:setItemPlace(entry, place.target, on)
                    if not ok then return nil, err end
                end
                return changed(s, true)
            end)()
        end)
    end
    if known and not known.carried and known.point then
        child:row("show", "Show me", tools.ask(s, "menu.place", "show", clicked, function()
            local ok, text = View.show(s.playerIndex, known)
            tools.ui().say(s.playerIndex, text, ok)
            return true
        end))
    end
    child:row("more", "All storage...", function() tools.ui().open(s.playerIndex, "storage") end)

    -- Picking up.
    local listed = true
    for _, fullType in ipairs(order) do listed = listed and s.app:onChecklist("types", fullType) end
    local function wantEvery()
        for _, fullType in ipairs(order) do
            if s.app:onChecklist("types", fullType) == listed then
                local ok, err = s.app:toggleChecklist("types", fullType)
                if not ok then return nil, err end
            end
        end
        return true
    end
    local function marked()
        for _, entry in ipairs(items) do
            local mark = s.app:markOf(entry)
            if not mark or not s.app:onChecklist("ids", mark) then return false end
        end
        return true
    end
    local wantTip = "Take my loot list, in a room, a building or a container, picks it up."
    if carried or picked > MAX_SINGLES then
        host:check("list", "Pick up when looting", listed, tools.ask(s, "menu.list", listed and "unlist" or "list", clicked, wantEvery), wantTip)
    else
        local want = host:sub("list", "Pick up when looting")
        want:check("all", every, listed, tools.ask(s, "menu.list", listed and "unlist" or "list", clicked, wantEvery), wantTip)
        local on = marked()
        want:check("label", ones, on, tools.ask(s, "menu.list", on and "unmark" or "mark", clicked, function()
            for _, entry in ipairs(items) do
                local ok, err = s.app:setItemWanted(entry, not on)
                if not ok then return nil, err end
            end
            return true
        end), "The mark comes off once you have it.")
    end

    -- Keeping.
    local kept, keptTypes = true, true
    for _, entry in ipairs(items) do kept = kept and s.app:isKept(entry) end
    for _, fullType in ipairs(order) do keptTypes = keptTypes and s.app:isTypeKept(fullType) end
    local keep = host:sub("keep", keptTypes and "Keep: every one" or kept and "Keep: " .. ones:sub(6) or "Keep")
    keep:check("all", every, keptTypes, tools.ask(s, "menu.keep", keptTypes and "unkeep kind" or "keep kind", clicked, function()
        for _, fullType in ipairs(order) do
            local ok, err = s.app:keepType(fullType, not keptTypes)
            if not ok then return nil, err end
        end
        return changed(s, true)
    end), "The ones you carry stay with you, and LootBox never throws one away. It still picks them up, puts the others away, and eats, drinks and pours.")
    keep:check("label", ones, kept, tools.ask(s, "menu.keep", kept and "unkeep" or "keep", clicked, function()
        for _, entry in ipairs(items) do
            local ok, err = s.app:protect(entry, not kept)
            if not ok then return nil, err end
        end
        return changed(s, true)
    end), "LootBox never moves or deletes a kept item.")

    -- Grouping.
    if not single then return end
    local fullType = order[1]
    local group = host:sub("category", "Categories")
    local custom = App.customCategories()
    for index = 1, math.min(12, #custom) do
        local definition = custom[index]
        local inside = false
        for _, value in ipairs(definition.types) do if value == fullType then inside = true end end
        group:check("tag", definition.name, inside, tools.ask(s, "menu.category", (inside and "remove from " or "add to ") .. definition.name, clicked, function()
            local kinds = Labels.without(definition.types, fullType)
            if not inside then kinds[#kinds + 1] = fullType end
            return changed(s, App.saveCategory({ id = definition.id, name = definition.name, types = kinds, includes = definition.includes }))
        end))
    end
    -- A category for a single copy, rather than for every one.
    if picked == 1 then
        local one, labels = group:sub("label", "Only this one"), s.app:itemLabels(item)
        local listed = {}
        local function tag(id)
            listed[id] = true
            local on = Labels.has(labels, id)
            one:check("tag", App.categoryName(id), on, tools.ask(s, "menu.tag", "tag " .. id, clicked, function()
                local kept = Labels.without(s.app:itemLabels(item), id)
                if not on then kept[#kept + 1] = id end
                return changed(s, s.app:setItemLabels(item, kept))
            end))
        end
        for _, id in ipairs(labels) do if not Labels.itemOf(id) then tag(id) end end
        for index = 1, math.min(12, #custom) do if not listed[custom[index].id] then tag(custom[index].id) end end
    end
    group:row("newCategory", "New category...", function() tools.ui().open(s.playerIndex, "categories", { type = fullType }) end)
end

return Menu
