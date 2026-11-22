-- A world fixture is not an inventory vessel. Keep the stock walk, item
-- transfer, water action and server validation; schedule just one vessel per
-- verified receipt so later fills see current water and carrying capacity.
local W=require "LootBox/WorldFluids"
local Job={}
Job.__index=Job
local MIRROR_MS=5000
local function queue(p) return ISTimedActionQueue.getTimedActionQueue(p) end
local function idle(p,q) return not q.current and #q.queue==0 and not p:hasTimedActions() end
local function safe(p)
    return p:isLocalPlayer() and not p:isDead() and not p:isAsleep() and not p:isRunning()
        and not p:isSprinting() and not p:isAiming() and not p:isAttacking() and not p:isShoving()
end

function Job.new(p,world,a,take,entries,enabled)
    if not a or type(entries)~="table" or #entries<1 or #entries>512 or not take and #entries~=1
        or not safe(p) or not idle(p,queue(p)) then return nil,"Finish the current action and select an available vessel." end
    return setmetatable({player=p,world=world,anchor=a,take=take,entries=entries,enabled=enabled,
        count=0,liters=0,state="running",name=take and "Fill From" or "Pour Into"},Job)
end
function Job:isBusy() return self.state=="running" or self.state=="cancelling" end
function Job:status()
    return {state=self.state,reason=self.reason,action="pour",intent="pour",done=self.count,total=#self.entries,
        moved=self.count,pourLiters=self.liters,skipped=0,reasons={},hasJob=self:isBusy(),canPreview=not self:isBusy(),
        canPause=false,canResume=false}
end
function Job:finish(state,why)
    self.state,self.reason=state,why
    if self.launched and not self.silent and PZActionCompletionHUD then
        pcall(PZActionCompletionHUD.show,self.player:getPlayerNum(),{brand="LOOTBOX",theme="loot",
            title=state=="finished" and "Pour complete" or "Pour stopped",status=state~="finished" and "stopped" or nil,
            detail=string.format("%d vessel(s) | %.3f L confirmed",self.count,self.liters),note=why})
    end
end

function Job:cancel(silent,reason)
    if not self:isBusy() or self.state=="cancelling" then return true end
    self.silent,self.state=silent,"cancelling"
    self.reason=reason or "World pour cancelled; no more vessels will be started."
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

function Job:launch(e)
    local p,o=self.player,self.anchor.object
    local s={entry=e,owned={},before=o:getFluidAmount(),inPlace=self.take and e.container==p:getInventory()}
    local q=queue(p)
    self.pending=s
    if self.take then
        if s.inPlace then
            -- Stock onTakeWater appends a redundant main-to-main return for
            -- partially filled water vessels. There is nothing to move.
            if luautils.walkAdjObject(p,o,true,true) then
                ISTimedActionQueue.add(ISTakeWaterAction:new(p,e.item,o,o:isTaintedWater()))
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
    if type(s.amount)~="number" or not (s.amount>0) then self:cancel(false,"The game did not start a usable fluid action.");return end
    self.launched=true
end

function Job:step()
    local p,a,s=self.player,self.anchor,self.pending
    local o,q=a.object,queue(p)
    if self.state=="cancelling" then
        if s then for _,v in ipairs(q.queue) do if s.owned[v] then return end end end
        self:finish("cancelled",self.reason)
        return
    end
    if not self.enabled() or not safe(p) or not W.live(p,a) then
        self:cancel(false,"The fixture, access, or player state changed.");return
    end
    if s then
        if s.stopped then self:cancel(false,"The native fluid action stopped.");return end
        local live
        if s.inPlace then
            live=W.inPlaceReceiver(p,self.world,s.entry)
            if not live then self:cancel(false,"The selected vessel or its equipment state changed.");return end
        end
        for _,v in ipairs(q.queue) do
            if not s.owned[v] then self:cancel(false,"Another action was queued.");return end
        end
        if not idle(p,q) then return end
        if not s.performed then self:cancel(false,"The native fluid action was interrupted.");return end
        if not s.inPlace then live=W.received(p,self.world,s.entry) end
        local before=s.entry.amount
        local target=before+(self.take and s.amount or -s.amount)
        local remaining=s.before+(self.take and -s.amount or s.amount)
        -- Natural water and reserve/puddle sources may not have a depleting
        -- component. Their native yield is proven by the actual vessel delta.
        local metered=not self.take or ((o:getFluidContainer() or o:getUsesExternalWaterSource())
            and not (a.capacity>=9999 and s.before==a.capacity))
        if not live or not W.near(live.amount,target) or metered and not W.near(o:getFluidAmount(),remaining) then
            s.waitSince=s.waitSince or getTimestampMs()
            if getTimestampMs()-s.waitSince>=MIRROR_MS then
                self:finish("cancelled","The exact fluid change or original holder was not confirmed. No retry; check the vessel before continuing.")
            end
            return
        end
        self.count,self.liters,self.pending=self.count+1,self.liters+s.amount,nil
        -- Do not dispatch from the same tick that accepted an engine update.
        if self.count==#self.entries then self:finish("finished","Selected world pour complete.") end
        return
    end
    if not idle(p,q) or p:isMoving() then self:cancel(false,"Movement or another action interrupted the selection.");return end
    if self.take and self.count>0 and (not o:hasFluid() or o:getFluidAmount()<=0 or p:hasFullInventory() or p:getFreeInventoryCapacity()<=0) then
        self:finish("finished","No more fluid or carrying space is available.");return
    end
    if not W.near(o:getFluidCapacity(),a.capacity) or o:getPrimaryFluid()~=a.primary or o:isTaintedWater()~=a.tainted then
        self:cancel(false,"The selected world fluid changed. Reopen the menu.");return
    end
    local e=self.entries[self.count+1]
    if not W.allowedEntry(p,self.world,a,e,self.take) then self:cancel(false,"The selected vessel or transfer direction is no longer available.");return end
    self:launch(e)
end
function Job:tick()
    if not self:isBusy() then return end
    local ok=pcall(self.step,self)
    if not ok then
        if self.state=="cancelling" then self:finish("cancelled","The game changed before the world pour could be confirmed.")
        else self:cancel(false,"The game did not expose this world fluid action.") end
    end
end
return Job
