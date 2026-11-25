package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local Survey = require "LootBox/Survey"
local passed = 0
local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

local function fixture()
    local function list(values)
        return { size = function() return #values end, get = function(_, index) return values[index + 1] end }
    end
    local rooms = {}
    local building = { getIDString = function() return "18446744073709551615" end,
        getRooms = function() return list(rooms) end, getSquares = function() error("A survey must not materialize building tiles") end }
    local function rectangle(x, y, width, height)
        return { getX = function() return x end, getY = function() return y end,
            getX2 = function() return x + width end, getY2 = function() return y + height end }
    end
    local function room(id, z, rectangles, owner)
        return { getIDString = function() return id end, getName = function() return "Room " .. tostring(id) end,
            getZ = function() return z end, getRects = function() return list(rectangles) end,
            getBuilding = function() return owner or building end }
    end
    return { building = building, rooms = rooms, rectangle = rectangle, room = room }
end

local function exhaust(survey, point, report)
    local sections = {}
    while true do
        local section = survey:next(point)
        if not section then return sections end
        sections[#sections + 1] = section
        if report then report(survey, section, #sections) else survey:report(section, true) end
        assert(#sections < 10000, "A finite fixture did not complete")
    end
end

local function bounds(section)
    return table.concat({ section.x1, section.y1, section.x2, section.y2, section.z }, ",")
end

test("all actual floors are included and the nearest room always comes next", function()
    local f = fixture()
    f.rooms[1] = f.room("basement", -1, { f.rectangle(-8, -3, 2, 2) })
    f.rooms[2] = f.room("ground", 0, { f.rectangle(0, 0, 2, 2) })
    f.rooms[3] = f.room("18446744073709551614", 1, { f.rectangle(0, 0, 2, 2) })
    f.rooms[4] = f.room("top", 31, { f.rectangle(0, 0, 2, 2) })
    f.rooms[5] = f.room("far end", 1, { f.rectangle(40, 0, 2, 2) })
    local survey = assert(Survey.ofBuilding(f.building))
    local sections = exhaust(survey, { x = 0, y = 0, z = 1 })
    assert(#sections == 5)
    assert(sections[1].roomId == "18446744073709551614" and sections[2].roomId == "ground" and sections[3].roomId == "basement")
    assert(sections[4].roomId == "far end" and sections[5].z == 31, "Forty tiles are nearer than thirty floors")
    assert(bounds(sections[3]) == "-8,-3,-6,-1,-1")
    local status = survey:status()
    assert(status.complete and status.roomsTotal == 5 and status.roomsDone == 5)
    assert(status.sectionsSearched == 5 and status.sectionsUnsearched == 0)
end)

test("what is nearest follows the player", function()
    local f = fixture()
    f.rooms[1] = f.room("west", 0, { f.rectangle(0, 0, 2, 2) })
    f.rooms[2] = f.room("middle", 0, { f.rectangle(20, 0, 2, 2) })
    f.rooms[3] = f.room("east", 0, { f.rectangle(40, 0, 2, 2) })
    local survey = assert(Survey.ofBuilding(f.building))
    local first = survey:next({ x = 41, y = 0, z = 0 })
    assert(first.roomId == "east")
    survey:report(first, true)
    assert(survey:next({ x = 1, y = 0, z = 0 }).roomId == "west")
    assert(survey:next({ x = 30, y = 0, z = 0 }).roomId == "middle")
    assert(survey:status().roomsDone == 1 and survey:status().roomsTotal == 3)
end)

test("room rectangles are covered by small sections with exclusive bounds", function()
    local f = fixture()
    f.rooms[1] = f.room("storage", 0, { f.rectangle(10, 20, 10, 9) })
    local sections = exhaust(assert(Survey.ofBuilding(f.building)), { x = 10, y = 20, z = 0 })
    local expected = { "10,20,18,28,0", "18,20,20,28,0", "10,28,18,29,0", "18,28,20,29,0" }
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

test("a section counts once however often it is reported, and the last report completes the survey", function()
    local f = fixture()
    f.rooms[1] = f.room("one", 0, { f.rectangle(0, 0, 1, 1) })
    local survey = assert(Survey.ofBuilding(f.building))
    local section = assert(survey:next())
    assert(not survey.complete)
    survey:report({}, true)
    assert(not survey.complete)
    survey:report(section, true)
    survey:report(section, true)
    assert(survey:next() == nil and survey.complete and survey:status().sectionsSearched == 1)
end)

test("overlapping rectangles finish and a blocked section remains unsearched", function()
    local f = fixture()
    f.rooms[1] = f.room("overlap", 1, { f.rectangle(0, 0, 2, 2), f.rectangle(1, 1, 2, 2) })
    local survey = assert(Survey.ofBuilding(f.building))
    local sections = exhaust(survey, nil, function(current, section, index)
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
    local survey = assert(Survey.ofBuilding(f.building))
    local sections = exhaust(survey)
    assert(#sections == 1 and sections[1].roomId == "mixed")
    local status = survey:status()
    assert(status.complete and status.roomsDone == 2 and status.sectionsSearched == 1 and status.sectionsUnsearched == 2)
    assert(#status.unsearchedRooms == 2)
end)

test("foreign room metadata is unsearched instead of searching another building", function()
    local f = fixture()
    f.rooms[1] = f.room("first", 0, { f.rectangle(0, 0, 1, 1) })
    f.rooms[2] = f.room("foreign", 0, { f.rectangle(2, 2, 1, 1) }, {})
    local survey = assert(Survey.ofBuilding(f.building))
    assert(#exhaust(survey) == 1)
    local status = survey:status()
    assert(status.complete and status.roomsDone == 2 and status.sectionsSearched == 1 and status.sectionsUnsearched == 1)
    assert(status.unsearchedRooms[1].roomId == "foreign")
end)

test("reported status snapshots cannot rewrite retained failure information", function()
    local f = fixture()
    f.rooms[1] = f.room("blocked", -1, { f.rectangle(0, 0, 1, 1) })
    local survey = assert(Survey.ofBuilding(f.building))
    local section = assert(survey:next())
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
    local missing, reason = Survey.ofBuilding({})
    assert(missing == nil and type(reason) == "string")
    local f = fixture()
    local survey = assert(Survey.ofBuilding(f.building))
    assert(survey:next() == nil)
    assert(survey:status().complete and survey:status().roomsTotal == 0)
end)

test("a marked area is one place in small sections", function()
    local survey = assert(Survey.ofArea({ x1 = 11, x2 = 0, y1 = 0, y2 = 3, z = -1 }, 100))
    local sections = exhaust(survey, { x = 0, y = 0, z = -1 })
    assert(#sections == 2 and bounds(sections[1]) == "0,0,8,4,-1" and bounds(sections[2]) == "8,0,12,4,-1")
    assert(survey:status().roomsTotal == 1 and survey:status().roomsDone == 1 and not survey.building)
    assert(not Survey.ofArea({ x1 = 0, x2 = 100, y1 = 0, y2 = 0, z = 0 }, 100), "101 tiles")
    assert(not Survey.ofArea({ x1 = 0.5, x2 = 1, y1 = 0, y2 = 0, z = 0 }, 100) and not Survey.ofArea(nil, 100))
end)

print(passed .. " building survey cases passed (explicit native metadata doubles)")
