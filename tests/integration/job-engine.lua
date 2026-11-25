-- Real Jobs, World, Categories, Carry and Routing. Only the game boundary is doubled:
-- squares, containers, items and a native adapter that performs each step at once.
if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end

local active
local Native = {}
function Native.new(player) return setmetatable({player = player}, {__index = Native}) end
function Native:isBusy() return self.op ~= nil end
function Native:isPlayerBusy() return false end
function Native:takeoverReason() end
function Native:obstacle() end
function Native:reachable(container) return active.near(active.world:square(container)) end
function Native:beside(square) return active.near(square) end
Native.BATCH = 20
function Native.light(item) return item.weight <= 0.1 end
function Native:cancel() self.op = nil; return true end
function Native:transferResult(op, id)
    if op.source and op.source:containsID(id) then return nil end
    return op.destination and op.destination:getItemWithID(id)
end
function Native:begin(op)
    active.ops[#active.ops + 1] = op
    self.op = op
    return true
end
function Native:poll()
    local op = self.op
    self.op = nil
    return active.perform(op)
end

local originalRequire = require
require = function(name)
    if name == "LootBox/Native" then return Native end
    return originalRequire(name)
end
package.loaded["LootBox/Jobs"] = nil
local Jobs = require "LootBox/Jobs"
require = originalRequire
local World = require "LootBox/World"
local Categories = require "LootBox/Categories"

local function list(values)
    return {size = function() return #values end, get = function(_, index) return values[index + 1] end,
        isEmpty = function() return #values == 0 end,
        contains = function(_, value) for _, entry in ipairs(values) do if entry == value then return true end end; return false end}
end
local function remove(values, value)
    for index, entry in ipairs(values) do if entry == value then table.remove(values, index); return true end end
end

local function fixture()
    local f = {now = 0, ops = {}, visits = {}, squares = {}, nextId = 0, reads = {}, blocked = {}, deleted = {}}
    active = f
    local function square(x, y, z)
        local key = x .. ":" .. y .. ":" .. (z or 0)
        if f.squares[key] then return f.squares[key] end
        local value = {x = x, y = y, z = z or 0, objects = {}, corpses = {}, ground = {}}
        function value:getX() f.reads.x = (f.reads.x or 0) + 1; return self.x end
        function value:getY() return self.y end
        function value:getZ() return self.z end
        function value:getObjects() return list(self.objects) end
        function value:getMovingObjects() return list({}) end
        function value:getStaticMovingObjects() return list(self.corpses) end
        function value:getWorldObjects() return list(self.ground) end
        function value:isSeen() return true end
        function value:getRoom() return f.room end
        function value:getBuilding() return nil end
        function value:getFloor() return {} end
        function value:isFree() return true end
        function value:canReachTo() return true end
        f.squares[key] = value
        return value
    end
    f.square = square
    f.at = square(0, 0)
    f.roomSquares = {f.at}
    f.room = {getSquares = function() return list(f.roomSquares) end, getName = function() return "kitchen" end}

    function f.near(target)
        return target ~= nil and target.z == f.at.z and math.abs(target.x - f.at.x) <= 1 and math.abs(target.y - f.at.y) <= 1
    end
    local function weigh(item)
        local total = item.weight
        for _, child in ipairs(item.inside and item.inside.items or {}) do total = total + weigh(child) end
        return total
    end
    function f.container(kind, parent)
        local value = {kind = kind, parent = parent, items = {}, capacity = 1000, explored = true}
        function value:getType() return self.kind end
        function value:getParent() return self.parent end
        function value:getSourceGrid() return self.parent and self.parent.where end
        function value:getItems() return list(self.items) end
        function value:isEmpty() return #self.items == 0 end
        function value:contains(item) return list(self.items):contains(item) end
        function value:getItemWithID(id) for _, item in ipairs(self.items) do if item.id == id then return item end end end
        function value:containsID(id) return self:getItemWithID(id) ~= nil end
        function value:getContainingItem() return self.bag end
        function value:getEffectiveCapacity() return self.capacity end
        function value:getCapacityWeight()
            local total = 0
            for _, item in ipairs(self.items) do total = total + weigh(item) end
            return total
        end
        function value:hasRoomFor(_, item) return self.kind == "floor" or self:getCapacityWeight() + weigh(item) <= self.capacity end
        function value:isItemAllowed() return true end
        function value:isRemoveItemAllowed() return true end
        function value:isExplored() return self.explored end
        function value:isLockedToCharacter() return false end
        function value:getVehiclePart() return nil end
        function value:getOutermostContainer()
            local current = self
            while current.bag and current.bag.container do current = current.bag.container end
            return current
        end
        function value:isInside(item)
            local current = self
            while current do
                if current.bag == item then return true end
                current = current.bag and current.bag.container
            end
            return false
        end
        return value
    end
    f.inventory = f.container("inventory")
    f.inventory.capacity = 50
    f.floor = f.container("floor")
    local player = {}
    f.player = player
    function player:getInventory() return f.inventory end
    function player:getPlayerNum() return 0 end
    function player:getCurrentSquare() return f.at end
    function player:getSquare() return f.at end
    function player:getX() return f.at.x + 0.5 end
    function player:getY() return f.at.y + 0.5 end
    function player:getZ() return f.at.z end
    function player:getVehicle() return nil end
    function player:isEquipped(item) return item == f.worn end
    function player:getPrimaryHandItem() return nil end
    function player:getSecondaryHandItem() return nil end
    function player:isDead() return false end
    function player:isAsleep() return false end
    function player:isUnlimitedCarry() return false end
    f.parent = player

    function f.item(source, fullType, options)
        options = options or {}
        f.nextId = f.nextId + 1
        local item = {id = f.nextId, fullType = fullType or "Base.Nails", weight = options.weight or 1, container = source,
            category = options.category or "Material", favorite = options.favorite}
        function item:getID() return self.id end
        function item:getFullType() return self.fullType end
        function item:getName() return self.fullType end
        function item:getDisplayCategory() return self.category end
        function item:getCategory() return self.inside and "Container" or "Item" end
        function item:getContainer() return self.container end
        function item:getWorldItem() return self.placed end
        function item:getInventory() return self.inside end
        function item:getUnequippedWeight() return weigh(self) end
        function item:isFavorite() return self.favorite == true end
        function item:isEquipped() return self.wornByCorpse == true or self == f.worn end
        function item:getAttachedSlot() return self.attached or -1 end
        function item:isUnwanted() return false end
        if options.bag then item.inside = f.container("bag"); item.inside.bag = item end
        if source then source.items[#source.items + 1] = item end
        return item
    end
    function f.drop(where, fullType, options)
        local item = f.item(nil, fullType, options)
        item.placed = {item = item, where = where}
        function item.placed:getItem() return self.item end
        function item.placed:getSquare() return self.where end
        function item.placed:getWorldObjectIndex()
            for index, object in ipairs(self.where.ground) do if object == self then return index - 1 end end
            return -1
        end
        where.ground[#where.ground + 1] = item.placed
        return item
    end
    function f.crate(where, name)
        local object = {where = where, name = name}
        local storage = f.container("crate", object)
        function object:getSquare() return self.where end
        function object:getSpriteName() return self.name end
        function object:getContainerCount() return 1 end
        function object:getContainerByIndex(index) if index == 0 then return storage end end
        function object:getContainer() return storage end
        function object:getContainerIndex(value) return value == storage and 0 or -1 end
        function object:getSprite() return {getProperties = function() return {has = function(_, flag) return self.trash and flag == "IsTrashCan" end} end} end
        function object:getObjectIndex()
            for index, value in ipairs(self.where.objects) do if value == self then return index - 1 end end
            return -1
        end
        where.objects[#where.objects + 1] = object
        f.roomSquares[#f.roomSquares + 1] = where
        return storage
    end
    function f.corpse(where)
        local body = {where = where, class = "IsoDeadBody"}
        local storage = f.container("inventorymale", body)
        function body:getSquare() return self.where end
        function body:getSpriteName() return "body" end
        function body:getContainer() return storage end
        function body:getContainerIndex(value) return value == storage and 0 or -1 end
        function body:getContainerByIndex(index) if index == 0 then return storage end end
        function body:getStaticMovingObjectIndex()
            for index, value in ipairs(self.where.corpses) do if value == self then return index - 1 end end
            return -1
        end
        where.corpses[#where.corpses + 1] = body
        f.roomSquares[#f.roomSquares + 1] = where
        return storage
    end

    local function refreshFloor()
        f.floor.items = {}
        for _, tile in pairs(f.squares) do
            if f.near(tile) then
                for _, placed in ipairs(tile.ground) do f.floor.items[#f.floor.items + 1] = placed.item end
            end
        end
    end
    f.loot = {refreshBackpacks = refreshFloor, checkExplored = function(_, container) container.explored = true end}
    function f.perform(op)
        if op.kind == "approach" then
            local target = op.square or op.container and f.world:square(op.container)
                or (op.location or op.locations) and f.square((op.location or op.locations[1]).x, (op.location or op.locations[1]).y)
            local key = target.x .. "," .. target.y
            if f.blocked[key] then
                f.attempts = (f.attempts or 0) + 1
                return false, "No path to the destination", "unreachable"
            end
            if f.at ~= target and not (f.near(target) and not op.exact) then f.at = target; f.visits[#f.visits + 1] = key end
            if f.onArrive then f.onArrive(key) end
            return true
        elseif op.kind == "transfer" then
            for _, item in ipairs(op.items or {op.item}) do
                if op.source == f.floor then
                    remove(item.placed.where.ground, item.placed)
                    item.placed = nil
                    refreshFloor()
                else assert(remove(op.source.items, item), "The item left its source") end
                assert(op.destination:hasRoomFor(f.player, item), "A transfer exceeded the destination")
                op.destination.items[#op.destination.items + 1], item.container = item, op.destination
            end
            op.resultItem = op.item
            if f.onTransfer then f.onTransfer(op) end
            return true
        elseif op.kind == "trash" then
            for _, item in ipairs(op.container.items) do
                assert(op.approved[tostring(item.id)], "An unapproved item was deleted")
                f.deleted[item], item.container = true, nil
            end
            op.container.items = {}
            return true
        end
        error("Unexpected native operation " .. op.kind)
    end
    getTimestampMs = function() return f.now end
    isClient = function() return false end
    instanceof = function(object, class) return type(object) == "table" and object.class == class end
    getTextOrNull = function() return nil end
    getVehicleById = nil
    ISInventoryWindowControlHandler_TransferSameType = nil
    ISInventoryPage = {GetFloorContainer = function() return f.floor end}
    getPlayerLoot = function() return f.loot end
    getCell = function()
        return {getGridSquare = function(_, x, y, z) return f.squares[x .. ":" .. y .. ":" .. z] end,
            getVehicles = function() return {iterator = function() return {hasNext = function() return false end} end} end}
    end
    f.state = {}
    f.world = World.new(player, f.state)
    f.graph = assert(Categories.new({}))
    f.world.graph = f.graph
    f.jobs = Jobs.new(player, f.world, f.graph)
    function f.request(destination, options)
        local request = {scope = "room", includeBags = false, filter = {all = true, ids = {}, types = {}}, destination = destination}
        for key, value in pairs(options or {}) do request[key] = value end
        return request
    end
    function f.finish()
        for _ = 1, 5000 do
            f.now = f.now + 50
            f.jobs:tick()
            local state = f.jobs:status().state
            if state ~= "running" and state ~= "pausing" and state ~= "cancelling" then return f.jobs:status() end
        end
        error("The job did not end: " .. tostring(f.jobs:status().reason))
    end
    function f.run(request)
        local plan = assert(f.jobs:preview(request))
        assert(f.jobs:start(plan, {reviewBins = false}))
        return f.finish(), plan
    end
    return f
end

local passed = 0
local function case(name, body)
    local quiet, savedPrint = print, print
    print = function() end
    local ok, err = pcall(body, fixture())
    print = savedPrint
    if not ok then error(name .. ": " .. tostring(err), 0) end
    passed = passed + 1
    quiet("PASS " .. name)
end

case("a filled loot bag is taken whole when bags are not opened", function(f)
    local crate = f.crate(f.square(5, 0), "crate")
    local bag = f.item(crate, "Base.Bag", {bag = true})
    local inside = f.item(bag.inside, "Base.Soup")
    local status, plan = f.run(f.request({kind = "inventory"}))
    assert(#plan.moves == 1 and plan.moves[1].itemName:find("with 1 items inside", 1, true))
    assert(status.state == "finished" and status.done == 1)
    assert(f.inventory:contains(bag) and inside.container == bag.inside and #crate.items == 0)
end)

case("a filled bag lying on the floor is picked up whole, and hauled to its destination", function(f)
    local tile = f.square(5, 0); f.roomSquares[2] = tile
    local bag = f.drop(tile, "Base.Bag", {bag = true})
    f.item(bag.inside, "Base.Soup")
    local crate = f.crate(f.square(20, 0), "crate"); f.roomSquares[3] = nil
    local status = f.run(f.request({kind = "container", ref = crate}))
    assert(status.state == "finished" and status.done == 1, status.reason)
    assert(crate:contains(bag) and #bag.inside.items == 1 and #tile.ground == 0)
end)

case("what is carried is read once for a whole load, not once per item", function(f)
    local source = f.crate(f.square(5, 0), "source")
    f.item(f.inventory, "Base.Bag", {bag = true})
    for index = 1, 30 do f.item(source, "Base.Thing" .. index, {weight = 0.5}) end
    local passes, original = 0, f.world.destinationPass
    function f.world:destinationPass(...) passes = passes + 1; return original(self, ...) end
    local status = f.run(f.request({kind = "inventory"}, {scope = "container", sourceContainer = source}))
    assert(status.state == "finished" and status.done == 30)
    assert(passes == 2, "Once for the plan and once for the job, not " .. passes)
end)

case("contents of a crate are dropped beside it when its own tile cannot be stood on", function(f)
    local tile = f.square(5, 0)
    function tile:isFree() return false end
    local source = f.crate(tile, "source")
    f.item(source); f.item(source)
    local status = f.run(f.request({kind = "floor", ref = f.at}, {scope = "container", sourceContainer = source}))
    assert(status.state == "finished" and status.done == 2 and #source.items == 0 and #f.inventory.items == 0)
end)

case("a hauled bag and the bags inside it take no further cargo", function(f)
    local source, target = f.crate(f.square(5, 0), "source"), f.crate(f.square(20, 0), "target")
    local outer = f.item(source, "Base.Duffel", {bag = true})
    local inner = f.item(outer.inside, "Base.Pouch", {bag = true})
    local loose = f.item(source)
    local status = f.run(f.request({kind = "container", ref = target}, {scope = "container", sourceContainer = source}))
    assert(status.state == "finished" and status.done == 2, status.reason)
    assert(target:contains(outer) and target:contains(loose) and #inner.inside.items == 0 and #outer.inside.items == 1)
end)

case("Clean empties a bag and then deletes the bag too", function(f)
    local crate, bin = f.crate(f.square(5, 0), "crate"), f.crate(f.square(10, 0), "bin")
    bin.parent.trash, bin.capacity = true, 3
    local outer = f.item(crate, "Base.Duffel", {bag = true})
    local inner = f.item(outer.inside, "Base.Pouch", {bag = true})
    local deepest, beside = f.item(inner.inside, "Base.Rag"), f.item(outer.inside, "Base.Can")
    local status = f.run(f.request({kind = "trash"}, {includeBags = true}))
    assert(status.state == "finished" and status.skipped == 0, status.reason)
    for _, item in ipairs({outer, inner, deepest, beside}) do assert(f.deleted[item], item.fullType .. " was left behind") end
    assert(#crate.items == 0 and #bin.items == 0 and #f.inventory.items == 0)
end)

case("Clean leaves a bag whose Keep item stays inside it", function(f)
    local crate, bin = f.crate(f.square(5, 0), "crate"), f.crate(f.square(10, 0), "bin")
    bin.parent.trash = true
    local bag = f.item(crate, "Base.Duffel", {bag = true})
    local kept, junk = f.item(bag.inside, "Base.Locket"), f.item(bag.inside, "Base.Rag")
    f.state.keep[tostring(kept.id)] = true
    local status = f.run(f.request({kind = "trash"}, {includeBags = true}))
    assert(f.deleted[junk] and not f.deleted[bag] and not f.deleted[kept])
    assert(crate:contains(bag) and kept.container == bag.inside and status.state == "finished")
end)

case("a filled bag in a bin does not block cleanup unless it holds a Keep or Favorite item", function(f)
    local crate, bin = f.crate(f.square(5, 0), "crate"), f.crate(f.square(10, 0), "bin")
    bin.parent.trash = true
    f.at = f.square(10, 1)
    local bag = f.item(bin, "Base.Plastic", {bag = true})
    local inside = f.item(bag.inside, "Base.Rag")
    local junk = f.item(crate, "Base.Can")
    local status = f.run(f.request({kind = "trash"}, {scope = "container", sourceContainer = crate}))
    assert(status.state == "finished" and f.deleted[junk] and f.deleted[bag])
    local second = f.item(bin, "Base.Plastic", {bag = true})
    f.item(second.inside, "Base.Locket", {favorite = true})
    f.item(crate, "Base.Can")
    local plan, err = f.jobs:preview(f.request({kind = "trash"}, {scope = "container", sourceContainer = crate}))
    local text = plan and table.concat(plan.warnings, " ") or err
    assert(text:find("protected", 1, true) or text:find("No usable", 1, true))
    assert(f.deleted[second] == nil)
end)

case("a corpse's clothes are loot and the player's own are not", function(f)
    local corpse = f.corpse(f.square(5, 0))
    local jacket, holster = f.item(corpse, "Base.Jacket"), f.item(corpse, "Base.Pistol")
    jacket.wornByCorpse, holster.attached = true, 1
    local mine = f.item(f.inventory, "Base.Jacket")
    f.worn = mine
    local status = f.run(f.request({kind = "inventory"}))
    assert(status.state == "finished" and status.done == 2)
    assert(f.inventory:contains(jacket) and f.inventory:contains(holster))
    local protected, reason = f.world:protected(mine)
    assert(protected and reason == "Equipped")
end)

case("a floor search walks only to tiles with a match", function(f)
    for index = 1, 30 do
        local tile = f.square(index * 3, 0)
        f.roomSquares[#f.roomSquares + 1] = tile
        f.drop(tile, index % 15 == 0 and "Base.Axe" or "Base.Leaf")
    end
    local status = f.run(f.request({kind = "inventory"}, {filter = {all = false, ids = {}, types = {"Base.Axe"}}}))
    assert(status.state == "finished" and status.done == 2)
    assert(#f.visits == 2 and f.visits[1] == "45,0" and f.visits[2] == "90,0", table.concat(f.visits, " "))
end)

case("the route always takes the nearest remaining stop, whatever its kind", function(f)
    local far, mid = f.crate(f.square(30, 0), "far"), f.crate(f.square(10, 0), "mid")
    local unopened = f.crate(f.square(6, 0), "unopened")
    f.item(far, "Base.A"); f.item(mid, "Base.B"); f.item(unopened, "Base.C"); unopened.explored = false
    local tile = f.square(3, 0); f.roomSquares[#f.roomSquares + 1] = tile
    f.drop(tile, "Base.D")
    local status = f.run(f.request({kind = "inventory"}))
    assert(status.done == 4, status.reason)
    assert(table.concat(f.visits, " ") == "3,0 6,0 10,0 30,0", table.concat(f.visits, " "))
end)

case("items already in storage with a requested label stay there", function(f)
    local sorted, loose = f.crate(f.square(5, 0), "sorted"), f.crate(f.square(8, 0), "loose")
    f.state.containerLabels[assert(f.world:key(sorted))] = {"native:Food"}
    local right, wrong = f.item(sorted, "Base.Soup", {category = "Food"}), f.item(sorted, "Base.Saw", {category = "Tool"})
    local stray = f.item(loose, "Base.Beans", {category = "Food"})
    local status, plan = f.run(f.request({kind = "labels", labels = {}}))
    assert(#plan.moves == 1 and sorted:contains(right) and sorted:contains(stray) and sorted:contains(wrong))
    local reason
    for _, row in ipairs(plan.skipped) do if row.itemName == "Base.Soup" then reason = row.reason end end
    assert(reason == "Already sorted" and status.done == 1)
end)

case("sorting looks for labelled storage once per plan and once per delivery", function(f)
    local target, source = f.crate(f.square(5, 0), "target"), f.crate(f.square(8, 0), "source")
    f.state.containerLabels[assert(f.world:key(target))] = {"native:Material"}
    for _ = 1, 40 do f.item(source) end
    local looked, discover = 0, f.world._discover
    function f.world:_discover() looked = looked + 1; return discover(self) end
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}}, {scope = "container", sourceContainer = source})))
    assert(#plan.moves == 40 and looked == 1, "Discovered " .. looked .. " times for 40 items")
    assert(f.jobs:start(plan))
    local status = f.finish()
    assert(status.done == 40 and #target.items == 40)
    assert(looked <= 4, "One trip discovered " .. looked .. " times")
end)

case("loot is not picked up for a destination that has no room left for it", function(f)
    local source, target = f.crate(f.square(5, 0), "source"), f.crate(f.square(20, 0), "target")
    target.capacity = 4
    for _ = 1, 6 do f.item(source) end
    local plan = assert(f.jobs:preview(f.request({kind = "container", ref = target}, {scope = "container", sourceContainer = source})))
    f.item(target); f.item(target)
    assert(f.jobs:start(plan))
    local status = f.finish()
    assert(#f.inventory.items == 0 and #target.items == 4 and #source.items == 4, "Nothing stays carried")
    local full = 0
    for _, row in ipairs(status.reasons) do if row.reason == "Destination full" then full = full + 1 end end
    assert(full == 2 and status.done == 2)
end)

case("a destination that fills up on the way pauses instead of looping, and resumes", function(f)
    local source, target = f.crate(f.square(5, 0), "source"), f.crate(f.square(20, 0), "target")
    target.capacity = 3
    for _ = 1, 3 do f.item(source) end
    local blocker
    f.onArrive = function(key) if key == "20,0" and not blocker then blocker = f.item(target, "Base.Crate", {weight = 2}) end end
    local status = f.run(f.request({kind = "container", ref = target}, {scope = "container", sourceContainer = source}))
    assert(status.state == "paused" and status.reason:find("Destination full", 1, true) and status.canResume)
    assert(#f.inventory.items == 2 and status.done == 1)
    remove(target.items, blocker)
    assert(f.jobs:resume())
    status = f.finish()
    assert(status.state == "finished" and status.done == 3 and #target.items == 3 and #f.inventory.items == 0)
end)

case("an unreachable container is tried once and leaves one note", function(f)
    local shut, open = f.crate(f.square(5, 0), "shut"), f.crate(f.square(9, 0), "open")
    for _ = 1, 5 do f.item(shut) end
    f.item(open)
    f.blocked["5,0"] = true
    local status = f.run(f.request({kind = "inventory"}))
    assert(f.attempts == 1 and status.done == 1 and status.skipped == 5 and #status.reasons == 1)
    assert(status.reasons[1].reason:find("No path", 1, true) and status.reasons[1].reason:find("5 items", 1, true))
end)

case("a plan can be made while another job runs, but only one job runs", function(f)
    local first, second = f.crate(f.square(5, 0), "first"), f.crate(f.square(9, 0), "second")
    f.item(first); f.item(second, "Base.Saw")
    local running = assert(f.jobs:preview(f.request({kind = "inventory"}, {scope = "container", sourceContainer = first})))
    assert(f.jobs:start(running))
    f.jobs:tick()
    local waiting = assert(f.jobs:preview(f.request({kind = "inventory"}, {scope = "container", sourceContainer = second})))
    assert(waiting.owner == f.jobs and #waiting.moves == 1)
    local started, problem = f.jobs:start(waiting)
    assert(not started and problem:find("already active", 1, true) and not f.jobs:status().canStart)
    assert(f.finish().done == 1 and #first.items == 0 and #second.items == 1)
    assert(f.jobs:start(waiting) and f.finish().done == 1 and #second.items == 0)
    local planner = Jobs.new(f.player, f.world, f.graph)
    f.item(first)
    assert(f.jobs:start(assert(f.jobs:preview(f.request({kind = "inventory"})))))
    local other = assert(planner:preview(f.request({kind = "inventory"}, {interaction = 77})))
    assert(other.owner == planner and other.request.interaction == 77 and f.finish().done == 1)
end)

case("previewing a 100 by 100 area reads each tile a fixed number of times", function(f)
    local function measure(side)
        for x = 0, side - 1 do for y = 0, side - 1 do f.square(x, y) end end
        f.reads.x = 0
        assert(f.world:scan({scope = "area", area = {x1 = 0, x2 = side - 1, y1 = 0, y2 = side - 1, z = 0}}))
        return f.reads.x / (side * side)
    end
    assert(measure(20) <= 4)
    assert(measure(100) <= 4, "Sorting must not query tiles again for every comparison")
end)

case("an error while checking protection protects the item", function(f)
    local crate = f.crate(f.square(5, 0), "crate")
    local item = f.item(crate)
    function item:isFavorite() error("Simulated native failure") end
    local protected, reason = f.world:protected(item)
    assert(protected and reason == "Protection could not be checked")
    assert(f.run(f.request({kind = "inventory"})).done == 0 and crate:contains(item))
end)

case("menu questions describe containers, the room and what is carried without changing anything", function(f)
    f.world.graph = assert(Categories.new({{id = "custom:camp", name = "Camp", types = {"Base.Rope"}}}))
    local crate = f.crate(f.square(5, 0), "crate")
    crate.capacity = 60
    f.item(crate, "Base.Rope"); f.item(crate, "Base.Rope"); f.item(crate, "Base.Soup", {category = "Food", favorite = true})
    local facts = f.world:containerFacts(crate)
    assert(facts.kind == "fixture" and facts.items == 3 and facts.takeable == 2 and facts.explored and not facts.locked and not facts.owned)
    assert(facts.used == 3 and facts.capacity == 60 and facts.truncated == false)
    assert(facts.types["Base.Rope"] == 2 and facts.types["Base.Soup"] == nil)
    assert(facts.categories["native:Material"] == 2 and facts.categories["custom:camp"] == 2 and facts.categories["native:Food"] == nil)
    assert(f.world:countMatching(crate, {ids = {"custom:camp"}, types = {}}) == 2)
    assert(f.world:countMatching(crate, {ids = {}, types = {"Base.Soup"}}) == 0 and f.world:countMatching(crate, {all = true}) == 2)
    for _ = 1, 410 do f.item(crate, "Base.Nail") end
    assert(f.world:containerFacts(crate).truncated and f.world:containerFacts(crate).items == 413)

    local bag = f.item(f.inventory, "Base.Bag", {bag = true})
    f.item(bag.inside, "Base.Rope"); f.item(f.inventory, "Base.Rope"); f.item(f.inventory, "Base.Rope", {favorite = true})
    assert(f.world:countCarried("Base.Rope") == 2 and f.world:countCarried("Base.Rope", bag.inside) == 1)
    assert(f.world:countCarried(nil) == 2, "The filled carried bag and the favorite are protected")
    assert(f.world:countCarriedCategory("custom:camp") == 2 and f.world:countCarriedCategory("native:Material", f.inventory) == 0)
    assert(f.world:countCarriedFilter({ids = {}, types = {"Base.Rope"}}) == 2 and f.world:countCarriedFilter({all = true}) == 2)
    f.item(f.inventory, "Base.Rope")
    assert(f.world:countCarried("Base.Rope") == 2, "One moment has one answer")
    f.now = f.now + 60
    assert(f.world:countCarried("Base.Rope") == 3)
    assert(f.world:containerFacts(f.inventory).kind == "main" and f.world:containerFacts(bag.inside).kind == "bag")
    assert(f.world:containerFacts(f.corpse(f.square(7, 7))).kind == "corpse" and f.world:containerFacts(f.floor).kind == "floor")

    f.crate(f.square(6, 0), "empty")
    local unopened = f.crate(f.square(7, 0), "unopened"); unopened.explored = false
    f.drop(f.square(5, 0), "Base.Leaf")
    local room = f.world:roomFacts(f.at)
    assert(room.name == "kitchen" and room.containers == 2 and room.groundItems == 1 and not room.truncated)
    f.room = nil
    assert(f.world:roomFacts(f.at) == nil)
end)

case("menu questions about labels, bins and the vehicle come from saved state", function(f)
    assert(not f.world:hasKnownBins() and not f.world:hasStorageLabels() and #f.world:knownBins() == 0 and #f.world:labelledContainers() == 0)
    local food = {fullType = "Base.Soup", categoryId = "native:Food", labels = {}}
    local crate, bin = f.crate(f.square(5, 0), "crate"), f.crate(f.square(6, 0), "bin")
    bin.parent.trash, bin.capacity = true, 20
    f.state.containerLabels["player:0"] = {"native:Food"}
    assert(not f.world:hasStorageLabels() and not f.world:storageAccepts(food))
    f.state.containerLabels[assert(f.world:key(crate))] = {"native:Food"}
    f.state.containerLabels["world:90:91:1:shelf:0:shelf"] = {"native:Tool"}
    assert(f.world:hasStorageLabels() and f.world:storageAccepts(food))
    assert(not f.world:storageAccepts({fullType = "Base.Nail", categoryId = "native:Material", labels = {}}))
    f.world:discover()
    local labelled = f.world:labelledContainers()
    assert(#labelled == 2)
    for _, entry in ipairs(labelled) do
        if entry.container then
            assert(entry.container == crate and entry.labels[1] == "native:Food" and entry.point.x == 5)
            entry.labels[1] = "changed by a page"
        else assert(entry.point.x == 90 and entry.point.z == 1 and entry.name == "shelf") end
    end
    assert(f.world:storageAccepts(food), "The returned list is a copy")
    local bins = f.world:knownBins()
    assert(f.world:hasKnownBins() and #bins == 1 and bins[1].container == bin and bins[1].capacity == 20 and bins[1].point.x == 6)
    local vehicle = {getKeyId = function() return 7 end, getScriptName = function() return "Base.Car" end,
        getSquare = function() return f.at end}
    assert(not f.world:isRememberedVehicle(vehicle) and not f.world:rememberedVehicleLoaded())
    f.state.vehicle = {id = 3, keyId = 7, script = "Base.Car", x = 0, y = 0, z = 0}
    assert(f.world:isRememberedVehicle(vehicle) and not f.world:rememberedVehicleLoaded())
    getVehicleById = function(id) return id == 3 and vehicle or nil end
    assert(f.world:rememberedVehicleLoaded())
end)

case("emptied labels leave no trace", function(f)
    local world = World.new(f.player, {containerLabels = {["bag:1"] = {}, ["bag:2"] = {"native:Food", "custom:gone"}, ["bag:3"] = {"custom:gone"}},
        itemLabels = {["4"] = {"custom:gone"}, ["5"] = {}}})
    assert(world.state.containerLabels["bag:1"] == nil and world.state.itemLabels["5"] == nil)
    assert(#world.state.containerLabels["bag:2"] == 2 and #world.state.itemLabels["4"] == 1)
end)

case("what a bin holds is not saved", function(f)
    local bin = f.crate(f.square(5, 0), "bin")
    bin.parent.trash = true
    f.world:discover()
    f.world:observeNearby()
    f.item(bin)
    f.world:discover()
    assert(f.world.dirty ~= true, "A bin's contents changing must not cause a save")
    for _, memory in pairs(f.state.trash) do assert(memory.used == nil) end
    assert(f.world:knownBins()[1].used == 1)
end)

print("PASS " .. passed .. " job engine scenarios")
