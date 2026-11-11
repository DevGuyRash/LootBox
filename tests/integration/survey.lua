package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local Survey = require "LootBox/Survey"
local passed = 0
local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

local function fixture()
    local metrics = { reads = 0 }
    local function method(run)
        return function(...)
            metrics.reads = metrics.reads + 1
            return run(...)
        end
    end
    local function list(values)
        return { size = method(function() return #values end), get = method(function(_, index) return values[index + 1] end) }
    end
    local rooms = {}
    local building = { getIDString = method(function() return "18446744073709551615" end),
        getRooms = method(function() return list(rooms) end), getSquares = function() error("A survey must not materialize building tiles") end }
    local function rectangle(x, y, width, height)
        return { getX = method(function() return x end), getY = method(function() return y end),
            getX2 = method(function() return x + width end), getY2 = method(function() return y + height end) }
    end
    local function room(id, z, rectangles, owner)
        return { getIDString = method(function() return id end), getName = method(function() return "Room " .. tostring(id) end),
            getZ = method(function() return z end), getRects = method(function() return list(rectangles) end),
            getBuilding = method(function() return owner or building end) }
    end
    return { building = building, rooms = rooms, rectangle = rectangle, room = room, metrics = metrics }
end

local function nextSection(survey, metrics)
    for _ = 1, 1000 do
        local before = metrics.reads
        local section = survey:next()
        assert(metrics.reads - before <= 64, "One cursor step exceeded the native metadata-read budget")
        if section ~= false then return section end
    end
    error("A finite fixture did not advance")
end

local function exhaust(survey, metrics, report)
    local sections = {}
    for _ = 1, 10000 do
        local section = nextSection(survey, metrics)
        if section == nil then return sections end
        sections[#sections + 1] = section
        if report then report(survey, section, #sections) else survey:report(section, true) end
    end
    error("A finite fixture did not complete")
end

local function bounds(section)
    return table.concat({ section.x1, section.y1, section.x2, section.y2, section.z }, ",")
end

test("all actual floors are included and the current room is searched first", function()
    local f = fixture()
    f.rooms[1] = f.room("basement", -1, { f.rectangle(-8, -3, 2, 2) })
    f.rooms[2] = f.room("ground", 0, { f.rectangle(0, 0, 2, 2) })
    f.rooms[3] = f.room("18446744073709551614", 1, { f.rectangle(0, 0, 2, 2) })
    f.rooms[4] = f.room("top", 31, { f.rectangle(0, 0, 2, 2) })
    local survey = assert(Survey.new(f.building, f.rooms[3]))
    local sections = exhaust(survey, f.metrics)
    assert(#sections == 4)
    assert(sections[1].roomId == "18446744073709551614" and sections[1].z == 1)
    assert(sections[2].z == -1 and sections[3].z == 0 and sections[4].z == 31)
    assert(bounds(sections[2]) == "-8,-3,-6,-1,-1")
    local status = survey:status()
    assert(status.complete and status.roomsTotal == 4 and status.roomsDone == 4)
    assert(status.sectionsSearched == 4 and status.sectionsUnsearched == 0)
end)

test("room rectangles are covered by small serpentine sections with exclusive bounds", function()
    local f = fixture()
    f.rooms[1] = f.room("storage", 0, { f.rectangle(10, 20, 10, 9) })
    local sections = exhaust(assert(Survey.new(f.building)), f.metrics)
    local expected = { "10,20,18,28,0", "18,20,20,28,0", "12,28,20,29,0", "10,28,12,29,0" }
    local seen, count = {}, 0
    assert(#sections == #expected)
    for index, section in ipairs(sections) do
        assert(bounds(section) == expected[index])
        assert(section.x2 - section.x1 <= 8 and section.y2 - section.y1 <= 8)
        for y = section.y1, section.y2 - 1 do for x = section.x1, section.x2 - 1 do
            local key = x .. ":" .. y
            assert(not seen[key], "One rectangle tile was scheduled twice")
            seen[key], count = true, count + 1
        end end
    end
    assert(count == 90)
end)

local function retainedEntries(value, seen)
    if type(value) ~= "table" then return 0 end
    seen = seen or {}
    if seen[value] then return 0 end
    seen[value] = true
    local count = 0
    for _, entry in pairs(value) do count = count + 1 + retainedEntries(entry, seen) end
    return count
end

test("an enormous room starts lazily and retains no growing section history", function()
    local f = fixture()
    f.rooms[1] = f.room("warehouse", 0, { f.rectangle(-1000000, -1000000, 2000000, 2000000) })
    local before = f.metrics.reads
    local survey = assert(Survey.new(f.building))
    assert(f.metrics.reads - before <= 4, "Construction scanned room geometry")
    local retained
    for index = 1, 1024 do
        local section = assert(nextSection(survey, f.metrics))
        assert(section.x1 == -1000000 + (index - 1) * 8 and section.y1 == -1000000)
        assert(section.x2 - section.x1 == 8 and section.y2 - section.y1 == 8)
        survey:report(section, true)
        if index == 16 then retained = retainedEntries(survey) end
    end
    assert(retainedEntries(survey) <= retained + 32, "Traversal state grew with every searched section")
    local status = survey:status()
    assert(not status.complete and status.roomsDone == 0 and status.sectionsSearched == 1024)
end)

test("finding a late current room yields instead of reading the whole room list at once", function()
    local f = fixture()
    for index = 1, 257 do f.rooms[index] = f.room(tostring(index), 0, { f.rectangle(index, 0, 1, 1) }) end
    local survey = assert(Survey.new(f.building, f.rooms[257]))
    local before = f.metrics.reads
    assert(survey:next() == false)
    assert(f.metrics.reads - before <= 64)
    local first = assert(nextSection(survey, f.metrics))
    assert(first.roomId == "257")
    survey:report(first, true)
    local rest = exhaust(survey, f.metrics)
    assert(#rest == 256)
    assert(survey:status().roomsDone == 257 and survey:status().sectionsSearched == 257)
end)

test("only the outstanding section can be reported and completion waits for its report", function()
    local f = fixture()
    f.rooms[1] = f.room("one", 0, { f.rectangle(0, 0, 1, 1) })
    local survey = assert(Survey.new(f.building))
    local section = assert(nextSection(survey, f.metrics))
    assert(not survey:status().complete)
    assert(not pcall(function() survey:next() end))
    assert(not pcall(function() survey:report({}, true) end))
    survey:report(section, true)
    assert(not pcall(function() survey:report(section, true) end))
    assert(nextSection(survey, f.metrics) == nil and survey:status().complete)
    assert(survey:next() == nil)
end)

test("overlapping rectangles finish and a blocked section remains unsearched", function()
    local f = fixture()
    f.rooms[1] = f.room("overlap", 1, { f.rectangle(0, 0, 2, 2), f.rectangle(1, 1, 2, 2) })
    local survey = assert(Survey.new(f.building))
    local sections = exhaust(survey, f.metrics, function(current, section, index)
        current:report(section, index == 1, index == 2 and "Locked door" or nil)
    end)
    assert(#sections == 2)
    local status = survey:status()
    assert(status.complete and status.roomsDone == 1 and status.sectionsSearched == 1 and status.sectionsUnsearched == 1)
    assert(#status.unsearchedRooms == 1 and status.unsearchedRooms[1].z == 1)
    assert(status.unsearchedRooms[1].reason:find("Locked door", 1, true))
end)

test("invalid geometry is reported without preventing later valid geometry", function()
    local f = fixture()
    f.rooms[1] = f.room("mixed", 0, { f.rectangle(0, 0, -1, 8), f.rectangle(0, 0, 1, 1) })
    f.rooms[2] = f.room("bad floor", math.huge, { f.rectangle(2, 2, 1, 1) })
    local survey = assert(Survey.new(f.building))
    local sections = exhaust(survey, f.metrics)
    assert(#sections == 1 and sections[1].roomId == "mixed")
    local status = survey:status()
    assert(status.complete and status.roomsDone == 2 and status.sectionsSearched == 1 and status.sectionsUnsearched == 2)
    assert(#status.unsearchedRooms == 2)
end)

test("removed or foreign room metadata becomes unsearched instead of searching another building", function()
    local f = fixture()
    f.rooms[1] = f.room("first", 0, { f.rectangle(0, 0, 1, 1) })
    f.rooms[2] = f.room("second", 0, { f.rectangle(2, 2, 1, 1) })
    local survey = assert(Survey.new(f.building))
    local first = assert(nextSection(survey, f.metrics))
    survey:report(first, true)
    f.rooms[2] = f.room("foreign", 0, { f.rectangle(2, 2, 1, 1) }, {})
    assert(#exhaust(survey, f.metrics) == 0)
    local status = survey:status()
    assert(status.complete and status.roomsDone == 2 and status.sectionsSearched == 1 and status.sectionsUnsearched == 1)
    assert(status.unsearchedRooms[1].roomId == "foreign")
end)

test("metadata appended during a job does not extend its captured itinerary", function()
    local f = fixture()
    f.rooms[1] = f.room("original", 0, { f.rectangle(0, 0, 1, 1) })
    local survey = assert(Survey.new(f.building))
    f.rooms[2] = f.room("later", 1, { f.rectangle(2, 2, 1, 1) })
    local sections = exhaust(survey, f.metrics)
    assert(#sections == 1 and sections[1].roomId == "original")
    assert(survey:status().roomsTotal == 1 and survey:status().roomsDone == 1)
end)

test("reported status snapshots cannot rewrite retained failure information", function()
    local f = fixture()
    f.rooms[1] = f.room("blocked", -1, { f.rectangle(0, 0, 1, 1) })
    local survey = assert(Survey.new(f.building))
    local section = assert(nextSection(survey, f.metrics))
    survey:report(section, false, "Blocked stairs")
    local status = survey:status()
    status.sectionsUnsearched = 0
    status.unsearchedRooms[1].reason = "Cleared"
    status.unsearchedRooms[1].sections = 0
    table.remove(status.unsearchedRooms, 1)
    local retained = survey:status()
    assert(retained.sectionsUnsearched == 1 and #retained.unsearchedRooms == 1)
    assert(retained.unsearchedRooms[1].sections == 1 and retained.unsearchedRooms[1].reason:find("Blocked stairs", 1, true))
end)

test("missing building metadata is an error and an empty building completes", function()
    local missing, reason = Survey.new({})
    assert(missing == nil and type(reason) == "string")
    local f = fixture()
    local survey = assert(Survey.new(f.building))
    assert(nextSection(survey, f.metrics) == nil)
    assert(survey:status().complete and survey:status().roomsTotal == 0)
end)

print(passed .. " building survey cases passed (explicit native metadata doubles)")
