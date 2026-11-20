package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local context
local function adapter(kind)
    local a={}
    function a:isBusy() return self.pending~=nil end
    function a:cancel()
        if self.pending then context.cancels=context.cancels+1;self.pending.cancelled=true end
    end
    function a:start(item,dst,third,validate,anchor)
        if self.pending then return nil,"busy" end
        local req={kind=kind,item=item,target=dst,third=third,anchor=anchor}
        req.guard=validate
        local ok=kind~="pour" and validate("admit",item) or kind=="pour" and validate(item,dst,"admit")
        if not ok or context.reject==kind then return nil,"stock refused "..kind end
        self.pending=req
        context.calls[#context.calls+1]=req
        return true
    end
    function a:poll()
        local req=self.pending
        if not req or not req.reply then return nil end
        self.pending=nil
        return req.reply[1],req.reply[2],req.reply[3]
    end
    return a
end
package.loaded["LootBox/PourMove"]={new=function() return adapter("move") end}
package.loaded["LootBox/PourNative"]={new=function() return adapter("pour") end}
package.loaded["LootBox/PourGround"]={
    new=function() return adapter("ground") end,
    capture=function(_,item,floor) return item.groundAnchor and item.groundAnchor.floor==floor and item.groundAnchor or nil end,
    reachable=function(_,anchor) return not anchor.blocked end,
    sameAnchor=function(a,b) return a==b end
}
local Pour=require "LootBox/Pour"
local Inventory=require "LootBox/PourInventory"

local function list(array)
    return {size=function() return #array end,get=function(_,i) return array[i+1] end,
        contains=function(_,item) for _,v in ipairs(array) do if v==item then return true end end;return false end}
end
local function container(kind,owner)
    local c={kind=kind,owner=owner,items={}}
    function c:getItems() return list(self.items) end
    function c:getType() return self.kind end
    function c:getContainingItem() return self.owner end
    function c:isLockedToCharacter() return self.lock==true end
    return c
end
local milk,water={},{}
local function item(c,id,name,capacity,amount,species)
    local i={id=id,name=name,container=c}
    function i:getID() return self.id end
    function i:getFullType() return "Base."..self.name end
    function i:getName() return self.name end
    function i:getContainer() return self.container end
    function i:getInventory() return self.bag end
    function i:isSealed() return false end
    function i:isFavorite() return self.favorite==true end
    function i:getFluidContainer() return self.fluid end
    if capacity then
        local f={owner=i,amount=amount,capacity=capacity,species=species or milk}
        function f:getOwner() return self.owner end
        function f:getAmount() return self.amount end
        function f:getCapacity() return self.capacity end
        function f:getFreeCapacity() return self.capacity-self.amount end
        function f:canPlayerEmpty() return true end
        function f:createFluidSample()
            return {size=function() return self.amount>0 and 1 or 0 end,
                getFluid=function() return self.species end,getPercentage=function() return 1 end,release=function() end}
        end
        i.fluid=f
    end
    table.insert(c.items,i)
    return i
end
local function fixture()
    local f={main=container("inventory"), shelf=container("counter"),calls={},cancels=0,queue={queue={}},
        options={pourLootToLoot=false,pourFillScope="main-first",pourFillOrder="smallest-first"}}
    context=f;f.pane=f.shelf
    getTimestampMs=function() return 1000 end
    local p={};f.player=p
    function p:getInventory() return f.main end
    function p:isLocalPlayer() return true end
    function p:getCurrentSquare() return {} end
    function p:isMoving() return f.moving==true end
    function p:getPlayerNum() return 0 end
    function p:getPrimaryHandItem() return f.held end
    for _,name in ipairs({"isDead","isAsleep","isRunning","isSprinting","isAiming","isAttacking","isShoving",
        "isClimbing","isKnockedDown","hasTimedActions"}) do p[name]=function() return false end end
    f.world={pourShelfAnchor=function(_,c) return c==f.shelf and {c} or nil end,protected=function(_,i) return i.keep==true end, pourShelfReachable=function(_,c) return c==f.shelf and not f.blocked end,
        consumptionSource=function(_,i,c) return i.container==c and c==f.shelf and not f.blocked end}
    ISTimedActionQueue={getTimedActionQueue=function() return f.queue end}
    FluidContainer={CanTransfer=function(_,b) return not b.rejected end}
    FluidUtil={roundTransfer=function(n) return math.floor(n*1000+.5)/1000 end}
    function f:start(source, targets)
        local plan=assert(Inventory.collect(p,self.world,source,self.pane,self.options))
        local picks=plan.fill
        if targets then
            picks={}
            for _,item_ in ipairs(targets) do
                for _,entry in ipairs(plan.targets) do if entry.item==item_ then picks[#picks+1]=entry end end
            end
            assert(#picks==#targets)
        end
        self.job=assert(Pour.new(p,self.world,plan.source,picks,self.options,function() return self.options,self.pane end))
        return self.job
    end
    return f
end
local function remove(item_)
    local a=item_.container.items
    for n,v in ipairs(a) do if v==item_ then table.remove(a,n);return end end
    error("Stale item")
end
local function moveAck(f,replicate, success)
    local q=assert(f.job.move.pending)
    local i=q.item
    assert(q.guard("admit",i))
    if success==false then q.reply={false,"transfer denied"};return i end
    remove(i)
    if replicate then i=item(q.third,i.id,i.name,i.fluid.capacity,i.fluid.amount,i.fluid.species)
    else i.container=q.third;table.insert(q.third.items,i) end
    q.reply={true,"confirmed",i}
    f.job:tick()
    return i
end
local function fluidAck(f,amount,partial)
    local q=assert(f.job.pour.pending)
    assert(q.guard(q.item,q.target,"observe"))
    q.item.fluid.amount=q.item.fluid.amount-amount
    if partial then return end
    q.target.fluid.amount=q.target.fluid.amount+amount
    q.reply={true,"paired",amount}
    f.job:tick()
end
local function isCall(f,i,kind,id,dest)
    local q=assert(f.calls[i],"missing call "..i)
    assert(q.kind==kind and q.item.id==id and (not dest or q.target==dest),"wrong call "..i)
end
local tests=0
local function test(name,fn)
    local ok,err=pcall(fn);if not ok then error(name..": "..tostring(err),0) end
    tests=tests+1;print("PASS "..name)
end

test("shelf milk stages one exact replica, pours and returns to the captured shelf",function()
    local f=fixture()
    local source,target=item(f.shelf,1,"Carton",2,1.5),item(f.main,2,"Bottle",1,0)
    local j=f:start(source);j:tick();isCall(f,1,"move",1,f.shelf)
    local replica=moveAck(f,true);assert(replica~=source and replica.container==f.main)
    j:tick();isCall(f,2,"pour",1,target)
    fluidAck(f,1);j:tick();isCall(f,3,"move",1,f.main)
    local returned=moveAck(f,true);j:tick()
    assert(returned~=replica and returned.container==f.shelf and returned.fluid.amount==.5)
    assert(j.state=="finished" and j.count==1 and j.liters==1)
end)

local function markGround(f,i,origin)
    f.shelf.kind="floor"
    local anchor={floor=f.shelf,square=origin}
    i.groundAnchor=anchor
    function i:getWorldItem()
        if self.container~=f.shelf then return nil end
        return {getItem=function() return self end,getSquare=function() return f.square end,
            getFluidContainer=function() return self.fluid end,isExistInTheWorld=function() return true end}
    end
    function f.player:getSquare() return f.square end
    f.square=f.square or {}
    return anchor
end

test("Ground item-owned fluid uses the exact placement adapter for both moves",function()
    local f=fixture()
    local src,dst=item(f.shelf,1,"Animal's Milk (Bucket)",2,1.5),item(f.main,2,"Empty Bucket",1,0)
    local origin=markGround(f,src,{kind="adjacent"})
    local j=f:start(src)
    j:tick();isCall(f,1,"ground",1,f.shelf);assert(f.calls[1].anchor==origin)
    moveAck(f,false)
    j:tick();isCall(f,2,"pour",1,dst);fluidAck(f,1)
    j:tick();isCall(f,3,"ground",1,f.main);assert(f.calls[3].anchor==origin)
    moveAck(f,false);j:tick()
    assert(j.state=="finished" and src.container==f.shelf and src.fluid.amount==.5 and dst.fluid.amount==1)
end)

test("Ground source blocked after pickup cannot redirect the pour",function()
    local f=fixture()
    local src=item(f.shelf,1,"Animal's Milk (Bucket)",2,1)
    item(f.main,2,"Empty Bucket",1,0)
    local origin=markGround(f,src,{})
    local j=f:start(src)
    j:tick();moveAck(f,false)
    origin.blocked=true
    j:tick()
    assert(j.state=="cancelled" and #f.calls==1 and src.container==f.main and j.reason:find("main inventory",1,true))
end)

local function stockGround(f,source)
    f.shelf.kind="floor"
    local square={}
    local fluid=source.fluid
    local world={getItem=function() return source end,getSquare=function() return square end,
        getFluidContainer=function() return fluid end,isExistInTheWorld=function() return true end}
    function f.player:getSquare() return square end
    function fluid:isMultiTileMoveable() return false end
    function source:getFluidContainer() return nil end
    function source:getWorldItem() return world end
    fluid.owner=world
end

test("stock facing refresh does not cancel the owned Ground action or its terminal receipt",function()
    local f=fixture()
    local src,dst=item(f.shelf,1,"Ground Bucket",2,1.5),item(f.main,2,"Bottle",1,0)
    stockGround(f,src)
    local j=f:start(src,{dst})
    j:tick();isCall(f,1,"pour",1,dst)
    f.pane=container("counter")
    fluidAck(f,1)
    j:tick()
    assert(j.state=="finished" and j.count==1 and #f.calls==1 and f.cancels==0)
    assert(src.fluid.amount==.5 and dst.fluid.amount==1)
end)

test("a stale Ground tab cannot authorize a new pour or hide player interruption",function()
    for _,mode in ipairs({"before", "batch", "moving", "unreachable"}) do
        local f=fixture()
        local src=item(f.shelf,1,"Ground Bucket",3,2.5)
        local dst,other=item(f.main,2,"Bottle",1,0),item(f.main,3,"Other Bottle",1,0)
        stockGround(f,src)
        local j=f:start(src,{dst,other})
        if mode~="before" then j:tick();isCall(f,1,"pour",1,dst) end
        f.pane=container("counter")
        if mode=="batch" then
            fluidAck(f,1)
        elseif mode=="moving" then
            f.moving=true;j:tick();assert(f.cancels==1)
        elseif mode=="unreachable" then
            f.blocked=true
            local q=assert(j.pour.pending)
            assert(not q.guard(q.item,q.target,"active"))
            q.reply={false,"out of reach",0}
        end
        j:tick()
        assert(#f.calls==(mode=="before" and 0 or 1) and other.fluid.amount==0)
        assert(j.state~="finished",mode)
    end
end)

test("opt-in shelf target stages and returns before source return",function()
    local f=fixture();f.options.pourLootToLoot=true
    local a,b=item(f.shelf,1,"Carton",3,2),item(f.shelf,2,"Bottle",1,0)
    local j=f:start(a,{b})
    j:tick();isCall(f,1,"move",1,f.shelf);moveAck(f,true)
    j:tick();isCall(f,2,"move",2,f.shelf);local dest=moveAck(f,true)
    j:tick();isCall(f,3,"pour",1,dest);fluidAck(f,1)
    isCall(f,4,"move",2,f.main);local returnedTarget=moveAck(f,true)
    j:tick();isCall(f,5,"move",1,f.main);local returnedSource=moveAck(f,true)
    j:tick()
    assert(j.state=="finished" and returnedSource.container==f.shelf and returnedTarget.container==f.shelf)
    assert(returnedSource.fluid.amount==1 and returnedTarget.fluid.amount==1)
end)

test("Fill All respects stable main room order, waits for paired receipt and stops when source exhausted",function()
    local f=fixture()
    local a=item(f.main,1,"Carton",2,1)
    local large,small=item(f.main,3,"Big",1,0),item(f.main,2,"Small",.5,0)
    local worn=item(f.main,4,"Hydration",1,0);f.held=worn
    local j=f:start(a);j:tick();isCall(f,1,"pour",1,small)
    fluidAck(f,.5,true);j:tick();j:tick();assert(#f.calls==1 and j.count==0)
    small.fluid.amount=.5;j.pour.pending.reply={true,"paired",.5};j:tick()
    j:tick();isCall(f,2,"pour",1,large);fluidAck(f,.5);j:tick();j:tick()
    assert(#f.calls==2 and worn.fluid.amount==0 and j.state=="finished" and j.count==2)
end)

test("direct equipped reservoir pours in place with equipped-first order",function()
    local f=fixture();f.options.pourFillScope="equipped-first"
    local a=item(f.main,1,"Carton",2,1)
    local worn=item(f.main,2,"Hydration",1,0);f.held=worn
    item(f.main,3,"Small",.5,0)
    local j=f:start(a);j:tick();isCall(f,1,"pour",1,worn)
    fluidAck(f,1);j:tick()
    assert(j.state=="finished" and #f.calls==1 and worn.container==f.main and f.held==worn)
end)

test("source amount change and mixed-fluid replacement each reject before pouring",function()
    for _,which in ipairs({"amount","species"}) do
        local f=fixture()
        local a=item(f.main,1,"Carton",2,1)
        item(f.main,2,"Bottle",1,0)
        local j=f:start(a)
        if which=="amount" then a.fluid.amount=.8 else a.fluid.species=water end
        j:tick()
        assert(#f.calls==0 and j.state=="cancelled",which)
    end
end)

test("target change after staging restores exact source but cannot report success",function()
    local f=fixture()
    local a,b=item(f.shelf,1,"Carton",3,2),item(f.main,2,"Bottle",1,0)
    local j=f:start(a);j:tick();moveAck(f,true)
    b.fluid.amount=.1
    j:tick();isCall(f,2,"move",1,f.main)
    local returned=moveAck(f,true);j:tick()
    assert(returned.container==f.shelf and #f.calls==2 and j.state~="finished" and j.count==0)
end)

test("failed receipts and unrelated player work never start another action",function()
    do
        local f=fixture()
        local a=item(f.main,1,"Carton",2,2);item(f.main,2,"A",1,0);item(f.main,3,"B",1,0)
        local j=f:start(a);j:tick();j.pour.pending.reply={false,"short companion receipt",.2};j:tick();j:tick()
        assert(j.state=="cancelled" and #f.calls==1 and j.count==0)
    end
    do
        local f=fixture()
        local a=item(f.shelf,1,"Carton",2,1);item(f.main,2,"A",1,0)
        local j=f:start(a);j:tick();local held=moveAck(f,true)
        local external={Type="ISReadABook"};f.queue.queue={external};f.queue.current=external;j:tick()
        assert(j.state=="cancelled" and #f.calls==1 and f.queue.queue[1]==external and held.container==f.main)
        assert(j.reason:find("Check main inventory",1,true))
    end
    do
        local f=fixture()
        local a=item(f.shelf,1,"Carton",2,1);item(f.main,2,"A",1,0)
        local j=f:start(a);j:tick();moveAck(f,true,false);j:tick();j:tick()
        assert(j.state~="finished" and #f.calls==1 and a.container==f.shelf)
    end
    do
        local f=fixture()
        local a=item(f.main,1,"Carton",2,1);item(f.main,2,"A",1,0)
        local j=f:start(a);j:tick()
        f.moving=true;j:tick()
        assert(f.cancels>=1 and #f.calls==1 and j.pour.pending.cancelled and not j.pour.pending.guard(a,f.main,"observe"))
        j.pour.pending.reply={false,"cancelled"};j:tick();assert(j.state=="cancelled")
    end
end)
test("a frozen least-filled stack source cannot be replaced after its contents change",function()
    local f=fixture()
    local first=item(f.main,80,"Bottle",1,.8)
    local picked=item(f.main,78,"Bottle",2,.9)
    local target=item(f.main,90,"Jar",2,0)
    local frozen=Inventory.snapshot(f.player,f.world,f.main,f.pane)
    local plan=assert(Inventory.choose(frozen,{first,picked},f.options))
    assert(plan.source.item==picked and Pour.capture(plan.source))
    local dest
    for _,entry in ipairs(plan.targets)do if entry.item==target then dest=entry end end
    local j=assert(Pour.new(f.player,f.world,plan.source,{assert(dest)},f.options,function()return f.options,f.pane end))
    picked.fluid.amount=.2 -- a sibling is still safe, but never silently used
    j:tick()
    assert(j.state=="cancelled" and #f.calls==0 and first.fluid.amount==.8 and target.fluid.amount==0)
end)

test("source or target capacity drift after menu capture never dispatches or substitutes",function()
    for _,which in ipairs({"source","target"}) do
        local f=fixture()
        local sibling=item(f.main,80,"Bottle",1,.8)
        local source=item(f.main,78,"Bottle",2,.9)
        local target=item(f.main,90,"Jar",.5,0)
        local spare=item(f.main,91,"Jar",2,0)
        local frozen=Inventory.snapshot(f.player,f.world,f.main,f.pane)
        local plan=assert(Inventory.choose(frozen,{sibling,source},f.options))
        assert(plan.source.item==source and Pour.capture(plan.source))
        local dest
        for _,entry in ipairs(plan.targets) do if entry.item==target then dest=entry end end
        assert(dest and Pour.capture(dest))
        if which=="source" then source.fluid.capacity=1 else target.fluid.capacity=.25 end
        local j=Pour.new(f.player,f.world,plan.source,{dest},f.options,function() return f.options,f.pane end)
        if j then j:tick(); assert(j.state=="cancelled",which.." capacity drift did not cancel") end
        assert(#f.calls==0 and source.fluid.amount==.9 and sibling.fluid.amount==.8
            and target.fluid.amount==0 and spare.fluid.amount==0,which)
    end
end)

local function twoShelfLoans()
    local f=fixture(); f.options.pourLootToLoot=true
    local a=item(f.shelf,71,"Milk Carton",3,2)
    local b=item(f.shelf,72,"Glass Bottle",1,0)
    local c=item(f.shelf,73,"Spare Bottle",1,0)
    local j=f:start(a,{b,c})
    j:tick(); isCall(f,1,"move",71,f.shelf)
    local liveSource=moveAck(f,true)
    j:tick(); isCall(f,2,"move",72,f.shelf)
    local liveTarget=moveAck(f,true)
    return f,j,liveSource,liveTarget,c
end

test("independently changed shelved target stays in main and is reported after exact source return",function()
    local f,j,source,target,spare=twoShelfLoans()
    target.fluid.amount=.2; target.fluid.species=water
    j:tick(); isCall(f,3,"move",source.id,f.main)
    local returned=moveAck(f,true);j:tick();j:tick()
    assert(#f.calls==3 and j.count==0 and j.state~="finished")
    assert(returned.container==f.shelf and returned.fluid.amount==2 and target.container==f.main
        and target.fluid.amount==.2 and spare.container==f.shelf and spare.fluid.amount==0)
    assert(j.reason:find("Check main inventory",1,true) and j.reason:find("Glass Bottle",1,true) and j.reason:find("[ID 72]",1,true),j.reason)
end)

test("independently changed shelved source stays in main after exact untouched target returns",function()
    local f,j,source,target=twoShelfLoans()
    source.fluid.species=water
    j:tick(); isCall(f,3,"move",target.id,f.main)
    local returned=moveAck(f,true);j:tick();j:tick()
    assert(#f.calls==3 and j.count==0 and j.state~="finished")
    assert(returned.container==f.shelf and returned.fluid.amount==0 and source.container==f.main
        and source.fluid.species==water and source.fluid.amount==2)
    assert(j.reason:find("Check main inventory",1,true) and j.reason:find("Milk Carton",1,true) and j.reason:find("[ID 71]",1,true),j.reason)
end)

test("changed capacity of either staged replica leaves it reported while the other loan returns",function()
    for _,which in ipairs({"source","target"}) do
        local f,j,source,target,spare=twoShelfLoans()
        local changed,unchanged=source,target
        if which=="target" then changed,unchanged=target,source end
        local amount=changed.fluid.amount
        changed.fluid.capacity=changed.fluid.capacity+.5
        j:tick(); isCall(f,3,"move",unchanged.id,f.main)
        local returned=moveAck(f,true);j:tick();j:tick()
        assert(#f.calls==3 and j.count==0 and j.state=="cancelled",which)
        assert(returned.container==f.shelf and changed.container==f.main and changed.fluid.amount==amount
            and spare.container==f.shelf and spare.fluid.amount==0,which)
        assert(j.reason:find("Check main inventory",1,true) and j.reason:find(changed.name,1,true)
            and j.reason:find("[ID "..changed.id.."]",1,true),j.reason)
    end
end)

test("denied first unwind return is not retried and both held vessels are reported",function()
    local f,j,source,target=twoShelfLoans()
    source.fluid.amount=1.75
    j:tick(); isCall(f,3,"move",target.id,f.main)
    moveAck(f,true,false); j:tick(); j:tick()
    assert(#f.calls==3 and j.count==0 and j.state~="finished")
    assert(source.container==f.main and target.container==f.main)
    assert(j.reason:find("Check main inventory",1,true) and j.reason:find("Milk Carton",1,true)
        and j.reason:find("Glass Bottle",1,true) and j.reason:find("[ID 72]",1,true),j.reason)
end)

test("a changed original shelf holder causes no return retry or relocation",function()
    local f,j,source,target=twoShelfLoans()
    source.fluid.amount=1.5
    j:tick(); isCall(f,3,"move",target.id,f.main)
    f.pane=container("counter")
    local move=assert(j.move.pending)
    assert(not move.guard("admit",target))
    move.reply={false,"original shelf changed"};j:tick();j:tick()
    assert(#f.calls==3 and j.count==0 and j.state~="finished")
    assert(source.container==f.main and target.container==f.main and #f.pane.items==0)
    assert(j.reason:find("Check main inventory",1,true) and j.reason:find("Milk Carton",1,true)
        and j.reason:find("Glass Bottle",1,true) and j.reason:find("[ID 72]",1,true),j.reason)
end)

print("PASS "..tests.." Pour controller scenarios")
