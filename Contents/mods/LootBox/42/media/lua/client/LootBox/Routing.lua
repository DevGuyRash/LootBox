local Routing = {}
Routing.__index = Routing

local WALK_SPEED, FLOOR_SECONDS, CELL_SIZE, MAX_ROUTES = 1.4, 8, 4, 256

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
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

return Routing
