package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;tests/?.lua;' .. package.path
-- Pouring between vessels and with fixtures, end to end. Litres by hand.
local Game = require 'support/game'
ISInventoryPage = { GetFloorContainer = function() return Game.floor end }
ISWorldObjectContextMenu.getMoveableDisplayName = function() return 'Sink' end
Fluid = { Water = Game.liquid('Water', 1), TaintedWater = 'TaintedWater' }
Game.liquid('Cola', 0.5)
local Pour = require 'LootBox/Pour'
local Fixture = require 'LootBox/Fixture'
local Inventory = require 'LootBox/PourInventory'
function instanceof_(o) return o end

local player, shelf
local function near(a, b) return math.abs(a - b) < 0.03 end
local function vessel(litres, capacity, name) return Game.item('Base.Vessel', { litres = litres, capacity = capacity or 1, liquid = name }) end
local function give(item) return player.main:put(item) end
local function entry(item, holder)
    local snapshot = Inventory.snapshot(player, Game.world, holder or player.main, holder)
    for _, e in ipairs(snapshot.entries) do
        if e.item == item then e.pourSignature = e.amount > 0 and Inventory.mix(e) or nil; return e end
    end
    error('the vessel is not offered')
end
local function pour(source, targets) return assert(Pour.new(player, Game.world, source, targets)) end
local function now(item, holder) return (holder or player.main):getItemWithID(item.id) end

for _, mp in ipairs({ false, true }) do
    local function case(name, fn)
        player = Game.reset(mp)
        shelf = Game.container('shelf')
        local ok, err = pcall(fn)
        if not ok then error((mp and 'mp ' or 'sp ') .. name .. ': ' .. tostring(err), 0) end
    end

    case('pours .8 of 1 into .5 of room', function()
        local a, b = give(vessel(0.8)), give(vessel(0.5))
        local job = Game.run(pour(entry(a), { entry(b) }))
        assert(job.state == 'finished' and near(a.fluid.amount, 0.3) and near(b.fluid.amount, 1), job.reason)
        assert(near(job.liters, 0.5))
    end)

    case('a pour that empties its source is still a pour', function()
        local a, b = give(vessel(0.3)), give(vessel(0, 2))
        local job = Game.run(pour(entry(a), { entry(b) }))
        assert(job.state == 'finished' and job.count == 1 and near(b.fluid.amount, 0.3), job.reason)
    end)

    case('fills in the given order and stops when empty', function()
        local a, b, c, d = give(vessel(1.5, 2)), give(vessel(0)), give(vessel(0)), give(vessel(0))
        local job = Game.run(pour(entry(a), { entry(b), entry(c), entry(d) }))
        assert(job.state == 'finished' and job.count == 2, job.reason)
        assert(near(b.fluid.amount, 1) and near(c.fluid.amount, 0.5) and near(d.fluid.amount, 0))
    end)

    case('fetches a shelf vessel, fills it and puts it back', function()
        local a, b = give(vessel(1)), shelf:put(vessel(0))
        local job = Game.run(pour(entry(a), { entry(b, shelf) }))
        local back = now(b, shelf)
        assert(job.state == 'finished' and back and near(back.fluid.amount, 1) and not now(b), job.reason)
    end)

    case('pours from a shelf vessel and returns what is left', function()
        local a, b = shelf:put(vessel(1)), give(vessel(0.6))
        local job = Game.run(pour(entry(a, shelf), { entry(b) }))
        assert(job.state == 'finished' and near(now(a, shelf).fluid.amount, 0.6) and near(b.fluid.amount, 1), job.reason)
    end)

    case('an item arriving mid-fetch changes nothing', function()
        local a, b = give(vessel(1)), shelf:put(vessel(0))
        Game.after(200, function() give(Game.item('Base.Nails')) end)
        assert(Game.run(pour(entry(a), { entry(b, shelf) })).state == 'finished' and near(now(b, shelf).fluid.amount, 1))
    end)

    case('puts everything back when a pour fails', function()
        local a, b = shelf:put(vessel(1)), shelf:put(vessel(0))
        Game.pourFails = true
        local job = Game.run(pour(entry(a, shelf), { entry(b, shelf) }))
        assert(job.state == 'cancelled' and now(a, shelf) and now(b, shelf) and not now(a) and not now(b), job.reason)
    end)

    case('stopping says which vessel is still carried', function()
        local a, b = give(vessel(1)), shelf:put(vessel(0))
        local job = pour(entry(a), { entry(b, shelf) })
        Game.onTick = function() if now(b) then job:cancel() end end
        Game.run(job)
        assert(job.state == 'cancelled' and job.reason:find('In your inventory: Base.Vessel'), job.reason)
    end)

    case('stops when the liquid is no longer what was chosen', function()
        local a, b = give(vessel(1)), give(vessel(0))
        local job = pour(entry(a), { entry(b) })
        a.fluid.name = 'Cola'
        Game.run(job)
        assert(job.state == 'cancelled' and job.reason:find('liquid changed') and near(b.fluid.amount, 0), job.reason)
    end)

    case('follows a vessel moved to another bag', function()
        local bag = Game.item('Base.Bag')
        bag.inside = Game.container('bag', { bag = bag })
        give(bag)
        local a, b = give(vessel(1)), give(vessel(0))
        local job = pour(entry(a), { entry(b) })
        bag.inside:put(b)
        assert(Game.run(job).state == 'finished' and near(b.fluid.amount, 1), job.reason)
    end)

    case('a vessel set on the ground goes back to the same spot', function()
        getPlayerLoot():refreshBackpacks()
        local a, b = give(vessel(1)), Game.lay(vessel(0), Game.square(11, 10), { 0.3, 0.7, 0 })
        local job = Game.run(pour(entry(a), { entry(b, Game.floor) }))
        local w = Game.square(11, 10).ground:get(0)
        assert(job.state == 'finished' and w and w.item.id == b.id and near(w.item.fluid.amount, 1), job.reason)
        assert(w.pose[1] == 0.3 and w.pose[2] == 0.7)
    end)

    case('a batch never mixes into a vessel someone filled meanwhile', function()
        local a, b, c = give(vessel(2, 2)), give(vessel(0)), give(vessel(0))
        local job = pour(entry(a), { entry(b), entry(c) })
        Game.after(300, function() c.fluid.amount, c.fluid.name = 0.5, 'Cola' end)
        Game.run(job)
        assert(job.state == 'cancelled' and job.count == 1 and near(c.fluid.amount, 0.5), job.reason)
    end)

    case('a pour that moves nothing is not a success, however small', function()
        local a, b = give(vessel(0.01)), give(vessel(0))
        Game.pourFails = true
        local job = Game.run(pour(entry(a), { entry(b) }))
        assert(job.state == 'cancelled' and job.count == 0, job.reason)
    end)

    case('a vessel that could not be put back is named', function()
        local a, b = give(vessel(1)), shelf:put(vessel(0))
        local put = shelf.put
        shelf.put = function(self, i) if now(i) == nil and job_started then return player.main:put(i) end return put(self, i) end
        local job = pour(entry(a), { entry(b, shelf) })
        job_started = true
        Game.run(job)
        job_started = nil
        assert(job.state == 'cancelled' and job.reason:find('In your inventory'), job.reason)
    end)

    case('a refusal before anything starts is said aloud', function()
        local said
        HaloTextHelper = { addBadText = function(_, text) said = text end }
        local a, b = give(vessel(1)), give(vessel(0))
        local target = entry(b)
        player.main:take(b)
        local job = Game.run(pour(entry(a), { target }))
        HaloTextHelper = nil
        assert(job.state == 'cancelled' and said and said:find('gone'), tostring(said))
    end)

    case('keep and favorite vessels are not fetched', function()
        local a, b = give(vessel(1)), shelf:put(vessel(0))
        local target = entry(b, shelf)
        b.keep = true
        local job = Game.run(pour(entry(a), { target }))
        assert(job.state == 'cancelled' and job.reason:find('Protected') and now(b, shelf), job.reason)
    end)

    local function fixture(litres)
        local object = Game.fixture(Game.square(11, 10), litres)
        Game.square(11, 10).objects:add(object)
        return { object = object, square = object.square, primary = object:getPrimaryFluid(), tainted = false, name = 'Sink', capacity = 100 }
    end
    local function fill(anchor, entries) return assert(Fixture.new(player, Game.world, anchor, true, entries)) end

    case('fills vessels from a fixture: 1 and .6 of 100', function()
        local anchor, a, b = fixture(50), give(vessel(0)), give(vessel(0.4))
        local job = Game.run(fill(anchor, { entry(a), entry(b) }))
        assert(job.state == 'finished' and job.count == 2 and near(a.fluid.amount, 1) and near(b.fluid.amount, 1), job.reason)
        assert(near(anchor.object.litres, 48.4))
    end)

    case('stops well when the fixture runs dry', function()
        local anchor, a, b = fixture(1), give(vessel(0)), give(vessel(0))
        local job = Game.run(fill(anchor, { entry(a), entry(b) }))
        assert(job.state == 'finished' and job.count == 1 and near(b.fluid.amount, 0), job.reason)
    end)

    case('fills a bagged vessel and finds it again', function()
        local bag = Game.item('Base.Bag')
        bag.inside = Game.container('bag', { bag = bag })
        give(bag)
        local anchor, a = fixture(50), bag.inside:put(vessel(0))
        local job = Game.run(fill(anchor, { entry(a) }))
        assert(job.state == 'finished' and near(now(a, bag.inside).fluid.amount, 1), job.reason)
    end)

    case('fills a shelf vessel and returns it', function()
        local anchor, a = fixture(50), shelf:put(vessel(0))
        local job = Game.run(fill(anchor, { entry(a, shelf) }))
        assert(job.state == 'finished' and near(now(a, shelf).fluid.amount, 1), job.reason)
    end)

    case('pours a vessel into a fixture', function()
        local anchor, a = fixture(10), give(vessel(1))
        local job = Game.run(assert(Fixture.new(player, Game.world, anchor, false, { entry(a) })))
        assert(job.state == 'finished' and near(a.fluid.amount, 0) and near(anchor.object.litres, 11), job.reason)
    end)
end
print('pouring tests passed')
