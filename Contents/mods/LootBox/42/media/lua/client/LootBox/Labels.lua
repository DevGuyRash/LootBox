-- What a label can say. A container's list holds, from closest to widest:
-- one exact item, one kind of item, one of the player's categories, one of the
-- game's categories, and "anything else".
local Labels = { REST = "rest:", FIRST = "first", LAST = "last", NAME = 28 }

function Labels.ofType(fullType) return "type:" .. fullType end
function Labels.ofItem(id, fullType) return "item:" .. tostring(id) .. ":" .. fullType end

function Labels.typeOf(id) return type(id) == "string" and id:match("^type:(.+)$") or nil end

-- The item ID and type a label names.
function Labels.itemOf(id)
    if type(id) ~= "string" then return nil end
    local item, fullType = id:match("^item:(%-?%d+):(.+)$")
    return item, fullType
end

-- Labels that are not a category, and so need no category to exist.
function Labels.direct(id)
    return id == Labels.REST or Labels.typeOf(id) ~= nil or Labels.itemOf(id) ~= nil
end

function Labels.closeness(id)
    if Labels.itemOf(id) then return 1 end
    if Labels.typeOf(id) then return 2 end
    if id == Labels.REST then return 5 end
    return id:sub(1, 7) == "custom:" and 3 or 4
end

-- Kahlua has no next().
function Labels.none(map)
    for _ in pairs(map) do return false end
    return true
end

function Labels.has(list, id)
    for _, value in ipairs(list or {}) do if value == id then return true end end
    return false
end

function Labels.without(list, id)
    local result = {}
    for _, value in ipairs(list or {}) do if value ~= id then result[#result + 1] = value end end
    return result
end

-- A picker shows categories and item types apart; a container keeps one list.
function Labels.split(list)
    local selection, rest = { ids = {}, types = {} }, false
    for _, id in ipairs(list or {}) do
        local fullType = Labels.typeOf(id)
        if id == Labels.REST then rest = true
        elseif fullType then selection.types[#selection.types + 1] = fullType
        else selection.ids[#selection.ids + 1] = id end
    end
    return selection, rest
end

function Labels.join(selection, rest)
    local result = {}
    for _, id in ipairs(selection.ids) do result[#result + 1] = id end
    for _, fullType in ipairs(selection.types) do result[#result + 1] = Labels.ofType(fullType) end
    if rest then result[#result + 1] = Labels.REST end
    return result
end

-- A container's labels, name and order travel together. Returns whether anything changed.
local fields = { "containerLabels", "storage" }

function Labels.move(state, from, to)
    local changed = false
    for _, field in ipairs(fields) do
        local values = state[field]
        if values and (values[from] ~= nil or values[to] ~= nil) then
            values[to], values[from] = values[from], nil
            changed = true
        end
    end
    return changed
end

function Labels.clear(state, key)
    local changed = false
    for _, field in ipairs(fields) do
        local values = state[field]
        if values and values[key] ~= nil then values[key], changed = nil, true end
    end
    return changed
end

-- A mark follows its item to a new ID and type. Returns whether anything changed.
function Labels.renameItem(state, from, to, fullType)
    local changed = false
    local function rename(list)
        for index, id in ipairs(list) do
            if Labels.itemOf(id) == tostring(from) then list[index], changed = Labels.ofItem(to, fullType), true end
        end
    end
    for _, field in ipairs({ "containerLabels", "itemLabels" }) do for _, list in pairs(state[field]) do rename(list) end end
    if state.checklist then rename(state.checklist.ids) end
    return changed
end

-- A saved name and order, or nil when neither says anything.
function Labels.details(value)
    if type(value) ~= "table" then return nil end
    local name = type(value.name) == "string" and value.name:gsub("%c", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, Labels.NAME) or nil
    if name == "" then name = nil end
    local order = (value.order == Labels.FIRST or value.order == Labels.LAST) and value.order or nil
    if not name and not order then return nil end
    return { name = name, order = order }
end

return Labels
