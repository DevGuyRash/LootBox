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
        return req.reply[1],req.reply[2],req.reply[3],req.reply[4]
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

local function withReceipts(fn)
    local lines, original={}, print
    print=function(line) lines[#lines+1]=line end
    local ok, why=pcall(fn,lines)
    print=original
    assert(ok,why)
end

test("partial native stop reports exactly one terminal receipt without item names or IDs",function()
    withReceipts(function(lines)
        local f=fixture()
        local source=item(f.shelf,777001,"Custom Named Vessel",2,1.5)
        local target=item(f.main,777002,"Personal Bottle Name",1,0)
        local j=f:start(source)
        j:tick();local replica=moveAck(f,true)
        j:tick();isCall(f,2,"pour",777001,target)
        assert(#lines==0,"starting a pour is not a terminal receipt")
        local active=assert(j.pour.pending)
        local msg="The game poured only part of the requested amount."
        replica.fluid.amount=replica.fluid.amount-.25;target.fluid.amount=.25
        active.reply={false,msg,.25}
        j:tick();j:tick();j:cancel();j:tick()
        assert(j.state=="cancelled" and j.liters==.25 and j.count==0 and #f.calls==2)
        assert(j.reason:find("Custom Named Vessel",1,true) and j.reason:find("777001",1,true),"game UI still identifies an outstanding loan")
        assert(#lines==1 and lines[1]=="[LootBox] action=pour event=terminal state=cancelled nativeSubmitted=true completed=0 confirmedLitres=0.250 phase=fluid route=portable mode=SP source=loot target=main destinations=1 reason="..msg)
    end)
end)

test("ordinary early pour stops distinguish stale view, player movement and occupied queue",function()
    local cases={
        {update=function(f) f.pane=nil end,reason="The selected loot pane changed or closed."},
        {update=function(f) f.moving=true end,reason="Character moved."},
        {update=function(f) f.queue.current={} end,reason="Another action was active."},
    }
    for _,case in ipairs(cases) do
        withReceipts(function(lines)
            local f=fixture()
            local source=item(f.shelf,17101,"Source",1,.5)
            local target=item(f.main,17102,"Target",1,0)
            local j=f:start(source,{target})
            case.update(f);j:tick();j:tick()
            assert(#f.calls==0 and j.state=="cancelled" and j.reason==case.reason)
            assert(#lines==1 and lines[1]=="[LootBox] action=pour event=terminal state=cancelled nativeSubmitted=false completed=0 confirmedLitres=0.000 phase=prepare route=portable mode=SP source=loot target=main destinations=1 reason="..case.reason)
        end)
    end
end)

test("cupboard pickup rejection identifies a proven retained source without retrying or pouring",function()
    local shots,originalHUD={},PZActionCompletionHUD
    PZActionCompletionHUD={show=function(_,card) shots[#shots+1]=card end}
    local ok,err=pcall(function()
        withReceipts(function(lines)
            local f=fixture()
            local src=item(f.shelf,201,"Animal Milk Bucket",10,8)
            local dst=item(f.main,202,"Empty Dispenser Bottle",15,0)
            local j=f:start(src,{dst})
            j:tick();isCall(f,1,"move",201,f.shelf)
            local q=assert(j.move.pending)
            q.reply={false,"The server rejected the inventory move.",nil,src}
            j:tick();j:tick();j:cancel()
            assert(j.state=="cancelled" and j.count==0 and j.liters==0 and #f.calls==1)
            assert(src.container==f.shelf and src.fluid.amount==8 and dst.fluid.amount==0)
            assert(j.reason:find("confirmed in original displayed storage",1,true) and not j.reason:find("confirmed in main",1,true))
            assert(#lines==1 and lines[1]:find("phase=source-pickup route=portable mode=SP source=loot target=main destinations=1 reason=The server rejected the inventory move.",1,true))
            assert(#shots==1 and shots[1].note:find("In original storage: 1.",1,true) and not shots[1].note:find("[ID",1,true))
        end)
    end)
    PZActionCompletionHUD=originalHUD;assert(ok,err)
end)

test("confirmed denied return stays in main; no retry or silent fallback",function()
    withReceipts(function(lines)
        local f=fixture()
        local src=item(f.shelf,211,"Animal Milk Bucket",10,8)
        local dst=item(f.main,212,"Empty Dispenser Bottle",15,0)
        local j=f:start(src,{dst})
        j:tick();local replica=moveAck(f,true)
        j:tick();fluidAck(f,8)
        j:tick();isCall(f,3,"move",211,f.main)
        local q=assert(j.move.pending)
        q.reply={false,"The server rejected the inventory move.",nil,replica}
        j:tick();j:tick();j:cancel()
        assert(j.state=="cancelled" and j.count==1 and j.liters==8 and #f.calls==3)
        assert(j.reason:find("confirmed in main inventory",1,true) and not j.reason:find("confirmed in original",1,true))
        assert(replica.container==f.main and f.main:getItems():contains(replica) and not f.shelf:getItems():contains(src))
        assert(dst.fluid.amount==8)
        assert(#lines==1 and lines[1]:find("completed=1 confirmedLitres=8.000 phase=source-return route=portable mode=SP source=loot target=main destinations=1 reason=The server rejected the inventory move.",1,true))
    end)
end)

test("unconfirmed network stop never uses one stale replica to claim return or retry",function()
    local f=fixture()
    local src=item(f.shelf,221,"Named precise bucket",10,8)
    local dst=item(f.main,222,"Empty dispenser",15,0)
    local j=f:start(src,{dst})
    j:tick();isCall(f,1,"move",221,f.shelf)
    j.move.pending.reply={false,"The native inventory move stopped without a confirmed result."}
    j:tick();j:tick()
    assert(j.state=="cancelled" and #f.calls==1 and j.count==0 and dst.fluid.amount==0)
    assert(j.reason:find("location unconfirmed; check main inventory and the original storage",1,true))
    assert(not j.reason:find("confirmed in original displayed storage",1,true))
end)

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

test("MP placed bucket fills equipped Western Canteen with stale animation and jog flags",function()
    for _,manual in ipairs({false,true}) do
        local f=fixture()
        isClient=function() return true end
        local src,dst=item(f.shelf,1,"Placed Bucket",2,1.5),item(f.main,2,"Western Canteen",1,0)
        f.held=dst
        stockGround(f,src)
        function f.player:isMoving() return true end
        function f.player:isRunning() return true end
        function f.player:isSprinting() return true end
        function f.player:isPlayerMoving() return false end
        function f.player:pressedMovement() return manual end
        local j=f:start(src,{dst})
        j:tick()
        if manual then
            assert(j.state=="cancelled" and j.reason=="Character moved." and #f.calls==0)
        else
            isCall(f,1,"pour",1,dst)
            fluidAck(f,1); j:tick()
            assert(j.state=="finished" and j.count==1 and #f.calls==1 and f.held==dst)
        end
    end
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
        assert(j.reason:find("Vessel locations:",1,true))
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
    assert(j.reason:find("Vessel locations:",1,true) and j.reason:find("Glass Bottle",1,true) and j.reason:find("[ID 72]",1,true),j.reason)
end)

test("independently changed shelved source stays in main after exact untouched target returns",function()
    local f,j,source,target=twoShelfLoans()
    source.fluid.species=water
    j:tick(); isCall(f,3,"move",target.id,f.main)
    local returned=moveAck(f,true);j:tick();j:tick()
    assert(#f.calls==3 and j.count==0 and j.state~="finished")
    assert(returned.container==f.shelf and returned.fluid.amount==0 and source.container==f.main
        and source.fluid.species==water and source.fluid.amount==2)
    assert(j.reason:find("Vessel locations:",1,true) and j.reason:find("Milk Carton",1,true) and j.reason:find("[ID 71]",1,true),j.reason)
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
        assert(j.reason:find("Vessel locations:",1,true) and j.reason:find(changed.name,1,true)
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
    assert(j.reason:find("Vessel locations:",1,true) and j.reason:find("Milk Carton",1,true)
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
    assert(j.reason:find("Vessel locations:",1,true) and j.reason:find("Milk Carton",1,true)
        and j.reason:find("Glass Bottle",1,true) and j.reason:find("[ID 72]",1,true),j.reason)
end)

test("inventory donor fills exact worn held attached and loaded-fluid-bag targets in place; native move is never called",function()
    for _,position in ipairs({"worn","attached","held","backpack"})do
        for _,cancelled in ipairs({false,true})do
            local f=fixture()
            local source=item(f.main,75,"Water Bottle",2,1,water)
            local dest=item(f.main,76,"Chosen Fluid Equipment",3,.5,water)
            local spare=item(f.main,77,"Chosen Fluid Equipment",3,.5,water)
            local carried
            if position=="worn" then function f.player:isEquippedClothing(i)return i==dest end
            elseif position=="attached" then function f.player:isAttachedItem(i)return i==dest end
            elseif position=="held" then f.held=dest
            else
                function f.player:isEquippedClothing(i)return i==dest end
                dest.bag=container("bag",dest)
                carried=item(dest.bag,78,"Separate Cargo")
            end
            local j=f:start(source,{dest});j:tick()
            isCall(f,1,"pour",75,dest)
            if cancelled then j:cancel();j.pour.pending.reply={false,"cancelled",0};j:tick()
            else fluidAck(f,1);j:tick() end
            assert(j.state==(cancelled and "cancelled" or "finished") and #f.calls==1)
            assert(dest.container==f.main and dest.id==76 and dest.fluid.amount==(cancelled and .5 or 1.5))
            assert(spare.fluid.amount==.5 and not j.move:isBusy())
            if position=="held" then assert(f.held==dest)
            elseif position=="attached" then assert(f.player:isAttachedItem(dest))
            else assert(f.player:isEquippedClothing(dest)) end
            if carried then assert(dest.bag.items[1]==carried and carried.container==dest.bag) end
        end
    end
end)

local function inversePlan(f,donor,receiver)
    local snap=Inventory.snapshot(f.player,f.world,receiver.container,f.pane)
    local plan=assert(Inventory.fillFrom(snap,receiver,f.options))
    local selected
    for _,entry in ipairs(plan.donors) do if entry.item==donor then selected=entry end end
    if f.shelf:getType()~="floor" then plan.target.pourAnchor=f.world:pourShelfAnchor(f.shelf) end
    local function contextFor(captured)
        assert(captured==f.shelf,"must ask about the clicked holder, not the currently active tab")
        return f.options,f.pane
    end
    return assert(selected),plan.target,contextFor
end
local function inverseStart(f,donor,receiver)
    local source,target,read=inversePlan(f,donor,receiver)
    f.job=assert(Pour.new(f.player,f.world,source,{target},f.options,read,receiver))
    return f.job
end

test("Fill From leaves the bagged donor in place, fills and returns only the exact clicked shelf replica",function()
    local f=fixture()
    local bag=item(f.main,300,"Worn pack");bag.bag=container("bag",bag);f.held=bag
    local chosen=item(bag.bag,301,"Portable milk",3,2.25)
    local other=item(f.main,302,"Portable milk",3,2.25)
    local target=item(f.shelf,303,"Kitchen jug",2,.5)
    local twin=item(f.shelf,304,"Kitchen jug",2,.5)
    local j=inverseStart(f,chosen,target)
    assert(j.shelf==f.shelf and j.anchor and not j.inPlaceGround)
    j:tick();isCall(f,1,"move",303,f.shelf)
    local staged=moveAck(f,true);assert(staged~=target and staged.id==target.id)
    j:tick();isCall(f,2,"pour",301,staged);fluidAck(f,1.5)
    isCall(f,3,"move",303,f.main);local restored=moveAck(f,true)
    j:tick()
    assert(j.state=="finished" and j.count==1 and j.liters==1.5 and #f.calls==3)
    assert(restored.id==target.id and restored.container==f.shelf and restored.fluid.amount==2)
    assert(chosen.container==bag.bag and chosen.fluid.amount==.75 and other.fluid.amount==2.25)
    assert(twin.container==f.shelf and twin.fluid.amount==.5 and f.held==bag)
end)

test("Fill From cannot grant forward or batch scope, guess an anchor, or silently replace a stale vessel",function()
    for _,mode in ipairs({"pane","locked","changed-target","changed-donor","replaced-receiver","removed-donor","changed-capacity"}) do
        local f=fixture()
        local donor=item(f.main,311,"Donor",2,1.25)
        local target=item(f.shelf,312,"Jug",2,.25)
        local twin=item(f.shelf,313,"Jug",2,.25)
        local src,dst,read=inversePlan(f,donor,target)
        assert(not Pour.new(f.player,f.world,src,{dst},f.options,read))
        assert(not Pour.new(f.player,f.world,src,{dst,dst},f.options,read,target))
        assert(not Pour.new(f.player,f.world,src,{dst},f.options,read,twin))
        local anchor=dst.pourAnchor;dst.pourAnchor=nil
        assert(not Pour.new(f.player,f.world,src,{dst},f.options,read,target))
        dst.pourAnchor=anchor
        f.job=assert(Pour.new(f.player,f.world,src,{dst},f.options,read,target))
        if mode=="pane" then f.pane=container("counter")
        elseif mode=="locked" then f.shelf.lock=true
        elseif mode=="changed-target" then target.fluid.amount=.5
        elseif mode=="changed-donor" then donor.fluid.species=water
        elseif mode=="replaced-receiver" then remove(target);item(f.shelf,target.id,target.name,2,.25)
        elseif mode=="removed-donor" then remove(donor)
        else target.fluid.capacity=3 end
        f.job:tick();f.job:tick()
        assert(#f.calls==0 and f.job.state=="cancelled" and twin.fluid.amount==.25,mode)
    end
end)

test("Fill From on a stock Ground receiver pours in place and does not redirect after facing refresh",function()
    local f=fixture()
    local src=item(f.main,321,"Donor",3,2)
    local dst=item(f.shelf,322,"Ground jug",2,.25);stockGround(f,dst)
    local native=dst:getWorldItem()
    local j=inverseStart(f,src,dst)
    j:tick();isCall(f,1,"pour",321,dst);f.pane=container("counter")
    fluidAck(f,1.75);j:tick()
    assert(j.state=="finished" and #f.calls==1 and dst:getWorldItem()==native)
    assert(dst.container==f.shelf and src.container==f.main and src.fluid.amount==.25 and dst.fluid.amount==2)
end)

test("Fill From refuses a stock Ground receiver relocated after preview even if still reachable",function()
    local f=fixture()
    local src=item(f.main,325,"Donor",3,2)
    local dst=item(f.shelf,326,"Ground jug",2,0);stockGround(f,dst)
    local j=inverseStart(f,src,dst)
    local adjacent={}
    function dst:getWorldItem() return self.fluid.owner end
    function dst.fluid.owner:getSquare() return adjacent end
    function f.player:getSquare() return adjacent end
    j:tick();j:tick()
    assert(j.state=="cancelled" and #f.calls==0 and src.fluid.amount==2 and dst.fluid.amount==0)
end)

test("Fill From uses the exact Ground loan for an item-owned receiver and returns to its captured spot",function()
    local f=fixture()
    local src=item(f.main,331,"Donor",3,2)
    local dst=item(f.shelf,332,"Ground bottle",2,0);local spot=markGround(f,dst,{kind="original"})
    local j=inverseStart(f,src,dst)
    j:tick();isCall(f,1,"ground",332,f.shelf);assert(f.calls[1].anchor==spot);moveAck(f,false)
    j:tick();isCall(f,2,"pour",331,dst);fluidAck(f,2)
    isCall(f,3,"ground",332,f.main);assert(f.calls[3].anchor==spot);moveAck(f,false)
    j:tick();assert(j.state=="finished" and #f.calls==3 and src.fluid.amount==0 and dst.fluid.amount==2 and dst.container==f.shelf)
end)

print("PASS "..tests.." Pour controller scenarios")
