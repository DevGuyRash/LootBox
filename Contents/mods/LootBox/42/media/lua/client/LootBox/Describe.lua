-- Plain-language names shared by menus, windows, the job bar and the log.
local Describe = {}

local function call(object, method, ...)
    if not object then return nil end
    local ok, value = pcall(function(...) return object[method](object, ...) end, ...)
    if ok then return value end
end

local function translated(key)
    local text = getTextOrNull and getTextOrNull(key)
    if text and text ~= "" and text ~= key then return text end
end

function Describe.category(id, definition)
    if definition then return definition.name end
    local raw = id:match("^native:(.+)$")
    return raw and (translated("IGUI_ItemCat_" .. raw) or raw) or "Removed category"
end

function Describe.type(fullType)
    return getItemNameFromFullType and getItemNameFromFullType(fullType) or fullType
end

function Describe.container(container)
    if not container then return "a container" end
    local item = call(container, "getContainingItem")
    if item then return tostring(call(item, "getName") or "bag") end
    local part = call(container, "getVehiclePart")
    if part then
        local id = tostring(call(part, "getId") or "vehicle storage")
        return translated("IGUI_VehiclePart" .. id) or id
    end
    local parent = call(container, "getParent")
    if parent and instanceof(parent, "IsoPlayer") then return "main inventory" end
    if parent and instanceof(parent, "IsoDeadBody") then return "corpse" end
    local custom = call(container, "getCustomName")
    if type(custom) == "string" and custom ~= "" then return custom end
    local raw = tostring(call(container, "getType") or "container")
    if raw == "floor" then return "the ground" end
    return translated("IGUI_ContainerTitle_" .. raw) or (raw:sub(1, 1):upper() .. raw:sub(2))
end

function Describe.vehicle(vehicle)
    if not vehicle then return "my vehicle" end
    if ISVehicleMenu and ISVehicleMenu.getVehicleDisplayName then
        local ok, name = pcall(ISVehicleMenu.getVehicleDisplayName, vehicle)
        if ok and name then return tostring(name) end
    end
    return tostring(call(call(vehicle, "getScript"), "getName") or "vehicle")
end

function Describe.texture(fullType)
    local script = getScriptManager and call(getScriptManager(), "getItem", fullType)
    return script and call(script, "getNormalTexture") or nil
end

function Describe.what(filter, category)
    filter = filter or {}
    if filter.all then return "everything" end
    local names = {}
    for _, id in ipairs(filter.ids or {}) do names[#names + 1] = Describe.category(id, category and category(id)) end
    for _, fullType in ipairs(filter.types or {}) do names[#names + 1] = Describe.type(fullType) end
    if #names == 0 then return "nothing yet" end
    if #names <= 2 then return table.concat(names, " and ") end
    return names[1] .. ", " .. names[2] .. " +" .. tostring(#names - 2)
end

local scopes = { inventory = "what I carry", reach = "within reach", room = "this room", building = "this building",
    area = "the marked area", labeled = "labelled containers", lootPane = "the open containers" }

function Describe.from(request)
    if request.scope == "container" then return request.sourceContainer and Describe.container(request.sourceContainer) or "the clicked container" end
    return scopes[request.scope] or "a chosen place"
end

function Describe.to(request)
    local destination = request.destination or {}
    local kind = destination.kind
    if kind == "inventory" then return "my bags" end
    if kind == "floor" then return "the floor" end
    if kind == "container" then return destination.ref and Describe.container(destination.ref) or "the clicked container" end
    if kind == "vehicle" then return Describe.vehicle(destination.ref) end
    if kind == "labels" then return "where it belongs" end
    if kind == "matching" then return destination.mode == "displayed" and "the open container" or "matching containers" end
    if kind == "trash" then return "a trash can" end
    return "a destination"
end

-- A short job title: verb first, then what makes this job different.
function Describe.title(request, category)
    local kind = request.destination and request.destination.kind
    local what, from = Describe.what(request.filter, category), Describe.from(request)
    if kind == "condense" or request.shortcutIntent == "condense" then return "Condense bags" end
    if kind == "trash" then return "Throw away " .. what .. " from " .. from end
    if kind == "inventory" then return "Take " .. what .. " from " .. from end
    if kind == "labels" then return "Put away " .. what .. " from " .. from end
    return "Move " .. what .. " from " .. from .. " to " .. Describe.to(request)
end

return Describe
