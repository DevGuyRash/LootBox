package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local Carry = require "LootBox/Carry"
local passed, failures, prototypes = 0, {}, {}

local function equal(actual, expected, message)
    if actual ~= expected then error((message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2) end
end

local function list(values)
    return {size = function() return #values end, get = function(_, index) return values[index + 1] end}
end

local function square(x, y, z)
    return {getX = function() return x end, getY = function() return y end, getZ = function() return z or 0 end}
end

local function inventory(location)
    local value = {items = {}, point = location or square(0, 0), capacity = 50}
    function value:getItems() return list(self.items) end
    function value:isRemoveItemAllowed() return not self.refuseRemoval end
    function value:getEffectiveCapacity() return self.capacity end
    function value:getCapacityWeight()
        local result = 0
        for _, item in ipairs(self.items) do result = result + item:getUnequippedWeight() end
        return result
    end
    return value
end

local function item(id, source, mass)
    local value = {id = id, source = source, mass = mass or 1}
    function value:getID() return self.id end
    function value:getFullType() return self.fullType or "Base.Item" end
    function value:getContainer() return self.source end
    function value:getUnequippedWeight() return self.mass end
    function value:IsInventoryContainer() return self.inventory ~= nil end
    function value:getInventory() return self.inventory end
    function value:canBeEquipped() return self.slot end
    function value:getBodyLocation() return self.slot end
    function value:getAttachedSlot() return self.attached or -1 end
    function value:isBroken() return self.broken == true end
    function value:isFavorite() return self.favorite == true end
    function value:isForceDropHeavyItem() return self.forceDrop == true end
    function value:isRequiresEquippedBothHands() return self.twoHands == true end
    function value:hasTag(tag) return self.tags and self.tags[tag] == true or false end
    if source then source.items[#source.items + 1] = value end
    return value
end

local function bag(id, source, slot, capacity, reduction, fullType)
    local value = item(id, source)
    value.fullType, value.slot = fullType or "Base.Bag", slot or "base:Back"
    value.inventory = inventory()
    value.inventory.bag, value.inventory.capacity = value, capacity or 20
    value.reduction, value.extras = reduction or 80, {}
    function value:getWeightReduction() return self.reduction end
    function value:getContentsWeight() return self.inventory:getCapacityWeight() end
    function value:getClothingItemExtra() return list(self.extras) end
    function value:getModule() return "Base" end
    return value
end

local function fixture()
    local actor = {inventory = inventory(), point = square(0, 0), worn = {}}
    local group = {locations = {"base:Back", "custom:LowerBack"}, exclusive = {}, multi = {}}
    function group:size() return #self.locations end
    function group:getLocationByIndex(index) return {getId = function() return self.locations[index + 1] end} end
    function group:isExclusive(left, right) return self.exclusive[left .. ":" .. right] == true end
    function group:isMultiItem(slot) return self.multi[slot] == true end
    function actor:getInventory() return self.inventory end
    function actor:getCurrentSquare() return self.point end
    function actor:getPrimaryHandItem() return self.primary end
    function actor:getSecondaryHandItem() return self.secondary end
    function actor:getWornItems()
        local result = list(self.worn)
        function result:contains(wanted)
            for _, entry in ipairs(actor.worn) do if entry.item == wanted then return true end end
            return false
        end
        function result:getBodyLocationGroup() return group end
        return result
    end
    function actor:getClothingItem_Back()
        for _, entry in ipairs(self.worn) do if entry.slot == "base:Back" then return entry.item end end
    end
    function actor:isEquipped(wanted)
        return self.primary == wanted or self.secondary == wanted or self:getWornItems():contains(wanted)
    end
    function actor:wear(selected, slot)
        local entry = {item = selected, slot = slot or selected.slot}
        function entry:getItem() return self.item end
        function entry:getLocation() return self.slot end
        self.worn[#self.worn + 1] = entry
    end
    local world = {state = {keep = {}}}
    function world:owns(container)
        while container and container ~= actor.inventory do container = container.bag and container.bag:getContainer() end
        return container == actor.inventory
    end
    function world:valid(container) return container and container.valid ~= false end
    function world:itemId(selected) return tostring(selected:getID()) end
    function world:square(container) return container.point end
    local function records(...)
        local result = {}
        for _, selected in ipairs({...}) do result[#result + 1] = {item = selected, source = selected:getContainer()} end
        return result
    end
    return actor, world, records, group
end

ISInventoryPaneContextMenu = {getItemInstance = function(fullType) return prototypes[fullType] end}
ItemTag = {REPLACE_PRIMARY = "ReplacePrimary"}

local function case(name, run)
    prototypes = {}
    local ok, reason = pcall(run)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failures[#failures + 1] = name .. ": " .. tostring(reason); print("FAIL " .. failures[#failures]) end
end

case("A free worn bag location is prepared before either free hand", function()
    local actor, world, records = fixture()
    local selected = bag(1, actor.inventory)
    local op = Carry.new(actor, world):next(records(selected), 15, 0)
    equal(op.item, selected)
    equal(op.mode, "wear")
    equal(op.slot, "base:Back")
end)

case("A full personal bag still gets equipped when its existing contents reduce carried mass", function()
    local actor, world, records = fixture()
    local selected = bag(2, actor.inventory, "base:Back", 20)
    item(3, selected.inventory, 20)
    local op = Carry.new(actor, world):next(records(selected), 1)
    equal(op.item, selected)
    equal(op.mode, "wear")
    equal(selected.inventory:getCapacityWeight(), 20)
end)

case("A declared custom lower location works alongside an occupied back", function()
    local actor, world, records = fixture()
    local existing = bag(4, actor.inventory)
    actor:wear(existing)
    local selected = bag(5, actor.inventory)
    selected.extras = {"Bag_CustomLower"}
    prototypes["Base.Bag_CustomLower"] = bag(-1, nil, "custom:LowerBack", 20, 70, "Base.Bag_CustomLower")
    local op = Carry.new(actor, world):next(records(existing, selected), 40)
    equal(op.item, selected)
    equal(op.mode, "wear")
    equal(op.variant, "Base.Bag_CustomLower")
    equal(op.slot, "custom:LowerBack")
    equal(actor:getClothingItem_Back(), existing)
end)

case("A smaller native variant cannot shrink a bag below the weight of its contents", function()
    local actor, world, records = fixture()
    local existing = bag(6, actor.inventory)
    actor:wear(existing)
    local selected = bag(7, actor.inventory)
    item(8, selected.inventory, 12)
    selected.extras = {"Bag_TinyLower"}
    prototypes["Base.Bag_TinyLower"] = bag(-1, nil, "custom:LowerBack", 10, 90, "Base.Bag_TinyLower")
    local op = Carry.new(actor, world):next(records(existing, selected), 40)
    equal(op.item, selected)
    equal(op.variant, nil)
    equal(op.mode, "secondary")
end)

case("Free primary remains usable while a one-handed secondary item is retained", function()
    local actor, world, records = fixture()
    local existing = bag(9, actor.inventory)
    actor:wear(existing)
    actor.secondary = item(10, actor.inventory)
    local selected = bag(11, actor.inventory)
    local op = Carry.new(actor, world):next(records(existing, selected), 40)
    equal(op.item, selected)
    equal(op.mode, "primary")
    equal(actor.secondary:getID(), 10)
end)

case("Existing occupied hands are not displaced to prepare another bag", function()
    local actor, world, records = fixture()
    local existing = bag(12, actor.inventory)
    actor:wear(existing)
    actor.primary, actor.secondary = item(13, actor.inventory), item(14, actor.inventory)
    local selected = bag(15, actor.inventory)
    equal(Carry.new(actor, world):next(records(existing, selected), 40), nil)
    equal(actor.primary:getID(), 13)
    equal(actor.secondary:getID(), 14)
end)

case("A free hand is not used when native equip would drop the other held heavy item", function()
    local actor, world, records = fixture()
    local existing = bag(16, actor.inventory)
    actor:wear(existing)
    actor.primary = item(17, actor.inventory)
    actor.primary.forceDrop = true
    equal(Carry.new(actor, world):next(records(existing, bag(18, actor.inventory)), 40), nil)
end)

case("A short load uses existing worn capacity instead of preparing another hand bag", function()
    local actor, world, records = fixture()
    local existing = bag(19, actor.inventory, "base:Back", 20)
    actor:wear(existing)
    local spare = bag(20, actor.inventory)
    equal(Carry.new(actor, world):next(records(existing, spare), 2), nil)
    equal(actor.primary, nil)
    equal(actor.secondary, nil)
end)

case("A held bag can move to a free worn location to free its hand", function()
    local actor, world, records = fixture()
    local selected = bag(21, actor.inventory)
    actor.secondary = selected
    local op = Carry.new(actor, world):next(records(selected), 30)
    equal(op.item, selected)
    equal(op.mode, "wear")
end)

case("Keep and favorite found bags are retained at their source", function()
    local actor, world, records = fixture()
    local source = inventory()
    local selected = bag(22, source)
    selected.favorite = true
    equal(Carry.new(actor, world):next(records(selected), 30), nil)
    selected.favorite, world.state.keep["22"] = false, true
    equal(Carry.new(actor, world):next(records(selected), 30), nil)
    equal(selected:getContainer(), source)
end)

case("A native removal refusal excludes a found bag", function()
    local actor, world, records = fixture()
    local source = inventory()
    source.refuseRemoval = true
    equal(Carry.new(actor, world):next(records(bag(23, source)), 30), nil)
end)

case("A tiny job does not detour to a distant bag", function()
    local actor, world, records = fixture()
    local distant = inventory(square(100, 100))
    equal(Carry.new(actor, world):next(records(bag(24, distant)), 1), nil)
end)

case("Zero remaining work does not prepare a full personal bag", function()
    local actor, world, records = fixture()
    local selected = bag(25, actor.inventory)
    item(26, selected.inventory, 20)
    equal(Carry.new(actor, world):next(records(selected), 0), nil)
end)

case("Native exclusive locations protect the existing worn bag", function()
    local actor, world, records, group = fixture()
    local existing = bag(27, actor.inventory, "custom:LowerBack")
    actor:wear(existing)
    group.exclusive["base:Back:custom:LowerBack"] = true
    local op = Carry.new(actor, world):next(records(existing, bag(28, actor.inventory)), 40)
    equal(op.mode, "secondary")
    equal(op.variant, nil)
    equal(actor.worn[1].item, existing)
end)

case("Native multi-item locations allow another bag without evicting the first", function()
    local actor, world, records, group = fixture()
    local existing, selected = bag(29, actor.inventory), bag(30, actor.inventory)
    actor:wear(existing)
    group.multi["base:Back"] = true
    local op = Carry.new(actor, world):next(records(existing, selected), 40)
    equal(op.item, selected)
    equal(op.mode, "wear")
    equal(actor.worn[1].item, existing)
end)

case("A capacity-blocked bag retries once after capacity changes and never spins in one revision", function()
    local actor, world, records = fixture()
    local selected = bag(31, inventory())
    local setup, source = Carry.new(actor, world), records(selected)
    local first = setup:next(source, 30, 4)
    assert(first)
    setup:complete(first, false, "capacity", 4)
    equal(setup:next(source, 30, 4), nil)
    local second = setup:next(source, 30, 5)
    assert(second)
    setup:complete(second, false, "capacity", 5)
    equal(setup:next(source, 30, 5), nil)
end)

case("A generic bag failure is not retried just because carrying capacity changed", function()
    local actor, world, records = fixture()
    local selected = bag(32, actor.inventory)
    local setup, source = Carry.new(actor, world), records(selected)
    setup:complete(assert(setup:next(source, 30, 1)), false, nil, 1)
    equal(setup:next(source, 30, 2), nil)
end)

case("Only an observed successful replacement supplies an identity migration", function()
    local actor, world = fixture()
    local original, replacement = bag(33, actor.inventory), bag(34, actor.inventory)
    local setup = Carry.new(actor, world)
    equal(setup:complete({item = original, resultItem = replacement}, false), nil)
    local mapping = setup:complete({item = original, resultItem = replacement}, true)
    equal(mapping.oldId, "33")
    equal(mapping.oldType, "Base.Bag")
    equal(mapping.newItem, replacement)
end)

print(tostring(passed) .. " carrying bag setup cases passed")
assert(#failures == 0, table.concat(failures, "\n"))
