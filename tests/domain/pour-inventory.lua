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
    item(inner.bag,"Nested",1,0)
    local nested=item(gear.bag,"Flask",1,.8)
    local stray=bag(p.main,"Unequipped");item(stray.bag,"Stray",1,0)
    item(loot,"Loot",1,0)
    local invalid=item(p.main,"Invalid",1,0);invalid.fluid.reject=true
    local result=assert(Pour.collect(p,w,source,loot,{}))
    assert(result.source.item==source and #result.targets==5)
    assert(result.fill[1].item==small and result.fill[2].item==duplicate and result.fill[3].item==large)
    local eq=assert(Pour.collect(p,w,source,loot,{pourFillScope="equipped-first",pourFillOrder="largest-first"}))
    assert(eq.fill[1].item==gear and eq.fill[2].item==nested and eq.fill[3].item==large)
    local only=assert(Pour.collect(p,w,source,loot,{pourFillScope="main-only"}))
    assert(#only.targets==5 and #only.fill==3)
    assert(result.fill[1].label~=result.fill[2].label and result.fill[1].icon)
    assert(result.fill[1].label:find("Main inventory",1,true) and result.fill[1].label:find("0.5 L free",1,true))
    assert(eq.fill[2].label:find("Hydration bag",1,true))
    assert(Pour.revalidate(p,w,result.fill[4],loot,{},result.source))
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
print("PASS PourInventory scope, order, exact endpoints and native suitability")
