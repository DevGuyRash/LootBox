package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local P,C,world,app,ms,mp
local function noop() end
local function yes() return true end
local function no() return false end
local function list(rows) return {size=function() return #rows end,get=function(_,i)return rows[i+1] end,
    contains=function(_,v)for _,x in ipairs(rows)do if x==v then return true end end return false end} end
function instanceof(o,kind)return o and o.classes and o.classes[kind] or false end
function getCell()return C end
function getSpecificPlayer(i)return i==0 and P or nil end
function getTimestampMs()return ms end
function isClient()return mp end
function isServer()return false end
function getText(k)return k=="ContextMenu_NaturalWaterSource" and "Natural water source" or k end
function getTexture(k)return k end
function sendItemStats()end
local clockEvents={Add=noop}
Events={OnTick=clockEvents,OnPressWalkTo=clockEvents}
for _,k in ipairs({"ClimbThroughWindowState","ClimbOverFenceState","ClimbOverWallState","ClimbState",
    "ClimbDownState","CloseWindowState","OpenWindowState","ForceOpenState"}) do _G[k]={instance=function()return k end} end
Fluid={Water="clean",TaintedWater="tainted"}
ZomboidGlobals={EquippedOrWornEncumbranceMultiplier=.3}
FluidUtil={roundTransfer=function(n)return math.floor(n*1000+.5)/1000 end}
FluidContainer={CanTransfer=function(a,b)return a~=b and a:getAmount()>0 and b:getFreeCapacity()>0 and b:canAddFluid(a.kind) end}
SafeHouse={isSafehouseAllowInteract=function(s)return not s.deny end,isSafehouseAllowLoot=function(s)return not s.lootDenied end}
Translator={getMoveableDisplayName=function(n)return n end}
ISLogSystem={logAction=noop}
table.wipe=table.wipe or function(t)for k in pairs(t)do t[k]=nil end end
local moves={}
luautils={getCorrectSquareForWall=function(_,s)return s end,haveToBeTransfered=function(p,i)return i.holder~=p.main end,
    walkAdjObject=function(p,o,diagonal,keep)
        assert(diagonal and keep and p==P)
        moves[#moves+1]=o
        return not o.blocked
    end}
local menuMethods={}
local function menu()return setmetatable({options={}}, {__index=menuMethods}) end
function menuMethods:addOption(n,t,f)local o={name=n,target=t,onSelect=f};self.options[#self.options+1]=o;return o end
function menuMethods:addSubMenu(o,c)o.child=c end
ISContextMenu={getNew=function()return menu()end}
local function tip(o,t,d)o.description=d end
local function opt(m,name,maybe)for _,o in ipairs(m.options)do if o.name==name then return o end end;if not maybe then error('missing menu: '..name) end end
local function click(row)return row.onSelect(row.target) end
local function itemclass(p)return {classes={InventoryItem=true},holder=p} end
local id=0
local function holder(owner)
    local b={rows={},owner=owner}
    function b:getItems()return list(self.rows)end
    function b:contains(i)return self:getItems():contains(i)end
    function b:getContainingItem()return self.owner end
    function b:getType()return "container"end
    b.isLockedToCharacter=no;b.setDrawDirty=noop;b.isInCharacterInventory=yes
    return b
end
local function put(i,b)
    if i.holder then for k,v in ipairs(i.holder.rows) do if v==i then table.remove(i.holder.rows,k);break end end end
    i.holder=b;b.rows[#b.rows+1]=i
end
local function item(b,name,cap,amount,kind)
    id=id+1
    local i=itemclass(nil);i.id=id;i.name=name
    function i:getID()return self.id end
    function i:getName()return self.name end
    function i:getFullType()return "Base."..self.name end
    function i:getContainer()return self.holder end
    function i:getInventory()return self.bag end
    function i:getFluidContainer()return self.fluid end
    i.isSealed=no
    i.isEquipped=function(self)return P:isEquipped(self) end
    i.isWorn=function(self)return P:isEquippedClothing(self) end
    i.getAttachedSlot=function(self)return P.attached[self] or -1 end
    i.canStoreWater=function(self)return self.waterStore~=false end
    i.isWaterSource=function(self)return self.fluid and self.fluid.amount>0 and self.fluid.kind==Fluid.Water end
    i.setBeingFilled=noop;i.setJobDelta=noop;i.syncItemFields=noop;i.isFavorite=no
    if cap then
        local f={owner=i,amount=amount,cap=cap,kind=kind or Fluid.Water}
        function f:getOwner()return self.owner end
        function f:getAmount()return self.amount end
        function f:getCapacity()return self.cap end
        function f:getFreeCapacity()return self.cap-self.amount end
        f.isMultiTileMoveable=no
        f.canPlayerEmpty=function(self)return not self.emptyLocked end
        f.isFull=function(self)return self.amount>=self.cap end
        f.canAddFluid=function(self,k)return not self.inputLocked and k~=self.forbid end
        function f:createFluidSample()return {size=function()return 1 end,getFluid=function()return self.kind end,
            getPercentage=function()return 1 end,release=noop}end
        i.fluid=f
    end
    put(i,b);return i
end
local function square(x,y,z)
    local s={x=x,y=y,z=z,rows={}};C.grid[x..":"..y..":"..z]=s
    function s:getX()return self.x end;function s:getY()return self.y end;function s:getZ()return self.z end
    function s:getBuilding()return self.building end
    function s:getObjects()return list(self.rows)end
    function s:canReachTo(dst)return not dst.blocked and math.abs(self.x-dst.x)<=1 and math.abs(self.y-dst.y)<=1 and self.z==dst.z end
    return s
end
local function object(s,name,cap,have,kind,mode)
    local o={square=s,name=name,cap=cap,amount=have,kind=kind,mode=mode,classes={IsoObject=true}}
    function o:getSquare()return self.square end
    function o:getObjectIndex()for j,r in ipairs(s.rows)do if r==self then return j-1 end end return -1 end
    function o:getFluidCapacity()return self.cap end;function o:getFluidAmount()return self.amount end
    function o:hasFluid()return self.amount>0 end
    function o:hasWater()return self.kind==Fluid.Water or self.kind==Fluid.TaintedWater end
    function o:isTaintedWater()return self.amount>0 and self.kind==Fluid.TaintedWater end
    function o:getPrimaryFluid()return self.amount>0 and self.kind or nil end
    function o:getFluidUiName()return self.kind end
    function o:getSprite()return {getProperties=function()return {has=function(_,k)return k=="CustomName" and self.name~=nil end,
        get=function()return self.name end}end}end
    function o:getFluidContainer()return self.mode=="collector" and self or nil end
    function o:getUsesExternalWaterSource()return self.mode=="plumbed" end
    function o:isFluidInputLocked()return self.mode=="wild" or self.mode=="mains" or self.lock==true end
    function o:canTransferFluidFrom(f)return not self:isFluidInputLocked() and f.amount>0 and f.kind~=self.forbid end
    function o:canTransferFluidTo(f)return self.amount>0 and f:canAddFluid(self.kind) end
    function o:transferFluidFrom(f,n)
        assert(not isClient(),"client-side fluid write")
        n=math.min(n,self.cap-self.amount,f.amount);self.amount=self.amount+n;self.kind=f.kind;f.amount=f.amount-n
    end
    function o:transferFluidTo(f,n)
        assert(not isClient(),"client-side fluid write")
        n=math.min(n,self.amount,f:getFreeCapacity());f.amount=f.amount+n;f.kind=self.kind
        if self.mode~="wild" and self.mode~="mains" then self.amount=self.amount-n end
    end
    s.rows[#s.rows+1]=o;return o
end
local function reset()
    ms=1;mp=false;id=0;moves={}
    C={grid={},getGridSquare=function(self,x,y,z)return self.grid[x..":"..y..":"..z] end}
    P={main=holder(),limit=50,worn={},attached={},classes={IsoPlayer=true,IsoGameCharacter=true}}
    P.square=square(0,0,0);P.getSquare=function(self)return self.square end;P.getCurrentSquare=P.getSquare
    function P:getInventory()return self.main end;function P:getBuilding()return self.square:getBuilding()end
    P.getPlayerNum=function()return 0 end;P.isLocalPlayer=yes
    P.getPrimaryHandItem=function(self)return self.primary end;P.getSecondaryHandItem=function(self)return self.secondary end
    for _,k in ipairs({"isDead","isAsleep","isMoving","isRunning","isSprinting","isAiming","isAttacking","isShoving",
        "isEquippedClothing","isAttachedItem","isEquipped","isTimedActionInstant","isDraggingCorpse","isFarming"}) do P[k]=no end
    function P:isEquippedClothing(i)return self.worn[i]~=nil end
    function P:isAttachedItem(i)return self.attached[i]~=nil end
    function P:isEquipped(i)return i==self.primary or i==self.secondary or self:isEquippedClothing(i) end
    P.getFreeInventoryCapacity=function(self)return self.limit end;P.hasFullInventory=function(self)return self.limit<=0 end
    P.hasTimedActions=function()return false end;P.setIsFarming=noop;P.setTimedActionToRetrigger=noop
    P.getTimedActionToRetrigger=function()return nil end
    world={protected=function(_,i)return i.protect==true end}
    app={world=world};package.loaded["LootBox/App"]={get=function()return app end}
    function app:worldPour(a,take,e,origin,opts)self.dispatch={a=a,take=take,e=e,origin=origin,opts=opts};return true end
    return P
end
local W=require "LootBox/WorldFluids"
local WM=require "LootBox/WorldFluidMenu"
local World=require "LootBox/World"
local PM=require "LootBox/PourMenu"
local I=require "LootBox/PourInventory"
local J=require "LootBox/WorldFluidJob"
local options={pourFillScope="main-first",pourFillOrder="smallest-first",pourLootToLoot=false}
local function snapshot()return I.snapshot(P,world,nil,nil)end
local function entry(i)
    for _,e in ipairs(snapshot().entries)do if e.item==i then assert(W.signature(e));return e end end
    error("not in snapshot: "..i.name)
end
local function anchor(o)return assert(W.objects(P,{o})[1],"missing world anchor")end
local function check(title,fn)reset();fn();print("PASS "..title)end

if WORLD_FLUID_STOCK then
    package.loaded["TimedActions/ISInventoryTransferUtil"]=true
    WORLD_FLUID_STOCK()
else
    ISWorldObjectContextMenu={getMoveableDisplayName=function(o)return o.name end}
end
check("directional eligibility: empty/full/locked collectors, plumbed, ordinary mains and tainted natural water without fluid components",function()
    local src=item(P.main,"Milk",2,1,"Milk");local dst=item(P.main,"Bottle",2,0)
    local s=P.square;local collector=object(s,"Collector",40,0,Fluid.Water,"collector")
    local wild=object(s,nil,9999,9999,Fluid.TaintedWater,"wild");local mains=object(s,"Sink",10000,10000,Fluid.Water,"mains")
    local pipe=object(s,"Plumbed",10,4,Fluid.Water,"plumbed")
    assert(W.permits(P,world,anchor(collector),entry(src),false) and not W.permits(P,world,anchor(collector),entry(dst),true))
    collector.amount=collector.cap
    assert(not W.permits(P,world,anchor(collector),entry(src),false) and W.permits(P,world,anchor(collector),entry(dst),true))
    collector.amount=3;collector.lock=true;assert(not W.permits(P,world,anchor(collector),entry(src),false))
    for _,o in ipairs({wild,mains})do assert(W.permits(P,world,anchor(o),entry(dst),true) and not W.permits(P,world,anchor(o),entry(src),false))end
    assert(W.permits(P,world,anchor(pipe),entry(src),false) and W.permits(P,world,anchor(pipe),entry(dst),true))
    dst.fluid.forbid=Fluid.TaintedWater;assert(not W.permits(P,world,anchor(wild),entry(dst),true))
    dst.fluid.forbid=Fluid.Water;assert(not W.permits(P,world,anchor(wild),entry(dst),true))
    src.waterStore=false;assert(not W.permits(P,world,anchor(pipe),entry(src),false))
    src.waterStore=true;src.protect=true;assert(not W.permits(P,world,anchor(pipe),entry(src),false))
    P.limit=0;assert(not W.permits(P,world,anchor(pipe),entry(dst),true))
end)
check("inventory Pour Into and Fill From, root + brand, no fake water destination, singleton world-only source, no fake unlimited litre labels",function()
    local src=item(P.main,"Bucket",2,1,"Milk")
    local c=object(P.square,"Rain collector",40,5,Fluid.Water,"collector")
    local w=object(square(1,0,0),nil,9999,9999,Fluid.TaintedWater,"wild")
    local parent,brand=menu(),menu();PM.add(0,parent,brand,{src},app,{},tip)
    for _,m in ipairs({parent,brand})do
        local out=opt(m,"Pour Into").child
        assert(opt(out,"Rain collector") and not opt(out,"Natural water source",true))
        local fill=opt(m,"Fill From").child;local row=opt(fill,"Natural water source")
        assert(row.description:find("Tooltip_WaterUnlimited",1,true) and not row.description:find("9999",1,true))
    end
    click(opt(opt(parent,"Pour Into").child,"Rain collector"));assert(app.dispatch.a.object==c and not app.dispatch.take)
    local old=app.dispatch;click(opt(opt(brand,"Fill From").child,"Natural water source"));assert(app.dispatch==old)
    src.fluid.amount=0
    parent,brand=menu(),menu();PM.add(0,parent,brand,{src},app,{},tip)
    assert(not opt(parent,"Pour Into",true));click(opt(opt(parent,"Fill From").child,"Natural water source"));assert(app.dispatch.a.object==w and app.dispatch.take)
end)
check("direct world click exact object; separately bound same-name fixtures; preference order; full donors in bags not offered",function()
    local small=item(P.main,"Small",1,0);local large=item(P.main,"Large",3,0)
    local bag=item(P.main,"Bag");bag.bag=holder(bag);local carried=item(bag.bag,"DonorInBag",2,1)
    local c=object(P.square,"Collector",40,8,Fluid.Water,"collector");local other=object(P.square,"Collector",40,8,Fluid.Water,"collector")
    local m=menu();WM.world(0,m,{other},app,options,tip)
    local r=opt(m,"Fill from Collector").child;click(opt(r,"Fill All"))
    local e=app.dispatch.e;assert(#e==3 and e[1].item==small and e[2].item==large and e[3].item==carried and app.dispatch.a.object==other)
    assert(not opt(m,"Pour into Collector",true))
    local m2=menu();WM.world(0,m2,{c,other},app,options,tip)
    assert(opt(m2,"Fill from Collector (0,0 z0 #1)") and opt(m2,"Fill from Collector (0,0 z0 #2)"))
    options.pourFillScope="main-only";m=menu();WM.world(0,m,{c},app,options,tip);click(opt(opt(m,"Fill from Collector").child,"Fill All"))
    assert(#app.dispatch.e==2);options.pourFillScope="main-first"
end)
check("stock access boundaries: safehouse/loot, adjacent walls, unloaded/replaced, another building or floor, world clicks may path from farther away",function()
    local s=square(1,0,0);local c=object(s,"Collector",40,4,Fluid.Water,"collector")
    assert(#W.objects(P,nil)==1);s.blocked=true;assert(#W.objects(P,nil)==0 and #W.objects(P,{c})==1);s.blocked=false
    s.deny=true;assert(#W.objects(P,{c})==0);s.deny=false;s.lootDenied=true;assert(#W.objects(P,{c})==0);s.lootDenied=false
    s.building={};assert(#W.objects(P,{c})==0);s.building=nil
    local a=anchor(c);s.rows={object(s,"Replacement",40,4,Fluid.Water,"collector")};assert(not W.live(P,a))
    local far=object(square(4,0,0),"Other",40,4,Fluid.Water,"collector");assert(#W.objects(P,{far})==1)
    local up=object(square(0,0,1),"Upstairs",40,4,Fluid.Water,"collector");assert(#W.objects(P,{up})==0)
end)
local function realProtection()
    world=World.new(P,{})
    app.world=world
end
local function wearable(name,cap,amount,position)
    local i=item(P.main,name,cap,amount)
    local contents
    if position=="back" then
        i.bag=holder(i);i.classes.InventoryContainer=true
        contents=item(i.bag,"PersonalGear")
    end
    if type(position)=="number" then P.attached[i]=position
    elseif position=="held" then P.secondary=i
    else P.worn[i]=position end
    return i,contents
end
local stockWearables={
    {"CanteenCowboy",1.8,"satchel"},
    {"Bag_LeatherWaterBag",1,"satchel"},
    {"Bag_HydrationBackpack",2,"back"},
    {"Bag_HydrationBackpack_Camo",3,"back"},
}
check("equipped fixture receivers include loaded hydration storage and ordinary custom attachments, reject full/locked/incompatible/protected receivers",function()
    realProtection()
    local o=object(P.square,"Rain collector",40,3,Fluid.Water,"collector")
    local a=anchor(o)
    local entries={}
    for _,d in ipairs(stockWearables)do entries[#entries+1]=wearable(d[1],d[2],0,d[3]) end
    local custom=wearable("CustomBeltVessel",1,0,0)
    entries[#entries+1]=custom
    for _,v in ipairs(entries)do
        local e=entry(v)
        assert(e.scope=="equipped" and W.permits(P,world,a,e,true))
        local m=menu();WM.world(0,m,{o},app,options,tip)
        local found=false
        for _,row in ipairs(opt(m,"Fill from Rain collector").child.options)do
            if row.itemForTexture==v then
                assert(row.target.entries[1].item==v)
                found=true
            end
        end
        assert(found)
        local parent,brand=menu(),menu()
        PM.add(0,parent,brand,{v},app,{},tip)
        assert(opt(opt(parent,"Fill From").child,"Rain collector"))
    end
    local pack=entries[3];local e=entry(pack)
    assert(world:protected(pack) and world:protected(pack,{allowEquippedConsumption=true}))
    pack.fluid.amount=1
    assert(not W.permits(P,world,a,entry(pack),false),"a nonempty bag donor policy must not be relaxed")
    pack.fluid.amount=pack.fluid.cap;assert(not W.permits(P,world,a,entry(pack),true))
    pack.fluid.amount=0;pack.fluid.inputLocked=true;assert(not W.permits(P,world,a,e,true))
    pack.fluid.inputLocked=false;pack.fluid.forbid=Fluid.Water;assert(not W.permits(P,world,a,e,true))
    pack.fluid.forbid=nil
    world.state.keep[tostring(pack.id)]=true;assert(not W.permits(P,world,a,e,true))
    world.state.keep={}
    pack.isFavorite=yes;assert(not W.permits(P,world,a,e,true))
    pack.isFavorite=no
    world.recovery={isProtected=function(_,i)return i==pack end};assert(not W.permits(P,world,a,e,true))
    world.recovery=nil
    local saved=entry(custom);P.attached[custom]=nil
    assert(not W.allowedEntry(P,world,a,saved,true))
end)
if not WORLD_FLUID_STOCK then print("World-fluid portable contract passed; installed game actions require tools/check-world-fluid-stock.py");return end

-- Only the Java action handle, character/world components and the inventory
-- transfer transport are doubles. Queue begin/perform/stop, water wrapper,
-- real action constructors, validity, partial use/add and complete are stock.
ISBaseTimedAction.create=function(self)
    local a=self
    self.action={isStarted=yes,forceStop=function()a:stop()end}
end
local Transport=ISBaseTimedAction:derive("ISInventoryTransferAction")
function Transport:perform()
    assert(self.item.holder==self.from,"wrong source")
    if self.from~=self.to then put(self.item,self.to) end
    ISBaseTimedAction.perform(self)
end
ISInventoryTransferUtil={newInventoryTransferAction=function(p,i,from,to)
    local a=ISBaseTimedAction.new(Transport,p);a.item,a.from,a.to=i,from,to
    return a
end}
local function q()return ISTimedActionQueue.getTimedActionQueue(P)end
local function start(o,take,items)
    P.StartAction=noop
    local entries={};for _,i in ipairs(items)do entries[#entries+1]=entry(i)end
    local j,why=J.new(P,world,anchor(o),take,entries,yes);assert(j,why);j:tick()
    assert(j.state=="running",j.reason);return j
end
local function finishStock(expected)
    local a=q().current
    assert(a and a.Type==expected,"expected "..expected.." got "..tostring(a and a.Type))
    if a.Type~="ISInventoryTransferAction" then assert(a:isValid(),"stock refused") end
    a:perform()
    if a.Type~="ISInventoryTransferAction" and not mp then assert(a:complete()) end
    return a
end
check("real stock Fill All serializes finite rainwater; second constructor caps remaining litres and never touches third vessel",function()
    local o=object(P.square,"Rain collector",40,1.5,Fluid.TaintedWater,"collector")
    local a=item(P.main,"One",1,0);local b=item(P.main,"Two",3,0);local c=item(P.main,"Three",1,0)
    local j=start(o,true,{a,b,c})
    assert(#q().queue==1 and q().current.waterUnit==1 and q().current.waterTaintedCL)
    finishStock("ISTakeWaterAction")
    assert(a.fluid.kind==Fluid.TaintedWater and o.amount==.5);j:tick();assert(j.count==1 and not q().current)
    j:tick();assert(q().current.item==b and q().current.waterUnit==.5)
    finishStock("ISTakeWaterAction");j:tick();j:tick()
    assert(j.state=="finished" and j.count==2 and j.liters==1.5 and c.fluid.amount==0 and o.amount==0 and #moves==2)
end)
check("real natural-water yield is not inferred from source loss; free carry weight is read at each vessel; plumbed tap capacity",function()
    local o=object(P.square,nil,9999,9999,Fluid.TaintedWater,"wild")
    local a=item(P.main,"One",1,0);local b=item(P.main,"Two",2,0)
    local j=start(o,true,{a,b});finishStock("ISTakeWaterAction");j:tick()
    P.limit=.25;j:tick();assert(q().current.waterUnit==.25)
    finishStock("ISTakeWaterAction");j:tick()
    assert(j.state=="finished" and j.liters==1.25 and b.fluid.kind==Fluid.TaintedWater and o.amount==9999)
    local tap=object(P.square,"Sink",8,.4,Fluid.Water,"plumbed")
    P.limit=5;local n=start(tap,true,{b})
    assert(W.near(q().current.waterUnit,.4));finishStock("ISTakeWaterAction");n:tick()
    assert(n.state=="finished" and W.near(n.liters,.4))
end)
check("stock object deposit respects destination free space, transfers milk, preserves both hands; volume unchanged on stale/locked target or no legal walk",function()
    local o=object(P.square,"Rain collector",5,4,"Milk","collector");local donor=item(P.main,"MilkBottle",3,2,"Milk")
    P.primary=item(P.main,"Hammer");P.secondary=item(P.main,"Torch")
    local main,off=P.primary,P.secondary;local j=start(o,false,{donor})
    assert(q().current.addUnits==1 and q().current.itemFrom==donor and q().current.objectTo==o and #q().queue==1)
    finishStock("ISAddFluidFromItemAction");j:tick()
    assert(j.state=="finished" and j.liters==1 and o.amount==5 and donor.fluid.amount==1 and P.primary==main and P.secondary==off)
    o.amount=2;local a=anchor(o);local e=entry(donor);o.lock=true
    local n=assert(J.new(P,world,a,false,{e},yes));n:tick()
    assert(n.state=="cancelled" and not q().current and o.amount==2)
    o.lock=false;o.blocked=true;a=anchor(o);n=assert(J.new(P,world,a,false,{e},yes));n:tick();n:tick()
    assert(n.state=="cancelled" and donor.fluid.amount==1)
end)
check("stock onTakeWater uses original bag -> main -> exact bag; later work waits for the stock return",function()
    local bag=item(P.main,"Pack");bag.bag=holder(bag)
    local target=item(bag.bag,"Flask",1,0);local nextBottle=item(P.main,"Other",1,0)
    local o=object(P.square,"Sink",10000,10000,Fluid.Water,"mains")
    local j=start(o,true,{target,nextBottle})
    assert(#q().queue==3 and q().queue[1].Type=="ISInventoryTransferAction" and q().queue[2].Type=="ISTakeWaterAction" and q().queue[3].to==bag.bag)
    finishStock("ISInventoryTransferAction");assert(target.holder==P.main)
    finishStock("ISTakeWaterAction");j:tick();assert(j.count==0 and q().current.to==bag.bag)
    finishStock("ISInventoryTransferAction");j:tick();assert(j.count==1 and target.holder==bag.bag and not q().current)
    j:tick();assert(q().current.item==nextBottle)
    finishStock("ISTakeWaterAction");j:tick();assert(j.count==2 and j.state=="finished")
end)
check("partial stock cancellation preserves partial liquid, cancels future bottles and reports no completed transfer",function()
    local o=object(P.square,"Rain",40,6,Fluid.Water,"collector");local a=item(P.main,"A",2,0);local b=item(P.main,"B",1,0)
    local j=start(o,true,{a,b})
    q().current:updateUse(.25);assert(a.fluid.amount==.5 and o.amount==5.5)
    j:cancel();j:tick();assert(j.state=="cancelled" and j.count==0 and j.liters==0 and a.fluid.amount==.5 and b.fluid.amount==0 and not q().current)
    local n=start(o,true,{a,b});q().current:stop();n:tick();n:tick();assert(n.state=="cancelled" and n.count==0 and not q().current)
end)
check("foreign queued work is never force-stopped or removed; controller does not dispatch another vessel",function()
    local o=object(P.square,"Rain",40,4,Fluid.Water,"collector");local a=item(P.main,"A",1,0);local b=item(P.main,"B",1,0)
    local j=start(o,true,{a,b})
    local foreign=ISBaseTimedAction.new(ISBaseTimedAction,P);foreign.Type="Foreign"
    ISTimedActionQueue.add(foreign);j:tick()
    assert(j.state=="cancelling" and q().queue[2]==foreign and q().current.item==a)
    finishStock("ISTakeWaterAction");j:tick()
    assert(q().current==foreign and j.state=="cancelled" and b.fluid.amount==0 and j.count==0)
end)
check("MP perform is not success: wait for correct item AND finite world mirror; no repeat on timeout; distinct replacement never accepted",function()
    local o=object(P.square,"Rain",40,4,Fluid.Water,"collector");local a=item(P.main,"A",1,0);local b=item(P.main,"B",1,0)
    mp=true;local j=start(o,true,{a,b});finishStock("ISTakeWaterAction");j:tick()
    assert(j.count==0 and j.state=="running" and not q().current)
    a.fluid.amount=1;j:tick();assert(j.count==0)
    o.amount=3;j:tick();assert(j.count==1 and not q().current)
    j:tick();finishStock("ISTakeWaterAction");j:tick()
    local impostor=item(P.main,"B",1,1);o.amount=2
    ms=5100;j:tick();assert(j.state=="cancelled" and j.count==1 and j.liters==1 and impostor.id~=b.id and #moves==2)
end)
check("part-filled stock worn recipients use one native fill, preserve exact gear and bag contents on success and cancellation",function()
    realProtection()
    local o=object(P.square,"Rain collector",40,6,Fluid.Water,"collector")
    local shovel=item(P.main,"Shovel");P.primary=shovel
    for _,d in ipairs(stockWearables)do
        local v,contents=wearable(d[1],d[2],d[2]-.5,d[3]);local id=v.id
        local spare=item(P.main,d[1],d[2],d[2]-.5)
        P.StartAction=noop
        -- Installed stock wrapper demonstrates the redundant main->main arm
        -- with an exact partial waterSource. Clear the synthetic queue and
        -- call the actual product route: only the stock water action remains.
        ISWorldObjectContextMenu.onTakeWater({o},o,nil,v,0)
        assert(#q().queue==2 and q().queue[2].from==P.main and q().queue[2].to==P.main)
        q().current:stop()
        P.limit=.15
        local j=start(o,true,{v})
        assert(#q().queue==1 and q().current.item==v and W.near(q().current.waterUnit,.5))
        local before=o.amount
        finishStock("ISTakeWaterAction");j:tick()
        assert(j.state=="finished" and j.count==1 and W.near(before-o.amount,.5) and W.near(v.fluid.amount,d[2]))
        assert(v.id==id and v.holder==P.main and P.worn[v]==d[3] and P.primary==shovel)
        assert(spare.fluid.amount==d[2]-.5 and (not contents or v.bag.rows[1]==contents and contents.holder==v.bag))
        v.fluid.amount=d[2]-.5
        local n=start(o,true,{v});q().current:updateUse(.5);n:cancel();n:tick()
        assert(n.state=="cancelled" and n.count==0 and #q().queue==0 and W.near(v.fluid.amount,d[2]-.25))
        assert(v.id==id and v.holder==P.main and P.worn[v]==d[3] and P.primary==shovel)
        assert(not contents or v.bag.rows[1]==contents and contents.holder==v.bag)
    end
end)
check("exact held and attached roles: native capacity applies naturally, stale state and same-ID replacement never complete",function()
    realProtection()
    local o=object(P.square,"Tap",10000,10000,Fluid.Water,"mains")
    local held=wearable("Held",2,0,"held");local attached=wearable("Attached",2,0,0)
    P.limit=.15
    local j=start(o,true,{held})
    assert(W.near(q().current.waterUnit,.5))
    finishStock("ISTakeWaterAction");j:tick()
    assert(j.state=="finished" and W.near(held.fluid.amount,.5) and P.secondary==held)
    local n=start(o,true,{attached})
    -- Attachment alone is not native isEquipped/isEquippedClothing.
    assert(W.near(q().current.waterUnit,.15) and P.attached[attached]==0)
    finishStock("ISTakeWaterAction");n:tick()
    assert(n.state=="finished" and W.near(attached.fluid.amount,.15) and P.attached[attached]==0)
    local stale=start(o,true,{attached});P.attached[attached]=nil;stale:tick();stale:tick()
    assert(stale.state=="cancelled" and W.near(attached.fluid.amount,.15) and #q().queue==0)
    P.attached[attached]=0
    mp=true
    local swap=start(o,true,{attached});finishStock("ISTakeWaterAction")
    put(attached,holder())
    local lookalike=wearable("Attached",2,.30,0);lookalike.id=attached.id
    swap:tick();swap:tick()
    assert(swap.state=="cancelled" and swap.count==0 and lookalike~=attached)
end)
print("Installed stock world-fluid actions and Kahlua/portable adapter traces complete; engine objects and network transport are doubles.")
