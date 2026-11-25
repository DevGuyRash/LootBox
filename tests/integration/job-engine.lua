-- Real Jobs, World, Categories, Carry and Routing. Only the game boundary is doubled:
-- squares, containers, items and a native adapter that performs each step at once.
if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end

local active
local Native = {}
function Native.new(player) return setmetatable({player = player}, {__index = Native}) end
function Native:isBusy() return self.op ~= nil end
function Native:isPlayerBusy() return false end
function Native:takeoverReason() end
function Native:extend() end
function Native:reachable(container) return active.near(active.world:square(container)) end
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
    local f = {now = 0, ops = {}, visits = {}, squares = {}, nextId = 0, reads = {}, blocked = {}, deleted = {}, emptied = {}}
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
            assert((op.source == f.floor or f.near(f.world:square(op.source))) and f.near(f.world:square(op.destination)), "A transfer out of reach")
            if f.refuse and f.refuse(op) then return false, "The game stopped the native action before completing it" end
            if op.source == f.floor then
                remove(op.item.placed.where.ground, op.item.placed)
                op.item.placed = nil
                refreshFloor()
            else assert(remove(op.source.items, op.item), "The item left its source") end
            assert(op.destination:hasRoomFor(f.player, op.item), "A transfer exceeded the destination")
            op.destination.items[#op.destination.items + 1], op.item.container = op.item, op.destination
            op.resultItem = op.item
            if f.onTransfer then f.onTransfer(op) end
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
    assert(crate:contains(bag) and kept.container == bag.inside and status.state == "finished_with_skips")
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

case("a can that refuses another item by count is emptied and tried once more", function(f)
    local crate, can = f.crate(f.square(5, 0), "crate"), f.can(f.square(20, 0), 100)
    for _ = 1, 7 do f.item(crate) end
    f.refuse = function(op) return op.destination == can and #can.items >= 3 end
    local status = f.run(clean(f, crate))
    assert(status.state == "finished" and status.done == 7 and #f.emptied == 3, status.reason)
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
    local found = f.item(other, "Base.Duffel", {bag = true})
    assert(f.jobs:start(assert(f.jobs:preview(f.request({kind = "container", ref = target}, {scope = "container", sourceContainer = other})))))
    f.jobs.carry.next = function(_, records) for _, record in ipairs(records) do offered[record.item] = true end end
    f.finish()
    assert(offered[found], "Found bags still help to carry loot")
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
    assert(not f.world:binDistance() and not f.world:hasStorageLabels() and #f.world:knownBins() == 0 and #f.world:labelledContainers() == 0)
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
    assert(f.world:binDistance() == 6 and #bins == 1 and bins[1].capacity == 20 and bins[1].point.x == 6 and bins[1].away == 6)
    local vehicle = {getKeyId = function() return 7 end, getScriptName = function() return "Base.Car" end,
        getSquare = function() return f.at end}
    assert(not f.world:isRememberedVehicle(vehicle) and not f.world:rememberedVehicleLoaded())
    f.state.vehicle = {id = 3, keyId = 7, script = "Base.Car", x = 0, y = 0, z = 0}
    assert(f.world:isRememberedVehicle(vehicle) and not f.world:rememberedVehicleLoaded())
    getVehicleById = function(id) return id == 3 and vehicle or nil end
    assert(f.world:rememberedVehicleLoaded())
end)

case("emptied and unusable labels leave no trace", function(f)
    local world = World.new(f.player, {containerLabels = {["bag:1"] = {}, ["bag:2"] = {"native:Food", "custom:gone"}, ["bag:3"] = {"custom:gone"}},
        itemLabels = {["4"] = {"custom:gone"}, ["5"] = {}}})
    assert(world.state.containerLabels["bag:1"] == nil and world.state.itemLabels["5"] == nil)
    assert(world:pruneLabels(function(id) return id ~= "custom:gone" end) == 3)
    assert(#world.state.containerLabels["bag:2"] == 1 and world.state.containerLabels["bag:3"] == nil and world.state.itemLabels["4"] == nil)
end)

print("PASS " .. passed .. " job engine scenarios")
