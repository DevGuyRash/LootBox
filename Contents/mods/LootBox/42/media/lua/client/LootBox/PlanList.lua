-- Turns a job plan into short, grouped rows: what moves where, what stays and
-- why, and what is still unknown.
local K = require "LootBox/UIKit"
local Describe = require "LootBox/Describe"

local PlanList = {}

-- Engine notices that are true of every job and say nothing about this one.
local boilerplate = { "Live capacity", "Native multiplayer does not", "Bin choice compares", "Floor items will be inspected",
    "This shows the first arrangement", "Uninspected bins", "Cleanup permanently", "Useful bags will be prepared" }

local function ordinary(text)
    for _, prefix in ipairs(boilerplate) do if text:sub(1, #prefix) == prefix then return true end end
    return text:find("unopened containers will be approached", 1, true) ~= nil
end

local function iconOf(record)
    local item = record and record.item
    if not item then return false end
    local ok, texture = pcall(function() return item:getTex() end)
    return ok and texture or Describe.texture(record.fullType or tostring(item:getFullType())) or false
end

local function group(rows, keyOf)
    local order, byKey = {}, {}
    for index, row in ipairs(rows) do
        local key = keyOf(row)
        local entry = byKey[key]
        if not entry then entry = { row = row, index = index, count = 0, names = {}, seen = {} }; byKey[key] = entry; order[#order + 1] = entry end
        entry.count = entry.count + 1
        local name = tostring(row.itemName or "Item")
        if not entry.seen[name] then entry.seen[name] = true; entry.names[#entry.names + 1] = name end
    end
    return order
end

local function plural(count, one, many) return tostring(count) .. " " .. (count == 1 and one or (many or one .. "s")) end
PlanList.plural = plural

function PlanList.summary(plan)
    if plan.condense then
        local saving = plan.condense.estimatedSaving
        return plural(plan.condense.bagCount or 0, "bag") .. ", " .. plural(plan.condense.eligible or 0, "item")
            .. (saving and saving > 0.005 and string.format(", saves about %.1f", saving) or "")
    end
    local parts = {}
    if #plan.moves > 0 then parts[#parts + 1] = plural(#plan.moves, "item") end
    local rooms = plan.building and plan.building.roomsTotal or 0
    local unopened = math.max(0, (plan.pending or 0) - rooms)
    if rooms > 0 then parts[#parts + 1] = plural(rooms, "room") .. " to search" end
    if unopened > 0 then parts[#parts + 1] = plural(unopened, "place") .. " to look into" end
    if #parts == 0 then return "Nothing to move" end
    return table.concat(parts, ", ")
end

function PlanList.rows(plan, options)
    options = options or {}
    local rows, moves, skipped = {}, plan.moves or {}, plan.skipped or {}
    local byTarget, targets = {}, {}
    for index, move in ipairs(moves) do
        local target = tostring(move.to or "")
        if not byTarget[target] then byTarget[target] = {}; targets[#targets + 1] = target end
        table.insert(byTarget[target], { itemName = move.itemName, from = move.from, status = move.status, record = plan.records and plan.records[index] })
    end
    for _, target in ipairs(targets) do
        local entries = byTarget[target]
        local title = options.heading or (target ~= "" and ("To " .. target) or "Moving")
        rows[#rows + 1] = { heading = true, title = title, right = plural(#entries, "item") }
        for _, entry in ipairs(group(entries, function(row) return tostring(row.itemName) .. "\1" .. tostring(row.from) end)) do
            local row = entry.row
            rows[#rows + 1] = { title = tostring(row.itemName) .. (entry.count > 1 and ("  x" .. entry.count) or ""),
                icon = iconOf(row.record), right = tostring(row.from or ""), tone = options.tone,
                tooltip = tostring(row.itemName) .. "\nFrom " .. tostring(row.from) .. " to " .. target .. (row.status and ("\n" .. tostring(row.status)) or "") }
        end
    end
    local rooms = plan.building and plan.building.roomsTotal or 0
    local unopened = math.max(0, (plan.pending or 0) - rooms)
    if (rooms > 0 or unopened > 0) and not plan.condense then
        rows[#rows + 1] = { heading = true, title = "Found along the way" }
        if rooms > 0 then rows[#rows + 1] = { title = plural(rooms, "room") .. " searched one after another", tone = "info" } end
        if unopened > 0 then rows[#rows + 1] = { title = plural(unopened, "place") .. " looked into when reached", tone = "info" } end
    end
    if #skipped > 0 then
        rows[#rows + 1] = { heading = true, title = "Staying put", right = tostring(#skipped) }
        for _, entry in ipairs(group(skipped, function(row) return tostring(row.reason or row.status) end)) do
            local names = table.concat(entry.names, ", ", 1, math.min(4, #entry.names)) .. (#entry.names > 4 and (" +" .. (#entry.names - 4)) or "")
            rows[#rows + 1] = { title = names, right = tostring(entry.count), rightTone = "dim",
                sub = tostring(entry.row.reason or entry.row.status or "Not eligible"), subTone = "warn",
                tooltip = table.concat(entry.names, ", ") .. "\n" .. tostring(entry.row.reason or "") }
        end
    end
    local notices = {}
    for _, warning in ipairs(plan.warnings or {}) do
        warning = tostring(warning)
        if not ordinary(warning) then notices[#notices + 1] = warning end
    end
    if #notices > 0 then
        rows[#rows + 1] = { heading = true, title = "Good to know" }
        for _, text in ipairs(notices) do rows[#rows + 1] = { title = text, tone = "warn", tooltip = text } end
    end
    return rows
end

return PlanList
