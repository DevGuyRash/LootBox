local Log = require "LootBox/Log"
local Sort = require "LootBox/Sort"
local Store = require "LootBox/Store"
local Recovery = {}
Recovery.__index = Recovery

local function call(value, name, ...)
    local method = value and value[name]
    if not method then return nil end
    return method(value, ...)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end

local function integer(value)
    return type(value) == "number" and value == value and math.abs(value) <= 9007199254740990 and value % 1 == 0
end

local function identity(item)
    return {id = item:getID(), fullType = tostring(item:getFullType())}
end

local function matches(item, entry)
    return item and item:getID() == entry.id and tostring(item:getFullType()) == entry.fullType
end

local function locationName(value)
    return tostring(call(value, "getId") or value)
end

local function wornSlots(player, item)
    local result, worn = {}, call(player, "getWornItems")
    for index = 0, (call(worn, "size") or 0) - 1 do
        local entry = worn:get(index)
        if call(entry, "getItem") == item then result[#result + 1] = locationName(entry:getLocation()) end
    end
    return result
end

local function slots(player, item)
    return {worn = wornSlots(player, item), primary = player:getPrimaryHandItem() == item,
        secondary = player:getSecondaryHandItem() == item}
end

local function anchor(container, world)
    local source = world:sourceAnchor(container)
    if not source or source.kind ~= "world" then return nil end
    return {kind = "world", point = copy(source.point), sprite = source.sprite,
        index = source.index, slot = source.slot, containerType = source.containerType}
end

local function validIdentity(value)
    return type(value) == "table" and integer(value.id) and type(value.fullType) == "string" and value.fullType ~= ""
end

local function reservedIdentities(receipt)
    local result = {}
    for _, entry in ipairs(receipt and receipt.entries or {}) do
        result[entry.id] = entry.fullType
        for _, child in ipairs(entry.children) do result[child.id] = child.fullType end
    end
    return result
end

local function validate(receipt)
    if type(receipt) ~= "table" or receipt.version ~= 1 or type(receipt.pending) ~= "boolean" then return nil, "Invalid personal gear recovery document" end
    if not receipt.pending then return true end
    if receipt.phase ~= "staging" and receipt.phase ~= "staged" and receipt.phase ~= "restoring" and receipt.phase ~= "blocked" then
        return nil, "Invalid personal gear recovery phase"
    end
    if receipt.intent ~= nil and (type(receipt.intent) ~= "table" or not integer(receipt.intent.index) or receipt.intent.index < 1
        or (receipt.intent.kind ~= "transfer" and receipt.intent.kind ~= "gear")) then return nil, "Invalid personal gear recovery intent" end
    local endpoint = receipt.endpoint
    if type(endpoint) ~= "table" or endpoint.kind ~= "world" or type(endpoint.point) ~= "table"
        or not integer(endpoint.index) or endpoint.index < 0 or not integer(endpoint.slot) or endpoint.slot < 0
        or type(endpoint.sprite) ~= "string" or type(endpoint.containerType) ~= "string"
        or type(receipt.endpointKey) ~= "string" or type(receipt.endpointName) ~= "string"
        or type(receipt.entries) ~= "table" or #receipt.entries == 0 then return nil, "Invalid personal gear recovery location" end
    for _, axis in ipairs({"x", "y", "z"}) do
        if not integer(endpoint.point[axis]) then return nil, "Invalid personal gear recovery coordinates" end
    end
    local seen = {}
    for _, entry in ipairs(receipt.entries) do
        if not validIdentity(entry) or seen[entry.id] or type(entry.name) ~= "string" or type(entry.children) ~= "table"
            or type(entry.slots) ~= "table" or type(entry.slots.worn) ~= "table"
            or type(entry.slots.primary) ~= "boolean" or type(entry.slots.secondary) ~= "boolean" then
            return nil, "Invalid personal gear recovery item"
        end
        seen[entry.id] = true
        for _, child in ipairs(entry.children) do
            if not validIdentity(child) or seen[child.id] then return nil, "Invalid personal gear recovery contents" end
            seen[child.id] = true
        end
        for _, slot in ipairs(entry.slots.worn) do
            if type(slot) ~= "string" or slot == "" then return nil, "Invalid personal gear recovery slot" end
        end
    end
    return true
end

function Recovery.new(player, world, path)
    local document, err = Store.load(path .. "/recovery")
    if document then
        local ok, invalid = validate(document)
        if not ok then document, err = nil, invalid end
    end
    local self = setmetatable({player = player, world = world, path = path .. "/recovery", error = err, unreadable = err,
        receipt = document and document.pending and document or nil}, Recovery)
    self.reserved = reservedIdentities(self.receipt)
    return self
end

function Recovery:save(candidate)
    local ok, reason = Store.save(self.path, candidate or {version = 1, pending = false})
    if not ok then self.error = "Personal gear recovery could not be saved: " .. tostring(reason); return nil, self.error end
    self.receipt, self.error = candidate, nil
    self.reserved = reservedIdentities(candidate)
    return true
end

-- pending: a receipt exists, so personal gear may be staged somewhere.
-- blocking: gear has really left the player and is still owed back. Callers
-- should refuse only another heavy lift for it; other work stays safe because
-- the gear and its container are protected.
-- items: what the receipt still covers. dropped: what turned out to be gone.
-- A read or write error alone is reported in error and never sets pending.
function Recovery:status()
    local receipt = self.receipt
    if not receipt then
        return {pending = false, blocking = false, phase = "none", count = 0, items = {}, dropped = {}, error = self.error, reason = self.error}
    end
    local point, items, blocking = receipt.endpoint.point, {}, false
    for _, entry in ipairs(receipt.entries) do
        items[#items + 1] = {id = entry.id, fullType = entry.fullType, name = entry.name, staged = entry.touched == true}
        blocking = blocking or entry.touched == true and entry.restored ~= true
    end
    return {pending = true, blocking = blocking, phase = receipt.phase, count = #receipt.entries, reason = self.error or receipt.reason,
        error = self.error, items = items, dropped = copy(receipt.dropped or {}),
        location = receipt.endpointName .. " (" .. point.x .. ", " .. point.y .. ", floor " .. point.z .. ")",
        point = copy(point)}
end

-- Gives up on the staged gear without moving anything. Returns the items the
-- receipt covered (an empty list when only an unreadable receipt was cleared).
function Recovery:forget()
    local dropped = self:status().items
    local ok, reason = Store.save(self.path, {version = 1, pending = false})
    self.receipt, self.reserved, self.liveEndpoint, self.unreadable = nil, {}, nil, nil
    self.error = not ok and "Personal gear recovery could not be saved: " .. tostring(reason) or nil
    Log.warn(self.interaction, "GEAR-FORGET", "items", #dropped, "saved", ok == true, "error", reason)
    return dropped, self.error
end

function Recovery:block(reason)
    if self.receipt then
        local candidate = copy(self.receipt)
        candidate.phase, candidate.reason = "blocked", reason
        Log.warn(self.interaction, "GEAR-BLOCKED", "reason", reason, "at", candidate.endpointName)
        local ok, failure = self:save(candidate)
        if not ok then return nil, failure end
    end
    return nil, reason
end

function Recovery:endpoint()
    if not self.receipt then return nil, self.error or "There is no staged personal gear" end
    local container, reason = self.world:resolveSource(self.receipt.endpoint)
    if not container then return nil, reason end
    if self.liveEndpoint and container ~= self.liveEndpoint then return nil, "The personal gear staging container was replaced" end
    if self.world:isTrash(container) or self.world:owns(container) or not self.world:canAccess(container) then
        return nil, "The personal gear staging container is no longer safe"
    end
    return container
end

function Recovery:isReservedContainer(container)
    local receipt = self.receipt
    if not receipt or not container then return false end
    local seen = {}
    while container and not seen[container] do
        seen[container] = true
        if container == self.liveEndpoint or self.world:key(container) == receipt.endpointKey then return true end
        container = call(call(container, "getContainingItem"), "getContainer")
    end
    return false
end

function Recovery:isProtected(item)
    local receipt = self.receipt
    if not receipt or not item then return false end
    local current, seen = item, {}
    while current and not seen[current] do
        seen[current] = true
        if self.reserved[current:getID()] == tostring(current:getFullType()) then return true end
        local container = current:getContainer()
        if self:isReservedContainer(container) then return true end
        current = call(container, "getContainingItem")
    end
    return false
end

local function restoreOrder(selected, current, maximum)
    local ordered, remaining = {}, current
    for _, root in ipairs(selected) do ordered[#ordered + 1], remaining = root, remaining - root.freed end
    Sort(ordered, function(root) return root.freed - root.raw, root.entry.id end)
    for _, root in ipairs(ordered) do
        if remaining + root.raw > maximum + 0.0001 then return nil end
        remaining = remaining + root.freed
    end
    return ordered
end

function Recovery:prepare(blockedItem, candidates)
    if self.unreadable then return nil, self.unreadable end
    if self.receipt then return nil, "Recover the personal gear already staged before starting another heavy lift" end
    local current, maximum = self.world:carrying()
    local needed = current + math.max(0, blockedItem:getUnequippedWeight()) - maximum
    if needed <= 0.0001 or maximum == math.huge then return nil, "The actual hard carrying limit does not require personal gear staging" end
    local inventory, roots = self.player:getInventory(), {}
    local contents = inventory:getItems()
    for index = 0, contents:size() - 1 do
        local item = contents:get(index)
        local attached = call(item, "getAttachedSlot") or -1
        local bag = call(item, "getInventory")
        local ownSlots = slots(self.player, item)
        local worn = #ownSlots.worn > 0
        if item ~= blockedItem and attached < 0 and (bag or not worn) and not call(item, "isHumanCorpse")
            and not call(item, "isForceDropHeavyItem") then
            local raw = math.max(0, item:getUnequippedWeight())
            local equipped = self.player:isEquipped(item)
            local freed = equipped and math.max(0, call(item, "getEquippedWeight") or raw) or raw
            local containsBlocked = bag and bag:isInside(blockedItem)
            if bag then
                for _, child in ipairs(self.world:records(bag, true)) do
                    if child.item == blockedItem then containsBlocked = true; break end
                end
            end
            if freed > 0.0001 and not containsBlocked then
                local entry = identity(item)
                entry.name, entry.slots, entry.children = tostring(item:getName()), ownSlots, {}
                for _, child in ipairs(bag and self.world:records(bag, true) or {}) do entry.children[#entry.children + 1] = identity(child.item) end
                roots[#roots + 1] = {item = item, entry = entry, raw = raw, freed = freed,
                    equipped = equipped, score = freed / (1 + (equipped and 2 or 0))}
            end
        end
    end
    Sort(roots, function(root) return -root.score, root.entry.id end)
    local sourceContainers, source = {}, blockedItem:getContainer()
    while source and not sourceContainers[source] do
        sourceContainers[source] = true
        source = call(call(source, "getContainingItem"), "getContainer")
    end
    for _, container in ipairs(candidates or self.world:safeStagingContainers()) do
        local endpoint = anchor(container, self.world)
        if endpoint and not sourceContainers[container] and self.world:canAccess(container) and not self.world:isTrash(container) and not self.world:owns(container) then
            local selected, selectedIds, freed, reserved = {}, {}, 0, 0
            local function add(root)
                if selectedIds[root.entry.id] then return end
                if container:isItemAllowed(root.item) and container:hasRoomFor(self.player, root.item)
                    and container:getCapacityWeight() + reserved + root.raw <= container:getEffectiveCapacity(self.player) then
                    selected[#selected + 1], selectedIds[root.entry.id] = root, true
                    freed, reserved = freed + root.freed, reserved + root.raw
                end
            end
            for _, root in ipairs(roots) do
                add(root)
                if freed + 0.0001 >= needed then break end
            end
            if freed + 0.0001 >= needed then
                local ordered = restoreOrder(selected, current, maximum)
                for _, equipped in ipairs({false, true}) do
                    if ordered then break end
                    for _, root in ipairs(roots) do
                        if root.equipped == equipped and not selectedIds[root.entry.id] then
                            add(root)
                            ordered = restoreOrder(selected, current, maximum)
                            if ordered then break end
                        end
                    end
                end
                if ordered then
                    local entries = {}
                    for _, root in ipairs(ordered) do entries[#entries + 1] = root.entry end
                    local receipt = {version = 1, pending = true, phase = "staging", endpoint = endpoint,
                        endpointKey = self.world:key(container), endpointName = self.world:name(container), entries = entries,
                        reason = "Temporarily storing whole personal items to make room for a heavy lift"}
                    local ok, reason = self:save(receipt)
                    if not ok then return nil, reason end
                    self.liveEndpoint = container
                    return true
                end
            end
        end
    end
    return nil, "No safe ordinary container can hold enough personal gear and preserve hard-limit headroom for its recovery; personal items were retained"
end

local function rootItem(self, entry, endpoint)
    local main = self.player:getInventory():getItemWithID(entry.id)
    if matches(main, entry) and main:getContainer() == self.player:getInventory() then return main, self.player:getInventory() end
    local staged = endpoint:getItemWithID(entry.id)
    if matches(staged, entry) and staged:getContainer() == endpoint then return staged, endpoint end
end

local function heldConflict(self, item, entry)
    for _, field in ipairs({"primary", "secondary"}) do
        local held
        if field == "primary" then held = self.player:getPrimaryHandItem() else held = self.player:getSecondaryHandItem() end
        if entry.slots[field] and held and held ~= item then return "The original " .. field .. " hand is occupied; clear it before recovering " .. entry.name end
    end
    local worn = call(self.player, "getWornItems")
    for index = 0, (call(worn, "size") or 0) - 1 do
        local equipped = worn:get(index)
        for _, original in ipairs(entry.slots.worn) do
            if locationName(equipped:getLocation()) == original and equipped:getItem() ~= item then
                return "The original worn slot is occupied; clear it before recovering " .. entry.name
            end
        end
    end
end

local function missingContents(self, item, entry)
    local missing = {}
    if #entry.children == 0 then return missing end
    local bag, observed = call(item, "getInventory"), {}
    for _, record in ipairs(bag and self.world:records(bag, true) or {}) do
        observed[record.item:getID()] = tostring(record.item:getFullType())
    end
    for _, child in ipairs(entry.children) do
        if observed[child.id] ~= child.fullType then missing[#missing + 1] = child end
    end
    return missing
end

-- Items the player or the world has since taken away can never be put back, so
-- they leave the receipt and are reported instead of holding everything else.
local function dropGone(self, candidate, endpoint, mode)
    local kept, gone = {}, {}
    local function drop(entry, name)
        gone[#gone + 1] = name .. " (" .. entry.fullType .. ")"
        candidate.dropped = candidate.dropped or {}
        table.insert(candidate.dropped, {id = entry.id, fullType = entry.fullType, name = name})
    end
    for _, entry in ipairs(candidate.entries) do
        local item = rootItem(self, entry, endpoint)
        if item or mode == "restore" and not entry.touched then
            kept[#kept + 1] = entry
            local missing = item and missingContents(self, item, entry) or {}
            for _, child in ipairs(missing) do
                drop(child, entry.name .. " contents")
                for index, original in ipairs(entry.children) do
                    if original == child then table.remove(entry.children, index); break end
                end
            end
        else drop(entry, entry.name) end
    end
    candidate.entries = kept
    if #gone > 0 then Log.warn(self.interaction, "GEAR-GONE", "items", table.concat(gone, ", "), "at", candidate.endpointName) end
    return #gone > 0
end

function Recovery:allows(op)
    local receipt = self.receipt
    if not receipt or not op or not op.personalRecovery or not op.item then return nil, "This is not a recorded personal gear operation" end
    local endpoint, reason = self:endpoint()
    if not endpoint then return self:block(reason) end
    local intent = receipt.intent
    local entry = intent and receipt.entries[intent.index]
    if not entry or not matches(op.item, entry) or intent.kind ~= op.kind or intent.mode ~= op.mode or intent.slot ~= op.slot
        or intent.twoHands ~= op.twoHands then
        return nil, "The operation has no matching durable personal gear intent"
    end
    if #missingContents(self, op.item, entry) > 0 then return nil, "Personal bag contents changed: " .. entry.name end
    local inventory = self.player:getInventory()
    if op.kind == "transfer" then
        if op.source == inventory and op.destination == endpoint and receipt.phase == "staging" then return true end
        if op.source == endpoint and op.destination == inventory and receipt.phase == "restoring" then return true end
    elseif op.kind == "gear" and op.item:getContainer() == inventory then
        if receipt.phase == "staging" and op.mode == "unequip" then return true end
        if receipt.phase == "restoring" and not heldConflict(self, op.item, entry) then
            if op.mode == "primary" and entry.slots.primary then return true end
            if op.mode == "secondary" and entry.slots.secondary then return true end
            if op.mode == "wear" then
                for _, slot in ipairs(entry.slots.worn) do if slot == op.slot then return true end end
            end
        end
    end
    return nil, "The operation does not match the recorded personal gear recovery direction or slot"
end

function Recovery:next(mode)
    local receipt = self.receipt
    if not receipt then return nil, self.unreadable, self.unreadable == nil end
    if self.error then
        local saved, failure = self:save(copy(receipt))
        if not saved then return nil, failure end
        receipt = self.receipt
    end
    if mode ~= "stage" and mode ~= "restore" then return nil, "Choose staging or recovery" end
    local endpoint, reason = self:endpoint()
    if not endpoint then return self:block(reason) end
    -- A multiplayer container that has not been opened lists no items yet.
    if call(endpoint, "isExplored") == false then return self:block("The personal gear staging container has not been opened yet") end
    local candidate = copy(receipt)
    dropGone(self, candidate, endpoint, mode)
    candidate.phase = mode == "stage" and "staging" or "restoring"
    candidate.reason = mode == "stage" and "Making room for a heavy lift" or "Recovering personal gear and original equipment slots"
    local op
    for index, entry in ipairs(candidate.entries) do
        local item, source
        if mode == "stage" or entry.touched then item, source = rootItem(self, entry, endpoint) end
        if mode == "stage" and source ~= endpoint then
            entry.touched = true
            if self.player:isEquipped(item) then op = {kind = "gear", mode = "unequip", item = item, source = source}
            else op = {kind = "transfer", item = item, source = source, destination = endpoint} end
        elseif mode == "restore" and entry.touched then
            if source == endpoint then
                op = {kind = "transfer", item = item, source = endpoint, destination = self.player:getInventory()}
            else
                local conflict = heldConflict(self, item, entry)
                if conflict then return self:block(conflict) end
                local currentSlots = slots(self.player, item)
                for _, slot in ipairs(entry.slots.worn) do
                    local found = false
                    for _, currentSlot in ipairs(currentSlots.worn) do if currentSlot == slot then found = true end end
                    if not found then
                        if self.player:isEquipped(item) then return self:block("Personal gear was equipped elsewhere; move it to its original slot manually: " .. entry.name) end
                        op = {kind = "gear", mode = "wear", slot = slot, item = item, source = source}
                        break
                    end
                end
                if not op and entry.slots.primary and entry.slots.secondary and (not currentSlots.primary or not currentSlots.secondary) then
                    op = {kind = "gear", mode = "primary", twoHands = true, item = item, source = source}
                end
                if not op and entry.slots.primary and not currentSlots.primary then op = {kind = "gear", mode = "primary", item = item, source = source} end
                if not op and entry.slots.secondary and not currentSlots.secondary then op = {kind = "gear", mode = "secondary", item = item, source = source} end
                if not op then entry.restored = true end
            end
        end
        if op then
            op.personalRecovery = true
            candidate.intent = {index = index, kind = op.kind, mode = op.mode, slot = op.slot, twoHands = op.twoHands}
            local ok, err = self:save(candidate)
            if not ok then return nil, err end
            return op
        end
    end
    candidate.intent = nil
    if mode == "restore" or #candidate.entries == 0 then
        local ok, err = self:save(nil)
        if ok then self.liveEndpoint = nil end
        return nil, err, ok == true
    end
    candidate.phase, candidate.reason = "staged", "Personal gear is safely staged until the heavy load has been delivered"
    local ok, err = self:save(candidate)
    return nil, err, ok == true
end

function Recovery:settle(op, ok, reason)
    if not self.receipt then return nil, "There is no active personal gear recovery receipt" end
    local candidate = copy(self.receipt)
    local intent = candidate.intent
    local entry = intent and candidate.entries[intent.index]
    if not entry or not matches(op.item, entry) then return nil, "The completed operation does not match its personal gear receipt" end
    local observed = false
    if op.kind == "transfer" then
        observed = matches(op.destination:getItemWithID(entry.id), entry) and not matches(op.source:getItemWithID(entry.id), entry)
    elseif op.kind == "gear" then
        if op.mode == "unequip" then observed = not self.player:isEquipped(op.item)
        elseif op.mode == "primary" then
            observed = self.player:getPrimaryHandItem() == op.item and (not op.twoHands or self.player:getSecondaryHandItem() == op.item)
        elseif op.mode == "secondary" then observed = self.player:getSecondaryHandItem() == op.item
        elseif op.mode == "wear" then
            for _, slot in ipairs(wornSlots(self.player, op.item)) do if slot == op.slot then observed = true end end
        end
    end
    if observed then ok, reason = true, nil
    elseif ok then ok, reason = false, "The native personal gear operation ended without its expected result" end
    candidate.intent = nil
    if not ok then candidate.phase, candidate.reason = "blocked", reason or "Personal gear operation stopped; choose Recover personal gear to continue" end
    local saved, err = self:save(candidate)
    if not saved then return nil, err end
    return ok, reason
end

function Recovery:replaceIdentity(oldId, oldType, item)
    if not self.receipt then return true end
    local candidate, changed = copy(self.receipt), false
    for _, entry in ipairs(candidate.entries) do
        if tostring(entry.id) == tostring(oldId) and entry.fullType == oldType then
            entry.id, entry.fullType, changed = item:getID(), tostring(item:getFullType()), true
        end
        for _, child in ipairs(entry.children) do
            if tostring(child.id) == tostring(oldId) and child.fullType == oldType then
                child.id, child.fullType, changed = item:getID(), tostring(item:getFullType()), true
            end
        end
    end
    if changed then return self:save(candidate) end
    return true
end

return Recovery
