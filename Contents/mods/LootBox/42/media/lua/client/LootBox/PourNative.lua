local Actor = require "LootBox/PourActor"
local PourNative = {}
PourNative.__index = PourNative
local SETTLE, MOVE_MAX = 7000, 120000

local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function fluidOf(item)
    local direct=item:getContainer()
    if not direct or not direct:contains(item) then return nil end
    if direct:getType()=="floor" then
        local world=item:getWorldItem()
        if not world or world:getItem()~=item or not world:isExistInTheWorld() then return nil end
        local component=world:getFluidContainer()
        if component and component:getOwner()==world and not component:isMultiTileMoveable() then
            return component,world
        end
        return nil
    end
    return item:getFluidContainer(),item
end

-- One stock-rounded amount for both menu previews and action admission.
function PourNative.transferAmount(have, free, requested)
    if not finite(have) or not finite(free) or (requested ~= nil and not finite(requested)) then
        return nil, "Fluid amounts are unavailable."
    end
    local wanted=math.min(have,free,requested or math.huge)
    local rounded=FluidUtil.roundTransfer(wanted)
    if not finite(rounded) then return nil, "The game did not provide a transfer amount." end
    local amount=math.min(wanted,rounded)
    if amount<=0 then return nil, "No fluid or free vessel space remains." end
    return amount
end

local function inspect(source, target, requested)
    if not source or not target or source == target or source:getID() == target:getID() then return nil, "Choose two different vessels." end
    local a, aOwner = fluidOf(source)
    local b, bOwner = fluidOf(target)
    if not a or not b or a == b or a:getOwner() ~= aOwner or b:getOwner() ~= bOwner
        or not a:canPlayerEmpty() or not b:canPlayerEmpty()
        or not FluidContainer.CanTransfer(a,b) then return nil, "The game does not allow pouring between these vessels." end
    local have, before, free = a:getAmount(), b:getAmount(), b:getFreeCapacity()
    if not finite(before) then return nil, "Fluid amounts are unavailable." end
    local amount,reason=PourNative.transferAmount(have,free,requested)
    if not amount then return nil,reason end
    return {sourceFluid=a,targetFluid=b,sourceOwner=aOwner,targetOwner=bOwner,
        amount=amount, sourceBefore=have, targetBefore=before}, nil
end

function PourNative.inspect(source, target, requested)
    local ok, result, reason = pcall(inspect,source,target,requested)
    if not ok then return nil, "The game did not expose this fluid transfer." end
    return result,reason
end

local function queueFor(player) return ISTimedActionQueue.getTimedActionQueue(player) end
local function emptyQueue(player,q) return not q.current and #q.queue == 0 and not player:hasTimedActions() end
-- In SP the engine calls Lua perform (which drains the Lua queue), then
-- complete, then removes the completed Java action from the character stack.
-- Only the very same Java handle may remain for that synchronous callback.
local function finishingQueue(player,q,s)
    if q.current or #q.queue ~= 0 or s.deferredTail then return false end
    if not player:hasTimedActions() then return true end
    local actions=player:getCharacterActions()
    local owned=s.action.action
    return owned~=nil and actions~=nil and actions:size()==1 and actions:get(0)==owned
end
local function member(q, action)
    for _, entry in ipairs(q.queue) do if entry == action then return true end end
    return false
end
local function restoreTail(s,player)
    local pending=s.deferredTail
    if not pending or getTimestampMs() <= pending.at then return end
    local q=queueFor(player)
    if q ~= pending.queue then s.deferredTail=nil; return end
    if q.current and #q.queue > 0 then
        local position=2
        for _,entry in ipairs(pending.items) do
            if not member(q,entry) then table.insert(q.queue,position,entry); position=position+1 end
        end
    elseif #q.queue == 0 then
        for _,entry in ipairs(pending.items) do
            if not member(q,entry) then q:addToQueue(entry) end
        end
    else
        return
    end
    s.deferredTail=nil
end

local function deferTail(s,player,q,tail)
    s.deferredTail={queue=q,items=tail,at=getTimestampMs()}
    -- The old native action owns this tick. Starting a foreign action in its
    -- perform callback would also run it before the SP complete callback.
    if Events and Events.OnTick then
        local callback
        callback=function()
            restoreTail(s,player)
            if not s.deferredTail then Events.OnTick.Remove(callback) end
        end
        Events.OnTick.Add(callback)
    end
end

local function address(player, item, owner)
    if owner ~= item then
        local square, here = owner:getSquare(), player:getSquare()
        if owner ~= item:getWorldItem() or owner:getItem() ~= item or not owner:isExistInTheWorld()
            or not square or not here or square:getZ() ~= here:getZ()
            or math.abs(square:getX()-here:getX()) > 1 or math.abs(square:getY()-here:getY()) > 1
            or (square ~= here and here:isBlockedTo(square)) then return nil end
        return {square}
    end
    local direct, main = item:getContainer(), player:getInventory()
    if not direct or not main or not direct:contains(item) then return nil end
    local seen, path, child = {}, {}, item
    for _ = 1, 9 do
        if not direct or seen[direct] or not direct:contains(child) then return nil end
        path[#path+1]=direct
        if direct == main then return path end
        seen[direct] = true
        child = direct:getContainingItem()
        if not child or child:getInventory() ~= direct then return nil end
        direct = child:getContainer()
    end
end

local function sameAddress(a,b)
    if not a or not b or #a ~= #b then return false end
    for index=1,#a do if a[index] ~= b[index] then return false end end
    return true
end

local function actorSafe(player)
    return not Actor.blocked(player)
end

local function livePair(self,s, phase)
    if isServer() or isClient() ~= s.mp or not self.player:isLocalPlayer()
        or self.player:isDead() or self.player:isAsleep() or not actorSafe(self.player) then return nil end
    if s.source:getID() ~= s.sourceID or s.target:getID() ~= s.targetID
        or s.source:getFullType() ~= s.sourceType or s.target:getFullType() ~= s.targetType then return nil end
    local a,aOwner = fluidOf(s.source)
    local b,bOwner = fluidOf(s.target)
    if not a or not b or a == b or aOwner ~= s.sourceOwner or bOwner ~= s.targetOwner
        or a:getOwner() ~= aOwner or b:getOwner() ~= bOwner then return nil end
    if phase ~= "observe" and (a ~= s.sourceFluid or b ~= s.targetFluid) then return nil end
    if not sameAddress(address(self.player,s.source,aOwner),s.sourceAddress)
        or not sameAddress(address(self.player,s.target,bOwner),s.targetAddress) then return nil end
    if s.validate and s.validate(s.source,s.target,phase) ~= true then return nil end
    return a,b
end

local function closeEnough(s,a,b)
    return finite(a) and finite(b) and math.abs(a-b) <= s.epsilon
end

local function quantities(s,a,b)
    local loss, gain = s.sourceBefore-a:getAmount(), b:getAmount()-s.targetBefore
    if not finite(loss) or not finite(gain) or loss < -s.epsilon or gain < -s.epsilon
        or loss > s.amount+s.epsilon or gain > s.amount+s.epsilon then return nil end
    return loss,gain
end

local function paired(s,loss,gain)
    if loss and loss > 0 and gain > 0 and closeEnough(s,loss,gain) then return math.min(loss,gain) end
end

local function protected(self,s,phase)
    local ok,a,b = pcall(livePair,self,s,phase)
    if ok then return a,b end
end

function PourNative.new(player)
    return setmetatable({player=player},PourNative)
end

function PourNative:isBusy() return self.active ~= nil end

function PourNative:start(source,target,requested,validate,allowProjectedEndpoint)
    if self.active then return nil,"A fluid transfer is already active." end
    local s, reason = PourNative.inspect(source,target,requested)
    if not s then return nil,reason end
    local player, q = self.player,queueFor(self.player)
    if isServer() or not emptyQueue(player,q) then return nil,"Finish the current action before pouring." end
    s.source,s.target,s.validate,s.mp=source,target,validate,isClient()
    s.epsilon = math.min(s.amount*.15, math.max(.000001, math.max(s.sourceBefore,s.targetBefore,s.amount)*.0000002))
    s.lastLoss,s.lastGain=0,0
    s.sourceID,s.targetID,s.sourceType,s.targetType=source:getID(),target:getID(),source:getFullType(),target:getFullType()
    local ok, started = pcall(function()
        s.sourceAddress=address(player,source,s.sourceOwner)
        s.targetAddress=address(player,target,s.targetOwner)
        if not s.sourceAddress or not s.targetAddress or (s.sourceOwner ~= source and s.targetOwner ~= target)
            or not protected(self,s,"admit") then return false end
        require "Fluids/ISFluidContainer"
        require "Fluids/ISFluidUtil"
        require "Fluids/ISFluidTransferAction"
        local a,b=ISFluidContainer:new(s.sourceFluid),ISFluidContainer:new(s.targetFluid)
        local action=ISFluidTransferAction:new(player,a,a:getFluidObject(),b,b:getFluidObject(),s.amount)
        if not action or not action.isValid or not action.update or not action.complete
            or not action.perform or not action.stop or not action.forceStop or not action.waitToStart then return false end
        s.action=action
        local valid,update,complete,perform,stop=action.isValid,action.update,action.complete,action.perform,action.stop
        local function allowed(phase)
            if s.reason then return false end
            -- Before native submission, recheck original amount and both mixtures.
            local src,dst=protected(self,s,phase=="active" and not s.preflight and "admit" or phase)
            if not src or not dst then return false end
            local queue=queueFor(player)
            if queue.current == action then
                if #queue.queue ~= 1 or queue.queue[1] ~= action then return false end
            elseif not ((phase == "admit" and emptyQueue(player,queue))
                or (phase == "complete" and not s.mp and s.performed and finishingQueue(player,queue,s))) then return false end
            local loss,gain=quantities(s,src,dst)
            if not loss then return false end
            if phase == "admit" or not s.preflight then
                if not closeEnough(s,loss,0) or not closeEnough(s,gain,0) then return false end
            elseif s.mp then
                if loss+s.epsilon < s.lastLoss or gain+s.epsilon < s.lastGain then return false end
                s.lastLoss,s.lastGain=loss,gain
            elseif not closeEnough(s,loss,s.lastLoss) or not closeEnough(s,gain,s.lastGain) then
                return false
            end
            local total=paired(s,loss,gain)
            local finished=total and closeEnough(s,total,s.amount)
            if not finished and (not src:canPlayerEmpty() or not dst:canPlayerEmpty()) then return false end
            if total then s.latestPaired=total end
            -- The two stock MP fluid mirrors can arrive separately. A
            -- terminal side makes native CanTransfer false even though the
            -- server is completing our exact, already-admitted pour.
            local endpointPending = allowProjectedEndpoint and s.mp and s.preflight
                and phase=="active" and not finished
                and ((closeEnough(s,loss,s.amount) and closeEnough(s,src:getAmount(),0))
                    or (closeEnough(s,gain,s.amount) and closeEnough(s,dst:getFreeCapacity(),0)))
            return true,finished,endpointPending
        end
        local wait=action.waitToStart
        action.stopOnWalk,action.stopOnRun,action.stopOnAim=true,true,true
        function action:canMergeAction() return false end
        function action:isValid()
            local good,finished,endpointPending=allowed(member(queueFor(player),action) and "active" or "admit")
            return good and (finished or endpointPending or valid(self))
        end
        function action:waitToStart()
            local good=allowed("active")
            if not good or not valid(self) then
                s.reason="Fluid transfer was interrupted before it could start."
                self:forceStop()
                -- Java checks waitToStart before creating the stock MP request.
                return true
            end
            local waiting=wait(self)
            if not waiting then s.preflight=true end
            return waiting
        end
        local function afterNative()
            local src,dst=protected(self,s,"active")
            if not src then return end
            local loss,gain=quantities(s,src,dst)
            if loss and (paired(s,loss,gain) or closeEnough(s,loss,0) and closeEnough(s,gain,0)) then
                s.lastLoss,s.lastGain=loss,gain
                s.latestPaired=paired(s,loss,gain) or s.latestPaired
            else s.reason="Fluid amounts changed outside the native pour." end
        end
        function action:update()
            local good,finished,endpointPending=allowed("active")
            if not good or not s.preflight then s.reason="Fluid transfer interrupted."; self:forceStop(); return end
            if finished or endpointPending then return end
            update(self)
            if not s.mp then afterNative() end
        end
        function action:complete()
            if s.mp then return true end
            local good,finished=allowed("complete")
            if not good or not s.preflight then s.reason="Fluid transfer interrupted."; return false end
            if finished then return true end
            if not valid(self) then s.reason="The game stopped accepting this fluid pair."; return false end
            local result=complete(self)
            afterNative()
            return result
        end
        function action:perform()
            local queue=queueFor(player)
            if queue.current ~= self then
                s.reason=s.reason or "Fluid transfer was no longer current."
                return
            end
            if s.preflight and allowed("active") then s.performed=true; s.performAt=getTimestampMs()
            else s.reason=s.reason or "Fluid transfer interrupted." end
            local foreign={}
            for _,entry in ipairs(queue.queue) do
                if entry ~= self then foreign[#foreign+1]=entry end
            end
            if #foreign==0 then return perform(self) end
            for _,entry in ipairs(foreign) do queue:removeFromQueue(entry) end
            local ok,result=pcall(perform,self)
            deferTail(s,player,queue,foreign)
            if not ok then error(result,0) end
            return result
        end
        function action:stop()
            s.reason=s.reason or "Fluid transfer was interrupted."
            local queue=queueFor(player)
            if queue.current ~= action then return end
            local foreign={}
            for _,entry in ipairs(queue.queue) do
                if entry ~= action then foreign[#foreign+1]=entry end
            end
            for _,entry in ipairs(foreign) do queue:removeFromQueue(entry) end
            local stopped,err=pcall(stop,self)
            for _,entry in ipairs(foreign) do
                if not member(queue,entry) then queue:addToQueue(entry) end
            end
            if not stopped then error(err,0) end
        end
        if not action:isValid() then return false end
        local duration=finite(action.maxTime) and math.max(0,action.maxTime) or 0
        s.deadline=getTimestampMs()+math.min(MOVE_MAX,math.max(30000, duration*120))
        self.active=s
        ISTimedActionQueue.add(action)
        return member(q,action) or s.performed
    end)
    if not ok or not started then self.active=nil; return nil,"The stock fluid action could not start." end
    return true,nil,s.amount
end

function PourNative:cancel()
    local s=self.active
    if not s or s.reason then return true end
    s.reason="Fluid transfer cancelled."
    local q=queueFor(self.player)
    if q.current == s.action and s.action.action then
        s.action:forceStop()
    elseif member(q,s.action) and q.current ~= s.action then
        q:removeFromQueue(s.action)
    end
    return true
end

function PourNative:poll()
    local s=self.active
    if not s then return false,"No fluid transfer is active.",0 end
    local now,q=getTimestampMs(),queueFor(self.player)
    if s.deferredTail then
        restoreTail(s,self.player)
        if s.deferredTail then return nil end
    end
    if member(q,s.action) then
        if not s.reason and (now >= s.deadline or #q.queue ~= 1 or not protected(self,s,"active")) then self:cancel() end
        return nil
    end
    if s.reason or not s.performed or not emptyQueue(self.player,q) then
        self.active=nil
        return false,s.reason or "Fluid transfer was interrupted.",s.latestPaired or 0
    end
    local a,b=protected(self,s,"observe")
    if not a or not b then self.active=nil; return false,"The exact vessels are no longer available.",0 end
    local loss,gain=quantities(s,a,b)
    local observed=paired(s,loss,gain)
    if not loss or loss+s.epsilon < s.lastLoss or gain+s.epsilon < s.lastGain then
        self.active=nil
        return false,"Vessel amounts changed outside the native pour.",s.latestPaired or 0
    end
    if now <= s.performAt+SETTLE and observed and closeEnough(s,observed,s.amount) then
        self.active=nil
        return true,nil,observed
    end
    if now < s.performAt+SETTLE then
        s.lastLoss,s.lastGain=loss,gain
        s.latestPaired=observed or s.latestPaired
        return nil
    end
    self.active=nil
    return false,(s.latestPaired and "The game poured only part of the requested amount."
        or "The game did not confirm matching fluid changes in both vessels."),s.latestPaired or 0
end

return PourNative
