package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Native = require "LootBox/PourNative"
local fixture
function isServer() return false end
function isClient() return fixture.mp end
function getTimestampMs() return fixture.now end
FluidUtil={roundTransfer=function(amount) return math.floor(amount*1000+.00001)/1000 end}
FluidContainer={CanTransfer=function(a,b) return a.signature==b.signature or b.amount==0 end}
local function container(parent)
    local c={items={},parent=parent}
    function c:contains(x) return self.items[x]==true end
    function c:getContainingItem() return self.parent end
    function c:getType() return self.kind or "inventory" end
    return c
end
local function put(item,dest)
    if item.direct then item.direct.items[item]=nil end
    item.direct=dest
    if dest then dest.items[item]=true end
end
local function item(id,signature,amount,capacity)
    local i={id=id}
    local f={amount=amount,capacity=capacity,signature=signature}
    function i:getID() return self.id end
    function i:getFullType() return "Base.MockVessel" end
    function i:getWorldItem() return self.world end
    function i:getContainer() return self.direct end
    function i:getInventory() return self.nested end
    function i:getFluidContainer() return self.fluid end
    function f:canPlayerEmpty() return not self.locked end
    function f:getAmount() return self.amount end
    function f:getFreeCapacity() return self.capacity-self.amount end
    function f:getOwner() return i end
    i.fluid=f
    return i
end
for _,mod in ipairs({"Fluids/ISFluidContainer","Fluids/ISFluidUtil","Fluids/ISFluidTransferAction"}) do package.loaded[mod]=true end
ISFluidContainer={new=function(_,f) return {getFluidObject=function() return f end} end}
ISFluidTransferAction={}
function ISFluidTransferAction:new(_, a, aa, b, bb, amount)
    assert(a:getFluidObject()==aa and b:getFluidObject()==bb)
    local act={maxTime=120,action={},amount=amount}
    function act:isValid() return FluidContainer.CanTransfer(aa,bb) end
    function act:waitToStart() return false end
    function act:update() fixture.updated=fixture.updated+1 end
    function act:complete()
        fixture.completed=fixture.completed+1
        aa.amount=aa.amount-amount
        bb.amount=bb.amount+amount
    end
    function act:perform()
        local q=fixture.queue
        table.remove(q.queue,1)
        q.current=q.queue[1]
    end
    function act:stop()
        fixture.stopped=fixture.stopped+1
        fixture.queue.queue={}
        fixture.queue.current=nil
    end
    function act:forceStop() self:stop() end
    return act
end
ISTimedActionQueue={
    getTimedActionQueue=function() return fixture.queue end,
    add=function(action)
        fixture.queued=fixture.queued+1
        fixture.queue:addToQueue(action)
    end,
}
local function setup(mp)
    local f={now=0,mp=mp,queued=0,updated=0,completed=0,stopped=0}
    fixture=f
    f.queue={queue={}}
    function f.queue:addToQueue(action)
        self.queue[#self.queue+1]=action
        self.current=self.current or action
    end
    function f.queue:removeFromQueue(action)
        for j,x in ipairs(self.queue) do if x==action then table.remove(self.queue,j); return end end
    end
    f.main, f.bag = container(), item(9,"none",0,1)
    f.bag.nested=container(f.bag)
    f.src,f.dst=item(10,"petrol",.9,1),item(11,"petrol",.2,1)
    put(f.bag,f.main); put(f.src,f.bag.nested); put(f.dst,f.main)
    -- The Java stack and its animation flag are independent of the Lua queue.
    -- Fixtures below explicitly model the installed native callback boundary.
    f.javaHandles={}
    local stack={}
    function stack:size() return #f.javaHandles end
    function stack:isEmpty() return #f.javaHandles==0 end
    function stack:get(i) return f.javaHandles[i+1] end
    function stack:contains(handle)
        for _,entry in ipairs(f.javaHandles) do if entry==handle then return true end end
        return false
    end
    f.player={getInventory=function() return f.main end,
        getCharacterActions=function() return stack end,
        hasTimedActions=function() return not stack:isEmpty() or f.actionAnimation==true end,
        isLocalPlayer=function() return true end, isDead=function() return false end, isAsleep=function() return false end}
    for _,state in ipairs({"Moving","Running","Sprinting","Aiming","Attacking","Shoving","Climbing","KnockedDown","bFalling","PerformingGrappleAnimation"}) do
        local key="is"..state
        f.player[key]=function() return f[key] == true end
    end
    f.native=Native.new(f.player)
    return f
end
local f=setup(false)
local description=assert(Native.inspect(f.src,f.dst))
assert(description.amount==.8 and description.sourceBefore==.9 and description.targetBefore==.2)
assert(not Native.inspect(f.src,f.src))
f.dst.fluid.locked=true; assert(not Native.inspect(f.src,f.dst)); f.dst.fluid.locked=false
f.dst.fluid.signature="water"; assert(not Native.inspect(f.src,f.dst)); f.dst.fluid.signature="petrol"
assert(f.native:start(f.src,f.dst,.4) and f.queued==1 and f.src.direct==f.bag.nested)
local action=f.queue.current
-- Installed B42 SP calls perform, then complete, then removes the exact
-- BaseAction from the Java stack. Stock perform already drained the Lua head.
f.javaHandles={action.action}
assert(not action:waitToStart())
action:update()
action:perform()
assert(f.queue.current==nil and #f.queue.queue==0 and f.player:hasTimedActions())
assert(f.player:getCharacterActions():size()==1 and f.player:getCharacterActions():contains(action.action))
action:complete()
assert(f.completed==1 and math.abs(f.src.fluid.amount-.5)<1e-6 and math.abs(f.dst.fluid.amount-.6)<1e-6,
    "SP complete must transfer the exact outstanding amount while Java still owns the finishing action")
f.javaHandles={}
local ok,reason,amount=f.native:poll()
assert(ok and reason==nil and math.abs(amount-.4)<.001 and f.completed==1 and f.src.direct==f.bag.nested)

-- No blanket relaxation of the SP terminal guard: a different Java action,
-- an additional native action, or an owned-looking handle without a preceding
-- successful Lua perform cannot authorize writes or replace foreign work.
for _,shape in ipairs({"foreign-only","own-plus-foreign","never-performed"}) do
    f=setup(false)
    assert(f.native:start(f.src,f.dst,.4))
    action=f.queue.current
    f.javaHandles={action.action}
    assert(not action:waitToStart())
    local foreign={}
    if shape=="never-performed" then
        f.queue.current=nil; f.queue.queue={}
    else
        action:perform()
        f.javaHandles=shape=="foreign-only" and {foreign} or {action.action,foreign}
    end
    local held=f.javaHandles
    local n=f.player:getCharacterActions():size()
    local first,last=held[1],held[n]
    action:complete()
    assert(f.completed==0 and f.src.fluid.amount==.9 and f.dst.fluid.amount==.2,
        "non-owned or unperformed terminal must not transfer: "..shape)
    assert(f.queued==1 and f.stopped==0 and #f.queue.queue==0 and f.javaHandles==held
        and #held==n and held[1]==first and held[n]==last,
        "terminal guard changed queue/foreign Java actions: "..shape)
    f.javaHandles={}
    assert(f.native:poll()~=true, "unconfirmed terminal cannot be reported complete: "..shape)
end

f=setup(false)
assert(f.native:start(f.src,f.dst,.4))
action=f.queue.current
assert(not action:waitToStart())
put(f.bag,container())
action:update()
assert(f.updated==0 and f.stopped==1 and f.completed==0)

f=setup(false)
assert(f.native:start(f.src,f.dst,.4))
local foreign={}
f.queue:addToQueue(foreign)
f.native:cancel()
assert(f.queue.current==foreign and f.stopped==1 and #f.queue.queue==1)

for _,sourceFirst in ipairs({true,false}) do
    f=setup(true)
    assert(f.native:start(f.src,f.dst,.4))
    action=f.queue.current
    assert(not action:waitToStart())
    action:complete()
    assert(f.completed==0 and f.src.fluid.amount==.9 and f.dst.fluid.amount==.2)
    action:perform()
    if sourceFirst then f.src.fluid.amount=.5 else f.dst.fluid.amount=.6 end
    assert(f.native:poll()==nil)
    if sourceFirst then f.dst.fluid.amount=.6 else f.src.fluid.amount=.5 end
    local accepted,_,liters=f.native:poll()
    assert(accepted and math.abs(liters-.4)<.001 and f.queued==1)
end

f=setup(true)
assert(f.native:start(f.src,f.dst,.4))
action=f.queue.current
assert(not action:waitToStart())
action:perform()
f.src.fluid.amount=.7; f.dst.fluid.amount=.4
assert(f.native:poll()==nil)
f.now=8000
local partial,_,liters=f.native:poll()
assert(partial==false and math.abs(liters-.2)<.001 and f.queued==1)

f=setup(true)
assert(f.native:start(f.src,f.dst,.4))
action=f.queue.current; assert(not action:waitToStart()); action:perform()
f.src.fluid.amount=.5
assert(f.native:poll()==nil)
f.now=8000
local confirmed,_,observed=f.native:poll()
assert(not confirmed and observed==0)
f=setup(true); f.isAiming=true
assert(not f.native:start(f.src,f.dst,.4) and f.queued==0)
f.isAiming=false; assert(f.native:start(f.src,f.dst,.4)); action=f.queue.current
f.isMoving=true
assert(action:waitToStart()==true and f.stopped==1 and f.updated==0)
local ok,_,amount=f.native:poll()
assert(not ok and amount==0)

f=setup(false); assert(f.native:start(f.src,f.dst,.4)); action=f.queue.current
assert(not action:waitToStart()); action:update()
f.src.fluid.amount=.85; f.dst.fluid.amount=.25
action:update()
assert(f.stopped==1 and f.updated==1)

f=setup(true); assert(f.native:start(f.src,f.dst,.4)); action=f.queue.current
assert(not action:waitToStart()); action:perform()
f.now=7100; f.src.fluid.amount=.5; f.dst.fluid.amount=.6
local accepted,_,late=f.native:poll()
assert(accepted==false and late==0)

f=setup(true)
assert(f.native:start(f.src,f.dst,.001)); action=f.queue.current
assert(not action:waitToStart()); action:perform()
f.src.fluid.amount=.8999; f.dst.fluid.amount=.2001
assert(f.native:poll()==nil, "a 0.1ml effect does not complete a 1ml request")
f.src.fluid.amount=.899; f.dst.fluid.amount=.201
local precise,_,milliliter=f.native:poll()
assert(precise and math.abs(milliliter-.001)<.000001)

f=setup(false)
assert(f.native:start(f.src,f.dst,.4)); action=f.queue.current
assert(not action:waitToStart())
local first,second={},{ }
f.queue.queue[2],f.queue.queue[3]=first,second
action:perform()
assert(f.queue.current==nil and #f.queue.queue==0, "foreign work must not begin from the pour callback")
assert(f.native:poll()==nil and f.queue.current==nil, "same-tick poll must not start the foreign tail")
action:complete()
assert(f.completed==0, "foreign input makes the native completion unsafe")
f.now=1
local completed=f.native:poll()
assert(completed==false and f.queue.current==first and f.queue.queue[2]==second)

f=setup(false)
local floor=container()
floor.kind="floor"
put(f.src,floor)
local square={getZ=function() return 0 end,getX=function() return 10 end,getY=function() return 10 end}
f.player.getSquare=function() return square end
local wrapper={getItem=function() return f.src end, getSquare=function() return square end,
    isExistInTheWorld=function(self) return not self.stale end}
f.src.world=wrapper
local nativeComponent={amount=.7,capacity=1,signature="petrol"}
setmetatable(nativeComponent,{__index=f.src.fluid})
function nativeComponent:getOwner() return wrapper end
function nativeComponent:isMultiTileMoveable() return self.multi end
function wrapper:getFluidContainer() return nativeComponent end
local floorPlan=assert(Native.inspect(f.src,f.dst))
assert(floorPlan.sourceFluid==nativeComponent and floorPlan.sourceOwner==wrapper and floorPlan.sourceBefore==.7)
assert(f.native:start(f.src,f.dst,.2))
action=f.queue.current
assert(not action:waitToStart()); action:perform(); action:complete()
local poured,_,quantity=f.native:poll()
assert(poured and math.abs(quantity-.2)<.000001 and f.src.fluid.amount==.9)
wrapper.stale=true; assert(not Native.inspect(f.src,f.dst)); wrapper.stale=false
nativeComponent.multi=true; assert(not Native.inspect(f.src,f.dst)); nativeComponent.multi=false
f.src.world=nil; assert(not Native.inspect(f.src,f.dst), "plain floor item cannot be silently borrowed")
put(f.src,nil); f.src.world=wrapper; assert(not Native.inspect(f.src,f.dst), "detached world-only wrapper is not a clicked floor item")

print("PASS stock pour: exact owned vessels, native compatibility, SP completion, MP paired replication, partial and cancellation")

-- Optional stock-Lua boundary smoke. Files are supplied by the test operator;
-- normal portable/Kahlua runs need no additional game assets.
if arg and arg[1] and arg[2] then
    local stock = arg[1]
    local function noop() end
    local function derive(self, name)
        local class=setmetatable({Type=name},{__index=self})
        class.__index=class
        return class
    end
    ISBaseTimedAction={derive=derive,waitToStart=function() return false end,
        new=function(self,p) return setmetatable({action={},character=p},self) end,
        getJobDelta=function(self) return self.progress end,
        stop=function()
            fixture.queue.queue={}; fixture.queue.current=nil
        end, perform=function()
            table.remove(fixture.queue.queue,1)
            fixture.queue.current=fixture.queue.queue[1]
        end, setActionAnim=noop,setOverrideHandModels=noop,forceStop=function(self) self:stop() end}
    ISBaseObject={derive=derive,new=function() return {} end}
    package.loaded["TimedActions/ISBaseTimedAction"]=true
    package.loaded["ISBaseObject"]=true
    local server=false
    function isServer() return server end
    function instanceof(obj, typename) return obj and obj.javaType==typename or false end
    function getPlayer() return fixture.player end
    Metabolics={LightDomestic=1,HeavyDomestic=2,MediumWork=3}
    FluidUtil.getTransferActionTimePerLiter=function() return 100 end
    FluidUtil.getMinTransferActionTime=function() return 40 end
    FluidContainer.CanTransfer=function(a,b)
        return a.amount>0 and b:getFreeCapacity()>0 and a.signature==b.signature
    end
    FluidContainer.Transfer=function(a,b,requested)
        assert(not isClient(),"stock fluid write on client")
        local amount=math.min(a.amount,b:getFreeCapacity(),requested)
        a.amount,b.amount=a.amount-amount,b.amount+amount
    end
    assert(loadfile(stock.."/ISFluidContainer.lua"))()
    assert(loadfile(arg[2]))()
    assert(loadfile(stock.."/ISFluidTransferAction.lua"))()
    local function actualSetup(mp)
        local f=setup(mp)
        for _,i in ipairs({f.src,f.dst}) do
            i.javaType="InventoryItem"
            i.fluid.javaType="FluidContainer"
            i.isInPlayerInventory=function() return true end
            i.getItemHeat=function() return 0 end
            i.syncItemFields=noop
        end
        f.player.isTimedActionInstant=function() return false end
        f.player.setMetabolicTarget=noop
        f.player.playSound=noop
        return f
    end
    f=actualSetup(false)
    f.src.fluid.amount,f.dst.fluid.amount=.25,.75
    assert(f.native:start(f.src,f.dst,.25))
    action=f.queue.current
    f.javaHandles={action.action}
    assert(not action:waitToStart())
    action:start()
    action.progress=.5; action:update()
    assert(math.abs(f.src.fluid.amount-.125)<1e-6 and math.abs(f.dst.fluid.amount-.875)<1e-6)
    action.progress=1; action:update()
    assert(not FluidContainer.CanTransfer(f.src.fluid,f.dst.fluid) and action:isValid())
    action:perform(); assert(not f.queue.current and f.player:hasTimedActions()); assert(action:complete())
    f.javaHandles={}
    local ok,_,volume=f.native:poll()
    assert(ok and volume==.25 and f.dst.fluid.amount==1)

    -- Also leave real quantity outstanding for the unmodified stock complete.
    -- The saturated prior case alone does not prove the actual final write.
    f=actualSetup(false)
    f.src.fluid.amount,f.dst.fluid.amount=.25,.75
    assert(f.native:start(f.src,f.dst,.25)); action=f.queue.current
    f.javaHandles={action.action}
    assert(not action:waitToStart()); action:start(); action.progress=.5; action:update()
    assert(math.abs(f.src.fluid.amount-.125)<1e-6 and math.abs(f.dst.fluid.amount-.875)<1e-6)
    action:perform()
    assert(not f.queue.current and f.player:getCharacterActions():get(0)==action.action)
    assert(action:complete() and f.src.fluid.amount==0 and f.dst.fluid.amount==1,
        "stock SP complete did not move the remaining half with its own Java handle still present")
    f.javaHandles={}
    ok,_,volume=f.native:poll(); assert(ok and volume==.25)
    f=actualSetup(true)
    assert(f.native:start(f.src,f.dst,.25))
    action=f.queue.current; assert(not action:waitToStart()); action:start(); action.progress=.5; action:update()
    assert(f.src.fluid.amount==.9 and f.dst.fluid.amount==.2)
    -- An independently built native server action receives the serialized
    -- fluid objects, not the client's decorated Lua action.
    local remote=actualSetup(false)
    server=true
    local src,dst=ISFluidContainer:new(remote.src.fluid),ISFluidContainer:new(remote.dst.fluid)
    local authoritative=ISFluidTransferAction:new(remote.player,src,src:getFluidObject(),dst,dst:getFluidObject(),.25)
    assert(authoritative:isValid() and authoritative:complete())
    server=false; fixture=f
    f.src.fluid.amount=remote.src.fluid.amount; action:perform()
    assert(f.native:poll()==nil)
    f.dst.fluid.amount=remote.dst.fluid.amount
    ok,_,volume=f.native:poll()
    assert(ok and math.abs(volume-.25)<1e-6)
    print("PASS pinned stock ISFluidTransferAction and ISFluidUtil: saturated SP handoff and server-owned paired MP with Java boundary doubles")
end
