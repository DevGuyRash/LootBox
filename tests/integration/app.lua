package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
package.loaded['TimedActions/ISTimedActionQueue'] = true
package.loaded['LootBox/AutoPutAway'] = {yield = function() end, forget = function(instance) instance.forgotten = true; instance.state.trip = nil end, update = function() end}

-- World/action boundaries are doubles. The actual App, category graph, catalog,
-- and data-only Store run together; native file I/O has a separate smoke check.
local files, denied, jobState, resumeCalls, resumeError = {}, false, "idle", 0, nil
local calls = {created = 0, previews = 0, starts = 0, pauses = 0, recoveries = 0}
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
local clock = 0
function getTimestampMs() return clock end
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
        _observe = function() end, forgetGlance = function() end, rename = function(_, container, name) container.named = name; return container.fixture == true end,
        endpoints = {}, valid = function() return true end, givenName = function() end, observeNearby = function() return calls.seen == true end,
        protected = function(_, item) return state.keep[item.id] == true end,
        rememberVehicle = function(_, vehicle)
            if not vehicle then return nil, "Vehicle unavailable" end
            state.vehicle = { id = 1, x = 1, y = 2, z = 0, script = "Base.Car" }
            return true
        end }
end }
package.loaded["LootBox/Jobs"] = { new = function()
    calls.created = calls.created + 1
    return { status = function() return { state = jobState, hasJob = jobState ~= "idle" and jobState ~= "cancelled", canPause = jobState == "running",
            canResume = jobState == "paused", canStart = true } end, cancel = function() return true end,
        tick = function() end,
        preview = function(_, request) calls.previews = calls.previews + 1; calls.request = request; return {request = request} end,
        refusal = function() return calls.refusal end,
        start = function(_, plan, options) calls.starts = calls.starts + 1; calls.plan, calls.options = plan, options; return true end,
        pause = function() calls.pauses = calls.pauses + 1; jobState = "paused"; return true end,
        recoverPersonalGear = function() calls.recoveries = calls.recoveries + 1; return true end,
        approveBin = function(_, review, options) calls.review, calls.approvalOptions = review, options; return true end,
        resume = function()
            resumeCalls = resumeCalls + 1
            if resumeError then return nil, resumeError end
            jobState = "running"
            return true
        end }
end }
package.loaded["LootBox/TillFull"] = {new = function() error("Unexpected consumption boundary") end}
local needsCalls, nearbyReads = 0, 0
package.loaded["LootBox/AutoNeeds"] = {interruptObservation=function()end,step=function(instance, opts, read, now)
    needsCalls = needsCalls + 1
    assert(opts.autoDrinkEquipped and opts == read() and now == getTimestampMs() and instance.player == player)
end}
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
test("passive session lookup leaves the main menu and categories free of player jobs", function()
    assert(App.peek(0) == nil and calls.created == 0)
    assert(App.catalog() and App.peek(0) == nil and calls.created == 0)
end)

test("opt-ins work with UI closed; passive sessions do not survey the world or wake other actors", function()
    local previous = getTimestampMs
    local clock = 0
    getTimestampMs = function() return clock end
    player.isLocalPlayer=function() return true end
    player.getCurrentSquare=function() return {} end
    for _, key in ipairs({"isMoving","isRunning","isSprinting","isAttacking","isAiming","hasTimedActions"}) do player[key]=function()return false end end
    App.onNeedsUpdate(player)
    assert(not App.peek(0) and needsCalls == 0)
    assert(App.setPreferences({autoConsumeNested=true}))
    App.onNeedsUpdate(player); assert(not App.peek(0) and needsCalls == 0)
    assert(App.setPreferences({autoDrinkEquipped=true}))
    App.onNeedsUpdate(player);assert(needsCalls==0)
    clock=800; player.isMoving=function()return true end;App.onNeedsUpdate(player)
    player.isMoving=function()return false end;clock=1450;App.onNeedsUpdate(player);assert(needsCalls==0)
    clock=1850;App.onNeedsUpdate(player); App.onNeedsUpdate(player); assert(needsCalls == 1)
    local passive=assert(App.peek(0)); assert(passive.needsOnly)
    passive.world.observeNearby=function() nearbyReads=nearbyReads+1;return false end
    App.tick();assert(nearbyReads==0)
    clock=6000; App.onNeedsUpdate(player); assert(needsCalls==2)
    assert(App.get(0)==passive and not passive.needsOnly); App.tick(); assert(nearbyReads==1)
    assert(App.setPreferences({autoDrinkEquipped=false,autoConsumeNested=false}))
    App.reset();getTimestampMs=previous
end)

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

test("deleting a category never reuses its identity for a different category", function()
    local obsolete = assert(App.saveCategory({ name = "Old", types = {}, includes = {} }))
    assert(App.deleteCategory(obsolete))
    App.reset()
    local replacement = assert(App.saveCategory({ name = "New", types = {}, includes = {} }))
    assert(replacement ~= obsolete)
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

test("an existing player session can be inspected without rebuilding its job or recovery", function()
    local app = assert(App.get(0))
    local created = calls.created
    assert(App.peek(0) == app and App.peek(0).recovery == app.recovery)
    assert(calls.created == created)
end)

test("Pause and bin review mode choices reach only the existing job", function()
    local app = assert(App.get(0))
    local plan, options, review = {}, {reviewBins = false}, {}
    local created, pauses = calls.created, calls.pauses
    assert(app:start(plan, options) and calls.plan == plan and calls.options.reviewBins == false and options.reviewBins == false)
    assert(app:approveBin(review, options) and calls.review == review and calls.approvalOptions == options)
    assert(app:pause() and calls.pauses == pauses + 1 and app:status().state == "paused")
    assert(calls.created == created)
    jobState = "idle"
end)

test("review scopes are independent and use explicit preference values", function()
    assert(App.setPreferences({confirmQuickMoves = false, confirmQuickCleanup = true, confirmBinReviews = false}))
    local ordinary, ordinaryKey = App.reviewPreference({destination = {kind = "matching"}})
    local cleanup, cleanupKey = App.reviewPreference({destination = {kind = "trash"}})
    local bins, binsKey = App.reviewPreference(nil, true)
    assert(ordinary == false and ordinaryKey == "confirmQuickMoves")
    assert(cleanup == true and cleanupKey == "confirmQuickCleanup")
    assert(bins == false and binsKey == "confirmBinReviews")
end)

test("new jobs use the current bin preference while explicit one-job options win without mutation", function()
    local app = assert(App.get(0))
    assert(App.setPreferences({confirmBinReviews = false}))
    assert(app:start({}) and calls.options.reviewBins == false)
    assert(App.setPreferences({confirmBinReviews = true}))
    assert(app:start({}) and calls.options.reviewBins == true)
    local options = {reviewBins = false, marker = "current job only"}
    assert(app:start({}, options) and calls.options.reviewBins == false and calls.options.marker == options.marker)
    assert(options.reviewBins == false and calls.options ~= options)
    assert(App.getPreferences().confirmBinReviews == true)
end)

test("a failed write keeps protection in effect, reports it, and never blocks later work", function()
    local app = assert(App.get(0))
    denied = true
    local fresh = {id = "item:fresh"}
    local ok, err = app:protect(fresh, true)
    assert(not ok and err and app:isKept(fresh) and app:status().warning)
    assert(app:preview({scope = "room"}), "A disk problem is not a reason to refuse a job")
    denied = false
    assert(app:protect(fresh, true) and app:status().warning == nil)
end)

test("categories can be edited while a job runs, pauses or waits", function()
    assert(App.get(0))
    for _, state in ipairs({"running", "paused", "needs_review"}) do
        jobState = state
        assert(App.saveCategory({name = "While " .. state, types = {}, includes = {}}))
    end
    jobState = "idle"
end)

test("deleting a category clears it from storage, tags, loot list and other categories", function()
    local app = assert(App.get(0))
    local doomed = assert(App.saveCategory({name = "Doomed", types = {"Base.Nails"}, includes = {}}))
    local holder = assert(App.saveCategory({name = "Holder", types = {}, includes = {doomed, "native:Food"}}))
    assert(app:setLabels(crate, {doomed, "native:Food"}) and app:setItemLabels(item, {doomed}))
    assert(app:setChecklist({ids = {doomed}, types = {"Base.Nails"}}))
    assert(App.deleteCategory(doomed))
    same(app:labels(crate), {"native:Food"}); same(app:itemLabels(item), {})
    same(app:getChecklist().ids, {}); same(App.category(holder).includes, {"native:Food"})
end)

test("one damaged saved value costs only itself", function()
    App.reset()
    local app = assert(App.get(0))
    local path = app.path
    local data = assert(Store.load(path))
    data.containerLabels = {["crate:ok"] = {"native:Food", "custom:99999"}, ["crate:bad"] = "Food"}
    data.vehicle = {id = "broken"}
    assert(Store.save(path, data))
    assert(Store.save("LootBox/preferences", {contextMenus = false, retiredOption = true, jobBar = "sometimes"}))
    App.reset()
    app = assert(App.get(0))
    assert(app.state.vehicle == nil)
    same(app:labels({id = "crate:ok"}), {"native:Food"}); same(app:labels({id = "crate:bad"}), {})
    local preferences = App.getPreferences()
    assert(preferences.contextMenus == false and preferences.jobBar == true and preferences.retiredOption == nil)
    assert(App.setPreferences({contextMenus = true}), "Preferences stay editable")
end)

test("an unreadable categories file costs no custom label, on disk or in memory", function()
    App.reset()
    local app = assert(App.get(0))
    local custom = assert(App.saveCategory({name = "Tools I like", types = {"Example.Widget"}, includes = {}}))
    assert(app:setLabels({id = "crate:mine"}, {custom, "native:Food"}) and app:setItemLabels(item, {custom}))
    assert(app:setChecklist({ids = {custom}, types = {}}))
    local kept = {}
    for _, slot in ipairs({".a.txt", ".b.txt"}) do kept[slot], files["LootBox/categories" .. slot] = files["LootBox/categories" .. slot], "garbage" end
    App.reset()
    app = assert(App.get(0))
    same(app:labels({id = "crate:mine"}), {custom, "native:Food"}); same(app:itemLabels(item), {custom}); same(app:getChecklist().ids, {custom})
    assert(app:setLabels({id = "crate:mine"}, {custom}))
    local fresh = assert(App.saveCategory({name = "New one", types = {}, includes = {}}))
    assert(fresh ~= custom, "A new category must not take over an old label")
    assert(app:setLabels({id = "crate:other"}, {"native:Food"}))
    for slot, text in pairs(kept) do files["LootBox/categories" .. slot] = text end
    App.reset()
    app = assert(App.get(0))
    same(app:labels({id = "crate:mine"}), {custom})
    assert(App.category(custom).name == "Tools I like")
end)

test("what is seen along the way is saved at most every half minute, and when the game saves or ends", function()
    App.reset()
    local app = assert(App.get(0))
    local writes, persist = 0, app.persist
    app.state.trash = {}
    function app:persist() writes = writes + 1; return persist(self) end
    local function seeBin(name) app.state.trash[name] = 20; calls.seen = true; clock = clock + 1000; App.tick(); calls.seen = false end
    clock = 1000000
    for index = 1, 29 do seeBin("bin:" .. index) end
    assert(writes == 0)
    for _ = 1, 3 do seeBin("bin:30") end
    assert(writes == 1)
    seeBin("bin:31"); assert(app:start({}) and writes == 1, "Starting a job is not a reason to write")
    App.save(); App.save(); assert(writes == 2)
    seeBin("bin:32"); App.reset()
    assert(writes == 3 and App.get(0).state.trash["bin:32"])
    clock = 0
end)

-- Job ownership: the engine is a double with real pause/resume states.
local Runner = {}
Runner.__index = Runner
local function runner(state) return setmetatable({state = state or "idle", log = {}}, Runner) end
function Runner:status() return {state = self.state, intent = self.intent, sourceContainer = self.sourceContainer, carried = self.carried, hasJob = self.state ~= "idle", canPause = self.state == "running", canResume = self.state == "paused",
    canStart = self.state == "idle", done = 3, total = 9} end
function Runner:pause(trigger) self.log[#self.log + 1] = "pause"; self.trigger = trigger; self.state = self.settles == false and "pausing" or "paused"; return true end
function Runner:resume() self.log[#self.log + 1] = "resume"; self.state = "running"; return true end
function Runner:cancel() self.log[#self.log + 1] = "cancel"; self.state = "idle"; return true end
function Runner:preview(request) self.log[#self.log + 1] = "preview"; return {request = request, moves = {{}}} end
function Runner:refusal() return self.refuses end
function Runner:start(plan)
    self.log[#self.log + 1] = "start"
    if self.fails then return nil, self.fails end
    self.state, self.intent, self.sourceContainer = "running", plan.request.shortcutIntent, plan.request.sourceContainer
    return true
end
function Runner:tick() end
local function working(state)
    App.reset()
    local app = assert(App.get(0))
    app.jobs = runner(state)
    app.jobs.label = "Clean kitchen"
    app.newRunner = function() return runner("idle") end
    return app
end
local want = {scope = "room", destination = {kind = "inventory"}, filter = {all = true}}

test("planning and nothing-to-do leave a running job alone", function()
    local app = working("running")
    local old = app.jobs
    assert(app:preview(want) and old.state == "running" and #old.log == 0)
end)

test("a new job sets the running one aside, and it can be resumed afterwards", function()
    local app = working("running")
    local old = app.jobs
    local plan = assert(app:preview(want))
    assert(app:start(plan))
    assert(old.state == "paused" and app.jobs ~= old and app.jobs.state == "running" and app.parked == old)
    assert(app:status().previous.label == "Clean kitchen")
    app.jobs.state = "idle"
    assert(app:resumePrevious() and app.jobs == old and old.state == "running" and app.parked == nil)
end)

test("pressing the same toolbar button again resumes its paused job and leaves a running one alone", function()
    local app = working("running")
    local job = app.jobs
    job.intent = "matching:nearby"
    local again = {shortcutIntent = "matching:nearby"}
    local found, outcome = app:again(again)
    assert(found and outcome == "running" and #job.log == 0)
    job.state = "paused"
    found, outcome = app:again(again)
    assert(found and outcome == "resumed" and job.state == "running" and app.jobs == job and app.parked == nil)
    assert(not app:again({shortcutIntent = "matching:displayed"}), "Another button is another action")
    assert(not app:again({}), "Menus always start fresh")
    job.intent, job.sourceContainer = "smart:all", "crate A"
    assert(app:again({shortcutIntent = "smart:all", sourceContainer = "crate A"}))
    assert(not app:again({shortcutIntent = "smart:all", sourceContainer = "crate B"}), "Another displayed container is another action")
    job.state = "idle"
    assert(not app:again({shortcutIntent = "smart:all", sourceContainer = "crate A"}), "A finished job is not resumed")
end)

test("pressing the button of a job that was set aside brings it back, whatever is running", function()
    local app = working("running")
    local first = app.jobs
    first.intent = "condense"
    assert(app:start(assert(app:preview(want))))
    local second = app.jobs
    assert(app.parked == first and second.state == "running")
    local found, outcome = app:again({shortcutIntent = "condense"})
    assert(found and outcome == "resumed" and app.jobs == first and first.state == "running")
    assert(second.state == "paused" and app.parked == second)
end)

test("a newer click of one button replaces its older job, unless that one is carrying something", function()
    for carried, parked in pairs({[0] = false, [3] = true}) do
        local app = working("paused")
        local old = app.jobs
        old.intent, old.sourceContainer, old.carried = "smart:all", "crate A", carried
        local fresh = {scope = "container", shortcutIntent = "smart:all", sourceContainer = "crate B", destination = {kind = "inventory"}, filter = {all = true}}
        assert(app:start(assert(app:preview(fresh))))
        assert(app.jobs ~= old and app.jobs.state == "running" and (app.parked == old) == parked)
        assert(old.state == (parked and "paused" or "idle"))
    end
end)

test("a job that cannot start does not disturb the one in progress", function()
    local app = working("running")
    local old = app.jobs
    local plan = assert(app:preview(want))
    app.spare.refuses = "Get out of the vehicle before starting this job"
    local ok, err = app:start(plan)
    assert(ok == nil and err == app.spare.refuses and old.state == "running" and #old.log == 0 and app.jobs == old)
    app.spare.refuses, app.spare.fails = nil, "Preview this job again before starting"
    ok, err = app:start(plan)
    assert(ok == nil and err:find("Preview", 1, true) and app.jobs == old and old.state == "running" and app.parked == nil)
    old.state = "paused"
    assert(not app:start(plan) and old.state == "paused", "A job the player paused stays paused")
end)

test("takeover waits for the old job's native action to settle", function()
    local app = working("running")
    local old = app.jobs
    old.settles = false
    assert(app:start(assert(app:preview(want))))
    assert(app.jobs == old and app.takeover, "Still settling")
    App.tick(); assert(app.jobs == old)
    old.state = "paused"
    App.tick()
    assert(app.jobs ~= old and app.jobs.state == "running" and not app.takeover)
end)

test("drinking pauses the running job and carries on with it afterwards", function()
    local app = working("running")
    local controller = {busy = true, state = "running", name = "Til Full", ticks = 0}
    function controller:isBusy() return self.busy end
    function controller:alreadySatisfied() return false end
    function controller:tick() self.ticks = self.ticks + 1 end
    function controller:status() return {state = self.state} end
    function controller:cancel() self.busy = false; return true end
    local module = package.loaded["LootBox/TillFull"]
    local before = module.new
    module.new = function() return controller end
    assert(app:tillFull({item}, "fluid"))
    assert(app.jobs.state == "paused" and app.consumption == controller and controller.ticks > 0)
    App.tick(); assert(app.jobs.state == "paused", "Not while still drinking")
    controller.busy = false
    App.tick(); assert(app.jobs.state == "running")
    local status = app:status()
    assert(status.state == "running" and status.canPause and status.label == "Clean kitchen" and not status.consuming, "The job is shown, not the finished drink")
    module.new = before
end)

test("a job started before a pending drink begins replaces that drink", function()
    local app = working("running")
    local began = 0
    local module = package.loaded["LootBox/TillFull"]
    local before = module.new
    module.new = function() return {alreadySatisfied = function() return false end, isBusy = function() return false end, tick = function() began = began + 1 end, state = "finished"} end
    app.jobs.settles = false
    assert(app:tillFull({item}, "fluid") and app.borrowed)
    assert(app:start(assert(app:preview(want))) and app.borrowed == nil)
    App.tick(); assert(began == 0)
    module.new = before
end)

test("drinking never resumes a job the player paused", function()
    local app = working("paused")
    local controller = {busy = false, state = "finished"}
    function controller:isBusy() return self.busy end
    function controller:alreadySatisfied() return false end
    function controller:tick() end
    function controller:status() return {state = self.state} end
    local module = package.loaded["LootBox/TillFull"]
    local before = module.new
    module.new = function() return controller end
    assert(app:tillFull({item}, "fluid"))
    App.tick(); App.tick()
    assert(app.jobs.state == "paused")
    module.new = before
end)

test("an automatic sip yields to the player's own request", function()
    local app = working("idle")
    local sip = {automatic = true, busy = true}
    function sip:isBusy() return self.busy end
    function sip:cancel() self.busy = false; return true end
    function sip:tick() end
    function sip:status() return {state = "running"} end
    app.consumption = sip
    assert(app:start(assert(app:preview(want))) and not sip.busy)
end)

test("Escape pauses a job unless that press is closing something", function()
    local app = working("running")
    Keyboard = {KEY_ESCAPE = 1}
    local typing, guard = false, false
    getCore = function() return {isDoingTextEntry = function() return typing end} end
    App.escapeGuard = function() return guard end
    typing = true; App.onKeyStartPressed(1); assert(app.jobs.state == "running")
    typing, guard = false, true; App.onKeyStartPressed(1); assert(app.jobs.state == "running")
    guard = false; App.onKeyStartPressed(2); assert(app.jobs.state == "running")
    App.onKeyStartPressed(1); assert(app.jobs.state == "paused" and app.jobs.trigger == "escape")
    Keyboard, getCore, App.escapeGuard = nil, nil, nil
end)

local function thing(id, fullType) return {id = id, getFullType = function() return fullType end, getID = function() return id end} end

test("kinds, single items and anything else are labels, saved and read back, with or without the container", function()
    App.reset()
    local app = assert(App.get(0))
    local crate = {id = "world:1:2:0:#0:crate:0:crate"}
    assert(app:setLabels(crate, {"type:Base.Nails", "native:Food", "rest:", "custom:99"}))
    same(app:labels(crate), {"type:Base.Nails", "native:Food", "rest:"})
    same(app:labels(crate.id), {"type:Base.Nails", "native:Food", "rest:"})
    assert(app:toggleLabel(crate.id, "native:Food") and app:toggleLabel(crate.id, "type:Base.Saw"))
    App.reset()
    same(assert(App.get(0)):labels(crate), {"type:Base.Nails", "rest:", "type:Base.Saw"})
    assert(App.categoryName("rest:") == "Anything else")
end)

test("a name and an order are saved by key, and cleared by an empty name and the usual order", function()
    App.reset()
    local app = assert(App.get(0))
    assert(app:setStorage("vehicle:7:Base.Car:TruckBed", {name = "  Haul\n ", order = "first"}))
    App.reset()
    app = assert(App.get(0))
    local details = app:storageDetails("vehicle:7:Base.Car:TruckBed")
    assert(details.name == "Haul" and details.order == "first")
    assert(app:setStorage("vehicle:7:Base.Car:TruckBed", {order = "usual"}) and app:setStorage("vehicle:7:Base.Car:TruckBed", {name = ""}))
    assert(app.state.storage["vehicle:7:Base.Car:TruckBed"] == nil)
end)

test("one item has one place, and its mark goes when no place or list names it", function()
    App.reset()
    local app = assert(App.get(0))
    local axe, rack, shed = thing("41", "Base.Axe"), {id = "rack"}, {id = "shed"}
    local mark = "item:41:Base.Axe"
    assert(app:setItemPlace(axe, rack, true))
    same(app:labels(rack), {mark}); same(app:itemLabels(axe), {mark})
    assert(app:setItemPlace(axe, shed, true))
    assert(#app:labels(rack) == 0); same(app:labels(shed), {mark})
    assert(app:setItemWanted(axe, true) and app:onChecklist("ids", mark))
    assert(app:setItemPlace(axe, shed, false))
    same(app:itemLabels(axe), {mark})
    assert(app:setItemWanted(axe, false))
    assert(#app:itemLabels(axe) == 0 and not app:onChecklist("ids", mark))
end)

test("a mark to pick something up comes off once it is carried", function()
    App.reset()
    local app = assert(App.get(0))
    local axe, carried = thing(52, "Base.Axe"), {}
    player.getInventory = function() return {getItems = function()
        return {size = function() return #carried end, get = function(_, index) return carried[index + 1] end} end} end
    assert(app:setItemWanted(axe, true))
    clock = clock + 2000; App.tick()
    assert(app:onChecklist("ids", "item:52:Base.Axe"))
    carried[1] = thing(52, "Base.Axe")
    clock = clock + 2000; App.tick()
    assert(not app:onChecklist("ids", "item:52:Base.Axe"))
    player.getInventory = nil
end)

test("keeping a kind is saved, and damaged storage data costs only what is damaged", function()
    App.reset()
    local app = assert(App.get(0))
    assert(app:keepType("Base.Nails", true) and app:isTypeKept("Base.Nails"))
    app.state.storage = {good = {name = "Pantry"}, bad = 7, worse = {name = {}, order = "sideways"}}
    app.state.keepTypes[12] = true
    assert(app:persist())
    App.reset()
    app = assert(App.get(0))
    assert(app:isTypeKept("Base.Nails") and app.state.keepTypes[12] == nil)
    assert(app.state.storage.good.name == "Pantry" and app.state.storage.bad == nil and app.state.storage.worse == nil)
end)

test("turning automatic put-away off forgets the trip, and so does a world opened while it is off", function()
    App.reset()
    local app = assert(App.get(0))
    assert(App.setPreferences({autoPutAway = true}))
    app.state.trip = {who = "Ann", had = {}}
    assert(App.setPreferences({autoPutAway = false}) and app.forgotten and app.state.trip == nil)
    app.state.trip = {who = "Ann", had = {}}
    assert(app:persist())
    App.reset()
    assert(assert(App.get(0)).state.trip == nil)
end)

test("Put Away pressed again starts afresh from a paused one, unless that one is carrying something", function()
    App.reset()
    local app = assert(App.get(0))
    local request = {shortcutIntent = "put-away", only = {["1"] = true}}
    local status = {hasJob = true, intent = "put-away", canResume = true, carried = 0}
    app.jobs.status = function() return status end
    assert(app:again(request) == false)
    status.carried = 2
    assert(app:again(request) == true)
    status.canResume, status.carried = false, 0
    local found, outcome = app:again(request)
    assert(found and outcome == "running")
end)

test("a job for certain items is not offered again as the last one", function()
    App.reset()
    local app = assert(App.get(0))
    assert(app:rememberSetup({scope = "inventory", filter = {all = true, ids = {}, types = {}}, destination = {kind = "labels", labels = {}}, only = {["1"] = true}}))
    assert(app:lastSetup() == nil)
end)

test("the game item catalog is read once and custom categories refresh it", function()
    App.reset()
    local reads, original = 0, getAllItems
    getAllItems = function() reads = reads + 1; return original() end
    local first = assert(App.catalog())
    assert(App.catalog() == first and reads == 1)
    assert(App.saveCategory({name = "Fresh", types = {}, includes = {}}))
    local second = assert(App.catalog())
    assert(second ~= first and reads == 1 and second.categories[#second.categories].name == "Fresh")
    getAllItems = original
end)
print(passed .. " App integration cases passed (explicit world/action and file doubles)")

