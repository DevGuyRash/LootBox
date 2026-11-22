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
    function h:getType() return "inventory" end
    function h:isLockedToCharacter() return false end
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
    function item:isInPlayerInventory() return self.holder==f.main end
    function item:getItemHeat() return 1 end
    function item:syncItemFields() if self.onSync then self.onSync(self) end end
    if parts then item.fluid=fluid(item,parts,false) end
    if cont then cont.rows[#cont.rows+1]=item end
    return item
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
    local bag=makeItem(100,"Base.Bag",f.main)
    f.pocket=holder(bag)
    function bag:getInventory() return f.pocket end
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
    return not f.incompatible and a~=b and a:canPlayerEmpty() and b:canPlayerEmpty() and not b:isInputLocked()
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
    local a=makeItem(x.donorId,x.donorType,root,copy(flow.donor.fluid.parts))
    local b=makeItem(flow.result.id,BOTTLE,root,copy(flow.result.item.fluid.parts))
    for _,i in ipairs({a,b}) do function i:isInPlayerInventory() return self.holder==root end end
    x.authority=true
    local act=ISFluidTransferAction:new(x.player,ISFluidContainer:new(a.fluid),a.fluid,
        ISFluidContainer:new(b.fluid),b.fluid,flow.wanted)
    assert(act:complete())
    x.authority=false
    return copy(a.fluid.parts),copy(b.fluid.parts)
end

-- Native active list is a Java-boundary double, not a policy replacement.
local activeMods=nil
function getActivatedMods() return activeMods end
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
    x.world={protected=function(_,it) return it.protected==true or it:isFavorite() end}
    x.anchor=assert(D.capture(x.player,{x.old}))
    function x:ask()
        local destination=D.destinations(self.player,self.world,self.anchor)[1]
        if not destination then return nil end
        local wanted
        for _,entry in ipairs(D.donors(self.player,self.world)) do
            if entry.item==self.donor then wanted=entry;break end
        end
        if not wanted then return nil end
        wanted.pourSignature=Inv.mix(wanted)
        self.job=D.new(self.player,self.world,self.anchor,wanted,destination,function()return not self.disabled end)
        return self.job
    end
    function x:queueTake()
        assert(self:ask());self.job:tick()
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

test("native active list gates the mounted shortcut; stock Take and menu selection remain intact",function()
    local target=fixture({})
    assert(not D.mountedMPEnabled() and not target:ask() and #target.q.queue==0)
    assert(require("LootBox/MountedClientAction").start()==nil)
    local row=show(target)
    assert(row.notAvailable and not row.child and row.tip:find("Use stock Take Bottle",1,true))
    for _,ids in ipairs({{}, {"Other"}, {"lootbox"}, {"LootBox","LootBox"}, {"LootBox","lootbox"}, {"LootBox",42}}) do
        activeMods=list(ids)
        assert(not Policy.enabled())
        assert(not target:ask())
    end
    activeMods={size=function() error("missing native list") end}
    assert(not Policy.enabled())
    activeMods=list({"Other","LootBox"})
    assert(Policy.enabled())
    target=fixture({})
    row=show(target)
    assert(row.child and not row.notAvailable and row.name=="Top up mounted dispenser")
    local option,count=show(target)
    for _,choice in ipairs(option.child.options) do
        assert(choice.itemForTexture==target.donor)
        assert(choice.name:find("add 0.25 L (1.000 L available)",1,true))
        choice.onSelect(choice.target);choice.onSelect(choice.target)
    end
    assert(count()==1 and #target.q.queue==0)
end)

local function detach(x)
    local take=x:queueTake()
    assert(engineStart(x,take) and x.sends==1,"owned native take did not start")
    local item=x:juggle(nil,copy(x.old.fluid.parts))
    x:landTake(item,take,true)
    assert(x.job:isBusy(),x.job.reason)
    return item
end
local function startPour(x,jug)
    x.job:tick()
    local a=assert(x.q.current,x.job.reason)
    assert(a.Type=="ISFluidTransferAction" and a.amount==.25 and a.sourceOwner==x.donor and a.targetOwner==jug)
    assert(engineStart(x,a) and x.sends==2,"owned native pour did not start")
    local left,right=authorityPour(x,{donor=x.donor,result={item=jug,id=jug.id},wanted=.25})
    return a,left,right
end
local function pourToRefit(x,jug)
    local a,left,right=startPour(x,jug)
    a:perform();release(x,a)
    x.donor.fluid.parts=left
    x.job:tick()
    assert(x.job.phase=="pour" and not x.q.current,"one-sided delta must not refit")
    jug.fluid.parts=right
    x.time=x.time+100;x.job:tick()
    assert(x.job.phase=="refit" and x.job.liters==.25 and x.job:isBusy(),x.job.reason)
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
            and math.abs(mounted.fluid:getAmount()-((initial[WATER] or 0)+.25))<.00005,
            x.job.reason)
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
                          "blocked","deniedInteract","deniedLoot","replaced","dropped","nestedSource","oversized","disabled"}) do
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
        elseif mode=="nestedSource" then
            x.main:Remove(x.donor);x.pocket.rows[1]=x.donor;x.donor.holder=x.pocket
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

print("PASS "..tests.." dormant paired product envelopes; Lua/Java/transport boundaries are explicit doubles")
