local Native = require "LootBox/Native"
local Categories = require "LootBox/Categories"
local Jobs = {}
Jobs.__index = Jobs

local function now() return getTimestampMs() end
local function copyList(values)
    local result = {}
    for index, value in ipairs(values or {}) do result[index] = value end
    return result
end
local function copyRecord(record)
    local result = {}
    for key, value in pairs(record) do result[key] = value end
    result.itemId = record.itemId or record.item:getID()
    result.fullType = record.fullType or tostring(record.item:getFullType())
    return result
end

local function sourceItem(record, source)
    local item = source:getItemWithID(record.itemId)
    if item and tostring(item:getFullType()) == record.fullType then return item end
end
local function cloneRequest(request)
    local result = {}
    for key, value in pairs(request) do result[key] = value end
    result.filter = { all = request.filter.all == true, ids = {}, types = {} }
    for _, id in ipairs(request.filter.ids or {}) do table.insert(result.filter.ids, id) end
    for _, fullType in ipairs(request.filter.types or {}) do table.insert(result.filter.types, fullType) end
    result.destination = {}
    for key, value in pairs(request.destination) do result.destination[key] = value end
    result.sourceLabels = copyList(request.sourceLabels)
    if request.destination.labels then result.destination.labels = copyList(request.destination.labels) end
    if type(request.area) == "table" then
        result.area = {}
        for key, value in pairs(request.area) do result.area[key] = value end
    end
    return result
end

function Jobs.new(player, world, graph)
    return setmetatable({ player = player, world = world, graph = graph,
        native = Native.new(player), view = { state = "idle", done = 0, total = 0 },
        revision = 0 }, Jobs)
end

function Jobs:status()
    local result = {}
    for key, value in pairs(self.view) do result[key] = value end
    return result
end

local function weight(item)
    return math.max(0, item:getUnequippedWeight())
end

function Jobs:choose(request, item, reservations)
    local previousGraph = self.world.graph
    self.world.graph = self.activeGraph or self.graph
    local ok, candidates, err = pcall(self.world.destinations, self.world, request, item)
    self.world.graph = previousGraph
    if not ok then return nil, "Destination discovery failed: " .. tostring(candidates) end
    if not candidates then return nil, err end
    for _, destination in ipairs(candidates) do
        local same = destination == item:getContainer()
        if same and destination:getType() == "floor" and request.destination.ref then
            local worldItem = item:getWorldItem()
            same = not worldItem or worldItem:getSquare() == request.destination.ref
        end
        if not same and not destination:isInside(item)
            and destination:isItemAllowed(item) and destination:hasRoomFor(self.player, item) then
            local reserved = reservations and reservations[destination] or 0
            local capacity = destination:getEffectiveCapacity(self.player)
            if destination:getType() == "floor" or destination:getCapacityWeight() + reserved + weight(item) <= capacity then
                if reservations then reservations[destination] = reserved + weight(item) end
                return destination
            end
        end
    end
    return nil, "No matching destination with room for this item"
end

local function validate(request)
    if type(request) ~= "table" or type(request.filter) ~= "table" or type(request.destination) ~= "table" then
        return nil, "Choose what to move, where to look, and a destination"
    end
    for _, values in ipairs({request.filter.ids or {}, request.filter.types or {}, request.sourceLabels or {}, request.destination.labels or {}}) do
        if type(values) ~= "table" then return nil, "Category and item selections must be lists of IDs" end
        local count = 0
        for key, value in pairs(values) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #values or type(value) ~= "string" or value == "" then
                return nil, "Category and item selections must be lists of IDs"
            end
            count = count + 1
        end
        if count ~= #values then return nil, "Category and item selections must be dense lists" end
    end
    if not request.filter.all and #(request.filter.ids or {}) == 0 and #(request.filter.types or {}) == 0 then
        return nil, "Select at least one category or item type"
    end
    local scopes = { inventory = true, reach = true, room = true, building = true, area = true, container = true, labeled = true }
    local destinations = { inventory = true, floor = true, container = true, vehicle = true, labels = true, trash = true }
    if not scopes[request.scope] then return nil, "Choose a source scope" end
    if not destinations[request.destination.kind] then return nil, "Choose a destination" end
    if request.scope == "container" and not request.sourceContainer then return nil, "Choose a source container" end
    if request.scope == "labeled" and #(request.sourceLabels or {}) == 0 then return nil, "Choose a source label" end
    if request.destination.kind == "container" and not request.destination.ref then return nil, "Choose a destination container" end
    return true
end

function Jobs:preview(request)
    if self.execution or self.ending or self.native:isBusy() then return nil, "Finish or cancel the current job before previewing another" end
    local ok, err = validate(request)
    if not ok then return nil, err end
    local scan
    scan, err = self.world:scan(request)
    if not scan then return nil, err end
    self.revision = self.revision + 1
    local plan = { owner = self, revision = self.revision, request = cloneRequest(request),
        moves = {}, skipped = {}, warnings = {}, records = {}, sources = scan.sources or {},
        groundSquares = scan.groundSquares or {}, trash = {}, approved = {}, unknownSources = {} }
    for _, warning in ipairs(scan.warnings or {}) do table.insert(plan.warnings, warning) end
    if request.destination.kind == "trash" then
        if isClient() and not getServerOptions():getBoolean("TrashDeleteAll") then
            return nil, "This server disables native trash deletion (TrashDeleteAll)"
        end
        local bins, warnings = self.world:trashCandidates()
        for _, warning in ipairs(warnings or {}) do table.insert(plan.warnings, warning) end
        for _, bin in ipairs(bins or {}) do
            local approved, blocked, names = {}, false, {}
            local contents = bin:getItems()
            for index = 0, contents:size() - 1 do
                local item = contents:get(index)
                if self.world:protected(item) then blocked = true end
                approved[self.world:itemId(item)] = true
                names[#names + 1] = tostring(item:getName())
            end
            if blocked then
                table.insert(plan.warnings, "Skipping " .. self.world:name(bin) .. ": contains protected items")
            else
                plan.trash[#plan.trash + 1] = bin
                plan.approved[bin] = approved
                if #names > 0 then
                    table.insert(plan.warnings, "Emptying " .. self.world:name(bin) .. " also deletes its " .. #names .. " existing items: " .. table.concat(names, ", "))
                end
            end
        end
        if #plan.trash == 0 then return nil, "No usable known trash can. Approach a real trash can first." end
        table.insert(plan.warnings, "Cleanup permanently empties the whole trash can, including the existing contents listed above.")
    end
    local reservations = {}
    for _, record in ipairs(scan.items or {}) do
        local item = record.item
        if self.graph:matchesFilter(request.filter, record.descriptor) then
            local reason
            if self.world:protected(item) then reason = "Protected: Keep, favorite, equipped, attached, or a nonempty bag"
            elseif request.destination.kind == "inventory" and self.world:owns(record.source) then reason = "Already carried" end
            local destination
            if not reason and request.destination.kind ~= "trash" then
                destination, reason = self:choose(request, item, reservations)
            end
            local row = { itemName = record.itemName, from = record.from,
                to = request.destination.kind == "trash" and "Trash can (fill, then empty)" or (destination and self.world:name(destination) or ""), reason = reason }
            if reason then table.insert(plan.skipped, row)
            else
                table.insert(plan.moves, row)
                table.insert(plan.records, record)
            end
        end
    end
    local unknown = 0
    for _, source in ipairs(plan.sources) do
        if not source:isExplored() then unknown = unknown + 1; plan.unknownSources[#plan.unknownSources + 1] = source end
    end
    if unknown > 0 then
        table.insert(plan.warnings, unknown .. " unopened containers will be approached and searched normally; matching newly revealed contents may be added to this job.")
        if isClient() then
            table.insert(plan.warnings, "Native multiplayer does not acknowledge empty container replies to Lua. Newly searched sources stay unconfirmed; this job cannot certify that the whole scope is clear.")
        end
    end
    if #plan.groundSquares > 0 then
        table.insert(plan.warnings, "Floor items will be inspected through the normal loot window after approaching each selected floor location.")
    end
    plan.pending = unknown + #plan.groundSquares
    table.insert(plan.warnings, "Live capacity, access, and item changes are checked again before each native action.")
    local records, approved = {}, {}
    for _, record in ipairs(plan.records) do records[#records + 1] = copyRecord(record) end
    for bin, ids in pairs(plan.approved) do
        approved[bin] = {}
        for id, value in pairs(ids) do approved[bin][id] = value end
    end
    self.reviewed = { token = plan, revision = self.revision, request = cloneRequest(request), records = records,
        unknownSources = copyList(plan.unknownSources), groundSquares = copyList(plan.groundSquares),
        trash = copyList(plan.trash), approved = approved, skipped = copyList(plan.skipped), graph = Categories.new(self.graph:list()) }
    return plan
end

function Jobs:start(plan)
    if self.execution or self.ending or self.native:isBusy() then return nil, "A LootBox job is already active" end
    local reviewed = self.reviewed
    if not reviewed or reviewed.token ~= plan or reviewed.revision ~= self.revision then
        return nil, "Preview this job again before starting" end
    self.reviewed = nil
    self.plan, self.cancelled, self.ending, self.hauled = reviewed, false, nil, {}
    self.activeGraph = reviewed.graph
    self.view = { state = "running", done = 0, total = #reviewed.records, skipped = #reviewed.skipped,
        reasons = copyList(reviewed.skipped), carried = 0, unconfirmedSources = 0 }
    self.execution = self:createExecution(reviewed)
    return true
end

function Jobs:skip(record, reason)
    self.view.skipped = self.view.skipped + 1
    table.insert(self.view.reasons, { itemName = record.itemName or "Container", reason = reason })
    self.view.reason = reason
end

local function interrupted(reason, code)
    return code == "interrupted" or (reason and (reason:find("player action", 1, true)
        or reason:find("interrupted", 1, true) or reason:find("stopped", 1, true)))
end

function Jobs:action(op, callback)
    local accepted, err, code = self.native:begin(op)
    if not accepted then
        if interrupted(err, code) then self:finishWhenSettled("cancelled", err)
        else callback(false, err) end
        return
    end
    self.pending = callback
end

function Jobs:approach(container, callback)
    if self.world:owns(container) then callback(true)
    else self:action({ kind = "approach", container = container }, callback) end
end

function Jobs:matches(record, plan)
    if self.world:protected(record.item) then return nil, "Item became protected" end
    if not self.activeGraph:matchesFilter(plan.request.filter, self.world:describe(record.item)) then
        return nil, "Item no longer matches the selection" end
    return true
end

function Jobs:recordSource(record, callback)
    if record.groundSquare then
        self:action({ kind = "approach", square = record.groundSquare }, function(ok, err)
            if not ok then callback(nil, err); return end
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then callback(nil, "The native loot window is not available"); return end
            loot:refreshBackpacks()
            local floor = ISInventoryPage.GetFloorContainer(self.player:getPlayerNum())
            local item = sourceItem(record, floor)
            local worldItem = item and item:getWorldItem()
            if not worldItem or worldItem:getSquare() ~= record.groundSquare then callback(nil, "Floor item changed location after preview"); return end
            record.item = item
            callback(floor)
        end)
    else
        if not sourceItem(record, record.source) then
            callback(nil, "Item changed source after preview"); return end
        self:approach(record.source, function(ok, err)
            if not ok then callback(nil, err); return end
            local item = sourceItem(record, record.source)
            if not item then callback(nil, "Item changed source after preview"); return end
            record.item = item
            callback(record.source)
        end)
    end
end

function Jobs:empty(bin, approved, callback)
    self:approach(bin, function(ok, err)
        if not ok then callback(false, err); return end
        local contents = bin:getItems()
        for index = 0, contents:size() - 1 do
            if self.world:protected(contents:get(index)) then callback(false, "Trash now contains a protected item; nothing was deleted"); return end
        end
        self:action({ kind = "trash", container = bin, approved = approved }, callback)
    end)
end

function Jobs:createExecution(plan)
    local execution = { phase = "source", tasks = {}, taskIndex = 1, records = {}, recordIndex = 1,
        batch = {}, seen = {}, plan = plan, finalBin = 1 }
    local groups, order = {}, {}
    for _, entry in ipairs(plan.records) do
        local record = copyRecord(entry)
        execution.seen[self.world:itemId(record.item) or record.item] = true
        local key = record.groundSquare or record.source
        if not groups[key] then groups[key] = {}; order[#order + 1] = key end
        groups[key][#groups[key] + 1] = record
    end
    for _, owned in ipairs({true, false}) do
        for _, key in ipairs(order) do
            if self.world:owns(groups[key][1].source) == owned then
                execution.tasks[#execution.tasks + 1] = {kind = "records", records = groups[key]}
            end
        end
    end
    for _, container in ipairs(plan.unknownSources) do execution.tasks[#execution.tasks + 1] = {kind = "discover", container = container} end
    for _, square in ipairs(plan.groundSquares) do execution.tasks[#execution.tasks + 1] = {kind = "floor", square = square} end
    plan.touched = {}
    return execution
end

function Jobs:addObserved(entries)
    local execution, result = self.execution, {}
    for _, entry in ipairs(entries) do
        local id = self.world:itemId(entry.item) or entry.item
        if not execution.seen[id] and self.activeGraph:matchesFilter(execution.plan.request.filter, entry.descriptor) then
            execution.seen[id] = true
            if not (execution.plan.request.destination.kind == "inventory" and self.world:owns(entry.source)) then
                result[#result + 1] = copyRecord(entry)
                self.view.total = self.view.total + 1
            end
        end
    end
    execution.records, execution.recordIndex, execution.phase = result, 1, "source"
end

function Jobs:nextRecord()
    self.execution.recordIndex = self.execution.recordIndex + 1
    self.execution.phase = "source"
end

function Jobs:startDelivery(after)
    self.execution.delivery = { index = 1, after = after, prepared = false }
    self.execution.phase = "delivery"
end

function Jobs:pickup(record)
    local execution, plan = self.execution, self.execution.plan
    self.view.itemName = record.itemName
    self:recordSource(record, function(source, err)
        local ok
        if source then ok, err = self:matches(record, plan) end
        if not source or not ok then self:skip(record, err); self:nextRecord(); return end
        if plan.request.destination.kind ~= "inventory" and self.world:owns(source) then
            execution.batch[#execution.batch + 1] = record
            self:nextRecord()
            return
        end
        local destination, request
        if plan.request.destination.kind == "inventory" then request = plan.request
        else request = { includeBags = plan.request.includeBags, destination = { kind = "inventory" } } end
        destination, err = self:choose(request, record.item)
        if not destination then
            if plan.request.destination.kind ~= "inventory" and #execution.batch > 0 then self:startDelivery("source")
            else self:skip(record, err or "Cannot carry this item to its destination"); self:nextRecord() end
            return
        end
        local hauling = plan.request.destination.kind ~= "inventory"
        if hauling then self.hauled[self.world:itemId(record.item) or record.item] = record end
        record.carryContainer = hauling and destination or nil
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination}
        self:action(operation, function(moved, failure)
            if moved then
                record.item = operation.resultItem
                if hauling then
                    record.hauled = true
                    execution.batch[#execution.batch + 1] = record
                    self.view.carried = self.view.carried + 1
                else self.view.done = self.view.done + 1 end
            else self:skip(record, failure or "Native pickup refused") end
            self:nextRecord()
        end)
    end)
end

function Jobs:nextDelivery(record, ok, reason, destination)
    if ok then
        self.view.done = self.view.done + 1
        record.delivered = true
        if record.hauled then self.view.carried = self.view.carried - 1 end
        if self.plan.request.destination.kind == "trash" then
            self.plan.approved[destination][self.world:itemId(record.item)] = true
            self.plan.touched[destination] = true
        end
    else
        if record.hauled and self.world:owns(record.item:getContainer()) then reason = (reason or "Delivery refused") .. "; item remains in carried storage" end
        self:skip(record, reason or "Native delivery refused")
    end
    self.execution.delivery.index = self.execution.delivery.index + 1
end

function Jobs:place(record, destination)
    local function transfer(ok, err)
        if not ok then self:nextDelivery(record, false, err); return end
        if destination:getType() == "floor" then
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then self:nextDelivery(record, false, "The native loot window is not available"); return end
            loot:refreshBackpacks()
            destination = ISInventoryPage.GetFloorContainer(self.player:getPlayerNum())
        end
        local matches, reason = self:matches(record, self.plan)
        if not matches then self:nextDelivery(record, false, reason); return end
        local source = record.item:getContainer()
        if not self.world:owns(source) or not source:contains(record.item) then
            self:nextDelivery(record, false, "Hauled item is no longer carried"); return end
        local operation = {kind = "transfer", item = record.item, source = source, destination = destination}
        self:action(operation, function(moved, failure)
            if moved then record.item = operation.resultItem end
            self:nextDelivery(record, moved, failure, destination)
        end)
    end
    if self.plan.request.destination.kind == "floor" and self.plan.request.destination.ref then
        self:action({kind = "approach", square = self.plan.request.destination.ref, exact = true}, transfer)
    else self:approach(destination, transfer) end
end

function Jobs:trashDestination(record, index)
    local plan = self.plan
    while index <= #plan.trash and not (self.world:valid(plan.trash[index]) and self.world:isTrash(plan.trash[index])) do index = index + 1 end
    local bin = plan.trash[index]
    if not bin then self:nextDelivery(record, false, "No reachable approved trash can can hold this item after emptying"); return end
    self:approach(bin, function(ok, err)
        if not ok then self.view.reason = err; self:trashDestination(record, index + 1); return end
        local function check(emptied, failure)
            if emptied and bin:hasRoomFor(self.player, record.item) and bin:isItemAllowed(record.item) then self:place(record, bin)
            else
                if failure then self.view.reason = failure end
                self:trashDestination(record, index + 1)
            end
        end
        if not bin:hasRoomFor(self.player, record.item) and not bin:getItems():isEmpty() then self:empty(bin, plan.approved[bin], check)
        else check(true) end
    end)
end

function Jobs:deliveryStep()
    local execution, delivery = self.execution, self.execution.delivery
    if not delivery.prepared then
        delivery.prepared = true
        if self.plan.request.destination.kind == "vehicle" then
            self:action({kind = "vehicle", vehicle = self.plan.request.destination.ref or self.world:vehicle()}, function(ok, err)
                if not ok then delivery.failure = err or "Vehicle access failed" end
            end)
            return
        end
    end
    local record = execution.batch[delivery.index]
    if not record then
        execution.batch = {}
        execution.phase, execution.delivery = delivery.after, nil
        return
    end
    self.view.itemName = record.itemName
    local ok, err = self:matches(record, self.plan)
    if not ok or delivery.failure then self:nextDelivery(record, false, delivery.failure or err); return end
    local source = record.item:getContainer()
    if not source or not self.world:owns(source) or not source:contains(record.item) then self:nextDelivery(record, false, "Hauled item is no longer carried"); return end
    if self.plan.request.destination.kind == "trash" then self:trashDestination(record, 1)
    else
        local destination
        destination, err = self:choose(self.plan.request, record.item)
        if not destination then self:nextDelivery(record, false, err)
        else self:place(record, destination) end
    end
end

function Jobs:discoverSource(source)
    self:approach(source, function(ok, err)
        if not ok then self:skip({itemName = self.world:name(source)}, err); self.execution.phase = "source"; return end
        if isClient() then
            self.view.unconfirmedSources = self.view.unconfirmedSources + 1
            local reason = "Native multiplayer synchronization is unconfirmed; only observed items from this source can be moved"
            table.insert(self.view.reasons, {itemName = self.world:name(source), reason = reason})
            self.view.reason = reason
            source:requestServerItemsForContainer()
            self.execution.discovery = {source = source, deadline = now() + 3000}
            self.execution.phase = "discoveryWait"
        else
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not loot then self:skip({itemName = self.world:name(source)}, "The native loot window is not available"); self.execution.phase = "source"; return end
            loot:checkExplored(source, self.player)
            self:addObserved(self.world:records(source, self.plan.request.includeBags))
        end
    end)
end

function Jobs:sourceStep()
    local execution = self.execution
    local record = execution.records[execution.recordIndex]
    if record then self:pickup(record); return end
    local task = execution.tasks[execution.taskIndex]
    execution.taskIndex = execution.taskIndex + 1
    if not task then
        if #execution.batch > 0 then self:startDelivery("finalTrash") else execution.phase = "finalTrash" end
    elseif task.kind == "records" then execution.records, execution.recordIndex = task.records, 1
    elseif task.kind == "discover" then self:discoverSource(task.container)
    elseif task.kind == "floor" then
        self:action({kind = "approach", square = task.square}, function(ok, err)
            local loot = getPlayerLoot(self.player:getPlayerNum())
            if not ok or not loot then self:skip({itemName = "Floor"}, err or "The native loot window is not available"); return end
            loot:refreshBackpacks()
            local scoped = {}
            for _, entry in ipairs(self.world:records(ISInventoryPage.GetFloorContainer(self.player:getPlayerNum()), self.plan.request.includeBags)) do
                if entry.groundSquare == task.square then scoped[#scoped + 1] = entry end
            end
            self:addObserved(scoped)
        end)
    end
end

function Jobs:carriedCount()
    local count = 0
    for _, record in pairs(self.hauled) do
        if not record.delivered then
            local item = record.carryContainer and sourceItem(record, record.carryContainer)
            if item and self.world:owns(record.carryContainer) then record.item = item; count = count + 1 end
        end
    end
    return count
end

function Jobs:complete(state, reason)
    self.view.carried = self:carriedCount()
    self.view.state, self.view.reason = state, reason or self.view.reason
    if self.view.carried > 0 then self.view.reason = (self.view.reason and self.view.reason .. "; " or "") .. self.view.carried .. " hauled items remain in carried storage" end
    self.execution, self.pending, self.activeGraph, self.ending = nil, nil, nil, nil
end

function Jobs:advance()
    if self.pending then
        local done, reason, code = self.native:poll()
        if done == nil then return end
        local callback = self.pending
        self.pending = nil
        if done == false and interrupted(reason, code) then self:finishWhenSettled("cancelled", reason)
        else callback(done, reason) end
        return
    end
    local execution = self.execution
    if execution.phase == "source" then self:sourceStep()
    elseif execution.phase == "delivery" then self:deliveryStep()
    elseif execution.phase == "discoveryWait" then
        local discovery = execution.discovery
        if not discovery.source:getItems():isEmpty() then
            self:addObserved(self.world:records(discovery.source, self.plan.request.includeBags))
        elseif now() >= discovery.deadline then
            self:skip({itemName = self.world:name(discovery.source)}, "No items observed after the native request; the source is unconfirmed, not certified empty")
            execution.phase = "source"
        end
    elseif execution.phase == "finalTrash" then
        local bin = self.plan.trash[execution.finalBin]
        execution.finalBin = execution.finalBin + 1
        if not bin then
            self:complete((self.view.skipped > 0 or self.view.unconfirmedSources > 0) and "finished_with_skips" or "finished")
        elseif self.plan.touched[bin] and self.world:valid(bin) and not bin:getItems():isEmpty() then
            self:empty(bin, self.plan.approved[bin], function(ok, err) if not ok then self:skip({itemName = self.world:name(bin)}, err) end end)
        end
    else error("Unknown job execution phase") end
end

function Jobs:finishWhenSettled(state, reason)
    self.ending = self.ending or {state = state, reason = reason}
    self.view.state = "cancelling"
    local ok, result, err = pcall(self.native.cancel, self.native)
    if not ok or result == false then self.ending.reason = (self.ending.reason or "") .. "; cancellation error: " .. tostring(ok and err or result) end
end

function Jobs:tick()
    if self.ending then
        if self.native:isBusy() then
            local ok, result, err = pcall(self.native.poll, self.native)
            if not ok then self.view.reason = "Native cleanup error: " .. tostring(result); return end
            if result == nil then return end
            if err and err ~= "Cancelled" then self.ending.reason = (self.ending.reason and self.ending.reason .. "; " or "") .. err end
        end
        self:complete(self.ending.state, self.ending.reason)
    elseif self.execution then
        local ok, err = pcall(self.advance, self)
        if not ok then self:finishWhenSettled("failed", "Job execution failed: " .. tostring(err)) end
    end
end

function Jobs:cancel()
    if self.ending then return true end
    if not self.execution and not self.native:isBusy() then return true end
    self:finishWhenSettled("cancelled", "Cancelled")
    return true
end

return Jobs
