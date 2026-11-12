local Condense = {}
Condense.__index = Condense

local EPS = 0.0001
local WORK_PER_TICK, MAX_EXCHANGES, MAX_VARIANTS = 256, 256, 12
local MAX_TRANSACTIONS = 4096
local MAX_REFUSALS = 64

local function call(object, method, ...)
    if not object then return nil end
    local args = {...}
    local ok, result = pcall(function()
        local fn = object[method]
        return fn and fn(object, unpack(args))
    end)
    if ok then return result end
end

local function size(values) return call(values, "size") or 0 end
local function isBag(item) return call(item, "IsInventoryContainer") == true or call(item, "getCategory") == "Container" end
local function itemKey(item) return tostring(item:getID()) .. ":" .. tostring(item:getFullType()) end
local function numericKey(value) return string.format("%.4f", value) end
local function copy(values)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    return result
end
local function clone(state)
    return {at = copy(state.at), used = copy(state.used), mass = state.mass,
        mainMass = state.mainMass, mainCount = state.mainCount}
end
local function better(a, b)
    if a.mass < b.mass - EPS then return true end
    if math.abs(a.mass - b.mass) > EPS then return false end
    if a.mainMass < b.mainMass - EPS then return true end
    if math.abs(a.mainMass - b.mainMass) > EPS then return false end
    return a.mainCount < b.mainCount
end
local function descendants(nodes, child, ancestor)
    while child and child ~= 1 do
        if child == ancestor then return true end
        child = nodes[child].parent
    end
    return ancestor == 1
end
local function deltas(nodes, source, destination, weight)
    local result = {}
    while source and source ~= 1 do
        result[source] = (result[source] or 0) - weight
        source = nodes[source].parent
    end
    while destination and destination ~= 1 do
        result[destination] = (result[destination] or 0) + weight
        destination = nodes[destination].parent
    end
    return result
end

local function capture(self)
    local world, player = self.world, self.world.player
    local main = player:getInventory()
    if not main or not world:owns(main) then return nil, "The carried inventory is unavailable" end
    local current, maximum = world:carrying()
    local nodes = {{key = "main", ref = main, factor = 1, capacity = math.huge, used = 0, parent = nil, rawGate = true}}
    local byContainer, seenContainers, seenItems = {[main] = 1}, {}, {}
    local items, protected, bagCount = {}, 0, 0
    local fingerprint = {}
    local function scan(container, node, root)
        if seenContainers[container] then return nil, "Carried bag nesting is cyclic or ambiguous" end
        seenContainers[container] = true
        local values = container:getItems()
        for index = 0, values:size() - 1 do
            local item = values:get(index)
            if not seenItems[item] then
                seenItems[item] = true
                if isBag(item) then
                    local inside = call(item, "getInventory")
                    local equipped = call(player, "isEquipped", item) == true or call(item, "isFakeEquipped", player) == true
                    local attached = (call(item, "getAttachedSlot") or -1) >= 0
                    local eligible = root and (equipped or self.options.useUnequipped)
                        or (not root and self.options.nested)
                    if inside and eligible and (not attached or equipped) and world:owns(inside) and world:valid(inside)
                        and call(inside, "isLockedToCharacter", player) ~= true
                        and not (world.recovery and world.recovery:isReservedContainer(inside)) then
                        local number = #nodes + 1
                        local maximumItem = call(item, "getMaxItemSize") or 0
                        nodes[number] = {key = itemKey(item), ref = inside, bag = item, parent = node,
                            factor = world:carryFactor(inside), capacity = inside:getEffectiveCapacity(player),
                            used = inside:getCapacityWeight(), maxItem = maximumItem,
                            rawGate = call(item, "getEquipParent") ~= nil or equipped, equipped = equipped}
                        byContainer[inside], bagCount = number, bagCount + 1
                        fingerprint[#fingerprint + 1] = nodes[number].key .. ":" .. nodes[node].key
                            .. ":" .. tostring(equipped) .. ":" .. tostring(nodes[number].rawGate)
                            .. ":" .. numericKey(nodes[number].factor) .. ":" .. numericKey(nodes[number].capacity)
                            .. ":" .. numericKey(nodes[number].used)
                        local ok, err = scan(inside, number, false)
                        if not ok then return nil, err end
                    end
                else
                    local fixed = world:protected(item) or call(item, "isHumanCorpse") == true
                    if fixed then protected = protected + 1
                    elseif self.options.rebalance or node == 1 then
                        local weight = math.max(0, item:getUnequippedWeight())
                        local entry = {key = itemKey(item), id = item:getID(), fullType = tostring(item:getFullType()),
                            ref = item, weight = weight, start = node, name = tostring(item:getName())}
                        items[#items + 1] = entry
                        fingerprint[#fingerprint + 1] = entry.key .. ":" .. nodes[node].key .. ":" .. numericKey(weight)
                    end
                end
            end
        end
        return true
    end
    local ok, err = scan(main, 1, true)
    if not ok then return nil, err end
    table.sort(items, function(a, b)
        if math.abs(a.weight - b.weight) > EPS then return a.weight > b.weight end
        return a.key < b.key
    end)
    local state = {at = {}, used = {}, mass = current, mainMass = 0, mainCount = 0}
    for index, node in ipairs(nodes) do state.used[index] = node.used end
    for index, item in ipairs(items) do
        state.at[index] = item.start
        if item.start == 1 then state.mainMass, state.mainCount = state.mainMass + item.weight, state.mainCount + 1 end
    end
    local destinations = {}
    for index = 2, #nodes do destinations[#destinations + 1] = index end
    table.sort(destinations, function(a, b)
        if nodes[a].factor ~= nodes[b].factor then return nodes[a].factor < nodes[b].factor end
        if nodes[a].parent ~= nodes[b].parent then return nodes[a].parent < nodes[b].parent end
        return nodes[a].key < nodes[b].key
    end)
    table.sort(fingerprint)
    local signature = table.concat(fingerprint, "|") .. ":" .. numericKey(maximum) .. ":" .. numericKey(current)
    if self.signature and self.signature ~= signature then self.revision = self.revision + 1 end
    self.signature = signature
    self.nodes, self.byContainer, self.items, self.destinations = nodes, byContainer, items, destinations
    self.state, self.hard, self.pairs, self.protectedCount, self.bagCount = state, maximum, {}, protected, bagCount
    self.eligible = #items
    self.search = nil
    return true
end

function Condense.new(world, options)
    local self = setmetatable({world = world, options = {rebalance = options and options.rebalance == true,
        useUnequipped = options and options.useUnequipped == true, nested = options and options.nested == true},
        revision = 0, failedPairs = {}, rejectedPlans = {}, transfers = 0, moved = {}, saved = 0, transactions = 0, refusals = 0}, Condense)
    local ok, err = capture(self)
    if not ok then return nil, err end
    self.beforeWeight = self.state.mass
    return self
end

function Condense:pair(itemIndex, nodeIndex)
    local row = self.pairs[itemIndex]
    if not row then row = {}; self.pairs[itemIndex] = row end
    if row[nodeIndex] == nil then
        local item, node = self.items[itemIndex], self.nodes[nodeIndex]
        row[nodeIndex] = {allowed = call(node.ref, "isItemAllowed", item.ref) == true
            and (nodeIndex == 1 or node.maxItem <= 0 or item.weight <= node.maxItem + EPS),
            removable = call(node.ref, "isRemoveItemAllowed", item.ref) == true}
    end
    return row[nodeIndex]
end

function Condense:legal(state, itemIndex, destination)
    local source = state.at[itemIndex]
    if source == destination then return nil end
    local item, target = self.items[itemIndex], self.nodes[destination]
    if not self:pair(itemIndex, destination).allowed or not self:pair(itemIndex, source).removable then return nil end
    local blocked = self.failedPairs[item.key .. ">" .. target.key]
    if blocked == self.revision then return nil end
    local weight = item.weight
    if destination == 1 or (target.rawGate and source ~= 1) then
        if state.mass + weight > self.hard + EPS then self.headroom = true; return nil end
    end
    if destination ~= 1 and state.used[destination] + weight > target.capacity + EPS then return nil end
    local delta = weight * (target.factor - self.nodes[source].factor)
    if delta > EPS and state.mass + delta > self.hard + EPS then self.headroom = true; return nil end
    local changes = deltas(self.nodes, source, destination, weight)
    for node, value in pairs(changes) do
        if value > EPS and state.used[node] + value > self.nodes[node].capacity + EPS then return nil end
    end
    return {item = itemIndex, source = source, destination = destination, delta = delta, changes = changes}
end

local function apply(self, state, step)
    local item = self.items[step.item]
    state.at[step.item] = step.destination
    for node, value in pairs(step.changes) do state.used[node] = state.used[node] + value end
    state.mass = state.mass + step.delta
    if step.source == 1 then state.mainMass, state.mainCount = state.mainMass - item.weight, state.mainCount - 1 end
    if step.destination == 1 then state.mainMass, state.mainCount = state.mainMass + item.weight, state.mainCount + 1 end
end

local function directAllowed(self, state, item, destination)
    local source = state.at[item]
    if source == destination then return false end
    if not self.options.rebalance and source ~= 1 then return false end
    return self.nodes[destination].factor < self.nodes[source].factor - EPS
        or (source == 1 and self.nodes[destination].factor <= 1 + EPS)
end

local function beginDirect(self, state, steps)
    return {state = state, steps = steps or {}, item = 1, destination = 1, pass = 1, added = 0}
end

local function directTick(self, direct, budget)
    local spent = 0
    while direct.item <= #self.items and spent < budget do
        local item, destination = direct.item, self.destinations[direct.destination]
        if not destination then direct.item, direct.destination, spent = direct.item + 1, 1, spent + 1
        else
            spent = spent + 1
            local step = directAllowed(self, direct.state, item, destination) and self:legal(direct.state, item, destination)
            if step then
                direct.steps[#direct.steps + 1] = step
                apply(self, direct.state, step)
                direct.added = direct.added + 1
                direct.item, direct.destination = direct.item + 1, 1
            else direct.destination = direct.destination + 1 end
        end
    end
    if direct.item <= #self.items then return false, spent end
    if self.options.rebalance and direct.added > 0 and direct.pass < #self.nodes then
        direct.item, direct.destination, direct.pass, direct.added = 1, 1, direct.pass + 1, 0
        return false, spent
    end
    return true, spent
end

local function evictionSets(self, state, incoming, destination)
    local eligible = {}
    for index, item in ipairs(self.items) do
        if index ~= incoming and descendants(self.nodes, state.at[index], destination) then eligible[#eligible + 1] = index end
    end
    local result, seen = {{}}, {[""] = true}
    local function add(set)
        if #result >= MAX_VARIANTS then return end
        local ids = copy(set); table.sort(ids)
        local key = table.concat(ids, ",")
        if not seen[key] and #result < MAX_VARIANTS then seen[key] = true; result[#result + 1] = copy(set) end
    end
    local function prefixes(descending)
        local order = copy(eligible)
        table.sort(order, function(a, b)
            if math.abs(self.items[a].weight - self.items[b].weight) > EPS then
                if descending then return self.items[a].weight > self.items[b].weight end
                return self.items[a].weight < self.items[b].weight
            end
            return self.items[a].key < self.items[b].key
        end)
        local total, set = 0, {}
        local needed = math.max(0, state.used[destination] + self.items[incoming].weight - self.nodes[destination].capacity)
        for _, index in ipairs(order) do
            set[#set + 1], total = index, total + self.items[index].weight
            if total + EPS >= needed then add(set); if total > needed + self.items[incoming].weight then break end end
        end
        add(order)
    end
    prefixes(false); prefixes(true)
    for index = 1, math.min(4, #eligible) do add({eligible[index]}) end
    return result
end

local function stageTick(self, candidate, budget)
    local spent = 0
    while candidate.evict <= #candidate.evictions and spent < budget do
        local item = candidate.evictions[candidate.evict]
        local destination = candidate.buffers[candidate.buffer]
        if not destination then return nil, spent end
        spent = spent + 1
        local step = not descendants(self.nodes, destination, candidate.destination)
            and self:pair(item, destination).removable and self:pair(item, candidate.state.at[item]).allowed
            and self:legal(candidate.state, item, destination)
        if step then
            step.buffer = true
            candidate.steps[#candidate.steps + 1] = step
            apply(self, candidate.state, step)
            candidate.evict, candidate.buffer = candidate.evict + 1, 1
        else candidate.buffer = candidate.buffer + 1 end
    end
    if candidate.evict <= #candidate.evictions then return false, spent end
    local step = self:legal(candidate.state, candidate.incoming, candidate.destination)
    spent = spent + 1
    if not step then return nil, spent end
    candidate.steps[#candidate.steps + 1] = step
    apply(self, candidate.state, step)
    candidate.refill = beginDirect(self, candidate.state, candidate.steps)
    return true, spent
end

local function planKey(self, steps)
    local parts = {self.signature}
    for _, step in ipairs(steps) do
        parts[#parts + 1] = self.items[step.item].key .. ":" .. self.nodes[step.source].key .. ">" .. self.nodes[step.destination].key
    end
    return table.concat(parts, "|")
end

local function candidateBetter(self, candidate, best)
    if not better(candidate.state, self.state) then return false end
    candidate.key = planKey(self, candidate.steps)
    if self.rejectedPlans[candidate.key] then return false end
    if not best then return true end
    if better(candidate.state, best.state) then return true end
    if better(best.state, candidate.state) then return false end
    return #candidate.steps < #best.steps
end

function Condense:planningTick()
    local search = self.search
    if not search then
        search = {phase = "direct", direct = beginDirect(self, clone(self.state)), incoming = 1,
            destination = 1, variant = 1, examined = 0, signatures = {}}
        self.search = search
    end
    local budget = WORK_PER_TICK
    while budget > 0 do
        if search.phase == "direct" then
            local done, spent = directTick(self, search.direct, budget)
            budget = budget - math.max(1, spent)
            if done then
                if #search.direct.steps > 0 then return {steps = search.direct.steps, compound = false, final = search.direct.state} end
                if not self.options.rebalance then return false end
                search.phase = "exchange"
            end
        elseif search.candidate then
            local candidate, done, spent = search.candidate
            if candidate.refill then done, spent = directTick(self, candidate.refill, budget)
            else done, spent = stageTick(self, candidate, budget) end
            budget = budget - math.max(1, spent)
            if done == nil or (done and candidate.refill and candidate.refill.item > #self.items) then
                if done and candidateBetter(self, candidate, search.best) then search.best = candidate end
                search.candidate, search.variant = nil, search.variant + 1
            end
        elseif search.examined >= MAX_EXCHANGES or search.incoming > #self.items then
            if search.examined >= MAX_EXCHANGES then self.limited = true end
            if search.best then return {steps = search.best.steps, compound = true, final = search.best.state, key = search.best.key} end
            return false
        else
            local incoming, destination = search.incoming, self.destinations[search.destination]
            if not destination then
                search.incoming, search.destination, search.variant, search.sets = incoming + 1, 1, 1, nil
                budget = budget - 1
            elseif self.state.at[incoming] == destination
                or self.nodes[destination].factor > self.nodes[self.state.at[incoming]].factor + EPS
                or not self:pair(incoming, destination).allowed then
                search.destination, search.variant, search.sets = search.destination + 1, 1, nil
                budget = budget - 1
            else
                if not search.sets then search.sets = evictionSets(self, self.state, incoming, destination) end
                local set = search.sets[search.variant]
                if not set then search.destination, search.variant, search.sets = search.destination + 1, 1, nil
                else
                    search.examined = search.examined + 1
                    local buffers = {}
                    for _, node in ipairs(self.destinations) do if node ~= destination then buffers[#buffers + 1] = node end end
                    buffers[#buffers + 1] = 1
                    search.candidate = {state = clone(self.state), steps = {}, incoming = incoming,
                        destination = destination, evictions = set, evict = 1, buffer = 1, buffers = buffers}
                end
                budget = budget - 1
            end
        end
    end
end

local function endReason(self)
    if self.bagCount == 0 then return "No eligible bags. Equip a bag or include unequipped bags in Settings." end
    if self.eligible == 0 then return self.options.rebalance and "There are no eligible carried items to reorganize." or "There are no eligible loose items in main inventory." end
    if self.headroom then return "No further safe improvement was found. Some rearrangements need more temporary carrying space under the native hard limit." end
    if self.limited then return "The bounded search finished. No additional safe improvement was found in this pass." end
    return "The eligible carried items are condensed; no further beneficial moves were found."
end

local function makeOperation(self, step)
    local item = self.items[step.item]
    return {kind = "transfer", item = item.ref, source = self.nodes[step.source].ref,
        destination = self.nodes[step.destination].ref, condense = true, condenseStep = step,
        condenseId = item.id, condenseType = item.fullType, condenseWeight = item.weight}
end

local function prepareArrangement(arrangement)
    arrangement.index, arrangement.applied, arrangement.bufferItems = 1, {}, {}
    for _, step in ipairs(arrangement.steps) do
        if step.buffer then arrangement.bufferItems[step.item] = step.source end
    end
end

function Condense:preview()
    if not self.arrangement and not self.finished then
        local result = self:planningTick()
        if result == false then self.finished, self.reason = true, endReason(self)
        elseif result then self.arrangement, self.search = result, nil; prepareArrangement(result) end
    end
    local steps = {}
    for _, step in ipairs(self.arrangement and self.arrangement.steps or {}) do
        steps[#steps + 1] = {itemName = self.items[step.item].name, from = self.world:name(self.nodes[step.source].ref),
            to = self.world:name(self.nodes[step.destination].ref), temporary = step.buffer == true}
    end
    return {steps = steps, eligible = self.eligible, bagCount = self.bagCount,
        mode = self.options.rebalance and "rebalance" or "pack", beforeWeight = self.beforeWeight,
        estimatedSaving = self.arrangement and math.max(0, self.state.mass - self.arrangement.final.mass) or 0,
        planning = not self.arrangement and not self.finished, reason = self.reason, limited = self.limited == true}
end

function Condense:next()
    if self.pausedReason then
        self.pausedReason = nil
        if not self.arrangement then
            local ok, err = capture(self)
            if not ok then return nil, err, false end
        end
    end
    if self.pending then return self.pending end
    if self.finished then return nil, self.reason, true end
    if not self.arrangement then
        if self.transactions >= MAX_TRANSACTIONS then
            self.finished, self.limited, self.reason = true, true, "Condense reached its finite arrangement limit; run it again to continue."
            return nil, self.reason, true
        end
        local result = self:planningTick()
        if result == nil then return nil, nil, false end
        if result == false then self.finished, self.reason = true, endReason(self); return nil, self.reason, true end
        self.arrangement, self.search = result, nil
        prepareArrangement(result)
    end
    local arrangement = self.arrangement
    local step = arrangement.steps[arrangement.index]
    if not step then
        self.transactions = self.transactions + 1
        if arrangement.repairing then self.reason = arrangement.failure end
        self.arrangement = nil
        local ok, err = capture(self)
        if not ok then self.pausedReason = err; return nil, err, false end
        return nil, nil, false
    end
    self.pending = makeOperation(self, step)
    return self.pending
end

function Condense:validate(op)
    if not op or op ~= self.pending then return nil, "The Condense operation is no longer current", "changed" end
    local item, source, destination = op.item, op.source, op.destination
    if not item or item:getID() ~= op.condenseId or tostring(item:getFullType()) ~= op.condenseType
        or item:getContainer() ~= source or source:getItemWithID(op.condenseId) ~= item then
        return nil, "An item moved while Condense was waiting; its arrangement needs checking", "changed"
    end
    if not self.world:owns(source) or not self.world:owns(destination) or not self.world:valid(source) or not self.world:valid(destination) then
        return nil, "A Condense bag is no longer carried", "changed"
    end
    if call(source, "isLockedToCharacter", self.world.player) == true
        or call(destination, "isLockedToCharacter", self.world.player) == true then
        return nil, "A Condense bag is locked to another character", "changed"
    end
    local protected, reason = self.world:protected(item)
    if protected or isBag(item) then return nil, "Protected: " .. tostring(reason or "Container objects stay fixed"), "changed" end
    local weight = math.max(0, item:getUnequippedWeight())
    if math.abs(weight - op.condenseWeight) > EPS then return nil, "An item's weight changed during Condense", "changed" end
    for _, node in ipairs(self.nodes) do
        if node.bag then
            local equipped = call(self.world.player, "isEquipped", node.bag) == true or call(node.bag, "isFakeEquipped", self.world.player) == true
            if not self.world:owns(node.ref) or node.bag:getInventory() ~= node.ref or node.bag:getContainer() ~= self.nodes[node.parent].ref
                or equipped ~= node.equipped or math.abs(self.world:carryFactor(node.ref) - node.factor) > EPS then
                return nil, "The carrying bag arrangement or equipment changed", "changed"
            end
        end
    end
    if call(source, "isRemoveItemAllowed", item) ~= true or call(destination, "isItemAllowed", item) ~= true
        or call(destination, "isInside", item) == true then return nil, "Native container rules refuse this Condense move", "changed" end
    local sourceIndex, targetIndex = self.byContainer[source], self.byContainer[destination]
    if not sourceIndex or not targetIndex then return nil, "The selected Condense bags changed", "changed" end
    local changes = deltas(self.nodes, sourceIndex, targetIndex, weight)
    for index, value in pairs(changes) do
        if value > EPS then
            local container = self.nodes[index].ref
            if container:getCapacityWeight() + value > container:getEffectiveCapacity(self.world.player) + EPS then
                return nil, "An enclosing bag no longer has room for this item", "capacity"
            end
        end
    end
    local current, maximum = self.world:carrying()
    local delta = self.world:carryDelta(item, destination)
    if delta > EPS and current + delta > maximum + EPS then return nil, "The native hard carrying limit prevents this temporary move", "capacity" end
    if not destination:hasRoomFor(self.world.player, item) then return nil, "Native admission needs more room for this Condense move", "capacity" end
    op.condenseDelta = delta
    return true
end

local function planRollback(self, reason)
    local arrangement, state, steps = self.arrangement, clone(self.state), {}
    for index = #arrangement.applied, 1, -1 do
        local previous = arrangement.applied[index]
        local step = self:legal(state, previous.item, previous.source)
        if not step then return nil end
        step.rollback = true
        steps[#steps + 1] = step
        apply(self, state, step)
    end
    self.arrangement = {steps = steps, index = 1, applied = {}, compound = true, repairing = true,
        bufferItems = arrangement.bufferItems, final = state, failure = reason}
    return true
end

function Condense:settle(op, ok, reason)
    if op ~= self.pending or not self.arrangement then return nil, "The Condense result has no current arrangement" end
    local step, arrangement = op.condenseStep, self.arrangement
    local observed = op.destination:getItemWithID(op.condenseId)
    if observed and tostring(observed:getFullType()) == op.condenseType and observed:getContainer() == op.destination
        and not op.source:containsID(op.condenseId) then ok, op.item = true, observed end
    self.pending = nil
    if ok then
        apply(self, self.state, step)
        self.items[step.item].ref = op.item
        self.transfers, self.moved[op.condenseId] = self.transfers + 1, true
        self.saved = self.saved - (op.condenseDelta or step.delta)
        self.revision = self.revision + 1
        arrangement.applied[#arrangement.applied + 1] = step
        arrangement.index = arrangement.index + 1
        return true
    end
    local item = self.items[step.item]
    self.refusals = self.refusals + 1
    if self.refusals >= MAX_REFUSALS then
        self.pending = op
        self.pausedReason = "Condense paused after repeated native refusals or changing inventory. Check the carried items, then Resume for a fresh attempt."
        return nil, self.pausedReason
    end
    self.failedPairs[item.key .. ">" .. self.nodes[step.destination].key] = self.revision
    if arrangement.repairing then
        self.pending = op
        self.pausedReason = "A temporary Condense move could not be restored: " .. tostring(reason or "Native action refused")
        return nil, self.pausedReason
    end
    if arrangement.compound and #arrangement.applied > 0 then
        if arrangement.key then self.rejectedPlans[arrangement.key] = true end
        if planRollback(self, reason) then return true end
        self.pending = op
        self.pausedReason = "Condense could not finish or restore its temporary arrangement: " .. tostring(reason or "Native action refused")
        return nil, self.pausedReason
    end
    self.arrangement = nil
    local refreshed, failure = capture(self)
    if not refreshed then self.pausedReason = failure; return nil, failure end
    self.reason = reason
    return true
end

function Condense:onResume()
    self.pausedReason = nil
    self.refusals = 0
    if not self.arrangement and not self.pending then
        self.finished = nil
        local ok, err = capture(self)
        if not ok then self.pausedReason = err end
    end
end

function Condense:status()
    local count, buffered = 0, 0
    for _ in pairs(self.moved) do count = count + 1 end
    local arrangement = self.arrangement
    if arrangement and arrangement.compound then
        for index, original in pairs(arrangement.bufferItems or {}) do
            local item = self.items[index].ref
            local container = item and item:getContainer()
            if container and container ~= self.nodes[original].ref and self.world:owns(container) then buffered = buffered + 1 end
        end
    end
    local current = self.world:carrying()
    return {mode = self.options.rebalance and "rebalance" or "pack", eligible = self.eligible, bagCount = self.bagCount,
        transfers = self.transfers, itemsMoved = count, buffered = buffered, saved = self.saved,
        beforeWeight = self.beforeWeight, currentWeight = current, limited = self.limited == true,
        reason = self.pausedReason or self.reason, repairing = arrangement and arrangement.repairing == true or false}
end

return Condense
