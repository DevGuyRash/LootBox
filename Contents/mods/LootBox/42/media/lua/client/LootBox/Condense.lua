local Log = require "LootBox/Log"
local call = require "LootBox/Safe"
local Pack = require "LootBox/Pack"

local Condense = {}
Condense.__index = Condense

local EPS = 0.0001
local MAX_ROUNDS, MAX_REFUSALS = 128, 64

local function isBag(item) return call(item, "IsInventoryContainer") == true or call(item, "getCategory") == "Container" end
local function itemKey(item) return tostring(item:getID()) .. ":" .. tostring(item:getFullType()) end
local function units(weight) return math.floor(weight / EPS + 0.5) end
local function pairKey(item, node) return item.key .. ">" .. node.key end

-- Reads what is carried now. Returns nil and why when it cannot be read.
local function capture(self)
    local world, player = self.world, self.world.player
    local main = player:getInventory()
    if not main or not world:owns(main) then return nil, "Your inventory cannot be read right now" end
    local carried, limit = world:carrying()
    local nodes, byContainer = {{key = "main", ref = main, factor = 1, room = math.huge}}, {[main] = 1}
    for _, bag in ipairs(world:bags(self.options)) do
        nodes[#nodes + 1] = {key = itemKey(bag.item), ref = bag.container, bag = bag.item, rules = bag, parent = byContainer[bag.source],
            factor = bag.factor, worn = bag.worn, held = call(bag.item, "getEquipParent") ~= nil,
            maxItem = call(bag.item, "getMaxItemSize") or 0,
            -- Rounded as the game rounds it when it checks for room.
            room = units(bag.container:getEffectiveCapacity(player) - math.floor(bag.container:getCapacityWeight() * 100 + 0.5) / 100)}
        byContainer[bag.container] = #nodes
    end
    local kinds, lots, byLot, eligible = {}, {}, {}, 0
    for node, place in ipairs(nodes) do
        local values, names = place.ref:getItems(), world:kinds(place.ref)
        for index = 0, values:size() - 1 do
            local item = values:get(index)
            local types = names(item)
            local movable = not isBag(item) and (self.options.rebalance or node == 1) and not world:protected(item)
                and call(item, "isHumanCorpse") ~= true and call(place.ref, "isRemoveItemAllowed", item) == true
            if movable then
                local weight = math.max(0, item:getUnequippedWeight())
                local entry = {key = itemKey(item), id = item:getID(), fullType = tostring(item:getFullType()), ref = item,
                    weight = weight, name = tostring(item:getName())}
                local fits, parts = {}, {units(weight), table.concat(types, ",")}
                for at, target in ipairs(nodes) do
                    if not self.blocked[pairKey(entry, target)] and call(target.ref, "isItemAllowed", item) == true
                        and (at == 1 or (target.maxItem <= 0 or weight <= target.maxItem) and world:meantFor(target.rules, item)) then
                        fits[at] = true
                        parts[#parts + 1] = at
                    end
                end
                local id = table.concat(parts, "|")
                local lot = byLot[id]
                if not lot then
                    lot = {weight = units(weight), kinds = types, fits = fits, cost = {}, start = {}, home = {}, items = {}}
                    for at, target in ipairs(nodes) do
                        -- Main inventory is the last choice among places that weigh the same.
                        lot.cost[at] = lot.weight * math.floor(target.factor * 10000 + 0.5) + (at == 1 and math.max(1, lot.weight) or 0)
                    end
                    byLot[id], lots[#lots + 1] = lot, lot
                end
                self.home[entry.key] = self.home[entry.key] or place.key
                lot.start[node] = (lot.start[node] or 0) + 1
                lot.items[node] = lot.items[node] or {}
                table.insert(lot.items[node], entry)
                eligible = eligible + 1
            else
                for _, kind in ipairs(types) do
                    kinds[kind] = kinds[kind] or {}
                    kinds[kind][node] = (kinds[kind][node] or 0) + 1
                end
            end
        end
    end
    local byKey = {}
    for node, place in ipairs(nodes) do byKey[place.key] = node end
    for _, lot in ipairs(lots) do
        for node, list in pairs(lot.items) do
            for _, entry in ipairs(list) do
                local at = byKey[self.home[entry.key]] or node
                lot.home[at] = (lot.home[at] or 0) + 1
            end
        end
    end
    self.nodes, self.lots, self.kinds = nodes, lots, kinds
    self.carried, self.limit, self.eligible, self.bagCount = carried, limit, eligible, #nodes - 1
    return true
end

-- Every move of the best arrangement found, one item at a time.
local function arrange(self)
    local nodes = {}
    for index, node in ipairs(self.nodes) do
        nodes[index] = {factor = math.floor(node.factor * 10000 + 0.5), room = node.room, parent = node.parent, held = node.held}
    end
    local started = getTimestampMs()
    local problem = {nodes = nodes, lots = self.lots, kinds = self.kinds, carried = self.carried / EPS * 10000, limit = (self.limit / EPS + 1) * 10000}
    local plan = Pack.plan(problem)
    self.stuck = problem.stuck
    local steps = {}
    for _, step in ipairs(plan and plan.steps or {}) do
        local items = self.lots[step.index].items
        local entry = table.remove(items[step.from], 1)
        items[step.to] = items[step.to] or {}
        table.insert(items[step.to], entry)
        steps[#steps + 1] = {item = entry, source = step.from, destination = step.to, parked = step.parked}
    end
    self.steps, self.index, self.parked, self.saving = steps, 1, {}, plan and plan.saving / 10000 * EPS or 0
    Log.trace(self.interaction, "CONDENSE-PLAN", "mode", self.options.rebalance and "rebalance" or "pack", "bags", self.bagCount,
        "items", self.eligible, "kinds", #self.lots, "moves", #steps, "carried", self.carried, "limit", self.limit,
        "saving", self.saving, "stuck", self.stuck == true, "ms", getTimestampMs() - started)
end

local function endReason(self)
    if self.bagCount == 0 then return "You are not wearing or holding a bag to pack. Settings can include bags you are not wearing." end
    if self.eligible == 0 then return self.options.rebalance and "Nothing you carry can be rearranged." or "Nothing loose in your inventory can be packed." end
    if self.stuck then return "Packed as well as possible. Some swaps need more free carrying room for a moment." end
    for _ in pairs(self.blocked) do return "Packed, except for items the game would not move." end
    return "Your bags are packed."
end

-- Plans again from what is carried now. A move refused once is tried again
-- when nothing else is left.
local function replan(self)
    self.rounds = self.rounds + 1
    if self.rounds > MAX_ROUNDS then
        self.finished, self.limited, self.reason = true, true, "Your items keep changing. Press Condense again to continue."
        return true
    end
    for _ = 1, 2 do
        local ok, err = capture(self)
        if not ok then return nil, err end
        arrange(self)
        if #self.steps > 0 then return true end
        local again = false
        for pair in pairs(self.blocked) do
            if self.refused[pair] < 2 then again = true end
        end
        if not again then break end
        for pair, count in pairs(self.refused) do if count < 2 then self.blocked[pair] = nil end end
    end
    self.finished, self.reason = true, endReason(self)
    return true
end

function Condense.new(world, options)
    options = options or {}
    local self = setmetatable({world = world, options = {rebalance = options.rebalance == true,
        useUnequipped = options.useUnequipped == true, nested = options.nested == true}, interaction = options.interaction,
        home = {}, blocked = {}, refused = {}, transfers = 0, saved = 0, rounds = 0, refusals = 0}, Condense)
    local ok, err = replan(self)
    if not ok then return nil, err end
    self.beforeWeight = self.carried
    return self
end

function Condense:preview()
    local steps = {}
    for _, step in ipairs(self.steps) do
        steps[#steps + 1] = {itemName = step.item.name, from = self.world:name(self.nodes[step.source].ref),
            to = self.world:name(self.nodes[step.destination].ref), temporary = step.parked == true}
    end
    return {steps = steps, eligible = self.eligible, bagCount = self.bagCount, beforeWeight = self.beforeWeight,
        mode = self.options.rebalance and "rebalance" or "pack", estimatedSaving = math.max(0, self.saving), reason = self.reason}
end

-- The next move, or nil and why not and whether that is the end.
function Condense:next()
    self.pausedReason = nil
    if self.pending then return self.pending end
    if not self.finished and not (self.steps and self.steps[self.index]) then
        local ok, err = replan(self)
        if not ok then self.pausedReason = err; return nil, err, false end
    end
    if self.finished then return nil, self.reason, true end
    local step = self.steps[self.index]
    self.pending = {kind = "transfer", item = step.item.ref, source = self.nodes[step.source].ref,
        destination = self.nodes[step.destination].ref, condense = true, condenseStep = step,
        condenseId = step.item.id, condenseType = step.item.fullType, condenseWeight = step.item.weight}
    return self.pending
end

function Condense:validate(op)
    if not op or op ~= self.pending then return nil, "This Condense move is out of date", "changed" end
    local item, source, destination, world = op.item, op.source, op.destination, self.world
    if not item or item:getID() ~= op.condenseId or tostring(item:getFullType()) ~= op.condenseType
        or item:getContainer() ~= source or source:getItemWithID(op.condenseId) ~= item then
        return nil, "An item moved while Condense was waiting", "changed"
    end
    if not world:owns(source) or not world:owns(destination) or not world:valid(source) or not world:valid(destination)
        or call(source, "isLockedToCharacter", world.player) == true or call(destination, "isLockedToCharacter", world.player) == true then
        return nil, "A bag is no longer carried or is locked", "changed"
    end
    local protected, reason = world:protected(item)
    if protected or isBag(item) then return nil, "Protected: " .. tostring(reason or "Bags stay where they are"), "changed" end
    local weight = math.max(0, item:getUnequippedWeight())
    if math.abs(weight - op.condenseWeight) > EPS then return nil, "An item's weight changed during Condense", "changed" end
    for _, node in ipairs(self.nodes) do
        if node.bag then
            local worn = call(world.player, "isEquipped", node.bag) == true or call(node.bag, "isFakeEquipped", world.player) == true
            if not world:owns(node.ref) or node.bag:getInventory() ~= node.ref or node.bag:getContainer() ~= self.nodes[node.parent].ref
                or worn ~= node.worn or math.abs(world:carryFactor(node.ref) - node.factor) > EPS then
                return nil, "The bags you carry changed", "changed"
            end
        end
    end
    if call(source, "isRemoveItemAllowed", item) ~= true or call(destination, "isItemAllowed", item) ~= true
        or call(destination, "isInside", item) == true then return nil, "The game does not allow this move", "changed" end
    local inside = {}
    local node = op.condenseStep.source
    while node do inside[node], node = true, self.nodes[node].parent end
    node = op.condenseStep.destination
    while node and node ~= 1 and not inside[node] do
        local container = self.nodes[node].ref
        if container:getCapacityWeight() + weight > container:getEffectiveCapacity(world.player) + EPS then
            return nil, world:name(container) .. " has no room for this", "capacity"
        end
        node = self.nodes[node].parent
    end
    local current, maximum = world:carrying()
    local delta = world:carryDelta(item, destination)
    if delta > EPS and current + delta > maximum + EPS then return nil, "You cannot carry that much, even for a moment", "capacity" end
    if not destination:hasRoomFor(world.player, item) or not world:serverAccepts(item, source, destination) then
        return nil, world:name(destination) .. " has no room for this", "capacity"
    end
    op.condenseDelta = delta
    return true
end

function Condense:settle(op, ok, reason)
    if op ~= self.pending then return nil, "This Condense result is out of date" end
    local step = op.condenseStep
    local observed = op.destination:getItemWithID(op.condenseId)
    if observed and tostring(observed:getFullType()) == op.condenseType and observed:getContainer() == op.destination
        and not op.source:containsID(op.condenseId) then ok, op.item = true, observed end
    self.pending = nil
    if ok then
        step.item.ref, self.parked[step.item] = op.item, step.parked and step or nil
        self.transfers = self.transfers + 1
        self.saved = self.saved - (op.condenseDelta or 0)
        self.index = self.index + 1
        return true
    end
    local pair = pairKey(step.item, self.nodes[step.destination])
    self.refusals, self.refused[pair], self.blocked[pair] = self.refusals + 1, (self.refused[pair] or 0) + 1, true
    if self.refusals >= MAX_REFUSALS then
        self.pausedReason = "The game keeps refusing these moves. Check what you carry, then Resume."
        return nil, self.pausedReason
    end
    Log.trace(self.interaction, "CONDENSE-REFUSED", "item", Log.item(op.item, self.world.player), "to", Log.container(op.destination, self.world.player),
        "times", self.refused[pair], "reason", reason)
    self.steps = nil
    return true
end

function Condense:onResume()
    self.pausedReason, self.finished, self.refusals, self.rounds = nil, nil, 0, 0
    if not self.pending then self.steps, self.blocked, self.refused = nil, {}, {} end
end

function Condense:status()
    local buffered = 0
    for item, step in pairs(self.parked) do
        if item.ref:getContainer() == self.nodes[step.destination].ref then buffered = buffered + 1 end
    end
    return {mode = self.options.rebalance and "rebalance" or "pack", eligible = self.eligible, bagCount = self.bagCount,
        planned = self.transfers + math.max(0, #(self.steps or {}) - (self.index or 1) + 1),
        transfers = self.transfers, buffered = buffered, saved = self.saved,
        beforeWeight = self.beforeWeight, currentWeight = (self.world:carrying()), limited = self.limited == true,
        reason = self.pausedReason or self.reason}
end

return Condense
