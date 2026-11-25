-- The stock steps on one vessel: fetch it from a shelf or the ground, pour into
-- another, put it back. Each finds the vessel again by id afterwards, because a
-- multiplayer move or sync may have replaced the object.
local Items = require "LootBox/Items"
local Log = require "LootBox/Log"
require "TimedActions/ISInventoryTransferUtil"

local Vessels = {}
-- Litres are Java floats that a pour rounds every frame.
Vessels.TOLERANCE = 0.02

local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end

-- What a pour of have into free moves, rounded as the game rounds it.
function Vessels.amount(have, free, wanted)
    if not finite(have) or not finite(free) then return nil end
    local most = math.min(have, free, wanted or math.huge)
    local rounded = FluidUtil.roundTransfer(most)
    local amount = finite(rounded) and math.min(most, rounded) or 0
    return amount > 0 and amount or nil
end

-- The liquid of a vessel, carried or standing on the ground.
function Vessels.fluid(item)
    local ground = item.getWorldItem and item:getWorldItem()
    local standing = ground and ground:getItem() == item and ground:getFluidContainer()
    if standing and standing:getOwner() == ground then return standing end
    return item:getFluidContainer()
end

-- The game cannot pour out of, or into, a vessel that is not carried, except
-- one that stands on the ground with its own liquid.
local function pourable(item)
    local fluid = item and Vessels.fluid(item)
    return fluid and fluid:canPlayerEmpty() and fluid or nil
end

local function reading(flow, id, containers)
    local item = Items.find(flow.player, id, containers)
    local fluid = item and Vessels.fluid(item)
    return fluid and fluid:getAmount(), item
end

-- Pours source into target. done(litres), or failed(why) with nothing moved.
function Vessels.pour(flow, source, target, opts)
    local a, b = pourable(source), pourable(target)
    if not a or not b or not FluidContainer.CanTransfer(a, b) then return opts.failed("The game does not allow pouring between these") end
    local amount = Vessels.amount(a:getAmount(), b:getFreeCapacity(), opts.litres)
    if not amount then return opts.failed("There is nothing to pour or no room for it") end
    local id, before = target:getID(), b:getAmount()
    local function gained()
        local now = reading(flow, id, opts.containers)
        return now and now - before or 0
    end
    Log.trace(flow.interaction, "POUR", "litres", string.format("%.3f", amount), "from", Log.item(source, flow.player),
        "into", Log.item(target, flow.player))
    local enough = amount - math.max(Vessels.TOLERANCE, amount * 0.02)
    local function full()
        local litres = gained()
        if litres >= enough then return litres end
    end
    local function settled(litres)
        flow.liters = flow.liters + litres
        return opts.done(litres)
    end
    -- What arrived counts, however the action ended.
    local function ended(why)
        return function()
            local litres = gained()
            if litres > 0 and not why then return settled(litres) end
            flow.liters = flow.liters + math.max(0, litres)
            return opts.failed(why or "The game did not confirm the pour")
        end
    end
    flow:act({ op = "pour", allow = opts.allow, limitMs = 300000, begin = function()
        require "Fluids/ISFluidTransferAction"
        local from, to = ISFluidContainer:new(a), ISFluidContainer:new(b)
        local action = ISFluidTransferAction:new(flow.player, from, from:getFluidObject(), to, to:getFluidObject(), amount)
        -- Emptying its source makes the game stop a pour just before it is done.
        local valid = action.isValid
        action.isValid = function(pouring) return pouring:isStarted() or valid(pouring) end
        ISTimedActionQueue.add(action)
    end }, function() flow:await(full, settled, ended()) end, function(why) flow:await(full, settled, ended(why), 1500) end)
end

-- Where a vessel on the ground stands, so it can be put back the same way; nil
-- when the game could not reproduce it.
function Vessels.spot(player, item)
    local object = item.getWorldItem and item:getWorldItem()
    local square = object and object:getSquare()
    if not square or object:getItem() ~= item or object:isExtendedPlacement() or Items.equipped(player, item) then return nil end
    local x, y, z = object:getOffX(), object:getOffY(), object:getOffZ()
    if not finite(x) or not finite(y) or x <= 0 or x >= 1 or y <= 0 or y >= 1 or not finite(z) or math.abs(z) > 0.00002
        or square:getTotalWeightOfItemsOnFloor() >= 50 then return nil end
    return { square = square, x = x, y = y, z = z, rotation = item:getWorldZRotation() }
end

-- Brings loan.item to the main inventory. done(item) with the object it now is.
function Vessels.fetch(flow, loan, done, failed)
    local main = flow.player:getInventory()
    flow:act({ op = "fetch", allow = loan.allow, begin = function()
        ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(flow.player, loan.item, loan.from, main))
    end }, function()
        loan.out = true
        flow:await(function() return main:getItemWithID(loan.id) end, function(item)
            loan.item = item
            Log.trace(flow.interaction, "FETCHED", "item", Log.item(item, flow.player), "from", Log.container(loan.from, flow.player))
            return done(item)
        end, function() return failed("The vessel did not arrive in your inventory") end)
    end, failed)
end

-- Puts a fetched vessel back where it came from.
function Vessels.giveBack(flow, loan, done, failed)
    local player = flow.player
    local item = Items.find(player, loan.id)
    if not item or item:getContainer() ~= player:getInventory() then return failed("The vessel is no longer in your inventory") end
    flow:act({ op = "return", allow = loan.allowBack, begin = function()
        if loan.spot then
            require "TimedActions/ISDropWorldItemAction"
            local spot = loan.spot
            local action = ISDropWorldItemAction:new(player, item, spot.square, spot.x, spot.y, spot.z, spot.rotation, false)
            action.isPlaceItem = true
            ISTimedActionQueue.add(action)
        else
            ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(player, item, player:getInventory(), loan.from))
        end
    end }, function()
        loan.out = false
        flow:await(function()
            if loan.spot then return (Items.eachNearby(player, function(candidate) return candidate:getID() == loan.id end)) end
            return loan.from:getItemWithID(loan.id)
        end, function(back)
            loan.item = back
            Log.trace(flow.interaction, "RETURNED", "item", Log.item(back, player), "to", Log.container(loan.from, player))
            return done(back)
        end, function() return done(nil) end)
    end, failed)
end

return Vessels
