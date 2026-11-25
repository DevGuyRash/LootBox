local Actor = require "LootBox/PourActor"
local Log = require "LootBox/Log"
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
    return not isServer() and not Actor.blocked(player)
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
    if s.problem or isClient() ~= s.multiplayer or not safe(s.player) then
        return false, "player: " .. tostring(s.problem or Actor.blocked(s.player))
    end
    local granted, check = s.guard(phase, s.item, s.from, s.to)
    return granted == true, check or "caller-guard"
end

local function admit(s, strict)
    local granted, check = permitted(s, "admit")
    if not granted then return false, check end
    if s.item:getContainer() ~= s.from or not s.from:contains(s.item) then return false, "item-not-in-source" end
    if not s.to:isItemAllowed(s.item) then return false, "destination-rejects-item" end
    if not s.to:hasRoomFor(s.player,s.item) then return false, "no-room" end
    if not strict then return true end
    local source, arrival, exact = endpoints(s)
    return exact and source == s.item and not arrival, "ambiguous-identity"
end

local function acknowledged(id)
    return isItemTransactionDone(id) == true and isItemTransactionRejected(id) == false
end

local function checked(fn, ...)
    local ok, result, why = pcall(fn,...)
    if not ok then Log.fault(nil,"PourMove.check",result) end
    return ok and result == true, why
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

function Move.new(player,interaction) return setmetatable({player=player,interaction=interaction},Move) end
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
        if s.sent then
            if commit then return false, "already-sent" end
            return permitted(s,"wait")
        end
        return admit(s,commit == true)
    end
    local function checkedStock(self, check, ...)
        local allowed, why = checked(allow,self)
        if not allowed then
            s.validationReason, s.check = "The local inventory-move safety check changed.", why
            return false
        end
        local accepted = check(self,...)
        s.validationReason = not accepted and "The game's inventory-move validation failed." or nil
        return accepted
    end
    function action:isValidStart(...)
        return checkedStock(self,validStart,...)
    end
    function action:isValid(...)
        return checkedStock(self,valid,...)
    end
    function action:start(...)
        local allowed, why = checked(allow,self,true)
        if not allowed or not valid(self) then
            s.check = not allowed and why or "stock-isValid"
            s.problem = "Native movement lost its source, capacity or queue"
            self:forceStop()
            return
        end
        s.startInvoked = true
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
        -- Stock stop discards the native transaction. Capture the native
        -- receipt first without changing its validation, submission or cleanup.
        if s.sent and self.transactionId == s.sent then
            s.serverRejected = s.serverRejected or checked(isItemTransactionRejected,s.sent)
        end
        s.problem = s.problem or (s.serverRejected and "The server rejected the inventory move."
            or s.validationReason or "The native inventory move stopped without a confirmed result.")
        if ISTimedActionQueue.getTimedActionQueue(s.player).current == self then
            return preserving(s,stopAction,self,...)
        end
    end
    return true
end

local function start(self,item,from,to,guard)
    if self.active then return nil,"Native movement already active" end
    local player = self.player
    if not safe(player) then return nil,"Unsupported or unsafe native movement","player: "..tostring(Actor.blocked(player)) end
    if type(guard) ~= "function" or not item or not from or not to or from == to
        or not from:getType() or not to:getType() or from:getType() == "floor" or to:getType() == "floor" then
        return nil,"Unsupported or unsafe native movement","endpoints"
    end
    if item:getContainer() ~= from or (item.getWorldItem and item:getWorldItem()) then
        return nil,"Unsupported or unsafe native movement","item-not-in-source"
    end
    if (player.isEquipped and player:isEquipped(item)) or (player.isAttachedItem and player:isAttachedItem(item))
        or (item.isWorn and item:isWorn()) then return nil,"Unsupported or unsafe native movement","item-equipped" end
    local q = ISTimedActionQueue.getTimedActionQueue(player)
    if q.current or #q.queue ~= 0 or player:hasTimedActions() then
        return nil,"Finish the current player action first","queue-busy"
    end
    local s = {player=player,item=item,from=from,to=to,guard=guard,id=item:getID(),fullType=item:getFullType(),
        multiplayer=isClient(),deadline=getTimestampMs()+TIMEOUT}
    if type(s.id) ~= "number" or type(s.fullType) ~= "string"
        or (s.multiplayer and (type(isItemTransactionDone) ~= "function" or type(isItemTransactionRejected) ~= "function")) then
        return nil,"The exact native movement is unavailable","bindings"
    end
    local admitted, check = admit(s,true)
    if not admitted then return nil,"The exact native movement is unavailable",check end
    if not install(s) then return nil,"The exact native movement is unavailable","stock-action-shape" end
    self.active = s
    s.startedAt = getTimestampMs()
    Log.trace(self.interaction,"OP","op","move","item",Log.item(item,player),
        "from",Log.container(from,player),"to",Log.container(to,player))
    ISTimedActionQueue.add(s.action)
    local _, own = status(s)
    if own or s.performed then return true end
    self.active = nil
    return nil,s.problem or "The game did not admit the native movement"
end

function Move:start(item,from,to,guard)
    local current = self.active
    local ok, result, reason, check = pcall(start,self,item,from,to,guard)
    if ok then
        if not result then
            Log.warn(self.interaction,"REFUSED","op","move","check",check or "not-queued","reason",reason,
                "item",Log.item(item,self.player),"from",Log.container(from,self.player),"to",Log.container(to,self.player),
                "player",Log.player(self.player))
        end
        return result,reason
    end
    Log.fault(self.interaction,"PourMove.start",result)
    if self.active and self.active ~= current then self:cancel() end
    return nil,"Native movement could not start"
end

-- A refused move is not evidence of where the item ended up. Only claim it
-- stayed at the from endpoint when a server request was ruled out or explicitly
-- rejected and both endpoints show the exact original reference there alone.
local function stayed(s)
    if s.multiplayer and s.startInvoked and not s.serverRejected then return nil end
    local from, to, exact = endpoints(s)
    if exact and from == s.item and not to then return from end
end

local function poll(self)
    local s = self.active
    if not s then return false,"No native movement is active" end
    local function finish(ok,reason,item,retained)
        self.active = nil
        local emit = ok and Log.trace or Log.warn
        emit(self.interaction,"OP-END","op","move","ok",ok,"check",not ok and s.check or nil,"reason",reason,"elapsedMs",getTimestampMs()-s.startedAt,
            "performed",s.performed == true,"transaction",s.sent,"acknowledged",s.ack,"serverRejected",s.serverRejected,
            "item",Log.item(item or s.item,self.player),"stayedInSource",retained ~= nil,
            "to",Log.container(s.to,self.player),"player",not ok and Log.player(self.player) or nil)
        return ok,reason,item,retained
    end
    local _,own,foreign = status(s)
    local now = getTimestampMs()
    local allowed, why = checked(permitted,s,(s.sent or s.performed) and "wait" or "admit")
    if foreign or not allowed then
        s.check = s.check or foreign and "foreign-action-queued" or why
        s.problem = s.problem or "Native movement interrupted"
    end
    if now >= s.deadline then s.problem = s.problem or "Native movement was not confirmed in time" end
    if s.problem then
        if own then stop(s); return nil end
        return finish(false,s.problem,nil,stayed(s))
    end
    if own then return nil end
    if not s.performed or not s.ack then return finish(false,"No successful native movement transaction",nil,stayed(s)) end
    if s.nextSample and now < s.nextSample then return nil end
    s.nextSample = now+SAMPLE
    local source,arrival,exact = endpoints(s)
    if not exact then return finish(false,"Ambiguous native movement identity") end
    if not source and arrival and (s.multiplayer or arrival == s.item) then return finish(true,nil,arrival) end
    return nil
end

function Move:poll()
    local ok, result, reason, item, retained = pcall(poll,self)
    if ok then return result,reason,item,retained end
    Log.fault(self.interaction,"PourMove.poll",result)
    if self.active then
        self:cancel()
        local _,own = status(self.active)
        if own then return nil end
        self.active = nil
    end
    return false,"Native movement could not be verified"
end

return Move
