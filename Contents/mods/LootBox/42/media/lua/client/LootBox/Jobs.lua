local Native = require "LootBox/Native"
local Categories = require "LootBox/Categories"
local Routing = require "LootBox/Routing"
local Carry = require "LootBox/Carry"
local Condense = require "LootBox/Condense"
local Completion = require "LootBox/CompletionFeedback"
local Log = require "LootBox/Log"
local Sort = require "LootBox/Sort"
local Jobs = {}
Jobs.__index = Jobs

-- How long a searched multiplayer container may stay empty before it counts as
-- unconfirmed. The game never acknowledges an empty reply.
local REPLY_MS = 1000
local HAULED, MAX_PREVIEWS, MAX_FAULTS, MAX_LOGGED = {hauled = true}, 4, 3, 12

local function now() return getTimestampMs() end
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
    -- canStart: the engine is idle. canPreview is its older name; preview() itself works during a job.
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
    local carryBlocked, capacityBlocked = false, false
    for _, destination in ipairs(candidates) do
        local same = destination == item:getContainer()
        if same and destination:getType() == "floor" and request.destination.ref then
            local worldItem = item:getWorldItem()
            same = not worldItem or worldItem:getSquare() == request.destination.ref
        end
        local allowed = not same and not destination:isInside(item) and destination:isItemAllowed(item)
        local room = allowed and destination:hasRoomFor(self.player, item)
        if allowed and not room then capacityBlocked = true end
        if room then
            local reserved = reservations and reservations[destination] or 0
            local capacity = destination:getEffectiveCapacity(self.player)
            local delta = self.world:carryDelta(item, destination)
            local current, maximum = self.world:carrying()
            local main = destination == self.player:getInventory()
            local added = main and math.max(0, delta) or weight(item)
            if destination:getType() == "floor" or (main and maximum == math.huge)
                or destination:getCapacityWeight() + reserved + added <= capacity then
                local reservedCarry = reservations and reservations.carriedMass or 0
                if delta <= 0 or current + reservedCarry + delta <= maximum + 0.0001 then
                    if reservations then
                        reservations[destination] = reserved + added
                        reservations.carriedMass = reservedCarry + math.max(0, delta)
                    end
                    return destination
                end
                carryBlocked = true
            else capacityBlocked = true end
        end
    end
    return nil, carryBlocked and "Native hard carrying limit reached; deliver the current load first"
        or "No matching destination with room for this item",
        (carryBlocked or capacityBlocked) and "capacity" or nil
end

local function matchesSelection(graph, request, descriptor, item, player)
    return graph:matchesFilter(request.filter, descriptor)
        and not (request.excludeUnwanted == true and item.isUnwanted and item:isUnwanted(player))
end

local function validate(request)
    if type(request) ~= "table" or type(request.filter) ~= "table" or type(request.destination) ~= "table" then
        return nil, "Choose what to move, where to look, and a destination"
    end
    for _, values in ipairs({request.filter.ids or {}, request.filter.types or {}, request.sourceLabels or {}, request.destination.labels or {}}) do
        if type(values) ~= "table" then return nil, "Category and item selections must be lists of IDs" end
        local count = 0
        for key, value in pairs(values) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #values or type(value) ~= "string" or value == "" then
                return nil, "Category and item selections must be lists of IDs"
            end
            count = count + 1
        end
        if count ~= #values then return nil, "Category and item selections must be dense lists" end
    end
    if not request.filter.all and #(request.filter.ids or {}) == 0 and #(request.filter.types or {}) == 0 then
        return nil, "Select at least one category or item type"
    end
    local scopes = { inventory = true, reach = true, room = true, building = true, area = true, container = true, lootPane = true, labeled = true }
    local destinations = { inventory = true, floor = true, container = true, vehicle = true, labels = true, trash = true, matching = true }
    if not scopes[request.scope] then return nil, "Choose a source scope" end
    if not destinations[request.destination.kind] then return nil, "Choose a destination" end
    if request.scope == "container" and not request.sourceContainer then return nil, "Choose a source container" end
    if request.scope == "lootPane" and type(request.sourceContainers) ~= "table" then return nil, "Choose the visible loot containers" end
    if request.scope == "labeled" and #(request.sourceLabels or {}) == 0 then return nil, "Choose a source label" end
    if request.destination.kind == "container" and not request.destination.ref then return nil, "Choose a destination container" end
    if request.destination.kind == "matching" and request.destination.mode ~= nil
        and request.destination.mode ~= "displayed" and request.destination.mode ~= "nearby" then
        return nil, "Choose the displayed container or nearby containers for matching transfers"
    end
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
        if isClient() then
            table.insert(plan.warnings, "Native multiplayer does not acknowledge empty container replies to Lua. Newly searched sources stay unconfirmed; this job cannot certify that the whole scope is clear.")
        end
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
    local info = controller:preview()
    local request = {scope = "inventory", shortcutIntent = "condense", includeBags = true, filter = {all = true, ids = {}, types = {}},
        destination = {kind = "inventory"}}
    local display = {}
    for _, key in ipairs({"mode", "eligible", "bagCount", "beforeWeight", "estimatedSaving", "useUnequipped", "nested", "reason"}) do display[key] = info[key] end
    display.useUnequipped, display.nested = options ~= nil and options.useUnequipped == true, options ~= nil and options.nested == true
    local plan = {owner = self, action = "condense", condense = display,
        request = cloneRequest(request), moves = {}, skipped = {}, warnings = {}, pending = 0}
    for _, row in ipairs(info.steps or {}) do
        plan.moves[#plan.moves + 1] = {itemName = row.itemName, from = row.from, to = row.to,
            status = row.temporary and "Put aside for a moment" or "Move", tone = row.temporary and "warning" or "success"}
    end
    plan.warnings[1] = "Every move is checked again just before it is made."
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

function Jobs:bindInteraction(options, label)
    self.interaction = options and options.interaction or Log.intent("engine", label, self.player)
    self.native.interaction = self.interaction
    if self.recovery then self.recovery.interaction = self.interaction end
end

function Jobs:start(plan, options)
    local reviewed, reason = self.reviews[plan], nil
    if engineBusy(self) then reason = "A LootBox job is already active"
    elseif not reviewed then reason = "Preview this job again before starting"
    else reason = seatedProblem(self, reviewed) end
    if reason then
        Log.info(options and options.interaction or reviewed and reviewed.request.interaction, "START-REFUSED", "reason", reason, "player", Log.player(self.player))
        return nil, reason
    end
    self:bindInteraction({interaction = options and options.interaction or reviewed.request.interaction},
        reviewed.request.shortcutIntent or reviewed.action or "transfer")
    self:logPlan(self.interaction, reviewed)
    self.reviews, self.previews, self.recoveryRequired = {}, {}, nil
    self.completion = {startedAt = now(), movedWeight = 0}
    self.plan, self.cancelled, self.ending, self.hauled, self.suspended = reviewed, false, nil, {}, nil
    self.activeGraph, self.startedAt, self.lastTick, self.opCount, self.loggedPhase = reviewed.graph, now(), now(), 0, nil
    Log.info(self.interaction, "START", "action", reviewed.action or "transfer", "records", #(reviewed.records or {}),
        "skipped", #reviewed.skipped, "unopened", #(reviewed.unknownSources or {}), "bins", #reviewed.bins, "player", Log.player(self.player))
    if reviewed.action == "condense" then
        reviewed.condense.interaction = self.interaction
        local info = reviewed.condense:status()
        self.view = {state = "running", done = 0, moved = 0, cleared = 0, total = info.planned,
            skipped = 0, reasons = {}, carried = 0, unconfirmedSources = 0, condense = info,
            reason = "Packing your bags."}
        self.execution = {phase = "condense", condense = reviewed.condense, batch = {}, reviewBins = false, unlocked = {}}
        return true
    end
    self.view = { state = "running", done = 0, moved = 0, cleared = 0, deferred = 0, total = #reviewed.records, skipped = #reviewed.skipped,
        reasons = copyList(reviewed.skipped), carried = 0, unconfirmedSources = 0 }
    self.execution = self:createExecution(reviewed)
    self.execution.reviewBins = not (options and options.reviewBins == false)
    self.carry = Carry.new(self.player, self.world)
    self.execution.afterCarry, self.execution.phase = reviewed.binProbe and "binProbe" or "source", "carry"
    if reviewed.binProbe then self.execution.binProbeIndex = 1 end
    if reviewed.survey then self.view.survey = reviewed.survey:status() end
    return true
end

function Jobs:condenseStep()
    local controller = self.execution.condense
    local op, reason, done = controller:next()
    self.view.condense = controller:status()
    if op then
        op.condense = true
        self.view.itemName = tostring(op.item:getName())
        self.view.reason = "Packing your bags."
        self:action(op, function(ok, failure)
            local continuing, problem = controller:settle(op, ok, failure)
            local status = controller:status()
            self.view.condense = status
            self.view.done, self.view.moved = status.transfers or 0, status.transfers or 0
            self.view.total = math.max(status.planned, self.view.done)
            if not continuing then self:finishWhenSettled("paused", problem) end
        end)
    elseif done then
        local status = self.view.condense
        if status.limited then self:skip({itemName = "Condense"}, reason) end
        self:complete(status.limited and "finished_with_skips" or "finished", reason)
    else self:finishWhenSettled("paused", reason) end
end

function Jobs:checkCondense(op)
    if not op.condense then return true end
    local controller = self.execution and self.execution.condense
    if not controller then return nil, "Condense is no longer running" end
    return controller:validate(op)
end

function Jobs:logOp(op)
    self.opCount, self.opStarted = self.opCount + 1, now()
    if not Log.detailed then return end
    Log.trace(self.interaction, "OP", "n", self.opCount, "kind", op.kind, "mode", op.mode,
        "item", op.item and Log.item(op.item, self.player),
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
        "carried", v.carried, "unconfirmed", v.unconfirmedSources, "phase", self.execution and self.execution.phase,
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

local function completeTransfer(self, work, source, destination)
    local op = work.op
    return self.native:transferResult({source = source, destination = destination,
        sourcePoint = op.sourcePoint, destinationPoint = op.destinationPoint,
        floorDestinations = op.floorDestinations}, work.itemId, work.fullType)
end

-- operation is the native step that failed, when one had begun.
function Jobs:finishOperation(work, ok, reason, code, operation)
    self.operation, self.pending, self.view.waiting = nil, nil, nil
    if self.execution then
        for _, entry in ipairs(work.op.unlocked or {}) do table.insert(self.execution.unlocked, entry) end
        work.op.unlocked = nil
        if ok then self.execution.faults = 0 end
    end
    if not ok and code == "seated" then
        work.retry, self.operation = true, work
        self:finishWhenSettled("paused", reason, "seated")
        return
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

function Jobs:retryWalk(work, point)
    work.walk = work.walk or {visited = {}, hops = 0}
    local walk = work.walk
    if walk.hops >= 2048 then return nil, "The original location could not be reached after interruption" end
    local targets, direct = self.world:walkTargets(point, walk.visited)
    if not targets then return nil, direct end
    walk.hops = walk.hops + 1
    for _, target in ipairs(targets) do walk.visited[pointKey(target)] = true end
    local operation = {kind = "approach"}
    if direct then operation.location = targets[1] else operation.locations = targets end
    return operation
end

function Jobs:prepareOperation(work)
    local op = work.op
    if op.kind == "transfer" then
        local source, destination = op.source, op.destination
        local observed = completeTransfer(self, work, source, destination)
        if observed then op.resultItem = observed; return {}, nil, nil, true end
        if work.sourcePoint then
            if not self.world:locationLoaded(work.sourcePoint) then
                local approach, reason = self:retryWalk(work, work.sourcePoint)
                return approach and {approach} or nil, reason, true
            end
            if not work.sourcePrepared then
                work.sourcePrepared = true
                return {{kind = "approach", location = work.sourcePoint}}, nil, true
            end
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then return nil, "The native loot window is not available" end
            loot:refreshBackpacks()
            source = ISInventoryPage.GetFloorContainer(self.player:getPlayerNum())
        end
        local missing
        if work.sourceAnchor then
            local reason
            source, reason = self.world:resolveSource(work.sourceAnchor)
            if not source and reason == "unloaded" then missing = work.sourceAnchor.point
            elseif not source then return nil, reason end
        end
        if work.destinationAnchor then
            local reason
            destination, reason = self.world:resolveSource(work.destinationAnchor)
            if not destination and reason == "unloaded" then missing = missing or work.destinationAnchor.point
            elseif not destination then return nil, reason end
        end
        if missing then
            local approach, reason = self:retryWalk(work, missing)
            return approach and {approach} or nil, reason, true
        end
        local completed = completeTransfer(self, work, source, destination)
        if completed then op.resultItem = completed; return {}, nil, nil, true end
        local item = source and source:getItemWithID(work.itemId)
        if not item or tostring(item:getFullType()) ~= work.fullType then return nil, "The selected item changed source while the job was stopped" end
        op.item, op.source, op.destination = item, source, destination
        local allowed, failure, admission = self:checkCondense(op)
        if not allowed then return nil, failure, nil, nil, admission end
        if op.personalRecovery then
            local allowed, reason = self.recovery:allows(op)
            if not allowed then return nil, reason end
        else
            local protected, reason = self.world:protected(item, op.hauled and HAULED)
            if protected then return nil, "Protected: " .. tostring(reason or "Item is protected") end
            if not matchesSelection(self.activeGraph, self.plan.request, self.world:describe(item), item, self.player) then return nil, "Item no longer matches the selection" end
        end
        local delta = self.world:carryDelta(item, destination)
        local current, maximum = self.world:carrying()
        if delta > 0 and current + delta > maximum + 0.0001 then return nil, "Native hard carrying limit reached; the item was left in place", nil, nil, "capacity" end
        op.item, op.source, op.destination = item, source, destination
        local steps = {}
        if work.sourcePoint then steps[#steps + 1] = {kind = "approach", location = work.sourcePoint}
        elseif not self.world:owns(source) then steps[#steps + 1] = {kind = "approach", container = source} end
        if work.destinationPoint then
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then return nil, "The native loot window is not available" end
            steps[#steps + 1] = {kind = "approach", location = work.destinationPoint, exact = true}
        elseif not self.world:owns(destination) then steps[#steps + 1] = {kind = "approach", container = destination} end
        steps[#steps + 1] = op
        return steps
    end
    if op.kind == "approach" and work.squarePoint then
        local point = work.squarePoint
        local square = getCell():getGridSquare(point.x, point.y, point.z)
        if not square then
            local approach, reason = self:retryWalk(work, point)
            return approach and {approach} or nil, reason, true
        end
        op.square = square
    end
    if op.kind == "approach" and work.containerAnchor then
        local container, reason = self.world:resolveSource(work.containerAnchor)
        if not container and reason == "unloaded" then
            local approach, failure = self:retryWalk(work, work.containerAnchor.point)
            return approach and {approach} or nil, failure, true
        end
        if not container then return nil, reason end
        op.container = container
    end
    return {op}
end

function Jobs:continueOperation()
    local work = self.operation
    if work.completed then self:finishOperation(work, true); return end
    if self.native:isPlayerBusy() then
        work.retry, work.sourcePrepared, work.walk = true, nil, nil
        self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
        return
    end
    self.view.waiting = nil
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
    if work.retry then
        local steps, reason, again, completed, code = self:prepareOperation(work)
        if not steps then self:finishOperation(work, false, reason, code); return end
        if completed then self:finishOperation(work, true); return end
        work.steps, work.index, work.prepareAgain, work.retry = steps, 1, again, false
    end
    local operation = work.steps[work.index]
    if not operation then
        if work.prepareAgain then work.retry = true; return end
        self:finishOperation(work, true)
        return
    end
    if operation == work.op and operation.kind == "transfer" then
        if work.sourcePoint or work.destinationPoint then
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then self:finishOperation(work, false, "The native loot window is not available"); return end
            loot:refreshBackpacks()
            local floor = ISInventoryPage.GetFloorContainer(self.player:getPlayerNum())
            if work.sourcePoint then operation.source = floor end
            if work.destinationPoint then operation.destination = floor end
        end
        local completed = completeTransfer(self, work, operation.source, operation.destination)
        if completed then operation.resultItem = completed; self:finishOperation(work, true); return end
        local item = operation.source:getItemWithID(work.itemId)
        if not item or tostring(item:getFullType()) ~= work.fullType then self:finishOperation(work, false, "The selected item changed source"); return end
        if work.sourcePoint then
            local world = item:getWorldItem()
            local square = world and world:getSquare()
            if not square or pointKey(coordinates(square)) ~= pointKey(work.sourcePoint) then self:finishOperation(work, false, "Floor item changed from its original location"); return end
        end
        operation.item = item
        local allowed, failure, admission = self:checkCondense(operation)
        if not allowed then self:finishOperation(work, false, failure, admission); return end
        if operation.personalRecovery then
            local allowed, reason = self.recovery:allows(operation)
            if not allowed then self:finishOperation(work, false, reason); return end
        else
            local protected, reason = self.world:protected(item, operation.hauled and HAULED)
            if protected then self:finishOperation(work, false, "Protected: " .. tostring(reason or "Item is protected")); return end
            if not matchesSelection(self.activeGraph, self.plan.request, self.world:describe(item), item, self.player) then self:finishOperation(work, false, "Item no longer matches the selection"); return end
        end
        local delta = self.world:carryDelta(item, operation.destination)
        local current, maximum = self.world:carrying()
        if delta > 0 and current + delta > maximum + 0.0001 then self:finishOperation(work, false, "Native hard carrying limit reached; the item was left in place", "capacity"); return end
        operation.item = item
    end
    if operation == work.op and operation.kind == "trash" then
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
    if operation.personalRecovery then
        local allowed, reason = self.recovery:allows(operation)
        if not allowed then self:finishOperation(work, false, reason); return end
    end
    self:logOp(operation)
    local accepted, reason, code = self.native:begin(operation)
    if not accepted then
        if operation.kind == "approach" and not code then code = "unreachable" end
        self:logOpEnd(operation, code == "busy" and "waiting" or "failed", reason, code)
        if code == "busy" then
            work.retry = true
            self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
        else self:finishOperation(work, false, reason, code, operation) end
        return
    end
    self.pending = {work = work, op = operation}
end

function Jobs:action(op, callback)
    local work = {op = op, callback = callback, steps = {op}, index = 1}
    if op.kind == "transfer" then
        work.itemId, work.fullType = op.item:getID(), tostring(op.item:getFullType())
        if op.source:getType() == "floor" then
            local world = op.item:getWorldItem()
            work.sourcePoint = world and coordinates(world:getSquare())
            op.sourcePoint = work.sourcePoint
        else work.sourceAnchor = self.world:sourceAnchor(op.source) end
        if op.destination:getType() == "floor" then
            work.destinationPoint = op.destinationPoint or coordinates(self.player:getCurrentSquare())
            op.destinationPoint = work.destinationPoint
        else work.destinationAnchor = self.world:sourceAnchor(op.destination) end
    elseif op.kind == "approach" then
        if op.container then work.containerAnchor = self.world:sourceAnchor(op.container)
        elseif op.square then work.squarePoint = coordinates(op.square) end
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

-- callback(source) or callback(nil, reason, code); code is "unreachable" when the way there failed.
function Jobs:recordSource(record, callback)
    if record.groundPoint then
        local function inspect()
        local point = record.groundPoint
        local square = getCell():getGridSquare(point.x, point.y, point.z)
        if not square then callback(nil, "Source floor did not load after walking"); return end
        self:action({ kind = "approach", square = square }, function(ok, err, code)
            if not ok then callback(nil, err, code); return end
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then callback(nil, "The native loot window is not available"); return end
            loot:refreshBackpacks()
            square = getCell():getGridSquare(point.x, point.y, point.z)
            if not square then callback(nil, "Source floor is no longer loaded"); return end
            local floor = ISInventoryPage.GetFloorContainer(self.player:getPlayerNum())
            local item = sourceItem(record, floor)
            local worldItem = item and item:getWorldItem()
            if not worldItem or worldItem:getSquare() ~= square then callback(nil, "Floor item changed location after preview"); return end
            record.groundSquare, record.source = square, floor
            record.item = item
            callback(floor)
        end)
        end
        self:walkLocation(record.groundPoint, function(ok, err, code)
            self.execution.phase = "source"
            if ok then inspect() else callback(nil, err, code) end
        end, nil, true)
    else
        local function inspect()
        local source, problem = self.world:resolveSource(record.sourceAnchor)
        if not source or not sourceItem(record, source) then callback(nil, problem or "Item changed source after preview"); return end
        self:approach(source, function(ok, err, current, code)
            if not ok then callback(nil, err, code); return end
            source = current
            local item = sourceItem(record, source)
            if not item then callback(nil, "Item changed source after preview"); return end
            record.item, record.source = item, source
            callback(source)
        end)
        end
        local source, problem = self.world:resolveSource(record.sourceAnchor)
        if not source and problem == "unloaded" then
            self:walkLocation(record.sourceAnchor.point, function(ok, err, code)
                self.execution.phase = "source"
                if ok then inspect() else callback(nil, err, code) end
            end, nil, true)
        else inspect() end
    end
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
        self:walkLocation(status.point, function(ok, reason)
            execution.phase = "recovery"
            if not ok then self:complete("failed", (reason or "Could not reach the staging container") .. "; personal gear remains reserved for recovery")
            else
                local endpoint, failure = self.recovery:endpoint()
                if not endpoint then self:complete("failed", failure .. "; personal gear remains reserved for recovery"); return end
                self:approach(endpoint, function(arrived, problem)
                    execution.phase = "recovery"
                    if arrived then work.arrived = true
                    else self:complete("failed", (problem or "Could not approach the staging container") .. "; personal gear remains reserved for recovery") end
                end)
            end
        end, nil, true)
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
        plan = plan, finalBin = 1, work = {}, deleted = {}, deferred = {}, capacityRevision = 0 }
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
        if #execution.batch > 0 then self:startDelivery("source")
        elseif not self:retryDeferred() then execution.phase = "finalTrash" end
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

function Jobs:startDelivery(after)
    self.execution.delivery = { index = 1, after = after, prepared = false, failed = {}, full = {}, origin = self.world:point() }
    self.execution.phase, self.execution.roomPass = "delivery", nil
end

-- Where this item would be delivered, counting what is already carried for delivery.
-- Reserves the room only when keep is called.
function Jobs:reserveDelivery(record)
    local execution, request = self.execution, self.plan.request
    if not execution.roomPass then
        local err
        execution.roomPass, err = self.world:destinationPass(request, self.activeGraph)
        if not execution.roomPass then return nil, err end
    end
    local trial = setmetatable({}, {__index = execution.batchRoom})
    local destination, err, code = self:choose(request, record.item, trial, execution.roomPass)
    if not destination then return nil, err, code end
    return function()
        for key, value in pairs(trial) do execution.batchRoom[key] = value end
    end
end

function Jobs:pickup(record)
    local execution, plan = self.execution, self.execution.plan
    if record.settled then self:nextRecord(); self:finishHeavyAttempt(record, false); return end
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
        local reserve, roomProblem, roomCode
        if not direct and kind ~= "trash" and kind ~= "matching" then reserve, roomProblem, roomCode = self:reserveDelivery(record) end
        if not direct and self.world:owns(source) then
            if reserve then reserve() end
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
        if not direct and kind ~= "trash" and kind ~= "matching" and not reserve then
            if roomCode == "capacity" and #execution.batch > 0 then self:startDelivery("source")
            else
                self:skip(record, roomCode == "capacity" and "Destination full" or roomProblem)
                self:nextRecord()
                self:finishHeavyAttempt(record, false)
            end
            return
        end
        local destination, request
        if direct then request = plan.request
        else request = { includeBags = plan.request.includeBags, destination = { kind = "inventory", cargo = self.hauled } } end
        destination, err, code = self:choose(request, record.item)
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
        local hauling = not direct
        if hauling then self.hauled[self.world:itemId(record.item) or record.item] = record end
        record.carryContainer = hauling and destination or nil
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination}
        self:action(operation, function(moved, failure, failureCode)
            if moved then
                record.item = operation.resultItem
                if hauling then
                    if reserve then reserve() end
                    record.carryContainer = operation.destination
                    record.hauled = true
                    execution.batch[#execution.batch + 1] = record
                    self.view.carried = self.view.carried + 1
                else
                    record.settled = true
                    self:recordMove(record)
                end
            elseif failureCode == "capacity" and hauling then
                if #execution.batch > 0 then self:startDelivery("source"); return end
                if self:onCapacityBlocked(record, failure or "Native pickup refused") then return end
            else self:skip(record, failure or "Native pickup refused") end
            self:nextRecord()
            self:finishHeavyAttempt(record, moved)
        end)
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

function Jobs:place(record, destination)
    local point
    if destination:getType() == "floor" then
        if self.plan.request.destination.kind == "matching" then
            point = self.world:matchingPoint(self.plan.request, destination)
            if not point then self:nextDelivery(record, false, "The original matching floor destination is unavailable"); return end
        elseif self.plan.request.destination.ref then point = coordinates(self.plan.request.destination.ref) end
    end
    local function transfer(ok, err, current)
        if not ok then self:nextDelivery(record, false, err); return end
        destination = current or destination
        if destination:getType() == "floor" then
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then self:nextDelivery(record, false, "The native loot window is not available"); return end
            loot:refreshBackpacks()
            destination = ISInventoryPage.GetFloorContainer(self.player:getPlayerNum())
        end
        local matches, reason = self:matches(record, self.plan)
        if not matches then self:nextDelivery(record, false, reason); return end
        local source = record.item:getContainer()
        if not self.world:owns(source) or not source:contains(record.item) then
            self:nextDelivery(record, false, "Hauled item is no longer carried"); return end
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination,
            trashTarget = record.trashTarget, hauled = record.hauled}
        if point then operation.destinationPoint = point end
        self:action(operation, function(moved, failure, code)
            if moved then record.item = operation.resultItem end
            if not moved and code == "capacity" and record.hauled and not record.trashTarget then self:holdDelivery(record, failure); return end
            self:nextDelivery(record, moved, failure, operation.destination)
        end)
    end
    if point then
        self:walkLocation(point, function(loaded, reason)
            self.execution.phase = "delivery"
            if not loaded then self:nextDelivery(record, false, reason); return end
            self:action({kind = "approach", location = point, exact = true}, function(ok, err) transfer(ok, err) end)
        end, nil, true)
    else self:approach(destination, transfer) end
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
        -- Finding labelled storage reads the surroundings, so one delivery looks once.
        if kind == "labels" then delivery.pass = self.world:destinationPass(self.plan.request, self.activeGraph) end
        if kind == "vehicle" then
            self:action({kind = "vehicle", vehicle = self.plan.request.destination.ref or self.world:vehicle()}, function(ok, err)
                if not ok then delivery.failure = err or "Vehicle access failed" end
            end)
            return
        end
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
    local ok, err = self:matches(record, self.plan)
    if not ok or delivery.failure then self:nextDelivery(record, false, delivery.failure or err); return end
    local source = record.item:getContainer()
    if not source or not self.world:owns(source) or not source:contains(record.item) then self:nextDelivery(record, false, "Hauled item is no longer carried"); return end
    -- Carried in a bag that is labelled for it.
    if self.world:alreadySorted(self.plan.request, record.item, self.activeGraph) then self:nextDelivery(record, true, nil, source); return end
    if self.plan.request.destination.kind == "trash" then self:trashDestination(record)
    else
        local destination, code
        destination, err, code = self:choose(self.plan.request, record.item, nil, delivery.pass)
        if not destination and delivery.pass then
            destination, err, code = self:choose(self.plan.request, record.item)
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

function Jobs:discoverSource(source, anchor, alreadyCounted)
    local function inspect()
    local current, failure = self.world:resolveSource(anchor)
    if not current then self:skip({itemName = self.world:name(source)}, failure); self.execution.phase = "source"; return end
    source = current
    self:approach(source, function(ok, err, current)
        if not ok then self:skip({itemName = self.world:name(source)}, err); self.execution.phase = "source"; return end
        source = current
        local opened, problem = self:explore(source)
        if not opened then self:skip({itemName = self.world:name(source)}, problem); self.execution.phase = "source"; return end
        local records = self.world:records(source, self.plan.request.includeBags)
        if isClient() then
            local reason = "Native multiplayer synchronization is unconfirmed; only observed items from this source can be moved"
            if not alreadyCounted then
                self.view.unconfirmedSources = self.view.unconfirmedSources + 1
                table.insert(self.view.reasons, {itemName = self.world:name(source), status = "Unconfirmed", tone = "warning", reason = reason})
            end
            self.view.reason = reason
        end
        if isClient() and #records == 0 then
            self.execution.discovery = {source = source, anchor = anchor, deadline = now() + REPLY_MS}
            self.execution.phase = "discoveryWait"
        else self:addObserved(records) end
    end)
    end
    local current, reason = self.world:resolveSource(anchor)
    if not current and reason == "unloaded" then
        self:walkLocation(anchor.point, function(ok, err)
            self.execution.phase = "source"
            if ok then inspect() else self:skip({itemName = self.world:name(source)}, err) end
        end, nil, true)
    else inspect() end
end

function Jobs:sourceStep()
    local execution = self.execution
    local record = execution.records[execution.recordIndex]
    while record and not record.settled and execution.failedSources[record.workSource] do
        self:skipUnreachable(record, execution.failedSources[record.workSource].reason)
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
        elseif not self:retryDeferred() then execution.phase = "finalTrash" end
    elseif task.kind == "records" then execution.records, execution.recordIndex = task.records, 1
    else self:discoverSource(task.container, task.anchor) end
end

function Jobs:carriedCount()
    local count = 0
    for _, record in pairs(self.hauled or {}) do
        if not record.delivered then
            local item = record.carryContainer and sourceItem(record, record.carryContainer)
            if item and self.world:owns(record.carryContainer) then record.item = item; count = count + 1 end
        end
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
            reason = (reason or "Condense stopped") .. "; " .. self.view.condense.buffered .. " items put aside for a moment are still in your inventory."
        end
    end
    if state == "failed" and self.execution and self.execution.recoveryOnly then
        self.suspended = self.execution.resumeSaved
    end
    self.view.carried = self:carriedCount()
    if not reason and (state == "finished" or state == "finished_with_skips") then
        reason = state == "finished" and "Finished the selected job."
            or "Finished with notes. Review the exclusions and unconfirmed sources below."
    end
    self.view.state, self.view.reason = state, reason or self.view.reason
    if self.view.carried > 0 then self.view.reason = (self.view.reason and self.view.reason .. "; " or "") .. self.view.carried .. " hauled items remain in carried storage" end
    if self.operation and self.operation.completed and self.operation.op.kind == "trash" then self:settleTrash(self.operation) end
    if state == "paused" and self.execution then
        self.suspended = {execution = self.execution, operation = self.operation, graph = self.activeGraph, binReview = self.binReview,
            stoppedAt = now(), interaction = self.interaction, startedAt = self.startedAt, opCount = self.opCount}
        if completion and not recoveryOnly then completion.pausedAt = self.suspended.stoppedAt end
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
        Completion.job(self.player, plan, self.view, completion, now())
    end
end

function Jobs:advance()
    if self.pending then
        local done, reason, code = self.native:poll()
        if done == nil then return end
        local pending = self.pending
        self.pending = nil
        self:logOpEnd(pending.op, done and "ok" or (code == "yielded" or code == "busy") and "yielded" or "failed", reason, code)
        if done == false and (code == "yielded" or code == "busy") then
            pending.work.retry, pending.work.sourcePrepared, pending.work.walk = true, nil, nil
            self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
        elseif not done then self:finishOperation(pending.work, false, reason, code, pending.op)
        elseif pending.op == pending.work.op then self:finishOperation(pending.work, true)
        else pending.work.index = pending.work.index + 1 end
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
            self:skip({itemName = self.world:name(discovery.source)}, "No items observed after the native request; the source is unconfirmed, not certified empty")
            execution.phase = "source"
        end
    elseif execution.phase == "finalTrash" then
        local target = self.plan.bins[execution.finalBin]
        execution.finalBin = execution.finalBin + 1
        if not target and #execution.unlocked > 0 then self:relockStep()
        elseif not target then
            local unsearched = self.view.survey and self.view.survey.sectionsUnsearched or 0
            self:complete((self.view.skipped > 0 or self.view.unconfirmedSources > 0 or unsearched > 0) and "finished_with_skips" or "finished")
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
        execution.draining = true
        local ok, problem = pcall(self.native.cancel, self.native, op)
        if not ok then Log.fault(self.interaction, "Native.cancel", problem) end
    end
end

function Jobs:extendDeadlines(milliseconds)
    self.native:extend(milliseconds)
    local execution = self.execution
    for _, state in pairs(execution and {execution.binInspection or false, execution.discovery or false, execution.section or false} or {}) do
        if state and state.deadline then state.deadline = state.deadline + milliseconds end
    end
end

function Jobs:tick()
    local stamp = now()
    -- The game runs no ticks while it is paused, but every deadline is wall clock.
    if self.lastTick and stamp - self.lastTick > 1000 then self:extendDeadlines(stamp - self.lastTick) end
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
        if self.execution.draining then
            local ok, result = pcall(self.native.poll, self.native)
            if not ok then Log.fault(self.interaction, "Native.poll:drain", result); return end
            if result == nil then return end
            self.execution.draining = nil
        end
        if not self.native:isBusy() and self.native:isPlayerBusy() then
            if self.operation and not self.operation.completed then
                self.operation.retry, self.operation.sourcePrepared, self.operation.walk = true, nil, nil
            end
            if not self.view.waiting and Log.detailed then
                Log.trace(self.interaction, "WAIT", "for", "player action", "queue", Log.queue(self.player))
            end
            self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
            return
        end
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
    self.startedAt, self.opCount, self.lastTick = saved.startedAt, saved.opCount, now()
    self:bindInteraction(saved, "resume")
    self.suspended, self.view.state, self.view.reason = nil, "running", "Continuing the stopped job with current item and destination checks."
    self.execution.faults, self.execution.failedSources = 0, {}
    Log.info(self.interaction, "RESUME", "phase", self.execution.phase, "after", now() - saved.stoppedAt, "player", Log.player(self.player))
    if self.execution.condense then self.execution.condense:onResume() end
    if self.operation and not self.operation.completed then
        self.operation.retry, self.operation.sourcePrepared, self.operation.walk = true, nil, nil
    end
    local stamp = now()
    local elapsed = stamp - saved.stoppedAt
    if self.completion and not self.execution.recoveryOnly and self.completion.pausedAt then
        self.completion.startedAt = self.completion.startedAt + math.max(0, stamp - self.completion.pausedAt)
        self.completion.pausedAt = nil
    end
    for _, state in pairs({self.execution.binInspection, self.execution.discovery, self.execution.section}) do
        if state and state.deadline then state.deadline = state.deadline + elapsed end
    end
    if saved.binReview then self:inspectBin(saved.binReview.target, saved.binReview.after)
    elseif not self.operation and self.execution.binInspection then
        local pending = self.execution.binInspection
        self.execution.binInspection = nil
        self:inspectBin(pending.target, pending.after)
    elseif not self.operation and self.execution.phase == "discoveryWait" then
        local pending = self.execution.discovery
        self.execution.discovery = nil
        self:discoverSource(pending.source, pending.anchor, true)
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
