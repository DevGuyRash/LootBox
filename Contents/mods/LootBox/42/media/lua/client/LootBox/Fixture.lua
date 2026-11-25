-- Fills chosen vessels from a world fixture, or pours one into it, with the
-- game's own walk and action. A vessel on a shelf is fetched and put back.
local Flow = require "LootBox/Flow"
local Inventory = require "LootBox/PourInventory"
local Vessels = require "LootBox/Vessels"
local W = require "LootBox/WorldFluids"
local Log = require "LootBox/Log"
local Fixture = Flow.class()

function Fixture.new(player, world, anchor, take, entries, interaction)
    local id = interaction or anchor.interaction or Log.intent("pour", take and "Fill from a fixture" or "Pour into a fixture", player)
    if #entries == 0 then return nil, "Choose a vessel" end
    local self = Flow.begin(Fixture, player, id, { world = world, anchor = anchor, take = take, entries = entries, index = 1,
        action = "pour", name = take and "Fill From" or "Pour Into", total = #entries })
    Log.info(id, "START", "op", take and "fixture-fill" or "fixture-pour", "fixture", W.describe(anchor), "vessels", #entries,
        "player", Log.player(player))
    return self
end

local function loanOf(entry)
    if entry.scope ~= "loot" then return nil end
    entry.loan = entry.loan or { id = entry.id, from = entry.container }
    return entry.loan
end

function Fixture:stop(state, reason) self.ending = self.ending or { state = state, reason = reason } end

function Fixture:next()
    local player, anchor, entry = self.player, self.anchor, self.entries[self.index]
    local loan = entry and entry.loan
    if loan and not loan.lost and Vessels.held(self, loan) and (entry.done or self.ending) then
        return Vessels.giveBack(self, loan, function() end, function(why)
            loan.lost = true
            self:stop("cancelled", why)
        end)
    end
    if entry and entry.done then self.index, entry = self.index + 1, self.entries[self.index + 1] end
    if not entry then self:stop("finished", "The vessels are done") end
    if self.ending then return self:finish(self.ending.state, self.ending.reason) end
    local ok, why = W.live(player, anchor)
    if not ok then return self:stop("cancelled", "The fixture is out of reach: " .. tostring(why)) end
    local object = anchor.object
    if object:hasFluid() and (object:getPrimaryFluid() ~= anchor.primary or object:isTaintedWater() ~= anchor.tainted) then
        return self:stop("cancelled", "The fixture's liquid changed")
    end
    local live
    live, why = Inventory.current(player, self.world, entry)
    if not live then return self:stop("cancelled", why) end
    if entry.pourSignature and type(entry.pourSignature) == "table" and live.amount > 0
        and not Inventory.sameLiquid(Inventory.mix(live) or {}, entry.pourSignature) then return self:stop("cancelled", "The liquid changed") end
    if live.scope == "loot" then
        local protected, reason = self.world:protected(live.item)
        if protected or live.item:isFavorite() then return self:stop("cancelled", "Protected: " .. tostring(reason or "Favorite")) end
        loan = loanOf(entry)
        loan.item = live.item
        loan.spot = loan.spot or Vessels.spot(player, live.item)
        return Vessels.fetch(self, loan, function() end, function(problem) self:stop("cancelled", problem) end)
    end
    ok, why = W.can(player, self.world, anchor, live, self.take)
    if not ok then
        -- Running dry or full part way through a batch is simply the end of it.
        local state = self.count > 0 and "finished" or "cancelled"
        return self:stop(state, self.count > 0 and "There is no more liquid or room" or "The game does not allow it: " .. tostring(why))
    end
    return self:pour(entry, live)
end

local function queue(self, item)
    local player, object = self.player, self.anchor.object
    if self.take and item:getContainer() ~= player:getInventory() then
        -- The game carries a bagged vessel out, fills it and puts it back.
        return ISWorldObjectContextMenu.onTakeWater({ object }, object, nil, item, player:getPlayerNum())
    end
    if not luautils.walkAdjObject(player, object, true, true) then return end
    if self.take then return ISTimedActionQueue.add(ISTakeWaterAction:new(player, item, object, object:isTaintedWater())) end
    ISTimedActionQueue.add(ISAddFluidFromItemAction:new(player, item, object))
end

function Fixture:pour(entry, live)
    local before, kind = live.amount, self.take and "ISTakeWaterAction" or "ISAddFluidFromItemAction"
    local expected
    local function changed()
        local now = Inventory.current(self.player, self.world, entry)
        return now and math.abs(now.amount - before) or 0
    end
    local function settled(litres)
        self.liters, self.count, entry.done = self.liters + litres, self.count + 1, true
        Log.trace(self.interaction, "FILLED", "n", self.count, "litres", litres, "expected", expected, "fixture", W.describe(self.anchor))
    end
    local function full()
        local litres = changed()
        if litres > 0 and litres >= (expected or 0) * 0.95 then return litres end
    end
    local function ended(why)
        return function()
            local litres = changed()
            if litres > 0 and not why then return settled(litres) end
            self.liters = self.liters + litres
            self:stop("cancelled", why or "The game did not confirm it")
        end
    end
    self:act({ op = self.take and "fixture-fill" or "fixture-pour", keepAfter = true,
        lasting = function() return Inventory.current(self.player, self.world, entry) ~= nil end,
        main = function(action) return action.Type == kind end,
        allow = function(phase, action)
            if phase == "run" then return true end
            expected = self.take and action.waterUnit or action.addUnits
            return Inventory.current(self.player, self.world, entry) ~= nil, "The vessel moved or is gone"
        end,
        begin = function() queue(self, live.item) end,
    }, function() self:await(full, settled, ended()) end, function(why) self:await(full, settled, ended(why), 1500) end)
end

function Fixture:finish(state, reason)
    for _, entry in ipairs(self.entries) do
        if Vessels.held(self, entry.loan) then reason = tostring(reason) .. ". In your inventory: " .. Inventory.vesselName(entry) end
    end
    return Flow.finish(self, state, reason)
end

function Fixture:card()
    return { title = self.state == "finished" and "Pour complete" or "Pour stopped",
        detail = { self.count .. (self.count == 1 and " vessel" or " vessels"), string.format("%.2f L", self.liters) },
        note = self.count < self.total and self.reason or nil }
end

return Fixture
