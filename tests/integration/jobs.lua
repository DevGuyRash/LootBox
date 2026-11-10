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
    function result:getType() return self.kind or "crate" end
    function result:getEffectiveCapacity() return self.capacity end
    function result:getCapacityWeight()
        local total = 0
        for _, item in ipairs(self.items) do total = total + item.weight end
        return total
    end
    function result:hasRoomFor(_, item) return self:getType() == "floor" or self:getCapacityWeight() + item.weight <= self.capacity end
    function result:isItemAllowed() return true end
    function result:isInside() return false end
    function result:isExplored() return self.explored end
    function result:requestServerItemsForContainer()
        self.requested = (self.requested or 0) + 1
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

function Native.new(player)
    local adapter = setmetatable({ player = player }, { __index = Native })
    active.adapter = adapter
    return adapter
end
function Native:isBusy() return self.active ~= nil end
function Native:begin(op)
    assert(not self.active, "The job overlapped native operations")
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
        if state.cleanup > 0 then return nil end
        self.active = nil
        active.restored = true
        return false, "Cancelled"
    end
    local op = state.op
    if active.throwPoll and op.kind == "vehicle" and not active.thrown then
        active.thrown = true
        error("Simulated observation failure during vehicle entry")
    end
    if state.pending > 0 then state.pending = state.pending - 1; return nil end
    if state.effectDone then self.active = nil; return true end
    if op.kind == "approach" then
        local target = op.container and op.container.position or op.square.name
        local withinReach = op.square and not op.exact and active.nearby[active.position] and active.nearby[active.position][target]
        if not withinReach and active.position ~= target then active.visits[#active.visits + 1] = target; active.position = target end
        if active.onApproach then active.onApproach(op) end
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
            local square = active.squares[active.position]
            current.world = { getSquare = function() return square end }
            active.ground[#active.ground + 1] = current
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

local function fixture(capacity)
    local f = { now = 0, position = "source", visits = {}, transfers = {}, deletions = {}, scheduled = {}, ground = {}, squares = {}, nearby = {} }
    f.inventory = container("inventory", capacity or 3, true)
    f.source = container("source", 100)
    f.destination = container("destination", 100)
    f.floor = container("floor", 1000); f.floor.kind = "floor"
    f.sources, f.bins, f.groundSquares = { f.source }, {}, {}
    f.player = { getPlayerNum = function() return 0 end }
    local world = {}
    function world:owns(value) return value and value.owned == true end
    function world:itemId(value) return value.id end
    function world:describe(value) return { fullType = value.fullType, categoryId = "native:Material", labels = {} } end
    function world:protected(value) return value.protected == true end
    function world:name(value) return value.name end
    function world:valid() return true end
    function world:isTrash(value) return value.trash == true end
    function world:vehicle() return {} end
    function world:trashCandidates() return f.bins, {} end
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
        for _, value in ipairs(f.ground) do f.floor.items[#f.floor.items + 1] = value; value.container = f.floor end
    end
    f.world = world
    active = f
    f.jobs = Jobs.new(f.player, world, assert(Categories.new({})))
    return f
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
        if state ~= "running" and state ~= "cancelling" then return f.jobs:status() end
    end
    error("Job did not reach a terminal state")
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

test("empty existing trash before selecting a larger bin", function()
    local f = fixture(10)
    local small, large = container("small trash", 2), container("large trash", 4)
    small.trash, large.trash = true, true; f.bins = { small, large }
    item(small, "Base.ExistingTrash")
    item(f.source, "Base.Heavy", 3)
    start(f, request("trash"))
    assert(finish(f).done == 1)
    assert(#f.deletions == 2 and f.deletions[1].bin == small and f.deletions[1].count == 1)
    assert(f.deletions[2].bin == large and f.deletions[2].count == 1)
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
    local selectedSquare, adjacent = { name = "selected floor" }, { name = "adjacent floor" }
    f.squares[selectedSquare.name], f.squares[adjacent.name] = selectedSquare, adjacent
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
    local destination = { name = "chosen floor" }; f.squares[destination.name] = destination
    local selected = item(f.source)
    start(f, request("floor", destination))
    assert(finish(f).done == 1)
    assert(selected.world and selected.world:getSquare() == destination)
end)

test("floor items can move between squares sharing one native floor view", function()
    local f = fixture(3); f.sources = { f.floor }
    local origin, destination = { name = "origin floor" }, { name = "destination floor" }
    f.squares[origin.name], f.squares[destination.name] = origin, destination
    local selected = item(f.floor)
    selected.world = { getSquare = function() return origin end }
    f.ground = { selected }
    start(f, request("floor", destination))
    assert(finish(f).done == 1)
    assert(selected.world and selected.world:getSquare() == destination and #f.ground == 1)
end)

test("adjacent floor destinations require standing on the chosen square", function()
    local f = fixture(3); f.sources = { f.inventory }; f.position = "origin floor"
    local origin, destination = { name = "origin floor" }, { name = "adjacent destination" }
    f.squares[origin.name], f.squares[destination.name] = origin, destination
    f.nearby[origin.name] = { [destination.name] = true }
    local selected = item(f.inventory)
    start(f, request("floor", destination))
    assert(finish(f).done == 1)
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

print("PASS " .. tests .. " Jobs integration scenarios")
