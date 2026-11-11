package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

-- World/action boundaries are doubles. The actual App, category graph, catalog,
-- and data-only Store run together; native file I/O has a separate smoke check.
local files, denied, jobState, resumeCalls, resumeError = {}, false, "idle", 0, nil
function getFileReader(path)
    if not files[path] then return nil end
    local read = false
    return { readLine = function() if not read then read = true; return files[path] end end, close = function() end }
end
function getFileWriter(path)
    if denied then return nil end
    local text = ""
    return { write = function(_, part) text = text .. part end, close = function() files[path] = text end }
end
local worldName, username = "server:alpha/season-one", "Alice:one"
local player = { getUsername = function() return username end, getPlayerNum = function() return 0 end }
function getSpecificPlayer() return player end
function getWorld() return { getWorld = function() return worldName end } end
function getTimestampMs() return 0 end
function getAllItems()
    return { size = function() return 1 end, get = function()
        return { getObsolete = function() return false end, isHidden = function() return false end,
            getFullName = function() return "Example.Widget" end, getDisplayName = function() return "Widget" end,
            getDisplayCategory = function() return "ModdedCategory" end }
    end }
end
function getText(key) return key end
Events = nil
package.loaded["LootBox/World"] = { new = function(_, state)
    return { key = function(_, container) return container.id end, itemId = function(_, item) return item.id end,
        discover = function() end, observeNearby = function() return false end,
        protected = function(_, item) return state.keep[item.id] == true end,
        rememberVehicle = function(_, vehicle)
            if not vehicle then return nil, "Vehicle unavailable" end
            state.vehicle = { id = 1, x = 1, y = 2, z = 0, script = "Base.Car" }
            return true
        end }
end }
package.loaded["LootBox/Jobs"] = { new = function()
    return { status = function() return { state = jobState } end, cancel = function() return true end,
        tick = function() end, start = function() return true end, resume = function()
            resumeCalls = resumeCalls + 1
            if resumeError then return nil, resumeError end
            jobState = "running"
            return true
        end }
end }
local App = require "LootBox/App"
local Store = require "LootBox/Store"
local function same(actual, expected)
    assert(#actual == #expected, "List length differs")
    for index, value in ipairs(expected) do assert(actual[index] == value, "List value differs") end
end
local passed = 0
local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

local medicine, supplies
test("main-menu custom categories preserve native and nested memberships", function()
    medicine = assert(App.saveCategory({ name = "Medical", types = { "Base.Bandage" }, includes = {} }))
    supplies = assert(App.saveCategory({ name = "Run supplies", types = {}, includes = { medicine, "native:Food" } }))
    same(App.category(supplies).includes, { medicine, "native:Food" })
    local catalog = assert(App.catalog())
    assert(catalog.items[1].fullType == "Example.Widget")
    assert(catalog.categories[1].id == "native:ModdedCategory")
    assert(not App.saveCategory({ id = medicine, name = "Medical", types = {}, includes = { supplies } }))
    same(App.category(medicine).types, { "Base.Bandage" })
end)

local crate, item = { id = "crate:drawer:0" }, { id = "item:12" }
test("world/player identity punctuation supports labels Keep and reusable checklists", function()
    local app = assert(App.get(0))
    assert(app:setLabels(crate, { supplies, "native:Food" }))
    assert(app:setItemLabels(item, { medicine, supplies }))
    assert(app:protect(item, true))
    assert(app:setChecklist({ ids = { supplies }, types = { "Base.WaterBottle" }, all = false }))
    assert(not app:rememberVehicle(nil))
    App.reset()
    app = assert(App.get(0))
    same(app:labels(crate), { supplies, "native:Food" })
    same(app:itemLabels(item), { medicine, supplies })
    assert(app:isKept(item))
    same(app:getChecklist().ids, { supplies })
    same(app:getChecklist().types, { "Base.WaterBottle" })
end)

test("different worlds and players retain independent saved intentions", function()
    worldName = "server:beta/season-one"
    App.reset()
    same(assert(App.get(0)):labels(crate), {})
    worldName, username = "server:alpha/season-one", "Bob:two"
    App.reset()
    same(assert(App.get(0)):itemLabels(item), {})
    username = "Alice:one"
    App.reset()
    assert(assert(App.get(0)):isKept(item))
end)

test("a native player whose username settles later binds the final account preferences", function()
    username = "Bob"
    local provisional = assert(App.get(0))
    same(provisional:labels(crate), {})
    assert(provisional:setLabels(crate, { "native:ModdedCategory" }))
    username = "Alice:one"
    local settled = assert(App.get(0))
    same(settled:labels(crate), { supplies, "native:Food" })
    assert(settled:rememberVehicle({}))
    App.reset()
    settled = assert(App.get(0))
    same(settled:labels(crate), { supplies, "native:Food" })
    assert(settled.state.vehicle.id == 1)
end)

test("failed native writes leave active labels and Keep unchanged", function()
    local app = assert(App.get(0))
    denied = true
    assert(not app:setLabels(crate, { "native:Tool" }))
    same(app:labels(crate), { supplies, "native:Food" })
    assert(not app:protect(item, false))
    assert(app:isKept(item))
    denied = false
end)

test("deleting a category never reuses its identity for a different category", function()
    local obsolete = assert(App.saveCategory({ name = "Old", types = {}, includes = {} }))
    assert(App.deleteCategory(obsolete))
    App.reset()
    local replacement = assert(App.saveCategory({ name = "New", types = {}, includes = {} }))
    assert(replacement ~= obsolete)
end)

test("a job paused for bin review keeps its category selection stable", function()
    assert(App.get(0))
    local before = #assert(App.catalog()).categories
    jobState = "needs_review"
    local id, reason = App.saveCategory({ name = "Wait for cleanup", types = {}, includes = {} })
    assert(id == nil and reason:find("current job", 1, true))
    assert(#assert(App.catalog()).categories == before)
    jobState = "idle"
    id = assert(App.saveCategory({ name = "Cleanup finished", types = {}, includes = {} }))
    assert(App.category(id).name == "Cleanup finished")
end)

test("Resume forwards success and a current native refusal to the existing job", function()
    local app = assert(App.get(0))
    jobState, resumeError = "cancelled", "Stop aiming before resuming"
    local ok, err = app:resume()
    assert(ok == nil and err == resumeError and resumeCalls == 1 and app:status().state == "cancelled")
    resumeError = nil
    assert(app:resume() and resumeCalls == 2 and app:status().state == "running")
    jobState = "idle"
end)

test("a validly encoded malformed category document remains read-only", function()
    assert(Store.save("LootBox/categories", { categories = false }))
    App.reset()
    assert(assert(App.catalog()).error)
    assert(not App.saveCategory({ name = "Do not overwrite", types = {}, includes = {} }))
    assert(assert(Store.load("LootBox/categories")).categories == false)
end)
print(passed .. " App integration cases passed (explicit world/action and file doubles)")
