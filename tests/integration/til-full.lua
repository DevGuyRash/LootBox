package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;tests/?.lua;' .. package.path
-- Til Full end to end: the real flow over a model of the game's queue, recipes
-- and server replies. Expected amounts are worked out by hand.
local Game = require 'support/game'
local Full = require 'LootBox/TillFull'
local Items = require 'LootBox/Items'

Game.liquid('Cola', 0.5)
Game.liquid('Beer', 0.5, { alcohol = true })
Game.liquid('Water', 1)
Game.script('Base.Can', { cantEat = true })
local can = Game.recipe('OpenCannedFood', { input = 'Base.Can', output = 'Base.CanOpen',
    makes = function() return { Game.item('Base.CanOpen', { food = { hunger = 0.16 } }), Game.item('Base.Nothing') } end })
local soda = Game.recipe('OpenCanOfBeverage', { input = 'Base.Pop', keeps = true, makes = function() return {} end })
local mystery = Game.recipe('OpenUnlabeledCan', { input = 'Base.MysteryCan',
    makes = function() return { Game.item('Base.CannedCornOpen', { food = { hunger = 0.2 }, modData = { NoLabel = true } }) } end })
local ration = Game.recipe('OpenWaterRationCan', { input = 'Base.WaterRationCan',
    makes = function() return { Game.item('Base.WaterRationCanEmpty', { litres = 0.3, capacity = 0.3 }) } end })

local player
local function near(a, b) return math.abs(a - b) < 0.0005 end
local function give(item) return player.main:put(item) end
local function food(hunger, base) return Game.item('Base.Food', { food = { hunger = hunger, base = base } }) end
local function closed() return Game.item('Base.Can', { food = { hunger = 0 }, openingRecipe = 'OpenCannedFood' }) end
local function start(items, kind, recipe, fields)
    local opts = { kind = kind, recipe = recipe }
    for k, v in pairs(fields or {}) do opts[k] = v end
    return assert(Full.new(player, Game.world, items, opts))
end
local function nail() give(Game.item('Base.Nails')) end

for _, mp in ipairs({ false, true }) do
    local label = mp and 'mp' or 'sp'
    local function case(name, fn)
        player = Game.reset(mp)
        local ok, err = pcall(fn)
        if not ok then error(label .. ' ' .. name .. ': ' .. tostring(err), 0) end
    end

    case('eats part of a food: hunger .1 of .25 relief leaves .15', function()
        player.hunger = 0.1
        local item = give(food(0.25))
        local job = Game.run(start({ item }, 'food'))
        assert(job.state == 'finished' and job.count == 1, job.reason)
        assert(near(player.hunger, 0) and near(player.main:getItemWithID(item.id).food.hunger, 0.15))
    end)

    case('eats a half-eaten food by its whole size', function()
        player.hunger = 0.1
        local item = give(food(0.2, 0.4))
        Game.run(start({ item }, 'food'))
        assert(near(player.main:getItemWithID(item.id).food.hunger, 0.1), 'left ' .. tostring(item.food.hunger))
    end)

    case('eats three of five: .5 hunger at .2 each', function()
        player.hunger = 0.5
        local stack = {}
        for i = 1, 5 do stack[i] = give(food(0.2)) end
        local job = Game.run(start(stack, 'food'))
        assert(job.count == 3 and near(player.hunger, 0))
        local left = 0
        for _, i in ipairs(player.main.items.values) do left = left + i.food.hunger end
        assert(near(left, 0.5), 'left ' .. left)
    end)

    case('does not overeat when needs arrive late', function()
        if not mp then return end
        player.hunger, Game.needsLate = 0.3, true
        local stack = {}
        for i = 1, 5 do stack[i] = give(food(0.15)) end
        local job = Game.run(start(stack, 'food'))
        assert(job.count == 2 and Game.consumed == 2, 'ate ' .. Game.consumed)
    end)

    case('opens and eats exactly what it opened, not a lookalike already there', function()
        player.hunger = 0.1
        local lookalike, shell = give(Game.item('Base.CanOpen', { food = { hunger = 0.16 } })), give(closed())
        local job = Game.run(start({ shell }, 'food', can))
        assert(job.state == 'finished' and job.count == 1, job.reason)
        assert(near(lookalike.food.hunger, 0.16) and player.main:getItemWithID(shell.id) == nil)
        local opened
        for _, i in ipairs(player.main.items.values) do if i.fullType == 'Base.CanOpen' and i ~= lookalike then opened = i end end
        assert(near(opened.food.hunger, 0.06))
    end)

    case('an unrelated item arriving mid-opening does not stop it', function()
        player.hunger = 0.16
        local shell = give(closed())
        Game.after(300, nail)
        local job = Game.run(start({ shell }, 'food', can))
        assert(job.state == 'finished' and near(player.hunger, 0), job.reason)
    end)

    case('another opened can arriving mid-opening is an equally good answer', function()
        player.hunger = 0.16
        local shell = give(closed())
        Game.after(300, function() give(Game.item('Base.CanOpen', { food = { hunger = 0.16 } })) end)
        local job = Game.run(start({ shell }, 'food', can))
        assert(job.state == 'finished' and near(player.hunger, 0) and Game.consumed == 1, job.reason)
    end)

    case('other carried things may come and go mid-opening', function()
        player.hunger = 0.16
        local shell, junk = give(closed()), give(Game.item('Base.Junk'))
        Game.after(300, function() player.main:take(junk) end)
        assert(Game.run(start({ shell }, 'food', can)).state == 'finished')
    end)

    case('finds the result at the player\'s feet when overloaded', function()
        player.hunger, Game.overloaded = 0.16, true
        local shell = give(closed())
        local job = Game.run(start({ shell }, 'food', can))
        assert(job.state == 'finished' and near(player.hunger, 0), job.reason)
    end)

    case('says where the result is when it cannot be picked up', function()
        player.hunger, Game.overloaded = 0.16, true
        local shell = give(closed())
        player.main.hasRoomFor = function(_, _, item) return item.fullType ~= 'Base.CanOpen' end
        local job = Game.run(start({ shell }, 'food', can))
        assert(job.state == 'cancelled' and job.reason:find('at your feet') and Game.consumed == 0, job.reason)
    end)

    case('fetches a can from a bag before opening it', function()
        player.hunger = 0.16
        local bag = Game.item('Base.Bag')
        bag.inside = Game.container('bag', { bag = bag })
        give(bag)
        local shell = bag.inside:put(closed())
        assert(Game.run(start({ shell }, 'food', can)).state == 'finished' and near(player.hunger, 0))
    end)

    case('opens a stack one at a time until full', function()
        player.hunger = 0.3
        local stack = { give(closed()), give(closed()), give(closed()) }
        local job = Game.run(start(stack, 'food', can))
        assert(job.count == 2 and near(player.hunger, 0), tostring(job.count))
        assert(player.main:getItemWithID(stack[3].id) ~= nil)
    end)

    case('recognises an unlabelled can by its stamp', function()
        player.hunger = 0.2
        local shell = give(Game.item('Base.MysteryCan', { food = { hunger = 0 } }))
        assert(Game.run(start({ shell }, 'food', mystery)).state == 'finished' and near(player.hunger, 0))
    end)

    case('opens and drinks a kept can: .1 thirst of .15 relief leaves a third', function()
        player.thirst = 0.1
        local pop = give(Game.item('Base.Pop', { litres = 0.3, capacity = 0.3, liquid = 'Cola', sealed = true }))
        local job = Game.run(start({ pop }, 'fluid', soda))
        local now = player.main:getItemWithID(pop.id)
        assert(job.state == 'finished' and near(player.thirst, 0) and near(now.fluid.amount, 0.1), tostring(job.reason))
        assert(not mp or now ~= pop, 'a server replaces the object')
    end)

    case('opens and drinks a ration whose result is a new vessel', function()
        player.thirst = 0.15
        local shell = give(Game.item('Base.WaterRationCan', { food = { hunger = 0 } }))
        local job = Game.run(start({ shell }, 'fluid', ration))
        assert(job.state == 'finished' and near(player.thirst, 0), job.reason)
    end)

    case('the game drinking the new vessel first is not a failure', function()
        player.thirst = 0.15
        local shell = give(Game.item('Base.WaterRationCan', { food = { hunger = 0 } }))
        Game.onTick = function()
            for _, i in ipairs(player.main.items.values) do
                if i.fullType == 'Base.WaterRationCanEmpty' then i.fluid.amount, i.fluid.name = 0, nil end
            end
        end
        local job = Game.run(start({ shell }, 'fluid', ration))
        assert(job.state == 'finished' and job.reason:find('as it was opened'), job.reason)
    end)

    case('refuses alcohol, unsafe food and protected items before opening', function()
        player.hunger, player.thirst = 0.5, 0.5
        local beer = give(Game.item('Base.Beer', { litres = 0.3, liquid = 'Beer' }))
        assert(Game.run(start({ beer }, 'fluid')).state == 'cancelled')
        local bad = give(food(0.2)); bad.unsafe = 'isRotten'
        assert(Game.run(start({ bad }, 'food')).state == 'cancelled')
        local kept = give(food(0.2)); kept.keep = true
        assert(Game.run(start({ kept }, 'food')).state == 'cancelled' and Game.consumed == 0)
        local favorite = give(food(0.2)); favorite.favorite = true
        assert(Game.run(start({ favorite }, 'food')).count == 1, 'an explicit choice may be a favorite')
    end)

    case('aiming stops it and leaves the player\'s own queue alone', function()
        player.hunger = 0.16
        local shell, book = give(closed()), give(Game.item('Base.Book'))
        local job = start({ shell }, 'food', can)
        local mine
        Game.after(200, function()
            mine = ISInventoryTransferAction:new(player, book, player.main, Game.container('shelf'))
            ISTimedActionQueue.add(mine)
            player.aiming = true
        end)
        Game.after(400, function() player.aiming = false end)
        Game.run(job)
        assert(job.state == 'cancelled' and job.reason:find('aimed'), job.reason)
        assert(Game.consumed == 0 and ISTimedActionQueue.getTimedActionQueue(player):indexOf(mine) ~= -1)
    end)

    case('a queued action of the player\'s waits for nothing and delays only the next step', function()
        player.hunger = 0.16
        local shell, book, shelf = give(closed()), give(Game.item('Base.Book')), Game.container('shelf')
        Game.after(200, function() ISTimedActionQueue.add(ISInventoryTransferAction:new(player, book, player.main, shelf)) end)
        assert(Game.run(start({ shell }, 'food', can)).state == 'finished')
        assert(shelf:getItemWithID(book.id) ~= nil and near(player.hunger, 0))
    end)

    case('cancel stops before anything is eaten', function()
        player.hunger = 0.16
        local shell = give(closed())
        local job = start({ shell }, 'food', can)
        Game.after(300, function() job:cancel() end)
        Game.run(job)
        assert(job.state == 'cancelled' and Game.consumed == 0)
    end)

    case('a rejected opening says so and eats nothing', function()
        if not mp then return end
        player.hunger = 0.16
        local shell = give(closed())
        Game.reject = function() return true end
        local job = Game.run(start({ shell }, 'food', can))
        assert(job.state == 'cancelled' and Game.consumed == 0 and player.main:getItemWithID(shell.id), job.reason)
    end)

    case('reports an opening that produced nothing', function()
        player.hunger = 0.16
        local shell = give(Game.item('Base.Dud', { food = { hunger = 0 } }))
        local dud = Game.recipe('Dud', { input = 'Base.Dud', output = 'Base.DudOpen', makes = function() return {} end })
        local job = Game.run(start({ shell }, 'food', dud))
        assert(job.state == 'failed' and job.reason:find('not within reach'), job.reason)
    end)

    case('a shelf item out of reach is refused', function()
        player.hunger = 0.3
        local shelf = Game.container('shelf')
        local item = shelf:put(food(0.2))
        Game.unreachable = true
        local job = Game.run(start({ item }, 'food', nil, { source = shelf }))
        assert(job.state == 'cancelled' and job.reason:find('reach'), job.reason)
    end)

    case('background intake opens, eats and yields to the player', function()
        player.hunger = 0.16
        local shell, tool = give(closed()), give(Game.item('Base.TinOpener', { opener = true }))
        shell.sealed = true
        local Opening = require 'LootBox/Opening'
        local plan = assert(Opening.automatic(player, shell, false, function() return true end))
        assert(plan.tool == tool)
        local permitted = true
        local automatic = { plan = plan, guard = function() return permitted end }
        local job = Game.run(start({ shell }, 'food', nil, { automatic = automatic }))
        assert(job.state == 'finished' and near(player.hunger, 0), job.reason)
        player.hunger = 0.3
        local snack = give(food(0.2))
        job = start({ snack }, 'food', nil, { automatic = { guard = function() return permitted end } })
        Game.after(200, function() ISTimedActionQueue.add(ISInventoryTransferAction:new(player, tool, player.main, Game.container('x'))) end)
        Game.run(job)
        assert(job.state == 'cancelled' and job.reason:find('something else'), job.reason)
    end)

    case('offers nothing when it would do nothing', function()
        local snack = give(food(0.2))
        assert(Full.offers(player, Game.world, { snack }, { kind = 'food' }) == false)
        player.hunger = 0.1
        assert(Full.offers(player, Game.world, { snack }, { kind = 'food' }) == true)
        assert(Full.offers(player, Game.world, { give(closed()) }, { kind = 'food', recipe = can }) == true)
    end)
end

-- The locator itself, where the flows above do not reach.
player = Game.reset(true)
local bag = Game.item('Base.Bag')
bag.inside = Game.container('bag', { bag = bag })
player.main:put(bag)
local deep = bag.inside:put(Game.item('Base.X'))
local found, holder, place = Items.find(player, deep.id)
assert(found == deep and holder == bag.inside and place == 'carried')
local twin = Game.replica(deep)
assert(Items.unique(player, deep))
player.main.items:add(twin); twin.container = player.main
assert(not Items.unique(player, deep))
player.main:take(twin)
local laid = Game.lay(Game.item('Base.Y'), Game.square(11, 10))
found, holder, place = Items.find(player, laid.id)
assert(found == laid and holder == nil and place == 'ground')
assert(Items.find(player, 999999) == nil)
bag.inside:put(bag) -- a bag inside itself must not hang the search
assert(Items.find(player, 999999) == nil)

-- Of several new matches: the best fit, then the main inventory, then the floor.
player = Game.reset(false)
local old = player.main:put(Game.item('Base.Jug', { litres = 5, capacity = 20 }))
local watch = Items.watch(player, { makes = function(item)
    return item.fullType == 'Base.Jug' and -math.abs(item.fluid.amount - 6) end })
assert(watch:find() == nil, 'what was there before is never the result')
local ground = Game.lay(Game.item('Base.Jug', { litres = 6, capacity = 20 }), Game.square(10, 10))
assert(watch:find() == ground)
local carried = player.main:put(Game.item('Base.Jug', { litres = 6, capacity = 20 }))
local better = player.main:put(Game.item('Base.Jug', { litres = 2, capacity = 20 }))
assert(watch:find() == carried and better and old)
print('til-full tests passed')
