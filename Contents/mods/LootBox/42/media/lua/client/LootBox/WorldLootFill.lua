-- Inverse world fill for ONE explicitly clicked loot vessel. A fixture is
-- never a portable donor: first borrow the exact receiver, run the stock
-- fixture action in main inventory, then return only its verified replica.
local I=require "LootBox/PourInventory"
local W=require "LootBox/WorldFluids"
local Stacks=require "LootBox/PourStacks"
local Log=require "LootBox/Log"
local Actor=require "LootBox/PourActor"
local Loan={}
Loan.__index=Loan
local function sameMix(actual,expected)
    if not actual or not expected then return false end
    for kind,ratio in pairs(expected) do if math.abs((actual[kind] or 0)-ratio)>.02 then return false end end
    for kind,ratio in pairs(actual) do if not expected[kind] and ratio>.02 then return false end end
    return true
end
local function exact(e,amount,mix,capacity)
    if not e then return false,"vessel-not-recognised" end
    if not W.near(e.capacity,capacity) then return false,string.format("capacity: %.5f expected, %.5f now",capacity,e.capacity) end
    if not W.near(e.amount,amount) then return false,string.format("litres: %.5f expected, %.5f now",amount,e.amount) end
    return e.amount==0 or I.sameMix(e,mix),"mixture-changed"
end
local function idle(p)
    local q=ISTimedActionQueue.getTimedActionQueue(p)
    return not q.current and #q.queue==0 and not p:hasTimedActions()
end
local function visible(p,world,lease)
    local shelf=lease.entry.container
    if Stacks.displayedLoot(p:getPlayerNum(),shelf)~=shelf then return false,"loot-pane-changed" end
    if lease.ground then return require("LootBox/PourGround").reachable(p,lease.ground),"spot-unreachable" end
    return lease.shelf~=nil and world:pourShelfReachable(shelf,lease.shelf),"storage-unreachable"
end
local function unprotected(world,e)
    return e.item:isFavorite()==false and world:protected(e.item)==false
end
local function canBorrow(p,world,e)
    local main=p:getInventory()
    if not unprotected(world,e) then return false,"vessel-protected" end
    if not e.container:isRemoveItemAllowed(e.item) then return false,"storage-keeps-item" end
    if not main:isItemAllowed(e.item) or not main:hasRoomFor(p,e.item)
        or p:getFreeInventoryCapacity()<=e.item:getUnequippedWeight() then return false,"no-carry-capacity" end
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
        and W.signature(e) and (e.amount==0 or W.normalized(e.pourSignature)) then return lease end
end
function Loan.bind(...) return Log.guard("WorldLootFill.bind",bind,...) end

function Loan.source(p,a,e)
    return Log.guard("WorldLootFill.source",function()
        return W.live(p,a) and W.canReceive(p,a,e) and W.recipe(a) or nil
    end)
end
-- The fixture still delivers only what was chosen. How much it holds, and in
-- what exact ratio, is measured again when the fill starts: rain changes both.
local function sameSource(job)
    local a,chosen=job.pick.a,job.pick.source
    local o=a.object
    local reachable,why=W.live(job.p,a)
    if not reachable then return false,why end
    if not W.near(o:getFluidCapacity(),a.capacity) then return false,"fixture-capacity" end
    if o:getPrimaryFluid()~=a.primary or o:isTaintedWater()~=a.tainted then return false,"fixture-liquid" end
    local live=W.recipe(a)
    if not live or live.provider~=chosen.provider or live.component~=chosen.component then return false,"fixture-feed" end
    for kind,ratio in pairs(live.mix) do if ratio>.02 and not chosen.mix[kind] then return false,"fixture-mixture" end end
    local can,reason=W.canReceive(job.p,a,job.live)
    if not can then return false,reason end
    return true,nil,live
end

-- Each liquid is conserved, whatever total arrived.
local function expectedMix(self,e)
    local gain,total=e.amount-self.amount,e.amount
    if gain<=0 then return nil end
    local expected={}
    if self.amount>0 then
        local initial=W.normalized(self.mix)
        if not initial then return nil end
        for kind,ratio in pairs(initial) do expected[kind]=ratio*self.amount/total end
    end
    for kind,ratio in pairs(self.recipe.mix) do expected[kind]=(expected[kind] or 0)+ratio*gain/total end
    return expected
end
local function confirmed(self,e) return sameMix(W.normalized(I.mix(e)),expectedMix(self,e)) end
local function guard(self)
    if not self.enabled() then return false,"shortcut-disabled" end
    return visible(self.p,self.world,self.pick.lease)
end
local function unchanged(self)
    local ok,e=I.accessible(self.p,self.world,self.live,self.original.container)
    if not ok then return false,e end
    if not unprotected(self.world,e) then return false,"vessel-protected" end
    return exact(e,self.amount,self.mix,self.original.capacity)
end

function Loan.new(p,world,pick,enabled)
    local l=pick.lease
    local id=pick.a and pick.a.interaction or Log.intent("pour","Fill from a fixture",p)
    local function refuse(check,reason,...)
        Log.warn(id,"REFUSED","op","loot-fill","check",check,"reason",reason,"vessel",l and l.entry and Log.item(l.entry.item,p) or nil,
            "fixture",W.describe(pick.a),"player",Log.player(p),...)
        return nil,reason
    end
    local busy="Choose an available loot vessel and finish the current action."
    if not l or not pick.source or not l.entry or l.entry.scope~="loot" or type(enabled)~="function"
        or isServer() then return refuse("selection",busy) end
    local blocked=Actor.blocked(p)
    if blocked then return refuse("player: "..blocked,busy) end
    if not idle(p) then return refuse("queue-busy",busy,"queue",Log.queue(p)) end
    local e=l.entry
    local self=setmetatable({p=p,world=world,pick=pick,original=e,live=e,amount=e.amount,mix=e.pourSignature,recipe=pick.source,
        interaction=id,startedAt=getTimestampMs(),enabled=enabled,state="running",phase="pickup",name="Fill From",liters=0,count=0},Loan)
    local changed="The selected fixture, receiver, or inventory room changed."
    for _,test in ipairs({function() return guard(self) end,function() return unchanged(self) end,
        function() return canBorrow(p,world,e) end,function() return sameSource(self) end}) do
        local ok,why=test()
        if not ok then return refuse(why,changed) end
    end
    local adapter=l.ground and require("LootBox/PourGround") or require("LootBox/PourMove")
    self.move=adapter.new(p,id)
    Log.info(id,"START","op","loot-fill","vessel",Log.item(e.item,p),"litres",string.format("%.5f/%.5f",e.amount,e.capacity),
        "from",Log.container(e.container,p),"fixture",W.describe(pick.a),"player",Log.player(p))
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
    local emit=ok and Log.info or Log.warn
    emit(self.interaction,"END","op","loot-fill","state",self.state,"reason",self.reason,"check",self.check,"phase",self.phase,
        "borrowed",self.touched==true,"returned",self.restored==true,"litres",self.liters,"elapsedMs",getTimestampMs()-self.startedAt,
        "vessel",Log.item(self.live.item,self.p),"fixture",Log.guard("WorldLootFill.describe",W.describe,self.pick.a),
        "player",Log.player(self.p))
    if self.touched and not self.silent and PZActionCompletionHUD then
        Log.guard("WorldLootFill.card",PZActionCompletionHUD.show,self.p:getPlayerNum(),{brand="LOOTBOX",theme="loot",
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
        if self.stop then return false,"cancelled" end
        local ok,why=guard(self)
        if not ok then return false,why end
        if phase~="admit" then return true end -- reciprocal membership may lag the native receipt
        ok,why=unchanged(self)
        if not ok then return false,why end
        if back then return from:isRemoveItemAllowed(e.item),"main-keeps-item" end
        ok,why=canBorrow(self.p,self.world,e)
        if not ok then return false,why end
        return sameSource(self)
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
    if self.stop then return false,"cancelled" end
    local ok,why=guard(self)
    if not ok then return false,why end
    local blocked=Actor.blocked(self.p)
    if blocked then return false,"player: "..blocked end
    ok,why=unchanged(self)
    if not ok then return false,why end
    local live
    ok,why,live=sameSource(self)
    if not ok then return false,why end
    if not exactID(self.p:getInventory(),self.original.id,self.live.item)
        or not exactID(self.original.container,self.original.id,nil) then return false,"ambiguous-identity" end
    self.recipe=live
    return true
end
-- Put the borrowed vessel back, or say why the fill did not count and then put
-- it back: it stays with the player only when it can no longer be identified.
function Loan:putBack(reason,check)
    self.returnReason,self.check=reason,check
    if check then Log.warn(self.interaction,"STOPPED","phase",self.phase,"check",check,"reason",reason,"vessel",Log.item(self.live.item,self.p)) end
    local ok,e=I.accessible(self.p,self.world,self.live,self.original.container,true)
    if not ok or not W.near(e.capacity,self.original.capacity) or not unprotected(self.world,e) then
        self:finish(false,reason);return
    end
    self.live,self.amount,self.mix,self.job,self.phase=e,e.amount,e.amount>0 and I.mix(e) or nil,nil,"return"
end
function Loan:step()
    local open,check=guard(self)
    if not self.stop and not open then
        self.check=check
        self:cancel(false,"The original loot location or shortcut is no longer available.")
    end
    if not self:isBusy() then return end
    if self.move:isBusy() then
        local ok,why,item=self.move:poll()
        if ok==nil then return end
        if not ok then self:finish(false,self.stop or why or "The exact move was not confirmed.");return end
        local back=self.phase=="return"
        local holder=back and self.original.container or self.p:getInventory()
        local e=I.rebind(self.p,self.world,self.original,item,holder,self.original.container,self.pick.lease.ground)
        local same,why=exact(e,self.amount,self.mix,self.original.capacity)
        Log.trace(self.interaction,"LOAN",back and "returned" or "borrowed",Log.item(item,self.p),"matches",same,"check",not same and why or nil)
        if not same then
            self.check=why
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
        if self.stop then self:finish(false,self.stop);return end
        if self.job.state~="finished" or self.job.count~=1 then
            self:putBack(self.job.reason or "The fixture fill was not confirmed.",self.job.check or "fill-unconfirmed");return
        end
        self.liters,self.filled=self.job.liters,true
        self:putBack(nil)
        return
    end
    if self.stop or Actor.blocked(self.p) or not idle(self.p) then
        self.check=self.check or Actor.blocked(self.p) or "queue-busy"
        self:finish(false,self.stop or self.returnReason or "Movement or another action interrupted the fill.");return
    end
    if self.phase=="pickup" or self.phase=="return" then self:submitMove(self.phase=="return");return end
    local ready,problem=self:preflight()
    if not ready then
        self:putBack("The fixture or capacity changed before the fill; the unfilled vessel was returned.",problem)
        return
    end
    self.live.pourSignature=self.mix
    local function preflight(act)
        return self:preflight() and act.character==self.p and act.item==self.live.item and act.waterObject==self.pick.a.object
            and act.waterUnit and act.waterUnit>0 and act.waterUnit<=self.p:getFreeInventoryCapacity()
    end
    local job,why=require("LootBox/WorldFluidJob").new(self.p,self.world,self.pick.a,true,{self.live},
        function()return guard(self) and unprotected(self.world,self.live) end,preflight,self.interaction)
    if not job then self:putBack(why or "The fixture action was unavailable.","fill-refused");return end
    job.noHUD=true
    job.receipt=function(e) return confirmed(self,e) end
    self.job=job
    job:tick()
end
function Loan:tick()
    if self:isBusy() then
        local ok,err=pcall(self.step,self)
        if not ok then
            Log.fault(self.interaction,"WorldLootFill.step",err,"phase",self.phase)
            if self.stop then self:finish(false,self.stop)
            else self:cancel(false,"The game could not verify the exact fixture fill.") end
        end
    end
end
return Loan
