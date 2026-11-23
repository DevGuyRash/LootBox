-- Disposable B42 observer contract. Java/packet projection are explicit doubles.
-- Explicit Lua/Java/queue/transport doubles, not native gameplay.
local stockRoot=arg and arg[1]
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local BOTTLE, WATER, OTHER="Base.WaterDispenserBottle",{},{}
local tests,f=0

local function list(t)
    return {size=function() return #t end,get=function(_,i) return t[i+1] end,
        contains=function(_,x) for _,i in ipairs(t) do if i==x then return true end end;return false end}
end
local function drop(rows,object)
    for i,v in ipairs(rows) do if v==object then table.remove(rows,i);return end end
end
local function fluid(owner,parts,locked,capacity)
    local liquid={owner=owner,parts=parts,locked=locked,capacity=capacity or 15,engineType="FluidContainer"}
    function liquid:getOwner() return self.owner end
    function liquid:getAmount() local amount=0;for _,n in pairs(self.parts) do amount=amount+n end;return amount end
    function liquid:getCapacity() return self.capacity end
    function liquid:isEmpty() return self:getAmount()==0 end
    function liquid:Empty() self.parts={} end
    function liquid:getFreeCapacity() return self.capacity-self:getAmount() end
    function liquid:getTransferRate() return 1 end
    function liquid:setInputLocked(value) self.locked=value end
    function liquid:copyFluidsFrom(other)
        assert(not self.locked);self.parts={}
        for kind,n in pairs(other.parts) do self.parts[kind]=n end
    end
    function liquid:isInputLocked() return self.locked end
    function liquid:canPlayerEmpty() return not self.disallowed end
    function liquid:isMultiTileMoveable() return false end
    function liquid:createFluidSample()
        local rows,total={},self:getAmount()
        for k,v in pairs(self.parts) do rows[#rows+1]={k,v/total} end
        return {size=function() return #rows end,getFluid=function(_,i) return rows[i+1][1] end,
            getPercentage=function(_,i) return rows[i+1][2] end,release=function() end}
    end
    return liquid
end
local function holder(containerItem)
    local h={rows={}}
    function h:getItems() return list(self.rows) end
    function h:getType() return containerItem and "bag" or "inventory" end
    function h:isLockedToCharacter() return self.locked==true end
    function h:hasRoomFor(_,i) return i:getContainer()==nil and not f.noHeadroom end
    function h:contains(item)
        for _,row in ipairs(self.rows) do if row==item then return true end end
        return false
    end
    function h:containsID(id)
        for _,row in ipairs(self.rows) do if row:getID()==id then return true end end
        return false
    end
    function h:Remove(item) assert(self:contains(item));drop(self.rows,item);item.holder=nil end
    function h:getContainingItem() return containerItem end
    return h
end
local function carriedIn(item,root)
    local direct=item:getContainer()
    local seen={}
    while direct and not seen[direct] and direct:contains(item) do
        if direct==root then return true end
        seen[direct]=true
        item=direct:getContainingItem()
        direct=item and item:getContainer()
    end
    return false
end
local function put(item,cont)
    if item.holder then item.holder:Remove(item) end
    cont.rows[#cont.rows+1]=item
    item.holder=cont
end
local function makeItem(id,typeName,cont,parts)
    local item={id=id,typeName=typeName,holder=cont,engineType="InventoryItem"}
    function item:getID() return self.id end
    function item:getFullType() return self.typeName end
    function item:getContainer() return self.holder end
    function item:getFluidContainer() return self.fluid end
    function item:getWorldItem() return self.ground end
    function item:isSealed() return self.sealed==true end
    function item:isFavorite() return self.favorite==true end
    function item:isWorn() return false end
    function item:isInPlayerInventory() return carriedIn(self,f.main) end
    function item:getItemHeat() return 1 end
    function item:syncItemFields() if self.onSync then self.onSync(self) end end
    if parts then item.fluid=fluid(item,parts,false) end
    if cont then cont.rows[#cont.rows+1]=item end
    return item
end
local function makeBag(id,typeName,cont)
    local bag=makeItem(id,typeName,cont)
    bag.pocket=holder(bag)
    function bag:getInventory() return self.pocket end
    return bag,bag.pocket
end
local function stand(square,name,facing,parts)
    local object={square=square,facing=facing,engineType="IsoObject"}
    function object:getEntityScript()
        return {getName=function() return name end,getModule=function()
            return {getName=function() return "Base" end}
        end}
    end
    function object:getSquare() return self.square end
    function object:getFacing() return self.facing end
    function object:getObjectIndex()
        for i,v in ipairs(self.square.rows) do if v==self then return i-1 end end
        return -1
    end
    function object:isExistInTheWorld() return self:getObjectIndex()>=0 end
    function object:getFluidContainer() return self.fluid end
    function object:hasComponent(c) return c==ComponentType.FluidContainer and self.fluid~=nil end
    if parts then object.fluid=fluid(object,parts,true) end
    square.rows[#square.rows+1]=object
    return object
end

function isServer() return f.authority==true end
function isClient() return not f.authority and f.mp~=false end
function getPlayer() return f.player end
function instanceof(o,typeName) return o and o.engineType==typeName end
function getTimestampMs() return f.time end
function getSpecificPlayer(index) if index==0 then return not f.replacedActor and f.player end end
function getCell() return f.cell end
IsoDirections={N={},E={},S={},W={}}
ComponentType={FluidContainer={}}
SafeHouse={isSafehouseAllowInteract=function(s,p) return s==f.square and p==f.player and not f.denied end,
    isSafehouseAllowLoot=function(s,p) return s==f.square and p==f.player and not f.deniedLoot end}
ISTimedActionQueue={getTimedActionQueue=function(p) assert(p==f.player);return f.q end,
    add=function(a) f.q:addToQueue(a) end}
ISBaseTimedAction={}
function ISBaseTimedAction:derive(name) local c={Type=name};c.__index=c;return setmetatable(c,{__index=self}) end
function ISBaseTimedAction.new(class,who) return setmetatable({character=who},class) end
function ISBaseTimedAction:setActionAnim() end
function ISBaseTimedAction:setOverrideHandModels() end
function ISBaseTimedAction:waitToStart() return false end
function ISBaseTimedAction:forceCancel() self.cancelled=true end
function ISBaseTimedAction:forceStop() self.action.forceStop=true end -- B42 only sets the Java flag
function ISBaseTimedAction:perform()
    f.stockPerforms=(f.stockPerforms or 0)+1
    assert(f.q.current==self and f.q.queue[1]==self)
    table.remove(f.q.queue,1);f.q.current=f.q.queue[1]
    if f.inStockPerform then f.inStockPerform() end
end
function ISBaseTimedAction:stop()
    f.stockStops=(f.stockStops or 0)+1
    assert(f.q.current==self and f.q.queue[1]==self)
    table.remove(f.q.queue,1);f.q.current=f.q.queue[1]
end
package.loaded["TimedActions/ISBaseTimedAction"]=true

if stockRoot then
    assert(loadfile(stockRoot.."/shared/TimedActions/ISAddTakeDispenserBottle.lua"))()
else
    ISAddTakeDispenserBottle=ISBaseTimedAction:derive("ISAddTakeDispenserBottle")
    function ISAddTakeDispenserBottle:new(p,object,bottle)
        return setmetatable({character=p,waterdispenser=object,square=object:getSquare(),bottle=bottle},self)
    end
    function ISAddTakeDispenserBottle:waitToStart() return self.character:shouldBeTurning() end
    function ISAddTakeDispenserBottle:isValid() return true end
    function ISAddTakeDispenserBottle:start()
        self.character:playSound(self.bottle and "WaterDispenserAddBottle" or "WaterDispenserRemoveBottle")
    end
end

package.loaded["TimedActions/ISAddTakeDispenserBottle"]=true

local function new(parts)
    f={time=1795249231830,sends=0,main=holder(),q={queue={}},java={}}
    local sq={rows={}}
    function sq:getX() return 10634 end
    function sq:getY() return 10417 end
    function sq:getZ() return 0 end
    function sq:getObjects() return list(self.rows) end
    function sq:canReachTo(s) return s==self and not f.blocked end
    f.square=sq
    f.cell={getGridSquare=function(_,x,y,z)
        assert(x==10634 and y==10417 and z==0)
        return not f.unloaded and sq or f.unloaded
    end}
    local p={}
    function p:getPlayerNum() return 0 end
    function p:getOnlineID() return f.online or 0 end
    function p:getInventory() return f.main end
    function p:getCurrentSquare() return f.actorSquare or sq end
    p.getSquare=p.getCurrentSquare
    function p:getX() return 10634.5 end
    function p:getY() return 10417.5 end
    function p:getZ() return 0 end
    function p:getCharacterActions() return list(f.java) end
    function p:isLocalPlayer() return not f.nonLocal end
    function p:isEquipped(i) return i.equipped==true end
    function p:isAttachedItem(i) return i.attached==true end
    function p:faceThisObject(o) assert(o==(f.exactFaceTarget or f.old)) end
    function p:shouldBeTurning() return f.turning==true end
    function p:isTimedActionInstant() return false end
    function p:SetVariable() end
    function p:playSound(name)
        if name=="WaterDispenserRemoveBottle" then f.stockStarts=(f.stockStarts or 0)+1
        else assert(name=="TransferLiquid" or name=="WaterDispenserAddBottle") end
    end
    for _,name in ipairs({"isDead","isAsleep","isMoving","isRunning","isSprinting","isAiming","isAttacking",
        "isShoving","isClimbing","isKnockedDown","isbFalling","isPerformingGrappleAnimation"}) do
        p[name]=function() return f[name]==true end
    end
    function p:hasTimedActions() return #f.java>0 end
    function p:setMetabolicTarget() end
    f.player=p
    function f.q:addToQueue(a)
        self.queue[#self.queue+1]=a
        if not self.current then self.current=a;a.action={};f.java[1]=a.action end
    end
    function f.q:removeFromQueue(a) drop(self.queue,a) end
    f.old=stand(sq,"WaterDispenser",IsoDirections.E,parts or {[WATER]=13.125204})
    f.control=makeItem(73121619,BOTTLE,f.main,{})
    f.bag,f.pocket=makeBag(100,"Base.Bag",f.main)
    f.bagControl=makeItem(101,BOTTLE,f.pocket,{[WATER]=15})
    function f:juggle(newId,parts,where)
        return makeItem(newId or 1635801116,BOTTLE,where or self.main,parts or {[WATER]=13.125204})
    end
    function f:retire() drop(self.square.rows,self.old) end
    function f:bare(facing,parts)
        return stand(self.square,"WaterDispenserNoBottle",facing or self.old.facing,parts)
    end
    function f:released() self.java={} end
    return f
end
local function test(name,run) run();tests=tests+1;print("PASS "..name) end
local function copy(source) local result={};for k,v in pairs(source) do result[k]=v end;return result end
local function close(a,b) return math.abs(a-b)<=.00005 end
FluidUtil={roundTransfer=function(n) return math.floor(n*100+.5)/100 end,
    getTransferActionTimePerLiter=function() return 40 end,getMinTransferActionTime=function() return 30 end}
FluidContainer={}
function FluidContainer.CanTransfer(a,b)
    return not f.incompatible and (not f.extraCompatibility or f.extraCompatibility(a,b))
        and a~=b and a:canPlayerEmpty() and b:canPlayerEmpty() and not b:isInputLocked()
        and a:getAmount()>0 and b:getFreeCapacity()>0
end
function FluidContainer.Transfer(a,b,amount)
    assert(isServer() and not isClient(), "Only the authority model transfers stock fluids")
    local total=a:getAmount()
    assert(amount>0 and amount<=total and amount<=b:getFreeCapacity())
    for kind,n in pairs(a.parts) do
        local moved=n*amount/total
        a.parts[kind],b.parts[kind]=n-moved,(b.parts[kind] or 0)+moved
    end
end
ISBaseObject={derive=ISBaseTimedAction.derive,new=function() return {} end}
package.loaded["ISBaseObject"]=true
if stockRoot then
    assert(loadfile(stockRoot.."/shared/Fluids/ISFluidContainer.lua"))()
    assert(loadfile(stockRoot.."/shared/Fluids/ISFluidUtil.lua"))()
    assert(loadfile(stockRoot.."/shared/Fluids/ISFluidTransferAction.lua"))()
else
    ISFluidContainer=ISBaseObject:derive("ISFluidContainer")
    function ISFluidContainer:new(fc) return setmetatable({fc=fc},self) end
    function ISFluidContainer:getFluidObject() return self.fc end
    function ISFluidContainer:getFluidContainer() return self.fc end
    function ISFluidContainer:getOwner() return self.fc.getOwner(self.fc) end
    function ISFluidTransferActionFallback(class,p,source,sourceFluid,target,targetFluid,amount)
        assert(sourceFluid==source:getFluidObject() and targetFluid==target:getFluidObject())
        return setmetatable({character=p,sourceFluidObject=sourceFluid,targetFluidObject=targetFluid,
            amount=amount,maxTime=40*amount,sourceOwner=source:getOwner(),targetOwner=target:getOwner()},class)
    end
    ISFluidTransferAction=ISBaseTimedAction:derive("ISFluidTransferAction")
    ISFluidTransferAction.new=ISFluidTransferActionFallback
    function ISFluidTransferAction:isValid() return FluidContainer.CanTransfer(self.sourceFluidObject,self.targetFluidObject) end
    function ISFluidTransferAction:update() end
    function ISFluidTransferAction:complete()
        FluidContainer.Transfer(self.sourceFluidObject,self.targetFluidObject,self.amount)
        return true
    end
    function ISFluidTransferAction:start() self.character:playSound("TransferLiquid") end
end
for _,name in ipairs({"ISFluidContainer","ISFluidUtil","ISFluidTransferAction"}) do package.loaded["Fluids/"..name]=true end

local function owns(x,a)
    return x.q.current==a and x.q.queue[1]==a and a.action and x.java[1]==a.action and #x.java==1
end
local function idle(x) return x.q.current==nil and #x.q.queue==0 and #x.java==0 end
local function release(x,a)
    assert(x.java[1]==a.action and #x.java==1)
    x:released()
    if x.tail then
        local keep=x.tail;x.tail=nil
        for _,pending in ipairs(keep) do x.q:addToQueue(pending) end
    end
end
local function engineStart(x,a) -- exact Java call boundary, not transport emulation
    if not a:isValid() or a:waitToStart()~=false then return false end
    a:start()
    x.sends=x.sends+1
    return true
end
local function authorityPour(x,flow)
    local root=holder()
    local function mirror(original)
        if original==x.main then return root end
        local bag=assert(original:getContainingItem())
        local _,pocket=makeBag(bag:getID(),bag:getFullType(),mirror(bag:getContainer()))
        return pocket
    end
    local a=makeItem(flow.donor:getID(),flow.donor:getFullType(),mirror(flow.donor:getContainer()),copy(flow.donor.fluid.parts))
    local b=makeItem(flow.result.id,BOTTLE,root,copy(flow.result.item.fluid.parts))
    for _,i in ipairs({a,b}) do function i:isInPlayerInventory() return carriedIn(self,root) end end
    x.authority=true
    local act=ISFluidTransferAction:new(x.player,ISFluidContainer:new(a.fluid),a.fluid,
        ISFluidContainer:new(b.fluid),b.fluid,flow.wanted)
    assert(act:complete())
    x.authority=false
    return copy(a.fluid.parts),copy(b.fluid.parts)
end

-- This fixture never advertises LootBox. Native actions, not an advertised
-- mod identifier, provide the execution and receipt boundaries.
function getActivatedMods() return list({"SomeOtherMod"}) end
local Policy=require "LootBox/MountedClientPolicy"
local D=require "LootBox/MountedDispenser"
local Menu=require "LootBox/MountedDispenserMenu"
local Inv=require "LootBox/PourInventory"
local function menu()
    return {options={},addOption=function(self,n,target,onSelect)
        local row={name=n,target=target,onSelect=onSelect}
        self.options[#self.options+1]=row;return row
    end,addSubMenu=function(_,o,b)o.child=b end}
end
ISContextMenu={getNew=function()return menu() end}
function getTexture(text) return text end
function instanceItem(typ) return makeItem(5001,typ,nil,{[WATER]=15}) end
local function fixture(parts)
    local x=new(parts)
    function x.player:faceThisObject(o) assert(o==self.facingTarget or o==x.old) end
    x.pocket:Remove(x.bagControl)
    x.donor=makeItem(110,"Base.WaterBottle",x.main,{[OTHER]=1})
    x.donorId,x.donorType=x.donor.id,x.donor.typeName
    x.world={protected=function(_,it)
        return it.protected==true or it:isFavorite() or x.player:isEquipped(it) or x.player:isAttachedItem(it)
    end}
    x.anchor=assert(D.capture(x.player,{x.old}))
    function x:selection(items)
        local destination=D.destinations(self.player,self.world,self.anchor)[1]
        local byItem={}
        for _,entry in ipairs(D.donors(self.player,self.world)) do byItem[entry.item]=entry end
        local wanted={}
        for index,item in ipairs(items) do
            local entry=byItem[item]
            if not entry then return nil end
            entry.pourSignature=Inv.mix(entry)
            wanted[index]=entry
        end
        return wanted,destination
    end
    function x:ask(items)
        local wanted,destination=self:selection(items or {self.donor})
        if not wanted or not destination then return nil end
        self.job=D.new(self.player,self.world,self.anchor,items and wanted or wanted[1],destination,function()return not self.disabled end)
        return self.job
    end
    function x:queueTake(items)
        assert(self:ask(items));self.job:tick()
        local a=assert(self.q.current,self.job.reason)
        assert(a.Type=="ISAddTakeDispenserBottle" and a.bottle==nil and a.waterdispenser==self.old)
        return a
    end
    function x:landTake(newItem,take,early)
        if early then assert(take:isValid()) end
        self:retire()
        self.job:tick()
        if not self.job:isBusy() then return end
        self.bareActual=self:bare()
        take:perform();release(self,take)
        self.job:tick()
        assert(self.job.phase=="take","stock perform is not the receipt")
        self.time=self.time+350;self.job:tick()
        if self.job:isBusy() then
            assert(self.job.phase=="pour" and self.job.jug==newItem and self.job.anchor.object==self.bareActual)
        end
    end
    return x
end

local function show(x)
    local m=menu()
    local action=m:addOption("Take Bottle",nil,function()end)
    local app={world=x.world}
    local selected=0
    package.loaded["LootBox/App"]={get=function()return app end}
    function app:refillDispenser(anchor,donor)
        assert(anchor.object==x.old and donor.item==x.donor);selected=selected+1;return true
    end
    local function tip(o,_,text)o.tip=text end
    Menu.add(0,m,{x.old},app,tip);Menu.add(0,m,{x.old},app,tip)
    assert(#m.options==2 and m.options[1]==action)
    return m.options[2],function()return selected end
end

test("mounted shortcut uses stock client bindings, independent of server add-on activation",function()
    local x=fixture({})
    assert(Policy.enabled() and D.mountedMPEnabled())
    assert(require("LootBox/MountedClientAction").start()==nil)
    local old=getActivatedMods
    for _,reader in ipairs({function() return list({}) end, function() return nil end,
            function() error("Server addon list must never be queried") end}) do
        getActivatedMods=reader
        local target=fixture({})
        assert(Policy.enabled() and target:ask() and #target.q.queue==0)
        local option,count=show(target)
        assert(option.child and not option.notAvailable and option.name=="Top up mounted dispenser")
        for _,choice in ipairs(option.child.options) do
            assert(choice.itemForTexture==target.donor)
            assert(choice.name:find("add 1.000 L (1.000 L available)",1,true))
            choice.onSelect(choice.target);choice.onSelect(choice.target)
        end
        assert(count()==1 and #target.q.queue==0)
    end
    getActivatedMods=old

    local interact=SafeHouse.isSafehouseAllowInteract
    x=fixture({})
    SafeHouse.isSafehouseAllowInteract=nil
    assert(not Policy.enabled() and not x:ask() and #x.q.queue==0)
    SafeHouse.isSafehouseAllowInteract=interact
    local clock=getTimestampMs
    getTimestampMs=nil
    assert(not Policy.enabled() and not x:ask() and #x.q.queue==0)
    local blocked=show(x)
    assert(blocked.notAvailable and not blocked.child and blocked.tip:find("Use stock Take Bottle",1,true))
    getTimestampMs=clock
    assert(Policy.enabled())
end)

local function detach(x,items)
    local take=x:queueTake(items)
    assert(engineStart(x,take) and x.sends==1,"owned native take did not start")
    local item=x:juggle(nil,copy(x.old.fluid.parts))
    x:landTake(item,take,true)
    assert(x.job:isBusy(),x.job.reason)
    return item
end
local function startPour(x,jug,wanted,source)
    wanted,source=wanted or 1,source or x.donor
    local oldSends=x.sends
    x.job:tick()
    local a=assert(x.q.current,x.job.reason)
    assert(a.Type=="ISFluidTransferAction" and math.abs(a.amount-wanted)<.00005 and a.sourceOwner==source and a.targetOwner==jug)
    assert(engineStart(x,a) and x.sends==oldSends+1,"owned native pour did not start")
    local left,right=authorityPour(x,{donor=source,result={item=jug,id=jug.id},wanted=wanted})
    return a,left,right
end
local function pourToRefit(x,jug,wanted)
    wanted=wanted or 1
    local a,left,right=startPour(x,jug,wanted)
    a:perform();release(x,a)
    x.donor.fluid.parts=left
    x.job:tick()
    assert(x.job.phase=="pour" and not x.q.current,"one-sided delta must not refit")
    jug.fluid.parts=right
    x.time=x.time+100;x.job:tick()
    assert(x.job.phase=="refit" and math.abs(x.job.liters-wanted)<.00005 and x.job:isBusy(),x.job.reason)
    x.job:tick()
    local refit=assert(x.q.current,x.job.reason)
    assert(refit.Type=="ISAddTakeDispenserBottle" and refit.bottle==jug and refit.waterdispenser==x.bareActual)
    x.player.facingTarget=x.bareActual
    assert(engineStart(x,refit) and x.sends==3)
    return refit,right
end

test("A3 nonempty mix and exact zero both carry only the native ID through pour and locked refit",function()
    for _,initial in ipairs({{}, {[WATER]=12.497615}}) do
        local x=fixture(initial)
        local jug=detach(x)
        assert(jug~=x.control and x.control.fluid:isEmpty())
        local a,final=pourToRefit(x,jug)
        drop(x.square.rows,x.bareActual)
        x.job:tick()
        local mounted=stand(x.square,"WaterDispenser",IsoDirections.E,{[WATER]=6})
        assert(a:isValid())
        a:perform();release(x,a)
        x.main:Remove(jug)
        x.time=x.time+450;x.job:tick()
        assert(x.job:isBusy(),"default sprite with retired ID is not receipt")
        mounted.fluid.parts=final
        x.job:tick()
        assert(x.job:isBusy(),"projected contents must settle")
        x.time=x.time+350;x.job:tick()
        assert(x.job.state=="finished" and x.job.count==1 and x.main:contains(x.control)
            and x.control.fluid:isEmpty() and not x.main:contains(jug) and mounted.fluid.locked
            and math.abs(mounted.fluid:getAmount()-((initial[WATER] or 0)+1))<.00005,
            x.job.reason)
    end
end)

test("compatible mix fills exactly to capacity without emptying a partially used donor",function()
    local x=fixture({[WATER]=14.625})
    local jug=detach(x)
    local a,final=pourToRefit(x,jug,.375)
    assert(math.abs(final[WATER]-14.625)<.00005 and math.abs(final[OTHER]-.375)<.00005)
    assert(math.abs(x.donor.fluid:getAmount()-.625)<.00005)
    drop(x.square.rows,x.bareActual)
    local mounted=stand(x.square,"WaterDispenser",IsoDirections.E,copy(final))
    a:perform();release(x,a);x.main:Remove(jug)
    x.job:tick();x.time=x.time+350;x.job:tick()
    assert(x.job.state=="finished" and mounted.fluid.locked and mounted.fluid:getAmount()==15,x.job.reason)
end)

test("native donor-empty and receiver-full mirrors may lead Done without completing early",function()
    for _,scenario in ipairs({"donorFirst","receiverFirst","missing","overshot"}) do
        local receiverFirst=scenario=="receiverFirst"
        local x=fixture(receiverFirst and {[WATER]=14.625} or {})
        local jug=detach(x)
        local pour,left,right=startPour(x,jug,receiverFirst and .375 or 1)
        if receiverFirst then jug.fluid.parts=right else x.donor.fluid.parts=left end
        assert(pour:isValid(),"A matching one-sided terminal delta must not invalidate the exact native pour")
        pour:update()
        assert(not pour.action.forceStop and x.job.phase=="pour")
        pour:perform();release(x,pour);x.job:tick()
        assert(x.job:isBusy() and x.job.phase=="pour" and not x.q.current)
        if receiverFirst then x.donor.fluid.parts=left
        elseif scenario=="overshot" then jug.fluid.parts={[OTHER]=1.01}
        elseif scenario~="missing" then jug.fluid.parts=right end
        x.time=x.time+(scenario=="missing" and 7100 or 100);x.job:tick()
        if scenario=="missing" or scenario=="overshot" then
            assert(x.job.state=="cancelled" and x.sends==2 and not x.q.current)
        else
            assert(x.job.phase=="refit" and x.job:isBusy() and x.sends==2)
        end
    end
end)

test("wrong amount, missing candidate, unrelated inventory and transient ID fail closed",function()
    for _,mode in ipairs({"nonzero","spareOnly","baselineLost","baselineType","unrelated","two","shadowId","movement","wrongActor","transient","holder","protected"}) do
        local x=fixture({})
        local a=x:queueTake()
        assert(engineStart(x,a))
        local jug
        if mode~="spareOnly" then
            jug=x:juggle(nil,mode=="nonzero" and {[WATER]=.000001} or {},mode=="holder" and x.pocket or nil)
        end
        if mode=="baselineLost" or mode=="baselineType" then
            local existing=x.main.rows[2];assert(existing~=x.donor)
            if mode=="baselineLost" then x.main:Remove(existing) else existing.typeName="Base.Suitcase" end
        elseif mode=="unrelated" then makeItem(666,"Base.Tissue",x.main)
        elseif mode=="two" then x:juggle(777,{})
        elseif mode=="shadowId" then x:juggle(x.control.id,{})
        elseif mode=="movement" then x.isMoving=true
        elseif mode=="wrongActor" then x.replacedActor=true
        elseif mode=="transient" then assert(a:isValid());x.main:Remove(jug)
        elseif mode=="protected" then jug.protected=true end
        x:retire();x:bare()
        if x.q.current==a then a:perform();release(x,a) end
        x.job:tick();x.time=x.time+7500;x.job:tick()
        assert(x.job.state=="cancelled" and x.sends==1 and x.job.count==0 and not x.q.current,mode)
    end
end)

test("invalid starting restrictions never queue or send a stock Take",function()
    for _,mode in ipairs({"smallResidual","notNativeEmpty","full","badChemistry","protected","noHeadroom",
                          "blocked","deniedInteract","deniedLoot","replaced","dropped","lockedSource","equippedSource","oversized","disabled"}) do
        local parts=mode=="smallResidual" and {[WATER]=.000001} or mode=="full" and {[WATER]=15} or {}
        local x=fixture(parts)
        if mode=="notNativeEmpty" then function x.old.fluid:isEmpty()return false end
        elseif mode=="badChemistry" then x.incompatible=true
        elseif mode=="protected" then x.donor.protected=true
        elseif mode=="noHeadroom" then x.noHeadroom=true
        elseif mode=="blocked" then x.blocked=true
        elseif mode=="deniedInteract" then x.denied=true
        elseif mode=="deniedLoot" then x.deniedLoot=true
        elseif mode=="replaced" then x.replacedActor=true
        elseif mode=="dropped" then x.donor.ground={}
        elseif mode=="lockedSource" then
            put(x.donor,x.pocket);x.pocket.locked=true
        elseif mode=="equippedSource" then x.donor.equipped=true
        elseif mode=="oversized" then
            for i=1,4096 do makeItem(10000+i,"Base.Tissue",x.main) end
        elseif mode=="disabled" then x.disabled=true end
        if x:ask() then x.job:tick() end
        assert(#x.q.queue==0 and x.sends==0,mode)
    end
end)

test("pre-send fence stops only the owned action and preserves foreign tail",function()
    local x=fixture({})
    local a=x:queueTake()
    local foreign={Type="OrdinaryFollowup"}
    x.q:addToQueue(foreign)
    assert(not engineStart(x,a) and a.action.forceStop,"invalid ownership crossed pre-send")
    assert(not x.q.current,"foreign started under old Java owner")
    release(x,a)
    x.job:tick()
    assert(x.sends==0 and x.job.state=="cancelled" and x.q.current==foreign and x.q.queue[1]==foreign)
end)

test("a changed Java handle is not stopped, performed, or misattributed to the exact owned action",function()
    local x=fixture({})
    local a=x:queueTake()
    local foreign={}
    x.java[1]=foreign
    assert(not engineStart(x,a))
    x.job:tick()
    assert(x.job.state=="cancelled" and x.sends==0 and not foreign.forceStop and not a.action.forceStop
        and not x.stockPerforms and not x.stockStops)
end)

test("refit never confirms a different or surviving ID, stale stand, unlock, or timeout",function()
    for _,mode in ipairs({"alive","wrongRetired","dropped","lockedWrong","duplicateStand","anotherActor"}) do
        local x=fixture({})
        local r=detach(x)
        local a,right=pourToRefit(x,r)
        drop(x.square.rows,x.bareActual)
        local mounted=stand(x.square,"WaterDispenser",IsoDirections.E,copy(right))
        if mode=="wrongRetired" then x.main:Remove(x.control)
        elseif mode=="lockedWrong" then mounted.fluid.locked=false;x.main:Remove(r)
        elseif mode=="duplicateStand" then stand(x.square,"WaterDispenser",IsoDirections.N,copy(right))
        elseif mode=="dropped" then x.main:Remove(r);r.ground={}
        elseif mode=="anotherActor" then x.replacedActor=true end
        a:perform();release(x,a)
        x.job:tick();x.time=x.time+7100;x.job:tick()
        assert(x.job.state=="cancelled" and x.job.count==0 and x.sends==3,mode)
    end
end)


local function settleLeg(x,jug,source,wanted,sourceFirst)
    local a,left,right=startPour(x,jug,wanted,source)
    a:perform();release(x,a)
    if sourceFirst then source.fluid.parts=left else jug.fluid.parts=right end
    x.job:tick()
    assert(x.job.phase=="pour" and not x.q.current,"A single endpoint is not permission to advance")
    if sourceFirst then jug.fluid.parts=right else source.fluid.parts=left end
    x.time=x.time+100;x.job:tick()
    assert(x.job:isBusy() and not x.q.current,x.job.reason)
    return right
end

local function settleRefit(x,jug,expected)
    x.job:tick()
    local refit=assert(x.q.current,x.job.reason)
    assert(refit.Type=="ISAddTakeDispenserBottle" and refit.bottle==jug and refit.waterdispenser==x.bareActual)
    x.player.facingTarget=x.bareActual
    assert(engineStart(x,refit))
    x.main:Remove(jug)
    drop(x.square.rows,x.bareActual)
    local fitted=stand(x.square,"WaterDispenser",IsoDirections.E,copy(expected))
    refit:perform();release(x,refit)
    x.job:tick();x.time=x.time+350;x.job:tick()
    assert(x.job.count==1 and not x.job:isBusy() and fitted.fluid.locked
        and x.main:contains(x.control) and not x.main:contains(jug),x.job.reason)
    assert(x.control.fluid:isEmpty())
    return fitted
end

test("a stock MP pour uses an exact donor in a nested pocket of an equipped bag",function()
    local x=fixture({[WATER]=13})
    x.bag.equipped=true
    local _,pocket=makeBag(102,"Base.BeltPouch",x.pocket)
    put(x.donor,pocket)
    assert(x.donor:isInPlayerInventory() and not x.main:containsID(x.donor.id))
    local selected,destination=x:selection({x.donor})
    local donor=assert(selected and selected[1])
    assert(donor.scope=="equipped" and donor.container==pocket)
    assert(D.plannedMountedTopUp(donor,destination)==1)
    assert(#Menu.targets({{anchor=x.anchor,bottle=destination}},donor,x.world)==1)
    local option,count=show(x)
    local row=assert(option.child.options[1])
    assert(row.itemForTexture==x.donor and row.name:find("add 1.000 L",1,true))
    row.onSelect(row.target)
    assert(count()==1 and idle(x))
    local jug=detach(x)
    assert(jug:getContainer()==x.main)
    local mixed=settleLeg(x,jug,x.donor,1,true)
    local fitted=settleRefit(x,jug,mixed)
    assert(x.job.state=="finished" and x.sends==3 and close(fitted.fluid:getAmount(),14))
    assert(x.donor:getContainer()==pocket and pocket:contains(x.donor) and x.donor.fluid:isEmpty())
end)

test("moved or stale carried donors cannot send a new stock action",function()
    for _,mode in ipairs({"moved","sameIdReplacement","duplicateId","staleContents","protected"}) do
        local x=fixture({})
        put(x.donor,x.pocket)
        local selection,destination=x:selection({x.donor})
        local chosen=assert(selection and selection[1])
        if mode=="moved" then put(x.donor,x.main)
        elseif mode=="sameIdReplacement" then
            x.pocket:Remove(x.donor)
            makeItem(x.donor.id,x.donor.typeName,x.pocket,{[OTHER]=1})
        elseif mode=="duplicateId" then
            makeItem(x.donor.id,x.donor.typeName,x.main,{[OTHER]=1})
        elseif mode=="staleContents" then x.donor.fluid.parts={[WATER]=1}
        elseif mode=="protected" then x.donor.favorite=true end
        assert(not D.new(x.player,x.world,x.anchor,chosen,destination,function() return true end)
            and x.sends==0 and idle(x),mode)
    end

    -- Same donor and same immediate pocket, but its ancestry changes
    -- after native pour admission. The native address is no longer exact.
    local x=fixture({})
    put(x.donor,x.pocket)
    local _,otherPocket=makeBag(102,"Base.Satchel",x.main)
    local jug=detach(x)
    x.job:tick()
    local pour=assert(x.q.current,x.job.reason)
    assert(pour.Type=="ISFluidTransferAction" and pour.sourceOwner==x.donor and pour.targetOwner==jug)
    put(x.bag,otherPocket)
    assert(x.donor:isInPlayerInventory() and x.donor.holder==x.pocket)
    assert(not engineStart(x,pour) and x.sends==1)
    x.job:tick()
    assert(pour.action.forceStop)
    pour:stop();release(x,pour);x.job:tick()
    assert(x.job.state=="cancelled" and x.job.count==0 and jug.fluid:isEmpty())
end)

test("batch takes once, uses exact ordered compatible donors, fills 15 L, refits once",function()
    local x=fixture({[WATER]=13})
    x.donor.fluid.parts={[OTHER]=.75}
    local second=makeItem(111,"Base.Bucket",x.pocket,{[WATER]=2})
    local spare=makeItem(112,"Base.Bucket",x.main,{[OTHER]=.5})
    local jug=detach(x,{x.donor,second,spare})
    assert(x.sends==1 and x.job:status().done==0 and x.job:status().total==3)
    settleLeg(x,jug,x.donor,.75,true)
    assert(x.job:status().done==1 and close(x.job.liters,.75) and x.sends==2 and x.donor.fluid:isEmpty())
    local mixed=settleLeg(x,jug,second,1.25,false)
    assert(x.job.phase=="refit" and x.sends==3 and x.job:status().done==2 and close(x.job.liters,2))
    local fitted=settleRefit(x,jug,mixed)
    x.job:tick()
    assert(x.job.state=="finished" and x.sends==4 and close(fitted.fluid:getAmount(),15))
    assert(close(fitted.fluid.parts[WATER],14.25) and close(fitted.fluid.parts[OTHER],.75))
    assert(close(second.fluid:getAmount(),.75) and close(spare.fluid:getAmount(),.5))
end)

test("batch rechecks the evolved mix and never uses protected, stale, or incompatible donors",function()
    local x=fixture({[WATER]=1})
    local bad={}
    local protected=makeItem(111,"Base.Bucket",x.main,{[WATER]=1})
    local stale=makeItem(112,"Base.Bucket",x.main,{[WATER]=1})
    local incompatible=makeItem(113,"Base.Bucket",x.main,{[bad]=1})
    local fitting=makeItem(114,"Base.Bucket",x.main,{[WATER]=.5})
    function x.extraCompatibility(from,target)
        return not (from.parts[bad] and target.parts[OTHER])
    end
    local jug=detach(x,{x.donor,protected,stale,incompatible,fitting})
    settleLeg(x,jug,x.donor,1,true)
    protected.protected=true
    stale.fluid.parts={[WATER]=1.25}
    local mixed=settleLeg(x,jug,fitting,.5,false)
    assert(x.job:status().skipped==3 and x.job:status().done==2)
    local fitted=settleRefit(x,jug,mixed)
    assert(x.sends==4 and x.job.state=="finished_with_skips" and close(fitted.fluid:getAmount(),2.5))
    assert(close(fitted.fluid.parts[OTHER],1) and close(fitted.fluid.parts[WATER],1.5))
    assert(protected.fluid:getAmount()==1 and stale.fluid:getAmount()==1.25 and incompatible.fluid:getAmount()==1)
end)

test("batch refits confirmed contents when the only remaining donor was removed",function()
    local x=fixture({})
    local removed=makeItem(111,"Base.Bucket",x.main,{[WATER]=1})
    local jug=detach(x,{x.donor,removed})
    local mixed=settleLeg(x,jug,x.donor,1,true)
    x.main:Remove(removed)
    x.job:tick()
    assert(x.job.phase=="refit" and x.job:status().skipped==1 and x.sends==2 and not x.q.current)
    local fitted=settleRefit(x,jug,mixed)
    assert(x.sends==3 and x.job.state=="finished_with_skips" and close(fitted.fluid:getAmount(),1))
end)

test("a foreign action, changed or ambiguous jug, or incomplete second leg cannot refit",function()
    for _,scenario in ipairs({"foreign","changed","ambiguous","incomplete"}) do
        local x=fixture({})
        local second=makeItem(111,"Base.Bucket",x.main,{[WATER]=1})
        local jug=detach(x,{x.donor,second})
        settleLeg(x,jug,x.donor,1,true)
        local foreign
        if scenario=="foreign" then
            foreign={Type="ForeignAction"}
            x.q:addToQueue(foreign)
        elseif scenario=="changed" then jug.fluid.parts={[WATER]=1}
        elseif scenario=="ambiguous" then makeItem(jug.id,BOTTLE,x.main,{[OTHER]=1})
        elseif scenario=="incomplete" then
            local a,left=startPour(x,jug,1,second)
            a:perform();release(x,a)
            second.fluid.parts=left
            x.job:tick(); x.time=x.time+7100
        end
        x.job:tick();x.job:tick()
        assert(x.job.state=="cancelled" and x.job.count==0 and close(x.job.liters,1),scenario)
        assert(x.sends==(scenario=="incomplete" and 3 or 2) and x.q.current==foreign)
        if foreign then assert(not foreign.action.forceStop and not foreign.cancelled) end
        assert(x.main:contains(jug) and x.bareActual:getObjectIndex()>=0)
    end
end)

test("batch rejects duplicate snapshot IDs and hides loot-denied mounts; donor truncation propagates",function()
    local x=fixture({})
    local spec,destination=x:selection({x.donor})
    assert(not D.new(x.player,x.world,x.anchor,{spec[1],spec[1]},destination,function()return true end))
    x.deniedLoot=true
    assert(#D.destinations(x.player,x.world,x.anchor)==0 and not x:ask({x.donor}) and x.sends==0)
    local original=Inv.snapshot
    local entries={spec[1]}
    Inv.snapshot=function()return {entries=entries,truncated=true}end
    local donors,truncated=D.donors(x.player,x.world)
    Inv.snapshot=original
    assert(donors==entries and truncated==true)
end)

print("PASS "..tests.." client-side mounted multiplayer and batch contracts; Lua/Java/transport boundaries are explicit doubles")
