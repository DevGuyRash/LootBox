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
function Native:beside() return false end
function Native:obstacle() return active.obstacle, active.obstacle and "corpse" end
Native.BATCH = 20
function Native.light(value) return value.weight <= 0.1 end
function Native:reachable(container)
    return active.reachable and active.reachable[container] == true
        or container.trash == true and not active.unloaded[container.position] and active.position == container.position
end
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
    if active.throwPoll == op.kind and not active.thrown then
        active.thrown = true
        error("Simulated observation failure during a native step")
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
        if active.blockedPositions[target] then self.active = nil; return false, "No path to the destination", "unreachable" end
        if op.container and active.lockedVehicle and op.container == active.lockedVehicle.storage then
            self.active = nil
            return false, "The vehicle is locked", "locked"
        end
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
        assert(op.source ~= op.destination, "A transfer must go somewhere else")
        for index, moving in ipairs(op.items or {op.item}) do
            if active.refuseItem and active.refuseItem(moving, op) then
                self.active = nil
                return false, "The game stopped the action before it was done", "refused"
            end
            assert(op.source:contains(moving), "Native transfer source lost the item")
            assert(op.destination:hasRoomFor(self.player, moving), "Native transfer exceeded capacity")
            assert(remove(op.source.items, moving))
            if op.source.kind == "floor" then remove(active.ground, moving); moving.world = nil end
            local current = moving
            if active.rehydrate then
                current = item(op.destination, moving.fullType, moving.weight)
                current.id, current.protected = moving.id, moving.protected
                moving.container = nil
            else
                op.destination.items[#op.destination.items + 1] = current
                current.container = op.destination
            end
            if index == 1 then op.resultItem = current end
            if op.destination.kind == "floor" then
                local square = active.floorDropPoint or active.squares[active.position]
                current.world = { getSquare = function() return square end }
                active.ground[#active.ground + 1] = current
                active.floorDrops[current.id] = {origin = coordinateKey(op.destinationPoint), square = square}
            end
            active.transfers[#active.transfers + 1] = { item = current, source = op.source, destination = op.destination, op = op }
        end
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
    elseif op.kind == "vehicle" then
        if active.lockedVehicle and not op.relock then active.lockedVehicle = nil end
    else error("Unknown native operation") end
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
        grid = {}, unloaded = {}, blockedPositions = {}, approaches = {}, operations = {}, sourceLocations = {}, binLocations = {}, floorDrops = {} }
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
    f.sources, f.bins = { f.source }, {}
    f.player = { getPlayerNum = function() return 0 end,
        getInventory = function() return f.inventory end,
        getVehicle = function() return f.seatedIn end,
        isDead = function() return f.dead == true end, isAsleep = function() return f.asleep == true end,
        getCurrentSquare = function() return f:ensureSquare(f.position) end }
    function f:groundRecords(values)
        local result = {}
        for _, value in ipairs(values or {}) do
            result[#result + 1] = {item = value, source = self.floor, descriptor = self.world:describe(value),
                groundSquare = value.world:getSquare(), itemName = value.fullType, from = "Floor"}
        end
        return result
    end
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
    function world:carried(id, fullType)
        for _, container in ipairs(f.carried) do
            local value = container:getItemWithID(id)
            if value and value.fullType == fullType then return value, container end
        end
    end
    function world:describe(value) return { fullType = value.fullType, categoryId = "native:Material", labels = {} } end
    function world:protected(value) return value.protected == true end
    function world:name(value) return value.name end
    function world:valid() return true end
    function world:filledBag(value) return value.inside and #value.inside.items > 0 and value.inside or nil end
    function world:alreadySorted() return false end
    function world:destinationPass() return {} end
    function world:gearRecords() return {} end
    function world:safeStagingContainers() return f.safeCandidates or {} end
    function world:isTrash(value) return value.trash == true end
    function world:vehicle() return {} end
    function world:deletionAllowed() return not f.client or f.allowTrash ~= false end
    function world:binKey(value) return value.trash and value.name or nil end
    function world:bins()
        local result, here = {}, self:point()
        for _, bin in ipairs(f.bins) do
            f.binLocations[bin.name] = f.binLocations[bin.name] or bin
            local at = self:square(bin)
            if f.binLocations[bin.name].trash then
                result[#result + 1] = {key = bin.name, point = {x = at.x, y = at.y, z = at.z}, capacity = bin.capacity,
                    away = math.sqrt((at.x - here.x) ^ 2 + (at.y - here.y) ^ 2)}
            end
        end
        if #result > 0 then return result end
        return nil, "No trash can is known yet"
    end
    function world:resolveBin(target)
        local current = f.binLocations[target.key]
        if f.unloaded[current.position] then return nil, "unloaded" end
        if not current.trash then return nil, "The trash can is gone" end
        target.capacity = current.capacity
        return current
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
            return {items = {}, sources = {}, warnings = {}, survey = f.survey}
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
        for _, record in ipairs(f:groundRecords(f.groundItems)) do records[#records + 1] = record end
        return { items = records, sources = endpoints, warnings = {} }
    end
    function world:sectionTarget(section)
        return {x = section.target.x, y = section.target.y, z = section.target.z}
    end
    function world:scanSection(section)
        local result = {items = {}, sources = {}, warnings = {}}
        local missing = f.unloaded[section.target.name] and 1 or section.missing or 0
        if missing == 0 or section.inspectLoadedPart then
            for _, source in ipairs(section.sources or {}) do
                result.sources[#result.sources + 1] = source
                if source.explored then
                    for _, record in ipairs(self:records(source)) do result.items[#result.items + 1] = record end
                end
            end
            for _, record in ipairs(f:groundRecords(section.groundItems)) do result.items[#result.items + 1] = record end
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
    -- The game's loot window: multiplayer asks the server once, single player rolls loot at once.
    function f.loot:checkExplored(source)
        if source.explored then return end
        if f.client then source:requestServerItemsForContainer() elseif source.reply then source.reply() end
        source.explored = true
    end
    function f.loot:refreshBackpacks()
        f.refreshes = (f.refreshes or 0) + 1
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

local function building(f, sections)
    local index, pending, processed, searched, unsearched, failures = 0, nil, 0, 0, 0, {}
    for _, section in ipairs(sections) do f:addSquare(section.target) end
    local survey = {building = {}, complete = false}
    function survey:next()
        assert(not pending, "A section cannot be skipped while its result is pending")
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

-- Starts without asking at trash cans, which is how the mod is set by default.
local function quick(f, input)
    assert(f.jobs:start(assert(f.jobs:preview(input)), {reviewBins = false}))
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
    assert(f.jobs:pause())
    local stopped = finish(f)
    assert(stopped.state == "paused" and stopped.canResume, "A settled pause must retain a resumable checkpoint")
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
    quick(f, request("trash"))
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
    assert(#f.deletions == 3 and f.deletions[1].count == 2 and f.deletions[2].count == 1 and f.deletions[3].count == 2)
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
    quick(f, request("trash"))
    local status = finish(f)
    assert(status.state == "paused" and status.carried == 1 and #f.deletions == 0 and bin:contains(existing))
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

test("a multiplayer container that fills after opening ends like any other", function()
    local f = fixture(3); f.client = true; f.source.explored = false
    f.onApproach = function(op) if op.container == f.source then f.loot:checkExplored(f.source) end end
    f.source.reply = function() item(f.source); item(f.source) end
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.done == 2 and #f.inventory.items == 2 and f.source.requested == 1)
    assert(status.state == "finished" and status.skipped == 0 and #status.reasons == 0)
end)

test("a multiplayer container that looks empty is noted without spoiling the result", function()
    local f = fixture(3); f.client = true; f.source.explored = false
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.state == "finished" and status.done == 0 and status.skipped == 0)
    assert(#status.reasons == 1 and status.reasons[1].reason:find("Looked empty", 1, true))
end)

test("a multiplayer container that fills late is read once more before the job ends", function()
    local f = fixture(9); f.client = true; f.source.explored = false
    local other = container("other crate", 100); f.sources[2] = other
    item(other, "Base.Nails")
    start(f)
    for _ = 1, 200 do tick(f); if #f.transfers > 0 then break end end
    local late = item(f.source, "Base.Late")
    local status = finish(f)
    assert(status.state == "finished" and status.done == 2 and #status.reasons == 0 and f.destination:contains(late))
end)

test("floor inspection excludes adjacent unselected squares", function()
    local f = fixture(3); f.onlyGround = true; f.sources = {}
    local selectedSquare, adjacent = f:addSquare(square("selected floor", 20, 0)), f:addSquare(square("adjacent floor", 21, 0))
    local selected = item(f.floor, "Base.Selected")
    local other = item(f.floor, "Base.Adjacent")
    selected.world = { getSquare = function() return selectedSquare end }
    other.world = { getSquare = function() return adjacent end }
    f.ground = { selected, other }
    f.groundItems = { selected }
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

test("one thrown error skips its item after native restoration and the job goes on", function()
    local f = fixture(3); f.sources = { f.inventory }; f.throwPoll = "transfer"
    local first, second = item(f.inventory), item(f.inventory)
    start(f)
    local status = finish(f)
    assert(f.thrown and f.restored and not f.adapter:isBusy())
    assert(status.state == "finished_with_skips" and status.skipped == 1 and status.done == 1)
    assert(f.inventory:contains(first) and f.destination:contains(second))
    assert(status.reasons[1].reason:find("internal error", 1, true))
end)

test("repeated errors pause the job so it can be resumed past the bad items", function()
    local f = fixture(9)
    for _ = 1, 5 do item(f.source) end
    start(f)
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    local advance = f.jobs.advance
    function f.jobs:advance() error("Simulated defect") end
    local stopped = finish(f)
    assert(stopped.state == "paused" and stopped.canResume and stopped.skipped == 3)
    f.jobs.advance = advance
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 2 and #f.destination.items == 2)
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
        {roomId = "upper", roomName = "Upper bedroom", z = 1, target = upper, groundItems = f.ground},
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
    assert(#f.ground == 0 and #bin.items == 0 and #f.deletions == 4)
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
    f.groundItems = f.ground
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
    quick(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and #f.deletions == 2 and f.deletions[1].count == 1 and f.deletions[2].count == 1)
end)

test("a can that could not be reached is not tried again in the same run", function()
    local f = fixture(1)
    local blocked, reachable = container("blocked bin", 10), container("reachable bin", 10)
    blocked.trash, reachable.trash, f.bins = true, true, {blocked, reachable}
    f:addSquare(square(blocked.position, 1, 0)); f:addSquare(square(reachable.position, 2, 0))
    f.blockedPositions[blocked.position] = true
    for _ = 1, 3 do item(f.source) end
    start(f, request("trash"))
    local status = finish(f)
    assert(status.done == 3 and status.skipped == 0 and f.approaches[blocked.position] == 1)
    assert(#f.deletions == 3)
    for _, deletion in ipairs(f.deletions) do assert(deletion.bin == reachable and deletion.count == 1) end
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

test("new bin contents are never deleted without asking when asking is on", function()
    local f = fixture(2)
    local bin = container("changing bin", 2); bin.trash, f.bins = true, {bin}
    for _ = 1, 2 do item(f.source) end
    local outsider
    f.onTransfer = function(op)
        if op.destination == bin and not outsider then outsider = item(bin, "Base.Unapproved") end
    end
    start(f, request("trash"))
    awaitState(f, "needs_review")
    assert(f.jobs:rejectBin(assert(f.jobs:reviewBin())))
    local status = awaitState(f, "paused")
    assert(status.done == 1 and status.carried == 1 and bin:contains(outsider) and #f.deletions == 0)
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    assert(finish(f).done == 2 and not outsider:getContainer())
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
    assert(ended.state == "paused" and ended.canResume and ended.carried == 1 and #f.deletions == 0)
end)

test("a newly discovered empty bin replaces an inaccessible bin without a question", function()
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
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and status.carried == 0)
    assert(#f.deletions == 1 and f.deletions[1].bin == fresh and f.deletions[1].count == 1)
    assert(#f.transfers == 2, "The carried item continues to the other can")
end)

test("approving a bin preserves the building survey and original item selection", function()
    local f = fixture(1)
    local bin = container("outside bin", 4)
    bin.trash, f.bins = true, {bin}; item(bin, "Base.Existing")
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
    assert(paused.survey.roomsTotal == 2 and paused.carried == 1 and #f.deletions == 0)
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
    bin.trash, f.bins = true, {bin}; item(bin, "Base.Existing")
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    local added = item(bin, "Base.NewUnapproved")
    review.moves[1], review.canApprove = {itemName = added.fullType, from = "Bin", to = "Delete"}, true
    assert(not f.jobs:approveBin(review))
    assert(f.jobs:status().state == "needs_review" and f.inventory:contains(selected) and bin:contains(added))
    assert(#f.deletions == 0)
    local fresh = assert(f.jobs:reviewBin())
    assert(#fresh.moves == 2 and fresh.moves[2].itemName == added.fullType)
    assert(not f.jobs:approveBin(review) and not f.jobs:rejectBin(review), "Refreshing review invalidates its older token")
    assert(f.jobs:cancel() and finish(f).state == "cancelled")
    assert(bin:contains(added) and f.inventory:contains(selected))
end)

test("contents that become protected after review require another decision", function()
    local f = fixture(2)
    local bin = container("changing protected review", 4)
    bin.trash, f.bins = true, {bin}
    local existing = item(bin, "Base.Existing")
    item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(review.canApprove and #review.moves == 1)
    existing.protected = true
    assert(not f.jobs:approveBin(review))
    local fresh = assert(f.jobs:reviewBin())
    assert(not fresh.canApprove and #fresh.skipped == 1 and fresh.skipped[1].status == "Protected")
    fresh.canApprove, fresh.skipped = true, {}
    assert(not f.jobs:approveBin(fresh), "Changing the shown review approves nothing")
    assert(f.jobs:cancel() and finish(f).state == "cancelled")
    assert(bin:contains(existing) and #f.deletions == 0)
end)

test("rejecting a reviewed bin inspects another without discarding source selection", function()
    local f = fixture(2)
    local first, second = container("first bin", 4), container("second bin", 4)
    first.trash, second.trash = true, true
    f.bins = {first, second}
    f:addSquare(square(first.position, 10, 0)); f:addSquare(square(second.position, 20, 0))
    local retained = item(first, "Base.ExistingFirst")
    item(second, "Base.ExistingSecond"); item(f.source, "Base.Selected")
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local declined = assert(f.jobs:reviewBin())
    assert(declined.bin.name == first.name and #f.transfers == 1)
    assert(f.jobs:rejectBin(declined))
    awaitState(f, "needs_review")
    local accepted = assert(f.jobs:reviewBin())
    assert(accepted.bin.name == second.name and accepted.canApprove and #f.transfers == 1)
    assert(f.jobs:approveBin(accepted))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and first:contains(retained))
    assert(#f.deletions == 1 and f.deletions[1].bin == second)
    assert(f.approaches[first.position] == 1, "The rejected bin must not be selected again by the current job")
end)

test("moving away from the bin blocks approval without losing the paused job", function()
    local f = fixture(2)
    local bin = container("reachable review bin", 4)
    bin.trash, f.bins = true, {bin}; item(bin, "Base.Existing")
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    f.position = "source"
    assert(not f.jobs:approveBin(review))
    assert(f.jobs:status().state == "needs_review" and f.inventory:contains(selected) and #f.deletions == 0)
    f.position = bin.position
    assert(f.jobs:approveBin(review))
    assert(finish(f).done == 1)
end)

test("cancelling a paused review invalidates its approval and rejection tokens", function()
    local f = fixture(2)
    local bin = container("cancelled review bin", 4)
    bin.trash, f.bins = true, {bin}; item(bin, "Base.Existing")
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local review = assert(f.jobs:reviewBin())
    assert(f.jobs:cancel() and f.jobs:status().state == "cancelling")
    assert(not f.jobs:approveBin(review) and not f.jobs:rejectBin(review))
    assert(finish(f).state == "cancelled")
    assert(not f.jobs:reviewBin() and not f.jobs:approveBin(review) and not f.jobs:rejectBin(review))
    assert(f.inventory:contains(selected) and #f.deletions == 0)
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
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0 and #f.source.items == 1)
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
    assert(#plan.moves == 0 and #plan.skipped == 1 and #plan.skipped[1].reason > 0)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 0 and status.skipped == 0)
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
        assert(status.done == 1 and status.skipped == 0 and mass == hardLimit)
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
    assert(status.done == 2 and status.skipped == 0 and mass == 50)
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
    assert(status.done == 2 and status.skipped == 0 and f.inventory:contains(first) and f.inventory:contains(second))
    assert(f.source:contains(forbidden) and f.source:contains(refused) and #f.inventory.items == 2)
end)

test("nil cannot approve or reject a bin before a review token is issued", function()
    local f = fixture(2)
    local bin = container("unissued bin review", 4)
    bin.trash, f.bins = true, {bin}; item(bin, "Base.Existing")
    local selected = item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    assert(not f.jobs:approveBin(nil) and not f.jobs:rejectBin(nil))
    assert(f.jobs:status().state == "needs_review" and f.inventory:contains(selected))
    assert(#f.deletions == 0)
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
    assert(result.state == "finished" and result.done == 1 and result.skipped == 0)
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
    assert(stopped.state == "paused" and stopped.canResume and #f.transfers == 0)
    assert(not f.jobs:resume())
    for _ = 1, 10 do tick(f) end
    assert(#f.transfers == 0)
    f.takeover = nil
    assert(f.jobs:resume())
    local result = finish(f)
    assert(result.done == 2 and result.skipped == 0 and #f.destination.items == 2)
end)

test("a completed pickup during pause is counted exactly once after resume", function()
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
    f.onlyGround, f.floorOnlyHere = true, true
    local selected = item(f.floor)
    selected.world = {getSquare = function() return f.squares.source end}
    f.ground, f.groundItems = {selected}, {selected}
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

test("a protected item added while stopped keeps the can from being emptied after Resume", function()
    local f = fixture(3)
    local bin = container("changed reviewed bin", 4); bin.trash, f.bins = true, {bin}
    item(bin, "Base.Existing"); item(f.source)
    start(f, request("trash"))
    awaitState(f, "needs_review")
    local old = assert(f.jobs:reviewBin())
    stopJob(f)
    local kept = item(bin); kept.protected = true
    assert(f.jobs:resume())
    local status = awaitState(f, "paused")
    assert(status.canResume and status.carried == 1 and not f.jobs:approveBin(old))
    assert(bin:contains(kept) and #f.deletions == 0)
    kept.protected = false
    assert(f.jobs:resume())
    awaitState(f, "needs_review")
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())) and finish(f).done == 1)
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
    quick(f, request("trash"))
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
        quick(f, request("trash"))
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
    quick(f, request("trash"))
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
    quick(f, request("trash"))
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

test("not asking is a choice for one job, and an unopened can is still opened first", function()
    local f = fixture(2)
    local bin = container("unopened bin", 4); bin.trash, bin.explored, f.bins = true, false, {bin}
    local selected, revealed = item(f.source), nil
    bin.reply = function() revealed = item(bin, "Base.Revealed") end
    quick(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.skipped == 0 and bin.explored and not selected:getContainer() and not revealed:getContainer())
    f.position, bin.explored = "source", false
    item(f.source)
    start(f, request("trash"))
    local paused = awaitState(f, "needs_review")
    assert(paused.done == 0 and bin:contains(revealed))
end)

test("skip-review never approves protected bin contents", function()
    local f = fixture(2)
    local bin = container("protected skip bin", 4); bin.trash = true
    local kept = item(bin)
    local selected = item(f.source)
    f.bins = {bin}
    local plan = assert(f.jobs:preview(request("trash")))
    assert(f.jobs:start(plan, {reviewBins = false}))
    kept.protected = true
    local status = finish(f)
    assert(status.state == "paused" and status.done == 0 and status.carried == 1 and #f.deletions == 0)
    assert(bin:contains(kept) and f.inventory:contains(selected))
end)

test("invalid approval cannot turn off future bin reviews", function()
    local f = fixture(2)
    local bin = container("policy token bin", 4); bin.trash = true; item(bin, "Base.Existing")
    f.bins = {bin}; item(f.source)
    start(f, request("trash"))
    local first = awaitState(f, "needs_review")
    assert(not f.jobs:approveBin({}, {reviewBins = false}))
    assert(f.jobs:status().reviewBins and f.jobs:status().reviewId == first.reviewId)
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    assert(finish(f).done == 1)
end)

test("manual pause preserves work while allowing a new reviewed plan", function()
    local f = fixture(2)
    item(f.source); item(f.source)
    start(f)
    awaitOperation(f, function(op) return op.kind == "approach" end)
    assert(f.jobs:status().canPause and f.jobs:pause())
    local status = awaitState(f, "paused")
    assert(status.canResume and not status.canPause and #f.transfers == 0)
    assert(f.jobs:preview(request("inventory")))
    assert(f.jobs:resume())
    assert(finish(f).done == 2 and #f.transfers == 4)
end)

test("shortcut readiness follows the running job and permits fresh work after settled cancellation", function()
    local f = fixture(2)
    local old = item(f.source, "Test.Old", 1)
    local selected = item(f.source, "Test.New", 1)
    local original = request("container", f.destination)
    original.filter = {all = false, ids = {}, types = {"Test.Old"}}
    original.shortcutIntent = "matching:put"
    assert(f.jobs:status().state == "idle" and f.jobs:status().canStart and f.jobs:status().hasJob == false)
    start(f, original)
    assert(not f.jobs:status().canStart and f.jobs:status().hasJob == true)
    assert(f.jobs:status().intent == "matching:put" and f.jobs:status().action == "transfer")
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    assert(f.adapter:isBusy() and not f.jobs:status().canStart)
    assert(f.jobs:pause() and not f.jobs:status().canStart and f.jobs:status().hasJob == true)
    local paused = awaitState(f, "paused")
    assert(paused.canResume and paused.canStart and paused.hasJob == true and #f.transfers == 0)
    assert(f.jobs:preview(original))
    assert(f.jobs:resume() and not f.jobs:status().canStart)
    assert(f.jobs:cancel() and not f.jobs:status().canStart)
    local cancelled = finish(f)
    assert(cancelled.state == "cancelled" and not cancelled.canResume and cancelled.canStart and cancelled.hasJob == false)
    assert(cancelled.intent == nil and cancelled.action == nil)
    local fresh = request("inventory")
    fresh.filter = {all = false, ids = {}, types = {"Test.New"}}
    local plan = assert(f.jobs:preview(fresh))
    assert(f.jobs:status().state == "cancelled" and #f.transfers == 0 and f.source:contains(old))
    assert(f.jobs:start(plan) and not f.jobs:status().canStart)
    local finished = finish(f)
    assert(finished.state == "finished" and finished.canStart and finished.done == 1 and finished.hasJob == false)
    assert(#f.transfers == 1 and f.transfers[1].item == selected and f.inventory:contains(selected))
    assert(f.source:contains(old) and f.destination:isEmpty())
    local reviewing = fixture(2)
    local bin = container("shortcut review bin", 4)
    bin.trash = true; item(bin, "Base.Existing")
    reviewing.bins = {bin}; item(reviewing.source)
    start(reviewing, request("trash"))
    local binReview = awaitState(reviewing, "needs_review")
    assert(not binReview.canStart and binReview.hasJob == true)
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
    quick(f, request("trash"))
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
    quick(f, request("trash"))
    local status = finish(f)
    assert(status.done == 1 and status.total == 1 and status.moved == 1 and status.cleared == 0 and status.skipped == 0)
    assert(#f.transfers == 2 and #f.deletions == 2 and not selected:getContainer() and not foreign:getContainer())
end)

local function recoveryFixture(f, personal)
    local safe = container("personal safe cupboard", 100)
    local point = f:ensureSquare(safe.position)
    f.safeCandidates = {safe}
    local recovery = {pending = false, personal = personal, safe = safe}
    function recovery:status() return {pending = self.pending, blocking = self.pending and not f.inventory:contains(personal),
        point = self.pending and {x = point.x, y = point.y, z = point.z} or nil} end
    function recovery:endpoint() return safe end
    function recovery:forget() self.pending, self.forgotten = false, true end
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
    assert(failed.hasJob == true and failed.canStart, "Staged gear must not keep other jobs from starting")
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

test("gear that cannot be put down costs only the heavy item and leaves nothing reserved", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Personal", 1); personal.protected = true
    local heavy, other = item(f.source, "Base.Heavy", 3), item(f.source, "Base.Other", 1)
    local bin = container("trash", 4); bin.trash = true; f.bins = {bin}
    local recovery, safe = recoveryFixture(f, personal)
    f.blockedPositions[safe.position] = true
    quick(f, request("trash"))
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 1 and status.skipped == 1, status.reason)
    assert(f.source:contains(heavy) and not other:getContainer() and f.inventory:contains(personal))
    assert(recovery.forgotten and not recovery.pending)
end)

test("gear already put down is fetched back when staging the rest fails", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Personal", 1); personal.protected = true
    local heavy = item(f.source, "Base.Heavy", 3)
    local bin = container("trash", 4); bin.trash = true; f.bins = {bin}
    local recovery, safe = recoveryFixture(f, personal)
    function recovery:next(mode)
        if mode == "stage" and safe:contains(personal) then return nil, "The cupboard is full" end
        if mode == "restore" and f.inventory:contains(personal) then self.pending = false; return nil, nil, true end
        local out = mode == "stage"
        return {kind = "transfer", item = personal, source = out and f.inventory or safe, destination = out and safe or f.inventory, personalRecovery = true}
    end
    quick(f, request("trash"))
    local status = finish(f)
    assert(status.state == "finished_with_skips" and f.inventory:contains(personal) and f.source:contains(heavy))
    assert(not recovery.pending and not recovery.forgotten)
end)

test("a heavy load still finishes after the player fetched the gear by hand", function()
    local f = fixture(3)
    local personal = item(f.inventory, "Base.Personal", 1); personal.protected = true
    local heavy = item(f.source, "Base.Heavy", 3)
    local bin = container("trash", 4); bin.trash = true; f.bins = {bin}
    local recovery, safe = recoveryFixture(f, personal)
    quick(f, request("trash"))
    awaitOperation(f, function(op) return op.kind == "approach" and op.container == bin end)
    stopJob(f)
    assert(remove(safe.items, personal)); f.hardLimit = 4
    f.inventory.items[#f.inventory.items + 1], personal.container, recovery.pending = personal, f.inventory, false
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and not heavy:getContainer(), status.reason)
end)

test("pausing a bin review requires a new generation and token before Resume continues", function()
    local f = fixture(2)
    local bin = container("paused generation bin", 4); bin.trash = true; item(bin, "Base.Existing")
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
    Carry.next = function(_, _, work)
        assert(#work == 2)
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

test("loot-pane previews own their captured source list rather than a mutable caller list", function()
    local f = fixture(20)
    local selected = item(f.source)
    local input = request("inventory")
    input.scope, input.sourceContainers = "lootPane", {f.source}
    local plan = assert(f.jobs:preview(input))
    assert(plan.request.sourceContainers ~= input.sourceContainers)
    input.sourceContainers[1] = f.destination
    assert(f.jobs.reviews[plan].request.sourceContainers[1] == f.source)
    plan.request.sourceContainers[1] = f.destination
    assert(f.jobs.reviews[plan].request.sourceContainers[1] == f.source)
    assert(f.jobs:start(plan))
    assert(finish(f).done == 1 and f.inventory:contains(selected))
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

test("a full first matching crate leaves its item carried and moves later distinct types", function()
    local f = matchingFixture(20)
    local full, available = f.destination, container("available matching crate", 20)
    full.capacity = 1
    item(full, "Base.Nails", 1)
    f.nearbyTargets = {full, available}
    f.targetTypes[available] = {["Base.Plank"] = true}
    local blocked = item(f.inventory, "Base.Nails", 1)
    local movable = item(f.inventory, "Base.Plank", 1)
    local plan = assert(f.jobs:preview(matchingRequest()))
    assert(#plan.moves == 1 and #plan.skipped == 1)
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.state == "finished" and status.moved == 1)
    assert(f.inventory:contains(blocked) and available:contains(movable))
    assert(not status.hasJob and status.canStart)
end)

test("matching crate filling after preview still skips only that type and continues", function()
    local f = matchingFixture(20)
    local full, available = f.destination, container("later available crate", 20)
    full.capacity = 1
    f.nearbyTargets = {full, available}
    f.targetTypes[available] = {["Base.Plank"] = true}
    local blocked, movable = item(f.inventory, "Base.Nails", 1), item(f.inventory, "Base.Plank", 1)
    local plan = assert(f.jobs:preview(matchingRequest()))
    assert(#plan.moves == 2)
    item(full, "Base.Nails", 1)
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.moved == 1)
    assert(f.inventory:contains(blocked) and available:contains(movable))
end)

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
    assert(status.state == "finished" and status.done == 2 and status.skipped == 0 and #f.transfers == 2)
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
    f.world.player, f.world.state = f.player, {containerLabels = {}}
    for _, name in ipairs({"bags", "kinds", "meantFor"}) do f.world[name] = require("LootBox/World")[name] end
    function f.world:carryFactor(value) return value.carryFactor or 1 end
    function f.inventory:isRemoveItemAllowed() return true end
    function f.player:isEquipped(value) return value.equipped == true end
    function f:addBag(name, capacity, factor, equipped, parent)
        parent = parent or self.inventory
        local inside = self:carryContainer(container(name, capacity), factor)
        local value = item(parent, "Test." .. name, 0)
        value.equipped = equipped ~= false
        function value:IsInventoryContainer() return true end
        function value:getCategory() return "Container" end
        function value:getInventory() return inside end
        function value:getEquipParent() return self.held and f.player or nil end
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
    -- Carrying 5.9: the nine needs 14.9 to pass through the inventory.
    f.hardLimit = 14
    f:startCondense({rebalance = true})
    local blocked = finish(f)
    assert(blocked.state == "finished" and #f.transfers == 0 and blocked.reason:find("for a moment", 1, true))
    f.hardLimit = 15
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and math.abs(f.world:carrying() - 5.5) < 0.0001)
end)

test("Condense needs full carrying room only for a bag held in a hand, as the game does", function()
    for _, held in ipairs({false, true}) do
        local f = condenseFixture()
        local strong, strongItem = f:addBag("Strong", 10, 0.2)
        local weak = f:addBag("Weak", 100, 0.5)
        strongItem.held = held
        item(f.inventory, "Test.Keep", 47).protected = true
        local selected = item(weak, "Test.Can", 2.8)
        -- Carrying 48.4 of 50.
        f:startCondense({rebalance = true})
        assert(finish(f).state == "finished")
        assert(strong:contains(selected) == not held and weak:contains(selected) == held)
    end
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
    assert(paused.canResume and f.jobs:previewCondense())
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
    assert(status.reason:find("cannot be read", 1, true))
    f.inventory.owned, f.onTransfer = true, nil
    assert(f.jobs:resume())
    assert(finish(f).state == "finished" and #f.transfers == 1)
end)

test("unwanted items are left whenever loot is taken, and never when they are moved elsewhere", function()
    local f = fixture(10)
    local wanted = item(f.source)
    local unwanted = item(f.source)
    unwanted.isUnwanted = function(_, player) return player == f.player end
    local plan = assert(f.jobs:preview(request("inventory")))
    assert(#plan.moves == 1 and plan.records[1].item == wanted)
    wanted.isUnwanted = function() return true end
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.moved == 0 and f.source:contains(wanted) and f.source:contains(unwanted) and #f.transfers == 0)
    assert(#assert(f.jobs:preview(request("container", f.destination))).moves == 2, "Only taking loot leaves unwanted items")
    local strict = request("container", f.destination); strict.excludeUnwanted = true
    assert(#assert(f.jobs:preview(strict)).moves == 0)
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

test("Condense never adds weight to keep things together", function()
    local f = condenseFixture()
    local stronger = f:addBag("Stronger", 3, 0.5)
    local weaker = f:addBag("Weaker", 4, 0.51)
    local firstA = item(stronger, "Test.A", 2)
    local firstB = item(stronger, "Test.B", 1)
    local secondA = item(weaker, "Test.A", 2)
    local secondB = item(weaker, "Test.B", 1)
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == 0)
    assert(stronger:contains(firstA) and stronger:contains(firstB) and weaker:contains(secondA) and weaker:contains(secondB))
    assert(math.abs(f.world:carrying() - 3.03) < 0.0000001)
    weaker.carryFactor = 0.5
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished")
    assert(stronger:contains(firstB) and stronger:contains(secondB) and weaker:contains(firstA) and weaker:contains(secondA))
    assert(math.abs(f.world:carrying() - 3) < 0.0000001)
    local count = #f.transfers
    f:startCondense({rebalance = true})
    assert(finish(f).state == "finished" and #f.transfers == count)
end)

local function randomizer(seed)
    return function(low, high)
        seed = seed * 16807 % 2147483647
        return low + math.floor(seed / 2147483647 * (high - low + 1))
    end
end

-- The least that could be carried, from trying every placement.
local function lightest(f, bags, rebalance)
    local places, loads, fixed = {{factor = 1, room = math.huge}}, {}, 0
    for _, value in ipairs(f.inventory.items) do if value.weight > 0 then loads[#loads + 1] = value.weight end end
    for _, bag in ipairs(bags) do
        local room = bag.capacity
        for _, value in ipairs(bag.items) do
            if rebalance then loads[#loads + 1] = value.weight else room, fixed = room - value.weight, fixed + value.weight * bag.carryFactor end
        end
        places[#places + 1] = {factor = bag.carryFactor, room = room}
    end
    table.sort(loads, function(a, b) return a > b end)
    local best = math.huge
    local function place(index, mass)
        if mass >= best then return end
        if not loads[index] then best = mass; return end
        for _, target in ipairs(places) do
            if loads[index] <= target.room + 0.00001 then
                target.room = target.room - loads[index]
                place(index + 1, mass + loads[index] * target.factor)
                target.room = target.room + loads[index]
            end
        end
    end
    place(1, fixed)
    return best
end

test("Condense reaches the least weight possible, in either mode, on small inventories", function()
    local weights, factors = {0.1, 0.2, 0.3, 0.5, 0.8, 1, 1.5, 2, 2.5, 3, 4, 5, 6}, {0.15, 0.2, 0.3, 0.35, 0.5}
    for seed = 1, 40 do
        for _, rebalance in ipairs({true, false}) do
            local random, f, bags = randomizer(seed * 7919), condenseFixture(), {}
            f.hardLimit = 1000
            for index = 1, 2 + seed % 2 do bags[index] = f:addBag("Bag" .. index, random(4, 10), factors[random(1, #factors)]) end
            for _ = 1, 7 do
                local weight, source = weights[random(1, #weights)], f.inventory
                local bag = bags[random(1, #bags)]
                if random(1, 2) == 1 and bag:getCapacityWeight() + weight <= bag.capacity then source = bag end
                item(source, "Test.Kind" .. random(1, 4), weight)
            end
            local best, kept = lightest(f, bags, rebalance), {}
            for _, bag in ipairs(bags) do for _, value in ipairs(bag.items) do kept[value] = bag end end
            local plan = assert(f.jobs:previewCondense({rebalance = rebalance}))
            if #plan.moves > 0 then assert(f.jobs:start(plan)); assert(finish(f).state == "finished") end
            assert(math.abs(f.world:carrying() - best) < 0.0001, "Seed " .. seed .. " carries " .. f.world:carrying() .. ", not " .. best)
            if not rebalance then for value, bag in pairs(kept) do assert(bag:contains(value)) end end
            assert(#assert(f.jobs:previewCondense({rebalance = rebalance})).moves == 0, "Seed " .. seed .. " is not settled")
        end
    end
end)

test("Condense starts moving at once and moves almost nothing twice in a large inventory", function()
    local random, f, bags = randomizer(4), condenseFixture(), {}
    f.hardLimit = 1000
    for index, entry in ipairs({{28, 0.15}, {18, 0.35}, {6, 0.5}}) do bags[index] = f:addBag("Bag" .. index, entry[1], entry[2]) end
    local weights, total = {0.1, 0.1, 0.2, 0.3, 0.5, 0.8, 1, 1.5, 2, 3}, 0
    for _ = 1, 80 do
        local weight, source = weights[random(1, #weights)], f.inventory
        local bag = bags[random(1, #bags)]
        if random(1, 10) < 8 and bag:getCapacityWeight() + weight <= bag.capacity then source = bag end
        item(source, "Test.Kind" .. random(1, 20) .. ":" .. weight, weight)
        total = total + weight
    end
    f:startCondense({rebalance = true})
    for _ = 1, 2 do tick(f) end
    assert(f.adapter.active, "The first move waits for planning")
    local status = finish(f)
    -- Every bag filled to the brim, the best first.
    local least = 28 * 0.15 + 18 * 0.35 + 6 * 0.5 + (total - 52)
    assert(status.state == "finished" and total > 52 and math.abs(f.world:carrying() - least) < 0.0001)
    local moves, again = {}, 0
    for _, entry in ipairs(f.transfers) do
        moves[entry.item.id] = (moves[entry.item.id] or 0) + 1
        if moves[entry.item.id] == 2 then again = again + 1 end
        assert(moves[entry.item.id] <= 2)
    end
    assert(#f.transfers < 80 and again <= 4, #f.transfers .. " moves, " .. again .. " items moved twice")
end)

test("Condense leaves an arrangement alone when no real weight can be saved", function()
    local f = condenseFixture()
    local strong, weak = f:addBag("Strong", 6, 0.15), f:addBag("Weak", 20, 0.35)
    -- 0.1, 0.2 and 0.3 add up to slightly different sums in different orders.
    for index = 1, 10 do item(strong, "Test.A", 0.1); item(strong, "Test.B", 0.2); item(strong, "Test.C", 0.3) end
    for index = 1, 10 do item(weak, "Test.D", 0.1); item(weak, "Test.E", 0.2); item(weak, "Test.F", 0.3) end
    local plan = assert(f.jobs:previewCondense({rebalance = true}))
    assert(#plan.moves == 0 and plan.condense.reason == "Your bags are packed.")
end)

test("new manager preview preserves pause until start and Resume invalidates it", function()
    local f = condenseFixture()
    local bag = f:addBag("Strong", 10, 0.1)
    local old = item(f.inventory, "Test.Loose", 2)
    local fresh = item(f.source, "Test.New", 1)
    f:startCondense()
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    assert(f.jobs:pause()); awaitState(f, "paused")
    local preview = assert(f.jobs:preview(request("inventory")))
    assert(f.jobs:status().canResume and f.jobs.suspended and f.jobs:resume())
    assert(f.jobs:pause()); awaitState(f, "paused")
    assert(not f.jobs:start(preview), "Resume must invalidate the speculative replacement")
    preview = assert(f.jobs:preview(request("inventory")))
    assert(f.jobs:start(preview) and not f.jobs.suspended)
    assert(finish(f).done == 1 and f.inventory:contains(fresh))
    assert(f.inventory:contains(old) and not bag:contains(old) and not f.jobs:resume())
end)

test("Cancel supersedes pending Condense pause and releases the scheduler", function()
    for _, settleFirst in ipairs({false, true}) do
        local f = condenseFixture()
        local bag = f:addBag("Strong", 10, 0.1)
        local selected = item(f.inventory, "Test.Loose", 2)
        f:startCondense()
        awaitOperation(f, function(op) return op.kind == "transfer" end)
        assert(f.jobs:pause())
        if settleFirst then awaitState(f, "paused") end
        assert(f.jobs:cancel())
        if not settleFirst then assert(not f.jobs:status().canStart) end
        local cancelled = finish(f)
        assert(cancelled.state == "cancelled" and not cancelled.canResume and not cancelled.hasJob and cancelled.canStart)
        assert(not f.jobs:resume() and f.jobs.suspended == nil and f.jobs.plan == nil and f.jobs.operation == nil)
        assert(f.inventory:contains(selected) and not bag:contains(selected))
        local fresh = item(f.source, "Test.Fresh", 1)
        local nextRequest = request("inventory")
        nextRequest.filter = {all = false, ids = {}, types = {"Test.Fresh"}}
        start(f, nextRequest)
        assert(finish(f).done == 1 and f.inventory:contains(fresh))
        for _ = 1, 20 do tick(f) end
        assert(f.inventory:contains(selected) and not bag:contains(selected) and #f.transfers == 1)
    end
end)

test("Cancel retains an observed Condense transfer without replaying its continuation", function()
    local f = condenseFixture()
    local bag = f:addBag("Strong", 10, 0.1)
    local first, second = item(f.inventory, "Test.First", 2), item(f.inventory, "Test.Second", 1)
    f.holdTransferResult, f.completeDuringCancel = true, true
    f:startCondense()
    for _ = 1, 30 do tick(f); if #f.transfers == 1 then break end end
    assert(#f.transfers == 1 and bag:contains(first))
    assert(f.jobs:cancel())
    local cancelled = finish(f)
    assert(cancelled.state == "cancelled" and not cancelled.canResume)
    f.holdTransferResult = false
    for _ = 1, 20 do tick(f) end
    assert(#f.transfers == 1 and bag:contains(first) and f.inventory:contains(second))
    assert(f.jobs.operation == nil and f.jobs.pending == nil and f.jobs.suspended == nil)
end)

test("Cancel drops recovery continuation but preserves the personal gear receipt", function()
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
    assert(f.jobs:cancel())
    local cancelled = finish(f)
    assert(not cancelled.canResume and not cancelled.hasJob and recovery.pending and f.jobs.recovery == recovery)
    assert(cancelled.recoveryRequired and cancelled.canStart)
    assert(f.jobs:preview(request("inventory")) and not f.jobs:start({}))
    assert(f.jobs:recoverPersonalGear())
    local recovered = finish(f)
    assert(recovered.state == "finished" and not recovered.canResume and not recovered.hasJob)
    assert(f.jobs.plan == nil and f.jobs.carry == nil and f.jobs.hauled == nil)
    assert(f.inventory:contains(personal) and f.source:contains(selected) and not recovery.pending)
    start(f, request("inventory"))
    awaitOperation(f, function(op) return op.kind == "approach" end)
    assert(f.jobs:pause()); awaitState(f, "paused")
    assert(f.jobs:resume() and finish(f).done == 1)
end)

test("terminal jobs release planning graphs but retain display summaries", function()
    local f = condenseFixture()
    f:addBag("Strong", 10, 0.1)
    item(f.inventory, "Test.Loose", 2)
    f:startCondense()
    local references = setmetatable({f.jobs.plan, f.jobs.execution, f.jobs.execution.condense}, {__mode = "v"})
    local result = finish(f)
    assert(result.state == "finished" and result.condense and not result.hasJob)
    assert(f.jobs.plan == nil and f.jobs.carry == nil and f.jobs.hauled == nil and f.jobs.reviewed == nil)
    -- Kahlua is backed by the JVM, whose explicit GC timing is not a
    -- portable assertion. Controller ownership was checked above in both VMs.
    if _VERSION=="Lua 5.1" and type(collectgarbage)=="function" and type(next)=="function" then
        collectgarbage("collect"); collectgarbage("collect")
        for _ in pairs(references) do error("Finished planning graph must be collectible") end
    end
    -- Terminal failure has the same lifecycle, but failed recovery checkpoints
    -- remain covered by the recovery scenarios above.
    local g = fixture(3)
    item(g.source)
    start(g)
    g.jobs:finishWhenSettled("failed", "Injected terminal failure")
    assert(finish(g).state == "failed" and not g.jobs:status().hasJob)
    assert(g.jobs.plan == nil and g.jobs.carry == nil and g.jobs.hauled == nil)
end)

test("terminal job feedback counts confirmed deliveries once and stays quiet across Pause", function()
    local cards = {}
    PZActionCompletionHUD = {duration = function(seconds) return tostring(math.floor(seconds)) .. "s" end,
        show = function(player, card) assert(player == 0); cards[#cards + 1] = card end}
    local f = fixture(3)
    item(f.source, "Test.A", 1.2)
    item(f.source, "Test.B", 1.3)
    start(f, request("inventory"))
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    assert(#cards == 0)
    stopJob(f)
    assert(#cards == 0)
    f.now = f.now + 1000000
    assert(f.jobs:resume())
    assert(finish(f).moved == 2)
    tick(f)
    assert(#cards == 1 and cards[1].title == "Loot run complete")
    assert(cards[1].detail:find("2 items moved | 2.5 weight | ", 1, true), "Card details use a font-safe ASCII separator")
    assert(not cards[1].detail:find("100", 1, true), "Paused time should not be counted")
    PZActionCompletionHUD = nil
end)

test("cancelling a paused job shows one stopped card and no planned moves", function()
    local cards = {}
    PZActionCompletionHUD = {duration = function() return "2s" end,
        show = function(_, card) cards[#cards + 1] = card end}
    local f = fixture(3)
    item(f.source)
    start(f, request("inventory"))
    stopJob(f)
    assert(#cards == 0 and f.jobs:cancel() and f.jobs:cancel())
    tick(f)
    assert(#cards == 1 and cards[1].title == "Loot run cancelled" and cards[1].status == "stopped")
    assert(cards[1].detail == "2s" and cards[1].note == "Cancelled")
    PZActionCompletionHUD = nil
end)

test("a seated player is told once, at the start, unless nothing needs walking", function()
    local f = fixture(9)
    item(f.source); item(f.source)
    f.seatedIn = {}
    local plan = assert(f.jobs:preview(request("inventory")))
    local started, problem = f.jobs:start(plan)
    assert(not started and problem:find("Get out of the vehicle", 1, true) and f.jobs:status().state == "idle")
    f.seatedIn = nil
    assert(f.jobs:start(plan) and finish(f).done == 2, "The same plan starts after getting out")
    local g = fixture(9)
    item(g.source)
    g.seatedIn, g.reachable = {}, {[g.source] = true}
    start(g, request("inventory"))
    assert(finish(g).done == 1, "Storage within reach of the seat needs no walk")
end)

test("sitting down during a job pauses it once and Resume repeats the same step", function()
    local f = fixture(9)
    item(f.source); item(f.source)
    start(f)
    local seated = true
    function f.adapter:begin(op)
        if op.kind == "approach" and seated then return nil, "Get out of the vehicle to continue", "seated" end
        return Native.begin(self, op)
    end
    local stopped = finish(f)
    assert(stopped.state == "paused" and stopped.skipped == 0 and stopped.reason:find("Get out of the vehicle", 1, true))
    seated = false
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and status.done == 2 and status.skipped == 0)
end)

test("a paused game uses up no deadline", function()
    local g = fixture(3); g.client = true; g.source.explored = false
    start(g, request("inventory"))
    for _ = 1, 50 do tick(g); if g.source.requested then break end end
    g.now = g.now + 60000
    g.source.reply = function() item(g.source) end
    g.scheduled[1] = {at = g.now + 400, run = g.source.reply}
    local status = finish(g)
    assert(status.done == 1 and status.state == "finished", "A minute without ticks must not end the wait for a server reply")
end)

test("leaving a bin during its multiplayer inspection goes back to it", function()
    local f = fixture(2); f.client = true
    local bin = container("inspected bin", 4)
    bin.trash, bin.explored, f.bins = true, false, {bin}
    bin.reply = function() item(bin, "Base.Revealed") end
    item(f.source)
    start(f, request("trash"))
    for _ = 1, 50 do tick(f); if bin.requested then break end end
    f.position = "source"
    local status = awaitState(f, "needs_review")
    assert(f.position == bin.position and status.skipped == 0 and f.approaches[bin.position] >= 2)
    assert(f.jobs:cancel()); finish(f)
end)

test("an empty multiplayer container costs about a second", function()
    local f = fixture(3); f.client = true; f.source.explored = false
    start(f, request("inventory"))
    for _ = 1, 50 do tick(f); if f.source.requested then break end end
    local asked = f.now
    finish(f)
    assert(f.now - asked >= 1000 and f.now - asked <= 2000, "Waited " .. (f.now - asked))
end)

local function lockedCar(f)
    local car = {}
    f.destination.getVehiclePart = function() return {getVehicle = function() return car end} end
    f.lockedVehicle = {storage = f.destination}
    return car
end

local function vehicleSteps(f)
    local result = {}
    for _, op in ipairs(f.operations) do if op.kind == "vehicle" then result[#result + 1] = op end end
    return result
end

test("a vehicle that opens from outside is loaded without sitting in it", function()
    local f = fixture(9)
    lockedCar(f); f.lockedVehicle = nil
    item(f.source)
    start(f, request("vehicle", {}))
    assert(finish(f).state == "finished" and #f.destination.items == 1 and #vehicleSteps(f) == 0)
end)

test("a locked vehicle is unlocked from its seat once, and locked again after the last delivery", function()
    local f = fixture(9); f.sources = {f.source}
    local car = lockedCar(f)
    item(f.source); item(f.source)
    function f.adapter:begin(op)
        if op.kind == "vehicle" and not op.relock then
            op.unlocked = {{vehicle = car, partId = "TrunkDoor"}, {vehicle = car, partId = "DoorFrontLeft"}, {vehicle = car, partId = "TrunkDoor"}}
        end
        return Native.begin(self, op)
    end
    start(f, request("vehicle", car))
    assert(finish(f).state == "finished" and #f.destination.items == 2)
    local steps = vehicleSteps(f)
    assert(#steps == 2 and steps[1].vehicle == car and not steps[1].relock)
    assert(steps[2] == f.operations[#f.operations] and steps[2].vehicle == car
        and table.concat(steps[2].relock, ",") == "TrunkDoor,DoorFrontLeft")
end)

test("a vehicle that cannot be unlocked keeps the load carried and says why", function()
    local f = fixture(9)
    lockedCar(f)
    local selected = item(f.source)
    function f.adapter:begin(op)
        if op.kind == "vehicle" then return nil, "The driver door is locked and you cannot unlock it" end
        return Native.begin(self, op)
    end
    start(f, request("vehicle", {}))
    local status = finish(f)
    assert(status.state == "finished_with_skips" and f.inventory:contains(selected))
    assert(status.reasons[1].reason:find("driver door is locked", 1, true) and status.reasons[1].reason:find("carried storage", 1, true))
end)

test("a vehicle that cannot be locked again is reported", function()
    local f = fixture(9)
    lockedCar(f)
    item(f.source)
    function f.adapter:begin(op)
        if op.relock then return nil, "The driver seat is occupied" end
        if op.kind == "vehicle" then op.unlocked = {{vehicle = op.vehicle, partId = "TrunkDoor"}} end
        return Native.begin(self, op)
    end
    start(f, request("vehicle", {}))
    local status = finish(f)
    assert(status.state == "finished_with_skips" and status.done == 1)
    assert(status.reasons[1].reason:find("left unlocked", 1, true) and status.reasons[1].reason:find("seat is occupied", 1, true))
end)

-- Batches, direct moves and delivery order ----------------------------------

local function transferOps(f)
    local result = {}
    for _, op in ipairs(f.operations) do if op.kind == "transfer" then result[#result + 1] = op end end
    return result
end

local function nails(source, count, fullType)
    local result = {}
    for index = 1, count do result[index] = item(source, fullType or "Base.Nails", 0.05) end
    return result
end

test("a hundred nails are carried and delivered twenty at a time", function()
    local f = fixture(50)
    nails(f.source, 100)
    item(f.source, "Base.Hammer", 1)
    start(f)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 101 and status.moved == 101 and #f.destination.items == 101)
    local ops = transferOps(f)
    assert(#ops == 12, "Five runs and a hammer each way, not " .. #ops)
    for _, op in ipairs(ops) do
        assert(#op.items <= 20)
        for _, value in ipairs(op.items) do assert(value.fullType == op.item.fullType, "Only one type to an action") end
    end
end)

test("a run takes only what fits, what is wanted and what is not protected", function()
    local f = fixture(50)
    f.hardLimit = 0.5
    local loose = nails(f.source, 14)
    loose[3].protected = true
    local plan = assert(f.jobs:preview(request("container", f.destination)))
    loose[5].protected = true
    assert(f.jobs:start(plan))
    local status = finish(f)
    assert(status.done == 12 and status.skipped == 1 and f.source:contains(loose[3]) and f.source:contains(loose[5]))
    local ops = transferOps(f)
    assert(#ops[1].items == 10 and #ops == 4, "Ten nails fill the half kilo that can be carried")
end)

test("an item the game leaves out of a run is tried alone and alone reported", function()
    local f = fixture(50)
    local loose = nails(f.source, 6)
    f.refuseItem = function(value, op) return value == loose[4] and op.destination == f.inventory end
    start(f)
    local status = finish(f)
    assert(status.done == 5 and status.skipped == 1 and status.state == "finished_with_skips")
    assert(f.source:contains(loose[4]) and #f.destination.items == 5)
    for _, op in ipairs(transferOps(f)) do if op.item == loose[4] then assert(#op.items == 1) end end
end)

test("pausing in the middle of a run counts what had moved and continues with the rest", function()
    local f = fixture(50)
    local loose = nails(f.source, 20)
    start(f, request("inventory"))
    awaitOperation(f, function(op) return op.kind == "transfer" end)
    for index = 1, 7 do
        remove(f.source.items, loose[index])
        f.inventory.items[#f.inventory.items + 1], loose[index].container = loose[index], f.inventory
    end
    stopJob(f)
    assert(f.jobs:resume())
    local status = finish(f)
    assert(status.state == "finished" and status.done == 20 and status.moved == 20 and #f.inventory.items == 20)
    local ops = transferOps(f)
    assert(#ops[#ops].items == 13, "What had moved is not asked for again")
end)

test("a delivery that exactly fills a container is accepted, and one nail more is not", function()
    local f = fixture(50)
    f.destination.capacity = 1
    function f.destination:getCapacityWeight()
        local total = 0
        for _, value in ipairs(self.items) do total = total + value.weight end
        return total
    end
    function f.destination:hasRoomFor(_, value) return math.floor((self:getCapacityWeight() + value.weight) * 100 + 0.5) <= 100 end
    for _ = 1, 10 do item(f.source, "Base.Fuse", 0.1 + 1e-9) end
    item(f.source, "Base.Nails", 0.05)
    local plan = start(f)
    assert(#plan.moves == 10 and #plan.skipped == 1)
    local status = finish(f)
    assert(status.state == "finished" and #f.destination.items == 10)
end)

test("with both containers in reach items go straight across and nothing is worn or carried", function()
    local f = fixture(1)
    f.reachable = {[f.source] = true, [f.destination] = true}
    function f.world:gearRecords() error("No bag is needed for what is not carried") end
    item(f.source, "Base.Anvil", 40); item(f.source, "Base.Plank", 3)
    start(f)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 2 and #f.transfers == 2, "The carrying limit does not matter here")
    for _, entry in ipairs(f.transfers) do assert(entry.source == f.source and entry.destination == f.destination) end
end)

test("a direct move the game refuses is carried instead", function()
    local f = fixture(9)
    f.reachable = {[f.source] = true, [f.destination] = true}
    local selected = item(f.source)
    f.refuseItem = function(_, op) return op.source == f.source and op.destination == f.destination end
    start(f)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0 and f.destination:contains(selected))
    assert(#f.transfers == 2 and f.transfers[1].destination == f.inventory)
end)

local function twoLabelled(f)
    local near, far = container("near crate", 100), container("far crate", 100)
    f:addSquare(square("near crate", 12, 0)); f:addSquare(square("far crate", 40, 0))
    function f.world:destinations(input, value)
        if input.destination.kind == "inventory" then return {f.inventory} end
        return {value and value.fullType == "Base.Far" and far or near}
    end
    f.sources = {f.source, f.inventory}
    return near, far, {scope = "room", includeBags = true, filter = {all = true, ids = {}, types = {}}, destination = {kind = "labels", labels = {}}}
end

test("a mixed load makes one stop at each destination, the nearest first", function()
    local f = fixture(50)
    local near, far, input = twoLabelled(f)
    for index = 1, 8 do item(f.source, index % 2 == 0 and "Base.Near" or "Base.Far") end
    start(f, input)
    assert(finish(f).state == "finished" and #near.items == 4 and #far.items == 4)
    assert(table.concat(f.visits, ",") == "near crate,far crate", table.concat(f.visits, ","))
end)

test("a hauled item the player moved to another bag is found by its identity and delivered", function()
    for _, rehydrate in ipairs({false, true}) do
        local f = fixture(9)
        f.rehydrate = rehydrate
        local pocket = f:carryContainer(container("pocket", 9), 1)
        local selected, other = item(f.source, "Base.Nails"), item(f.source, "Base.Plank")
        start(f)
        for _ = 1, 300 do tick(f); if #f.transfers == 2 then break end end
        local held = f.inventory:getItemWithID(selected.id)
        remove(f.inventory.items, held)
        local current = item(pocket, "Base.Nails"); current.id = selected.id
        held.container = nil
        local status = finish(f)
        assert(status.state == "finished" and status.done == 2 and status.carried == 0, tostring(status.reason))
        assert(f.destination:getItemWithID(selected.id) and f.destination:getItemWithID(other.id))
    end
end)

test("a destination that unloads while its load is gathered is walked to before anything is judged", function()
    local f = fixture(1)
    f.destination.capacity = 2
    item(f.source); item(f.source)
    f.onTransfer = function(op) if op.destination == f.inventory then f.unloaded.destination = true end end
    local fresh
    f.onWalk = function(_, target)
        if target == "destination" and not fresh then
            fresh = container("destination", 2)
            f.sourceLocations.destination, f.destination = fresh, fresh
        end
    end
    local input = request("container", f.destination)
    start(f, input)
    local status = finish(f)
    assert(status.state == "finished" and status.done == 2 and status.skipped == 0 and fresh and #fresh.items == 2, tostring(status.reason))
end)

test("three identical refusals in a row pause the job at that item", function()
    local f = fixture(9)
    local items = {}
    for index = 1, 5 do items[index] = item(f.source, "Base.Thing" .. index) end
    local refusing = true
    f.refuseItem = function() return refusing end
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.state == "paused" and status.skipped == 2 and status.reason:find("3 times in a row", 1, true))
    refusing = false
    assert(f.jobs:resume())
    status = finish(f)
    assert(status.done == 3 and f.inventory:contains(items[3]), "The item that brought the pause is not lost")
end)

test("a success in between starts the count of refusals again", function()
    local f = fixture(9)
    local items = {}
    for index = 1, 6 do items[index] = item(f.source, "Base.Thing" .. index) end
    f.refuseItem = function(value) return value ~= items[3] end
    start(f, request("inventory"))
    local status = finish(f)
    assert(status.state == "paused" and status.skipped == 4 and status.done == 1)
end)

test("a corpse in the player's arms pauses the job once and costs no item", function()
    local f = fixture(9)
    item(f.source); item(f.source)
    f.obstacle = "Put down the corpse to continue"
    local plan = assert(f.jobs:preview(request("inventory")))
    local started, why = f.jobs:start(plan)
    assert(not started and why == f.obstacle and f.jobs:status().state ~= "running")
    f.obstacle = nil
    assert(f.jobs:start(plan))
    local begin, dragging = Native.begin, true
    function f.adapter:begin(op)
        if dragging then return nil, "Put down the corpse to continue", "corpse" end
        return begin(self, op)
    end
    local status = finish(f)
    assert(status.state == "paused" and status.skipped == 0 and status.reason:find("corpse", 1, true))
    dragging = false
    assert(f.jobs:resume())
    status = finish(f)
    assert(status.state == "finished" and status.done == 2)
end)

test("the loot window is rebuilt only for a floor item it does not list yet", function()
    local f = fixture(9); f.onlyGround, f.sources = true, {}
    local tile = f:addSquare(square("pile", 20, 0))
    f.groundItems = f.ground
    for index = 1, 4 do
        local selected = item(f.floor, "Base.Thing" .. index)
        selected.world = {getSquare = function() return tile end}
        f.ground[index] = selected
    end
    f.floor.items = {}
    start(f, request("floor", f.squares.destination))
    local status = finish(f)
    assert(status.done == 4 and status.state == "finished")
    assert(f.refreshes == 1, "Rebuilt " .. tostring(f.refreshes) .. " times for four pickups and four drops")
end)

test("staged personal gear does not keep ordinary jobs from running", function()
    local f = fixture(3)
    local personal, selected = item(f.inventory, "Base.Personal", 1), item(f.source)
    local recovery, safe = recoveryFixture(f, personal)
    assert(remove(f.inventory.items, personal)); safe.items[#safe.items + 1], personal.container = personal, safe
    recovery.pending, recovery.failRestore = true, true
    assert(f.jobs:recoverPersonalGear())
    assert(finish(f).state == "failed" and recovery.pending)
    start(f)
    assert(finish(f).done == 1 and f.destination:contains(selected) and safe:contains(personal))
end)

-- The file trace, as the game writes it.
local Log = originalRequire("LootBox/Log")
local function trace(body)
    local lines, savedPrint = {}, print
    local reader, writer = getFileReader, getFileWriter
    Log.flush()
    getFileReader = function() return nil end
    getFileWriter = function() return {write = function(_, text) lines[#lines + 1] = text end, close = function() end} end
    print = function() end
    local ok, err = pcall(body)
    Log.flush()
    getFileReader, getFileWriter, print = reader, writer, savedPrint
    assert(ok, err)
    return table.concat(lines)
end

local function events(text, id)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        local found, name = line:match("#(%S+) (%u[%u%-]+)")
        if found == tostring(id) then result[#result + 1] = {name = name, line = line} end
    end
    return result
end

local function first(list, name)
    for _, entry in ipairs(list) do if entry.name == name then return entry.line end end
    error("No " .. name .. " line was written")
end

test("one interaction number tells what was asked, what happened and why it ended", function()
    local id, f
    local text = trace(function()
        f = fixture(3)
        item(f.source, "Base.Hammer")
        local kept = item(f.source, "Base.Kept"); kept.protected = true
        local denied = item(f.source, "Base.Denied")
        id = Log.intent("menu.container", "Take all", f.player)
        local plan = assert(f.jobs:preview(request("container", f.destination), {interaction = id}))
        assert(f.jobs:start(plan, {interaction = id}) and f.jobs:status().interaction == id)
        function f.adapter:begin(op)
            if op.kind == "transfer" and op.item == denied then return nil, "Simulated native refusal" end
            return Native.begin(self, op)
        end
        assert(finish(f).done == 1)
    end)
    local lines = events(text, id)
    assert(first(lines, "INTENT"):find("menu.container", 1, true))
    local plan = first(lines, "PLAN")
    assert(plan:find("everything", 1, true) and plan:find("records=2", 1, true) and plan:find("skipped=1", 1, true))
    local skipped = first(lines, "PLAN-SKIP")
    assert(skipped:find("count=1", 1, true) and skipped:find("Base.Kept", 1, true))
    assert(first(lines, "PLAN-FROM") and first(lines, "PLAN-TO") and first(lines, "START"))
    local begun, ended, failed = 0, 0, nil
    for _, entry in ipairs(lines) do
        if entry.name == "OP" then begun = begun + 1 end
        if entry.name == "OP-END" then ended = ended + 1; if entry.line:find("result=failed", 1, true) then failed = entry.line end end
    end
    assert(begun > 0 and begun == ended, "Every native operation has a beginning and an end")
    assert(failed and failed:find("WARN", 1, true) and failed:find("Simulated native refusal", 1, true) and failed:find("Base.Denied", 1, true))
    assert(first(lines, "PHASE") and first(lines, "TASK") and first(lines, "SKIP"):find("Simulated native refusal", 1, true))
    local ending = first(lines, "END")
    assert(ending:find("state=finished_with_skips", 1, true) and ending:find("done=1", 1, true) and ending:find("skipped=1", 1, true))
end)

test("a pause names its real trigger and Resume keeps the same number", function()
    local id, f
    local text = trace(function()
        f = fixture(3)
        item(f.source)
        start(f)
        id = f.jobs:status().interaction
        assert(type(id) == "number", "A job without a caller's number opens its own")
        awaitOperation(f, function(op) return op.kind == "transfer" end)
        function f.adapter:takeoverReason() return active.takeover, "combat", active.takeover and "aim" end
        f.takeover = "Aiming paused the job"
        assert(finish(f).state == "paused")
        f.takeover = nil
        assert(f.jobs:resume() and f.jobs:status().interaction == id)
        assert(f.jobs:pause("escape") and finish(f).state == "paused")
        assert(f.jobs:cancel())
    end)
    local lines, pauses = events(text, id), {}
    for _, entry in ipairs(lines) do if entry.name == "PAUSE" then pauses[#pauses + 1] = entry.line end end
    assert(#pauses == 2 and pauses[1]:find("trigger=aim", 1, true) and pauses[2]:find("trigger=escape", 1, true))
    assert(pauses[1]:find("player={", 1, true) and first(lines, "RESUME") and first(lines, "END"):find("state=cancelled", 1, true))
end)

test("a thrown error reaches the log with its item and phase", function()
    local text = trace(function()
        local f = fixture(3)
        item(f.source, "Base.Cursed")
        start(f)
        for _ = 1, 100 do tick(f); if f.adapter.active and f.adapter.active.op.kind == "transfer" then break end end
        f.jobs.advance = function() error("Simulated defect 4711") end
        finish(f)
    end)
    local fault = text:match("[^\n]*FAULT[^\n]*")
    assert(fault and fault:find("Simulated defect 4711", 1, true) and fault:find("Base.Cursed", 1, true) and fault:find("Jobs:source", 1, true))
end)

test("a skipped refusal to start is explained under the caller's number", function()
    local id
    local text = trace(function()
        local f = fixture(3)
        id = Log.intent("window.plan", "Start", f.player)
        local started, problem = f.jobs:start({}, {interaction = id})
        assert(not started and problem == "Preview this job again before starting")
        local plan = f.jobs:preview({scope = "nowhere", filter = {all = true}, destination = {kind = "inventory"}}, {interaction = id})
        assert(plan == nil)
    end)
    local lines = events(text, id)
    assert(first(lines, "START-REFUSED"):find("Preview this job again", 1, true))
    assert(first(lines, "PLAN-REFUSED"):find("Choose a valid source", 1, true))
end)

test("detailed logging off writes no descriptions", function()
    local f
    local described = 0
    local item_, container_ = Log.item, Log.container
    Log.item = function(...) described = described + 1; return item_(...) end
    Log.container = function(...) described = described + 1; return container_(...) end
    Log.detailed = false
    local ok, err = pcall(function()
        f = fixture(3)
        local kept = item(f.source); kept.protected = true
        item(f.source)
        start(f)
        assert(finish(f).done == 1)
    end)
    Log.detailed, Log.item, Log.container = true, item_, container_
    assert(ok, err)
    assert(described == 0, "Descriptions are built only when they will be written")
end)

print("PASS " .. tests .. " Jobs integration scenarios")
