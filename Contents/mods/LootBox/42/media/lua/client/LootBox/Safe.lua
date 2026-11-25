local Log = require "LootBox/Log"

-- Native calls that may be missing or may throw return nil. A throw is logged
-- once per method so a defect is visible without flooding the log.
local reported = {}

local function dispatch(object, method, ...)
    local fn = object[method]
    if fn then return fn(object, ...) end
end

return function(object, method, ...)
    if not object then return nil end
    local ok, value = pcall(dispatch, object, method, ...)
    if ok then return value end
    if not reported[method] then
        reported[method] = true
        Log.fault(nil, "native:" .. method, value)
    end
end
