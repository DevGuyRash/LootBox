-- Inverse world fill for ONE explicitly clicked loot vessel. A fixture is
-- never a portable donor: first borrow the exact receiver, run the stock
-- fixture action in main inventory, then return only its verified replica.
local I=require "LootBox/PourInventory"
local W=require "LootBox/WorldFluids"
local Stacks=require "LootBox/PourStacks"
local Log=require "LootBox/Diagnostics"
local Actor=require "LootBox/PourActor"
local Loan={}
Loan.__index=Loan
local function exact(e,amount,mix,capacity)
    return e and W.near(e.capacity,capacity) and W.near(e.amount,amount)
        and (amount==0 or I.sameMix(e,mix))
end
local function idle(p)
    local q=ISTimedActionQueue.getTimedActionQueue(p)
    return not q.current and #q.queue==0 and not p:hasTimedActions()
end
local function visible(p,world,lease)
    local shelf=lease.entry.container
    if Stacks.displayedLoot(p:getPlayerNum(),shelf)~=shelf then return false end
    if lease.ground then return require("LootBox/PourGround").reachable(p,lease.ground) end
    return lease.shelf~=nil and world:pourShelfReachable(shelf,lease.shelf)
end
local function unprotected(world,e)
    return e.item:isFavorite()==false and world:protected(e.item)==false
end
local function canBorrow(p,world,e)
    local main=p:getInventory()
    return unprotected(world,e) and e.container:isRemoveItemAllowed(e.item)
        and main:isItemAllowed(e.item) and main:hasRoomFor(p,e.item)
        and p:getFreeInventoryCapacity()>e.item:getUnequippedWeight()
end
local MIX_TOLERANCE=.00001 -- stock FluidSample reports proportions, not litres
local function normalized(mix)
    if not mix then return end
    local total=0
    for _,ratio in pairs(mix) do total=total+ratio end
    if math.abs(total-1)<=MIX_TOLERANCE then return mix end
end
local function sameMix(actual,expected)
    if not actual or not expected then return false end
    for kind,ratio in pairs(expected) do
        if not actual[kind] or math.abs(actual[kind]-ratio)>MIX_TOLERANCE then return false end
    end
    for kind in pairs(actual) do if not expected[kind] then return false end end
    return true
end
local function bind(p,world,e)
    if e.scope~="loot" or e.free<=0 then return end
    local lease={entry=e,shelf=e.pourAnchor}
    if e.container:getType()=="floor" then
        lease.ground=require("LootBox/PourGround").capture(p,e.item,e.container,true)
        if not lease.ground then return end
    end
    if visible(p,world,lease) and canBorrow(p,world,e) and I.accessible(p,world,e,e.container)
        and W.signature(e) and (e.amount==0 or normalized(e.pourSignature)) then return lease end
end
function Loan.bind(...)
    local ok,v=pcall(bind,...)
    if ok then return v end
end

local function source(p,a,e)
    if not a.nearby or not W.live(p,a) or not W.canReceive(p,a,e) then return end
    local o=a.object
    local external=o:getUsesExternalWaterSource()
    local provider=o
    if external then
        -- Ask the native plumbing resolver for the feed, not the tap's
        -- own component or just its primary fluid. A feed we cannot pin
        -- and independently verify is not an admissible fixture loan.
        provider=o:FindExternalWaterSource()
        if not provider or provider==o or not provider:isExistInTheWorld()
            or provider:getUsesExternalWaterSource() or not W.near(provider:getFluidCapacity(),a.capacity)
            or not W.near(provider:getFluidAmount(),a.amount) then return end
    end
    local component=provider:getFluidContainer()
    if component and component:getAmount()>0 then
        if not W.near(component:getAmount(),a.amount) then return end
        local raw=normalized(I.mix({fluid=component}))
        if not raw then return end
        local recipe=raw
        if external then
            recipe={}
            for kind,ratio in pairs(raw) do
                -- The stock tap's createSampleAndPurifyWater replaces only
                -- TaintedWater. Other components remain in the same ratios.
                local out=kind==Fluid.TaintedWater and Fluid.Water or kind
                recipe[out]=(recipe[out] or 0)+ratio
            end
        end
        if not a.primary or not recipe[a.primary] then return end
        return {provider=provider,component=component,raw=raw,recipe=recipe}
    end
    if external then return end
    -- Natural/puddle, mains and reserve sources without a populated
    -- component synthesize one native water type rather than a mixture.
    local kind=a.primary or a.tainted and Fluid.TaintedWater
    if kind~=Fluid.Water and kind~=Fluid.TaintedWater then return end
    return {provider=o,component=component,recipe={[kind]=1},
        reserve=kind==Fluid.Water and not a.unlimited}
end
function Loan.source(...)
    local ok,v=pcall(source,...)
    if ok then return v end
end
local function unchangedSource(job)
    local a,c=job.pick.a,job.pick.source
    local o=a.object
    if not W.live(job.p,a) or not W.near(o:getFluidCapacity(),a.capacity) or not W.near(o:getFluidAmount(),a.amount)
        or o:getPrimaryFluid()~=a.primary or o:isTaintedWater()~=a.tainted then return false end
    local live=source(job.p,a,job.live)
    return live and live.provider==c.provider and live.component==c.component and sameMix(live.recipe,c.recipe)
        and (not c.raw or sameMix(live.raw,c.raw))
end

-- Require component-by-component conservation. A matching total (or even
-- an unchanged primary fluid) is not proof of the liquid that arrived.
local function receivedMix(self,e,gain)
    local c,a=self.pick.source,self.pick.a
    if c.raw then
        if c.provider:getFluidContainer()~=c.component or not W.near(c.component:getAmount(),a.amount-gain) then return end
    elseif c.reserve and not W.near(a.object:getFluidAmount(),a.amount-gain) then return end
    local total=self.amount+gain
    local expected={}
    if self.amount>0 then
        local initial=normalized(self.mix)
        if not initial then return end
        for kind,ratio in pairs(initial) do expected[kind]=ratio*self.amount/total end
    end
    for kind,ratio in pairs(c.recipe) do expected[kind]=(expected[kind] or 0)+ratio*gain/total end
    local actual=normalized(I.mix(e))
    if sameMix(actual,expected) then return actual end
end
local function guard(self)
    return self.enabled() and visible(self.p,self.world,self.pick.lease)
end
local function unchanged(self)
    local ok,e=I.accessible(self.p,self.world,self.live,self.original.container)
    return ok and unprotected(self.world,e) and exact(e,self.amount,self.mix,self.original.capacity)
end

function Loan.new(p,world,pick,enabled)
    local l=pick.lease
    if not l or not pick.a.nearby or not pick.source or not l.entry or l.entry.scope~="loot" or type(enabled)~="function"
        or isServer() or Actor.blocked(p) or not idle(p) then return nil,"Choose an available loot vessel and finish the current action." end
    local e=l.entry
    local self=setmetatable({p=p,world=world,pick=pick,original=e,live=e,amount=e.amount,mix=e.pourSignature,
        enabled=enabled,state="running",phase="pickup",name="Fill From",liters=0,count=0},Loan)
    if not guard(self) or not unchanged(self) or not canBorrow(p,world,e) or not unchangedSource(self)
        or not W.canReceive(p,pick.a,e) then return nil,"The selected fixture, receiver, or inventory room changed." end
    local adapter=l.ground and require("LootBox/PourGround") or require("LootBox/PourMove")
    self.move=adapter.new(p)
    return self
end
function Loan:isBusy()return self.state=="running" or self.state=="cancelling" end
function Loan:status()
    return {state=self.state,reason=self.reason,action="pour",intent="pour",done=self.count,total=1,
        moved=self.count,pourLiters=self.liters,skipped=0,reasons={},hasJob=self:isBusy(),canPreview=not self:isBusy(),
        canPause=false,canResume=false}
end
function Loan:finish(ok,why)
    self.state=ok and "finished" or "cancelled"
    self.reason=why
    if not ok and self.touched and not self.restored then
        self.reason=why.." Check main inventory and the original loot location; the return was not confirmed."
    end
    Log.emit("world-fill-loot","terminal",self.state,self.phase,ok and "completed" or "stopped",
        " pickupSubmitted=%s returnConfirmed=%s confirmedLitres=%.3f",tostring(self.touched==true),
        tostring(self.restored==true),self.liters)
    if self.touched and not self.silent and PZActionCompletionHUD then
        pcall(PZActionCompletionHUD.show,self.p:getPlayerNum(),{brand="LOOTBOX",theme="loot",
            title=ok and "Fill complete" or "Fill stopped",status=not ok and "stopped" or nil,
            detail=string.format("%.3f L confirmed",self.liters),note=self.reason})
    end
end
function Loan:cancel(silent,why)
    if not self:isBusy() or self.stop then return true end
    self.stop,self.silent=why or "Fill cancelled.",silent
    self.state="cancelling"
    if self.move:isBusy() then self.move:cancel()
    elseif self.job and self.job:isBusy() then self.job:cancel(true,self.stop)
    else self:finish(false,self.stop) end
    return true
end
function Loan:submitMove(back)
    local e=self.live
    local from=e.container
    local to=back and self.original.container or self.p:getInventory()
    local function allowed(phase)
        if self.stop or not guard(self) then return false end
        if phase~="admit" then return true end -- reciprocal membership may lag the native receipt
        if not unchanged(self) then return false end
        if back then return from:isRemoveItemAllowed(e.item) end
        return canBorrow(self.p,self.world,e) and unchangedSource(self) and W.canReceive(self.p,self.pick.a,e)
    end
    local ok,why=self.move:start(e.item,from,to,allowed,self.pick.lease.ground)
    if not ok then self:finish(false,why or "The game did not admit the receiver move.");return end
    self.touched=true
end
-- Even after pickup, a conflicted ID must not be submitted to the stock
-- action. Check both direct holders at admission, not just contains(handle).
local function exactID(container,id,expected)
    local items=container:getItems()
    local n=items:size()
    if n>4096 then return false end
    local found
    for i=0,n-1 do
        local it=items:get(i)
        if not it then return false end
        if it:getID()==id then
            if found or it~=expected or it:getContainer()~=container then return false end
            found=it
        end
    end
    return found==expected
end
function Loan:preflight()
    return guard(self) and not self.stop and not Actor.blocked(self.p)
        and unchanged(self) and unchangedSource(self) and W.canReceive(self.p,self.pick.a,self.live)
        and exactID(self.p:getInventory(),self.original.id,self.live.item)
        and exactID(self.original.container,self.original.id,nil)
end
function Loan:step()
    if not self.stop and not guard(self) then self:cancel(false,"The original loot location or shortcut is no longer available.") end
    if not self:isBusy() then return end
    if self.move:isBusy() then
        local ok,why,item=self.move:poll()
        if ok==nil then return end
        if not ok then self:finish(false,self.stop or why or "The exact move was not confirmed.");return end
        local back=self.phase=="return"
        local holder=back and self.original.container or self.p:getInventory()
        local e=I.rebind(self.p,self.world,self.original,item,holder,self.original.container,self.pick.lease.ground)
        if not exact(e,self.amount,self.mix,self.original.capacity) then
            self:finish(false,"The moved receiver or its contents did not match the selection.");return
        end
        self.live=e
        if back then self.restored=true end
        if self.stop then self:finish(false,self.stop);return end
        if back then
            self.count=self.filled and 1 or 0
            self:finish(self.filled,self.returnReason or "The selected vessel was filled and returned.")
        else self.phase="fill" end
        return
    end
    if self.job then
        if self.job:isBusy() then self.job:tick() end
        if self.job:isBusy() then return end
        if self.stop or self.job.state~="finished" or self.job.count~=1 then
            self:finish(false,self.stop or self.job.reason or "The fixture fill was not confirmed.");return
        end
        local gained=self.job.liters
        local ok,e=I.accessible(self.p,self.world,self.live,self.original.container,true)
        if not ok or not W.near(e.amount,self.amount+gained) or not W.near(e.capacity,self.original.capacity)
            or not unprotected(self.world,e) then self:finish(false,"The filled receiver changed.");return end
        local mix=receivedMix(self,e,gained)
        if not mix then self:finish(false,"The filled receiver's liquid could not be confirmed.");return end
        self.liters=gained
        self.live,self.amount,self.mix,self.job,self.filled,self.phase=e,e.amount,mix,nil,true,"return"
        return
    end
    if self.stop or Actor.blocked(self.p) or not idle(self.p) then self:finish(false,self.stop or "Movement or another action interrupted the fill.");return end
    if self.phase=="pickup" or self.phase=="return" then self:submitMove(self.phase=="return");return end
    if not self:preflight() then
        -- No fluid action has been submitted. Restore an unchanged receiver
        -- when the origin is still allowed and there is no conflicting action.
        self.returnReason,self.phase="The fixture or capacity changed before the fill; the unfilled vessel was returned.","return"
        return
    end
    self.live.pourSignature=self.mix
    local function preflight(act)
        return self:preflight() and act.character==self.p and act.item==self.live.item and act.waterObject==self.pick.a.object
            and act.waterUnit and act.waterUnit>0 and act.waterUnit<=self.p:getFreeInventoryCapacity()
    end
    local job,why=require("LootBox/WorldFluidJob").new(self.p,self.world,self.pick.a,true,{self.live},
        function()return guard(self) and unprotected(self.world,self.live) end,preflight)
    if not job then self:finish(false,why or "The fixture action was unavailable.");return end
    job.noHUD=true
    job.receipt=function(e,gained) return receivedMix(self,e,gained)~=nil end
    self.job=job
    job:tick()
end
function Loan:tick()
    if self:isBusy() then
        local ok=pcall(self.step,self)
        if not ok then
            if self.stop then self:finish(false,self.stop)
            else self:cancel(false,"The game could not verify the exact fixture fill.") end
        end
    end
end
return Loan
