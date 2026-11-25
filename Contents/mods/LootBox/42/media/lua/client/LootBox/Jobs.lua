local Native = require "LootBox/Native"
local Categories = require "LootBox/Categories"
local Routing = require "LootBox/Routing"
local Carry = require "LootBox/Carry"
local Condense = require "LootBox/Condense"
local Completion = require "LootBox/CompletionFeedback"
local Log = require "LootBox/Log"
local Sort = require "LootBox/Sort"
local call = require "LootBox/Safe"
local Facts = require "LootBox/Facts"
local Jobs = {}
Jobs.__index = Jobs

-- How long a searched multiplayer container may stay empty before it counts as
-- unconfirmed. The game never acknowledges an empty reply.
local REPLY_MS = 1000
local HAULED, MAX_PREVIEWS, MAX_FAULTS, MAX_LOGGED = {hauled = true}, 4, 3, 12
-- Emptying a can costs about as long as walking three tiles, so a bigger can is worth only a small detour.
local EMPTY_SECONDS, MAX_NAMES = 2, 6

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

local function whole(self, request, graph, container)
    for _, entry in ipairs(self.world:records(container, true)) do
        if self.world:protected(entry.item) or not matchesSelection(graph, request, entry.descriptor, entry.item, self.player) then return false end
    end
    return true
end

-- Why a filled bag in the world cannot move whole. Contents that are moved one
-- by one, or deleted with the bag, must all belong to the selection.
local function bagReason(self, request, graph, record)
    local inside = not self.world:owns(record.source) and self.world:filledBag(record.item)
    if not inside or not request.includeBags and (request.destination.kind ~= "trash" or request.filter.all) then return nil end
    return not whole(self, request, graph, inside) and "Bag holds items outside this selection" or nil
end

local function tooHeavy(bins, item)
    local biggest = 0
    for _, target in ipairs(bins) do biggest = math.max(biggest, target.capacity) end
    return #bins > 0 and weight(item) > biggest and "Too heavy for any trash can (the biggest known holds " .. biggest .. ")" or nil
end

local function findBin(bins, key)
    for _, target in ipairs(bins) do if target.key == key then return target end end
end

local function usableBins(self, request, noLook)
    local bins, reason = self.world:bins(request, noLook)
    for _, target in ipairs(bins or {}) do target.approved = {} end
    return bins, reason
end

local function withContents(self, item, name)
    local inside = self.world:filledBag(item)
    name = tostring(name or item:getName())
    return inside and name .. " (with " .. inside:getItems():size() .. " items inside)" or name
end

-- The first protected item in a can, which keeps it from being emptied.
local function protectedIn(self, bin)
    local contents = bin:getItems()
    for index = 0, contents:size() - 1 do
        local item = contents:get(index)
        local protected, why = self.world:protected(item)
        if protected then return tostring(item:getName()) .. " (" .. tostring(why or "protected") .. ")" end
    end
end

-- Says how far the nearest can is and what goes with it, or why none can be used.
local function nearestBin(self, bins)
    local blocked
    for _, target in ipairs(bins) do
        local bin = self.world:resolveBin(target)
        local opened = bin and bin:isExplored()
        local holds = opened and protectedIn(self, bin)
        if holds then blocked = blocked or "The nearest trash can holds " .. holds .. ", so it is left alone"
        else
            local text, count = "Nearest trash can: " .. Facts.awayText(target.away), opened and bin:getItems():size() or 0
            if count > 0 then
                local names = {}
                for index = 0, math.min(count, MAX_NAMES) - 1 do names[#names + 1] = withContents(self, bin:getItems():get(index)) end
                text = text .. ". Emptying it also deletes what is in it: " .. table.concat(names, ", ")
                    .. (count > MAX_NAMES and " and " .. (count - MAX_NAMES) .. " more" or "")
            end
            return blocked and blocked .. ". " .. text or text
        end
    end
    return nil, blocked
end

-- Rubbish already in a can stays there. The can is emptied at the end when all it holds was selected.
local function binFinder(self, request, graph, find)
    local found = {}
    return function(container)
        if request.destination.kind ~= "trash" then return nil end
        if found[container] ~= nil then return found[container] or nil end
        local key = self.world:binKey(container)
        local target = key and find(key)
        found[container] = target or false
        if target and target.selected == nil then
            local bin = self.world:resolveBin(target)
            if bin and bin:isExplored() then target.selected = not bin:isEmpty() and whole(self, request, graph, bin)
            else target.selected = bin ~= nil and request.filter.all == true end
            target.touched = target.touched or target.selected
        end
        return target
    end
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
    for index, target in ipairs(reviewed.bins) do
        if index > MAX_LOGGED then Log.trace(interaction, "PLAN-CAN", "more", #reviewed.bins - MAX_LOGGED); break end
        Log.trace(interaction, "PLAN-CAN", "at", target.key, "away", target.away, "holds", target.capacity, "emptied", target.touched == true)
    end
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
        moves = {}, skipped = {}, warnings = {}, records = {}, sources = scan.sources or {}, unknownSources = {} }
    plan.request.destination.targets = nil
    local bins, notes, destinations, seenDestinations = {}, Log.detailed and {} or nil, {}, {}
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
        if not self.world:deletionAllowed() then return nil, "This server does not let players empty trash cans" end
        -- A can in the place being cleaned may not have been noticed before.
        for _, source in ipairs(plan.sources) do self.world:binKey(source) end
        bins, err = usableBins(self, request)
        if not bins then return nil, err end
        local notice, problem = nearestBin(self, bins)
        if problem then return nil, problem end
        table.insert(plan.warnings, notice)
    end
    local canOf = binFinder(self, request, self.graph, function(key) return findBin(bins, key) end)
    local reservations, pass = {}, nil
    if request.destination.kind ~= "trash" then
        pass, err = self.world:destinationPass(request, self.graph)
    end
    local passError = err
    for _, record in ipairs(bagsLast(self, request, scan.items or {})) do
        local item = record.item
        local can = canOf(record.source)
        if (not can or can.selected) and matchesSelection(self.graph, request, record.descriptor, record.item, self.player) then
            local protected, protection = self.world:protected(item)
            local reason, status
            if protected then reason, status = protection or "Protected item", "Protected"
            elseif request.destination.kind == "inventory" and self.world:owns(record.source) then reason, status = "Already in carried storage", "Already carried"
            elseif self.world:alreadySorted(request, item, self.graph) then reason, status = "Already sorted", "Already sorted"
            else
                reason = bagReason(self, request, self.graph, record)
                if reason then status = "Protected"
                elseif request.destination.kind == "trash" and not can and not record.emptied then reason = tooHeavy(bins, item) end
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
                record.bin = can and can.key
                table.insert(plan.moves, row)
                table.insert(plan.records, record)
            end
        end
    end
    if preparesBags then table.insert(plan.warnings, "Useful bags will be prepared first. Items waiting for that space are checked again during the job; native capacity can still leave an item in place.") end
    local unknown = 0
    for _, source in ipairs(plan.sources) do
        if not source:isExplored() then
            local can = canOf(source)
            if not can then plan.unknownSources[#plan.unknownSources + 1] = source end
            if not can or can.selected then unknown = unknown + 1 end
        end
    end
    if unknown > 0 then
        table.insert(plan.warnings, unknown .. " unopened containers will be approached and searched normally; matching newly revealed contents may be added to this job.")
        if isClient() then
            table.insert(plan.warnings, "Native multiplayer does not acknowledge empty container replies to Lua. Newly searched sources stay unconfirmed; this job cannot certify that the whole scope is clear.")
        end
    end
    plan.pending = unknown
    if scan.survey then
        local status = scan.survey:status()
        local left = status.roomsTotal - status.roomsDone
        if scan.survey.building then plan.building = {roomsTotal = left} end
        plan.pending = plan.pending + left
    end
    table.insert(plan.warnings, "Live capacity, access, and item changes are checked again before each native action.")
    local records = {}
    for _, record in ipairs(plan.records) do records[#records + 1] = self:captureRecord(record) end
    remember(self, plan, { request = cloneRequest(request), records = records,
        sources = copyList(plan.sources), unknownSources = copyList(plan.unknownSources),
        bins = bins, survey = scan.survey,
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
        local info = reviewed.condense:status()
        self.view = {state = "running", done = 0, moved = 0, cleared = 0, total = info.eligible or 0,
            skipped = 0, reasons = {}, carried = 0, unconfirmedSources = 0, condense = info,
            reason = "Planning carried-item condensation."}
        self.execution = {phase = "condense", condense = reviewed.condense, batch = {}, reviewBins = false, unlocked = {}}
        return true
    end
    self.view = { state = "running", done = 0, moved = 0, cleared = 0, deferred = 0, total = #reviewed.records, skipped = #reviewed.skipped,
        reasons = copyList(reviewed.skipped), carried = 0, unconfirmedSources = 0 }
    self.execution = self:createExecution(reviewed)
    self.execution.reviewBins = not (options and options.reviewBins == false)
    self.carry = Carry.new(self.player, self.world)
    self.execution.afterCarry, self.execution.phase = "source", "carry"
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

function Jobs:checkCondense(op)
    if not op.condense then return true end
    local controller = self.execution and self.execution.condense
    if not controller then return nil, "The Condense arrangement is no longer active" end
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
    if ok and work.op.kind == "trash" then self:settleTrash(work.op) end
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
        local bin, problem = self.world:resolveBin(operation.target)
        local ask
        if bin then problem, ask = self:binProblem(operation.target, bin) end
        if problem then self:finishOperation(work, false, problem, ask and "ask" or nil); return end
        operation.container = bin
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
end

-- The item, or a bag it lies in, is one of these.
function Jobs:within(record, ids)
    local item, seen = record.item, {}
    while item and not seen[item] do
        seen[item] = true
        if ids[self.world:itemId(item)] then return true end
        item = call(call(item, "getContainer"), "getContainingItem")
    end
    return false
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
    local records, rubbish = {}, {}
    if self.plan.request.destination.kind == "trash" then
        for _, byId in pairs(execution.work) do for id, byType in pairs(byId) do for _, record in pairs(byType) do
            if not record.settled then rubbish[id] = true end
        end end end
    end
    for _, record in ipairs(self.world:gearRecords(sources)) do
        -- A bag being hauled is cargo; equipping it would keep it from its destination.
        local hauled = self.hauled[self.world:itemId(record.item) or record.item]
        if (not hauled or hauled.delivered) and not self:within(record, rubbish) then records[#records + 1] = record end
    end
    local incoming = 0
    for _, byId in pairs(execution.work) do for _, byType in pairs(byId) do for _, record in pairs(byType) do
        if not record.settled and not record.bin and not self.world:owns(record.item:getContainer())
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
    local status = self.recovery:status()
    if not status.pending and not execution.recoveryOnly then
        execution.recovery, execution.phase = nil, work and work.after or "source"
        return
    end
    -- Gear that never left the player costs only the heavy item. Gear already put down must be fetched.
    local function fail(reason)
        if work.mode ~= "stage" then self:complete("failed", reason .. ". Your gear stays reserved; choose Fetch my gear."); return end
        local record = execution.heavyRecord
        execution.heavyRecord = nil
        self:skip(record, "Your gear could not be put down nearby to lift this: " .. reason)
        self:nextRecord()
        if self.recovery:status().blocking then self:beginRecovery("restore", "source")
        else self.recovery:forget(); execution.recovery = nil end
    end
    if not work.arrived then
        if not status.point then fail(status.reason or "The place is not known"); return end
        self:walkLocation(status.point, function(ok, reason)
            execution.phase = "recovery"
            if not ok then fail(reason or "Could not reach the container"); return end
            local endpoint, failure = self.recovery:endpoint()
            if not endpoint then fail(failure); return end
            self:approach(endpoint, function(arrived, problem)
                execution.phase = "recovery"
                if arrived then work.arrived = true else fail(problem or "Could not get to the container") end
            end)
        end, nil, true)
        return
    end
    local op, reason, done = self.recovery:next(work.mode)
    if op then
        self.view.reason = work.mode == "stage" and "Storing whole personal items for one heavy-item trip."
            or "Recovering personal items and their original equipment slots."
        self:action(op, function(ok, failure)
            local settled, err = self.recovery:settle(op, ok, failure)
            if not settled then fail(err or "Moving your gear stopped")
            else self:capacityChanged(); execution.phase = "recovery" end
        end)
    elseif not done then fail(reason or "Moving your gear stopped")
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
        batch = {}, seen = {}, seenSources = {}, failedSources = {}, batchRoom = {}, unlocked = {},
        plan = plan, work = {}, deferred = {}, capacityRevision = 0 }
    local groups, order = {}, {}
    for _, entry in ipairs(plan.records) do
        local record = self:captureRecord(entry)
        self:registerWork(execution, record)
        execution.seen[self.world:itemId(record.item) or record.item] = true
        if not record.bin then
            local key = plan.request.destination.kind == "matching" and self.player:getInventory() or sourceGroup(record)
            if not groups[key] then groups[key] = {}; order[#order + 1] = key end
            groups[key][#groups[key] + 1] = record
        end
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
    for _, record in ipairs(self:newRecords(scan.items)) do
        local key = sourceGroup(record)
        if not groups[key] then groups[key] = {}; order[#order + 1] = key end
        groups[key][#groups[key] + 1] = record
    end
    for _, key in ipairs(order) do addRecordTask(execution, groups[key]) end
    local canOf = self:binFinder()
    for _, source in ipairs(scan.sources) do
        local key = self.world:key(source) or source
        if not source:isExplored() and not execution.seenSources[key] then
            execution.seenSources[key] = true
            if not canOf(source) then addDiscoverTask(self, execution, source) end
        end
    end
    for _, warning in ipairs(scan.warnings) do self:skip({itemName = "Building source"}, warning) end
    execution.afterCarry, execution.phase = "source", "carry"
end

function Jobs:acceptSection(section, scan, missing, denied, reason)
    local survey = self.plan.survey
    local ok = missing == 0 and denied == 0 and reason == nil
    reason = reason or (missing > 0 and (tostring(missing) .. " tiles could not be seen or no longer belong here"))
        or (denied > 0 and "A safehouse you may not use covers part of it") or nil
    survey:report(section, ok, reason)
    if not ok then self:skip({itemName = section.roomName .. " / floor " .. tostring(section.z)}, reason) end
    self.view.survey = survey:status()
    self.execution.section = nil
    self:sectionTasks(scan)
end

function Jobs:surveyStep()
    local survey, execution = self.plan.survey, self.execution
    local section = survey:next(self.world:point())
    self.view.survey = survey:status()
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

function Jobs:binFinder()
    return binFinder(self, self.plan.request, self.activeGraph, function(key)
        self:refreshBins(true)
        return findBin(self.plan.bins, key)
    end)
end

-- Registers newly seen selected items and returns the ones to carry.
function Jobs:newRecords(entries)
    local execution, result, canOf = self.execution, {}, self:binFinder()
    for _, entry in ipairs(bagsLast(self, self.plan.request, entries)) do
        local id = self.world:itemId(entry.item) or entry.item
        local can = canOf(entry.source)
        if not execution.seen[id] and (not can or can.selected)
            and matchesSelection(self.activeGraph, self.plan.request, entry.descriptor, entry.item, self.player) then
            execution.seen[id] = true
            if not (self.plan.request.destination.kind == "inventory" and self.world:owns(entry.source)) then
                local record = self:captureRecord(entry)
                record.bin = can and can.key
                self:registerWork(execution, record)
                if not can then result[#result + 1] = record end
                self.view.total = self.view.total + 1
            end
        end
    end
    return result
end

function Jobs:addObserved(entries)
    local execution = self.execution
    execution.records, execution.recordIndex, execution.phase = self:newRecords(entries), 1, "carry"
    execution.afterCarry = "source"
end

function Jobs:nextRecord()
    self.execution.recordIndex = self.execution.recordIndex + 1
    self.execution.phase = "source"
end

function Jobs:finishHeavyAttempt(record, moved)
    if self.execution.heavyRecord ~= record then return end
    self.execution.heavyRecord = nil
    self:beginRecovery("restore", "source")
    if moved then self:startDelivery("recovery") end
end

function Jobs:startDelivery(after)
    self.execution.delivery = { index = 1, after = after, prepared = false, full = {} }
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
            if plan.request.destination.kind == "trash" then self:refreshBins(true) end
            err = bagReason(self, plan.request, self.activeGraph, record)
                or plan.request.destination.kind == "trash" and tooHeavy(plan.bins, record.item) or nil
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
        local target = kind == "trash" and not record.notDirect and self:binInReach(record)
        if target then
            local bin = self:readyBin(target)
            if bin then
                self:throwAway(record, target, bin, source, function(moved, failure)
                    if moved then record.settled = true; self:recordMove(record); self:nextRecord(); self:finishHeavyAttempt(record, false)
                    else
                        record.notDirect = true
                        Log.trace(self.interaction, "CARRY-INSTEAD", "item", Log.item(record.item, self.player), "reason", failure)
                    end
                end)
            end
            return
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
    delivery.index, delivery.why = delivery.index + 1, reason
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
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination, hauled = record.hauled}
        if point then operation.destinationPoint = point end
        self:action(operation, function(moved, failure, code)
            if moved then record.item = operation.resultItem end
            if not moved and code == "capacity" and record.hauled then self:holdDelivery(record, failure); return end
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

-- Trash -----------------------------------------------------------------------
-- target is one can: {key, point, capacity, approved, touched, refused, selected}. touched means it holds something
-- this job must delete, refused why it is out of use until Resume.

-- Cans found since join in, and cans that are gone or out of range drop out.
function Jobs:refreshBins(ifChanged)
    if ifChanged and self.plan.binRevision == self.world.binRevision then return end
    self.plan.binRevision = self.world.binRevision
    local bins, reason = usableBins(self, self.plan.request, true)
    local result = {}
    for _, target in ipairs(bins or {}) do
        local known = findBin(self.plan.bins, target.key) or target
        known.capacity, result[#result + 1] = target.capacity, known
    end
    for _, target in ipairs(self.plan.bins) do
        if target.touched and not findBin(result, target.key) then result[#result + 1] = target end
    end
    self.plan.bins, self.plan.noBins = result, reason
end

function Jobs:refuseBin(target, reason)
    target.refused = tostring(reason or "The trash can cannot be used")
    Log.info(self.interaction, "CAN-REFUSED", "at", target.key, "reason", target.refused, "touched", target.touched == true,
        "player", Log.point(self.world:point()))
end

-- Why this can may not be emptied. ask means the player can settle it by approving what it holds.
function Jobs:binProblem(target, bin)
    local holds = protectedIn(self, bin)
    if holds then return "It holds " .. holds end
    local contents, fresh = bin:getItems(), {}
    for index = 0, contents:size() - 1 do
        local id = self.world:itemId(contents:get(index))
        if not target.approved[id] then fresh[#fresh + 1] = id end
    end
    if #fresh == 0 then return nil end
    if self.execution.reviewBins then return "It holds items you have not approved", true end
    for _, id in ipairs(fresh) do target.approved[id] = true end
    Log.trace(self.interaction, "CAN-APPROVED", "at", target.key, "items", #fresh, "why", "asking is off", "bin", Log.container(bin, self.player))
end

-- The can, once the player stands at it, it has been opened and its contents may go. Otherwise takes the
-- next step towards that; the phase that asked is run again afterwards.
function Jobs:readyBin(target)
    local execution, phase = self.execution, self.execution.phase
    local bin, reason = self.world:resolveBin(target)
    if not bin and reason ~= "unloaded" then self:refuseBin(target, reason); return nil end
    if not bin or not self.native:reachable(bin) then
        target.tries = (target.tries or 0) + 1
        if target.tries > 3 then self:refuseBin(target, "Could not get close enough to the trash can"); return nil end
        self.view.reason = "Walking to a trash can"
        local function arrived(ok, err)
            execution.phase = phase
            if not ok then self:refuseBin(target, err) end
        end
        if bin then self:approach(bin, arrived) else self:walkLocation(target.point, arrived, nil, true) end
        return nil
    end
    target.tries = 0
    if not bin:isExplored() then
        local opened, problem = self:explore(bin)
        if not opened then self:refuseBin(target, problem); return nil end
        if isClient() then
            execution.binWait, execution.phase = {phase = phase, deadline = now() + REPLY_MS}, "binWait"
            self.view.reason = "Looking into the trash can"
            return nil
        end
    end
    local problem, ask = self:binProblem(target, bin)
    if not problem then return bin end
    if not ask then self:refuseBin(target, problem); return nil end
    self.reviewGeneration = (self.reviewGeneration or 0) + 1
    self.binReview = {target = target, phase = phase}
    execution.phase, self.view.state, self.view.reviewId = "binReview", "needs_review", self.reviewGeneration
    self.view.reason = "This trash can already holds something. Check it to continue."
    Log.info(self.interaction, "CAN-REVIEW", "bin", Log.container(bin, self.player), "reason", problem, "during", phase)
end

function Jobs:reviewBin()
    local pending = self.binReview
    if not pending or self.ending then return nil, "This job is not waiting for a bin review" end
    local bin, reason = self.world:resolveBin(pending.target)
    if not bin or not self.native:reachable(bin) then return nil, reason or "Walk back to the trash can first" end
    local review = {moves = {}, skipped = {}, warnings = {}, pending = 0, canApprove = true,
        bin = {name = self.world:name(bin), point = pending.target.point,
            capacity = bin:getEffectiveCapacity(self.player), used = bin:getCapacityWeight()}}
    local approved, contents = {}, bin:getItems()
    for index = 0, contents:size() - 1 do
        local item = contents:get(index)
        local protected, why = self.world:protected(item)
        if protected then
            review.canApprove = false
            review.skipped[#review.skipped + 1] = {itemName = item:getName(), status = "Protected", tone = "warning",
                reason = tostring(why or "Item is protected") .. ", so this can is not emptied"}
        else review.moves[#review.moves + 1] = {itemName = withContents(self, item), status = "Delete", tone = "danger",
            from = "Already in the can", to = "Deleted"} end
        approved[self.world:itemId(item)] = true
    end
    if isClient() then review.warnings[1] = "Other players can change this can. Everything in it when it is emptied is deleted." end
    pending.token, pending.approved = review, approved
    return review
end

function Jobs:approveBin(review, options)
    local pending = self.binReview
    if not pending or not review or not pending.token or pending.token ~= review or self.ending then return nil, "Review this bin again before continuing" end
    local target, bin = pending.target, self.world:resolveBin(pending.target)
    if not bin or not self.native:reachable(bin) then return nil, "Walk back to the trash can first" end
    local problem = self:binProblem({key = target.key, approved = pending.approved}, bin)
    if problem then return nil, problem end
    for id in pairs(pending.approved) do target.approved[id] = true end
    if options and options.reviewBins == false then self.execution.reviewBins = false end
    Log.info(self.interaction, "CAN-REVIEWED", "at", target.key, "answer", "empty", "askAgain", self.execution.reviewBins)
    self.binReview, self.view.state, self.execution.phase = nil, "running", pending.phase
    return true
end

function Jobs:rejectBin(review)
    local pending = self.binReview
    if not pending or not review or not pending.token or pending.token ~= review or self.ending then return nil, "This bin review is no longer active" end
    self:refuseBin(pending.target, "You chose not to use it")
    self.binReview, self.view.state, self.execution.phase = nil, "running", pending.phase
    return true
end

-- The nearest can that takes this item, preferring one that takes everything carried. Without one, why not,
-- and whether a refused can would have done.
function Jobs:pickBin(record)
    local execution, delivery, here, load = self.execution, self.execution.delivery, self.world:point(), 0
    for index = delivery.index, #execution.batch do load = load + weight(execution.batch[index].item) end
    local best, bestCost, why, refused
    for _, target in ipairs(self.plan.bins) do
        local bin, reason = self.world:resolveBin(target)
        if not bin and reason ~= "unloaded" then target.refused = target.refused or reason
        elseif bin and not target.refused then
            local holds = bin:isExplored() and protectedIn(self, bin)
            if holds then self:refuseBin(target, "It holds " .. holds) end
        end
        if weight(record.item) <= target.capacity and (not bin or bin:isItemAllowed(record.item)) then
            if target.refused then refused, why = true, why or target.refused
            else
                local emptyings = math.max(0, math.ceil(load / target.capacity) - 1)
                local cost = self.routing:estimate(here, target.point) + emptyings * EMPTY_SECONDS
                if not best or cost < bestCost then best, bestCost = target, cost end
            end
        end
    end
    if best then
        Log.trace(self.interaction, "CAN-CHOSEN", "at", best.key, "holds", best.capacity, "load", load, "seconds", bestCost, "from", Log.point(here))
    end
    return best, why or self.plan.noBins or tooHeavy(self.plan.bins, record.item) or "No trash can takes this item", refused or self.plan.noBins ~= nil
end

function Jobs:binInReach(record)
    for _, target in ipairs(self.plan.bins) do
        local bin = not target.refused and weight(record.item) <= target.capacity and self.world:resolveBin(target)
        if bin and self.native:reachable(bin) and bin:isItemAllowed(record.item) then return target end
    end
end

function Jobs:empty(target, bin)
    self.view.reason = "Emptying the trash can"
    self:action({kind = "trash", container = bin, target = target, approved = target.approved}, function(ok, reason, code)
        -- Out of reach is walked back to, and unapproved contents are asked about, when the phase runs again.
        if not ok and code ~= "ask" and self.native:reachable(bin) then self:refuseBin(target, reason) end
    end)
end

function Jobs:settleTrash(op)
    op.target.touched = nil
    for _, byId in pairs(self.execution.work) do for _, byType in pairs(byId) do for _, record in pairs(byType) do
        if record.bin == op.target.key and not record.settled then
            record.settled = true
            self.view.done, self.view.cleared = self.view.done + 1, self.view.cleared + 1
        end
    end end end
end

-- Empties a can that holds this job's rubbish. True while that needs another step.
function Jobs:emptyCan(target)
    if not target.touched or target.refused then return false end
    local bin = self:readyBin(target)
    if bin and bin:isEmpty() then self:settleTrash({target = target}); return false end
    if bin then self:empty(target, bin) end
    return true
end

-- Puts one item into a can at hand, emptying a full one first. done(false, reason) when the can will not take it.
function Jobs:throwAway(record, target, bin, source, done)
    if not bin:hasRoomFor(self.player, record.item) then
        if bin:isEmpty() then done(false, "It does not fit into an empty trash can") else self:empty(target, bin) end
        return
    end
    local operation = {kind = "transfer", item = record.item, source = source, destination = bin, hauled = record.hauled}
    self:action(operation, function(moved, reason)
        if moved then
            record.item = operation.resultItem
            target.approved[self.world:itemId(record.item)], target.touched = true, true
            done(true)
        elseif not record.emptiedFor and not bin:isEmpty() then
            -- A server can limit how many items a can takes.
            record.emptiedFor = true
            self:empty(target, bin)
        else done(false, reason) end
    end)
end

function Jobs:trashDestination(record)
    local delivery, target = self.execution.delivery, self.execution.delivery.target
    local known = target and not target.refused and self.world:resolveBin(target)
    if not target or target.refused or weight(record.item) > target.capacity or known and not known:isItemAllowed(record.item) then
        if target and self:emptyCan(target) then return end
        local why, temporary
        target, why, temporary = self:pickBin(record)
        delivery.target = target
        if not target then
            if temporary then self:holdDelivery(record, why) else self:nextDelivery(record, false, why) end
            return
        end
    end
    local bin = self:readyBin(target)
    if not bin then return end
    self:throwAway(record, target, bin, record.item:getContainer(), function(moved, reason)
        self:nextDelivery(record, moved, reason, bin)
    end)
end

function Jobs:finalStep()
    local execution, here, best, bestCost = self.execution, self.world:point(), nil, nil
    for _, target in ipairs(self.plan.bins) do
        local cost = target.touched and not target.refused and self.routing:estimate(here, target.point)
        if cost and (not best or cost < bestCost) then best, bestCost = target, cost end
    end
    if best then self:emptyCan(best); return end
    if #execution.unlocked > 0 then self:relockStep(); return end
    for _, target in ipairs(self.plan.bins) do
        if target.touched then self:skip({itemName = "Trash can at " .. Log.point(target.point)}, "Not emptied. " .. target.refused) end
    end
    local unsearched = self.view.survey and self.view.survey.sectionsUnsearched or 0
    self:complete((self.view.skipped > 0 or self.view.unconfirmedSources > 0 or unsearched > 0) and "finished_with_skips" or "finished")
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
    -- A can is emptied before it is left, not walked back to.
    if not record and delivery.target and self:emptyCan(delivery.target) then return end
    if not record and #delivery.full > 0 then
        local trash, why = self.plan.request.destination.kind == "trash", delivery.why
        execution.batch, delivery.full, delivery.index, delivery.pass = delivery.full, {}, 1, nil
        self:finishWhenSettled("paused", trash and "No usable trash can: " .. why
            or "Destination full: " .. #execution.batch .. " carried items have no room there", trash and "no-trash-can" or "destination-full")
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
            or "Finished with notes. Review the exclusions and unconfirmed sources below."
    end
    self.view.state, self.view.reason = state, reason or self.view.reason
    if self.view.carried > 0 then self.view.reason = (self.view.reason and self.view.reason .. "; " or "") .. self.view.carried .. " hauled items remain in carried storage" end
    if self.operation and self.operation.completed and self.operation.op.kind == "trash" then self:settleTrash(self.operation.op) end
    if state == "paused" and self.execution then
        self.suspended = {execution = self.execution, operation = self.operation, graph = self.activeGraph, binReview = self.binReview,
            stoppedAt = now(), interaction = self.interaction, startedAt = self.startedAt, opCount = self.opCount}
        if completion and not recoveryOnly then completion.pausedAt = self.suspended.stoppedAt end
        if self.binReview then self.binReview.token, self.binReview.approved = nil, nil end
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
    elseif execution.phase == "carry" then self:carryStep()
    elseif execution.phase == "source" then self:sourceStep()
    elseif execution.phase == "binWait" then
        if now() >= execution.binWait.deadline then execution.phase, execution.binWait = execution.binWait.phase, nil end
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
    elseif execution.phase == "finalTrash" then self:finalStep()
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
    for _, state in pairs(execution and {execution.binWait or false, execution.discovery or false, execution.section or false} or {}) do
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
    if #self.plan.bins > 0 or self.plan.noBins then self:refreshBins() end
    for _, target in ipairs(self.plan.bins) do target.refused, target.tries = nil, nil end
    for _, state in pairs({self.execution.discovery, self.execution.section}) do
        if state and state.deadline then state.deadline = state.deadline + elapsed end
    end
    local asking = saved.binReview or self.execution.binWait
    if asking then
        -- The can is looked at again, so it is asked about only if that is still needed.
        self.execution.phase, self.execution.binWait = asking.phase, nil
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
