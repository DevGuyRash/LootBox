package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

for _, name in ipairs({ "ISCollapsableWindow", "ISPanel", "ISToolTip" }) do package.loaded["ISUI/" .. name] = true end
package.loaded["PZAPI/ModOptions"] = true
local function derive(parent)
    local class = {}
    class.__index = class
    return setmetatable(class, { __index = parent })
end
ISCollapsableWindow = { derive = derive, update = function() end, createChildren = function(window)
    window.collapseButton = { setVisible = function() end }
end }
ISPanel = { derive = derive }

local current
package.loaded["LootBox/App"] = {
    get = function() return current.app end,
    getPreferences = function() return current.preferences end,
}
package.loaded["LootBox/Categories"] = {}
local function control(parent, text)
    local widget = { text = text, enabled = true, visible = true }
    function widget:setEnable(enabled) self.enabled = enabled end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    function widget:setVisible(visible) self.visible = visible end
    function widget:setName(name) self.text = name end
    parent.controls = parent.controls or {}
    parent.controls[#parent.controls + 1] = widget
    return widget
end
local Widgets = { H = 28, GAP = 10, colors = { accent = {r = 1, g = 1, b = 1},
    success = {r = 1, g = 1, b = 1}, danger = {r = 1, g = 1, b = 1} },
    unfocus = function(body) current.unfocused = body end }
function Widgets.button(parent, _, _, _, text, target, callback)
    local widget = control(parent, text)
    widget.target, widget.callback = target, callback
    return widget
end
function Widgets.label(parent, _, _, text) return control(parent, text) end
function Widgets.heading(parent, _, _, text) return control(parent, text) end
function Widgets.text(parent, _, _, _, _, text) return control(parent, text) end
function Widgets.setText(panel, text) panel.text = text end
function Widgets.list(parent)
    local widget = control(parent, "")
    widget.items = {}
    function widget:addItem(text, data)
        local row = { text = text, item = data }
        self.items[#self.items + 1] = row
        return row
    end
    function widget:clear() self.items = {} end
    return widget
end
package.loaded["LootBox/Widgets"] = Widgets
local UI = require "LootBox/UI"

local function fakeReview(_, playerIndex, context, request, plan, notice)
    current.review = { playerIndex = playerIndex, context = context, request = request, plan = plan, notice = notice,
        initialise = function() end, addToUIManager = function() end, close = function() end }
    return current.review
end
UI.QuickReview.new = fakeReview
UI.showProgress = function(_, notice) current.progress = { notice = notice }; return current.progress end
UI.open = function(playerIndex, context, mode)
    current.opened = { playerIndex = playerIndex, context = context, mode = mode }
    return { messageText = function(_, text) current.opened.message = text end }
end
local function fixture()
    local f = { previews = 0, starts = 0, remembered = 0, preferences = { confirmQuickMoves = true } }
    current = f
    UI.quickWindows, UI.areaPickers = {}, {}
    UI.windows = {}
    f.plan = { moves = { { itemName = "Bandage", to = "Crate" } }, skipped = {}, pending = 0 }
    f.app = {
        preview = function(_, request) f.previews = f.previews + 1; f.reviewed = request; return f.plan end,
        start = function(_, plan)
            f.starts = f.starts + 1
            assert(plan == f.plan, "A quick action must start its current reviewed plan")
            if f.startError then return nil, f.startError end
            return true
        end,
        rememberSetup = function()
            f.remembered = f.remembered + 1
            if f.saveError then return nil, f.saveError end
            return true
        end,
    }
    f.binPlan = { moves = {}, skipped = {}, warnings = {}, pending = 0, canApprove = true,
        bin = { name = "Outside bin", point = { x = 4, y = 3, z = 0 } } }
    f.activeJob, f.paused = {}, true
    f.player = {}
    function getSpecificPlayer() return f.player end
    f.app.reviewBin = function()
        f.binReviews = (f.binReviews or 0) + 1
        if f.reviewError then return nil, f.reviewError end
        return f.binPlan
    end
    f.app.approveBin = function(_, token)
        assert(token == f.binPlan, "Approval must use the displayed bin review")
        f.approvals = (f.approvals or 0) + 1
        if f.approvalError then return nil, f.approvalError end
        f.paused = false
        return true
    end
    f.app.rejectBin = function(_, token)
        assert(token == f.binPlan, "Rejection must use the displayed bin review")
        f.rejections, f.paused = (f.rejections or 0) + 1, false
        return true
    end
    return f
end
local function request(kind)
    return { scope = "inventory", includeBags = true, filter = { ids = {}, types = { "Base.Bandage" }, all = false },
        destination = { kind = kind or "container", ref = {} } }
end

local function setupWindow(f, chosen, loaded)
    local currentRequest = request("floor")
    f.app.getSetups = function()
        return { presets = { { id = "setup:1", name = "First aid" }, { id = "setup:2", name = "Unavailable supplies" } } }
    end
    f.app.loadSetup = function() return nil, "Category custom:1 is unavailable" end
    f.app.deleteSetup = function(_, id) f.deleted = id; return true end
    f.app.saveSetup = function(_, name, setup, id) f.saved = { name = name, setup = setup, id = id }; return id end
    local function button() return { setEnable = function(self, enabled) self.enabled = enabled end } end
    return setmetatable({
        selectedSetupId = loaded, context = {},
        setupPicker = { selected = 1, data = chosen, getOptionData = function(self) return self.data end },
        setupName = { text = "Replacement workflow", setText = function(self, text) self.text = text end,
            getText = function(self) return self.text end },
        updateSetupButton = button(), deleteSetupButton = button(),
        app = function() return f.app end,
        readRequest = function() return currentRequest end,
        show = function(self, mode) self.shown = mode end,
        messageText = function(self, text) self.message = text end,
    }, { __index = UI.Window })
end

local function reviewWindow(f, plan, context)
    local window = setmetatable({ playerIndex = 0, width = 650, height = 520, plan = plan or f.binPlan,
        context = context or { binReview = f.binPlan }, request = { scope = "inventory",
            filter = { all = true, ids = {}, types = {} }, destination = { kind = "trash" } },
        titleBarHeight = function() return 18 end,
        setVisible = function(self, visible) self.visible = visible end,
        removeFromUIManager = function(self) self.removed = true end,
    }, { __index = UI.QuickReview })
    UI.QuickReview.createChildren(window)
    return window
end

local function press(window, text)
    for _, widget in ipairs(window.controls) do
        if widget.text == text then
            assert(widget.enabled, "The control is disabled: " .. text)
            assert(widget.visible, "The control is hidden: " .. text)
            assert(widget.callback, "The control has no action: " .. text)
            widget.callback(widget.target, widget)
            return
        end
    end
    error("Missing control: " .. text)
end

local function progressWindow(f)
    f.jobStatus = {state = "needs_review", done = 0, total = 8, reasons = {}}
    f.app.status = function() return f.jobStatus end
    f.app.cancel = function() f.cancelled = true; return true end
    local window = setmetatable({playerIndex = 0, width = 540, height = 440,
        titleBarHeight = function() return 18 end}, {__index = UI.Progress})
    UI.Progress.createChildren(window)
    UI.Progress.update(window)
    return window
end

local passed = 0
local function test(name, run)
    run(fixture())
    passed = passed + 1
    print("PASS " .. name)
end

test("ordinary shortcuts show a compact review by default", function(f)
    local result = UI.quickAction(0, {}, request())
    assert(result == f.review and f.review.plan == f.plan)
    assert(f.previews == 1 and f.starts == 0)
end)

test("disabling quick confirmation starts only the current ordinary reviewed plan", function(f)
    f.preferences.confirmQuickMoves = false
    local result = UI.quickAction(0, {}, request())
    assert(result == f.progress and f.previews == 1 and f.starts == 1 and not f.review)
end)

test("cleanup always shows a fresh explicit review even with quick confirmation off", function(f)
    f.preferences.confirmQuickMoves = false
    local result = UI.quickAction(0, {}, request("trash"))
    assert(result == f.review and result.request.destination.kind == "trash")
    assert(f.previews == 1 and f.starts == 0)
end)

test("a setup write failure does not prevent a valid quick transfer", function(f)
    f.preferences.confirmQuickMoves = false
    f.saveError = "Local storage is read-only"
    UI.quickAction(0, {}, request())
    assert(f.starts == 1 and f.progress.notice:find(f.saveError, 1, true))
end)

test("a rejected automatic start remains visible in a review", function(f)
    f.preferences.confirmQuickMoves = false
    f.startError = "Finish or cancel the current job"
    local result = UI.quickAction(0, {}, request())
    assert(result == f.review and f.review.notice:find(f.startError, 1, true))
    assert(not f.progress)
end)

test("an empty selection opens the composer without starting or inspecting sources", function(f)
    local setup = request()
    setup.filter.types = {}
    UI.quickAction(0, {}, setup)
    assert(f.opened.mode == "compose" and f.opened.message:find("Choose", 1, true))
    assert(f.previews == 0 and f.starts == 0)
end)

test("area shortcuts inspect nothing until the player finishes the area picker", function(f)
    local square = { getZ = function() return 0 end }
    function getSpecificPlayer() return { getCurrentSquare = function() return square end, isDead = function() return false end } end
    UI.AreaPicker.new = function(_, _, _, callback)
        f.pick = callback
        return { initialise = function() end, setWantKeyEvents = function() end,
            setWantMouseEvents = function() end, addToUIManager = function() end, bringToTop = function() end }
    end
    local setup = request("trash")
    setup.scope = "area"
    UI.quickAction(0, {}, setup, true)
    assert(f.previews == 0 and f.starts == 0 and f.pick)
    f.pick(nil)
    assert(f.previews == 0)
    f.pick({ x1 = 1, x2 = 2, y1 = 3, y2 = 4, z = 0 })
    assert(f.previews == 1 and f.review.request.area.x1 == 1 and f.starts == 0)
end)

test("adjusting a full preview retains the task selector search and setup name", function(f)
    local setup = request("trash")
    local function choice(data) return { selected = 1, getOptionData = function() return data end } end
    local window = {
        readRequest = function() return setup end,
        app = function() return f.app end,
        operation = choice("clean"), selectorKind = choice("items"),
        search = { getText = function() return "Bandage" end },
        setupName = { getText = function() return "Medical cleanup" end },
        show = function(self, mode) self.shown = mode end,
        messageText = function(self, text) self.message = text end,
    }
    UI.Window.preview(window)
    assert(window.shown == "preview" and window.request == setup)
    assert(window.operationValue == "clean" and window.selectorKindValue == "items")
    assert(window.searchDraft == "Bandage" and window.setupNameDraft == "Medical cleanup")
end)

test("an explicit single selection is visible when entering the full picker", function()
    local window = {}
    UI.Window.setRequest(window, request())
    assert(window.selectorKindValue == "items" and window.searchDraft == "Base.Bandage")
    UI.Window.setRequest(window, { scope = "room", filter = { ids = { "native:Food" }, types = {}, all = false },
        destination = { kind = "inventory" } })
    assert(window.selectorKindValue == "categories" and window.searchDraft == "native:Food")
    UI.Window.setRequest(window, { scope = "room", filter = { ids = {}, types = {}, all = true }, destination = { kind = "trash" } })
    assert(window.operationValue == "clean" and window.searchDraft == "")
end)

test("closing the manager releases its field focus before hiding and detaching", function(f)
    local body = {}
    local window = { playerIndex = 0, body = body, rememberDraft = function() end,
        setVisible = function(_, visible) assert(not visible and f.unfocused == body); f.hidden = true end,
        removeFromUIManager = function() assert(f.hidden); f.removed = true end }
    UI.windows[0] = window
    UI.Window.close(window)
    assert(f.removed and UI.windows[0] == nil)
end)

test("a shortcut releases focus from an existing LootBox editor", function(f)
    local body = {}
    UI.windows[0] = { body = body }
    UI.quickAction(0, {}, request())
    assert(f.unfocused == body and f.review)
end)

test("an unavailable chosen setup remains deletable without deleting the previously loaded setup", function(f)
    local window = setupWindow(f, "setup:2", "setup:1")
    window:loadNamedSetup()
    assert(window.message:find("unavailable", 1, true))
    assert(window.deleteSetupButton.enabled and window.updateSetupButton.enabled)
    assert(window.setupName:getText() == "Unavailable supplies")
    window:deleteNamedSetup()
    assert(f.deleted == "setup:2")
end)

test("updating a setup replaces the visible picker selection rather than the previously loaded setup", function(f)
    local window = setupWindow(f, "setup:2", "setup:1")
    local replacement = window:readRequest()
    window:saveNamedSetup(true)
    assert(f.saved.id == "setup:2" and f.saved.name == "Replacement workflow")
    assert(f.saved.setup == replacement)
end)

test("clearing the setup picker disables management and cannot create or delete a setup", function(f)
    local window = setupWindow(f, false, "setup:1")
    window:selectNamedSetup()
    assert(not window.updateSetupButton.enabled and not window.deleteSetupButton.enabled)
    assert(window.setupName:getText() == "")
    window:saveNamedSetup(true)
    window:deleteNamedSetup()
    assert(not f.saved and not f.deleted)
end)

test("opening a bin review retains its token and does not restart or remember the active job", function(f)
    local activeJob = f.activeJob
    local result = UI.showBinReview(0)
    assert(result == f.review and f.review.context.binReview == f.binPlan and f.review.plan == f.binPlan)
    assert(f.binReviews == 1 and f.starts == 0 and f.remembered == 0)
    assert(f.activeJob == activeJob and f.paused)
end)

test("a failed bin review remains on progress without creating an approval window", function(f)
    f.reviewError = "Approach the bin before reviewing"
    local result, reason = UI.showBinReview(0)
    assert(result == nil and reason == f.reviewError)
    assert(f.progress.notice == f.reviewError and not f.review)
    assert(f.starts == 0 and f.remembered == 0 and f.paused)
end)

test("an empty observed bin can be approved to continue the same paused job", function(f)
    local activeJob = f.activeJob
    local window = reviewWindow(f)
    assert(window.runButton.enabled)
    press(window, "Approve bin and continue")
    assert(f.approvals == 1 and not f.paused and f.activeJob == activeJob)
    assert(f.starts == 0 and f.remembered == 0 and f.progress)
    assert(window.removed and window.visible == false)
end)

test("protected bin contents disable approval even when items are visible", function(f)
    f.binPlan.canApprove = false
    f.binPlan.skipped = { { itemName = "Kept tool", reason = "Protected" } }
    local window = reviewWindow(f)
    assert(not window.runButton.enabled)
    assert(not f.approvals and f.paused and f.starts == 0)
end)

test("trying another bin rejects this token without starting a replacement job", function(f)
    local window = reviewWindow(f)
    press(window, "Try another bin")
    assert(f.rejections == 1 and not f.approvals and not f.paused)
    assert(f.starts == 0 and f.remembered == 0 and f.progress and window.removed)
end)

test("back closes the bin window while the active job stays paused", function(f)
    local activeJob = f.activeJob
    local window = reviewWindow(f)
    press(window, "Back")
    assert(window.removed and f.paused and f.activeJob == activeJob)
    assert(not f.approvals and not f.rejections and not f.progress and f.starts == 0)
end)

test("a rejected bin approval stays visible with its error and token", function(f)
    f.approvalError = "Bin contents changed; review again"
    local window = reviewWindow(f)
    press(window, "Approve bin and continue")
    assert(f.approvals == 1 and f.paused and not window.removed and not f.progress)
    assert(window.messagePanel.text == f.approvalError and window.context.binReview == f.binPlan)
    assert(f.starts == 0 and f.remembered == 0)
end)

test("ordinary cleanup still starts its reviewed plan rather than approving a bin token", function(f)
    local window = reviewWindow(f, f.plan, {})
    press(window, "Start cleanup and delete")
    assert(f.starts == 1 and not f.approvals and not f.rejections)
    assert(window.removed and f.progress)
end)

test("a building review can start a survey before any item has been observed", function(f)
    f.plan.moves, f.plan.pending, f.plan.building = {}, 14, { roomsTotal = 13 }
    local window = reviewWindow(f, f.plan, {})
    assert(window.runButton.enabled)
    local roomSummary, sourceSummary
    for _, row in ipairs(window.rows.items) do
        if row.text:find("13 building rooms", 1, true) then roomSummary = true end
        if row.text:find("1 sources", 1, true) then sourceSummary = true end
    end
    assert(roomSummary and sourceSummary)
    press(window, "Start cleanup and delete")
    assert(f.starts == 1 and not f.approvals)
end)

test("paused progress exposes review and cancellation while preserving the active job", function(f)
    local window, activeJob = progressWindow(f), f.activeJob
    assert(window.reviewBinButton.visible and window.reviewBinButton.enabled and window.cancelButton.enabled)
    press(window, "Review bin")
    assert(f.review.context.binReview == f.binPlan and f.starts == 0 and f.activeJob == activeJob and f.paused)
    press(window, "Cancel job")
    assert(f.cancelled)
end)

test("building progress keeps unsearched floor details without duplicating them on refresh", function(f)
    local window = progressWindow(f)
    f.jobStatus.survey = {roomsDone = 2, roomsTotal = 13, sectionsSearched = 3, sectionsUnsearched = 1,
        unsearchedRooms = { {roomId = "bedroom:2", roomName = "Second bedroom", z = 1, reason = "Blocked stairs"} } }
    UI.Progress.update(window)
    UI.Progress.update(window)
    assert(window.surveyPanel.text:find("2 of 13", 1, true) and #window.reasonsList.items == 1)
    local row = window.reasonsList.items[1]
    assert(row.text:find("Second bedroom", 1, true) and row.text:find("floor 1", 1, true))
    f.jobStatus.state = "running"
    UI.Progress.update(window)
    assert(not window.reviewBinButton.visible and not window.reviewBinButton.enabled and window.cancelButton.enabled)
    f.jobStatus.state = "finished_with_skips"
    UI.Progress.update(window)
    assert(not window.cancelButton.enabled)
end)

print(passed .. " UI workflow cases passed (explicit native window and job boundary doubles)")
