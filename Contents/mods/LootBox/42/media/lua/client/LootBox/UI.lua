-- The one place menus, buttons and keys go through to start work or open a window.
require "PZAPI/ModOptions"
local App = require "LootBox/App"
local K = require "LootBox/UIKit"
local Main = require "LootBox/MainWindow"
local JobBar = require "LootBox/JobBar"
local Review = require "LootBox/Review"
local AreaPicker = require "LootBox/AreaPicker"
local PlanList = require "LootBox/PlanList"
local Log = require "LootBox/Log"

local UI = { visits = {} }

function UI.say(playerIndex, text, good)
    local player = getSpecificPlayer(playerIndex)
    text = tostring(text or "")
    if player and HaloTextHelper then
        local show = good and HaloTextHelper.addGoodText or HaloTextHelper.addBadText
        if show then show(player, text); return end
    end
    print("[LootBox] " .. text)
end

function UI.open(playerIndex, page, context) return Main.show(playerIndex or 0, page, context) end

function UI.showJob(playerIndex, problem)
    local bar = JobBar.show(playerIndex or 0, problem)
    bar.pinned = true
    return bar
end

local function begin(playerIndex, app, plan, interaction, options)
    local ok, err = app:start(plan, { interaction = interaction, reviewBins = options and options.reviewBins })
    if not ok then Log.warn(interaction, "NOT-STARTED", "reason", err) end
    return ok, err
end

-- Runs a request. Nothing disturbs the job in progress until there is
-- something to do and the player has agreed to any review they asked for.
function UI.act(playerIndex, request, options)
    playerIndex, options = playerIndex or 0, options or {}
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    local id = options.interaction or request.interaction
        or Log.intent("api", options.label or "request", app.player, "request", Log.request(request))
    request.interaction = id
    if options.area and not request.area then
        local picker
        picker, err = AreaPicker.start(playerIndex, function(area)
            Log.info(id, "AREA", "picked", area and (area.x1 .. "," .. area.y1 .. ".." .. area.x2 .. "," .. area.y2) or "cancelled")
            if not area then return end
            request.area = area
            options.area = nil
            UI.act(playerIndex, request, options)
        end)
        if not picker then UI.say(playerIndex, err) end
        return picker, err
    end
    local plan
    plan, err = app:preview(request)
    if not plan then
        Log.warn(id, "REFUSED", "reason", err)
        if not options.quiet then UI.say(playerIndex, err) end
        return nil, err
    end
    if #plan.moves == 0 and (plan.pending or 0) == 0 then
        local first = plan.skipped and plan.skipped[1]
        local reason = first and (#plan.skipped == 1 and (tostring(first.itemName) .. ": " .. tostring(first.reason))
            or (#plan.skipped .. " items stay put. " .. tostring(first.reason))) or "Nothing to move"
        Log.info(id, "END", "state", "nothing-to-do", "reason", reason)
        if not options.quiet then UI.say(playerIndex, reason) end
        return true, reason, "nothing"
    end
    app:rememberSetup(request)
    local wanted, preference = App.reviewPreference(request)
    if not wanted and not options.review then
        local ok
        ok, err = begin(playerIndex, app, plan, id)
        if not ok and not options.quiet then UI.say(playerIndex, err) end
        return ok, err, "started"
    end
    return Review.show(playerIndex, { kind = "plan", plan = plan, request = request, interaction = id, preference = wanted and preference or nil,
        title = "LootBox", heading = plan.label,
        start = function() return begin(playerIndex, app, plan, id) end,
        other = function() UI.open(playerIndex, "plan", { request = request }); return true end })
end

function UI.condense(playerIndex)
    playerIndex = playerIndex or 0
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    local id = Log.intent("toolbar.condense", "condense", app.player)
    local plan
    plan, err = app:previewCondense()
    if not plan then
        Log.warn(id, "REFUSED", "reason", err)
        UI.say(playerIndex, err)
        return nil, err
    end
    if #plan.moves == 0 and (plan.pending or 0) == 0 then
        local reason = plan.condense and plan.condense.reason or "Your bags are already packed well"
        Log.info(id, "END", "state", "nothing-to-do", "reason", reason)
        UI.say(playerIndex, reason, true)
        return true
    end
    local wanted, preference = App.reviewPreference(nil)
    if not wanted then
        local ok
        ok, err = begin(playerIndex, app, plan, id)
        if not ok then UI.say(playerIndex, err) end
        return ok, err
    end
    return Review.show(playerIndex, { kind = "condense", plan = plan, interaction = id, preference = preference, title = "LootBox",
        heading = "Condense bags", start = function() return begin(playerIndex, app, plan, id) end,
        other = function() UI.open(playerIndex, "settings"); return true end })
end

function UI.showBinReview(playerIndex)
    playerIndex = playerIndex or 0
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    local status = app:status()
    UI.visits[playerIndex] = { app = app, id = status.reviewId }
    local plan
    plan, err = app:reviewBin()
    if not plan then UI.say(playerIndex, err); return nil, err end
    return Review.show(playerIndex, { kind = "bin", plan = plan, interaction = status.interaction, preference = "confirmBinReviews", title = "LootBox",
        start = function(skip) return app:approveBin(plan, skip and { reviewBins = false } or nil) end,
        other = function() return app:rejectBin(plan) end })
end

-- A full picture for a bug report: who, where, what is around, what is saved.
function UI.snapshot(playerIndex)
    local app = App.get(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    local id = Log.intent("settings", "snapshot", player)
    local detailed = Log.detailed
    Log.detailed = true
    Log.info(id, "SNAPSHOT", "version", getCore():getVersion(), "screen", getCore():getScreenWidth() .. "x" .. getCore():getScreenHeight())
    local mods = getActivatedMods and getActivatedMods()
    if mods then
        local names = {}
        for index = 0, mods:size() - 1 do names[#names + 1] = tostring(mods:get(index)) end
        Log.trace(id, "mods", "active", table.concat(names, ","))
    end
    local preferences, changed = App.getPreferences(), {}
    for key, value in pairs(preferences) do changed[#changed + 1] = key .. "=" .. tostring(value) end
    table.sort(changed)
    Log.trace(id, "preferences", "values", table.concat(changed, ","))
    if app then
        local status = app:status()
        Log.trace(id, "job", "state", status.state, "label", status.label, "done", status.done, "total", status.total, "reason", status.reason,
            "previous", status.previous and status.previous.label)
        for _, page in ipairs({ getPlayerInventory(playerIndex), getPlayerLoot(playerIndex) }) do
            for index, button in ipairs(page and page.backpacks or {}) do
                Log.trace(id, "container", "pane", page.onCharacter and "inventory" or "loot", "icon", index, "state", Log.container(button.inventory, player))
                local items = button.inventory and button.inventory:getItems()
                for at = 0, math.min(60, items and items:size() or 0) - 1 do Log.trace(id, "item", "state", Log.item(items:get(at), player)) end
            end
        end
        for _, entry in ipairs(app.world:labelledContainers()) do
            Log.trace(id, "label", "key", entry.key, "name", entry.name, "labels", table.concat(entry.labels, "+"), "loaded", entry.container ~= nil)
        end
        for _, bin in ipairs(app.world:knownBins()) do Log.trace(id, "trash-can", "key", bin.key, "at", Log.point(bin.point)) end
        Log.trace(id, "saved", "vehicle", app.state.vehicle and app.state.vehicle.script, "lootList", Log.request({ filter = app:getChecklist(), destination = {} }))
    end
    Log.detailed = detailed
    return Log.flush() and Log.path() or nil
end

function UI.closeAll()
    Main.closeAll()
    Review.closeAll()
    AreaPicker.closeAll()
    JobBar.closeAll()
    K.resetLayout()
    UI.visits = {}
end

function UI.tick()
    local enabled = App.preference("jobBar")
    for playerIndex = 0, getNumActivePlayers() - 1 do
        local app = App.peek(playerIndex)
        if app then
            JobBar.tick(playerIndex, app, enabled)
            local status = app.jobs:status()
            if status.state == "needs_review" and status.reviewId ~= nil and not getCore():isDoingTextEntry() then
                local visit = UI.visits[playerIndex]
                if not visit or visit.app ~= app or visit.id ~= status.reviewId then UI.showBinReview(playerIndex) end
            end
        end
    end
end

-- One key: the job while there is one, otherwise the planner.
function UI.onKeyStartPressed(key)
    if getCore():isDoingTextEntry() or not getCore():isKey("LootBoxCurrentJob", key) or not getSpecificPlayer(0) then return end
    local app = App.get(0)
    if not app then return end
    local status = app:status()
    if app:active() or status.previous or (status.recovery and status.recovery.blocking) then
        local bar = JobBar.bars[0]
        if bar and bar:isVisible() and bar.pinned then bar:hide(); bar.pinned = false else UI.showJob(0) end
    elseif Main.open[0] and Main.open[0]:isVisible() then Main.open[0]:close()
    else UI.open(0, "plan") end
end

function UI.escapeGuard(playerIndex)
    if AreaPicker.open[playerIndex] then return true end
    for _, window in ipairs({ Main.open[playerIndex] or false, Review.open[playerIndex] or false }) do
        if window and window:isVisible() then return true end
    end
    return false
end

function UI.install()
    if UI.installed then return end
    UI.installed = true
    App.escapeGuard = UI.escapeGuard
    require("LootBox/Menus").install(UI)
    require "keyBinding"
    local known = {}
    for _, binding in ipairs(keyBinding) do known[binding.value] = true end
    if not known["[LootBox]"] then keyBinding[#keyBinding + 1] = { value = "[LootBox]" } end
    if not known.LootBoxCurrentJob then keyBinding[#keyBinding + 1] = { value = "LootBoxCurrentJob", key = Keyboard.KEY_F7 } end
    require("LootBox/Navigation").install()
    Events.OnTick.Add(UI.tick)
    Events.OnKeyStartPressed.Add(UI.onKeyStartPressed)
    if Events.OnDisconnect then Events.OnDisconnect.Add(UI.closeAll) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(UI.closeAll) end
    local options = PZAPI.ModOptions:getOptions("LootBox") or PZAPI.ModOptions:create("LootBox", "LootBox")
    options:addTitle("LootBox")
    require("LootBox/ContainerFocus").register(options)
    options:addButton("settings", "Settings", "Menus, buttons, reviews and automatic eating.", function() UI.open(0, "settings") end)
    options:addButton("manageCategories", "Categories", "Make your own item groups.", function() UI.open(0, "categories") end)
    options:addButton("help", "Help", "How to loot, sort, haul and clean.", function() UI.open(0, "help") end)
end

UI.Main, UI.JobBar, UI.Review, UI.AreaPicker, UI.PlanList = Main, JobBar, Review, AreaPicker, PlanList
return UI
