-- Ordinary, portable item-owned vessels selected from the native Ground pane.
-- No inventory or fluid writes: the stock pickup transaction and stock Place
-- Item action are the only operations. The recreated wrapper is not the item ID.
require "TimedActions/ISTimedActionQueue"
local Stacks=require "LootBox/PourStacks"
local Ground={}
Ground.__index=Ground
local MAX_ITEMS,TIMEOUT,SAMPLE=4096,30000,100
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function near(a,b) return finite(a) and finite(b) and math.abs(a-b)<0.00002 end
local function angle(a,b) return finite(a) and finite(b) and math.abs((a-b+180)%360-180)<0.001 end
local function optional(run,...) local ok,value=pcall(run,...);if ok then return value end end
local function indexOK(n) return finite(n) and n%1==0 and n>=0 end

local function display(player,floor)
    if isServer() or getSpecificPlayer(player:getPlayerNum())~=player or not player:isLocalPlayer()
        or player:isDead() or player:isAsleep() or player:getVehicle()~=nil then return false end
    local i=player:getPlayerNum()
    return Stacks.displayedLoot(i,floor)==floor
        and ISInventoryPage.GetFloorContainer(i)==floor and floor:getType()=="floor"
        and floor:isLockedToCharacter(player)==false
end

-- This adapter only promises ordinary flat ground. It does not reconstruct an
-- extended tabletop/stair pose or manually alter any world item or removal flag.
local function reachable(p,a)
    if not a or a.player~=p or not display(p,a.floor) then return false end
    local sq,here=a.square,p:getCurrentSquare()
    if not here or not sq or getCell():getGridSquare(a.x,a.y,a.z)~=sq or here:getZ()~=a.z
        or math.abs(here:getX()-a.x)>1 or math.abs(here:getY()-a.y)>1 then return false end
    if isClient() and (not SafeHouse or SafeHouse.isSafehouseAllowLoot(sq,p)~=true) then return false end
    if not sq:isCouldSee(p:getPlayerNum()) or not sq:TreatAsSolidFloor() or sq:isSolid() or sq:isSolidTrans()
        or sq:HasStairs() or sq:hasSlopedSurface() or not sq:isAdjacentTo(here)
        or sq:isBlockedTo(here) or not luautils.walkAdjTest(p,sq) or (sq~=here and (not here:canReachTo(sq) or sq:isWallTo(here) or sq:isWindowTo(here))) then return false end
    return true
end
function Ground.reachable(p,a) return optional(reachable,p,a)==true end

local function exactWorld(item,world,square)
    if not item or not world or not square or item:getWorldItem()~=world or world:getItem()~=item
        or world:getSquare()~=square or not world:isExistInTheWorld() then return false end
    local i=world:getWorldObjectIndex()
    local list=square:getWorldObjects()
    return indexOK(i) and i<list:size() and list:get(i)==world
end
local function pose(a,it,w)
    return near(w:getOffX(),a.ox) and near(w:getOffY(),a.oy) and near(w:getOffZ(),a.oz)
        and angle(it:getWorldXRotation(),a.rx) and angle(it:getWorldYRotation(),a.ry)
        and angle(it:getWorldZRotation(),a.rz) and w:isExtendedPlacement()==false
end
local function ordinary(p,it)
    if not it or it:isFavorite() or p:isEquipped(it) or (p.isAttachedItem and p:isAttachedItem(it)) or (it.isWorn and it:isWorn())
        or it:getType()=="CandleLit" or it:getType()=="Lantern_HurricaneLit"
        or it:getType()=="CarBatteryCharger" or instanceof(it,"Radio") then return false end
    local model=it:getWorldStaticItem()
    if (not model or model=="") and not instanceof(it,"HandWeapon") and not instanceof(it,"Clothing") then return false end
    return not instanceof(it,"Clothing") or it:canBe3DRender()
end
local function room(square,it,alreadyHere)
    local weight,total=it:getUnequippedWeight(),square:getTotalWeightOfItemsOnFloor()
    -- Match the stricter stock Place Item cursor (<50), not merely the timed
    -- action (<=50). Original item already counts when previewing its pickup.
    return finite(total) and total>=0 and finite(weight) and weight>=0 and total+(alreadyHere and 0 or weight)<50
end
local function capture(p,it,floor)
    if not it or not display(p,floor) or it:getContainer()~=floor or not floor:getItems():contains(it) or not ordinary(p,it) then return nil end
    local w=it:getWorldItem()
    local sq=w and w:getSquare()
    if not exactWorld(it,w,sq) or w:isExtendedPlacement()~=false then return nil end
    local fc,wfc=it:getFluidContainer(),w:getFluidContainer()
    if not fc or fc:getOwner()~=it or not fc:canPlayerEmpty() or fc:isMultiTileMoveable() or it:isSealed()
        or (wfc and wfc~=fc) then return nil end
    local a={player=p, floor=floor, square=sq, item=it, world=w, id=it:getID(),fullType=it:getFullType(),
        x=sq:getX(),y=sq:getY(),z=sq:getZ(),ox=w:getOffX(),oy=w:getOffY(),oz=w:getOffZ(),
        rx=it:getWorldXRotation(),ry=it:getWorldYRotation(),rz=it:getWorldZRotation()}
    if not finite(a.id) or type(a.fullType)~="string" or a.fullType=="" or not finite(a.ox) or not finite(a.oy)
        -- The native wrapper randomizes zero offsets and resets X/Y tilt on placement.
        -- Never borrow an object for which stock cannot reproduce its original pose.
        or a.ox<=0 or a.ox>=1 or a.oy<=0 or a.oy>=1 or not near(a.oz,0)
        or not angle(a.rx,0) or not angle(a.ry,0) or not finite(a.rz) or a.rz<0 or a.rz>360
        or not reachable(p,a) or not room(sq,it,true) then return nil end
    return a
end
function Ground.capture(p,it,floor) return optional(capture,p,it,floor) end
function Ground.sameAnchor(a,b)
    return a~=nil and b~=nil and a.player==b.player and a.floor==b.floor and a.square==b.square
        and a.world==b.world and a.item==b.item and a.id==b.id and a.fullType==b.fullType
        and near(a.ox,b.ox) and near(a.oy,b.oy) and near(a.oz,b.oz)
        and angle(a.rx,b.rx) and angle(a.ry,b.ry) and angle(a.rz,b.rz)
end

-- Return nil,false when identity is inherently ambiguous. Overlap BETWEEN
-- endpoints is normal during replication and never by itself signals success.
local function locate(list,a,world)
    local count=list:size()
    if not indexOK(count) or count>MAX_ITEMS then return nil,false end
    local found
    for n=0,count-1 do
        local obj=list:get(n)
        if not obj then return nil,false end
        local v=obj
        if world then v=obj:getItem() end
        if not v then return nil,false end
        if v:getID()==a.id then
            if found or v:getFullType()~=a.fullType then return nil,false end
            if world and not exactWorld(v,obj,a.square) then return nil,false end
            found=v
        end
    end
    return found,true
end
local function positions(s)
    local m,mc=locate(s.main:getItems(),s.a,false)
    local g,gc=locate(s.a.square:getWorldObjects(),s.a,true)
    if m and m:getContainer()~=s.main then return nil,nil,false end
    return m,g,mc and gc
end
local function qFor(s) return ISTimedActionQueue.getTimedActionQueue(s.p) end
local function inQueue(q,a)
    for _,v in ipairs(q.queue) do if a==v then return true end end
    return false
end
local function granted(s,phase)
    return not s.problem and s.mp==isClient() and Ground.reachable(s.p,s.a)
        and not s.p:isMoving() and not s.p:isRunning() and not s.p:isSprinting()
        and not s.p:isAiming() and not s.p:isAttacking()
        and s.guard(phase,s.it,s.from,s.to)==true and getTimestampMs()<s.untilAt
end
local function ownOrIdle(s)
    local q=qFor(s)
    return (q.current==s.act and #q.queue==1 and q.queue[1]==s.act)
        or (not q.current and #q.queue==0)
end
local function matchesAction(s)
    local a=s.act
    if not a then return true end
    if a.character~=s.p or a.item~=s.it then return false end
    if s.taking then return a.srcContainer==s.from and a.destContainer==s.to end
    return a.sq==s.a.square and a.xoffset==s.a.ox and a.yoffset==s.a.oy
        and a.zoffset==s.a.oz and a.rotation==s.a.rz and a.isPlaceItem==true
end
local function exactStart(s)
    if not matchesAction(s) or not granted(s,"admit") or not ownOrIdle(s) or not ordinary(s.p,s.it) then return false end
    local m,g,unambiguous=positions(s)
    local projected,clean=locate(s.a.floor:getItems(),s.a,false)
    if not unambiguous or not clean then return false end
    if s.taking then
        return projected==s.it and g==s.it and not m and Ground.sameAnchor(s.a,Ground.capture(s.p,s.it,s.a.floor))
            and s.a.floor:isRemoveItemAllowed(s.it) and s.main:isItemAllowed(s.it) and s.main:hasRoomFor(s.p,s.it)
    end
    return m==s.it and not projected and not g and s.it:getWorldItem()==nil and s.main:isRemoveItemAllowed(s.it)
        and angle(s.it:getWorldXRotation(),s.a.rx) and angle(s.it:getWorldYRotation(),s.a.ry)
        and angle(s.it:getWorldZRotation(),s.a.rz) and room(s.a.square,s.it,false)
end

-- The native stop resets the entire queue. Isolate its reset to our owned
-- current entry, then restore the exact foreign references/order. Never call
-- stop, forceCancel, perform or a global queue-clear on an unrelated action.
local function stopOwned(s,fn,act,...)
    local q=qFor(s)
    if q.current~=act then return end
    local tail={}
    for _,v in ipairs(q.queue) do if v~=act then tail[#tail+1]=v end end
    if #tail==0 then return fn(act,...) end
    for _,v in ipairs(tail) do q:removeFromQueue(v) end
    local ok,out=pcall(fn,act,...)
    for _,v in ipairs(tail) do if not inQueue(q,v) then q:addToQueue(v) end end
    if not ok then error(out,0) end
    return out
end
local function cancelOwned(s)
    local q=qFor(s)
    if q.current==s.act then
        if s.act.action and not s.stopping then s.stopping=true;s.act:forceStop() end
    elseif inQueue(q,s.act) then s.act:forceCancel();q:removeFromQueue(s.act) end
end

local function install(s)
    local a=s.act
    if not a or a.character~=s.p or a.item~=s.it or type(a.forceStop)~="function" then return false end
    if s.taking then
        if a.Type~="ISInventoryTransferAction" or a.srcContainer~=s.from or a.destContainer~=s.to then return false end
    else
        if a.Type~="ISDropWorldItemAction" or a.sq~=s.a.square or a.xoffset~=s.a.ox or a.yoffset~=s.a.oy
            or a.zoffset~=s.a.oz or a.rotation~=s.a.rz then return false end
        a.isPlaceItem=true -- stock ISPlace3DItemCursor:create, including adjacency
    end
    local valid,vstart,wait,start,perform,stop=a.isValid,a.isValidStart,a.waitToStart,a.start,a.perform,a.stop
    if type(valid)~="function" or type(vstart)~="function" or type(wait)~="function" or type(start)~="function"
        or type(perform)~="function" or type(stop)~="function" then return false end
    a.stopOnWalk,a.stopOnRun,a.stopOnAim=true,true,true
    local function okNow()
        if not matchesAction(s) then return false end
        if s.sent or s.armed and not s.taking and s.mp then return granted(s,"wait") and ownOrIdle(s) end
        return exactStart(s)
    end
    function a:canMergeAction() return false end
    function a:isValidStart(...) return optional(okNow)==true and vstart(self,...) end
    function a:isValid(...) return optional(okNow)==true and valid(self,...) end
    function a:waitToStart(...)
        if optional(exactStart,s)~=true or not valid(self) then
            s.problem="Ground vessel or placement is no longer valid.";cancelOwned(s);return true
        end
        local waiting=wait(self,...)
        if not waiting then s.armed=true end
        return waiting
    end
    function a:start(...)
        if not s.armed or qFor(s).current~=self or optional(exactStart,s)~=true or not valid(self) then
            s.problem="Ground action lost its original item or location.";cancelOwned(s);return
        end
        local v=start(self,...)
        s.started=true
        if s.taking and s.mp then
            local id=self.transactionId
            if finite(id) and id~=0 then s.sent=id else s.problem="The stock ground pickup was not submitted." end
        end
        return v
    end
    if s.taking then
        local transfer=a.transferItem
        if type(transfer)~="function" then return false end
        function a:transferItem(v,...)
            if not s.mp and s.started and v==s.it and optional(exactStart,s)==true and valid(self) then return transfer(self,v,...) end
        end
    else
        local complete=a.complete
        if type(complete)~="function" then return false end
        function a:complete(...)
            -- MP authority runs the unmodified stock class on the server;
            -- this local wrapper never performs an inventory/world mutation on a client.
            if s.mp then return false end
            if s.completed or not s.armed or not s.started or optional(exactStart,s)~=true or not valid(self) then
                s.problem="The exact stock ground placement was not safe.";return false
            end
            s.completed=true
            return complete(self,...)
        end
    end
    function a:perform(...)
        if qFor(s).current~=self then s.problem="Ground action was no longer current.";return end
        if not s.armed or not s.started or not ownOrIdle(s) or optional(granted,s,"wait")~=true then
            s.problem=s.problem or "Ground action was interrupted."
        end
        if s.taking and s.mp then
            s.ack=s.sent~=nil and self.transactionId==s.sent and isItemTransactionDone(s.sent)==true and isItemTransactionRejected(s.sent)==false
        end
        s.performed=true
        return stopOwned(s,perform,self,...)
    end
    function a:stop(...) s.problem=s.problem or "Ground action was stopped.";return stopOwned(s,stop,self,...) end
    return true
end

function Ground.new(player) return setmetatable({player=player},Ground) end
function Ground:isBusy() return self.active~=nil end
local function begin(self,it,from,to,guard,a)
    local p=self.player
    if self.active or type(guard)~="function" or not a or not it or it:getID()~=a.id or it:getFullType()~=a.fullType then return nil,"Choose the original ground vessel." end
    local main=p:getInventory()
    local take=from==a.floor and to==main
    if not take and not (from==main and to==a.floor) then return nil,"Ground move endpoints changed." end
    local s={p=p,it=it,a=a,main=main,from=from,to=to,taking=take,guard=guard,mp=isClient(),untilAt=getTimestampMs()+TIMEOUT}
    local q=qFor(s)
    if q.current or #q.queue~=0 or p:hasTimedActions() or not exactStart(s) then return nil,"Ground vessel, position or room changed." end
    if take then
        require "TimedActions/ISInventoryTransferUtil"
        s.act=ISInventoryTransferUtil.newInventoryTransferAction(p,it,from,to)
    else
        require "TimedActions/ISDropWorldItemAction"
        s.act=ISDropWorldItemAction:new(p,it,a.square,a.ox,a.oy,a.oz,a.rz,false)
    end
    if not install(s) or not s.act:isValid() then return nil,"The game declined the ground action." end
    self.active=s
    ISTimedActionQueue.add(s.act)
    if not inQueue(q,s.act) and not s.performed then self.active=nil;return nil,"The stock ground action did not start." end
    return true
end
function Ground:start(...)
    local previous=self.active
    local ok,value,why=pcall(begin,self,...)
    if ok then return value,why end
    if self.active and self.active~=previous then self:cancel() end
    return nil,"The stock ground action is unavailable."
end
function Ground:cancel()
    local s=self.active
    if s then s.problem=s.problem or "Ground action cancelled.";optional(cancelOwned,s) end
    return true
end
local function poll(self)
    local s=self.active
    if not s then return false,"No ground action is active." end
    local q=qFor(s)
    local owned=q.current==s.act or inQueue(q,s.act)
    local function finish(ok,reason,item) self.active=nil;return ok,reason,item end
    if not ownOrIdle(s) or not granted(s,"wait") then s.problem=s.problem or "Ground action lost its context or timed out." end
    if s.problem then
        if owned then cancelOwned(s);return nil end
        return finish(false,s.problem)
    end
    if owned then return nil end
    if not s.performed or (s.taking and s.mp and not s.ack) or (not s.taking and not s.mp and not s.completed)
        then return finish(false,"The stock ground action did not complete.") end
    local now=getTimestampMs()
    if s.sample and now<s.sample then return nil end
    s.sample=now+SAMPLE
    local m,g,unambiguous=positions(s)
    if not unambiguous then return finish(false,"Ground vessel identity is ambiguous.") end
    -- The displayed Floor is a synthetic aggregate. Its Add/Remove can lag
    -- behind world and main. Never settle on an ambiguous or stale projection.
    local projected,clean=locate(s.a.floor:getItems(),s.a,false)
    if not clean then return nil end
    if s.taking then
        if m and not g and not projected and (s.mp or m==s.it) and m:getWorldItem()==nil then return finish(true,nil,m) end
    elseif not m and g then
        if not pose(s.a,g,g:getWorldItem()) then return finish(false,"Return was not at the selected ground position.") end
        if (s.mp or g==s.it) and projected==g and g:getContainer()==s.a.floor then
            return finish(true,nil,g)
        end
    end
    return nil
end
function Ground:poll()
    local ok,value,why,item=pcall(poll,self)
    if ok then return value,why,item end
    local s=self.active
    if s then
        self:cancel()
        local q=optional(qFor,s)
        if q and (q.current==s.act or inQueue(q,s.act)) then return nil end
        self.active=nil
    end
    return false,"The exact ground vessel could not be verified."
end
return Ground
