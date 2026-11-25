local Categories = require "LootBox/Categories"
local Catalog = require "LootBox/Catalog"
local Store = require "LootBox/Store"
local World = require "LootBox/World"
local Jobs = require "LootBox/Jobs"
local Setups = require "LootBox/Setups"
local Recovery = require "LootBox/Recovery"
local TillFull = require "LootBox/TillFull"
local AutoPutAway = require "LootBox/AutoPutAway"
local AutoNeeds = require "LootBox/AutoNeeds"
local Describe = require "LootBox/Describe"
local Items = require "LootBox/Items"
local Labels = require "LootBox/Labels"
local Log = require "LootBox/Log"
require "LootBox/CompletionHUD"

local App = {}
local Instance = {}
Instance.__index = Instance
local sessions, definitions, graph, loadError = {}, nil, nil, nil
local nextCategoryId = 1
local preferences, preferencesError
local lastNeedsUpdate = {}
-- What was noticed while walking is saved in batches; every label change saves at once.
local SIGHTINGS_MS = 30000

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end

local function currentPreferences()
    if not preferences then
        local data, err = Store.load("LootBox/preferences")
        local repaired
        preferences, repaired = Setups.preferences(data or {})
        preferencesError = err
        if err then Log.warn(nil, "preferences-unreadable", "error", err) end
        if #repaired > 0 then Log.trace(nil, "preferences-repaired", "keys", table.concat(repaired, ",")) end
        Log.detailed = preferences.detailedLog
    end
    return preferences, preferencesError
end

function App.getPreferences()
    local options, err = currentPreferences()
    return copy(options), err
end

-- One value without copying the table; safe to call every frame.
function App.preference(key) return (currentPreferences())[key] end

function App.reviewPreference(request, binReview)
    local key = binReview and "confirmBinReviews"
        or (request and request.destination and request.destination.kind == "trash" and "confirmQuickCleanup" or "confirmQuickMoves")
    local current, err = App.getPreferences()
    return err ~= nil or current[key] == true, key, err
end

function App.setPreferences(patch)
    local candidate = App.getPreferences()
    local err
    if type(patch) ~= "table" then return nil, "Choose interface preferences to change" end
    for key, value in pairs(patch) do
        if Setups.defaults[key] == nil or type(value) ~= "boolean" then
            return nil, "Unknown or invalid interface preference: " .. tostring(key)
        end
        candidate[key] = value
    end
    local ok
    ok, err = Store.save("LootBox/preferences", candidate)
    if ok then
        if candidate.autoDrinkEquipped ~= preferences.autoDrinkEquipped or candidate.autoConsumeCarried ~= preferences.autoConsumeCarried
            or candidate.autoConsumeNested ~= preferences.autoConsumeNested or candidate.autoConsumeRiskyOpen ~= preferences.autoConsumeRiskyOpen then
            for _, instance in pairs(sessions) do
                if instance.autoNeeds then instance.autoNeeds.stock, instance.autoNeeds.nativeAttempt, instance.autoNeeds.blocked = nil, nil, {} end
            end
        end
        if not candidate.autoPutAway then
            for _, instance in pairs(sessions) do AutoPutAway.forget(instance) end
        end
        preferences, preferencesError = candidate, nil
        Log.detailed = candidate.detailedLog
        for key, value in pairs(patch) do Log.info(nil, "preference", key, value) end
    end
    return ok, err
end

local function initialize()
    if definitions then return end
    local data, err = Store.load("LootBox/categories")
    if err then loadError = err; Log.warn(nil, "categories-unreadable", "error", err) end
    if type(data) ~= "table" then data = {} end
    local dropped
    graph, dropped = Categories.salvage(type(data.categories) == "table" and data.categories or {})
    definitions = graph:list()
    for _, note in ipairs(dropped or {}) do Log.warn(nil, "category-repaired", "note", note) end
    nextCategoryId = type(data.nextId) == "number" and data.nextId >= 1 and data.nextId % 1 == 0 and data.nextId or 1
    for _, definition in ipairs(definitions) do
        local suffix = tonumber(definition.id:match("^custom:(%d+)$"))
        if suffix and suffix >= nextCategoryId then nextCategoryId = suffix + 1 end
    end
end

local nativeCatalog
local merged
-- The game's own items never change within a session; custom categories do.
function App.catalog()
    initialize()
    if merged then return merged end
    if not nativeCatalog then
        local err
        nativeCatalog, err = Catalog.read()
        if not nativeCatalog then return nil, err end
    end
    merged = { items = nativeCatalog.items, categories = {}, error = loadError }
    for index, category in ipairs(nativeCatalog.categories) do merged.categories[index] = category end
    for _, definition in ipairs(graph:list()) do
        definition.kind = "custom"
        merged.categories[#merged.categories + 1] = definition
    end
    return merged
end

function App.customCategories()
    initialize()
    return graph:list()
end

function App.categoryName(id) return Describe.category(id, App.category(id)) end

function App.category(id)
    initialize()
    for _, definition in ipairs(graph:list()) do
        if definition.id == id then return definition end
    end
end

local function saveDefinitions(nextDefinitions)
    local nextGraph, err = Categories.new(nextDefinitions)
    if not nextGraph then return nil, err end
    local ok
    ok, err = Store.save("LootBox/categories", { categories = nextDefinitions, nextId = nextCategoryId })
    if not ok then return nil, err end
    definitions, graph, merged, loadError = copy(nextDefinitions), nextGraph, nil, nil
    for _, instance in pairs(sessions) do instance.world.graph = graph end
    Log.info(nil, "categories", "count", #definitions)
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

local without = Labels.without

-- Deleting a category also removes it wherever this session can see it used.
function App.deleteCategory(id)
    initialize()
    local nextDefinitions, found = {}, false
    for _, entry in ipairs(definitions) do
        if entry.id == id then found = true
        else
            local kept = copy(entry)
            kept.includes = without(kept.includes, id)
            nextDefinitions[#nextDefinitions + 1] = kept
        end
    end
    if not found then return nil, "Unknown custom category" end
    local ok, err = saveDefinitions(nextDefinitions)
    if not ok then return nil, err end
    for _, instance in pairs(sessions) do instance:forgetCategory(id) end
    return true
end

local function escaped(text)
    text = tostring(text)
    local codes = {}
    for index = 1, #text do codes[index] = string.format("%04x", text:byte(index)) end
    local hex = table.concat(codes)
    return hex:gsub(string.rep(".", 96), "%0/"):gsub("/$", "")
end

local function identityOf(player)
    return tostring(getWorld():getWorld()) .. ":" .. tostring(player:getUsername()) .. ":" .. player:getPlayerNum()
end

-- While the categories cannot be read nothing says which custom ones exist, so all of them are kept,
-- and their numbers are not given out again.
local function knownCategory(id)
    if type(id) ~= "string" then return false end
    if Labels.direct(id) then return true end
    local number = loadError and tonumber(id:match("^custom:(%d+)$"))
    if number then nextCategoryId = math.max(nextCategoryId, number + 1); return true end
    return id:match("^native:.+") ~= nil or App.category(id) ~= nil
end

-- Keep every readable entry. One damaged value must not cost the player the rest.
local function repairState(state)
    local notes = {}
    local function note(text) notes[#notes + 1] = text end
    if type(state) ~= "table" then return {}, { "unreadable document" } end
    for _, name in ipairs({ "containerLabels", "itemLabels" }) do
        local clean = {}
        if state[name] ~= nil and type(state[name]) ~= "table" then note(name .. " unreadable") end
        for key, labels in pairs(type(state[name]) == "table" and state[name] or {}) do
            local list = {}
            if type(labels) == "table" then
                for _, id in ipairs(labels) do
                    if knownCategory(id) then list[#list + 1] = id
                    else note(name .. " dropped " .. tostring(id)) end
                end
            end
            if type(key) == "string" and #list > 0 then clean[key] = list end
        end
        state[name] = clean
    end
    local storage = {}
    for key, value in pairs(type(state.storage) == "table" and state.storage or {}) do
        local details = type(key) == "string" and Labels.details(value) or nil
        if details then storage[key] = details else note("storage dropped " .. tostring(key)) end
    end
    state.storage = storage
    for _, name in ipairs({ "keep", "keepTypes" }) do
        local clean = {}
        for key, flag in pairs(type(state[name]) == "table" and state[name] or {}) do
            if type(key) == "string" and flag == true then clean[key] = true end
        end
        state[name] = clean
    end
    local vehicle = state.vehicle
    if vehicle ~= nil then
        local valid = type(vehicle) == "table" and type(vehicle.script) == "string"
        for _, key in ipairs({ "id", "x", "y", "z" }) do valid = valid and type(vehicle[key]) == "number" end
        if not valid then state.vehicle = nil; note("vehicle dropped") end
    end
    local list = state.checklist
    if list ~= nil then
        local clean = { ids = {}, types = {}, all = false }
        if type(list) == "table" then
            for _, id in ipairs(type(list.ids) == "table" and list.ids or {}) do
                if knownCategory(id) then clean.ids[#clean.ids + 1] = id end
            end
            for _, fullType in ipairs(type(list.types) == "table" and list.types or {}) do
                if type(fullType) == "string" and fullType ~= "" then clean.types[#clean.types + 1] = fullType end
            end
        end
        state.checklist = clean
    end
    return state, notes
end

-- A username can settle after the player object exists, so the identity is
-- checked each time and only its encoding is remembered.
local paths = {}
local function pathOf(player)
    local identity = identityOf(player)
    if not paths[identity] then paths[identity] = "LootBox/world/" .. escaped(identity) end
    return paths[identity]
end

function App.get(playerIndex, passiveNeeds)
    initialize()
    local player = getSpecificPlayer(playerIndex or 0)
    if not player then return nil, "Enter a game to move or label items" end
    local path = pathOf(player)
    local existing = sessions[playerIndex or 0]
    if existing and existing.player == player and existing.path == path then
        if not passiveNeeds then existing.needsOnly = false end
        return existing
    end
    if existing then existing:cancel(true) end
    local loaded, err = Store.load(path)
    local state, notes = {}, {}
    if loaded ~= nil then state, notes = repairState(loaded) else state = repairState({}) end
    local instance = setmetatable({ player = player, state = state, path = path, needsOnly = passiveNeeds == true }, Instance)
    if err then
        instance.warning = err
        Log.warn(nil, "world-data-unreadable", "path", path, "error", err)
    end
    for _, text in ipairs(notes) do Log.warn(nil, "world-data-repaired", "note", text) end
    -- What left home while this was on says nothing about what came back while it was off.
    if not App.preference("autoPutAway") then state.trip = nil end
    instance.world = World.new(player, state)
    instance.world.graph, instance.world.preference = graph, App.preference
    instance.recovery = Recovery.new(player, instance.world, path)
    local receipt = instance.recovery.receipt
    if receipt and instance.world.currentKey then receipt.endpointKey = instance.world.currentKey(receipt.endpointKey) end
    instance.world.recovery = instance.recovery
    instance.jobs = instance:newRunner()
    sessions[playerIndex or 0] = instance
    Log.info(nil, "session", "player", Log.player(player), "storageLabels", instance:labelCount(), "categories", #definitions,
        "knownBins", instance.world.knownBins and #instance.world:knownBins(), "vehicle", state.vehicle and state.vehicle.script)
    return instance
end

Describe.given = function(container)
    for _, instance in pairs(sessions) do
        local name = instance.world:givenName(container)
        if name then return name end
    end
end

function App.peek(playerIndex)
    local instance = sessions[playerIndex or 0]
    if instance and instance.player == getSpecificPlayer(playerIndex or 0) and instance.path == pathOf(instance.player) then return instance end
end

function Instance:newRunner()
    local runner = Jobs.new(self.player, self.world, graph)
    runner.recovery = self.recovery
    return runner
end

function Instance:labelCount()
    local count = 0
    for _ in pairs(self.state.containerLabels) do count = count + 1 end
    return count
end

-- A failed write is reported and retried with the next change. It never blocks work.
function Instance:persist()
    self.seenAt = nil
    local ok, err = Store.save(self.path, self.state)
    if not ok then
        self.warning = "Could not save LootBox data: " .. tostring(err)
        Log.warn(nil, "save-failed", "path", self.path, "error", err)
    else self.warning = nil end
    return ok, err
end

-- A container, or the saved key of one that need not be loaded.
local function keyOf(self, target)
    if type(target) == "string" then return target end
    local key, err = self.world:key(target)
    return key, err or "Container is no longer available"
end

function Instance:labels(target)
    local key = keyOf(self, target)
    return key and copy(self.state.containerLabels[key] or {}) or {}
end

local function validLabels(ids)
    if type(ids) ~= "table" then return nil, "Labels must be a list" end
    local result, seen = {}, {}
    for _, id in ipairs(ids) do
        if knownCategory(id) and not seen[id] then result[#result + 1] = id; seen[id] = true end
    end
    return result
end

-- A mark on one item means nothing once no container and no list names it.
local function dropMarks(self, gone)
    local used = {}
    for _, labels in pairs(self.state.containerLabels) do for _, id in ipairs(labels) do used[id] = true end end
    for _, id in ipairs((self.state.checklist or {}).ids or {}) do used[id] = true end
    for _, id in ipairs(gone) do
        if Labels.itemOf(id) and not used[id] then
            for item, labels in pairs(self.state.itemLabels) do
                local kept = without(labels, id)
                if #kept ~= #labels then self.state.itemLabels[item] = #kept > 0 and kept or nil end
            end
        end
    end
end

local function changedStorage(self)
    self.storageRevision = (self.storageRevision or 0) + 1
    self.world:forgetGlance()
    return self:persist()
end

function Instance:setLabels(target, ids)
    local key, err = keyOf(self, target)
    if not key then return nil, err end
    local labels
    labels, err = validLabels(ids)
    if not labels then return nil, err end
    local before = self.state.containerLabels[key] or {}
    self.state.containerLabels[key] = #labels > 0 and labels or nil
    dropMarks(self, before)
    if target ~= key then self.world:_observe(target) end
    Log.info(nil, "storage-label", "key", key, "container", target ~= key and Log.container(target, self.player) or nil,
        "labels", table.concat(labels, "+"))
    return changedStorage(self)
end

function Instance:toggleLabel(target, id)
    local labels = self:labels(target)
    local kept = without(labels, id)
    if #kept == #labels then kept[#kept + 1] = id end
    return self:setLabels(target, kept)
end

function Instance:storageDetails(target)
    local key = keyOf(self, target)
    return key and copy(self.state.storage[key] or {}) or {}
end

-- details: {name, order}; only the fields given change. An empty name takes the name off.
function Instance:setStorage(target, details)
    local key, err = keyOf(self, target)
    if not key then return nil, err end
    local now, container = self:storageDetails(key), target ~= key and target or self.world.endpoints[key]
    for field, value in pairs(details) do now[field] = value end
    now = Labels.details(now) or {}
    if details.name ~= nil and container and self.world:valid(container) then
        local ok
        ok, err = self.world:rename(container, now.name)
        if ok == nil then return nil, err end
    end
    self.state.storage[key] = Labels.details(now)
    if target ~= key then self.world:_observe(target) end
    Log.info(nil, "storage-details", "key", key, "name", now.name, "order", now.order)
    return changedStorage(self)
end

-- The mark that stands for this very item, made the first time it is needed.
function Instance:markOf(item, make)
    local id = self.world:itemId(item)
    for _, label in ipairs(self.state.itemLabels[id] or {}) do if Labels.itemOf(label) then return label end end
    if not make or not id then return nil end
    local mark = Labels.ofItem(id, tostring(item:getFullType()))
    local labels = self:itemLabels(item)
    labels[#labels + 1] = mark
    self.state.itemLabels[id] = labels
    return mark
end

-- One item has one place, so a new one replaces the old.
function Instance:setItemPlace(item, target, on)
    local key, err = keyOf(self, target)
    if not key then return nil, err end
    local mark = self:markOf(item, on)
    if not mark then return true end
    for other, labels in pairs(self.state.containerLabels) do
        if other ~= key and Labels.has(labels, mark) then
            local kept = without(labels, mark)
            self.state.containerLabels[other] = #kept > 0 and kept or nil
        end
    end
    local labels = without(self:labels(key), mark)
    if on then labels[#labels + 1] = mark end
    return self:setLabels(target, labels)
end

function Instance:itemLabels(item)
    return copy(self.state.itemLabels[self.world:itemId(item)] or {})
end

function Instance:setItemLabels(item, ids)
    local labels, err = validLabels(ids)
    if not labels then return nil, err end
    local key = self.world:itemId(item)
    self.state.itemLabels[key] = #labels > 0 and labels or nil
    self.world:forgetGlance()
    Log.info(nil, "item-label", "item", Log.item(item, self.player), "labels", table.concat(labels, "+"))
    return self:persist()
end

function Instance:protect(item, value)
    local key = self.world:itemId(item)
    self.state.keep[key] = value == true or nil
    Log.info(nil, "keep", "item", Log.item(item, self.player), "on", value == true)
    return self:persist()
end

function Instance:keepType(fullType, value)
    self.state.keepTypes[fullType] = value == true or nil
    Log.info(nil, "keep-type", "type", fullType, "on", value == true)
    return self:persist()
end
function Instance:isTypeKept(fullType) return self.state.keepTypes[fullType] == true end

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
        return nil, "Choose categories or item types for the loot list" end
    local labels, err = validLabels(filter.ids)
    if not labels then return nil, err end
    local types, seen = {}, {}
    for _, fullType in ipairs(filter.types) do
        if type(fullType) == "string" and fullType ~= "" and not seen[fullType] then types[#types + 1] = fullType; seen[fullType] = true end
    end
    local before = (self.state.checklist or {}).ids or {}
    self.state.checklist = { ids = labels, types = types, all = false }
    dropMarks(self, before)
    Log.info(nil, "loot-list", "categories", table.concat(labels, "+"), "types", #types)
    return self:persist()
end
function Instance:onChecklist(kind, key)
    for _, value in ipairs((self.state.checklist or {})[kind] or {}) do if value == key then return true end end
    return false
end
function Instance:toggleChecklist(kind, key)
    local list = self:getChecklist()
    local kept = without(list[kind], key)
    if #kept == #list[kind] then kept[#kept + 1] = key end
    list[kind] = kept
    return self:setChecklist(list)
end

-- Marks one item to be picked up. The mark comes off once it is carried.
function Instance:setItemWanted(item, on)
    local mark = self:markOf(item, on)
    if not mark or (on and true or false) == self:onChecklist("ids", mark) then return true end
    return self:toggleChecklist("ids", mark)
end

local function unmarkCarried(self)
    for _, mark in ipairs(copy((self.state.checklist or {}).ids or {})) do
        local id, fullType = Labels.itemOf(mark)
        if id and Items.eachCarried(self.player, function(item)
            return tostring(item:getID()) == id and tostring(item:getFullType()) == fullType end) then
            Log.info(nil, "picked-up", "mark", mark)
            self:toggleChecklist("ids", mark)
        end
    end
end
function Instance:forgetCategory(id)
    for _, field in ipairs({ "containerLabels", "itemLabels" }) do
        for key, labels in pairs(self.state[field]) do
            local kept = without(labels, id)
            self.state[field][key] = #kept > 0 and kept or nil
        end
    end
    if self.state.checklist then self.state.checklist.ids = without(self.state.checklist.ids, id) end
    self.world:forgetGlance()
    local data = self:getSetups()
    local document = self.setups
    if document and data then
        local function clean(request)
            request.filter.ids = without(request.filter.ids, id)
            request.sourceLabels = without(request.sourceLabels, id)
            if request.destination.labels then request.destination.labels = without(request.destination.labels, id) end
        end
        for _, preset in ipairs(document.presets) do clean(preset.setup) end
        if document.lastSetup then clean(document.lastSetup) end
        Store.save(self.path .. "/setups", document)
    end
    return self:persist()
end

local function setupDocument(instance)
    if not instance.setups then
        local data, err = Store.load(instance.path .. "/setups")
        local dropped
        instance.setups, dropped = Setups.document(data or {})
        if err then Log.warn(nil, "presets-unreadable", "error", err) end
        for _, note in ipairs(dropped) do Log.warn(nil, "preset-repaired", "note", note) end
    end
    return instance.setups
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
    local candidate = copy(data)
    id, err = Setups.add(candidate, name, request, id)
    if not id then return nil, err end
    local ok
    ok, err = saveSetups(self, candidate)
    return ok and id or nil, err
end

function Instance:deleteSetup(id)
    local data, err = setupDocument(self)
    local candidate, found = copy(data), false
    for index, preset in ipairs(candidate.presets) do
        if preset.id == id then table.remove(candidate.presets, index); found = true; break end
    end
    if not found then return nil, "That preset no longer exists" end
    return saveSetups(self, candidate)
end

-- A job for certain items only cannot be set up again.
function Instance:rememberSetup(request)
    local options, err = App.getPreferences()
    if not options.rememberLastSetup or request.only then return true end
    local data
    data = setupDocument(self)
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
    for _, ids in ipairs({ request.filter.ids, request.sourceLabels, request.destination.labels }) do
        for _, id in ipairs(ids) do
            if id:match("^custom:") and not App.category(id) then return nil, "This preset uses a category that no longer exists" end
        end
    end
    context = context or {}
    if request.scope == "lootPane" then
        request.sourceContainers, err = self.world:smartLootSources(nil, true)
        if not request.sourceContainers then return nil, err end
    end
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
    for _, preset in ipairs(data.presets) do
        if preset.id == id then return self:resolveSetup(preset.setup, context) end
    end
    return nil, "That preset no longer exists"
end

function Instance:lastSetup(context)
    local options, err = App.getPreferences()
    if not options.rememberLastSetup then return nil end
    local data
    data = setupDocument(self)
    if not data.lastSetup then return nil end
    return self:resolveSetup(data.lastSetup, context)
end

function Instance:knownVehicles() return self.world:knownVehicles() end
function Instance:currentContainer()
    local loot = getPlayerLoot(self.player:getPlayerNum())
    return loot and loot.inventoryPane and loot.inventoryPane.inventory or nil
end
-- Planning never disturbs the job in progress. When one exists a second
-- runner plans, and takes over only once the player starts that plan.
function Instance:planner()
    local status = self.jobs:status()
    if not status.hasJob and status.canStart ~= false then return self.jobs end
    self.spare = self.spare or self:newRunner()
    return self.spare
end

function Instance:preview(request)
    local runner = self:planner()
    runner.graph = graph
    local plan, err = runner:preview(request)
    if plan then plan.owner, plan.label = runner, Describe.title(request, App.category)
    else Log.info(request.interaction, "PLAN-REFUSED", "reason", err, "request", Log.request(request)) end
    return plan, err
end

function Instance:previewCondense()
    local options = App.getPreferences()
    local runner = self:planner()
    runner.graph = graph
    local plan, err = runner:previewCondense({ rebalance = options.condenseRebalance,
        useUnequipped = options.condenseUseUnequipped, nested = options.condenseNested })
    if plan then plan.owner, plan.label = runner, "Condense bags" end
    return plan, err
end

local function quiet(controller) return controller and controller.automatic == true end

-- Background sips yield to anything the player asks for.
local function clearConsumption(self)
    local current = self.consumption
    if not current or not current:isBusy() then return true end
    if quiet(current) then current:cancel(true) end
    if current:isBusy() then return nil, (current.name or "Til Full") .. " is still finishing" end
    return true
end

local function retireConsumption(self)
    if self.consumption and not self.consumption:isBusy() then self.consumption = nil end
end

function Instance:start(plan, options)
    if not (options and options.automatic) then AutoPutAway.yield(self) end
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    if self.borrowed and self.borrowed.begin then
        Log.info(options and options.interaction, "PENDING-DROPPED", "reason", "a newer job was started before it began")
        self.borrowed = nil
    end
    retireConsumption(self)
    local chosen = {}
    for key, value in pairs(options or {}) do chosen[key] = value end
    if chosen.reviewBins == nil then chosen.reviewBins = App.reviewPreference(nil, true) end
    self.problem = nil
    local runner = plan.owner or self.jobs
    if runner == self.jobs then
        local started
        started, err = runner:start(plan, chosen)
        if started then runner.label, self.consumption = plan.label, nil end
        return started, err
    end
    err = runner:refusal(plan)
    if err then
        Log.info(chosen.interaction, "START-REFUSED", "reason", err, "player", Log.player(self.player))
        return nil, err
    end
    return self:takeOver({ runner = runner, plan = plan, options = chosen })
end

-- Pauses the current job and hands over once its native action has settled.
function Instance:takeOver(pending)
    local status = self.jobs:status()
    Log.info(pending.options and pending.options.interaction or pending.runner.interaction, "TAKEOVER", "replaces", self.jobs.label, "state", status.state)
    if status.canPause then
        local ok, err = self.jobs:pause("new job")
        if not ok then return nil, err end
        pending.paused = true
    end
    self.takeover = pending
    return self:advance()
end

-- The job that gave way stays resumable as the previous job.
function Instance:advance()
    local pending = self.takeover
    if not pending then return true end
    local status = self.jobs:status()
    if status.canPause or (status.hasJob and not status.canResume) then return true end
    self.takeover = nil
    local previous = self.jobs
    self.jobs = pending.runner
    retireConsumption(self)
    local started, err
    if pending.plan then started, err = self.jobs:start(pending.plan, pending.options)
    else started, err = self.jobs:resume() end
    if not started then
        self.jobs, self.problem = previous, err
        if pending.paused then previous:resume() end
        return nil, err
    end
    if pending.plan then
        self.jobs.label, self.spare = pending.plan.label, nil
        local intent = pending.plan.request and pending.plan.request.shortcutIntent
        -- A newer click of the same button supersedes its job, unless that one is carrying something.
        if status.canResume and intent ~= nil and intent == status.intent and (status.carried or 0) == 0 then
            Log.info(nil, "PREVIOUS-DROPPED", "job", previous.label, "reason", "same button")
            previous:cancel(true)
            return true
        end
        if status.canResume then self:discardPrevious() end
    end
    if status.canResume then self.parked = previous elseif not pending.plan then self.parked = nil end
    return true
end

-- Pressing a toolbar button again carries on with the job it started. Returns whether
-- there is one, then what became of it or why not.
function Instance:again(request)
    local intent = request.shortcutIntent
    local function started(status)
        return status.hasJob and status.intent == intent and status.sourceContainer == request.sourceContainer
    end
    if intent == nil then return false end
    local coming = self.takeover and self.takeover.plan and self.takeover.plan.request
    if coming and coming.shortcutIntent == intent and coming.sourceContainer == request.sourceContainer then return true, "running" end
    local status = self.jobs:status()
    local ok, err
    -- Certain items were chosen then, and others may have been since; only a load on its way is carried on with.
    if request.only and started(status) and status.canResume and (status.carried or 0) == 0 then return false end
    if started(status) then
        if not status.canResume then return true, "running" end
        ok, err = self:resume()
    elseif not request.only and self.parked and started(self.parked:status()) then ok, err = self:resumePrevious()
    else return false end
    return true, ok and "resumed" or nil, err
end

function Instance:resumePrevious()
    if not self.parked then return nil, "There is no previous job" end
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    return self:takeOver({ runner = self.parked })
end

function Instance:discardPrevious()
    if not self.parked then return end
    Log.info(nil, "PREVIOUS-DROPPED", "job", self.parked.label)
    self.parked:cancel(true)
    self.parked = nil
end

-- Eating, drinking and pouring borrow the player: the job pauses, then carries on.
function Instance:borrow(begin)
    AutoPutAway.yield(self)
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    if self.borrowed then return nil, "Another action is about to start" end
    if not self.jobs:status().canPause then return begin() end
    ok, err = self.jobs:pause("eating, drinking or pouring")
    if not ok then return nil, err end
    self.borrowed = { begin = begin }
    return self:lend()
end

function Instance:lend()
    local borrowed = self.borrowed
    if not borrowed then return true end
    if borrowed.begin then
        local status = self.jobs:status()
        if status.canPause or (status.hasJob and not status.canResume) then return true end
        local begin = borrowed.begin
        borrowed.begin = nil
        local ok, err = begin()
        if not ok then self.problem = err; self.borrowed = nil; self.jobs:resume(); return nil, err end
        return true
    end
    if self.consumption and self.consumption:isBusy() then return true end
    self.borrowed = nil
    retireConsumption(self)
    Log.info(self.jobs.interaction, "JOB-CONTINUES", "job", self.jobs.label)
    return self.jobs:resume()
end

function Instance:adopt(controller)
    self.consumption = controller
    controller:tick()
    if not controller:isBusy() and controller.state ~= "finished" then return nil, controller.reason end
    controller.adopted = true
    return true
end

function Instance:startPour(source, targets, interaction)
    return self:borrow(function()
        local controller, why = require("LootBox/Pour").new(self.player, self.world, source, targets, interaction)
        if not controller then return nil, why end
        return self:adopt(controller)
    end)
end

function Instance:worldPour(anchor, take, entries, interaction)
    return self:borrow(function()
        local controller, why = require("LootBox/Fixture").new(self.player, self.world, anchor, take, entries, interaction)
        if not controller then return nil, why end
        return self:adopt(controller)
    end)
end

function Instance:refillDispenser(stand, donors, bottle)
    return self:borrow(function()
        local controller, why = require("LootBox/Dispenser").new(self.player, self.world, stand, donors, bottle)
        if not controller then return nil, why end
        return self:adopt(controller)
    end)
end

function Instance:tillFull(items, kind, openingRecipe, menuSource)
    local options = App.getPreferences()
    if not options.tillFullEnabled then return nil, "Til Full is disabled in settings" end
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    local controller
    controller, err = TillFull.new(self.player, self.world, items,
        { kind = kind, both = options.tillFullBothNeeds, recipe = openingRecipe, source = menuSource })
    if not controller then return nil, err end
    if Log.guard("TillFull.alreadySatisfied", controller.alreadySatisfied, controller) then return true end
    return self:borrow(function() return self:adopt(controller) end)
end

function Instance:cancel(silent)
    self.takeover, self.borrowed = nil, nil
    if self.consumption and self.consumption:isBusy() then return self.consumption:cancel(silent) end
    return self.jobs:cancel(silent)
end
function Instance:pause(trigger)
    self.takeover = nil
    if self.consumption and self.consumption:isBusy() then return nil, (self.consumption.name or "Til Full") .. " cannot be paused; cancel it instead" end
    return self.jobs:pause(trigger or "player")
end
function Instance:resume()
    self.problem = nil
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    ok, err = self.jobs:resume()
    if ok then self.consumption = nil end
    return ok, err
end
function Instance:status()
    local controller = self.consumption
    local job = self.jobs:status()
    if controller and not controller:isBusy() and (quiet(controller) or job.hasJob) then controller = nil end
    local status = controller and controller:status() or job
    status.label = controller and (controller.label or controller.name) or self.jobs.label
    status.consuming = controller ~= nil and controller:isBusy()
    if self.problem and self.problemState ~= job.state then
        if self.problemState then self.problem = nil end
        self.problemState = self.problem and job.state or nil
    end
    if self.problem then status.reason = self.problem end
    if self.parked then status.previous = { label = self.parked.label, done = self.parked:status().done, total = self.parked:status().total } end
    status.warning = self.warning
    status.recovery = self:recoveryStatus()
    return status
end
function Instance:active()
    local status = self.jobs:status()
    return status.hasJob == true or (self.consumption ~= nil and self.consumption:isBusy() and not quiet(self.consumption))
end
function Instance:recoveryStatus() return self.recovery:status() end
function Instance:recoverPersonalGear()
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    ok, err = self.jobs:recoverPersonalGear()
    if ok then self.consumption = nil end
    return ok, err
end
function Instance:forgetPersonalGear()
    Log.warn(nil, "gear-forgotten", "player", Log.player(self.player))
    return self.recovery:forget()
end
function Instance:reviewBin() return self.jobs:reviewBin() end
function Instance:approveBin(review, options) return self.jobs:approveBin(review, options) end
function Instance:rejectBin(review) return self.jobs:rejectBin(review) end

-- Escape stops automatic work, unless the same press is closing something.
function App.escapeCloses(playerIndex)
    if getCore and getCore().isDoingTextEntry and getCore():isDoingTextEntry() then return true end
    local menu = getPlayerContextMenu and getPlayerContextMenu(playerIndex)
    if menu and menu.isAnyVisible and menu:isAnyVisible() then return true end
    return App.escapeGuard ~= nil and App.escapeGuard(playerIndex) == true
end

function App.onKeyStartPressed(key)
    if not Keyboard or key ~= Keyboard.KEY_ESCAPE then return end
    local instance = sessions[0]
    if not instance or App.escapeCloses(0) then return end
    if instance.consumption and instance.consumption:isBusy() then instance:cancel()
    else instance:pause("escape") end
end

-- OnPlayerUpdate also fires when the manager has never been opened. Defaults
-- cost no inventory reads or session creation; each local player has its own clock.
function App.onNeedsUpdate(player)
    local options = currentPreferences()
    if not (options.autoDrinkEquipped or options.autoConsumeCarried) or not player or not player:isLocalPlayer() then return end
    local index, now = player:getPlayerNum(), getTimestampMs()
    AutoNeeds.interruptObservation(sessions[index])
    local activity = lastNeedsUpdate[index]
    if not activity or activity.player ~= player then
        activity = {player=player, quietAt=now + 1000}
        lastNeedsUpdate[index] = activity
    end
    if player:isMoving() or player:isRunning() or player:isSprinting() or player:isAttacking()
        or player:isAiming() or player:hasTimedActions() then
        activity.quietAt = now + 1000
        return
    end
    if now < activity.quietAt or (activity.checked and now - activity.checked < 4000) then return end
    activity.checked = now
    if player ~= getSpecificPlayer(index) or not player:getCurrentSquare() then return end
    local instance = App.get(index, true)
    if not instance or instance.takeover or instance.borrowed then return end
    AutoNeeds.step(instance, options, currentPreferences, now)
end

-- Asked every update, answered once a second unless a put-away of its own is running.
function App.onHomeUpdate(player)
    local options = currentPreferences()
    if not options.autoPutAway or not player or not player:isLocalPlayer() then return end
    local index = player:getPlayerNum()
    if player ~= getSpecificPlayer(index) or not player:getCurrentSquare() then return end
    local instance = sessions[index]
    if not instance or instance.player ~= player then instance = App.get(index) end
    if instance then AutoPutAway.update(instance, getTimestampMs()) end
end

function App.tick()
    -- Poll as well as subscribing: native UI may consume the key event first.
    local escapeDown = Keyboard and isKeyDown and isKeyDown(Keyboard.KEY_ESCAPE) or false
    if escapeDown and not App.escapeDown then App.onKeyStartPressed(Keyboard.KEY_ESCAPE) end
    App.escapeDown = escapeDown
    local stamp = getTimestampMs()
    require("LootBox/Act").restore()
    for _, instance in pairs(sessions) do
        local consumption = instance.consumption
        if consumption then
            consumption:tick()
        end
        instance.jobs:tick()
        if instance.takeover then instance:advance() end
        if instance.borrowed then instance:lend() end
        if not instance.needsOnly and (not instance.lastObserve or stamp - instance.lastObserve >= 1000) then
            instance.lastObserve = stamp
            if instance.world:observeNearby() then instance.seenAt = instance.seenAt or stamp end
            unmarkCarried(instance)
            if instance.seenAt and stamp - instance.seenAt >= SIGHTINGS_MS then instance:persist() end
        end
    end
end

function App.save()
    for _, instance in pairs(sessions) do if instance.seenAt then instance:persist() end end
end

function App.reset()
    for _, instance in pairs(sessions) do
        instance:cancel(true)
        if instance.seenAt then instance:persist() end
    end
    sessions, definitions, graph, loadError, merged, nativeCatalog = {}, nil, nil, nil, nil, nil
    preferences, preferencesError = nil, nil
    App.escapeDown, lastNeedsUpdate = false, {}
end

if Events then
    Events.OnTick.Add(App.tick)
    if Events.OnPlayerUpdate then Events.OnPlayerUpdate.Add(App.onNeedsUpdate); Events.OnPlayerUpdate.Add(App.onHomeUpdate) end
    if Events.OnKeyStartPressed then Events.OnKeyStartPressed.Add(App.onKeyStartPressed) end
    if Events.OnSave then Events.OnSave.Add(App.save) end
    if Events.OnDisconnect then Events.OnDisconnect.Add(App.reset) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(App.reset) end
end

return App

