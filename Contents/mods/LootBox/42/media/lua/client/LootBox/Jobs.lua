local Native = require "LootBox/Native"
local Categories = require "LootBox/Categories"
local Routing = require "LootBox/Routing"
local Carry = require "LootBox/Carry"
local Condense = require "LootBox/Condense"
local Clock = require "LootBox/Clock"
local Setups = require "LootBox/Setups"
local Completion = require "LootBox/CompletionFeedback"
local Log = require "LootBox/Log"
local Sort = require "LootBox/Sort"
local Jobs = {}
Jobs.__index = Jobs

-- How long a searched multiplayer container may stay empty before the job moves
-- on. The game never acknowledges an empty reply.
local REPLY_MS = 1000
local HAULED, MAX_PREVIEWS, MAX_FAULTS, MAX_LOGGED, MAX_REFUSALS = {hauled = true}, 4, 3, 12, 3
-- What the player has to do before anything can continue, by the code Native reports it under.
local PLAYER_MUST = {seated = true, corpse = true, trading = true}
local WAITING = "Waiting for your current action to finish. This job will continue automatically."
local FULL, HEAVY = "No matching destination with room for this item", "You cannot carry anything this heavy on top of what you have"

local now = Clock.now
local function coordinates(square)
    return {x = square:getX(), y = square:getY(), z = square:getZ()}
end
local function pointKey(point) return point.x .. ":" .. point.y .. ":" .. point.z end
local function copyList(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end
local function copyRecord(record)
    local result = {}
    for key, value in pairs(record) do result[key] = value end
    result.itemId = record.itemId or record.item:getID()
    result.fullType = record.fullType or tostring(record.item:getFullType())
    return result
end

local function sourceItem(record, source)
    local item = source:getItemWithID(record.itemId)
    if item and tostring(item:getFullType()) == record.fullType then return item end
end
local function cloneRequest(request)
    local result = {}
    for key, value in pairs(request) do result[key] = value end
    result.filter = { all = request.filter.all == true, ids = {}, types = {} }
    for _, id in ipairs(request.filter.ids or {}) do table.insert(result.filter.ids, id) end
    for _, fullType in ipairs(request.filter.types or {}) do table.insert(result.filter.types, fullType) end
    result.destination = {}
    for key, value in pairs(request.destination) do result.destination[key] = value end
    result.sourceLabels = copyList(request.sourceLabels)
    if request.sourceContainers then result.sourceContainers = copyList(request.sourceContainers) end
    if request.destination.labels then result.destination.labels = copyList(request.destination.labels) end
    if type(request.area) == "table" then
        result.area = {}
        for key, value in pairs(request.area) do result.area[key] = value end
    end
    return result
end

function Jobs.new(player, world, graph)
    return setmetatable({ player = player, world = world, graph = graph,
        native = Native.new(player), routing = Routing.new(), view = { state = "idle", done = 0, total = 0 },
        reviews = {}, previews = {} }, Jobs)
end

local function engineBusy(self)
    return self.execution ~= nil or self.ending ~= nil or self.native:isBusy()
end

local function remember(self, plan, reviewed)
    self.reviews[plan] = reviewed
    table.insert(self.previews, plan)
    if #self.previews > MAX_PREVIEWS then self.reviews[table.remove(self.previews, 1)] = nil end
end

-- Skipped items by reason, for the log. Written out only when a job starts.
local function note(notes, reason, item, player)
    if not notes then return end
    local entry = notes[reason]
    if not entry then entry = {count = 0, samples = {}}; notes[reason] = entry end
    entry.count = entry.count + 1
    if #entry.samples < 3 then entry.samples[#entry.samples + 1] = Log.item(item, player) end
end

function Jobs:status()
    local result = {}
    for key, value in pairs(self.view) do result[key] = value end
    result.hasJob = self.execution ~= nil or self.ending ~= nil or self.suspended ~= nil
    result.recoveryRequired = self.recoveryRequired == true
    result.intent = result.hasJob and self.plan and self.plan.request and self.plan.request.shortcutIntent or nil
    result.sourceContainer = result.hasJob and self.plan and self.plan.request and self.plan.request.sourceContainer or nil
    result.action = result.hasJob and self.plan and (self.plan.action or "transfer") or nil
    result.interaction = self.interaction
    result.canResume = self.suspended ~= nil and not self.ending and not self.native:isBusy()
        and (not self.recoveryRequired or self.suspended.execution.recoveryOnly == true)
    result.canPause = self.execution ~= nil and not self.ending
    -- The engine is idle; preview() works during a job. AutoNeeds still reads the older name.
    result.canStart = not engineBusy(self)
    result.canPreview = result.canStart
    local execution = self.execution or self.suspended and self.suspended.execution
    result.reviewBins = not execution or execution.reviewBins ~= false
    if execution and execution.condense then result.condense = execution.condense:status() end
    return result
end

function Jobs:captureRecord(record)
    local result = copyRecord(record)
    if result.groundSquare then
        local square = result.groundSquare
        result.groundPoint = {x = square:getX(), y = square:getY(), z = square:getZ()}
    else result.sourceAnchor = result.sourceAnchor or self.world:sourceAnchor(result.source) end
    return result
end

local function weight(item)
    return math.max(0, item:getUnequippedWeight())
end

local function carriedDestination(self, request)
    return request.destination.kind == "inventory"
        or (request.destination.kind == "container" and self.world:owns(request.destination.ref))
end

-- Whether a container takes this item now, on top of what a plan already promised it.
-- Returns true, or nil, a reason, and "capacity" when only space is missing.
function Jobs:admits(item, destination, reservations)
    if destination:isInside(item) or not destination:isItemAllowed(item) then return nil, "That container does not take this item" end
    -- The floor holds 50 a tile; the game picks one with room.
    local main, floor = destination == self.player:getInventory(), destination:getType() == "floor"
    if not floor and not destination:hasRoomFor(self.player, item) then return nil, FULL, "capacity" end
    local delta = self.world:carryDelta(item, destination)
    local current, maximum = self.world:carrying()
    local reserved, added = reservations and reservations[destination] or 0, main and math.max(0, delta) or weight(item)
    -- The game has already agreed to this item alone; only promised space has to be added up.
    if reserved > 0 and not floor and not (main and maximum == math.huge)
        and destination:getCapacityWeight() + reserved + added > destination:getEffectiveCapacity(self.player) + 0.005 then
        return nil, FULL, "capacity"
    end
    local reservedCarry = reservations and reservations.carriedMass or 0
    if delta > 0 and current + reservedCarry + delta > maximum + 0.0001 then return nil, HEAVY, "capacity" end
    if reservations then
        reservations[destination] = reserved + added
        reservations.carriedMass = reservedCarry + math.max(0, delta)
    end
    return true
end

-- pass comes from world:destinationPass; without one the world is read again for this item.
function Jobs:choose(request, item, reservations, pass)
    local err
    if not pass then
        pass, err = self.world:destinationPass(request, self.activeGraph or self.graph)
        if not pass then return nil, err end
    end
    local ok, candidates, problem, trace = pcall(self.world.destinations, self.world, request, item, pass)
    if not ok then
        Log.fault(self.interaction, "World.destinations", candidates, "trace", problem, "extra", trace, "item", Log.item(item, self.player))
        return nil, "Destination discovery failed: " .. tostring(candidates)
    end
    if not candidates then return nil, problem end
    local reason, code = FULL, nil
    for _, destination in ipairs(candidates) do
        local same = destination == item:getContainer()
        if same and destination:getType() == "floor" and request.destination.ref then
            local worldItem = item:getWorldItem()
            same = not worldItem or worldItem:getSquare() == request.destination.ref
        end
        if not same then
            local admitted, why, kind = self:admits(item, destination, reservations)
            if admitted then return destination end
            code = code or kind
            if why == HEAVY then reason = HEAVY end
        end
    end
    return nil, reason, code
end

local function matchesSelection(graph, request, descriptor, item, player)
    local leave = request.excludeUnwanted == true or request.destination.kind == "inventory"
    return graph:matchesFilter(request.filter, descriptor) and not (leave and item.isUnwanted and item:isUnwanted(player))
end

local function validate(request)
    if type(request) ~= "table" or type(request.filter) ~= "table" or type(request.destination) ~= "table" then
        return nil, "Choose what to move, where to look, and a destination"
    end
    local valid, err = Setups.request(request)
    if not valid then return nil, err end
    if not valid.filter.all and #valid.filter.ids == 0 and #valid.filter.types == 0 then return nil, "Select at least one category or item type" end
    if request.scope == "container" and not request.sourceContainer then return nil, "Choose a source container" end
    if request.scope == "lootPane" and type(request.sourceContainers) ~= "table" then return nil, "Choose the visible loot containers" end
    if request.scope == "labeled" and #valid.sourceLabels == 0 then return nil, "Choose a source label" end
    if request.destination.kind == "container" and not request.destination.ref then return nil, "Choose a destination container" end
    if request.destination.kind == "matching" and (request.scope ~= "inventory" or request.includeBags ~= true) then
        return nil, "Matching transfers use all carried containers, including bags"
    end
    return true
end

-- Why a filled bag in the world cannot move whole. Contents that are moved one
-- by one, or deleted with the bag, must all belong to the selection.
local function bagReason(self, request, graph, record)
    local inside = not self.world:owns(record.source) and self.world:filledBag(record.item)
    if not inside or not request.includeBags and (request.destination.kind ~= "trash" or request.filter.all) then return nil end
    for _, entry in ipairs(self.world:records(inside, true)) do
        if self.world:protected(entry.item) or not matchesSelection(graph, request, entry.descriptor, entry.item, self.player) then
            return "Bag holds items outside this selection"
        end
    end
end

local function withContents(self, item, name)
    local inside = self.world:filledBag(item)
    name = tostring(name or item:getName())
    return inside and name .. " (with " .. inside:getItems():size() .. " items inside)" or name
end

-- A bag that is emptied first must come after its contents, innermost first.
local function bagsLast(self, request, records)
    if not request.includeBags then return records end
    local result, bags = {}, {}
    for _, record in ipairs(records) do
        if not self.world:owns(record.source) and self.world:filledBag(record.item) then bags[#bags + 1] = record
        else result[#result + 1] = record end
    end
    for index = #bags, 1, -1 do bags[index].emptied = true; result[#result + 1] = bags[index] end
    return result
end

-- A preview never changes the running job. options.interaction logs the plan under that number.
function Jobs:preview(request, options)
    local interaction = options and options.interaction or type(request) == "table" and request.interaction or nil
    local plan, err = self:buildPlan(request)
    if not plan then
        if interaction then Log.info(interaction, "PLAN-REFUSED", "reason", err, "request", Log.request(request), "player", Log.player(self.player)) end
        return nil, err
    end
    if interaction then self:logPlan(interaction, self.reviews[plan]) end
    return plan
end

function Jobs:logPlan(interaction, reviewed)
    if reviewed.logged == interaction or not Log.detailed then return end
    reviewed.logged = interaction
    local request = reviewed.request
    Log.trace(interaction, "PLAN", "action", reviewed.action or "transfer", "request", Log.request(request),
        "records", #(reviewed.records or {}), "skipped", #reviewed.skipped, "unopened", #(reviewed.unknownSources or {}),
        "bins", #reviewed.bins, "rooms", reviewed.survey and reviewed.survey:status().roomsTotal)
    for reason, entry in pairs(reviewed.notes or {}) do
        Log.trace(interaction, "PLAN-SKIP", "reason", reason, "count", entry.count, "samples", "{" .. table.concat(entry.samples, " ") .. "}")
    end
    local function containers(event, list)
        for index, container in ipairs(list) do
            if index > MAX_LOGGED then Log.trace(interaction, event, "more", #list - MAX_LOGGED); break end
            Log.trace(interaction, event, "container", Log.container(container, self.player))
        end
    end
    containers("PLAN-FROM", reviewed.sources or {})
    containers("PLAN-TO", reviewed.destinations or {})
end

function Jobs:buildPlan(request)
    local ok, err = validate(request)
    if not ok then return nil, err end
    local scan
    scan, err = self.world:scan(request)
    if not scan then return nil, err end
    if request.destination.kind == "matching" then
        request = cloneRequest(request)
        request.destination.mode = request.destination.mode or "nearby"
        local ordered
        ordered, err = self.world:matchingOrder(scan.items or {})
        if not ordered then return nil, err end
        scan.items = ordered
        local matching
        matching, err = self.world:matchingTargets(request.destination.mode, scan.items or {})
        if not matching then return nil, err end
        request.destination.targets = matching
    end
    local plan = { owner = self, request = cloneRequest(request),
        moves = {}, skipped = {}, warnings = {}, records = {}, sources = scan.sources or {},
        trash = {}, approved = {}, unknownSources = {} }
    plan.request.destination.targets = nil
    local targets, notes, destinations, seenDestinations = {}, Log.detailed and {} or nil, {}, {}
    for _, warning in ipairs(scan.warnings or {}) do table.insert(plan.warnings, warning) end
    local preparesBags = false
    if request.destination.kind == "inventory" then
        local incoming = 0
        for _, record in ipairs(scan.items or {}) do
            if not self.world:owns(record.source) and matchesSelection(self.graph, request, record.descriptor, record.item, self.player)
                and not self.world:protected(record.item) then incoming = incoming + weight(record.item) end
        end
        preparesBags = Carry.new(self.player, self.world):next(self.world:gearRecords(plan.sources), incoming) ~= nil
    end
    if request.destination.kind == "trash" then
        if isClient() and not getServerOptions():getBoolean("TrashDeleteAll") then
            return nil, "This server disables native trash deletion (TrashDeleteAll)"
        end
        local bins, warnings = self.world:trashCandidates()
        for _, warning in ipairs(warnings or {}) do table.insert(plan.warnings, warning) end
        for _, bin in ipairs(bins or {}) do
            local target = self.world:trashTarget(bin)
            if target and target.needsInspection then
                target.approved = {}
                targets[#targets + 1] = target
            else
            local approved, blocked, names = {}, nil, {}
            local contents = bin:getItems()
            for index = 0, contents:size() - 1 do
                local item = contents:get(index)
                local protected, why = self.world:protected(item)
                if protected then
                    blocked = tostring(item:getName()) .. " (" .. tostring(why) .. ")"
                    note(notes, "Bin holds a protected item: " .. tostring(why), item, self.player)
                end
                approved[self.world:itemId(item)] = true
                names[#names + 1] = withContents(self, item)
            end
            if blocked then
                table.insert(plan.warnings, "Skipping " .. self.world:name(bin) .. ": contains protected items, such as " .. blocked)
            else
                plan.trash[#plan.trash + 1] = bin
                plan.approved[bin] = approved
                if target then target.approved = approved; targets[#targets + 1] = target end
                if #names > 0 then
                    table.insert(plan.warnings, "Emptying " .. self.world:name(bin) .. " also deletes its " .. #names .. " existing items: " .. table.concat(names, ", "))
                end
            end
            end
        end
        for _, target in ipairs(self.world:unloadedTrashTargets()) do
            target.approved = {}
            targets[#targets + 1] = target
        end
        if #targets == 0 then return nil, "No usable known trash can. Approach a real trash can first." end
        if #targets > #plan.trash then
            table.insert(plan.warnings, "Uninspected bins will be approached and inspected first. Your bin-review setting controls whether approval is automatic or shown in a review window.")
        end
        table.insert(plan.warnings, "Cleanup permanently empties the whole trash can, including the existing contents listed above.")
        table.insert(plan.warnings, "Bin choice compares travel, carrying trips and bin emptyings. Initial travel is estimated; completed walks improve later choices. New bins are inspected before use.")
    end
    local reservations, pass = {}, nil
    if request.destination.kind ~= "trash" then
        pass, err = self.world:destinationPass(request, self.graph)
    end
    local passError = err
    for _, record in ipairs(bagsLast(self, request, scan.items or {})) do
        local item = record.item
        if matchesSelection(self.graph, request, record.descriptor, record.item, self.player) then
            local protected, protection = self.world:protected(item)
            local reason, status
            if protected then reason, status = protection or "Protected item", "Protected"
            elseif request.destination.kind == "inventory" and self.world:owns(record.source) then reason, status = "Already in carried storage", "Already carried"
            elseif self.world:alreadySorted(request, item, self.graph) then reason, status = "Already sorted", "Already sorted"
            else
                reason = bagReason(self, request, self.graph, record)
                if reason then status = "Protected" end
            end
            local destination, admission
            if not reason and request.destination.kind ~= "trash" then
                if pass then destination, reason, admission = self:choose(request, item, reservations, pass)
                else reason = passError end
                if reason and admission == "capacity" and preparesBags then
                    reason, status = nil, "Recheck after bag setup"
                end
            end
            if destination and not seenDestinations[destination] then
                seenDestinations[destination], destinations[#destinations + 1] = true, destination
            end
            if reason then note(notes, reason, item, self.player) end
            local row = { itemName = record.emptied and record.itemName or withContents(self, item, record.itemName), from = record.from,
                to = request.destination.kind == "trash" and "Trash can (fill, then empty)"
                    or (destination and self.world:name(destination) or (status == "Recheck after bag setup" and "Carried storage after bag setup" or "")), reason = reason,
                status = status or (reason and "Left in place" or "Move"), tone = reason and "warning" or "success" }
            if reason then table.insert(plan.skipped, row)
            else
                table.insert(plan.moves, row)
                table.insert(plan.records, record)
            end
        end
    end
    if preparesBags then table.insert(plan.warnings, "Useful bags will be prepared first. Items waiting for that space are checked again during the job; native capacity can still leave an item in place.") end
    local unknown = 0
    for _, source in ipairs(plan.sources) do
        if not source:isExplored() then unknown = unknown + 1; plan.unknownSources[#plan.unknownSources + 1] = source end
    end
    if unknown > 0 then
        table.insert(plan.warnings, unknown .. " unopened containers will be approached and searched normally; matching newly revealed contents may be added to this job.")
        if isClient() then table.insert(plan.warnings, "In multiplayer a container can look empty for a moment after it is opened.") end
    end
    plan.pending = unknown + (#targets - #plan.trash)
    if scan.survey then
        local status = scan.survey:status()
        plan.building = {roomsTotal = status.roomsTotal}
        plan.pending = plan.pending + status.roomsTotal
        table.insert(plan.warnings, "The building will be searched progressively across its rooms and floors. New matching contents may be added after walking and exploration. Blocked or unloaded sections are reported as unsearched.")
    end
    table.insert(plan.warnings, "Live capacity, access, and item changes are checked again before each native action.")
    local records, approved = {}, {}
    for _, record in ipairs(plan.records) do records[#records + 1] = self:captureRecord(record) end
    for bin, ids in pairs(plan.approved) do
        approved[bin] = {}
        for id, value in pairs(ids) do approved[bin][id] = value end
    end
    for _, target in ipairs(targets) do target.approved = target.container and approved[target.container] or {} end
    for _, bin in ipairs(plan.trash) do destinations[#destinations + 1] = bin end
    remember(self, plan, { request = cloneRequest(request), records = records,
        sources = copyList(plan.sources), unknownSources = copyList(plan.unknownSources),
        trash = copyList(plan.trash), bins = targets, survey = scan.survey, binProbe = #targets > 0 and #plan.trash == 0, approved = approved,
        skipped = copyList(plan.skipped), notes = notes, destinations = destinations, graph = Categories.new(self.graph:list()) })
    return plan
end

function Jobs:previewCondense(options)
    if engineBusy(self) then return nil, "Finish or cancel the current job before condensing" end
    local controller, err = Condense.new(self.world, options)
    if not controller then return nil, err end
    local info
    info, err = controller:preview()
    if not info then return nil, err end
    local request = {scope = "inventory", shortcutIntent = "condense", includeBags = true, filter = {all = true, ids = {}, types = {}},
        destination = {kind = "inventory"}}
    local display = {}
    for _, key in ipairs({"mode", "eligible", "bagCount", "beforeWeight", "estimatedSaving", "useUnequipped", "nested", "reason"}) do display[key] = info[key] end
    display.useUnequipped, display.nested = options ~= nil and options.useUnequipped == true, options ~= nil and options.nested == true
    local plan = {owner = self, action = "condense", condense = display,
        request = cloneRequest(request), moves = {}, skipped = {}, warnings = {}, pending = info.planning and 1 or 0}
    for _, row in ipairs(info.steps or {}) do
        plan.moves[#plan.moves + 1] = {itemName = row.itemName, from = row.from, to = row.to,
            status = row.temporary and "Temporary buffer" or "Reposition", tone = row.temporary and "warning" or "success"}
    end
    plan.warnings[1] = "This shows the first arrangement. Condense checks current items, bag eligibility and native capacity before every transfer."
    remember(self, plan, {action = "condense", condense = controller, request = request,
        graph = Categories.new(self.graph:list()), bins = {}, skipped = {}})
    return plan
end

-- A seated player cannot walk. Says so once instead of failing every item.
local function seatedProblem(self, reviewed)
    if reviewed.action == "condense" or not self.player:getVehicle() then return nil end
    local destination, walks = reviewed.request.destination, #reviewed.bins > 0 or reviewed.survey ~= nil
    local function away(container)
        return not self.world:owns(container) and not self.native:reachable(container)
    end
    walks = walks or destination.kind == "floor" or destination.kind == "labels"
        or destination.kind == "container" and away(destination.ref)
    for _, target in ipairs(destination.targets or {}) do walks = walks or away(target.ref) end
    for _, record in ipairs(reviewed.records) do
        if walks then break end
        walks = record.groundPoint ~= nil or away(record.source)
    end
    for _, source in ipairs(reviewed.unknownSources) do walks = walks or away(source) end
    return walks and "Get out of the vehicle before starting this job" or nil
end

-- Why this plan cannot start now, whatever the engine is doing.
function Jobs:refusal(plan)
    local reviewed = self.reviews[plan]
    if not reviewed then return "Preview this job again before starting" end
    return seatedProblem(self, reviewed) or (self.native:obstacle())
end

function Jobs:bindInteraction(options, label)
    self.interaction = options and options.interaction or Log.intent("engine", label, self.player)
    self.native.interaction = self.interaction
    if self.recovery then self.recovery.interaction = self.interaction end
end

function Jobs:start(plan, options)
    local reviewed, reason = self.reviews[plan], nil
    if engineBusy(self) then reason = "A LootBox job is already active"
    else reason = self:refusal(plan) end
    if reason then
        Log.info(options and options.interaction or reviewed and reviewed.request.interaction, "START-REFUSED", "reason", reason, "player", Log.player(self.player))
        return nil, reason
    end
    self:bindInteraction({interaction = options and options.interaction or reviewed.request.interaction},
        reviewed.request.shortcutIntent or reviewed.action or "transfer")
    self:logPlan(self.interaction, reviewed)
    self.reviews, self.previews, self.recoveryRequired = {}, {}, nil
    self.completion = {elapsed = 0, movedWeight = 0}
    self.plan, self.ending, self.hauled, self.suspended = reviewed, nil, {}, nil
    self.activeGraph, self.startedAt, self.lastTick, self.opCount, self.loggedPhase = reviewed.graph, now(), now(), 0, nil
    Log.info(self.interaction, "START", "action", reviewed.action or "transfer", "records", #(reviewed.records or {}),
        "excluded", #reviewed.skipped, "unopened", #(reviewed.unknownSources or {}), "bins", #reviewed.bins, "player", Log.player(self.player))
    if reviewed.action == "condense" then
        local info = reviewed.condense:status()
        self.view = {state = "running", done = 0, moved = 0, cleared = 0, total = info.eligible or 0,
            skipped = 0, reasons = {}, carried = 0, condense = info,
            reason = "Planning carried-item condensation."}
        self.execution = {phase = "condense", condense = reviewed.condense, batch = {}, reviewBins = false, unlocked = {}}
        return true
    end
    self.view = { state = "running", done = 0, moved = 0, cleared = 0, deferred = 0, total = #reviewed.records, skipped = 0,
        reasons = {}, carried = 0 }
    self.execution = self:createExecution(reviewed)
    self.execution.reviewBins = not (options and options.reviewBins == false)
    self.carry = Carry.new(self.player, self.world)
    self.execution.afterCarry, self.execution.phase = reviewed.binProbe and "binProbe" or "source", self:inArmsReach(reviewed) and "source" or "carry"
    if reviewed.binProbe then self.execution.binProbeIndex = 1 end
    if reviewed.survey then self.view.survey = reviewed.survey:status() end
    return true
end

-- Both ends can be used from here, so nothing has to be carried.
function Jobs:inArmsReach(reviewed)
    local destination = reviewed.request.destination
    if destination.kind ~= "container" or reviewed.survey or #reviewed.unknownSources > 0
        or self.world:owns(destination.ref) or not self.native:reachable(destination.ref) then return false end
    for _, record in ipairs(reviewed.records) do
        if record.groundPoint or not self.native:reachable(record.source) then return false end
    end
    return true
end

function Jobs:condenseStep()
    local controller = self.execution.condense
    local op, reason, done = controller:next()
    self.view.condense = controller:status()
    if op then
        op.condense = true
        self.view.itemName = tostring(op.item:getName())
        self.view.reason = "Reorganizing carried items using the current Condense settings."
        self:action(op, function(ok, failure)
            local continuing, problem = controller:settle(op, ok, failure)
            local status = controller:status()
            self.view.condense = status
            self.view.done, self.view.moved = status.transfers or 0, status.transfers or 0
            self.view.total = math.max(self.view.total, self.view.done)
            if not continuing then self:finishWhenSettled("paused", problem or "Condense needs a fresh check before continuing") end
        end)
    elseif done then
        local status = self.view.condense
        if (status.buffered or 0) > 0 then self:finishWhenSettled("paused", reason or "A bag arrangement is incomplete; buffered items remain carried")
        else
            if status.limited then self:skip({itemName = "Condense"}, reason or status.reason or "The bounded improvement search reached its limit") end
            self:complete(self.view.skipped > 0 and "finished_with_skips" or "finished", reason or status.reason or "Condense completed.")
        end
    elseif reason then self:finishWhenSettled("paused", reason)
    else self.view.reason = "Planning useful capacity-safe bag arrangements." end
end

function Jobs:logOp(op)
    self.opCount, self.opStarted = self.opCount + 1, now()
    if not Log.detailed then return end
    Log.trace(self.interaction, "OP", "n", self.opCount, "kind", op.kind, "mode", op.mode,
        "item", op.item and Log.item(op.item, self.player), "items", op.items and #op.items > 1 and #op.items or nil,
        "from", op.source and Log.container(op.source, self.player), "fromAt", op.sourcePoint and Log.point(op.sourcePoint),
        "to", op.destination and Log.container(op.destination, self.player), "toAt", op.destinationPoint and Log.point(op.destinationPoint),
        "container", op.container and Log.container(op.container, self.player), "vehicle", op.vehicle and Log.vehicle(op.vehicle),
        "relock", op.relock and table.concat(op.relock, ","),
        "target", Log.point(op.square or op.location or op.locations and op.locations[1]), "player", Log.player(self.player))
end

function Jobs:logOpEnd(op, result, reason, code)
    local failed = result == "failed"
    if not failed and not Log.detailed then return end
    local write = failed and Log.warn or Log.trace
    write(self.interaction, "OP-END", "n", self.opCount, "kind", op.kind, "result", result, "ms", now() - (self.opStarted or now()),
        "reason", reason, "code", code, "item", op.item and Log.item(op.resultItem or op.item, self.player),
        "from", op.source and Log.container(op.source, self.player), "to", op.destination and Log.container(op.destination, self.player),
        "container", op.container and Log.container(op.container, self.player), "at", Log.point(self.player:getCurrentSquare()))
end

function Jobs:logPhase()
    local phase = self.execution and self.execution.phase
    if not phase or phase == self.loggedPhase then return end
    Log.trace(self.interaction, "PHASE", "from", self.loggedPhase, "to", phase, "reason", self.view.reason)
    self.loggedPhase = phase
end

-- leftovers are items the job picked up and still holds.
function Jobs:logEnd(event, state, trigger)
    local v, leftovers = self.view, {}
    for _, record in pairs(self.hauled or {}) do
        if not record.delivered and record.hauled and #leftovers < 5 then leftovers[#leftovers + 1] = Log.item(record.item, self.player) end
    end
    local unlocked = {}
    for _, entry in ipairs(self.execution and self.execution.unlocked or {}) do unlocked[#unlocked + 1] = entry.partId end
    Log.info(self.interaction, event, "state", state, "trigger", trigger, "reason", v.reason, "ms", now() - (self.startedAt or now()),
        "done", v.done, "total", v.total, "moved", v.moved, "cleared", v.cleared, "skipped", v.skipped, "deferred", v.deferred,
        "carried", v.carried, "phase", self.execution and self.execution.phase,
        "unlocked", #unlocked > 0 and table.concat(unlocked, ",") or nil,
        "leftovers", #leftovers > 0 and "{" .. table.concat(leftovers, " ") .. "}" or nil, "player", Log.player(self.player))
end

function Jobs:skip(record, reason)
    if Log.detailed then
        Log.trace(self.interaction, "SKIP", "item", record.item and Log.item(record.item, self.player) or record.itemName,
            "reason", reason, "source", record.source and Log.where(record.source))
    end
    self.view.skipped = self.view.skipped + 1
    local status = record.status or "Left in place"
    if type(reason) == "string" and reason:sub(1, 11) == "Protected: " then status, reason = "Protected", reason:sub(12) end
    table.insert(self.view.reasons, { itemName = record.itemName or "Container", status = status,
        reason = reason, tone = record.tone or "warning" })
    self.view.reason = reason
end

-- One note for a source that cannot be reached, however many of its items that leaves behind.
function Jobs:skipUnreachable(record, reason)
    local failed = self.execution.failedSources
    local key = record.workSource
    local row = failed[key] and failed[key].row
    if not row then
        self:skip(record, reason)
        failed[key].row = self.view.reasons[#self.view.reasons]
        return
    end
    failed[key].count = (failed[key].count or 1) + 1
    self.view.skipped = self.view.skipped + 1
    row.itemName = record.groundPoint and "Floor" or self.world:name(record.source)
    row.reason = failed[key].reason .. " (" .. failed[key].count .. " items)"
end

-- operation is the native step that failed, when one had begun.
function Jobs:finishOperation(work, ok, reason, code, operation)
    local execution = self.execution
    self.operation, self.pending = nil, nil
    if execution then
        for _, entry in ipairs(work.op.unlocked or {}) do table.insert(execution.unlocked, entry) end
        work.op.unlocked = nil
        if ok then execution.faults = 0 end
    end
    if not ok and PLAYER_MUST[code] then
        work.retry, self.operation = true, work
        self:finishWhenSettled("paused", reason, code)
        return
    end
    if execution and ok and work.op.kind ~= "approach" then execution.refusals = nil
    elseif execution and code == "refused" then
        local last = execution.refusals
        execution.refusals = {reason = reason, count = last and last.reason == reason and last.count + 1 or 1}
        if execution.refusals.count >= MAX_REFUSALS then
            execution.refusals = nil
            work.retry, self.operation = true, work
            self:finishWhenSettled("paused", reason .. ", " .. MAX_REFUSALS .. " times in a row", "refused")
            return
        end
    end
    if ok and work.op.kind == "approach" and work.op.travel then
        local trip, target = work.op.travel, work.op.location
        local square = work.op.container and self.world:square(work.op.container) or work.op.square
        if square then target = coordinates(square) end
        self.routing:observe(trip.from, target or trip.to, trip.distance, trip.elapsedMs)
    end
    if ok and work.op.kind == "trash" then self:settleTrash(work) end
    if not ok and not operation and Log.detailed then
        Log.trace(self.interaction, "OP-REFUSED", "kind", work.op.kind, "item", work.op.item and Log.item(work.op.item, self.player),
            "reason", reason, "code", code)
    end
    work.callback(ok, reason, code)
end

-- The player's own action goes first; an interrupted step is prepared again afterwards.
function Jobs:waitForPlayer(work)
    if work and not work.completed then work.retry = true end
    if not self.view.waiting and Log.detailed then
        Log.trace(self.interaction, "WAIT", "for", "player action", "queue", Log.queue(self.player))
    end
    self.view.waiting = WAITING
end

-- A place is a container's anchor, a tile, or the gear waiting in storage. Returns
-- what is there now, or nil and "unloaded" or another reason.
function Jobs:resolve(anchor)
    if not anchor then return nil, "Source has no stable location" end
    if anchor.kind == "ground" then
        local square = getCell():getGridSquare(anchor.point.x, anchor.point.y, anchor.point.z)
        if square then return square end
        return nil, "unloaded"
    elseif anchor.kind == "gear" then return self.recovery:endpoint() end
    return self.world:resolveSource(anchor)
end

-- Walks to a place and waits out interruptions: callback(container or square),
-- or callback(nil, reason, code); code is "unreachable" when the way there failed.
function Jobs:reach(anchor, callback)
    local execution, phase = self.execution, self.execution.phase
    local function done(place, reason, code)
        execution.phase = phase
        callback(place, reason, code)
    end
    local function arrive(place)
        if anchor.kind == "ground" then
            if not anchor.exact and self.native:beside(place) then done(place); return end
        elseif self.world:owns(place) or self.native:reachable(place) then done(place); return end
        local op = {kind = "approach", exact = anchor.exact}
        if anchor.kind == "ground" then op.square = place else op.container = place end
        self:action(op, function(ok, reason, code) done(ok and (op.container or op.square) or nil, reason, code) end, anchor)
    end
    local place, reason = self:resolve(anchor)
    if place then arrive(place)
    elseif reason ~= "unloaded" then done(nil, reason)
    else
        self:walkLocation(anchor.point, function(ok, err, code)
            if not ok then done(nil, err, code); return end
            place, reason = self:resolve(anchor)
            if place then execution.phase = phase; arrive(place) else done(nil, reason) end
        end, nil, true)
    end
end

-- What of a transfer the game has not done yet.
function Jobs:unmoved(work)
    local result = {}
    for _, entry in ipairs(work.entries) do
        if not self.native:transferResult(work.op, entry.itemId, entry.fullType) then result[#result + 1] = entry end
    end
    if #result == 0 then work.op.resultItem = self.native:transferResult(work.op, work.entries[1].itemId, work.entries[1].fullType) end
    return result
end

-- After an interruption everything is found and reached again before the step is repeated.
function Jobs:reopen(work)
    local execution, phase, op = self.execution, self.execution.phase, work.op
    work.retry, self.operation = nil, nil
    local function ready(ok, reason, code)
        execution.phase = phase
        if ok then self.operation = work else self:finishOperation(work, false, reason, code) end
    end
    if op.kind == "approach" and work.anchor then
        self:reach(work.anchor, function(place, reason, code)
            execution.phase = phase
            if op.container then op.container = place or op.container else op.square = place or op.square end
            self:finishOperation(work, place ~= nil, reason, code)
        end)
    elseif op.kind == "transfer" then
        local ends = {{"source", work.from}, {"destination", work.to}}
        for _, entry in ipairs(ends) do
            local field, anchor = entry[1], entry[2]
            local place, reason = self:resolve(anchor)
            if place and anchor.kind ~= "ground" then op[field] = place
            elseif not place and reason ~= "unloaded" then ready(false, reason); return end
        end
        if #self:unmoved(work) == 0 then self:finishOperation(work, true); return end
        local function goTo(index)
            local field, anchor = ends[index][1], ends[index][2]
            self:reach(anchor, function(place, reason, code)
                if not place then ready(false, reason, code); return end
                if anchor.kind ~= "ground" then op[field] = place end
                if ends[index + 1] then goTo(index + 1) else ready(true) end
            end)
        end
        goTo(1)
    else ready(true) end
end

function Jobs:floor() return ISInventoryPage.GetFloorContainer(self.player:getPlayerNum()) end

-- The live item of a record on this tile and the floor container holding it. The
-- container lists what the loot window last saw around the player.
function Jobs:groundItem(record, point)
    local function find()
        local item = sourceItem(record, self:floor())
        local world = item and item:getWorldItem()
        local square = world and world:getSquare()
        return square and square == getCell():getGridSquare(point.x, point.y, point.z) and item or nil
    end
    local item = find()
    if not item then
        local loot = getPlayerLoot(self.player:getPlayerNum())
        if not loot then return nil, "The native loot window is not available" end
        loot:refreshBackpacks()
        item = find()
    end
    if item then return item, self:floor() end
    return nil, "Floor item changed from its original location"
end

-- Everything that must still hold at the moment an item moves: true, or nil,
-- a reason and a code. "moved" when the game has already done all of it.
function Jobs:admit(work)
    local op = work.op
    if op.kind ~= "transfer" then
        if op.personalRecovery then return self.recovery:allows(op) end
        return true
    end
    local pending = self:unmoved(work)
    if #pending == 0 then return "moved" end
    if work.to.kind == "ground" then op.destination = self:floor() end
    local items, room = {}, {}
    for _, entry in ipairs(pending) do
        local item, reason, code
        if work.from.kind == "ground" then
            local floor
            item, floor = self:groundItem(entry, work.from.point)
            if item then op.source = floor else reason = floor end
        else
            item = sourceItem(entry, op.source)
            if not item then reason = "The selected item changed source" end
        end
        local ok = item ~= nil
        if ok then
            if #items == 0 then op.item = item end
            if op.condense then
                local controller = self.execution and self.execution.condense
                if controller then ok, reason, code = controller:validate(op) else ok, reason = nil, "The Condense arrangement is no longer active" end
            elseif op.personalRecovery then ok, reason = self.recovery:allows(op)
            else ok, reason = self:matches({item = item, hauled = op.hauled}, self.plan) end
            if ok then ok, reason, code = self:admits(item, op.destination, room) end
        end
        if ok then items[#items + 1] = item
        elseif #items == 0 then return nil, reason, code end
    end
    op.item, op.items = items[1], items
    return true
end

function Jobs:continueOperation()
    local work = self.operation
    if work.completed then self:finishOperation(work, true); return end
    if self.native:isPlayerBusy() then self:waitForPlayer(work); return end
    local target = work.op.trashTarget
    if target and target.needsInspection then
        local execution, phase = self.execution, self.execution.phase
        self.operation = nil
        self:inspectBin(target, function(ok, reason)
            execution.phase = phase
            if not ok then
                if work.op.kind == "transfer" and execution.delivery then
                    execution.delivery.target = nil
                    execution.phase = "delivery"
                else self:finishOperation(work, false, reason or "Bin was not approved") end
                return
            end
            work.op.container = target.container
            work.op.approved = target.approved
            work.retry = true
            self.operation = work
        end)
        return
    end
    if work.retry then self:reopen(work); return end
    local operation = work.op
    local ready, refusal, refusalCode = self:admit(work)
    if not ready then self:finishOperation(work, false, refusal, refusalCode); return end
    if ready == "moved" then self:finishOperation(work, true); return end
    if operation.kind == "trash" then
        local bin, problem = operation.container
        if operation.trashTarget then bin, problem = self.world:resolveTrashTarget(operation.trashTarget) end
        if not bin or (operation.trashTarget and not self.world:binReachable(operation.trashTarget)) then
            self:finishOperation(work, false, problem or "The reviewed trash can is no longer reachable"); return
        end
        if isClient() and not getServerOptions():getBoolean("TrashDeleteAll") then
            self:finishOperation(work, false, "This server disables native trash deletion (TrashDeleteAll)"); return
        end
        local safe, failure = self:binSafe({approved = operation.approved}, bin)
        if not safe then self:finishOperation(work, false, failure); return end
        operation.container = bin
        work.deletions, work.deletionSource = {}, self:sourceKey(bin)
        local contents = bin:getItems()
        for index = 0, contents:size() - 1 do
            local item = contents:get(index)
            work.deletions[#work.deletions + 1] = {itemId = item:getID(), fullType = tostring(item:getFullType())}
        end
    end
    self:logOp(operation)
    local accepted, reason, code = self.native:begin(operation)
    if not accepted then
        if operation.kind == "approach" and not code then code = "unreachable" end
        self:logOpEnd(operation, code == "busy" and "waiting" or "failed", reason, code)
        if code == "busy" then self:waitForPlayer(work)
        else self:finishOperation(work, false, reason, code, operation) end
        return
    end
    self.pending = work
end

-- anchor is where an approach leads; run lists the records a transfer moves together.
function Jobs:action(op, callback, anchor, run)
    local work = {op = op, callback = callback, anchor = anchor}
    if op.kind == "transfer" then
        work.entries = {}
        for index, record in ipairs(run or {{itemId = op.item:getID(), fullType = tostring(op.item:getFullType())}}) do
            work.entries[index] = {itemId = record.itemId, fullType = record.fullType}
        end
        if op.source:getType() == "floor" then
            local world = op.item:getWorldItem()
            op.sourcePoint = world and coordinates(world:getSquare())
            work.from = {kind = "ground", point = op.sourcePoint}
        else work.from = self.world:sourceAnchor(op.source) or {kind = "live", container = op.source} end
        if op.destination:getType() == "floor" then
            op.destinationPoint = op.destinationPoint or coordinates(self.player:getCurrentSquare())
            work.to = {kind = "ground", point = op.destinationPoint, exact = true}
        else work.to = self.world:sourceAnchor(op.destination) or {kind = "live", container = op.destination} end
    elseif op.kind == "approach" and not anchor then
        work.anchor = op.container and self.world:sourceAnchor(op.container)
            or op.square and {kind = "ground", point = coordinates(op.square), exact = op.exact} or nil
    end
    self.operation = work
    self:continueOperation()
end

function Jobs:approach(container, callback)
    if self.world:owns(container) then callback(true, nil, container)
    else
        local operation = {kind = "approach", container = container}
        self:action(operation, function(ok, reason, code) callback(ok, reason, operation.container, code) end)
    end
end

function Jobs:walkLocation(point, callback, building, loadedOnly)
    local origin = self.world:point()
    if not origin then callback(false, "Player has no loaded location", "unreachable"); return end
    local distance = math.abs(point.x - origin.x) + math.abs(point.y - origin.y)
    self.execution.walk = {point = point, after = callback, building = building, loadedOnly = loadedOnly,
        visited = {}, hops = 0, limit = math.min(2048, math.max(8, math.ceil(distance / 8) + math.abs(point.z - origin.z) * 8))}
    self.execution.phase = "walk"
end

function Jobs:walkStep()
    local walk = self.execution.walk
    local function finish(ok, err, code)
        self.execution.walk = nil
        walk.after(ok, err, not ok and (code or "unreachable") or nil)
    end
    if walk.loadedOnly and self.world:locationLoaded(walk.point) then finish(true); return end
    if walk.hops >= walk.limit then finish(false, "Walking frontier exhausted before reaching the location"); return end
    local targets, direct = self.world:walkTargets(walk.point, walk.visited, walk.building)
    if not targets then finish(false, direct); return end
    walk.hops = walk.hops + 1
    for _, point in ipairs(targets) do walk.visited[point.x .. ":" .. point.y .. ":" .. point.z] = true end
    local operation = {kind = "approach"}
    if direct then operation.location = targets[1] else operation.locations = targets end
    self:action(operation, function(ok, err, code)
        if direct then finish(ok, err, code)
        elseif ok then self.execution.phase = "walk"
        else
            walk.failure = err
            self.execution.phase = "walk"
        end
    end)
end

function Jobs:matches(record, plan)
    local protected, protection = self.world:protected(record.item, record.hauled and HAULED)
    if protected then return nil, "Protected: " .. tostring(protection or "Item is protected") end
    if not matchesSelection(self.activeGraph, plan.request, self.world:describe(record.item), record.item, self.player) then
        return nil, "Item no longer matches the selection" end
    return true
end

function Jobs:recordSource(record, callback)
    local point = record.groundPoint
    local source = not point and self:resolve(record.sourceAnchor)
    if source and not sourceItem(record, source) then callback(nil, "Item changed source after preview"); return end
    self:reach(point and {kind = "ground", point = point} or record.sourceAnchor, function(place, reason, code)
        if not place then callback(nil, reason, code); return end
        local item, holder
        if point then
            record.groundSquare = place
            item, holder = self:groundItem(record, point)
        else item, holder = sourceItem(record, place), place end
        if not item then callback(nil, point and holder or "Item changed source after preview"); return end
        record.item, record.source = item, holder
        callback(holder)
    end)
end

function Jobs:empty(bin, approved, callback)
    local target
    for _, candidate in ipairs(self.plan.bins or {}) do
        if candidate.container == bin or candidate.key == self.world:key(bin) then target = candidate; break end
    end
    self:approach(bin, function(ok, err, current)
        if not ok then callback(false, err); return end
        bin = current
        if target then
            bin, err = self.world:resolveTrashTarget(target)
            if not bin then callback(false, err); return end
            approved = target.approved
        end
        local contents = bin:getItems()
        for index = 0, contents:size() - 1 do
            if self.world:protected(contents:get(index)) then callback(false, "Trash now contains a protected item; nothing was deleted"); return end
        end
        self:action({ kind = "trash", container = bin, approved = approved, trashTarget = target }, callback)
    end)
end

function Jobs:sourceKey(source, record)
    if record and record.groundPoint then return "floor:" .. pointKey(record.groundPoint) end
    return self.world:key(source) or source
end

function Jobs:registerWork(execution, record)
    local source = self:sourceKey(record.source, record)
    local id = tostring(record.itemId)
    execution.work[source] = execution.work[source] or {}
    execution.work[source][id] = execution.work[source][id] or {}
    execution.work[source][id][record.fullType] = record
    record.workSource = source
    local deleted = execution.deleted[source]
    if deleted and deleted[id] and deleted[id][record.fullType] then
        record.settled = true
        self.view.done, self.view.cleared = self.view.done + 1, self.view.cleared + 1
    end
end

function Jobs:settleTrash(work)
    local execution = self.execution or self.suspended and self.suspended.execution
    if not execution or not work.deletions then return end
    local source = work.deletionSource
    execution.deleted[source] = execution.deleted[source] or {}
    for _, deleted in ipairs(work.deletions) do
        if not sourceItem(deleted, work.op.container) then
            local id = tostring(deleted.itemId)
            execution.deleted[source][id] = execution.deleted[source][id] or {}
            execution.deleted[source][id][deleted.fullType] = true
            local registered = execution.work[source] and execution.work[source][id]
            local record = registered and registered[deleted.fullType]
            if record and not record.settled then
                record.settled = true
                self.view.done, self.view.cleared = self.view.done + 1, self.view.cleared + 1
            end
        end
    end
end

function Jobs:carryStep()
    local execution, sources = self.execution, {}
    if self.recovery and self.recovery:status().pending then execution.phase = execution.afterCarry or "source"; return end
    if self.plan.request.destination.kind == "container" and self.world:owns(self.plan.request.destination.ref) then
        execution.phase = execution.afterCarry or "source"
        return
    end
    for _, source in ipairs(self.plan.sources) do sources[#sources + 1] = source end
    for _, task in ipairs(execution.tasks) do
        if task.kind == "records" then
            for _, record in ipairs(task.records) do sources[#sources + 1] = record.source end
        elseif task.kind == "discover" then sources[#sources + 1] = task.container end
    end
    for _, record in ipairs(execution.records) do sources[#sources + 1] = record.source end
    local records = {}
    for _, record in ipairs(self.world:gearRecords(sources)) do
        -- A bag being hauled is cargo; equipping it would keep it from its destination.
        local hauled = self.hauled[self.world:itemId(record.item) or record.item]
        if not hauled or hauled.delivered then records[#records + 1] = record end
    end
    local incoming = 0
    for _, byId in pairs(execution.work) do for _, byType in pairs(byId) do for _, record in pairs(byType) do
        if not record.settled and not self.world:owns(record.item:getContainer())
            and not self.world:protected(record.item) then incoming = incoming + weight(record.item) end
    end end end
    local revision = execution.capacityRevision
    local op = self.carry:next(records, incoming, revision)
    if not op then
        execution.phase = execution.afterCarry or "source"
        self.view.reason = "Carrying bags are ready. Continuing the selected job."
        return
    end
    self.view.reason = "Preparing carrying bags before collecting the next load."
    local oldInventory = op.item:getInventory()
    self:action(op, function(ok, reason, code)
        local replacement = self.carry:complete(op, ok, code, revision)
        if replacement then self.world:replaceGear(replacement.oldId, replacement.oldType, replacement.newItem) end
        if ok then
            local current = op.resultItem or op.item
            local currentInventory = current:getInventory()
            for _, byId in pairs(execution.work) do
                for _, byType in pairs(byId) do
                    for _, record in pairs(byType) do
                        if record.item == op.item then
                            record.item, record.itemId, record.fullType = current, current:getID(), tostring(current:getFullType())
                            record.source, record.sourceAnchor, record.groundPoint = current:getContainer(), self.world:sourceAnchor(current:getContainer()), nil
                        elseif record.source == oldInventory then
                            local item = sourceItem(record, currentInventory)
                            if item then record.item, record.source = item, currentInventory end
                        end
                        if self.world:owns(record.source) then record.sourceAnchor = self.world:sourceAnchor(record.source) end
                    end
                end
            end
            self:capacityChanged()
        end
        execution.phase = "carry"
    end)
end

function Jobs:capacityChanged()
    if self.execution then self.execution.capacityRevision = self.execution.capacityRevision + 1 end
end

function Jobs:onCapacityBlocked(record, reason)
    local execution = self.execution
    if execution.heavyRecord == record then
        execution.heavyRecord = nil
        self:skip(record, reason)
        self:nextRecord()
        self:beginRecovery("restore", "source")
        return true
    end
    if self.recovery and not record.stagingAttempted and #execution.batch == 0
        and self.plan.request.destination.kind == "trash" and not self.world:owns(record.item:getContainer()) then
        local current, maximum = self.world:carrying()
        if current + weight(record.item) > maximum + 0.0001 and weight(record.item) <= maximum then
            record.stagingAttempted = true
            local prepared, failure = self.recovery:prepare(record.item, self.world:safeStagingContainers())
            if prepared then
                execution.heavyRecord = record
                self:beginRecovery("stage", "source")
                return true
            end
            Log.trace(self.interaction, "STAGING-REFUSED", "item", Log.item(record.item, self.player), "reason", failure)
            reason = reason .. "; " .. tostring(failure)
        end
    end
    record.admissionFailures = (record.admissionFailures or 0) + 1
    if record.admissionFailures >= 3 then self:skip(record, reason); return end
    if not execution.deferred[record] then self.view.deferred = self.view.deferred + 1 end
    execution.deferred[record] = {revision = execution.capacityRevision, reason = reason}
    self.view.reason = "This item is waiting for a later load after carrying space is freed."
    if Log.detailed then Log.trace(self.interaction, "DEFER", "item", Log.item(record.item, self.player), "reason", reason) end
end

-- A bag whose contents are still being moved waits until the rest of the pass is done.
function Jobs:deferBag(record)
    record.bagWaits = (record.bagWaits or 0) + 1
    local reason = "Bag still holds items that were left in place"
    if record.bagWaits > 2 then self:skip(record, reason); return end
    if not self.execution.deferred[record] then self.view.deferred = self.view.deferred + 1 end
    self.execution.deferred[record] = {reason = reason, bag = true}
    if Log.detailed then Log.trace(self.interaction, "DEFER", "item", Log.item(record.item, self.player), "reason", reason) end
end

function Jobs:beginRecovery(mode, after)
    self.execution.recovery = {mode = mode, after = after}
    self.execution.phase = "recovery"
end

function Jobs:recoverPersonalGear(options)
    if not self.recovery or not self.recovery:status().pending then return nil, "There is no personal gear waiting to be recovered" end
    if self.execution or self.ending or self.native:isBusy() then return nil, "Pause or cancel the current job before recovering personal gear" end
    local reason = self.native:takeoverReason()
    if reason then return nil, reason end
    local saved = self.suspended
    while saved and saved.execution.recoveryOnly do saved = saved.execution.resumeSaved end
    self:bindInteraction(options, "recover personal gear")
    self.recoveryRequired, self.startedAt = true, now()
    self.suspended, self.activeGraph, self.opCount, self.loggedPhase = nil, self.graph, 0, nil
    self.execution = {recoveryOnly = true, unlocked = {}, resumeSaved = saved, phase = "recovery", batch = {},
        recovery = {mode = "restore"}, capacityRevision = 0}
    self.plan = self.plan or {bins = {}}
    self.view.state, self.view.reason = "running", "Returning to the personal gear staging container."
    self.view.reasons, self.view.skipped = self.view.reasons or {}, self.view.skipped or 0
    Log.info(self.interaction, "START", "action", "recover-gear", "staged", self.recovery:status().location, "player", Log.player(self.player))
    return true
end

function Jobs:recoveryStep()
    local execution, work = self.execution, self.execution.recovery
    if not work.arrived then
        local status = self.recovery:status()
        if not status.point then self:complete("failed", status.reason or "The personal gear receipt has no usable location"); return end
        self:reach({kind = "gear", point = status.point}, function(endpoint, reason)
            if endpoint then work.arrived = true
            else self:complete("failed", (reason or "Could not reach the staging container") .. "; personal gear remains reserved for recovery") end
        end)
        return
    end
    local op, reason, done = self.recovery:next(work.mode)
    if op then
        self.view.reason = work.mode == "stage" and "Storing whole personal items for one heavy-item trip."
            or "Recovering personal items and their original equipment slots."
        self:action(op, function(ok, failure)
            local settled, err = self.recovery:settle(op, ok, failure)
            if not settled then self:complete("failed", (err or "Personal gear operation stopped") .. ". Choose Recover personal gear to continue.")
            else self:capacityChanged(); execution.phase = "recovery" end
        end)
    elseif not done then self:complete("failed", (reason or "Personal gear recovery stopped") .. ". Personal gear remains reserved for recovery.")
    elseif execution.recoveryOnly then
        local saved = execution.resumeSaved
        if saved then
            if saved.operation and saved.operation.op.personalRecovery then saved.operation = nil end
            saved.execution.recovery, saved.execution.heavyRecord = nil, nil
            if saved.execution.phase == "recovery" then saved.execution.phase = "source" end
        end
        self.recoveryRequired = nil
        self.view.state = saved and "paused" or "finished"
        self.view.reason = saved and "Personal gear recovered. Choose Resume job to continue the paused job." or "Personal gear recovered to its original places."
        self:logEnd("END", "finished", "gear-recovered")
        self.execution, self.operation, self.pending, self.activeGraph, self.suspended = nil, nil, nil, nil, saved
        if not saved then self.plan, self.carry, self.hauled = nil, nil, nil end
    else execution.recovery, execution.phase = nil, work.after or "source" end
end

function Jobs:heavyEmptyStep()
    local execution = self.execution
    execution.heavyBinIndex = execution.heavyBinIndex or 1
    local target = self.plan.bins[execution.heavyBinIndex]
    if not target then
        execution.heavyBinIndex = nil
        self:beginRecovery("restore", "source")
        return
    end
    execution.heavyBinIndex = execution.heavyBinIndex + 1
    if target.touched then
        self:walkLocation(target.point, function(arrived, reason)
            execution.phase = "heavyEmpty"
            local bin = arrived and self.world:resolveTrashTarget(target)
            if not bin then self:skip({itemName = "Trash can"}, reason or "The heavy-item bin is unavailable")
            elseif not bin:getItems():isEmpty() then
                self:empty(bin, target.approved, function(ok, failure)
                    if not ok then self:skip({itemName = self.world:name(bin)}, failure) end
                end)
            end
        end, nil, true)
    end
end

function Jobs:retryDeferred()
    local execution, records, bags = self.execution, {}, {}
    local deferred = execution.deferred
    execution.deferred, self.view.deferred = {}, 0
    for record, pending in pairs(deferred) do
        if record.settled then -- already handled in place
        elseif pending.bag then bags[#bags + 1] = record
        elseif pending.revision < execution.capacityRevision then records[#records + 1] = record
        else self:skip(record, pending.reason or "No further carrying space became available for this item") end
    end
    Sort(records, function(record) return tostring(record.itemId) end)
    for _, record in ipairs(Sort(bags, function(record) return tostring(record.itemId) end)) do
        if #records > 0 or not self.world:filledBag(record.item) then records[#records + 1] = record
        else self:skip(record, deferred[record].reason) end
    end
    if #records == 0 then return false end
    execution.failedSources = {}
    execution.records, execution.recordIndex, execution.phase = records, 1, "source"
    return true
end

local function sourceGroup(record)
    if record.groundPoint then return pointKey(record.groundPoint) end
    -- Emptied bags wait behind the group that empties them.
    return record.emptied and tostring(record.source) .. ":bags" or record.source
end

local function addRecordTask(execution, records)
    local first = records[1]
    execution.tasks[#execution.tasks + 1] = {kind = "records", records = records,
        point = first.groundPoint or first.sourceAnchor and first.sourceAnchor.point}
end

local function addDiscoverTask(self, execution, container)
    local anchor = self.world:sourceAnchor(container)
    execution.tasks[#execution.tasks + 1] = {kind = "discover", container = container, anchor = anchor, point = anchor and anchor.point}
end

function Jobs:createExecution(plan)
    local execution = { phase = "source", tasks = {}, records = {}, recordIndex = 1,
        batch = {}, seen = {}, seenSources = {}, failedRoutes = {}, failedSources = {}, batchRoom = {}, unlocked = {},
        plan = plan, finalBin = 1, work = {}, deleted = {}, deferred = {}, empty = {}, capacityRevision = 0 }
    local destination = plan.request.destination
    if destination.kind == "container" and not self.world:owns(destination.ref) then execution.destination = self.world:sourceAnchor(destination.ref)
    elseif destination.kind == "vehicle" then execution.destination = self.world:sourceAnchor((self.world:destinations(plan.request) or {})[1]) end
    local groups, order = {}, {}
    for _, entry in ipairs(plan.records) do
        local record = self:captureRecord(entry)
        self:registerWork(execution, record)
        execution.seen[self.world:itemId(record.item) or record.item] = true
        local key = plan.request.destination.kind == "matching" and self.player:getInventory() or sourceGroup(record)
        if not groups[key] then groups[key] = {}; order[#order + 1] = key end
        groups[key][#groups[key] + 1] = record
    end
    for _, key in ipairs(order) do addRecordTask(execution, groups[key]) end
    for _, container in ipairs(plan.unknownSources) do
        addDiscoverTask(self, execution, container)
        execution.seenSources[self.world:key(container) or container] = true
    end
    return execution
end

-- The nearest remaining stop from here. Carried items need no walk and go first.
function Jobs:nextTask()
    local tasks, here = self.execution.tasks, self.world:point()
    local best, bestCost
    for index, task in ipairs(tasks) do
        local cost = task.point and here and self.routing:estimate(here, task.point) or 0
        if not best or cost < bestCost then best, bestCost = index, cost end
    end
    if not best then return nil end
    local task = table.remove(tasks, best)
    if Log.detailed then
        Log.trace(self.interaction, "TASK", "kind", task.kind, "at", task.point and Log.point(task.point), "records", task.records and #task.records,
            "container", task.container and Log.container(task.container, self.player), "left", #tasks, "player", Log.point(here))
    end
    return task
end

function Jobs:sectionTasks(scan)
    local execution, groups, order = self.execution, {}, {}
    execution.tasks, execution.records, execution.recordIndex = {}, {}, 1
    for _, entry in ipairs(bagsLast(self, self.plan.request, scan.items)) do
        local id = self.world:itemId(entry.item) or entry.item
        if not execution.seen[id] and matchesSelection(self.activeGraph, self.plan.request, entry.descriptor, entry.item, self.player) then
            execution.seen[id] = true
            if not (self.plan.request.destination.kind == "inventory" and self.world:owns(entry.source)) then
                local record = self:captureRecord(entry)
                local key = sourceGroup(record)
                if not groups[key] then groups[key] = {}; order[#order + 1] = key end
                self:registerWork(execution, record)
                groups[key][#groups[key] + 1] = record
                self.view.total = self.view.total + 1
            end
        end
    end
    for _, key in ipairs(order) do addRecordTask(execution, groups[key]) end
    for _, source in ipairs(scan.sources) do
        local key = self.world:key(source) or source
        if not source:isExplored() and not execution.seenSources[key] then
            execution.seenSources[key] = true
            addDiscoverTask(self, execution, source)
        end
    end
    for _, warning in ipairs(scan.warnings) do self:skip({itemName = "Building source"}, warning) end
    execution.afterCarry, execution.phase = "source", "carry"
end

function Jobs:acceptSection(section, scan, missing, denied, reason)
    local survey = self.plan.survey
    local ok = missing == 0 and denied == 0 and reason == nil
    reason = reason or (missing > 0 and (tostring(missing) .. " tiles remain unloaded or no longer belong to this room"))
        or (denied > 0 and "Permission blocks part of this room") or nil
    survey:report(section, ok, reason)
    if not ok then self:skip({itemName = section.roomName .. " / floor " .. tostring(section.z)}, reason) end
    self.view.survey = survey:status()
    self.execution.section = nil
    self:sectionTasks(scan)
end

function Jobs:surveyStep()
    local survey, execution = self.plan.survey, self.execution
    local section = survey:next()
    self.view.survey = survey:status()
    if section == false then return end
    if not section then
        execution.phase = "source"
        return
    end
    self.view.reason = "Searching " .. section.roomName .. " on floor " .. tostring(section.z)
    local initial, missing, denied = self.world:scanSection(section, self.plan.request)
    if missing == 0 then self:acceptSection(section, initial, missing, denied); return end
    self:walkLocation(self.world:sectionTarget(section), function(ok, err)
        if not ok then
            local scan, unloaded, blocked = self.world:scanSection(section, self.plan.request)
            self:acceptSection(section, scan, unloaded, blocked, err)
            return
        end
        execution.section = {section = section, deadline = now() + 5000, nextScan = 0}
        execution.phase = "surveyScan"
    end, survey.building)
end

function Jobs:surveyScan()
    local execution, survey = self.execution, self.plan.survey
    local pending = execution.section
    if now() < pending.nextScan then return end
    pending.nextScan = now() + 250
    local scan, missing, denied = self.world:scanSection(pending.section, self.plan.request)
    if missing > 0 and now() < pending.deadline then return end
    self:acceptSection(pending.section, scan, missing, denied)
end

function Jobs:addObserved(entries)
    local execution, result = self.execution, {}
    for _, entry in ipairs(bagsLast(self, execution.plan.request, entries)) do
        local id = self.world:itemId(entry.item) or entry.item
        if not execution.seen[id] and matchesSelection(self.activeGraph, execution.plan.request, entry.descriptor, entry.item, self.player) then
            execution.seen[id] = true
            if not (execution.plan.request.destination.kind == "inventory" and self.world:owns(entry.source)) then
                local record = self:captureRecord(entry)
                self:registerWork(execution, record)
                result[#result + 1] = record
                self.view.total = self.view.total + 1
            end
        end
    end
    execution.records, execution.recordIndex, execution.phase = result, 1, "carry"
    execution.afterCarry = "source"
end

function Jobs:nextRecord()
    self.execution.recordIndex = self.execution.recordIndex + 1
    self.execution.phase = "source"
end

function Jobs:finishHeavyAttempt(record, moved)
    if self.execution.heavyRecord ~= record then return end
    self.execution.heavyRecord = nil
    if moved then self:startDelivery("heavyEmpty") else self:beginRecovery("restore", "source") end
end

-- One stop per destination, nearest first, with alike items together.
function Jobs:deliveryOrder(batch)
    local request, room, pass, here = self.plan.request, {}, nil, self.world:point()
    if request.destination.kind == "trash" then return batch end
    if request.destination.kind == "matching" then pass = self.world:destinationPass(request, self.activeGraph) end
    local stops, count, types, seen = {}, 0, {}, 0
    for _, record in ipairs(batch) do
        if pass then record.target = self:choose(request, record.item, room, pass) end
        local stop = record.target or false
        if not stops[stop] then
            count = count + 1
            local square = stop and stop:getType() ~= "floor" and self.world:square(stop)
            stops[stop] = {order = count, cost = not stop and math.huge or square and here and self.routing:estimate(here, coordinates(square)) or 0}
        end
        if not types[record.fullType] then seen = seen + 1; types[record.fullType] = seen end
    end
    return Sort(batch, function(record)
        local stop = stops[record.target or false]
        return stop.cost, stop.order, types[record.fullType]
    end)
end

function Jobs:startDelivery(after)
    self.execution.batch = self:deliveryOrder(self.execution.batch)
    self.execution.delivery = { index = 1, after = after, prepared = false, failed = {}, full = {}, origin = self.world:point() }
    self.execution.phase, self.execution.roomPass, self.execution.carryPass = "delivery", nil, nil
end

-- A container or vehicle is found again when its surroundings load again. False while they are not.
function Jobs:findDestination()
    local anchor, destination = self.execution.destination, self.plan.request.destination
    if not anchor then return true end
    local container, reason = self.world:resolveSource(anchor)
    if not container then return reason ~= "unloaded" end
    local part = destination.kind == "vehicle" and destination.ref and container.getVehiclePart and container:getVehiclePart()
    if destination.kind == "container" then destination.ref = container
    elseif part then destination.ref = part:getVehicle() end
    return true
end

-- Where this item would be delivered, counting what is already carried for delivery.
-- Returns the room it would take on top of base, to keep once the item has moved.
function Jobs:reserveDelivery(record, base)
    local execution, request = self.execution, self.plan.request
    record.target = nil
    if not self:findDestination() then execution.roomPass = nil; return {} end
    if not execution.roomPass then
        local err
        execution.roomPass, err = self.world:destinationPass(request, self.activeGraph)
        if not execution.roomPass then return nil, err end
    end
    local room = setmetatable({}, {__index = base or execution.batchRoom})
    local destination, err, code = self:choose(request, record.item, room, execution.roomPass)
    if not destination then return nil, err, code end
    record.target = destination
    return room
end

local function keepRoom(execution, room)
    for key, value in pairs(room or {}) do execution.batchRoom[key] = value end
end

-- What a pickup needs to know about carried storage, read again only once bags or space have changed.
function Jobs:carryPass(request)
    local execution = self.execution
    local pass, err = execution.carryPass, nil
    if not pass or pass.revision ~= execution.capacityRevision then
        pass = {revision = execution.capacityRevision}
        pass.value, err = self.world:destinationPass(request, self.activeGraph)
        execution.carryPass = pass.value and pass or nil
    end
    return pass.value, err
end

-- Light items of one type from one place, which the game moves in a single action.
function Jobs:gather(record, source, accept)
    local execution, run = self.execution, {record}
    if record.single or not Native.light(record.item) then return run end
    for index = execution.recordIndex + 1, #execution.records do
        if #run >= Native.BATCH then break end
        local other = execution.records[index]
        if other.fullType == record.fullType and other.workSource == record.workSource
            and not (other.single or other.settled or other.hauled) then
            local item = sourceItem(other, source)
            if item then
                other.item, other.source = item, source
                if self:matches(other, self.plan) and accept(other) then run[#run + 1] = other end
            end
        end
    end
    return run
end

-- Splits a run into the records the game moved and those it left, which go one by one from here.
function Jobs:settleRun(run, operation, ok)
    local moved, left = {}, {}
    for _, record in ipairs(run) do
        local item = self.native:transferResult(operation, record.itemId, record.fullType) or ok and #run == 1 and operation.resultItem
        if item then
            record.item = item
            moved[#moved + 1] = record
        else left[#left + 1] = record end
    end
    if #run > 1 then
        for _, record in ipairs(left) do record.single = true end
        if #left > 0 and Log.detailed then
            Log.trace(self.interaction, "RUN-SPLIT", "moved", #moved, "left", #left, "type", run[1].fullType)
        end
    end
    return moved, left
end

function Jobs:pickup(record)
    local execution, plan = self.execution, self.execution.plan
    if record.settled or record.hauled then self:nextRecord(); self:finishHeavyAttempt(record, false); return end
    self.view.itemName = record.itemName
    self.view.reason = "Preparing selected items for transfer."
    self:recordSource(record, function(source, err, code)
        if not source and code == "unreachable" then
            execution.failedSources[record.workSource] = {reason = err}
            self:skipUnreachable(record, err)
            self:nextRecord()
            self:finishHeavyAttempt(record, false)
            return
        end
        local ok
        if source then ok, err = self:matches(record, plan) end
        if ok and self.world:alreadySorted(plan.request, record.item, self.activeGraph) then ok, err = nil, "Already sorted" end
        if ok and plan.request.includeBags and not self.world:owns(source) and self.world:filledBag(record.item) then
            self:deferBag(record)
            self:nextRecord()
            return
        end
        if ok then
            err = bagReason(self, plan.request, self.activeGraph, record)
            ok = err == nil
        end
        if not source or not ok then
            self:skip(record, err)
            self:nextRecord()
            self:finishHeavyAttempt(record, false)
            return
        end
        local direct = carriedDestination(self, plan.request)
        local kind = plan.request.destination.kind
        local room, roomProblem, roomCode
        if not direct and kind ~= "trash" and kind ~= "matching" then room, roomProblem, roomCode = self:reserveDelivery(record) end
        if not direct and self.world:owns(source) then
            keepRoom(execution, room)
            execution.batch[#execution.batch + 1] = record
            self:nextRecord()
            return
        end
        if plan.request.destination.kind == "trash" then
            for _, target in ipairs(plan.bins) do
                if target.key == self.world:key(source) and not target.blocked then
                    if target.needsInspection then
                        self:inspectBin(target, function() execution.phase = "source" end)
                        return
                    end
                    if self:binSafe(target, source) then
                        self:empty(source, target.approved, function(emptied, failure)
                            if not emptied then self:skip(record, failure) end
                            self:nextRecord()
                        end)
                        return
                    end
                end
            end
        end
        if not direct and kind ~= "trash" and kind ~= "matching" and not room then
            if roomCode == "capacity" and #execution.batch > 0 then self:startDelivery("source")
            else
                self:skip(record, roomCode == "capacity" and "Destination full" or roomProblem)
                self:nextRecord()
                self:finishHeavyAttempt(record, false)
            end
            return
        end
        -- With both ends in reach nothing has to be carried.
        local target = record.target
        local near = not direct and not record.mustCarry and target ~= nil and target:getType() ~= "floor" and self.native:reachable(target)
        local request, pass, load = plan.request, nil, {}
        if not direct then request = { includeBags = plan.request.includeBags, destination = { kind = "inventory", cargo = self.hauled } } end
        local destination = near and target
        if not near then
            pass, err = self:carryPass(request)
            if pass then destination, err, code = self:choose(request, record.item, load, pass) end
        end
        if not destination then
            if not direct and #execution.batch > 0 then self:startDelivery("source")
            else
                if code == "capacity" and not direct then
                    if self:onCapacityBlocked(record, err) then return end
                else self:skip(record, err or "Cannot carry this item to its destination") end
                self:nextRecord()
                self:finishHeavyAttempt(record, false)
            end
            return
        end
        local hauling, rooms = not direct and not near, {[record] = room}
        local run = self:gather(record, source, function(other)
            if self.world:filledBag(other.item) or self.world:alreadySorted(plan.request, other.item, self.activeGraph) then return false end
            local base = room
            if room then
                base = self:reserveDelivery(other, room)
                if not base or near and other.target ~= target then return false end
            end
            if not near and self:choose(request, other.item, load, pass) ~= destination then return false end
            rooms[other], room = base, base
            return true
        end)
        for _, entry in ipairs(run) do
            if hauling then self.hauled[self.world:itemId(entry.item) or entry.item] = entry end
        end
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination}
        self:action(operation, function(ok, failure, failureCode)
            local moved = self:settleRun(run, operation, ok)
            for _, entry in ipairs(moved) do
                if hauling then
                    keepRoom(execution, rooms[entry])
                    entry.hauled = true
                    execution.batch[#execution.batch + 1] = entry
                    self.view.carried = self.view.carried + 1
                else
                    entry.settled = true
                    self:recordMove(entry)
                end
                local types = pass and pass.types and pass.types[destination]
                if types then types[entry.fullType] = types[entry.fullType] or {} end
            end
            local done = moved[1] == record
            if not done and #run > 1 then execution.phase = "source"; return end
            if not done and near then
                record.mustCarry, execution.phase = true, "source"
                if Log.detailed then Log.trace(self.interaction, "CARRY-INSTEAD", "item", Log.item(record.item, self.player), "reason", failure) end
                return
            end
            if not done then
                if failureCode == "capacity" and hauling then
                    if #execution.batch > 0 then self:startDelivery("source"); return end
                    if self:onCapacityBlocked(record, failure or "Native pickup refused") then return end
                else self:skip(record, failure or "Native pickup refused") end
            end
            self:nextRecord()
            self:finishHeavyAttempt(record, done)
        end, nil, run)
    end)
end

function Jobs:recordMove(record)
    self.view.done, self.view.moved = self.view.done + 1, self.view.moved + 1
    if self.completion then self.completion.movedWeight = self.completion.movedWeight + weight(record.item) end
end

function Jobs:nextDelivery(record, ok, reason, destination)
    if ok then
        self:recordMove(record)
        record.delivered, record.settled = true, true
        if not self.world:owns(destination) then self:capacityChanged() end
        if record.hauled then self.view.carried = self.view.carried - 1 end
        if self.plan.request.destination.kind == "trash" then
            local target = record.trashTarget
            target.approved[self.world:itemId(record.item)] = true
            target.touched = true
            target.used = destination:getCapacityWeight()
        end
    else
        if record.hauled and self.world:owns(record.item:getContainer()) then reason = (reason or "Delivery refused") .. "; item remains in carried storage" end
        self:skip(record, reason or "Native delivery refused")
    end
    self.execution.delivery.index = self.execution.delivery.index + 1
end

-- Hauled items a full destination refused stay in the batch; the rest is delivered first.
function Jobs:holdDelivery(record, reason)
    local delivery = self.execution.delivery
    delivery.full[#delivery.full + 1] = record
    delivery.index = delivery.index + 1
    if Log.detailed then Log.trace(self.interaction, "DESTINATION-FULL", "item", Log.item(record.item, self.player), "reason", reason) end
end

-- A record's item and the bag it is in now, which the player may have changed.
function Jobs:carriedItem(record)
    local holder = record.item:getContainer()
    local item = holder and self.world:owns(holder) and sourceItem(record, holder)
    if item then return item, holder end
    return self.world:carried(record.itemId, record.fullType)
end

-- The carried records after this one that the game can move into the same place in one action.
function Jobs:deliveryRun(record, source, destination)
    local execution, run, room = self.execution, {record}, {}
    if record.trashTarget or record.single or not Native.light(record.item) or not self:admits(record.item, destination, room) then return run end
    for index = execution.delivery.index + 1, #execution.batch do
        local other = execution.batch[index]
        if #run >= Native.BATCH or other.single or other.fullType ~= record.fullType or other.target ~= record.target
            or other.hauled ~= record.hauled then break end
        local item = sourceItem(other, source)
        if not item or self.world:filledBag(item) then break end
        other.item = item
        if not self:matches(other, self.plan) or not self:admits(item, destination, room) then break end
        run[#run + 1] = other
    end
    return run
end

function Jobs:place(record, destination)
    local execution, delivery = self.execution, self.execution.delivery
    local point
    if destination:getType() == "floor" then
        if self.plan.request.destination.kind == "matching" then
            point = self.world:matchingPoint(self.plan.request, destination)
            if not point then self:nextDelivery(record, false, "The original matching floor destination is unavailable"); return end
        elseif self.plan.request.destination.ref then point = coordinates(self.plan.request.destination.ref)
        else point = self.world:point() end
    end
    local part = destination.getVehiclePart and destination:getVehiclePart()
    self:reach(point and {kind = "ground", point = point, exact = true} or self.world:sourceAnchor(destination), function(place, err, code)
        if not place and code == "locked" and part and not delivery.unlocked then
            delivery.unlocked = true
            self:action({kind = "vehicle", vehicle = part:getVehicle()}, function(ok, problem)
                if not ok then self:nextDelivery(record, false, problem or "Vehicle access failed") end
            end)
            return
        elseif not place then self:nextDelivery(record, false, err); return end
        destination = point and self:floor() or place
        local item, source = self:carriedItem(record)
        if not item then self:nextDelivery(record, false, "Hauled item is no longer carried"); return end
        record.item = item
        local matches, reason = self:matches(record, self.plan)
        if not matches then self:nextDelivery(record, false, reason); return end
        local run = self:deliveryRun(record, source, destination)
        local operation = {kind = "transfer", item = item, source = source, destination = destination,
            trashTarget = record.trashTarget, hauled = record.hauled, destinationPoint = point}
        self:action(operation, function(ok, failure, failureCode)
            local moved, left = self:settleRun(run, operation, ok)
            for index, entry in ipairs(moved) do execution.batch[delivery.index + index - 1] = entry end
            for index, entry in ipairs(left) do execution.batch[delivery.index + #moved + index - 1] = entry end
            for _, entry in ipairs(moved) do self:nextDelivery(entry, true, nil, operation.destination) end
            if #left == 0 or #run > 1 then return end
            if failureCode == "capacity" and record.hauled and not record.trashTarget then self:holdDelivery(record, failure)
            else self:nextDelivery(record, false, failure) end
        end, nil, run)
    end)
end

local function routeKey(point, key)
    return math.floor(point.x / 8) .. ":" .. math.floor(point.y / 8) .. ":" .. point.z .. ">" .. key
end

function Jobs:binSafe(target, bin)
    local contents = bin:getItems()
    for index = 0, contents:size() - 1 do
        local item = contents:get(index)
        if self.world:protected(item) or not target.approved[self.world:itemId(item)] then
            return nil, "The bin contains protected or newly unapproved contents"
        end
    end
    return true
end

function Jobs:refreshBins()
    local known = {}
    for _, target in ipairs(self.plan.bins) do known[target.key] = true end
    local bins = self.world:trashCandidates()
    for _, bin in ipairs(bins) do
        local target = self.world:trashTarget(bin)
        if target and not known[target.key] then
            target.approved = {}
            target.needsInspection = true
            self.plan.bins[#self.plan.bins + 1] = target
            known[target.key] = true
        end
    end
end

function Jobs:probeBin()
    local execution = self.execution
    local target = self.plan.bins[execution.binProbeIndex]
    execution.binProbeIndex = execution.binProbeIndex + 1
    if not target then
        self:skip({itemName = "Trash cans"}, "No approved usable bin was found; source items were left in place. Approach a bin and review again.")
        self:complete("finished_with_skips")
        return
    end
    self.view.reason = "Inspecting a remembered trash can before collecting any items"
    self:inspectBin(target, function(ok, err)
        if ok then execution.phase = "source"
        else
            target.blocked = true
            self:skip({itemName = "Remembered trash can"}, err or "Bin could not be inspected")
            execution.phase = "binProbe"
        end
    end)
end

function Jobs:inspectBin(target, callback, attempts)
    local execution = self.execution
    local function approach()
        local bin, reason = self.world:resolveTrashTarget(target)
        if not bin then callback(false, reason); return end
        self:approach(bin, function(ok, err)
            if not ok then callback(false, err); return end
            bin, reason = self.world:resolveTrashTarget(target)
            if not bin then callback(false, reason); return end
            if isClient() then self:explore(bin) end
            execution.binInspection = {target = target, after = callback, attempts = (attempts or 0) + 1,
                deadline = now() + (isClient() and REPLY_MS or 0)}
            execution.phase = "binInspection"
            self.view.reason = "Inspecting the destination before its whole-bin deletion review"
        end)
    end
    self:walkLocation(target.point, function(ok, err)
        if ok then approach() else callback(false, err) end
    end, nil, true)
end

function Jobs:finishBinInspection()
    local pending = self.execution.binInspection
    if now() < pending.deadline then return end
    self.execution.binInspection = nil
    if not self.world:markTrashInspected(pending.target) then
        if pending.attempts < 3 then self:inspectBin(pending.target, pending.after, pending.attempts)
        else pending.after(false, "The player moved away during inspection") end
        return
    end
    self.reviewGeneration = (self.reviewGeneration or 0) + 1
    self.binReview = {target = pending.target, after = pending.after}
    self.execution.phase, self.view.state, self.view.reviewId = "binReview", "needs_review", self.reviewGeneration
    self.view.reason = "Review the inspected bin contents before continuing. The current job and item selection are retained."
    if Log.detailed then
        Log.trace(self.interaction, "BIN-REVIEW", "bin", Log.container(self.world:resolveTrashTarget(pending.target), self.player),
            "automatic", not self.execution.reviewBins)
    end
    if not self.execution.reviewBins then
        local review, reason = self:reviewBin()
        local approved, failure
        if review and review.canApprove then approved, failure = self:approveBin(review) end
        if not approved then
            local pendingReview = self.binReview
            if pendingReview then
                pendingReview.target.blocked = true
                self.binReview, self.view.state = nil, "running"
                pendingReview.after(false, failure or reason or "The bin contains protected items")
            end
        end
    end
end

function Jobs:reviewBin()
    local pending = self.binReview
    if not pending or self.ending then return nil, "This job is not waiting for a bin review" end
    local bin, reason = self.world:resolveTrashTarget(pending.target)
    if not bin or not self.world:binReachable(pending.target) then return nil, reason or "Approach the inspected bin before reviewing it" end
    local review = {moves = {}, skipped = {}, warnings = {}, pending = 0, canApprove = true,
        bin = {name = self.world:name(bin), point = pending.target.point,
            capacity = bin:getEffectiveCapacity(self.player), used = bin:getCapacityWeight(), routing = self.view.routing}}
    local approved, contents = {}, bin:getItems()
    for index = 0, contents:size() - 1 do
        local item = contents:get(index)
        local protected, reason = self.world:protected(item)
        if protected then
            review.canApprove = false
            review.skipped[#review.skipped + 1] = {itemName = item:getName(), status = "Protected", tone = "warning",
                reason = tostring(reason or "Item is protected") .. "; whole-bin deletion is blocked"}
        else review.moves[#review.moves + 1] = {itemName = withContents(self, item), status = "Delete", tone = "danger",
            from = "Existing bin contents", to = "Delete with approved cleanup"} end
        approved[self.world:itemId(item)] = true
    end
    review.warnings[1] = "Continuing approves native whole-bin deletion of these existing contents and the selected items the job delivers."
    if isClient() then review.warnings[#review.warnings + 1] = "Multiplayer shows client-observed contents. Empty replies are not acknowledged to Lua, and concurrent shared-bin changes cannot be made atomic by a client mod." end
    pending.token, pending.approved = review, approved
    return review
end

function Jobs:approveBin(review, options)
    local pending = self.binReview
    if not pending or not review or not pending.token or pending.token ~= review or self.ending then return nil, "Review this bin again before continuing" end
    local bin = self.world:resolveTrashTarget(pending.target)
    if not bin or not self.world:binReachable(pending.target) then return nil, "The bin is no longer available here" end
    local temporary = {approved = pending.approved}
    local ok, err = self:binSafe(temporary, bin)
    if not ok then return nil, err end
    pending.target.approved, pending.target.needsInspection = pending.approved, nil
    if options and options.reviewBins == false then self.execution.reviewBins = false end
    self.binReview, self.view.state = nil, "running"
    self.view.reason = "Continuing the current cleanup with the reviewed bin"
    pending.after(true)
    return true
end

function Jobs:rejectBin(review)
    local pending = self.binReview
    if not pending or not review or not pending.token or pending.token ~= review or self.ending then return nil, "This bin review is no longer active" end
    pending.target.blocked = true
    self.binReview, self.view.state = nil, "running"
    self.view.reason = "Trying another bin for the current cleanup"
    pending.after(false, "Bin skipped by the player")
    return true
end

function Jobs:rankBins(record)
    local execution, delivery = self.execution, self.execution.delivery
    local records, weights, carrying = {}, {}, 0
    for index = delivery.index, #execution.batch do
        local entry = execution.batch[index]
        records[#records + 1] = entry
        carrying = carrying + weight(entry.item)
    end
    local returnPoint = self.world:point()
    for index = execution.recordIndex, #execution.records do
        local entry = execution.records[index]
        if not entry.settled and not self.world:protected(entry.item) then
            if #records == #execution.batch - delivery.index + 1 then
                local square = self.world:square(entry.source)
                if square then returnPoint = {x = square:getX(), y = square:getY(), z = square:getZ()} end
            end
            records[#records + 1] = entry
        end
    end
    for _, entry in ipairs(records) do weights[#weights + 1] = weight(entry.item) end
    local from, candidates, targets, pendingBins = self.world:point(), {}, {}, {}
    for _, target in ipairs(self.plan.bins) do
        if target.touched then
            self.world:resolveTrashTarget(target)
            if target.used > 0 then pendingBins[#pendingBins + 1] = target end
        end
    end
    for _, target in ipairs(self.plan.bins) do
        local path = routeKey(delivery.origin, target.key)
        if not target.blocked and not delivery.failed[target.key] and not execution.failedRoutes[path] then
            local bin, reason = self.world:resolveTrashTarget(target)
            local safe = bin and (target.needsInspection or self:binSafe(target, bin))
            if safe or reason == "unloaded" then
                local outbound, provenance = self.routing:estimate(from, target.point)
                local back = self.routing:estimate(target.point, returnPoint)
                local repeatCost = self.routing:estimate(returnPoint, target.point)
                local accepts = {}
                for index, entry in ipairs(records) do accepts[index] = not bin or bin:isItemAllowed(entry.item) end
                local deferredEmptyCount, deferredTravel = 0, 0
                for _, pending in ipairs(pendingBins) do
                    if pending ~= target then
                        deferredEmptyCount = deferredEmptyCount + 1
                        local outward = self.routing:estimate(target.point, pending.point)
                        local inward = self.routing:estimate(pending.point, target.point)
                        deferredTravel = deferredTravel + outward + inward
                    end
                end
                candidates[#candidates + 1] = {key = target.key, container = target, capacity = target.capacity,
                    used = target.used, outbound = outbound, returnCost = back, repeatCost = repeatCost, accepts = accepts,
                    deferredEmptyCount = deferredEmptyCount, deferredTravel = deferredTravel}
                target.provenance = provenance
                targets[target.key] = target
            end
        end
    end
    local ranked = Routing.rank(candidates, weights, math.max(carrying, weight(record.item)))
    local first = ranked[1]
    if first then
        local target = targets[first.key]
        self.view.routing = first.reason .. "; travel " .. tostring(target.provenance)
        return target
    end
    for _, target in ipairs(self.plan.bins) do
        if target.needsInspection and not target.blocked and not delivery.failed[target.key]
            and not execution.failedRoutes[routeKey(delivery.origin, target.key)] then
            self.view.routing = "Inspecting an unreviewed bin before asking for contents approval"
            return target
        end
    end
end

function Jobs:trashDestination(record)
    local execution, delivery = self.execution, self.execution.delivery
    local target = delivery.target
    if not target then target = self:rankBins(record); delivery.target = target end
    if not target then
        self:nextDelivery(record, false, "No reachable approved trash can can hold this item after emptying")
        delivery.failed = {}
        return
    end
    local function retry(reason, failedRoute)
        self.view.reason = reason
        delivery.failed[target.key], delivery.target = true, nil
        if failedRoute then execution.failedRoutes[routeKey(delivery.origin, target.key)] = reason end
        execution.phase = "delivery"
    end
    local function use()
        local bin, reason = self.world:resolveTrashTarget(target)
        if not bin then retry("Trash can could not be resolved after walking: " .. tostring(reason), true); return end
        local safe, failure = self:binSafe(target, bin)
        if not safe then retry(failure); return end
        target.needsInspection = nil
        if not bin:isItemAllowed(record.item) then retry("The selected bin does not accept this item"); return end
        if weight(record.item) > bin:getEffectiveCapacity(self.player) then retry("The item exceeds this bin's empty capacity"); return end
        self:approach(bin, function(ok, err)
            if not ok then retry(err, true); return end
            bin, reason = self.world:resolveTrashTarget(target)
            if not bin then retry(reason, true); return end
            local function check(emptied, problem)
                if emptied and bin:hasRoomFor(self.player, record.item) then
                    record.trashTarget = target
                    self:place(record, bin)
                else retry(problem or "This item cannot fit after emptying the bin") end
            end
            if not bin:hasRoomFor(self.player, record.item) and not bin:getItems():isEmpty() then
                self:empty(bin, target.approved, check)
            else check(true) end
        end)
    end
    if target.needsInspection then
        self:inspectBin(target, function(ok, err)
            execution.phase = "delivery"
            if not ok then retry(err, true) end
        end)
        return
    end
    if self.world:locationLoaded(target.point) then use()
    else
        self:walkLocation(target.point, function(ok, err)
            execution.phase = "delivery"
            if ok then use() else retry(err, true) end
        end, nil, true)
    end
end

function Jobs:deliveryStep()
    local execution, delivery = self.execution, self.execution.delivery
    if not delivery.prepared then
        delivery.prepared = true
        local kind = self.plan.request.destination.kind
        if kind == "trash" then self:refreshBins() end
        if not self:findDestination() then
            if Log.detailed then Log.trace(self.interaction, "DESTINATION-UNLOADED", "at", Log.point(execution.destination.point), "carried", self.view.carried) end
            self:walkLocation(execution.destination.point, function(ok, reason)
                execution.phase = "delivery"
                if not ok then delivery.failure = reason else self:findDestination() end
            end, nil, true)
            return
        end
        -- Finding labelled storage reads the surroundings, so one delivery looks once.
        if kind == "labels" then delivery.pass = self.world:destinationPass(self.plan.request, self.activeGraph) end
    end
    local record = execution.batch[delivery.index]
    if not record and #delivery.full > 0 then
        execution.batch, delivery.full, delivery.index, delivery.pass = delivery.full, {}, 1, nil
        self:finishWhenSettled("paused", "Destination full: " .. #execution.batch .. " carried items have no room there", "destination-full")
        return
    end
    if not record then
        execution.batch, execution.batchRoom = {}, {}
        execution.phase, execution.delivery = delivery.after, nil
        if execution.phase == "source" then execution.afterCarry, execution.phase = "source", "carry" end
        return
    end
    self.view.itemName = record.itemName
    local item, holder = self:carriedItem(record)
    if not item then self:nextDelivery(record, false, "Hauled item is no longer carried"); return end
    record.item = item
    local ok, err = self:matches(record, self.plan)
    if not ok or delivery.failure then self:nextDelivery(record, false, delivery.failure or err); return end
    if self.plan.request.destination.kind == "trash" then self:trashDestination(record)
    else
        local destination, code = record.target, nil
        if not destination or destination == holder or not self.world:valid(destination) or not self:admits(item, destination) then
            destination, err, code = self:choose(self.plan.request, item, nil, delivery.pass)
            if not destination and delivery.pass then
                destination, err, code = self:choose(self.plan.request, item)
            end
            record.target = destination
        end
        if destination then self:place(record, destination)
        elseif code == "capacity" and record.hauled then self:holdDelivery(record, err)
        else self:nextDelivery(record, false, err) end
    end
end

-- Opens a container the way the loot window does on arrival.
function Jobs:explore(container)
    local loot = getPlayerLoot(self.player:getPlayerNum())
    if not loot then return nil, "The native loot window is not available" end
    loot:checkExplored(container, self.player)
    return true
end

function Jobs:discoverSource(source, anchor)
    local execution = self.execution
    self:reach(anchor, function(current, reason)
        local opened
        if current then opened, reason = self:explore(current) end
        if not opened then
            self:skip({itemName = self.world:name(source)}, reason)
            execution.phase = "source"
            return
        end
        local records = self.world:records(current, self.plan.request.includeBags)
        if isClient() and #records == 0 then
            execution.discovery = {source = current, anchor = anchor, deadline = now() + REPLY_MS}
            execution.phase = "discoveryWait"
        else self:addObserved(records) end
    end)
end

-- What a multiplayer container holds can arrive late, so those that looked empty are read once more at the end.
function Jobs:lookAgain()
    local execution, empty = self.execution, self.execution.empty
    local last = execution.lookedAgain
    execution.empty, execution.lookedAgain = {}, true
    for _, entry in ipairs(empty) do
        local container = self:resolve(entry.anchor)
        local filled = container and not container:getItems():isEmpty()
        if Log.detailed then Log.trace(self.interaction, "LOOK-AGAIN", "container", container and Log.container(container, self.player), "filled", filled == true) end
        if filled and not last then
            execution.tasks[#execution.tasks + 1] = {kind = "discover", container = container, anchor = entry.anchor, point = entry.anchor.point}
        else
            table.insert(self.view.reasons, {itemName = self.world:name(entry.source), status = "Empty", tone = "dim",
                reason = "Looked empty. In multiplayer the game does not confirm that."})
        end
    end
    return #execution.tasks > 0
end

function Jobs:sourceStep()
    local execution = self.execution
    local record = execution.records[execution.recordIndex]
    while record and (record.settled or record.hauled or execution.failedSources[record.workSource]) do
        if not (record.settled or record.hauled) then self:skipUnreachable(record, execution.failedSources[record.workSource].reason) end
        self:nextRecord()
        self:finishHeavyAttempt(record, false)
        if execution.phase ~= "source" then return end
        record = execution.records[execution.recordIndex]
    end
    if record then self:pickup(record); return end
    local task = self:nextTask()
    if not task then
        if self.plan.survey and not self.plan.survey.complete then execution.phase = "survey"
        elseif #execution.batch > 0 then self:startDelivery("source")
        elseif not self:retryDeferred() and not self:lookAgain() then execution.phase = "finalTrash" end
    elseif task.kind == "records" then execution.records, execution.recordIndex = task.records, 1
    else self:discoverSource(task.container, task.anchor) end
end

function Jobs:carriedCount()
    local count = 0
    for _, record in pairs(self.hauled or {}) do
        local item = not record.delivered and self:carriedItem(record)
        if item then record.item = item; count = count + 1 end
    end
    return count
end

function Jobs:complete(state, reason, trigger)
    local recoveryOnly = self.execution and self.execution.recoveryOnly
    local completion, plan = self.completion, self.plan
    trigger = trigger or self.ending and self.ending.trigger
    if self.execution and self.execution.condense then
        self.view.condense = self.execution.condense:status()
        if (self.view.condense.buffered or 0) > 0 then
            reason = (reason or "Condense stopped") .. "; a bag arrangement is incomplete and buffered items remain carried."
            if state == "paused" then reason = reason .. " Resume to finish or repair it." end
        end
    end
    if state == "failed" and self.execution and self.execution.recoveryOnly then
        self.suspended = self.execution.resumeSaved
    end
    self.view.carried = self:carriedCount()
    if not reason and (state == "finished" or state == "finished_with_skips") then
        reason = state == "finished" and "Finished the selected job."
            or "Finished with notes."
    end
    self.view.state, self.view.reason = state, reason or self.view.reason
    if self.view.carried > 0 then self.view.reason = (self.view.reason and self.view.reason .. "; " or "") .. self.view.carried .. " hauled items remain in carried storage" end
    if self.operation and self.operation.completed and self.operation.op.kind == "trash" then self:settleTrash(self.operation) end
    if state == "paused" and self.execution then
        self.suspended = {execution = self.execution, operation = self.operation, graph = self.activeGraph, binReview = self.binReview,
            interaction = self.interaction, startedAt = self.startedAt, opCount = self.opCount}
        if self.binReview then self.binReview.token, self.binReview.approved = nil, nil end
        for _, target in ipairs(self.plan.bins or {}) do target.approved, target.needsInspection = {}, true end
        self.view.reason = (self.view.reason or "Stopped") .. ". Choose Resume job to continue."
    end
    self:logEnd(state == "paused" and "PAUSE" or "END", state, trigger)
    self.execution, self.pending, self.operation, self.activeGraph, self.ending, self.binReview = nil, nil, nil, nil, nil, nil
    self.view.waiting = nil
    if state == "cancelled" then
        -- Keep the personal-gear receipt separate from discarded scheduler state.
        -- Cancellation is terminal; only Pause retains execution callbacks.
        self.suspended = nil
    end
    if not self.suspended then
        -- Terminal status is a display snapshot, not an owner of planning graphs.
        -- A failed recovery may still own a paused checkpoint and must retain it.
        self.plan, self.carry, self.hauled, self.completion = nil, nil, nil, nil
    end
    if completion and state ~= "paused" and (not recoveryOnly or state == "cancelled") then
        Completion.job(self.player, plan, self.view, completion)
    end
end

function Jobs:advance()
    if self.pending then
        local done, reason, code = self.native:poll()
        if done == nil then return end
        local work = self.pending
        local yielded = not done and (code == "yielded" or code == "busy")
        self.pending = nil
        self:logOpEnd(work.op, done and "ok" or yielded and "yielded" or "failed", reason, code)
        if yielded then self:waitForPlayer(work)
        else self:finishOperation(work, done, reason, code, work.op) end
        return
    end
    if self.operation then self:continueOperation(); return end
    local execution = self.execution
    if execution.phase == "condense" then self:condenseStep()
    elseif execution.phase == "recovery" then self:recoveryStep()
    elseif execution.phase == "heavyEmpty" then self:heavyEmptyStep()
    elseif execution.phase == "carry" then self:carryStep()
    elseif execution.phase == "source" then self:sourceStep()
    elseif execution.phase == "binProbe" then self:probeBin()
    elseif execution.phase == "binInspection" then self:finishBinInspection()
    elseif execution.phase == "binReview" then return
    elseif execution.phase == "survey" then self:surveyStep()
    elseif execution.phase == "surveyScan" then self:surveyScan()
    elseif execution.phase == "walk" then self:walkStep()
    elseif execution.phase == "delivery" then self:deliveryStep()
    elseif execution.phase == "discoveryWait" then
        local discovery = execution.discovery
        if not discovery.source:getItems():isEmpty() then
            self:addObserved(self.world:records(discovery.source, self.plan.request.includeBags))
        elseif now() >= discovery.deadline then
            execution.empty[#execution.empty + 1] = discovery
            execution.phase = "source"
        end
    elseif execution.phase == "finalTrash" then
        local target = self.plan.bins[execution.finalBin]
        execution.finalBin = execution.finalBin + 1
        if not target and #execution.unlocked > 0 then self:relockStep()
        elseif not target then
            local unsearched = self.view.survey and self.view.survey.sectionsUnsearched or 0
            self:complete((self.view.skipped > 0 or unsearched > 0) and "finished_with_skips" or "finished")
        elseif target.touched then
            self:walkLocation(target.point, function(arrived, failure)
                execution.phase = "finalTrash"
                local bin = arrived and self.world:resolveTrashTarget(target)
                if not bin then self:skip({itemName = "Trash can"}, failure or "Touched bin is unavailable; contents were retained")
                elseif not bin:getItems():isEmpty() then
                    self:empty(bin, target.approved, function(ok, err) if not ok then self:skip({itemName = self.world:name(bin)}, err) end end)
                end
            end, nil, true)
        end
    else error("Unknown job execution phase") end
end

-- Locks the vehicles this job unlocked, once everything is delivered.
function Jobs:relockStep()
    local execution = self.execution
    local vehicle, ids, seen, rest = execution.unlocked[1].vehicle, {}, {}, {}
    for _, entry in ipairs(execution.unlocked) do
        if entry.vehicle ~= vehicle then rest[#rest + 1] = entry
        elseif not seen[entry.partId] then seen[entry.partId] = true; ids[#ids + 1] = entry.partId end
    end
    self.view.reason = "Locking the vehicle again."
    self:action({kind = "vehicle", vehicle = vehicle, relock = ids}, function(ok, reason)
        execution.unlocked = rest
        if not ok then self:skip({itemName = "Vehicle"}, "The vehicle was left unlocked: " .. tostring(reason)) end
        execution.phase = "finalTrash"
    end)
end

function Jobs:finishWhenSettled(state, reason, trigger)
    self.ending = self.ending or {state = state, reason = reason, trigger = trigger}
    self.view.state = state == "paused" and "pausing" or "cancelling"
    local ok, result, err = pcall(self.native.cancel, self.native, self.operation and self.operation.op)
    if not ok or result == false then
        local problem = tostring(ok and err or result)
        self.ending.reason = (self.ending.reason or "") .. "; cancellation error: " .. problem
        if ok then Log.warn(self.interaction, "CANCEL-FAILED", "reason", problem) else Log.fault(self.interaction, "Native.cancel", problem) end
    end
end

-- The record a failing step was working on, if it was working on one.
function Jobs:currentRecord()
    local execution = self.execution
    if execution.delivery then return execution.batch[execution.delivery.index], true end
    if execution.phase == "source" or execution.phase == "walk" then return execution.records and execution.records[execution.recordIndex], false end
end

-- A thrown error leaves the failing step behind first, so that Resume does not
-- repeat it, and stops the job when it keeps happening or nothing can be skipped.
function Jobs:onFault(err, trace)
    local execution = self.execution
    if not execution then Log.fault(self.interaction, "Jobs:ended", err, "trace", trace); return end
    local record, delivering = self:currentRecord()
    Log.fault(self.interaction, "Jobs:" .. tostring(execution.phase), err, "trace", trace,
        "record", record and record.item and Log.item(record.item, self.player), "op", self.operation and self.operation.op.kind,
        "player", Log.player(self.player))
    execution.faults = (execution.faults or 0) + 1
    local op, skipped = self.operation and self.operation.op, false
    if self.pending then self:logOpEnd(self.pending.op, "interrupted", "internal error") end
    if record then
        self.operation, self.pending, execution.walk = nil, nil, nil
        local reason = "An internal error stopped this item; the LootBox log has the details"
        local problem
        skipped, problem = pcall(function()
            if delivering then self:nextDelivery(record, false, reason)
            else self:skip(record, reason); self:nextRecord(); self:finishHeavyAttempt(record, false) end
        end)
        if not skipped then Log.fault(self.interaction, "Jobs:skip-after-fault", problem) end
        if delivering then execution.phase = "delivery" end
    elseif execution.phase == "carry" then
        self.operation, self.pending = nil, nil
        execution.phase, skipped = execution.afterCarry or "source", true
    end
    if not skipped or execution.faults >= MAX_FAULTS then
        self:finishWhenSettled("paused", "LootBox hit an internal error; the LootBox log has the details (" .. tostring(err) .. ")", "error")
    elseif self.native:isBusy() then
        local ok, problem = pcall(self.native.cancel, self.native, op)
        if not ok then Log.fault(self.interaction, "Native.cancel", problem) end
    end
end

function Jobs:tick()
    local stamp = now()
    if self.execution and self.completion and not self.execution.recoveryOnly then
        self.completion.elapsed = self.completion.elapsed + stamp - (self.lastTick or stamp)
    end
    self.lastTick = stamp
    if self.execution and not self.ending then
        local reason, _, trigger = self.native:takeoverReason()
        if reason then self:finishWhenSettled("paused", reason, trigger) end
    end
    if self.ending then
        if self.native:isBusy() then
            local op = self.pending and self.pending.op
            local ok, result, err = pcall(self.native.poll, self.native)
            if not ok then
                self.view.reason = "Native cleanup error: " .. tostring(result)
                Log.fault(self.interaction, "Native.poll:cleanup", result, "trace", err)
                return
            end
            if result == nil then return end
            if op then self:logOpEnd(op, result and "ok" or "interrupted", err) end
            if result == true and self.pending and self.pending.op == self.operation.op
                and (self.operation.op.kind == "transfer" or self.operation.op.kind == "trash" or self.operation.op.kind == "gear") then self.operation.completed = true end
            if err and err ~= "Cancelled" then self.ending.reason = (self.ending.reason and self.ending.reason .. "; " or "") .. err end
        end
        self:complete(self.ending.state, self.ending.reason)
    elseif self.execution then
        -- A step given up after an error still has to come to rest.
        if self.native:isBusy() and not self.pending then
            local ok, result = pcall(self.native.poll, self.native)
            if not ok then Log.fault(self.interaction, "Native.poll:drain", result); return end
            if result == nil then return end
        end
        if not self.native:isBusy() and self.native:isPlayerBusy() then self:waitForPlayer(self.operation); return end
        self.view.waiting = nil
        local ok, err, trace = pcall(self.advance, self)
        if not ok then self:onFault(err, trace) end
        self:logPhase()
    end
end

function Jobs:resume()
    local saved = self.suspended
    if not saved or self.ending or self.native:isBusy() then return nil, "There is no stopped job ready to resume" end
    if self.recoveryRequired and not saved.execution.recoveryOnly then return nil, "Recover personal gear before resuming the ordinary job" end
    if self.player:isDead() or self.player:isAsleep() then return nil, "The player cannot resume this job now" end
    local reason = self.native:takeoverReason()
    if reason then return nil, reason .. ". Stop that action before choosing Resume job." end
    self.execution, self.operation, self.activeGraph, self.binReview = saved.execution, saved.operation, saved.graph, nil
    self.reviews, self.previews = {}, {}
    self.startedAt, self.opCount = saved.startedAt, saved.opCount
    self:bindInteraction(saved, "resume")
    self.suspended, self.view.state, self.view.reason = nil, "running", "Continuing the stopped job with current item and destination checks."
    self.execution.faults, self.execution.failedSources = 0, {}
    Log.info(self.interaction, "RESUME", "phase", self.execution.phase, "player", Log.player(self.player))
    if self.execution.condense then self.execution.condense:onResume() end
    if self.operation and not self.operation.completed then self.operation.retry = true end
    if saved.binReview then self:inspectBin(saved.binReview.target, saved.binReview.after)
    elseif not self.operation and self.execution.binInspection then
        local pending = self.execution.binInspection
        self.execution.binInspection = nil
        self:inspectBin(pending.target, pending.after)
    elseif not self.operation and self.execution.phase == "discoveryWait" then
        local pending = self.execution.discovery
        self.execution.discovery = nil
        self:discoverSource(pending.source, pending.anchor)
    elseif not self.operation and self.execution.phase == "surveyScan" then
        local pending, execution = self.execution.section, self.execution
        self:walkLocation(self.world:sectionTarget(pending.section), function(ok, failure)
            if not ok then
                local scan, missing, denied = self.world:scanSection(pending.section, self.plan.request)
                self:acceptSection(pending.section, scan, missing, denied, failure)
            else
                pending.deadline, pending.nextScan = now() + 5000, 0
                execution.phase = "surveyScan"
            end
        end, self.plan.survey.building)
    end
    return true
end

-- trigger names the control for the log, such as "escape" or "toolbar".
function Jobs:pause(trigger)
    if self.ending then return true end
    if not self.execution then return nil, "There is no running job to pause" end
    self:finishWhenSettled("paused", "Paused by the player", trigger or "player")
    return true
end

function Jobs:cancel(silent)
    if silent then self.completion = nil end
    if self.ending then
        -- Cancel supersedes an in-flight Pause without issuing native cleanup twice.
        self.ending.state, self.ending.reason, self.ending.trigger = "cancelled", "Cancelled", silent and "session-end" or "player"
        self.view.state = "cancelling"
        return true
    end
    if not self.execution and not self.native:isBusy() then
        if self.suspended then self:complete("cancelled", "Cancelled", silent and "session-end" or "player") end
        return true
    end
    self:finishWhenSettled("cancelled", "Cancelled", silent and "session-end" or "player")
    return true
end

return Jobs
