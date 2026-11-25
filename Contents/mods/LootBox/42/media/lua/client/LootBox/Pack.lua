-- Decides where carried items belong, then in which order to move them there.
-- Only whole numbers (weights in 0.0001, costs in 0.00000001), so sums never drift.
--   nodes: {factor, room, parent, held}. Node 1 is main inventory and has no limit of its own.
--   lots:  {weight, kinds, fits = {[node]}, cost, start and home = {[node] = count}}, interchangeable items.
--   kinds: {[kind] = {[node] = count}} for things that stay where they are.
--   carried, limit: the weight carried, and the most the game lets the player carry.
local Sort = require "LootBox/Sort"

local Pack = {}

-- The game rounds how full a bag is to 0.01, so less room than that is none.
local FULL = 100
local WORK, SEARCH, RETRIES = 40000, 600, 4
local EXACT_ITEMS, EXACT_WORK = 40, 6000

local function within(nodes, node, outer)
    while node do
        if node == outer then return true end
        node = nodes[node].parent
    end
    return false
end

-- Room for something from one place in another, counting the bags around it.
local function space(p, s, from, to)
    local least = math.huge
    while to ~= 1 and not within(p.nodes, from, to) do
        if s.room[to] < least then least = s.room[to] end
        to = p.nodes[to].parent
    end
    return least
end

local function shift(p, s, index, from, to, count)
    local lot, at = p.lots[index], s.at[index]
    local start, weight = lot.start, lot.weight * count
    at[from], at[to] = (at[from] or 0) - count, (at[to] or 0) + count
    s.cost = s.cost + (lot.cost[to] - lot.cost[from]) * count
    s.moves = s.moves + math.min(count, math.max(0, (start[from] or 0) - at[from]))
        - math.min(count, math.max(0, (start[to] or 0) - at[to] + count))
    for _, kind in ipairs(lot.kinds) do
        local places = s.places[kind]
        places[from], places[to] = places[from] - count, (places[to] or 0) + count
        if places[from] == 0 then s.spread = s.spread - 1 end
        if places[to] == count then s.spread = s.spread + 1 end
    end
    while from ~= 1 do s.room[from], from = s.room[from] + weight, p.nodes[from].parent end
    while to ~= 1 do s.room[to], to = s.room[to] - weight, p.nodes[to].parent end
end

local function begin(p)
    local s = {at = {}, room = {}, places = {}, cost = 0, spread = 0, moves = 0}
    for index, node in ipairs(p.nodes) do s.room[index] = node.room end
    for kind, places in pairs(p.kinds) do
        s.places[kind] = {}
        for node, count in pairs(places) do s.places[kind][node] = count end
    end
    for index, lot in ipairs(p.lots) do
        s.at[index] = {}
        for node, count in pairs(lot.start) do
            s.at[index][node], s.cost = count, s.cost + lot.cost[node] * count
            for _, kind in ipairs(lot.kinds) do
                s.places[kind] = s.places[kind] or {}
                s.places[kind][node] = (s.places[kind][node] or 0) + count
            end
        end
    end
    for _, places in pairs(s.places) do for _ in pairs(places) do s.spread = s.spread + 1 end end
    return s
end

-- Weight first, then the same kinds of things together, then the fewest moves.
local function better(s, cost, spread, moves)
    if s.cost ~= cost then return s.cost < cost end
    if s.spread ~= spread then return s.spread < spread end
    return s.moves < moves
end

local function joins(s, lot, node)
    for _, kind in ipairs(lot.kinds) do if (s.places[kind][node] or 0) > 0 then return true end end
    return false
end

-- How many of each to take so their weight comes closest to the limit without
-- passing it, and beats least. Tries the most of the first ones first.
local function choose(p, entries, limit, least)
    local count, rest = #entries, {}
    rest[count + 1] = 0
    for index = count, 1, -1 do rest[index] = rest[index + 1] + entries[index].weight * entries[index].count end
    local taken, best, sum, index, tries = {}, nil, 0, 1, SEARCH
    while true do
        while index <= count and sum + rest[index] > least do
            local entry = entries[index]
            taken[index] = math.min(entry.count, math.floor((limit - sum) / entry.weight))
            sum, index = sum + taken[index] * entry.weight, index + 1
        end
        if sum > least then
            best, least = {}, sum
            for at = 1, index - 1 do best[at] = taken[at] end
        end
        tries = tries - 1
        if limit - least < FULL or tries <= 0 then break end
        index = index - 1
        while index >= 1 and taken[index] == 0 do index = index - 1 end
        if index < 1 then break end
        taken[index], sum, index = taken[index] - 1, sum - entries[index].weight, index + 1
    end
    p.work = p.work - (SEARCH - tries)
    return best, least
end

-- Brings weight from a worse place into a better one until it is full,
-- sending something lighter back where that helps.
local function fill(p, s, into, from)
    local room = space(p, s, from, into)
    if room < FULL or room == math.huge then return false end
    local entries = {}
    for index, lot in ipairs(p.lots) do
        local here = s.at[index][from] or 0
        if here > 0 and lot.weight > 0 and lot.fits[into] and lot.cost[into] < lot.cost[from] then
            entries[#entries + 1] = {index = index, weight = lot.weight, count = here, rank = joins(s, lot, into) and 0 or 1}
        end
    end
    if #entries == 0 then return false end
    Sort(entries, function(entry) return entry.rank, -entry.weight, entry.index end)
    local best, gain = choose(p, entries, room, 0)
    local returnable, out = {}, {}
    for index, lot in ipairs(p.lots) do
        if (s.at[index][into] or 0) > 0 and lot.weight > 0 and lot.fits[from] then returnable[#returnable + 1] = index end
    end
    local function exchange(back)
        if p.work <= 0 or room - gain < FULL then return end
        local weight = 0
        for _, index in ipairs(back) do weight = weight + p.lots[index].weight end
        local taken, sum = choose(p, entries, room + weight, weight + gain)
        if taken then best, gain, out = taken, sum - weight, back end
    end
    for _, index in ipairs(returnable) do exchange({index}) end
    for first = 1, #returnable do
        for second = first + 1, #returnable do exchange({returnable[first], returnable[second]}) end
    end
    if not best then return false end
    for _, index in ipairs(out) do shift(p, s, index, into, from, 1) end
    for at, count in pairs(best) do
        if count > 0 then shift(p, s, entries[at].index, from, into, count) end
    end
    return true
end

local function relocate(p, s)
    local changed = false
    for index, lot in ipairs(p.lots) do
        local at = s.at[index]
        for _, from in ipairs(p.order) do
            for _, to in ipairs(p.order) do
                local here = at[from] or 0
                if to ~= from and here > 0 and lot.fits[to] and lot.cost[to] <= lot.cost[from] then
                    local most = lot.weight > 0 and math.min(here, math.floor(space(p, s, from, to) / lot.weight)) or here
                    for _, count in ipairs({most, math.min(most, (lot.start[to] or 0) - (at[to] or 0))}) do
                        if count > 0 and count <= at[from] then
                            local cost, spread, moves = s.cost, s.spread, s.moves
                            shift(p, s, index, from, to, count)
                            if better(s, cost, spread, moves) then changed = true
                            else shift(p, s, index, to, from, count) end
                        end
                    end
                end
            end
        end
    end
    return changed
end

-- Moves one lot to where the rest of its kind is, or where it started, making
-- room by sending another lot the other way.
local function gather(p, s)
    local changed = false
    local function try(index, from, to, count)
        local lot, at = p.lots[index], s.at[index]
        local weight = lot.weight * count
        local need = weight - space(p, s, from, to)
        if count <= 0 or need <= 0 then return end
        for other, swap in ipairs(p.lots) do
            local there = s.at[other][to] or 0
            if other ~= index and there > 0 and swap.weight > 0 and swap.fits[from] then
                for _, back in ipairs({math.ceil(need / swap.weight), weight / swap.weight, there}) do
                    local net = weight - swap.weight * back
                    if back <= there and back == math.floor(back) and at[from] >= count
                        and (lot.cost[to] - lot.cost[from]) * count <= (swap.cost[to] - swap.cost[from]) * back
                        and net <= space(p, s, from, to) and -net <= space(p, s, to, from) then
                        p.work = p.work - 1
                        local cost, spread, moves = s.cost, s.spread, s.moves
                        shift(p, s, index, from, to, count)
                        shift(p, s, other, to, from, back)
                        if better(s, cost, spread, moves) then changed = true; return end
                        shift(p, s, other, from, to, back)
                        shift(p, s, index, to, from, count)
                    end
                end
            end
        end
    end
    for index, lot in ipairs(p.lots) do
        local at = s.at[index]
        for _, from in ipairs(p.order) do
            for _, to in ipairs(p.order) do
                local here = at[from] or 0
                if to ~= from and here > 0 and lot.fits[to] and p.work > 0 then
                    local missing = math.min(here, (lot.start[to] or 0) - (at[to] or 0))
                    if missing > 0 or joins(s, lot, to) then
                        try(index, from, to, here)
                        if missing ~= here then try(index, from, to, missing) end
                    end
                end
            end
        end
    end
    return changed
end

local function improve(p, s)
    p.work = WORK
    for _ = 1, 8 do
        local changed = false
        for _, into in ipairs(p.order) do
            for at = #p.order, 1, -1 do
                local from = p.order[at]
                if from == into then break end
                if p.work > 0 and fill(p, s, into, from) then changed = true end
            end
        end
        if relocate(p, s) then changed = true end
        if gather(p, s) then changed = true end
        if not changed then break end
    end
    return s
end

-- Tries every placement of a few things, heaviest first, leaving out those that
-- cannot beat the one given even if the rest could be cut to fit.
local function exact(p, best)
    local pieces, total = {}, 0
    for index, lot in ipairs(p.lots) do
        for _, count in pairs(lot.start) do
            for _ = 1, lot.weight > 0 and count or 0 do pieces[#pieces + 1], total = index, total + lot.weight end
            if #pieces > EXACT_ITEMS then return nil end
        end
    end
    Sort(pieces, function(index) return -p.lots[index].weight, index end)
    local s, work, found, at = begin(p), EXACT_WORK, nil, {}
    for index, lot in ipairs(p.lots) do
        for node, count in pairs(lot.start) do
            if node ~= 1 and lot.weight > 0 then shift(p, s, index, node, 1, count) end
        end
    end
    local least = best.cost
    local function bound(cost, left)
        for _, node in ipairs(p.order) do
            if left <= 0 then break end
            local part = math.min(left, math.max(0, s.room[node]))
            cost, left = cost + part * p.nodes[node].factor, left - part
        end
        return cost
    end
    local function place(piece, cost, left, low)
        local index = pieces[piece]
        if not index then
            if cost < least then
                least, found = cost, {}
                for other = 1, #pieces do found[other] = at[other] end
            end
            return
        end
        work = work - 1
        if work <= 0 or bound(cost, left) >= least then return end
        local lot = p.lots[index]
        for rank = low, #p.order do
            local node = p.order[rank]
            -- Things alike go in one order only.
            if (lot.fits[node] or node == 1 and (lot.start[1] or 0) > 0) and lot.weight <= space(p, s, 1, node) then
                at[piece] = node
                if node ~= 1 then shift(p, s, index, 1, node, 1) end
                place(piece + 1, cost + lot.cost[node], left - lot.weight, pieces[piece + 1] == index and rank or 1)
                if node ~= 1 then shift(p, s, index, node, 1, 1) end
            end
        end
    end
    local fixed = 0
    for index, lot in ipairs(p.lots) do
        if lot.weight == 0 then for node, count in pairs(s.at[index]) do fixed = fixed + lot.cost[node] * count end end
    end
    place(1, fixed, total, 1)
    if not found then return nil end
    for piece, node in ipairs(found) do if node ~= 1 then shift(p, s, pieces[piece], 1, node, 1) end end
    return s
end

-- The best arrangement found, or nil when the present one is as good. Looks from
-- here, from everything loose, from where things were before this run began, and
-- at every possibility when there are few.
local function arrange(p)
    local now, best = begin(p), improve(p, begin(p))
    for _, loose in ipairs({true, false}) do
        local s, legal = begin(p), true
        for index, lot in ipairs(p.lots) do
            for node, count in pairs(lot.start) do
                if node ~= 1 and not (loose and not lot.fits[1]) then shift(p, s, index, node, 1, count) end
            end
            for node, count in pairs(loose and {} or lot.home) do
                if not lot.fits[node] and count > (lot.start[node] or 0) then legal = false end
                if node ~= 1 then shift(p, s, index, 1, node, count) end
            end
        end
        for node, room in pairs(s.room) do if room < math.min(0, now.room[node]) then legal = false end end
        if legal and s.moves > 0 then
            improve(p, s)
            if better(s, best.cost, best.spread, best.moves) then best = s end
        end
    end
    local s = exact(p, best)
    if s then best = improve(p, s) end
    if best.cost < now.cost or best.cost == now.cost and best.spread < now.spread then return best end
end

-- The moves in an order the game allows, and the ones nothing can make room for.
-- A move may park one item in the way for a moment, in main inventory if it can.
local function order(p, target)
    local s, steps, flows = begin(p), {}, {}
    for index, lot in ipairs(p.lots) do
        local spare, short = {}, {}
        for _, node in ipairs(p.order) do
            local extra = (lot.start[node] or 0) - (target.at[index][node] or 0)
            if extra > 0 then spare[#spare + 1] = {node = node, count = extra}
            elseif extra < 0 then short[#short + 1] = {node = node, count = -extra} end
        end
        local want = 1
        for _, have in ipairs(spare) do
            while have.count > 0 do
                local into = short[want]
                local count = math.min(have.count, into.count)
                flows[#flows + 1] = {index = index, from = have.node, to = into.node, count = count}
                have.count, into.count = have.count - count, into.count - count
                if into.count == 0 then want = want + 1 end
            end
        end
    end
    -- Heaviest relief first, so every step so far has helped the most.
    Sort(flows, function(flow)
        local lot = p.lots[flow.index]
        return lot.cost[flow.to] - lot.cost[flow.from], flow.index
    end)
    local carried = p.carried
    local function allowed(index, from, to)
        local weight = p.lots[index].weight
        -- The game wants room for all of it, even when it comes from a bag inside.
        if weight > space(p, s, from, to) or to ~= 1 and weight > s.room[to] then return false end
        local added = weight * math.max(0, p.nodes[to].factor - p.nodes[from].factor)
        if to == 1 or p.nodes[to].held and from ~= 1 then added = weight * 10000 end
        return added == 0 or carried + added <= p.limit
    end
    local function step(flow, to, parked)
        shift(p, s, flow.index, flow.from, to, 1)
        carried = carried + p.lots[flow.index].weight * (p.nodes[to].factor - p.nodes[flow.from].factor)
        flow.count = flow.count - 1
        steps[#steps + 1] = {index = flow.index, from = flow.from, to = to, parked = parked, cost = s.cost, spread = s.spread}
    end
    -- The lightest thing whose leaving lets another one in, else the heaviest.
    local function park()
        local best, buffer, score
        for _, flow in ipairs(flows) do
            local lot, at = p.lots[flow.index], nil
            if flow.count > 0 and not flow.parked then
                if flow.from ~= 1 and lot.fits[1] and allowed(flow.index, flow.from, 1) then at = 1 end
                for _, node in ipairs(p.order) do
                    if not at and node ~= 1 and node ~= flow.from and lot.fits[node] and not within(p.nodes, node, flow.from)
                        and allowed(flow.index, flow.from, node) then at = node end
                end
            end
            local value = lot.weight
            for _, other in ipairs(at and flows or {}) do
                local weight = p.lots[other.index].weight
                if value > 0 and other.count > 0 and other.to == flow.from and weight <= space(p, s, other.from, other.to) + lot.weight then
                    value = -lot.weight
                end
            end
            -- Any that lets one in (below zero) beats any that does not.
            value = value < 0 and -value or at and 1000000000 - value
            if at and (not best or value < score) then best, buffer, score = flow, at, value end
        end
        if not best then return false end
        step(best, buffer, true)
        flows[#flows + 1] = {index = best.index, from = buffer, to = best.to, count = 1, parked = true}
        return true
    end
    while true do
        local moved, left = false, false
        for _, flow in ipairs(flows) do
            local count = flow.count
            while flow.count > 0 and allowed(flow.index, flow.from, flow.to) do step(flow, flow.to) end
            moved, left = moved or flow.count < count, left or flow.count > 0
            if flow.count < count and left then break end
        end
        if not left then return steps, {} end
        if not moved and not park() then
            local stuck = {}
            for _, flow in ipairs(flows) do if flow.count > 0 then stuck[#stuck + 1] = flow end end
            return steps, stuck
        end
    end
end

-- The moves to make, or nil when the present arrangement is as good as any found.
function Pack.plan(p)
    p.order = {}
    for index in ipairs(p.nodes) do p.order[index] = index end
    Sort(p.order, function(node) return p.nodes[node].factor, node == 1 and 1 or 0, node end)
    local now = begin(p)
    local best
    for _ = 1, RETRIES do
        local target = arrange(p)
        if not target then break end
        local steps, stuck = order(p, target)
        local last, cost, spread = 0, now.cost, now.spread
        for index, step in ipairs(steps) do
            if step.cost < cost or step.cost == cost and step.spread < spread then last, cost, spread = index, step.cost, step.spread end
        end
        while #steps > last do table.remove(steps) end
        if last > 0 and (not best or cost < best.cost or cost == best.cost and spread < best.spread) then
            best = {steps = steps, cost = cost, spread = spread}
        end
        if #stuck == 0 then break end
        p.stuck = true
        for _, flow in ipairs(stuck) do p.lots[flow.index].fits[flow.to] = nil end
    end
    if best then best.saving = now.cost - best.cost end
    return best
end

return Pack
