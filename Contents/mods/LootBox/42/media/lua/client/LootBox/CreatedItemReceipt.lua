-- One ownership + destination boundary for stock actions that create an item.
-- A fresh matching ID is not itself an identity receipt.
local Log = require "LootBox/Log"
local Receipt = {}
Receipt.__index = Receipt
local MAX_ITEMS, TIMEOUT = 4096, 7000
local MAX_DEPTH, MAX_CONTAINERS = 8, 64
local SETTLE_MS, ACTION_MS = 350, 120000

local function integer(value)
    return type(value) == "number" and math.abs(value) < math.huge and value == math.floor(value)
end

-- The exact proof paths still read the direct receiver only. Correlation
-- also needs every carried ID: a pre-existing item can be in a nested bag.
local function readInventory(inventory, cap, nested)
    local byId, holders = {}, nested and {} or nil
    local seen, total, containers = {}, 0, 0
    local function read(holder, depth)
        if seen[holder] or depth > MAX_DEPTH or containers >= MAX_CONTAINERS then
            return nil, "The carried inventory tree is ambiguous or too large"
        end
        seen[holder], containers = true, containers + 1
        local rows = holder:getItems()
        local n = rows:size()
        if not integer(n) or n < 0 or n > cap - total then
            return nil, "Cannot verify this many receiving items"
        end
        total = total + n
        for i = 0, n - 1 do
            local item = rows:get(i)
            local id = item and item:getID()
            if not integer(id) or byId[id] or item:getContainer() ~= holder then
                return nil, "The receiving inventory has ambiguous item identity"
            end
            byId[id] = item
            if nested then
                holders[id] = holder
                local getter = item.getInventory
                local child = getter and getter(item)
                if child then
                    if child:getContainingItem() ~= item then return nil, "A carried container changed ownership" end
                    local ok, reason = read(child, depth + 1)
                    if not ok then return nil, reason end
                elseif instanceof and instanceof(item, "InventoryContainer") then
                    return nil, "A carried container could not be inspected"
                end
            end
        end
        return true
    end
    local ok, reason = read(inventory, 0)
    if not ok then return nil, reason end
    return byId, nil, holders
end

-- Reuse exactly the same bounded carried-tree read for exact retirement
-- checks. A nil item without a problem only means absence from this tree.
function Receipt.findCarried(inventory,id)
    if not inventory or not integer(id) then return nil,"The carried ID could not be inspected" end
    local ok,rows,reason,holders=pcall(function()
        if inventory:getContainingItem()~=nil then return nil,"The receiving inventory is not an independent root" end
        return readInventory(inventory,MAX_ITEMS,true)
    end)
    if not ok then Log.fault(nil,"CreatedItemReceipt.findCarried",rows) end
    if not ok or not rows then return nil,ok and reason or "The carried tree could not be inspected" end
    return rows[id],nil,holders[id]
end

local function currentTime(self)
    local now = self.clock()
    if not integer(now) or now < self.lastClock then error("The receipt clock changed") end
    self.lastClock = now
    return now
end

local function sample(self)
    if self.inventory() ~= self.destination then return nil, "The receiving inventory changed" end
    if self.correlation and self.destination:getContainingItem() ~= nil then
        return nil, "The receiving inventory is not an independent root"
    end
    local rows, reason, holders = readInventory(self.destination, self.maxItems, self.correlation ~= nil)
    if not rows then return nil, reason end
    if self.maxMatches then
        local n = 0
        for _, item in pairs(rows) do
            if self.matches(item) == true then n = n + 1 end
            if n > self.maxMatches then return nil, "Cannot verify this many matching receiving items" end
        end
    end
    if not self.correlation and self.preserveMatching and self.baseline then
        for id, original in pairs(self.baseline) do
            if original ~= true and (rows[id] ~= original or self.matches(original) ~= true) then
                return nil, "A pre-existing matching item did not retain its exact inventory identity"
            end
        end
    end
    return rows, nil, holders
end

local function inspection(self, unguarded, ...)
    local ok, value, reason, extra = pcall(unguarded, self, ...)
    if not ok then
        Log.fault(nil, "CreatedItemReceipt", value)
        return nil, "The native creation receipt could not be verified"
    end
    return value, reason, extra
end

-- A producer may declare a bounded set of distinct one-item companion roles.
-- All additions remain forbidden except the single usable output and those
-- exact roles. Classify on possible type first, then validate the value:
-- an unsafe or duplicate object must still count against the receipt.
local function companionRules(mode)
    if mode.companions==nil and mode.companionRole==nil then return {} end
    if not mode.strictDelta or not mode.readyAtPerform or type(mode.companions)~="table" or type(mode.companionRole)~="function" then return end
    local rules, count={},0
    for role,check in pairs(mode.companions) do
        count=count+1
        if type(role)~="string" or role=="" or type(check)~="function" or count>8 then return end
        rules[role]=check
    end
    return rules
end

local function roles(watch,item)
    local mode=watch.correlation
    local primary=watch.matches(item)==true
    local role=mode.companionRole and mode.companionRole(item)
    if not role then return primary end
    if primary or not mode.companions[role] then error("Conflicting produced item roles") end
    return primary,role
end

function Receipt.begin(owner, opts)
    if not owner or type(opts) ~= "table" or type(opts.inventory) ~= "function" or type(opts.matches) ~= "function"
        or type(opts.anchor) ~= "function" or type(opts.clock) ~= "function" then
        return nil, "Missing native item receipt context"
    end
    local cap, timeout, matches = opts.maxItems or MAX_ITEMS, opts.timeoutMs or TIMEOUT, opts.maxMatches
    if not integer(cap) or cap < 1 or cap > MAX_ITEMS or not integer(timeout) or timeout < 1 or timeout > TIMEOUT
        or (matches ~= nil and (not integer(matches) or matches < 1 or matches > cap)) then
        return nil, "Invalid native item receipt bounds"
    end
    local mode, settle, actionTimeout, companions = opts.correlation
    if mode ~= nil then
        if type(mode) ~= "table" or type(mode.guard) ~= "function" or type(mode.value) ~= "function"
            or mode.strictDelta~=nil and type(mode.strictDelta)~="boolean"
            or mode.retiredItem~=nil and (mode.strictDelta~=true or mode.readyAtPerform~=true)
            or mode.readyAtPerform~=nil and type(mode.readyAtPerform)~="boolean"
            or mode.atPerform~=nil and (mode.readyAtPerform~=true or type(mode.atPerform)~="function")
            or mode.observeValue~=nil and type(mode.observeValue)~="function" then
            return nil, "Missing observed item correlation guards"
        end
        companions=companionRules(mode)
        if not companions then return nil,"Invalid native companion-item contract" end
        settle, actionTimeout = mode.settleMs or SETTLE_MS, mode.actionTimeoutMs or ACTION_MS
        if not integer(settle) or settle < 100 or settle > 1000 or settle >= timeout
            or not integer(actionTimeout) or actionTimeout < 1 or actionTimeout > ACTION_MS then
            return nil, "Invalid observed item correlation bounds"
        end
    end
    local ok, inventory, at = pcall(function() return opts.inventory(), opts.clock() end)
    if not ok then Log.fault(nil, "CreatedItemReceipt.begin", inventory) end
    if not ok or not inventory or not integer(at) then return nil, "The receiving inventory is unavailable" end
    local self = setmetatable({owner=owner, destination=inventory, inventory=opts.inventory, matches=opts.matches,
        anchor=opts.anchor, deliveredBeforeDone=opts.deliveredBeforeDone, clock=opts.clock,
        lastClock=at, maxItems=cap, maxMatches=matches, timeoutMs=timeout, preserveMatching=opts.preserveMatching == true, stage="watch"}, Receipt)
    if mode then
        self.correlation = {guard=mode.guard, value=mode.value, observeValue=mode.observeValue,
            strictDelta=mode.strictDelta==true, retiredItem=mode.retiredItem, readyAtPerform=mode.readyAtPerform==true,
            companions=companions, companionRole=mode.companionRole, seenCompanions={}, atPerform=mode.atPerform,
            settleMs=settle, seen={}, novelCount=0, actionDeadline=at+actionTimeout}
    end
    local baseline, reason, holders = inspection(self, function(watch)
        local rows, failure, places = sample(watch)
        if not rows then return nil, failure end
        if watch.correlation then
            local prior,types={},watch.correlation.strictDelta and {} or nil
            for id,item in pairs(rows) do
                local primary,role=roles(watch,item)
                if role or primary then prior[id]=role or true end
                if types then
                    local fullType=item:getFullType()
                    if type(fullType)~="string" or fullType=="" then return nil,"A carried item's type is unavailable" end
                    types[id]=fullType
                end
            end
            watch.correlation.priorMatches,watch.correlation.priorTypes=prior,types
            local retiring=watch.correlation.retiredItem
            if retiring then
                local id=retiring:getID()
                if rows[id]~=retiring or places[id]~=watch.destination or prior[id] then
                    return nil,"The selected input is not the exact receiving-inventory item"
                end
                watch.correlation.retiredId=id
            end
            return rows, nil, places
        end
        -- Normally only IDs are kept. Synchronous adapters can additionally
        -- require that previous members of the result class never changed.
        for id, item in pairs(rows) do
            if not watch.preserveMatching or watch.matches(item) ~= true then rows[id] = true end
        end
        return rows
    end)
    if not baseline then return nil, reason end
    self.baseline, self.baselineHolders = baseline, holders
    return self
end

local function finish(self, reason)
    self.stage, self.reason = "closed", reason
    self.owner, self.baseline, self.proof, self.inventory, self.anchor, self.matches, self.deliveredBeforeDone, self.destination =
        nil, nil, nil, nil, nil, nil, nil, nil
    self.correlation, self.baselineHolders = nil, nil
end

function Receipt:cancel(reason)
    if self.stage ~= "closed" then finish(self, reason or "Native item creation was cancelled") end
end

local function novelMatches(self, rows)
    local found, count = nil, 0
    for id, item in pairs(rows) do
        -- This predicate describes all possible stock outputs, not whether it
        -- would be safe to later consume just this one. In particular, a
        -- second unsafe/restricted matching item still makes a delta ambiguous.
        if not self.baseline[id] and self.matches(item) == true then
            found, count = item, count + 1
        end
    end
    return found, count
end

local function outputSetReady(mode)
    if not mode.candidate then return false end
    for role in pairs(mode.companions) do if not mode.seenCompanions[role] then return false end end
    return true
end

-- Explicit opt-in: scope and proof of outcome, not packet-level lineage.
-- Only the same stock producer's start/perform may advance these stages.
local function observe(self, phase)
    local mode = self.correlation
    local now = currentTime(self)
    if now >= (self.stage == "done" and self.deadline or mode.actionDeadline) then
        return nil, self.stage == "done" and "The observed output was not stable in time"
            or "The owned action did not perform in time"
    end
    local allowed, reason = mode.guard(self.owner, self.destination, phase)
    if allowed ~= true then return nil, reason or "The owned action or its surroundings changed" end
    local rows, failure, holders = sample(self)
    if not rows then return nil, failure end
    for id, item in pairs(rows) do
        local primary,role=roles(self,item)
        local matches=role or primary
        local original = self.baseline[id]
        if original then
            if mode.retiredId==id and mode.retiredSeen then return nil,"The retired input returned to inventory" end
            if original ~= item or self.baselineHolders[id] ~= holders[id]
                or (mode.priorMatches[id] or false) ~= matches
                or mode.strictDelta and mode.priorTypes[id]~=item:getFullType() then
                return nil, "A pre-existing item changed identity, location, or output class"
            end
        elseif self.stage == "watch" then
            -- Never let a new ID seen before the exact native start be
            -- attributed to it, even if that ID started in another bag.
            return nil, "An inventory item appeared before the owned action started"
        elseif mode.strictDelta and not matches then
            return nil,"A competing inventory item appeared during the owned action"
        else
            local prior = mode.seen[id]
            if prior then
                if prior.item ~= item or prior.holder ~= holders[id] or prior.matches ~= matches then
                    return nil, "A newly observed item changed identity, location, or output class"
                end
            else
                if mode.novelCount >= self.maxItems then return nil, "Too many new items were observed" end
                mode.novelCount = mode.novelCount + 1
                mode.seen[id] = {item=item, holder=holders[id], matches=matches}
            end
            if role then
                if holders[id]~=self.destination then return nil,"A possible companion appeared outside the receiving inventory" end
                local seen=mode.seenCompanions[role]
                if seen and seen.item~=item then return nil,"Multiple new items matched the same required companion role" end
                local valid,problem=mode.companions[role](item,self.owner,self.destination,phase)
                if valid~=true then return nil,problem or "The expected companion did not match its native value" end
                mode.seenCompanions[role]={id=id,item=item}
            elseif primary then
                if holders[id] ~= self.destination then return nil, "A possible output appeared outside the receiving inventory" end
                if mode.candidate and mode.candidate ~= item then return nil, "Multiple new matching items were observed" end
                if mode.observeValue then
                    local allowed,problem=mode.observeValue(item,self.owner,self.destination,phase)
                    if allowed~=true then return nil,problem or "The possible output was not safe when first observed" end
                end
                mode.candidate, mode.candidateId = item, id
            end
        end
    end
    if mode.candidate and rows[mode.candidateId] ~= mode.candidate then
        return nil, "The observed possible output disappeared before use"
    end
    for _, companion in pairs(mode.seenCompanions) do
        if rows[companion.id]~=companion.item then return nil,"An expected companion disappeared before use" end
    end
    if mode.strictDelta then
        for id in pairs(self.baseline) do
            if not rows[id] then
                if id~=mode.retiredId or self.stage=="watch" or mode.retiredItem:getID()~=id
                    or mode.retiredItem:getContainer() or (mode.retiredItem.getWorldItem and mode.retiredItem:getWorldItem())
                    or (mode.readyAtPerform and not outputSetReady(mode)) then
                    return nil,"A baseline carried item disappeared outside the expected replacement"
                end
                mode.retiredSeen=true
            end
        end
    elseif self.preserveMatching then
        for id in pairs(mode.priorMatches) do
            if not rows[id] then return nil, "A pre-existing matching item disappeared before use" end
        end
    end
    return now
end

function Receipt:start(owner)
    if not self.correlation then return nil, "This receipt does not use observed item correlation" end
    if self.owner ~= owner or self.stage ~= "watch" then
        self:cancel("Not this receipt's current native start")
        return nil, self.reason
    end
    local at, reason = inspection(self, observe, "start")
    if not at then finish(self, reason); return nil, reason end
    self.stage = "running"
    return true
end

local function completeCorrelated(self, proof)
    if type(proof) ~= "table" or proof.correlated ~= true or proof.ordered ~= nil
        or proof.id ~= nil or proof.item ~= nil then
        return nil, "This receipt requires the explicit observed native outcome"
    end
    local at, reason = observe(self, "perform")
    if not at then return nil, reason end
    if self.correlation.readyAtPerform then
        local mode=self.correlation
        local anchored, failure=self.anchor()
        if failure or anchored~=true or not outputSetReady(mode) or (mode.retiredId and not mode.retiredSeen) then
            return nil,failure or "The selected input and complete output set were not visible at native completion"
        end
        if mode.atPerform then
            local ready,why=mode.atPerform(mode.candidate,self.owner,self.destination)
            if ready~=true then return nil,why or "The owned native action did not corroborate the observed result" end
        end
        mode.anchorSeen=true
    end
    self.stage, self.deadline = "done", at + self.timeoutMs
    return true
end

local function pollCorrelated(self)
    local phase = self.stage == "done" and "settling" or self.stage == "running" and "running" or "before-start"
    local at, reason = observe(self, phase)
    if not at then return false, reason end
    if self.stage ~= "done" then return nil end
    local mode = self.correlation
    local anchored, failure = self.anchor()
    if failure then return false, failure end
    if anchored ~= true then
        if mode.anchorSeen then return false, "The observed native input or fixture transition was reversed" end
        return nil
    end
    mode.anchorSeen = true
    if not mode.candidate then return nil end
    local safe, problem = mode.value(mode.candidate, self.owner, self.destination)
    if safe == false or problem then return false, problem or "The only new matching item was not safe to use" end
    if safe ~= true then mode.stableSince = nil; return nil end
    mode.stableSince = mode.stableSince or at
    if at - mode.stableSince < mode.settleMs then return nil end
    return true, mode.candidate
end

local function complete(self, proof)
    local now = currentTime(self)
    if type(proof) == "table" and proof.correlated ~= nil then
        return nil, "Observed item correlation was not enabled"
    end
    if type(proof) == "table" and proof.ordered == true and proof.id == nil and proof.item == nil then
        -- An adopter may opt in ONLY with a verified stock delivery contract:
        -- the input/fixture transition proves success, the one output is
        -- already in this exact destination and remains available (either
        -- synchronous local completion or known applied sends before Done). Transport order,
        -- stock action completion alone, and apparent uniqueness are not proof.
        if type(self.deliveredBeforeDone) ~= "function"
            or self.deliveredBeforeDone(self.owner, self.destination) ~= true then
            return nil, "This stock action does not prove delivery to the receiving inventory"
        end
        local anchored, problem = self.anchor()
        if anchored ~= true then return nil, problem or "The stock input transition was not confirmed at completion" end
        local rows, failure = sample(self)
        if not rows then return nil, failure end
        local item, count = novelMatches(self, rows)
        if count ~= 1 then return nil, "The ordered native output is missing or ambiguous" end
        -- Freeze the completion-time choice. Late lookalikes can never stand in
        -- for a true output that was not present at this barrier.
        self.proof = {id=item:getID(), item=item}
    elseif type(proof) == "table" and not proof.ordered then
        local id = proof.id or (proof.item and proof.item:getID())
        if not integer(id) or (proof.item and proof.item:getID() ~= id) or self.baseline[id] then
            return nil, "The native output identity is invalid or already existed"
        end
        self.proof = {id=id, item=proof.item}
    else
        local rows, reason = sample(self)
        if not rows then return nil, reason end
        local _, count = novelMatches(self, rows)
        return nil, count > 1 and "New matching items cannot be uniquely attributed to the native action"
            or "The native action did not identify its new item"
    end
    self.stage, self.deadline = "done", now + self.timeoutMs
    return true
end

function Receipt:complete(owner, proof)
    local expected = self.correlation and "running" or "watch"
    if self.stage ~= expected or self.owner ~= owner then
        local reason = "Not this receipt's current native action"
        if self.correlation then self:cancel(reason) end
        return nil, reason
    end
    local ok, reason = inspection(self, self.correlation and completeCorrelated or complete, proof)
    if not ok then finish(self, reason) end
    return ok, reason
end

local function poll(self)
    if currentTime(self) >= self.deadline then return false, "The native output was not received in time" end
    local rows, problem = sample(self)
    if not rows then return false, problem end
    local anchored, failure = self.anchor()
    if failure then return false, failure end
    if anchored ~= true then return nil end
    local item = rows[self.proof.id]
    if not item then return nil end
    if (self.proof.item and self.proof.item ~= item) or self.matches(item) ~= true then
        return false, "The native output changed before use"
    end
    return true, item
end

function Receipt:poll()
    if self.stage == "closed" then return false, self.reason end
    if not self.correlation and self.stage ~= "done" then return nil end
    local ok, value = inspection(self, self.correlation and pollCorrelated or poll)
    if not ok and value then finish(self, value); return false, value end
    if ok == true then finish(self, "The native creation receipt was already delivered") end
    return ok, value
end

return Receipt
