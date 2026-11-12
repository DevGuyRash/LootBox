if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end

local active, tests = nil, 0
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end
local Store = {}
function Store.load(path) return copy(active.documents[path]), active.loadError end
function Store.save(path, value)
    if active.failSave then return nil, "Disk is unavailable" end
    active.documents[path] = copy(value)
    active.writes[#active.writes + 1] = {path = path, value = copy(value), moves = #active.moves}
    return true
end
local originalRequire = require
require = function(name)
    if name == "LootBox/Store" then return Store end
    return originalRequire(name)
end
local Recovery = require "LootBox/Recovery"
require = originalRequire

local function list(values)
    return {size = function() return #values end, get = function(_, index) return values[index + 1] end}
end
local function remove(values, item)
    for index, value in ipairs(values) do if value == item then table.remove(values, index); return true end end
end
local function fixture()
    local f = {documents = {}, writes = {}, moves = {}, nextId = 0, maximum = 50, worn = {}, candidates = {}, locations = {}}
    local function container(name, capacity, kind)
        local value = {name = name, capacity = capacity or 100, kind = kind or "crate", items = {}}
        function value:getItems() return list(self.items) end
        function value:getItemWithID(id) for _, item in ipairs(self.items) do if item.id == id then return item end end end
        function value:contains(item) for _, value in ipairs(self.items) do if value == item then return true end end; return false end
        function value:getContainingItem() return self.bag end
        function value:getEffectiveCapacity() return self.capacity end
        function value:getCapacityWeight()
            if self == f.inventory then return f.world:carrying() end
            local weight = 0
            for _, item in ipairs(self.items) do weight = weight + item.raw end
            return weight
        end
        function value:isItemAllowed(item) return not self.refusedType or item.fullType ~= self.refusedType end
        function value:hasRoomFor(_, item) return self:getCapacityWeight() + item.raw <= self.capacity end
        function value:isInside(item)
            local source = item:getContainer()
            while source do if source == self then return true end; source = source.bag and source.bag:getContainer() end
            return false
        end
        function value:getType() return self.kind end
        return value
    end
    f.container = container
    f.inventory, f.safe, f.source, f.trash = container("inventory", 50, "inventory"), container("safe cupboard", 100), container("heavy source", 100), container("trash", 100)
    f.safe.point, f.source.point, f.trash.point = {x = 10, y = 20, z = 0}, {x = 11, y = 20, z = 0}, {x = 12, y = 20, z = 0}
    f.safe.index, f.source.index, f.trash.index, f.trash.trash = 0, 1, 2, true
    f.candidates = {f.safe}
    for _, value in ipairs({f.safe, f.source, f.trash}) do f.locations[value.point.x] = value end
    local player = {}
    function player:getInventory() return f.inventory end
    function player:getPrimaryHandItem() return f.primary end
    function player:getSecondaryHandItem() return f.secondary end
    function player:isEquipped(item)
        if item == f.primary or item == f.secondary then return true end
        for _, entry in ipairs(f.worn) do if entry.item == item then return true end end
        return false
    end
    function player:getWornItems()
        local entries = {}
        for _, entry in ipairs(f.worn) do
            entries[#entries + 1] = {getItem = function() return entry.item end, getLocation = function() return entry.slot end}
        end
        return list(entries)
    end
    f.player = player
    local world = {}
    function world:carrying()
        local total = 0
        for _, item in ipairs(f.inventory.items) do total = total + (player:isEquipped(item) and item.equippedWeight or item.raw) end
        return total, f.maximum
    end
    function world:owns(value)
        local seen = {}
        while value and not seen[value] do
            if value == f.inventory then return true end
            seen[value] = true; value = value.bag and value.bag:getContainer()
        end
        return false
    end
    function world:key(value) return value and value.name end
    function world:name(value) return value.name end
    function world:valid(value) return value and not value.removed end
    function world:canAccess(value) return self:valid(value) and not value.denied end
    function world:isTrash(value) return value.trash == true end
    function world:safeStagingContainers() return f.candidates end
    function world:sourceAnchor(value)
        if not value.point then return {kind = "carried"} end
        return {kind = value.anchorKind or "world", point = copy(value.point), index = value.index, slot = 0,
            sprite = "fixture_cupboard", containerType = value.kind}
    end
    function world:resolveSource(anchor)
        local value = anchor.point and f.locations[anchor.point.x]
        if value and not value.removed and value.index == anchor.index then return value end
        return nil, "The staging container is unavailable"
    end
    function world:records(container)
        local result, seen = {}, {}
        local function collect(current)
            if seen[current] then return end
            seen[current] = true
            for _, item in ipairs(current.items) do
                result[#result + 1] = {item = item, source = current}
                if item.bag then collect(item.bag) end
            end
        end
        collect(container)
        return result
    end
    f.world = world
    function f:item(source, raw, options)
        options = options or {}
        self.nextId = self.nextId + 1
        local value = {id = self.nextId, fullType = options.fullType or "Base.Personal" .. self.nextId,
            raw = raw, equippedWeight = options.equippedWeight or raw, source = source, attached = options.attached or -1, forceDrop = options.forceDrop}
        function value:getID() return self.id end
        function value:getFullType() return self.fullType end
        function value:getName() return self.fullType end
        function value:getContainer() return self.source end
        function value:getUnequippedWeight() return self.raw end
        function value:getEquippedWeight() return self.equippedWeight end
        function value:getInventory() return self.bag end
        function value:getAttachedSlot() return self.attached end
        function value:isHumanCorpse() return false end
        function value:isForceDropHeavyItem() return self.forceDrop == true end
        source.items[#source.items + 1] = value
        if options.bag then value.bag = container("bag:" .. value.id, options.capacity or 50); value.bag.bag = value end
        if options.slot then self.worn[#self.worn + 1] = {slot = options.slot, item = value} end
        if options.primary then self.primary = value end
        if options.secondary then self.secondary = value end
        return value
    end
    function f:apply(op)
        assert(self.recovery:allows(op))
        local persisted = self.documents["fixture/recovery"]
        assert(persisted and persisted.pending and persisted.intent, "Every native mutation requires a durable intent")
        if op.kind == "transfer" then
            assert(op.source:contains(op.item) and op.destination:hasRoomFor(self.player, op.item), "Native admission must accept every recovery transfer")
            assert(remove(op.source.items, op.item))
            op.destination.items[#op.destination.items + 1], op.item.source = op.item, op.destination
        elseif op.mode == "unequip" then
            for index = #self.worn, 1, -1 do if self.worn[index].item == op.item then table.remove(self.worn, index) end end
            if self.primary == op.item then self.primary = nil end
            if self.secondary == op.item then self.secondary = nil end
        elseif op.mode == "wear" then self.worn[#self.worn + 1] = {slot = op.slot, item = op.item}
        elseif op.mode == "primary" then self.primary = op.item; if op.twoHands then self.secondary = op.item end
        elseif op.mode == "secondary" then self.secondary = op.item
        else error("Unknown native gear operation") end
        self.moves[#self.moves + 1] = op
        assert(self.recovery:settle(op, true))
    end
    function f:run(mode)
        for _ = 1, 100 do
            local op, reason, done = self.recovery:next(mode)
            if op then self:apply(op)
            else return done == true, reason end
        end
        error("Personal recovery did not converge")
    end
    active = f
    f.recovery = Recovery.new(player, world, "fixture")
    return f
end
local function test(name, body)
    print("RUN " .. name); body(); tests = tests + 1; print("PASS " .. name)
end
local function wholeBagFixture()
    local f = fixture()
    f:item(f.inventory, 25, {slot = "Torso"})
    local bag = f:item(f.inventory, 20, {bag = true, equippedWeight = 5, slot = "Back"})
    local nested = f:item(bag.bag, 4, {bag = true})
    local child = f:item(nested.bag, 2)
    local heavy = f:item(f.source, 25, {fullType = "Base.Heavy"})
    return f, bag, nested, child, heavy
end

test("whole bags and nested contents are reserved before the first mutation", function()
    local f, bag, nested, child, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    assert(#f.moves == 0 and #f.writes == 1 and f.writes[1].moves == 0)
    assert(f.recovery:isProtected(bag) and f.recovery:isProtected(nested) and f.recovery:isProtected(child))
    assert(f.recovery:isReservedContainer(f.safe) and not f.recovery:isReservedContainer(f.trash))
    assert(f:run("stage"))
    assert(bag:getContainer() == f.safe and nested:getContainer() == bag.bag and child:getContainer() == nested.bag)
    assert(#f.moves == 2 and f.moves[1].kind == "gear" and f.moves[2].kind == "transfer")
end)

test("whole bags return with their nested hierarchy and original worn slot", function()
    local f, bag, nested, child, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy) and f:run("stage"))
    assert(f.world:carrying() == 25)
    assert(f:run("restore"))
    assert(bag:getContainer() == f.inventory and f.player:isEquipped(bag))
    assert(nested:getContainer() == bag.bag and child:getContainer() == nested.bag and f.world:carrying() == 30)
    assert(not f.recovery:status().pending and not f.recovery:isProtected(child) and not f.recovery:isReservedContainer(f.safe))
    assert(f.documents["fixture/recovery"].pending == false)
end)

test("failed receipt persistence never authorizes or moves personal gear", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    f.failSave = true
    assert(not f.recovery:prepare(heavy))
    assert(#f.moves == 0 and #f.writes == 0 and bag:getContainer() == f.inventory and f.player:isEquipped(bag))
    assert(not f.recovery:allows({kind = "transfer", item = bag, source = f.inventory, destination = f.safe, personalRecovery = true}))
end)

test("only an exact persisted intent may bypass normal item protections", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    assert(not f.recovery:allows({kind = "transfer", item = bag, source = f.inventory, destination = f.safe, personalRecovery = true}))
    local op = assert(f.recovery:next("stage"))
    assert(f.recovery:allows(op))
    local forged = {}
    for key, value in pairs(op) do forged[key] = value end
    forged.mode = "primary"
    assert(not f.recovery:allows(forged))
    forged.mode, forged.personalRecovery = op.mode, false
    assert(not f.recovery:allows(forged) and #f.moves == 0)
end)

test("trash and the heavy source ancestry cannot become a staging endpoint", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    for _, candidates in ipairs({{f.trash}, {f.source}, {f.inventory}}) do
        assert(not f.recovery:prepare(heavy, candidates))
        assert(#f.writes == 0 and #f.moves == 0 and f.inventory:contains(bag))
    end
end)

test("a full or denied ordinary container is rejected before staging", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    f.safe.capacity = 19
    assert(not f.recovery:prepare(heavy) and #f.writes == 0)
    f.safe.capacity, f.safe.denied = 100, true
    assert(not f.recovery:prepare(heavy) and #f.moves == 0 and f.inventory:contains(bag))
end)

test("changing endpoint permissions blocks the next mutation with the receipt retained", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    local op = assert(f.recovery:next("stage"))
    f.safe.denied = true
    assert(not f.recovery:allows(op) and f.recovery:status().pending and #f.moves == 0 and f.inventory:contains(bag))
end)

test("reconnect resumes from observed locations after an unacknowledged transfer", function()
    local f, bag, _, child, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    f:apply(assert(f.recovery:next("stage")))
    local op = assert(f.recovery:next("stage"))
    assert(f.recovery:allows(op))
    assert(remove(f.inventory.items, bag)); f.safe.items[#f.safe.items + 1], bag.source = bag, f.safe
    f.recovery = Recovery.new(f.player, f.world, "fixture")
    assert(f.recovery:status().pending and f.recovery:isProtected(child))
    assert(f:run("restore") and bag:getContainer() == f.inventory and f.player:isEquipped(bag))
    assert(#f.moves == 3 and not f.recovery:status().pending)
end)

test("missing nested contents keep recovery pending instead of certifying restoration", function()
    local f, bag, nested, child, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy) and f:run("stage"))
    assert(remove(nested.bag.items, child)); child.source = f.source; f.source.items[#f.source.items + 1] = child
    local op, reason, done = f.recovery:next("restore")
    assert(not op and not done and reason:find("contents changed", 1, true))
    assert(f.recovery:status().pending and f.safe:contains(bag) and f.recovery:isProtected(child))
end)

test("a changed original worn slot is left under the user's control", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy) and f:run("stage"))
    local replacement = f:item(f.inventory, 1, {slot = "Back"})
    local transferred = assert(f.recovery:next("restore")); f:apply(transferred)
    local op, reason, done = f.recovery:next("restore")
    assert(not op and not done and reason:find("occupied", 1, true))
    assert(f.player:isEquipped(replacement) and not f.player:isEquipped(bag) and f.recovery:status().pending)
end)

test("an untouched planned item is not restored over later user handling", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    assert(remove(f.inventory.items, bag)); f.source.items[#f.source.items + 1], bag.source = bag, f.source
    assert(f:run("restore") and bag:getContainer() == f.source and #f.moves == 0)
end)

test("false native success cannot retire an unobserved personal transfer", function()
    local f = fixture()
    local personal = f:item(f.inventory, 30)
    local heavy = f:item(f.source, 30)
    assert(f.recovery:prepare(heavy))
    local op = assert(f.recovery:next("stage"))
    assert(not f.recovery:settle(op, true))
    assert(f.inventory:contains(personal) and f.recovery:status().pending and #f.moves == 0)
end)

test("two-hand equipment returns to both original hands in one native operation", function()
    local f = fixture()
    local personal = f:item(f.inventory, 20, {primary = true, secondary = true})
    local heavy = f:item(f.source, 40)
    assert(f.recovery:prepare(heavy) and f:run("stage") and f:run("restore"))
    assert(f.primary == personal and f.secondary == personal and not f.recovery:status().pending)
    local equips = 0
    for _, op in ipairs(f.moves) do if op.kind == "gear" and op.mode == "primary" then assert(op.twoHands); equips = equips + 1 end end
    assert(equips == 1)
end)

test("recovery restores reduced-weight bags before loose items to preserve hard headroom", function()
    local f = fixture()
    local loose = f:item(f.inventory, 19)
    local bag = f:item(f.inventory, 40, {bag = true, equippedWeight = 30, slot = "Back"})
    local heavy = f:item(f.source, 40)
    assert(f.world:carrying() == 49 and f.recovery:prepare(heavy) and f:run("stage"))
    local op = assert(f.recovery:next("restore"))
    assert(op.item == bag and op.kind == "transfer", "Raw40 bag must return before loose19 at hard50")
    f:apply(op)
    assert(f:run("restore") and f.world:carrying() == 49 and f.inventory:contains(loose))
end)

test("staging reserves extra loose roots when raw bag retrieval needs more headroom", function()
    local f = fixture()
    local bag = f:item(f.inventory, 45, {bag = true, equippedWeight = 35, slot = "Back"})
    local loose8, loose6 = f:item(f.inventory, 8), f:item(f.inventory, 6)
    local heavy = f:item(f.source, 40)
    assert(f.world:carrying() == 49 and f.recovery:prepare(heavy))
    assert(f.recovery:status().count == 3 and f:run("stage"))
    assert(f:run("restore") and f.world:carrying() == 49)
    assert(f.inventory:contains(bag) and f.inventory:contains(loose8) and f.inventory:contains(loose6))
end)

test("impossible raw readmission rejects staging before any receipt or movement", function()
    local f = fixture()
    local bag = f:item(f.inventory, 55, {bag = true, equippedWeight = 35, slot = "Back"})
    f:item(f.inventory, 14)
    local heavy = f:item(f.source, 40)
    assert(not f.recovery:prepare(heavy) and #f.writes == 0 and #f.moves == 0 and f.player:isEquipped(bag))
end)

test("normal comfort encumbrance alone does not trigger personal gear staging", function()
    local f = fixture()
    local personal = f:item(f.inventory, 20)
    local heavy = f:item(f.source, 15)
    assert(not f.recovery:prepare(heavy) and #f.writes == 0 and f.inventory:contains(personal))
end)

test("a missing or replaced staging container retains its durable recovery location", function()
    local f, _, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy) and f:run("stage"))
    f.safe.removed = true
    local op, reason = f.recovery:next("restore")
    assert(not op and reason and f.recovery:status().pending and f.recovery:status().point.x == 10)
    local reloaded = Recovery.new(f.player, f.world, "fixture")
    assert(reloaded:status().pending and reloaded:status().point.x == 10)
end)

test("a failed intent write leaves the whole item in place and can be retried", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    f.failSave = true
    local op, reason = f.recovery:next("stage")
    assert(not op and reason and #f.moves == 0 and f.player:isEquipped(bag) and f.inventory:contains(bag))
    f.failSave = false
    assert(f:run("restore") and not f.recovery:status().pending and #f.moves == 0)
end)

test("a heavy item inside a bag excludes that bag's ordinary source ancestor", function()
    local f, bag, _, _, heavy = wholeBagFixture()
    local sourceBag = f:item(f.safe, 1, {bag = true})
    assert(remove(f.source.items, heavy)); sourceBag.bag.items[#sourceBag.bag.items + 1], heavy.source = heavy, sourceBag.bag
    assert(not f.recovery:prepare(heavy, {f.safe}) and #f.writes == 0 and #f.moves == 0 and f.inventory:contains(bag))
end)

test("reservation accounts for the sum of whole roots in the staging container", function()
    local f = fixture()
    f:item(f.inventory, 19)
    f:item(f.inventory, 40, {bag = true, equippedWeight = 30, slot = "Back"})
    f.safe.capacity = 50
    local heavy = f:item(f.source, 40)
    assert(not f.recovery:prepare(heavy) and #f.writes == 0 and #f.moves == 0)
end)

test("attached and force-drop-heavy possessions are retained instead of staged", function()
    local f = fixture()
    local attached = f:item(f.inventory, 30, {attached = 1})
    local held = f:item(f.inventory, 10, {forceDrop = true, primary = true})
    local heavy = f:item(f.source, 20)
    assert(not f.recovery:prepare(heavy) and #f.writes == 0 and f.inventory:contains(attached) and f.primary == held)
end)

test("malformed persisted identities block new staging without authorizing movement", function()
    local f, _, _, _, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    f.documents["fixture/recovery"].entries[1].id = "not a native ID"
    local loaded = Recovery.new(f.player, f.world, "fixture")
    assert(loaded:status().pending and loaded:status().reason and not loaded:prepare(heavy))
    assert(not loaded:next("stage") and #f.moves == 0)
end)

test("a native replacement follows the exact old identity while preserving descendant reservations", function()
    local f, old, nested, child, heavy = wholeBagFixture()
    assert(f.recovery:prepare(heavy))
    local replacement = f:item(f.inventory, 20, {bag = true, equippedWeight = 5, fullType = "Base.ReplacementBag"})
    assert(not f.recovery:isProtected(replacement))
    assert(f.recovery:replaceIdentity(old:getID(), "Base.WrongType", replacement))
    assert(not f.recovery:isProtected(replacement) and f.recovery:isProtected(old))
    assert(remove(old.bag.items, nested)); replacement.bag.items[#replacement.bag.items + 1], nested.source = nested, replacement.bag
    assert(remove(f.inventory.items, old)); old.source = nil
    for _, entry in ipairs(f.worn) do if entry.item == old then entry.item = replacement end end
    assert(f.recovery:replaceIdentity(old:getID(), old:getFullType(), replacement))
    assert(f.recovery:isProtected(replacement) and f.recovery:isProtected(child))
    assert(f:run("stage") and f:run("restore") and f.player:isEquipped(replacement) and child:getContainer() == nested.bag)
end)

print("PASS " .. tests .. " Recovery integration scenarios")
