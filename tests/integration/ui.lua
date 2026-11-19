package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

for _, name in ipairs({ "ISCollapsableWindow", "ISPanel", "ISToolTip" }) do package.loaded["ISUI/" .. name] = true end
package.loaded["PZAPI/ModOptions"] = true
local function derive(parent)
    local class = {}
    class.__index = class
    return setmetatable(class, { __index = parent })
end
local current
function instanceof(object, class) return type(object) == "table" and object.classes and object.classes[class] == true end
local function geometry(widget, x, y, width, height)
    widget.x, widget.y, widget.width, widget.height = x or 0, y or 0, width or 0, height or 28
    function widget:setX(v) self.x = v end
    function widget:setY(v) self.y = v end
    function widget:setWidth(v) self.width = v; self.textDirty = true end
    function widget:setHeight(v) self.height = v; self.textDirty = true end
    function widget:getYScroll() return self.scroll or 0 end
    function widget:setYScroll(v) self.scroll = v end
    return widget
end
local NativePanel = { derive = derive }
function NativePanel:new(x, y, width, height)
    return setmetatable(geometry({ controls = {}, children = {} }, x, y, width, height), { __index = self })
end
function NativePanel:initialise() end
function NativePanel:addChild(child) self.children[#self.children + 1] = child end
function NativePanel:removeChild(child)
    for i, value in ipairs(self.children) do if value == child then table.remove(self.children, i); return end end
end
function NativePanel:setVisible(value) self.visible = value end
function NativePanel:removeFromUIManager() self.removed = true end
function NativePanel:addToUIManager() self.registered = true end
function NativePanel:bringToTop() end
function NativePanel:titleBarHeight() return 18 end
ISPanel = NativePanel
ISCollapsableWindow = setmetatable({ derive = derive }, { __index = NativePanel })
function ISCollapsableWindow:createChildren()
    self.collapseButton = { setVisible = function() end }
    self.resizeWidget, self.resizeWidget2 = {}, {}
end
function ISCollapsableWindow:setResizable(value) self.resizable = value end
function ISCollapsableWindow:resizeWidgetHeight() return 10 end
function ISCollapsableWindow:onResize() self.nativeResizes = (self.nativeResizes or 0) + 1 end
function ISCollapsableWindow:update() end

local App = {
    get = function() current.gets = (current.gets or 0) + 1; return current.app end,
    peek = function() current.peeks = (current.peeks or 0) + 1; return current.sessionAvailable and current.app end,
    getPreferences = function() return current.preferences, current.preferenceError end,
    reviewPreference = function(request, binReview)
        local key = binReview and "confirmBinReviews"
            or (request and request.destination and request.destination.kind == "trash" and "confirmQuickCleanup" or "confirmQuickMoves")
        return current.preferenceError ~= nil or current.preferences[key] == true, key, current.preferenceError
    end,
    setPreferences = function(patch)
        current.preferenceWrites = (current.preferenceWrites or 0) + 1
        if current.preferenceSaveError then return nil, current.preferenceSaveError end
        for key, value in pairs(patch) do current.preferences[key] = value end
        return true
    end,
    catalog = function() return current.catalog end,
}
package.loaded["LootBox/App"] = App
local function control(parent, text, x, y, width, height)
    local widget = geometry({ text = text, enabled = true, visible = true }, x, y, width, height)
    function widget:setEnable(enabled) self.enabled = enabled end
    function widget:setEnabled(enabled) self.enabled = enabled end
    function widget:setTooltip(tooltip) self.tooltip = tooltip end
    function widget:setVisible(visible) self.visible = visible end
    function widget:setName(name) self.text = name end
    function widget:setTitle(name) self.text = name end
    function widget:setText(text) self.text = text end
    function widget:getText() return self.text end
    function widget:setEditable(editable) self.editable = editable end
    function widget:isFocused() return self.focused == true end
    parent.controls = parent.controls or {}
    parent.controls[#parent.controls + 1] = widget
    return widget
end
local Widgets = { H = 28, GAP = 10, colors = { accent = {r = .8, g = .7, b = .4},
    success = {r = .5, g = .7, b = .6}, danger = {r = .8, g = .5, b = .4},
    item = {r = .5, g = .8, b = .9}, warning = {r = .9, g = .7, b = .3} },
    unfocus = function(body) current.unfocused = body end,
    color = function(name) return {name = name} end,
    escape = function(text) return tostring(text or "") end }
function Widgets.button(parent, x, y, width, text, target, callback)
    local widget = control(parent, text, x, y, width, Widgets.H)
    widget.target, widget.callback = target, callback
    return widget
end
function Widgets.label(parent, x, y, text) return control(parent, text, x, y, 0, Widgets.H) end
function Widgets.heading(parent, x, y, text) return control(parent, text, x, y, 0, Widgets.H) end
function Widgets.text(parent, x, y, width, height, text)
    local widget = control(parent, text, x, y, width, height)
    function widget:removeScrollBars() self.vscroll = nil end
    function widget:paginate()
        local lineWidth = getTextManager():MeasureStringX(UIFont.Small, self.text)
        self.scrollHeight = math.max(1, math.ceil(lineWidth / math.max(1, self.width))) * getTextManager():getFontHeight(UIFont.Small) + 4
    end
    function widget:getScrollHeight() return self.scrollHeight or self.height end
    return widget
end
function Widgets.setText(panel, text)
    if panel.text ~= text then panel.text = text; panel.scroll = 0 end
end
function Widgets.entry(parent, x, y, width, text) return control(parent, text or "", x, y, width, Widgets.H) end
function Widgets.check(parent, x, y, width, text, selected, target, callback, tooltip)
    local widget = control(parent, text, x, y, width, Widgets.H)
    widget.target, widget.callback, widget.tooltip = target, callback, tooltip
    widget.checked = selected == true
    function widget:setSelected(_, v) self.checked = v end
    function widget:isSelected() return self.checked end
    return widget
end
function Widgets.combo(parent, x, y, width, target, callback, tooltip)
    local widget = control(parent, "", x, y, width, Widgets.H)
    widget.options, widget.selected = {}, 0
    function widget:setToolTipMap(values) self.tooltip = values end
    function widget:setSelected(index) self.selected = index end
    widget:setToolTipMap({defaultTooltip = tooltip})
    function widget:addOptionWithData(text, data, optionTooltip)
        self.options[#self.options + 1] = {text = text, data = data, tooltip = optionTooltip}
        if self.selected == 0 then self.selected = 1 end
    end
    function widget:selectData(data)
        for i, option in ipairs(self.options) do if option.data == data then self.selected = i; return end end
    end
    function widget:getOptionData(i) return self.options[i] and self.options[i].data end
    function widget:getOptionTooltip(index)
        local option = self.options[index]
        if option then
            if type(option) == "table" then
                if option.tooltip then return option.tooltip end
                if self.tooltip then return self.tooltip[option.text] or self.tooltip.defaultTooltip end
            elseif self.tooltip then return self.tooltip[option] or self.tooltip.defaultTooltip end
        end
    end
    function widget:clear() self.options, self.tooltip = {}, {} end
    return widget
end
function Widgets.list(parent, x, y, width, height, target, callback, selection)
    local widget = control(parent, "", x, y, width, height)
    widget.items, widget.target, widget.callback, widget.selection = {}, target, callback, selection
    widget.scrollHeight = 0
    function widget:getScrollHeight() return self.scrollHeight end
    function widget:setScrollHeight(height) self.scrollHeight = height; self:setYScroll(self:getYScroll()) end
    function widget:setYScroll(value) self.scroll = math.max(-math.max(0, self.scrollHeight - self.height), math.min(0, value)) end
    function widget:onMouseWheel(delta) self:setYScroll(self:getYScroll() - delta * Widgets.H * 3); return true end
    function widget:addItem(text, data, tooltip)
        local row = { text = text, item = data, tooltip = tooltip, index = #self.items + 1, height = Widgets.H }
        self.items[#self.items + 1] = row
        self:setScrollHeight(self.scrollHeight + row.height)
        return row
    end
    function widget:clear() self.items, self.selected, self.scroll, self.scrollHeight = {}, 0, 0, 0 end
    return widget
end
package.loaded["LootBox/Widgets"] = Widgets
UIFont = {Small = "small"}
function getTextManager() return {
    getFontHeight = function() return Widgets.H - 12 end,
    MeasureStringX = function(_, _, text) return #text * math.max(7, (Widgets.H - 12) / 2) end,
} end
function getCore() return {getScreenWidth = function() return 1280 end, getScreenHeight = function() return 900 end,
    isDoingTextEntry = function() return current.typing == true end,
    isKey = function(_, binding, key) assert(binding == "LootBoxCurrentJob"); return key == current.boundKey end} end
function getNumActivePlayers() return current.activePlayers or 1 end
function getText(key) return key end
function getTextOrNull() return nil end
function getItemNameFromFullType(id) return id end
local UI = require "LootBox/UI"
local realReviewNew = UI.QuickReview.new

local function fakeReview(_, playerIndex, context, request, plan, notice)
    current.review = { playerIndex = playerIndex, context = context, request = request, plan = plan, notice = notice,
        initialise = function() end, addToUIManager = function() end,
        setVisible = function(self, visible) self.visible = visible end,
        bringToTop = function(self) self.raised = (self.raised or 0) + 1 end,
        close = function(self) self.closed = true; UI.quickWindows[playerIndex] = nil end }
    return current.review
end
UI.QuickReview.new = fakeReview
UI.showProgress = function(_, notice)
    current.progressShows = (current.progressShows or 0) + 1
    current.progress = { notice = notice }
    return current.progress
end
UI.open = function(playerIndex, context, mode)
    current.opened = { playerIndex = playerIndex, context = context, mode = mode }
    return { messageText = function(_, text) current.opened.message = text end }
end
local function fixture()
    local f = { previews = 0, starts = 0, remembered = 0, preferences = { confirmQuickMoves = true, confirmQuickCleanup = true, confirmBinReviews = true, showQuickProgress = true },
        sessionAvailable = true, boundKey = 65, recovery = {pending = false},
        jobStatus = {state = "needs_review", canPreview = true, reviewId = 1, done = 0, total = 8, reasons = {}} }
    current = f
    UI.quickWindows, UI.areaPickers, UI.progressWindows, UI.reviewVisits = {}, {}, {}, {}
    UI.windows = {}
    f.plan = { moves = { { itemName = "Bandage", to = "Crate" } }, skipped = {}, pending = 0 }
    f.app = {
        preview = function(_, request)
            f.previews = f.previews + 1; f.reviewed = request
            if f.previewError then return nil, f.previewError end
            return f.plan
        end,
        start = function(_, plan, options)
            f.starts = f.starts + 1
            f.startOptions = options
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
    f.catalog = { items = {
        {fullType = "Base.Bandage", name = "Bandage", categoryId = "native:FirstAid"},
        {fullType = "Base.Apple", name = "Apple", categoryId = "native:Food"},
    }, categories = {
        {id = "native:Food", name = "Food", kind = "native"},
        {id = "native:FirstAid", name = "First aid", kind = "native"},
        {id = "custom:1", name = "Run supplies", kind = "custom", types = {"Base.Bandage"}, includes = {}},
    } }
    f.app.getSetups = function() return {presets = {}} end
    f.app.lastSetup = function() return nil end
    f.app.knownVehicles = function() return {} end
    f.app.labels = function() return {} end
    f.app.itemLabels = function() return {} end
    f.app.isKept = function() return false end
    f.app.replaceJob = function(_, callback)
        f.replacements = (f.replacements or 0) + 1
        if f.replaceError then return nil, f.replaceError end
        if f.deferReplacement then f.pendingReplacement = callback; return true end
        return callback()
    end
    f.app.cancel = function() f.cancelled = true; return true end
    f.app.status = function() return f.jobStatus end
    f.app.recoveryStatus = function() return f.recovery end
    f.app.recoverPersonalGear = function()
        f.recoveries = (f.recoveries or 0) + 1
        if f.recoveryError then return nil, f.recoveryError end
        return true
    end
    f.app.pause = function()
        f.pauses = (f.pauses or 0) + 1
        if f.pauseError then return nil, f.pauseError end
        f.jobStatus.state, f.jobStatus.canPause, f.jobStatus.canResume = "paused", false, true
        return true
    end
    f.app.resume = function()
        f.resumes = (f.resumes or 0) + 1
        if f.resumeError then return nil, f.resumeError end
        f.jobStatus.state, f.jobStatus.canResume, f.jobStatus.canPreview, f.jobStatus.hasJob = "running", false, false, true
        return true
    end
    f.activeJob, f.paused = {}, true
    f.player = {}
    function getSpecificPlayer() return f.player end
    f.app.reviewBin = function()
        f.binReviews = (f.binReviews or 0) + 1
        if f.reviewError then return nil, f.reviewError end
        return f.binPlan
    end
    f.app.approveBin = function(_, token, options)
        assert(token == f.binPlan, "Approval must use the displayed bin review")
        f.approvals = (f.approvals or 0) + 1
        f.approvalOptions = options
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

local function reviewWindow(f, plan, context, setup)
    local window = setmetatable(geometry({ controls = {}, children = {}, playerIndex = 0, width = 650, height = 520, plan = plan or f.binPlan,
        context = context or { binReview = f.binPlan }, request = setup or { scope = "inventory",
            filter = { all = true, ids = {}, types = {} }, destination = { kind = "trash" } },
        titleBarHeight = function() return 18 end,
        setVisible = function(self, visible) self.visible = visible end,
        removeFromUIManager = function(self) self.removed = true end,
    }, 0, 0, 650, 520), { __index = UI.QuickReview })
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
    local window = setmetatable(geometry({controls = {}, children = {}, playerIndex = 0, width = 540, height = 440,
        titleBarHeight = function() return 18 end}, 0, 0, 540, 440), {__index = UI.Progress})
    UI.Progress.createChildren(window)
    UI.Progress.update(window)
    return window
end

local function manyCatalogRows(f)
    for index = 1, 40 do
        f.catalog.items[#f.catalog.items + 1] = {fullType = "Base.Bandage_" .. index,
            name = "Medical draft Apple bandage " .. index, categoryId = "native:Food"}
        f.catalog.categories[#f.catalog.categories + 1] = {id = "native:Food_" .. index,
            name = "Food " .. index, kind = "native"}
    end
end

local function managerWindow(f, mode, context)
    local window = UI.Window:new(0, context or {}, mode or "home")
    window:createChildren()
    return window
end

local function resize(window, width, height, bottomOnly)
    local grip = bottomOnly and window.resizeWidget2 or window.resizeWidget
    assert(window.resizable and grip.resizeFunction, "The native frame must expose an operative resize grip")
    grip.resizeFunction(window, math.max(width, window.minimumWidth or 0), math.max(height, window.minimumHeight or 0))
end

local function inside(widget, parent)
    assert(widget.x >= 0 and widget.y >= 0, "A control escaped the top or left edge")
    assert(widget.width > 0 and widget.height > 0, "A resized control lost its usable dimensions")
    assert(widget.x + widget.width <= parent.width, "A control escaped the right edge")
    assert(widget.y + widget.height <= parent.height, "A control escaped the bottom edge")
end

local passed = 0
local function test(name, run)
    run(fixture())
    passed = passed + 1
    print("PASS " .. name)
end

test("ordinary shortcuts show a compact review when enabled", function(f)
    local result = UI.quickAction(0, {}, request())
    assert(result == f.review and f.review.plan == f.plan)
    assert(f.previews == 1 and f.starts == 0)
end)

test("disabling quick confirmation starts only the current ordinary reviewed plan", function(f)
    f.preferences.confirmQuickMoves = false
    local result = UI.quickAction(0, {}, request())
    assert(result == f.progress and f.previews == 1 and f.starts == 1 and not f.review)
end)

test("cleanup review can remain enabled independently of ordinary quick confirmation", function(f)
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
    setmetatable(window, {__index = UI.Window})
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

test("the manager native grips resize without replacing an unfinished composer", function(f)
    manyCatalogRows(f)
    local window = managerWindow(f, "compose", {request = request("floor"), square = {}})
    local body, search, name, selection, rows = window.body, window.search, window.setupName, window.selection, window.selectionList
    search:setText("Medical draft"); search.focused = true
    name:setText("After the loot run")
    selection["Base.Apple"] = true
    window:fillSelectionList()
    assert(#rows.items > 20)
    rows:setYScroll(-56); rows.selected = 2
    local remembered = f.remembered
    for _, size in ipairs({{760, 710}, {1200, 850}, {900, 760}}) do
        resize(window, size[1], size[2])
        assert(window.body == body and window.search == search and window.setupName == name and window.selectionList == rows)
        assert(search:getText() == "Medical draft" and search.focused and name:getText() == "After the loot run")
        assert(window.selection == selection and selection["Base.Apple"] and rows:getYScroll() == -56 and rows.selected == 2)
        assert(rows.height >= Widgets.H)
        inside(rows, body); inside(window.runButton or window.deleteSetupButton, body)
    end
    resize(window, 900, 820, true)
    assert(f.remembered == remembered and f.starts == 0 and not f.cancelled and not f.unfocused)
    assert(window.body.y + window.body.height <= window.height - window:resizeWidgetHeight() - 2)
end)

test("category resize retains unsaved name membership filters and scroll", function(f)
    manyCatalogRows(f)
    local window = managerWindow(f, "categories")
    window.categoryName:setText("Weekend supply draft")
    window.categorySearch:setText("Run")
    window.memberSearch:setText("Apple")
    window.memberKind:selectData("types")
    window.editor.types["Base.Apple"] = true
    window:fillMemberList()
    assert(#window.memberList.items > 20)
    window.memberList:setYScroll(-84)
    local body, editor, field, members = window.body, window.editor, window.categoryName, window.memberList
    resize(window, 760, 710)
    assert(window.body == body and window.editor == editor and window.categoryName == field and window.memberList == members)
    assert(field:getText() == "Weekend supply draft" and window.categorySearch:getText() == "Run")
    assert(window.memberSearch:getText() == "Apple" and window.memberKind:getOptionData(window.memberKind.selected) == "types")
    assert(editor.types["Base.Apple"] and members.selection == editor.types and members:getYScroll() == -84)
    inside(members, body); inside(window.deleteCategoryButton, body)
    assert(not f.cancelled and f.starts == 0 and f.remembered == 0)
end)

test("label resize preserves the chosen copy unsaved tags and Keep", function(f)
    manyCatalogRows(f)
    local selected = {getName = function() return "My hammer" end, getFullType = function() return "Base.Hammer" end}
    local window = managerWindow(f, "labels", {item = selected, labelKind = "item"})
    window.labelSelection["native:Food"] = true
    window.keep:setSelected(1, true)
    window.labelSearch:setText("Food")
    window:fillLabelList()
    assert(#window.labelList.items > 20)
    window.labelList:setYScroll(-28)
    local body, target, tags, keep = window.body, window.labelTarget:getOptionData(window.labelTarget.selected), window.labelSelection, window.keep
    resize(window, 760, 710)
    resize(window, 1150, 820)
    assert(window.body == body and window.labelSelection == tags and window.keep == keep)
    assert(window.labelTarget:getOptionData(window.labelTarget.selected) == target and target.ref == selected)
    assert(tags["native:Food"] and keep:isSelected(1) and window.labelSearch:getText() == "Food")
    assert(window.labelList.selection == tags and window.labelList:getYScroll() == -28)
    inside(window.labelList, body); inside(window.saveLabelsButton, body)
    assert(not f.cancelled and f.starts == 0)
end)

test("settings and Help resize retain unsaved choices and reading position", function(f)
    f.preferences.contextMenus, f.preferences.showTips = true, true
    local settings = managerWindow(f, "settings")
    settings.preferenceSelection.contextMenus = false
    local body, selection, viewport = settings.body, settings.preferenceSelection, settings.preferenceViewport
    local rows = viewport.items
    resize(settings, 760, 710)
    assert(settings.body == body and settings.preferenceSelection == selection and settings.preferenceViewport == viewport)
    assert(viewport.items == rows and not selection.contextMenus)
    assert(f.preferences.contextMenus == true)
    local help = managerWindow(f, "help", {guide = "buildings"})
    help.guideSearch:setText("building")
    help.guidePanel:setYScroll(-140)
    local panel, guide = help.guidePanel, help.currentGuide
    resize(help, 760, 710); resize(help, 1200, 850)
    assert(help.guidePanel == panel and help.currentGuide == guide and guide.id == "buildings")
    assert(help.guideSearch:getText() == "building" and panel:getYScroll() == -140)
    inside(help.guidePanel, help.body); inside(help.guideSetupButton, help.body)
end)

test("full job preview resizes its decision rows without changing its reviewed plan", function(f)
    local window = managerWindow(f, "home")
    window.request = request("trash")
    window.plan = {moves = {{itemName = "Nails", from = "Upstairs", to = "Outside bin"}},
        skipped = {{itemName = "My hammer", status = "Protected", reason = "Keep", tone = "warning"}}, pending = 0}
    window:show("preview")
    local body, token, button = window.body, window.plan, window.runButton
    resize(window, 760, 710); resize(window, 1150, 850)
    assert(window.body == body and window.plan == token and window.runButton == button)
    local list
    for _, widget in ipairs(body.controls) do if widget.items then list = widget end end
    assert(#list.items == 2 and list.items[1].item.segments[1].text == "Nails")
    local protected = list.items[2]
    assert(protected.item.segments[1].tone == "item" and protected.item.segments[2].text == "Protected")
    assert(protected.item.segments[2].tone == "warning" and protected.item.segments[3].text == "Keep" and protected.item.segments[3].tone == "text")
    assert(protected.tooltip:find("My hammer", 1, true) and protected.tooltip:find("Keep", 1, true))
    inside(list, body); inside(button, body)
    assert(f.starts == 0 and not f.cancelled)
end)

test("bin review resize preserves approval token and shows destination identity capacity and scope", function(f)
    f.binPlan.bin = {name = "Porch trash can", point = {x = 12, y = 34, z = 0}, capacity = 20, used = 7,
        routing = "Two trips, one emptying; travel observed"}
    f.binPlan.moves = {{itemName = "Broken bottle", from = "Existing bin contents", to = "Delete with approved cleanup"}}
    local window = realReviewNew(UI.QuickReview, 0, {binReview = f.binPlan}, request("trash"), f.binPlan)
    window:createChildren()
    local rows, token, plan = window.rows, window.context.binReview, window.plan
    resize(window, 540, 440); resize(window, 950, 700, true)
    assert(window.rows == rows and window.context.binReview == token and window.plan == plan)
    local text = ""
    for _, widget in ipairs(window.controls) do text = text .. "\n" .. tostring(widget.text or "") end
    assert(text:find("Porch trash can", 1, true) and text:find("Floor 0 at 12, 34", 1, true))
    assert(text:find("7.0 / 20.0", 1, true) and text:find("Free 13.0", 1, true) and text:find("travel observed", 1, true))
    assert(window.messagePanel.text:find("whole-bin deletion", 1, true))
    local row = rows.items[1]
    assert(row.item.segments[1].text == "Broken bottle" and row.item.segments[2].text == "Will be deleted")
    assert(row.item.segments[2].tone == "danger" and row.item.segments[3].tone == "text")
    assert(window.runButton.y + window.runButton.height < window.height - window:resizeWidgetHeight())
    assert(f.starts == 0 and not f.approvals and not f.cancelled)
    press(window, "Approve bin and continue")
    assert(f.approvals == 1 and f.starts == 0)
end)

test("stopped progress exposes Resume and resizes without cancelling or duplicating notes", function(f)
    local window = progressWindow(f)
    f.jobStatus = {state = "paused", canResume = true, done = 13, total = 159, skipped = 1,
        reasons = {{itemName = "Garbage Bag", status = "Protected", reason = "Bag contains items", tone = "warning"}}}
    for index = 2, 25 do
        f.jobStatus.reasons[index] = {itemName = "Kept item " .. index, status = "Protected", reason = "Keep", tone = "warning"}
    end
    window:update()
    local rows, status = window.reasonsList, f.jobStatus
    rows:setYScroll(-28)
    resize(window, 520, 410); resize(window, 900, 650)
    window:update()
    assert(window.resumeButton.visible and window.resumeButton.enabled and window.cancelButton.enabled)
    assert(window.reasonsList == rows and #rows.items == 25 and rows:getYScroll() == -28)
    assert(f.jobStatus == status and f.starts == 0 and not f.cancelled and not f.resumes)
    local row = rows.items[1]
    assert(row.item.segments[1].text == "Garbage Bag" and row.item.segments[1].tone == "item")
    assert(row.item.segments[2].text == "Protected" and row.item.segments[2].tone == "warning")
    assert(row.item.segments[3].text == "Bag contains items" and row.item.segments[3].tone == "text")
    press(window, "Resume job")
    assert(f.resumes == 1 and f.starts == 0 and f.jobStatus.state == "running")
    window:update()
    assert(not window.resumeButton.visible and window.cancelButton.enabled)
end)

test("a rejected Resume stays visible and temporary waiting never offers a second job", function(f)
    local window = progressWindow(f)
    f.jobStatus.state, f.jobStatus.canResume = "paused", true
    f.resumeError = "Stop aiming before resuming"
    window:update(); press(window, "Resume job"); window:update()
    assert(window.reasonPanel.text:find(f.resumeError, 1, true) and window.resumeButton.visible)
    f.jobStatus.state, f.jobStatus.canResume = "running", false
    f.jobStatus.waiting = "Waiting for your current action to finish. This job will continue automatically."
    window:update()
    assert(window.statusLabel.text == "Waiting for your action" and window.reasonPanel.text:find("automatically", 1, true))
    assert(not window.resumeButton.visible and window.cancelButton.enabled and f.starts == 0)
end)

test("closing progress and reviews cannot cancel or restart the active job", function(f)
    local active = f.activeJob
    local progress = progressWindow(f)
    progress:close()
    local review = reviewWindow(f)
    review:close()
    assert(f.activeJob == active and f.starts == 0 and not f.cancelled and not f.resumes and not f.approvals)
    assert(progress.removed and review.removed)
end)

test("default and minimum frames retain a full decision row at larger font sizes", function()
    local originalModule, originalH = package.loaded["LootBox/UI"], Widgets.H
    for _, rowHeight in ipairs({28, 32, 44}) do
        Widgets.H = rowHeight
        package.loaded["LootBox/UI"] = nil
        local scaled = require "LootBox/UI"
        local f = fixture()
        manyCatalogRows(f)
        local manager = scaled.Window:new(0, {request = request("floor"), square = {}}, "compose")
        manager:createChildren()
        assert(manager.selectionList.height >= rowHeight, "The initial manager must show a complete selectable row")
        resize(manager, manager.minimumWidth, manager.minimumHeight)
        assert(manager.selectionList.height >= rowHeight, "The minimum manager must show a complete selectable row")
        inside(manager.selectionList, manager.body)
        assert(manager.selectionList.y + manager.selectionList.height < manager.setupName.y)
        assert(manager.body.y + manager.body.height <= manager.height - manager:resizeWidgetHeight() - 2)
        for _, binReview in ipairs({false, true}) do
            local plan = binReview and f.binPlan or f.plan
            local review = scaled.QuickReview:new(0, binReview and {binReview = plan} or {}, request("trash"), plan)
            review:createChildren()
            assert(review.rows.height >= rowHeight, "The initial review must show a complete decision row")
            resize(review, review.minimumWidth, review.minimumHeight)
            assert(review.rows.height >= rowHeight, "The minimum review must show a complete decision row")
            assert(review.rows.y + review.rows.height < review.runButton.y)
            assert(review.messagePanel.y + review.messagePanel.height <= review.height - review:resizeWidgetHeight() - 2)
        end
        f.jobStatus = {state = "needs_review", done = 0, total = 4, reasons = {}}
        f.app.status = function() return f.jobStatus end
        local progress = scaled.Progress:new(0)
        progress:createChildren(); progress:update()
        assert(progress.reasonsList.height >= rowHeight, "The initial progress must show a complete note row")
        resize(progress, progress.minimumWidth, progress.minimumHeight)
        assert(progress.reasonsList.height >= rowHeight, "The minimum progress must show a complete note row")
        assert(progress.reasonsList.y + progress.reasonsList.height < progress.cancelButton.y)
        assert(progress.footer.y + progress.footer.height <= progress.height - progress:resizeWidgetHeight() - 2)
        assert(not f.cancelled and f.starts == 0 and not f.resumes)
    end
    Widgets.H, package.loaded["LootBox/UI"] = originalH, originalModule
end)

test("Til Full settings explain contextual targets and the explicit both-needs override", function(f)
    local window = UI.Window:new(0, {}, "settings")
    window:createChildren()
    local found
    for _, row in ipairs(window.preferenceViewport.items) do
        if row.item.key == "tillFullBothNeeds" then
            found = row.item.description
        end
    end
    assert(found and found:find("Eat restore hunger and Drink restore thirst", 1, true))
    assert(found:find("On targets both needs", 1, true) and found:find("Native fullness limits still apply", 1, true))
    assert(not window.preferenceSelection.tillFullBothNeeds)
end)

test("all four automatic supplies settings are independent and off until saved", function(f)
    local window = managerWindow(f, "settings", {})
    local keys = {autoDrinkEquipped=true,autoConsumeCarried=true,autoConsumeNested=true,autoConsumeRiskyOpen=true}
    for _, row in ipairs(window.preferenceViewport.items) do
        if keys[row.item.key] then
            assert(window.preferenceSelection[row.item.key] == false)
            keys[row.item.key] = nil
        end
    end
    for key in pairs(keys) do error("Missing automatic supply preference: " .. key) end
    for _, row in ipairs(window.preferenceViewport.items) do
        if row.item.key == "autoConsumeNested" then
            window.preferenceViewport.callback(window.preferenceViewport.target, row.item)
        end
    end
    press(window.body, "Save preferences")
    assert(f.preferences.autoConsumeNested and not f.preferences.autoConsumeCarried)
    assert(not f.preferences.autoDrinkEquipped and not f.preferences.autoConsumeRiskyOpen)
end)

test("pour progress reports paired liters not moved inventory items", function(f)
    local window=progressWindow(f)
    f.jobStatus={state="running",intent="pour",done=1,total=3,pourLiters=0.5,reasons={}}
    window:update()
    assert(window.statusLabel.text=="Pouring" and window.countLabel.text:find("1 of 3 vessels | 0.500 L confirmed",1,true))
end)

test("four Pour Into controls save independently; main only does not change individual choices", function(f)
    local window = managerWindow(f, "settings", {})
    local seen={}
    local keys={pourLootToLoot=true,pourMostRoomFirst=true,pourEquippedFirst=true,pourMainOnly=true}
    for _,row in ipairs(window.preferenceViewport.items) do
        local key=row.item.key
        if keys[key] then
            assert(not seen[key] and window.preferenceSelection[key]==false)
            seen[key]=true
            if key=="pourMainOnly" then
                assert(row.item.description:find("individual targets remain available",1,true))
                window.preferenceViewport.callback(window.preferenceViewport.target,row.item)
            end
        end
    end
    for key in pairs(keys) do assert(seen[key]) end
    press(window.body,"Save preferences")
    assert(f.preferences.pourMainOnly and not f.preferences.pourLootToLoot
        and not f.preferences.pourMostRoomFirst and not f.preferences.pourEquippedFirst)
end)

test("Settings keeps every preference reachable above Save across native font sizes", function()
    local originalModule, originalH = package.loaded["LootBox/UI"], Widgets.H
    for _, rowHeight in ipairs({28, 31, 38, 45, 50}) do
        Widgets.H = rowHeight
        package.loaded["LootBox/UI"] = nil
        local scaled = require "LootBox/UI"
        local f = fixture()
        f.preferences.contextMenus = true
        local window = scaled.Window:new(0, {}, "settings")
        window:createChildren()
        resize(window, window.minimumWidth, window.minimumHeight)
        local viewport, choices = window.preferenceViewport, window.preferenceSelection
        local rows, save = viewport.items
        for _, widget in ipairs(window.body.controls) do if widget.text == "Save preferences" then save = widget end end
        assert(#rows == 33 and save and viewport.height >= rowHeight)
        assert(viewport.y + viewport.height < save.y)
        local preferences, sections, lastY = 0, 0, 0
        for _, row in ipairs(rows) do
            if row.item.key then
                preferences = preferences + 1
                assert(#row.item.details > 0 and row.height >= rowHeight + #row.item.details * (rowHeight - 12))
                for _, line in ipairs(row.item.details) do
                    assert(getTextManager():MeasureStringX(UIFont.Small, line) <= viewport.width - 50)
                end
            else sections = sections + 1; assert(row.item.selectable == false) end
            lastY = lastY + row.height
        end
        assert(preferences == 28 and sections == 5)
        viewport.callback(viewport.target, rows[1].item)
        assert(choices.contextMenus == true and viewport.selected == 0)
        viewport.callback(viewport.target, rows[2].item)
        assert(choices.contextMenus == false and f.preferences.contextMenus == true)
        viewport:onMouseWheel(1000)
        local last = rows[#rows]
        assert(lastY - last.height + viewport:getYScroll() >= 0)
        assert(lastY + viewport:getYScroll() <= viewport.height)
        local scroll = viewport:getYScroll()
        resize(window, 1200, 850)
        assert(window.preferenceViewport == viewport and viewport.items == rows and window.preferenceSelection == choices)
        assert(choices.contextMenus == false and viewport:getYScroll() <= 0)
        assert(viewport:getYScroll() >= scroll and not f.cancelled and f.starts == 0)
    end
    Widgets.H, package.loaded["LootBox/UI"] = originalH, originalModule
end)

test("Settings changes only persist through its fixed Save control", function(f)
    f.preferences.contextMenus, f.preferences.showTips = true, true
    local saves
    local previous = App.setPreferences
    App.setPreferences = function(values) saves = values; return true end
    local window = managerWindow(f, "settings")
    local viewport, choices = window.preferenceViewport, window.preferenceSelection
    viewport.callback(viewport.target, viewport.items[2].item)
    for _, row in ipairs(viewport.items) do
        if row.item.key == "showTips" then viewport.callback(viewport.target, row.item); break end
    end
    resize(window, 760, 710)
    viewport:onMouseWheel(1000)
    assert(saves == nil and f.preferences.contextMenus and f.preferences.showTips)
    press(window.body, "Save preferences")
    assert(saves.contextMenus == false and saves.showTips == false)
    local count = 0
    for _, value in pairs(saves) do assert(type(value) == "boolean"); count = count + 1 end
    assert(count == 28 and window.preferenceSelection == choices)
    assert(window.messagePanel.text:find("Preferences saved", 1, true) and not f.cancelled and f.starts == 0)
    App.setPreferences = previous
end)

test("container reviews name native main inventory as both a source and destination", function(f)
    local player = { classes = { IsoPlayer = true } }
    local main = { getContainingItem = function() return nil end, getVehiclePart = function() return nil end,
        getParent = function() return player end, getType = function() return "none" end }
    local bag = { getContainingItem = function() return {getName = function() return "Small Backpack" end} end }
    local setup = {scope = "container", sourceContainer = bag, filter = {all = true, ids = {}, types = {}},
        destination = {kind = "container", ref = main}}
    local function description(window, expected)
        for _, widget in ipairs(window.controls) do
            if widget.text == expected then return true end
        end
        return false
    end
    local plan = {moves = {}, skipped = {}}
    assert(description(reviewWindow(f, plan, {}, setup), "Move all unprotected items from Small Backpack to My main inventory."))
    setup.sourceContainer, setup.destination = main, {kind = "floor"}
    assert(description(reviewWindow(f, plan, {}, setup), "Move all unprotected items from My main inventory to the floor."))
end)

test("cleanup review defaults to approval visits and offers an explicit job-only skip", function(f)
    local default = reviewWindow(f, f.plan, {})
    press(default, "Start cleanup and delete")
    assert(f.starts == 1 and f.startOptions == nil)
    local skipped = reviewWindow(f, f.plan, {})
    press(skipped, "Start and skip bin reviews")
    assert(f.starts == 2 and f.startOptions.reviewBins == false)
    assert(f.preferences.confirmQuickMoves == true and skipped.removed)
end)

test("arrival approval can skip later reviews without replacing the active job", function(f)
    local window, activeJob = reviewWindow(f), f.activeJob
    press(window, "Approve and skip further bin reviews")
    assert(f.approvals == 1 and f.approvalOptions.reviewBins == false)
    assert(f.starts == 0 and f.activeJob == activeJob and window.removed)
end)

test("both arrival approval choices remain disabled for a protected bin", function(f)
    f.binPlan.canApprove = false
    local window = reviewWindow(f)
    assert(not window.runButton.enabled and not window.skipReviewsButton.enabled)
    assert(not f.approvals and f.starts == 0)
end)

test("failed skip approval keeps the displayed token and error available", function(f)
    f.approvalError = "A protected item arrived in the bin"
    local window = reviewWindow(f)
    press(window, "Approve and skip further bin reviews")
    assert(not window.removed and window.context.binReview == f.binPlan)
    assert(window.messagePanel.text == f.approvalError and f.paused and f.starts == 0)
end)

test("the full cleanup preview offers the same explicit skip choice", function(f)
    local window = managerWindow(f, "home")
    window.request, window.plan = request("trash"), f.plan
    window:show("preview")
    press(window.body, "Start and skip bin reviews")
    assert(f.starts == 1 and f.startOptions.reviewBins == false and window.visible == false and f.progress)
end)

test("arrival review opens with progress closed and dismissal stays respected", function(f)
    assert(UI.progressWindows[0] == nil)
    UI.tick()
    local first = f.review
    assert(first and first.plan == f.binPlan and f.binReviews == 1)
    first:close()
    UI.tick(); UI.tick()
    assert(f.binReviews == 1 and UI.quickWindows[0] == nil and f.paused and f.starts == 0)
    UI.showBinReview(0)
    assert(f.binReviews == 2 and f.review ~= first and f.review.plan == f.binPlan)
end)

test("reopening the visible arrival review does not replace its approval token", function(f)
    local first = UI.showBinReview(0)
    local token = first.context.binReview
    local same = UI.showBinReview(0)
    UI.tick()
    assert(same == first and f.binReviews == 1 and same.context.binReview == token and first.raised == 1)
end)

test("a fresh arrival generation opens again after the old visit was dismissed", function(f)
    UI.tick()
    f.review:close()
    f.jobStatus.state = "running"
    UI.tick()
    assert(f.binReviews == 1)
    f.jobStatus.state, f.jobStatus.reviewId = "needs_review", 2
    f.binPlan = {moves = {}, skipped = {}, warnings = {}, pending = 0, canApprove = true}
    UI.tick(); UI.tick()
    assert(f.binReviews == 2 and f.review.context.binReview == f.binPlan and f.review.context.reviewId == 2)
end)

test("a replacement player session gets its own fresh review even when visit numbers match", function(f)
    UI.tick()
    local oldWindow, oldToken = f.review, f.binPlan
    local replacement = {}
    for key, entry in pairs(f.app) do replacement[key] = entry end
    f.app = replacement
    f.binPlan = {moves = {{itemName = "New session item"}}, skipped = {}, warnings = {}, pending = 0, canApprove = true}
    UI.tick()
    assert(f.binReviews == 2 and f.review ~= oldWindow and f.review.context.binReview ~= oldToken)
    assert(f.review.context.binReview == f.binPlan and oldWindow.closed)
end)

test("typing defers an arrival popup without consuming the pending visit", function(f)
    f.typing = true
    UI.tick(); UI.tick()
    assert(not f.review and not f.binReviews)
    f.typing = false
    UI.tick()
    assert(f.review and f.binReviews == 1)
end)

test("a failed automatic review is shown once and remains manually retryable", function(f)
    f.reviewError = "The bin unloaded before its contents could be reviewed"
    UI.tick(); UI.tick(); UI.tick()
    assert(f.binReviews == 1 and f.progressShows == 1 and f.progress.notice == f.reviewError)
    f.reviewError = nil
    UI.showBinReview(0)
    assert(f.binReviews == 2 and f.review and f.review.context.binReview == f.binPlan)
end)

test("arrival polling never creates a player session or approves a bin", function(f)
    f.sessionAvailable = false
    UI.tick(); UI.tick()
    assert(f.peeks == 2 and not f.gets and not f.review and not f.approvals and f.starts == 0)
    f.sessionAvailable = true
    f.app = {status = function() return {state = "needs_review", reviewId = 1} end,
        reviewBin = function() f.binReviews = (f.binReviews or 0) + 1; return f.binPlan end}
    UI.tick()
    assert(f.binReviews == 1 and f.review)
end)

test("Pause and Resume remain explicit while progress shows current settled counts", function(f)
    local window = progressWindow(f)
    f.jobStatus = {state = "running", canPause = true, done = 5, moved = 3, cleared = 2, total = 9, reasons = {}}
    window:update()
    assert(window.pauseButton.visible and not window.resumeButton.visible)
    assert(window.countLabel.text:find("5 processed of 9", 1, true))
    assert(window.countLabel.text:find("3 moved, 2 cleared in place", 1, true))
    press(window, "Pause job")
    window:update()
    assert(f.pauses == 1 and window.resumeButton.visible and not window.pauseButton.visible)
    assert(window.cancelButton.enabled and f.starts == 0)
    press(window, "Resume job")
    assert(f.resumes == 1 and f.jobStatus.state == "running" and f.starts == 0)
end)

test("a refused pause stays visible without altering the running job", function(f)
    local window = progressWindow(f)
    f.jobStatus.state, f.jobStatus.canPause = "running", true
    f.pauseError = "The pending native action has not settled"
    window:update(); press(window, "Pause job"); window:update()
    assert(window.reasonPanel.text:find(f.pauseError, 1, true) and f.jobStatus.state == "running")
    assert(not f.cancelled and f.starts == 0 and not f.resumes)
end)

test("pending personal gear remains reachable after the ordinary job stops", function(f)
    local window = progressWindow(f)
    f.jobStatus.state = "failed"
    f.recovery = {pending = true, count = 2, location = "Porch cabinet, floor 0", reason = "Original hand is occupied"}
    window:update()
    assert(window.recoverButton.visible and window.recoverButton.enabled)
    assert(window.reasonPanel.text:find(f.recovery.location, 1, true))
    f.recoveryError = "Clear the original hand first"
    press(window, "Recover gear"); window:update()
    assert(f.recoveries == 1 and window.reasonPanel.text:find(f.recoveryError, 1, true))
    f.jobStatus.state, f.jobStatus.canPause = "running", true
    window:update()
    assert(not window.recoverButton.enabled)
    f.jobStatus.state, f.jobStatus.canPause = "pausing", false
    window:update()
    assert(not window.recoverButton.enabled)
end)

test("the Current job key follows native rebinding and ignores text entry", function(f)
    f.jobStatus.state = "paused"
    UI.onKeyStartPressed(64)
    assert(not f.progress)
    UI.onKeyStartPressed(65)
    assert(f.progressShows == 1 and f.starts == 0)
    f.boundKey = 211
    UI.onKeyStartPressed(65)
    assert(f.progressShows == 1)
    f.typing = true
    UI.onKeyStartPressed(211)
    assert(f.progressShows == 1)
    f.typing = false
    UI.onKeyStartPressed(211)
    assert(f.progressShows == 2)
end)

test("the manual Current job key can open persisted recovery after entering a world", function(f)
    f.jobStatus.state = "idle"
    UI.onKeyStartPressed(f.boundKey)
    assert(not f.progress and f.gets == 1)
    f.recovery.pending = true
    UI.onKeyStartPressed(f.boundKey)
    assert(f.progressShows == 1 and f.gets == 2)
    function getSpecificPlayer() return nil end
    UI.onKeyStartPressed(f.boundKey)
    assert(f.progressShows == 1 and f.gets == 2)
end)

test("install registers a native rebindable F7 action without duplicating existing bindings", function()
    local registrations, menuInstalls = {tick = {}, key = {}, start = {}}, 0
    local options = {addTitle = function() end, addDescription = function() end, addButton = function() end}
    PZAPI = {ModOptions = {getOptions = function() return options end}}
    Events = {OnTick = {Add = function(fn) registrations.tick[#registrations.tick + 1] = fn end},
        OnGameStart = {Add = function(fn) registrations.start[#registrations.start + 1] = fn end},
        OnKeyStartPressed = {Add = function(fn) registrations.key[#registrations.key + 1] = fn end}}
    package.loaded["LootBox/Menus"] = {install = function() menuInstalls = menuInstalls + 1 end}
    package.loaded.keyBinding = true
    Keyboard, keyBinding = {KEY_F7 = 65, KEY_HOME = 199, KEY_END = 207, KEY_PRIOR = 201, KEY_NEXT = 209}, {{value = "ForeignAction", key = 9}}
    UI.installed = nil
    UI.install(); UI.install()
    assert(#keyBinding == 7 and keyBinding[1].key == 9 and keyBinding[3].value == "LootBoxCurrentJob" and keyBinding[3].key == 65)
    assert(#registrations.tick == 1 and #registrations.key == 2 and #registrations.start == 1 and menuInstalls == 1)
    assert(keyBinding[4].value == "LootBoxScrollTop" and keyBinding[4].key == 199)
    assert(keyBinding[5].value == "LootBoxScrollBottom" and keyBinding[5].key == 207)
    assert(keyBinding[6].value == "LootBoxScrollPageUp" and keyBinding[6].key == 201)
    assert(keyBinding[7].value == "LootBoxScrollPageDown" and keyBinding[7].key == 209)
    keyBinding[3].key = 211
    UI.installed = nil
    UI.install()
    assert(#keyBinding == 7 and keyBinding[3].key == 211)
end)

test("capacity-dependent bag setup uses its own warning status in the job review", function(f)
    local plan = {moves = {{itemName = "Plank", from = "Crate", to = "Carried storage after bag setup", status = "Recheck after bag setup"}},
        skipped = {}, warnings = {}}
    local window = reviewWindow(f, plan, {}, request("inventory"))
    local row = window.rows.items[1].item.segments
    assert(row[1].text == "Plank" and row[1].tone == "item")
    assert(row[2].text == "After bag setup" and row[2].tone == "warning")
    assert(row[3].text:find("Carried storage after bag setup", 1, true) and row[3].tone == "text")
end)

local function tick(widget, selected)
    widget:setSelected(1, selected)
    if widget.callback then widget.callback(widget.target, 1, selected) end
end

test("ordinary and cleanup quick actions can both run quietly without review", function(f)
    f.preferences.confirmQuickMoves, f.preferences.confirmQuickCleanup, f.preferences.showQuickProgress = false, false, false
    assert(UI.quickAction(0, {}, request("inventory")) == true)
    assert(UI.quickAction(0, {}, request("trash")) == true)
    assert(f.starts == 2 and f.previews == 2 and not f.review and not f.progress and not f.opened)
end)

test("matching quick requests keep their portable mode and use the ordinary review choice", function(f)
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, false
    local setup = request("matching"); setup.destination.mode = "displayed"
    assert(UI.quickAction(0, {kind = "matching"}, setup) == true)
    assert(f.reviewed.destination.kind == "matching" and f.reviewed.destination.mode == "displayed")
    assert(f.reviewed.scope == "inventory" and f.reviewed.includeBags and not f.progress)
end)

test("quiet quick starts close an older visible preview without opening another panel", function(f)
    local old = UI.quickAction(0, {}, request())
    assert(old == f.review)
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, false
    assert(UI.quickAction(0, {}, request()) == true)
    assert(old.closed and UI.quickWindows[0] == nil and not f.progress and f.starts == 1)
end)

test("quick progress is optional and important startup notices remain visible", function(f)
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, true
    assert(UI.quickAction(0, {}, request()) == f.progress and f.progressShows == 1)
    f.preferences.showQuickProgress, f.saveError = false, "Cannot save the setup"
    assert(UI.quickAction(0, {}, request()) == f.progress and f.progressShows == 2)
    assert(f.progress.notice:find(f.saveError, 1, true) and f.starts == 2)
end)

test("unreadable review preferences show a review rather than silently using direct defaults", function(f)
    f.preferences.confirmQuickMoves, f.preferences.confirmQuickCleanup = false, false
    f.preferenceError = "Damaged review preferences"
    local review = UI.quickAction(0, {}, request("trash"))
    assert(review == f.review and review.notice:find(f.preferenceError, 1, true))
    assert(f.starts == 0 and not f.progress and not f.preferenceWrites)
end)

test("a transfer preview opt-out persists only after its valid start", function(f)
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    assert(not window.skipPreviewCheck:isSelected(1))
    tick(window.skipPreviewCheck, true)
    assert(not f.preferenceWrites)
    resize(window, 540, 440)
    assert(window.skipPreviewCheck:isSelected(1))
    inside(window.skipPreviewCheck, window)
    press(window, "Start quick job")
    assert(f.starts == 1 and f.preferenceWrites == 1 and f.preferences.confirmQuickMoves == false)
    assert(f.preferences.confirmQuickCleanup and f.preferences.confirmBinReviews)
end)

test("cancelling a preview does not save its pending opt-out", function(f)
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    tick(window.skipPreviewCheck, true)
    press(window, "Cancel")
    assert(window.removed and f.starts == 0 and not f.preferenceWrites and f.preferences.confirmQuickMoves)
end)

test("a rejected start keeps both the preview and its remembered preference unchanged", function(f)
    f.startError = "The source changed"
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    tick(window.skipPreviewCheck, true)
    press(window, "Start quick job")
    assert(not window.removed and window.messagePanel.text:find(f.startError, 1, true))
    assert(not f.preferenceWrites and f.preferences.confirmQuickMoves)
end)

test("cleanup preview opt-out does not change transfer or arrival-review preferences", function(f)
    local window = reviewWindow(f, f.plan, {}, request("trash"))
    tick(window.skipPreviewCheck, true)
    press(window, "Start cleanup and delete")
    assert(f.starts == 1 and f.preferences.confirmQuickCleanup == false)
    assert(f.preferences.confirmQuickMoves and f.preferences.confirmBinReviews and f.preferenceWrites == 1)
end)

test("a bin review can remember automatic approval after its valid token succeeds", function(f)
    local window = reviewWindow(f)
    tick(window.skipPreviewCheck, true)
    press(window, "Approve bin and continue")
    assert(f.approvals == 1 and f.approvalOptions.reviewBins == false and f.preferences.confirmBinReviews == false)
    assert(f.preferences.confirmQuickMoves and f.preferences.confirmQuickCleanup and f.preferenceWrites == 1)
    assert(f.starts == 0)
end)

test("invalid bin approval cannot persist an opt-out", function(f)
    f.approvalError = "Review this bin again"
    local window = reviewWindow(f)
    tick(window.skipPreviewCheck, true)
    press(window, "Approve bin and continue")
    assert(not window.removed and window.messagePanel.text:find(f.approvalError, 1, true))
    assert(not f.preferenceWrites and f.preferences.confirmBinReviews and f.paused)
end)

test("an explicit preview can re-enable future reviews after a successful start", function(f)
    f.preferences.confirmQuickMoves = false
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    assert(window.skipPreviewCheck:isSelected(1))
    tick(window.skipPreviewCheck, false)
    press(window, "Start quick job")
    assert(f.preferences.confirmQuickMoves == true and f.preferenceWrites == 1 and f.starts == 1)
end)

test("a preference-write failure leaves the running job intact and explains the unsaved choice", function(f)
    f.preferenceSaveError = "The local preference file is read-only"
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    tick(window.skipPreviewCheck, true)
    press(window, "Start quick job")
    assert(window.removed and f.starts == 1 and f.preferences.confirmQuickMoves)
    assert(f.progress.notice:find(f.preferenceSaveError, 1, true) and f.preferenceWrites == 1)
end)

test("manual Start runs directly while explicit Preview remains available", function(f)
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, false
    local window = managerWindow(f, "compose", {request = request("inventory")})
    press(window.body, "Start job")
    assert(f.starts == 1 and f.progress and window.visible == false)
end)

test("explicit Preview opens a plan even when automatic reviews are disabled", function(f)
    f.preferences.confirmQuickMoves = false
    local window = managerWindow(f, "compose", {request = request("inventory")})
    press(window.body, "Preview job")
    assert(window.mode == "preview" and f.previews == 1 and f.starts == 0)
    assert(window.skipPreviewCheck:isSelected(1))
end)

test("manual Start honors enabled reviews instead of bypassing the chosen preference", function(f)
    local window = managerWindow(f, "compose", {request = request("inventory")})
    press(window.body, "Start job")
    assert(window.mode == "preview" and f.starts == 0)
    tick(window.skipPreviewCheck, true)
    press(window.body, "Adjust setup")
    press(window.body, "Preview job")
    assert(window.skipPreviewCheck:isSelected(1))
    press(window.body, "Start job")
    assert(f.starts == 1 and not f.preferences.confirmQuickMoves)
end)

test("matching mode fixes all carried sources and restores the previous source choices on exit", function(f)
    local setup = request("inventory"); setup.scope, setup.includeBags, setup.includeInventory = "room", false, true
    local window = managerWindow(f, "compose", {request = setup})
    window.destination:selectData("matching"); window:onDestinationChanged()
    assert(window.scope:getOptionData(window.scope.selected) == "inventory" and window.scope.enabled == false)
    assert(window.includeBags:isSelected(1) and window.includeBags.enable == false)
    assert(window.includeBags.tooltip:find("every carried container", 1, true))
    window.endpoint:selectData("displayed")
    local chosen = assert(window:readRequest())
    assert(chosen.scope == "inventory" and chosen.includeBags and not chosen.includeInventory)
    assert(chosen.destination.kind == "matching" and chosen.destination.mode == "displayed")
    resize(window, 900, 740)
    assert(window.endpoint:getOptionData(window.endpoint.selected) == "displayed")
    window.destination:selectData("inventory"); window:onDestinationChanged()
    assert(window.scope:getOptionData(window.scope.selected) == "room" and window.scope.enabled)
    assert(not window.includeBags:isSelected(1) and window.includeBags.enable and window.includeInventory:isSelected(1))
end)

test("cleanup previews omit a redundant one-job skip button when arrival reviews are already off", function(f)
    f.preferences.confirmBinReviews = false
    local window = reviewWindow(f, f.plan, {}, request("trash"))
    assert(window.skipReviewsButton == nil and window.runButton.enabled)
    inside(window.skipPreviewCheck, window)
end)

test("an untouched preview checkbox cannot overwrite a newer Settings choice", function(f)
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    assert(not window.skipPreviewCheck:isSelected(1))
    f.preferences.confirmQuickMoves = false
    press(window, "Start quick job")
    assert(f.starts == 1 and f.preferences.confirmQuickMoves == false and not f.preferenceWrites)
end)

test("an explicit bin review can enable future bin approvals without forcing a one-job skip", function(f)
    f.preferences.confirmBinReviews = false
    local window = reviewWindow(f)
    assert(window.skipPreviewCheck:isSelected(1))
    tick(window.skipPreviewCheck, false)
    press(window, "Approve bin and continue")
    assert(f.approvals == 1 and f.approvalOptions == nil and f.preferences.confirmBinReviews)
    assert(f.preferenceWrites == 1)
end)

test("a one-job skip remains separate from remembered arrival-review preferences", function(f)
    local window = reviewWindow(f)
    assert(not window.skipPreviewCheck:isSelected(1))
    press(window, "Approve and skip further bin reviews")
    assert(f.approvals == 1 and f.approvalOptions.reviewBins == false)
    assert(f.preferences.confirmBinReviews and not f.preferenceWrites)
end)

test("Adjust setup carries a changed review choice into the full composer without saving early", function(f)
    local window = reviewWindow(f, f.plan, {}, request("inventory"))
    tick(window.skipPreviewCheck, true)
    press(window, "Adjust setup")
    assert(f.opened and not f.preferenceWrites and f.preferences.confirmQuickMoves)
    local full = managerWindow(f, "compose", f.opened.context)
    press(full.body, "Preview job")
    assert(full.skipPreviewCheck:isSelected(1) and not f.preferenceWrites)
    press(full.body, "Start job")
    assert(f.starts == 1 and f.preferenceWrites == 1 and not f.preferences.confirmQuickMoves)
end)

test("a quiet quick action with no planned moves does not require an empty approval window", function(f)
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, false
    f.plan.moves = {}
    assert(UI.quickAction(0, {}, request()) == true)
    assert(f.starts == 1 and not f.review and not f.progress)
end)

test("Smart Take quick requests and Adjust setup retain the unwanted-item exclusion", function(f)
    local setup = request("inventory")
    setup.excludeUnwanted = true
    UI.quickAction(0, {}, setup)
    assert(f.reviewed.excludeUnwanted == true and f.review.request.excludeUnwanted == true)
    local window = reviewWindow(f, f.plan, {}, setup)
    press(window, "Adjust setup")
    assert(f.opened.context.request.excludeUnwanted == true)
    local full = managerWindow(f, "compose", f.opened.context)
    assert(full:readRequest().excludeUnwanted == true)
    press(full.body, "Preview job")
    assert(f.reviewed.excludeUnwanted == true)
end)

test("Condense follows the ordinary review setting and can start quietly", function(f)
    f.plan.condense = {mode = "pack", eligible = 1, bagCount = 1, estimatedSaving = 2.7}
    f.app.previewCondense = function() f.condensePreviews = (f.condensePreviews or 0) + 1; return f.plan end
    local preview = UI.condense(2)
    assert(preview.context.condense and preview.playerIndex == 2 and preview.plan == f.plan)
    assert(preview.request.destination.kind == "condense" and f.starts == 0)
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, false
    assert(UI.condense(2) == true and f.starts == 1 and f.condensePreviews == 2 and not f.progress)
    assert(preview.closed and UI.quickWindows[2] == nil)
end)

test("fresh footer actions use replacement instead of Resume and wait for cleanup", function(f)
    f.deferReplacement = true
    f.jobStatus = {state = "paused", hasJob = true, canResume = true}
    local first, latest = 0, 0
    assert(UI.replaceAction(0, function() first = first + 1 end))
    assert(UI.replaceAction(0, function() latest = latest + 1 end))
    assert(first == 0 and latest == 0 and not f.resumes)
    f.pendingReplacement()
    assert(first == 0 and latest == 1 and f.replacements == 2)
end)

test("replacement releases editor focus and closes stale reviews only for its player", function(f)
    local body, other = {}, {}
    UI.windows[0], UI.windows[1] = {body = body}, {body = other}
    local closed = false
    UI.quickWindows[0] = {close = function() closed = true end}
    assert(UI.replaceAction(0, function() return true end))
    assert(f.unfocused == body and closed and UI.windows[1].body == other)
end)

test("replacement refusal surfaces recovery guidance without starting or resuming", function(f)
    f.replaceError = "Recover personal gear before starting another job"
    local result, err = UI.replaceAction(0, function() error("Must not start") end)
    assert(result == nil and err == f.replaceError and f.progress)
    assert(not f.resumes and f.starts == 0)
end)

test("Condense requests a fresh plan after cleanup rather than reviving a checkpoint", function(f)
    f.deferReplacement = true
    f.app.previewCondense = function() f.condensePreviews = (f.condensePreviews or 0) + 1; return f.plan end
    assert(UI.condense(0))
    assert(UI.condense(0))
    assert(not f.condensePreviews and not f.resumes)
    f.pendingReplacement()
    assert(f.condensePreviews == 1 and f.replacements == 2)
end)

test("loot pane quick review preserves the snapshot in Adjust setup", function(f)
    local source, other = {}, {}
    local setup = request("inventory")
    setup.scope, setup.sourceContainers = "lootPane", {source, other}
    setup.shortcutIntent, setup.includeBags = "smart:all", false
    local review = UI.quickAction(0, {}, setup)
    assert(review.request.sourceContainers[1] == source and review.request.sourceContainers ~= setup.sourceContainers)
    local window = reviewWindow(f, f.plan, {}, review.request)
    press(window, "Adjust setup")
    local full = managerWindow(f, "compose", f.opened.context)
    local adjusted = full:readRequest()
    assert(adjusted.scope == "lootPane" and adjusted.sourceContainers[1] == source and #adjusted.sourceContainers == 2)
    assert(not adjusted.includeInventory and not adjusted.includeBags)
end)

test("Smart Take emptied during cleanup never opens an empty review or compose menu", function(f)
    f.plan.moves = {}
    local setup = request("inventory")
    setup.shortcutIntent = "smart:all"
    assert(UI.quickAction(0, {}, setup) == true)
    assert(f.starts == 0 and not f.review and not f.opened and not f.progress)
end)

test("Smart Take preview errors report progress without opening a setup menu", function(f)
    f.previewError = "Selected source is no longer accessible"
    local setup = request("inventory")
    setup.shortcutIntent = "smart:matching"
    local result, err = UI.quickAction(0, {}, setup)
    assert(result == nil and err == f.previewError and f.progress and not f.opened and not f.review)
end)

test("Condense review starts its reviewed plan and opens its settings section", function(f)
    f.plan.condense = {mode = "rebalance", eligible = 4, bagCount = 2, beforeWeight = 10, estimatedSaving = 2.7,
        useUnequipped = false, nested = false}
    local setup = request("condense")
    local window = reviewWindow(f, f.plan, {condense = true}, setup)
    assert(window.runButton.text == "Start Condense" and window.runButton.enabled)
    press(window, "Start Condense")
    assert(f.starts == 1 and window.removed)
    window = reviewWindow(f, f.plan, {condense = true}, setup)
    press(window, "Condense settings")
    assert(f.opened.mode == "settings" and f.opened.context.settingsSection == "condense" and f.starts == 1)
end)

test("composer scope tooltips follow native option precedence when matching is toggled", function(f)
    local window = managerWindow(f, "compose", {request = request("inventory")})
    local inventoryOption
    for index, option in ipairs(window.scope.options) do
        if option.data == "inventory" then inventoryOption = index; break end
    end
    assert(inventoryOption and window.scope:getOptionTooltip(inventoryOption):find("Bag contents are included", 1, true))
    window.destination:selectData("matching"); window:onDestinationChanged()
    assert(window.scope:getOptionTooltip(inventoryOption):find("always use all carried containers", 1, true))
    window.destination:selectData("inventory"); window:onDestinationChanged()
    assert(window.scope:getOptionTooltip(inventoryOption):find("Bag contents are included", 1, true))
end)

test("blocked quick previews show Current job without creating a composer or a second job", function(f)
    f.previewError = "Finish or cancel the current job before previewing another"
    f.jobStatus.canPreview = false
    for _, state in ipairs({"running", "pausing", "cancelling", "paused", "needs_review", "idle"}) do
        f.jobStatus.state = state
        local result, err = UI.quickAction(0, {}, request("inventory"))
        assert(result == nil and err == f.previewError)
        assert(f.progress.notice:find(f.previewError, 1, true))
        assert(not f.opened and not f.review and f.starts == 0 and f.remembered == 0)
    end
    assert(f.previews == 6 and f.progressShows == 6)
end)

test("invalid source previews retain the full adjustment route when the core allows previews", function(f)
    local source = {getContainingItem = function() end, getVehiclePart = function() end,
        getParent = function() end, getType = function() return "crate" end}
    local setup = request("inventory")
    setup.scope, setup.sourceContainer = "container", source
    f.previewError = "The selected source is no longer available"
    local result, err = UI.quickAction(0, {sourceContainer = source}, setup)
    assert(result == nil and err == f.previewError)
    assert(f.opened.mode == "compose" and f.opened.message == f.previewError)
    assert(f.opened.context.request.sourceContainer == source and not f.progress)
    local window = managerWindow(f, "compose", f.opened.context)
    assert(window:readRequest().sourceContainer == source and f.starts == 0 and f.remembered == 0)
end)

test("a terminal cancelled job can start a new quick action when the core permits it", function(f)
    f.jobStatus.state, f.jobStatus.canResume = "cancelled", false
    f.preferences.confirmQuickMoves, f.preferences.showQuickProgress = false, false
    assert(UI.quickAction(0, {}, request("inventory")) == true)
    assert(f.starts == 1 and f.previews == 1 and not f.progress and not f.opened)
end)

test("shrinking destination choices selects a visible match and preserves a same-kind choice", function(f)
    local window = managerWindow(f, "compose", {request = request("inventory")})
    window.destination:selectData("labels"); window:onDestinationChanged()
    assert(#window.endpoint.options > 2)
    window.endpoint:setSelected(3)
    window.destination:selectData("matching"); window:onDestinationChanged()
    assert(#window.endpoint.options == 2 and window.endpoint.selected == 1)
    assert(window.endpoint:getOptionData(window.endpoint.selected) == "nearby")
    assert(window:readRequest().destination.mode == "nearby")
    window.endpoint:selectData("displayed"); window:onDestinationChanged()
    assert(window.endpoint.selected == 2 and window:readRequest().destination.mode == "displayed")
    assert(f.starts == 0 and f.previews == 0)
end)

test("saved matching choices restore on a new composer while reflow retains its current choice", function(f)
    local setup = request("matching")
    setup.destination.mode = "displayed"
    local window = managerWindow(f, "compose", {request = setup})
    assert(window.endpoint:getOptionData(window.endpoint.selected) == "displayed")
    window.endpoint:selectData("nearby"); window:onDestinationChanged()
    resize(window, 900, 740)
    assert(window.endpoint:getOptionData(window.endpoint.selected) == "nearby")
    window:setRequest(setup); window:show("compose")
    assert(window.endpoint:getOptionData(window.endpoint.selected) == "displayed")
    assert(window:readRequest().destination.mode == "displayed" and f.starts == 0)
end)

test("cross-kind default sentinels cannot override a saved vehicle and same-kind defaults remain selected", function(f)
    local savedVehicle = {}
    local previousVehicleMenu = ISVehicleMenu
    ISVehicleMenu = {getVehicleDisplayName = function(vehicle) assert(vehicle == savedVehicle); return "Saved car" end}
    f.app.knownVehicles = function() return {savedVehicle} end
    local setup = request("vehicle")
    setup.destination.ref = savedVehicle
    local window = managerWindow(f, "compose", {request = setup})
    assert(window.endpoint:getOptionData(window.endpoint.selected) == savedVehicle)
    window.destination:selectData("labels"); window:onDestinationChanged()
    window.endpoint:selectData(false)
    assert(window.endpoint:getOptionData(window.endpoint.selected) == false)
    window.destination:selectData("vehicle"); window:onDestinationChanged()
    assert(window.endpoint:getOptionData(window.endpoint.selected) == savedVehicle)
    window.endpoint:selectData(false); window:onDestinationChanged()
    assert(window.endpoint.selected == 1 and window.endpoint:getOptionData(window.endpoint.selected) == false)
    assert(window:readRequest().destination.ref == nil and f.starts == 0)
    ISVehicleMenu = previousVehicleMenu
end)

test("an empty destination pool stays unselected and cannot create an implicit container target", function(f)
    local container = {getContainingItem = function() end, getVehiclePart = function() end,
        getParent = function() end, getType = function() return "crate" end}
    local setup = request("container")
    setup.destination.ref = container
    local window = managerWindow(f, "compose", {request = setup, container = container})
    assert(window.endpoint:getOptionData(window.endpoint.selected) == container)
    window.context.container, window.context.targetContainer, window.context.containers = nil, nil, {}
    window:onDestinationChanged()
    assert(#window.endpoint.options == 0 and window.endpoint.selected == 0)
    assert(window.endpoint:getOptionData(window.endpoint.selected) == nil)
    local chosen, err = window:readRequest()
    assert(chosen == nil and err:find("destination container", 1, true) and f.starts == 0)
end)

local function labelContainer(name)
    return {getContainingItem = function() end, getVehiclePart = function() end,
        getParent = function() end, getType = function() return name end}
end

test("changing a third storage target to item tags selects and saves the only item", function(f)
    local item = {getName = function() return "My hammer" end, getFullType = function() return "Base.Hammer" end}
    local containers = {labelContainer("cupboard"), labelContainer("shelf"), labelContainer("crate")}
    f.app.setItemLabels = function(_, target) f.savedTagTarget = target; return true end
    f.app.protect = function(_, target) f.savedKeepTarget = target; return true end
    local window = managerWindow(f, "labels", {containers = containers, item = item, labelKind = "container"})
    window.labelTarget:setSelected(3); window:loadLabels()
    assert(window.labelTarget:getOptionData(3).ref == containers[3])
    window.labelKind:selectData("item"); window:fillLabelTargets()
    local target = window.labelTarget:getOptionData(window.labelTarget.selected)
    assert(#window.labelTarget.options == 1 and window.labelTarget.selected == 1)
    assert(target.kind == "item" and target.ref == item and window.saveLabelsButton.enabled)
    press(window.body, "Save tags and Keep")
    assert(f.savedTagTarget == item and f.savedKeepTarget == item and f.starts == 0)
end)

test("same-kind label rebuilding keeps the same storage identity after the pool order changes", function(f)
    local first, second, third = labelContainer("cupboard"), labelContainer("shelf"), labelContainer("crate")
    local window = managerWindow(f, "labels", {containers = {first, second, third}, labelKind = "container"})
    window.labelTarget:setSelected(3); window:loadLabels()
    window.labelContainers = {second, third, first}
    window:fillLabelTargets()
    local target = window.labelTarget:getOptionData(window.labelTarget.selected)
    assert(window.labelTarget.selected == 2 and target.kind == "container" and target.ref == third)
    assert(window.saveLabelsButton.enabled and f.starts == 0)
end)

test("empty label pools disable saving and a later available pool selects its first target", function(f)
    local first, second, third = labelContainer("cupboard"), labelContainer("shelf"), labelContainer("crate")
    local window = managerWindow(f, "labels", {containers = {first, second, third}, labelKind = "container"})
    window.labelTarget:setSelected(3); window:loadLabels()
    window.labelContainers = {}; window:fillLabelTargets()
    assert(window.labelTarget.selected == 0 and window.labelTarget:getOptionData(0) == nil)
    assert(not window.saveLabelsButton.enabled and not window.keep.visible)
    assert(window.labelCount.text:find("No label target", 1, true))
    window.labelContainers = {second, first}; window:fillLabelTargets()
    assert(window.labelTarget.selected == 1 and window.labelTarget:getOptionData(1).ref == second)
    assert(window.saveLabelsButton.enabled and f.starts == 0)
end)

print(passed .. " UI workflow cases passed (explicit native window and job boundary doubles)")

