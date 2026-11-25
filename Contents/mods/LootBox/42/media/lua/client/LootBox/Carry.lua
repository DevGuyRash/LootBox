local Log = require "LootBox/Log"
local call = require "LootBox/Safe"
local Sort = require "LootBox/Sort"

local Carry = {}
Carry.__index = Carry

local function bag(item) return call(item, "IsInventoryContainer") == true end
local function identity(item) return tostring(call(item, "getID")) .. ":" .. tostring(call(item, "getFullType")) end
local function size(list) return call(list, "size") or 0 end

function Carry.wornSlot(item)
    local slot = bag(item) and call(item, "canBeEquipped") or call(item, "getBodyLocation")
    if slot and tostring(slot) ~= "" then return slot end
end

function Carry.slot(player, requested)
    if not requested then return nil end
    local group = call(call(player, "getWornItems"), "getBodyLocationGroup")
    for index = 0, (call(group, "size") or 0) - 1 do
        local slot = call(call(group, "getLocationByIndex", index), "getId")
        if slot and tostring(slot) == tostring(requested) then return slot end
    end
end

function Carry.slotAvailable(player, requested, item)
    local slot = Carry.slot(player, requested)
    if not slot then return false end
    local worn = call(player, "getWornItems")
    local group = call(worn, "getBodyLocationGroup")
    for index = 0, size(worn) - 1 do
        local entry = call(worn, "get", index)
        if call(entry, "getItem") ~= item then
            local location = call(entry, "getLocation")
            if (location == slot and not call(group, "isMultiItem", slot)) or call(group, "isExclusive", slot, location)
                or call(group, "isExclusive", location, slot) then return false end
        end
    end
    return true, slot
end

function Carry.wornAt(player, requested, item)
    local slot, worn = Carry.slot(player, requested), call(player, "getWornItems")
    if not slot then return nil end
    for index = 0, size(worn) - 1 do
        local entry = call(worn, "get", index)
        local current = call(entry, "getItem")
        if call(entry, "getLocation") == slot and (not item or current == item) then return current end
    end
end

function Carry.prototype(fullType)
    local menu = ISInventoryPaneContextMenu
    if not menu or not menu.getItemInstance then return nil end
    local ok, item = pcall(menu.getItemInstance, fullType)
    if ok then return item end
    Log.fault(nil, "Carry.prototype", item, "type", fullType)
end

function Carry.permittedVariant(item, fullType)
    local extras = call(item, "getClothingItemExtra")
    local module = call(item, "getModule")
    for index = 0, size(extras) - 1 do
        local value = tostring(call(extras, "get", index))
        if not value:find(".", 1, true) and module then value = tostring(module) .. "." .. value end
        if value == fullType then return true end
    end
    return false
end

function Carry.handAvailable(player, mode, item)
    local primary, secondary = call(player, "getPrimaryHandItem"), call(player, "getSecondaryHandItem")
    local selected = secondary
    if mode == "primary" then selected = primary end
    if selected and selected ~= item then return false end
    for _, held in pairs({primary = primary, secondary = secondary}) do
        if held ~= item and (call(held, "isForceDropHeavyItem")
            or call(held, "isRequiresEquippedBothHands")) then return false end
    end
    local back = call(player, "getClothingItem_Back")
    if ItemTag and ItemTag.REPLACE_PRIMARY and call(back, "hasTag", ItemTag.REPLACE_PRIMARY) then return false end
    return true
end

local function variants(item)
    local result, seen = {item}, {[tostring(call(item, "getFullType"))] = true}
    local extras, module = call(item, "getClothingItemExtra"), call(item, "getModule")
    for index = 0, math.min(size(extras), 64) - 1 do
        local fullType = tostring(call(extras, "get", index))
        if not fullType:find(".", 1, true) and module then fullType = tostring(module) .. "." .. fullType end
        if not seen[fullType] then
            seen[fullType] = true
            local prototype = Carry.prototype(fullType)
            if bag(prototype) then result[#result + 1] = prototype end
        end
    end
    return result
end

function Carry.new(player, world)
    return setmetatable({player = player, world = world, attempted = {}}, Carry)
end

local function storage(item, container, free)
    local largest, accepts = call(item, "getMaxItemSize") or 0, {}
    return {free = free, reduction = math.max(0, math.min(1, (call(item, "getWeightReduction") or 0) / 100)),
        accepts = function(load)
            if accepts[load.kind] == nil then
                accepts[load.kind] = (largest <= 0 or load.weight <= largest) and call(container, "isItemAllowed", load.item) == true
            end
            return accepts[load.kind] and load.item ~= item
        end}
end

-- The weight these bags would take off the load, the best bag filled first, and what is left over.
local function relief(bags, loads)
    local free, total, left = {}, 0, 0
    Sort(bags, function(entry) return -entry.reduction end)
    for index, entry in ipairs(bags) do free[index] = entry.free end
    for _, load in ipairs(loads) do
        local placed = false
        for index, entry in ipairs(bags) do
            if not placed and load.weight <= free[index] and entry.accepts(load) then
                free[index], total, placed = free[index] - load.weight, total + load.weight * entry.reduction, true
            end
        end
        if not placed then left = left + load.weight end
    end
    return total, left
end

-- The next bag worth preparing. records are the bags there are, work is what is still to be carried.
function Carry:next(records, work, revision)
    if #work == 0 then return nil end
    revision = revision or 0
    local player, world = self.player, self.world
    local loads, total, candidates, worn, seen = {}, 0, {}, {}, {}
    for index, item in ipairs(work) do
        local weight = math.max(0, call(item, "getUnequippedWeight") or 0)
        loads[index] = {item = item, weight = weight, kind = tostring(call(item, "getFullType")) .. ":" .. weight}
        total = total + weight
    end
    Sort(loads, function(load) return -load.weight end)
    for _, record in ipairs(records or {}) do
        local item = record.item
        if bag(item) and not seen[item] then
            seen[item] = true
            candidates[#candidates + 1] = item
            if call(player, "isEquipped", item) then
                local container = call(item, "getInventory")
                worn[item] = storage(item, container,
                    math.max(0, (call(container, "getEffectiveCapacity", player) or 0) - (call(container, "getCapacityWeight") or 0)))
            end
        end
    end
    -- What the load gains from the other worn bags, and with this one as well.
    local function gain(item, added)
        local others = {}
        for _, candidate in ipairs(candidates) do
            if worn[candidate] and candidate ~= item then others[#others + 1] = worn[candidate] end
        end
        local before, left = relief(others, loads)
        others[#others + 1] = added
        return relief(others, loads) - before, left
    end
    local best, bestScore
    for _, item in ipairs(candidates) do
        local source, id = call(item, "getContainer"), world:itemId(item)
        local own = world:owns(source)
        local keep = world.state and world.state.keep and world.state.keep[id]
        local excluded = not own and (keep or call(item, "isFavorite"))
        local attempted = self.attempted[identity(item)]
        local retry = type(attempted) == "table" and attempted.capacityRevision ~= revision
        if not excluded and (not attempted or retry) and not call(call(player, "getWornItems"), "contains", item)
            and not call(item, "isBroken") and (call(item, "getAttachedSlot") or -1) < 0
            and source and world:valid(source) and call(source, "isRemoveItemAllowed", item) ~= false then
            local contents = call(item, "getContentsWeight") or 0
            local point, origin = world:square(source), call(player, "getCurrentSquare")
            local distance = 0
            if not own and point and origin then
                distance = math.abs((call(point, "getX") or 0) - (call(origin, "getX") or 0))
                    + math.abs((call(point, "getY") or 0) - (call(origin, "getY") or 0))
                    + 6 * math.abs((call(point, "getZ") or 0) - (call(origin, "getZ") or 0))
            end
            for _, target in ipairs(variants(item)) do
                local container = call(target, "getInventory")
                local capacity = call(container, "getEffectiveCapacity", player) or 0
                local free = math.max(0, capacity - contents)
                local added = storage(target, container, free)
                local replacePrimary = ItemTag and ItemTag.REPLACE_PRIMARY and call(target, "hasTag", ItemTag.REPLACE_PRIMARY)
                local kept = own and contents * added.reduction or 0
                local cost = (own and 0.15 or 0.5) + distance / 8
                -- The most it could gain, before asking the game about every item.
                if contents <= capacity and not replacePrimary and kept + added.reduction * math.min(total, free) > cost then
                    local benefit, left = gain(item, added)
                    benefit = benefit + kept
                    local slot = Carry.wornSlot(target)
                    local available = slot and Carry.slotAvailable(player, slot, item)
                    local mode
                    if available then mode = "wear"
                    elseif target == item and not call(player, "isEquipped", item) and (left > 0 or contents > 0) then
                        mode = Carry.handAvailable(player, "secondary", item) and "secondary"
                            or Carry.handAvailable(player, "primary", item) and "primary"
                    end
                    local score = benefit - cost + (available and 1000 or 0)
                    if mode and benefit > cost and (not bestScore or score > bestScore) then
                        best = {kind = "gear", item = item, source = source, mode = mode, slot = available and tostring(slot) or nil,
                            variant = target ~= item and tostring(call(target, "getFullType")) or nil}
                        best.why = string.format("takes %.1f off a load of %.1f", benefit, total)
                        bestScore = score
                    end
                end
            end
        end
    end
    if best then best.carryRevision = revision end
    return best
end

function Carry:complete(op, ok, code, revision)
    self.attempted[identity(op.item)] = not ok and code == "capacity"
        and {capacityRevision = revision or op.carryRevision or 0} or true
    if ok and op.resultItem and op.resultItem ~= op.item then
        self.attempted[identity(op.resultItem)] = true
        return {oldId = tostring(op.item:getID()), oldType = tostring(op.item:getFullType()), newItem = op.resultItem}
    end
end

return Carry
