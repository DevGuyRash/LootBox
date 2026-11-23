-- Explicit native-boundary doubles. Pass the installed stock media/lua root
-- as arg[1] to run its original dispenser action body, not the normal suite's double.
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local function copy(t) local out={};for k,v in pairs(t) do out[k]=v end;return out end
local function list(t)
    return {size=function()return #t end,get=function(_,i)return t[i+1]end,
        contains=function(_,x) for _,v in ipairs(t) do if v==x then return true end end;return false end}
end
local function remove(t,x)
    for i,v in ipairs(t) do if v==x then table.remove(t,i);return end end
end
local function fc(owner,values,cap,locked)
    local f={owner=owner,parts=copy(values),cap=cap,locked=locked==true}
    function f:getOwner() return self.owner end
    function f:getAmount() local n=0;for _,v in pairs(self.parts) do n=n+v end;return n end
    function f:getCapacity() return self.cap end
    function f:getFreeCapacity() return self.cap-self:getAmount() end
    function f:isInputLocked() return self.locked end
    function f:isMultiTileMoveable() return false end
    function f:canPlayerEmpty() return true end
    function f:copyFluidsFrom(other) assert(not self.locked); self.parts=copy(other.parts) end
    function f:setInputLocked(value) self.locked=value end
    function f:createFluidSample()
        local keys,total={},self:getAmount()
        for k,v in pairs(self.parts) do if v>0 then keys[#keys+1]=k end end
        return {size=function()return #keys end,getFluid=function(_,n)return keys[n+1] end,
            getPercentage=function(_,n)return self.parts[keys[n+1]]/total end,release=function()end}
    end
    return f
end

local f,id
local BOTTLE="Base.WaterDispenserBottle"
local function item(typ,amounts,cap,holder)
    id=id+1
    local i={id=id,typ=typ,holder=holder}
    i.fluid=fc(i,amounts,cap)
    function i:getFluidContainer() return self.fluid end
    function i:getContainer() return self.holder end
    function i:getID()return self.id end
    function i:getFullType()return self.typ end
    function i:getName()return self.typ==BOTTLE and "Dispenser bottle" or "Milk bucket" end
    function i:isSealed()return false end
    function i:isFavorite()return self.favorite==true end
    function i:isWorn()return false end
    if holder then holder.rows[#holder.rows+1]=i end
    return i
end
function instanceItem(typ) assert(typ==BOTTLE);return item(typ,{Water=15},15) end
function isClient()return f.mp end
function isServer()return false end
function getTimestampMs()return f.now end
SafeHouse={isSafehouseAllowInteract=function(s,p)return s==f.square and p==f.player and not f.accessDenied end}
IsoDirections={N="N",E="E",S="S",W="W"}
ComponentType={FluidContainer="fluid"}
Metabolics={HeavyDomestic=1}
FluidContainer={}
function FluidContainer.CanTransfer(a,b)
    return not f.incompatible and not b.locked and a~=b and a:getAmount()>0 and b:getFreeCapacity()>.0001
end
FluidUtil={roundTransfer=function(n)return math.floor(n*1000+.5)/1000 end}

ISBaseTimedAction={}
function ISBaseTimedAction:derive(t) local a={Type=t};a.__index=a;return setmetatable(a,{__index=self}) end
function ISBaseTimedAction.new(t,p) return setmetatable({character=p},t) end
function ISBaseTimedAction:forceStop() self:stop() end
function ISBaseTimedAction:forceCancel() self.cancelled=true end
function ISBaseTimedAction:setActionAnim()end
function ISBaseTimedAction:perform() remove(f.q.queue,self);f.q.current=f.q.queue[1] end
function ISBaseTimedAction:stop() f.q.queue={};f.q.current=nil end
package.loaded["TimedActions/ISBaseTimedAction"]=true
ISTimedActionQueue={getTimedActionQueue=function(p)assert(p==f.player);return f.q end,add=function(a)
    f.q:addToQueue(a);f.enqueued[#f.enqueued+1]=a
end}
function sendAddItemToContainer(c,it) assert(c==f.main and c:contains(it));f.created=it end
function sendRemoveItemFromContainer(c,it) assert(c==f.main and c:contains(it));f.used=it end

if arg and arg[1] then
    assert(loadfile(arg[1].."/shared/TimedActions/ISAddTakeDispenserBottle.lua"))()
else
    ISAddTakeDispenserBottle=ISBaseTimedAction:derive("ISAddTakeDispenserBottle")
    function ISAddTakeDispenserBottle:new(p,a,i)
        return setmetatable({character=p,waterdispenser=a,square=a:getSquare(),bottle=i},self)
    end
    function ISAddTakeDispenserBottle:isValid() return true end
    function ISAddTakeDispenserBottle:waitToStart()return false end
    function ISAddTakeDispenserBottle:start()end
    function ISAddTakeDispenserBottle:complete()
        assert(not f.mp,"the client must never execute stock complete")
        local p,s,old=self.character,self.square,self.waterdispenser
        local saved=self.bottle and self.bottle:getFluidContainer() or old:getFluidContainer()
        if not self.bottle then
            local jug=p:getInventory():AddItem(BOTTLE)
            jug:getFluidContainer():copyFluidsFrom(saved)
            sendAddItemToContainer(p:getInventory(),jug)
        end
        s:transmitRemoveItemFromSquare(old);s:RemoveTileObject(old)
        local next=s:addWorkstationEntity(self.bottle and "WaterDispenser" or "WaterDispenserNoBottle","sprite")
        if self.bottle then
            local target=next:getFluidContainer()
            target:setInputLocked(false);target:copyFluidsFrom(saved);target:setInputLocked(true)
            sendRemoveItemFromContainer(p:getInventory(),self.bottle)
            p:getInventory():Remove(self.bottle)
        end
        next:sync();return true
    end
end
package.loaded["TimedActions/ISAddTakeDispenserBottle"]=true
package.loaded["LootBox/PourNative"]={new=function()
    return {
        isBusy=function(self)return self.pending~=nil end,
        start=function(self,a,b,amount,guard)
            if not FluidContainer.CanTransfer(a.fluid,b.fluid) or not guard(a,b,"admit") then return nil,"stock fluid rejected" end
            f.pours[#f.pours+1]={a,b}
            local moved=math.min(a.fluid:getAmount(),b.fluid:getFreeCapacity(),amount or math.huge)
            self.pending={a=a,b=b,guard=guard,amount=moved}
            return true,nil,moved
        end,
        cancel=function(self) self.pending.cancelled=true end,
        poll=function(self)
            if self.pending.cancelled then self.pending=nil;return false,"stock fluid stopped",0 end
            if not self.pending.reply then return nil end
            local reply=self.pending.reply
            self.pending=nil
            return true,nil,reply
        end}
end,transferAmount=function(have,free)
    local wanted=math.min(have,free)
    local amount=math.min(wanted,FluidUtil.roundTransfer(wanted))
    if amount>0 then return amount end
end}
local Inventory=require "LootBox/PourInventory"
local D=require "LootBox/MountedDispenser"

local function fixture(mp,contents,name)
    id=0;f={mp=mp,now=10,enqueued={},pours={}}
    local main={rows={}}
    f.main=main
    function main:contains(i)return list(self.rows):contains(i) end
    function main:getItems()return list(self.rows) end
    function main:getContainingItem()return nil end
    function main:getType()return "inventory" end
    function main:isLockedToCharacter()return false end
    function main:hasRoomFor(_,i) assert(i:getContainer()==nil);return not f.atCap end
    function main:AddItem(t) assert(t==BOTTLE); return item(t,{Water=15},15,self) end
    function main:Remove(i)assert(self:contains(i));remove(self.rows,i);i.holder=nil end
    local s={rows={},face=name or "N"}
    f.square=s
    function s:getX()return 5 end;function s:getY()return 4 end;function s:getZ()return 0 end
    function s:canReachTo(q)return q==s and not f.blocked end
    function s:getObjects()return list(self.rows) end
    function s:transmitRemoveItemFromSquare(o) assert(o:getObjectIndex()>=0) end
    function s:RemoveTileObject(o)remove(self.rows,o) end
    function s:addWorkstationEntity(t)
        local o={sq=self,name=t,facing=self.face}
        if t=="WaterDispenser" then o.fluid=fc(o,{Water=15},15,true) end
        function o:getEntityScript()return {getName=function()return self.name end,
            getModule=function()return {getName=function()return "Base" end}end} end
        function o:getSquare()return self.sq end
        function o:getFacing()return self.facing end
        function o:getObjectIndex()for i,v in ipairs(s.rows) do if v==self then return i-1 end end;return -1 end
        function o:getFluidContainer() return self.fluid end
        function o:hasComponent(t) return t==ComponentType.FluidContainer and self.fluid~=nil end
        function o:sync() if f.inject then f.inject(); f.inject=nil end end
        s.rows[#s.rows+1]=o
        return o
    end
    f.old=s:addWorkstationEntity(contents and "WaterDispenser" or "WaterDispenserNoBottle")
    if contents then f.old.fluid.parts=copy(contents) end
    local p={}
    f.player=p
    for _,name_ in ipairs({"isDead","isAsleep","isRunning","isSprinting","isAiming","isAttacking","isShoving",
        "isClimbing","isKnockedDown","isbFalling","isPerformingGrappleAnimation","isEquipped","isAttachedItem",
        "isEquippedClothing","isTimedActionInstant","shouldBeTurning"}) do p[name_]=function()return false end end
    function p:isMoving() return f.moving==true end
    function p:isLocalPlayer()return true end
    function p:getCurrentSquare()return s end;function p:getSquare()return s end
    function p:getX()return 5.5 end;function p:getY()return 4.5 end
    function p:getInventory()return main end
    function p:hasTimedActions()return f.java~=nil end
    function p:getCharacterActions()return list(f.java and {f.java} or {}) end
    function p:getPlayerNum()return 0 end
    function p:faceThisObject()end;function p:SetVariable()end;function p:playSound()end
    local q={queue={}}
    f.q=q
    function q:addToQueue(a)self.queue[#self.queue+1]=a;self.current=self.current or a end
    function q:removeFromQueue(a)remove(self.queue,a) end
    local world={protected=function(_,i)return i.protected==true end}
    f.world=world
    f.donor=item("Base.Bucket",{Milk=1.5,Water=.5},10,main)
    f.spare=item(BOTTLE,contents or {},15,main)
    f.anchor=assert(D.capture(p,{f.old}))
    function f:request(which,selected)
        local options=D.destinations(p,world,self.anchor)
        local target
        for _,e in ipairs(options) do if not which or e.item==which then target=e;break end end
        if not target then return end
        local sources,byItem={},{}
        for _,e in ipairs(D.donors(p,world)) do byItem[e.item]=e end
        for index,chosen in ipairs(selected or {self.donor}) do
            local entry=assert(byItem[chosen])
            entry.pourSignature=Inventory.mix(entry)
            sources[index]=entry
        end
        self.job=assert(D.new(p,world,self.anchor,selected and sources or sources[1],target,function()return not self.off end))
        return self.job
    end
    function f:perform(allowComplete)
        local a=assert(q.current)
        assert(a:isValid() and not a:waitToStart())
        a.action={};self.java=a.action
        a:start();a:perform()
        if allowComplete then assert(not self.mp);a:complete() end
        self.java=nil
        return a
    end
    function f:fluidReceipt(wrongMix,chosen)
        local s=assert(self.job.fluid.pending)
        assert(s.a==(chosen or self.donor) and s.b==self.job.jug and s.guard(s.a,s.b,"active"))
        local a,b=s.a.fluid,s.b.fluid
        local got=s.amount
        local total=a:getAmount()
        for k,v in pairs(a.parts) do
            local delta=v*got/total
            a.parts[k]=v-delta
            b.parts[k]=(b.parts[k] or 0)+delta
        end
        if wrongMix then b.parts={Petrol=b:getAmount()} end
        s.reply=got
    end
    return f
end

for _,face in ipairs({"N","S","E","W"}) do
    local test=fixture(false,{Milk=1,Water=.5},face)
    local d=assert(test:request())
    d:tick()
    assert(#test.enqueued==1 and test.enqueued[1].waterdispenser==test.old and not test.enqueued[1].bottle)
    test:perform(true);d:tick();d:tick()
    assert(d.jug==test.created and d.jug~=test.spare and #test.pours==1)
    local bare=test.square.rows[1]
    assert(bare~=test.old and not bare.fluid and bare.facing==face)
    test:fluidReceipt();d:tick();d:tick()
    assert(#test.enqueued==2 and test.enqueued[2].bottle==test.created and test.enqueued[2].waterdispenser==bare)
    test:perform(true);d:tick()
    local fitted=test.square.rows[1]
    assert(d.state=="finished" and d.count==1 and d.liters==2 and fitted~=bare and fitted.facing==face)
    assert(fitted.fluid.parts.Milk==2.5 and fitted.fluid.parts.Water==1 and fitted.fluid.locked)
    assert(test.used==test.created and test.main:contains(test.spare) and test.spare.fluid:getAmount()==1.5)
end
print("PASS mounted SP uses exactly one stock-created jug with spare untouched, exact fixture and mixture, all facings")

local t=fixture(true,{Milk=1})
assert(not t:request() and #t.enqueued==0)
-- Even two separate delayed replicas cannot turn a mounted click into an automatic MP choice.
item(BOTTLE,{Milk=1},15,t.main);t.main:Remove(t.spare)
assert(not t:request() and #t.enqueued==0 and #t.pours==0)

t=fixture(true,nil)
local delayedB=item(BOTTLE,{},15,t.main)
local d=assert(t:request(t.spare))
t.main:Remove(delayedB)
d:tick();assert(t.pours[1][2]==t.spare)
t:fluidReceipt();d:tick();d:tick()
assert(#t.enqueued==1 and t.enqueued[1].bottle==t.spare and t.enqueued[1].waterdispenser==t.old)
t:perform(false);d:tick()
assert(d.state=="finished_with_skips" and d.count==0 and d.liters==2 and t.main:contains(t.spare)
    and t.square.rows[1]==t.old and not t.old.fluid)
print("PASS MP continuation requires exact deliberate jug and reports request, never assumes refit or reacts to delayed B")

t=fixture(true,nil)
local a=t.spare
local b=item(BOTTLE,{},15,t.main)
d=assert(t:request(a));t.main:Remove(a)
d:tick();d:tick()
assert(d.state=="cancelled" and #t.enqueued==0 and #t.pours==0 and b.fluid:getAmount()==0)
t=fixture(true,nil)
d=assert(t:request(t.spare));d:tick();t:fluidReceipt();d:tick()
t.square:RemoveTileObject(t.old);local replacement=t.square:addWorkstationEntity("WaterDispenserNoBottle")
d:tick();d:tick()
assert(d.state=="cancelled" and t.square.rows[1]==replacement and #t.enqueued==0 and t.main:contains(t.spare))
print("PASS disappearing exact jug and same-square replacement never retarget or refit")

t=fixture(false,{Milk=1})
d=assert(t:request());d:tick();t:perform(true)
local created=t.created
t.main:Remove(created);item(BOTTLE,{Milk=1},15,t.main)
d:tick();d:tick()
assert(d.state=="cancelled" and #t.pours==0 and not d.jug, "do not accept a new matching ref after native cleanup")
t=fixture(false,{Milk=1})
d=assert(t:request());d:tick();t:perform(true)
t.created.id=t.created.id+1000
d:tick();d:tick()
assert(d.state=="cancelled" and #t.pours==0 and not d.jug, "an unchanged reference cannot authorize a changed ID")
t=fixture(false,{Milk=1})
d=assert(t:request());d:tick();t:perform(true);d:tick();d:tick()
t:fluidReceipt();d:tick();d:tick();t:perform(true)
local final=t.square.rows[1]
t.square:RemoveTileObject(final)
local matching=t.square:addWorkstationEntity("WaterDispenser")
matching.fluid.parts=copy(final.fluid.parts)
d:tick();d:tick()
assert(d.state=="cancelled" and d.count==0 and d.liters==2 and #t.enqueued==2, "a successor replaced after complete isn't our refit")
print("PASS queued cleanup cannot bind a changed jug reference or ID, or report a replaced finished stand")

-- Once the exact synchronous stock output is captured, later compatible
-- arrivals cannot change which jug is poured into (even before next tick).
t=fixture(false,{Milk=1})
d=assert(t:request());d:tick();t:perform(true)
local later=item(BOTTLE,{Milk=1},15,t.main)
d:tick();d:tick()
assert(d.jug==t.created and d.jug~=later and #t.pours==1 and t.pours[1][2]==t.created)
print("PASS the synchronous receipt keeps the exact native output despite a later lookalike")

-- Compatibility/mixture cannot disambiguate other in-call jug activity.
-- Even a nonmatching new jug could be the stock output with changed contents.
for _,change in ipairs({"extra-wrong-mixture","spare-removed","spare-replaced-same-id"}) do
    t=fixture(false,{Milk=1})
    d=assert(t:request());d:tick()
    t.inject=function()
        if change=="extra-wrong-mixture" then item(BOTTLE,{Water=1},15,t.main)
        else
            local spareID=t.spare:getID()
            t.main:Remove(t.spare)
            if change=="spare-replaced-same-id" then item(BOTTLE,{Milk=1},15,t.main).id=spareID end
        end
    end
    t:perform(true);d:tick();d:tick()
    assert(d.state=="cancelled" and #t.enqueued==1 and #t.pours==0 and not d.jug,change)
end
print("PASS synchronous receipt rejects a second new jug or changes to any preexisting jug reference")

t=fixture(false,{Milk=1})
-- Admission remains safe if the inventory exceeds the receipt's budget
-- after the action was queued, but before stock completion.
d=assert(t:request());d:tick()
for _=2,65 do item(BOTTLE,{},15,t.main) end
t:perform(true);d:tick()
assert(d.state=="cancelled" and #t.enqueued==1 and #t.pours==0 and not t.created and t.square.rows[1]==t.old)
t=fixture(false,{Milk=1})
for _=2,64 do item(BOTTLE,{},15,t.main) end
d=assert(t:request());d:tick();t:perform(true);d:tick()
assert(d.state=="cancelled" and #t.enqueued==1 and #t.pours==0 and t.created and not d.jug)
print("PASS the synchronous receipt bounds jug enumeration before and after stock completion")

t=fixture(false,{Milk=1})
d=assert(t:request());d:tick()
t:perform(true);d:tick()
local jug=d.jug
local old=t.square.rows[1]
d:cancel();d:tick();d:tick()
assert(d.state=="cancelled" and #t.enqueued==1 and #t.pours==0 and t.main:contains(jug) and t.square.rows[1]==old)
t=fixture(false,{Milk=1})
d=assert(t:request());d:tick()
local interrupted=assert(t.q.current)
interrupted.action={};t.java=interrupted.action
local manual={Type="Manual"};t.q:addToQueue(manual)
d:cancel();t.java=nil;d:tick();d:tick()
assert(d.state=="cancelled" and t.q.current==manual and t.square.rows[1]==t.old and not t.created and #t.enqueued==1)
print("PASS cancel before native mutation or after single detach is terminal, preserves foreign work, no retry")

t=fixture(false,{Milk=2})
d=assert(t:request());d:tick();t.inject=function() item(BOTTLE,{Milk=2},15,t.main) end
t:perform(true);d:tick();d:tick()
assert(d.state=="cancelled" and #t.enqueued==1 and #t.pours==0 and not d.jug)
t=fixture(false,{Milk=2});t.atCap=true
assert(not t:request() and #t.enqueued==0 and t.square.rows[1]==t.old)
t=fixture(false,{Milk=15})
assert(not t:request() and #t.enqueued==0 and t.square.rows[1]==t.old)
t=fixture(false,{Milk=1})
d=assert(t:request());t.incompatible=true;d:tick()
assert(d.state=="cancelled" and #t.enqueued==0 and t.square.rows[1]==t.old)
t=fixture(true,nil)
d=assert(t:request(t.spare));d:tick();t:fluidReceipt(true);d:tick();d:tick()
assert(d.state=="cancelled" and d.liters==0 and #t.enqueued==0 and t.main:contains(t.spare))
print("PASS ambiguous synchronous output, invalid chemistry, capacity and mispaired constituents do not progress")

for _,mp in ipairs({false,true}) do
    local test=fixture(mp,not mp and {Milk=1,Water=1} or nil)
    local source2=item("Base.Bottle",{Water=1.25},2,test.main)
    local job=assert(test:request(mp and test.spare or nil,{test.donor,source2}))
    job:tick()
    local bare=test.old
    if not mp then
        assert(#test.enqueued==1)
        test:perform(true);job:tick();job:tick()
        bare=test.square.rows[1]
        assert(bare~=test.old and not bare.fluid)
    end
    assert(#test.pours==1)
    test:fluidReceipt();job:tick();job:tick()
    assert(#test.pours==2 and test.pours[2][1]==source2 and test.pours[2][2]==job.jug)
    test:fluidReceipt(false,source2);job:tick();job:tick()
    assert(#test.enqueued==(mp and 1 or 2) and test.q.current.bottle==job.jug and test.q.current.waterdispenser==bare)
    test:perform(not mp);job:tick()
    assert(job:status().done==2 and job:status().total==2 and math.abs(job.liters-3.25)<.00005)
    if mp then
        assert(job.state=="finished_with_skips" and job.refitRequested and test.main:contains(job.jug))
        print("PASS manual multiplayer batch uses the two selected sources and only reports a refit request")
    else
        local fitted=test.square.rows[1]
        assert(job.state=="finished" and fitted.fluid.locked and fitted.fluid:getAmount()==5.25
            and fitted.fluid.parts.Milk==2.5 and fitted.fluid.parts.Water==2.75 and test.main:contains(test.spare))
        print("PASS single-player batch takes and refits once with the original jug, final mix and liters")
    end
end

local function menu()
    return {options={},addOption=function(self,n,t,c)
        local row={name=n,target=t,onSelect=c};self.options[#self.options+1]=row;return row
    end,addSubMenu=function(_,o,m)o.child=m end}
end
ISContextMenu={getNew=function()return menu() end}
function getTexture(k)return k end
function getSpecificPlayer()return f.player end
local Menu=require "LootBox/MountedDispenserMenu"
local function tip(o,_,s)o.help=s end
t=fixture(true,nil)
local second=item(BOTTLE,{},15,t.main)
local host,parent=menu(),menu()
local native=parent:addOption("Add Bottle",nil,function()end)
local app={world=t.world}
package.loaded["LootBox/App"]={get=function()return app end}
function app:refillDispenser(anchor,donor,bottle)
    assert(anchor.object==t.old and donor.item==t.donor and bottle.item==second)
    self.selected=(self.selected or 0)+1;return true
end
Menu.add(0,host,{t.old},app,tip)
local choice=assert(host.options[1].child.options[2])
assert(choice.itemForTexture==second and parent.options[1]==native)
for _,option in ipairs(choice.child.options) do
    if option.itemForTexture==t.donor then option.onSelect(option.target);option.onSelect(option.target) end
end
assert(app.selected==1 and #t.enqueued==0)
print("PASS exact visible menu makes jug and donor explicit, stock menu remains, one selection only")
