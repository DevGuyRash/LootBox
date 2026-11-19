local Loan = {}
Loan.__index = Loan
local SIP_TIMEOUT, MP_SIP_TIMEOUT, MOVE_TIMEOUT = 3000, 7000, 30000
local REPLICA_INTERVAL, MAX_ENDPOINT_ITEMS = 225, 1024
local blocked = setmetatable({}, {__mode="k"})
local function amount(fluid) return fluid:getAmount() end
local function thirst(player) return player:getStats():get(CharacterStat.THIRST) end
local function stockOn(player)
    if not isClient or not isServer or isServer() or getCore():getOptionAutoDrink() ~= true then return false end
    return not isClient() or (player:getAutoDrink() == true and type(isItemTransactionDone) == "function"
        and type(isItemTransactionRejected) == "function")
end
local function declined(player, item)
    local ids = blocked[player]
    return ids and ids[item:getID()] == true
end
local function queueFor(player) return ISTimedActionQueue.getTimedActionQueue(player) end
local function idle(player, queue)
    return not queue.current and #queue.queue == 0 and not player:hasTimedActions()
end
local function pathFrom(cont, main)
    local path, seen = {}, {}
    while cont ~= main do
        if not cont or #path >= 8 or seen[cont] then return nil end
        local bag = cont:getContainingItem()
        if not bag or bag:isFavorite() ~= false or bag:getInventory() ~= cont then return nil end
        local parent = bag:getContainer()
        if not parent or not parent:contains(bag) then return nil end
        seen[cont] = true
        path[#path + 1] = {bag=bag, parent=parent, container=cont, id=bag:getID()}
        cont = parent
    end
    return path
end

function Loan:samePath()
    if self.player:getInventory() ~= self.main then return false end
    for _, link in ipairs(self.path) do
        if link.bag:getID() ~= link.id or link.bag:isFavorite() ~= false or link.bag:getInventory() ~= link.container
            or link.bag:getContainer() ~= link.parent or not link.parent:contains(link.bag) then return false end
    end
    return true
end

function Loan:valid(phase, source)
    return self.item:getID() == self.id and self.item:getFullType() == self.fullType
        and self.item:isFavorite() == false and self.item:getContainer() == source and source:contains(self.item)
        and self.item:getFluidContainer() == self.fluid and self:samePath()
        and self.guard(self.item, self.source, phase) == true
end

local function replica(self, endpoint)
    local items = endpoint:getItems()
    local count = items:size()
    if type(count) ~= "number" or count < 0 or count > MAX_ENDPOINT_ITEMS then return nil, false end
    local found
    for index = 0, count - 1 do
        local item = items:get(index)
        if item and item:getID() == self.id then
            if found or item:getFullType() ~= self.fullType or item:getContainer() ~= endpoint
                or item:isFavorite() ~= false or not endpoint:contains(item) then return nil, false end
            found = item
        end
    end
    return found, true
end

function Loan:replicas(phase, from, to)
    if not self:samePath() then return nil, nil, false end
    local origin, validFrom = replica(self, from)
    local target, validTo = replica(self, to)
    if not validFrom or not validTo then return nil, nil, false end
    if origin and (origin ~= self.item or not self.guard(origin, self.source, phase)) then return nil, nil, false end
    if target and not self.guard(target, self.source, phase) then return nil, nil, false end
    return origin, target, true
end

function Loan:replicaCheck(phase, from, to)
    local now = getTimestampMs()
    if not self:samePath() or self.guard(self.item, self.source, "waitWater") ~= true then return false end
    if not self.nextReplicaCheck or now >= self.nextReplicaCheck then
        local _, _, valid = self:replicas(phase, from, to)
        self.nextReplicaCheck, self.replicasValid = now + REPLICA_INTERVAL, valid
    end
    return self.replicasValid == true
end

local function stockSource(self, items)
    return self.player:getWaterSource(items)
end
local function drinkable(self)
    local f = self.fluid
    return self.item:isSealed() == false and self.item:isWaterOnlySource()
        and not f:isPoisonous() and not f:isTainted() and f:canPlayerEmpty()
        and f:getProperties():getThirstChange() < 0
end

function Loan.canOffer(player, item)
    local ok, eligible = pcall(function()
        if not stockOn(player) or declined(player,item) or not item:isWaterOnlySource() then return false end
        local main = player:getInventory()
        if not main:isItemAllowed(item) or not main:hasRoomFor(player, item) then return false end
        local one = ArrayList.new()
        one:add(item)
        return player:getWaterSource(one) == item
    end)
    return ok and eligible == true
end

function Loan:transfer(from, to, phase)
    local queue = queueFor(self.player)
    if not self:valid(phase, from) or not idle(self.player, queue)
        or not to:isItemAllowed(self.item) or not to:hasRoomFor(self.player, self.item) then return false end
    if self.multiplayer then
        local origin, target, exact = self:replicas(phase, from, to)
        if not exact or origin ~= self.item or target then return false end
    end
    if phase == "outbound" and (not stockOn(self.player) or stockSource(self, self.main:getItems())
            or stockSource(self, self.candidate) ~= self.item or not drinkable(self)) then return false end
    require "TimedActions/ISInventoryTransferUtil"
    local action = ISInventoryTransferUtil.newInventoryTransferAction(self.player, self.item, from, to)
    if not action or not action.forceStop or not action.forceCancel then return false end
    -- A later, manual transfer sharing these endpoints is still a separate action.
    function action:canMergeAction() return false end
    action.stopOnWalk, action.stopOnAim, action.stopOnRun = true, true, true
    local baseValid, baseTransfer, baseStop = action.isValid, action.transferItem, action.stop
    if not baseValid or not baseTransfer or not baseStop then return false end
    local function allowed(native, item, committing)
        local q = queueFor(self.player)
        if native ~= action or self.action ~= action or native.srcContainer ~= from or native.destContainer ~= to
            or native.character ~= self.player or item ~= self.item or native.item ~= item or isServer() or isClient() ~= self.multiplayer then return false end
        if q.current ~= action then
            if committing or not idle(self.player, q) then return false end
        elseif #q.queue ~= 1 or q.queue[1] ~= action then return false end
        if self.multiplayer and self.sent and not committing then
            return getTimestampMs() < self.deadline and self:replicaCheck(phase, from, to)
        end
        return getTimestampMs() < self.deadline and self:valid(phase, from)
            and to:isItemAllowed(item) and to:hasRoomFor(self.player,item)
            and (phase ~= "outbound" or stockOn(self.player) and not stockSource(self, self.main:getItems())
                and stockSource(self, self.candidate) == item and drinkable(self))
    end
    local function checked(native, item, committing)
        local ok, can = pcall(allowed, native, item, committing)
        if not ok or not can then self.interrupted = true; return false end
        return true
    end
    action.isValid = function(native, ...)
        return checked(native, native.item) and baseValid(native, ...)
    end
    action.transferItem = function(native, item, ...)
        if not self.multiplayer and checked(native, item, true) and baseValid(native) then return baseTransfer(native, item, ...) end
    end
    if self.multiplayer then
        local baseStart, basePerform = action.start, action.perform
        if type(baseStart) ~= "function" or type(basePerform) ~= "function" then return false end
        action.start = function(native, ...)
            if not checked(native, native.item, true) or not baseValid(native) then
                native:forceStop()
                return
            end
            baseStart(native, ...)
            local id = native.transactionId
            if type(id) == "number" and id ~= 0 then
                self.sent = id
            else
                self.interrupted = true
            end
        end
        action.perform = function(native, ...)
            local id = native.transactionId
            local ack = self.sent and id == self.sent
                and isItemTransactionDone(id) and not isItemTransactionRejected(id)
            -- Stock perform clears the transaction ID. Keep its queue and cleanup
            -- intact, and require observed movement as a second independent gate.
            basePerform(native, ...)
            self.acked = ack == true
        end
    end
    action.stop = function(native)
        local q = queueFor(self.player)
        -- The engine's stock stop may reset its whole queue. Keep only the
        -- foreign tail outside that call; never start it ahead of native stop.
        if q.current ~= native then self.interrupted = true; return end
        local tail = {}
        for _, entry in ipairs(q.queue) do
            if entry ~= native then tail[#tail + 1] = entry end
        end
        for _, entry in ipairs(tail) do q:removeFromQueue(entry) end
        local ok, err = pcall(baseStop, native)
        for _, entry in ipairs(tail) do
            local present = false
            for _, queued in ipairs(q.queue) do if queued == entry then present = true end end
            if not present then q:addToQueue(entry) end
        end
        self.interrupted = true
        if not ok then error(err, 0) end
    end
    self.action, self.deadline = action, getTimestampMs() + MOVE_TIMEOUT
    self.sent, self.acked, self.stopRequested, self.nextReplicaCheck, self.nextArrivalCheck = nil, false, false, nil, nil
    ISTimedActionQueue.add(action)
    return queue.current == action or (self.item:getContainer() == to and to:contains(self.item))
end

function Loan:stopAction()
    local q, own = queueFor(self.player), self.action
    if not own then return end
    if q.current == own then
        if own.action and not self.stopRequested then
            self.stopRequested = true
            own:forceStop()
        end
    else
        for _, act in ipairs(q.queue) do
            if act == own then own:forceCancel(); q:removeFromQueue(own); break end
        end
    end
end

function Loan:finish(state, reason)
    if self.multiplayer and state ~= "finished" then
        blocked[self.player] = blocked[self.player] or {}
        blocked[self.player][self.id] = true
    end
    self.state, self.reason, self.action = state, reason, nil
end

function Loan:isBusy() return self.state == "running" end

function Loan:cancel()
    if self:isBusy() then
        self:stopAction()
        self:finish("cancelled", "Water access cancelled; check the main inventory for the bottle.")
    end
    return true
end

function Loan:step()
    local now, queue = getTimestampMs(), queueFor(self.player)
    local phase, item = self.phase, self.item
    if self.interrupted then self:cancel(); return end
    if phase == "outbound" or phase == "returning" then
        local from = phase == "outbound" and self.source or self.main
        local to = phase == "outbound" and self.main or self.source
        local arrived
        if self.multiplayer then
            if now >= self.deadline or not self:samePath()
                or self.guard(self.item, self.source, "waitWater") ~= true
                or phase == "outbound" and not stockOn(self.player) then self:cancel(); return end
            if queue.current == self.action then
                if #queue.queue ~= 1 or not self:replicaCheck(phase, from, to) then self:cancel() end
                return
            end
            if not self.acked or not idle(self.player, queue) then self:cancel(); return end
            if self.nextArrivalCheck and now < self.nextArrivalCheck then return end
            local origin, target, endpointsValid = self:replicas(phase, from, to)
            if not endpointsValid then self:cancel(); return end
            -- Done and remove/add replication are separate; do not adopt until
            -- reciprocal direct membership resolves to a single exact item.
            if origin or not target then self.nextArrivalCheck=now + REPLICA_INTERVAL; return end
            local fluid = target:getFluidContainer()
            if not fluid then self:cancel(); return end
            self.item, self.fluid, arrived = target, fluid, true
            item = target
        else
            arrived = self:valid(phase, to)
            if queue.current == self.action then
                if #queue.queue ~= 1 or now >= self.deadline
                    or phase == "outbound" and not stockOn(self.player)
                    or not arrived and not self:valid(phase, from) then self:cancel() end
                return
            end
            if not arrived or not idle(self.player, queue) then self:cancel(); return end
        end
        if phase == "returning" then
            self:finish(self.count == 1 and "finished" or "failed",
                self.count == 1 and "Vanilla auto-drank water; bottle returned." or "Vanilla did not drink; bottle returned.")
            return
        end
        self.action, self.phase, self.deadline = nil, "observe", now + (self.multiplayer and MP_SIP_TIMEOUT or SIP_TIMEOUT)
        phase = self.phase
    end
    if phase == "observe" then
        if not self:valid(phase, self.main) or not idle(self.player, queue) or not stockOn(self.player) then self:cancel(); return end
        local current = amount(self.fluid)
        local selected = stockSource(self,self.main:getItems())
        if (selected and selected ~= item) or self.fluid:isPoisonous() or self.fluid:isTainted()
            or (current > 0.00001 and not drinkable(self)) then self:cancel(); return end
        local consumed = current < self.beforeAmount - 0.00001
        if consumed and thirst(self.player) < self.beforeThirst - 0.00001 then self.count = 1 end
        if self.multiplayer then
            if self.count ~= 1 then
                if now < self.deadline then return end
                self:finish("failed", "Server hydration could not be confirmed; bottle left in the main inventory.")
                return
            end
        elseif not consumed and now < self.deadline and selected == item then return end
        if self:transfer(self.main, self.source, "return") then
            self.phase = "returning"
        else
            self:finish(self.count == 1 and "finished" or "failed", "Bottle left in the main inventory; could not safely return it.")
        end
    end
end

function Loan:tick()
    if self:isBusy() then
        local ok = pcall(self.step, self)
        if not ok then self:cancel() end
    end
end

function Loan:status()
    return {state=self.state, reason=self.reason, done=self.count, total=1, moved=0, skipped=0, reasons={},
        hasJob=self:isBusy(), canPreview=not self:isBusy(), canResume=false, canPause=false, action="consume", intent="consume:fluid"}
end

local function new(player, item, guard)
    if not stockOn(player) or declined(player,item) or type(guard) ~= "function" then return nil end
    local main, source = player:getInventory(), item:getContainer()
    if not source or source == main then return nil end
    local path = pathFrom(source, main)
    if not path then return nil end
    local loan = setmetatable({player=player, item=item, id=item:getID(), fullType=item:getFullType(), fluid=item:getFluidContainer(),
        main=main, source=source, path=path, guard=guard, multiplayer=isClient(), state="running", phase="outbound", count=0,
        deadline=getTimestampMs() + MOVE_TIMEOUT}, Loan)
    if not loan.fluid or not loan:valid("admit", source) or not drinkable(loan) then return nil end
    loan.candidate = ArrayList.new()
    loan.candidate:add(item)
    loan.beforeAmount, loan.beforeThirst = amount(loan.fluid), thirst(player)
    if type(loan.beforeAmount) ~= "number" or type(loan.beforeThirst) ~= "number" or loan.beforeThirst <= 0.1 then return nil end
    if loan:transfer(source, main, "outbound") then return loan end
end

function Loan.new(player, item, guard)
    local ok, result = pcall(new, player, item, guard)
    if ok then return result end
end

return Loan
