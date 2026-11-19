require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISInventoryTransferUtil"

local Move = {}
Move.__index = Move
local TIMEOUT, SAMPLE, MAX_ITEMS = 30000, 125, 4096

local function endpoint(container, id, fullType)
    local items = container:getItems()
    if items:size() > MAX_ITEMS then return nil, false end
    local match
    for i = 0, items:size()-1 do
        local item = items:get(i)
        if not item then return nil, false end
        if item:getID() == id then
            if match or item:getFullType() ~= fullType or item:getContainer() ~= container then return nil, false end
            match = item
        end
    end
    return match, true
end

local function endpoints(s)
    local source, sourceOK = endpoint(s.from, s.id, s.fullType)
    local arrival, arrivalOK = endpoint(s.to, s.id, s.fullType)
    -- MP Add and Remove are separate replica updates; either may arrive first.
    -- Only duplicate IDs inside a single endpoint (or mismatched type/owner)
    -- are inherently ambiguous. Cross-endpoint overlap has not settled yet.
    return source, arrival, sourceOK and arrivalOK
end

local function safe(player)
    return not isServer() and not player:isDead() and not player:isAsleep() and not player:isMoving()
        and not player:isRunning() and not player:isSprinting() and not player:isAiming()
        and not player:isAttacking()
end

local function status(s)
    local q = ISTimedActionQueue.getTimedActionQueue(s.player)
    local own, unrelated = q.current == s.action, q.current ~= nil and q.current ~= s.action
    for _, action in ipairs(q.queue) do
        if action == s.action then own = true else unrelated = true end
    end
    return q, own, unrelated
end

local function permitted(s, phase)
    return not s.problem and isClient() == s.multiplayer and safe(s.player)
        and s.guard(phase, s.item, s.from, s.to) == true
end

local function admit(s, strict)
    if not permitted(s, "admit") or s.item:getContainer() ~= s.from or not s.from:contains(s.item)
        or not s.to:isItemAllowed(s.item) or not s.to:hasRoomFor(s.player,s.item) then return false end
    if not strict then return true end
    local source, arrival, exact = endpoints(s)
    return exact and source == s.item and not arrival
end

local function acknowledged(id)
    return isItemTransactionDone(id) == true and isItemTransactionRejected(id) == false
end

local function checked(fn, ...)
    local ok, result = pcall(fn,...)
    return ok and result == true
end

-- Stock stop/perform may reset the Lua queue. Keep existing foreign actions
-- out of that reset, then put them back unchanged in their original order.
local function preserving(s, fn, action, ...)
    local q, _, foreign = status(s)
    if not foreign or q.current ~= action then return fn(action,...) end
    local tail = {}
    for _, queued in ipairs(q.queue) do if queued ~= action then tail[#tail+1] = queued end end
    for _, queued in ipairs(tail) do q:removeFromQueue(queued) end
    local ok, result = pcall(fn,action,...)
    for _, queued in ipairs(tail) do
        local present = false
        for _, candidate in ipairs(q.queue) do if candidate == queued then present = true end end
        if not present then q:addToQueue(queued) end
    end
    if not ok then error(result,0) end
    return result
end

function Move.new(player) return setmetatable({player=player},Move) end
function Move:isBusy() return self.active ~= nil end

local function stop(s)
    local q, own = status(s)
    if not own then return end
    if q.current == s.action then
        if s.action.action and not s.stopRequested then
            s.stopRequested = true
            s.action:forceStop()
        end
    else
        s.action:forceCancel()
        q:removeFromQueue(s.action)
    end
end

function Move:cancel()
    if self.active then
        self.active.problem = self.active.problem or "Native movement cancelled"
        stop(self.active)
    end
    return true
end

local function install(s)
    local action = ISInventoryTransferUtil.newInventoryTransferAction(s.player,s.item,s.from,s.to)
    if not action or action.Type ~= "ISInventoryTransferAction" or action.character ~= s.player
        or action.item ~= s.item or action.srcContainer ~= s.from or action.destContainer ~= s.to then return false end
    local valid, validStart, begin, perform, stopAction, transfer = action.isValid, action.isValidStart,
        action.start, action.perform, action.stop, action.transferItem
    if type(valid) ~= "function" or type(validStart) ~= "function" or type(begin) ~= "function"
        or type(perform) ~= "function" or type(stopAction) ~= "function" or type(transfer) ~= "function"
        or type(action.forceStop) ~= "function" or type(action.forceCancel) ~= "function" then return false end
    s.action = action
    action.stopOnWalk, action.stopOnRun, action.stopOnAim = true,true,true
    function action:canMergeAction() return false end
    local function allow(self, commit)
        local q, _, foreign = status(s)
        if self ~= action or self.item ~= s.item or self.srcContainer ~= s.from or self.destContainer ~= s.to
            or self.character ~= s.player or foreign or (commit and q.current ~= self) or getTimestampMs() >= s.deadline then return false end
        if s.sent then return not commit and permitted(s,"wait") end
        return admit(s,commit == true)
    end
    function action:isValidStart(...)
        return checked(allow,self) and validStart(self,...)
    end
    function action:isValid(...)
        if s.sent then return checked(allow,self) end
        return checked(allow,self) and valid(self,...)
    end
    function action:start(...)
        if not checked(allow,self,true) or not valid(self) then
            s.problem = "Native movement lost its source, capacity or queue"
            self:forceStop()
            return
        end
        local value = begin(self,...)
        if s.multiplayer then
            local id = self.transactionId
            if type(id) == "number" and id ~= 0 then s.sent = id
            else s.problem = "Native movement was not submitted" end
        end
        return value
    end
    function action:transferItem(item,...)
        if not s.multiplayer and item == s.item and checked(allow,self,true) and valid(self) then
            return transfer(self,item,...)
        end
    end
    function action:perform(...)
        local _,_,foreign = status(s)
        local ack = not s.multiplayer or (s.sent and self.transactionId == s.sent
            and checked(acknowledged,s.sent))
        if foreign then s.problem = s.problem or "Another player action entered the queue" end
        if ISTimedActionQueue.getTimedActionQueue(s.player).current ~= self then
            s.problem = s.problem or "The native movement is no longer the current action"
            return
        end
        local value = preserving(s,perform,self,...)
        s.performed, s.ack = true, ack == true
        return value
    end
    function action:stop(...)
        s.problem = s.problem or "Native movement stopped or was rejected"
        if ISTimedActionQueue.getTimedActionQueue(s.player).current == self then
            return preserving(s,stopAction,self,...)
        end
    end
    return true
end

local function start(self,item,from,to,guard)
    if self.active then return nil,"Native movement already active" end
    local player = self.player
    if not safe(player) or type(guard) ~= "function" or not item or not from or not to or from == to
        or not from:getType() or not to:getType() or from:getType() == "floor" or to:getType() == "floor"
        or item:getContainer() ~= from or (item.getWorldItem and item:getWorldItem())
        or (player.isEquipped and player:isEquipped(item))
        or (player.isAttachedItem and player:isAttachedItem(item))
        or (item.isWorn and item:isWorn()) then return nil,"Unsupported or unsafe native movement" end
    local q = ISTimedActionQueue.getTimedActionQueue(player)
    if q.current or #q.queue ~= 0 or player:hasTimedActions() then return nil,"Finish the current player action first" end
    local s = {player=player,item=item,from=from,to=to,guard=guard,id=item:getID(),fullType=item:getFullType(),
        multiplayer=isClient(),deadline=getTimestampMs()+TIMEOUT}
    if type(s.id) ~= "number" or type(s.fullType) ~= "string"
        or (s.multiplayer and (type(isItemTransactionDone) ~= "function" or type(isItemTransactionRejected) ~= "function"))
        or not admit(s,true) or not install(s) then
        return nil,"The exact native movement is unavailable"
    end
    self.active = s
    ISTimedActionQueue.add(s.action)
    local _, own = status(s)
    if own or s.performed then return true end
    self.active = nil
    return nil,s.problem or "The game did not admit the native movement"
end

function Move:start(item,from,to,guard)
    local current = self.active
    local ok, result, reason = pcall(start,self,item,from,to,guard)
    if ok then return result,reason end
    if self.active and self.active ~= current then self:cancel() end
    return nil,"Native movement could not start"
end

local function poll(self)
    local s = self.active
    if not s then return false,"No native movement is active" end
    local function finish(ok,reason,item)
        self.active = nil
        return ok,reason,item
    end
    local _,own,foreign = status(s)
    local now = getTimestampMs()
    if foreign or not checked(permitted,s,(s.sent or s.performed) and "wait" or "admit") then
        s.problem = s.problem or "Native movement interrupted"
    end
    if now >= s.deadline then s.problem = s.problem or "Native movement was not confirmed in time" end
    if s.problem then
        if own then stop(s); return nil end
        return finish(false,s.problem)
    end
    if own then return nil end
    if not s.performed or not s.ack then return finish(false,"No successful native movement transaction") end
    if s.nextSample and now < s.nextSample then return nil end
    s.nextSample = now+SAMPLE
    local source,arrival,exact = endpoints(s)
    if not exact then return finish(false,"Ambiguous native movement identity") end
    if not source and arrival and (s.multiplayer or arrival == s.item) then return finish(true,nil,arrival) end
    return nil
end

function Move:poll()
    local ok, result, reason, item = pcall(poll,self)
    if ok then return result,reason,item end
    if self.active then
        self:cancel()
        local _,own = status(self.active)
        if own then return nil end
        self.active = nil
    end
    return false,"Native movement could not be verified"
end

return Move
