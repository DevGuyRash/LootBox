-- Where things belong. One ranking answers for jobs, menus, tooltips and the
-- Put Away button, so what a tooltip says is what a job does. World methods:
--
-- world:storages()              -> every labelled or named container, nearest first, loaded or not:
--                                  {key, labels, name, given, order, container or nil, point or nil, tiles, carried, vehicle}
-- world:storagePass(storages)   -> what the questions below share while the world stands still
-- world:storageFor(item, pass, destination) -> {storage, rank, rest}, best first
-- world:placement(item, destination, graph) -> how closely the storage it lies in is meant for it (see closeness), or nil
-- world:placesFor(item, pass, destination, mine) -> storageFor() from where the item lies, and its placement
-- world:homes(item)             -> placesFor() for a tooltip or menu, answered from a moment ago, and whether it is in its place
-- world:home(item)              -> the one of those a job would use
-- world:putAway(fixed, only)    -> {item, storage, rank} for each carried item with a place at hand
-- world:fitting(container)      -> {item}: carried things that belong in this container, whatever else would take them
-- world:labelsInside(container) -> labels for the kinds of item inside, and for their categories
-- world:contentsHaveHomes(container) -> boolean, something in it belongs somewhere else
-- world:nearStorage()           -> a string that stands for the storage at hand
-- world:nearHere(fixed)         -> destination.near for a job that stays around here
-- world:atHome(range)           -> the nearest storage that stays where it is, within range tiles
local Labels = require "LootBox/Labels"
local call = require "LootBox/Safe"
local Sort = require "LootBox/Sort"

local GLANCE_MS = 1000
local Storage = {HOME_RANGE = 20}

local function eachKey(state, visit)
    local keys, seen = {}, {}
    for _, field in ipairs({"containerLabels", "storage"}) do
        for key in pairs(state[field] or {}) do
            if not seen[key] and key:sub(1, 7) ~= "player:" then seen[key] = true; keys[#keys + 1] = key end
        end
    end
    for _, key in ipairs(Sort(keys)) do visit(key) end
end

local function pointOf(key)
    local kind, x, y, z = key:match("^(%a+):(%-?%d+):(%-?%d+):(%-?%d+):")
    if kind == "world" or kind == "corpse" then return {x = tonumber(x), y = tonumber(y), z = tonumber(z)} end
end

local function squarePoint(square)
    if square then return {x = square:getX(), y = square:getY(), z = square:getZ()} end
end

function Storage.plainName(container)
    local kind = tostring(call(container, "getType") or "Container")
    return getTextOrNull and getTextOrNull("IGUI_ContainerTitle_" .. kind) or kind
end

-- The game keeps a fixture's name on the object, where every player sees it. Bags are
-- renamed in the game's own menu. Vehicle parts have no name, so theirs are LootBox's.
local function fixture(container)
    local parent = call(container, "getParent")
    return parent ~= nil and call(container, "getType") ~= "floor" and not call(container, "getContainingItem")
        and not call(container, "getVehiclePart") and not instanceof(parent, "IsoGameCharacter") and not instanceof(parent, "IsoDeadBody")
end

-- The name the player gave a container, if any.
function Storage:givenName(container)
    if not container or call(container, "getType") == "floor" then return nil end
    if fixture(container) then
        local name = call(container, "getCustomName")
        return type(name) == "string" and name ~= "" and name ~= Storage.plainName(container) and name or nil
    end
    if Labels.none(self.state.storage) or call(container, "getContainingItem") then return nil end
    local key = self:key(container)
    return key and self.state.storage[key] and self.state.storage[key].name or nil
end

-- Returns whether the name now belongs to the game, or nil and why not.
function Storage:rename(container, name)
    if not fixture(container) then return false end
    if SafeHouse and not SafeHouse.isSafehouseAllowInteract(call(call(container, "getParent"), "getSquare"), self.player) then
        return nil, "This storage is in a safehouse you may not use"
    end
    container:setCustomName(name and name ~= "" and name or Storage.plainName(container))
    return true
end

-- Saved keys end in the part ID for vehicles and the container type for fixtures.
local function nameOf(key)
    local kind = key:sub(1, 4) == "bag:" and "Bag" or key:match("([^:]+)$") or "Container"
    return getTextOrNull and (getTextOrNull("IGUI_ContainerTitle_" .. kind) or getTextOrNull("IGUI_VehiclePart" .. kind)) or kind
end

function Storage:storages()
    return self:pass(function()
        local result, here = {}, squarePoint(call(self.player, "getCurrentSquare"))
        local function live(key)
            local container = self.endpoints[key]
            return container and self:valid(container) and container or nil
        end
        -- Asking a container for its key lets one that was moved up take its labels along.
        eachKey(self.state, function(key)
            local container = live(key)
            if container then self:key(container) end
        end)
        eachKey(self.state, function(key)
            local container, details = live(key), self.state.storage[key] or {}
            if container and self:key(container) ~= key then container = nil end
            local given = details.name
            if container and fixture(container) then
                given = self:givenName(container)
                -- Remembered for when it is out of sight.
                if given ~= details.name and (Labels.details({name = given}) or {}).name ~= details.name then
                    details = Labels.details({name = given, order = details.order}) or {}
                    self.state.storage[key], self.dirty = Labels.details(details), true
                end
            end
            local labels = {}
            for index, id in ipairs(self.state.containerLabels[key] or {}) do labels[index] = id end
            local point = container and squarePoint(self:square(container)) or pointOf(key)
            local name = given or container and self:name(container) or nameOf(key)
            local entry = {key = key, labels = labels, container = container, point = point, given = given, order = details.order,
                name = name, kind = key:sub(1, 4) == "bag:" and name or container and Storage.plainName(container) or nameOf(key), nameable = key:sub(1, 8) == "vehicle:" or container ~= nil and key:sub(1, 4) ~= "bag:",
                carried = container ~= nil and self:owns(container), vehicle = key:sub(1, 8) == "vehicle:"}
            entry.tiles = entry.carried and 0 or here and point and math.sqrt((here.x - point.x) ^ 2 + (here.y - point.y) ^ 2) or math.huge
            -- A floor away is further than it looks on the map.
            entry.away = entry.tiles + (here and point and not entry.carried and math.abs(here.z - point.z) * 10 or 0)
            result[#result + 1] = entry
        end)
        return Sort(result, function(entry) return entry.away, entry.key end)
    end)
end

function Storage:storagePass(storages, graph)
    return {graph = graph or self.graph, accepted = {}, types = {}, kinds = {}, storages = storages}
end

local function wanted(destination, id)
    local chosen = destination and destination.labels
    return not chosen or #chosen == 0 or Labels.has(chosen, id)
end

-- The closest of these labels that names the item, or nil when none do.
local function closest(destination, labels, graph, descriptor)
    local best
    for _, id in ipairs(labels or {}) do
        if wanted(destination, id) and graph:matches(id, descriptor) then
            -- A category given to this one copy says as much as a label for its kind.
            local rank = Labels.has(descriptor.labels, id) and not Labels.itemOf(id) and 2 or Labels.closeness(id)
            if not best or rank < best then best = rank end
        end
    end
    return best
end

local REST = Labels.closeness(Labels.REST)

-- An item is moved on from where it lies only to storage meant for it more closely:
-- 0 for the very item, 1 for its kind, 2 for a category, 3 for anything else.
local function closeness(rank) return rank == 1 and 0 or rank == 2 and 1 or rank < REST and 2 or 3 end

-- Storage meant for an item more closely comes first. Among equals, storage to fill first comes
-- before the rest and storage to fill last after it, as does a bag the player carries for loot of
-- that category; then where the same thing already lies, unless each names the item or its kind.
local function score(entry)
    local storage = entry.storage
    local last = storage.order == Labels.LAST or storage.carried and entry.closeness > 1
    return entry.closeness * 2 + (last and entry.closeness > 0 and 1 or 0),
        storage.order == Labels.FIRST and 0 or 1,
        (entry.closeness <= 1 and 0 or entry.similar * 10) + entry.rank
end

function Storage:storageFor(item, pass, destination)
    local descriptor, types = self:describe(item), self:similarTypes(pass, item)
    local id = descriptor.fullType .. "|" .. tostring(descriptor.categoryId) .. "|" .. table.concat(descriptor.labels, "|")
        .. "|" .. table.concat(types, "|") .. "|" .. table.concat(destination and destination.labels or {}, "|")
    local accepted = pass.accepted[id]
    if not accepted then
        accepted = {}
        for _, storage in ipairs(pass.graph and pass.storages or {}) do
            local rank = closest(destination, storage.labels, pass.graph, descriptor)
            if rank then
                accepted[#accepted + 1] = {storage = storage, rank = rank, closeness = closeness(rank),
                    similar = storage.container and self:holdsSimilar(pass, storage.container, types) and 0 or 1}
            end
        end
        -- storages() is nearest first, and equals keep their order.
        pass.accepted[id] = Sort(accepted, score)
    end
    return accepted
end

-- In storage, or in a bag or kit that is. The player's own bags are labelled for what they bring
-- home: only a label for that item or its kind makes one its place, and loot in one labelled by
-- category waits there for storage that stays put (a half step looser).
function Storage:placement(item, destination, graph)
    local descriptor, container, found = self:describe(item), call(item, "getContainer"), nil
    for _ = 1, 16 do
        if not container then return found end
        local key = self:key(container)
        local rank = key and closest(destination, self.state.containerLabels[key], graph or self.graph, descriptor)
        local value = rank and closeness(rank)
        if value and value > 1 and self:owns(container) then value = value + 0.5 end
        if value and (not found or value < found) then found = value end
        container = call(call(container, "getContainingItem"), "getContainer")
    end
    return found
end

-- Tooltips and buttons ask every frame, so one answer serves for a moment.
function Storage:glance()
    local stamp, known = getTimestampMs(), self.glanced
    if not known or stamp < known.stamp or stamp - known.stamp >= GLANCE_MS or known.graph ~= self.graph then
        self:pass(function() self:findLabelled() end)
        known = self:storagePass(self:storages())
        known.stamp, self.glanced = stamp, known
    end
    return known
end

-- What was changed shows at once.
function Storage:forgetGlance() self.glanced = nil end

-- Out of sight there is no telling whether a container is full.
local function takes(self, storage, item)
    local container = storage.container
    return container == nil or container ~= call(item, "getContainer") and call(container, "isInside", item) ~= true
        and call(container, "isItemAllowed", item) ~= false and call(container, "hasRoomFor", self.player, item) ~= false
end

-- Where it may go from where it lies, best first. What has a place moves on only to a closer one.
-- Something of the player's own whose place is a bag they carry stays with them.
function Storage:placesFor(item, pass, destination, mine)
    local placed, result = self:placement(item, destination, pass.graph), {}
    for _, entry in ipairs(placed ~= 0 and self:storageFor(item, pass, destination) or {}) do
        local own, loose = entry.storage.carried and mine, entry.storage.carried and entry.closeness > 1
        -- Loot waiting in a carried bag goes on to storage that stays put, not to another bag.
        local waiting = placed and placed % 1 ~= 0 and entry.storage.key:sub(1, 4) == "bag:"
        -- A key opens something; only storage labelled for keys takes one.
        local key = entry.closeness == 3 and instanceof(item, "Key")
        if (not placed or entry.closeness < placed) and not (loose and (mine or placed)) and not waiting and not key then
            result[#result + 1] = entry
            if own then break end
        end
    end
    return result, placed
end

function Storage:homes(item)
    local places, placed = self:placesFor(item, self:glance(), nil, self:owns(call(item, "getContainer")))
    local result = {}
    for _, entry in ipairs(places) do
        if not placed or entry.storage.container and takes(self, entry.storage, item) then result[#result + 1] = entry end
    end
    return result, placed ~= nil and #result == 0
end

-- The place an item goes: at hand, or else in sight, or else the first that is known. Then
-- whether it is in its place, and the first place when every one in sight is full.
function Storage:home(item)
    local homes, placed = self:homes(item)
    local best, score
    for _, entry in ipairs(homes) do
        local storage = entry.storage
        if storage.carried and #homes == 1 then return storage, placed end
        if takes(self, storage, item) then
            local value = not storage.container and 3 or storage.tiles <= Storage.HOME_RANGE and 1 or 2
            if not score or value < score then best, score = storage, value end
        end
    end
    return best, placed, not best and homes[1] and homes[1].storage or nil
end

-- Storage that stays where it is.
local function stays(storage)
    return storage.container and not storage.carried and not storage.vehicle and #storage.labels > 0
        and not call(storage.container, "getContainingItem")
end

function Storage:atHome(range)
    for _, storage in ipairs(self:glance().storages) do
        if stays(storage) and storage.tiles <= (range or Storage.HOME_RANGE) then return storage end
    end
end

-- Changes when the labelled storage at hand, or what it is labelled for, does.
function Storage:nearStorage()
    local glance = self:glance()
    if not glance.near then
        local parts = {}
        for _, storage in ipairs(glance.storages) do
            if storage.container and storage.tiles <= Storage.HOME_RANGE then
                parts[#parts + 1] = storage.key .. "=" .. table.concat(storage.labels, "+") .. "@" .. tostring(storage.order)
            end
        end
        glance.near = table.concat(parts, "|")
    end
    return glance.near
end

-- Keeps a job to the storage around where it started, and to what stays put when fixed.
function Storage:nearHere(fixed)
    local here = self:point()
    return here and {x = here.x, y = here.y, range = Storage.HOME_RANGE, fixed = fixed == true}
end

function Storage:atHand(storage, near)
    local point = storage.point
    if not storage.container or storage.carried or near.fixed and not stays(storage) or not point then return false end
    return (point.x - near.x) ^ 2 + (point.y - near.y) ^ 2 <= near.range ^ 2
end

-- The first place at hand of each item, or of those in only, with what is already promised to a
-- place taken off its room.
function Storage:putAway(fixed, only)
    local result, near, promised = {}, self:nearHere(fixed), {}
    if not near or Labels.none(self.state.containerLabels) then return result end
    return self:pass(function()
        for _, record in ipairs(self:records(call(self.player, "getInventory"), true)) do
            local item = record.item
            local weight = (not only or only[tostring(call(item, "getID"))]) and not self:protected(item) and (call(item, "getUnequippedWeight") or 0)
            for _, home in ipairs(weight and self:homes(item) or {}) do
                local container = home.storage.container
                if self:atHand(home.storage, near) and takes(self, home.storage, item) then
                    local used = (call(container, "getCapacityWeight") or 0) + (promised[container] or 0)
                    local capacity = call(container, "getEffectiveCapacity", self.player)
                    if not capacity or used + weight <= capacity + 0.001 then
                        promised[container] = (promised[container] or 0) + weight
                        result[#result + 1] = {item = item, storage = home.storage, rank = home.rank}
                        break
                    end
                end
            end
        end
        return result
    end)
end

-- A container for anything else is offered only what nothing else takes.
function Storage:fitting(container)
    return self:pass(function() return self:_fitting(container) end)
end

function Storage:_fitting(container)
    local result, labels = {}, self.state.containerLabels[self:key(container) or ""]
    if not labels or not self.graph then return result end
    for _, record in ipairs(self:records(call(self.player, "getInventory"), true)) do
        local item = record.item
        if record.source ~= container and call(container, "isInside", item) ~= true and not self:protected(item)
            and call(container, "isItemAllowed", item) ~= false then
            local rank = closest(nil, labels, self.graph, self:describe(item))
            local first = rank == REST and self:storageFor(item, self:glance())[1]
            if rank and not (first and first.closeness < 3) then result[#result + 1] = item end
        end
    end
    return result
end

function Storage:contentsHaveHomes(container)
    if Labels.none(self.state.containerLabels) then return false end
    return self:pass(function()
        for _, record in ipairs(self:records(container, false)) do
            if not self:protected(record.item) then
                for _, home in ipairs(self:homes(record.item)) do if home.storage.container then return true end end
            end
        end
        return false
    end)
end

-- Labels for what a container holds: its kinds of item, or the categories they come under, one
-- of the player's own where there is one.
function Storage:labelsInside(container)
    local types, categories, seen = {}, {}, {}
    local function add(list, id) if not seen[id] then seen[id] = true; list[#list + 1] = id end end
    for _, record in ipairs(self:records(container, false)) do
        local descriptor = record.descriptor
        add(types, Labels.ofType(descriptor.fullType))
        local own = self.graph and self.graph:customMatches(descriptor)[1]
        add(categories, own or descriptor.categoryId)
    end
    return Sort(types), Sort(categories)
end

return Storage
