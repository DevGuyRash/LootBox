package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
for _, name in ipairs({ 'TimedActions/ISTimedActionQueue', 'TimedActions/ISInventoryTransferUtil' }) do package.loaded[name] = package.loaded[name] or true end
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
local observers={}
local function tickEvents()
    local copy={}
    -- Only the defer-until-next-tick callback; the engine's character-action
    -- list is doubled, so do not run the stock queue's global watchdog here.
    for cb in pairs(observers) do if cb~=ISTimedActionQueue.onTick then copy[#copy+1]=cb end end
    for _,cb in ipairs(copy) do cb() end
end
Events={OnTick={Add=function(cb)observers[cb]=true end,Remove=function(cb)observers[cb]=nil end},
    OnPressWalkTo={Add=noop}}
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
function menuMethods:insertOptionAfter(after,n,t,f)
    local o={name=n,target=t,onSelect=f}
    for at,v in ipairs(self.options) do if v.name==after then table.insert(self.options,at+1,o);return o end end
    self.options[#self.options+1]=o;return o
end
function menuMethods:addSubMenu(o,c)o.child=c end
ISContextMenu={getNew=function()return menu()end}
local function tip(o,t,d)o.description=d end
local function opt(m,name,maybe)for _,o in ipairs(m.options)do if o.name==name then return o end end;if not maybe then error('missing menu: '..name) end end
local function click(row)return row.onSelect(row.target) end
local function close(a,b)return math.abs(a-b)<1e-6 end
IsoFlagType={solidfloor="solidfloor",water="water"}
local function itemclass(p)return {classes={InventoryItem=true},holder=p} end
local id=0
local function holder(owner)
    local b={rows={},owner=owner}
    function b:getItems()return list(self.rows)end
    function b:contains(i)return self:getItems():contains(i)end
    function b:getContainingItem()return self.owner end
    function b:getType()return "container"end
    b.isLockedToCharacter=function(self)return self.locked==true end
    b.isItemAllowed=yes;b.isRemoveItemAllowed=yes;b.hasRoomFor=yes;b.setDrawDirty=noop;b.isInCharacterInventory=yes
    return b
end
local function put(i,b)
    if i.holder then for k,v in ipairs(i.holder.rows) do if v==i then table.remove(i.holder.rows,k);break end end end
    i.holder=b;b.rows[#b.rows+1]=i
end
local function mixture(o)
    if o.mix then return o.mix end
    return {[o.kind]=o.ratio or 1}
end
local function sample(o)
    local rows={}
    for kind,ratio in pairs(mixture(o)) do rows[#rows+1]={kind,ratio} end
    return {size=function()return #rows end,getFluid=function(_,i)return rows[i+1][1] end,
        getPercentage=function(_,i)return rows[i+1][2] end,release=noop}
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
    i.isSealed=no;i.getUnequippedWeight=function()return .2 end
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
        function f:getPrimaryFluid()return self.kind end
        function f:getCapacity()return self.cap end
        function f:getFreeCapacity()return self.cap-self.amount end
        f.isMultiTileMoveable=no
        f.canPlayerEmpty=function(self)return not self.emptyLocked end
        f.isFull=function(self)return self.amount>=self.cap end
        f.canAddFluid=function(self,k)return not self.inputLocked and k~=self.forbid end
        f.createFluidSample=sample
        i.fluid=f
    end
    put(i,b);return i
end
local function square(x,y,z)
    local s={x=x,y=y,z=z,rows={}};C.grid[x..":"..y..":"..z]=s
    function s:getX()return self.x end;function s:getY()return self.y end;function s:getZ()return self.z end
    function s:getBuilding()return self.building end
    function s:getObjects()return list(self.rows)end
    function s:getProperties()return {has=function(_,k)return k=="water" and self.water==true end}end
    function s:canReachTo(dst)return not dst.blocked and math.abs(self.x-dst.x)<=1 and math.abs(self.y-dst.y)<=1 and self.z==dst.z end
    return s
end
local function object(s,name,cap,have,kind,mode)
    local o={square=s,name=name,cap=cap,amount=have,kind=kind,mode=mode,classes={IsoObject=true}}
    function o:getSquare()return self.square end
    function o:getObjectIndex()for j,r in ipairs(s.rows)do if r==self then return j-1 end end return -1 end
    function o:getFluidCapacity()return self.cap end;function o:getFluidAmount()return self.amount end
    o.getAmount=o.getFluidAmount
    o.createFluidSample=sample
    o.isExistInTheWorld=function(self)return not self.removed end
    function o:FindExternalWaterSource()return self.upstream end
    function o:hasFluid()return self.amount>0 end
    function o:hasWater()return self.kind==Fluid.Water or self.kind==Fluid.TaintedWater end
    function o:isTaintedWater()return self.amount>0 and self.kind==Fluid.TaintedWater end
    function o:getPrimaryFluid()return self.amount>0 and self.kind or nil end
    function o:getFluidUiName()return self.kind end
    function o:getSprite()return {getProperties=function()return {has=function(_,k)return k=="CustomName" and self.name~=nil or k=="solidfloor" and self.floor==true end,
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
        n=math.min(n,self.amount,f:getFreeCapacity())
        local mix,total={},f.amount+n
        if f.amount>0 then for k,r in pairs(mixture(f)) do mix[k]=r*f.amount/total end end
        for k,r in pairs(mixture(self.upstream or self)) do
            local out=self.upstream and k==Fluid.TaintedWater and Fluid.Water or k
            mix[out]=(mix[out] or 0)+r*n/total
        end
        local primary,top=nil,0
        for k,r in pairs(mix) do if r>top then primary,top=k,r end end
        f.mix,f.kind,f.amount=mix,primary,total
        if self.mode~="wild" and self.mode~="mains" then self.amount=self.amount-n end
        if self.upstream then self.upstream.amount=self.amount end
    end
    s.rows[#s.rows+1]=o
    if mode=="plumbed" then
        local above=square(s.x,s.y,s.z+1)
        o.upstream=object(above,"Feed",cap,have,Fluid.TaintedWater,"collector")
    end
    return o
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
        "isEquippedClothing","isAttachedItem","isEquipped","isTimedActionInstant","isDraggingCorpse","isFarming","isClimbing","isKnockedDown"}) do P[k]=no end
    function P:isEquippedClothing(i)return self.worn[i]~=nil end
    function P:isAttachedItem(i)return self.attached[i]~=nil end
    function P:isEquipped(i)return i==self.primary or i==self.secondary or self:isEquippedClothing(i) end
    P.getFreeInventoryCapacity=function(self)return self.limit end;P.hasFullInventory=function(self)return self.limit<=0 end
    P.hasTimedActions=function()return false end;P.setIsFarming=noop;P.setTimedActionToRetrigger=noop
    P.getTimedActionToRetrigger=function()return nil end
    world={protected=function(_,i)return i.protect==true end}
    app={world=world};package.loaded["LootBox/App"]={get=function()return app end}
    function app:worldPour(a,take,e,id)self.dispatch={a=a,take=take,e=e,id=id};return true end
    return P
end
local W=require "LootBox/WorldFluids"
local WM=require "LootBox/WorldFluidMenu"
local World=require "LootBox/World"
local PM=require "LootBox/PourMenu"
local I=require "LootBox/PourInventory"
local options={pourFillScope="main-first",pourFillOrder="smallest-first",pourLootToLoot=false}
local branded
local function open(items,parent)
    parent=parent or menu();branded=nil
    local added=PM.add({playerIndex=0,parent=parent,items=items,app=app,preferences={},tooltip=tip,
        branded=function() branded=branded or menu();return branded end,interaction=function(origin,label) app.asked={origin,label};return 900 end})
    return parent,added
end
local function snapshot()return I.snapshot(P,world,nil,nil)end
local function entry(i)
    for _,e in ipairs(snapshot().entries)do if e.item==i then assert(W.signature(e));return e end end
    error("not in snapshot: "..i.name)
end
local function maybeAnchor(o)for _,a in ipairs(W.objects(P))do if a.object==o then return a end end end
local function anchor(o)return assert(maybeAnchor(o),"missing world anchor")end
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
check("one Pour Into and one Fill From directly after the stock Fluid entry; no row that only explains itself",function()
    local src=item(P.main,"Bucket",2,1,"Milk")
    local c=object(P.square,"Rain collector",40,5,Fluid.Water,"collector")
    local w=object(square(1,0,0),nil,9999,9999,Fluid.TaintedWater,"wild")
    local parent=menu()
    parent:addOption("Drink");parent:addOption("ContextMenu_Fluid");parent:addOption("Drop")
    local _,added=open({src},parent)
    local names={};for n,o in ipairs(parent.options)do names[n]=o.name end
    assert(added and not branded and table.concat(names,"|")=="Drink|ContextMenu_Fluid|Pour Into|Fill From|Drop")
    open({src},parent);assert(#parent.options==5,"a repeated fill event adds nothing")
    local out=opt(parent,"Pour Into").child
    assert(#out.options==1)
    click(opt(out,"Rain collector, 5 / 40 L (mixes with clean)"))
    assert(app.dispatch.a.object==c and not app.dispatch.take and app.dispatch.id==900)
    assert(app.asked[1]=="menu.item" and app.asked[2]=="Pour Into > Rain collector, 5 / 40 L (mixes with clean)")
    local fill=opt(parent,"Fill From").child
    local row=opt(fill,"Natural water source (mixes with Milk)")
    assert(row.description:find("Tooltip_WaterUnlimited",1,true) and not row.description:find("9999",1,true))
    local old=app.dispatch;click(row);assert(app.dispatch==old,"one click per open menu")
    src.fluid.amount=0
    parent=open({src});assert(not opt(parent,"Pour Into",true))
    click(opt(opt(parent,"Fill From").child,"Natural water source (tainted)"));assert(app.dispatch.a.object==w and app.dispatch.take)
    parent,added=open({item(P.main,"Nails")});assert(not added and #parent.options==0)
    local full=item(P.main,"Full",1,1,"Petrol");c.lock=true;w.square.blocked=true;src.fluid.amount=src.fluid.cap;src.fluid.kind="Milk"
    parent,added=open({full});assert(not added and #parent.options==0,"no destination and no room means no entry at all")
end)
check("puddles are not a source, natural water appears once, same-named fixtures are told apart by direction only",function()
    local v=item(P.main,"Bottle",1,0)
    local puddle=object(P.square,nil,3,3,Fluid.TaintedWater,"wild");puddle.floor=true
    for x=-1,1 do object(square(x,-1,0),nil,9999,9999,Fluid.TaintedWater,"wild") end
    object(square(-1,0,0),"Sink",10000,10000,Fluid.Water,"mains")
    object(square(1,0,0),"Sink",10000,10000,Fluid.Water,"mains")
    object(square(1,1,0),"Sink",10,4,Fluid.Water,"plumbed")
    local rows=opt(open({v}),"Fill From").child.options
    local names={};for n,o in ipairs(rows)do names[n]=o.name end
    table.sort(names)
    assert(table.concat(names,"|")=="Natural water source (tainted)|Sink, east (clean)|Sink, south-east (clean), 4 / 10 L|Sink, west (clean)",table.concat(names,"|"))
    for _,o in ipairs(rows) do assert(not o.name:find("#",1,true) and not (o.description or ""):find("z0",1,true)) end
    P.square.water=true;puddle.cap,puddle.amount=9999,9999
    assert(opt(opt(open({v}),"Fill From").child,"Natural water source (tainted)"),"open water underfoot still is one")
end)
check("a carried empty bottle fills from a carried bucket; a stack fills all or one and never mixes",function()
    local bucket=item(P.main,"Bucket",10,8)
    local bottle=item(P.main,"Bottle",1,0)
    local rows=opt(open({bottle}),"Fill From").child
    app.startPour=function(_,source,targets,id) app.pour={source=source,targets=targets,id=id};return true end
    click(opt(rows,"Bucket (clean), 8 / 10 L"))
    assert(app.pour.source.item==bucket and #app.pour.targets==1 and app.pour.targets[1].item==bottle and app.pour.id==900)
    local second,milk=item(P.main,"Bottle",1,.5),item(P.main,"Bottle",1,.5,"Milk")
    local row={name="Bottle",items={bottle,bottle,second,milk}}
    local pane={inventory=P.main,itemindex={Bottle=row},itemslist={row},items={row},collapsed={Bottle=true},player=0,getIsVisible=yes}
    row.invPanel=pane;pane.inventoryPage={inventoryPane=pane}
    function getPlayerInventory()return {inventoryPane=pane,getIsVisible=yes} end
    function getPlayerLoot()end
    local parent=open({row})
    local source=opt(opt(parent,"Fill From").child,"Bucket (clean), 8 / 10 L").child
    assert(#source.options==2 and opt(source,"Fill one"))
    click(opt(source,"Fill all (2)"))
    assert(#app.pour.targets==2 and app.pour.targets[1].item==second and app.pour.targets[2].item==bottle)
    getPlayerInventory,getPlayerLoot=nil,nil
end)
check("destinations name contents and litres, own liquid and empty first; batches only those, two or more",function()
    local src=item(P.main,"Bucket",10,8)
    item(P.main,"Jar",1,.25,"Milk");item(P.main,"Jar",1,0);item(P.main,"Jar",1,.6)
    local pack=item(P.main,"Pack");pack.bag=holder(pack);item(pack.bag,"Jar",1,.6)
    local rows=opt(open({src}),"Pour Into").child.options
    local names={};for n,o in ipairs(rows)do names[n]=o.name end
    assert(table.concat(names,"|")=="Pour into all (3)|Jar (clean), 0.6 / 1 L - Main inventory|Jar (clean), 0.6 / 1 L - Pack|"
        .."Jar, 0 / 1 L|Jar, 0.25 / 1 L (mixes with Milk)",table.concat(names,"|"))
    app.startPour=function(_,_,targets) app.pour=targets;return true end
    click(rows[1]);assert(#app.pour==3)
    for _,e in ipairs(app.pour) do assert(e.fluid.kind~="Milk") end
    reset();src=item(P.main,"Bucket",10,8);item(P.main,"Jar",1,0);item(P.main,"Jar",1,.25,"Milk")
    rows=opt(open({src}),"Pour Into").child.options
    assert(#rows==2 and rows[1].name=="Jar, 0 / 1 L","one fillable destination is not a batch")
end)
check("more than eight rows become groups by type, and identical vessels are one row",function()
    local src=item(P.main,"Bucket",30,30)
    for _=1,12 do item(P.main,"Empty Bottle",1,0) end
    for n=1,5 do item(P.main,"Jar",1,n/10) end
    for n=1,4 do item(P.main,"Soup"..n,1,.2,"Soup") end
    local child=opt(open({src}),"Pour Into").child
    local function count(m) for _,o in ipairs(m.options) do if o.child then count(o.child) end end;assert(#m.options<=8,"too many rows") end
    count(child)
    local empty=opt(child,"Empty Bottle, 0 / 1 L (12)").child
    assert(#empty.options==2 and opt(empty,"All (12)") and opt(empty,"One"))
    local jars=opt(child,"Jar (clean) (5)").child
    assert(#jars.options==6 and opt(jars,"All (5)") and opt(jars,"Jar (clean), 0.3 / 1 L"))
    assert(opt(child,"Soup1, 0.2 / 1 L (mixes with Soup)"))
    reset();src=item(P.main,"Bucket",30,30)
    for n=1,23 do item(P.main,"Jar",1,n/100) end
    child=opt(open({src}),"Pour Into").child
    count(child)
    local total=0
    local function leaves(m) for _,o in ipairs(m.options) do
        if o.child then leaves(o.child) elseif o.name:find("^Jar") then total=total+1 end end end
    leaves(child);assert(total==23,"every vessel stays reachable: "..total)
end)
check("another mod's Pour Into keeps its place; ours moves into LootBox",function()
    local src=item(P.main,"Bucket",2,1);item(P.main,"Jar",1,0)
    local parent=menu();local foreign=parent:addOption("Pour into ...",nil,function()end)
    open({src},parent)
    assert(parent.options[1]==foreign and not opt(parent,"Pour Into",true) and opt(branded,"Pour Into").child)
    getActivatedMods=function()return {contains=function(_,m)return m=="PourIntoContainer" end} end
    parent=open({src});assert(not opt(parent,"Pour Into",true) and opt(branded,"Pour Into"))
    getActivatedMods=nil
end)
check("stock access boundaries: safehouse/loot, adjacent walls, unloaded/replaced, another building, floor or distance",function()
    local s=square(1,0,0);local c=object(s,"Collector",40,4,Fluid.Water,"collector")
    assert(maybeAnchor(c));s.blocked=true;assert(not maybeAnchor(c));s.blocked=false
    s.deny=true;assert(not maybeAnchor(c));s.deny=false;s.lootDenied=true;assert(not maybeAnchor(c));s.lootDenied=false
    local a=anchor(c);s.rows={object(s,"Replacement",40,4,Fluid.Water,"collector")};assert(not W.live(P,a))
    assert(not maybeAnchor(object(square(4,0,0),"Other",40,4,Fluid.Water,"collector")))
    assert(not maybeAnchor(object(square(0,0,1),"Upstairs",40,4,Fluid.Water,"collector")))
end)
-- A reachable open Shelf, not a fictitious second player inventory.
local stockWearables={
    {"CanteenCowboy",1.8,"satchel"},
    {"Bag_LeatherWaterBag",1,"satchel"},
    {"Bag_HydrationBackpack",2,"back"},
    {"Bag_HydrationBackpack_Camo",3,"back"},
}
local function traced(fn)
    local lines,saved={},{}
    for _,level in ipairs({"trace","info","warn","error"}) do
        saved[level]=Log[level]
        Log[level]=function(id,event,...)
            local line={id=id,event=event,level=level}
            for n=1,select("#",...),2 do line[(select(n,...))]=(select(n+1,...)) end
            lines[#lines+1]=line
        end
    end
    local ok,err=pcall(fn,lines)
    for level,write in pairs(saved) do Log[level]=write end
    assert(ok,err)
end
local function find(lines,event) for n=#lines,1,-1 do if lines[n].event==event then return lines[n] end end end
local function q()return ISTimedActionQueue.getTimedActionQueue(P)end
local function untilAction(j,what)
    for _=1,6 do
        if q().current or not j:isBusy() then break end
        ms=ms+125;j:tick()
    end
    local a=q().current
    assert(a and a.Type==what,"expected "..what.." in "..j.phase..": "..tostring(j.reason))
    return a
end
print("Installed stock world-fluid actions and Kahlua/portable adapter traces complete; engine objects and network transport are doubles.")
