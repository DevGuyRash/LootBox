package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;tests/?.lua;' .. package.path
-- Refilling a water dispenser end to end. Litres are worked out by hand.
local Game = require 'support/game'
local Dispenser = require 'LootBox/Dispenser'
local Inventory = require 'LootBox/PourInventory'
Game.liquid('Water', 1); Game.liquid('Bleach')

local player, square
local function near(a, b) return math.abs(a - b) < 0.03 end
local function give(item) return player.main:put(item) end
local function bucket(litres, name) return give(Game.item('Base.Bucket', { litres = litres, capacity = 10, liquid = name })) end
local function bottles()
    local out = {}
    for _, i in ipairs(player.main.items.values) do if i.fullType == 'Base.WaterDispenserBottle' then out[#out + 1] = i end end
    return out
end
local function stand()
    for _, o in ipairs(square.objects.values) do return o, o.fluid and o.fluid.amount end
end
local function start(object, items, bottle)
    local anchor = assert(Dispenser.capture(player, { object }))
    local snapshot = Inventory.snapshot(player, Game.world)
    local targets = Dispenser.destinations(player, Game.world, anchor, snapshot)
    local target = targets[1]
    for _, t in ipairs(targets) do if bottle and t.id == bottle.id then target = t end end
    local donors = {}
    for _, item in ipairs(items) do
        for _, e in ipairs(snapshot.entries) do
            if e.item == item then
                assert(Dispenser.canFill(e, target), 'the menu would not offer this source')
                e.pourSignature = Inventory.mix(e)
                donors[#donors + 1] = e
            end
        end
    end
    return assert(Dispenser.new(player, Game.world, anchor, donors, target))
end

for _, mp in ipairs({ false, true }) do
    local function case(name, fn)
        player = Game.reset(mp)
        square = Game.square(11, 10)
        local ok, err = pcall(fn)
        if not ok then error((mp and 'mp ' or 'sp ') .. name .. ': ' .. tostring(err), 0) end
    end

    case('takes, fills and fits: 6 + 4 = 10', function()
        local source = bucket(4)
        local job = Game.run(start(Game.dispenser(square, 6), { source }))
        local object, litres = stand()
        assert(job.state == 'finished' and near(litres, 10) and object.fluid.locked ~= false, job.reason)
        assert(#bottles() == 0 and near(source.fluid.amount, 0) and near(job.liters, 4))
    end)

    case('keeps the very bottle it took when a twin is already carried', function()
        local twin = give(Game.bottle(6))
        local job = Game.run(start(Game.dispenser(square, 6), { bucket(4) }))
        assert(job.state == 'finished' and near(select(2, stand()), 10), job.reason)
        assert(#bottles() == 1 and bottles()[1].id == twin.id and near(twin.fluid.amount, 6))
    end)

    case('picks the best match when another bottle arrives mid-take', function()
        Game.after(200, function() give(Game.bottle(1)) end)
        local job = Game.run(start(Game.dispenser(square, 6), { bucket(4) }))
        assert(job.state == 'finished' and near(select(2, stand()), 10), job.reason)
        assert(#bottles() == 1 and near(bottles()[1].fluid.amount, 1))
    end)

    case('unrelated items and stands do not stop it', function()
        Game.after(200, function() give(Game.item('Base.Nails')) end)
        Game.dispenser(Game.square(9, 10), 3)
        local job = Game.run(start(Game.dispenser(square, 6, 'E'), { bucket(4) }))
        assert(job.state == 'finished' and near(select(2, stand()), 10), job.reason)
    end)

    case('several sources, until full: 17 + 1 + .9 of 3', function()
        local a, b = bucket(1), bucket(3)
        local job = Game.run(start(Game.dispenser(square, 17), { a, b }))
        assert(job.state == 'finished' and job.count == 2 and near(select(2, stand()), 18.9), job.reason)
        assert(near(a.fluid.amount, 0) and near(b.fluid.amount, 2.1), b.fluid.amount)
    end)

    case('an empty mounted bottle works', function()
        local job = Game.run(start(Game.dispenser(square, 0), { bucket(5) }))
        assert(job.state == 'finished' and near(select(2, stand()), 5), job.reason)
    end)

    case('skips a source that changed and still fits the bottle', function()
        local a, b = bucket(2), bucket(3)
        local job = start(Game.dispenser(square, 6), { a, b })
        Game.after(100, function() a.fluid.amount, a.fluid.name = 0, nil end)
        Game.run(job)
        assert(job.state == 'finished' and job.count == 1 and job.skipped == 1 and near(select(2, stand()), 9), job.reason)
    end)

    case('puts the bottle back when nothing could be poured', function()
        local source = bucket(4)
        local job = start(Game.dispenser(square, 6), { source })
        Game.after(100, function() source.fluid.name = 'Bleach' end)
        Game.run(job)
        assert(job.state == 'cancelled' and near(select(2, stand()), 6) and #bottles() == 0, job.reason)
    end)

    case('puts the bottle back when the pour fails', function()
        Game.pourFails = true
        local job = Game.run(start(Game.dispenser(square, 6), { bucket(4) }))
        assert(job.state == 'cancelled' and near(select(2, stand()), 6) and job.reason:find('back on its stand'), job.reason)
    end)

    case('stopping mid-way says where the bottle is', function()
        local job = start(Game.dispenser(square, 6), { bucket(4) })
        Game.onTick = function() if #bottles() == 1 then job:cancel(false, 'Cancelled') end end
        Game.run(job)
        assert(job.state == 'cancelled' and job.reason:find('in your inventory') and #bottles() == 1, job.reason)
    end)

    case('a removed stand leaves the bottle with the player', function()
        local job = start(Game.dispenser(square, 6), { bucket(4) })
        Game.onTick = function() if #bottles() == 1 then square.objects.values = {} end end
        Game.run(job)
        assert(job.state == 'failed' and job.reason:find('in your inventory'), job.reason)
    end)

    case('a stand taken by someone else is never touched', function()
        local object = Game.dispenser(square, 6)
        local job = start(object, { bucket(4) })
        square.objects.values = {}
        Game.run(job)
        assert(job.state == 'cancelled' and #bottles() == 0, job.reason)
    end)

    case('a rejected take changes nothing', function()
        if not mp then return end
        Game.reject = function() return true end
        local job = Game.run(start(Game.dispenser(square, 6), { bucket(4) }))
        assert(job.state == 'cancelled' and #bottles() == 0 and near(select(2, stand()), 6), job.reason)
    end)

    case('a bare stand gets the chosen loose bottle, filled', function()
        local other, chosen = give(Game.bottle(2)), give(Game.bottle(3))
        local job = Game.run(start(Game.dispenser(square, nil), { bucket(4) }, chosen))
        assert(job.state == 'finished' and near(select(2, stand()), 7), job.reason)
        assert(#bottles() == 1 and bottles()[1].id == other.id)
    end)
end

player = Game.reset(false)
square = Game.square(11, 10)
local object = Game.dispenser(square, 18.9)
local anchor = Dispenser.capture(player, { object })
assert(#Dispenser.destinations(player, Game.world, anchor) == 0, 'a full bottle offers nothing')
assert(Dispenser.capture(player, { object, Game.dispenser(Game.square(9, 10), 1) }) == nil, 'two dispensers are not one choice')
assert(Dispenser.capture(player, {}) == nil)
print('dispenser tests passed')
