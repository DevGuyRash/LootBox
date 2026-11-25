package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local files, clock, printed, passed = {}, 1000, {}, 0
function getTimestampMs() return clock end
function getFileReader(path)
    if not files[path] then return nil end
    local lines, at = {}, 0
    for line in (files[path]):gmatch("[^\n]+") do lines[#lines + 1] = line end
    return {readLine = function() at = at + 1; return lines[at] end, close = function() end}
end
function getFileWriter(path, _, append)
    local text = append and files[path] or ""
    return {write = function(_, part) text = text .. part end, close = function() files[path] = text end}
end
local nativePrint = print
print = function(text) printed[#printed + 1] = tostring(text) end
local classes = {}
function instanceof(object, class) return classes[object] == class end
Events = nil
local Log = require "LootBox/Log"
local function test(name, run) run(); passed = passed + 1; nativePrint("PASS " .. name) end
local function file() Log.flush(); return files["LootBox/log/session-1.txt"] or "" end

local square = {getX = function() return 10 end, getY = function() return 20 end, getZ = function() return 0 end, getRoom = function() return {getName = function() return "kitchen" end} end}
local inventory = {getCapacityWeight = function() return 12.34 end, getEffectiveCapacity = function() return 50 end}
local player = {getCurrentSquare = function() return square end, getInventory = function() return inventory end, isAiming = function() return true end,
    getX = function() return 10 end, getY = function() return 20 end}
local crateObject = {getSquare = function() return square end, getSpriteName = function() return "carpentry_01" end, getContainerCount = function() return 1 end,
    getContainerIndex = function() return 0 end, getObjectIndex = function() return 4 end}
local crate = {getContainingItem = function() end, getVehiclePart = function() end, getParent = function() return crateObject end, getType = function() return "crate" end,
    getCustomName = function() return "My crate" end, getItems = function() return {size = function() return 7 end} end, getCapacityWeight = function() return 4.5 end,
    getEffectiveCapacity = function() return 50 end, isExplored = function() return true end, isLockedToCharacter = function() return true end}
local nails = {getFullType = function() return "Base.Nails" end, getID = function() return 99 end, getName = function() return "Nails" end, getContainer = function() return crate end,
    getUnequippedWeight = function() return 0.01 end, isFavorite = function() return true end}

test("an intent records who asked for what, from where, and the world at that moment", function()
    local id = Log.intent("menu.item", "Take all Nails", player, "clicked", Log.item(nails, player), "container", Log.container(crate, player))
    local text = file()
    assert(id == 1 and text:find("#1 INTENT from=menu.item ask=\"Take all Nails\" mode=SP", 1, true), text)
    for _, fact in ipairs({"at=10,20,0", "room=kitchen", "doing=aiming", "carry=12.34/50", "Base.Nails#99", "in=crate@10,20,0", "favorite",
        "named=\"My crate\"", "items=7", "load=4.5/50", "LOCKED", "explored=true"}) do assert(text:find(fact, 1, true), fact .. " missing in " .. text) end
end)

test("every line of an interaction carries its number and time", function()
    clock = 3500
    local id = Log.intent("toolbar", "Condense", player)
    Log.trace(id, "OP", "n", 1)
    assert(file():find("2.500       #2 OP n=1", 1, true), file())
end)

test("traces stay out of the console; outcomes and problems reach it", function()
    printed = {}
    Log.trace(2, "OP", "n", 2); Log.info(2, "END", "state", "finished"); Log.warn(2, "REFUSED", "reason", "Full")
    assert(#printed == 2 and printed[1]:find("#2 END state=finished", 1, true) and printed[2]:find("REFUSED", 1, true))
end)

test("turning detail off drops traces and nothing else", function()
    Log.detailed = false
    Log.trace(3, "HIDDEN"); Log.info(3, "SHOWN")
    local text = file()
    assert(not text:find("HIDDEN", 1, true) and text:find("SHOWN", 1, true))
    Log.detailed = true
end)

test("a swallowed error is reported once, with its site", function()
    printed = {}
    for _ = 1, 5 do Log.guard("PourMenu", function() error("boom") end) end
    assert(#printed == 1 and printed[1]:find("FAULT site=PourMenu", 1, true) and printed[1]:find("boom", 1, true))
end)

test("describing broken or missing things never throws", function()
    local hostile = setmetatable({}, {__index = function() error("native exception") end})
    for _, describe in ipairs({Log.item, Log.container, Log.player, Log.vehicle, Log.point, Log.request}) do
        assert(type(describe(nil)) == "string" and type(describe(hostile)) == "string")
    end
end)

test("the next session uses the next of five files", function()
    package.loaded["LootBox/Log"] = nil
    local again = require "LootBox/Log"
    again.info(nil, "session"); again.flush()
    assert(files["LootBox/log/index.txt"] == "2" and files["LootBox/log/session-2.txt"] and again.path():find("session-2", 1, true))
    files["LootBox/log/index.txt"] = "5"
    package.loaded["LootBox/Log"] = nil
    local wrapped = require "LootBox/Log"
    wrapped.info(nil, "session"); wrapped.flush()
    assert(files["LootBox/log/index.txt"] == "1")
end)

test("a full file continues in the next one, and a new session starts fresh", function()
    files["LootBox/log/index.txt"] = "2"
    package.loaded["LootBox/Log"] = nil
    local small = require "LootBox/Log"
    small.maxBytes = 300
    for index = 1, 20 do small.trace(1, "OP", "n", index) end
    small.flush()
    assert(files["LootBox/log/session-3.txt"]:find("continues in the next file", 1, true) and files["LootBox/log/session-4.txt"])
    assert(#files["LootBox/log/session-3.txt"] < 700)
    local before = files["LootBox/log/index.txt"]
    small.reset(); small.info(nil, "session"); small.flush()
    assert(files["LootBox/log/index.txt"] ~= before)
end)

test("an unwritable log never breaks an action and never claims to have saved", function()
    getFileWriter = function() error("read only") end
    package.loaded["LootBox/Log"] = nil
    local blocked = require "LootBox/Log"
    blocked.warn(1, "REFUSED"); blocked.info(1, "END")
    assert(blocked.flush() == false)
end)

print = nativePrint
print(passed .. " log cases passed")
