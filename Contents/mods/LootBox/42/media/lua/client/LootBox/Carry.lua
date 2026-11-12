local Carry = {}
Carry.__index = Carry

local function call(value, name, ...)
    if not value then return nil end
    local args = {...}
    local ok, result = pcall(function()
        local method = value[name]
        return method and method(value, unpack(args))
    end)
    if ok then return result end
end

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
    return ok and item or nil
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

function Carry:next(records, incomingWeight, revision)
    if incomingWeight ~= nil and incomingWeight <= 0 then return nil end
    revision = revision or 0
    local player, world = self.player, self.world
    local remaining, equippedFree = math.max(0, incomingWeight or 0), 0
    local candidates, seen = {}, {}
    for _, record in ipairs(records or {}) do
        local item = record.item
        if item and not seen[item] then
            seen[item] = true
            if bag(item) then
                candidates[#candidates + 1] = item
                if call(player, "isEquipped", item) then
                    local container = call(item, "getInventory")
                    equippedFree = equippedFree + math.max(0, (call(container, "getEffectiveCapacity", player) or 0)
                        - (call(container, "getCapacityWeight") or 0))
                end
            elseif incomingWeight == nil and not world:owns(call(item, "getContainer")) then
                remaining = remaining + math.max(0, call(item, "getUnequippedWeight") or 0)
            end
        end
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
                local reduction = math.max(0, math.min(1, (call(target, "getWeightReduction") or 0) / 100))
                local replacePrimary = ItemTag and ItemTag.REPLACE_PRIMARY and call(target, "hasTag", ItemTag.REPLACE_PRIMARY)
                local benefit = reduction * (math.min(remaining, free) + (own and contents or 0))
                local cost = (own and 0.15 or 0.5) + distance / 8
                if contents <= capacity and (free > 0 or own and contents > 0) and reduction > 0 and not replacePrimary and benefit > cost then
                    local slot = Carry.wornSlot(target)
                    local available = slot and Carry.slotAvailable(player, slot, item)
                    if available then
                        local score = benefit - cost + 1000
                        if not bestScore or score > bestScore then
                            best = {kind = "gear", item = item, source = source, mode = "wear", slot = tostring(slot),
                                variant = target ~= item and tostring(call(target, "getFullType")) or nil}
                            bestScore = score
                        end
                    elseif target == item and not call(player, "isEquipped", item) and (equippedFree < remaining or contents > 0) then
                        for _, mode in ipairs({"secondary", "primary"}) do
                            if Carry.handAvailable(player, mode, item) then
                                local score = benefit - cost
                                if not bestScore or score > bestScore then
                                    best = {kind = "gear", item = item, source = source, mode = mode}
                                    bestScore = score
                                end
                                break
                            end
                        end
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
