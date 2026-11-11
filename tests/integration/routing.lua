package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local Routing = require "LootBox/Routing"
local passed = 0
local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

local function bin(key, capacity, outbound, options)
    options = options or {}
    return { key = key, container = { name = key }, capacity = capacity, used = options.used or 0,
        outbound = outbound, returnCost = options.returnCost or outbound,
        repeatCost = options.repeatCost or outbound, emptySeconds = options.emptySeconds or 2,
        accepts = options.accepts, deferredEmptyCount = options.deferredEmptyCount,
        deferredTravel = options.deferredTravel }
end

local function near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001, tostring(actual) .. " differs from " .. tostring(expected))
end

test("the nearer bin wins when both fit the work in one emptying", function()
    local nearby, farther = bin("near", 10, 1), bin("far", 50, 2)
    local ranked = Routing.rank({ farther, nearby }, { 2, 2, 2, 2, 2 }, 10)
    assert(#ranked == 2 and ranked[1].key == "near")
    assert(ranked[1].trips == 1 and ranked[1].emptyCount == 1)
    near(ranked[1].cost, 3)
    near(ranked[2].cost, 4)
end)

test("a farther larger bin wins when its saved emptyings outweigh travel", function()
    local ranked = Routing.rank({ bin("near", 2, 1), bin("large", 10, 2) }, { 2, 2, 2, 2, 2 }, 10)
    assert(ranked[1].key == "large" and ranked[1].emptyCount == 1)
    near(ranked[1].cost, 4)
    assert(ranked[2].emptyCount == 5)
    near(ranked[2].cost, 11)
end)

test("limited carrying capacity can make the nearer small bin the cheaper choice", function()
    local choices = { bin("near", 2, 1), bin("large", 10, 3) }
    local weights = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }
    local oneTrip = Routing.rank(choices, weights, 10)
    assert(oneTrip[1].key == "large")
    near(oneTrip[1].cost, 5)
    local fiveTrips = Routing.rank(choices, weights, 2)
    assert(fiveTrips[1].key == "near" and fiveTrips[1].trips == 5)
    near(fiveTrips[1].cost, 19)
    near(fiveTrips[2].cost, 29)
end)

test("staying with a touched bin avoids moving its owed cleanup to another route", function()
    local nearby = bin("touched small", 10, 1, { used = 9 })
    local larger = bin("larger", 20, 1.5, { deferredEmptyCount = 1, deferredTravel = 1 })
    local ranked = Routing.rank({ larger, nearby }, { 3, 3 }, 6)
    assert(ranked[1].key == "touched small" and ranked[1].emptyCount == 2)
    near(ranked[1].cost, 5)
    assert(ranked[2].emptyCount == 2)
    near(ranked[2].cost, 6.5)
    local withoutCleanup = Routing.rank({ nearby, bin("larger", 20, 1.5) }, { 3, 3 }, 6)
    assert(withoutCleanup[1].key == "larger", "The deferred emptying and travel must decide this choice")
    near(withoutCleanup[1].cost, 3.5)
end)

test("a larger bin still wins when future emptyings outweigh the cleanup owed elsewhere", function()
    local nearby = bin("touched small", 10, 1, { used = 9 })
    local larger = bin("larger", 50, 1.5, { deferredEmptyCount = 1, deferredTravel = 1 })
    local weights = { 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3 }
    local ranked = Routing.rank({ nearby, larger }, weights, 36)
    assert(ranked[1].key == "larger" and ranked[1].emptyCount == 2)
    near(ranked[1].cost, 6.5)
    assert(ranked[2].emptyCount == 5)
    near(ranked[2].cost, 11)
end)

test("approved existing contents add an emptying before a full bin can be filled", function()
    local ranked = Routing.rank({ bin("full", 5, 1, { used = 5 }) }, { 3, 2 }, 5)
    assert(#ranked == 1 and ranked[1].emptyCount == 2)
    near(ranked[1].cost, 5)
    local empty = Routing.rank({ bin("empty", 5, 1) }, { 3, 2 }, 5)
    assert(empty[1].emptyCount == 1)
    near(empty[1].cost, 3)
end)

test("a bin that cannot hold or accept the current item is excluded", function()
    local choices = { bin("too small", 2, 0), bin("disallowed", 8, 0, { accepts = { false } }), bin("usable", 8, 3) }
    local ranked = Routing.rank(choices, { 3 }, 3)
    assert(#ranked == 1 and ranked[1].key == "usable")
end)

test("later oversized or disallowed items remain explicit work for another bin", function()
    local ranked = Routing.rank({ bin("partial", 3, 1), bin("whole batch", 6, 2) }, { 1, 4, 1 }, 6)
    assert(ranked[1].key == "whole batch" and ranked[1].unserved == 0)
    assert(ranked[2].unserved == 1 and ranked[2].unservedPenalty > 0)
    near(ranked[1].cost, 4)
    near(ranked[2].cost, 9)
    local limited = Routing.rank({ bin("limited", 10, 1, { accepts = { true, false, true } }) }, { 1, 4, 1 }, 6)
    assert(limited[1].unserved == 1 and limited[1].reason:find("another bin", 1, true))
end)

test("zero-weight items and zero carrying weight do not divide by zero", function()
    local ranked = Routing.rank({ bin("zero", 0, 1) }, { 0, 0, 0 }, 0)
    assert(#ranked == 1 and ranked[1].trips == 1 and ranked[1].emptyCount == 1)
    near(ranked[1].cost, 3)
    assert(#Routing.rank({ bin("zero", 0, 1) }, { 1 }, 0) == 0)
end)

test("equal-cost choices have a stable key order and do not mutate input snapshots", function()
    local second, first = bin("b", 10, 1), bin("a", 10, 1)
    local choices, weights = { second, first }, { 2, 3 }
    local ranked = Routing.rank(choices, weights, 5)
    assert(ranked[1].key == "a" and ranked[2].key == "b")
    assert(choices[1] == second and choices[2] == first and second.cost == nil and weights[1] == 2)
    assert(ranked[1] ~= first and ranked[2] ~= second)
    ranked[1].cost = 999
    assert(first.cost == nil)
end)

test("invalid weights and nonfinite capacity or travel cannot select a bin", function()
    local invalid = { bin("infinite", math.huge, 1), bin("bad used", 10, 1, { used = 0 / 0 }),
        bin("bad travel", 10, -1), bin("bad acceptance", 10, 1, { accepts = { "yes" } }) }
    assert(#Routing.rank(invalid, { 1 }, 1) == 0)
    local usable = { bin("valid", 10, 1) }
    for _, weights in ipairs({ { -1 }, { 0 / 0 }, { math.huge }, { [1] = 1, [3] = 1 } }) do
        assert(#Routing.rank(usable, weights, 1) == 0)
    end
    assert(#Routing.rank(usable, { 1 }, math.huge) == 0)
end)

test("travel remains estimated until a completed directional observation is supplied", function()
    local routes = Routing.new()
    local from, destination = { x = 0, y = 0, z = 0 }, { x = 16, y = 0, z = 1 }
    local initial, provenance = routes:estimate(from, destination)
    assert(initial > 0 and provenance == "estimated")
    assert(routes:observe(from, destination, 30, 12000))
    local observed, source = routes:estimate(from, destination)
    near(observed, 12)
    assert(source == "observed")
    local reverse, reverseSource = routes:estimate(destination, from)
    assert(reverse > 0 and reverseSource == "estimated")
    assert(not routes:observe(from, destination, 0, 12000))
    assert(not routes:observe(from, destination, 30, -1))
    assert(not routes:observe(from, { x = 0 / 0, y = 0, z = 0 }, 30, 12000))
    near(routes:estimate(from, destination), 12)
end)

test("floor changes cost travel even when horizontal coordinates match", function()
    local routes = Routing.new()
    local origin = { x = 0, y = 0, z = 0 }
    local same = routes:estimate(origin, origin)
    local upstairs, source = routes:estimate(origin, { x = 0, y = 0, z = 1 })
    assert(same == 0 and upstairs > same and source == "estimated")
end)

test("the travel cache evicts old observations while retaining recent routes", function()
    local routes = Routing.new()
    for index = 1, 257 do
        assert(routes:observe({ x = index * 16, y = 0, z = 0 }, { x = index * 16 + 8, y = 0, z = 0 }, 8, 5000))
    end
    local _, oldest = routes:estimate({ x = 16, y = 0, z = 0 }, { x = 24, y = 0, z = 0 })
    local newestSeconds, newest = routes:estimate({ x = 257 * 16, y = 0, z = 0 }, { x = 257 * 16 + 8, y = 0, z = 0 })
    assert(oldest == "estimated" and newest == "observed")
    near(newestSeconds, 5)
end)

print(passed .. " routing policy cases passed (hand-worked capacity and travel snapshots)")
