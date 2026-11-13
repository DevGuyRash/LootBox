local Native = require "LootBox/Native"
local Categories = require "LootBox/Categories"
local Routing = require "LootBox/Routing"
local Carry = require "LootBox/Carry"
local Condense = require "LootBox/Condense"
local Jobs = {}
Jobs.__index = Jobs

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
        revision = 0 }, Jobs)
end

local function planningBlocked(self)
    return self.execution or self.ending or self.native:isBusy() or (self.suspended and self.view.state == "paused")
end

function Jobs:status()
    local result = {}
    for key, value in pairs(self.view) do result[key] = value end
    result.hasJob = self.execution ~= nil or self.ending ~= nil or self.suspended ~= nil
    result.canResume = self.suspended ~= nil and not self.ending and not self.native:isBusy()
        and (not self.recoveryRequired or self.suspended.execution.recoveryOnly == true)
    result.canPause = self.execution ~= nil and not self.ending
    result.canPreview = not planningBlocked(self)
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

function Jobs:choose(request, item, reservations)
    local previousGraph = self.world.graph
    self.world.graph = self.activeGraph or self.graph
    local ok, candidates, err = pcall(self.world.destinations, self.world, request, item)
    self.world.graph = previousGraph
    if not ok then return nil, "Destination discovery failed: " .. tostring(candidates) end
    if not candidates then return nil, err end
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
    local scopes = { inventory = true, reach = true, room = true, building = true, area = true, container = true, labeled = true }
    local destinations = { inventory = true, floor = true, container = true, vehicle = true, labels = true, trash = true, matching = true }
    if not scopes[request.scope] then return nil, "Choose a source scope" end
    if not destinations[request.destination.kind] then return nil, "Choose a destination" end
    if request.scope == "container" and not request.sourceContainer then return nil, "Choose a source container" end
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

function Jobs:preview(request)
    if planningBlocked(self) then return nil, "Finish or cancel the current job before previewing another" end
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
    self.revision = self.revision + 1
    local plan = { owner = self, revision = self.revision, request = cloneRequest(request),
        moves = {}, skipped = {}, warnings = {}, records = {}, sources = scan.sources or {},
        groundSquares = scan.groundSquares or {}, trash = {}, approved = {}, unknownSources = {} }
    plan.request.destination.targets = nil
    local targets = {}
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
            local approved, blocked, names = {}, false, {}
            local contents = bin:getItems()
            for index = 0, contents:size() - 1 do
                local item = contents:get(index)
                if self.world:protected(item) then blocked = true end
                approved[self.world:itemId(item)] = true
                names[#names + 1] = tostring(item:getName())
            end
            if blocked then
                table.insert(plan.warnings, "Skipping " .. self.world:name(bin) .. ": contains protected items")
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
    local reservations = {}
    for _, record in ipairs(scan.items or {}) do
        local item = record.item
        if matchesSelection(self.graph, request, record.descriptor, record.item, self.player) then
            local protected, protection = self.world:protected(item)
            local reason, status
            if protected then reason, status = protection or "Protected item", "Protected"
            elseif request.destination.kind == "inventory" and self.world:owns(record.source) then reason, status = "Already in carried storage", "Already carried" end
            local destination, admission
            if not reason and request.destination.kind ~= "trash" then
                destination, reason, admission = self:choose(request, item, reservations)
                if reason and admission == "capacity" and preparesBags then
                    reason, status = nil, "Recheck after bag setup"
                end
            end
            local row = { itemName = record.itemName, from = record.from,
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
    if #plan.groundSquares > 0 then
        table.insert(plan.warnings, "Floor items will be inspected through the normal loot window after approaching each selected floor location.")
    end
    plan.pending = unknown + #plan.groundSquares + (#targets - #plan.trash)
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
    self.reviewed = { token = plan, revision = self.revision, request = cloneRequest(request), records = records,
        sources = copyList(plan.sources), unknownSources = copyList(plan.unknownSources), groundSquares = copyList(plan.groundSquares),
        trash = copyList(plan.trash), bins = targets, survey = scan.survey, binProbe = #targets > 0 and #plan.trash == 0, approved = approved,
        skipped = copyList(plan.skipped), graph = Categories.new(self.graph:list()) }
    return plan
end

function Jobs:previewCondense(options)
    if planningBlocked(self) then return nil, "Finish or cancel the current job before condensing" end
    local controller, err = Condense.new(self.world, options)
    if not controller then return nil, err end
    local info
    info, err = controller:preview()
    if not info then return nil, err end
    self.revision = self.revision + 1
    local request = {scope = "inventory", includeBags = true, filter = {all = true, ids = {}, types = {}},
        destination = {kind = "inventory"}}
    local display = {}
    for _, key in ipairs({"mode", "eligible", "bagCount", "beforeWeight", "estimatedSaving", "useUnequipped", "nested", "reason"}) do display[key] = info[key] end
    display.useUnequipped, display.nested = options ~= nil and options.useUnequipped == true, options ~= nil and options.nested == true
    local plan = {owner = self, revision = self.revision, action = "condense", condense = display,
        request = cloneRequest(request), moves = {}, skipped = {}, warnings = {}, pending = info.planning and 1 or 0}
    for _, row in ipairs(info.steps or {}) do
        plan.moves[#plan.moves + 1] = {itemName = row.itemName, from = row.from, to = row.to,
            status = row.temporary and "Temporary buffer" or "Reposition", tone = row.temporary and "warning" or "success"}
    end
    plan.warnings[1] = "This shows the first arrangement. Condense checks current items, bag eligibility and native capacity before every transfer."
    self.reviewed = {token = plan, revision = self.revision, action = "condense", condense = controller,
        request = request, graph = Categories.new(self.graph:list()), bins = {}, skipped = {}}
    return plan
end

function Jobs:start(plan, options)
    if planningBlocked(self) then return nil, "A LootBox job is already active" end
    local reviewed = self.reviewed
    if not reviewed or reviewed.token ~= plan or reviewed.revision ~= self.revision then
        return nil, "Preview this job again before starting" end
    self.reviewed = nil
    self.plan, self.cancelled, self.ending, self.hauled, self.suspended = reviewed, false, nil, {}, nil
    self.activeGraph, self.diagnostics = reviewed.graph, {count = 0, seen = {}}
    if reviewed.action == "condense" then
        local info = reviewed.condense:status()
        self.view = {state = "running", done = 0, moved = 0, cleared = 0, total = info.eligible or 0,
            skipped = 0, reasons = {}, carried = 0, unconfirmedSources = 0, condense = info,
            reason = "Planning carried-item condensation."}
        self.execution = {phase = "condense", condense = reviewed.condense, batch = {}, reviewBins = false}
        self:diagnostic("start-condense")
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
    self:diagnostic("start")
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

function Jobs:diagnostic(event, reason, work)
    local log = self.diagnostics
    if not log or log.count >= 128 then return end
    local phase = self.execution and self.execution.phase or "none"
    local message = reason and tostring(reason):gsub("[\r\n]", " "):sub(1, 300) or ""
    local key = event .. "|" .. self.view.state .. "|" .. phase .. "|" .. message
    if log.seen[key] then return end
    log.seen[key], log.count = true, log.count + 1
    local item = work and work.fullType or "none"
    local id = work and work.itemId or "none"
    print("[LootBox] event=" .. event .. " state=" .. self.view.state .. " phase=" .. phase
        .. " item=" .. tostring(item) .. " id=" .. tostring(id) .. " reason=" .. message)
end

function Jobs:skip(record, reason)
    self.view.skipped = self.view.skipped + 1
    local status = record.status or "Left in place"
    if type(reason) == "string" and reason:sub(1, 11) == "Protected: " then status, reason = "Protected", reason:sub(12) end
    table.insert(self.view.reasons, { itemName = record.itemName or "Container", status = status,
        reason = reason, tone = record.tone or "warning" })
    self.view.reason = reason
    self:diagnostic("left-in-place", reason)
end

local function completeTransfer(self, work, source, destination)
    local op = work.op
    return self.native:transferResult({source = source, destination = destination,
        sourcePoint = op.sourcePoint, destinationPoint = op.destinationPoint,
        floorDestinations = op.floorDestinations}, work.itemId, work.fullType)
end

function Jobs:finishOperation(work, ok, reason, code)
    self.operation, self.pending, self.view.waiting = nil, nil, nil
    if ok and work.op.kind == "approach" and work.op.travel then
        local trip, target = work.op.travel, work.op.location
        local square = work.op.container and self.world:square(work.op.container) or work.op.square
        if square then target = coordinates(square) end
        self.routing:observe(trip.from, target or trip.to, trip.distance, trip.elapsedMs)
    end
    if ok and work.op.kind == "trash" then self:settleTrash(work) end
    if not ok then self:diagnostic("native-failure", reason, work) end
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
            local protected, reason = self.world:protected(item)
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
            local protected, reason = self.world:protected(item)
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
    local accepted, reason, code = self.native:begin(operation)
    if not accepted then
        if code == "busy" then
            work.retry = true
            self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
        else self:finishOperation(work, false, reason, code) end
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
        self:action(operation, function(ok, reason) callback(ok, reason, operation.container) end)
    end
end

function Jobs:walkLocation(point, callback, building, loadedOnly)
    local origin = self.world:point()
    if not origin then callback(false, "Player has no loaded location"); return end
    local distance = math.abs(point.x - origin.x) + math.abs(point.y - origin.y)
    self.execution.walk = {point = point, after = callback, building = building, loadedOnly = loadedOnly,
        visited = {}, hops = 0, limit = math.min(2048, math.max(8, math.ceil(distance / 8) + math.abs(point.z - origin.z) * 8))}
    self.execution.phase = "walk"
end

function Jobs:walkStep()
    local walk = self.execution.walk
    local function finish(ok, err)
        self.execution.walk = nil
        walk.after(ok, err)
    end
    if walk.loadedOnly and self.world:locationLoaded(walk.point) then finish(true); return end
    if walk.hops >= walk.limit then finish(false, "Walking frontier exhausted before reaching the location"); return end
    local targets, direct = self.world:walkTargets(walk.point, walk.visited, walk.building)
    if not targets then finish(false, direct); return end
    walk.hops = walk.hops + 1
    for _, point in ipairs(targets) do walk.visited[point.x .. ":" .. point.y .. ":" .. point.z] = true end
    local operation = {kind = "approach"}
    if direct then operation.location = targets[1] else operation.locations = targets end
    self:action(operation, function(ok, err)
        if direct then finish(ok, err)
        elseif ok then self.execution.phase = "walk"
        else
            walk.failure = err
            self.execution.phase = "walk"
        end
    end)
end

function Jobs:matches(record, plan)
    local protected, protection = self.world:protected(record.item)
    if protected then return nil, "Protected: " .. tostring(protection or "Item is protected") end
    if not matchesSelection(self.activeGraph, plan.request, self.world:describe(record.item), record.item, self.player) then
        return nil, "Item no longer matches the selection" end
    return true
end

function Jobs:recordSource(record, callback)
    if record.groundPoint then
        local function inspect()
        local point = record.groundPoint
        local square = getCell():getGridSquare(point.x, point.y, point.z)
        if not square then callback(nil, "Source floor did not load after walking"); return end
        self:action({ kind = "approach", square = square }, function(ok, err)
            if not ok then callback(nil, err); return end
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
        self:walkLocation(record.groundPoint, function(ok, err)
            self.execution.phase = "source"
            if ok then inspect() else callback(nil, err) end
        end, nil, true)
    else
        local function inspect()
        local source, problem = self.world:resolveSource(record.sourceAnchor)
        if not source or not sourceItem(record, source) then callback(nil, problem or "Item changed source after preview"); return end
        self:approach(source, function(ok, err, current)
            if not ok then callback(nil, err); return end
            source = current
            local item = sourceItem(record, source)
            if not item then callback(nil, "Item changed source after preview"); return end
            record.item, record.source = item, source
            callback(source)
        end)
        end
        local source, problem = self.world:resolveSource(record.sourceAnchor)
        if not source and problem == "unloaded" then
            self:walkLocation(record.sourceAnchor.point, function(ok, err)
                self.execution.phase = "source"
                if ok then inspect() else callback(nil, err) end
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
    local records = self.world:gearRecords(sources)
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
        else self:diagnostic("gear-unavailable", reason) end
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
            self:diagnostic("staging-unavailable", failure, record)
            reason = reason .. "; " .. tostring(failure)
        end
    end
    record.admissionFailures = (record.admissionFailures or 0) + 1
    if record.admissionFailures >= 3 then self:skip(record, reason); return end
    if not execution.deferred[record] then self.view.deferred = self.view.deferred + 1 end
    execution.deferred[record] = {revision = execution.capacityRevision, reason = reason}
    self.view.reason = "This item is waiting for a later load after carrying space is freed."
    self:diagnostic("capacity-deferred", reason, record)
end

function Jobs:beginRecovery(mode, after)
    self.execution.recovery = {mode = mode, after = after}
    self.execution.phase = "recovery"
end

function Jobs:recoverPersonalGear()
    if not self.recovery or not self.recovery:status().pending then return nil, "There is no personal gear waiting to be recovered" end
    if self.execution or self.ending or self.native:isBusy() then return nil, "Pause or cancel the current job before recovering personal gear" end
    local reason = self.native:takeoverReason()
    if reason then return nil, reason end
    local saved = self.suspended
    while saved and saved.execution.recoveryOnly do saved = saved.execution.resumeSaved end
    self.recoveryRequired = true
    self.suspended, self.activeGraph = nil, self.graph
    self.execution = {recoveryOnly = true, resumeSaved = saved, phase = "recovery", batch = {},
        recovery = {mode = "restore"}, capacityRevision = 0}
    self.plan = self.plan or {bins = {}}
    self.view.state, self.view.reason = "running", "Returning to the personal gear staging container."
    self.view.reasons, self.view.skipped = self.view.reasons or {}, self.view.skipped or 0
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
        self.execution, self.operation, self.pending, self.activeGraph, self.suspended = nil, nil, nil, nil, saved
        self.recoveryRequired = nil
        self.view.state = saved and "paused" or "finished"
        self.view.reason = saved and "Personal gear recovered. Choose Resume job to continue the paused job." or "Personal gear recovered to its original places."
        self:diagnostic("recovered", self.view.reason)
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
    local execution, records = self.execution, {}
    for record, pending in pairs(execution.deferred) do
        if record.settled then
            execution.deferred[record] = nil
            self.view.deferred = self.view.deferred - 1
        elseif pending.revision < execution.capacityRevision then
            records[#records + 1] = record
            execution.deferred[record] = nil
            self.view.deferred = self.view.deferred - 1
        else
            self:skip(record, pending.reason or "No further carrying space became available for this item")
            execution.deferred[record] = nil
            self.view.deferred = self.view.deferred - 1
        end
    end
    if #records == 0 then return false end
    table.sort(records, function(a, b) return tostring(a.itemId) < tostring(b.itemId) end)
    execution.records, execution.recordIndex, execution.phase = records, 1, "source"
    return true
end

function Jobs:createExecution(plan)
    local execution = { phase = "source", tasks = {}, taskIndex = 1, records = {}, recordIndex = 1,
        batch = {}, seen = {}, seenSources = {}, seenGround = {}, failedRoutes = {}, plan = plan, finalBin = 1,
        work = {}, deleted = {}, deferred = {}, capacityRevision = 0 }
    local groups, order = {}, {}
    for _, entry in ipairs(plan.records) do
        local record = self:captureRecord(entry)
        self:registerWork(execution, record)
        execution.seen[self.world:itemId(record.item) or record.item] = true
        local key = plan.request.destination.kind == "matching" and self.player:getInventory() or record.groundSquare or record.source
        if not groups[key] then groups[key] = {}; order[#order + 1] = key end
        groups[key][#groups[key] + 1] = record
    end
    for _, owned in ipairs({true, false}) do
        for _, key in ipairs(order) do
            if self.world:owns(groups[key][1].source) == owned then
                execution.tasks[#execution.tasks + 1] = {kind = "records", records = groups[key]}
            end
        end
    end
    for _, container in ipairs(plan.unknownSources) do
        execution.tasks[#execution.tasks + 1] = {kind = "discover", container = container, anchor = self.world:sourceAnchor(container)}
        execution.seenSources[self.world:key(container) or container] = true
    end
    for _, square in ipairs(plan.groundSquares) do
        local point = coordinates(square)
        execution.tasks[#execution.tasks + 1] = {kind = "floor", point = point}
        execution.seenGround[pointKey(point)] = true
    end
    plan.touched = {}
    return execution
end

function Jobs:sectionTasks(scan)
    local execution, groups, order = self.execution, {}, {}
    execution.tasks, execution.taskIndex, execution.records, execution.recordIndex = {}, 1, {}, 1
    for _, entry in ipairs(scan.items) do
        local id = self.world:itemId(entry.item) or entry.item
        if not execution.seen[id] and matchesSelection(self.activeGraph, self.plan.request, entry.descriptor, entry.item, self.player) then
            execution.seen[id] = true
            if not (self.plan.request.destination.kind == "inventory" and self.world:owns(entry.source)) then
                local key = entry.groundSquare or entry.source
                if not groups[key] then groups[key] = {}; order[#order + 1] = key end
                local record = self:captureRecord(entry)
                self:registerWork(execution, record)
                groups[key][#groups[key] + 1] = record
                self.view.total = self.view.total + 1
            end
        end
    end
    for _, key in ipairs(order) do execution.tasks[#execution.tasks + 1] = {kind = "records", records = groups[key]} end
    for _, source in ipairs(scan.sources) do
        local key = self.world:key(source) or source
        if not source:isExplored() and not execution.seenSources[key] then
            execution.seenSources[key] = true
            execution.tasks[#execution.tasks + 1] = {kind = "discover", container = source, anchor = self.world:sourceAnchor(source)}
        end
    end
    for _, square in ipairs(scan.groundSquares) do
        local point = coordinates(square)
        if not execution.seenGround[pointKey(point)] then
            execution.seenGround[pointKey(point)] = true
            execution.tasks[#execution.tasks + 1] = {kind = "floor", point = point}
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
    for _, entry in ipairs(entries) do
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
    self.execution.delivery = { index = 1, after = after, prepared = false, failed = {}, origin = self.world:point() }
    self.execution.phase = "delivery"
end

function Jobs:pickup(record)
    local execution, plan = self.execution, self.execution.plan
    if record.settled then self:nextRecord(); self:finishHeavyAttempt(record, false); return end
    self.view.itemName = record.itemName
    self.view.reason = "Preparing selected items for transfer."
    self:recordSource(record, function(source, err)
        local ok
        if source then ok, err = self:matches(record, plan) end
        if not source or not ok then
            self:skip(record, err)
            self:nextRecord()
            self:finishHeavyAttempt(record, false)
            return
        end
        local direct = carriedDestination(self, plan.request)
        if not direct and self.world:owns(source) then
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
        local destination, request, code
        if direct then request = plan.request
        else request = { includeBags = plan.request.includeBags, destination = { kind = "inventory" } } end
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
                    record.carryContainer = operation.destination
                    record.hauled = true
                    execution.batch[#execution.batch + 1] = record
                    self.view.carried = self.view.carried + 1
                else
                    record.settled = true
                    self.view.done, self.view.moved = self.view.done + 1, self.view.moved + 1
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

function Jobs:nextDelivery(record, ok, reason, destination)
    if ok then
        self.view.done, self.view.moved = self.view.done + 1, self.view.moved + 1
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
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination, trashTarget = record.trashTarget}
        if point then operation.destinationPoint = point end
        self:action(operation, function(moved, failure)
            if moved then record.item = operation.resultItem end
            self:nextDelivery(record, moved, failure, operation.destination)
        end)
    end
    if point then
        self:walkLocation(point, function(loaded, reason)
            self.execution.phase = "delivery"
            if not loaded then self:nextDelivery(record, false, reason); return end
            self:action({kind = "approach", location = point, exact = true}, transfer)
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

function Jobs:inspectBin(target, callback)
    local execution = self.execution
    local function approach()
        local bin, reason = self.world:resolveTrashTarget(target)
        if not bin then callback(false, reason); return end
        self:approach(bin, function(ok, err)
            if not ok then callback(false, err); return end
            bin, reason = self.world:resolveTrashTarget(target)
            if not bin then callback(false, reason); return end
            if isClient() and not bin:isExplored() then bin:requestServerItemsForContainer() end
            execution.binInspection = {target = target, after = callback, deadline = now() + (isClient() and 3000 or 0)}
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
    if not self.world:markTrashInspected(pending.target) then pending.after(false, "The player moved away during inspection"); return end
    self.reviewGeneration = (self.reviewGeneration or 0) + 1
    self.binReview = {target = pending.target, after = pending.after}
    self.execution.phase, self.view.state, self.view.reviewId = "binReview", "needs_review", self.reviewGeneration
    self.view.reason = "Review the inspected bin contents before continuing. The current job and item selection are retained."
    self:diagnostic("bin-review")
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
        else review.moves[#review.moves + 1] = {itemName = item:getName(), status = "Delete", tone = "danger",
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
        if self.plan.request.destination.kind == "trash" then self:refreshBins() end
        if self.plan.request.destination.kind == "vehicle" then
            self:action({kind = "vehicle", vehicle = self.plan.request.destination.ref or self.world:vehicle()}, function(ok, err)
                if not ok then delivery.failure = err or "Vehicle access failed" end
            end)
            return
        end
    end
    local record = execution.batch[delivery.index]
    if not record then
        execution.batch = {}
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
        local destination
        destination, err = self:choose(self.plan.request, record.item)
        if not destination then self:nextDelivery(record, false, err)
        else self:place(record, destination) end
    end
end

function Jobs:discoverSource(source, anchor, alreadyCounted)
    local function inspect()
    local current, failure = self.world:resolveSource(anchor)
    if not current then self:skip({itemName = self.world:name(source)}, failure); self.execution.phase = "source"; return end
    source = current
    self:approach(source, function(ok, err, current)
        if not ok then self:skip({itemName = self.world:name(source)}, err); self.execution.phase = "source"; return end
        source = current
        if isClient() then
            local reason = "Native multiplayer synchronization is unconfirmed; only observed items from this source can be moved"
            if not alreadyCounted then
                self.view.unconfirmedSources = self.view.unconfirmedSources + 1
                table.insert(self.view.reasons, {itemName = self.world:name(source), status = "Unconfirmed", tone = "warning", reason = reason})
            end
            self.view.reason = reason
            source:requestServerItemsForContainer()
            self.execution.discovery = {source = source, anchor = anchor, deadline = now() + 3000}
            self.execution.phase = "discoveryWait"
        else
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then self:skip({itemName = self.world:name(source)}, "The native loot window is not available"); self.execution.phase = "source"; return end
            loot:checkExplored(source, self.player)
            self:addObserved(self.world:records(source, self.plan.request.includeBags))
        end
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
    if record then self:pickup(record); return end
    local task = execution.tasks[execution.taskIndex]
    execution.taskIndex = execution.taskIndex + 1
    if not task then
        if self.plan.survey and not self.plan.survey.complete then execution.phase = "survey"
        elseif #execution.batch > 0 then self:startDelivery("source")
        elseif not self:retryDeferred() then execution.phase = "finalTrash" end
    elseif task.kind == "records" then execution.records, execution.recordIndex = task.records, 1
    elseif task.kind == "discover" then self:discoverSource(task.container, task.anchor)
    elseif task.kind == "floor" then
        self:walkLocation(task.point, function(arrived, failure)
        self.execution.phase = "source"
        if not arrived then self:skip({itemName = "Floor"}, failure); return end
        local square = getCell():getGridSquare(task.point.x, task.point.y, task.point.z)
        if not square then self:skip({itemName = "Floor"}, "Source floor is still unloaded"); return end
        self:action({kind = "approach", square = square}, function(ok, err)
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not ok or not loot then self:skip({itemName = "Floor"}, err or "The native loot window is not available"); return end
            loot:refreshBackpacks()
            square = getCell():getGridSquare(task.point.x, task.point.y, task.point.z)
            if not square then self:skip({itemName = "Floor"}, "Source floor is no longer loaded"); return end
            local scoped = {}
            for _, entry in ipairs(self.world:records(ISInventoryPage.GetFloorContainer(self.player:getPlayerNum()), self.plan.request.includeBags)) do
                if entry.groundSquare == square then scoped[#scoped + 1] = entry end
            end
            self:addObserved(scoped)
        end)
        end, nil, true)
    end
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

function Jobs:complete(state, reason)
    if self.execution and self.execution.condense then
        self.view.condense = self.execution.condense:status()
        if (self.view.condense.buffered or 0) > 0 then
            reason = (reason or "Condense stopped") .. "; a bag arrangement is incomplete and buffered items remain carried. Resume to finish or repair it."
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
    if (state == "cancelled" or state == "paused") and self.execution then
        self.suspended = {execution = self.execution, operation = self.operation, graph = self.activeGraph, binReview = self.binReview, stoppedAt = now()}
        if self.binReview then self.binReview.token, self.binReview.approved = nil, nil end
        for _, target in ipairs(self.plan.bins or {}) do target.approved, target.needsInspection = {}, true end
        self.view.reason = (self.view.reason or "Stopped") .. ". Choose Resume job to continue."
    end
    self:diagnostic("complete", self.view.reason)
    self.execution, self.pending, self.operation, self.activeGraph, self.ending, self.binReview = nil, nil, nil, nil, nil, nil
    self.view.waiting = nil
end

function Jobs:advance()
    if self.pending then
        local done, reason, code = self.native:poll()
        if done == nil then return end
        local pending = self.pending
        self.pending = nil
        if done == false and (code == "yielded" or code == "busy") then
            pending.work.retry, pending.work.sourcePrepared, pending.work.walk = true, nil, nil
            self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
        elseif not done then self:finishOperation(pending.work, false, reason, code)
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
        if not target then
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

function Jobs:finishWhenSettled(state, reason)
    self.ending = self.ending or {state = state, reason = reason}
    self.view.state = state == "paused" and "pausing" or "cancelling"
    self:diagnostic("stopping", reason)
    local ok, result, err = pcall(self.native.cancel, self.native, self.operation and self.operation.op)
    if not ok or result == false then self.ending.reason = (self.ending.reason or "") .. "; cancellation error: " .. tostring(ok and err or result) end
end

function Jobs:tick()
    if self.execution and not self.ending then
        local reason, code = self.native:takeoverReason()
        if reason then self:finishWhenSettled(code == "combat" and "paused" or "cancelled", reason) end
    end
    if self.ending then
        if self.native:isBusy() then
            local ok, result, err = pcall(self.native.poll, self.native)
            if not ok then
                self.view.reason = "Native cleanup error: " .. tostring(result)
                self:diagnostic("cleanup-failure", self.view.reason, self.operation)
                return
            end
            if result == nil then return end
            if result == true and self.pending and self.pending.op == self.operation.op
                and (self.operation.op.kind == "transfer" or self.operation.op.kind == "trash" or self.operation.op.kind == "gear") then self.operation.completed = true end
            if err and err ~= "Cancelled" then self.ending.reason = (self.ending.reason and self.ending.reason .. "; " or "") .. err end
        end
        self:complete(self.ending.state, self.ending.reason)
    elseif self.execution then
        self:diagnostic("transition")
        if not self.native:isBusy() and self.native:isPlayerBusy() then
            if self.operation and not self.operation.completed then
                self.operation.retry, self.operation.sourcePrepared, self.operation.walk = true, nil, nil
            end
            self.view.waiting = "Waiting for your current action to finish. This job will continue automatically."
            return
        end
        self.view.waiting = nil
        local ok, err = pcall(self.advance, self)
        if not ok then self:finishWhenSettled("failed", "Job execution failed: " .. tostring(err)) end
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
    self.suspended, self.view.state, self.view.reason = nil, "running", "Continuing the stopped job with current item and destination checks."
    if self.execution.condense then self.execution.condense:onResume() end
    if self.operation and not self.operation.completed then
        self.operation.retry, self.operation.sourcePrepared, self.operation.walk = true, nil, nil
    end
    local elapsed = now() - saved.stoppedAt
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

function Jobs:pause()
    if self.ending then return true end
    if not self.execution then return nil, "There is no running job to pause" end
    self:finishWhenSettled("paused", "Paused by the player")
    return true
end

function Jobs:cancel()
    if self.ending then return true end
    if not self.execution and not self.native:isBusy() then
        if self.suspended then
            self.view.state, self.view.reason = "cancelled", "Cancelled. Choose Resume job to continue."
            self:diagnostic("cancelled-checkpoint", self.view.reason)
        end
        return true
    end
    self:finishWhenSettled("cancelled", "Cancelled")
    return true
end

return Jobs
