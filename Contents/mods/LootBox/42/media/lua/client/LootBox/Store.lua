local Log = require "LootBox/Log"
local Sort = require "LootBox/Sort"

local Store = {}
local MAX_BYTES, MAX_DEPTH, MAX_ENTRIES = 8 * 1024 * 1024, 64, 200000
local wide, character = pcall(string.char, 256)
local UNIT_WIDTH = wide and #character == 1 and character:byte() == 256 and 4 or 2

-- path -> the last complete slot this session read or wrote
local known = {}
local hex = {}

local function checksum(value)
    local first, second = 1, 0
    for index = 1, #value do
        first = (first + value:byte(index)) % 65521
        second = (second + first) % 65521
    end
    return string.format("%08x", second * 65536 + first)
end

local function encodeValue(value, output, visiting, depth, budget)
    local function append(part)
        budget.bytes = budget.bytes + #part
        if budget.bytes > MAX_BYTES then error("Saved data exceeds the local storage limit") end
        output[#output + 1] = part
    end
    local kind = type(value)
    if kind == "string" then
        if #value * UNIT_WIDTH > MAX_BYTES - budget.bytes then error("Saved data exceeds the local storage limit") end
        local parts, format = {}, UNIT_WIDTH == 4 and "%04x" or "%02x"
        for index = 1, #value do
            local unit = value:byte(index)
            if not hex[unit] then hex[unit] = string.format(format, unit) end
            parts[index] = hex[unit]
        end
        append((UNIT_WIDTH == 4 and "u" or "s") .. #value .. ":" .. table.concat(parts))
    elseif kind == "boolean" then
        append(value and "y" or "n")
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then error("Saved numbers must be finite") end
        append("d" .. string.format("%.17g", value) .. ";")
    elseif kind == "table" then
        if depth >= MAX_DEPTH then error("Saved data is nested too deeply") end
        if visiting[value] then error("Saved data contains a table cycle") end
        visiting[value] = true
        local keys = {}
        for key in pairs(value) do
            if type(key) ~= "string" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
                error("Saved table keys must be strings or positive integers")
            end
            keys[#keys + 1] = key
        end
        budget.count = budget.count + #keys
        if budget.count > MAX_ENTRIES then error("Saved data has too many entries") end
        Sort(keys, function(key)
            if type(key) == "number" then return 0, key, "" end
            return 1, 0, key
        end)
        append("m" .. #keys .. ":")
        for _, key in ipairs(keys) do
            encodeValue(key, output, visiting, depth + 1, budget)
            encodeValue(value[key], output, visiting, depth + 1, budget)
        end
        visiting[value] = nil
    else
        error("Saved data cannot contain " .. kind)
    end
end

local function encodeBody(value)
    if type(value) ~= "table" then return nil, "Saved data must be a table" end
    local output = {}
    local ok, err = pcall(encodeValue, value, output, {}, 0, { count = 0, bytes = 0 })
    if not ok then return nil, tostring(err) end
    local body = table.concat(output)
    if #body > MAX_BYTES then return nil, "Saved data exceeds the local storage limit" end
    return body
end

function Store.encode(value)
    local body, err = encodeBody(value)
    if not body then return nil, err end
    return "LBD1|" .. checksum(body) .. "|" .. body
end

function Store.decode(value)
    if type(value) ~= "string" or #value > MAX_BYTES + 14 then return nil, "Invalid saved data length" end
    local expected, body = value:match("^LBD1|(%x%x%x%x%x%x%x%x)|(.*)$")
    if not body then return nil, "Unsupported or damaged saved data header" end
    if checksum(body) ~= expected then return nil, "Saved data checksum does not match" end
    local position, entries = 1, 0
    local function natural(delimiter)
        local ending = body:find(delimiter, position, true)
        if not ending then error("Truncated saved data") end
        local text = body:sub(position, ending - 1)
        if not text:match("^%d+$") or #text > 10 then error("Invalid saved length") end
        local number = tonumber(text)
        if number > MAX_BYTES then error("Saved length exceeds storage limit") end
        position = ending + 1
        return number
    end
    local function parse(depth)
        local tag = body:sub(position, position)
        position = position + 1
        if tag == "s" or tag == "u" then
            local width = tag == "u" and 4 or 2
            local length = natural(":") * width
            local text = body:sub(position, position + length - 1)
            if #text ~= length or text:find("[^%x]") then error("Invalid saved string") end
            position = position + length
            local parts = {}
            for index = 1, length, width do
                parts[#parts + 1] = string.char(tonumber(text:sub(index, index + width - 1), 16))
            end
            return table.concat(parts)
        elseif tag == "y" then return true
        elseif tag == "n" then return false
        elseif tag == "d" then
            local ending = body:find(";", position, true)
            if not ending then error("Truncated saved number") end
            local text = body:sub(position, ending - 1)
            if #text > 32 or text:find("[^0-9%.%+%-eE]") then error("Invalid saved number") end
            local number = tonumber(text)
            if not number or number ~= number or number == math.huge or number == -math.huge then error("Invalid saved number") end
            position = ending + 1
            return number
        elseif tag == "m" then
            if depth >= MAX_DEPTH then error("Saved data is nested too deeply") end
            local count, result, seen = natural(":"), {}, {}
            entries = entries + count
            if entries > MAX_ENTRIES then error("Saved data has too many entries") end
            for _ = 1, count do
                local key = parse(depth + 1)
                if type(key) ~= "string" and (type(key) ~= "number" or key < 1 or key % 1 ~= 0) then
                    error("Invalid saved table key")
                end
                if seen[key] then error("Duplicate saved table key") end
                seen[key] = true
                result[key] = parse(depth + 1)
            end
            return result
        end
        error("Invalid saved data tag")
    end
    local ok, result = pcall(parse, 0)
    if not ok then return nil, tostring(result) end
    if position ~= #body + 1 then return nil, "Unexpected data after saved value" end
    if type(result) ~= "table" then return nil, "Saved data must be a table" end
    return result
end

local function validPath(path)
    return type(path) == "string" and #path > 0
        and path:match("^[%w_./%-]+$") ~= nil and path:sub(1, 1) ~= "/" and not path:find("..", 1, true)
end

-- Returns the slot text, or nil with an error; text that cannot be used comes back third.
local function readFile(path)
    local ok, reader = pcall(getFileReader, path, false)
    if not ok then return nil, "Cannot open " .. path .. ": " .. tostring(reader) end
    if not reader then return nil end
    local readOk, value, extra = pcall(function() return reader:readLine(), reader:readLine() end)
    local closeOk, closeError = pcall(function() reader:close() end)
    if not readOk then return nil, "Cannot read " .. path .. ": " .. tostring(value) end
    if not closeOk then return nil, "Cannot close " .. path .. ": " .. tostring(closeError) end
    if extra ~= nil then return nil, "Unexpected extra lines in " .. path, tostring(value) .. "\n" .. tostring(extra) end
    if value == nil then return nil, "Empty saved slot " .. path, "" end
    return tostring(value)
end

local function readSlot(path)
    local text, err, damaged = readFile(path)
    if not text then return nil, err, damaged end
    local revision, payload = text:match("^LBS1|(%d+)|(.*)$")
    revision = revision and tonumber(revision)
    if not revision or revision < 1 or revision > 9007199254740990 or revision % 1 ~= 0 then
        return nil, "Invalid saved slot generation in " .. path, text
    end
    local decoded
    decoded, err = Store.decode(payload)
    if not decoded then return nil, "Cannot load " .. path .. ": " .. err, text end
    return { revision = revision, value = decoded, body = payload:sub(15), text = text, path = path }
end

-- damaged lists every unusable slot text; it is nil when a slot could not be read at all.
local function slots(path)
    local a, aError, aText = readSlot(path .. ".a.txt")
    local b, bError, bText = readSlot(path .. ".b.txt")
    if a and b then
        if a.revision == b.revision and a.body ~= b.body then
            return nil, "Conflicting saved slot generations", nil, {a.text, b.text}, a.revision
        end
        return b.revision > a.revision and b or a
    end
    if a then return a, nil, bError end
    if b then return b, nil, aError end
    local damaged, revision = {}, 0
    for _, slot in ipairs({{aError, aText}, {bError, bText}}) do
        if slot[1] and not slot[2] then return nil, aError or bError end
        if slot[2] then
            damaged[#damaged + 1] = slot[2]
            local found = tonumber(slot[2]:match("^LBS1|(%d%d?%d?%d?%d?%d?%d?%d?%d?)|") or 0)
            revision = math.max(revision, found)
        end
    end
    return nil, aError or bError, nil, damaged, revision
end

-- Returns the saved value, or nil with an error. The third result carries
-- recovered/warning, or damaged = true when Store.save would keep a backup and replace it.
function Store.load(path)
    if not validPath(path) then return nil, "Invalid local storage path" end
    if type(getFileReader) ~= "function" then return nil, "Native local file reading is unavailable" end
    local current, err, warning, damaged = slots(path)
    known[path] = current
    if err then Log.warn(nil, "STORE", "load", path, "error", err) end
    if not current then return nil, err, err and {damaged = damaged ~= nil and #damaged > 0} or nil end
    if warning then Log.warn(nil, "STORE", "load", path, "recovered", warning) end
    return current.value, nil, { revision = current.revision, recovered = warning ~= nil, warning = warning }
end

local function writeText(path, text, append)
    local opened, writer = pcall(getFileWriter, path, true, append == true)
    if not opened or not writer then return nil, "Cannot open saved slot " .. path end
    local wrote, writeError = pcall(function() writer:write(text) end)
    local closed, closeError = pcall(function() writer:close() end)
    if not wrote then return nil, "Cannot write " .. path .. ": " .. tostring(writeError) end
    if not closed then return nil, "Cannot close " .. path .. ": " .. tostring(closeError) end
    return true
end

function Store.save(path, value)
    if not validPath(path) then return nil, "Invalid local storage path" end
    if type(getFileReader) ~= "function" or type(getFileWriter) ~= "function" then
        return nil, "Native local file storage is unavailable"
    end
    local body, err = encodeBody(value)
    if not body then return nil, err end
    local current, damaged, revision = known[path], nil, nil
    -- A raw read proves the remembered slot is still the file on disk without decoding it.
    if not current or readFile(current.path) ~= current.text then
        local loadError, warning
        current, loadError, warning, damaged, revision = slots(path)
        if not current and loadError and not damaged then return nil, loadError end
    end
    known[path] = current
    if current and current.body == body then return true end
    if damaged and #damaged > 0 then
        local kept, problem = writeText(path .. ".damaged.txt", table.concat(damaged, "\n") .. "\n", true)
        if not kept then return nil, "Damaged save could not be backed up: " .. problem end
        Log.warn(nil, "STORE", "replaced", path, "backup", path .. ".damaged.txt")
    end
    local target = path .. ".a.txt"
    if current and current.path == target then target = path .. ".b.txt" end
    revision = (current and current.revision or revision or 0) + 1
    if revision > 9007199254740990 then return nil, "Saved generation limit reached" end
    local text = "LBS1|" .. string.format("%.0f", revision) .. "|LBD1|" .. checksum(body) .. "|" .. body
    local wrote, writeError = writeText(target, text)
    local stored, readError = readFile(target)
    if stored == text then
        known[path] = { revision = revision, body = body, text = text, path = target }
        return true
    end
    return nil, writeError or readError or "Saved slot failed readback verification"
end

return Store
