local Inventory = require "LootBox/NeedsInventory"
local TillFull = require "LootBox/TillFull"
local Log = require "LootBox/Log"

local Auto = {}
local SCAN, COOLDOWN, STALL = 4000, 12000, 20000
local thresholds = {food = 0.25, fluid = 0.20}
local EQUIPPED_ONLY = {autoDrinkEquipped=true}
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function need(player, kind)
    return player:getStats():get(kind == "food" and CharacterStat.HUNGER or CharacterStat.THIRST)
end

local function safe(player)
    if not player:isLocalPlayer() or not player:getCurrentSquare() or player:getVehicle()
        or player:isDead() or player:isAsleep() or player:isMoving() or player:isRunning() or player:isSprinting()
        or player:isAiming() or player:isAttacking() or player:isShoving() or player:isClimbing()
        or player:isKnockedDown() or player:isbFalling() or player:isPerformingGrappleAnimation()
        or ISInventoryPaneContextMenu.getEatingMask(player, false) then return false end
    local stats = player:getStats()
    return stats:getNumVisibleZombies() == 0 and stats:getNumChasingZombies() == 0 and stats:getNumVeryCloseZombies() == 0
end

local function free(instance)
    if instance.error or instance.replacement or instance.recovery:status().pending then return false end
    local jobs = instance.jobs:status()
    return jobs.canStart == true and jobs.hasJob ~= true and jobs.recoveryRequired ~= true
end

local function waterEnabled(player)
    return getCore():getOptionAutoDrink() == true and (not isClient() or player:getAutoDrink() == true)
end
local function waterSource(player) return player:getWaterSource(player:getInventory():getItems()) end

-- A selectable stock vessel does not prove that any water was delivered. Watch
-- the same vessel without interfering with normal sips, including on a server.
local function stockWater(s, p, opts, world, src, thirst, now)
    local component = src:getFluidContainer()
    if not component then s.stock = nil; return end
    local amount = component:getAmount()
    if not finite(amount) or amount <= 0 then s.stock = nil; return end
    local w = s.stock
    if not w or w.item ~= src or w.component ~= component or w.amount ~= amount or thirst < w.lastThirst - 0.0001 then
        s.stock = {item=src, component=component, amount=amount, thirst=thirst, lastThirst=thirst, started=now}
        return
    end
    w.lastThirst = thirst
    if s.nativeAttempt and s.nativeAttempt.item == src and s.nativeAttempt.amount == amount then return end
    if now - w.started < STALL or thirst <= w.thirst + 0.0001 then return end
    if opts.autoDrinkEquipped and not isClient() and src:getContainer() == p:getInventory()
        and Inventory.eligible(p,EQUIPPED_ONLY,"fluid",world,src)
        and waterSource(p) == src and p.autoDrink then
        s.nativeAttempt = {item=src, amount=amount}
        -- Use stock's own selection, quantity, authority and AutoDrink hook once.
        -- No additional timed drink, hook registration or stat/fluid write.
        p:autoDrink()
        w.confirmed = component:getAmount() < w.amount and need(p,"fluid") < thirst
        s.notBefore = now + COOLDOWN
        return true
    end
end

-- guard() asks whether the player still allows it; with an item, also whether
-- that exact item is still theirs to take.
local function guardFor(instance, kind, read)
    local p, world = instance.player, instance.world
    return function(item, source, plan)
        local ok, result = pcall(function()
            local opts, err = read()
            if err or not opts or not free(instance) or not safe(p) then return false end
            if kind == "food" and not opts.autoConsumeCarried then return false end
            if kind == "fluid" and (not (opts.autoDrinkEquipped or opts.autoConsumeCarried) or not waterEnabled(p)) then return false end
            if not item then return true end
            -- What automatic intake itself opened is in the main inventory, whatever opened it.
            if item:getContainer() ~= p:getInventory() and not Inventory.sourceAccessible(p, opts, world, source) then return false end
            return Inventory.eligible(p, opts, kind, world, item, plan)
        end)
        if not ok then Log.fault(nil, "AutoNeeds.guard", result) end
        return ok and result == true
    end
end

local function start(instance, s, opts, read, kind, before, now)
    local p, w = instance.player, instance.world
    local item, plan = Inventory.select(p, opts, kind, w)
    if not item then
        if not s.nothing[kind] then Log.trace(nil, "AUTO-SCAN", "kind", kind, "found", "nothing eligible", "need", before, "player", Log.player(p)) end
        s.nothing[kind] = true
        return false
    end
    s.nothing[kind] = nil
    local interaction = Log.intent("auto", kind == "food" and "eat" or "drink", p, "hunger", need(p, "food"), "thirst", need(p, "fluid"),
        "item", Log.item(item, p), "source", Log.container(item:getContainer(), p), "opening", plan ~= nil)
    local active, why = TillFull.new(p, w, { item }, { kind = kind, interaction = interaction,
        automatic = { guard = guardFor(instance, kind, read), plan = plan } })
    if not active then
        Log.warn(interaction, "REFUSED", "at", "start", "reason", why)
        return false
    end
    s.pending, s.notBefore = { controller = active, before = before, kind = kind }, now + COOLDOWN
    instance.consumption = active
    active:tick()
    return true
end

local function step(instance, opts, read, now)
    if not opts or not (opts.autoConsumeCarried or opts.autoDrinkEquipped) or isServer() then return end
    local s = instance.autoNeeds
    if not s then s = {blocked={},nothing={}}; instance.autoNeeds = s end
    if s.last and now >= s.last and now - s.last < SCAN then return end
    s.last = now
    local p, pending = instance.player, s.pending
    if pending then
        local c = pending.controller
        if c:isBusy() then return end
        if instance.consumption == c then instance.consumption = nil end
        local after = need(p,pending.kind)
        if c.state ~= "cancelled" and (c.state ~= "finished" or c.count < 1 or not finite(after) or after >= pending.before - 0.0001) then
            -- It did not help: do not repeat it until the need has been met some other way.
            s.blocked[pending.kind] = true
            Log.warn(c.interaction, "AUTO-BLOCKED", "kind", pending.kind, "state", c.state, "reason", c.reason,
                "portions", c.count, "needBefore", pending.before, "needNow", after)
        end
        -- What was refused before it even started is refused again in seconds.
        local refused = c.state == "cancelled" and c.goal and not c.launched
        s.pending, s.notBefore = nil, math.max(s.notBefore, now + (refused and 5 * COOLDOWN or COOLDOWN))
    end
    if (instance.consumption and instance.consumption:isBusy()) or not free(instance) or not safe(p) then s.stock=nil;return end
    local q = ISTimedActionQueue.getTimedActionQueue(p)
    if not q or q.current or not q.queue or #q.queue ~= 0 or p:hasTimedActions() then s.stock=nil;return end
    local hunger, thirst = need(p,"food"), need(p,"fluid")
    if not finite(hunger) or not finite(thirst) then s.stock=nil;return end
    if hunger < thresholds.food then s.blocked.food = nil end
    if thirst < thresholds.fluid then s.blocked.fluid, s.nativeAttempt = nil, nil end
    if s.notBefore and now < s.notBefore then return end
    local knownSetting, enabled = pcall(waterEnabled,p)
    if thirst >= thresholds.fluid and not s.blocked.fluid and knownSetting and enabled then
        -- Treat unknown native methods/results as no authorization, not
        -- "there must be no vanilla source". Hunger remains independent.
        local known, src = pcall(waterSource,p)
        if known and src then
            local checked, retried = pcall(stockWater,s,p,opts,instance.world,src,thirst,now)
            if not checked then Log.fault(nil,"AutoNeeds.stockWater",retried) end
            if not checked then s.stock = nil elseif retried then return end
        else
            s.stock = nil
            if known then
                if start(instance,s,opts,read,"fluid",thirst,now) then return end
                s.notBefore = now + COOLDOWN -- an empty search walks the whole inventory too
            end
        end
    else s.stock = nil end
    if opts.autoConsumeCarried and hunger >= thresholds.food and not s.blocked.food
        and not start(instance,s,opts,read,"food",hunger,now) then s.notBefore = now + COOLDOWN end
end

function Auto.interruptObservation(instance)
    local s = instance and instance.autoNeeds
    if not s or not s.stock then return end
    local ok, stillIdle = pcall(function()
        local p = instance.player
        return safe(p) and not p:hasTimedActions()
    end)
    if not ok or not stillIdle then s.stock = nil end
end

function Auto.step(instance, options, readOptions, now)
    -- Missing/changed modded or build bindings cannot make an unfamiliar supply eligible.
    local ok, err = pcall(step, instance, options, readOptions, now)
    if not ok then Log.fault(nil,"AutoNeeds.step",err) end
    if not ok and instance.autoNeeds then instance.autoNeeds.stock = nil end
end

return Auto
