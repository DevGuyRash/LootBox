-- A world fixture is not an inventory vessel. Keep the stock walk, item
-- transfer, water action and server validation; schedule just one vessel per
-- verified receipt so later fills see current water and carrying capacity.
local W=require "LootBox/WorldFluids"
local Log=require "LootBox/Log"
local Job={}
Job.__index=Job
local MIRROR_MS=5000
local function queue(p) return ISTimedActionQueue.getTimedActionQueue(p) end
local function idle(p,q) return not q.current and #q.queue==0 and not p:hasTimedActions() end
local function safe(p,preflight)
    return p:isLocalPlayer() and not p:isDead() and not p:isAsleep()
        and (preflight and (not p.pressedMovement or not p:pressedMovement(false))
            or not preflight and not p:isRunning() and not p:isSprinting()) and not p:isAiming() and not p:isAttacking() and not p:isShoving()
end

function Job.new(p,world,a,take,entries,enabled,preflight,interaction)
    local id=interaction or a and a.interaction or Log.intent("pour",take and "Fill from a fixture" or "Pour into a fixture",p)
    local rejection
    if not a or type(entries)~="table" or #entries<1 or #entries>512 or not take and #entries~=1
        then rejection="invalid-selection"
    elseif not safe(p,preflight) then rejection="actor-unavailable"
    elseif not idle(p,queue(p)) then rejection="queue-busy" end
    if rejection then
        Log.warn(id,"REFUSED","op",take and "fixture-fill" or "fixture-pour","check",rejection,
            "vessels",type(entries)=="table" and #entries or nil,"fixture",a and W.describe(a) or nil,
            "queue",Log.queue(p),"player",Log.player(p))
        return nil,"Finish the current action and select an available vessel."
    end
    Log.info(id,"START","op",take and "fixture-fill" or "fixture-pour","fixture",W.describe(a),"vessels",#entries,"player",Log.player(p))
    for index,e in ipairs(entries) do
        if index>40 then Log.trace(id,"TARGET","more",#entries-40);break end
        Log.trace(id,"TARGET","n",index,"vessel",Log.item(e.item,p),"scope",e.scope,"place",e.place,
            "litres",string.format("%.5f/%.5f",e.amount,e.capacity),"container",Log.container(e.container,p))
    end
    return setmetatable({player=p,world=world,anchor=a,take=take,entries=entries,enabled=enabled,preflight=preflight,
        interaction=id,startedAt=getTimestampMs(),count=0,liters=0,state="running",name=take and "Fill From" or "Pour Into"},Job)
end
function Job:isBusy() return self.state=="running" or self.state=="cancelling" end
function Job:status()
    return {state=self.state,reason=self.reason,action="pour",intent="pour",done=self.count,total=#self.entries,
        moved=self.count,pourLiters=self.liters,skipped=0,reasons={},hasJob=self:isBusy(),canPreview=not self:isBusy(),
        canPause=false,canResume=false}
end
local function phaseOf(self)
    local s=self.pending
    return s and (s.performed and "receipt" or type(s.amount)=="number" and s.amount>0 and "action" or "dispatch") or "prepare"
end
-- The vessel and the fixture as they are now, against what was asked.
local function opEnd(self,s,ok,check,live)
    local amount=live and live.amount
    local emit=ok and Log.trace or Log.warn
    emit(self.interaction,"OP-END","op",self.take and "fixture-fill" or "fixture-pour","ok",ok,"check",check,
        "vessel",Log.item(live and live.item or s.entry.item,self.player),
        "expectedLitres",s.amount and string.format("%.5f",s.amount) or nil,
        "vesselBefore",string.format("%.5f",s.vesselBefore),"vesselNow",amount and string.format("%.5f",amount) or nil,
        "fixtureBefore",string.format("%.5f",s.before),"fixtureNow",string.format("%.5f",self.anchor.object:getFluidAmount()),
        "tolerance",string.format("%.5f",W.tolerance(s.amount or 0)),"elapsedMs",getTimestampMs()-s.startedAt,
        "performed",s.performed==true,"stopped",s.stopped==true)
end
function Job:finish(state,why,code,phase)
    self.state,self.reason,self.check=state,why,code or self.stopCode
    if self.pending then Log.guard("WorldFluidJob.opEnd",opEnd,self,self.pending,false,self.check,self.lastLive) end
    local emit=state=="finished" and Log.info or Log.warn
    emit(self.interaction,"END","op",self.take and "fixture-fill" or "fixture-pour","state",state,
        "check",self.check,"phase",phase or self.stopPhase or phaseOf(self),"reason",why,
        "vessels",self.count,"of",#self.entries,"litres",self.liters,"submitted",self.launched==true,
        "elapsedMs",getTimestampMs()-self.startedAt,"player",Log.player(self.player))
    if self.launched and not self.silent and not self.noHUD and PZActionCompletionHUD then
        Log.guard("WorldFluidJob.card",PZActionCompletionHUD.show,self.player:getPlayerNum(),{brand="LOOTBOX",theme="loot",
            title=state=="finished" and "Pour complete" or "Pour stopped",status=state~="finished" and "stopped" or nil,
            detail=string.format("%d vessel(s) | %.3f L confirmed",self.count,self.liters),note=why})
    end
end

function Job:cancel(silent,reason,code)
    if not self:isBusy() or self.state=="cancelling" then return true end
    self.silent,self.state=silent,"cancelling"
    self.reason=reason or "World pour cancelled; no more vessels will be started."
    self.stopCode,self.stopPhase=code or (silent and "session-cleanup" or "player-cancelled"),phaseOf(self)
    local s,q=self.pending,queue(self.player)
    if not s then self:finish("cancelled",self.reason);return true end
    -- Never clear a foreign queue. If another action was appended, drop only
    -- our not-yet-started operations, and leave the active stock action alone.
    local foreign=false
    for _,a in ipairs(q.queue) do if not s.owned[a] then foreign=true end end
    for i=#q.queue,1,-1 do
        local a=q.queue[i]
        if a~=q.current and s.owned[a] and not a:isStarted() then
            a:forceCancel()
            q:removeFromQueue(a)
        end
    end
    if not foreign and q.current and s.owned[q.current] and q.current.action then q.current:forceStop() end
    if s.entry.container~=self.player:getInventory() then
        self.reason=self.reason.." If a bag transfer was interrupted, check the original bag and main inventory."
    end
    return true
end

local function watch(s,action)
    -- Observe the per-instance finish signal, not a shared class. An MP client
    -- perform is NOT a receipt; the mirrored quantities must also agree.
    local perform,stop=action.perform,action.stop
    action.perform=function(a,...)
        local result=perform(a,...)
        s.performed=true
        return result
    end
    action.stop=function(a,...)
        s.stopped=true
        return stop(a,...)
    end
end

-- A fixture loan may have walked/turned after it previewed available room.
-- Only tighten this instance's pre-submission check; leave the stock action,
-- server validation, fluid handling, and networking unchanged.
local function restoreTail(q,tail)
    local position=q.current and 2 or nil
    for _,a in ipairs(tail) do
        if q:indexOf(a)<0 then
            if position then table.insert(q.queue,position,a);position=position+1
            else q:addToQueue(a) end
        end
    end
end
local function restoreLoanTail(player,s)
    local pending=s.loanTail
    if not pending or getTimestampMs()<=pending.at then return end
    if queue(player)==pending.q then restoreTail(pending.q,pending.tail) end
    s.loanTail=nil
end
local function guardLoanStart(action,admit,q,s)
    local wait,stop,perform=action.waitToStart,action.stop,action.perform
    function action:waitToStart(...)
        local ready=Log.guard("WorldFluidJob.admit",admit,self)
        if not ready or q.current~=self or #q.queue~=1 then self:forceStop();return true end
        return wait(self,...)
    end
    local function preserving(fn,defer,self,...)
        if q.current~=self then s.stopped=true;return end
        local tail={}
        for _,a in ipairs(q.queue) do if a~=self then tail[#tail+1]=a end end
        if #tail==0 then return fn(self,...) end
        for _,a in ipairs(tail) do q:removeFromQueue(a) end
        local ok,r=pcall(fn,self,...)
        if defer then
            -- Stock onCompleted may reset an invalid next action and all
            -- its successors. Resume the same manual entries only after the
            -- owned perform/complete callbacks have returned.
            s.loanConflict=true
            s.loanTail={q=q,tail=tail,at=getTimestampMs()}
            if Events and Events.OnTick then
                local function restore()
                    restoreLoanTail(self.character,s)
                    if not s.loanTail then Events.OnTick.Remove(restore) end
                end
                Events.OnTick.Add(restore)
            end
        else restoreTail(q,tail) end
        if not ok then error(r,0) end
        return r
    end
    function action:stop(...) return preserving(stop,false,self,...) end
    function action:perform(...) return preserving(perform,true,self,...) end
end

function Job:launch(e,before)
    local p,o=self.player,self.anchor.object
    local s={entry=e,owned={},before=o:getFluidAmount(),inPlace=self.take and e.container==p:getInventory(),startedAt=getTimestampMs(),vesselBefore=before}
    local q=queue(p)
    self.pending,self.lastLive=s,nil
    if self.take then
        if s.inPlace then
            -- Stock onTakeWater appends a redundant main-to-main return for
            -- partially filled water vessels. There is nothing to move.
            if luautils.walkAdjObject(p,o,true,true) then
                local action=ISTakeWaterAction:new(p,e.item,o,o:isTaintedWater())
                if self.preflight then guardLoanStart(action,self.preflight,q,s) end
                ISTimedActionQueue.add(action)
            end
        else
            ISWorldObjectContextMenu.onTakeWater({o},o,nil,e.item,p:getPlayerNum())
        end
    elseif luautils.walkAdjObject(p,o,true,true) then
        -- Main inventory only: the unmodified action uses its own override
        -- hand models. Do not call stock equip(), which replaces primary gear.
        ISTimedActionQueue.add(ISAddFluidFromItemAction:new(p,e.item,o))
    end
    for _,a in ipairs(q.queue) do
        s.owned[a]=true
        if self.take and a.Type=="ISTakeWaterAction" and a.waterObject==o and a.item==e.item
            or not self.take and a.Type=="ISAddFluidFromItemAction" and a.objectTo==o and a.itemFrom==e.item then
            s.amount=self.take and a.waterUnit or a.addUnits
            watch(s,a)
        end
    end
    Log.trace(self.interaction,"OP","op",self.take and "fixture-fill" or "fixture-pour","n",self.count+1,
        "vessel",Log.item(e.item,p),"fixture",W.describe(self.anchor),"litres",s.amount,"inPlace",s.inPlace,
        "freeCarry",p:getFreeInventoryCapacity(),"queue",Log.queue(p))
    if type(s.amount)~="number" or not (s.amount>0) then
        self:cancel(false,"The game did not start a usable fluid action.","native-not-queued");return
    end
    self.launched=true
end

function Job:step()
    local p,a,s=self.player,self.anchor,self.pending
    local o,q=a.object,queue(p)
    if s and s.loanTail then
        restoreLoanTail(p,s)
        if s.loanTail then return end -- never take the same-tick idle gap as a receipt
    end
    if self.state=="cancelling" then
        if s then for _,v in ipairs(q.queue) do if s.owned[v] then return end end end
        self:finish("cancelled",self.reason)
        return
    end
    local reachable,why=W.live(p,a)
    local blocked=not self.enabled() and "settings-changed" or not safe(p,self.preflight) and "actor-unavailable"
        or not reachable and tostring(why)
    if blocked then
        self:cancel(false,"The fixture, access, or player state changed.",blocked);return
    end
    if s then
        if s.loanConflict then self:cancel(false,"Another action was queued.","queue-busy");return end
        if s.stopped then self:cancel(false,"The native fluid action stopped.","native-stopped");return end
        local live,problem
        if s.inPlace then
            live,problem=W.inPlaceReceiver(p,self.world,s.entry)
            if not live then self:cancel(false,"The selected vessel or its equipment state changed.",problem);return end
        end
        for _,v in ipairs(q.queue) do
            if not s.owned[v] then self:cancel(false,"Another action was queued.","queue-busy");return end
        end
        if not idle(p,q) then return end
        if not s.performed then self:cancel(false,"The native fluid action was interrupted.","native-interrupted");return end
        if not s.inPlace then live,problem=W.received(p,self.world,s.entry) end
        self.lastLive=live
        if live and not W.changedBy(s.vesselBefore,live.amount,self.take and s.amount or -s.amount) then problem="vessel-litres" end
        if not problem and self.receipt and not self.receipt(live) then problem="vessel-mixture" end
        if problem then
            s.waitSince=s.waitSince or getTimestampMs()
            if getTimestampMs()-s.waitSince>=MIRROR_MS then
                self:finish("cancelled","The exact fluid change or original holder was not confirmed. No retry; check the vessel before continuing.",
                    problem)
            end
            return
        end
        opEnd(self,s,true,nil,live)
        self.count,self.liters,self.pending=self.count+1,self.liters+s.amount,nil
        -- Do not dispatch from the same tick that accepted an engine update.
        if self.count==#self.entries then self:finish("finished","Selected world pour complete.","completed","receipt") end
        return
    end
    local moving=self.preflight and require("LootBox/PourActor").blocked(p) or not self.preflight and p:isMoving()
    local interruption=not idle(p,q) and "queue-busy" or moving and "actor-moving"
    if interruption then self:cancel(false,"Movement or another action interrupted the selection.",interruption);return end
    if self.take and self.count>0 and (not o:hasFluid() or o:getFluidAmount()<=0 or p:hasFullInventory() or p:getFreeInventoryCapacity()<=0) then
        self:finish("finished","No more fluid or carrying space is available.","fluid-or-capacity-exhausted");return
    end
    -- Rain changes how much a collector holds at any time; only what it holds matters.
    if not W.near(o:getFluidCapacity(),a.capacity) or o:getPrimaryFluid()~=a.primary or o:isTaintedWater()~=a.tainted then
        Log.warn(self.interaction,"STOPPED","check","fixture-fluid-changed","chosenLiquid",W.liquid(a),"chosenTainted",a.tainted,
            "chosenCapacity",a.capacity,"fixture",W.describe(a))
        self:cancel(false,"The selected world fluid changed. Reopen the menu.","fixture-fluid-changed");return
    end
    local e=self.entries[self.count+1]
    local allowed,problem=W.allowedEntry(p,self.world,a,e,self.take)
    if not allowed then
        Log.warn(self.interaction,"STOPPED","check",problem,"vessel",Log.item(e.item,p),"fixture",W.describe(a))
        self:cancel(false,"The selected vessel or transfer direction is no longer available.",problem);return
    end
    self:launch(e,allowed.amount)
end
function Job:tick()
    if not self:isBusy() then return end
    local ok,err=pcall(self.step,self)
    if not ok then
        Log.fault(self.interaction,"WorldFluidJob.step",err,"phase",phaseOf(self),"vessel",self.count+1)
        if self.state=="cancelling" then self:finish("cancelled","The game changed before the world pour could be confirmed.","cleanup-binding-error")
        else self:cancel(false,"The game did not expose this world fluid action.","action-binding-error") end
    end
end
return Job
