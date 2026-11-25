-- Refills a water dispenser's bottle: take it off its stand, pour the chosen
-- vessels into it, fit it again. Taking deletes the stand and makes a new
-- bottle and a bare stand; fitting does the reverse. Both are found afresh.
local Flow = require "LootBox/Flow"
local Items = require "LootBox/Items"
local Inventory = require "LootBox/PourInventory"
local Vessels = require "LootBox/Vessels"
local Log = require "LootBox/Log"
local Dispenser = Flow.class()
Dispenser.MAX_DONORS = 128

local BOTTLE, ACTION = "Base.WaterDispenserBottle", "ISAddTakeDispenserBottle"

local function kind(object)
    local script = object and object.getEntityScript and object:getEntityScript()
    local name = script and script:getModule() and script:getModule():getName() == "Base" and script:getName()
    return name == "WaterDispenser" and "mounted" or name == "WaterDispenserNoBottle" and "bare" or nil
end

-- The stand at this place now.
local function standAt(square, facing)
    local list = square:getObjects()
    for index = 0, list:size() - 1 do
        local object = list:get(index)
        local what = kind(object)
        if what and object:getFacing() == facing then return { object = object, square = square, facing = facing, kind = what } end
    end
end

local function allowed(player, square)
    return not isClient() or SafeHouse.isSafehouseAllowInteract(square, player) and SafeHouse.isSafehouseAllowLoot(square, player)
end

local function reading(fluid)
    local amount, capacity = fluid:getAmount(), fluid:getCapacity()
    return { fluid = fluid, amount = amount, cap = capacity, mix = amount > 0 and Inventory.mix({ fluid = fluid }) or {} }
end

-- The one dispenser among the clicked objects.
function Dispenser.capture(player, objects)
    return Log.guard("Dispenser.capture", function()
        local found
        for index, object in ipairs(objects) do
            if index > 128 then return nil end
            if kind(object) and (not found or found.object ~= object) then
                if found or not object:getSquare() or not allowed(player, object:getSquare()) then return nil end
                found = standAt(object:getSquare(), object:getFacing())
                if not found or found.object ~= object then return nil end
            end
        end
        return found
    end)
end

-- What can be filled: the mounted bottle, or each loose bottle for a bare stand.
function Dispenser.destinations(player, world, stand, snapshot)
    if stand.kind == "mounted" then
        local fluid = stand.object:getFluidContainer()
        if not fluid or fluid:getFreeCapacity() <= 0 then return {} end
        -- The mounted bottle is locked; a loose one tells what may go into it.
        local loose = instanceItem(BOTTLE)
        local test = loose and loose:getFluidContainer()
        if not test then return {} end
        test:copyFluidsFrom(fluid)
        return { { state = reading(fluid), test = test } }
    end
    local out = {}
    for _, entry in ipairs((snapshot or Inventory.snapshot(player, world)).entries) do
        if entry.fullType == BOTTLE and entry.container == player:getInventory() and entry.free > 0
            and not world:protected(entry.item) and #out < 12 then
            out[#out + 1] = { item = entry.item, id = entry.id, state = reading(entry.fluid), test = entry.fluid, label = entry.label }
        end
    end
    return out
end

function Dispenser.canFill(entry, bottle)
    return entry.id ~= bottle.id and entry.scope ~= "loot" and Vessels.amount(entry.amount, bottle.test:getFreeCapacity()) ~= nil
        and FluidContainer.CanTransfer(entry.fluid, bottle.test) == true
end

function Dispenser.new(player, world, stand, donors, bottle)
    local id = stand.interaction or Log.intent("refill", "Refill dispenser", player)
    donors = donors.item and { donors } or donors
    local self = Flow.begin(Dispenser, player, id, { world = world, square = stand.square, facing = stand.facing, donors = donors,
        index = 1, jugId = bottle.id, phase = stand.kind == "mounted" and "take" or "pour", litresBefore = bottle.state.amount,
        action = "pour", name = "Refill Dispenser", total = #donors })
    Log.info(id, "START", "op", "dispenser-refill", "stand", stand.kind, "square", Log.point(stand.square), "litres", bottle.state.amount,
        "capacity", bottle.state.cap, "sources", #donors, "player", Log.player(player))
    return self
end

function Dispenser:stand(what)
    local stand = standAt(self.square, self.facing)
    return stand and stand.kind == what and stand or nil
end

function Dispenser:jug()
    if self.jugId then return (Items.find(self.player, self.jugId)) end
    return self.watch and self.watch:find() or nil
end

local function handle(self, stand, jug, done)
    local player = self.player
    self:act({ op = jug and "fit-bottle" or "take-bottle", main = function(action) return action.Type == ACTION end,
        allow = function(phase) return phase == "run" or allowed(player, self.square) and self:stand(stand.kind) ~= nil, "The stand changed" end,
        begin = function()
            require "TimedActions/ISAddTakeDispenserBottle"
            if luautils.walkAdj(player, self.square, false) then
                ISTimedActionQueue.add(ISAddTakeDispenserBottle:new(player, stand.object, jug))
            end
        end,
    }, done, function(why) self:giveUp(why) end)
end

-- Ends the work, fitting the bottle again if it was taken.
function Dispenser:giveUp(reason)
    if not self.jugId or self.phase == "fit" then return self:finish("cancelled", reason) end
    self.problem, self.phase = reason, "fit"
end

function Dispenser:finish(state, reason)
    if state ~= "finished" and self:jug() then reason = tostring(reason) .. ". The bottle is in your inventory" end
    return Flow.finish(self, state, reason)
end

function Dispenser:next()
    if self.phase == "take" then return self:take() end
    if self.phase == "pour" then return self:fill() end
    return self:fit()
end

function Dispenser:take()
    local stand = self:stand("mounted")
    if not stand then return self:finish("cancelled", "The bottle is no longer on its stand") end
    local litres = stand.object:getFluidContainer():getAmount()
    self.watch = Items.watch(self.player, { interaction = self.interaction, makes = function(item)
        if item:getFullType() ~= BOTTLE then return false end
        return -math.abs(item:getFluidContainer():getAmount() - litres)
    end })
    handle(self, stand, nil, function()
        self:await(function() return self:stand("bare") and self:jug() end, function(jug)
            self.jugId, self.phase = jug:getID(), "pour"
        end, function()
            self:finish("failed", self:jug() and "The empty stand is not here" or "The game did not take the bottle")
        end)
    end)
end

function Dispenser:fill()
    local jug = self:jug()
    if not jug then return self:finish("failed", "The bottle is no longer in your inventory") end
    local donor = self.donors[self.index]
    local fluid = jug:getFluidContainer()
    local free = fluid:getFreeCapacity()
    if not donor or not Vessels.amount(free, free) then self.phase = "fit"; return end
    local live, why = Inventory.current(self.player, self.world, donor)
    if live and (not Inventory.sameLiquid(Inventory.mix(live) or {}, donor.pourSignature or Inventory.mix(live) or {})
        or not Dispenser.canFill(live, { id = self.jugId, test = fluid })) then live, why = nil, "It no longer fits the bottle" end
    self.index = self.index + 1
    if not live then
        self.skipped = (self.skipped or 0) + 1
        Log.trace(self.interaction, "SKIP", "source", Log.item(donor.item, self.player), "reason", why)
        return
    end
    Vessels.pour(self, live.item, jug, { done = function() self.count = self.count + 1 end,
        failed = function(problem) self:giveUp(problem) end })
end

function Dispenser:fit()
    local jug, stand = self:jug(), self:stand("bare")
    if not jug or jug:getContainer() ~= self.player:getInventory() then return self:finish("failed", "The bottle is not in your main inventory") end
    if not stand then return self:finish("failed", "The empty stand is gone") end
    handle(self, stand, jug, function()
        self:await(function() return self:stand("mounted") and not self:jug() end, function()
            if self.problem then return self:finish("cancelled", self.problem .. ". The bottle is back on its stand") end
            return self:finish(self.count > 0 and "finished" or "cancelled",
                self.count > 0 and "The bottle is back on its stand" or "Nothing could be poured. The bottle is back on its stand")
        end, function()
            return self:finish("failed", "The game did not confirm the fitted bottle")
        end)
    end)
end

function Dispenser:card()
    return { title = self.state == "finished" and "Dispenser refilled" or "Dispenser refill stopped",
        detail = { string.format("%.2f L", self.liters) } }
end

return Dispenser
