-- Puts away what the player brought home. What left with them stays with them:
-- only what they did not have when they left, carried or in the vehicle they came
-- back in, is ever moved, and the first sign of the player doing something stops it.
local Act = require "LootBox/Act"
local Items = require "LootBox/Items"
local Labels = require "LootBox/Labels"
local Log = require "LootBox/Log"

local Auto = { TITLE = "Put away what I brought home" }
-- Two distances, so that standing on the edge of home is not coming and going.
local ARRIVE, LEAVE, CALM_MS, LOOK_MS = 15, 25, 3000, 1000

local function carriedIds(player)
    local ids = {}
    Items.eachCarried(player, function(item) ids[tostring(item:getID())] = true end)
    return ids
end

-- A new character in the same save never left home with what the last one had.
local function whoami(player)
    local descriptor = player:getDescriptor()
    return tostring(descriptor:getForename()) .. " " .. tostring(descriptor:getSurname())
end

local function danger(player)
    local stats = player:getStats()
    return stats:getNumVisibleZombies() > 0 or stats:getNumChasingZombies() > 0 or stats:getNumVeryCloseZombies() > 0
end

local function crafting(index)
    local open = ISEntityUI and ISEntityUI.players and ISEntityUI.players[index]
    for _, window in pairs(open and open.windows or {}) do
        if window.instance and window.instance:isReallyVisible() then return true end
    end
    return false
end

-- The player moving, fighting, resting, or busy with a menu, a drag, a window of ours or a text box.
local function acting(player)
    local index = player:getPlayerNum()
    local menu = getPlayerContextMenu and getPlayerContextMenu(index)
    local search = ISSearchManager and ISSearchManager.players and ISSearchManager.players[player]
    return player:pressedMovement(false) or Act.blocked(player) ~= nil or player:getVehicle() ~= nil
        or player:isSitOnGround() or player:isSittingOnFurniture() or getCore():isDoingTextEntry()
        or ISMouseDrag and ISMouseDrag.dragging ~= nil or getCell():getDrag(index) ~= nil
        or menu ~= nil and menu:isAnyVisible() or search ~= nil and search.isSearchMode == true
        or Auto.windows ~= nil and Auto.windows(index) == true or crafting(index)
end

-- A click may be anything, so it only puts off a start; a click on Stop must reach its button.
local function busy(player)
    return acting(player) or danger(player) or isMouseButtonDown(0) or isMouseButtonDown(1)
end

local function free(instance)
    if instance.takeover or instance.borrowed or instance.error or instance.recovery:status().pending then return false end
    if instance.consumption and instance.consumption:isBusy() then return false end
    local jobs = instance.jobs:status()
    return jobs.canStart == true and jobs.hasJob ~= true and jobs.recoveryRequired ~= true
end

local function stateOf(instance)
    if not instance.homecoming then instance.homecoming = { pending = {}, cargo = {}, calmAt = 0, lookAt = 0 } end
    return instance.homecoming
end

local function stop(instance, s, why)
    local runner = s.runner
    s.runner = nil
    if not runner or instance.jobs ~= runner or not runner:status().hasJob then return end
    Log.info(runner.interaction, "AUTO-PUT-AWAY", "stopped", why)
    runner:cancel(true)
end

-- Anything the player asks for comes first.
function Auto.yield(instance, why)
    local s = instance.homecoming
    if not s or not s.runner then return end
    stop(instance, s, why or "the player asked for something else")
    s.pending, s.cargo = {}, {}
end

-- Turned off: nothing noted so far counts when it is turned on again.
function Auto.forget(instance)
    Auto.yield(instance, "turned off")
    instance.homecoming = nil
    if instance.state.trip ~= nil then instance.state.trip = nil; instance:persist() end
end

local function watch(instance, s, now)
    local runner = s.runner
    local status = runner:status()
    if instance.jobs ~= runner or not status.hasJob then
        s.runner, s.pending, s.cargo = nil, {}, {}
        return
    end
    local why
    -- Danger puts it off; anything the player does themself ends it.
    if acting(instance.player) then why, s.pending, s.cargo = "the player moved or acted", {}, {}
    elseif status.waiting then why, s.pending, s.cargo = "the player started something", {}, {}
    elseif danger(instance.player) then why, s.calmAt = "danger", now + CALM_MS
    -- It ran into something only the player can settle, which would happen again.
    elseif status.canResume then why, s.pending = "it could not go on: " .. tostring(status.reason), {} end
    if why then stop(instance, s, why) end
end

-- Everything in a vehicle's compartments.
local function cargoIds(vehicle, ids)
    for index = 0, vehicle:getPartCount() - 1 do
        local container = vehicle:getPartByIndex(index):getItemContainer()
        local items = container and container:getItems()
        for at = 0, (items and items:size() or 0) - 1 do ids[tostring(items:get(at):getID())] = true end
    end
    return ids
end

local function leave(instance, s, player, vehicle)
    local had = carriedIds(player)
    if vehicle then cargoIds(vehicle, had) end
    instance.state.trip = { who = whoami(player), had = had }
    s.home, s.pending, s.cargo, s.vehicle = false, {}, {}, vehicle
    Log.trace(nil, "AUTO-PUT-AWAY", "left", "home", "at", Log.point(player:getCurrentSquare()))
    instance:persist()
end

local function arrive(instance, s, player, now)
    local trip = instance.state.trip
    instance.state.trip, s.calmAt = nil, now + CALM_MS
    if trip and trip.who == whoami(player) then
        for id in pairs(carriedIds(player)) do if not trip.had[id] then s.pending[id] = true end end
        -- What came home in the vehicle counts once it is taken out of it.
        for id in pairs(s.vehicle and cargoIds(s.vehicle, {}) or {}) do if not trip.had[id] then s.cargo[id] = true end end
        Log.trace(nil, "AUTO-PUT-AWAY", "came", "home", "new", not Labels.none(s.pending), "cargo", not Labels.none(s.cargo))
        instance:persist()
    end
    s.vehicle = nil
end

local function look(instance, s, now)
    local player = instance.player
    local vehicle = player:getVehicle()
    local near = instance.world:atHome(s.home and LEAVE or ARRIVE) ~= nil
    if s.home and not near then leave(instance, s, player, vehicle) end
    -- Nobody has come home until they get out.
    if vehicle then s.vehicle = vehicle; return end
    if near and not s.home then arrive(instance, s, player, now) end
    s.home = near
    if near then s.vehicle = nil end
    if near and not Labels.none(s.cargo) then
        for id in pairs(carriedIds(player)) do if s.cargo[id] then s.cargo[id], s.pending[id] = nil, true end end
    end
end

local function begin(instance, s)
    local player, world = instance.player, instance.world
    local only, count = {}, 0
    for _, entry in ipairs(world:putAway(true, s.pending)) do only[tostring(entry.item:getID())], count = true, count + 1 end
    s.pending = only
    if count == 0 then return end
    local id = Log.intent("auto", "put away", player, "items", count)
    local plan, why = instance:preview({ scope = "inventory", includeInventory = false, includeBags = true, sourceLabels = {},
        filter = { all = true, ids = {}, types = {} }, only = only, title = Auto.TITLE, interaction = id,
        destination = { kind = "labels", labels = {}, near = world:nearHere(true) } })
    local ok
    if plan and #plan.moves > 0 then ok, why = instance:start(plan, { automatic = true, interaction = id, reviewBins = false }) end
    if ok then s.runner = instance.jobs; return end
    s.pending = {}
    Log.info(id, "END", "state", "nothing-to-do", "reason", why or plan and plan.skipped[1] and plan.skipped[1].reason)
end

local function update(instance, now)
    local s = stateOf(instance)
    if s.runner then watch(instance, s, now); return end
    if busy(instance.player) or not Act.idle(instance.player) then s.calmAt = now + CALM_MS end
    if now >= s.lookAt or s.lookAt - now > LOOK_MS then
        s.lookAt = now + LOOK_MS
        look(instance, s, now)
    else return end
    if s.home and not Labels.none(s.pending) and now >= s.calmAt and free(instance) then begin(instance, s) end
end

function Auto.update(instance, now) Log.guard("AutoPutAway.update", update, instance, now) end

return Auto
