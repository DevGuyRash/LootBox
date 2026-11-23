local Inventory = require "LootBox/PourInventory"
local Fluid = require "LootBox/PourNative"
local CreatedItemReceipt = require "LootBox/CreatedItemReceipt"
local nativeClientAvailable = require("LootBox/MountedClientPolicy").enabled
local D = {}
D.__index = D
D.MAX_DONORS = 128

local BOTTLE = "Base.WaterDispenserBottle"
local MAX_ITEMS, MAX_JUGS, MAX_TILE, TIMEOUT = 4096, 64, 128, 20000
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function near(a,b) return finite(a) and finite(b) and math.abs(a-b)<=.00005 end
local function qFor(p) return ISTimedActionQueue.getTimedActionQueue(p) end
local function idle(p)
    local q=qFor(p)
    return q and not q.current and #q.queue==0 and not p:hasTimedActions()
end
local function safe(p)
    return not isServer() and p:isLocalPlayer() and not (p:isDead() or p:isAsleep() or p:isMoving()
        or p:isRunning() or p:isSprinting() or p:isAiming() or p:isAttacking() or p:isShoving()
        or p:isClimbing() or p:isKnockedDown() or p:isbFalling() or p:isPerformingGrappleAnimation())
end
local function kind(obj)
    local script=obj and obj.getEntityScript and obj:getEntityScript()
    local module=script and script:getModule()
    if not module or module:getName()~="Base" then return nil end
    local name=script:getName()
    if name=="WaterDispenser" then return "mounted" end
    if name=="WaterDispenserNoBottle" then return "bare" end
end
local function reached(p,square)
    local here=p:getCurrentSquare()
    if not here or not square or here:getZ()~=square:getZ() or p:getSquare()~=here
        or math.abs(p:getX()-(square:getX()+.5))>1.6 or math.abs(p:getY()-(square:getY()+.5))>1.6
        or not here:canReachTo(square) then return false end
    if isClient() then
        if not SafeHouse or not SafeHouse.isSafehouseAllowInteract or not SafeHouse.isSafehouseAllowInteract(square,p) then return false end
        local trading=ISTradingUI and ISTradingUI.GetUIForPlayer(p)
        if trading and trading:isVisible() then return false end
    end
    return true
end
local function slot(square,facing,strict)
    local list,found=square:getObjects(),nil
    if list:size()>MAX_TILE then return nil,false end
    for i=0,list:size()-1 do
        local obj=list:get(i)
        local k=kind(obj)
        if strict and not obj then return nil,false end
        if k and (strict or obj:getFacing()==facing) then
            if found or obj:getFacing()~=facing or obj:getSquare()~=square or obj:getObjectIndex()~=i then return nil,false end
            found={object=obj,square=square,facing=facing,kind=k}
        end
    end
    return found,true
end
local function sameSlot(a,b) return b and a.object==b.object and a.kind==b.kind end
local function activeSlot(p,a,strict)
    return reached(p,a.square) and sameSlot(a,slot(a.square,a.facing,strict))
end

local function sample(fc,owner)
    if not fc or fc:getOwner()~=owner or not fc:canPlayerEmpty() or fc:isMultiTileMoveable() then return nil end
    local cap,amount=fc:getCapacity(),fc:getAmount()
    if not finite(cap) or cap<=0 or not finite(amount) or amount<0 or amount>cap+.00005 then return nil end
    local mix=amount==0 and {} or Inventory.mix({fluid=fc})
    if not mix then return nil end
    return {fluid=fc,cap=cap,amount=amount,mix=mix}
end
local function sameMix(a,b)
    if not a or not b then return false end
    for k,n in pairs(a) do if not near(n,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function sameFluid(a,b)
    return a and b and near(a.cap,b.cap) and near(a.amount,b.amount) and sameMix(a.mix,b.mix)
end
local function pairedMix(source,receiver,afterSource,afterReceiver,moved)
    if not source or not receiver or not afterSource or not afterReceiver or not finite(moved) or moved<=0
        or not near(receiver.cap,afterReceiver.cap) or not near(source.cap,afterSource.cap)
        or not near(source.amount-moved,afterSource.amount) or not near(receiver.amount+moved,afterReceiver.amount) then return false end
    local kinds={}
    for _,s in ipairs({source,receiver,afterSource,afterReceiver}) do
        for k in pairs(s.mix) do kinds[k]=true end
    end
    for k in pairs(kinds) do
        local ratio=source.mix[k] or 0
        if not near(ratio*(source.amount-moved),(afterSource.mix[k] or 0)*afterSource.amount)
            or not near((receiver.mix[k] or 0)*receiver.amount+ratio*moved,(afterReceiver.mix[k] or 0)*afterReceiver.amount) then return false end
    end
    return true
end
local function mounted(a)
    local fc=a.object:getFluidContainer()
    if a.kind=="mounted" and fc and fc:isInputLocked() then return sample(fc,a.object) end
end
local function bottleFluid(i,p)
    local main=p:getInventory()
    if not i or i:getFullType()~=BOTTLE or i:getContainer()~=main or not main:contains(i) or i:isSealed()
        or i:isFavorite() or p:isEquipped(i) or p:isAttachedItem(i) or i:isWorn() then return nil end
    local fc=i:getFluidContainer()
    if fc and fc:getOwner()==i and not fc:isInputLocked() then return fc end
end
local function bottle(i,p) return sample(bottleFluid(i,p),i) end
local function preview(initial)
    -- An unspawned stock item supplies the real unlocked container and its
    -- native filled weight. No item or fluid is added to the player's world.
    local item=instanceItem(BOTTLE)
    local fc=item and item:getFluidContainer()
    if not fc or fc:isInputLocked() then return nil end
    fc:copyFluidsFrom(initial.fluid)
    local reading=sample(fc,item)
    if not sameFluid(initial,reading) then return nil end
    return item,reading
end
local function options(p,objects)
    local picked,seen
    for i,obj in ipairs(objects) do
        if i>MAX_TILE then return nil end
        local k=kind(obj)
        if k and (not seen or seen~=obj) then
            if picked then return nil end
            local square,face=obj:getSquare(),obj:getFacing()
            if not square or not face then return nil end
            local a=slot(square,face)
            if not a or a.object~=obj or not activeSlot(p,a) then return nil end
            picked,seen=a,obj
        end
    end
    return picked
end
function D.capture(p,objects)
    local ok,found=pcall(options,p,objects)
    return ok and found or nil
end
function D.mountedMPEnabled() return nativeClientAvailable()==true end

-- Near-zero is not an empty mount. Keep the native empty predicate distinct
-- from an uncertain small residual before scheduling the native Take.
local function eligibleMountedReading(reading)
    return reading and (reading.amount>.00005 or reading.amount==0 and reading.fluid:isEmpty()==true)
end
local function carriedDonor(e,main)
    local scope,item=e.scope,e.item
    return (scope=="main" or scope=="carried" or scope=="equipped") and item==e.object
        and item:getContainer()==e.container and not item:getWorldItem()
        and (e.container==main or item:isInPlayerInventory()==true)
end
local function inwardAmount(e,reading,main)
    if not carriedDonor(e,main) or not eligibleMountedReading(reading) then return nil end
    return Fluid.transferAmount(e.amount,reading.fluid:getFreeCapacity())
end
function D.plannedMountedTopUp(donor,destination)
    return destination.mpMain and inwardAmount(donor,destination.test,destination.mpMain) or nil
end
function D.destinations(p,world,a)
    if a.kind=="mounted" then
        local mp=isClient()
        if mp and (not D.mountedMPEnabled() or not activeSlot(p,a,true)
            or not SafeHouse.isSafehouseAllowLoot or SafeHouse.isSafehouseAllowLoot(a.square,p)~=true) then return {} end
        local reading=mounted(a)
        if not reading or not FluidUtil or FluidUtil.roundTransfer(reading.cap-reading.amount)<=0
            or mp and not eligibleMountedReading(reading) then return {} end
        local item, test=preview(reading)
        local main=p:getInventory()
        if not item or not main:hasRoomFor(p,item) then return {} end
        return {{item=item,state=reading,test=test,mpMain=mp and main or nil}}
    end
    if a.object:getFluidContainer() then return {} end
    local list=Inventory.snapshot(p,world,nil,nil).entries
    local out={}
    for _,e in ipairs(list) do
        if e.fullType==BOTTLE and e.container==p:getInventory() then
            local reading=not world:protected(e.item) and bottle(e.item,p)
            if reading and reading.cap>reading.amount then out[#out+1]={item=e.item,id=e.id,state=reading,test=reading,label=e.label} end
            if #out>12 then return {} end
        end
    end
    return out
end
function D.donors(p,world)
    local snapshot=Inventory.snapshot(p,world,nil,nil)
    return snapshot.entries,snapshot.truncated
end
function D.canFill(e,destination)
    if e.item==destination.item or not FluidUtil or not FluidContainer
        or destination.mpMain and not D.plannedMountedTopUp(e,destination)
        or FluidUtil.roundTransfer(math.min(e.amount,destination.test.cap-destination.test.amount))<=0 then return false end
    return FluidContainer.CanTransfer(e.fluid,destination.test.fluid)==true
end

local function jugRefs(main)
    local list,seen=main:getItems(),{}
    local n=0
    if list:size()>MAX_ITEMS then return nil end
    for i=0,list:size()-1 do
        local item=list:get(i)
        if not item then return nil end
        if item:getFullType()==BOTTLE then
            local id=item:getID()
            n=n+1
            if n>MAX_JUGS or not finite(id) or seen[id] or item:getContainer()~=main then return nil end
            seen[id]=item
        end
    end
    return seen
end
-- Passive, once-per-stage local receipts for an explicitly selected MP job.
-- No callback is installed and a missing reading cannot change job behavior.
local receiptSerial=0
local function receipt(self,phase,read)
    if not self.observed then return end
    pcall(function()
        if phase=="take-start" then
            receiptSerial=receiptSerial+1
            self.receiptSerial=receiptSerial
        elseif not self.receiptSerial then return end
        print(string.format("[LootBox] action=dispenser-refill receipt=%s job=%d %s",phase,self.receiptSerial,read()))
    end)
end
local function fluidRecord(it)
    local fc=it:getFluidContainer()
    if not fc then return nil end
    return {ref=it,amount=fc:getAmount(),cap=fc:getCapacity(),locked=fc:isInputLocked(),mix=Inventory.mix({fluid=fc}) or {}}
end
local function spareReading(self,initial)
    local rows=jugRefs(self.observed.main)
    if not rows then return "unavailable" end
    local ids={}
    if initial then
        self.receiptSpares={}
        for id,it in pairs(rows) do
            local rec=fluidRecord(it)
            if rec then self.receiptSpares[id]=rec end
        end
    end
    if not self.receiptSpares then return "unavailable" end
    for id in pairs(self.receiptSpares) do ids[#ids+1]=id end
    table.sort(ids)
    local out={}
    for _,id in ipairs(ids) do
        local old=self.receiptSpares[id]
        local rec=rows[id] and fluidRecord(rows[id])
        local unchanged=rec and rec.ref==old.ref and rec.locked==old.locked and sameFluid(old,rec)
        out[#out+1]=string.format("%.0f:%.6f:%s",id,rec and rec.amount or -1,
            initial and "baseline" or unchanged and "unchanged" or "changed")
    end
    return #out>0 and table.concat(out,",") or "none"
end
local function removed(before,after,item)
    if before[item:getID()]~=item or after[item:getID()] then return false end
    for id,it in pairs(before) do if it~=item and after[id]~=it then return false end end
    for id,it in pairs(after) do if before[id]~=it then return false end end
    return true
end
local function owns(q,a)
    if not q then return false end
    for _,entry in ipairs(q.queue) do if entry==a then return true end end
    return q.current==a
end
local function finishWindow(p,q,a)
    if not q or q.current or #q.queue>0 then return false end
    if not p:hasTimedActions() then return true end
    local java=p:getCharacterActions()
    return a.action and java and java:size()==1 and java:get(0)==a.action
end

-- Keep stock stop/perform's queue handling local to this action. A foreign
-- tail is restored on a later tick so it cannot run inside SP complete().
local function nativeEnd(p,s,callback,a,...)
    local q=qFor(p)
    if not q or q.current~=a then s.problem="The dispenser action is no longer current.";return end
    local tail={}
    for _,entry in ipairs(q.queue) do if entry~=a then tail[#tail+1]=entry end end
    if #tail==0 then return callback(a,...) end
    s.problem="Another action interrupted the dispenser."
    for _,entry in ipairs(tail) do q:removeFromQueue(entry) end
    local ok,out=pcall(callback,a,...)
    local function restore()
        if qFor(p)~=q then return end
        local pos=q.current and 2 or 1
        if q.current then
            for _,entry in ipairs(tail) do if not owns(q,entry) then table.insert(q.queue,pos,entry);pos=pos+1 end end
        else
            for _,entry in ipairs(tail) do if not owns(q,entry) then q:addToQueue(entry) end end
        end
    end
    s.restore=restore
    if Events and Events.OnTick then
        local f
        f=function()
            if s.restore and s.canRestore and not s:canRestore() then return end
            Events.OnTick.Remove(f)
            if s.restore then s.restore=nil;restore() end
        end
        Events.OnTick.Add(f)
    end
    if not ok then error(out,0) end
    return out
end

local function makeAction(self,refit)
    local p,a=self.player,self.anchor
    local item=refit and self.jug or nil
    local expected=refit and self.after or self.original
    if not idle(p) or not self:canUse(refit) or (not refit and self.mp) then return nil end
    require "TimedActions/ISAddTakeDispenserBottle"
    local act=ISAddTakeDispenserBottle:new(p,a.object,item)
    if not act or act.character~=p or act.waterdispenser~=a.object or act.square~=a.square or act.bottle~=item
        or not act.isValid or not act.waitToStart or not act.start or not act.perform or not act.stop or not act.complete
        or not act.forceStop or not act.forceCancel then return nil end
    local s={action=act,deadline=getTimestampMs()+TIMEOUT}
    local valid,wait,start,perform,stop,complete=act.isValid,act.waitToStart,act.start,act.perform,act.stop,act.complete
    local function allowed(ending)
        local q=qFor(p)
        if s.problem or self.cancelled or not self:canUse(refit) then return false end
        if ending then return s.performed and s.started and finishWindow(p,q,act) end
        return idle(p) or q and q.current==act and q.queue[1]==act and #q.queue==1
    end
    act.stopOnWalk,act.stopOnRun,act.stopOnAim=true,true,true
    function act:canMergeAction() return false end
    function act:isValid() return allowed() and valid(self) end
    function act:waitToStart()
        if not allowed() or not valid(self) then
            s.problem="The game refused the selected dispenser action."
            self:forceStop();return true
        end
        return wait(self)
    end
    function act:start(...)
        if not allowed() or not valid(self) then s.problem="The game refused the selected dispenser action.";self:forceStop();return end
        s.started=true
        return start(self,...)
    end
    function act:perform(...)
        s.performed=true
        return nativeEnd(p,s,perform,self,...)
    end
    function act:stop(...)
        s.problem=s.problem or "The stock dispenser action stopped."
        return nativeEnd(p,s,stop,self,...)
    end
    function act:complete(...)
        -- Only same-process authoritative execution has a synchronous receipt.
        if self.character~=p or isClient() or not allowed(true) or not valid(self) then return false end
        if refit then
            local before=jugRefs(p:getInventory())
            if not before then return false end
            local ok=complete(self,...)
            local after=jugRefs(p:getInventory())
            local result=slot(a.square,a.facing)
            if ok==true and after and result and result.object~=a.object and a.object:getObjectIndex()==-1
                and removed(before,after,item) and sameFluid(mounted(result),expected) then s.result=result end
            return ok
        end

        -- Stock B42.22 takes one jug synchronously via AddItem on this main
        -- inventory, copies the fixture contents, then replaces the fixture.
        -- Only this owned, same-process complete may establish that delivery
        -- order; no MP request, completion packet or later item diff can.
        local successor,stockReturned
        local receipt=CreatedItemReceipt.begin(self,{
            inventory=function() return p:getInventory() end,
            matches=function(candidate) return candidate:getFullType()==BOTTLE end,
            preserveMatching=true,maxMatches=MAX_JUGS,clock=getTimestampMs,
            anchor=function()
                return successor and successor.kind=="bare" and successor.object~=a.object
                    and not successor.object:getFluidContainer() and a.object:getObjectIndex()==-1 and activeSlot(p,successor)
            end,
            deliveredBeforeDone=function(owner,destination)
                return stockReturned==true and owner==self and destination==p:getInventory()
                    and not isClient() and not isServer()
            end,
        })
        if not receipt then return false end
        local ok=complete(self,...)
        if ok==true then
            successor=slot(a.square,a.facing)
            stockReturned=true
            if receipt:complete(self,{ordered=true}) then
                local confirmed,new=receipt:poll()
                if confirmed==true and sameFluid(bottle(new,p),expected) then
                    s.result,s.jug,s.jugID=successor,new,new:getID()
                end
            end
        end
        receipt:cancel()
        return ok
    end
    if not act:isValid() then return nil end
    ISTimedActionQueue.add(act)
    if not owns(qFor(p),act) and not s.performed then return nil end
    return s
end

local function captureDonors(selection)
    if type(selection)~="table" then return nil end
    local batch=selection.item==nil
    local list=batch and selection or {selection}
    local n,seen,records=#list,{},{}
    if n<1 or n>D.MAX_DONORS then return nil end
    for key in pairs(list) do
        if not finite(key) or key%1~=0 or key<1 or key>n then return nil end
    end
    for index=1,n do
        local entry=list[index]
        if type(entry)~="table" or not entry.item or not finite(entry.id) or entry.id%1~=0
            or seen[entry.id] or type(entry.pourSignature)~="table" then return nil end
        seen[entry.id]=true
        local reading=sample(entry.fluid,entry.item)
        local before
        if reading and near(reading.cap,entry.capacity) and near(reading.amount,entry.amount)
            and sameMix(reading.mix,entry.pourSignature) then before=reading end
        local identity={}
        for key,value in pairs(entry) do identity[key]=value end
        records[index]={entry=identity,before=before}
    end
    return records,batch
end

function D.new(p,world,a,selection,destination,allow)
    if type(allow)~="function" or not a or not safe(p) or not idle(p) or not activeSlot(p,a) then return nil,"Stand next to the selected dispenser and finish your current action." end
    local mp,observed=isClient(),isClient() and a.kind=="mounted"
    if mp and a.kind~="bare" and (not observed or not D.mountedMPEnabled()) then
        return nil,"Use the stock Take Bottle action first and select the exact detached bottle."
    end
    local donors,batch=captureDonors(selection)
    if not donors then return nil,"The selected sources are invalid, ambiguous, or too numerous; reopen the menu." end
    local f=setmetatable({player=p,world=world,anchor=a,donors=donors,batch=batch,mp=mp,allow=allow,
        state="running",phase=a.kind=="mounted" and "take" or "pour",liters=0,count=0,verified=0,skipped=0,cursor=1,
        name="Refill Dispenser",fluid=Fluid.new(p)},D)
    if a.kind=="mounted" then
        f.original=mounted(a)
        if not sameFluid(f.original,destination.state) then return nil,"The mounted bottle changed; reopen the menu." end
        f.preview,f.test=preview(f.original)
    else
        f.jug,f.jugID=destination.item,destination.id
        f.original=destination.state
        f.test=bottle(f.jug,p)
        if not f.jug or f.jugID~=f.jug:getID() or not sameFluid(f.test,f.original) then return nil,"The selected bottle changed; reopen the menu." end
    end
    if observed then
        local square,main,index,online=a.square,p:getInventory(),p:getPlayerNum(),p:getOnlineID()
        local cell=getCell()
        f.observed={square=square,here=p:getCurrentSquare(),main=main,index=index,online=online,
            cell=cell,queue=qFor(p),x=square:getX(),y=square:getY(),z=square:getZ()}
        if not finite(online) or online<0 or not cell or not f:scope() or not activeSlot(p,a,true) then
            return nil,"The mounted bottle or receiving space does not qualify."
        end
    end
    local first,index,amount=f:nextDonor(f.test)
    if not first then return nil,"No selected source can still pour into the exact bottle; reopen the menu." end
    f:setDonor(first,amount)
    f.cursor,f.skipped=index,index-1
    f.expected=f.original
    if observed and not f:canUse(false) then return nil,"The mounted bottle, donor, or receiving space does not qualify." end
    return f
end
function D:scope()
    local p,r=self.player,self.observed
    if self.allow()~=true or isClient()~=self.mp or not safe(p) then return false end
    if not r then return true end
    return D.mountedMPEnabled() and not self.cancelled and p==getSpecificPlayer(r.index)
        and p:getOnlineID()==r.online and p:getCurrentSquare()==r.here and p:getInventory()==r.main
        and qFor(p)==r.queue and getCell()==r.cell and r.cell:getGridSquare(r.x,r.y,r.z)==r.square
        and reached(p,r.square) and SafeHouse.isSafehouseAllowLoot
        and SafeHouse.isSafehouseAllowLoot(r.square,p)==true
end
function D:guard()
    return self:scope() and activeSlot(self.player,self.anchor,self.observed~=nil)
end
function D:carried(observe,record)
    local r=record or self.currentDonor
    if not r or not r.before then return nil end
    local ok,live=Inventory.accessible(self.player,self.world,r.entry,nil,observe)
    return ok and near(live.capacity,r.before.cap)
        and (not self.observed or carriedDonor(live,self.observed.main)) and live or nil
end
function D:matchedDonor(expected,record)
    local r=record or self.currentDonor
    if not r or not expected then return nil end
    local live=self:carried(expected~=r.before,r)
    local scope=self.observed
    if not live or self.world:protected(live.item) or not sameFluid(sample(live.fluid,live.item),expected) then return nil end
    if scope or self.batch then
        local exact,problem,holder=CreatedItemReceipt.findCarried(self.player:getInventory(),live.id)
        if problem or exact~=live.item or holder~=live.container then return nil end
    end
    return live
end
function D:nextDonor(target)
    if not target then return nil end
    for index=self.cursor,#self.donors do
        local record=self.donors[index]
        local live=self:matchedDonor(record.before,record)
        local main=self.observed and self.observed.main
        if live and live.id~=self.jugID and D.canFill(live,{item=self.jug,test=target,mpMain=main}) then
            local quantity
            if main then quantity=inwardAmount(live,target,main)
            elseif self.batch then quantity=Fluid.transferAmount(live.amount,target.fluid:getFreeCapacity()) end
            if quantity or not (main or self.batch) then return record,index,quantity,live end
        end
    end
end
function D:setDonor(record,amount)
    self.currentDonor,self.donor,self.from,self.amount=record,record.entry,record.before,amount
end
function D:heldJug()
    local jug,main=self.jug,self.player:getInventory()
    return jug and jug:getID()==self.jugID and jug:getFullType()==BOTTLE
        and jug:getContainer()==main and main:contains(jug)
end
-- During a batch an added same-ID row cannot impersonate the exact jug.
function D:exactBatchJug()
    if not self.batch then return true end
    local main=self.player:getInventory()
    local found,problem,holder=CreatedItemReceipt.findCarried(main,self.jugID)
    return not problem and found==self.jug and holder==main
end
function D:canUse(refit)
    if not self:guard() then return false end
    if refit then
        return self.anchor.kind=="bare" and not self.anchor.object:getFluidContainer()
            and self:heldJug() and self:exactBatchJug()
            and not self.world:protected(self.jug) and sameFluid(bottle(self.jug,self.player),self.after)
    end
    local live=self:matchedDonor(self.from)
    return sameFluid(mounted(self.anchor),self.original) and live
        and self.player:getInventory():hasRoomFor(self.player,self.preview)
        and D.canFill(live,{test=self.test,mpMain=self.observed and self.observed.main})
end
function D:isBusy() return self.state=="running" or self.state=="cancelling" end
function D:status()
    local done=self.batch and self.verified or self.count
    return {state=self.state,reason=self.reason,action="pour",intent="pour",hasJob=self:isBusy(),canPreview=not self:isBusy(),
        canResume=false,canPause=false,done=done,moved=done,total=self.batch and #self.donors or 1,
        pourLiters=self.liters,skipped=self.skipped,reasons={}}
end
function D:finish(state,reason)
    if not self:isBusy() then return end
    self.state,self.reason=state,reason
    if self.launched then
        pcall(function() print(string.format("[LootBox] action=dispenser-refill event=terminal state=%s phase=%s confirmedLitres=%.3f reason=%s",
            state,self.phase,self.liters,reason)) end)
        if not self.silent and PZActionCompletionHUD then
            pcall(function()
                PZActionCompletionHUD.show(self.player:getPlayerNum(),{brand="LOOTBOX",theme="loot",
                    title=self.count>0 and "Dispenser refilled" or self.refitRequested and "Dispenser refit requested" or "Dispenser refill stopped",
                    status=self.count==0 and state~="finished" and "stopped" or nil,
                    detail=string.format("%.3f L confirmed",self.liters),note=reason})
            end)
        end
    end
end
function D:fitted()
    self.count=1
    local why="The exact refilled bottle is fitted to its stand."
    if self.skipped>0 then
        why=why.." Unavailable or incompatible sources were left untouched."
        self:finish("finished_with_skips",why)
    else self:finish("finished",why) end
end
function D:stopped(reason)
    -- Unverified attempts never trigger another native leg or refit.
    if self.jug or self.phase=="take" and self.launched then
        local ok,held=pcall(self.heldJug,self)
        if ok and held then reason=reason.." The selected bottle is visible in main inventory. Check the stand before fitting."
        else reason=reason.." Bottle location unconfirmed. Check main inventory and the selected stand." end
    end
    self:finish("cancelled",reason)
end
local function cancelAction(p,s)
    if not s then return end
    if s.cancel then s:cancel();return end
    local q,a=qFor(p),s.action
    if q.current==a and a.action then a:forceStop()
    elseif owns(q,a) and q.current~=a then a:forceCancel();q:removeFromQueue(a) end
end
function D:cancel(silent)
    if not self:isBusy() or self.cancelled then return true end
    self.cancelled,self.silent,self.state=true,silent,"cancelling"
    if self.native and not self.native.stopRequested then
        if not self.native.cancel then self.native.stopRequested=true end
        cancelAction(self.player,self.native)
    end
    if self.fluid:isBusy() then self.fluid:cancel() end
    return true
end

local function observedAction(self,refit)
    local p,a=self.player,self.anchor
    return require("LootBox/MountedClientAction").start(p,a,refit and self.jug or nil,{
        live=function() return self:scope() and self:matchedDonor(refit and self.afterDonor or self.from)~=nil end,
        admit=function() return self:canUse(refit) end,
        useItem=function(i)
            for _,source in ipairs(self.donors) do
                if i==source.entry.item or i:getID()==source.entry.id then return false end
            end
            return not self.world:protected(i)
        end,
        slot=function() return slot(a.square,a.facing,true) end,
        jugUnchanged=function() return self:heldJug() and not self.world:protected(self.jug)
            and sameFluid(bottle(self.jug,p),self.after)==true end,
        fitted=function(result) return sameFluid(mounted(result),self.after)==true end,
    },nativeEnd)
end

function D:step()
    local p,s=self.player,self.native
    if s and self.observed then
        local ok,result=s:poll()
        if ok==nil then return end
        self.native=nil
        if not ok then self:stopped(result);return end
        if self.phase=="take" then
            local a=slot(result.square,result.facing,true)
            if not a or a.object~=result.stand or a.kind~="bare" or a.object:getFluidContainer()
                or a.square~=self.anchor.square or a.facing~=self.anchor.facing or result.item:getID()~=result.id
                or self.world:protected(result.item) or not sameFluid(bottle(result.item,p),self.original)
                or self.original.amount==0 and (result.item:getFluidContainer():getAmount()~=0
                    or result.item:getFluidContainer():isEmpty()~=true) then
                self:stopped("The exact dispenser bottle or its stand changed.");return
            end
            self.anchor,self.jug,self.jugID,self.phase=a,result.item,result.id,"pour"
            receipt(self,"take",function()
                return string.format("stand=bare facing=%s freshJug=%.0f jugLitres=%.6f spares=%s",
                    tostring(a.facing),result.id,self.original.amount,spareReading(self,false))
            end)
        elseif self.phase=="refit" and activeSlot(p,result,true) and sameFluid(mounted(result),self.after) then
            receipt(self,"refit",function()
                local read=mounted(result)
                local retired=CreatedItemReceipt.findCarried(self.observed.main,self.jugID)==nil
                    and self.jug:getContainer()==nil and self.jug:getWorldItem()==nil
                return string.format("stand=mounted facing=%s retiredJug=%.0f retired=%s mountedLitres=%.6f locked=%s donor=%.0f donorLitres=%.6f spares=%s",
                    tostring(result.facing),self.jugID,tostring(retired),read.amount,tostring(read.fluid:isInputLocked()),
                    self.donor.id,self.afterDonor.amount,spareReading(self,false))
            end)
            self:fitted()
        else self:stopped("The stock refit could not be confirmed.") end
        return
    end
    if s then
        if owns(qFor(p),s.action) then
            if self.cancelled or not self:guard() or getTimestampMs()>=s.deadline then
                s.problem=s.problem or "The dispenser action was interrupted."
                if not s.stopRequested then s.stopRequested=true;cancelAction(p,s) end
            end
            return
        end
        if s.restore and not idle(p) then return end
        if s.restore then local f=s.restore;s.restore=nil;f() end
        if not idle(p) and not s.problem then return end
        self.native=nil
        if self.cancelled or s.problem then self:stopped(s.problem or "Refill cancelled.");return end
        if self.phase=="take" and s.result and s.jug then
            if activeSlot(p,s.result) and s.jug:getID()==s.jugID and sameFluid(bottle(s.jug,p),self.original) then
                self.anchor,self.jug,self.jugID,self.phase=s.result,s.jug,s.jugID,"pour";return
            end
        elseif self.phase=="refit" then
            if s.result then
                local current=jugRefs(p:getInventory())
                if activeSlot(p,s.result) and sameFluid(mounted(s.result),self.after) and current and not current[self.jugID] then
                    self:fitted();return
                end
                self:stopped("The stand changed after the stock refit.");return
            end
            if self.mp and s.performed and s.started then
                self.refitRequested=true
                self:finish("finished_with_skips","The bottle was filled and stock refit was requested. Verify the stand.");return
            end
        end
        self:stopped("The stock dispenser result could not be confirmed.");return
    end
    if self.fluid:isBusy() then
        if not self.cancelled and not self:guard() then self:cancel() end
        if self.observed and not self.cancelled then
            local q,stack=qFor(p),p:getCharacterActions()
            local action=self.fluid.active and self.fluid.active.action
            if not q.current and #q.queue==0 and p:hasTimedActions()
                and (stack:size()==0 or stack:size()==1 and action and stack:get(0)==action.action) then
                self.pourTailAt=self.pourTailAt or getTimestampMs()
                if getTimestampMs()-self.pourTailAt<1500 then return end
                self:cancel()
            end
        end
        local ok,why,amount=self.fluid:poll()
        if ok==nil then return end
        local after=bottle(self.jug,p)
        local donor=self:carried(true)
        local afterDonor=donor and sample(donor.fluid,donor.item)
        local paired=self:heldJug() and pairedMix(self.from,self.before,afterDonor,after,amount)
        if paired then paired=self:matchedDonor(afterDonor)~=nil and self:exactBatchJug() end
        if paired then self.liters=self.liters+amount end
        if not ok or self.cancelled then self:stopped(why or "Refill cancelled.");return end
        if not paired or (self.observed or self.batch) and not near(amount,self.amount) then
            self:stopped("The exact filled bottle and its mixture could not be confirmed.");return
        end
        self.after,self.expected,self.afterDonor=after,after,afterDonor
        self.verified,self.cursor=self.verified+1,self.cursor+1
        receipt(self,"pour",function()
            return string.format("jug=%.0f jugFrom=%.6f jugTo=%.6f donor=%.0f donorFrom=%.6f donorTo=%.6f transferred=%.6f spares=%s",
                self.jugID,self.before.amount,self.after.amount,self.donor.id,self.from.amount,afterDonor.amount,
                amount,spareReading(self,false))
        end)
        if not self.batch or self.cursor>#self.donors or FluidUtil.roundTransfer(after.fluid:getFreeCapacity())<=0 then
            self.phase="refit"
        end
        return
    end
    if self.cancelled or not self:guard() or not idle(p) then self:stopped("Refill cancelled or no longer in reach.");return end
    if self.phase=="take" or self.phase=="refit" then
        local why
        if self.observed then self.native,why=observedAction(self,self.phase=="refit")
        else self.native=makeAction(self,self.phase=="refit") end
        if not self.native then self:stopped(why or "The game could not start the stock dispenser action.");return end
        if self.phase=="take" then
            receipt(self,"take-start",function()
                local r=self.observed
                return string.format("xyz=%d,%d,%d facing=%s mountedLitres=%.6f locked=%s donor=%.0f donorLitres=%.6f spares=%s",
                    r.x,r.y,r.z,tostring(self.anchor.facing),self.original.amount,tostring(self.original.fluid:isInputLocked()),
                    self.donor.id,self.from.amount,spareReading(self,true))
            end)
        end
        self.launched=true;return
    end
    local target=bottle(self.jug,p)
    if self.anchor.kind~="bare" or self.anchor.object:getFluidContainer()
        or not self:heldJug() or not self:exactBatchJug() or not sameFluid(target,self.expected)
        or self.world:protected(self.jug) then self:stopped("The exact bottle or stand changed.");return end
    local record,index,planned,live=self:nextDonor(target)
    if not record then
        if self.batch and self.after then
            self.skipped=self.skipped+#self.donors-self.cursor+1
            self.phase="refit";return
        end
        self:stopped("No selected source still qualifies for this bottle.");return
    end
    self.skipped,self.cursor=self.skipped+index-self.cursor,index
    self:setDonor(record,planned)
    self.before=target
    self.pourTailAt=nil
    local checkedAt
    local ok,why,amount=self.fluid:start(live.item,self.jug,self.amount,function(_,jug,phase)
        if not self:guard() or jug~=self.jug or not self:heldJug() or self.world:protected(jug)
            or self.world:protected(live.item) then return false end
        local donor=self:carried(phase=="observe")
        local fc=bottleFluid(jug,p)
        if not donor or not fc or not near(fc:getCapacity(),self.before.cap) then return false end
        if phase=="admit" then
            return self:matchedDonor(self.from)~=nil and self:exactBatchJug()
                and sameFluid(sample(fc,jug),self.before)==true
        end
        local at=getTimestampMs()
        if not checkedAt or at-checkedAt>=500 then
            if donor.amount>0 then
                local reading=sample(donor.fluid,donor.item)
                if not reading or not sameMix(reading.mix,self.from.mix) then return false end
            end
            if near(fc:getAmount(),self.before.amount) and not sameFluid(sample(fc,jug),self.before) then return false end
            checkedAt=at
        end
        return true
    end,self.observed~=nil)
    if not ok then self:stopped(why or "The game refused the pour.");return end
    if (self.observed or self.batch) and not near(amount,self.amount) then self:cancel();return end
    self.launched=true
end
function D:tick()
    if not self:isBusy() then return end
    local ok=pcall(self.step,self)
    if not ok then
        pcall(self.cancel,self)
        self:stopped("The game did not expose the required dispenser action.")
    end
end
return D
