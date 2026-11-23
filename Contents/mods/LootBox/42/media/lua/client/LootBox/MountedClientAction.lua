-- An owned stock action and its client-observed world/inventory receipt.
-- Never calls stock complete on this peer or treats local perform as success.
local Take = require "LootBox/MountedTakeReceipt"
local findCarried = require("LootBox/CreatedItemReceipt").findCarried
local M = {}
local enabled = require("LootBox/MountedClientPolicy").enabled
local ACTION, BOTTLE = "ISAddTakeDispenserBottle", "Base.WaterDispenserBottle"
local ACTION_MS, MIRROR_MS, STABLE_MS = 20000, 7000, 350

local function queue(p) return ISTimedActionQueue.getTimedActionQueue(p) end
local function netOwn(s, sole)
    local a, q, p = s.action, s.queue, s.player
    if queue(p)~=q or q.current~=a or q.queue[1]~=a or sole and #q.queue~=1 or a.character~=p then return false end
    local stack, handle = p:getCharacterActions(), a.action
    if not handle or s.handle and s.handle~=handle or stack:size()~=1 or stack:get(0)~=handle then return false end
    s.handle=handle
    return true
end
local function idle(s)
    return queue(s.player)==s.queue and not s.queue.current and #s.queue.queue==0
        and s.player:getCharacterActions():size()==0 and not s.player:hasTimedActions()
end

-- Refit is NOT an item-creation receipt. Its own world and inventory changes
-- can project in either order, before perform, or after an initial default mount.
local function refitWatch(s)
    local a, input, p, ops = s.action, s.input, s.player, s.ops
    local jug, id = a.bottle, a.bottle:getID()
    local W = {phase="waiting",deadline=getTimestampMs()+ACTION_MS}
    function W:cancel(reason)
        self.problem,self.phase=self.problem or reason,"closed"
        return nil,self.problem
    end
    local function live()
        return ops.live() and a.Type==ACTION and getmetatable(a)==ISAddTakeDispenserBottle
            and a.character==p and a.bottle==jug and jug:getID()==id and jug:getFullType()==BOTTLE
            and a.waterdispenser==input.object and a.square==input.square
    end
    local function held()
        local current,problem,holder=findCarried(s.main,id)
        return not problem and current==jug and holder==s.main and not jug:getWorldItem() and ops.admit()
    end
    local function pre()
        return live() and netOwn(s,true) and held()
    end
    local function inspect()
        if not live() then return false,"The refit actor, vessels or permission changed." end
        local result,valid=ops.slot()
        if not valid then return false,"The dispenser slot is ambiguous." end
        if result and result.object==input.object then
            if W.absent or result.kind~="bare" or result.object:getFluidContainer() then
                return false,"The bare dispenser transition reversed."
            end
        else
            if input.object:getObjectIndex()~=-1 or result and result.kind~="mounted"
                or W.successor and (not result or W.successor.object~=result.object) then
                return false,"The stock refit successor changed."
            end
            W.absent,W.successor=true,result
        end
        local current,problem,holder=findCarried(s.main,id)
        if problem then return false,"The exact refit bottle could not be audited." end
        if current then
            if W.retired or current~=jug or holder~=s.main or jug:getWorldItem() or not ops.jugUnchanged() then
                return false,"The selected refit bottle moved or changed."
            end
        elseif jug:getContainer() or jug:getWorldItem() then
            return false,"The selected refit bottle was moved, not consumed."
        else W.retired=true end
        local confirmed=W.retired and W.successor and ops.fitted(W.successor)
        if W.stable and not confirmed then return false,"The confirmed refit changed." end
        return true,confirmed
    end
    function W:waitToStart(owner,waiting)
        self.pass=false
        if owner~=a or self.phase~="waiting" or type(waiting)~="boolean" or not pre() then
            self:cancel("The exact bottle or bare stand changed before refit.");return true,self.problem
        end
        self.pass=not waiting
        return waiting
    end
    function W:beforeStart(owner)
        if owner~=a or self.phase~="waiting" or not self.pass or not pre() then
            return self:cancel("The refit start did not pass its admission fence.")
        end
        self.phase="starting";return true
    end
    function W:started(owner,returned)
        if owner~=a or self.phase~="starting" or not returned or not pre() then
            return self:cancel("The stock refit start was not verified.")
        end
        self.phase="running";return true
    end
    function W:beforePerform(owner)
        if owner~=a or self.phase~="running" or not netOwn(s,true) then
            return self:cancel("The stock refit perform was not owned.")
        end
        local ok,why=inspect()
        if not ok then return self:cancel(why) end
        self.phase="performing";return true
    end
    function W:performed(owner,returned)
        if owner~=a or self.phase~="performing" or not returned then
            return self:cancel("The stock refit perform was not verified.")
        end
        self.phase,self.deadline="settling",getTimestampMs()+MIRROR_MS
        return true
    end
    function W:poll()
        if self.phase~="closed" and getTimestampMs()>=self.deadline then
            self:cancel("The refit did not settle before the receipt expired.")
        end
        if self.phase=="waiting" or self.phase=="starting" then
            if pre() then return nil end
            self:cancel("The exact bottle or refit action was not available.")
        elseif self.phase=="running" and not netOwn(s,true) then
            self:cancel("The stock refit lost native ownership.")
        elseif self.phase=="settling" and not idle(s) then
            local q,stack=s.queue,p:getCharacterActions()
            if queue(p)==q and not q.current and #q.queue==0
                and (stack:size()==0 or stack:size()==1 and stack:get(0)==s.handle) then return nil end
            self:cancel("Another action interrupted refit settlement.")
        end
        if self.phase=="closed" then return false,self.problem end
        if self.phase=="performing" then return nil end
        local ok,confirmed=inspect()
        if not ok then self:cancel(confirmed);return false,self.problem end
        if self.phase~="settling" or not confirmed then return nil end
        self.stable=self.stable or getTimestampMs()
        if getTimestampMs()-self.stable<STABLE_MS then return nil end
        self.phase="closed"
        return true,self.successor
    end
    return W
end

function M.start(p,input,jug,ops,nativeEnd)
    if enabled()~=true or not p or not input or type(ops)~="table"
        or not ops.live() or not ops.admit() then return nil end
    require "TimedActions/ISAddTakeDispenserBottle"
    local a=ISAddTakeDispenserBottle:new(p,input.object,jug)
    if not a or getmetatable(a)~=ISAddTakeDispenserBottle or a.Type~=ACTION or a.character~=p
        or a.waterdispenser~=input.object or a.square~=input.square or a.bottle~=jug then return nil end
    local s={player=p,input=input,main=p:getInventory(),queue=queue(p),action=a,ops=ops}
    if not idle(s) then return nil end
    local wait,start,stop,perform = a.waitToStart,a.start,a.stop,a.perform
    if type(wait)~="function" or type(start)~="function" or type(stop)~="function" or type(perform)~="function"
        or type(a.forceStop)~="function" then return nil end
    if jug then s.watch=refitWatch(s)
    else
        local why
        s.watch,why=Take.begin(p,a,input.object,{allow=ops.live,canAdmit=ops.admit,canUseItem=ops.useItem,
            allowEmpty=true,strictDelta=true})
        if not s.watch then return nil,why end
    end

    local function observe(method,...)
        local ok,result,why=pcall(s.watch[method],s.watch,...)
        if ok then return result,why end
        s.problem=s.problem or "The dispenser receipt could not be verified."
        s.watch:cancel(s.problem)
        return false,s.problem
    end
    local function finish(callback,...)
        if s.ended or not netOwn(s,false) then return false end
        s.ended=true
        local ok=pcall(nativeEnd,p,s,callback,a,...)
        if not ok then s.problem=s.problem or "The stock dispenser cleanup failed." end
        return ok and not s.problem
    end
    -- The same owned Java handle may remain until its Lua callback returns.
    function s:canRestore()
        return queue(p)~=self.queue or not p:getCharacterActions():contains(self.handle)
    end
    function s:cancel(reason)
        self.problem=self.problem or reason or "Refill cancelled."
        self.watch:cancel(self.problem)
        if not self.stopRequested and not self.ended and netOwn(self,false) then
            self.stopRequested=true
            a:forceStop()
            -- An unstarted native rejection does not call Lua stop.
            if not self.entered then finish(stop) end
        end
    end
    function s:poll()
        if self.restore and self:canRestore() then local restore=self.restore;self.restore=nil;restore() end
        if self.problem then self:cancel();return false,self.problem end
        if not ops.live() then self:cancel("The dispenser action was interrupted.");return false,self.problem end
        if not self.accepted then
            local status,result=observe("poll")
            if status==false then self:cancel(result);return false,self.problem end
            if status==true then self.accepted,self.acceptedAt=result,getTimestampMs() end
        end
        if self.accepted then
            if idle(self) then return true,self.accepted end
            if getTimestampMs()-self.acceptedAt>=1500 or self.queue.current or #self.queue.queue~=0 then
                self:cancel("Another action interrupted the dispenser handoff.");return false,self.problem
            end
        end
    end

    a.stopOnWalk,a.stopOnRun,a.stopOnAim=true,true,true
    function a:canMergeAction() return false end
    function a:isValid()
        if s.ended then return false end
        local status,why=observe("poll")
        if status==false and not s.entered then s:cancel(why) end
        return status~=false
    end
    function a:waitToStart()
        local ok,waiting=pcall(wait,self)
        if not ok then s:cancel("The stock dispenser could not begin waiting.");return true end
        local hold,why=observe("waitToStart",self,waiting)
        if type(hold)~="boolean" or why then s:cancel(why);return true end
        return hold
    end
    function a:start()
        s.entered=true
        if not observe("beforeStart",self) then s:cancel("The exact dispenser start was not admitted.");return end
        local ok=pcall(start,self)
        if not observe("started",self,ok) then s:cancel("The stock dispenser start failed.") end
    end
    function a:perform(...)
        local pre,why=observe("beforePerform",self)
        if not pre then s.problem=s.problem or why or "The exact dispenser perform was not verified." end
        local ok=finish(perform,...)
        observe("performed",self,ok)
    end
    function a:stop(...)
        s.problem=s.problem or "The stock dispenser action stopped."
        s.watch:cancel(s.problem)
        finish(stop,...)
    end
    function a:complete()
        s:cancel("The client cannot complete a stock dispenser action.")
        return false
    end
    ISTimedActionQueue.add(a)
    if (s.queue.current~=a or s.queue.queue[1]~=a) and not s.ended then return nil end
    return s
end

return M
