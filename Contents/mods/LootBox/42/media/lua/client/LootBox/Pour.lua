-- Pours one chosen vessel into the chosen others, in order. A vessel on a shelf
-- is fetched, used and put back; one standing on the ground is used in place.
local Flow = require "LootBox/Flow"
local Inventory = require "LootBox/PourInventory"
local Vessels = require "LootBox/Vessels"
local Log = require "LootBox/Log"
local Pour = Flow.class()

function Pour.options(preferences)
    return { pourLootToLoot = preferences.pourLootToLoot == true,
        pourFillScope = preferences.pourMainOnly and "main-only" or preferences.pourEquippedFirst and "equipped-first" or "main-first",
        pourFillOrder = preferences.pourMostRoomFirst and "largest-first" or "smallest-first" }
end

function Pour.displayed(index, holder) return require("LootBox/PourStacks").displayedLoot(index, holder) end

local function slot(entry)
    local fetched = entry.scope == "loot" and not entry.groundSquare
    return { entry = entry, mix = entry.pourSignature or entry.amount > 0 and Inventory.mix(entry) or nil,
        loan = fetched and { id = entry.id, from = entry.container, spot = entry.spot } or nil }
end

local function describe(entry, player)
    return Log.item(entry.item, player) .. " " .. tostring(entry.scope) .. " " .. Inventory.litres(entry.amount) .. "/"
        .. Inventory.litres(entry.capacity) .. "L " .. tostring(entry.relation)
end

function Pour.new(player, world, source, targets, interaction)
    local id = interaction or Log.intent("pour", "Pour " .. tostring(source.label), player)
    local self = Flow.begin(Pour, player, id, { world = world, source = slot(source), targets = {}, index = 1, action = "pour",
        name = "Pour Into", total = #targets })
    Log.info(id, "START", "op", "pour", "source", describe(source, player), "targets", #targets, "player", Log.player(player))
    for index, entry in ipairs(targets) do
        self.targets[index] = slot(entry)
        if index <= 40 then Log.trace(id, "TARGET", "n", index, "vessel", describe(entry, player)) end
    end
    if #targets == 0 then return nil, "Choose at least one destination" end
    return self
end

-- The vessel now, still holding the liquid that was chosen.
function Pour:live(vessel)
    local live, why = Inventory.current(self.player, self.world, vessel.entry)
    if not live then return nil, why end
    if live.amount > 0 and vessel.mix and not vessel.filled and not Inventory.sameLiquid(Inventory.mix(live) or {}, vessel.mix) then
        return nil, "The liquid changed"
    end
    return live
end

-- Ends the work, putting back what was fetched.
function Pour:unwind(reason, state)
    self.ending = self.ending or { reason = reason, state = state or "cancelled" }
end

function Pour:putBack(vessel)
    Vessels.giveBack(self, vessel.loan, function() end, function(why)
        vessel.loan.lost, vessel.loan.out = true, false
        self:unwind(why)
    end)
end

function Pour:fetch(vessel, live)
    local item, loan = live.item, vessel.loan
    local protected, reason = self.world:protected(item)
    if protected or item:isFavorite() then return self:unwind("Protected: " .. tostring(reason or "Favorite")) end
    loan.item = item
    Vessels.fetch(self, loan, function() end, function(why) self:unwind(why) end)
end

function Pour:next()
    local target = self.targets[self.index]
    if target and target.loan and target.loan.out and (target.done or self.ending) then return self:putBack(target) end
    if target and target.done then self.index, target = self.index + 1, self.targets[self.index + 1] end
    local source, problem = nil, nil
    if not self.ending then
        source, problem = self:live(self.source)
        if not source then self:unwind(problem)
        elseif not target or not Vessels.amount(source.amount, source.amount) then self:unwind("The pouring is done", "finished") end
    end
    if not self.ending then
        local live, why = self:live(target)
        if not live then self:unwind(why)
        elseif self.source.loan and not self.source.loan.out then return self:fetch(self.source, source)
        elseif target.loan and not target.loan.out then return self:fetch(target, live)
        else
            return Vessels.pour(self, source.item, live.item, {
                done = function() self.count, target.done, target.filled = self.count + 1, true, true end,
                failed = function(why) self:unwind(why) end })
        end
    end
    if self.source.loan and self.source.loan.out then return self:putBack(self.source) end
    return self:finish(self.ending.state, self.ending.reason)
end

-- Where each fetched vessel was left, when it could not be put back.
function Pour:left()
    local names = {}
    for _, vessel in ipairs({ self.source, self.targets[self.index] }) do
        if vessel.loan and (vessel.loan.out or vessel.loan.lost) then names[#names + 1] = Inventory.vesselName(vessel.entry) end
    end
    return #names > 0 and "In your inventory: " .. table.concat(names, ", ") or nil
end

function Pour:finish(state, reason)
    local left = self:left()
    if left then reason = tostring(reason) .. ". " .. left end
    return Flow.finish(self, state, reason)
end

function Pour:card()
    return { title = self.state == "finished" and "Pour complete" or "Pour stopped",
        detail = { self.count .. (self.count == 1 and " vessel" or " vessels"), string.format("%.2f L", self.liters) } }
end

return Pour
