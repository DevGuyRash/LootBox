package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local f
package.loaded["TimedActions/ISTimedActionQueue"] = true
package.loaded["TimedActions/ISInventoryTransferUtil"] = true

local function container(kind)
    local items = {}
    return {items=items,getType=function()return kind end, getItems=function()
        return {size=function()return #items end,get=function(_,i)return items[i+1] end}
    end, contains=function(_,needle) for _,v in ipairs(items)do if v==needle then return true end end return false end,
        isItemAllowed=function(self)return not self.denied end,hasRoomFor=function(self)return not self.full end}
end
local function remove(x)
    if not x.parent then return end
    for i,v in ipairs(x.parent.items) do if v==x then table.remove(x.parent.items,i);break end end
    x.parent=nil
end
local function place(x,c) remove(x);x.parent=c;c.items[#c.items+1]=x end
local function item(id, kind)
    return {getID=function()return id end,getFullType=function()return kind or "Base.Bucket" end,
        getContainer=function(x)return x.parent end}
end
function isClient()return f.mp end
function isServer()return f.server end
function getTimestampMs()return f.now end
function isItemTransactionDone(id)return f.done[id]==true end
function isItemTransactionRejected(id)return f.reject[id]==true end
ISTimedActionQueue = {getTimedActionQueue=function()return f.q end,add=function(a)
    f.q:addToQueue(a)
    a:start()
end}
ISInventoryTransferUtil={newInventoryTransferAction=function(p,x,from,to)
    local a={Type="ISInventoryTransferAction",character=p,item=x,srcContainer=from,destContainer=to,action={}}
    function a:isValid()return not f.invalid end
    function a:isValidStart()return self:isValid() end
    function a:start()f.starts=f.starts+1;if f.mp then self.transactionId=12 end end
    function a:transferItem(y)f.writes=f.writes+1;place(y,to) end
    function a:perform()
        if not f.mp then self:transferItem(self.item) end
        self.transactionId=0
        f.q:removeFromQueue(self)
        f.q.current=f.q.queue[1]
    end
    function a:stop() f.q.queue={};f.q.current=nil end
    function a:forceStop()self:stop() end
    function a:forceCancel()self.cancelled=true end
    f.action=a
    return a
end}
local Move=require "LootBox/PourMove"
local function reset(mp)
    f={mp=mp or false,server=false,now=1,done={},reject={},starts=0,writes=0,admit=true,wait=true}
    f.source,f.dest,f.item=container("crate"),container("inventory"),item(62)
    place(f.item,f.source)
    f.q={queue={},addToQueue=function(q,a) q.queue[#q.queue+1]=a;q.current=q.current or a end,
        removeFromQueue=function(q,a) for i,v in ipairs(q.queue)do if a==v then table.remove(q.queue,i);return end end end}
    f.player={isDead=function()return false end,isAsleep=function()return false end,
        isMoving=function()return f.moving end,isRunning=function()return false end,isSprinting=function()return false end,
        isAiming=function()return f.aiming end,isAttacking=function()return false end,hasTimedActions=function()return false end,
        isEquipped=function()return f.worn end}
    f.move=Move.new(f.player)
end
local function begin()
    return f.move:start(f.item,f.source,f.dest,function(phase,x,from,to)
        assert(x==f.item and from==f.source and to==f.dest)
        return f[phase]
    end)
end
local function arrival()
    return item(62)
end
reset()
assert(begin() and f.action.stopOnAim and f.action.stopOnWalk and f.action.stopOnRun and not f.action:canMergeAction())
assert(f.move:poll()==nil)
f.action:perform()
local ok,reason,arrived=f.move:poll()
assert(ok and reason==nil and arrived==f.item and f.writes==1 and f.item.parent==f.dest)
print("PASS stock single player transfer settles only after exact source removal and arrival")

reset(true);assert(begin() and f.action.transactionId==12)
f.admit=false
remove(f.item);local repl=arrival();place(repl,f.dest)
assert(f.move:poll()==nil and f.action:isValid(), "replica arriving first is not server acceptance")
f.done[12]=true;f.action:perform()
local success,_,returned=f.move:poll()
assert(success and returned==repl and f.writes==0)
print("PASS standard MP acknowledgement and different Java object share exact immutable ID")

reset(true);assert(begin())
f.done[12]=true;f.action:perform()
assert(f.move:poll()==nil, "Done by itself does not settle")
remove(f.item);place(arrival(),f.dest);f.now=200
assert(f.move:poll())
reset(true);assert(begin())
f.done[12]=true;f.reject[12]=true;f.action:perform()
remove(f.item);place(arrival(),f.dest)
assert(f.move:poll()==false, "rejection always wins even with a plausible mirrored arrival")
reset(true);assert(begin())
f.done[11]=true;f.action:perform()
remove(f.item);place(arrival(),f.dest)
assert(f.move:poll()==false, "another transaction's acknowledgement is irrelevant")
print("PASS MP ack-first, replica-first, wrong transaction, and rejection ordering")

reset(true);assert(begin())
f.done[12]=true;f.action:perform();remove(f.item);place(item(62,"Other.Type"),f.dest)
assert(f.move:poll()==false)
reset(true);assert(begin())
f.done[12]=true;f.action:perform();local overlap=arrival();place(overlap,f.dest)
assert(f.move:poll()==nil,"replicated Add before Remove is pending, not ambiguous")
remove(f.item);f.now=200
local overlapOK,_,overlapArrival=f.move:poll()
assert(overlapOK and overlapArrival==overlap,"paired endpoints settle after the Remove update")
reset(true);assert(begin())
f.done[12]=true;f.action:perform();place(arrival(),f.dest)
assert(f.move:poll()==nil)
f.now=30002
assert(f.move:poll()==false,"unresolved overlap fails at the ordinary timeout")
reset(true);assert(begin())
f.done[12]=true;f.action:perform();remove(f.item);place(arrival(),f.dest);place(arrival(),f.dest)
assert(f.move:poll()==false,"duplicate ID within one endpoint is ambiguous, not pending")
reset(true);place(arrival(),f.dest)
assert(not begin(),"strict admission requires no destination replica before the request")
reset(true);assert(begin())
f.done[12]=true;f.action:perform();remove(f.item);place(item(63),f.dest)
assert(f.move:poll()==nil,"unrelated item never settles")
f.now=30002;assert(f.move:poll()==false)
print("PASS identity mismatch, duplicate arrival, and bounded no-arrival failure")

reset();f.worn=true;assert(not begin())
reset();f.dest.full=true;assert(not begin())
reset();f.source.getType=function()return "floor" end;assert(not begin())
reset();f.admit=false;assert(not begin())
reset();f.aiming=true;assert(not begin())
reset();assert(begin());f.moving=true
assert(f.move:poll()==nil and f.move:poll()==false and f.writes==0)
reset(true);assert(begin());f.wait=false
local foreign={}
f.q:addToQueue(foreign)
assert(f.move:cancel())
assert(f.move:poll()==false and f.q.current==foreign and f.q.queue[1]==foreign and f.writes==0)
print("PASS no floor/worn/full/unsafe transfer; cancellation preserves foreign work")

reset(true);assert(begin())
local stale=f.action
f.q.queue={foreign};f.q.current=foreign
stale:stop()
assert(f.move:poll()==false and f.q.current==foreign and f.q.queue[1]==foreign)
print("PASS stale native stop cannot clear a newer manual action")

-- Optional stock Lua lane. Supply the root of installed media/lua or the
-- unmodified B42.22 mirror; no game assets are required for portable runs.
if arg and arg[1] then
    local root=arg[1]
    local function noop() end
    ISBaseTimedAction={derive=function(base,name)
        return setmetatable({Type=name},{__index=base})
    end,isValidStart=function(self)return self:isValid() end,
        setActionAnim=noop,setAnimVariable=noop,setOverrideHandModels=noop,
        forceStop=function(self)self:stop()end,forceCancel=noop}
    function ISBaseTimedAction:perform()
        f.q:removeFromQueue(self)
        f.q.current=f.q.queue[1]
    end
    function ISBaseTimedAction:stop()
        f.q.queue={};f.q.current=nil
    end
    for _,mod in ipairs({"TimedActions/ISBaseTimedAction","TimedActions/ISInventoryTransferAction",
        "TimedActions/ISGrabCorpseAction","ISUI/PlayerData/ISPlayerData"}) do package.loaded[mod]=true end
    ISInventoryPage={}
    ISTradingUI={GetUIForPlayer=function()return nil end}
    CharacterTrait={DEXTROUS=1,ALL_THUMBS=2,DESENSITIZED=3,HEMOPHOBIC=4}
    Metabolics={LightWork=1}
    function getServerOptions()return {getInteger=function()return 0 end} end
    function instanceof(x,t)return x==f.player and t=="IsoPlayer" end
    function getSpecificPlayer()return f.player end
    function isItemTransactionConsistent()return true end
    function getText(s)return s end
    function getPlayerLoot()return {selectButtonForContainer=noop} end
    function getItemTransactionDuration()return 120 end
    function createItemTransaction(p,items,from,to)
        assert(p==f.player and #items==1 and items[1]==f.item and from==f.source and to==f.dest)
        assert(not f.request,"one stock transaction only")
        f.request=12
        return f.request
    end
    function removeItemTransaction(id,rejected)
        assert(id==f.request)
        f.removed={id,rejected}
    end
    assert(loadfile(root.."/client/TimedActions/ISInventoryTransferAction.lua"))()
    assert(loadfile(root.."/shared/TimedActions/ISInventoryTransferUtil.lua"))()
    local function stockSetup()
        reset(true)
        for _,c in ipairs({f.source,f.dest}) do
            c.isVehicleSeat=function()return false end
            c.isInCharacterInventory=function(self)return self==f.dest end
            c.getTakeSound=noop; c.getPutSound=noop; c.getContainerPosition=noop
            c.getContainingItem=noop; c.getParent=noop
        end
        local p=f.player
        p.getInventory=function()return f.dest end
        p.getPlayerNum=function()return 0 end
        p.hasTrait=function()return false end
        p.isWearingAwkwardGloves=function()return false end
        p.isTimedActionInstant=function()return false end
        p.isPlayerMoving=function()return false end
        p.clearVariable=noop; p.reportEvent=noop; p.setMetabolicTarget=noop
        p.shouldBeTurning=function()return false end
        p.getEmitter=function()return {isPlaying=function()return false end,playSound=noop} end
        local x=f.item
        x.isHumanCorpse=function()return false end
        x.getActualWeight=function()return 1 end
        x.isFavorite=function()return false end
        x.getIsCraftingConsumed=function()return false end
        x.getType=function()return "Bucket" end
        x.setJobType=function(self,name)self.job=name end
        x.getJobType=function(self)return self.job end
        x.getName=function()return "Bucket" end
        x.setJobDelta=noop
        f.q.indexOf=function(q,a) for i,v in ipairs(q.queue)do if v==a then return i end end return -1 end
        -- Java queue calls its delayed wait/start/update/perform lifecycle.
        ISTimedActionQueue.add=function(a)
            f.q:addToQueue(a)
            a.action={setWaitForFinished=noop,setTime=noop,stopTimedActionAnim=noop,setLoopedAction=noop,
                getJobDelta=function()return 0 end,forceComplete=function()a:perform()end}
        end
        assert(begin())
        local a=f.q.current
        assert(a:waitToStart() and not f.request)
        f.now=f.now+11
        assert(not a:waitToStart() and a:isValidStart())
        a:start()
        assert(f.request==12 and a.transactionId==12 and a.started)
        return a
    end
    local a=stockSetup()
    local remote=arrival()
    place(remote,f.dest)
    a:update()
    assert(f.move:poll()==nil and f.q.current==a,"matching arrival alone cannot complete")
    f.done[12]=true
    a:update()
    assert(f.removed[1]==12 and not f.removed[2] and a.transactionId==0 and f.move:poll()==nil,
        "native positive result sampled before ID clears; Add-before-Remove stays pending")
    remove(f.item)
    f.now=f.now+126
    local settled,_,actual=f.move:poll()
    assert(settled and actual==remote and f.writes==0)
    a=stockSetup()
    f.reject[12]=true
    a:update()
    assert(f.removed[1]==12 and f.removed[2] and f.move:poll()==false and f.item.parent==f.source)
    print("PASS pinned stock inventory action: exact MP request, positive result, delayed Add/Remove, and rejection")
end
