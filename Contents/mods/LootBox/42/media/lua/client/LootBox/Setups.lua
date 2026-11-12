local Setups = {}

Setups.defaults = { contextMenus = true, inventoryShortcuts = true, worldShortcuts = true,
    vehicleShortcuts = true, categoryShortcuts = true, savedShortcuts = true,
    confirmQuickMoves = false, confirmQuickCleanup = false, confirmBinReviews = false,
    matchingTransferButtons = true, showQuickProgress = false, rememberLastSetup = true, showTips = true }

local scopes = { inventory = true, container = true, reach = true, room = true,
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

function Setups.preferences(value)
    if type(value) ~= "table" then return nil, "Invalid saved interface preferences" end
    local result = {}
    for key, entry in pairs(value) do
        if Setups.defaults[key] == nil or type(entry) ~= "boolean" then
            return nil, "Unknown or invalid interface preference: " .. tostring(key)
        end
    end
    for key, default in pairs(Setups.defaults) do
        if value[key] == nil then result[key] = default else result[key] = value[key] end
    end
    return result
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
    if includeInventory == nil or includeBags == nil or all == nil then return nil, "Setup options must be on or off" end
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
    if destination.kind == "matching" then scope, includeInventory, includeBags = "inventory", false, true end
    local result = { scope = scope, includeInventory = includeInventory, includeBags = includeBags,
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
    if type(value) ~= "string" then return nil, "Give this setup a name" end
    local result = value:gsub("^%s+", ""):gsub("%s+$", "")
    if #result == 0 or #result > 80 or result:find("[%z\1-\31]") then
        return nil, "Use a setup name between 1 and 80 characters without control characters"
    end
    return result
end

function Setups.document(value)
    if type(value) ~= "table" then return nil, "Invalid saved setups document" end
    local nextId = value.nextId == nil and 1 or value.nextId
    local presets = value.presets == nil and {} or value.presets
    if not integer(nextId) or nextId < 1 or type(presets) ~= "table" or #presets > MAX_PRESETS then
        return nil, "Invalid saved setups document"
    end
    local result, seen, count = { nextId = nextId, presets = {} }, {}, 0
    for index in pairs(presets) do
        if not integer(index) or index < 1 or index > #presets then return nil, "Saved setups must form a dense list" end
        count = count + 1
    end
    if count ~= #presets then return nil, "Saved setups must form a dense list" end
    for _, preset in ipairs(presets) do
        if type(preset) ~= "table" or type(preset.id) ~= "string" then return nil, "Invalid saved setup identity" end
        local suffix = tonumber(preset.id:match("^setup:(%d+)$"))
        if not suffix or suffix < 1 or suffix >= nextId or not integer(suffix)
            or preset.id ~= "setup:" .. tostring(suffix) or seen[preset.id] then
            return nil, "Invalid or reused saved setup identity"
        end
        local name, err = Setups.name(preset.name)
        if not name then return nil, err end
        local setup
        setup, err = Setups.request(preset.setup)
        if not setup then return nil, err end
        result.presets[#result.presets + 1] = { id = preset.id, name = name, setup = setup }
        seen[preset.id] = true
    end
    if value.lastSetup ~= nil then
        local setup, err = Setups.request(value.lastSetup)
        if not setup then return nil, err end
        result.lastSetup = setup
    end
    return result
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
        if not found then return nil, "Saved setup is no longer available" end
    else
        if #document.presets >= MAX_PRESETS then return nil, "Keep at most 32 saved setups; update or remove one first" end
        if document.nextId >= MAX_ID then return nil, "Saved setup identity limit reached" end
        id = "setup:" .. tostring(document.nextId)
        document.nextId = document.nextId + 1
        document.presets[#document.presets + 1] = { id = id, name = name, setup = setup }
    end
    return id
end

return Setups
