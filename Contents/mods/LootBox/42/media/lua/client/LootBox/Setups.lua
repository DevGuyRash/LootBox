local Setups = {}

Setups.defaults = { pourLootToLoot = false, pourMainOnly = false, pourEquippedFirst = false, pourMostRoomFirst = false,
    autoDrinkEquipped = false, autoConsumeCarried = false, autoConsumeNested = false, autoConsumeRiskyOpen = false,
    tillFullEnabled = true, tillFullBothNeeds = false, contextMenus = true, inventoryShortcuts = true, worldShortcuts = true,
    vehicleShortcuts = true, categoryShortcuts = true, savedShortcuts = true, confirmQuickMoves = false, confirmQuickCleanup = false, confirmBinReviews = false,
    smartTakeAllContainers = true, matchingTransferButtons = true, jobBar = true, rememberLastSetup = true, detailedLog = true,
    condenseButton = true, condenseRebalance = false, condenseUseUnequipped = false, condenseNested = false }

local scopes = { inventory = true, container = true, lootPane = true, reach = true, room = true,
    building = true, area = true, labeled = true }
local destinations = { inventory = true, floor = true, container = true,
    vehicle = true, labels = true, trash = true, matching = true }
local MAX_ID, MAX_PRESETS = 2147483647, 32

local function integer(value)
    return type(value) == "number" and value == value and math.abs(value) <= MAX_ID and value == math.floor(value)
end

local function strings(value, labels)
    if type(value) ~= "table" or #value > 4096 then return nil, "Choose a bounded list of categories or item types" end
    local result, seen, count = {}, {}, 0
    for index, entry in pairs(value) do
        if not integer(index) or index < 1 or index > #value or type(entry) ~= "string"
            or #entry > 256 or not entry:find("%S")
            or (labels and not (entry:match("^native:.+") or entry:match("^custom:.+"))) then
            return nil, "Categories and item types must form a dense list of valid IDs"
        end
        count = count + 1
    end
    if count ~= #value then return nil, "Categories and item types must form a dense list" end
    for _, entry in ipairs(value) do
        if not seen[entry] then seen[entry] = true; result[#result + 1] = entry end
    end
    return result
end

local function boolean(value, default)
    if value == nil then return default end
    if type(value) == "boolean" then return value end
end

-- Unknown or damaged entries fall back to their default. Returns what was repaired.
function Setups.preferences(value)
    local result, repaired = {}, {}
    if type(value) ~= "table" then value, repaired = {}, { "document" } end
    for key, entry in pairs(value) do
        if Setups.defaults[key] == nil or type(entry) ~= "boolean" then repaired[#repaired + 1] = tostring(key) end
    end
    for key, default in pairs(Setups.defaults) do
        if type(value[key]) == "boolean" then result[key] = value[key] else result[key] = default end
    end
    table.sort(repaired)
    return result, repaired
end

function Setups.request(value)
    if type(value) ~= "table" then return nil, "Choose an action setup to save" end
    local scope = value.scope == nil and "inventory" or value.scope
    local destination = value.destination == nil and { kind = "inventory" } or value.destination
    local filter = value.filter == nil and { ids = {}, types = {}, all = false } or value.filter
    if not scopes[scope] or type(destination) ~= "table" or not destinations[destination.kind]
        or type(filter) ~= "table" then return nil, "Choose a valid source, selection, and destination" end
    local includeInventory, includeBags = boolean(value.includeInventory, false), boolean(value.includeBags, true)
    local all = boolean(filter.all, false)
    local excludeUnwanted = boolean(value.excludeUnwanted, false)
    if includeInventory == nil or includeBags == nil or all == nil or excludeUnwanted == nil then return nil, "Setup options must be on or off" end
    local ids, err = strings(filter.ids == nil and {} or filter.ids, true)
    if not ids then return nil, err end
    local types
    types, err = strings(filter.types == nil and {} or filter.types, false)
    if not types then return nil, err end
    local sourceLabels
    sourceLabels, err = strings(value.sourceLabels == nil and {} or value.sourceLabels, true)
    if not sourceLabels then return nil, err end
    local labels
    labels, err = strings(destination.labels == nil and {} or destination.labels, true)
    if not labels then return nil, err end
    if scope == "lootPane" then includeInventory, includeBags = false, false end
    if destination.kind == "matching" then scope, includeInventory, includeBags = "inventory", false, true end
    local result = { scope = scope, includeInventory = includeInventory, includeBags = includeBags, excludeUnwanted = excludeUnwanted,
        filter = { ids = ids, types = types, all = all }, sourceLabels = sourceLabels,
        destination = { kind = destination.kind, labels = labels } }
    if destination.kind == "matching" then
        local mode = destination.mode == nil and "nearby" or destination.mode
        if mode ~= "displayed" and mode ~= "nearby" then return nil, "Choose displayed or nearby matching containers" end
        result.destination.mode = mode
    end
    if value.area ~= nil then
        if type(value.area) ~= "table" then return nil, "Choose a valid area" end
        result.area = {}
        for _, field in ipairs({ "x1", "y1", "x2", "y2", "z" }) do
            if not integer(value.area[field]) then return nil, "Area coordinates must be finite native integers" end
            result.area[field] = value.area[field]
        end
        if result.area.x1 > result.area.x2 or result.area.y1 > result.area.y2 then
            return nil, "Select the first and opposite area corners in order"
        end
    end
    return result
end

function Setups.name(value)
    if type(value) ~= "string" then return nil, "Give this preset a name" end
    local result = value:gsub("^%s+", ""):gsub("%s+$", "")
    if #result == 0 or #result > 80 or result:find("[%z\1-\31]") then
        return nil, "Use a name between 1 and 80 characters without control characters"
    end
    return result
end

-- Keep every readable preset. Returns the document and what was dropped.
function Setups.document(value)
    local result, dropped, seen = { nextId = 1, presets = {} }, {}, {}
    if type(value) ~= "table" then return result, { "unreadable presets" } end
    if integer(value.nextId) and value.nextId >= 1 then result.nextId = value.nextId end
    for _, preset in pairs(type(value.presets) == "table" and value.presets or {}) do
        local suffix = type(preset) == "table" and type(preset.id) == "string" and tonumber(preset.id:match("^setup:(%d+)$"))
        local name = suffix and Setups.name(preset.name)
        local setup, why
        if name then setup, why = Setups.request(preset.setup) end
        if setup and integer(suffix) and suffix >= 1 and not seen[preset.id] and #result.presets < MAX_PRESETS then
            seen[preset.id] = true
            result.presets[#result.presets + 1] = { id = preset.id, name = name, setup = setup, order = suffix }
            if suffix >= result.nextId then result.nextId = suffix + 1 end
        else dropped[#dropped + 1] = tostring(name or "preset") .. ": " .. tostring(why or "invalid or duplicate identity") end
    end
    table.sort(result.presets, function(a, b) return a.order < b.order end)
    for _, preset in ipairs(result.presets) do preset.order = nil end
    if value.lastSetup ~= nil then
        local setup, why = Setups.request(value.lastSetup)
        if setup then result.lastSetup = setup else dropped[#dropped + 1] = "last setup: " .. tostring(why) end
    end
    return result, dropped
end

function Setups.add(document, name, request, id)
    local setup, err = Setups.request(request)
    if not setup then return nil, err end
    name, err = Setups.name(name)
    if not name then return nil, err end
    if id ~= nil and type(id) ~= "string" then return nil, "Choose an existing setup to update" end
    local found = false
    if id then
        for _, preset in ipairs(document.presets) do
            if preset.id == id then preset.name, preset.setup, found = name, setup, true; break end
        end
        if not found then return nil, "That preset no longer exists" end
    else
        if #document.presets >= MAX_PRESETS then return nil, "Keep at most 32 presets; update or remove one first" end
        if document.nextId >= MAX_ID then return nil, "Saved setup identity limit reached" end
        id = "setup:" .. tostring(document.nextId)
        document.nextId = document.nextId + 1
        document.presets[#document.presets + 1] = { id = id, name = name, setup = setup }
    end
    return id
end

return Setups
