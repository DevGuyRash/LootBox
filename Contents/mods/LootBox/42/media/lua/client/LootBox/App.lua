local Categories = require "LootBox/Categories"
local Catalog = require "LootBox/Catalog"
local Store = require "LootBox/Store"
local World = require "LootBox/World"
local Jobs = require "LootBox/Jobs"
local Setups = require "LootBox/Setups"
local Recovery = require "LootBox/Recovery"
local TillFull = require "LootBox/TillFull"
local AutoNeeds = require "LootBox/AutoNeeds"
local Describe = require "LootBox/Describe"
local Log = require "LootBox/Log"
require "LootBox/CompletionHUD"

local App = {}
local Instance = {}
Instance.__index = Instance
local sessions, definitions, graph, loadError = {}, nil, nil, nil
local nextCategoryId = 1
local preferences, preferencesError
local lastNeedsUpdate = {}

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

local function without(list, id)
    local result = {}
    for _, value in ipairs(list or {}) do if value ~= id then result[#result + 1] = value end end
    return result
end

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
                    if type(id) == "string" and (id:match("^native:.+") or (id:match("^custom:.+") and App.category(id))) then list[#list + 1] = id
                    else note(name .. " dropped " .. tostring(id)) end
                end
            end
            if type(key) == "string" and #list > 0 then clean[key] = list end
        end
        state[name] = clean
    end
    local keep = {}
    for key, flag in pairs(type(state.keep) == "table" and state.keep or {}) do
        if type(key) == "string" and flag == true then keep[key] = true end
    end
    state.keep = keep
    local trash = {}
    for key, bin in pairs(type(state.trash) == "table" and state.trash or {}) do
        if type(key) == "string" and type(bin) == "table" and type(bin.x) == "number" and type(bin.y) == "number" and type(bin.z) == "number" then trash[key] = bin
        else note("trash can dropped") end
    end
    state.trash = trash
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
                if type(id) == "string" and (id:match("^native:.+") or App.category(id)) then clean.ids[#clean.ids + 1] = id end
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
    instance.world = World.new(player, state)
    instance.world.graph = graph
    instance.recovery = Recovery.new(player, instance.world, path)
    instance.world.recovery = instance.recovery
    instance.jobs = instance:newRunner()
    sessions[playerIndex or 0] = instance
    Log.info(nil, "session", "player", Log.player(player), "storageLabels", instance:labelCount(), "categories", #definitions,
        "knownBins", instance.world.hasKnownBins and instance.world:hasKnownBins(), "vehicle", state.vehicle and state.vehicle.script)
    return instance
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
    local ok, err = Store.save(self.path, self.state)
    if not ok then
        self.warning = "Could not save LootBox data: " .. tostring(err)
        Log.warn(nil, "save-failed", "path", self.path, "error", err)
    else self.warning = nil end
    return ok, err
end

function Instance:labels(container)
    local key = self.world:key(container)
    return key and copy(self.state.containerLabels[key] or {}) or {}
end

local function validLabels(ids)
    if type(ids) ~= "table" then return nil, "Labels must be a list" end
    local result, seen = {}, {}
    for _, id in ipairs(ids) do
        local known = type(id) == "string" and (id:match("^native:.+") or App.category(id))
        if known and not seen[id] then result[#result + 1] = id; seen[id] = true end
    end
    return result
end

function Instance:setLabels(container, ids)
    local key, err = self.world:key(container)
    if not key then return nil, err or "Container is no longer available" end
    local labels
    labels, err = validLabels(ids)
    if not labels then return nil, err end
    self.state.containerLabels[key] = #labels > 0 and labels or nil
    self.world:discover()
    Log.info(nil, "storage-label", "container", Log.container(container, self.player), "labels", table.concat(labels, "+"))
    return self:persist()
end

function Instance:itemLabels(item)
    return copy(self.state.itemLabels[self.world:itemId(item)] or {})
end

function Instance:setItemLabels(item, ids)
    local labels, err = validLabels(ids)
    if not labels then return nil, err end
    local key = self.world:itemId(item)
    self.state.itemLabels[key] = #labels > 0 and labels or nil
    Log.info(nil, "item-label", "item", Log.item(item, self.player), "labels", table.concat(labels, "+"))
    return self:persist()
end

function Instance:protect(item, value)
    local key = self.world:itemId(item)
    self.state.keep[key] = value == true or nil
    Log.info(nil, "keep", "item", Log.item(item, self.player), "on", value == true)
    return self:persist()
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
        return nil, "Choose categories or item types for the loot list" end
    local labels, err = validLabels(filter.ids)
    if not labels then return nil, err end
    local types, seen = {}, {}
    for _, fullType in ipairs(filter.types) do
        if type(fullType) == "string" and fullType ~= "" and not seen[fullType] then types[#types + 1] = fullType; seen[fullType] = true end
    end
    self.state.checklist = { ids = labels, types = types, all = false }
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
function Instance:forgetCategory(id)
    for _, field in ipairs({ "containerLabels", "itemLabels" }) do
        for key, labels in pairs(self.state[field]) do
            local kept = without(labels, id)
            self.state[field][key] = #kept > 0 and kept or nil
        end
    end
    if self.state.checklist then self.state.checklist.ids = without(self.state.checklist.ids, id) end
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

function Instance:rememberSetup(request)
    local options, err = App.getPreferences()
    if not options.rememberLastSetup then return true end
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
    if not status.hasJob and status.canPreview ~= false then return self.jobs end
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
    if runner ~= self.jobs and self.jobs:status().canPause then return nil, "Pause or finish the current job before condensing" end
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
        self:persist()
        local started
        started, err = runner:start(plan, chosen)
        if started then runner.label, self.consumption = plan.label, nil end
        return started, err
    end
    self.takeover = { runner = runner, plan = plan, options = chosen }
    Log.info(chosen.interaction, "TAKEOVER", "replaces", self.jobs.label, "state", self.jobs:status().state)
    if self.jobs:status().canPause then
        ok, err = self.jobs:pause("new job")
        if not ok then self.takeover = nil; return nil, err end
    end
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
    if status.canResume then
        if self.parked then Log.info(nil, "PREVIOUS-DROPPED", "job", self.parked.label); self.parked:cancel(true) end
        self.parked = previous
    end
    self.jobs, self.spare = pending.runner, nil
    retireConsumption(self)
    self:persist()
    local started, err = self.jobs:start(pending.plan, pending.options)
    if started then self.jobs.label = pending.plan.label; return true end
    self.jobs = previous
    if self.parked == previous then self.parked = nil end
    self.problem = err
    return nil, err
end

function Instance:resumePrevious()
    local previous = self.parked
    if not previous then return nil, "There is no previous job" end
    local ok, err = clearConsumption(self)
    if not ok then return nil, err end
    local status = self.jobs:status()
    if status.canPause or (status.hasJob and not status.canResume) then return nil, "Pause or finish the current job first" end
    self.parked = status.canResume and self.jobs or nil
    self.jobs = previous
    retireConsumption(self)
    return self.jobs:resume()
end

function Instance:discardPrevious()
    if not self.parked then return end
    Log.info(nil, "PREVIOUS-DROPPED", "job", self.parked.label)
    self.parked:cancel(true)
    self.parked = nil
end

-- Eating, drinking and pouring borrow the player: the job pauses, then carries on.
function Instance:borrow(begin)
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

function App.tick()
    -- Poll as well as subscribing: native UI may consume the key event first.
    local escapeDown = Keyboard and isKeyDown and isKeyDown(Keyboard.KEY_ESCAPE) or false
    if escapeDown and not App.escapeDown then App.onKeyStartPressed(Keyboard.KEY_ESCAPE) end
    App.escapeDown = escapeDown
    local stamp = getTimestampMs()
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
            if instance.world:observeNearby() then instance:persist() end
        end
    end
end

function App.reset()
    for _, instance in pairs(sessions) do instance:cancel(true) end
    sessions, definitions, graph, loadError, merged, nativeCatalog = {}, nil, nil, nil, nil, nil
    preferences, preferencesError = nil, nil
    App.escapeDown, lastNeedsUpdate = false, {}
end

if Events then
    Events.OnTick.Add(App.tick)
    if Events.OnPlayerUpdate then Events.OnPlayerUpdate.Add(App.onNeedsUpdate) end
    if Events.OnKeyStartPressed then Events.OnKeyStartPressed.Add(App.onKeyStartPressed) end
    if Events.OnDisconnect then Events.OnDisconnect.Add(App.reset) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(App.reset) end
end

return App

