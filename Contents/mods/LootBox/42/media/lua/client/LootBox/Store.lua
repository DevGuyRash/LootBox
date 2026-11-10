local Store = {}
local MAX_BYTES, MAX_DEPTH, MAX_ENTRIES = 8 * 1024 * 1024, 64, 200000
local wide, character = pcall(string.char, 256)
local UNIT_WIDTH = wide and #character == 1 and character:byte() == 256 and 4 or 2

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
        for index = 1, #value do parts[index] = string.format(format, value:byte(index)) end
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
        table.sort(keys, function(a, b)
            if type(a) ~= type(b) then return type(a) == "number" end
            return a < b
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

function Store.encode(value)
    if type(value) ~= "table" then return nil, "Saved data must be a table" end
    local output = {}
    local ok, err = pcall(encodeValue, value, output, {}, 0, { count = 0, bytes = 0 })
    if not ok then return nil, tostring(err) end
    local body = table.concat(output)
    if #body > MAX_BYTES then return nil, "Saved data exceeds the local storage limit" end
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

local function readFile(path)
    local ok, reader = pcall(getFileReader, path, false)
    if not ok then return nil, "Cannot open " .. path .. ": " .. tostring(reader) end
    if not reader then return nil end
    local readOk, value, extra = pcall(function() return reader:readLine(), reader:readLine() end)
    local closeOk, closeError = pcall(function() reader:close() end)
    if not readOk then return nil, "Cannot read " .. path .. ": " .. tostring(value) end
    if not closeOk then return nil, "Cannot close " .. path .. ": " .. tostring(closeError) end
    if extra ~= nil then return nil, "Unexpected extra lines in " .. path end
    if value == nil then return nil, "Empty saved slot " .. path end
    return tostring(value)
end

local function readSlot(path)
    local value, err = readFile(path)
    if not value then return nil, err end
    local revision, payload = value:match("^LBS1|(%d+)|(.*)$")
    revision = revision and tonumber(revision)
    if not revision or revision < 1 or revision > 9007199254740990 or revision % 1 ~= 0 then
        return nil, "Invalid saved slot generation in " .. path
    end
    local decoded
    decoded, err = Store.decode(payload)
    if not decoded then return nil, "Cannot load " .. path .. ": " .. err end
    return { revision = revision, value = decoded, payload = payload, path = path }
end

local function slots(path)
    local a, aError = readSlot(path .. ".a.txt")
    local b, bError = readSlot(path .. ".b.txt")
    if a and b then
        if a.revision == b.revision and a.payload ~= b.payload then return nil, nil, "Conflicting saved slot generations" end
        if b.revision > a.revision then return b, a end
        return a, b
    end
    if a then return a, nil, nil, bError end
    if b then return b, nil, nil, aError end
    return nil, nil, aError or bError
end

function Store.load(path)
    if not validPath(path) then return nil, "Invalid local storage path" end
    if type(getFileReader) ~= "function" then return nil, "Native local file reading is unavailable" end
    local current, _, err, recovery = slots(path)
    if not current then return nil, err end
    return current.value, nil, { revision = current.revision, recovered = recovery ~= nil, warning = recovery }
end

function Store.save(path, value)
    if not validPath(path) then return nil, "Invalid local storage path" end
    if type(getFileReader) ~= "function" or type(getFileWriter) ~= "function" then
        return nil, "Native local file storage is unavailable"
    end
    local encoded, err = Store.encode(value)
    if not encoded then return nil, err end
    local current, _, loadError = slots(path)
    if not current and loadError then return nil, loadError end
    local target = path .. ".a.txt"
    if current and current.path == target then target = path .. ".b.txt" end
    local revision = current and current.revision + 1 or 1
    if revision > 9007199254740990 then return nil, "Saved generation limit reached" end
    local record = "LBS1|" .. string.format("%.0f", revision) .. "|" .. encoded
    local opened, writer = pcall(getFileWriter, target, true, false)
    if not opened or not writer then return nil, "Cannot open saved slot " .. target end
    local wrote, writeError = pcall(function() writer:write(record) end)
    local closed, closeError = pcall(function() writer:close() end)
    local verified, verifyError = readSlot(target)
    if verified and verified.revision == revision and verified.payload == encoded then return true end
    if not wrote then return nil, "Cannot write " .. target .. ": " .. tostring(writeError) end
    if not closed then return nil, "Cannot close " .. target .. ": " .. tostring(closeError) end
    return nil, verifyError or "Saved slot failed readback verification"
end

return Store
