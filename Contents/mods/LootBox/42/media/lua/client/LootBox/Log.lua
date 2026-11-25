-- One local trace that explains a player interaction from intent to outcome.
-- Every line belongs to an interaction (#n): what was asked and from where, the
-- player and containers at that moment, each native operation with the state
-- around it, and how it ended. Files live in Zomboid/Lua/LootBox/log and never
-- leave the machine. Logging must never be able to break an action.
local Log = { slots = 5, maxBytes = 4 * 1024 * 1024, detailed = true }

local LEVEL = { trace = 1, info = 2, warn = 3, error = 4 }
local DIRECTORY = "LootBox/log/"
local FLUSH_MS, MAX_BUFFER = 1000, 400
local buffer, bytes, lastFlush, slot, stopped = {}, 0, 0, nil, false
local nextId, seenErrors = 1, {}

local function try(object, method, ...)
    if object == nil then return nil end
    local ok, value = pcall(function(...)
        local fn = object[method]
        if fn == nil then return nil end
        return fn(object, ...)
    end, ...)
    if ok then return value end
end

local function is(object, class)
    if object == nil or not instanceof then return false end
    local ok, result = pcall(instanceof, object, class)
    return ok and result == true
end

local function stamp() return getTimestampMs and getTimestampMs() or 0 end

local function round(value, places)
    if type(value) ~= "number" then return tostring(value) end
    if value == math.huge then return "inf" end
    local text = string.format("%." .. (places or 2) .. "f", value)
    if text:find(".", 1, true) then text = text:gsub("0+$", ""):gsub("%.$", "") end
    return text
end
Log.number = round

local function quote(value)
    if value == nil then return "-" end
    if type(value) == "number" then return round(value, 3) end
    local text = tostring(value):gsub("[\r\n]+", " / ")
    if text == "" then return '""' end
    if text:find("^[%w_%.%-%+:#/,@%%%[%]%(%)<>]+$") then return text end
    return '"' .. text:gsub('"', "'") .. '"'
end

-- Describers -------------------------------------------------------------

function Log.point(square)
    if square == nil then return "-" end
    if type(square) == "table" and square.x ~= nil and not square.getX then
        return tostring(square.x) .. "," .. tostring(square.y) .. "," .. tostring(square.z)
    end
    local x, y, z = try(square, "getX"), try(square, "getY"), try(square, "getZ")
    if x == nil then return "-" end
    return round(x, 0) .. "," .. round(y, 0) .. "," .. round(z, 0)
end

local function distance(player, square)
    local px, py = try(player, "getX"), try(player, "getY")
    local x, y = try(square, "getX"), try(square, "getY")
    if type(px) ~= "number" or type(x) ~= "number" then return nil end
    return math.sqrt((px - x - 0.5) ^ 2 + (py - y - 0.5) ^ 2)
end

-- Short identity, used inside item lines.
function Log.where(container)
    if container == nil then return "nowhere" end
    local bag = try(container, "getContainingItem")
    if bag then return "bag:" .. tostring(try(bag, "getFullType")) .. "#" .. tostring(try(bag, "getID")) end
    local part = try(container, "getVehiclePart")
    if part then
        return "vehicle:" .. tostring(try(try(part, "getVehicle"), "getScriptName")) .. "/" .. tostring(try(part, "getId"))
    end
    local parent = try(container, "getParent")
    if is(parent, "IsoPlayer") then return "main-inventory" end
    local kind = tostring(try(container, "getType"))
    if is(parent, "IsoDeadBody") then kind = "corpse" end
    local square = try(parent, "getSquare") or try(container, "getSourceGrid")
    return kind .. (square and ("@" .. Log.point(square)) or "")
end

local function listSize(list)
    local n = try(list, "size")
    return type(n) == "number" and n or nil
end

function Log.container(container, player)
    if container == nil then return "{none}" end
    local out = { Log.where(container) }
    local custom = try(container, "getCustomName")
    if custom and custom ~= "" then out[#out + 1] = "named=" .. quote(custom) end
    local parent = try(container, "getParent")
    if parent and not is(parent, "IsoPlayer") and not try(container, "getContainingItem") then
        local sprite = try(parent, "getSpriteName") or try(try(parent, "getSprite"), "getName")
        if sprite then out[#out + 1] = "sprite=" .. tostring(sprite) end
        local slotIndex, count = try(parent, "getContainerIndex", container), try(parent, "getContainerCount")
        if type(count) == "number" and count > 1 then out[#out + 1] = "compartment=" .. tostring(slotIndex) .. "/" .. tostring(count) end
        local index = try(parent, "getObjectIndex")
        if type(index) == "number" then out[#out + 1] = "object=" .. tostring(index) end
    end
    local items = listSize(try(container, "getItems"))
    out[#out + 1] = "items=" .. tostring(items or "?")
    local used = try(container, "getCapacityWeight")
    local capacity = player and try(container, "getEffectiveCapacity", player) or try(container, "getCapacity")
    if used or capacity then out[#out + 1] = "load=" .. round(used or 0) .. "/" .. round(capacity or 0) end
    out[#out + 1] = "explored=" .. tostring(try(container, "isExplored"))
    if player then
        if try(container, "isLockedToCharacter", player) == true then out[#out + 1] = "LOCKED" end
        local square = try(parent, "getSquare")
        local far = distance(player, square)
        if far then out[#out + 1] = "dist=" .. round(far, 1) end
    end
    return "{" .. table.concat(out, " ") .. "}"
end

function Log.fluid(fluid)
    if fluid == nil then return nil end
    return quote(try(fluid, "getUiName") or "empty") .. ":" .. round(try(fluid, "getAmount") or 0, 3)
        .. "/" .. round(try(fluid, "getCapacity") or 0, 3) .. "L"
end

function Log.item(item, player)
    if item == nil then return "{none}" end
    if is(item, "IsoWorldInventoryObject") then item = try(item, "getItem") end
    local out = { tostring(try(item, "getFullType")) .. "#" .. tostring(try(item, "getID")),
        quote(try(item, "getName") or "?"), "in=" .. Log.where(try(item, "getContainer")) }
    local weight = try(item, "getUnequippedWeight")
    if weight then out[#out + 1] = "w=" .. round(weight) end
    local flags = {}
    if try(item, "isFavorite") == true then flags[#flags + 1] = "favorite" end
    if player and try(player, "isEquipped", item) == true then flags[#flags + 1] = "equipped"
    elseif try(item, "isEquipped") == true then flags[#flags + 1] = "worn-elsewhere" end
    if (try(item, "getAttachedSlot") or -1) >= 0 then flags[#flags + 1] = "attached" end
    if player and try(item, "isUnwanted", player) == true then flags[#flags + 1] = "unwanted" end
    if try(item, "isBroken") == true then flags[#flags + 1] = "broken" end
    if is(item, "Food") then
        flags[#flags + 1] = try(item, "isRotten") == true and "rotten" or try(item, "isFresh") == true and "fresh" or "stale"
    end
    if #flags > 0 then out[#out + 1] = "[" .. table.concat(flags, ",") .. "]" end
    local fluid = try(item, "getFluidContainer")
    if fluid then out[#out + 1] = "fluid=" .. Log.fluid(fluid) end
    if is(item, "InventoryContainer") then
        local contents = try(item, "getInventory") or try(item, "getItemContainer")
        out[#out + 1] = "holds=" .. tostring(listSize(try(contents, "getItems")) or "?") .. "(" .. round(try(contents, "getCapacityWeight") or 0)
            .. "/" .. round(try(contents, "getCapacity") or 0) .. ")"
    end
    local placed = try(item, "getWorldItem")
    if placed then out[#out + 1] = "ground=" .. Log.point(try(placed, "getSquare")) end
    return "{" .. table.concat(out, " ") .. "}"
end

function Log.vehicle(vehicle)
    if vehicle == nil then return "{none}" end
    return "{" .. tostring(try(vehicle, "getScriptName")) .. " key=" .. tostring(try(vehicle, "getKeyId"))
        .. " @" .. Log.point(try(vehicle, "getSquare")) .. "}"
end

function Log.queue(player)
    if not ISTimedActionQueue or not ISTimedActionQueue.getTimedActionQueue then return "-" end
    local ok, list = pcall(ISTimedActionQueue.getTimedActionQueue, player)
    if not ok or not list or not list.queue then return "-" end
    local names = {}
    for index, action in ipairs(list.queue) do
        if index > 6 then names[#names + 1] = "+" .. tostring(#list.queue - 6); break end
        names[#names + 1] = tostring(action.Type or "?")
    end
    return #names == 0 and "idle" or table.concat(names, ">")
end

function Log.player(player)
    if player == nil then return "{none}" end
    local square = try(player, "getCurrentSquare")
    local out = { "at=" .. Log.point(square) }
    local room = try(try(square, "getRoom"), "getName")
    if room then out[#out + 1] = "room=" .. quote(room) end
    local doing = {}
    for _, pair in ipairs({ { "isDead", "dead" }, { "isAsleep", "asleep" }, { "isAiming", "aiming" }, { "isAttacking", "attacking" },
        { "isSprinting", "sprinting" }, { "isRunning", "running" }, { "isMoving", "moving" }, { "isSneaking", "sneaking" } }) do
        if try(player, pair[1]) == true then doing[#doing + 1] = pair[2] end
    end
    if #doing > 0 then out[#out + 1] = "doing=" .. table.concat(doing, "+") end
    local vehicle = try(player, "getVehicle")
    if vehicle then out[#out + 1] = "seated=" .. Log.vehicle(vehicle) end
    local inventory = try(player, "getInventory")
    out[#out + 1] = "carry=" .. round(try(inventory, "getCapacityWeight") or 0) .. "/" .. round(try(inventory, "getEffectiveCapacity", player) or 0)
    for _, hand in ipairs({ { "getPrimaryHandItem", "right" }, { "getSecondaryHandItem", "left" } }) do
        local held = try(player, hand[1])
        if held then out[#out + 1] = hand[2] .. "=" .. tostring(try(held, "getFullType")) .. "#" .. tostring(try(held, "getID")) end
    end
    local worn, bags = try(player, "getWornItems"), {}
    for index = 0, (listSize(worn) or 0) - 1 do
        local item = try(try(worn, "get", index), "getItem")
        if is(item, "InventoryContainer") then
            local contents = try(item, "getInventory")
            bags[#bags + 1] = tostring(try(item, "getFullType")) .. "#" .. tostring(try(item, "getID")) .. "("
                .. round(try(contents, "getCapacityWeight") or 0) .. "/" .. round(try(contents, "getEffectiveCapacity", player) or 0)
                .. ",-" .. round(try(item, "getWeightReduction") or 0, 0) .. "%)"
        end
    end
    if #bags > 0 then out[#out + 1] = "worn=" .. table.concat(bags, ",") end
    out[#out + 1] = "queue=" .. Log.queue(player)
    return "{" .. table.concat(out, " ") .. "}"
end

function Log.request(request)
    if type(request) ~= "table" then return "{none}" end
    local filter, destination = request.filter or {}, request.destination or {}
    local what = filter.all and "everything" or (table.concat(filter.ids or {}, "+") .. " types:" .. table.concat(filter.types or {}, "+"))
    local out = { "what=" .. quote(#what > 400 and (what:sub(1, 400) .. "...") or what), "from=" .. tostring(request.scope) }
    if request.sourceContainer then out[#out + 1] = Log.where(request.sourceContainer) end
    if request.sourceContainers then out[#out + 1] = "sources=" .. #request.sourceContainers end
    if request.area then
        out[#out + 1] = "area=" .. request.area.x1 .. "," .. request.area.y1 .. ".." .. request.area.x2 .. "," .. request.area.y2 .. "@" .. request.area.z
    end
    out[#out + 1] = "to=" .. tostring(destination.kind)
    if destination.mode then out[#out + 1] = "mode=" .. tostring(destination.mode) end
    if destination.kind == "container" then out[#out + 1] = Log.where(destination.ref)
    elseif destination.kind == "floor" then out[#out + 1] = Log.point(destination.ref)
    elseif destination.kind == "vehicle" then out[#out + 1] = destination.ref and Log.vehicle(destination.ref) or "remembered" end
    if destination.labels and #destination.labels > 0 then out[#out + 1] = "labels=" .. table.concat(destination.labels, "+") end
    out[#out + 1] = "bags=" .. tostring(request.includeBags ~= false)
    if request.includeInventory then out[#out + 1] = "carried=true" end
    return "{" .. table.concat(out, " ") .. "}"
end

-- Writing ----------------------------------------------------------------

local function choose()
    if slot then return slot end
    local previous = 0
    local ok, reader = pcall(getFileReader, DIRECTORY .. "index.txt", false)
    if ok and reader then
        previous = tonumber(tostring(reader:readLine() or "")) or 0
        reader:close()
    end
    slot = previous % Log.slots + 1
    local writer = getFileWriter(DIRECTORY .. "index.txt", true, false)
    writer:write(tostring(slot)); writer:close()
    writer = getFileWriter(DIRECTORY .. "session-" .. slot .. ".txt", true, false)
    writer:write("LootBox log. One interaction = one #number. Times are local milliseconds since the session began.\n"); writer:close()
    return slot
end

function Log.flush()
    lastFlush = stamp()
    if #buffer == 0 then return end
    local lines = buffer
    buffer = {}
    if not getFileWriter or not getFileReader or stopped then return end
    local ok, err = pcall(function()
        local writer = getFileWriter(DIRECTORY .. "session-" .. choose() .. ".txt", true, true)
        writer:write(table.concat(lines, "\n") .. "\n")
        writer:close()
    end)
    if not ok then stopped = true; print("[LootBox] log file unavailable: " .. tostring(err)) end
end

function Log.path() return slot and ("Zomboid/Lua/" .. DIRECTORY .. "session-" .. slot .. ".txt") or nil end

local began
local function write(level, id, event, ...)
    if stopped and level < LEVEL.warn then return end
    if level == LEVEL.trace and not Log.detailed then return end
    local now = stamp()
    began = began or now
    local out = { string.format("%9.3f", (now - began) / 1000), level == LEVEL.warn and "WARN " or level == LEVEL.error and "ERROR" or "     ",
        id and ("#" .. tostring(id)) or "#-", event }
    local n = select("#", ...)
    for index = 1, n, 2 do
        local key, value = select(index, ...), select(index + 1, ...)
        if value ~= nil then
            local text = type(value) == "string" and value:sub(1, 1) == "{" and value or quote(value)
            out[#out + 1] = tostring(key) .. "=" .. text
        end
    end
    local line = table.concat(out, " ")
    if level >= LEVEL.info then print("[LootBox] " .. table.concat(out, " ", 3)) end
    if stopped then return end
    bytes = bytes + #line
    if bytes > Log.maxBytes then
        buffer[#buffer + 1] = "log limit reached for this session"
        Log.flush(); stopped = true
        return
    end
    buffer[#buffer + 1] = line
    if level >= LEVEL.warn or #buffer >= MAX_BUFFER then Log.flush() end
end

local function guarded(level, id, event, ...)
    local ok, err = pcall(write, level, id, event, ...)
    if not ok and not seenErrors[event] then
        seenErrors[event] = true
        print("[LootBox] log line failed for " .. tostring(event) .. ": " .. tostring(err))
    end
end

-- trace: file only. info: file and console. warn/error: also flushed at once.
function Log.trace(id, event, ...) guarded(LEVEL.trace, id, event, ...) end
function Log.info(id, event, ...) guarded(LEVEL.info, id, event, ...) end
function Log.warn(id, event, ...) guarded(LEVEL.warn, id, event, ...) end
function Log.error(id, event, ...) guarded(LEVEL.error, id, event, ...) end

-- Opens an interaction and returns its number. origin says which control was
-- used (menu.container, menu.item, toolbar.smart-take, window.plan, key, auto).
function Log.intent(origin, label, player, ...)
    local id = nextId
    nextId = nextId + 1
    guarded(LEVEL.info, id, "INTENT", "from", origin, "ask", label, "mode", isClient and isClient() and "MP" or "SP",
        "player", Log.player(player), ...)
    return id
end

-- Report a swallowed failure once per call site, then count repeats quietly.
function Log.fault(id, site, err, ...)
    local key = tostring(site) .. "|" .. tostring(err)
    local count = (seenErrors[key] or 0) + 1
    seenErrors[key] = count
    if count == 1 then guarded(LEVEL.error, id, "FAULT", "site", site, "error", tostring(err), ...)
    elseif count % 100 == 0 then guarded(LEVEL.trace, id, "FAULT-REPEAT", "site", site, "count", count) end
end

-- pcall that cannot hide a defect.
function Log.guard(site, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    Log.fault(nil, site, a)
end

function Log.tick()
    if #buffer > 0 and stamp() - lastFlush >= FLUSH_MS then Log.flush() end
end

function Log.reset()
    Log.flush()
    seenErrors = {}
end

if Events then
    if Events.OnTickEvenPaused then Events.OnTickEvenPaused.Add(Log.tick)
    elseif Events.OnTick then Events.OnTick.Add(Log.tick) end
    if Events.OnDisconnect then Events.OnDisconnect.Add(Log.reset) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(Log.reset) end
end

return Log
