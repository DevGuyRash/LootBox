local Routing = {}
Routing.__index = Routing

local WALK_SPEED, FLOOR_SECONDS, CELL_SIZE, MAX_ROUTES = 1.4, 8, 4, 256

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function nonnegative(value)
    return finite(value) and value >= 0
end

local function point(value)
    return type(value) == "table" and finite(value.x) and finite(value.y) and finite(value.z)
        and math.abs(value.x) <= 2147483647 and math.abs(value.y) <= 2147483647 and math.abs(value.z) <= 2147483647
end

local function cell(value)
    return tostring(math.floor(value.x / CELL_SIZE)) .. ":" .. tostring(math.floor(value.y / CELL_SIZE))
        .. ":" .. tostring(math.floor(value.z))
end

local function direct(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    return math.sqrt(dx * dx + dy * dy) / WALK_SPEED + math.abs(to.z - from.z) * FLOOR_SECONDS
end

function Routing.new()
    return setmetatable({ routes = {}, order = {} }, Routing)
end

function Routing:estimate(from, to)
    if not point(from) or not point(to) then return nil, "Invalid route coordinates" end
    local estimate = direct(from, to)
    local first, last = cell(from), cell(to)
    local previous = first ~= last and self.routes[first .. ">" .. last]
    if previous then
        return previous.seconds * math.max(0.5, math.min(2, estimate / previous.direct)), "observed"
    end
    return estimate, "estimated"
end

function Routing:observe(from, to, distance, elapsedMs)
    if not point(from) or not point(to) or not finite(distance) or distance <= 0
        or not finite(elapsedMs) or elapsedMs <= 0 then return nil, "Invalid observed travel" end
    local first, last = cell(from), cell(to)
    local estimate = direct(from, to)
    if first == last or estimate <= 0 then return false end
    local key, seconds = first .. ">" .. last, elapsedMs / 1000
    local previous = self.routes[key]
    if previous then
        previous.seconds = previous.seconds + (seconds - previous.seconds) / 2
        previous.direct = previous.direct + (estimate - previous.direct) / 2
        previous.distance = previous.distance + (distance - previous.distance) / 2
    else
        if #self.order >= MAX_ROUTES then self.routes[table.remove(self.order, 1)] = nil end
        self.order[#self.order + 1] = key
        self.routes[key] = { seconds = seconds, direct = estimate, distance = distance }
    end
    return true
end

local function validCandidate(candidate, count)
    if type(candidate) ~= "table" or candidate.container == nil or type(candidate.key) ~= "string" or candidate.key == ""
        or not nonnegative(candidate.capacity) or not nonnegative(candidate.used)
        or not nonnegative(candidate.outbound) or not nonnegative(candidate.returnCost)
        or not nonnegative(candidate.repeatCost)
        or (candidate.emptySeconds ~= nil and not nonnegative(candidate.emptySeconds))
        or (candidate.deferredTravel ~= nil and not nonnegative(candidate.deferredTravel))
        or (candidate.deferredEmptyCount ~= nil and (not nonnegative(candidate.deferredEmptyCount)
            or candidate.deferredEmptyCount ~= math.floor(candidate.deferredEmptyCount))) then return false end
    if candidate.accepts ~= nil then
        if type(candidate.accepts) ~= "table" then return false end
        for index, allowed in pairs(candidate.accepts) do
            if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > count
                or type(allowed) ~= "boolean" then return false end
        end
    end
    return true
end

local function accepts(candidate, index, weight)
    return weight <= candidate.capacity and (not candidate.accepts or candidate.accepts[index] ~= false)
end

local function scored(candidate, weights, tripCapacity, totalWeight)
    if not accepts(candidate, 1, weights[1]) then return nil end
    local fill, occupied = candidate.used, candidate.used > 0
    local emptyCount, unserved, unservedWeight = 0, 0, 0
    for index, weight in ipairs(weights) do
        if accepts(candidate, index, weight) then
            if fill + weight > candidate.capacity then
                if occupied then emptyCount = emptyCount + 1 end
                fill, occupied = 0, false
            end
            fill, occupied = fill + weight, true
        else
            unserved, unservedWeight = unserved + 1, unservedWeight + weight
        end
    end
    if occupied then emptyCount = emptyCount + 1 end
    emptyCount = emptyCount + (candidate.deferredEmptyCount or 0)
    local trips = totalWeight == 0 and 1 or math.max(1, math.ceil(totalWeight / tripCapacity))
    local emptySeconds = candidate.emptySeconds or 2
    local fallbackTrips = unserved == 0 and 0 or (unservedWeight == 0 and 1 or math.max(1, math.ceil(unservedWeight / tripCapacity)))
    local unservedPenalty = fallbackTrips * (candidate.returnCost + candidate.repeatCost + emptySeconds)
        + unserved * emptySeconds
    local cost = candidate.outbound + (trips - 1) * (candidate.returnCost + candidate.repeatCost)
        + emptyCount * emptySeconds + unservedPenalty + (candidate.deferredTravel or 0)
    if not finite(cost) then return nil end
    local reason = tostring(trips) .. " estimated hauling trips, " .. tostring(emptyCount) .. " bin emptyings"
    if unserved > 0 then reason = reason .. ", " .. tostring(unserved) .. " items need another bin" end
    return { container = candidate.container, key = candidate.key, cost = cost, emptyCount = emptyCount,
        trips = trips, unserved = unserved, unservedPenalty = unservedPenalty, reason = reason }
end

function Routing.rank(candidates, weights, tripCapacity)
    if type(candidates) ~= "table" or type(weights) ~= "table" or #weights == 0 or not nonnegative(tripCapacity) then return {} end
    local count = 0
    for index, weight in pairs(weights) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #weights or not nonnegative(weight) then return {} end
        count = count + 1
    end
    local totalWeight = 0
    for _, weight in ipairs(weights) do totalWeight = totalWeight + weight end
    if count ~= #weights or not finite(totalWeight) or (tripCapacity == 0 and totalWeight > 0) then return {} end
    local result = {}
    for index, candidate in ipairs(candidates) do
        if validCandidate(candidate, #weights) then
            local score = scored(candidate, weights, tripCapacity, totalWeight)
            if score then score.order = index; result[#result + 1] = score end
        end
    end
    table.sort(result, function(a, b)
        if a.cost ~= b.cost then return a.cost < b.cost end
        if a.unserved ~= b.unserved then return a.unserved < b.unserved end
        if a.key ~= b.key then return a.key < b.key end
        return a.order < b.order
    end)
    for _, score in ipairs(result) do score.order = nil end
    return result
end

return Routing
