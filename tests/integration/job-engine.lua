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
    local f = {now = 0, ops = {}, visits = {}, squares = {}, nextId = 0, reads = {}, blocked = {}, deleted = {}, wearing = {}, emptied = {}}
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
        -- The game returns the first object with the IsTrashCan property and a container.
        function value:getTrashReceptacle() for _, object in ipairs(self.objects) do if object.trash then return object end end end
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
        return target ~= nil and target.z == f.at.z and not (f.wall and f.wall(f.at, target)) and math.abs(target.x - f.at.x) <= 1 and math.abs(target.y - f.at.y) <= 1
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
    function player:isEquipped(item) return item == f.worn or f.wearing[item] ~= nil end
    function player:getWornItems()
        local worn = {}
        for item, slot in pairs(f.wearing) do
            worn[#worn + 1] = {getItem = function() return item end, getLocation = function() return slot end}
        end
        local result = list(worn)
        function result:contains(item) return f.wearing[item] ~= nil end
        function result:getBodyLocationGroup()
            return {size = function() return 1 end, isMultiItem = function() return false end, isExclusive = function() return false end,
                getLocationByIndex = function() return {getId = function() return "base:Back" end} end}
        end
        return result
    end
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
        if options.class then item.class = options.class end
        if options.bag then
            item.inside = f.container("bag")
            item.inside.bag, item.inside.capacity = item, options.capacity or 1000
            function item:IsInventoryContainer() return true end
            function item:getWeightReduction() return options.reduction or 0 end
            function item:getMaxItemSize() return options.largest or 0 end
            function item:getContentsWeight() return self.inside:getCapacityWeight() end
            function item:canBeEquipped() return options.wear end
            function item:isFakeEquipped() return options.keyRing == true and self.container == f.inventory end
            function item.inside:isItemAllowed(value) return not options.accepts or options.accepts(value) end
        end
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
                or (op.location or op.locations) and f.square((op.location or op.locations[1]).x, (op.location or op.locations[1]).y, (op.location or op.locations[1]).z)
            local key = target.x .. "," .. target.y .. (target.z ~= 0 and "," .. target.z or "")
            if f.blocked[key] then
                f.attempts = (f.attempts or 0) + 1
                return false, "No path to the destination", "unreachable"
            end
            if f.at ~= target and not (f.near(target) and not op.exact) then f.at = target; f.visits[#f.visits + 1] = key end
            if f.onArrive then f.onArrive(key) end
            return true
        elseif op.kind == "transfer" then
            for _, where in ipairs({op.source, op.destination}) do
                assert(where == f.floor or f.near(f.world:square(where)), "A transfer out of reach")
            end
            if f.refuse and f.refuse(op) then return false, "The game stopped the native action before completing it" end
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
        elseif op.kind == "gear" then
            assert(op.mode == "wear" and remove(op.source.items, op.item))
            f.inventory.items[#f.inventory.items + 1], op.item.container = op.item, f.inventory
            f.wearing[op.item], op.resultItem = op.slot, op.item
            return true
        elseif op.kind == "trash" then
            assert(f.near(f.world:square(op.container)), "A can was emptied out of reach")
            f.emptied[#f.emptied + 1] = {can = op.container, count = #op.container.items}
            for _, item in ipairs(op.container.items) do
                assert(op.approved[tostring(item.id)], "An unapproved item was deleted")
                assert(not f.world:protected(item), "A protected item was deleted")
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
        return {getGridSquare = function(_, x, y, z)
                -- f.sight: how far from the player the world is loaded.
                if f.sight and (math.abs(x - f.at.x) > f.sight or math.abs(y - f.at.y) > f.sight) then return nil end
                return f.squares[x .. ":" .. y .. ":" .. z]
            end,
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
    -- A can the player has walked past before.
    function f.can(where, capacity)
        local can = f.crate(where, "can")
        f.roomSquares[#f.roomSquares] = nil
        can.parent.trash, can.capacity = true, capacity or 20
        f.state.trash[where.x .. ":" .. where.y .. ":" .. where.z] = can.capacity
        return can
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
    assert(not plan and err:find("Base.Plastic", 1, true) and err:find("left alone", 1, true), err)
    assert(f.deleted[second] == nil)
end)

-- Whole Clean jobs. Distances, capacities and loads are worked out by hand in each case.
local function clean(f, source, options)
    local request = f.request({kind = "trash"}, {scope = source and "container" or "room", sourceContainer = source, includeBags = true})
    for key, value in pairs(options or {}) do request[key] = value end
    return request
end
local function asking(f, request)
    assert(f.jobs:start(assert(f.jobs:preview(request))))
    return f.finish()
end
local function road(f, to)
    for x = 0, to do f.square(x, 0) end
end
local function trips(f) return table.concat(f.visits, " ") end

case("Clean goes to the rubbish first, never empty-handed to a can, even when the can was never opened", function(f)
    local crate, can = f.crate(f.square(10, 0), "crate"), f.can(f.square(20, 0))
    can.explored = false
    local junk, rolled = f.item(crate), nil
    f.loot.checkExplored = function(_, container) container.explored = true; rolled = f.item(container, "Base.Banana") end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0, status.reason)
    assert(trips(f) == "10,0 20,0", trips(f))
    assert(f.deleted[junk] and f.deleted[rolled] and #f.emptied == 1, "What opening the can revealed goes with it")
end)

case("Clean with several cans uses the nearest that takes the item, and a bigger one only for a small detour", function(f)
    -- At walking speed a saved emptying is worth about 2.8 tiles.
    local function run(far, weight, bigAt)
        local crate, near = f.crate(f.square(far, 0), "crate"), f.can(f.square(far + 10, 0), 10)
        local big = f.can(f.square(far + bigAt, 0), 30)
        f.at = f.square(far, 1)
        for _ = 1, weight do f.item(crate) end
        f.emptied = {}
        local status = f.run(clean(f, crate))
        assert(status.state == "finished" and status.done == weight, status.reason)
        for _, object in ipairs({near.parent, big.parent}) do remove(object.where.objects, object) end
        return f.emptied[1].can == near and "near" or "big"
    end
    assert(run(0, 8, 11) == "near", "Eight fit the nearer can, so size does not matter")
    assert(run(100, 12, 11) == "big", "Twelve need two emptyings of the small can or one tile more")
    assert(run(200, 12, 40) == "near", "Thirty tiles are not worth one emptying")
    local crate, small, large = f.crate(f.square(300, 0), "crate"), f.can(f.square(303, 0), 10), f.can(f.square(340, 0), 20)
    f.at = f.square(300, 1)
    local tire, scrap = f.item(crate, "Base.Tire", {weight = 15}), f.item(crate)
    f.emptied = {}
    local status = f.run(clean(f, crate))
    assert(status.done == 2 and f.deleted[tire] and f.deleted[scrap], status.reason)
    for _, entry in ipairs(f.emptied) do assert(entry.can == large or entry.count <= 10 and entry.can == small) end
end)

case("a full can is emptied before the load goes in and filled again", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 10)
    for _ = 1, 9 do f.item(can, "Base.Old") end
    for _ = 1, 15 do f.item(crate) end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 15 and #f.inventory.items == 0, status.reason)
    -- 9 old + 1 new fill it, then 10 new, then the last 4.
    assert(#f.emptied == 3 and f.emptied[1].count == 10 and f.emptied[2].count == 10 and f.emptied[3].count == 4)
    assert(trips(f) == "5,0 20,0", "One carried load is one trip: " .. trips(f))
end)

case("a can too far away is not offered, and an explicit plan says how far it is", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(3000, 0))
    f.item(crate)
    f.state.trash["3000:0:0"] = 20
    f.sight = 60
    assert(f.world:binDistance() == nil)
    local plan, err = f.jobs:preview(clean(f, crate))
    assert(not plan and err:find("2995 tiles away", 1, true), err) -- from the crate, the closer of the two
    f.state.trash["150:0:0"] = 20
    assert(f.world:binDistance() == 150)
    f.state.trash["150:0:0"], f.state.trash["151:0:0"] = nil, 20
    assert(f.world:binDistance() == nil)
    plan = assert(f.jobs:preview(clean(f, nil, {scope = "area", area = {x1 = 2990, x2 = 3000, y1 = 0, y2 = 0, z = 0}})),
        "Cans beside the place being cleaned count")
    assert(f.jobs.reviews[plan].bins[1].key == "3000:0:0" and #f.jobs.reviews[plan].bins == 1)
    f.state.trash = {}
    local _, none = f.jobs:preview(clean(f, crate))
    assert(none:find("No trash can is known", 1, true) and can)
end)

case("the plan names the nearest can instead of warning about each remembered one", function(f)
    local crate = f.crate(f.square(5, 0), "crate")
    local can = f.can(f.square(12, 0))
    f.item(can, "Base.Old")
    f.item(crate)
    f.sight = 60
    for index = 1, 20 do f.state.trash[(80 + index) .. ":0:0"] = 10 end
    local plan = assert(f.jobs:preview(clean(f, crate)))
    local notices, text = 0, table.concat(plan.warnings, " | ")
    for _, warning in ipairs(plan.warnings) do if warning:find("trash can", 1, true) then notices = notices + 1 end end
    assert(notices == 1 and text:find("7 tiles away", 1, true) and text:find("Base.Old", 1, true), text)
    assert(plan.pending == 0, "Unseen cans are not places to look into")
end)

case("nothing to throw away starts nothing, whatever cans are known", function(f)
    local crate = f.crate(f.square(5, 0), "crate")
    f.item(crate, "Base.Locket", {favorite = true})
    f.state.trash["60:0:0"] = 10
    f.sight = 30
    local plan = assert(f.jobs:preview(clean(f)))
    assert(#plan.moves == 0 and plan.pending == 0)
end)

case("without a usable can Clean pauses with the load and Resume tries again", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 10)
    for _ = 1, 9 do f.item(crate) end
    local kept
    f.onArrive = function(key)
        if key == "20,0" and not kept then kept = f.item(can, "Base.Locket", {favorite = true}) end
    end
    local status = f.run(clean(f, crate))
    assert(status.state == "paused" and status.canResume and status.carried == 9 and status.done == 0, status.reason)
    assert(status.reason:find("Base.Locket", 1, true) and #f.emptied == 0)
    assert(f.jobs:resume() and f.finish().state == "paused" and #f.inventory.items == 9, "Still blocked")
    remove(can.items, kept)
    assert(f.jobs:resume())
    status = f.finish()
    assert(status.state == "finished" and status.done == 9 and status.skipped == 0 and #f.inventory.items == 0, status.reason)
end)

case("an unreachable can is tried once per run, the other is used, and Resume forgives it", function(f)
    local crate, shut, open = f.crate(f.square(5, 0), "crate"), f.can(f.square(8, 0)), f.can(f.square(40, 0))
    f.inventory.capacity = 3
    for _ = 1, 6 do f.item(crate) end
    f.blocked["8,0"] = true
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 6 and f.attempts == 1 and f.emptied[1].can == open, status.reason)
    for _ = 1, 2 do f.item(crate) end
    f.blocked["40,0"] = true
    status = f.run(clean(f, crate))
    assert(status.state == "paused" and status.carried == 2 and status.reason:find("No path", 1, true))
    f.blocked["8,0"] = nil
    assert(f.jobs:resume() and f.finish().state == "finished")
    assert(f.emptied[#f.emptied].can == shut)
end)

case("something new in the can mid-job goes too when asking is off", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 4)
    for _ = 1, 9 do f.item(crate) end
    local stray
    f.onTransfer = function(op) if op.destination == can and not stray then stray = f.item(can, "Base.Rotten") end end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 9 and status.skipped == 0 and f.deleted[stray], status.reason)
end)

case("asking: an empty can needs no question, contents are asked about once, and again only for something new", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 4)
    for _ = 1, 3 do f.item(crate) end
    assert(asking(f, clean(f, crate)).state == "finished", "An empty can asks nothing")
    for _ = 1, 9 do f.item(crate) end
    local old, stray = f.item(can, "Base.Old"), nil
    f.onTransfer = function(op) if op.destination == can and f.deleted[old] and not stray then stray = f.item(can, "Base.Rotten") end end
    local status = asking(f, clean(f, crate))
    assert(status.state == "needs_review" and status.carried == 9 and not f.deleted[old])
    local review = assert(f.jobs:reviewBin())
    assert(#review.moves == 1 and review.moves[1].itemName == "Base.Old")
    assert(f.jobs:approveBin(review))
    status = f.finish()
    assert(status.state == "needs_review" and stray and not f.deleted[stray] and f.deleted[old])
    review = assert(f.jobs:reviewBin())
    local named = false
    for _, row in ipairs(review.moves) do named = named or row.itemName == "Base.Rotten" end
    assert(named and f.jobs:approveBin(review))
    status = f.finish()
    assert(status.state == "finished" and status.done == 9 and f.deleted[stray], status.reason)
end)

case("what was approved at a can stays approved across a pause", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 4)
    local old = f.item(can, "Base.Old")
    for _ = 1, 6 do f.item(crate) end
    assert(asking(f, clean(f, crate)).state == "needs_review")
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())))
    for _ = 1, 3 do f.now = f.now + 50; f.jobs:tick() end
    assert(f.jobs:pause() and f.finish().state == "paused" and not f.deleted[old])
    f.at = f.square(0, 0)
    assert(f.jobs:resume())
    local status = f.finish()
    assert(status.state == "finished" and status.done == 6 and f.deleted[old], "Asked again: " .. tostring(status.reason))
end)

case("pausing while a can is being asked about asks again on Resume", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 4)
    f.item(can, "Base.Old"); f.item(crate)
    local first = asking(f, clean(f, crate))
    local stale = assert(f.jobs:reviewBin())
    assert(f.jobs:pause() and f.finish().state == "paused")
    f.at = f.square(0, 0)
    assert(not f.jobs:approveBin(stale) and f.jobs:resume())
    local again = f.finish()
    assert(again.state == "needs_review" and again.reviewId > first.reviewId and not f.jobs:approveBin(stale))
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())) and f.finish().state == "finished")
end)

case("refusing every can pauses with the load, and Resume asks again", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 4)
    local old = f.item(can, "Base.Old"); f.item(crate)
    assert(asking(f, clean(f, crate)).state == "needs_review")
    assert(f.jobs:rejectBin(assert(f.jobs:reviewBin())))
    local status = f.finish()
    assert(status.state == "paused" and status.carried == 1 and can:contains(old))
    assert(f.jobs:resume() and f.finish().state == "needs_review")
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())) and f.finish().state == "finished" and f.deleted[old])
end)

case("a can that is gone on arrival is forgotten and another one is used", function(f)
    road(f, 60)
    local crate, moved, other = f.crate(f.square(5, 0), "crate"), f.can(f.square(30, 0)), f.can(f.square(57, 0))
    f.state.trash["30:0:0"], f.state.trash["57:0:0"] = 20, 20
    f.sight = 12
    for _ = 1, 2 do f.item(crate) end
    remove(moved.parent.where.objects, moved.parent)
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 2 and f.emptied[1].can == other, status.reason)
    assert(f.state.trash["30:0:0"] == nil and f.state.trash["57:0:0"] == 20)
end)

case("when the last can disappears Clean pauses with the load, and a can found later finishes it", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0))
    for _ = 1, 3 do f.item(crate) end
    f.onTransfer = function(op) if op.destination == f.inventory then remove(can.parent.where.objects, can.parent) end end
    local status = f.run(clean(f, crate))
    assert(status.state == "paused" and #f.inventory.items > 0 and status.reason:find("No trash can is known", 1, true), status.reason)
    f.can(f.square(8, 0))
    assert(f.jobs:resume())
    status = f.finish()
    assert(status.state == "finished" and status.done == 3 and #f.inventory.items == 0, status.reason)
end)

case("a different can in the same place is simply used", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 10)
    f.item(crate); f.item(crate)
    local swapped
    f.onTransfer = function(op)
        if op.destination == f.inventory and not swapped then
            remove(can.parent.where.objects, can.parent)
            f.crate(f.square(20, 0), "shelf that shifts the object index")
            swapped = f.can(f.square(20, 0), 30)
        end
    end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 2 and f.emptied[1].can == swapped, status.reason)
end)

case("Clean upstairs carries everything to the can outside and comes back for the rest", function(f)
    local upper, can = f.crate(f.square(3, 0, 1), "upper"), f.can(f.square(12, 0, 0), 5)
    f.at = f.square(0, 0, 1)
    f.inventory.capacity = 4
    for _ = 1, 8 do f.item(upper) end
    local status = f.run(clean(f, upper))
    assert(status.state == "finished" and status.done == 8, status.reason)
    assert(trips(f) == "3,0,1 12,0 3,0,1 12,0", trips(f))
end)

case("an item no can is big enough for is left where it is", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 10)
    local ham, scrap = f.item(crate, "Base.HamRadio", {weight = 15}), f.item(crate)
    local status, plan = f.run(clean(f, crate))
    assert(#plan.moves == 1 and plan.skipped[1].reason == "Too heavy for any trash can (the biggest known holds 10)", plan.skipped[1].reason)
    assert(crate:contains(ham) and f.deleted[scrap] and #f.inventory.items == 0 and status.done == 1 and can)
end)

case("an item too heavy for the cans that are left is not picked up either", function(f)
    local crate, can, small = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 20), f.can(f.square(30, 0), 10)
    local ham = f.item(crate, "Base.HamRadio", {weight = 15})
    f.onArrive = function() remove(can.parent.where.objects, can.parent) end
    local status = f.run(clean(f, crate))
    assert(crate:contains(ham) and #f.inventory.items == 0 and status.state == "finished_with_skips" and small)
    assert(status.reasons[1].reason:find("the biggest known holds 10", 1, true))
end)

case("rubbish already in a can in the place being cleaned stays there until the can is emptied", function(f)
    local can, crate = f.can(f.square(3, 0), 20), f.crate(f.square(20, 0), "crate")
    f.roomSquares[#f.roomSquares + 1] = can.parent.where
    local bag = f.item(can, "Base.Bag", {bag = true})
    local rag, junk = f.item(bag.inside, "Base.Rag"), f.item(crate)
    -- Never noticed before, and too far to be noticed from here.
    f.at = f.square(20, 1)
    f.state.trash["3:0:0"], f.state.trash["23:0:0"] = nil, 20
    f.can(f.square(23, 0), 20)
    local status, plan = f.run(clean(f))
    assert(#plan.moves == 3 and status.state == "finished" and status.done == 3, status.reason)
    assert(status.skipped == 0 and status.moved == 1 and status.cleared == 2 and #f.emptied == 2)
    assert(f.deleted[bag] and rag.container == bag.inside and f.deleted[junk])
    assert(trips(f) == "23,0 3,0", "Nothing is taken out of a can: " .. trips(f))
end)

case("a can that also holds something not selected is not emptied for its own sake", function(f)
    local can, crate = f.can(f.square(3, 0), 20), f.crate(f.square(20, 0), "crate")
    f.roomSquares[#f.roomSquares + 1] = can.parent.where
    f.item(can, "Base.Nails"); local hammer = f.item(can, "Base.Hammer")
    local status, plan = f.run(clean(f, nil, {filter = {all = false, ids = {}, types = {"Base.Nails"}}}))
    assert(#plan.moves == 0 and #f.emptied == 0 and can:contains(hammer) and status.skipped == 0 and crate)
end)

case("rubbish within reach of a can goes straight in", function(f)
    local crate, can = f.crate(f.square(10, 0), "crate"), f.can(f.square(10, 2), 30)
    f.at = f.square(10, 1)
    -- Heavier than the player can lift at all.
    f.inventory.capacity = 5
    local heavy, junk = f.item(crate, "Base.Generator", {weight = 25}), f.item(crate)
    local tile = f.square(11, 1); f.roomSquares[#f.roomSquares + 1] = tile
    local leaf = f.drop(tile, "Base.Leaf")
    local status = f.run(clean(f))
    assert(status.state == "finished" and status.done == 3 and #f.visits == 0, status.reason)
    assert(f.deleted[heavy] and f.deleted[junk] and f.deleted[leaf])
    for _, op in ipairs(f.ops) do assert(op.kind ~= "transfer" or op.destination == can, "It went through the inventory") end
end)

case("asking also covers a can within reach of the rubbish", function(f)
    local crate, near, other = f.crate(f.square(10, 0), "crate"), f.can(f.square(10, 2), 30), f.can(f.square(30, 0), 30)
    f.at = f.square(10, 1)
    local junk, old = f.item(crate), f.item(near, "Base.Old")
    local status = asking(f, clean(f, crate))
    assert(status.state == "needs_review" and crate:contains(junk) and near:contains(old))
    assert(f.jobs:rejectBin(assert(f.jobs:reviewBin())))
    status = f.finish()
    assert(status.state == "finished" and f.deleted[junk] and near:contains(old) and f.emptied[1].can == other, status.reason)
    f.at = f.square(10, 1)
    local more = f.item(crate)
    assert(asking(f, clean(f, crate)).state == "needs_review")
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())) and f.finish().state == "finished" and f.deleted[more] and f.deleted[old])
end)

case("when the game refuses the direct way the item is carried instead", function(f)
    local crate, can = f.crate(f.square(10, 0), "crate"), f.can(f.square(10, 2), 30)
    f.at = f.square(10, 1)
    local junk = f.item(crate)
    f.refuse = function(op) return op.source == crate and op.destination == can end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 1 and f.deleted[junk], status.reason)
end)

case("light rubbish goes into a can many at a time, both directly and out of the bags", function(f)
    local near, can = f.crate(f.square(10, 0), "near"), f.can(f.square(10, 2), 20)
    f.at = f.square(10, 1)
    for _ = 1, 10 do f.item(near, "Base.Butt", {weight = 0.1}) end
    assert(f.run(clean(f, near)).done == 10)
    local function transfers() local n = 0; for _, op in ipairs(f.ops) do if op.kind == "transfer" then n = n + 1 end end; return n end
    assert(transfers() == 1, "Ten light items are one action, not " .. transfers())
    local far = f.crate(f.square(30, 0), "far")
    for _ = 1, 10 do f.item(far, "Base.Butt", {weight = 0.1}) end
    f.ops = {}
    local status = f.run(clean(f, far))
    assert(status.state == "finished" and status.done == 10 and can:isEmpty(), status.reason)
    assert(transfers() == 2, "One pickup and one delivery, not " .. transfers())
end)

case("a full run of light rubbish empties the can in between", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 1)
    for _ = 1, 25 do f.item(crate, "Base.Butt", {weight = 0.1}) end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 25 and #f.inventory.items == 0, status.reason)
    -- A can of 1 holds ten: ten, ten, five.
    assert(#f.emptied == 3 and f.emptied[1].count == 10 and f.emptied[2].count == 10 and f.emptied[3].count == 5)
end)

case("a can that refuses another item by count is emptied and tried once more", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 100)
    for _ = 1, 7 do f.item(crate) end
    f.refuse = function(op) return op.destination == can and #can.items >= 3 end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 7 and #f.emptied == 3, status.reason)
end)

local function until_(f, wanted)
    for _ = 1, 400 do
        f.now = f.now + 50
        f.jobs:tick()
        local op = f.jobs.pending and f.jobs.pending.op
        if op and wanted(op) then return end
    end
    error("The step never began")
end

case("a can within reach is emptied too before it is given up on, and takes light rubbish by the handful", function(f)
    local crate, can = f.crate(f.square(10, 0), "crate"), f.can(f.square(10, 2), 1)
    f.at = f.square(10, 1)
    for _ = 1, 25 do f.item(crate, "Base.Butt", {weight = 0.1}) end
    local status = f.run(clean(f, crate))
    local transfers = 0
    for _, op in ipairs(f.ops) do
        if op.kind == "transfer" then transfers = transfers + 1; assert(op.destination == can) end
    end
    assert(status.done == 25 and transfers == 3 and #f.emptied == 3, "Ten, ten and five, not " .. transfers)
    can.capacity, f.emptied = 100, {}
    for _ = 1, 7 do f.item(crate) end
    f.refuse = function(op) return op.destination == can and #can.items >= 3 end
    status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 7 and #f.emptied == 3 and #f.visits == 0, status.reason)
    for _, op in ipairs(f.ops) do assert(op.kind ~= "transfer" or op.destination == can, "It was carried instead") end
end)

case("no bag is put on when nothing has to be carried, and rubbish already in a can is no load", function(f)
    local crate, can = f.crate(f.square(10, 0), "crate"), f.can(f.square(10, 2), 30)
    f.at = f.square(10, 1)
    f.item(crate)
    local asked = 0
    assert(f.jobs:start(assert(f.jobs:preview(clean(f, crate))), {reviewBins = false}))
    f.jobs.carry.next = function() asked = asked + 1 end
    assert(f.finish().done == 1 and asked == 0)
    for _ = 1, 3 do f.item(can) end
    local far = f.crate(f.square(40, 0), "far")
    local junk, load = f.item(far), nil
    f.roomSquares = {can.parent.where, far.parent.where}
    f.at = f.square(40, 1)
    assert(f.jobs:start(assert(f.jobs:preview(clean(f))), {reviewBins = false}))
    f.jobs.carry.next = function(_, _, items) load = load or items end
    assert(f.finish().done == 4)
    assert(#load == 1 and load[1] == junk)
end)

case("walking off while a can is being emptied walks back to it on Resume", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0))
    local junk = f.item(crate)
    assert(f.jobs:start(assert(f.jobs:preview(clean(f, crate))), {reviewBins = false}))
    until_(f, function(op) return op.kind == "trash" end)
    assert(f.jobs:pause() and f.finish().state == "paused" and can:contains(junk))
    f.at = f.square(0, 0)
    assert(f.jobs:resume())
    local status = f.finish()
    assert(status.state == "finished" and f.deleted[junk] and status.done == 1, status.reason)
end)

case("a can exchanged while the job is paused over it still takes the load", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0))
    local junk = f.item(crate)
    assert(f.jobs:start(assert(f.jobs:preview(clean(f, crate))), {reviewBins = false}))
    until_(f, function(op) return op.kind == "transfer" and op.destination == can end)
    assert(f.jobs:pause() and f.finish().state == "paused")
    remove(can.parent.where.objects, can.parent)
    local other = f.can(f.square(20, 0), 30)
    other.parent.name = "another can"
    f.at = f.square(0, 0)
    assert(f.jobs:resume())
    local status = f.finish()
    assert(status.state == "finished" and status.done == 1 and f.deleted[junk] and f.emptied[1].can == other, status.reason)
end)

case("each can is emptied before it is left, so nothing is walked back for", function(f)
    local crate, small, large = f.crate(f.square(5, 0), "crate"), f.can(f.square(8, 0), 10), f.can(f.square(40, 0), 20)
    f.inventory.capacity = 16
    f.item(crate)
    f.item(crate, "Base.Tire", {weight = 15})
    local status = f.run(clean(f, crate))
    assert(status.done == 2 and #f.emptied == 2, status.reason)
    local last = f.visits[#f.visits]
    assert(last == "40,0" or last == "8,0")
    for index = 3, #f.visits do assert(f.visits[index] ~= f.visits[index - 2], "Walked back: " .. trips(f)) end
    assert(small:isEmpty() and large:isEmpty())
end)

case("a bag chosen as rubbish, and a bag inside it, are never worn", function(f)
    local crate = f.crate(f.square(5, 0), "crate")
    f.can(f.square(20, 0))
    local duffel = f.item(crate, "Base.Duffel", {bag = true})
    local pouch = f.item(duffel.inside, "Base.Pouch", {bag = true})
    local mine = f.item(f.inventory, "Base.Backpack", {bag = true})
    local offered = {}
    assert(f.jobs:start(assert(f.jobs:preview(clean(f, crate, {includeBags = false}))), {reviewBins = false}))
    f.jobs.carry.next = function(_, records) for _, record in ipairs(records) do offered[record.item] = true end end
    f.finish()
    assert(offered[mine] and not offered[duffel] and not offered[pouch])
    offered = {}
    local other, target = f.crate(f.square(6, 0), "other"), f.crate(f.square(30, 0), "target")
    local found = f.item(other, "Base.Duffel", {bag = true}); f.item(other)
    local request = f.request({kind = "container", ref = target}, {scope = "container", sourceContainer = other})
    request.filter = {all = false, ids = {}, types = {"Base.Nails"}}
    assert(f.jobs:start(assert(f.jobs:preview(request))))
    f.jobs.carry.next = function(_, records) for _, record in ipairs(records) do offered[record.item] = true end end
    f.finish()
    assert(offered[found], "A found bag that is not part of the load still helps to carry it")
end)

case("a server that forbids emptying cans is told before any work", function(f)
    local crate = f.crate(f.square(5, 0), "crate")
    f.can(f.square(8, 0)); f.item(crate)
    f.world:observeNearby()
    isClient = function() return true end
    getServerOptions = function() return {getBoolean = function(_, name) return name ~= "TrashDeleteAll" end} end
    assert(f.world:binDistance() == nil)
    local plan, err = f.jobs:preview(clean(f, crate))
    assert(not plan and err:find("server does not let players empty trash cans", 1, true), err)
end)

case("Clean in multiplayer waits for an unopened can to answer", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0))
    can.explored = false
    f.item(crate)
    local old, asked
    isClient = function() return true end
    getServerOptions = function() return {getBoolean = function() return true end} end
    f.loot.checkExplored = function(_, container) container.explored, asked = true, f.now end
    local arrived = f.onArrive
    assert(f.jobs:start(assert(f.jobs:preview(clean(f, crate)))))
    for _ = 1, 400 do
        f.now = f.now + 50
        f.jobs:tick()
        if asked and not old and f.now - asked >= 400 then old = f.item(can, "Base.Old") end
        if f.jobs:status().state ~= "running" then break end
    end
    assert(f.jobs:status().state == "needs_review" and old and not arrived, "The late reply must be asked about")
    assert(f.now - asked >= 1000 and f.now - asked < 3000)
    assert(f.jobs:approveBin(assert(f.jobs:reviewBin())) and f.finish().state == "finished" and f.deleted[old])
end)

case("a marked area that is out of sight is walked to and cleaned", function(f)
    road(f, 120)
    local crate = f.crate(f.square(102, 0), "far crate")
    local can = f.can(f.square(111, 0))
    f.state.trash["111:0:0"] = 20
    f.sight = 20
    local junk = f.item(crate)
    local plan = assert(f.jobs:preview(clean(f, nil, {scope = "area", area = {x1 = 100, x2 = 104, y1 = 0, y2 = 0, z = 0}})))
    assert(#plan.moves == 0 and plan.pending == 1, "One place to look into, not nothing to move")
    assert(f.jobs:start(plan, {reviewBins = false}))
    local status = f.finish()
    assert(status.state == "finished" and status.done == 1 and f.deleted[junk] and can, status.reason)
end)

case("an area on an upper floor does not wait for open air", function(f)
    local tile = f.square(1, 0, 1)
    f.square(0, 0, 0); f.square(1, 0, 0); f.square(2, 0, 0)
    f.can(f.square(0, 1, 0)); local leaf = f.drop(tile, "Base.Leaf")
    f.at = f.square(1, 0, 1)
    local plan = assert(f.jobs:preview(clean(f, nil, {scope = "area", area = {x1 = 0, x2 = 2, y1 = 0, y2 = 0, z = 1}})))
    assert(plan.pending == 0 and #plan.moves == 1 and leaf)
end)

case("cans are remembered and forgotten anywhere in sight, and old saves still load", function(f)
    local can = f.can(f.square(7, 7), 20); f.state.trash["7:7:0"] = nil
    assert(f.world:observeNearby() and f.state.trash["7:7:0"] == 20)
    remove(can.parent.where.objects, can.parent)
    f.at = f.square(1, 0)
    assert(f.world:observeNearby() and f.state.trash["7:7:0"] == nil, "A can moved seven tiles away is gone")
    f.at = f.square(2, 0)
    assert(not f.world:observeNearby(), "Nothing new is not a reason to save")
    local old = {["world:10:-4:1:3:trashcontainers_01_0:0:bin"] = {x = 10, y = -4, z = 1, sprite = "trashcontainers_01_0",
        index = 3, slot = 0, kind = "bin", capacity = 20, used = 3}, ["bad"] = {x = "east"}, ["5:6:0"] = 30}
    local world = World.new(f.player, {trash = old})
    assert(world.state.trash["10:-4:1"] == 20 and world.state.trash["5:6:0"] == 30)
    local count = 0
    for _ in pairs(world.state.trash) do count = count + 1 end
    assert(count == 2)
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

case("put away does not unpack a kit that is already in storage for its contents", function(f)
    local medical, box = f.crate(f.square(5, 0), "medical"), f.crate(f.square(8, 0), "box")
    f.state.containerLabels[assert(f.world:key(medical))] = {"native:Medical"}
    local kit = f.item(medical, "Base.FirstAidKit", {bag = true, category = "Container"})
    local packed = f.item(kit.inside, "Base.Bandage", {category = "Medical"})
    local loose = f.item(box, "Base.Bandage", {category = "Medical"})
    local status = f.run(f.request({kind = "labels", labels = {}}, {includeBags = true}))
    assert(status.done == 1 and medical:contains(loose) and kit.inside:contains(packed), status.reason)
end)

case("put away prefers where the same thing is, then the closest label, then the nearest", function(f)
    local id = "custom:ammo"
    f.graph = assert(Categories.new({{id = id, name = "Ammo", types = {"Base.Nails"}, includes = {}}}))
    f.world.graph, f.jobs.graph = f.graph, f.graph
    local near, custom, tagged, holding = f.crate(f.square(3, 0), "near"), f.crate(f.square(6, 0), "custom"),
        f.crate(f.square(9, 0), "tagged"), f.crate(f.square(12, 0), "holding")
    local function label(crate, value) f.state.containerLabels[assert(f.world:key(crate))] = {value} end
    label(near, "native:Material"); label(custom, id); label(tagged, "custom:mine"); label(holding, "native:Material")
    f.item(holding, "Base.Glue")
    local glue, nails, screws, named = f.item(f.inventory, "Base.Glue"), f.item(f.inventory, "Base.Nails"),
        f.item(f.inventory, "Base.Screws"), f.item(f.inventory, "Base.Nails")
    f.state.itemLabels[tostring(named.id)] = {"custom:mine"}
    local status = f.run(f.request({kind = "labels", labels = {}}, {scope = "inventory"}))
    assert(status.state == "finished" and status.done == 4, status.reason)
    assert(holding:contains(glue) and custom:contains(nails) and near:contains(screws) and tagged:contains(named))
end)

local function labelled(f, crate, ...)
    f.state.containerLabels[assert(f.world:key(crate))] = {...}
    return crate
end
local function putAway(f, options) return f.run(f.request({kind = "labels", labels = {}}, options or {scope = "inventory"})) end

case("a label for a kind of item beats where the same kind happens to lie", function(f)
    local named, holding = labelled(f, f.crate(f.square(9, 0), "named"), "type:Base.Nails"), labelled(f, f.crate(f.square(3, 0), "holding"), "native:Material")
    f.item(holding, "Base.Nails")
    local nails, glue = f.item(f.inventory, "Base.Nails"), f.item(f.inventory, "Base.Glue")
    local status = putAway(f)
    assert(status.done == 2 and named:contains(nails) and holding:contains(glue), status.reason)
end)

case("a place for one item is for that item only", function(f)
    local rack, crate = f.crate(f.square(9, 0), "rack"), labelled(f, f.crate(f.square(3, 0), "crate"), "type:Base.Axe")
    local mine, spare = f.item(f.inventory, "Base.Axe"), f.item(f.inventory, "Base.Axe")
    local mark = "item:" .. mine.id .. ":Base.Axe"
    labelled(f, rack, mark)
    f.state.itemLabels[tostring(mine.id)] = {mark}
    local status = putAway(f)
    assert(status.done == 2 and rack:contains(mine) and crate:contains(spare), status.reason)
end)

case("a place chosen for an item or its kind moves it out of a category's storage, once", function(f)
    local tools, rack, shed = labelled(f, f.crate(f.square(2, 0), "tools"), "native:Tool"), f.crate(f.square(6, 0), "rack"),
        labelled(f, f.crate(f.square(9, 0), "shed"), "type:Base.Saw")
    local hammer, saw, wrench = f.item(tools, "Base.Hammer", {category = "Tool"}), f.item(tools, "Base.Saw", {category = "Tool"}),
        f.item(tools, "Base.Wrench", {category = "Tool"})
    local mark = "item:" .. hammer.id .. ":Base.Hammer"
    labelled(f, rack, mark)
    f.state.itemLabels[tostring(hammer.id)] = {mark}
    local status = putAway(f, {scope = "room"})
    assert(status.done == 2 and rack:contains(hammer) and shed:contains(saw) and tools:contains(wrench), status.reason)
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}}, {scope = "room"})))
    assert(#plan.moves == 0)
end)

case("a full place sends the item to the next, and says so beforehand", function(f)
    local near, far = labelled(f, f.crate(f.square(2, 0), "near"), "native:Material"), labelled(f, f.crate(f.square(6, 0), "far"), "native:Material")
    near.capacity = 0
    local nails = f.item(f.inventory)
    assert(f.world:home(nails).container == far and f.world:putAway()[1].storage.container == far)
    far.capacity = 0
    f.now = f.now + 2000
    local home, placed, full = f.world:home(nails)
    assert(not home and not placed and full.container == near and #f.world:putAway() == 0)
end)

case("filled last waits for the others of its kind, not for a wider label, and never passes over one item's own place", function(f)
    local material, nails, rack = labelled(f, f.crate(f.square(2, 0), "material"), "native:Material"), labelled(f, f.crate(f.square(6, 0), "nails"), "type:Base.Nails"),
        f.crate(f.square(9, 0), "rack")
    local mine, spare = f.item(f.inventory, "Base.Nails"), f.item(f.inventory, "Base.Nails")
    local mark = "item:" .. mine.id .. ":Base.Nails"
    labelled(f, rack, mark)
    f.state.itemLabels[tostring(mine.id)] = {mark}
    f.state.storage[f.world:key(nails)], f.state.storage[f.world:key(rack)] = {order = "last"}, {order = "last"}
    local status = putAway(f)
    assert(status.done == 2 and rack:contains(mine) and nails:contains(spare) and #material.items == 0, status.reason)
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}}, {scope = "room"})))
    assert(#plan.moves == 0, "It is not moved a second time")
end)

case("what is in a category's storage stays sorted while its own place is full", function(f)
    local material, box = labelled(f, f.crate(f.square(2, 0), "material"), "native:Material"), labelled(f, f.crate(f.square(6, 0), "box"), "type:Base.Nails")
    local nails = f.item(material, "Base.Nails")
    box.capacity = 0
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}}, {scope = "room"})))
    assert(#plan.moves == 0 and plan.skipped[1].reason == "Already sorted")
    local home, placed = f.world:home(nails)
    assert(home == nil and placed)
    box.capacity, f.now = 5, f.now + 2000
    assert(f.world:home(nails).container == box)
end)

case("put away never moves things between the player's own bags, and automatic put-away only to what stays put", function(f)
    local pantry = labelled(f, f.crate(f.square(5, 0), "pantry"), "native:Food")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    labelled(f, pack.inside, "native:Food")
    f.world:_observe(pack.inside)
    local soup = f.item(f.inventory, "Base.Soup", {category = "Food"})
    assert(f.world:home(soup).container == pantry and f.world:putAway()[1].storage.container == pantry)
    local status = putAway(f)
    assert(status.done == 1 and pantry:contains(soup), status.reason)
    local bag = f.drop(f.square(1, 0), "Base.Duffel", {bag = true})
    labelled(f, bag.inside, "type:Base.Soup")
    f.world:_observe(bag.inside)
    f.item(f.inventory, "Base.Soup", {category = "Food"})
    f.now = f.now + 2000
    assert(f.world:putAway()[1].storage.container == bag.inside and f.world:putAway(true)[1].storage.container == pantry)
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}, near = f.world:nearHere(true)}, {scope = "inventory"})))
    assert(#plan.moves == 1 and plan.moves[1].to == "crate")
end)

case("something whose place is a bag the player carries stays with them", function(f)
    labelled(f, f.crate(f.square(3, 0), "tools"), "native:Tool"); labelled(f, f.crate(f.square(5, 0), "medical"), "native:Medical")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    local axe = f.item(f.inventory, "Base.Axe", {category = "Tool"})
    local mark = "item:" .. axe.id .. ":Base.Axe"
    labelled(f, pack.inside, mark, "type:Base.Bandage")
    f.state.itemLabels[tostring(axe.id)] = {mark}
    f.world:_observe(pack.inside)
    local bandage = f.item(pack.inside, "Base.Bandage", {category = "Medical"})
    assert(#f.world:putAway() == 0 and #f.world:putAway(true) == 0 and f.world:home(axe).container == pack.inside)
    local _, placed = f.world:home(bandage)
    assert(placed)
    local status = putAway(f, {scope = "inventory", includeBags = true})
    assert(status.state == "finished" and pack.inside:contains(axe) and pack.inside:contains(bandage), status.reason)
end)

case("what a labelled bag brought home is put away, and what it collects from a room stays in it", function(f)
    local pantry, shelf = labelled(f, f.crate(f.square(5, 0), "pantry"), "native:Food"), f.crate(f.square(8, 0), "shelf")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    labelled(f, pack.inside, "native:Food")
    f.world:_observe(pack.inside)
    local beans = f.item(pack.inside, "Base.Beans", {category = "Food"})
    assert(f.world:home(beans).container == pantry and f.world:putAway(true)[1].item == beans)
    local status = putAway(f, {scope = "inventory", includeBags = true})
    assert(status.done == 1 and pantry:contains(beans), status.reason)
    f.state.containerLabels[f.world:key(pantry)], f.roomSquares = nil, {f.square(8, 0)}
    local soup = f.item(shelf, "Base.Soup", {category = "Food"})
    status = putAway(f, {scope = "room"})
    assert(status.done == 1 and pack.inside:contains(soup), status.reason)
end)

case("one item's own place wins over storage for its kind, even from where it lies", function(f)
    local crate, rack = labelled(f, f.crate(f.square(3, 0), "crate"), "type:Base.Axe"), f.crate(f.square(6, 0), "rack")
    local axe, other = f.item(crate, "Base.Axe"), f.item(crate, "Base.Axe")
    local mark = "item:" .. axe.id .. ":Base.Axe"
    labelled(f, rack, mark)
    f.state.itemLabels[tostring(axe.id)] = {mark}
    assert(f.world:home(axe).container == rack and select(2, f.world:home(other)))
    local status = putAway(f, {scope = "room"})
    assert(status.done == 1 and rack:contains(axe) and crate:contains(other), status.reason)
end)

case("loot from a room goes to storage at hand before a bag the player carries for that category", function(f)
    local pantry, shelf = labelled(f, f.crate(f.square(3, 0), "pantry"), "native:Food"), f.crate(f.square(1, 0), "shelf")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    labelled(f, pack.inside, "native:Food")
    f.world:_observe(pack.inside)
    local soup = f.item(shelf, "Base.Soup", {category = "Food"})
    assert(f.world:home(soup).container == pantry)
    local status = putAway(f, {scope = "room"})
    assert(status.done == 1 and pantry:contains(soup), status.reason)
end)

case("a category given to one copy does not outrank that copy's own place", function(f)
    local tools, rack = labelled(f, f.crate(f.square(2, 0), "tools"), "native:Tool"), f.crate(f.square(9, 0), "rack")
    local axe = f.item(tools, "Base.Axe", {category = "Tool"})
    local mark = "item:" .. axe.id .. ":Base.Axe"
    labelled(f, rack, mark)
    f.state.itemLabels[tostring(axe.id)] = {"native:Tool", mark}
    local status = putAway(f, {scope = "room"})
    assert(status.done == 1 and rack:contains(axe), status.reason)
end)

case("automatic put-away never lets a carried bag take what was brought home", function(f)
    local pantry = labelled(f, f.crate(f.square(3, 0), "pantry"), "type:Base.Soup")
    f.state.storage[f.world:key(pantry)] = {order = "first"}
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    labelled(f, pack.inside, "type:Base.Soup")
    f.world:_observe(pack.inside)
    local soup = f.item(f.inventory, "Base.Soup", {category = "Food"})
    pantry.capacity = 0
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}, near = f.world:nearHere(true)}, {scope = "inventory", only = {[tostring(soup.id)] = true}})))
    assert(#plan.moves == 0 and f.inventory:contains(soup))
end)

case("loot waiting in a carried bag goes on to storage that stays put, not to a bag on the floor", function(f)
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    labelled(f, pack.inside, "native:Food")
    f.world:_observe(pack.inside)
    local duffel = f.drop(f.square(1, 0), "Base.Duffel", {bag = true})
    labelled(f, duffel.inside, "native:Food")
    f.world:_observe(duffel.inside)
    local soup = f.item(pack.inside, "Base.Soup", {category = "Food"})
    assert(#f.world:putAway() == 0)
    local pantry = labelled(f, f.crate(f.square(3, 0), "pantry"), "native:Food")
    f.now = f.now + 2000
    assert(f.world:putAway()[1].storage.container == pantry)
end)

case("Put Away counts only what fits", function(f)
    labelled(f, f.crate(f.square(3, 0), "box"), "native:Material").capacity = 3
    for _ = 1, 10 do f.item(f.inventory) end
    assert(#f.world:putAway() == 3)
end)

case("a place for one item in a bag keeps no other loot out of it", function(f)
    local source = f.crate(f.square(5, 0), "source")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    labelled(f, pack.inside, "item:99:Base.Axe")
    local soup = f.item(source, "Base.Soup", {category = "Food"})
    f.run(f.request({kind = "inventory"}))
    assert(pack.inside:contains(soup))
    labelled(f, pack.inside, "item:99:Base.Axe", "native:Tool")
    local beans = f.item(source, "Base.Beans", {category = "Food"})
    f.run(f.request({kind = "inventory"}))
    assert(f.inventory:contains(beans))
end)

case("a kept kind may be eaten, drunk and poured, and an empty key ring stays on the player", function(f)
    local nails, ring = f.item(f.inventory), f.item(f.inventory, "Base.KeyRing", {bag = true, keyRing = true})
    f.state.keepTypes["Base.Nails"] = true
    assert(f.world:protected(nails) and not f.world:protected(nails, {using = true}))
    labelled(f, f.crate(f.square(3, 0), "rest"), "rest:")
    local protected, why = f.world:protected(ring)
    assert(protected and why == "Equipped" and #f.world:putAway() == 0)
end)

case("a mark follows its item when the game gives it a new identity", function(f)
    local rack = f.crate(f.square(3, 0), "rack")
    local old, new = f.item(f.inventory, "Base.Jacket"), f.item(f.inventory, "Base.JacketUp")
    local mark = "item:" .. old.id .. ":Base.Jacket"
    labelled(f, rack, mark)
    f.state.itemLabels[tostring(old.id)], f.state.checklist = {mark}, {ids = {mark}, types = {}}
    f.world:replaceGear(old.id, "Base.Jacket", new)
    local now = "item:" .. new.id .. ":Base.JacketUp"
    assert(f.state.itemLabels[tostring(new.id)][1] == now and f.state.containerLabels[f.world:key(rack)][1] == now and f.state.checklist.ids[1] == now)
    assert(f.world:home(new).container == rack)
end)

case("storage for anything else takes only what nothing else will", function(f)
    local rest, food = labelled(f, f.crate(f.square(2, 0), "rest"), "rest:"), labelled(f, f.crate(f.square(9, 0), "food"), "native:Food")
    local soup, sock = f.item(f.inventory, "Base.Soup", {category = "Food"}), f.item(f.inventory, "Base.Sock", {category = "Clothing"})
    local status = putAway(f)
    assert(status.done == 2 and food:contains(soup) and rest:contains(sock), status.reason)
end)

case("what lies in storage for anything else moves once it has a place, and is not passed between such containers", function(f)
    local first, second = labelled(f, f.crate(f.square(2, 0), "first"), "rest:"), labelled(f, f.crate(f.square(4, 0), "second"), "rest:")
    local sock, soup = f.item(second, "Base.Sock", {category = "Clothing"}), f.item(second, "Base.Soup", {category = "Food"})
    local food = labelled(f, f.crate(f.square(9, 0), "food"), "native:Food")
    local status, plan = putAway(f, {scope = "room"})
    assert(#plan.moves == 1 and status.done == 1 and food:contains(soup) and second:contains(sock) and #first.items == 0, status.reason)
end)

case("storage filled first is full before the rest, and storage filled last waits for the others", function(f)
    local last, usual, first = labelled(f, f.crate(f.square(2, 0), "last"), "native:Food"), labelled(f, f.crate(f.square(4, 0), "usual"), "native:Food"),
        labelled(f, f.crate(f.square(9, 0), "first"), "native:Food")
    f.state.storage[f.world:key(last)], f.state.storage[f.world:key(first)] = {order = "last"}, {order = "first"}
    first.capacity, usual.capacity = 2, 1
    for _ = 1, 4 do f.item(f.inventory, "Base.Soup", {category = "Food"}) end
    local status = putAway(f)
    assert(status.done == 4 and #first.items == 2 and #usual.items == 1 and #last.items == 1, status.reason)
end)

case("storage filled last still comes before storage for anything else", function(f)
    local rest, last = labelled(f, f.crate(f.square(2, 0), "rest"), "rest:"), labelled(f, f.crate(f.square(9, 0), "last"), "native:Food")
    f.state.storage[f.world:key(last)] = {order = "last"}
    local soup = f.item(f.inventory, "Base.Soup", {category = "Food"})
    local status = putAway(f)
    assert(status.done == 1 and last:contains(soup) and #rest.items == 0, status.reason)
end)

case("a job for certain items moves no others", function(f)
    local crate = labelled(f, f.crate(f.square(3, 0), "crate"), "native:Material")
    local wanted, other = f.item(f.inventory), f.item(f.inventory)
    local status, plan = putAway(f, {scope = "inventory", only = {[tostring(wanted.id)] = true}})
    assert(#plan.moves == 1 and status.done == 1 and crate:contains(wanted) and f.inventory:contains(other), status.reason)
end)

case("a job kept to storage around here leaves further storage alone", function(f)
    local far = labelled(f, f.crate(f.square(12, 0), "far"), "native:Material")
    f.item(f.inventory)
    local plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}, near = {x = 0, y = 0, range = 10}}, {scope = "inventory"})))
    assert(#plan.moves == 0)
    plan = assert(f.jobs:preview(f.request({kind = "labels", labels = {}, near = {x = 0, y = 0, range = 12}}, {scope = "inventory"})))
    assert(#plan.moves == 1 and #far.items == 0)
end)

case("keeping every one of a kind holds on to what is carried, and loots and sorts the rest", function(f)
    local crate, loose = labelled(f, f.crate(f.square(3, 0), "crate"), "native:Material"), f.crate(f.square(5, 0), "loose")
    local mine, theirs = f.item(f.inventory, "Base.Nails"), f.item(loose, "Base.Nails")
    f.state.keepTypes["Base.Nails"] = true
    local status = putAway(f, {scope = "room", includeInventory = true})
    assert(status.done == 1 and f.inventory:contains(mine) and crate:contains(theirs), status.reason)
    status = f.run(f.request({kind = "inventory"}))
    assert(f.inventory:contains(theirs), status.reason)
end)

case("a kept kind is never thrown away, from a room, a bag or a can", function(f)
    local loose, can = f.crate(f.square(3, 0), "loose"), f.can(f.square(5, 0))
    local kept, rubbish = f.item(loose, "Base.Nails"), f.item(loose, "Base.Rag")
    local bag = f.item(loose, "Base.Bag", {bag = true})
    local inside = f.item(bag.inside, "Base.Nails")
    f.state.keepTypes["Base.Nails"] = true
    f.run(f.request({kind = "trash"}, {includeBags = false}))
    assert(f.deleted[rubbish] and loose:contains(kept) and bag.inside:contains(inside) and loose:contains(bag))
    local holds = f.item(can, "Base.Nails")
    f.item(loose, "Base.Rag")
    local plan, why = f.jobs:preview(f.request({kind = "trash"}))
    assert(plan == nil and why:find("Nails", 1, true) and can:contains(holds), tostring(why))
end)

case("what a tooltip says is what Put Away does", function(f)
    local rest, food, pantry = labelled(f, f.crate(f.square(2, 0), "rest"), "rest:"), labelled(f, f.crate(f.square(6, 0), "food"), "native:Food"),
        labelled(f, f.crate(f.square(8, 0), "pantry"), "type:Base.Soup")
    local soup, beans, sock = f.item(f.inventory, "Base.Soup", {category = "Food"}), f.item(f.inventory, "Base.Beans", {category = "Food"}),
        f.item(f.inventory, "Base.Sock", {category = "Clothing"})
    local said = {}
    for _, item in ipairs({soup, beans, sock}) do said[item] = f.world:homes(item)[1].storage.container end
    assert(said[soup] == pantry and said[beans] == food and said[sock] == rest)
    putAway(f)
    for item, container in pairs(said) do assert(container:contains(item)) end
    f.now = f.now + 2000
    local homes, placed = f.world:homes(soup)
    assert(#homes == 0 and placed == true)
end)

case("Put Away counts what has a place at hand and leaves kept, favorite and worn things", function(f)
    labelled(f, f.crate(f.square(3, 0), "near"), "native:Material")
    labelled(f, f.crate(f.square(60, 0), "far"), "native:Food")
    local nails, kept = f.item(f.inventory), f.item(f.inventory)
    f.item(f.inventory, "Base.Soup", {category = "Food"})
    f.item(f.inventory, "Base.Glue", {favorite = true})
    f.worn = f.item(f.inventory, "Base.Tape")
    f.state.keep[tostring(kept.id)] = true
    local entries = f.world:putAway()
    assert(#entries == 1 and entries[1].item == nails)
    assert(f.world:atHome(20) and not f.world:atHome(2))
end)

case("what belongs in a container is offered by the container, whatever else would take it", function(f)
    local rest, food = labelled(f, f.crate(f.square(2, 0), "rest"), "rest:"), labelled(f, f.crate(f.square(6, 0), "food"), "native:Food")
    local soup, sock = f.item(f.inventory, "Base.Soup", {category = "Food"}), f.item(f.inventory, "Base.Sock", {category = "Clothing"})
    local fits = f.world:fitting(food)
    assert(#fits == 1 and fits[1] == soup)
    fits = f.world:fitting(rest)
    assert(#fits == 1 and fits[1] == sock, "Anything else means what nothing else takes")
end)

case("a fixture that moves up takes its labels, name and order along", function(f)
    local tile = f.square(4, 0)
    local lower, upper = f.crate(tile, "crate"), f.crate(tile, "crate")
    local key = assert(f.world:key(upper))
    f.world:_observe(lower); f.world:_observe(upper)
    f.state.containerLabels[key], f.state.storage[key] = {"native:Food"}, {order = "last"}
    table.remove(tile.objects, 1)
    local moved = assert(f.world:key(upper))
    assert(moved ~= key and f.state.containerLabels[moved][1] == "native:Food" and f.state.storage[moved].order == "last")
    assert(f.state.containerLabels[key] == nil and f.state.storage[key] == nil)
end)

case("a name given in the game is shown and remembered, and the plain name is no name", function(f)
    local crate = labelled(f, f.crate(f.square(4, 0), "crate"), "native:Food")
    function crate:getCustomName() return self.custom end
    f.world:_observe(crate)
    assert(f.world:name(crate) == "crate" and f.world:storages()[1].given == nil)
    crate.custom = "Pantry"
    assert(f.world:name(crate) == "Pantry" and f.world:storages()[1].name == "Pantry")
    f.sight = 1; f.world.endpoints = {}
    assert(f.world:storages()[1].name == "Pantry" and not f.world:storages()[1].container)
end)

case("labels for what is inside are its kinds, or their categories with the player's own first", function(f)
    f.graph = assert(Categories.new({{id = "custom:1", name = "Fixings", types = {"Base.Nails"}, includes = {}}}))
    f.world.graph = f.graph
    local crate = f.crate(f.square(4, 0), "crate")
    f.item(crate, "Base.Nails"); f.item(crate, "Base.Nails"); f.item(crate, "Base.Soup", {category = "Food"})
    local types, categories = f.world:labelsInside(crate)
    assert(table.concat(types, " ") == "type:Base.Nails type:Base.Soup" and table.concat(categories, " ") == "custom:1 native:Food")
end)

case("an item already carried in a bag labelled for it is put away", function(f)
    local source = f.crate(f.square(5, 0), "source")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.wearing[pack] = "base:Back"
    f.state.containerLabels[assert(f.world:key(pack.inside))] = {"native:Food"}
    f.world:_observe(pack.inside)
    local soup = f.item(source, "Base.Soup", {category = "Food"})
    local status = f.run(f.request({kind = "labels", labels = {}}))
    assert(status.state == "finished" and status.done == 1 and status.skipped == 0 and pack.inside:contains(soup), status.reason)
end)

case("a bag being hauled is never worn to carry the rest", function(f)
    local source, target = f.crate(f.square(5, 0), "source"), f.crate(f.square(20, 0), "target"); f.roomSquares[3] = nil
    local bag = f.item(source, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    for _ = 1, 3 do f.item(source, "Base.Plank", {weight = 3}) end
    local status = f.run(f.request({kind = "container", ref = target}))
    assert(status.state == "finished" and status.done == 4 and status.skipped == 0 and #target.items == 4, status.reason)
    assert(target:contains(bag) and not f.wearing[bag])
end)

case("a bag inside a hauled bag is not taken out and worn", function(f)
    local source, target = f.crate(f.square(5, 0), "source"), f.crate(f.square(20, 0), "target"); f.roomSquares[3] = nil
    local outer = f.item(source, "Base.Duffel", {bag = true})
    local inner = f.item(outer.inside, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    f.item(source, "Base.Plank", {weight = 9})
    local status = f.run(f.request({kind = "container", ref = target}))
    assert(status.state == "finished" and status.done == 2 and outer.inside:contains(inner) and not f.wearing[inner], status.reason)
end)

case("taking everything counts a bag that was put on, and what is in it, as taken", function(f)
    local source = f.crate(f.square(5, 0), "source")
    local bag = f.item(source, "Base.Pack", {bag = true, wear = "base:Back", reduction = 80})
    local inside, plank = f.item(bag.inside, "Base.Soup"), f.item(source, "Base.Plank", {weight = 9})
    local status = f.run(f.request({kind = "inventory"}, {includeBags = true}))
    assert(status.state == "finished" and status.done == 3 and status.skipped == 0, status.reason)
    assert(f.wearing[bag] and bag.inside:contains(inside) and bag.inside:contains(plank) and #source.items == 0)
end)

case("no bag is put on for things it cannot hold", function(f)
    local source, target = f.crate(f.square(5, 0), "source"), f.crate(f.square(20, 0), "target"); f.roomSquares[3] = nil
    local strap = f.item(f.inventory, "Base.AmmoStrap", {bag = true, wear = "base:Back", reduction = 85, accepts = function() return false end})
    f.item(source, "Base.Plank", {weight = 3})
    assert(f.run(f.request({kind = "container", ref = target})).state == "finished" and not f.wearing[strap])
    local small = f.item(f.inventory, "Base.Holster", {bag = true, wear = "base:Back", reduction = 85, largest = 1.3})
    f.item(source, "Base.Plank", {weight = 3})
    assert(f.run(f.request({kind = "container", ref = target})).state == "finished" and not f.wearing[small])
    local useful = f.item(f.inventory, "Base.Pack", {bag = true, wear = "base:Back", reduction = 60})
    f.item(source, "Base.Plank", {weight = 3})
    assert(f.run(f.request({kind = "container", ref = target})).state == "finished" and f.wearing[useful])
    assert(#target.items == 3)
end)

case("loot goes into worn bags only, unless the settings add others", function(f)
    local source = f.crate(f.square(5, 0), "source")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, reduction = 60, capacity = 1})
    f.wearing[pack] = "base:Back"
    local loot = f.item(f.inventory, "Base.LootBag", {bag = true, reduction = 90})
    local pouch = f.item(pack.inside, "Base.Pouch", {bag = true, weight = 0})
    f.item(loot.inside, "Base.Nails"); f.item(pouch.inside, "Base.Screws", {weight = 0})
    local first, second = f.item(source), f.item(source)
    assert(f.run(f.request({kind = "inventory"})).done == 2)
    assert(pack.inside:contains(first) and f.inventory:contains(second) and #loot.inside.items == 1 and #pouch.inside.items == 1)
    f.world.preference = function(key) return key == "condenseUseUnequipped" end
    local third = f.item(source)
    assert(f.run(f.request({kind = "inventory"})).done == 1 and loot.inside:contains(third))
    f.world.preference = function(key) return key == "condenseNested" end
    local fourth = f.item(source, "Base.Screws", {weight = 0})
        assert(f.run(f.request({kind = "inventory"})).done == 1 and pouch.inside:contains(fourth))
end)

case("a key goes on a key ring or stays in main inventory, where the game looks for it", function(f)
    local source = f.crate(f.square(5, 0), "source")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, reduction = 85})
    f.wearing[pack] = "base:Back"
    local key = f.item(source, "Base.CarKey", {class = "Key"})
    assert(f.run(f.request({kind = "inventory"})).done == 1 and f.inventory:contains(key))
    local ring = f.item(f.inventory, "Base.KeyRing", {bag = true, reduction = 85, keyRing = true, capacity = 1,
        accepts = function(value) return value.class == "Key" end})
    local other = f.item(source, "Base.HouseKey", {class = "Key"})
    assert(f.run(f.request({kind = "inventory"})).done == 1 and ring.inside:contains(other))
    local target, hauled = f.crate(f.square(20, 0), "target"), f.item(source, "Base.CarKey", {class = "Key", weight = 2})
    f.onTransfer = function(op) assert(op.destination ~= pack.inside) end
    assert(f.run(f.request({kind = "container", ref = target}, {scope = "container", sourceContainer = source})).done == 1 and target:contains(hauled))
end)

case("a bag labelled for one thing takes nothing else from a loot run", function(f)
    local source = f.crate(f.square(5, 0), "source")
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, reduction = 85})
    f.wearing[pack] = "base:Back"
    f.state.containerLabels[assert(f.world:key(pack.inside))] = {"native:Food"}
    local soup, saw = f.item(source, "Base.Soup", {category = "Food"}), f.item(source, "Base.Saw", {category = "Tool"})
    assert(f.run(f.request({kind = "inventory"})).done == 2)
    assert(pack.inside:contains(soup) and f.inventory:contains(saw))
end)

case("preparing bags reads each container once however many items it holds", function(f)
    local source = f.crate(f.square(5, 0), "source")
    for _ = 1, 300 do f.item(source, nil, {weight = 0.1}) end
    local plan = assert(f.jobs:preview(f.request({kind = "inventory"})))
    local reads, items = 0, source.getItems
    function source:getItems() reads = reads + 1; return items(self) end
    assert(f.jobs:start(plan))
    f.now = f.now + 50
    f.jobs:tick()
    assert(reads <= 2, "Read the crate " .. reads .. " times in one tick")
end)

local function condense(f, options)
    local plan = assert(f.jobs:previewCondense(options))
    if #plan.moves == 0 then return plan.condense, plan end
    assert(f.jobs:start(plan))
    return f.finish(), plan
end

case("Condense keeps keys where the game looks and other things out of a labelled bag", function(f)
    local pack = f.item(f.inventory, "Base.Pack", {bag = true, reduction = 85})
    f.wearing[pack] = "base:Back"
    local key, saw, soup = f.item(f.inventory, "Base.CarKey", {class = "Key"}), f.item(f.inventory, "Base.Saw", {category = "Tool"}),
        f.item(f.inventory, "Base.Soup", {category = "Food"})
    f.state.containerLabels[assert(f.world:key(pack.inside))] = {"native:Food"}
    condense(f)
    assert(pack.inside:contains(soup) and f.inventory:contains(saw) and f.inventory:contains(key))
    f.state.containerLabels[assert(f.world:key(pack.inside))] = nil
    condense(f)
    assert(pack.inside:contains(saw) and f.inventory:contains(key))
    local ring = f.item(f.inventory, "Base.KeyRing", {bag = true, reduction = 85, keyRing = true, capacity = 1,
        accepts = function(value) return value.class == "Key" end})
    condense(f)
    assert(ring.inside:contains(key))
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
    assert(not f.world:binDistance() and not f.world:hasStorageLabels() and #f.world:knownBins() == 0 and #f.world:storages() == 0)
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
    f.world:observeNearby()
    local labelled = f.world:storages()
    assert(#labelled == 2)
    for _, entry in ipairs(labelled) do
        if entry.container then
            assert(entry.container == crate and entry.labels[1] == "native:Food" and entry.point.x == 5)
            entry.labels[1] = "changed by a page"
        else assert(entry.point.x == 90 and entry.point.z == 1 and entry.name == "shelf") end
    end
    assert(f.world:storageAccepts(food), "The returned list is a copy")
    local bins = f.world:knownBins()
    assert(f.world:binDistance() == 6 and #bins == 1 and bins[1].capacity == 20 and bins[1].point.x == 6 and bins[1].away == 6)
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

print("PASS " .. passed .. " job engine scenarios")
