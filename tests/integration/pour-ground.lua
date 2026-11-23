-- From repository root: lua5.1 tests/integration/pour-ground.lua [stock/ISDropWorldItemAction.lua] [stock/media/lua]
-- Optional pinned Lua has its unmodified constructor, geometry/weight checks, start,
-- complete and perform executed against a deterministic Java/world/replication fixture.
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
for _,s in ipairs({"ISTimedActionQueue","ISInventoryTransferUtil","ISDropWorldItemAction","ISBaseTimedAction"}) do
    package.loaded["TimedActions/"..s]=true
end
local stock,stockPickup=arg and arg[1],arg and arg[2]
local G=require "LootBox/PourGround"
local f,ran=nil,0
local function yes() return true end
local function no() return false end
local function nothing() end
local function zero() return 0 end
local function get(k) return function(o) return o[k] end end
local function L()
    local l={}
    function l:size() return #self end
    function l:get(i) return self[i+1] end
    function l:contains(o) for _,v in ipairs(self) do if o==v then return true end end return false end
    function l:remove(o) for i,v in ipairs(self) do if o==v then table.remove(self,i);return true end end end
    return l
end
local function container(kind)
    local v={kind=kind,items=L(),getType=get("kind"),getItems=get("items"),isLockedToCharacter=no,
        isItemAllowed=yes,isRemoveItemAllowed=yes,hasRoomFor=yes,setDrawDirty=nothing}
    function v:contains(o) return self.items:contains(o) end
    function v:getItemById(id) for _,i in ipairs(self.items) do if i.id==id then return i end end end
    function v:containsID(id) return self:getItemById(id)~=nil end
    function v:Remove(it) self.items:remove(it);if it.container==self then it.container=nil end end
    function v:add(it) if not self:contains(it) then table.insert(self.items,it) end;it.container=self end
    return v
end
local function square(x,y,z)
    local v={x=x,y=y,z=z,world=L(),weight=1,loaded=true,clear=true,visible=true,solidFloor=true,
        getX=get("x"),getY=get("y"),getZ=get("z"),getWorldObjects=get("world"),
        getTotalWeightOfItemsOnFloor=get("weight"),isCouldSee=get("visible"),TreatAsSolidFloor=get("solidFloor"),
        isSolid=no,isSolidTrans=no,HasStairs=no,hasSlopedSurface=no,isWallTo=no,isWindowTo=no}
    function v:isAdjacentTo(other)
        return self.z==other.z and math.abs(self.x-other.x)<=1 and math.abs(self.y-other.y)<=1
    end
    function v:canReachTo(other) return self.clear and other.clear end
    function v:isBlockedTo(other) return not self.clear or not other.clear end
    function v:AddWorldInventoryItem(item,ox,oy,oz,nilFlag)
        assert(not f.mp and nilFlag==false,"world writes are not allowed from an MP client")
        f.localWrites=f.localWrites+1;f:place(item,self,ox,oy,oz,false)
        return item
    end
    return v
end
local function item(id,typ)
    local it={id=id,full="Base."..(typ or "Bucket"),kind=typ or "Bucket",rx=0,ry=0,rz=315,model="Bucket",
        getID=get("id"),getFullType=get("full"),getType=get("kind"),getContainer=get("container"),getWorldItem=get("world"),
        getWorldStaticItem=get("model"),getWorldXRotation=get("rx"),getWorldYRotation=get("ry"),getWorldZRotation=get("rz"),
        isFavorite=no,isSealed=no,getUnequippedWeight=function() return 0.8 end,
        getPlaceOneSound=nothing,setJobDelta=nothing,setJobType=nothing,canBe3DRender=yes}
    it.fluid={getOwner=function() return it end, canPlayerEmpty=yes,isMultiTileMoveable=no}
    it.getFluidContainer=get("fluid")
    function it:setWorldZRotation(r) self.rz=r end
    return it
end
function isClient() return f.mp end
function isServer() return false end
function getSpecificPlayer(n) if n==0 then return f.p end end
function getPlayerLoot(n) assert(n==0);return f.page end
function getCell() return f.cell end
function getTimestampMs() return f.now end
function getText(s) return s end
function isItemTransactionDone(id) return id==37 and f.done end
function isItemTransactionRejected(id) return id~=37 or f.rejected end
function instanceof(obj,what) return obj~=nil and obj.class==what end
function sendRemoveItemFromContainer() assert(not f.mp);f.sync=f.sync+1 end
ISInventoryPage={GetFloorContainer=function(n) assert(n==0);return f.floor end}
SafeHouse={isSafehouseAllowLoot=function() return f.allowed end}
luautils={walkAdjTest=function(p,sq) return f.walk and sq:isAdjacentTo(p:getCurrentSquare()) end}
ISTimedActionQueue={}
function ISTimedActionQueue.getTimedActionQueue(p) assert(f.p==p);return f.q end
function ISTimedActionQueue.add(a) f.q:addToQueue(a) end
ISBaseTimedAction={}
function ISBaseTimedAction:derive(t) local c={Type=t};c.__index=c;return setmetatable(c,{__index=self}) end
function ISBaseTimedAction:new(p) return setmetatable({character=p},self) end
ISBaseTimedAction.isValidStart=yes
ISBaseTimedAction.waitToStart=no
ISBaseTimedAction.forceCancel=nothing
function ISBaseTimedAction:forceStop() self:stop() end
function ISBaseTimedAction:stop() f.q:resetQueue() end
function ISBaseTimedAction:perform() f.q:onCompleted(self) end
if stock then
    assert(loadfile(stock))()
else
    ISDropWorldItemAction=ISBaseTimedAction:derive("ISDropWorldItemAction")
    function ISDropWorldItemAction:new(p,i,sq,x,y,z,r,m)
        return setmetatable({character=p,item=i,sq=sq,xoffset=x,yoffset=y,zoffset=z,rotation=r,isMultiple=m},self)
    end
    function ISDropWorldItemAction:isValid()
        return self.character:getInventory():containsID(self.item:getID()) and self.sq:isAdjacentTo(f.p.here)
            and not self.sq:isBlockedTo(f.p.here) and self.sq.weight+self.item:getUnequippedWeight()<=50
    end
    ISDropWorldItemAction.start=nothing
    function ISDropWorldItemAction:complete()
        local v=self.sq:AddWorldInventoryItem(self.item,self.xoffset,self.yoffset,self.zoffset,false)
        v:setWorldZRotation(self.rotation);v.world:setExtendedPlacement(false);v.world:transmitCompleteItemToClients()
        self.character:getInventory():Remove(v);sendRemoveItemFromContainer();return true
    end
end
local Pickup=ISBaseTimedAction:derive("ISInventoryTransferAction")
function Pickup:isValid() return f.nativeTake end
function Pickup:start() if f.mp then self.transactionId=f.txid end end
function Pickup:transferItem(it)
    assert(not f.mp and it==self.item); f.localWrites=f.localWrites+1; f:unworld(it);f.floor:Remove(it);f.main:add(it)
end
function Pickup:perform()
    if not f.mp then self:transferItem(self.item) end
    self.transactionId=0;ISBaseTimedAction.perform(self)
end
ISInventoryTransferUtil={newInventoryTransferAction=function(p,it,src,dst)
    return setmetatable({character=p,item=it,srcContainer=src,destContainer=dst},Pickup)
end}
local function fixture(mp,adjacent)
    local t={mp=mp,now=300,allowed=true,walk=true,nativeTake=true,txid=37,done=false,
        rejected=false,main=container("inventory"),floor=container("floor"),localWrites=0,sync=0,
        grounds={square(30,50,0),square(31,50,0),square(32,50,0)},q={queue={}}}
    f=t
    t.page={visible=true,getIsVisible=get("visible"),inventoryPane={inventory=t.floor}}
    t.p={main=t.main,here=t.grounds[1],getPlayerNum=zero,getInventory=get("main"),getCurrentSquare=get("here"),
        isLocalPlayer=yes,isDead=no,isAsleep=no,getVehicle=nothing,isEquipped=no,isAttachedItem=no,hasTimedActions=no,
        isMoving=no,isShoving=no,isClimbing=no,isKnockedDown=no,isRunning=no,isSprinting=no,isAiming=no,isAttacking=no,isTimedActionInstant=yes,playSound=nothing,
        getEmitter=function() return {isPlaying=yes} end}
    t.cell={getGridSquare=function(_,x,y,z)
        for _,sq in ipairs(t.grounds) do if sq.loaded and sq.x==x and sq.y==y and sq.z==z then return sq end end
    end}
    function t.q:addToQueue(a) self.queue[#self.queue+1]=a;if not self.current then self.current=a;a.action={} end end
    function t.q:removeFromQueue(a)
        for i,v in ipairs(self.queue) do if v==a then table.remove(self.queue,i);break end end
    end
    function t.q:resetQueue()
        for _,v in ipairs(self.queue) do if v~=self.current then v:forceCancel() end end
        self.queue={}; self.current=nil
    end
    function t.q:onCompleted(a) self:removeFromQueue(a); self.current=self.queue[1] end
    function t:place(it,sq,ox,oy,oz,project)
        local w={item=it,sq=sq,ox=ox,oy=oy,oz=oz,extended=false,isExtendedPlacement=get("extended"),getOffX=get("ox"),
            getOffY=get("oy"),getOffZ=get("oz"),getItem=get("item"),getSquare=get("sq"),getFluidContainer=get("fluid"),
            isExistInTheWorld=function(o) return o.sq~=nil end,transmitCompleteItemToClients=nothing,setIgnoreRemoveSandbox=nothing}
        function w:setExtendedPlacement(e) self.extended=e end
        function w:getWorldObjectIndex() for i,v in ipairs(self.sq.world) do if v==self then return i-1 end end return -1 end
        sq.world[#sq.world+1]=w;it.world=w
        if project then self.floor:add(it) end
        return w
    end
    function t:unworld(it) local w=it.world;if w then w.sq.world:remove(w);w.sq=nil;it.world=nil end end
    function t:step() self.now=self.now+115 end
    t.it=item(478);t.sq=t.grounds[adjacent and 2 or 1];t:place(t.it,t.sq,0.23,0.87,0,true)
    t.g=G.new(t.p);t.a=assert(G.capture(t.p,t.it,t.floor),"ordinary bucket must capture")
    function t:arm()
        local a=assert(self.q.current);assert(a:isValidStart() and a:isValid());assert(not a:waitToStart());a:start();return a
    end
    function t:take()
        assert(self.g:start(self.it,self.floor,self.main,yes,self.a));return self:arm()
    end
    function t:toMain()
        self:unworld(self.it);self.floor:Remove(self.it);self.main:add(self.it)
    end
    function t:drop(v) assert(self.g:start(v or self.it,self.main,self.floor,yes,self.a));return self:arm() end
    function t:arrival(id,where,ox)
        local v=item(id or self.it.id);self:place(v,where or self.sq,ox or self.a.ox,self.a.oy,self.a.oz,false);return v
    end
    return t
end
local function test(name,func)
    local ok,why=pcall(func)
    if not ok then io.stderr:write(name,": ",tostring(why),"\n");os.exit(1) end
    ran=ran+1
end
for _,adj in ipairs({false,true}) do
    test("SP exact round trip "..tostring(adj),function()
        local t=fixture(false,adj);local a=t:take();a:perform()
        local ok,_,v=t.g:poll();assert(ok==true and v==t.it)
        a=t:drop();assert(a.isPlaceItem and not a.isMultiple and a.sq==t.sq);assert(a:complete());a:perform()
        -- A world Add without the original native Ground projection is NOT a receipt.
        assert(t.g:poll()==nil);t.floor:add(v);t:step()
        local pass,_,g=t.g:poll();assert(pass==true and g==v and g.world~=t.a.world)
        assert(t.localWrites==2 and t.sync==1 and g.world.ox==0.23 and g.world.oy==0.87 and g.rz==315)
    end)
    test("MP native ACK + two ordered observations "..tostring(adj),function()
        local t=fixture(true,adj);local a=t:take();t.done=true;a:perform()
        assert(t.g:poll()==nil); local clone=item(478);t.main:add(clone);t:step();assert(t.g:poll()==nil)
        t:unworld(t.it);t.floor:Remove(t.it);t:step()
        local ok,_,v=t.g:poll();assert(ok==true and v==clone and v~=t.it)
        local d=t:drop(v);assert(d:complete()==false);d:perform()
        local placed=t:arrival();t.floor:add(placed);assert(t.g:poll()==nil)
        t.main:Remove(clone);t:step();local done,_,g=t.g:poll();assert(done==true and g==placed and g~=v and t.localWrites==0)
    end)
end
test("Delayed original floor row blocks pickup; duplicate same-ID row blocks placement",function()
    local t=fixture(true,true);local a=t:take();t.done=true;a:perform()
    local out=item(478);t.main:add(out);t:unworld(t.it)
    assert(t.g:poll()==nil);t.floor:Remove(t.it);t:step();assert(t.g:poll()==true)
    local d=t:drop(out);d:perform();t.main:Remove(out)
    local fake=item(478);t.floor:add(fake);local g=t:arrival();t.floor:add(g)
    assert(t.g:poll()==nil);t.floor:Remove(fake);t:step();local ok,_,real=t.g:poll();assert(ok==true and real==g)
end)
test("MP delayed projection in either direction",function()
    local t=fixture(true,true);t:toMain();local d=t:drop();d:perform();t.main:Remove(t.it)
    local g=t:arrival();assert(t.g:poll()==nil)
    g.container=t.floor;t:step();assert(t.g:poll()==nil) -- membership must agree with getContainer
    t.floor.items[#t.floor.items+1]=g;g.container=nil;t:step();assert(t.g:poll()==nil)
    g.container=t.floor;t:step();local ok,_,v=t.g:poll();assert(ok==true and v==g)
end)
for _,receipt in ipairs({"rejected","missing","wrong","unsubmitted"}) do
    test("Rejected pickup "..receipt,function()
        local t=fixture(true,true);if receipt=="unsubmitted" then t.txid=0 end
        local a=t:take();t.done=receipt~="missing";t.rejected=receipt=="rejected";if receipt=="wrong" then a.transactionId=22 end
        a:perform();t:toMain();assert(t.g:poll()==false and t.localWrites==0)
    end)
end
for _,kind in ipairs({"tile","offset","rotation","id","class","extended","duplicate","mainOnly","wrongProjection","empty"}) do
    test("Never confirm wrong return "..kind,function()
        local t=fixture(true,true);t:toMain();local a=t:drop();a:perform();if kind~="mainOnly" then t.main:Remove(t.it) end
        if kind~="empty" then
            local g=t:arrival(kind=="id" and 112 or 478,kind=="tile" and t.grounds[1] or t.sq,kind=="offset" and 0.25 or 0.23)
            if kind=="rotation" then g.ry=33 elseif kind=="class" then g.full="Base.Bottle"
            elseif kind=="extended" then g.world.extended=true elseif kind=="duplicate" then t:arrival() end
            if kind~="wrongProjection" then t.floor:add(g) end
        end
        local ok=t.g:poll();assert(ok~=true);if ok==nil then t.now=t.now+30001;assert(t.g:poll()==false) end
    end)
end
for _,kind in ipairs({"favorite","extended","multi","foreignFluid","sealed","staleWrapper","wall","denied","hidden","unloaded","heavy","stairs","surface","unsupportedModel","clothing","charger","radio","worldHeight","outside","wrongFloor","foreignOwner","noFloor","noWalk","zeroX","zeroY","tiltX","tiltY","unsetHeading"}) do
    test("Fail closed "..kind,function()
        local t=fixture(true,true)
        local changes={
            favorite=function() t.it.isFavorite=yes end,extended=function() t.it.world.extended=true end,
            multi=function() t.it.fluid.isMultiTileMoveable=yes end,foreignFluid=function() t.it.world.fluid={} end,
            sealed=function() t.it.isSealed=yes end,staleWrapper=function() t.sq.world={} end,wall=function() t.sq.clear=false end,
            denied=function() t.allowed=false end,hidden=function() t.page.visible=false end,unloaded=function() t.sq.loaded=false end,
            heavy=function() t.sq.weight=50 end,stairs=function() t.sq.HasStairs=yes end,surface=function() t.sq.hasSlopedSurface=yes end,
            unsupportedModel=function() t.it.model="" end,clothing=function() t.it.class="Clothing";t.it.canBe3DRender=no end,
            charger=function() t.it.kind="CarBatteryCharger" end,radio=function() t.it.class="Radio" end,
            worldHeight=function() t.it.world.oz=0.5 end,outside=function() t.p.here=square(45,55,3) end,
            wrongFloor=function() t.page.inventoryPane.inventory=t.main end,foreignOwner=function() t.it.fluid.getOwner=nothing end,
            noFloor=function() t.sq.solidFloor=false end,noWalk=function() t.walk=false end,
            zeroX=function() t.it.world.ox=0 end,zeroY=function() t.it.world.oy=0 end,
            tiltX=function() t.it.rx=12 end,tiltY=function() t.it.ry=270 end,unsetHeading=function() t.it.rz=-1 end}
        changes[kind]();assert(G.capture(t.p,t.it,t.floor)==nil);assert(not t.g:start(t.it,t.floor,t.main,yes,t.a));assert(not t.q.current)
    end)
end
test("No relocation, stale siblings, or substituted action params",function()
    local t=fixture(true,true);local old=t.a;t.it.world.ox=0.4
    assert(not G.sameAnchor(old,G.capture(t.p,t.it,t.floor)));assert(not t.g:start(t.it,t.floor,t.main,yes,old))
    t.it.world.ox=old.ox;assert(t.g:start(t.it,t.floor,t.main,yes,old))
    local a=t.q.current;a.item=item(900);assert(not a:isValid());assert(a:waitToStart());assert(t.g:poll()==false)
    t:toMain();assert(t.g:start(t.it,t.main,t.floor,yes,old));local d=t.q.current;d.rotation=0
    assert(not d:isValid());assert(d:waitToStart());assert(t.g:poll()==false)
end)
test("Native validator, preflight room and queue exclusivity",function()
    local t=fixture(true,true);t.nativeTake=false;assert(not t.g:start(t.it,t.floor,t.main,yes,t.a));t.nativeTake=true
    t.main.hasRoomFor=no;assert(not t.g:start(t.it,t.floor,t.main,yes,t.a));t.main.hasRoomFor=yes
    local tail={forceCancel=function() error("foreign cancellation") end}
    t.q:addToQueue(tail);assert(not t.g:start(t.it,t.floor,t.main,yes,t.a));assert(t.q.current==tail);t.q:onCompleted(tail)
    local a=t:take();assert(not t.g:start(t.it,t.floor,t.main,yes,t.a));t.q:addToQueue(tail)
    assert(t.g:poll()==nil);assert(t.g:poll()==false);assert(#t.q.queue==1 and t.q.current==tail and t.localWrites==0)
end)
test("Foreign tail survives perform and action cancels without writes",function()
    local t=fixture(false,true);local a=t:take();local other={forceCancel=function() error("foreign touched") end}
    t.q:addToQueue(other);a:perform();assert(t.g:poll()==false and t.q.current==other and t.localWrites==0)
end)
test("Two ordinary drops on one display keep independent source squares",function()
    local t=fixture(false,true);local other=item(479);local sq=t.grounds[1]
    t:place(other,sq,0.7,0.1,0,true);local b=assert(G.capture(t.p,other,t.floor));assert(not G.sameAnchor(t.a,b))
    assert(not t.g:start(other,t.floor,t.main,yes,t.a));local a=t:take();a:perform();assert(t.g:poll()==true)
    local d=t:drop();assert(d:complete());d:perform();t.floor:add(t.it);assert(t.g:poll()==true)
    assert(other.world.sq==sq and t.it.world.sq==t.sq and G.sameAnchor(b,G.capture(t.p,other,t.floor)))
end)
-- The repository's concrete PourStacks implementation also recognizes an unfolded
-- Ground section inside a combined loot display, and must not mistake a mere tab
-- or a folded section for permission to use it.
if package.loaded["LootBox/PourStacks"] then
    test("Visible combined Ground section survives an empty loan; folding it withdraws permission",function()
        local t=fixture(true,true)
        local pane=t.page.inventoryPane
        local button={inventory=t.floor}
        local section={index=1,button=button,container=t.floor,folded=false}
        t.page.backpacks={button}
        pane.inventory=container("different");pane.getIsVisible=yes;pane.ninvCombinedBuilt=false
        pane.ninvSections={section};pane.ninvSectionOf={[t.floor]=section}
        assert(G.capture(t.p,t.it,t.floor));t:toMain();assert(G.reachable(t.p,t.a))
        section.folded=true;assert(not G.reachable(t.p,t.a));assert(not t.g:start(t.it,t.main,t.floor,yes,t.a))
    end)
end
if stockPickup then
    for _,n in ipairs({"TimedActions/ISInventoryTransferAction","TimedActions/ISGrabCorpseAction","ISUI/PlayerData/ISPlayerData"}) do package.loaded[n]=true end
    ISTradingUI={GetUIForPlayer=function() return f.trading and {isVisible=yes} end}
    CharacterTrait={DEXTROUS=1,ALL_THUMBS=2,DESENSITIZED=3,HEMOPHOBIC=4}
    Metabolics={LightWork=1}
    ISBaseTimedAction.setActionAnim=nothing;ISBaseTimedAction.setAnimVariable=nothing;ISBaseTimedAction.setOverrideHandModels=nothing
    function getServerOptions() return {getInteger=zero} end
    function isItemTransactionConsistent() return true end
    function getItemTransactionDuration() return 120 end
    function createItemTransaction(p,items,from,to)
        assert(p==f.p and #items==1 and items[1]==f.it and from==f.floor and to==f.main)
        assert(not f.request,"more than one stock operation")
        f.request=37;return f.request
    end
    function removeItemTransaction(id,rejected) assert(id==f.request); f.removed={id,rejected} end
    assert(loadfile(stockPickup.."/client/TimedActions/ISInventoryTransferAction.lua"))()
    assert(loadfile(stockPickup.."/shared/TimedActions/ISInventoryTransferUtil.lua"))()
    local function prepared()
        local t=fixture(true,true)
        for _,c in ipairs({t.floor,t.main}) do
            c.isVehicleSeat=no;c.isInCharacterInventory=function(self) return self==t.main end
            c.getTakeSound=nothing;c.getPutSound=nothing;c.getContainerPosition=nothing;c.getContainingItem=nothing;c.getParent=nothing
        end
        local p=t.p;p.class="IsoPlayer";p.hasTrait=no;p.isWearingAwkwardGloves=no;p.isPlayerMoving=no
        p.clearVariable=nothing;p.reportEvent=nothing;p.setMetabolicTarget=nothing;p.shouldBeTurning=no
        p.getEmitter=function() return {isPlaying=no,playSound=nothing} end
        local i=t.it;i.isHumanCorpse=no;i.getActualWeight=function() return 1 end;i.getIsCraftingConsumed=no
        i.setJobType=function(self,n)self.job=n end;i.getJobType=get("job");i.getName=function()return "Bucket" end
        t.page.selectButtonForContainer=function() end
        function t.q:indexOf(a) for idx,v in ipairs(self.queue) do if v==a then return idx end end return -1 end
        local put=t.q.addToQueue
        function t.q:addToQueue(a)
            put(self,a);a.action={setWaitForFinished=nothing,setTime=nothing,stopTimedActionAnim=nothing,setLoopedAction=nothing,
                getJobDelta=zero,forceComplete=function()a:perform()end}
        end
        assert(t.g:start(t.it,t.floor,t.main,yes,t.a))
        local a=t.q.current
        assert(a:waitToStart() and not t.request);t.now=t.now+11;assert(not a:waitToStart() and a:isValidStart())
        a:start();assert(t.request==37 and a.transactionId==37 and a.started)
        return t,a
    end
    test("Pinned native Ground pickup: actual request, reordered replica, matching receipt before cleanup",function()
        local t,a=prepared();local v=item(478);t.main:add(v)
        a:update();assert(t.g:poll()==nil and t.q.current==a)
        t.done=true;a:update()
        assert(t.removed[1]==37 and t.removed[2]==false and a.transactionId==0 and t.g:poll()==nil)
        t:unworld(t.it);t:step();assert(t.g:poll()==nil,"wait for synthetic Floor too")
        t.floor:Remove(t.it);t:step();local pass,_,actual=t.g:poll();assert(pass==true and actual==v and t.localWrites==0)
    end)
    test("Pinned native Ground pickup: server rejection",function()
        local t,a=prepared();t.rejected=true;a:update()
        assert(t.removed[1]==37 and t.removed[2]==true and t.g:poll()==false and t.floor:contains(t.it) and t.localWrites==0)
    end)
    test("Pinned native Ground pickup: stock validator remains enabled after request",function()
        local t,a=prepared();t.trading=true;assert(not a:isValid());a:stop()
        assert(t.removed[1]==37 and t.removed[2]==true and t.g:poll()==false and t.floor:contains(t.it) and t.localWrites==0)
    end)
end
print("✓ "..ran.." ground placement/pickup cases"..(stock and " (pinned stock Place Item Lua)" or " (fixture)")..(stockPickup and " + stock pickup transaction Lua" or ""))
