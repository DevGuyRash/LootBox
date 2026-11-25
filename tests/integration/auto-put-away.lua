-- Automatic put-away: what it counts as brought home, when it starts and what ends it.
-- The player, the job runner and the world's answers are doubles.
if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end
package.loaded["TimedActions/ISTimedActionQueue"] = true
next = nil -- Kahlua has none

local f
function getTimestampMs() return f.now end
function getCore() return {isDoingTextEntry = function() return f.typing == true end} end
function getPlayerContextMenu() return {isAnyVisible = function() return f.menu == true end} end
function getCell() return {getDrag = function() return f.building and {} or nil end} end
function isMouseButtonDown() return f.mouse == true end
function getPlayerLoot() return {backpacks = f.backpacks} end
package.loaded["LootBox/Log"] = {trace = function() end, info = function() end, point = function() end, intent = function() return 1 end,
    guard = function(_, run, ...) return run(...) end}
package.loaded["LootBox/Act"] = {idle = function() return not f.acting end, blocked = function() return f.blocked end}
local Auto = require "LootBox/AutoPutAway"
ISEntityUI = {players = {[0] = {windows = {HandcraftWindow = {instance = {isReallyVisible = function() return f.crafting == true end}}, BuildWindow = {}}}}}
Auto.windows = function() return f.window == true end

local function list(values) return {size = function() return #values end, get = function(_, index) return values[index + 1] end} end
local function container(items, vehicle)
    return {getItems = function() return list(items) end, getVehiclePart = function() return vehicle end}
end
local function item(id) return {id = id, getID = function(self) return self.id end} end

local function fixture()
    f = {now = 100000, carried = {item(1), item(2)}, near = true, zombies = 0, backpacks = {}, starts = {}, places = {}, saved = 0}
    local stats = {getNumVisibleZombies = function() return f.zombies end, getNumChasingZombies = function() return 0 end, getNumVeryCloseZombies = function() return 0 end}
    f.who = "Ann Lee"
    f.player = {getPlayerNum = function() return 0 end, getStats = function() return stats end, getVehicle = function() return f.vehicle end,
        getInventory = function() return container(f.carried) end, pressedMovement = function() return f.moving == true end,
        isSitOnGround = function() return false end, isSittingOnFurniture = function() return f.sitting == true end,
        getCurrentSquare = function() return {} end,
        getDescriptor = function() return {getForename = function() return f.who end, getSurname = function() return "" end} end}
    f.runner = {job = {hasJob = false, canStart = true}}
    function f.runner:status() return self.job end
    function f.runner:cancel() f.cancelled = (f.cancelled or 0) + 1; self.job = {hasJob = false, canStart = true}; return true end
    f.app = {player = f.player, state = {}, jobs = f.runner, recovery = {status = function() return {} end}, world = {HOME_RANGE = 20,
        atHome = function(_, range) f.range = range; return f.near and {} or nil end, nearHere = function() return {} end,
        putAway = function(_, fixed, only) assert(fixed == true, "Only storage that stays where it is") assert(only, "Room is kept for what may move")
            local result = {}
            for _, value in ipairs(f.carried) do if f.places[value.id] ~= false and only[tostring(value.id)] then result[#result + 1] = {item = value} end end
            return result
        end}}
    function f.app:persist() f.saved = f.saved + 1 end
    function f.app:preview(request) f.request = request; return {moves = f.noMoves and {} or {1}, skipped = {}} end
    function f.app:start(_, options)
        f.starts[#f.starts + 1] = f.request.only
        f.options = options
        f.runner.job = {hasJob = true, canPause = true}
        return true
    end
    return f
end
local function wait(ms)
    for _ = 1, math.floor(ms / 100) do f.now = f.now + 100; Auto.update(f.app, f.now) end
end
local function trip(...)
    wait(1200)
    f.near = false
    wait(1200)
    for _, id in ipairs({...}) do f.carried[#f.carried + 1] = item(id) end
    f.near = true
end
local passed = 0
local function test(name, run) fixture(); run(); passed = passed + 1; print("PASS " .. name) end

test("only what was not carried when leaving is put away, after standing still", function()
    trip(7, 8)
    wait(1200)
    assert(#f.starts == 0, "It waits until the player has stood still")
    wait(4000)
    assert(#f.starts == 1 and f.starts[1]["7"] and f.starts[1]["8"] and not f.starts[1]["1"] and not f.starts[1]["2"])
    assert(f.options.automatic and f.request.destination.kind == "labels" and f.request.destination.near)
end)

test("without a known departure nothing is touched", function()
    f.near = false
    wait(1200)
    f.carried[3] = item(9)
    f.near = true
    wait(6000)
    assert(#f.starts == 0)
end)

test("what left with the player is remembered across a restart", function()
    trip(7)
    local saved = f.app.state
    assert(saved.trip.had["1"] and not saved.trip.had["7"])
    f.app.homecoming = nil
    wait(6000)
    assert(#f.starts == 1 and f.starts[1]["7"] and saved.trip == nil)
end)

test("a new character does not inherit the last one's trip", function()
    trip(7)
    f.who = "Bob Roe"
    wait(6000)
    assert(#f.starts == 0 and f.app.state.trip == nil)
end)

test("standing on the edge of home is not coming and going", function()
    wait(1200)
    assert(f.range == 25)
    f.near = false
    wait(1200)
    assert(f.range == 25 or f.range == 15)
    wait(1200)
    assert(f.range == 15)
end)

local function car(...)
    local trunk = {}
    for _, id in ipairs({...}) do trunk[#trunk + 1] = item(id) end
    local parts = {container(trunk), nil}
    return {trunk = trunk, getPartCount = function() return 2 end, getPartByIndex = function(_, index)
        return {getItemContainer = function() return parts[index + 1] end} end}
end

for _, reason in ipairs({"moving", "typing", "menu", "mouse", "sitting", "vehicle", "blocked", "acting", "building", "window", "crafting"}) do
    test("it does not start while the player is busy: " .. reason, function()
        trip(7)
        f[reason] = reason == "vehicle" and car() or true
        wait(8000)
        assert(#f.starts == 0)
        f[reason] = nil
        wait(5000)
        assert(#f.starts == 1)
    end)
end

test("it waits for zombies to be gone", function()
    trip(7)
    f.zombies = 1
    wait(8000)
    assert(#f.starts == 0)
    f.zombies = 0
    wait(5000)
    assert(#f.starts == 1)
end)

for _, reason in ipairs({"moving", "menu", "blocked", "building", "window", "typing"}) do
    test("it stops for good the moment the player acts: " .. reason, function()
        trip(7)
        wait(5000)
        assert(#f.starts == 1)
        f[reason] = true
        wait(100)
        assert(f.cancelled == 1)
        f[reason] = nil
        wait(20000)
        assert(#f.starts == 1)
    end)
end

test("a click reaches the Stop button, which ends it", function()
    trip(7)
    wait(5000)
    f.mouse = true
    wait(300)
    assert(not f.cancelled)
    f.runner.job = {hasJob = false, canStart = true}
    f.mouse = nil
    wait(20000)
    assert(#f.starts == 1)
end)

test("danger puts it off until it has passed", function()
    trip(7)
    wait(5000)
    f.zombies = 1
    wait(100)
    assert(f.cancelled == 1)
    f.zombies = 0
    wait(2000)
    assert(#f.starts == 1)
    wait(3000)
    assert(#f.starts == 2 and f.starts[2]["7"])
end)

test("turned off and on again, what was noted before counts for nothing", function()
    trip(7)
    Auto.forget(f.app)
    assert(f.app.state.trip == nil)
    wait(8000)
    assert(#f.starts == 0)
end)

test("it stops when the player queues something of their own", function()
    trip(7)
    wait(5000)
    f.runner.job.waiting = "Waiting for your current action"
    wait(100)
    assert(f.cancelled == 1)
end)

test("a finished or stopped put-away is not repeated", function()
    trip(7)
    wait(5000)
    f.runner.job = {hasJob = false, canStart = true}
    wait(10000)
    assert(#f.starts == 1)
end)

test("one that cannot go on is dropped rather than left paused", function()
    trip(7)
    wait(5000)
    f.runner.job = {hasJob = true, canResume = true, reason = "Destination full"}
    wait(10000)
    assert(f.cancelled == 1 and #f.starts == 1)
end)

test("anything the player asks for takes its place", function()
    trip(7)
    wait(5000)
    Auto.yield(f.app)
    assert(f.cancelled == 1)
    Auto.yield(f.app)
    wait(20000)
    assert(f.cancelled == 1 and #f.starts == 1)
end)

test("it never interrupts a job, a drink or gear waiting to be fetched", function()
    for _, block in ipairs({function() f.runner.job = {hasJob = true, canStart = true} end, function() f.app.borrowed = {} end,
        function() f.app.consumption = {isBusy = function() return true end} end,
        function() f.app.recovery = {status = function() return {pending = true} end} end}) do
        fixture()
        trip(7)
        block()
        wait(8000)
        assert(#f.starts == 0)
    end
end)

test("things without a place are left alone", function()
    trip(7, 8)
    f.places[8] = false
    wait(5000)
    assert(f.starts[1]["7"] and not f.starts[1]["8"])
end)

test("what came home in the vehicle counts once it is taken out, and what left in it does not", function()
    local truck = car(20)
    f.vehicle = truck
    wait(1200)
    f.vehicle = nil
    wait(1200)
    f.vehicle = truck
    wait(1200)
    f.near = false
    wait(1200)
    truck.trunk[2] = item(21)
    f.near = true
    wait(3000)
    f.vehicle = nil
    wait(6000)
    assert(#f.starts == 0, "It is still in the truck")
    f.carried[3], f.carried[4] = item(20), item(21)
    wait(6000)
    assert(#f.starts == 1 and f.starts[1]["21"] and not f.starts[1]["20"])
end)

test("stopped by the player, what is still in the vehicle no longer counts", function()
    local truck = car(20, 21)
    wait(1200)
    f.vehicle = truck
    f.near = false
    wait(1200)
    truck.trunk[1], truck.trunk[2] = item(30), item(31)
    f.near = true
    wait(1200)
    f.vehicle = nil
    f.carried[3] = item(30)
    wait(5000)
    assert(#f.starts == 1)
    f.moving = true
    wait(100)
    f.moving = nil
    f.carried[4] = item(31)
    wait(10000)
    assert(#f.starts == 1)
end)

test("loot picked up right after driving off is not taken for what left home", function()
    wait(1200)
    f.vehicle = car()
    f.near = false
    wait(1200)
    f.vehicle = nil
    f.carried[3] = item(7)
    wait(1200)
    f.near = true
    wait(6000)
    assert(#f.starts == 1 and f.starts[1]["7"])
end)

test("a car left parked at home brings nothing home", function()
    local parked = car(20)
    f.vehicle = parked
    wait(1200)
    f.vehicle = nil
    wait(1200)
    trip(7)
    wait(5000)
    f.runner.job = {hasJob = false, canStart = true}
    f.carried[#f.carried + 1] = item(20)
    wait(8000)
    assert(#f.starts == 1 and not f.starts[1]["20"])
end)

test("a vehicle that never left is no trip", function()
    f.vehicle = car(20)
    wait(1200)
    f.vehicle = nil
    wait(1200)
    f.carried[3] = item(20)
    wait(6000)
    assert(#f.starts == 0)
end)

print(passed .. " automatic put-away cases passed")
