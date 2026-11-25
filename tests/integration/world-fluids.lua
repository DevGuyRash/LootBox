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
    function app:worldPour(a,take,e,origin,opts,loan)self.dispatch={a=a,take=take,e=e,origin=origin,opts=opts,loan=loan};return true end
    return P
end
local W=require "LootBox/WorldFluids"
local WM=require "LootBox/WorldFluidMenu"
local World=require "LootBox/World"
local PM=require "LootBox/PourMenu"
local I=require "LootBox/PourInventory"
local J=require "LootBox/WorldFluidJob"
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
    assert(app.dispatch.a.object==c and not app.dispatch.take and app.dispatch.opts and app.dispatch.a.interaction==900)
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
    app.startPour=function(_,source,targets,opts,receiver) app.pour={source=source,targets=targets,opts=opts,receiver=receiver};return true end
    click(opt(rows,"Bucket (clean), 8 / 10 L"))
    assert(app.pour.source.item==bucket and #app.pour.targets==1 and app.pour.targets[1].item==bottle and not app.pour.receiver
        and app.pour.opts.interaction==900 and app.pour.opts.pourRoute=="carried-fill-from")
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
    s.building={};assert(not maybeAnchor(c));s.building=nil
    local a=anchor(c);s.rows={object(s,"Replacement",40,4,Fluid.Water,"collector")};assert(not W.live(P,a))
    assert(not maybeAnchor(object(square(4,0,0),"Other",40,4,Fluid.Water,"collector")))
    assert(not maybeAnchor(object(square(0,0,1),"Upstairs",40,4,Fluid.Water,"collector")))
end)
-- A reachable open Shelf, not a fictitious second player inventory.
local function shelfFixture()
    local shelf=holder()
    local marker={}
    P.page={getIsVisible=yes,inventoryPane={inventory=shelf}}
    function getPlayerLoot(i)return i==0 and P.page end
    world.consumptionSource=function(_,it,holder)return holder==shelf and it:getContainer()==shelf and shelf:contains(it) and not shelf.locked end
    world.pourShelfAnchor=function(_,holder)return holder==shelf and not shelf.locked and marker or nil end
    world.pourShelfReachable=function(_,holder,anchor)return holder==shelf and anchor==marker and not shelf.locked end
    return shelf
end
local function inverseFor(v) return opt(open({v}),"Fill From",true) end
check("one Fill From combines fixtures and permitted portable donors and drops what is no longer usable",function()
    local shelf=shelfFixture();local v=item(shelf,"Jug",2,0)
    local sink=object(P.square,"Sink",10000,10000,Fluid.Water,"mains")
    local toilet=object(square(1,0,0),"Toilet",10,3,Fluid.Water,"plumbed")
    local wild=object(square(0,1,0),nil,9999,9999,Fluid.TaintedWater,"wild")
    object(square(1,1,0),"Dry",40,0,Fluid.Water,"collector")
    local tank=object(P.square,"Big tank",15000,15000,"Milk","collector")
    local m=inverseFor(v).child
    assert(#m.options==4 and opt(m,"Sink (clean)") and opt(m,"Toilet (clean), 3 / 10 L")
        and opt(m,"Natural water source (tainted)") and opt(m,"Big tank (Milk), 15000 / 15000 L"))
    click(opt(m,"Toilet (clean), 3 / 10 L"));local t=app.dispatch
    assert(t.a.object==toilet and t.loan.lease.entry.item==v and #t.e==1 and t.take)
    click(opt(m,"Sink (clean)"));assert(app.dispatch==t and v.holder==shelf and v.fluid.amount==0 and toilet.amount==3)
    local donor=item(P.main,"Portable",2,1);item(shelf,"UnselectedDonor",1,1)
    m=inverseFor(v).child;assert(#m.options==5)
    assert(opt(m,"Portable (clean), 1 / 2 L").itemForTexture==donor)
    toilet.square.deny=true;wild.square.blocked=true;tank.kind="forbidden";v.fluid.forbid="forbidden"
    m=inverseFor(v).child;assert(#m.options==2 and opt(m,"Sink (clean)"))
    P.limit=.2;m=inverseFor(v).child;assert(#m.options==1 and m.options[1].itemForTexture==donor)
    assert(not W.live(P,t.a) and sink.amount==10000)
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
        assert(opt(opt(open({v}),"Fill From").child,"Rain collector (clean), 3 / 40 L"))
    end
    local pack=entries[3];local e=entry(pack)
    assert(world:protected(pack) and world:protected(pack,{allowEquippedConsumption=true}))
    pack.fluid.amount=1
    assert(not W.permits(P,world,a,entry(pack),false),"a nonempty bag donor policy must not be relaxed")
    pack.fluid.amount=pack.fluid.cap;assert(not W.permits(P,world,a,entry(pack),true))
    pack.fluid.amount=0;pack.fluid.inputLocked=true;assert(not W.permits(P,world,a,e,true))
    pack.fluid.inputLocked=false;pack.fluid.forbid=Fluid.Water;assert(not W.permits(P,world,a,e,true))
    pack.fluid.forbid=nil
    -- Filling in place neither moves nor deletes, so Keep and Favorite allow it.
    world.state.keep[tostring(pack.id)]=true;assert(W.permits(P,world,a,e,true))
    world.state.keep={}
    pack.isFavorite=yes;assert(W.permits(P,world,a,e,true) and W.inPlaceReceiver(P,world,e))
    pack.isFavorite=no
    local bag=item(P.main,"Pack");bag.bag=holder(bag)
    local inside=item(bag.bag,"Flask",1,0);assert(W.permits(P,world,a,entry(inside),true))
    inside.isFavorite=yes;assert(not W.permits(P,world,a,entry(inside),true),"from a bag the game carries it out and back")
    world.recovery={isProtected=function(_,i)return i==pack end};assert(not W.permits(P,world,a,e,true))
    world.recovery=nil
    local saved=entry(custom);P.attached[custom]=nil
    assert(not W.allowedEntry(P,world,a,saved,true))
end)

local Log=require "LootBox/Log"
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
check("the world job trace tells a refusal from a Lua error and names vessel, fixture and player",function()
    local savedQueue=ISTimedActionQueue
    if not WORLD_FLUID_STOCK then
        local queue={queue={}}
        ISTimedActionQueue={getTimedActionQueue=function()return queue end}
    end
    traced(function(lines)
        mp=true
        local o=object(P.square,"Collector",40,6,Fluid.Water,"collector")
        local vessel=item(P.main,"Bottle",1,0)
        local a,e=anchor(o),entry(vessel)
        a.interaction=31
        P.hasTimedActions=yes
        local busy,msg=J.new(P,world,a,true,{e},yes)
        assert(not busy and msg=="Finish the current action and select an available vessel.")
        local refused=find(lines,"REFUSED")
        assert(refused.id==31 and refused.check=="queue-busy" and refused.fixture:find("Collector",1,true) and refused.player)
        P.hasTimedActions=no
        local j=assert(J.new(P,world,a,true,{e},function()error("binding gone")end))
        assert(j.interaction==31 and find(lines,"START").fixture:find("litres=6.00000/40.00000",1,true))
        assert(find(lines,"TARGET").vessel:find("Base.Bottle#"..vessel.id,1,true))
        local fault
        local saved=Log.fault;Log.fault=function(id,site,err)fault={id=id,site=site,err=tostring(err)}end
        for _=1,5 do j:tick()end
        Log.fault=saved
        assert(fault.id==31 and fault.site=="WorldFluidJob.step" and fault.err~="nil")
        local finish=find(lines,"END")
        assert(j.state=="cancelled" and finish.check=="action-binding-error" and finish.phase=="prepare" and finish.submitted==false
            and finish.vessels==0 and finish.of==1 and finish.litres==0)
    end)
    ISTimedActionQueue=savedQueue
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
function Transport:isValid()return self.item.holder==self.from end
function Transport:start()if mp then self.transactionId=81 end end
function Transport:transferItem(it)
    assert(not mp and it.holder==self.from,"illegal inventory write")
    if self.from~=self.to then
        if self.from.takeWorld then self.from.takeWorld(it) end
        put(it,self.to)
    end
end
function Transport:perform()
    if not mp then self:transferItem(self.item) end
    self.transactionId=0
    ISBaseTimedAction.perform(self)
end
ISInventoryTransferUtil={newInventoryTransferAction=function(p,i,from,to)
    local a=ISBaseTimedAction.new(Transport,p);a.item,a.from,a.to,a.srcContainer,a.destContainer=i,from,to,from,to
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
local Loan=require "LootBox/WorldLootFill"
package.loaded["TimedActions/ISTimedActionQueue"]=true
local function loanStart(name,mode,amount,kind,initial,donorMix)
    local shelf=shelfFixture();local target=item(shelf,"Jug",2,initial and initial.amount or 0,initial and initial.kind)
    if initial then target.fluid.mix=initial.mix end
    local other=item(shelf,"Jug",2,0);local privateShelf=holder();local hidden=item(privateShelf,"Jug",2,0)
    local o=object(P.square,name,mode=="wild" and 9999 or mode=="mains" and 10000 or 25,amount,kind,mode)
    if donorMix then (o.upstream or o).mix=donorMix end
    local a=inverseFor(target);click(a.child.options[1])
    local l=app.dispatch.loan
    P.StartAction=noop;P.faceThisObject=noop;P.shouldBeTurning=no
    local j,why=Loan.new(P,world,l,yes);assert(j,why)
    return j,target,shelf,o,other,hidden
end
local function untilAction(j,what)
    for _=1,6 do
        if q().current or not j:isBusy() then break end
        ms=ms+125;j:tick()
    end
    local a=q().current
    assert(a and a.Type==what,"expected "..what.." in "..j.phase..": "..tostring(j.reason))
    return a
end
local function armMove(j,it,from,to)
    local a=untilAction(j,"ISInventoryTransferAction")
    assert(a.item==it and a.srcContainer==from and a.destContainer==to)
    assert(a:isValidStart() and a:isValid());a:start()
    return a
end
for _,d in ipairs({{"Sink","mains",10000,Fluid.Water},{"Toilet","plumbed",.75,Fluid.Water},
    {"Rain collector","collector",1.25,Fluid.TaintedWater},{nil,"wild",9999,Fluid.TaintedWater},
    {"Custom tank","collector",5,"Milk"}})do
    check("stock fixture loan: actual water action on exact main item, return to exact shelf: "..tostring(d[1]),function()
        -- Idle native movement/input, but stale animation flags on an MP-style replica.
        P.isRunning=yes;P.isSprinting=yes;P.isMoving=yes;P.isPlayerMoving=no;P.pressedMovement=no
        local j,v,s,o,other,hidden=loanStart(d[1],d[2],d[3],d[4])
        local oldid=v.id
        armMove(j,v,s,P.main):perform();assert(v.holder==P.main and v.fluid.amount==0)
        local a=untilAction(j,"ISTakeWaterAction");assert(a.item==v and a.waterObject==o and not a:waitToStart())
        local n=a.waterUnit;assert(n==math.min(2,d[3]));finishStock("ISTakeWaterAction")
        armMove(j,v,P.main,s):perform();j:tick()
        assert(j.state=="finished" and j.liters==n and j.count==1 and v.fluid.amount==n and v.fluid.kind==d[4])
        assert(v.id==oldid and s:contains(v) and not P.main:contains(v) and other.fluid.amount==0 and hidden.fluid.amount==0)
        assert(o.amount==((d[2]=="wild" or d[2]=="mains") and d[3] or d[3]-n))
    end)
end
check("weighted stock fill preserves the receiver's original ingredients and adds the exact fixture blend",function()
    local blend={[Fluid.Water]=.75,Milk=.25}
    local initial={amount=.5,kind="Milk",mix={Milk=.9,[Fluid.Water]=.1}}
    local j,v,s,o=loanStart("Custom tank","collector",5,Fluid.Water,initial,blend)
    armMove(j,v,s,P.main):perform()
    local a=untilAction(j,"ISTakeWaterAction");assert(not a:waitToStart() and a.waterUnit==1.5)
    finishStock("ISTakeWaterAction");armMove(j,v,P.main,s):perform();j:tick()
    assert(j.state=="finished" and v.fluid.amount==2 and v.fluid.kind==Fluid.Water)
    assert(close(v.fluid.mix[Fluid.Water],.5875) and close(v.fluid.mix.Milk,.4125))
end)
check("a finite plumbed tap converts only tainted water; missing native feed is not advertised",function()
    local initial={amount=.75,kind=Fluid.Water}
    local raw={[Fluid.TaintedWater]=.4,[Fluid.Water]=.4,Milk=.2}
    local j,v,s,o=loanStart("Tap","plumbed",1,Fluid.Water,initial,raw)
    armMove(j,v,s,P.main):perform()
    local a=untilAction(j,"ISTakeWaterAction");assert(not a:waitToStart() and a.waterUnit==1)
    finishStock("ISTakeWaterAction");armMove(j,v,P.main,s):perform();j:tick()
    assert(j.state=="finished" and v.fluid.amount==1.75 and v.fluid.mix[Fluid.TaintedWater]==nil)
    assert(close(v.fluid.mix.Milk,.2/1.75) and close(v.fluid.mix[Fluid.Water],1.55/1.75))
    o.amount=.5;o.upstream.removed=true
    assert(not inverseFor(v))
end)
for _,corrects in ipairs({false,true}) do
    check("MP wrong same-volume/primary mixture never certifies; corrected mirror allowed="..tostring(corrects),function()
        mp=true
        function isItemTransactionDone(id)return id==81 end
        function isItemTransactionRejected()return false end
        local blend={[Fluid.Water]=.75,Milk=.25}
        local initial={amount=.5,kind="Milk",mix={Milk=.9,[Fluid.Water]=.1}}
        local j,v,s,o=loanStart("Rain collector","collector",5,Fluid.Water,initial,blend)
        armMove(j,v,s,P.main):perform();put(v,P.main)
        local water=untilAction(j,"ISTakeWaterAction");assert(not water:waitToStart());finishStock("ISTakeWaterAction")
        o.amount=3.5
        -- Both total and dominant type are correct, but this swaps out most
        -- of the original liquid. It is not the selected stock fill receipt.
        v.fluid.amount,v.fluid.kind,v.fluid.mix=2,Fluid.Water,{[Fluid.Water]=.95,Milk=.05}
        j:tick();ms=ms+125;j:tick()
        assert(j.liters==0 and j.count==0 and not q().current and v.holder==P.main)
        if not corrects then
            -- Not certified as the selected liquid, but still the player's own
            -- vessel, and it goes back where it came from.
            ms=ms+5500;for _=1,3 do j:tick() end
            armMove(j,v,P.main,s):perform();put(v,s)
            for _=1,3 do ms=ms+125;j:tick() end
            assert(j.state=="cancelled" and j.restored and j.liters==0 and j.count==0 and j.check=="vessel-mixture")
            assert(not q().current and v.holder==s)
        else
            v.fluid.mix={[Fluid.Water]=.5875,Milk=.4125}
            armMove(j,v,P.main,s):perform();put(v,s);ms=ms+125;j:tick()
            assert(j.state=="finished" and j.count==1 and j.liters==1.5 and v.holder==s)
        end
    end)
end
check("stock perform never resets a queued manual tail even if its first entry would fail isValidStart",function()
    local j,v,s,o=loanStart("Rain","collector",3,Fluid.Water)
    armMove(j,v,s,P.main):perform()
    local a=untilAction(j,"ISTakeWaterAction");assert(not a:waitToStart())
    local first,second=ISBaseTimedAction:new(P),ISBaseTimedAction:new(P)
    local validates,begins,cancelled=0,0,0
    first.isValidStart=function()validates=validates+1;return false end
    function first:begin()begins=begins+1;ISBaseTimedAction.begin(self)end
    function first:forceCancel()cancelled=cancelled+1 end
    second.forceCancel=first.forceCancel
    ISTimedActionQueue.add(first);ISTimedActionQueue.add(second)
    finishStock("ISTakeWaterAction")
    assert(q().current==nil and #q().queue==0 and validates==0 and begins==0 and cancelled==0)
    j:tick();assert(q().current==nil and begins==0 and j.liters==0)
    ms=ms+125;tickEvents()
    assert(q().current==first and q().queue[2]==second and #q().queue==2 and cancelled==0 and begins==1)
    for _=1,3 do j:tick() end
    assert(j.state=="cancelled" and j.liters==0 and v.holder==P.main and q().current==first)
end)
check("ordinary placed stock component: exact Ground pickup -> stock natural fill -> stock Place Item at original offsets/rotation",function()
    local floor=shelfFixture();floor.getType=function()return "floor" end
    local s=P.square
    local worldRows={}
    function s:getWorldObjects()return list(worldRows)end
    s.isCouldSee=yes;s.TreatAsSolidFloor=yes;s.isAdjacentTo=yes
    s.isSolid=no;s.isSolidTrans=no;s.HasStairs=no;s.hasSlopedSurface=no;s.isBlockedTo=no;s.isWallTo=no;s.isWindowTo=no
    s.getTotalWeightOfItemsOnFloor=function()return 1 end
    luautils.walkAdjTest=yes;ISInventoryPage={GetFloorContainer=function()return floor end}
    local v=item(floor,"Vessel",2,0)
    local ghost=item(floor,"Vessel",2,0)
    v.getWorldItem=function(self)return self.wrapper end
    v.getType=function()return "Vessel" end
    v.getWorldStaticItem=function()return "NativeModel" end
    v.getWorldXRotation=function()return 0 end;v.getWorldYRotation=v.getWorldXRotation
    v.rz=125;v.getWorldZRotation=function(self)return self.rz end
    v.setWorldZRotation=function(self,r)self.rz=r end;v.setJobType=noop;v.getPlaceOneSound=noop
    function floor.takeWorld(it)
        assert(not mp and it==v and #worldRows==1 and it.wrapper==worldRows[1])
        it.fluid=it.wrapper.fluid;it.fluid.owner=it;it.wrapper=nil;worldRows={}
    end
    local function place(it,x,y,z)
        local w={square=s,it=it,ox=x,oy=y,oz=z,classes={IsoObject=true,IsoWorldInventoryObject=true}}
        function w:getSquare()return self.square end
        function w:getItem()return self.it end
        function w:getOffX()return self.ox end;function w:getOffY()return self.oy end;function w:getOffZ()return self.oz end
        w.isExistInTheWorld=yes;w.getWorldObjectIndex=function()return 0 end
        w.isExtendedPlacement=function(self)return self.extended==true end
        w.setExtendedPlacement=function(self,e)self.extended=e end;w.transmitCompleteItemToClients=noop;w.setIgnoreRemoveSandbox=noop
        w.fluid=it.fluid;w.fluid.owner=w;it.fluid=nil;it.wrapper=w;worldRows={w}
        w.getFluidContainer=function(self)return self.fluid end
        return w
    end
    local old=place(v,.37,.71,0)
    ISInventoryPage.renderDirty=false;P.getVehicle=noop;P.StartAction=noop;P.getEmitter=function()return {isPlaying=yes} end
    P.playSound=noop;P.isTimedActionInstant=yes;P.faceThisObject=noop;P.shouldBeTurning=no
    function P.main:Remove(it)assert(it==v);put(it,holder())end
    function sendRemoveItemFromContainer(c,it)assert(not mp and c==P.main and it==v)end
    function s:AddWorldInventoryItem(it,x,y,z,flag)assert(not mp and it==v and not flag);place(it,x,y,z);return it end
    local o=object(s,nil,9999,9999,Fluid.TaintedWater,"wild")
    old.extended=true
    local r=inverseFor(v);assert(not r and not q().current and old.fluid.amount==0)
    old.extended=false;r=inverseFor(v);click(opt(r.child,"Natural water source (tainted)"))
    local pick=app.dispatch.loan;assert(pick.lease.ground.worldFluid and pick.lease.ground.world==old)
    local j,why=Loan.new(P,world,pick,yes);assert(j,why)
    local tak=untilAction(j,"ISInventoryTransferAction")
    assert(tak:isValidStart() and tak:isValid() and not tak:waitToStart());tak:start();tak:perform()
    local water=untilAction(j,"ISTakeWaterAction")
    assert(v.holder==P.main and v.fluid.owner==v and water.item==v and not water:waitToStart())
    finishStock("ISTakeWaterAction")
    local drop=untilAction(j,"ISDropWorldItemAction")
    assert(drop.item==v and drop.sq==s and drop.xoffset==.37 and drop.yoffset==.71 and drop.rotation==125)
    assert(drop:isValidStart() and drop:isValid() and not drop:waitToStart());drop:start()
    drop:perform();assert(drop:complete());j:tick()
    assert(j.state~="finished") -- the square alone is not a reciprocal Ground receipt
    put(v,floor);ms=ms+200;j:tick()
    assert(j.state=="finished" and j.count==1 and j.liters==2 and v.wrapper~=old)
    assert(v.wrapper.fluid.owner==v.wrapper and v.wrapper.fluid.amount==2 and v.wrapper.fluid.kind==Fluid.TaintedWater)
    assert(v.wrapper.ox==.37 and v.wrapper.oy==.71 and v.rz==125 and ghost.fluid.amount==0 and o.amount==9999)
end)
check("source/mixture changes after pickup return the unchanged vessel once; no work on changed or duplicate IDs",function()
    local j,v,s,o=loanStart("Tank","collector",5,"Milk")
    armMove(j,v,s,P.main):perform();o.ratio=.8
    local back=armMove(j,v,P.main,s);back:perform();j:tick()
    assert(j.state=="cancelled" and j.restored and j.liters==0 and o.amount==5 and v.fluid.amount==0)
    local n,w,orig,fixture=loanStart("Sink","mains",10000,Fluid.Water)
    armMove(n,w,orig,P.main):perform();n:tick() -- exact pickup receipt
    local conflict=item(P.main,"Jug",2,0);conflict.id=w.id
    for _=1,7 do ms=ms+200;n:tick()end
    assert(n.state=="cancelled" and not q().current and w.fluid.amount==0 and conflict.fluid.amount==0 and fixture.amount==10000)
end)
check("between receipt and start, changed taint, denied fixture, or new manual work never starts the old water action",function()
    local j,v,s,o=loanStart("Rain","collector",3,Fluid.Water)
    armMove(j,v,s,P.main):perform()
    local a=untilAction(j,"ISTakeWaterAction")
    o.kind=Fluid.TaintedWater
    assert(a:waitToStart() and not q().current)
    armMove(j,v,P.main,s):perform();j:tick()
    assert(j.state=="cancelled" and j.restored and v.holder==s and v.fluid.amount==0 and o.amount==3 and j.liters==0)
    local k,w,orig,fc=loanStart("Toilet","plumbed",3,Fluid.Water)
    armMove(k,w,orig,P.main):perform()
    a=untilAction(k,"ISTakeWaterAction")
    local foreign=ISBaseTimedAction.new(ISBaseTimedAction,P)
    foreign.Type="Manual";ISTimedActionQueue.add(foreign);fc.square.deny=true
    assert(a:waitToStart() and q().current==foreign and #q().queue==1)
    for _=1,5 do k:tick()end
    assert(k.state=="cancelled" and k.liters==0 and w.fluid.amount==0 and q().current==foreign)
end)
check("rain before and during a collector fill: measured from the vessel, for a shelf loan and for carried vessels",function()
    local j,v,s,o=loanStart("Rain collector","collector",3,Fluid.TaintedWater)
    o.amount=3.4 -- between the menu and the click
    armMove(j,v,s,P.main):perform()
    o.amount=3.7
    local a=untilAction(j,"ISTakeWaterAction");assert(not a:waitToStart())
    a:updateUse(.5);o.amount=o.amount+.6;finishStock("ISTakeWaterAction");o.amount=o.amount+.3
    armMove(j,v,P.main,s):perform();j:tick()
    assert(j.state=="finished" and j.count==1 and close(j.liters,2) and close(v.fluid.amount,2) and v.holder==s)
    local one,two=item(P.main,"One",1,0),item(P.main,"Two",1,0)
    local n=start(o,true,{one,two})
    o.amount=o.amount+.5;finishStock("ISTakeWaterAction");o.amount=o.amount+.5;n:tick();n:tick()
    finishStock("ISTakeWaterAction");n:tick()
    assert(n.state=="finished" and n.count==2 and n.liters==2)
end)
check("a finite fixture's float32 bookkeeping cannot fail a correct fill",function()
    local function f32(x)
        if x<=0 then return 0 end
        local scale=1
        while x*scale>=16777216 do scale=scale/2 end
        while x*scale<8388608 do scale=scale*2 end
        return math.floor(x*scale+.5)/scale
    end
    local seed=11
    local function random() seed=(seed*16807)%2147483647;return seed/2147483647 end
    for _=1,40 do
        local have,size=f32(1+30*random()),f32(.3+4*random())
        local o=object(P.square,"Barrel",40,have,Fluid.Water,"collector")
        local v=item(P.main,"Jug",size,f32(size*random()*.5))
        function o:transferFluidTo(f,n)
            n=f32(math.max(0,math.min(n,self.amount,f:getFreeCapacity())))
            f.amount=f32(f.amount+n);self.amount=f32(self.amount-n);f.kind=self.kind
        end
        local before=v.fluid.amount
        local j=start(o,true,{v})
        local want=q().current.waterUnit
        for frame=1,90 do q().current:updateUse(f32(frame/91)) end
        finishStock("ISTakeWaterAction");j:tick()
        assert(j.state=="finished" and j.count==1,string.format("%.4f L from %.4f L",want,have))
        assert(math.abs(v.fluid.amount-before-want)<.001)
        P.square.rows={};put(v,holder())
    end
end)
check("changed return permissions never place in a sibling shelf or report complete",function()
    local j,v,s,o=loanStart("Rain","collector",3,Fluid.Water)
    armMove(j,v,s,P.main):perform();local a=untilAction(j,"ISTakeWaterAction");assert(not a:waitToStart())
    finishStock("ISTakeWaterAction");j:tick();s.hasRoomFor=no
    for _=1,4 do j:tick()end
    assert(j.state=="cancelled" and j.count==0 and j.liters==2 and v.holder==P.main and o.amount==1)
    assert(j.reason:find("return was not confirmed",1,true) and not q().current)
end)
check("MP receiver identity requires accepted transactions + reciprocal shelf mirrors; water requires both finite deltas, never writes via client",function()
    mp=true;local ack=true
    function isItemTransactionDone(id)return id==81 and ack end
    function isItemTransactionRejected(id)return not ack end
    local j,v,s,o,sibling=loanStart("Tank","collector",5,Fluid.TaintedWater)
    local oldid=v.id
    armMove(j,v,s,P.main):perform()
    j:tick();assert(not q().current)
    local clone=item(P.main,"Jug",2,0);clone.id=oldid
    ms=ms+200;j:tick();assert(not q().current) -- add-before-remove isn't a receipt
    put(v,holder());ms=ms+200
    local water=untilAction(j,"ISTakeWaterAction");assert(water.item==clone and not water:waitToStart())
    finishStock("ISTakeWaterAction");j:tick();assert(not q().current and j.liters==0)
    o.amount=3;j:tick();assert(not q().current and j.liters==0)
    clone.fluid.amount=2;clone.fluid.kind=Fluid.TaintedWater;local back=armMove(j,clone,P.main,s);back:perform()
    local returned=item(s,"Jug",2,2,Fluid.TaintedWater);returned.id=oldid
    ms=ms+200;j:tick();assert(j.state=="running")
    put(clone,holder());ms=ms+200;j:tick()
    assert(j.state=="finished" and j.liters==2 and j.count==1 and sibling.fluid.amount==0 and returned.holder==s)
    ack=false
    local n,w,orig,fixture=loanStart("Sink","mains",10000,Fluid.Water)
    armMove(n,w,orig,P.main):perform()
    for _=1,6 do ms=ms+200;n:tick()end
    assert(n.state=="cancelled" and n.liters==0 and w.holder==orig and fixture.amount==10000 and not q().current)
end)

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
    assert(close(q().current.waterUnit,.4));finishStock("ISTakeWaterAction");n:tick()
    assert(n.state=="finished" and close(n.liters,.4))
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
check("MP perform is not success: wait for the correct item; no repeat on timeout; distinct replacement never accepted",function()
    local o=object(P.square,"Rain",40,4,Fluid.Water,"collector");local a=item(P.main,"A",1,0);local b=item(P.main,"B",1,0)
    mp=true;local j=start(o,true,{a,b});finishStock("ISTakeWaterAction");j:tick()
    assert(j.count==0 and j.state=="running" and not q().current)
    o.amount=3;j:tick();assert(j.count==0,"the fixture alone proves nothing")
    a.fluid.amount=1;j:tick();assert(j.count==1 and not q().current)
    j:tick();finishStock("ISTakeWaterAction");j:tick()
    local impostor=item(P.main,"B",1,1);o.amount=2
    traced(function(lines)
        ms=5100;j:tick();j:tick()
        local op,finish=find(lines,"OP-END"),find(lines,"END")
        assert(op.ok==false and op.check=="vessel-litres" and op.expectedLitres=="1.00000" and op.vesselBefore=="0.00000"
            and op.vesselNow=="0.00000" and op.fixtureBefore=="3.00000" and op.fixtureNow=="2.00000")
        assert(finish.state=="cancelled" and finish.phase=="receipt" and finish.check=="vessel-litres"
            and finish.submitted==true and finish.vessels==1 and finish.of==2 and finish.litres==1)
    end)
    assert(j.state=="cancelled" and j.count==1 and j.liters==1 and impostor.id~=b.id and #moves==2)
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
        assert(#q().queue==1 and q().current.item==v and close(q().current.waterUnit,.5))
        local before=o.amount
        finishStock("ISTakeWaterAction");j:tick()
        assert(j.state=="finished" and j.count==1 and close(before-o.amount,.5) and close(v.fluid.amount,d[2]))
        assert(v.id==id and v.holder==P.main and P.worn[v]==d[3] and P.primary==shovel)
        assert(spare.fluid.amount==d[2]-.5 and (not contents or v.bag.rows[1]==contents and contents.holder==v.bag))
        v.fluid.amount=d[2]-.5
        local n=start(o,true,{v});q().current:updateUse(.5);n:cancel();n:tick()
        assert(n.state=="cancelled" and n.count==0 and #q().queue==0 and close(v.fluid.amount,d[2]-.25))
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
    assert(close(q().current.waterUnit,.5))
    finishStock("ISTakeWaterAction");j:tick()
    assert(j.state=="finished" and close(held.fluid.amount,.5) and P.secondary==held)
    local n=start(o,true,{attached})
    -- Attachment alone is not native isEquipped/isEquippedClothing.
    assert(close(q().current.waterUnit,.15) and P.attached[attached]==0)
    finishStock("ISTakeWaterAction");n:tick()
    assert(n.state=="finished" and close(attached.fluid.amount,.15) and P.attached[attached]==0)
    local stale=start(o,true,{attached});P.attached[attached]=nil;stale:tick();stale:tick()
    assert(stale.state=="cancelled" and close(attached.fluid.amount,.15) and #q().queue==0)
    P.attached[attached]=0
    mp=true
    local swap=start(o,true,{attached});finishStock("ISTakeWaterAction")
    put(attached,holder())
    local lookalike=wearable("Attached",2,.30,0);lookalike.id=attached.id
    swap:tick();swap:tick()
    assert(swap.state=="cancelled" and swap.count==0 and lookalike~=attached)
end)
print("Installed stock world-fluid actions and Kahlua/portable adapter traces complete; engine objects and network transport are doubles.")
