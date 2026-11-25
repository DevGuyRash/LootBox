package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local Routing = require "LootBox/Routing"
local passed = 0
local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

local function near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001, tostring(actual) .. " differs from " .. tostring(expected))
end

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

print(passed .. " travel estimate cases passed")
