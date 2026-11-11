local Categories = require "LootBox/Categories"
local Catalog = require "LootBox/Catalog"
local Store = require "LootBox/Store"
local World = require "LootBox/World"
local Jobs = require "LootBox/Jobs"
local Setups = require "LootBox/Setups"

local App = {}
local Instance = {}
Instance.__index = Instance
local sessions, definitions, graph, loadError = {}, nil, nil, nil
local nextCategoryId = 1
local preferences, preferencesError

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end

function App.getPreferences()
    if not preferences then
        local data, err = Store.load("LootBox/preferences")
        preferences, preferencesError = Setups.preferences(data or {})
        preferencesError = err or preferencesError
        if not preferences then preferences = copy(Setups.defaults) end
    end
    return copy(preferences), preferencesError
end

function App.setPreferences(patch)
    local candidate, err = App.getPreferences()
    if err then return nil, err end
    if type(patch) ~= "table" then return nil, "Choose interface preferences to change" end
    for key, value in pairs(patch) do
        if Setups.defaults[key] == nil or type(value) ~= "boolean" then
            return nil, "Unknown or invalid interface preference: " .. tostring(key)
        end
        candidate[key] = value
    end
    local ok
    ok, err = Store.save("LootBox/preferences", candidate)
    if ok then preferences = candidate end
    return ok, err
end

local function initialize()
    if definitions then return end
    local data, err = Store.load("LootBox/categories")
    if err then loadError = err end
    if data ~= nil and (type(data) ~= "table" or type(data.categories) ~= "table"
        or (data.nextId ~= nil and (type(data.nextId) ~= "number" or data.nextId < 1 or data.nextId % 1 ~= 0))) then
        loadError = "Invalid saved category document"
        data = nil
    end
    definitions = data and data.categories or {}
    nextCategoryId = data and data.nextId or 1
    for _, definition in ipairs(definitions) do
        local suffix = type(definition.id) == "string" and tonumber(definition.id:match("^custom:(%d+)$"))
        if suffix and suffix >= nextCategoryId then nextCategoryId = suffix + 1 end
    end
    graph, err = Categories.new(definitions)
    if not graph then loadError = err; definitions = {}; graph = Categories.new({}) end
end

function App.catalog()
    initialize()
    local catalog, err = Catalog.read()
    if not catalog then return nil, err end
    for _, definition in ipairs(graph:list()) do
        definition.kind = "custom"
        catalog.categories[#catalog.categories + 1] = definition
    end
    catalog.error = loadError
    return catalog
end

function App.category(id)
    initialize()
    for _, definition in ipairs(graph:list()) do
        if definition.id == id then return definition end
    end
end

local function saveDefinitions(nextDefinitions)
    if loadError then return nil, "Category storage needs repair: " .. loadError end
    for _, instance in pairs(sessions) do
        local state = instance:status().state
        if state == "running" or state == "cancelling" then return nil, "Finish or cancel the current job before editing categories" end
    end
    local nextGraph, err = Categories.new(nextDefinitions)
    if not nextGraph then return nil, err end
    local ok
    ok, err = Store.save("LootBox/categories", { categories = nextDefinitions, nextId = nextCategoryId })
    if not ok then return nil, err end
    definitions, graph = copy(nextDefinitions), nextGraph
    for _, instance in pairs(sessions) do instance.world.graph = graph end
    return true
end

function App.saveCategory(definition)
    initialize()
    if type(definition) ~= "table" then return nil, "Missing category definition" end
    local candidate = copy(definition)
    if not candidate.id then
        candidate.id = "custom:" .. nextCategoryId
        nextCategoryId = nextCategoryId + 1
    end
    local nextDefinitions, replaced = {}, false
    for _, entry in ipairs(definitions) do
        if entry.id == candidate.id then
            nextDefinitions[#nextDefinitions + 1], replaced = candidate, true
        else nextDefinitions[#nextDefinitions + 1] = copy(entry) end
    end
    if not replaced then nextDefinitions[#nextDefinitions + 1] = candidate end
    local ok, err = saveDefinitions(nextDefinitions)
    if not ok then return nil, err end
    return candidate.id
end

function App.deleteCategory(id)
    initialize()
    for _, entry in ipairs(definitions) do
        for _, included in ipairs(entry.includes) do
            if included == id then return nil, "Used by " .. entry.name .. "; remove that inclusion first" end
        end
    end
    for _, instance in pairs(sessions) do
        for _, ids in pairs(instance.state.containerLabels) do
            for _, label in ipairs(ids) do if label == id then return nil, "Still used by a container label" end end
        end
        for _, ids in pairs(instance.state.itemLabels) do
            for _, label in ipairs(ids) do if label == id then return nil, "Still used by an item label" end end
        end
    end
    local nextDefinitions, found = {}, false
    for _, entry in ipairs(definitions) do
        if entry.id ~= id then nextDefinitions[#nextDefinitions + 1] = copy(entry) else found = true end
    end
    if not found then return nil, "Unknown custom category" end
    return saveDefinitions(nextDefinitions)
end

local function escaped(text)
    text = tostring(text)
    local codes = {}
    for index = 1, #text do codes[index] = string.format("%04x", text:byte(index)) end
    local hex = table.concat(codes)
    return hex:gsub(string.rep(".", 96), "%0/"):gsub("/$", "")
end

local function scope(player)
    local world = getWorld():getWorld()
    local identity = tostring(world) .. ":" .. tostring(player:getUsername()) .. ":" .. player:getPlayerNum()
    return "LootBox/world/" .. escaped(identity)
end

local function stateError(state)
    if type(state) ~= "table" then return "Invalid saved world document" end
    for _, name in ipairs({ "containerLabels", "itemLabels" }) do
        if state[name] ~= nil and type(state[name]) ~= "table" then return "Invalid saved " .. name end
        for key, labels in pairs(state[name] or {}) do
            if type(key) ~= "string" or type(labels) ~= "table" then return "Invalid saved " .. name end
            local count = 0
            for index, id in pairs(labels) do
                if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #labels
                    or type(id) ~= "string" or not (id:match("^native:.+") or id:match("^custom:.+")) then return "Invalid saved label list" end
                count = count + 1
            end
            if count ~= #labels then return "Invalid saved label list" end
        end
    end
    if state.keep ~= nil and type(state.keep) ~= "table" then return "Invalid saved Keep flags" end
    for key, flag in pairs(state.keep or {}) do
        if type(key) ~= "string" or type(flag) ~= "boolean" then return "Invalid saved Keep flag" end
    end
    if state.trash ~= nil and type(state.trash) ~= "table" then return "Invalid saved trash memory" end
    for key, bin in pairs(state.trash or {}) do
        if type(key) ~= "string" or type(bin) ~= "table" then return "Invalid saved trash can" end
        for _, coordinate in ipairs({ "x", "y", "z" }) do
            if type(bin[coordinate]) ~= "number" then return "Invalid saved trash coordinates" end
        end
    end
    if state.vehicle ~= nil then
        if type(state.vehicle) ~= "table" then return "Invalid saved vehicle" end
        for _, key in ipairs({ "id", "x", "y", "z" }) do
            if type(state.vehicle[key]) ~= "number" then return "Invalid saved vehicle " .. key end
        end
        if type(state.vehicle.script) ~= "string" then return "Invalid saved vehicle script" end
    end
    if state.checklist ~= nil then
        if type(state.checklist) ~= "table" or type(state.checklist.ids) ~= "table" or type(state.checklist.types) ~= "table" then return "Invalid saved checklist" end
        for _, id in ipairs(state.checklist.ids) do if type(id) ~= "string" then return "Invalid saved checklist category" end end
        for _, fullType in ipairs(state.checklist.types) do if type(fullType) ~= "string" then return "Invalid saved checklist item" end end
    end
end

function App.get(playerIndex)
    initialize()
    local player = getSpecificPlayer(playerIndex or 0)
    if not player then return nil, "Enter a game to move or label items" end
    local path = scope(player)
    local existing = sessions[playerIndex or 0]
    if existing and existing.player == player and existing.path == path then return existing end
    if existing then existing:cancel() end
    local state, err = Store.load(path)
    if state ~= nil then
        local invalid = stateError(state)
        if invalid then state, err = nil, invalid end
    end
    if not state then state = {} end
    for _, key in ipairs({ "containerLabels", "itemLabels", "keep", "trash" }) do
        if type(state[key]) ~= "table" then
            if state[key] ~= nil then err = "Invalid saved " .. key end
            state[key] = {}
        end
    end
    local instance = setmetatable({ player = player, state = state, path = path, error = err }, Instance)
    instance.world = World.new(player, state)
    instance.world.graph = graph
    instance.jobs = Jobs.new(player, instance.world, graph)
    sessions[playerIndex or 0] = instance
    return instance
end

function Instance:persist()
    if self.error then return nil, self.error end
    return Store.save(self.path, self.state)
end

function Instance:labels(container)
    local key = self.world:key(container)
    return key and copy(self.state.containerLabels[key] or {}) or {}
end

local function validLabels(ids)
    if type(ids) ~= "table" then return nil, "Labels must be a list" end
    local result, seen = {}, {}
    for _, id in ipairs(ids) do
        if type(id) ~= "string" or (not id:match("^native:.+") and not App.category(id)) then
            return nil, "Unknown category label" end
        if not seen[id] then result[#result + 1] = id; seen[id] = true end
    end
    return result
end

function Instance:setLabels(container, ids)
    local key, err = self.world:key(container)
    if not key then return nil, err or "Container is no longer available" end
    local labels
    labels, err = validLabels(ids)
    if not labels then return nil, err end
    local old = self.state.containerLabels[key]
    self.state.containerLabels[key] = labels
    local ok
    ok, err = self:persist()
    if not ok then self.state.containerLabels[key] = old else self.world:discover() end
    return ok, err
end

function Instance:itemLabels(item)
    return copy(self.state.itemLabels[self.world:itemId(item)] or {})
end

function Instance:setItemLabels(item, ids)
    local labels, err = validLabels(ids)
    if not labels then return nil, err end
    local key = self.world:itemId(item)
    local old = self.state.itemLabels[key]
    self.state.itemLabels[key] = labels
    local ok
    ok, err = self:persist()
    if not ok then self.state.itemLabels[key] = old end
    return ok, err
end

function Instance:protect(item, value)
    local key = self.world:itemId(item)
    local old = self.state.keep[key]
    self.state.keep[key] = value == true or nil
    local ok, err = self:persist()
    if not ok then self.state.keep[key] = old end
    return ok, err
end

function Instance:isProtected(item) return self.world:protected(item) end
function Instance:isKept(item) return self.state.keep[self.world:itemId(item)] == true end
function Instance:rememberVehicle(vehicle)
    local ok, err = self.world:rememberVehicle(vehicle)
    if not ok then return nil, err end
    return self:persist()
end
function Instance:getChecklist()
    return copy(self.state.checklist or { ids = {}, types = {}, all = false })
end
function Instance:setChecklist(filter)
    if type(filter) ~= "table" or type(filter.ids) ~= "table" or type(filter.types) ~= "table" then
        return nil, "Choose categories or item types for the checklist" end
    local labels, err = validLabels(filter.ids)
    if not labels then return nil, err end
    local types, seen = {}, {}
    for _, fullType in ipairs(filter.types) do
        if type(fullType) ~= "string" or fullType == "" then return nil, "Invalid item type in checklist" end
        if not seen[fullType] then types[#types + 1] = fullType; seen[fullType] = true end
    end
    local old = self.state.checklist
    self.state.checklist = { ids = labels, types = types, all = filter.all == true }
    local ok
    ok, err = self:persist()
    if not ok then self.state.checklist = old end
    return ok, err
end

local function setupDocument(instance)
    if not instance.setups then
        local data, err = Store.load(instance.path .. "/setups")
        instance.setups, instance.setupsError = Setups.document(data or {})
        instance.setupsError = err or instance.setupsError
        if not instance.setups then instance.setups = { nextId = 1, presets = {} } end
    end
    return instance.setups, instance.setupsError
end

local function saveSetups(instance, candidate)
    local ok, err = Store.save(instance.path .. "/setups", candidate)
    if ok then instance.setups = candidate end
    return ok, err
end

function Instance:getSetups()
    local data, err = setupDocument(self)
    return { presets = copy(data.presets), lastSetup = copy(data.lastSetup) }, err
end

function Instance:saveSetup(name, request, id)
    local data, err = setupDocument(self)
    if err then return nil, err end
    local candidate = copy(data)
    id, err = Setups.add(candidate, name, request, id)
    if not id then return nil, err end
    local ok
    ok, err = saveSetups(self, candidate)
    return ok and id or nil, err
end

function Instance:deleteSetup(id)
    local data, err = setupDocument(self)
    if err then return nil, err end
    local candidate, found = copy(data), false
    for index, preset in ipairs(candidate.presets) do
        if preset.id == id then table.remove(candidate.presets, index); found = true; break end
    end
    if not found then return nil, "Saved setup is no longer available" end
    return saveSetups(self, candidate)
end

function Instance:rememberSetup(request)
    local options, err = App.getPreferences()
    if err then return nil, err end
    if not options.rememberLastSetup then return true end
    local data
    data, err = setupDocument(self)
    if err then return nil, err end
    local setup
    setup, err = Setups.request(request)
    if not setup then return nil, err end
    local candidate = copy(data)
    candidate.lastSetup = setup
    return saveSetups(self, candidate)
end

function Instance:resolveSetup(setup, context)
    local request, err = Setups.request(setup)
    if not request then return nil, err end
    local catalog
    catalog, err = App.catalog()
    if not catalog then return nil, err end
    local available = {}
    for _, category in ipairs(catalog.categories) do available[category.id] = true end
    for _, ids in ipairs({ request.filter.ids, request.sourceLabels, request.destination.labels }) do
        for _, id in ipairs(ids) do
            if not available[id] then return nil, "Saved setup category is unavailable: " .. id end
        end
    end
    context = context or {}
    if request.scope == "container" then
        request.sourceContainer = context.sourceContainer or context.container
        if not request.sourceContainer then return nil, "Right-click a source container to use this saved setup" end
    end
    if request.destination.kind == "container" then
        request.destination.ref = context.targetContainer or context.container
        if not request.destination.ref then return nil, "Right-click a destination container to use this saved setup" end
    elseif request.destination.kind == "floor" then
        request.destination.ref = context.square or (self.player.getSquare and self.player:getSquare())
            or (self.player.getCurrentSquare and self.player:getCurrentSquare())
        if not request.destination.ref then return nil, "Choose a loaded floor location for this saved setup" end
    end
    return request
end

function Instance:loadSetup(id, context)
    local data, err = setupDocument(self)
    if err then return nil, err end
    for _, preset in ipairs(data.presets) do
        if preset.id == id then return self:resolveSetup(preset.setup, context) end
    end
    return nil, "Saved setup is no longer available"
end

function Instance:lastSetup(context)
    local options, err = App.getPreferences()
    if err then return nil, err end
    if not options.rememberLastSetup then return nil end
    local data
    data, err = setupDocument(self)
    if err then return nil, err end
    if not data.lastSetup then return nil end
    return self:resolveSetup(data.lastSetup, context)
end

function Instance:knownVehicles() return self.world:knownVehicles() end
function Instance:currentContainer()
    local loot = getPlayerLoot(self.player:getPlayerNum())
    return loot and loot.inventoryPane and loot.inventoryPane.inventory or nil
end
function Instance:preview(request)
    if self.error or loadError then return nil, self.error or loadError end
    self.jobs.graph = graph
    return self.jobs:preview(request)
end
function Instance:start(plan)
    local ok, err = self:persist()
    if not ok then return nil, err end
    return self.jobs:start(plan)
end
function Instance:cancel() return self.jobs:cancel() end
function Instance:status() return self.jobs:status() end

function App.tick()
    local stamp = getTimestampMs()
    for _, instance in pairs(sessions) do
        instance.jobs:tick()
        if not instance.lastObserve or stamp - instance.lastObserve >= 1000 then
            instance.lastObserve = stamp
            if instance.world:observeNearby() and not instance.error then
                local ok, err = instance:persist()
                if not ok then instance.error = err end
            end
        end
    end
end

function App.reset()
    for _, instance in pairs(sessions) do instance:cancel() end
    sessions, definitions, graph, loadError = {}, nil, nil, nil
    preferences, preferencesError = nil, nil
end

if Events then
    Events.OnTick.Add(App.tick)
    if Events.OnDisconnect then Events.OnDisconnect.Add(App.reset) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(App.reset) end
end

return App
