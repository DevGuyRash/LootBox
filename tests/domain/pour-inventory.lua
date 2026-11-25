package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Pour = require "LootBox/PourInventory"

local function container(owner)
    local c={items={}, owner=owner}
    function c:getItems() return {size=function() return #c.items end, get=function(_,i) return c.items[i+1] end} end
    function c:getContainingItem() return self.owner end
    function c:isLockedToCharacter() return self.lock == true end
    function c:getType() return self.floor and "floor" or "container" end
    return c
end
local nextId=0
local stockFluid = {}
local function item(c, name, cap, amount)
    nextId=nextId+1
    local i={id=nextId, container=c, name=name}
    for key, field in pairs({getID="id",getName="name",getInventory="bag",getFluidContainer="fluid",getContainer="container",
        getTex="name",getWorldItem="wrapper"}) do i[key]=function(self) return self[field] end end
    function i:getFullType() return "Base." .. self.name end
    function i:isSealed() return self.sealed==true end
    if cap then
        i.fluid={cap=cap, amount=amount,owner=i}
        function i.fluid:getOwner() return self.owner end
        function i.fluid:getAmount() return self.amount end
        function i.fluid:getCapacity() return self.cap end
        function i.fluid:getFreeCapacity() return self.cap-self.amount end
        function i.fluid:canPlayerEmpty() return self.cannotEmpty~=true end
        function i.fluid:createFluidSample()
            return {size=function() return self.amount>0 and 1 or 0 end,
                getFluid=function(_,index) if index==0 then return stockFluid end end,
                getPercentage=function(_,index) if index==0 then return 1 end end,
                release=function() end}
        end
    end
    c.items[#c.items+1]=i
    return i
end
local function bag(c,name,cap)
    local b=item(c,name,cap,0);b.bag=container(b);return b
end
local function fixture()
    local p={main=container(), gear={}, square={}}
    function p:getSquare() return self.square end
    function p:getInventory() return self.main end
    function p:getPrimaryHandItem() return self.primary end
    function p:getSecondaryHandItem() return self.secondary end
    function p:getAttachedItems() return {contains=function(_,i) return self.gear[i]==true end} end
    local loot, world=container(), {}
    function world:consumptionSource(i,c)
        return c==loot and not self.deny and i.container==loot
    end
    FluidUtil={roundTransfer=function(amount) return math.floor(amount*1000+.5)/1000 end}
    FluidContainer={CanTransfer=function(source,target) return not source.reject and not target.reject end}
    return p,world,loot
end
do
    local p,w,loot=fixture()
    local source=item(p.main,"Source",3,2)
    local large, small, duplicate=item(p.main,"Bottle",2,0),item(p.main,"Bottle",1,.5),item(p.main,"Bottle",1,.5)
    local gear=bag(p.main,"Hydration bag",3);p.gear[gear]=true
    local inner=bag(gear.bag,"Pouch")
    local deeper=item(inner.bag,"Nested",1,0)
    local nested=item(gear.bag,"Flask",1,.8)
    local stray=bag(p.main,"Unequipped");local inStray=item(stray.bag,"Stray",1,0)
    item(stray.bag,"Full",1,1)
    item(loot,"Loot",1,0)
    local invalid=item(p.main,"Invalid",1,0);invalid.fluid.reject=true
    local result=assert(Pour.collect(p,w,source,loot,{}))
    assert(result.source.item==source and #result.targets==7)
    assert(result.fill[1].item==small and result.fill[2].item==duplicate and result.fill[3].item==large)
    local eq=assert(Pour.collect(p,w,source,loot,{pourFillScope="equipped-first",pourFillOrder="largest-first"}))
    assert(eq.fill[1].item==gear and eq.fill[2].item==deeper and eq.fill[3].item==nested and eq.fill[4].item==large)
    local only=assert(Pour.collect(p,w,source,loot,{pourFillScope="main-only"}))
    assert(#only.targets==7 and #only.fill==3)
    assert(result.fill[1].place=="Main inventory" and eq.fill[3].place=="Hydration bag")
    assert(Pour.revalidate(p,w,result.fill[4],loot,{},result.source))
    local inBag=result.fill[#result.fill]
    assert(inBag.item==inStray and inBag.scope=="carried" and Pour.revalidate(p,w,inBag,loot,{},result.source))
    stray.bag.lock=true
    assert(not Pour.revalidate(p,w,inBag,loot,{},result.source))
    p.gear[gear]=nil
    assert(not Pour.revalidate(p,w,result.fill[4],loot,{},result.source))
end
do
    local p,w,loot=fixture()
    local source=item(loot,"Source",2,1)
    local target=item(loot,"Loot",1,0)
    local other=item(p.main,"Main",1,0)
    local r=assert(Pour.collect(p,w,source,loot,{}));assert(#r.targets==1 and r.targets[1].item==other)
    local opt={pourLootToLoot=true}
    r=assert(Pour.collect(p,w,source,loot,opt));assert(#r.targets==2)
    assert(Pour.revalidate(p,w,r.targets[1],loot,opt,r.source))
    assert(not Pour.revalidate(p,w,r.targets[1],container(),opt,r.source))
    assert(not Pour.revalidate(p,w,r.targets[1],loot,{},r.source))
    w.deny=true;assert(not Pour.collect(p,w,source,loot,opt))
    w.deny=false;source.sealed=true;assert(not Pour.collect(p,w,source,loot,opt))
    source.sealed=false;source.fluid.cannotEmpty=true;assert(not Pour.collect(p,w,source,loot,opt))
    source.fluid.cannotEmpty=false;loot.floor=true
    local function wrapper(i)
        local component={}
        for k,v in pairs(i.fluid) do component[k]=v end
        function component:isMultiTileMoveable() return self.multitile==true end
        local native={getItem=function() return i end,getFluidContainer=function() return component end,
            getSquare=function() return p.square end,isExistInTheWorld=function(self) return not self.stale end}
        component.owner=native
        return native,component
    end
    local so,sf=wrapper(source)
    local to,tf=wrapper(target)
    assert(not Pour.collect(p,w,source,loot,opt), "item-only floor fluid is never offered or borrowed")
    source.wrapper,target.wrapper=so,to
    sf.multitile=true
    assert(not Pour.collect(p,w,source,loot,opt), "stock rejects multi-tile world fluid even with an item component")
    sf.multitile=false
    r=assert(Pour.collect(p,w,source,loot,opt));assert(r.source.object==so and r.source.fluid==sf and sf~=source.fluid)
    source.fluid,target.fluid=nil,nil
    r=assert(Pour.collect(p,w,source,loot,opt));assert(r.source.object==so and r.source.fluid==sf)
    assert(#r.targets==1 and r.targets[1].item==other, "native world-to-world is unavailable")
    assert(Pour.revalidate(p,w,r.targets[1],loot,opt,r.source))
    so.stale=true
    assert(not Pour.revalidate(p,w,r.targets[1],loot,opt,r.source))
    so.stale=false
    local fake=item(loot,"Source",2,1)
    fake.wrapper=so
    assert(not Pour.collect(p,w,fake,loot,opt), "same-name pseudo-item cannot borrow a real wrapper")
    so.getItem=function() return target end
    assert(not Pour.revalidate(p,w,r.targets[1],loot,opt,r.source))
end
do
    local p,w,loot=fixture()
    local source=item(p.main,"Source",1,.9)
    local a,b=item(p.main,"A",1,0),item(p.main,"B",1,0)
    local duplicate=item(p.main,"Duplicate",1,0);duplicate.id=a.id
    local ghost=item(p.main,"Ghost",1,0);ghost.fluid.owner=b
    local multi=item(p.main,"MultiTile",1,0);function multi.fluid:isMultiTileMoveable() return true end
    local tiny=item(p.main,"Tiny",1,.99999)
    local r=assert(Pour.collect(p,w,source,loot,{}))
    assert(#r.targets==1 and r.targets[1].item==b)
    b.fluid.amount=1
    assert(Pour.accessible(p,w,r.targets[1],loot))
    assert(not Pour.revalidate(p,w,r.targets[1],loot,{},r.source))
    source.fluid.amount=0
    assert(Pour.accessible(p,w,r.source,loot))
    assert(not Pour.revalidate(p,w,r.source,loot,{}))
end
do
    local p,w,loot=fixture()
    local original=item(loot,"Source",2,1)
    item(p.main,"Bottle",1,0)
    local r=assert(Pour.collect(p,w,original,loot,{}))
    local moved=item(p.main,"Source",2,1);moved.id=original.id
    assert(not Pour.rebind(p,w,r.source,moved,loot,loot))
    local rebound=assert(Pour.rebind(p,w,r.source,moved,p.main,loot))
    assert(rebound.item==moved and rebound.id==original.id and rebound.scope=="main")
    moved.name="Unrelated"
    assert(not Pour.rebind(p,w,r.source,moved,p.main,loot))
    moved.name="Source"
    local old=moved.fluid
    local water,gas={},{}
    local parts={{water,.8},{gas,.2}}
    local released=0
    function old:createFluidSample()
        return {size=function() return #parts end,
            getFluid=function(_,i) return parts[i+1][1] end,
            getPercentage=function(_,i) return parts[i+1][2] end,
            release=function() released=released+1 end}
    end
    local mix=assert(Pour.mix(rebound))
    parts={{gas,.2},{water,.8}}
    assert(Pour.sameMix(rebound,mix) and released==2)
    parts={{gas,.25},{water,.75}}
    assert(not Pour.sameMix(rebound,mix) and released==3)
    moved.fluid=item(p.main,"Other",2,0).fluid
    moved.fluid.owner=moved
    assert(not Pour.stillHere(p,w,rebound,loot,{}))
    local valid,after=Pour.accessible(p,w,rebound,loot,true)
    assert(valid and after.fluid==moved.fluid and after.amount==0)
end
do
    local p,w,loot=fixture()
    local source=item(loot,"Source",3,2)
    local protected=item(loot,"Reserved",1,0)
    local favorite=item(loot,"Favorite",1,0)
    function favorite:isFavorite() return true end
    function w:protected(i) return i==protected end
    local seen=0
    local check=w.consumptionSource
    function w:consumptionSource(i,c) seen=seen+1;return check(self,i,c) end
    for _=1,600 do item(loot,"Nonfluid") end
    local late=item(loot,"Late",1,0)
    local opt={pourLootToLoot=true}
    local plan=assert(Pour.collect(p,w,source,loot,opt))
    assert(seen==2 and not plan.truncated and #plan.fill==1 and plan.fill[1].item==late)
    for _=1,4000 do item(loot,"Nonfluid") end
    seen=0
    plan=assert(Pour.collect(p,w,source,loot,opt))
    assert(seen==2 and plan.truncated and #plan.fill==0 and #plan.targets==1 and plan.targets[1].item==late)
end
do
    local p,w,loot=fixture()
    local source=item(p.main,"Source",3,2)
    for _=1,513 do item(p.main,"Bottle",1,0) end
    local plan=assert(Pour.collect(p,w,source,loot,{}))
    assert(plan.truncated and #plan.fill==0 and #plan.targets==512)
end
do
    local p,w,loot=fixture()
    local source=item(p.main,"Source",2,1)
    local custom=bag(p.main,"Custom modded tote")
    local held=item(custom.bag,"Bottle",1,0)
    function p:isEquipped(i) return i==custom end
    local plan=assert(Pour.collect(p,w,source,loot,{}))
    assert(#plan.targets==1 and plan.targets[1].item==held and plan.targets[1].scope=="equipped")
    custom.container=loot -- capability alone cannot make a stale bag part of main inventory
    assert(not Pour.stillHere(p,w,plan.targets[1],loot,{}))
    plan=assert(Pour.collect(p,w,source,loot,{}))
    assert(#plan.targets==0)
end
do
    local p,w,loot=fixture()
    local a=item(loot,"Carton",3,2)
    local b=item(loot,"Carton",3,1.5)
    local m=item(p.main,"Bottle",1,0)
    local second=item(p.main,"Bottle",1,.25)
    local third=item(p.main,"Bottle",1,.5)
    local conflict=item(loot,"Duplicate ID",3,1);conflict.id=third.id
    local alias=item(loot,"Duplicate fluid ref",3,1);alias.fluid=b.fluid
    loot.items[#loot.items+1]=b -- same real item row is not a second vessel
    local reached=0
    local check=w.consumptionSource
    function w:consumptionSource(i,c) reached=reached+1;return check(self,i,c) end
    local snap=Pour.snapshot(p,w,loot,loot)
    local once=reached
    local first=assert(Pour.source(snap,a));assert(Pour.source(snap,b))
    assert(not Pour.source(snap,m))
    assert(not Pour.source(snap,conflict) and not Pour.source(snap,alias))
    assert(not Pour.source(Pour.snapshot(p,w,loot,nil),a) and reached==once)
    local x,y=assert(Pour.plan(snap,a)),assert(Pour.plan(snap,b))
    assert(#x.targets==2 and #y.targets==2 and reached==once)
    assert(x.targets[1].item==m and x.targets[2].item==second and y.targets[1]~=x.targets[1])
    assert(y.targets[1].label==x.targets[1].label)
    local label=x.targets[1].label
    x.targets[1].label="tampered";x.source.label="tampered"
    a.fluid.amount=.5;m.fluid.amount=.8
    local again=assert(Pour.plan(snap,a))
    assert(again.source.label==first.label and again.source.amount==2 and again.targets[1].label==label
        and again.targets[1].amount==0 and reached==once)
    local enabled=assert(Pour.plan(snap,a,{pourLootToLoot=true}))
    assert(#enabled.targets==3 and reached==once)
    for _,e in ipairs(enabled.targets) do assert(e.item~=a and e.id~=third.id and e.item~=alias) end
end
do
    local p,w,loot=fixture()
    local lowLiters=item(p.main,"A",2,1)
    local lowRatio=item(p.main,"A",8,2)
    local sameRatioSmaller=item(p.main,"A",4,1)
    local sameBothLater=item(p.main,"A",4,1)
    local target=item(p.main,"Target",1,0)
    local empty=item(p.main,"Empty",2,0)
    local otherHolder=item(loot,"Hidden",20,.1)
    local dupe=item(p.main,"Duplicate",100,1)
    local dupeWitness=item(p.main,"Duplicate witness",100,1);dupeWitness.id=dupe.id
    local snap=Pour.snapshot(p,w,p.main,loot)
    local choices={empty,otherHolder,dupe,lowLiters,sameBothLater,lowRatio,sameRatioSmaller,sameRatioSmaller}
    local chosen=assert(Pour.choose(snap,choices,{}))
    assert(chosen.source.item==sameRatioSmaller, "smallest ratio, liters then exact stable ID")
    chosen=assert(Pour.choose(snap,{lowLiters,lowRatio},{}))
    assert(chosen.source.item==lowRatio, "smallest ratio must beat smaller absolute liters")
    local accepted={}
    FluidContainer.CanTransfer=function(from,to)
        accepted[from]=(accepted[from] or 0)+1
        return from~=sameRatioSmaller.fluid and to==target.fluid
    end
    chosen=assert(Pour.choose(snap,choices,{}))
    assert(chosen.source.item==sameBothLater and chosen.targets[1].item==target)
    assert(accepted[sameRatioSmaller.fluid] and accepted[sameBothLater.fluid]
        and not accepted[lowLiters.fluid] and not accepted[lowRatio.fluid])
    assert(not Pour.choose(snap,{empty,otherHolder,dupe},{}))
    snap.truncated=true
    assert(not Pour.choose(snap,choices,{}), "an incomplete group may not select an uncertain substitute")
end
do
    local p,w,loot=fixture()
    local choices={}
    for i=1,5 do choices[i]=item(p.main,"Source",10,i*.1) end
    for _=1,2200 do item(p.main,"Bottle",1,0) end
    local probes=0
    FluidContainer.CanTransfer=function(from)
        probes=probes+1
        return from==choices[5].fluid
    end
    local plan,why=Pour.choose(Pour.snapshot(p,w,p.main,loot),choices,{})
    assert(not plan and why:find("Too many",1,true) and probes<=8192)
end
do
    local p,w,loot=fixture()
    local receiver=item(loot,"Receiver",2,.2)
    local main=item(p.main,"Main donor",3,.8)
    local pack=bag(p.main,"Pack");p.gear[pack]=true
    local bagged=item(pack.bag,"Bagged donor",2,1.2)
    local sibling=item(loot,"Loot donor",1,.4)
    item(loot,"Empty",1,0)
    local hidden=item(container(),"Hidden",1,1)
    local empty=item(p.main,"Empty",1,0)
    local bad=item(p.main,"Forbidden",1,.6)
    local unreadable=item(p.main,"Unknown",1,.5);unreadable.fluid.createFluidSample=function() return nil end
    FluidContainer.CanTransfer=function(from,to) return from~=bad.fluid and to==receiver.fluid end
    local function inverse(prefs)
        return Pour.fillFrom(Pour.snapshot(p,w,loot,loot),{receiver},prefs or {})
    end
    local a=assert(inverse())
    local target=a.targets[1]
    assert(#a.targets==1 and target.item==receiver and target.pourSignature and #a.donors==2)
    local one,two=a.donors[1].source,a.donors[2].source
    assert(one.item==main and two.item==bagged and two.scope=="equipped")
    assert(one.pourSignature and two.pourSignature and a.donors[1].targets[1].relation=="same")
    local opt={pourLootToLoot=true}
    local b=assert(inverse(opt))
    assert(#b.donors==3 and b.donors[3].source.item==sibling)
    for _,d in ipairs(b.donors) do local i=d.source.item;assert(i~=receiver and i~=hidden and i~=empty) end
    assert(not Pour.revalidate(p,w,target,loot,opt,one),"normal carried-source action cannot target loot")
    assert(Pour.revalidate(p,w,target,loot,{},one,receiver))
    assert(not Pour.revalidate(p,w,target,loot,{},one,sibling))
    assert(not Pour.revalidate(p,w,target,loot,{},b.donors[3].source,receiver))
    assert(Pour.revalidate(p,w,target,loot,opt,b.donors[3].source,receiver))
    assert(not Pour.fillFrom(Pour.snapshot(p,w,loot,nil),{receiver},opt),"an unshown holder is not a destination")
    assert(not Pour.fillFrom(Pour.snapshot(p,w,loot,loot),{receiver,sibling},opt),"several loot receivers are never one choice")
    assert(#assert(Pour.collect(p,w,main,loot,opt)).targets==0,"inverse menu cannot widen regular Pour Into")
    pack.bag.lock=true;assert(#assert(inverse()).donors==1)
    loot.lock=true;assert(not inverse(opt));loot.lock=false
    receiver.fluid.amount=2;assert(not inverse(opt));receiver.fluid.amount=0
    local fromEmpty=assert(inverse());assert(not fromEmpty.targets[1].pourSignature and #fromEmpty.donors==1)
    receiver.sealed=true;assert(not inverse(opt));receiver.sealed=false
    w.deny=true;assert(not inverse(opt));w.deny=false
    item(p.main,"Collision",1,.4).id=receiver.id;assert(not inverse(opt))
end
do
    -- Water into: empty, water, a 0.2% trace, milk. Only milk would be contaminated.
    local p,w=fixture()
    local water,milk={},{}
    local function vessel(name,capacity,amount,parts)
        local i=item(p.main,name,capacity,amount)
        i.fluid.createFluidSample=function(self)
            return {size=function() return self.amount>0 and #parts or 0 end,getFluid=function(_,n) return parts[n+1][1] end,
                getPercentage=function(_,n) return parts[n+1][2] end,release=function() end}
        end
        return i
    end
    local source=vessel("Bucket",10,5,{{water,1}})
    local empty,same=vessel("Empty",1,0,{}),vessel("Same",1,.4,{{water,1}})
    local trace=vessel("Trace",1,.5,{{water,.998},{milk,.002}})
    local other=vessel("Milk",1,.95,{{milk,1}})
    local plan=assert(Pour.collect(p,w,source,nil,{}))
    local relation={}
    for _,e in ipairs(plan.targets) do relation[e.item]=e.relation end
    assert(relation[empty]=="empty" and relation[same]=="same" and relation[trace]=="same" and relation[other]=="mixes")
    assert(#plan.fill==3)
    for _,e in ipairs(plan.fill) do assert(e.item~=other,"the fullest vessel of another liquid used to be filled first") end
    local inverse=assert(Pour.fillFrom(Pour.snapshot(p,w,p.main,nil),{empty,other},{}))
    for _,donor in ipairs(inverse.donors) do
        local fill=Pour.batch(donor.targets,{})
        assert(#fill==1 and fill[1].item==empty)
    end
end
do
    -- Favorite and Keep guard against moving and deleting; a pour does neither.
    local w={protected=function(_,i) return i.reason~=nil,i.reason end}
    assert(not Pour.reserved(w,{reason="Favorite"}) and not Pour.reserved(w,{reason="Keep"}) and not Pour.reserved(w,{}))
    assert(Pour.reserved(w,{reason="Personal gear reserved for recovery"}) and Pour.reserved(w,{reason="Equipped"}))
end
do
    local p,w=fixture()
    local source=item(p.main,"Source",3,2)
    local nails,equipment=600,0
    for _=1,nails do item(p.main,"Nails") end
    item(p.main,"Bottle",1,0)
    function p:getWornItems() equipment=equipment+1;return nil end
    assert(Pour.collect(p,w,source,nil,{}))
    assert(equipment<=4,"cargo without liquid is not tested against the player's equipment")
    local bottle=item(p.main,"Bottle",1,.5)
    bottle.fluid.getTranslatedContainerName=function() return "Water Bottle" end
    bottle.fluid.getPrimaryFluid=function() return {getTranslatedName=function() return "Water" end} end
    local e={item=bottle,fluid=bottle.fluid,amount=.5,capacity=1}
    assert(Pour.vesselName(e)=="Water Bottle" and Pour.liquid(bottle.fluid)=="Water" and Pour.litres(.5)=="0.5" and Pour.litres(1)=="1")
    bottle.fluid.amount,e.amount=0,0
    assert(Pour.vesselName(e)=="Bottle" and not Pour.liquid(bottle.fluid))
end
do
    local p,w=fixture()
    local source=item(p.main,"Source",3,2)
    local target=item(p.main,"Bottle",1,0)
    local e=assert(Pour.collect(p,w,source,nil,{})).targets[1]
    local ok,live=Pour.accessible(p,w,e,nil);assert(ok and live.item==target)
    target.id=999
    local _,why=Pour.accessible(p,w,e,nil);assert(why=="vessel-identity")
    target.id=e.id;target.container=container()
    _,why=Pour.accessible(p,w,e,nil);assert(why=="item-moved")
end
print("PASS PourInventory scope, order, exact endpoints, inverse donor direction and native suitability")
