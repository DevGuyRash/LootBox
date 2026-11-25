if type(package) == "table" and type(package.path) == "string" then
    package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
end

local Categories = require "LootBox/Categories"
local Store = require "LootBox/Store"
-- The file doubles below belong to the store alone.
require("LootBox/Log").warn = function() end
local originalReader, originalWriter = getFileReader, getFileWriter
local originalExecutionMarker = LootBoxStoreExecutionMarker
local disk, fault, lastWritten, openHandles = {}, nil, nil, 0
local passed, failures = 0, {}

local function equal(actual, expected, message)
    if actual ~= expected then
        error((message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function rejected(value, err)
    equal(value, nil, "Invalid input must be rejected")
    assert(type(err) == "string" and #err > 0, "A rejection must explain the failure")
end

local function same(actual, expected)
    equal(type(actual), type(expected))
    if type(expected) ~= "table" then equal(actual, expected); return end
    for key, value in pairs(expected) do same(actual[key], value) end
    for key in pairs(actual) do assert(expected[key] ~= nil, "Unexpected saved key " .. tostring(key)) end
end

getFileReader = function(path)
    if fault and fault.kind == "read" then error("Fixture read denied") end
    local bytes = disk[path]
    if bytes == nil then return nil end
    local cursor, closed = 1, false
    openHandles = openHandles + 1
    return {
        readLine = function()
            if closed then error("Fixture reader is closed") end
            if cursor > #bytes then return nil end
            local ending = bytes:find("\n", cursor, true)
            local line = bytes:sub(cursor, ending and ending - 1 or #bytes)
            cursor = ending and ending + 1 or #bytes + 1
            return line
        end,
        close = function()
            if not closed then openHandles = openHandles - 1 end
            closed = true
        end,
    }
end

getFileWriter = function(path, create, append)
    local extension = path:match("%.([^./]+)$")
    if not ({ ini = true, cfg = true, txt = true, log = true, json = true })[extension] then return nil end
    if fault and fault.kind == "open-write" then return nil end
    if disk[path] == nil and not create then return nil end
    disk[path] = append and (disk[path] or "") or ""
    local closed = false
    lastWritten = path
    openHandles = openHandles + 1
    return {
        write = function(_, bytes)
            if closed then error("Fixture writer is closed") end
            if fault and fault.kind == "partial-write" then
                disk[path] = disk[path] .. bytes:sub(1, 19)
                error("Fixture storage interrupted")
            end
            disk[path] = disk[path] .. bytes
        end,
        close = function()
            if not closed then openHandles = openHandles - 1 end
            closed = true
        end,
    }
end

local function case(name, run)
    disk, fault, lastWritten, openHandles = {}, nil, nil, 0
    local ok, err = pcall(run)
    if ok and openHandles ~= 0 then ok, err = false, "File handles remain open" end
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failures[#failures + 1] = name .. ": " .. tostring(err)
        print("FAIL " .. failures[#failures])
    end
end

local function item(fullType, categoryId, labels)
    return { fullType = fullType, categoryId = categoryId, labels = labels or {} }
end

case("Every native category remains selectable without a whitelist", function()
    local graph = assert(Categories.new({}))
    equal(graph:matches("native:Modded_AlienParts", item("Space.Capacitor", "native:Modded_AlienParts")), true)
    equal(graph:matches("native:WaterContainer", item("Base.Bottle", "native:WaterContainer")), true)
    equal(graph:matches("native:Food", item("Base.Bottle", "native:WaterContainer")), false)
end)

case("Custom categories unite their types and nested native or custom categories", function()
    local graph = assert(Categories.new({
        { id = "custom:packing", name = "Packing", types = { "Base.Nails" }, includes = { "native:WaterContainer" } },
        { id = "custom:tools", name = "Tools", includes = { "native:Tool" } },
        { id = "custom:supplies", name = "Supplies", types = { "Base.Bandage" }, includes = { "custom:packing", "custom:tools" } },
    }))
    equal(graph:matches("custom:supplies", item("Base.Nails", "native:Material")), true)
    equal(graph:matches("custom:supplies", item("Base.Bottle", "native:WaterContainer")), true)
    equal(graph:matches("custom:supplies", item("Base.Saw", "native:Tool")), true)
    equal(graph:matches("custom:supplies", item("Base.Bandage", "native:FirstAid")), true)
    equal(graph:matches("custom:supplies", item("Base.Apple", "native:Food")), false)
end)

case("An instance can have multiple memberships without relabeling its item type", function()
    local graph = assert(Categories.new({
        { id = "custom:camp", name = "Camp" },
        { id = "custom:trip", name = "Trip", includes = { "custom:camp" } },
    }))
    local marked = item("Base.Rope", "native:Material", { "custom:camp", "native:Tool" })
    equal(graph:matches("custom:camp", marked), true)
    equal(graph:matches("custom:trip", marked), true)
    equal(graph:matches("native:Tool", marked), true)
    equal(graph:matches("native:Material", marked), true)
    equal(graph:matches("custom:camp", item("Base.Rope", "native:Material")), false)
end)

case("An item type is selected across categories and the checklist uses union", function()
    local graph = assert(Categories.new({}))
    local filter = { types = { "Base.Rope" }, ids = { "native:Food", "native:FirstAid" } }
    equal(graph:matchesFilter(filter, item("Base.Rope", "native:Material")), true)
    equal(graph:matchesFilter(filter, item("Base.Apple", "native:Food")), true)
    equal(graph:matchesFilter(filter, item("Base.Bandage", "native:FirstAid")), true)
    equal(graph:matchesFilter(filter, item("Base.Nails", "native:Material")), false)
    equal(graph:matchesFilter({}, item("Base.Apple", "native:Food")), false)
    equal(graph:matchesFilter({ all = true }, item("Base.Nails", "native:Material")), true)
end)

case("Empty custom categories select nothing", function()
    local graph = assert(Categories.new({ { id = "custom:empty", name = "Empty" } }))
    equal(graph:matches("custom:empty", item("Base.Apple", "native:Food")), false)
end)

case("Category definitions cannot be changed by mutating returned editor data", function()
    local definitions = { { id = "custom:keep", name = "Keep", types = { "Base.Nails" } } }
    local graph = assert(Categories.new(definitions))
    definitions[1].types[1] = "Base.Apple"
    local editor = graph:list()
    editor[1].name = "Changed"
    editor[1].types[1] = "Base.Apple"
    equal(graph:list()[1].name, "Keep")
    equal(graph:matches("custom:keep", item("Base.Nails", "native:Material")), true)
    equal(graph:matches("custom:keep", item("Base.Apple", "native:Food")), false)
end)

case("Custom category cycles are refused", function()
    rejected(Categories.new({ { id = "custom:self", name = "Self", includes = { "custom:self" } } }))
    rejected(Categories.new({
        { id = "custom:a", name = "A", includes = { "custom:b" } },
        { id = "custom:b", name = "B", includes = { "custom:c" } },
        { id = "custom:c", name = "C", includes = { "custom:a" } },
    }))
end)

case("Missing custom references are refused while arbitrary native categories remain valid", function()
    rejected(Categories.new({ { id = "custom:trip", name = "Trip", includes = { "custom:missing" } } }))
    local graph = assert(Categories.new({ { id = "custom:trip", name = "Trip", includes = { "native:NewModCategory" } } }))
    equal(graph:matches("custom:trip", item("Mod.NewItem", "native:NewModCategory")), true)
end)

case("Duplicate IDs or category members are refused", function()
    rejected(Categories.new({ { id = "custom:a", name = "A" }, { id = "custom:a", name = "Other A" } }))
    rejected(Categories.new({ { id = "custom:a", name = "A", types = { "Base.Nails", "Base.Nails" } } }))
    rejected(Categories.new({ { id = "custom:a", name = "A", includes = { "native:Food", "native:Food" } } }))
end)

case("Malformed category arrays and incomplete editor values are refused", function()
    rejected(Categories.new({ [2] = { id = "custom:a", name = "A" } }))
    rejected(Categories.new({ { id = "custom:a", name = "A", types = { [2] = "Base.Nails" } } }))
    rejected(Categories.new({ { id = "custom:a", name = "A", includes = false } }))
    rejected(Categories.new({ { id = "native:a", name = "A" } }))
    rejected(Categories.new({ { id = "custom:a", name = " " } }))
end)

case("Long nested categories retain union membership", function()
    local definitions = { { id = "custom:1", name = "1", types = { "Base.Nails" } } }
    for index = 2, 1200 do
        definitions[index] = { id = "custom:" .. index, name = tostring(index), includes = { "custom:" .. (index - 1) } }
    end
    local graph = assert(Categories.new(definitions))
    equal(graph:matches("custom:1200", item("Base.Nails", "native:Material")), true)
    equal(graph:matches("custom:1200", item("Base.Apple", "native:Food")), false)
end)

case("Fresh local profiles have no saved value and no corruption error", function()
    local value, err = Store.load("LootBox/categories")
    equal(value, nil)
    equal(err, nil)
end)

case("Saved values preserve Unicode, control bytes, booleans, numbers and nested lists", function()
    local value = {
        version = 1,
        name = "M\195\169dicaments \229\140\187\231\153\130",
        controls = "line one\nline two\r\t\000|;:\\",
        enabled = false,
        values = { 0, -12.5, 1.25e20, true, false, "" },
        categories = { { id = "custom:medical", types = { "Base.Bandage" }, includes = { "native:FirstAid" } } },
    }
    local encoded = assert(Store.encode(value))
    local decoded = assert(Store.decode(encoded))
    same(decoded, value)
    equal(Store.save("LootBox/categories", value), true)
    same(assert(Store.load("LootBox/categories")), value)
end)

case("String and numeric keys retain different meanings", function()
    local value = { [1] = "first", [3] = "third", ["1"] = "named one", ["false"] = false }
    same(assert(Store.decode(assert(Store.encode(value)))), value)
end)

case("Documents written before plain text was stored as it is stay readable", function()
    local old = "LBD1|c26d2aee|m3:s5:636f756e74d3.5;s4:6b656570m1:s2:3132ys6:6c6162656c73m1:s27:776f726c643a313a323a303a333a63726174653a303a6372617465m2:d1;s11:6e61746976653a466f6f64d2;s8:637573746f6d3a31"
    same(assert(Store.decode(old)), {count = 3.5, keep = {["12"] = true}, labels = {["world:1:2:0:3:crate:0:crate"] = {"native:Food", "custom:1"}}})
end)

case("Plain text is stored once per character, and any text survives", function()
    local key = "world:10234:9876:0:#0:furniture_storage_01_12:0:crate"
    local text = assert(Store.encode({[key] = {"native:Food"}}))
    assert(text:find(key, 1, true) and #text < #key + 60)
    for _, value in ipairs({"", "plain", "with|bar;semi:colon", "two\nlines", "tab\t", "\127", "d3;", "m1:"}) do
        local encoded = assert(Store.encode({value = value}))
        assert(not encoded:find("\n", 1, true), "A saved document is one line")
        equal(assert(Store.decode(encoded)).value, value)
    end
end)

case("Saved data never executes Lua", function()
    LootBoxStoreExecutionMarker = "not executed"
    local source = "LootBoxStoreExecutionMarker = 'executed'; return {version=1}"
    rejected(Store.decode(source))
    equal(LootBoxStoreExecutionMarker, "not executed")
    local value = { text = source }
    same(assert(Store.decode(assert(Store.encode(value)))), value)
    equal(LootBoxStoreExecutionMarker, "not executed")
end)

case("A damaged or truncated encoding is reported instead of becoming empty settings", function()
    local encoded = assert(Store.encode({ version = 1, name = "Camp" }))
    rejected(Store.decode(encoded:sub(1, #encoded - 1)))
    rejected(Store.decode(encoded .. "extra"))
    rejected(Store.decode(""))
end)

case("Unsupported values, non-finite numbers and cyclic data are refused", function()
    rejected(Store.encode({ callback = function() end }))
    rejected(Store.encode({ amount = math.huge }))
    rejected(Store.encode({ amount = 0 / 0 }))
    local cyclic = {}
    cyclic.again = cyclic
    rejected(Store.encode(cyclic))
end)

case("A later successful save is the value read on reopening", function()
    equal(Store.save("LootBox/categories", { name = "First" }), true)
    equal(Store.save("LootBox/categories", { name = "Second", labels = { "native:Food", "native:Tool" } }), true)
    same(assert(Store.load("LootBox/categories")), { name = "Second", labels = { "native:Food", "native:Tool" } })
end)

case("An interrupted save leaves the prior complete settings usable", function()
    equal(Store.save("LootBox/categories", { name = "Before interruption" }), true)
    fault = { kind = "partial-write" }
    rejected(Store.save("LootBox/categories", { name = "Interrupted replacement" }))
    fault = nil
    local value, err, metadata = Store.load("LootBox/categories")
    equal(err, nil)
    same(value, { name = "Before interruption" })
    equal(metadata.recovered, true)
    equal(Store.save("LootBox/categories", { name = "Retried" }), true)
    same(assert(Store.load("LootBox/categories")), { name = "Retried" })
end)

case("A denied writer preserves the prior complete settings", function()
    equal(Store.save("LootBox/categories", { name = "Before denial" }), true)
    fault = { kind = "open-write" }
    rejected(Store.save("LootBox/categories", { name = "Denied replacement" }))
    fault = nil
    same(assert(Store.load("LootBox/categories")), { name = "Before denial" })
end)

case("Corruption of the newest save recovers the preceding complete value", function()
    equal(Store.save("LootBox/categories", { name = "Preceding value" }), true)
    equal(Store.save("LootBox/categories", { name = "Newest value" }), true)
    disk[lastWritten] = "corrupted fixture data"
    local value, err, metadata = Store.load("LootBox/categories")
    equal(err, nil)
    same(value, { name = "Preceding value" })
    equal(metadata.recovered, true)
end)

case("Unreadable existing storage reports an error instead of fresh settings", function()
    equal(Store.save("LootBox/categories", { name = "Existing value" }), true)
    fault = { kind = "read" }
    rejected(Store.load("LootBox/categories"))
    rejected(Store.save("LootBox/categories", { name = "Replacement" }))
    fault = nil
    same(assert(Store.load("LootBox/categories")), { name = "Existing value" })
end)

case("Entirely damaged saves are reported, kept as a backup and then replaced", function()
    equal(Store.save("LootBox/categories", { name = "First" }), true)
    equal(Store.save("LootBox/categories", { name = "Second" }), true)
    disk["LootBox/categories.a.txt"], disk["LootBox/categories.b.txt"] = "damaged one", "damaged two"
    rejected(Store.load("LootBox/categories"))
    local _, _, metadata = Store.load("LootBox/categories")
    equal(metadata.damaged, true)
    equal(Store.save("LootBox/categories", { name = "Replacement" }), true)
    local backup = disk["LootBox/categories.damaged.txt"]
    assert(backup:find("damaged one", 1, true) and backup:find("damaged two", 1, true))
    same(assert(Store.load("LootBox/categories")), { name = "Replacement" })
    equal(Store.save("LootBox/categories", { name = "Next" }), true)
    same(assert(Store.load("LootBox/categories")), { name = "Next" })
end)

case("Damaged saves are never replaced when the backup cannot be written", function()
    equal(Store.save("LootBox/categories", { name = "First" }), true)
    disk["LootBox/categories.a.txt"] = "damaged"
    fault = { kind = "open-write" }
    rejected(Store.save("LootBox/categories", { name = "Replacement" }))
    fault = nil
    same(disk, { ["LootBox/categories.a.txt"] = "damaged" })
end)

case("Two different saves of one generation are both backed up and superseded", function()
    equal(Store.save("LootBox/categories", { name = "One" }), true)
    local first = disk["LootBox/categories.a.txt"]
    disk = {}
    equal(Store.save("LootBox/categories", { name = "Two" }), true)
    disk["LootBox/categories.b.txt"] = first
    rejected(Store.load("LootBox/categories"))
    equal(Store.save("LootBox/categories", { name = "Three" }), true)
    same(assert(Store.load("LootBox/categories")), { name = "Three" })
    assert(disk["LootBox/categories.damaged.txt"]:find(first, 1, true))
end)

case("Saving unchanged data writes nothing", function()
    equal(Store.save("LootBox/categories", { name = "Camp", labels = { "native:Food" } }), true)
    local text = disk["LootBox/categories.a.txt"]
    lastWritten = nil
    equal(Store.save("LootBox/categories", { labels = { "native:Food" }, name = "Camp" }), true)
    equal(lastWritten, nil)
    equal(Store.save("LootBox/categories", { name = "Moved" }), true)
    equal(lastWritten, "LootBox/categories.b.txt")
    equal(disk["LootBox/categories.a.txt"], text, "The previous save stays as the fallback")
    disk["LootBox/categories.b.txt"] = "damaged meanwhile"
    equal(Store.save("LootBox/categories", { name = "Moved" }), true)
    same(assert(Store.load("LootBox/categories")), { name = "Moved" })
end)

case("Salvage keeps every usable category and says what was lost", function()
    local graph, notes = Categories.salvage({
        { id = "custom:good", name = "Good", types = { "Base.Nails" }, includes = { "native:Food" } },
        { id = "custom:gone", name = "Uses a missing one", types = { "Base.Rope" }, includes = { "custom:missing" } },
        { id = "custom:a", name = "A", types = { "Base.Axe", "Base.Axe", 4 }, includes = { "custom:b" } },
        { id = "custom:b", name = "B", types = { "Base.Bow" }, includes = { "custom:a" } },
        { id = "custom:good", name = "Second copy" },
        { id = "native:bad", name = "Wrong kind" },
        "not a category",
        { id = "custom:unnamed", name = " ", types = { "Base.Cup" } },
    })
    equal(#graph:list(), 5)
    equal(graph:matches("custom:good", item("Base.Apple", "native:Food")), true)
    equal(graph:matches("custom:gone", item("Base.Rope", "native:Material")), true)
    equal(graph:matches("custom:a", item("Base.Bow", "native:Weapon")), true, "One direction of a cycle survives")
    equal(graph:matches("custom:b", item("Base.Axe", "native:Weapon")), false)
    equal(graph:matches("custom:unnamed", item("Base.Cup", "native:Material")), true)
    -- missing include, duplicate type, non-text type, cycle, duplicate ID, wrong ID, not a table, no name
    equal(#notes, 8)
    local clean, none = Categories.salvage({ { id = "custom:good", name = "Good" } })
    equal(#clean:list(), 1)
    equal(#none, 0)
    local empty, lost = Categories.salvage("damaged")
    equal(#empty:list(), 0)
    equal(#lost, 1)
end)

case("Salvage follows long chains without recursion", function()
    local definitions = { { id = "custom:1", name = "1", types = { "Base.Nails" } } }
    for index = 2, 1200 do
        definitions[index] = { id = "custom:" .. index, name = tostring(index), includes = { "custom:" .. (index - 1) } }
    end
    definitions[1].includes = { "custom:1200" }
    local graph, notes = Categories.salvage(definitions)
    equal(#graph:list(), 1200)
    equal(#notes, 1)
end)

case("Separate world and player paths keep independent preferences", function()
    equal(Store.save("LootBox/world-alice", { labels = { "native:Food" } }), true)
    equal(Store.save("LootBox/world-bob", { labels = { "native:Tool" } }), true)
    same(assert(Store.load("LootBox/world-alice")), { labels = { "native:Food" } })
    same(assert(Store.load("LootBox/world-bob")), { labels = { "native:Tool" } })
end)

case("Chunked world identities support native paths longer than 256 characters", function()
    local path = "LootBox/world/" .. string.rep("a", 96) .. "/" .. string.rep("b", 96) .. "/" .. string.rep("c", 96)
    assert(#path > 256)
    equal(Store.save(path, { labels = { "native:Food" } }), true)
    same(assert(Store.load(path)), { labels = { "native:Food" } })
end)

getFileReader, getFileWriter = originalReader, originalWriter
LootBoxStoreExecutionMarker = originalExecutionMarker
print("Category and storage contracts: " .. passed .. " passed, " .. #failures .. " failed")
if #failures > 0 then error(table.concat(failures, "\n"), 0) end
return passed
