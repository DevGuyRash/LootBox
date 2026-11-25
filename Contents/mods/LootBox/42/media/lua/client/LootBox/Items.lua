-- The one answer to "where is this item now?" and "what did my action make?".
--
-- A multiplayer item can come back as a new object under the same id, and some
-- stock actions delete an item and make another with a random id. Either way
-- the server sends the change before it reports the action done, on the same
-- ordered channel, so a result can be looked up as soon as the action performs.
local Log = require "LootBox/Log"

local Items = {}
local MAX_CONTAINERS, MAX_ITEMS = 128, 8192

-- Calls visit(item, holder) for everything carried, outermost first, until it
-- returns something true. Returns that item and its holder.
function Items.eachCarried(player, visit)
    local main = player:getInventory()
    local queue, seen, count = { main }, { [main] = true }, 0
    for _, holder in ipairs(queue) do
        local list = holder:getItems()
        for index = 0, list:size() - 1 do
            local item = list:get(index)
            count = count + 1
            if count > MAX_ITEMS then return nil end
            if item then
                if visit(item, holder) then return item, holder end
                local inside = item.getInventory and item:getInventory()
                if inside and not seen[inside] and #queue < MAX_CONTAINERS then
                    seen[inside] = true
                    queue[#queue + 1] = inside
                end
            end
        end
    end
end

-- Calls visit(item, square) for the items lying on and around the player's tile.
function Items.eachNearby(player, visit)
    local here, cell = player:getCurrentSquare(), getCell and getCell()
    if not here or not cell then return nil end
    for dx = -1, 1 do
        for dy = -1, 1 do
            local square = cell:getGridSquare(here:getX() + dx, here:getY() + dy, here:getZ())
            local list = square and square:getWorldObjects()
            for index = 0, (list and list:size() or 0) - 1 do
                local object = list:get(index)
                local item = object and object:getItem()
                if item and visit(item, square) then return item, square end
            end
        end
    end
end

-- The item with this id, in whatever object now represents it, its holder, and
-- "carried", "container" (one of those given) or "ground" (beside the player).
function Items.find(player, id, containers)
    local function same(item) return item:getID() == id end
    local item, holder = Items.eachCarried(player, same)
    if item then return item, holder, "carried" end
    for _, container in ipairs(containers or {}) do
        item = container:getItemWithID(id)
        if item then return item, container, "container" end
    end
    item = Items.eachNearby(player, same)
    if item then return item, item:getContainer(), "ground" end
end

-- Exactly one carried item has this id and it is this object. Stock requests
-- name items by id, so a duplicate could act on the wrong one.
function Items.unique(player, item)
    local id, count = item:getID(), 0
    Items.eachCarried(player, function(candidate)
        if candidate:getID() == id then count = count + (candidate == item and 1 or 2) end
        return count > 1
    end)
    return count == 1
end

function Items.holds(container, item)
    return container ~= nil and item ~= nil and item:getContainer() == container and container:contains(item) == true
end

function Items.equipped(player, item)
    return item == player:getPrimaryHandItem() or item == player:getSecondaryHandItem()
        or (player.isEquipped and player:isEquipped(item) == true)
        or (player.isAttachedItem and player:isAttachedItem(item) == true)
        or (item.isWorn and item:isWorn() == true)
end

local Watch = {}
Watch.__index = Watch

-- Remembers everything in reach before an action, to tell its result apart
-- from what was already there.
--   item   what the action works on; it may survive under the same id
--   ready  ready(item): the survivor is what we wanted
--   makes  makes(item): false, or how well a new item fits (true or a number)
function Items.watch(player, opts)
    local watch = setmetatable({ player = player, known = {}, interaction = opts.interaction, ready = opts.ready, makes = opts.makes,
        id = opts.item and opts.item:getID() }, Watch)
    local function remember(item) watch.known[item:getID()] = true end
    Items.eachCarried(player, remember)
    Items.eachNearby(player, remember)
    return watch
end

-- A carried answer before one on the ground. The game drops a result on the
-- player's own tile when they are overloaded.
local function rank(player, place)
    if not place.getItems then return place == player:getCurrentSquare() and 0 or nil end
    return place == player:getInventory() and 2 or 1
end

-- The result: an item, its holder (nil on the ground), and whether it is the
-- original. Two equally good new items are equally good answers: both are the
-- player's, and neither existed when the action started.
function Watch:find()
    if self.id and self.ready then
        local item, holder = Items.find(self.player, self.id)
        if item and self.ready(item) then return item, holder, true end
    end
    if not self.makes then return nil end
    local best, bestHolder, bestScore, bestRank, matches = nil, nil, nil, nil, 0
    local function consider(item, place)
        local id = item:getID()
        if self.known[id] then return end
        local score = self.makes(item)
        if not score then return end
        score = type(score) == "number" and score or 0
        local placed = rank(self.player, place)
        if not placed then return end
        matches = matches + 1
        local carried, bestCarried = placed > 0, bestRank ~= nil and bestRank > 0
        if not best or carried and not bestCarried or carried == bestCarried and (score > bestScore
            or score == bestScore and (placed > bestRank or placed == bestRank and id < best:getID())) then
            best, bestHolder, bestScore, bestRank = item, place.getItems and place or nil, score, placed
        end
    end
    Items.eachCarried(self.player, consider)
    Items.eachNearby(self.player, consider)
    if best and not self.logged then
        self.logged = true
        Log.trace(self.interaction, "RESULT", "item", Log.item(best, self.player), "matches", matches, "score", bestScore, "place", bestRank)
    end
    return best, bestHolder, false
end

-- The original is gone: not carried, and not on the ground here.
function Watch:retired()
    return self.id == nil or Items.find(self.player, self.id) == nil
end

return Items
