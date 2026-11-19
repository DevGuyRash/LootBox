package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

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
    calls.created = calls.created + 1
    return { status = function() return { state = jobState } end, cancel = function() return true end,
        tick = function() end,
        preview = function(_, request) calls.previews = calls.previews + 1; calls.request = request; return {request = request} end,
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

test("paused and pausing jobs retain their category meanings until explicitly cancelled", function()
    local before = #assert(App.catalog()).categories
    for _, state in ipairs({"paused", "pausing"}) do
        jobState = state
        local id, reason = App.saveCategory({name = "Cannot change a paused job", types = {}, includes = {}})
        assert(id == nil and reason and #assert(App.catalog()).categories == before)
    end
    jobState = "idle"
end)

test("pending gear recovery blocks both new previews and previously reviewed starts", function()
    local app = assert(App.get(0))
    local recovery = app.recovery
    app.recovery = {status = function() return {pending = true, count = 1, reason = "Recover the backpack in the porch cabinet"} end}
    local previews, starts, recoveries = calls.previews, calls.starts, calls.recoveries
    local plan, reason = app:preview({scope = "room"})
    assert(not plan and reason:find("backpack", 1, true) and calls.previews == previews)
    local started
    started, reason = app:start({})
    assert(not started and reason:find("backpack", 1, true) and calls.starts == starts)
    local status = app:status()
    assert(status.recovery.pending and status.recovery.count == 1)
    assert(app:recoverPersonalGear() and calls.recoveries == recoveries + 1)
    app.recovery = recovery
    local request = {scope = "room"}
    assert(app:preview(request) and calls.previews == previews + 1 and calls.request == request)
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

test("unreadable preferences require reviews until a current explicit choice is supplied", function()
    local prior = App.getPreferences()
    assert(Store.save("LootBox/preferences", {unknownSetting = true}))
    App.reset()
    for _, query in ipairs({{destination = {kind = "inventory"}}, {destination = {kind = "trash"}}}) do
        local required, _, err = App.reviewPreference(query)
        assert(required and err)
    end
    local required, _, err = App.reviewPreference(nil, true)
    assert(required and err and not App.setPreferences({confirmBinReviews = false}))
    local app = assert(App.get(0))
    assert(app:start({}) and calls.options.reviewBins == true)
    assert(app:start({}, {reviewBins = false}) and calls.options.reviewBins == false)
    assert(Store.load("LootBox/preferences").unknownSetting == true)
    assert(Store.save("LootBox/preferences", prior))
    App.reset()
end)

test("Til Full owns the App action boundary until cancellation settles", function()
    local app = assert(App.get(0))
    local controller = {busy = true, state = "running"}
    function controller:isBusy() return self.busy end
    function controller:alreadySatisfied() return self.full end
    function controller:status() return {state = self.state, hasJob = self.busy, canPreview = not self.busy} end
    function controller:tick() self.ticks = (self.ticks or 0) + 1 end
    function controller:cancel() self.cancelled = true; self.state = "cancelling"; return true end
    local module = package.loaded["LootBox/TillFull"]
    local oldNew, oldStatus, oldCancel = module.new, app.jobs.status, app.jobs.cancel
    local canRecipe, expectedRecipe, expectedSource = {}, nil, nil
    module.new = function(_, _, items, kind, both, recipe, source)
        assert(items[1] == item and kind == "food" and both == false)
        assert(recipe == expectedRecipe and source == expectedSource)
        return controller
    end
    local pending = true
    app.jobs.status = function() return {hasJob = pending, canPreview = not pending, state = "paused"} end
    app.jobs.cancel = function() calls.consumeJobCancel = true; return true end
    controller.full = true
    assert(app:tillFull({item}, "food") and not calls.consumeJobCancel and not controller.ticks)
    expectedRecipe, expectedSource = canRecipe, {}
    assert(app:tillFull({item}, "food",canRecipe,expectedSource) and not calls.consumeJobCancel and not controller.ticks)
    expectedRecipe, expectedSource = nil, nil
    controller.full = false
    assert(not app:tillFull({item}, "food") and calls.consumeJobCancel)
    pending = false
    assert(app:tillFull({item}, "food") and controller.ticks == 1)
    local previews, starts, recoveries, resumes = calls.previews, calls.starts, calls.recoveries, resumeCalls
    assert(not app:preview({}) and not app:previewCondense() and not app:start({}))
    assert(not app:pause() and not app:resume() and not app:recoverPersonalGear())
    assert(calls.previews == previews and calls.starts == starts and calls.recoveries == recoveries and resumeCalls == resumes)
    assert(not app:tillFull({item}, "food"))
    assert(app:cancel() and controller.cancelled and app:status().state == "cancelling")
    assert(not app:start({}), "Cancellation still owns pending cleanup")
    controller.busy, controller.state = false, "cancelled"
    assert(app:start({}) and app.consumption == nil)
    app.consumption = controller
    assert(app:recoverPersonalGear() and app.consumption == nil)
    app.consumption = controller
    assert(app:resume() and app.consumption == nil)
    app.jobs.status, app.jobs.cancel, module.new = oldStatus, oldCancel, oldNew
end)

test("new requests replace active or paused jobs only after cleanup; latest request wins", function()
    local app = assert(App.get(0))
    local oldStatus, oldCancel = app.jobs.status, app.jobs.cancel
    local status = {hasJob = true, canPreview = false, state = "running"}
    local cancels, first, second = 0, 0, 0
    app.jobs.status = function() return status end
    app.jobs.cancel = function() cancels = cancels + 1; return true end
    assert(app:replaceJob(function() first = first + 1 end))
    assert(app:replaceJob(function() second = second + 1; return true end))
    app:runReplacement()
    assert(cancels == 2 and first == 0 and second == 0)
    status = {hasJob = false, canPreview = true, state = "cancelled"}
    app:runReplacement(); app:runReplacement()
    assert(first == 0 and second == 1)
    assert(app:replaceJob(function() second = second + 1; return true end))
    assert(second == 2, "Idle request executes immediately")
    status = {hasJob = true, canPreview = true, state = "paused"}
    assert(app:replaceJob(function() first = first + 1 end))
    assert(first == 0, "Paused checkpoint must be cancelled, never implicitly resumed")
    app:cancel()
    status = {hasJob = false, canPreview = true}
    app:runReplacement()
    assert(first == 0 and app.replacement == nil)
    app.jobs.status, app.jobs.cancel = oldStatus, oldCancel
end)

test("deferred replacement fails safely when recovery appears or callback fails", function()
    local app = assert(App.get(0))
    local oldStatus, oldCancel, oldRecovery = app.jobs.status, app.jobs.cancel, app.recovery.status
    local status, pending, ran = {hasJob = true, canPreview = false}, false, false
    app.jobs.status = function() return status end
    app.jobs.cancel = function() return true end
    app.recovery.status = function() return {pending = pending} end
    assert(app:replaceJob(function() ran = true end))
    status, pending = {hasJob = false, canPreview = true}, true
    app:runReplacement()
    assert(not ran and app:status().reason:find("Recover personal gear", 1, true))
    pending, status = false, {hasJob = true, canPreview = false}
    assert(app:replaceJob(function() error("injected replacement error") end))
    status = {hasJob = false, canPreview = true}
    app:runReplacement()
    assert(app.replacement == nil and app:status().reason:find("injected replacement error", 1, true))
    app.replacementProblem = nil
    app.jobs.status, app.jobs.cancel, app.recovery.status = oldStatus, oldCancel, oldRecovery
end)

test("Escape pauses work and clears queued replacements even when native UI consumed its event", function()
    local app = assert(App.get(0))
    local oldStatus, oldCancel = app.jobs.status, app.jobs.cancel
    local status, ran = {hasJob = true, canPreview = false}, false
    app.jobs.status = function() return status end
    app.jobs.cancel = function() return true end
    Keyboard = {KEY_ESCAPE = 1}
    local down = false
    isKeyDown = function() return down end
    assert(app:replaceJob(function() ran = true end))
    local before = calls.pauses
    App.onKeyStartPressed(2)
    assert(calls.pauses == before)
    App.onKeyStartPressed(1)
    assert(calls.pauses == before + 1 and app.replacement == nil)
    assert(app:replaceJob(function() ran = true end))
    down = true; App.tick(); App.tick()
    assert(calls.pauses == before + 2 and app.replacement == nil)
    status = {hasJob = false, canPreview = true}
    down = false; App.tick()
    assert(not ran)
    Keyboard, isKeyDown = nil, nil
    app.jobs.status, app.jobs.cancel = oldStatus, oldCancel
end)

test("a validly encoded malformed category document remains read-only", function()
    assert(Store.save("LootBox/categories", { categories = false }))
    App.reset()
    assert(assert(App.catalog()).error)
    assert(not App.saveCategory({ name = "Do not overwrite", types = {}, includes = {} }))
    assert(assert(Store.load("LootBox/categories")).categories == false)
end)
print(passed .. " App integration cases passed (explicit world/action and file doubles)")

