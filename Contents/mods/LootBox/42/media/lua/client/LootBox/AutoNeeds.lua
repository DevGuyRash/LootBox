local Inventory = require "LootBox/NeedsInventory"
local TillFull = require "LootBox/TillFull"
local Loan = require "LootBox/StockWaterLoan"
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
        or player:isKnockedDown() or player:isbFalling() or player:isPerformingGrappleAnimation() then return false end
    local stats = player:getStats()
    return stats:getNumVisibleZombies() == 0 and stats:getNumChasingZombies() == 0 and stats:getNumVeryCloseZombies() == 0
end

local function free(instance)
    if instance.error or instance.replacement or instance.recovery:status().pending then return false end
    local jobs = instance.jobs:status()
    return jobs.canPreview == true and jobs.hasJob ~= true and jobs.recoveryRequired ~= true
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

local function guardFor(instance, kind, read, policyItem, plan, loan)
    local p, world = instance.player, instance.world
    local waterChecked, noStock = nil, false
    return function(item, source, phase)
        local ok, result = pcall(function()
            local opts, err = read()
            if err or not opts or not free(instance) or not safe(p) then return false end
            if kind == "food" and not opts.autoConsumeCarried then return false end
            if kind == "fluid" and (not (opts.autoDrinkEquipped or opts.autoConsumeCarried) or not waterEnabled(p)) then return false end
            if phase == "waitWater" then
                -- The two network endpoints can briefly show no replica. A
                -- pending transaction still yields to the player and to the
                -- original bag's ownership, settings and protection.
                return loan and kind == "fluid" and Inventory.sourceAccessible(p,opts,world,source)
            end
            if phase == "waitOpening" then
                -- The server can remove the exact can before reporting Done. Only
                -- the other safety/intent checks still make sense after removal.
                return plan ~= nil and kind == "food" and item == policyItem and plan.source == source
                    and source == p:getInventory() and (not plan.risky or opts.autoConsumeRiskyOpen == true)
            end
            local opening = plan and item == policyItem and plan or nil
            if not Inventory.sourceAccessible(p,opts,world,source)
                or not Inventory.accessible(p,opts,kind,world,item,opening) then return false end
            if phase == "admit" and not Inventory.eligible(p,opts,kind,world,item,opening) then return false end
            if loan or kind ~= "fluid" or phase == "return" then return true end
            -- Ordinary non-water intake yields if a stock source appears. Do
            -- not traverse the native inventory once per animation frame.
            local now = getTimestampMs()
            if phase == "admit" or not waterChecked or now - waterChecked >= 750 then
                waterChecked, noStock = now, waterSource(p) == nil
            end
            return noStock
        end)
        if not ok then Log.fault(nil,"AutoNeeds.guard",result) end
        return ok and result == true
    end
end

local function start(instance,s,opts,read,kind,before,now)
    local p, w = instance.player, instance.world
    local permitted
    if kind == "fluid" then
        local main = p:getInventory()
        permitted = function(value, source)
            return source == main or not value:isWaterOnlySource() or Loan.canOffer(p,value)
        end
    end
    local item, plan = Inventory.select(p,opts,kind,w,nil,permitted,kind == "food" and s.readyOnly)
    if not item or (plan and s.readyOnly) or not Inventory.eligible(p,opts,kind,w,item,plan) then
        if not s.nothing[kind] then Log.trace(nil,"AUTO-SCAN","kind",kind,"found","nothing eligible","need",before,"player",Log.player(p)) end
        s.nothing[kind] = true
        return false
    end
    s.nothing[kind] = nil
    local pureWater = kind == "fluid" and item:isWaterOnlySource()
    local loan = pureWater and item:getContainer() ~= p:getInventory()
    local guard = guardFor(instance,kind,read,item,plan,loan)
    local interaction = Log.intent("auto",kind == "food" and "eat" or "drink",p,"hunger",need(p,"food"),"thirst",need(p,"fluid"),
        "item",Log.item(item,p),"source",Log.container(item:getContainer(),p),"opening",plan ~= nil,"loan",loan == true)
    local active, why
    if loan then
        active = Loan.new(p,item,guard,interaction)
    else
        active, why = TillFull.new(p,w,{item},kind,false,nil,nil,{guard=guard,openingPlan=plan,interaction=interaction})
    end
    if not active then
        Log.warn(interaction,"REFUSED","at","start","reason",why or "The water loan could not start")
        return false
    end
    s.pending, s.notBefore = {controller=active, before=before, kind=kind}, now + COOLDOWN
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
        if c.state == "finished" and c.mpOpenedInputRetired and pending.kind == "food" then
            -- Stock did not name a food output. A later *new* needs assessment
            -- may choose any already-edible, allowed carried food. Never open
            -- another can in this hunger episode, even if there is no food.
            s.readyOnly = true
        elseif c.state ~= "cancelled" and (c.state ~= "finished" or (c.count or 0) < 1 or not finite(after)
            or after >= pending.before - 0.0001) then
            -- Only an unconfirmed outcome forbids another try in this episode.
            -- An interruption waits out the cooldown like any other attempt.
            s.blocked[pending.kind] = true
            Log.warn(c.interaction,"AUTO-BLOCKED","kind",pending.kind,"state",c.state,"reason",c.reason,
                "confirmed",c.count,"needBefore",pending.before,"needNow",after)
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
    if hunger < thresholds.food then s.blocked.food, s.readyOnly = nil, nil end
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
