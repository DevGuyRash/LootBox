if package then
    package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
    package.loaded["LootBox/Jobs"] = nil
end

local active, tests = nil, 0
local Native = {}

local function list(values)
    return { size = function() return #values end, get = function(_, index) return values[index + 1] end,
        isEmpty = function() return #values == 0 end }
end

local function container(name, capacity, owned)
    local result = { name = name, capacity = capacity or 100, owned = owned, items = {}, explored = true, position = name }
    function result:getItems() return list(self.items) end
    function result:isEmpty() return #self.items == 0 end
    function result:contains(item) for _, entry in ipairs(self.items) do if entry == item then return true end end; return false end
    function result:getItemWithID(id) for _, entry in ipairs(self.items) do if entry:getID() == id then return entry end end end
    function result:containsID(id) return self:getItemWithID(id) ~= nil end
    function result:getType() return self.kind or "crate" end
    function result:getEffectiveCapacity() return self.capacity end
    function result:getCapacityWeight()
        local total = 0
        for _, item in ipairs(self.items) do total = total + item.weight end
        return total
    end
    function result:hasRoomFor(player, item)
        return self:getType() == "floor" or self:getCapacityWeight() + item.weight <= self:getEffectiveCapacity(player)
    end
    function result:isItemAllowed() return true end
    function result:isInside() return false end
    function result:isExplored() return self.explored end
    function result:requestServerItemsForContainer()
        self.requested = (self.requested or 0) + 1
        self.lastRequestAt = active.now
        if self.reply then
            active.scheduled[#active.scheduled + 1] = { at = active.now + 400, run = self.reply }
        end
    end
    return result
end

local nextId = 0
local function item(source, fullType, weight)
    nextId = nextId + 1
    local result = { id = tostring(nextId), fullType = fullType or "Base.Nails", weight = weight or 1, container = source }
    function result:getID() return self.id end
    function result:getFullType() return self.fullType end
    function result:getName() return self.fullType end
    function result:getUnequippedWeight() return self.weight end
    function result:getContainer() return self.container end
    function result:getWorldItem() return self.world end
    source.items[#source.items + 1] = result
    return result
end

local function remove(values, value)
    for index, entry in ipairs(values) do
        if entry == value then table.remove(values, index); return true end
    end
    return false
end

local function coordinateKey(point)
    return point.x .. ":" .. point.y .. ":" .. point.z
end

local function square(name, x, y, z)
    local value = {name = name, x = x, y = y, z = z or 0}
    function value:getX() return self.x end
    function value:getY() return self.y end
    function value:getZ() return self.z end
    return value
end

function Native.new(player)
    local adapter = setmetatable({ player = player }, { __index = Native })
    active.adapter = adapter
    return adapter
end
function Native:isBusy() return self.active ~= nil end
function Native:isPlayerBusy() return active.playerBusy == true end
function Native:takeoverReason() return active.takeover, active.takeoverKind end
function Native:transferResult(op, id, fullType)
    if op.sourcePoint then
        for _, value in ipairs(active.ground) do
            local square = value:getWorldItem():getSquare()
            if coordinateKey(square) == coordinateKey(op.sourcePoint) and value:getID() == id then return nil end
        end
    elseif op.source and op.source:containsID(id) then return nil end
    if op.destinationPoint then
        for _, value in ipairs(active.ground) do
            local square, dropped = value:getWorldItem():getSquare(), active.floorDrops[id]
            local original = coordinateKey(op.destinationPoint)
            local admitted = coordinateKey(square) == original
            for _, point in ipairs(op.floorDestinations or {}) do
                if coordinateKey(point) == coordinateKey(square) then admitted = true end
            end
            if value:getID() == id and value:getFullType() == fullType
                and admitted and (coordinateKey(square) == original or dropped and dropped.origin == original) then return value end
        end
    elseif op.destination then
        local value = op.destination:getItemWithID(id)
        if value and value:getFullType() == fullType then return value end
    end
end
function Native:begin(op)
    assert(not self.active, "The job overlapped native operations")
    if op.kind == "trash" and active.rejectTrash then return nil, "The server rejected deletion" end
    if op.kind == "trash" and active.holdTrashBegin then
        active.holdTrashBegin, active.playerBusy = false, true
        return nil, "An ordinary action is finishing", "busy"
    end
    if active.beginBusy then active.beginBusy = nil; return nil, "Another action is finishing", "busy" end
    if active.rejectOnce then local reason = active.rejectOnce; active.rejectOnce = nil; return nil, reason end
    if op.kind == "transfer" and op.personalRecovery then
        local external = not op.source.owned and op.source or not op.destination.owned and op.destination
        if external and active.position ~= external.position then return nil, "The personal gear container is out of reach" end
    end
    if op.kind == "transfer" and op.destination.owned and not op.source.owned and (active.rejectPickupCount or 0) > 0 then
        active.rejectPickupCount = active.rejectPickupCount - 1
        active.rejectedPickups = (active.rejectedPickups or 0) + 1
        return nil, "The destination is full", "capacity"
    end
    if op.kind == "transfer" and op.destination.kind == "floor" then
        op.floorDestinations = {op.destinationPoint}
        if active.floorDropPoint then op.floorDestinations[#op.floorDestinations + 1] = active.floorDropPoint end
    end
    active.operations[#active.operations + 1] = op
    if op.kind == "trash" then
        for _, entry in ipairs(op.container.items) do
            if not op.approved[entry.id] or entry.protected then return nil, "The trash can contains an item outside the approved cleanup" end
        end
    end
    self.active = { op = op, pending = 1 }
    return true
end
function Native:cancel()
    if self.active then self.active.cancelled = true; self.active.cleanup = 3; active.cancelRequested = true end
    return true
end
function Native:poll()
    local state = self.active
    if not state then return true end
    if state.cancelled then
        state.cleanup = state.cleanup - 1
        if active.trashReplyDuringCancel and state.op.kind == "trash" and not state.effectDone then
            local bin = state.op.container
            for _, entry in ipairs(bin.items) do entry.container = nil end
            active.deletions[#active.deletions + 1] = {bin = bin, count = #bin.items}
            bin.items, state.effectDone = {}, true
        end
        if state.cleanup > 0 then return nil end
        self.active = nil
        active.restored = true
        if active.completeDuringCancel and state.effectDone then return true end
        return false, "Cancelled"
    end
    local op = state.op
    if active.yieldOnce and (active.yieldOnce == true or active.yieldOnce == op.kind) then
        active.yieldOnce, self.active = nil, nil
        return false, "An ordinary action is using the queue", "yielded"
    end
    if active.throwPoll and op.kind == "vehicle" and not active.thrown then
        active.thrown = true
        error("Simulated observation failure during vehicle entry")
    end
    if state.pending > 0 then state.pending = state.pending - 1; return nil end
    if state.effectDone then self.active = nil; return true end
    if op.kind == "approach" then
        local target
        if op.container then target = op.container.position
        elseif op.square then target = op.square.name
        else
            local choices = op.locations or {op.location}
            for _, point in ipairs(choices) do
                local candidate = active.grid[coordinateKey(point)]
                if candidate and not active.blockedPositions[candidate.name] then target = candidate.name; break end
            end
            target = target or coordinateKey(choices[1])
        end
        active.approaches[target] = (active.approaches[target] or 0) + 1
        if active.blockedPositions[target] then self.active = nil; return false, "No path to the destination" end
        if op.container and active.unloaded[target] then self.active = nil; return false, "Container chunk is unloaded" end
        local from = active.world:point()
        local withinReach = op.square and not op.exact and active.nearby[active.position] and active.nearby[active.position][target]
        if not withinReach and active.position ~= target then active.visits[#active.visits + 1] = target; active.position = target end
        if op.location or op.locations then
            active.unloaded[target] = nil
            if active.onWalk then active.onWalk(op, target) end
        end
        if active.onApproach then active.onApproach(op) end
        if active.observeTravel then
            local to = active.world:point()
            local distance, elapsed = math.abs(from.x - to.x) + math.abs(from.y - to.y) + math.abs(from.z - to.z), 1000
            if type(active.observeTravel) == "function" then distance, elapsed = active.observeTravel(from, to) end
            op.travel = {from = from, to = to, distance = distance, elapsedMs = elapsed}
        end
    elseif op.kind == "transfer" then
        assert(op.source:contains(op.item), "Native transfer source lost the item")
        assert(op.destination:hasRoomFor(self.player, op.item), "Native transfer exceeded capacity")
        assert(remove(op.source.items, op.item))
        if op.source.kind == "floor" then remove(active.ground, op.item); op.item.world = nil end
        local current = op.item
        if active.rehydrate then
            current = item(op.destination, op.item.fullType, op.item.weight)
            current.id, current.protected = op.item.id, op.item.protected
            op.item.container = nil
        else
            op.destination.items[#op.destination.items + 1] = current
            current.container = op.destination
        end
        op.resultItem = current
        if op.destination.kind == "floor" then
            local square = active.floorDropPoint or active.squares[active.position]
            current.world = { getSquare = function() return square end }
            active.ground[#active.ground + 1] = current
            active.floorDrops[current.id] = {origin = coordinateKey(op.destinationPoint), square = square}
        end
        active.transfers[#active.transfers + 1] = { item = current, source = op.source, destination = op.destination }
        if active.onTransfer then active.onTransfer(op) end
        if active.holdTransferResult then state.effectDone = true; return nil end
    elseif op.kind == "trash" then
        for _, entry in ipairs(op.container.items) do
            assert(op.approved[entry.id], "A whole-bin command included an unapproved item")
            assert(not entry.protected, "A whole-bin command included a protected item")
            entry.container = nil
        end
        active.deletions[#active.deletions + 1] = { bin = op.container, count = #op.container.items }
        op.container.items = {}
        if active.holdTrashResult then state.effectDone = true; return nil end
    elseif op.kind ~= "vehicle" then error("Unknown native operation") end
    self.active = nil
    return true
end

local originalRequire = require
require = function(name)
    if name == "LootBox/Native" then return Native end
    return originalRequire(name)
end
local Jobs = require "LootBox/Jobs"
require = originalRequire
local Categories = require "LootBox/Categories"

getTimestampMs = function() return active.now end
isClient = function() return active.client == true end
getServerOptions = function() return { getBoolean = function() return active.allowTrash ~= false end } end
getPlayerLoot = function() return active.loot end
ISInventoryPage = { GetFloorContainer = function() return active.floor end }
getCell = function() return {getGridSquare = function(_, x, y, z)
    local found = active.grid[x .. ":" .. y .. ":" .. z]
    if found and not active.unloaded[found.name] then return found end
end} end

local function fixture(capacity)
    local f = { now = 0, position = "source", visits = {}, transfers = {}, deletions = {}, scheduled = {}, ground = {}, squares = {}, nearby = {},
        grid = {}, unloaded = {}, blockedPositions = {}, approaches = {}, operations = {}, sourceLocations = {}, binLocations = {}, unloadedBins = {}, inspectedBins = {}, floorDrops = {} }
    local nextPosition = 0
    function f:ensureSquare(name, point)
        if self.squares[name] then
            local existing = self.squares[name]
            if not existing.getX then
                nextPosition = nextPosition + 1
                self.squares[name] = square(name, nextPosition * 10, 0)
            end
        else
            nextPosition = nextPosition + 1
            self.squares[name] = square(name, point and point.x or nextPosition * 10,
                point and point.y or 0, point and point.z or 0)
        end
        local result = self.squares[name]
        self.grid[coordinateKey(result)] = result
        return result
    end
    function f:addSquare(value)
        self.squares[value.name], self.grid[coordinateKey(value)] = value, value
        return value
    end
    f:addSquare(square("source", 0, 0))
    f:addSquare(square("destination", 10, 0))
    f:addSquare(square("inventory", 0, 0))
    f.inventory = container("inventory", capacity or 3, true)
    f.source = container("source", 100)
    f.destination = container("destination", 100)
    f.floor = container("floor", 1000); f.floor.kind = "floor"
    f.sources, f.bins, f.groundSquares = { f.source }, {}, {}
    f.player = { getPlayerNum = function() return 0 end,
        getInventory = function() return f.inventory end,
        isDead = function() return f.dead == true end, isAsleep = function() return f.asleep == true end,
        getCurrentSquare = function() return f:ensureSquare(f.position) end }
    local world = {}
    function world:point()
        local current = f:ensureSquare(f.position)
        return {x = current.x, y = current.y, z = current.z}
    end
    function world:key(value) return value.name end
    function world:square(value) return f:ensureSquare(value.position) end
    function world:sourceAnchor(value)
        f.sourceLocations[value.name] = f.sourceLocations[value.name] or value
        if self:owns(value) then return {key = value.name} end
        local point = self:square(value)
        return {key = value.name, point = {x = point.x, y = point.y, z = point.z}}
    end
    function world:resolveSource(anchor)
        if not anchor then return nil, "Missing source anchor" end
        local current = f.sourceLocations[anchor.key]
        if current and f.unloaded[current.position] then return nil, "unloaded" end
        if current then return current end
        return nil, "Source changed after preview"
    end
    function world:locationLoaded(point)
        return getCell():getGridSquare(point.x, point.y, point.z) ~= nil
    end
    function world:walkTargets(point)
        local target = f.grid[coordinateKey(point)]
        if not target then return nil, "No loaded walking frontier reaches the unsearched location" end
        return {{x = point.x, y = point.y, z = point.z}}, true
    end
    function world:owns(value) return value and value.owned == true end
    f.carried = {f.inventory}
    f.hardLimit = capacity or 3
    function f:carryContainer(value, factor)
        value.owned, value.carryFactor = true, factor or 1
        self.carried[#self.carried + 1] = value
        return value
    end
    function world:carryDelta(value, destination)
        if not self:owns(destination) then return 0 end
        local source = value:getContainer()
        local previous = self:owns(source) and (source.carryFactor or 1) or 0
        return value.weight * ((destination.carryFactor or 1) - previous)
    end
    function world:carrying()
        local mass = 0
        for _, carried in ipairs(f.carried) do
            for _, value in ipairs(carried.items) do mass = mass + value.weight * (carried.carryFactor or 1) end
        end
        return f.unlimitedCarry and 0 or mass, f.unlimitedCarry and math.huge or f.hardLimit
    end
    function f.inventory:getCapacityWeight() return world:carrying() end
    function f.inventory:getEffectiveCapacity() return f.hardLimit end
    function f.player:getMaxWeight() error("Comfort must not govern hauling admission") end
    function world:itemId(value) return value.id end
    function world:describe(value) return { fullType = value.fullType, categoryId = "native:Material", labels = {} } end
    function world:protected(value) return value.protected == true end
    function world:name(value) return value.name end
    function world:valid() return true end
    function world:gearRecords() return {} end
    function world:safeStagingContainers() return f.safeCandidates or {} end
    function world:isTrash(value) return value.trash == true end
    function world:vehicle() return {} end
    function world:trashCandidates()
        local bins = {}
        for _, bin in ipairs(f.bins) do if not f.unloaded[bin.position] then bins[#bins + 1] = bin end end
        return bins, {}
    end
    function world:trashTarget(bin)
        local point = self:square(bin)
        f.binLocations[bin.name] = f.binLocations[bin.name] or bin
        return {key = bin.name, container = bin, point = {x = point.x, y = point.y, z = point.z},
            capacity = bin.capacity, used = bin:getCapacityWeight(), needsInspection = bin.uninspected and not f.inspectedBins[bin.name] or nil}
    end
    function world:unloadedTrashTargets()
        local targets = {}
        for _, bin in ipairs(f.unloadedBins) do
            local target = self:trashTarget(bin)
            target.container, target.needsInspection = nil, true
            targets[#targets + 1] = target
        end
        return targets
    end
    function world:resolveTrashTarget(target)
        local current = f.binLocations[target.key]
        if current and f.unloaded[current.position] then return nil, "unloaded" end
        if not current or not current.trash then return nil, "missing" end
        target.container, target.capacity, target.used = current, current.capacity, current:getCapacityWeight()
        return current
    end
    function world:binReachable(target)
        local current = f.binLocations[target.key]
        return current and not f.unloaded[current.position] and f.position == current.position
    end
    function world:markTrashInspected(target)
        if self:binReachable(target) then f.inspectedBins[target.key] = true; return true end
    end
    function world:records(source)
        local result = {}
        for _, value in ipairs(source.items) do
            result[#result + 1] = { item = value, source = source, descriptor = self:describe(value),
                groundSquare = value.world and value.world:getSquare(), itemName = value.fullType, from = source.name }
        end
        return result
    end
    function world:scan(request)
        f.scannedRequest = request
        if request.scope == "building" and f.survey then
            return {items = {}, sources = {}, groundSquares = {}, warnings = {}, survey = f.survey}
        end
        local records, endpoints = {}, {}
        if not f.onlyGround then
            for _, source in ipairs(f.sources) do
                local selected = request.scope ~= "labeled"
                if not selected then
                    for _, id in ipairs(request.sourceLabels) do if source.labels and source.labels[id] then selected = true end end
                end
                if selected then
                    endpoints[#endpoints + 1] = source
                    if source.explored then
                        for _, record in ipairs(self:records(source)) do records[#records + 1] = record end
                    end
                end
            end
        end
        return { items = records, sources = endpoints, groundSquares = f.groundSquares, warnings = {} }
    end
    function world:sectionTarget(section)
        return {x = section.target.x, y = section.target.y, z = section.target.z}
    end
    function world:scanSection(section)
        local result = {items = {}, sources = {}, groundSquares = {}, warnings = {}}
        local missing = f.unloaded[section.target.name] and 1 or section.missing or 0
        if missing == 0 or section.inspectLoadedPart then
            for _, source in ipairs(section.sources or {}) do
                result.sources[#result.sources + 1] = source
                if source.explored then
                    for _, record in ipairs(self:records(source)) do result.items[#result.items + 1] = record end
                end
            end
            result.groundSquares = section.groundSquares or {}
        end
        return result, missing, section.denied or 0
    end
    function world:destinations(request)
        if request.destination.kind == "inventory" then return { f.inventory } end
        if request.destination.kind == "floor" then return { f.floor } end
        if request.destination.kind == "container" then return { request.destination.ref or f.destination } end
        return { f.destination }
    end
    f.loot = {}
    function f.loot:checkExplored(source) source.explored = true; if source.reply then source.reply() end end
    function f.loot:refreshBackpacks()
        f.floor.items = {}
        for _, value in ipairs(f.ground) do
            local here = value.world and value.world:getSquare()
            if not f.floorOnlyHere or here == f.squares[f.position] then
                f.floor.items[#f.floor.items + 1] = value; value.container = f.floor
            end
        end
    end
    f.world = world
    active = f
    f.jobs = Jobs.new(f.player, world, assert(Categories.new({})))
    return f
end

local function building(f, sections, yields)
    local index, pending, processed, searched, unsearched, failures = 0, nil, 0, 0, 0, {}
    local remainingYields = yields or 0
    for _, section in ipairs(sections) do f:addSquare(section.target) end
    local survey = {building = {}, complete = false}
    function survey:next()
        assert(not pending, "A section cannot be skipped while its result is pending")
        if remainingYields > 0 then remainingYields = remainingYields - 1; return false end
        index = index + 1
        pending = sections[index]
        if not pending then self.complete = true end
        return pending
    end
    function survey:report(section, ok, reason)
        assert(pending == section, "The job reported a different room from the one it searched")
        pending, processed = nil, processed + 1
        if ok then searched = searched + 1
        else
            unsearched = unsearched + 1
            failures[#failures + 1] = {roomId = section.roomId, roomName = section.roomName,
                z = section.z, sections = 1, reason = reason}
        end
    end
    function survey:status()
        return {roomsTotal = #sections, roomsDone = processed, sectionsSearched = searched,
            sectionsUnsearched = unsearched, unsearchedRooms = failures, complete = self.complete}
    end
    f.survey = survey
    local input = {scope = "building", includeBags = true,
        filter = {all = true, ids = {}, types = {}}, destination = {kind = "container", ref = f.destination}}
    input.scope = "building"
    return input
end

local function request(kind, destination)
    return { scope = "room", includeBags = true, filter = { all = true, ids = {}, types = {} },
        destination = { kind = kind or "container", ref = destination } }
end

local function tick(f)
    f.now = f.now + 100
    for index = #f.scheduled, 1, -1 do
        if f.scheduled[index].at <= f.now then local event = table.remove(f.scheduled, index); event.run() end
    end
    f.jobs:tick()
end

local function finish(f)
    for _ = 1, 1000 do
        tick(f)
        local state = f.jobs:status().state
        if state ~= "running" and state ~= "cancelling" and state ~= "pausing" then return f.jobs:status() end
    end
    error("Job did not reach a terminal state")
end

local function awaitState(f, expected)
    for _ = 1, 1000 do
        tick(f)
        local status = f.jobs:status()
        if status.state == expected then return status end
        assert(status.state == "running" or status.state == "cancelling" or status.state == "pausing",
            "Job ended before reaching " .. expected .. ": " .. tostring(status.state) .. " / " .. tostring(status.reason))
    end
    error("Job did not reach " .. expected)
end

local function start(f, input)
    local plan, err = f.jobs:preview(input or request("container", f.destination))
    assert(plan, err)
    assert(f.jobs:start(plan))
    return plan
end

local function test(name, body)
    print("RUN " .. name)
    body()
    tests = tests + 1
    print("PASS " .. name)
end

local function awaitOperation(f, predicate)
    for _ = 1, 1000 do
        tick(f)
        if f.adapter.active and predicate(f.adapter.active.op) then return f.adapter.active.op end
        assert(f.jobs:status().state == "running", "The selected operation was never reached")
    end
    error("The selected operation did not start")
end

local function stopJob(f)
    assert(f.jobs:cancel())
    local stopped = finish(f)
    assert(stopped.state == "cancelled" and stopped.canResume, "A settled cancellation must retain a resumable checkpoint")
    return stopped
end

test("haul seven unit items in three capacity-limited trips", function()
    local f = fixture(3)
    for _ = 1, 7 do item(f.source) end
    start(f)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 7 and #f.source.items == 0 and #f.destination.items == 7)
    local deliveries = 0
    for _, location in ipairs(f.visits) do if location == "destination" then deliveries = deliveries + 1 end end
    assert(deliveries == 3, "Seven items with capacity three require three delivery trips")
    assert(#f.inventory.items == 0)
end)

test("fill carried capacity across separate source containers", function()
    local f = fixture(3)
    local second = container("second", 100)
    f.sources = { f.source, second }
    item(f.source); item(second); item(second)
    start(f)
    assert(finish(f).done == 3)
    local deliveries = 0
    for _, location in ipairs(f.visits) do if location == "destination" then deliveries = deliveries + 1 end end
    assert(deliveries == 1 and #f.destination.items == 3)
end)

test("multiplayer hauling follows recreated handles through several capacity-limited trips", function()
    local f = fixture(3); f.client, f.rehydrate = true, true
    local personal = item(f.inventory, "Base.Key", 1)
    local originals, identities = {}, {}
    for _ = 1, 5 do
        local selected = item(f.source)
        originals[#originals + 1], identities[selected.id] = selected, true
    end
    start(f)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 5 and status.skipped == 0 and status.carried == 0)
    assert(#f.source.items == 0 and #f.destination.items == 5 and f.inventory:contains(personal))
    local deliveries = 0
    for _, location in ipairs(f.visits) do if location == "destination" then deliveries = deliveries + 1 end end
    assert(deliveries == 3)
    for _, current in ipairs(f.destination.items) do
        assert(identities[current.id] and current:getContainer() == f.destination)
        identities[current.id] = nil
    end
    for _ in pairs(identities) do error("A hauled identity is missing from the final destination") end
    for _, original in ipairs(originals) do assert(original:getContainer() == nil and not f.destination:contains(original)) end
end)

test("a same-source packet refresh retains the reviewed item identity", function()
    local f = fixture(3); f.rehydrate = true
    local original = item(f.source, "Base.Selected")
    local plan = assert(f.jobs:preview(request("container", f.destination)))
    assert(remove(f.source.items, original)); original.container = nil
    local current = item(f.source, original.fullType, original.weight); current.id = original.id
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0)
    assert(#f.destination.items == 1 and f.destination.items[1].id == original.id)
    assert(not f.destination:contains(original) and not f.destination:contains(current))
end)

test("reviewed identities are never rebound in a different source container", function()
    local f = fixture(3)
    local original = item(f.source)
    local plan = assert(f.jobs:preview(request("container", f.destination)))
    assert(remove(f.source.items, original)); original.container = nil
    local elsewhere = container("elsewhere", 100)
    local current = item(elsewhere, original.fullType, original.weight); current.id = original.id
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.done == 0 and status.skipped == 1 and #f.transfers == 0 and elsewhere:contains(current))
end)

test("cancelling after a recreated pickup reports the item still carried", function()
    local f = fixture(3); f.rehydrate, f.holdTransferResult = true, true
    local original = item(f.source)
    start(f)
    for _ = 1, 30 do tick(f); if #f.transfers > 0 then break end end
    assert(#f.transfers == 1 and original:getContainer() == nil)
    assert(f.jobs:cancel())
    local status = finish(f)
    assert(status.state == "cancelled" and status.carried == 1 and f.restored)
    assert(#f.inventory.items == 1 and f.inventory.items[1].id == original.id)
    assert(#f.destination.items == 0 and #f.transfers == 1)
end)

test("preserve unrelated possessions and skip an uncarryable item", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Key", 1)
    local huge = item(f.source, "Base.Huge", 4)
    item(f.source); item(f.source)
    start(f)
    local status = finish(f)
    assert(status.done == 2 and status.skipped == 1 and f.inventory:contains(personal) and f.source:contains(huge))
    assert(#f.destination.items == 2)
end)

test("cleanup fills bins before deleting batches", function()
    local f = fixture(3)
    local bin = container("trash", 2); bin.trash = true; f.bins = { bin }
    item(bin, "Base.ExistingTrash")
    for _ = 1, 5 do item(f.source) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 5 and status.skipped == 0 and #f.source.items == 0 and #bin.items == 0)
    assert(#f.deletions == 3)
    for _, deletion in ipairs(f.deletions) do assert(deletion.count == 2) end
end)

test("cleanup approves recreated destination identities and empties whole batches", function()
    local f = fixture(3); f.client, f.rehydrate = true, true
    local bin = container("trash", 2); bin.trash = true; f.bins = { bin }
    for _ = 1, 5 do item(f.source) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 5 and status.skipped == 0 and #f.source.items == 0 and #bin.items == 0)
    assert(#f.deletions == 3 and f.deletions[1].count == 2 and f.deletions[2].count == 2 and f.deletions[3].count == 1)
end)

test("choose a fitting larger bin without emptying an unused undersized bin", function()
    local f = fixture(10)
    local small, large = container("small trash", 2), container("large trash", 4)
    small.trash, large.trash = true, true; f.bins = { small, large }
    local retained = item(small, "Base.ExistingTrash")
    item(f.source, "Base.Heavy", 3)
    start(f, request("trash"))
    assert(finish(f).done == 1)
    assert(#f.deletions == 1 and f.deletions[1].bin == large and f.deletions[1].count == 1)
    assert(small:contains(retained), "Capacity planning must not delete contents of an unused bin")
end)

test("newly protected bin contents stop whole-bin deletion", function()
    local f = fixture(3)
    local bin = container("trash", 2); bin.trash = true; f.bins = { bin }
    local existing = item(bin, "Base.ExistingTrash")
    item(f.source); item(f.source)
    f.onTransfer = function(op) if op.destination == bin then existing.protected = true end end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.skipped > 0 and #f.deletions == 0 and bin:contains(existing))
end)

test("reviewed requests resist later UI mutation", function()
    local f = fixture(3)
    local selected = item(f.source, "Base.Selected")
    local other = item(f.source, "Base.Other")
    local input = request("container", f.destination)
    input.filter = { all = false, ids = {}, types = { "Base.Selected" } }
    local plan = assert(f.jobs:preview(input))
    input.filter.types[1] = "Base.Other"
    plan.request.filter.types[1] = "Base.Other"
    plan.request.destination.ref = container("unreviewed destination", 100)
    assert(f.jobs:start(plan))
    assert(finish(f).done == 1 and f.destination:contains(selected) and f.source:contains(other))
    assert(not f.jobs:start(plan), "A consumed preview must not replay")
end)

test("observe nonempty MP replies without a Lua update event", function()
    local f = fixture(3); f.client = true; f.source.explored = false
    f.onApproach = function(op) if op.container == f.source then f.source.explored = true end end
    f.source.reply = function() item(f.source); item(f.source) end
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.done == 2 and #f.inventory.items == 2 and f.source.requested == 1)
    assert(status.unconfirmedSources == 1 and status.state == "finished_with_skips")
end)

test("empty MP replies remain explicitly unconfirmed", function()
    local f = fixture(3); f.client = true; f.source.explored = false
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.done == 0 and status.skipped == 1 and status.unconfirmedSources == 1)
    assert(status.state == "finished_with_skips" and status.reason:find("unconfirmed", 1, true))
end)

test("floor inspection excludes adjacent unselected squares", function()
    local f = fixture(3); f.onlyGround = true; f.sources = {}
    local selectedSquare, adjacent = f:addSquare(square("selected floor", 20, 0)), f:addSquare(square("adjacent floor", 21, 0))
    f.groundSquares = { selectedSquare }
    local selected = item(f.floor, "Base.Selected")
    local other = item(f.floor, "Base.Adjacent")
    selected.world = { getSquare = function() return selectedSquare end }
    other.world = { getSquare = function() return adjacent end }
    f.ground = { selected, other }
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.done == 1 and f.inventory:contains(selected) and #f.ground == 1 and f.ground[1] == other)
end)

test("floor destination remains pinned after walking to sources", function()
    local f = fixture(3)
    local destination = f:addSquare(square("chosen floor", 20, 0))
    local selected = item(f.source)
    start(f, request("floor", destination))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1)
    assert(selected.world and selected.world:getSquare() == destination)
end)

test("floor items can move between squares sharing one native floor view", function()
    local f = fixture(3); f.sources = { f.floor }
    local origin, destination = f:addSquare(square("origin floor", 20, 0)), f:addSquare(square("destination floor", 30, 0))
    local selected = item(f.floor)
    selected.world = { getSquare = function() return origin end }
    f.ground = { selected }
    start(f, request("floor", destination))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1)
    assert(selected.world and selected.world:getSquare() == destination and #f.ground == 1)
end)

test("adjacent floor destinations require standing on the chosen square", function()
    local f = fixture(3); f.sources = { f.inventory }; f.position = "origin floor"
    local origin, destination = f:addSquare(square("origin floor", 20, 0)), f:addSquare(square("adjacent destination", 21, 0))
    f.nearby[origin.name] = { [destination.name] = true }
    local selected = item(f.inventory)
    start(f, request("floor", destination))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1)
    assert(selected.world and selected.world:getSquare() == destination)
end)

test("labeled scope keeps its reviewed source-label selection", function()
    local f = fixture(3)
    f.source.labels = { ["native:Junk"] = true }
    local selected = item(f.source)
    local foodContainer = container("food", 100)
    foodContainer.labels = { ["native:Food"] = true }
    local other = item(foodContainer)
    f.sources = { f.source, foodContainer }
    local input = request("container", f.destination)
    input.scope, input.sourceLabels = "labeled", { "native:Junk" }
    local plan = assert(f.jobs:preview(input))
    assert(f.scannedRequest.sourceLabels[1] == "native:Junk")
    input.sourceLabels[1] = "native:Food"
    plan.request.sourceLabels[1] = "native:Food"
    assert(f.jobs:start(plan))
    assert(finish(f).done == 1 and f.destination:contains(selected) and foodContainer:contains(other))
end)

test("malformed selection lists fail before starting a job", function()
    local f = fixture(3)
    local input = request("container", f.destination)
    input.filter.ids = "native:Material"
    local plan, problem = f.jobs:preview(input)
    assert(plan == nil and type(problem) == "string" and #f.transfers == 0)
end)

test("cancel waits for native restoration before ending", function()
    local f = fixture(3); f.sources = { f.inventory }
    item(f.inventory)
    start(f, request("vehicle", {}))
    for _ = 1, 20 do tick(f); if f.adapter:isBusy() then break end end
    assert(f.adapter:isBusy())
    assert(f.jobs:cancel() and f.jobs:status().state == "cancelling")
    tick(f)
    assert(f.jobs:status().state == "cancelling" and not f.restored)
    assert(finish(f).state == "cancelled" and f.restored and not f.adapter:isBusy())
end)

test("exception waits for native restoration and stays failed", function()
    local f = fixture(3); f.sources = { f.inventory }; f.throwPoll = true
    item(f.inventory)
    start(f, request("vehicle", {}))
    local status = finish(f)
    assert(status.state == "failed" and f.restored and not f.adapter:isBusy())
    assert(f.thrown and status.reason:find("Job execution failed", 1, true))
end)

test("building jobs search both floors and finish all selected transfers", function()
    local f = fixture(2)
    local upstairs, downstairs = container("upstairs", 100), container("downstairs", 100)
    f:addSquare(square("upstairs", 0, 0, 1)); f:addSquare(square("downstairs", 0, 0, 0))
    item(upstairs); item(upstairs); item(downstairs); item(downstairs)
    local input = building(f, {
        {roomId = "upper", roomName = "Upper bedroom", z = 1, target = square("upper section", 1, 0, 1), sources = {upstairs}},
        {roomId = "lower", roomName = "Lower hall", z = 0, target = square("lower section", 1, 0, 0), sources = {downstairs}},
    })
    local plan = start(f, input)
    assert(plan.building.roomsTotal == 2 and #plan.moves == 0 and plan.pending == 2)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 4 and #f.destination.items == 4)
    assert(status.survey.roomsDone == 2 and status.survey.sectionsSearched == 2 and status.survey.sectionsUnsearched == 0)
    assert(f.approaches.upstairs and f.approaches.downstairs)
end)

test("an unloaded building section is walked to and inspected after streaming", function()
    local f = fixture(2)
    local remote = container("remote upstairs", 100)
    f:addSquare(square(remote.position, 40, 0, 1)); item(remote)
    local section = {roomId = "remote", roomName = "Remote bedroom", z = 1,
        target = square("remote section", 41, 0, 1), sources = {remote}}
    local input = building(f, {section})
    f.unloaded[section.target.name] = true
    start(f, input)
    local status = finish(f)
    assert(status.done == 1 and #f.destination.items == 1 and status.survey.sectionsSearched == 1)
    assert(f.approaches[section.target.name] == 1 and not f.unloaded[section.target.name])
end)

test("metadata yielding leaves building jobs cancellable before movement", function()
    local f = fixture(2)
    local input = building(f, {{roomId = "one", roomName = "Room", z = 0,
        target = square("section", 1, 0), sources = {f.source}}}, 100)
    item(f.source)
    start(f, input)
    for _ = 1, 20 do tick(f) end
    assert(f.jobs:status().state == "running" and #f.operations == 0)
    assert(f.jobs:cancel())
    local status = finish(f)
    assert(status.state == "cancelled" and status.done == 0 and #f.source.items == 1)
end)

test("cancelling a building approach waits for native cleanup without searching the room", function()
    local f = fixture(2)
    local section = {roomId = "remote", roomName = "Unloaded room", z = 1,
        target = square("walking to section", 40, 0, 1), sources = {f.source}}
    local input = building(f, {section})
    f.unloaded[section.target.name] = true
    item(f.source)
    start(f, input)
    for _ = 1, 30 do tick(f); if f.adapter:isBusy() then break end end
    assert(f.adapter:isBusy() and f.jobs:cancel())
    tick(f)
    assert(f.jobs:status().state == "cancelling" and not f.restored)
    local status = finish(f)
    assert(status.state == "cancelled" and f.restored and not f.adapter:isBusy())
    assert(status.survey.sectionsSearched == 0 and status.done == 0 and #f.transfers == 0)
end)

test("upstairs building cleanup returns between an outside bin and the selected floor", function()
    local f = fixture(1); f.onlyGround, f.sources = true, {}
    local upper = f:addSquare(square("upper floor items", 20, 0, 1))
    local bin = container("outside ground bin", 3); bin.trash, f.bins = true, {bin}
    f:addSquare(square(bin.position, 10, 0, 0))
    for _ = 1, 4 do
        local selected = item(f.floor)
        selected.world = {getSquare = function() return upper end}
        f.ground[#f.ground + 1] = selected
    end
    local input = building(f, {
        {roomId = "upper", roomName = "Upper bedroom", z = 1, target = upper, groundSquares = {upper}},
        {roomId = "lower", roomName = "Ground hall", z = 0, target = square("lower room", 1, 0, 0)},
    })
    input.destination = {kind = "trash"}
    start(f, input)
    local status = finish(f)
    local upperVisits, outsideVisits = 0, 0
    for _, name in ipairs(f.visits) do
        if name == upper.name then upperVisits = upperVisits + 1 end
        if name == bin.position then outsideVisits = outsideVisits + 1 end
    end
    assert(status.state == "finished" and status.done == 4 and status.skipped == 0)
    assert(upperVisits == 4 and outsideVisits == 4, "Capacity one requires four actual upstairs/outside deliveries")
    assert(#f.ground == 0 and #bin.items == 0 and #f.deletions == 2)
    assert(status.survey.roomsDone == 2 and status.survey.sectionsSearched == 2)
end)

test("a blocked building section remains unsearched while reachable rooms continue", function()
    local f = fixture(2)
    local blocked = {roomId = "blocked", roomName = "Blocked attic", z = 1,
        target = square("blocked section", 40, 0, 1), sources = {f.source}}
    local healthy = container("healthy", 100); f:addSquare(square(healthy.position, 1, 0)); item(healthy)
    local input = building(f, {blocked, {roomId = "healthy", roomName = "Hall", z = 0,
        target = square("healthy section", 2, 0), sources = {healthy}}})
    f.unloaded[blocked.target.name], f.blockedPositions[blocked.target.name] = true, true
    start(f, input)
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 1)
    assert(status.survey.roomsDone == 2 and status.survey.sectionsSearched == 1 and status.survey.sectionsUnsearched == 1)
    assert(status.survey.unsearchedRooms[1].roomName == "Blocked attic" and status.survey.unsearchedRooms[1].z == 1)
end)

test("permission-denied room portions are not counted as fully searched", function()
    local f = fixture(2)
    local selected = item(f.source)
    local input = building(f, {{roomId = "partial", roomName = "Partly accessible room", z = 0,
        target = square("partial section", 1, 0), sources = {f.source}, denied = 1}})
    start(f, input)
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 1 and f.destination:contains(selected))
    assert(status.survey.sectionsSearched == 0 and status.survey.sectionsUnsearched == 1)
end)

test("accessible closet storage does not require standing in an obstructed center", function()
    local f = fixture(2)
    local closet = container("hall beside closet", 100)
    f:addSquare(square(closet.position, 1, 0)); local selected = item(closet)
    local section = {roomId = "closet", roomName = "Storage closet", z = 0,
        target = square("obstructed closet center", 2, 0), sources = {closet}}
    local input = building(f, {section})
    f.blockedPositions[section.target.name] = true
    start(f, input)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and f.destination:contains(selected))
    assert(not f.approaches[section.target.name])
end)

test("capacity-limited return trips reacquire a recreated source container", function()
    local f = fixture(2)
    local original = f.source
    for _ = 1, 5 do item(original) end
    local unloaded, fresh
    f.onTransfer = function(op)
        if op.destination == f.destination and not unloaded then f.unloaded.source, unloaded = true, true end
    end
    f.onWalk = function(_, target)
        if target == "source" and not fresh then
            fresh = container("source", 100)
            for _, old in ipairs(original.items) do
                local current = item(fresh, old.fullType, old.weight); current.id = old.id; old.container = nil
            end
            original.items = {}
            f.sourceLocations.source, f.sources[1], f.source = fresh, fresh, fresh
        end
    end
    start(f)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 5 and status.skipped == 0 and fresh)
    assert(#fresh.items == 0 and #f.destination.items == 5 and #f.inventory.items == 0)
end)

test("reloaded source items must retain the reviewed type as well as identity", function()
    local f = fixture(1)
    item(f.source, "Base.Selected"); local remaining = item(f.source, "Base.Selected")
    local original, fresh = f.source
    f.onTransfer = function(op) if op.destination == f.destination then f.unloaded.source = true end end
    f.onWalk = function(_, target)
        if target == "source" and not fresh then
            fresh = container("source", 100)
            local changed = item(fresh, "Base.Different"); changed.id = remaining.id
            remaining.container, original.items = nil, {}
            f.sourceLocations.source, f.source = fresh, fresh
        end
    end
    start(f)
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 1 and #fresh.items == 1 and #f.destination.items == 1)
end)

test("floor hauling reacquires the selected XYZ after its chunk is recreated", function()
    local f = fixture(1); f.onlyGround, f.sources = true, {}
    local oldSquare = f:addSquare(square("upstairs floor", 20, 0, 1))
    f.groundSquares = {oldSquare}
    for _ = 1, 3 do
        local selected = item(f.floor)
        selected.world = {getSquare = function() return oldSquare end}
        f.ground[#f.ground + 1] = selected
    end
    local freshSquare, unloaded
    f.onTransfer = function(op)
        if op.destination == f.destination and not unloaded then f.unloaded[oldSquare.name], unloaded = true, true end
    end
    f.onWalk = function(_, target)
        if target == oldSquare.name and unloaded and not freshSquare then
            freshSquare = f:addSquare(square(oldSquare.name, 20, 0, 1))
            local freshGround = {}
            for _, old in ipairs(f.ground) do
                local current = item(f.floor, old.fullType, old.weight); current.id = old.id
                current.world = {getSquare = function() return freshSquare end}
                freshGround[#freshGround + 1], old.container = current, nil
            end
            f.ground = freshGround
        end
    end
    start(f)
    local status = finish(f)
    assert(status.done == 3 and status.skipped == 0 and freshSquare and #f.ground == 0)
    assert(#f.destination.items == 3 and #f.inventory.items == 0)
end)

test("cleanup chooses a farther larger bin when fewer emptyings outweigh travel", function()
    local f = fixture(6)
    local near, large = container("near small", 1), container("farther large", 6)
    near.trash, large.trash, f.bins = true, true, {near, large}
    f:addSquare(square(near.position, 0, 0)); f:addSquare(square(large.position, 1, 0))
    for _ = 1, 6 do item(f.source) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 6 and status.skipped == 0 and #f.deletions == 1 and f.deletions[1].bin == large)
    assert(f.deletions[1].count == 6 and not f.approaches[near.position])
end)

test("cleanup keeps the nearer bin when larger capacity saves no emptying", function()
    local f = fixture(3)
    local near, far = container("near adequate", 6), container("far huge", 60)
    near.trash, far.trash, f.bins = true, true, {near, far}
    f:addSquare(square(near.position, 1, 0)); f:addSquare(square(far.position, 20, 0))
    for _ = 1, 3 do item(f.source) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 3 and #f.deletions == 1 and f.deletions[1].bin == near and not f.approaches[far.position])
end)

test("cleanup keeps using a touched bin when switching still owes its final emptying", function()
    local f = fixture(9)
    local near, large = container("near touched bin", 10), container("larger alternative", 20)
    near.trash, large.trash, f.bins = true, true, {near, large}
    f:addSquare(square(near.position, 1, 0)); f:addSquare(square(large.position, 2, 0))
    for _ = 1, 5 do item(f.source, "Base.Plank", 3) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 5 and status.skipped == 0 and status.carried == 0)
    local delivered = 0
    for _, transfer in ipairs(f.transfers) do
        if transfer.destination ~= f.inventory then
            assert(transfer.destination == near, "The last two planks must account for cleanup still owed to the first bin")
            delivered = delivered + 1
        end
    end
    assert(delivered == 5 and not f.approaches[large.position])
    assert(#f.deletions == 2 and f.deletions[1].bin == near and f.deletions[1].count == 3
        and f.deletions[2].bin == near and f.deletions[2].count == 2,
        "The ten-unit bin must empty its first nine-unit load before accepting the final six units")
    assert(#f.source.items == 0 and #near.items == 0 and #large.items == 0 and #f.inventory.items == 0)
end)

test("a selected full bin is emptied before the next item is deposited", function()
    local f = fixture(3)
    local bin = container("full chosen bin", 3); bin.trash, f.bins = true, {bin}
    local existing = item(bin, "Base.Existing", 3)
    item(f.source, "Base.Selected", 2)
    f.onTransfer = function(op)
        if op.destination == bin then assert(not bin:contains(existing), "Chosen full bin must be emptied before deposit") end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and #f.deletions == 2 and f.deletions[1].count == 1 and f.deletions[2].count == 1)
end)

test("failed bin routes are not repeated from the same hauling origin", function()
    local f = fixture(1)
    local blocked, reachable = container("blocked bin", 10), container("reachable bin", 10)
    blocked.trash, reachable.trash, f.bins = true, true, {blocked, reachable}
    f:addSquare(square(blocked.position, 1, 0)); f:addSquare(square(reachable.position, 2, 0))
    f.blockedPositions[blocked.position] = true
    for _ = 1, 3 do item(f.source) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 3 and status.skipped == 0 and f.approaches[blocked.position] == 1)
    assert(#f.deletions == 1 and f.deletions[1].bin == reachable and f.deletions[1].count == 3)
end)

test("remembered unloaded bins are inspected before any source pickup", function()
    local f = fixture(2)
    local bin = container("remembered bin", 4); bin.trash = true
    f:addSquare(square(bin.position, 20, 0)); f.unloaded[bin.position] = true; f.unloadedBins = {bin}
    local unseen = item(bin, "Base.Unseen")
    local selected = item(f.source)
    start(f, request("trash"))
    local status = awaitState(f, "needs_review")
    assert(status.done == 0 and status.carried == 0 and f.approaches[bin.position])
    assert(f.source:contains(selected) and bin:contains(unseen) and #f.transfers == 0 and #f.deletions == 0)
    local review = assert(f.jobs:reviewBin())
    assert(review.canApprove and #review.moves == 1 and review.moves[1].itemName == "Base.Unseen")
    assert(f.jobs:rejectBin(review))
    assert(finish(f).state == "finished_with_skips" and f.source:contains(selected) and bin:contains(unseen))
end)

test("an empty remembered bin accepts cleanup only after a fresh explicit review", function()
    local f = fixture(2)
    local bin = container("remembered empty bin", 4); bin.trash = true
    f:addSquare(square(bin.position, 20, 0)); f.unloaded[bin.position] = true; f.unloadedBins = {bin}
    item(f.source); item(f.source)
    start(f, request("trash"))
    local paused = awaitState(f, "needs_review")
    assert(paused.done == 0 and #f.transfers == 0 and #f.deletions == 0)
    local review = assert(f.jobs:reviewBin())
    assert(review.canApprove and #review.moves == 0 and #review.skipped == 0)
    assert(f.jobs:approveBin(review))
    local status = finish(f)
    assert(status.done == 2 and status.skipped == 0 and #f.deletions == 1 and f.deletions[1].bin == bin)
end)

test("a recreated bin is resolved before depositing or deleting", function()
    local f = fixture(2)
    local original = container("reloaded bin", 4); original.trash, f.bins = true, {original}
    f:addSquare(square(original.position, 20, 0))
    local selected = item(f.source)
    local fresh
    f.onTransfer = function(op) if op.destination == f.inventory then f.unloaded[original.position] = true end end
    f.onWalk = function(_, target)
        if target == original.position and not fresh then
            fresh = container(original.name, 4); fresh.trash = true
            f.binLocations[original.name], f.bins[1] = fresh, fresh
        end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and fresh and selected:getContainer() == nil)
    assert(#f.deletions == 1 and f.deletions[1].bin == fresh and #original.items == 0)
end)

test("new unapproved bin contents are never deleted during cleanup", function()
    local f = fixture(2)
    local bin = container("changing bin", 2); bin.trash, f.bins = true, {bin}
    for _ = 1, 2 do item(f.source) end
    local outsider
    f.onTransfer = function(op)
        if op.destination == bin and not outsider then outsider = item(bin, "Base.Unapproved") end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.skipped > 0 and outsider and bin:contains(outsider))
    assert(#f.deletions == 0, "Whole-bin deletion cannot include a newly unapproved item")
end)

test("completed native walks improve later bin choices beyond straight-line proximity", function()
    local f = fixture(1)
    local near, farther = container("near with detour", 10), container("farther direct", 10)
    near.trash, farther.trash, f.bins = true, true, {near}
    f:addSquare(square(near.position, 4, 0)); f:addSquare(square(farther.position, 8, 0))
    f.observeTravel = function(from, to)
        if from.x == 0 and to.x == 4 then return 14, 10000 end
        return math.abs(from.x - to.x), math.abs(from.x - to.x) * 1000
    end
    item(f.source)
    start(f, request("trash"))
    assert(finish(f).done == 1 and f.deletions[1].bin == near)
    f.position, f.bins = "source", {near, farther}
    item(f.source)
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and #f.deletions == 2)
    assert(f.deletions[2].bin == farther, "An observed detour can make the farther direct bin cheaper")
end)

test("a newly discovered nonempty bin pauses without expanding the cleanup approval", function()
    local f = fixture(2)
    local blocked, unknown = container("original bin", 2), container("new nonempty bin", 10)
    blocked.trash, unknown.trash, f.bins = true, true, {blocked}
    f:addSquare(square(blocked.position, 1, 0)); f:addSquare(square(unknown.position, 2, 0))
    local retained = item(unknown, "Base.UnseenExisting")
    item(f.source)
    f.onTransfer = function(op)
        if op.destination == f.inventory then
            f.bins = {blocked, unknown}
            f.blockedPositions[blocked.position] = true
        end
    end
    start(f, request("trash"))
    local status = awaitState(f, "needs_review")
    assert(status.done == 0 and status.carried == 1)
    assert(unknown:contains(retained) and #unknown.items == 1 and #f.deletions == 0)
    local review = assert(f.jobs:reviewBin())
    assert(#review.moves == 1 and review.moves[1].itemName == "Base.UnseenExisting")
    assert(f.jobs:rejectBin(review))
    local ended = finish(f)
    assert(ended.state == "finished_with_skips" and ended.carried == 1 and #f.deletions == 0)
end)

test("a newly discovered empty bin can replace an inaccessible bin after explicit approval", function()
    local f = fixture(2)
    local blocked, fresh = container("original inaccessible bin", 2), container("new empty bin", 10)
    blocked.trash, fresh.trash, f.bins = true, true, {blocked}
    f:addSquare(square(blocked.position, 1, 0)); f:addSquare(square(fresh.position, 2, 0))
    local selected = item(f.source)
    f.onTransfer = function(op)
        if op.destination == f.inventory then
            f.bins = {blocked, fresh}
            f.blockedPositions[blocked.position] = true
        end
    end
    start(f, request("trash"))
    local paused = awaitState(f, "needs_review")
    assert(paused.done == 0 and paused.carried == 1 and f.inventory:contains(selected))
    assert(#f.transfers == 1 and #f.deletions == 0)
    local review = assert(f.jobs:reviewBin())
    assert(review.canApprove and #review.moves == 0)
    assert(f.jobs:approveBin(review))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and status.carried == 0)
    assert(#f.deletions == 1 and f.deletions[1].bin == fresh and f.deletions[1].count == 1)
    assert(#f.transfers == 2, "Approving a destination must continue the carried item instead of picking it up again")
end)

test("a loaded uninspected bin pauses before collecting any source items", function()
    local f = fixture(2)
    local bin = container("uninspected loaded bin", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    f:addSquare(square(bin.position, 10, 0))
    local selected = item(f.source)
    start(f, request("trash"))
    local paused = awaitState(f, "needs_review")
    assert(paused.done == 0 and paused.carried == 0 and f.source:contains(selected))
    assert(f.approaches[bin.position] and f.inspectedBins[bin.name])
    local review = assert(f.jobs:reviewBin())
    for _ = 1, 120 do tick(f) end
    assert(f.jobs:status().state == "needs_review" and #f.transfers == 0 and #f.deletions == 0)
    assert(f.jobs:approveBin(review))
    assert(finish(f).done == 1 and #f.deletions == 1)
end)

test("approving a bin preserves the building survey and original item selection", function()
    local f = fixture(1)
    local bin = container("outside uninspected bin", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    f:addSquare(square(bin.position, 10, 0))
    local upper, lower = container("upper source", 100), container("lower source", 100)
    f:addSquare(square(upper.position, 20, 0, 1)); f:addSquare(square(lower.position, 20, 0, 0))
    item(upper, "Base.Selected"); item(lower, "Base.Selected")
    local retained = item(upper, "Base.Other")
    local input = building(f, {
        {roomId = "upper", roomName = "Upper bedroom", z = 1, target = square("upper selected section", 21, 0, 1), sources = {upper}},
        {roomId = "lower", roomName = "Lower hall", z = 0, target = square("lower selected section", 21, 0, 0), sources = {lower}},
    })
    input.filter, input.destination = {all = false, ids = {}, types = {"Base.Selected"}}, {kind = "trash"}
    local plan = start(f, input)
    local paused = awaitState(f, "needs_review")
    assert(paused.survey.roomsDone == 0 and paused.survey.roomsTotal == 2 and #f.transfers == 0)
    input.filter.types[1], plan.request.filter.types[1] = "Base.Other", "Base.Other"
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 2 and status.skipped == 0)
    assert(status.survey.roomsDone == 2 and status.survey.sectionsSearched == 2)
    assert(upper:contains(retained) and #upper.items == 1 and #lower.items == 0)
    assert(#f.inventory.items == 0 and #bin.items == 0)
end)

test("public bin review mutation cannot approve contents added after the snapshot", function()
    local f = fixture(2)
    local bin = container("reviewed destination", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    local added = item(bin, "Base.NewUnapproved")
    review.moves[1], review.canApprove = {itemName = added.fullType, from = "Bin", to = "Delete"}, true
    assert(not f.jobs:approveBin(review))
    assert(f.jobs:status().state == "needs_review" and f.source:contains(selected) and bin:contains(added))
    assert(#f.transfers == 0 and #f.deletions == 0)
    local fresh = assert(f.jobs:reviewBin())
    assert(#fresh.moves == 1 and fresh.moves[1].itemName == added.fullType)
    assert(not f.jobs:approveBin(review) and not f.jobs:rejectBin(review), "Refreshing review invalidates its older token")
    assert(f.jobs:cancel() and finish(f).state == "cancelled")
    assert(bin:contains(added) and f.source:contains(selected))
end)

test("protected existing contents remain blocked even if the public review is altered", function()
    local f = fixture(2)
    local bin = container("protected uninspected bin", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local kept = item(bin, "Base.Kept"); kept.protected = true
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(not review.canApprove and #review.skipped == 1 and #review.moves == 0)
    review.canApprove, review.skipped = true, {}
    assert(not f.jobs:approveBin(review))
    assert(f.jobs:status().state == "needs_review" and #f.transfers == 0 and #f.deletions == 0)
    assert(f.jobs:rejectBin(review))
    assert(finish(f).state == "finished_with_skips" and bin:contains(kept) and f.source:contains(selected))
end)

test("contents that become protected after review require another decision", function()
    local f = fixture(2)
    local bin = container("changing protected review", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local existing = item(bin, "Base.Existing")
    item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(review.canApprove and #review.moves == 1)
    existing.protected = true
    assert(not f.jobs:approveBin(review))
    local fresh = assert(f.jobs:reviewBin())
    assert(not fresh.canApprove and #fresh.skipped == 1)
    assert(f.jobs:cancel() and finish(f).state == "cancelled")
    assert(bin:contains(existing) and #f.transfers == 0 and #f.deletions == 0)
end)

test("rejecting a reviewed bin inspects another without discarding source selection", function()
    local f = fixture(2)
    local first, second = container("first uninspected bin", 4), container("second uninspected bin", 4)
    first.trash, second.trash, first.uninspected, second.uninspected = true, true, true, true
    f.bins = {first, second}
    f:addSquare(square(first.position, 10, 0)); f:addSquare(square(second.position, 20, 0))
    local retained = item(first, "Base.ExistingFirst")
    item(f.source, "Base.Selected")
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local declined = assert(f.jobs:reviewBin())
    assert(declined.bin.name == first.name and #f.transfers == 0)
    assert(f.jobs:rejectBin(declined))
    awaitState(f, "needs_review")
    local accepted = assert(f.jobs:reviewBin())
    assert(accepted.bin.name == second.name and accepted.canApprove and #f.transfers == 0)
    assert(f.jobs:approveBin(accepted))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 1 and first:contains(retained))
    assert(#f.deletions == 1 and f.deletions[1].bin == second)
    assert(f.approaches[first.position] == 1, "The rejected bin must not be selected again by the current job")
end)

test("moving away from the bin blocks approval without losing the paused job", function()
    local f = fixture(2)
    local bin = container("reachable review bin", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    f.position = "source"
    assert(not f.jobs:approveBin(review))
    assert(f.jobs:status().state == "needs_review" and f.source:contains(selected) and #f.deletions == 0)
    f.position = bin.position
    assert(f.jobs:approveBin(review))
    assert(finish(f).done == 1)
end)

test("cancelling a paused review invalidates its approval and rejection tokens", function()
    local f = fixture(2)
    local bin = container("cancelled review bin", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(f.jobs:cancel() and f.jobs:status().state == "cancelling")
    assert(not f.jobs:approveBin(review) and not f.jobs:rejectBin(review))
    assert(finish(f).state == "cancelled")
    assert(not f.jobs:reviewBin() and not f.jobs:approveBin(review) and not f.jobs:rejectBin(review))
    assert(f.source:contains(selected) and #f.transfers == 0 and #f.deletions == 0)
end)

test("waiting for an empty multiplayer inspection never substitutes for explicit approval", function()
    local f = fixture(2); f.client = true
    local bin = container("unconfirmed multiplayer bin", 4)
    bin.trash, bin.uninspected, bin.explored, f.bins = true, true, false, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    for _ = 1, 30 do tick(f); if bin.requested then break end end
    assert(bin.requested == 1 and not bin.explored and f.jobs:status().state == "running")
    for _ = 1, 10 do tick(f) end
    assert(f.jobs:status().state == "running" and #f.transfers == 0)
    awaitState(f, "needs_review")
    assert(f.now - bin.lastRequestAt >= 3000 and not bin.explored)
    local review = assert(f.jobs:reviewBin())
    local uncertainty = false
    for _, warning in ipairs(review.warnings) do
        if warning:find("Empty replies", 1, true) and warning:find("not acknowledged", 1, true) then uncertainty = true end
    end
    assert(uncertainty and #review.moves == 0 and review.canApprove)
    for _ = 1, 60 do tick(f) end
    assert(f.jobs:status().state == "needs_review" and f.source:contains(selected))
    assert(#f.transfers == 0 and #f.deletions == 0)
    assert(f.jobs:cancel() and finish(f).state == "cancelled")
end)

test("a custom eleven-weight hard limit forces four trips", function()
    local f = fixture(50)
    f.hardLimit = 11
    local gear = item(f.inventory, "Base.PersonalGear", 3)
    for _ = 1, 8 do item(f.source, "Base.Plank", 3) end
    local peak, pickups = 0, 0
    f.onTransfer = function(op)
        local mass = f.world:carrying()
        peak = math.max(peak, mass)
        if not op.source.owned and op.destination.owned then
            pickups = pickups + 1
            assert(mass <= 11, "Automatic pickup exceeded the native hard character limit")
        end
    end
    start(f)
    local status = finish(f)
    assert(status.done == 8 and status.skipped == 0 and pickups == 8)
    assert(peak == 9 and f.inventory:contains(gear) and #f.inventory.items == 1)
    local trips = 0
    for _, name in ipairs(f.visits) do if name == f.destination.position then trips = trips + 1 end end
    assert(trips == 4, "Three weight of gear leaves room for two three-weight planks per hard-cap trip")
end)

test("a weighted carried bag admits an item that cannot fit the character limit at full weight", function()
    local f = fixture(50)
    f.hardLimit = 11
    item(f.inventory, "Base.PersonalGear", 3)
    local backpack = f:carryContainer(container("equipped backpack", 50), 0.2)
    local selected = item(f.source, "Base.HeavySupply", 20)
    function f.world:destinations(input)
        if input.destination.kind == "inventory" then return {f.inventory, backpack} end
        return {f.destination}
    end
    local input = request("inventory")
    local plan = start(f, input)
    assert(#plan.moves == 1 and #plan.skipped == 0)
    local status = finish(f)
    local mass = f.world:carrying()
    assert(status.done == 1 and backpack:contains(selected) and not f.inventory:contains(selected))
    assert(mass == 7, "Three weight of gear plus twenty weight reduced by eighty percent is seven")
end)

test("preview reserves one character mass allowance across different carried bags", function()
    local f = fixture(50)
    f.hardLimit = 3
    local first = f:carryContainer(container("first pouch", 2), 1)
    local second = f:carryContainer(container("second pouch", 2), 1)
    item(f.source, "Base.First", 2); item(f.source, "Base.Second", 2)
    function f.world:destinations(input)
        if input.destination.kind == "inventory" then return {first, second} end
        return {f.destination}
    end
    local plan = start(f, request("inventory"))
    assert(#plan.moves == 1 and #plan.skipped == 1, "Separate bag capacities must not create separate character limits")
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 1 and #f.source.items == 1)
    local mass = f.world:carrying()
    assert(mass == 2 and #first.items + #second.items == 1)
end)

test("weight-reducing carried rearrangement remains allowed while already overloaded", function()
    local f = fixture(50)
    f.hardLimit = 5
    local selected = item(f.inventory, "Base.Selected", 8)
    local retained = item(f.inventory, "Base.PersonalGear", 2)
    local backpack = f:carryContainer(container("reducing backpack", 50), 0.25)
    f.sources = {f.inventory}
    local input = request("container", backpack)
    input.scope, input.filter = "inventory", {all = false, ids = {}, types = {"Base.Selected"}}
    start(f, input)
    local status = finish(f)
    local mass = f.world:carrying()
    assert(status.done == 1 and status.skipped == 0 and backpack:contains(selected))
    assert(f.inventory:contains(retained) and mass == 4, "Moving eight weight into a seventy-five-percent reducing bag lowers ten to four")
end)

test("a changed hard limit is checked before the next pickup", function()
    local f = fixture(50)
    f.hardLimit = 11
    item(f.inventory, "Base.PersonalGear", 3)
    for _ = 1, 3 do item(f.source, "Base.Plank", 3) end
    local picked = 0
    f.onTransfer = function(op)
        if not op.source.owned and op.destination.owned then
            picked = picked + 1
            if picked == 1 then f.hardLimit = 5 end
        elseif op.source.owned and not op.destination.owned then f.hardLimit = 11 end
    end
    start(f)
    local status = finish(f)
    assert(status.done == 3 and status.skipped == 0)
    assert(f.transfers[1].destination == f.inventory and f.transfers[2].destination == f.destination,
        "A lower limit after the first pickup must cause delivery before another pickup")
end)

test("an item beyond native hard carrying capacity stays at its source with a reason", function()
    local f = fixture(50)
    f.hardLimit = 11
    local retained = item(f.inventory, "Base.PersonalGear", 3)
    local heavy = item(f.source, "Base.Oversized", 9)
    local plan = start(f, request("inventory"))
    assert(#plan.moves == 0 and #plan.skipped == 1 and type(plan.skipped[1].reason) == "string"
        and #plan.skipped[1].reason > 0)
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 0 and status.skipped == 1)
    assert(f.source:contains(heavy) and f.inventory:contains(retained) and #f.transfers == 0)
end)

test("over-comfort pickups reach the exact native hard boundary without exceeding it", function()
    for _, hardLimit in ipairs({50, 75}) do
        local f = fixture(hardLimit)
        local retained = item(f.inventory, "Base.PersonalGear", 14)
        local fitting = item(f.source, "Base.FittingSupply", hardLimit - 14)
        local excess = item(f.source, "Base.OneMoreNail", 0.05)
        local plan = start(f, request("inventory"))
        assert(#plan.moves == 1 and #plan.skipped == 1,
            "The comfort threshold must not consume the remaining native hard allowance")
        local status = finish(f)
        local mass = f.world:carrying()
        assert(status.done == 1 and status.skipped == 1 and mass == hardLimit)
        assert(f.inventory:contains(retained) and f.inventory:contains(fitting) and f.source:contains(excess))
    end
end)

test("a live increase from fifty to seventy-five changes the next preview admission", function()
    local f = fixture(50)
    item(f.inventory, "Base.PersonalGear", 14)
    local selected = item(f.source, "Base.HeavySupply", 61)
    local refused = assert(f.jobs:preview(request("inventory")))
    assert(#refused.moves == 0 and #refused.skipped == 1 and f.source:contains(selected))
    f.hardLimit = 75
    local admitted = start(f, request("inventory"))
    assert(#admitted.moves == 1 and #admitted.skipped == 0)
    local status = finish(f)
    local mass = f.world:carrying()
    assert(status.done == 1 and status.skipped == 0 and mass == 75 and f.inventory:contains(selected))
end)

test("mixed bag and main destinations share one hard budget and preserve both reservations", function()
    local f = fixture(50)
    item(f.inventory, "Base.PersonalGear", 14)
    local backpack = f:carryContainer(container("half-weight backpack", 20), 0.5)
    local packed = item(f.source, "Base.PackedSupply", 20)
    local carried = item(f.source, "Base.MainSupply", 26)
    local excess = item(f.source, "Base.Excess", 1)
    function f.world:destinations(input)
        if input.destination.kind == "inventory" then return {backpack, f.inventory} end
        return {f.destination}
    end
    local plan = start(f, request("inventory"))
    assert(#plan.moves == 2 and #plan.skipped == 1,
        "Fourteen gear plus ten reduced bag mass plus twenty-six main mass exhausts fifty")
    local status = finish(f)
    local mass = f.world:carrying()
    assert(status.done == 2 and status.skipped == 1 and mass == 50)
    assert(backpack:contains(packed) and f.inventory:contains(carried) and f.source:contains(excess))
end)

test("native-accepted carried rearrangement reserves only newly added main mass", function()
    for _, factor in ipairs({0.5, 1}) do
        local f = fixture(50)
        local retained = item(f.inventory, "Base.PersonalGear", 30)
        local backpack = f:carryContainer(container("carried source backpack", 50), factor)
        local selected = item(backpack, "Base.Selected", 20)
        f.sources = {backpack}
        function f.inventory:hasRoomFor(_, value) return value == selected end
        local plan = start(f, request("container", f.inventory))
        assert(#plan.moves == 1 and #plan.skipped == 0,
            "After native admission, moving an already-carried item must not reserve its full weight again")
        local status = finish(f)
        local mass = f.world:carrying()
        assert(status.done == 1 and status.skipped == 0 and mass == 50)
        assert(f.inventory:contains(retained) and f.inventory:contains(selected) and #backpack.items == 0)
    end
end)

test("unloading remains possible when the existing body mass exceeds the native hard limit", function()
    local f = fixture(50)
    local retained = item(f.inventory, "Base.PersonalGear", 20)
    local selected = item(f.inventory, "Base.Selected", 40)
    f.sources = {f.inventory}
    local input = request("container", f.destination)
    input.scope, input.filter = "inventory", {all = false, ids = {}, types = {"Base.Selected"}}
    local plan = start(f, input)
    assert(#plan.moves == 1 and #plan.skipped == 0)
    local status = finish(f)
    local mass = f.world:carrying()
    assert(status.done == 1 and status.skipped == 0 and mass == 20)
    assert(f.destination:contains(selected) and f.inventory:contains(retained))
end)

test("unlimited carry removes finite main reservations while native item predicates still apply", function()
    local f = fixture(50)
    f.unlimitedCarry = true
    local first = item(f.source, "Base.First", 40)
    local second = item(f.source, "Base.Second", 40)
    local forbidden = item(f.source, "Base.Forbidden", 1)
    local refused = item(f.source, "Base.NativeRefusal", 1)
    function f.inventory:isItemAllowed(value) return value ~= forbidden end
    local nativeRoom = f.inventory.hasRoomFor
    function f.inventory:hasRoomFor(player, value)
        return value ~= refused and nativeRoom(self, player, value)
    end
    local plan = start(f, request("inventory"))
    assert(#plan.moves == 2 and #plan.skipped == 2,
        "Unlimited carrying may reserve eighty in a nominal fifty inventory, but cannot bypass native restrictions")
    local status = finish(f)
    assert(status.done == 2 and status.skipped == 2 and f.inventory:contains(first) and f.inventory:contains(second))
    assert(f.source:contains(forbidden) and f.source:contains(refused) and #f.inventory.items == 2)
end)

test("nil cannot approve or reject a bin before a review token is issued", function()
    local f = fixture(2)
    local bin = container("unissued bin review", 4)
    bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    assert(not f.jobs:approveBin(nil) and not f.jobs:rejectBin(nil))
    assert(f.jobs:status().state == "needs_review" and f.source:contains(selected))
    assert(#f.transfers == 0 and #f.deletions == 0)
    local review = assert(f.jobs:reviewBin())
    assert(not f.jobs:approveBin(nil) and not f.jobs:rejectBin(nil))
    assert(f.jobs:approveBin(review) and finish(f).done == 1)
end)


test("resume follows an accepted recreated source instead of its detached handle", function()
    local f = fixture(3)
    local original, selected = f.source, item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" and op.container == original end)
    stopJob(f)
    local current = container("source", 100)
    local recreated = item(current); recreated.id = selected.id
    original.items, selected.container = {}, nil
    f.sourceLocations.source, f.source = current, current
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and current:isEmpty())
    assert(f.destination:getItemWithID(selected.id) and #f.transfers == 2)
end)

test("resumed unknown-source exploration requests and reads the current container", function()
    local f = fixture(3)
    f.client, f.source.explored = true, false
    local original = f.source
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" and op.container == original end)
    stopJob(f)
    local current = container("source", 100); current.explored = false
    local selected = item(current)
    f.sourceLocations.source, f.source = current, current
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and result.unconfirmedSources == 1)
    assert(not original.requested and current.requested == 1 and f.destination:contains(selected))
end)

test("resumed delivery uses the current anchored destination", function()
    local f = fixture(3)
    local selected, original = item(f.source), f.destination
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" and op.container == original end)
    stopJob(f)
    local current = container("destination", 100)
    f.sourceLocations.destination, f.destination = current, current
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and current:contains(selected) and original:isEmpty())
end)

test("a rejected source identity is never adopted on resume", function()
    local f = fixture(3)
    local selected = item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" and op.container == f.source end)
    stopJob(f)
    f.sourceLocations.source = nil
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 0 and result.skipped == 1 and f.source:contains(selected))
    assert(#f.transfers == 0 and f.destination:isEmpty())
end)

test("admission contention waits and continues the same job", function()
    local f = fixture(3)
    item(f.source); item(f.source)
    f.beginBusy = true
    start(f)
    local result = finish(f)
    assert(result.state == "finished" and result.done == 2 and result.skipped == 0)
    assert(not result.canResume and #f.destination.items == 2)
end)

test("an arbitrary queued action yields without cancelling or skipping work", function()
    local f = fixture(3)
    local selected = item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    f.yieldOnce, f.playerBusy = "transfer", true
    tick(f)
    for _ = 1, 20 do tick(f) end
    local waiting = f.jobs:status()
    assert(waiting.state == "running" and waiting.waiting and waiting.done == 0 and waiting.skipped == 0)
    assert(f.source:contains(selected) and #f.transfers == 0)
    f.playerBusy = false
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and #f.transfers == 2)
end)

test("failure wording cannot imply user cancellation", function()
    local f = fixture(3)
    item(f.source)
    f.rejectOnce = "Another player action interrupted and stopped this native operation"
    start(f)
    local result = finish(f)
    assert(result.state == "finished_with_skips" and result.skipped == 1 and result.done == 0 and not result.canResume)
end)

test("explicit takeover stops pending work until the user resumes", function()
    local f = fixture(3)
    item(f.source); item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    f.takeover = "Aiming stopped the job"
    local stopped = finish(f)
    assert(stopped.state == "cancelled" and stopped.canResume and #f.transfers == 0)
    assert(not f.jobs:resume())
    for _ = 1, 10 do tick(f) end
    assert(#f.transfers == 0)
    f.takeover = nil
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 2 and result.skipped == 0 and #f.destination.items == 2)
end)

test("a completed pickup during cancellation is counted exactly once after resume", function()
    local f = fixture(3)
    local selected = item(f.source)
    f.holdTransferResult, f.completeDuringCancel = true, true
    start(f, request("inventory"))
    for _ = 1, 100 do tick(f); if #f.transfers == 1 then break end end
    assert(#f.transfers == 1 and f.inventory:contains(selected))
    local stopped = stopJob(f)
    assert(stopped.done == 0)
    f.holdTransferResult = false
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 1 and result.total == 1 and result.skipped == 0 and #f.transfers == 1)
end)

test("protection and native hard carrying limits are checked after a stop", function()
    for _, change in ipairs({"protection", "capacity"}) do
        local f = fixture(3)
        local selected = item(f.source, "Base.Selected", 2)
        start(f, request("inventory"))
        awaitOperation(f, function(op) return op.kind == "transfer" end)
        stopJob(f)
        if change == "protection" then selected.protected = true else f.hardLimit = 1 end
        assert(f.jobs:resume())
        local result = finish(f)
        assert(result.done == 0 and result.skipped == 1 and f.source:contains(selected) and #f.transfers == 0)
        if change == "protection" then assert(result.reasons[1].status == "Protected") end
    end
end)

test("resuming a floor pickup returns before refreshing its shared floor view", function()
    local f = fixture(3)
    f.onlyGround, f.floorOnlyHere, f.groundSquares = true, true, {f.squares.source}
    local selected = item(f.floor)
    selected.world = {getSquare = function() return f.squares.source end}
    f.ground = {selected}
    start(f, request("inventory"))
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    stopJob(f)
    f.position = "destination"; f.loot:refreshBackpacks()
    assert(f.floor:isEmpty())
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and f.inventory:contains(selected))
    assert(f.transfers[1].source.kind == "floor" and f.position == "source")
end)

test("resuming a floor delivery keeps its original destination point", function()
    local f = fixture(3)
    local selected = item(f.inventory)
    f.sources = {f.inventory}
    local target = f.squares.destination
    start(f, request("floor", target))
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    stopJob(f)
    f.position = "source"
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.state == "finished" and result.done == 1 and result.skipped == 0 and selected:getWorldItem():getSquare() == target)
    assert(f.position == "destination")
end)

test("resume retires a bin token and requires fresh approval", function()
    local f = fixture(3)
    local bin = container("reviewed bin", 4); bin.trash, bin.uninspected, f.bins = true, true, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local old = assert(f.jobs:reviewBin())
    stopJob(f)
    assert(not f.jobs:approveBin(old) and not f.jobs:rejectBin(old))
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    local fresh = assert(f.jobs:reviewBin())
    assert(fresh ~= old and not f.jobs:approveBin(old))
    assert(f.jobs:approveBin(fresh))
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and not selected:getContainer())
end)

test("resume after an observed empty still reviews the next deposit", function()
    local f = fixture(3)
    local bin = container("full reviewed bin", 1); bin.trash, f.bins = true, {bin}
    item(bin); local selected = item(f.source)
    f.holdTrashResult, f.completeDuringCancel = true, true
    start(f, request("trash"))
    for _ = 1, 200 do tick(f); if #f.deletions == 1 then break end end
    assert(#f.deletions == 1 and bin:isEmpty())
    stopJob(f)
    f.holdTrashResult = false
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    assert(#f.deletions == 1 and not bin:contains(selected))
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    local result = finish(f)
    assert(result.done == 1 and bin:isEmpty() and #f.deletions == 2)
end)

test("resumed final cleanup cannot silently reuse its old bin approval", function()
    local f = fixture(3)
    local bin = container("final reviewed bin", 4); bin.trash, f.bins = true, {bin}
    item(f.source)
    start(f, request("trash"))
    awaitOperation(f, function(op) return op.kind == "trash" end)
    assert(#f.deletions == 0)
    stopJob(f)
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    assert(#f.deletions == 0)
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    local result = finish(f)
    assert(result.done == 1 and #f.deletions == 1 and bin:isEmpty())
end)


test("a resumed native adjacent floor result is counted without a duplicate drop", function()
    local f = fixture(3)
    local selected = item(f.inventory)
    f.sources = {f.inventory}
    local target = f.squares.destination
    local adjacent = f:addSquare(square("native adjacent floor", target.x + 1, target.y, target.z))
    f.floorDropPoint, f.holdTransferResult = adjacent, true
    start(f, request("floor", target))
    for _ = 1, 100 do tick(f); if #f.transfers == 1 then break end end
    assert(#f.transfers == 1 and selected:getWorldItem():getSquare() == adjacent)
    stopJob(f)
    f.holdTransferResult, f.position = false, "source"
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.state == "finished" and result.done == 1 and result.skipped == 0 and #f.transfers == 1)
    assert(selected:getWorldItem():getSquare() == adjacent)
end)

test("resuming a building walk retains its pending section and earlier rooms", function()
    local f = fixture(3)
    local upper = container("upper source", 100); local selected = item(upper)
    f:addSquare(square(upper.position, 30, 0, 1))
    local input = building(f, {
        {roomId = "empty", roomName = "Empty room", z = 0, target = f.squares.source, sources = {}},
        {roomId = "upper", roomName = "Upstairs", z = 1, target = f.squares[upper.position], sources = {upper}},
    })
    f.unloaded[upper.position] = true
    start(f, input)
    awaitOperation(f, function(op) return op.kind == "approach" and op.location and op.location.z == 1 end)
    local stopped = stopJob(f)
    assert(stopped.survey.roomsDone == 1)
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and result.survey.roomsDone == 2)
    assert(result.survey.sectionsSearched == 2 and f.destination:contains(selected))
end)

test("a protected item added while stopped blocks resumed whole-bin approval", function()
    local f = fixture(3)
    local bin = container("changed reviewed bin", 4); bin.trash, bin.uninspected, f.bins = true, true, {bin}
    item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local old = assert(f.jobs:reviewBin())
    stopJob(f)
    local kept = item(bin); kept.protected = true
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(not review.canApprove and #review.skipped == 1 and review.skipped[1].status == "Protected")
    assert(not f.jobs:approveBin(old) and not f.jobs:approveBin(review))
    assert(bin:contains(kept) and #f.deletions == 0 and #f.transfers == 0)
end)

test("resumed cleanup follows the reacquired bin through approval and capacity updates", function()
    local f = fixture(3)
    local bin = container("reloaded bin", 4); bin.trash, f.bins = true, {bin}
    local selected = item(f.source)
    start(f, request("trash"))
    awaitOperation(f, function(op) return op.kind == "approach" and op.container == bin end)
    stopJob(f)
    local current = container("reloaded bin", 2); current.trash = true
    local existing = item(current)
    f.sourceLocations[current.name], f.binLocations[current.name], f.bins[1] = current, current, current
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(review.bin.capacity == 2 and review.bin.used == 1)
    assert(f.jobs:approveBin(review))
    local result = finish(f)
    assert(result.done == 1 and result.skipped == 0 and #f.deletions == 1)
    assert(f.deletions[1].bin == current and f.deletions[1].count == 2)
    assert(not selected:getContainer() and not existing:getContainer() and current:isEmpty())
end)

test("cleanup clears selected bin contents in place without hauling", function()
    local f = fixture(2)
    local bin = container("source trash", 4); bin.trash = true
    f.sources, f.bins = {bin}, {bin}
    local selected = item(bin)
    start(f, request("trash"))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.moved == 0 and status.cleared == 1)
    assert(status.skipped == 0 and #f.transfers == 0 and #f.deletions == 1 and not selected:getContainer())
end)

test("source bins settle once regardless of source order", function()
    for _, first in ipairs({true, false}) do
        local f = fixture(1)
        local bin = container("source and destination trash", 2); bin.trash = true
        local existing, hauled = item(bin, "Base.Existing"), item(f.source)
        f.bins = {bin}
        f.sources = first and {bin, f.source} or {f.source, bin}
        start(f, request("trash"))
        local status = finish(f)
        assert(status.done == 2 and status.total == 2 and status.moved == 1 and status.cleared == 1 and status.skipped == 0)
        assert(#f.transfers == 2 and not existing:getContainer() and not hauled:getContainer())
    end
end)

test("failed source-bin deletion retains its selected work and contents", function()
    local f = fixture(2)
    local bin = container("rejected source trash", 4); bin.trash = true
    f.sources, f.bins = {bin}, {bin}
    local selected = item(bin)
    f.rejectTrash = true
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 0 and status.cleared == 0 and status.skipped == 1)
    assert(bin:contains(selected) and #f.transfers == 0 and #f.deletions == 0)
end)

test("a protected copy added after trash work queues prevents dispatch", function()
    local f = fixture(2)
    local bin = container("late protection trash", 4); bin.trash = true
    f.sources, f.bins = {bin}, {bin}
    local selected = item(bin)
    f.holdTrashBegin = true
    start(f, request("trash"))
    local queued = false
    for _ = 1, 100 do
        tick(f)
        if f.jobs.operation and f.jobs.operation.op.kind == "trash" and not f.adapter.active then queued = true; break end
    end
    assert(queued)
    selected.protected, f.playerBusy = true, false
    local status = finish(f)
    assert(status.done == 0 and status.cleared == 0 and status.skipped == 1 and bin:contains(selected))
    for _, op in ipairs(f.operations) do assert(op.kind ~= "trash", "Protected contents must stop the whole-bin command before dispatch") end
end)

test("a late native pickup refusal delivers the current load then retries the same item", function()
    local f = fixture(2)
    item(f.source); item(f.source)
    local armed = false
    f.onTransfer = function(op)
        if op.destination == f.inventory and not armed then armed = true; f.rejectPickupCount = 1 end
    end
    start(f)
    local status = finish(f)
    assert(status.done == 2 and status.skipped == 0 and #f.destination.items == 2 and f.rejectedPickups == 1)
    assert(#f.transfers == 4 and #f.inventory.items == 0)
end)

test("an empty-load capacity refusal retries after another item is delivered", function()
    local f = fixture(2)
    item(f.source, "Base.Heavy", 2); item(f.source, "Base.Light", 1)
    f.rejectPickupCount = 1
    start(f)
    local status = finish(f)
    assert(status.done == 2 and status.skipped == 0 and status.deferred == 0 and #f.destination.items == 2)
    assert(f.rejectedPickups == 1 and #f.transfers == 4)
end)

test("capacity refusal with no later progress finishes finitely and keeps the item", function()
    local f = fixture(2)
    local selected = item(f.source)
    f.rejectPickupCount = 10
    start(f)
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 0 and status.skipped == 1 and status.deferred == 0)
    assert(f.source:contains(selected) and f.rejectedPickups == 1 and #f.transfers == 0)
end)

test("skip-review is explicit per job and still freshly inspects bins", function()
    local f = fixture(2)
    local bin = container("uninspected skip bin", 4); bin.trash, bin.uninspected = true, true
    f.bins = {bin}
    local selected = item(f.source)
    local plan = assert(f.jobs:preview(request("trash")))
    assert(f.jobs:start(plan, {reviewBins = false}))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and f.inspectedBins[bin.name] and not selected:getContainer())
    local nextItem = item(f.source)
    bin.uninspected, f.inspectedBins[bin.name] = true, nil
    start(f, request("trash"))
    local paused = awaitState(f, "needs_review")
    assert(paused.done == 0 and f.source:contains(nextItem))
end)

test("skip-review never approves protected bin contents", function()
    local f = fixture(2)
    local bin = container("protected skip bin", 4); bin.trash, bin.uninspected = true, true
    local kept = item(bin); kept.protected = true
    local selected = item(f.source)
    f.bins = {bin}
    local plan = assert(f.jobs:preview(request("trash")))
    assert(f.jobs:start(plan, {reviewBins = false}))
    local status = finish(f)
    assert(status.done == 0 and status.skipped > 0 and #f.transfers == 0 and #f.deletions == 0)
    assert(bin:contains(kept) and f.source:contains(selected))
end)

test("invalid approval cannot turn off future bin reviews", function()
    local f = fixture(2)
    local bin = container("policy token bin", 4); bin.trash, bin.uninspected = true, true
    f.bins = {bin}; item(f.source)
    start(f, request("trash"))
    local first = awaitState(f, "needs_review")
    assert(not f.jobs:approveBin({}, {reviewBins = false}))
    assert(f.jobs:status().reviewBins and f.jobs:status().reviewId == first.reviewId)
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    assert(finish(f).done == 1)
end)

test("manual pause preserves work and blocks replacement until Cancel", function()
    local f = fixture(2)
    item(f.source); item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" end)
    assert(f.jobs:status().canPause and f.jobs:pause())
    local status = awaitState(f, "paused")
    assert(status.canResume and not status.canPause and #f.transfers == 0)
    assert(not f.jobs:preview(request("inventory")))
    assert(f.jobs:resume())
    assert(finish(f).done == 2 and #f.transfers == 4)
end)

test("shortcut readiness follows the running job and permits fresh work after settled cancellation", function()
    local f = fixture(2)
    local old = item(f.source, "Test.Old", 1)
    local selected = item(f.source, "Test.New", 1)
    local original = request("container", f.destination)
    original.filter = {all = false, ids = {}, types = {"Test.Old"}}
    assert(f.jobs:status().state == "idle" and f.jobs:status().canPreview and f.jobs:status().hasJob == false)
    start(f, original)
    assert(not f.jobs:status().canPreview and f.jobs:status().hasJob == true)
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    assert(f.adapter:isBusy() and not f.jobs:status().canPreview)
    assert(f.jobs:pause() and not f.jobs:status().canPreview and f.jobs:status().hasJob == true)
    local paused = awaitState(f, "paused")
    assert(paused.canResume and not paused.canPreview and paused.hasJob == true and #f.transfers == 0)
    assert(not f.jobs:preview(original))
    assert(f.jobs:resume() and not f.jobs:status().canPreview)
    assert(f.jobs:cancel() and not f.jobs:status().canPreview)
    local cancelled = finish(f)
    assert(cancelled.state == "cancelled" and cancelled.canResume and cancelled.canPreview and cancelled.hasJob == true)
    local fresh = request("inventory")
    fresh.filter = {all = false, ids = {}, types = {"Test.New"}}
    local plan = assert(f.jobs:preview(fresh))
    assert(f.jobs:status().state == "cancelled" and #f.transfers == 0 and f.source:contains(old))
    assert(f.jobs:start(plan) and not f.jobs:status().canPreview)
    local finished = finish(f)
    assert(finished.state == "finished" and finished.canPreview and finished.done == 1 and finished.hasJob == false)
    assert(#f.transfers == 1 and f.transfers[1].item == selected and f.inventory:contains(selected))
    assert(f.source:contains(old) and f.destination:isEmpty())
    local reviewing = fixture(2)
    local bin = container("shortcut review bin", 4)
    bin.trash, bin.uninspected = true, true
    reviewing.bins = {bin}; item(reviewing.source)
    start(reviewing, request("trash"))
    local binReview = awaitState(reviewing, "needs_review")
    assert(not binReview.canPreview and binReview.hasJob == true)
end)

test("combat pause remains stopped after the combat input ends until Resume", function()
    local f = fixture(2)
    local selected = item(f.source)
    start(f)
    f.takeover, f.takeoverKind = "Aiming paused the job", "combat"
    local paused = awaitState(f, "paused")
    assert(paused.canResume and f.source:contains(selected))
    f.takeover, f.takeoverKind = nil, nil
    for _ = 1, 10 do tick(f) end
    assert(f.jobs:status().state == "paused" and #f.transfers == 0)
    assert(f.jobs:resume())
    assert(finish(f).done == 1 and #f.destination.items == 1)
end)

test("late observed trash completion during pause settles selected source IDs once", function()
    local f = fixture(2)
    local bin = container("delayed source trash", 4); bin.trash = true
    f.sources, f.bins = {bin}, {bin}
    local selected = item(bin)
    start(f, request("trash"))
    awaitOperation(f, function(op) return op.kind == "trash" end)
    assert(#f.deletions == 0 and bin:contains(selected))
    f.trashReplyDuringCancel, f.completeDuringCancel = true, true
    assert(f.jobs:pause())
    local paused = awaitState(f, "paused")
    assert(paused.done == 1 and paused.cleared == 1 and #f.deletions == 1 and not selected:getContainer())
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.done == 1 and status.cleared == 1 and status.skipped == 0 and #f.deletions == 1 and #f.transfers == 0)
end)

test("trash deletion cannot settle a same-ID copy registered at another source", function()
    local f = fixture(1)
    local bin = container("distinct source trash", 1); bin.trash = true
    local selected = item(f.source)
    local foreign = item(bin); foreign.id = selected.id
    f.bins = {bin}
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.total == 1 and status.moved == 1 and status.cleared == 0 and status.skipped == 0)
    assert(#f.transfers == 2 and #f.deletions == 2 and not selected:getContainer() and not foreign:getContainer())
end)

test("bin-source settlement requires the registered full type as well as the ID", function()
    local f = fixture(1)
    local bin = container("type-changing source trash", 2); bin.trash = true
    local selected, existing = item(f.source), item(bin, "Base.Original")
    f.bins, f.sources = {bin}, {f.source, bin}
    local changed = false
    f.onApproach = function(op)
        if op.container == bin and not changed then existing.fullType, changed = "Base.Replacement", true end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.moved == 1 and status.cleared == 0 and status.skipped == 1)
    assert(#f.transfers == 2 and not selected:getContainer() and not existing:getContainer())
end)

local function recoveryFixture(f, personal)
    local safe = container("personal safe cupboard", 100)
    local point = f:ensureSquare(safe.position)
    f.safeCandidates = {safe}
    local recovery = {pending = false, personal = personal, safe = safe}
    function recovery:status() return {pending = self.pending, point = {x = point.x, y = point.y, z = point.z}} end
    function recovery:endpoint() return safe end
    function recovery:prepare() self.pending = true; return true end
    function recovery:allows(op)
        return self.pending and op.personalRecovery and op.item == personal and
            ((op.source == f.inventory and op.destination == safe) or (op.source == safe and op.destination == f.inventory))
    end
    function recovery:next(mode)
        if self.failRestore and mode == "restore" then return nil, "The original place is blocked" end
        if mode == "stage" then
            if safe:contains(personal) then return nil, nil, true end
            return {kind = "transfer", item = personal, source = f.inventory, destination = safe, personalRecovery = true}
        end
        if f.inventory:contains(personal) then self.pending = false; return nil, nil, true end
        return {kind = "transfer", item = personal, source = safe, destination = f.inventory, personalRecovery = true}
    end
    function recovery:settle(op, ok) return ok and op.destination:contains(personal) end
    f.jobs.recovery = recovery
    return recovery, safe
end

test("losing a staged heavy source restores personal items before collecting other work", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Personal", 1); personal.protected = true
    local heavy, other = item(f.source, "Base.Heavy", 3), item(f.source, "Base.Other", 1)
    local bin = container("heavy cleanup trash", 4); bin.trash = true; f.bins = {bin}
    local recovery, safe = recoveryFixture(f, personal)
    f.onTransfer = function(op)
        if op.personalRecovery and op.destination == safe then
            assert(remove(f.source.items, heavy)); heavy.container = nil
        end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 1 and f.inventory:contains(personal) and not recovery.pending)
    assert(not other:getContainer())
    local restoredAt, nextPickup
    for index, op in ipairs(f.transfers) do
        if op.item == personal and op.destination == f.inventory then restoredAt = index end
        if op.item == other and op.destination == f.inventory then nextPickup = index end
    end
    assert(restoredAt and nextPickup and restoredAt < nextPickup)
end)

test("a changed destination rule after staging restores personal gear before finishing", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Personal", 1); personal.protected = true
    local heavy = item(f.source, "Base.Heavy", 3)
    local bin = container("changed heavy destination", 4); bin.trash = true; f.bins = {bin}
    local recovery, safe = recoveryFixture(f, personal)
    f.onTransfer = function(op)
        if op.personalRecovery and op.destination == safe then
            function f.inventory:isItemAllowed(value) return value ~= heavy end
        end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 0 and status.skipped == 1 and f.inventory:contains(personal) and f.source:contains(heavy))
    assert(not recovery.pending and #f.deletions == 0)
end)

test("failed manual recovery keeps the original checkpoint and prevents premature Resume", function()
    local f = fixture(3)
    local personal, selected = item(f.inventory, "Base.Personal", 1), item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" end)
    assert(f.jobs:pause()); awaitState(f, "paused")
    local recovery, safe = recoveryFixture(f, personal)
    assert(remove(f.inventory.items, personal)); safe.items[#safe.items + 1], personal.container = personal, safe
    recovery.pending, recovery.failRestore = true, true
    assert(f.jobs:recoverPersonalGear())
    local failed = finish(f)
    assert(failed.state == "failed" and recovery.pending and not failed.canResume and not f.jobs:resume())
    assert(failed.hasJob == true and failed.canPreview)
    recovery.failRestore = false
    assert(f.jobs:recoverPersonalGear())
    local recovered = finish(f)
    assert(recovered.state == "paused" and recovered.canResume and recovered.hasJob == true and not recovery.pending and f.inventory:contains(personal))
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and status.hasJob == false and f.destination:contains(selected))
end)

test("repeated Recover after pausing recovery preserves the ordinary job checkpoint", function()
    local f = fixture(3)
    local personal, selected = item(f.inventory, "Base.Personal", 1), item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" end)
    assert(f.jobs:pause()); awaitState(f, "paused")
    local recovery, safe = recoveryFixture(f, personal)
    assert(remove(f.inventory.items, personal)); safe.items[#safe.items + 1], personal.container = personal, safe
    recovery.pending = true
    assert(f.jobs:recoverPersonalGear())
    awaitOperation(f, function(op) return op.kind == "approach" end)
    assert(f.jobs:pause()); awaitState(f, "paused")
    assert(f.jobs:recoverPersonalGear())
    local recovered = finish(f)
    assert(recovered.state == "paused" and recovered.canResume and f.inventory:contains(personal) and not recovery.pending)
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0 and f.destination:contains(selected))
end)

test("a heavy cleanup restores personal gear only after deleting the delivered heavy load", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Personal", 1); personal.protected = true
    local heavy = item(f.source, "Base.Heavy", 3)
    local bin = container("heavy trip trash", 4); bin.trash = true; f.bins = {bin}
    local recovery = recoveryFixture(f, personal)
    local restoredAfterDelete = false
    f.onTransfer = function(op)
        assert(not (op.item == personal and op.destination == bin), "Personal staging must never target the deletion bin")
        if op.personalRecovery and op.destination == f.inventory then restoredAfterDelete = #f.deletions == 1 and heavy:getContainer() == nil end
    end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.moved == 1 and status.skipped == 0)
    assert(restoredAfterDelete and f.inventory:contains(personal) and not recovery.pending and #f.transfers == 4 and #f.deletions == 1)
end)

test("pausing a bin review requires a new generation and token before Resume continues", function()
    local f = fixture(2)
    local bin = container("paused generation bin", 4); bin.trash, bin.uninspected = true, true
    f.bins = {bin}; item(f.source)
    start(f, request("trash"))
    local before = awaitState(f, "needs_review")
    local old = assert(f.jobs:reviewBin())
    assert(f.jobs:pause()); awaitState(f, "paused")
    assert(not f.jobs:approveBin(old))
    assert(f.jobs:resume())
    local after = awaitState(f, "needs_review")
    assert(after.reviewId > before.reviewId and not f.jobs:approveBin(old))
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())) and finish(f).done == 1)
end)

test("bag preparation keeps capacity-dependent selected items in the preview instead of final exclusions", function()
    local f = fixture(3)
    item(f.source, "Base.Plank", 2)
    item(f.source, "Base.Plank", 2)
    local Carry = require "LootBox/Carry"
    local previous = Carry.next
    Carry.next = function(_, _, incoming)
        assert(incoming == 4)
        return {kind = "gear"}
    end
    local plan = assert(f.jobs:preview(request("inventory")))
    Carry.next = previous
    assert(#plan.moves == 2 and #plan.skipped == 0)
    assert(plan.moves[2].status == "Recheck after bag setup")
    assert(plan.moves[2].to == "Carried storage after bag setup")
    assert(#f.transfers == 0 and f.source:getItems():size() == 2)
    local normal = assert(f.jobs:preview(request("inventory")))
    assert(#normal.moves == 1 and #normal.skipped == 1, "Without useful bag preparation the live capacity exclusion remains truthful")
end)

local function matchingFixture(capacity)
    local f = fixture(capacity or 20)
    f.sources = {f.inventory}
    f.displayed, f.nearbyTargets = f.destination, {f.destination}
    f.targetTypes = {[f.destination] = {["Base.Nails"] = true}}
    function f.world:matchingOrder(records)
        if f.orderError then return nil, f.orderError end
        if not f.nativeOrder then return records end
        local byItem, ordered = {}, {}
        for _, record in ipairs(records) do byItem[record.item] = record end
        for _, value in ipairs(f.nativeOrder) do ordered[#ordered + 1] = assert(byItem[value]) end
        return ordered
    end
    function f.world:matchingTargets(mode)
        local result = {}
        for _, target in ipairs(mode == "displayed" and {f.displayed} or f.nearbyTargets) do
            local types = {}
            for fullType, selected in pairs(f.targetTypes[target] or {}) do types[fullType] = selected end
            local floor = target:getType() == "floor"
            local point = floor and f.floorTarget or nil
            result[#result + 1] = {ref = target, anchor = not floor and self:sourceAnchor(target) or nil,
                point = point and {x = point.x, y = point.y, z = point.z}, types = types}
        end
        return result
    end
    function f.world:matchingPoint(input)
        for _, target in ipairs(input.destination.targets or {}) do
            if target.point then return {x = target.point.x, y = target.point.y, z = target.point.z} end
        end
    end
    local ordinaryDestinations = f.world.destinations
    function f.world:destinations(input, value)
        if input.destination.kind ~= "matching" then return ordinaryDestinations(self, input, value) end
        local result = {}
        for _, target in ipairs(input.destination.targets or {}) do
            if target.types[value:getFullType()] then
                local current = target.anchor and self:resolveSource(target.anchor) or f.floor
                if current then result[#result + 1] = current end
            end
        end
        return result
    end
    return f
end

local function matchingRequest(mode)
    return {scope = "inventory", includeBags = true, filter = {all = true, ids = {}, types = {}},
        destination = {kind = "matching", mode = mode or "nearby"}}
end

test("matching transfers move main, outer bag and nested bag items directly to the captured target", function()
    local f = matchingFixture(20)
    local outer = f:carryContainer(container("outer carried bag", 10), 0.5)
    local inner = f:carryContainer(container("nested carried bag", 10), 0.5)
    f.sources = {f.inventory, outer, inner}
    local mainItem, outerItem, innerItem = item(f.inventory), item(outer), item(inner)
    start(f, matchingRequest("displayed"))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 3 and status.moved == 3 and status.carried == 0 and status.skipped == 0)
    assert(f.destination:contains(mainItem) and f.destination:contains(outerItem) and f.destination:contains(innerItem))
    assert(f.inventory:isEmpty() and outer:isEmpty() and inner:isEmpty() and #f.transfers == 3)
    assert(f.transfers[1].source == f.inventory and f.transfers[2].source == outer and f.transfers[3].source == inner)
end)

test("matching displayed transfers keep the clicked destination after the loot pane changes", function()
    local f = matchingFixture(20)
    local selected = item(f.inventory)
    local other = container("new displayed storage", 10)
    local plan = assert(f.jobs:preview(matchingRequest("displayed")))
    f.displayed = other
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0 and f.destination:contains(selected) and other:isEmpty())
    assert(#f.transfers == 1)
end)

test("public review edits cannot replace private matching routes or their selection", function()
    local f = matchingFixture(20)
    local selected = item(f.inventory)
    local other = container("unreviewed matching storage", 10)
    local plan = assert(f.jobs:preview(matchingRequest("displayed")))
    assert(plan.request.destination.targets == nil)
    plan.request.destination.targets = {{ref = other, types = {["Base.Nails"] = true}}}
    plan.request.destination.mode = "nearby"
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and f.destination:contains(selected) and other:isEmpty())
end)

test("nearby matching routes use later eligible targets when the first fills", function()
    local f = matchingFixture(10)
    local bag = f:carryContainer(container("matching carry bag", 10), 0.5)
    f.sources = {f.inventory, bag}
    f.destination.capacity = 2
    local second = container("second matching target", 3)
    f.nearbyTargets = {f.destination, second}
    f.targetTypes[second] = {["Base.Nails"] = true}
    for _ = 1, 2 do item(f.inventory) end
    for _ = 1, 3 do item(bag) end
    start(f, matchingRequest())
    local status = finish(f)
    assert(status.state == "finished" and status.done == 5 and status.skipped == 0 and status.carried == 0)
    assert(#f.destination.items == 2 and #second.items == 3 and #f.transfers == 5)
    assert(f.inventory:isEmpty() and bag:isEmpty())
end)

test("native matching order across bags determines which items fit a limited target", function()
    local f = matchingFixture(10)
    local bag = f:carryContainer(container("middle weight bag", 10), 1)
    f.sources = {f.inventory, bag}
    local light = item(f.inventory, "Base.WaterBottle", 1)
    local heavy = item(f.inventory, "Base.WaterBottle", 3)
    local middle = item(bag, "Base.WaterBottle", 2)
    f.destination.capacity = 4
    f.targetTypes[f.destination] = {["Base.WaterBottle"] = true}
    f.nativeOrder = {light, middle, heavy}
    start(f, matchingRequest())
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 2 and status.skipped == 1 and #f.transfers == 2)
    assert(f.destination:contains(light) and f.destination:contains(middle) and not f.destination:contains(heavy))
    assert(f.inventory:contains(heavy) and bag:isEmpty())
end)

test("matching floor delivery resumes at its original point after the player leaves", function()
    local f = matchingFixture(10)
    local target = f:addSquare(square("matching original floor", 20, 0))
    local elsewhere = f:addSquare(square("matching other floor", 50, 10, 1))
    local selected = item(f.inventory)
    f.displayed, f.floorTarget = f.floor, {x = target.x, y = target.y, z = target.z}
    f.targetTypes[f.floor] = {["Base.Nails"] = true}
    start(f, matchingRequest("displayed"))
    awaitOperation(f, function(op) return op.kind == "transfer" and op.destination == f.floor end)
    stopJob(f)
    f.position, f.floorOnlyHere = elsewhere.name, true
    f.floorTarget = {x = elsewhere.x, y = elsewhere.y, z = elsewhere.z}
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0 and #f.transfers == 1)
    assert(selected:getWorldItem():getSquare() == target)
    assert(f.floorDrops[selected.id].origin == coordinateKey({x = target.x, y = target.y, z = target.z}))
end)

test("matching transfers reject incomplete carried scope and invalid modes without moving items", function()
    local f = matchingFixture(10)
    local selected = item(f.inventory)
    local input = matchingRequest()
    input.scope = "room"
    assert(not f.jobs:preview(input))
    input.scope, input.includeBags = "inventory", false
    assert(not f.jobs:preview(input))
    input.includeBags, input.destination.mode = true, "unknown"
    assert(not f.jobs:preview(input))
    assert(f.inventory:contains(selected) and #f.operations == 0 and f.jobs:status().state == "idle")
end)

test("an unreachable captured matching floor leaves items carried instead of dropping at the new location", function()
    local f = matchingFixture(10)
    local target = f:addSquare(square("unloaded matching floor", 20, 0))
    local selected = item(f.inventory)
    f.displayed, f.floorTarget = f.floor, {x = target.x, y = target.y, z = target.z}
    f.targetTypes[f.floor] = {["Base.Nails"] = true}
    local plan = assert(f.jobs:preview(matchingRequest("displayed")))
    f.grid[coordinateKey(target)], f.unloaded[target.name] = nil, true
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 0 and status.skipped == 1)
    assert(f.inventory:contains(selected) and #f.transfers == 0 and #f.ground == 0)
end)

test("a native matching sort failure leaves every carried item untouched", function()
    local f = matchingFixture(10)
    local selected = item(f.inventory)
    f.orderError = "Native matching sort failed"
    local plan, err = f.jobs:preview(matchingRequest())
    assert(not plan and err == f.orderError and f.inventory:contains(selected) and #f.operations == 0)
end)

test("an explicit carried bag receives a single direct transfer without a Smart Load detour", function()
    local f = fixture(3)
    local preferred = f:carryContainer(container("other reducing bag", 10), 0.1)
    local selectedBag = f:carryContainer(container("selected reducing bag", 20), 0.25)
    local selected = item(f.source, "Base.Heavy", 6)
    local ordinary = f.world.destinations
    function f.world:destinations(input, value)
        if input.destination.kind == "inventory" then return {preferred, f.inventory} end
        return ordinary(self, input, value)
    end
    start(f, request("container", selectedBag))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.moved == 1 and status.carried == 0 and status.skipped == 0)
    assert(#f.transfers == 1 and f.transfers[1].source == f.source and f.transfers[1].destination == selectedBag)
    assert(selectedBag:contains(selected) and preferred:isEmpty() and f.inventory:isEmpty())
end)

test("an explicit main-inventory unpack does not prepare another bag or queue a hauling leg", function()
    local f = fixture(10)
    local sourceBag = f:carryContainer(container("unpacked personal bag", 10), 1)
    local otherBag = f:carryContainer(container("unused gear bag", 10), 0.5)
    local selected = item(sourceBag, "Base.Nails", 2)
    f.sources = {sourceBag}
    local Carry = require "LootBox/Carry"
    local previous = Carry.next
    local bagItem = {getInventory = function() return otherBag end}
    Carry.next = function() return {kind = "gear", item = bagItem} end
    start(f, request("container", f.inventory))
    local status = finish(f)
    Carry.next = previous
    assert(status.state == "finished" and status.done == 1 and status.carried == 0 and status.skipped == 0)
    assert(#f.transfers == 1 and f.transfers[1].source == sourceBag and f.transfers[1].destination == f.inventory)
    assert(f.inventory:contains(selected) and sourceBag:isEmpty() and otherBag:isEmpty())
    for _, op in ipairs(f.operations) do assert(op.kind ~= "gear") end
end)

local function condenseFixture()
    local f = fixture(50)
    f.world.player = f.player
    function f.world:carryFactor(value) return value.carryFactor or 1 end
    function f.inventory:isRemoveItemAllowed() return true end
    function f.player:isEquipped(value) return value.equipped == true end
    function f:addBag(name, capacity, factor, equipped, parent)
        parent = parent or self.inventory
        local inside = self:carryContainer(container(name, capacity), factor)
        local value = item(parent, "Test." .. name, 0)
        value.equipped = equipped ~= false
        function value:IsInventoryContainer() return true end
        function value:getInventory() return inside end
        function value:getMaxItemSize() return self.maximumItem or 0 end
        function value:getAttachedSlot() return -1 end
        function inside:isRemoveItemAllowed() return true end
        return inside, value
    end
    function f:startCondense(options)
        local plan, err = self.jobs:previewCondense(options)
        assert(plan, err)
        assert(self.jobs:start(plan))
        return plan
    end
    return f
end

test("Condense packs heavy loose items into the strongest useful bags first", function()
    local f = condenseFixture()
    local strong = f:addBag("Strong", 8, 0.1)
    local weak = f:addBag("Weak", 8, 0.5)
    local light = item(f.inventory, "Test.Light", 2)
    local medium = item(f.inventory, "Test.Medium", 4)
    local heavy = item(f.inventory, "Test.Heavy", 6)
    f:startCondense()
    local status = finish(f)
    assert(status.state == "finished" and #f.transfers == 3 and f.transfers[1].item == heavy)
    assert(strong:contains(heavy) and strong:contains(light) and weak:contains(medium))
    assert(math.abs(f.world:carrying() - 2.8) < 0.0001 and math.abs(status.condense.saved - 9.2) < 0.0001)
    f:startCondense()
    assert(finish(f).state == "finished" and #f.transfers == 3)
end)

test("Condense default leaves bag contents and protected loose items in place", function()
    local f = condenseFixture()
    local strong = f:addBag("Strong", 8, 0.1)
    local weak = f:addBag("Weak", 8, 0.5)
    local existing = item(weak, "Test.Existing", 4)
    local loose = item(f.inventory, "Test.Loose", 6)
    local protected = item(f.inventory, "Test.Keep", 1)
    protected.protected = true
    f:startCondense()
    assert(finish(f).state == "finished" and #f.transfers == 1)
    assert(strong:contains(loose) and weak:contains(existing) and f.inventory:contains(protected))
end)

test("Condense optimization resolves fragmentation through temporary main storage", function()
    local f = condenseFixture()
    local strong = f:addBag("Strong", 10, 0.1)
    local weak = f:addBag("Weak", 10, 0.5)
    local nine = item(strong, "Test.Nine", 9)
    local eight = item(weak, "Test.Eight", 8)
    local two = item(weak, "Test.Two", 2)
    f:startCondense({rebalance = true})
    local status = finish(f)
    assert(status.state == "finished" and #f.transfers == 4 and status.condense.buffered == 0)
    assert(strong:contains(eight) and strong:contains(two) and weak:contains(nine))
    assert(math.abs(f.world:carrying() - 5.5) < 0.0001 and math.abs(status.condense.saved - 0.4) < 0.0001)
    assert(f.transfers[1].item == nine and f.transfers[1].destination == f.inventory)
end)

test("Condense avoids equal-weight full-bag exchanges and respects temporary hard capacity", function()
    local equal = condenseFixture()
    local strong = equal:addBag("Strong", 10, 0.1)
    local weak = equal:addBag("Weak", 10, 0.5)
    item(strong, "Test.TenA", 10); item(weak, "Test.TenB", 10)
    equal:startCondense({rebalance = true})
    assert(finish(equal).state == "finished" and #equal.transfers == 0)
    local f = condenseFixture()
    strong = f:addBag("Strong", 10, 0.1)
    weak = f:addBag("Weak", 10, 0.5)
    item(strong, "Test.Nine", 9); item(weak, "Test.Eight", 8); item(weak, "Test.Two", 2)
    f.hardLimit = 14
    f:startCondense({rebalance = true})
    local blocked = finish(f)
    assert(blocked.state == "finished" and #f.transfers == 0 and blocked.reason:find("temporary", 1, true))
    f.hardLimit = 22
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and math.abs(f.world:carrying() - 5.5) < 0.0001)
end)

test("Condense uses unequipped loot bags only when enabled and honors native item size", function()
    local f = condenseFixture()
    local loot, bag = f:addBag("LootBag", 8, 1, false)
    local selected = item(f.inventory, "Test.Loose", 4)
    f:startCondense()
    assert(finish(f).state == "finished" and #f.transfers == 0 and f.inventory:contains(selected))
    bag.maximumItem = 3
    f:startCondense({useUnequipped = true})
    assert(finish(f).state == "finished" and #f.transfers == 0)
    bag.maximumItem = 4
    f:startCondense({useUnequipped = true})
    assert(finish(f).state == "finished" and #f.transfers == 1 and loot:contains(selected))
    assert(f.world:carrying() == 4 and not bag.equipped)
end)

test("Condense nested opt-in retains enclosing bag capacity budgets", function()
    local f = condenseFixture()
    local outer = f:addBag("Outer", 5, 0.2)
    local inner = f:addBag("Inner", 10, 0.2, false, outer)
    local existing = item(inner, "Test.Existing", 4)
    local selected = item(f.inventory, "Test.Loose", 3)
    function outer:isItemAllowed() return false end
    function outer:getCapacityWeight() return inner:getCapacityWeight() end
    f:startCondense()
    assert(finish(f).state == "finished" and #f.transfers == 0)
    f:startCondense({nested = true})
    assert(finish(f).state == "finished" and #f.transfers == 0)
    outer.capacity = 7
    f:startCondense({nested = true})
    assert(finish(f).state == "finished" and #f.transfers == 1 and inner:contains(selected) and inner:contains(existing))
    assert(outer:getCapacityWeight() == 7 and math.abs(f.world:carrying() - 1.4) < 0.0001)
end)

test("Condense native failure after buffering restores items before trying another arrangement", function()
    local f = condenseFixture()
    local strong = f:addBag("Strong", 10, 0.1)
    local weak = f:addBag("Weak", 10, 0.5)
    local nine = item(strong, "Test.Nine", 9)
    local eight = item(weak, "Test.Eight", 8)
    local two = item(weak, "Test.Two", 2)
    local failed, restored = false, false
    function f.onTransfer(op)
        if op.item == nine and op.destination == f.inventory and not failed then
            failed, f.rejectOnce = true, "Native destination changed"
        elseif failed and op.item == nine and op.destination == strong then restored = true end
    end
    f:startCondense({rebalance = true})
    local status = finish(f)
    assert(status.state == "finished" and failed and restored and status.condense.buffered == 0)
    assert(strong:contains(eight) and strong:contains(two) and weak:contains(nine))
    assert(math.abs(f.world:carrying() - 5.5) < 0.0001)
end)

test("Condense Pause and Resume settle an observed transfer exactly once", function()
    local f = condenseFixture()
    local bag = f:addBag("Strong", 10, 0.1)
    local first = item(f.inventory, "Test.First", 4)
    local second = item(f.inventory, "Test.Second", 2)
    f.holdTransferResult = true
    f:startCondense()
    for _ = 1, 30 do tick(f); if #f.transfers == 1 then break end end
    assert(#f.transfers == 1 and bag:contains(first))
    f.completeDuringCancel = true
    assert(f.jobs:pause())
    local paused = awaitState(f, "paused")
    assert(paused.canResume and not f.jobs:previewCondense())
    f.holdTransferResult = false
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and #f.transfers == 2 and status.condense.transfers == 2)
    assert(bag:contains(first) and bag:contains(second) and math.abs(f.world:carrying() - 0.6) < 0.0001)
end)

test("Condense pauses on failed inventory capture and resumes from current storage", function()
    local f = condenseFixture()
    local bag = f:addBag("Strong", 10, 0.1)
    local selected = item(f.inventory, "Test.Loose", 4)
    function f.onTransfer() f.inventory.owned = false end
    f:startCondense()
    local status = awaitState(f, "paused")
    assert(status.canResume and #f.transfers == 1 and bag:contains(selected))
    assert(status.reason:find("unavailable", 1, true))
    f.inventory.owned, f.onTransfer = true, nil
    assert(f.jobs:resume())
    assert(finish(f).state == "finished" and #f.transfers == 1)
end)

test("Smart Take unwanted exclusion survives preview and final native dispatch checks", function()
    local f = fixture(10)
    local wanted = item(f.source)
    local unwanted = item(f.source)
    unwanted.isUnwanted = function(_, player) return player == f.player end
    local input = request("inventory")
    input.excludeUnwanted = true
    local plan = assert(f.jobs:preview(input))
    assert(#plan.moves == 1 and plan.records[1].item == wanted)
    wanted.isUnwanted = function() return true end
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.moved == 0 and f.source:contains(wanted) and f.source:contains(unwanted) and #f.transfers == 0)
    local ordinary = assert(f.jobs:preview(request("inventory")))
    assert(#ordinary.moves == 2, "Only Smart Take's explicit unwanted policy changes selection")
end)

test("Condense packing groups with protected seeds among equally reducing bags", function()
    local f = condenseFixture()
    local empty = f:addBag("AlphaEmpty", 10, 0.5)
    local matching = f:addBag("ZetaMatching", 10, 0.5)
    local seed = item(matching, "Test.Match", 1)
    seed.protected = true
    local selected = item(f.inventory, "Test.Match", 2)
    f:startCondense()
    local status = finish(f)
    assert(status.state == "finished" and #f.transfers == 1 and empty:isEmpty())
    assert(matching:contains(seed) and matching:contains(selected) and f.transfers[1].item == selected)
    assert(math.abs(f.world:carrying() - 1.5) < 0.0001)
end)

test("Condense consolidates split pairs without an immediate reduction in type locations", function()
    local f = condenseFixture()
    local first = f:addBag("First", 10, 0.5)
    local second = f:addBag("Second", 10, 0.5)
    for _ = 1, 2 do item(first, "Test.Match", 1); item(second, "Test.Match", 1) end
    f:startCondense({rebalance = true})
    local status = finish(f)
    assert(status.state == "finished" and math.abs(f.world:carrying() - 2) < 0.0001)
    assert((#first.items == 4 and second:isEmpty()) or (#second.items == 4 and first:isEmpty()))
    local count = #f.transfers
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == count)
end)

test("Condense groups equal-weight full bags across Pause and Resume without later churn", function()
    local f = condenseFixture()
    local first = f:addBag("First", 2, 0.5)
    local second = f:addBag("Second", 2, 0.5)
    item(first, "Test.A", 1); item(first, "Test.B", 1)
    item(second, "Test.A", 1); item(second, "Test.B", 1)
    f.holdTransferResult = true
    f:startCondense({rebalance = true})
    for _ = 1, 100 do tick(f); if #f.transfers == 1 then break end end
    assert(#f.transfers == 1)
    f.completeDuringCancel = true
    assert(f.jobs:pause())
    assert(awaitState(f, "paused").canResume)
    f.holdTransferResult = false
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and status.condense.buffered == 0)
    assert(#first.items == 2 and #second.items == 2)
    assert(first.items[1].fullType == first.items[2].fullType)
    assert(second.items[1].fullType == second.items[2].fullType and first.items[1].fullType ~= second.items[1].fullType)
    assert(math.abs(f.world:carrying() - 2) < 0.0001 and math.abs(status.condense.saved) < 0.0001)
    local count = #f.transfers
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == count)
end)

test("Condense uses native clothing aliases when grouping with a protected seed", function()
    local previous = ISInventoryWindowControlHandler_TransferSameType
    ISInventoryWindowControlHandler_TransferSameType = {getItemsTable = function(_, source)
        local map = {}
        for _, value in ipairs(source.items) do
            map[value.fullType] = map[value.fullType] or {}
            map[value.fullType][#map[value.fullType] + 1] = value
            if value.alias then
                map[value.alias] = map[value.alias] or {}
                map[value.alias][#map[value.alias] + 1] = value
            end
        end
        return map
    end}
    local f = condenseFixture()
    local first = f:addBag("First", 10, 0.5)
    local second = f:addBag("Second", 10, 0.5)
    local seed = item(first, "Test.SleevesDown", 1)
    seed.alias, seed.protected = "Test.SleevesUp", true
    local selected = item(second, "Test.SleevesUp", 1)
    f:startCondense({rebalance = true})
    local status = finish(f)
    ISInventoryWindowControlHandler_TransferSameType = previous
    assert(status.state == "finished" and #f.transfers == 1 and f.transfers[1].item == selected)
    assert(first:contains(seed) and first:contains(selected) and second:isEmpty())
    assert(f.world:carrying() == 1)
end)

test("Condense prefers even tiny reduction gains and rejects tiny increases for grouping", function()
    local f = condenseFixture()
    local stronger = f:addBag("AlphaStronger", 10, 0.10)
    local matching = f:addBag("ZetaMatching", 10, 0.11)
    local seed = item(matching, "Test.Match", 1)
    seed.protected = true
    local selected = item(f.inventory, "Test.Match", 0.001)
    f:startCondense()
    assert(finish(f).state == "finished" and stronger:contains(selected) and matching:contains(seed))
    assert(#f.transfers == 1 and math.abs(f.world:carrying() - 0.1101) < 0.0000001)
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == 1 and stronger:contains(selected))
end)

test("Condense rejects a grouping exchange with a tiny positive net mass delta", function()
    local f = condenseFixture()
    local stronger = f:addBag("Stronger", 3, 0.5)
    local weaker = f:addBag("Weaker", 4, 0.50001)
    local firstA = item(stronger, "Test.A", 2)
    local firstB = item(stronger, "Test.B", 1)
    local secondA = item(weaker, "Test.A", 2)
    local secondB = item(weaker, "Test.B", 1)
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == 0)
    assert(stronger:contains(firstA) and stronger:contains(firstB) and weaker:contains(secondA) and weaker:contains(secondB))
    assert(math.abs(f.world:carrying() - 3.00003) < 0.0000001)
    weaker.carryFactor = 0.5
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished")
    assert(stronger:contains(firstB) and stronger:contains(secondB) and weaker:contains(firstA) and weaker:contains(secondA))
    assert(math.abs(f.world:carrying() - 3) < 0.0000001)
    local count = #f.transfers
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == count)
end)

print("PASS " .. tests .. " Jobs integration scenarios")
