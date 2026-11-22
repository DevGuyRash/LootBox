require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISToolTip"
require "PZAPI/ModOptions"

local App = require "LootBox/App"
local Categories = require "LootBox/Categories"
local Guides = require "LootBox/Guides"
local W = require "LootBox/Widgets"
local UI = { windows = {}, progressWindows = {}, quickWindows = {}, areaPickers = {}, notices = {}, reviewVisits = {} }
local Window = ISCollapsableWindow:derive("LootBoxWindow")
local Progress = ISCollapsableWindow:derive("LootBoxProgress")
local QuickReview = ISCollapsableWindow:derive("LootBoxQuickReview")
local AreaPicker = ISPanel:derive("LootBoxAreaPicker")
local H, GAP, C = W.H, W.GAP, W.colors
local button, entry, combo, check, list, wrapped = W.button, W.entry, W.combo, W.check, W.list, W.text
local states = { idle = "Ready for a job", running = "Working", cancelling = "Stopping and restoring access", pausing = "Pausing and restoring access",
    needs_review = "Review bin before continuing", paused = "Paused - ready to resume",
    cancelled = "Cancelled", failed = "Stopped after an error", complete = "Finished",
    finished = "Finished", finished_with_skips = "Finished with notes" }
local sourceNames = { lootPane = "the captured loot-pane containers", inventory = "my carried items", reach = "within reach", room = "the current room",
    building = "the current building", area = "the selected area", labeled = "labeled containers", container = "the selected container" }
local destinationNames = { inventory = "my inventory with Smart Load (bags first)", floor = "the floor", container = "the selected container",
    vehicle = "my vehicle", labels = "matching labeled storage", matching = "containers holding matching item types", trash = "trash cans" }

local reviewChoices = {
    confirmQuickMoves = {label = "Skip future transfer previews", tooltip = "Remember this after a successful start. Future quick transfers start directly. You can enable reviews again in Settings."},
    confirmQuickCleanup = {label = "Skip future cleanup previews", tooltip = "Remember this after a successful start. Future quick cleanup actions delete eligible items without this preview. Bin review is a separate setting."},
    confirmBinReviews = {label = "Skip future bin reviews", tooltip = "Remember this after successful approval. Eligible bins will be inspected and approved automatically for this and future jobs. Protected items, permissions and native rules still apply."},
}

local function condenseMode(info)
    return info and info.mode == "rebalance" and "Optimize bag contents" or "Pack main inventory"
end

local function condenseScope(info)
    local scope = info and info.useUnequipped and "Equipped and unequipped bags" or "Equipped bags only"
    return scope .. (info and info.nested and "; nested contents included" or "; nested contents left in place")
end

local function condenseDescription(info)
    local text = condenseScope(info) .. ". Bag objects stay where they are."
    if info and info.estimatedSaving then
        text = text .. string.format("\nFirst arrangement estimate: %.2f encumbrance reduced. Later arrangements are checked as the job runs.", info.estimatedSaving)
    end
    return text
end

local function rememberReviewChoice(widget, key, notice)
    if not widget then return notice end
    if widget.initialReviewSelection ~= nil and widget:isSelected(1) == widget.initialReviewSelection then return notice end
    local required = not widget:isSelected(1)
    local preferences, problem = App.getPreferences()
    if not problem and preferences[key] == required then return notice end
    local ok, err = App.setPreferences({[key] = required})
    if ok then return notice end
    local message = "The job is running, but its review choice could not be saved: " .. tostring(err)
    return notice and (notice .. "\n" .. message) or message
end

local function label(parent, x, y, text, dim)
    return W.label(parent, x, y, text, dim and "muted" or "text")
end

local function place(widget, x, y, width, height)
    if not widget then return end
    if x ~= nil and widget.x ~= x then widget:setX(x) end
    if y ~= nil and widget.y ~= y then widget:setY(y) end
    if width ~= nil and widget.width ~= width then widget:setWidth(math.max(1, width)) end
    if height ~= nil and widget.height ~= height then widget:setHeight(math.max(1, height)) end
end

local function resizeFrame(target, width, height)
    target:setWidth(width)
    target:setHeight(height)
    target:onResize()
end

local function enableResize(window)
    window:setResizable(true)
    window.resizeWidget.resizeFunction = resizeFrame
    window.resizeWidget2.resizeFunction = resizeFrame
end

local function bottomInset(window)
    return math.max(GAP, window:resizeWidgetHeight() + 2)
end

local function detailRow(widget, itemName, status, description, tone)
    itemName, status, description = tostring(itemName or "Item"), tostring(status or ""), tostring(description or "")
    local text = itemName .. (status ~= "" and ("   " .. status) or "") .. (description ~= "" and ("   " .. description) or "")
    return widget:addItem(text, { segments = { { text = itemName, tone = "item", share = 0.32 },
        { text = status, tone = tone or "warning", share = 0.20 }, { text = description, tone = "text" } } }, text)
end

local function value(widget)
    return widget and widget:getOptionData(widget.selected) or nil
end

local function setOf(values)
    local result = {}
    for _, v in ipairs(values or {}) do result[v] = true end
    return result
end

local function arrayOf(values)
    local result = {}
    for key, selected in pairs(values or {}) do if selected then result[#result + 1] = key end end
    table.sort(result)
    return result
end

local function matchesSearch(text, query)
    return query == "" or string.find(string.lower(tostring(text)), query, 1, true) ~= nil
end

local function copyRequest(request)
    request = request or {}
    local filter, destination = request.filter or {}, request.destination or {}
    local result = { scope = request.scope or "inventory", sourceContainer = request.sourceContainer,
        shortcutIntent = request.shortcutIntent,
        includeInventory = request.includeInventory == true, includeBags = request.includeBags ~= false, excludeUnwanted = request.excludeUnwanted == true,
        filter = { ids = {}, types = {}, all = filter.all == true },
        destination = { kind = destination.kind or "inventory", ref = destination.ref, mode = destination.mode } }
    for _, id in ipairs(filter.ids or {}) do result.filter.ids[#result.filter.ids + 1] = id end
    for _, id in ipairs(filter.types or {}) do result.filter.types[#result.filter.types + 1] = id end
    if request.sourceContainers then
        result.sourceContainers = {}
        for _, source in ipairs(request.sourceContainers) do result.sourceContainers[#result.sourceContainers + 1] = source end
    end
    if request.sourceLabels then
        result.sourceLabels = {}
        for _, id in ipairs(request.sourceLabels) do result.sourceLabels[#result.sourceLabels + 1] = id end
    end
    if destination.labels then
        result.destination.labels = {}
        for _, id in ipairs(destination.labels) do result.destination.labels[#result.destination.labels + 1] = id end
    end
    if request.area then
        result.area = {}
        for _, key in ipairs({ "x1", "y1", "x2", "y2", "z" }) do result.area[key] = request.area[key] end
    end
    return result
end

local function hasSelection(request)
    local f = request.filter or {}
    return f.all == true or #(f.ids or {}) > 0 or #(f.types or {}) > 0
end

local function friendly(text)
    text = tostring(text or "Container"):gsub("_", " ")
    return text:sub(1, 1):upper() .. text:sub(2)
end

local function containerName(container)
    if not container then return "Container you click" end
    local item = container:getContainingItem()
    if item then return tostring(item:getName()) end
    local part = container:getVehiclePart()
    if part then return getTextOrNull("IGUI_VehiclePart" .. part:getId()) or friendly(part:getId()) end
    local parent = container:getParent()
    if parent and instanceof(parent, "IsoPlayer") then return "My main inventory" end
    local count = parent and parent.getContainerCount and parent:getContainerCount() or 1
    local index = parent and parent:getContainerIndex(container)
    local name = friendly(container:getType())
    if count > 1 and index and index >= 0 then name = name .. " - compartment " .. tostring(index + 1) end
    return name
end

local function vehicleName(vehicle)
    if ISVehicleMenu and ISVehicleMenu.getVehicleDisplayName then return ISVehicleMenu.getVehicleDisplayName(vehicle) end
    return vehicle:getScript():getName()
end

local function categoryRows(catalog)
    local rows = {}
    for _, row in ipairs(catalog.categories) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b)
        if a.kind ~= b.kind then return a.kind == "custom" end
        if string.lower(a.name) == string.lower(b.name) then return a.id < b.id end
        return string.lower(a.name) < string.lower(b.name)
    end)
    return rows
end

local function categoryMatches(row, group, selected)
    return group == "all" or (group == "selected" and selected and selected[row.id])
        or (group == "custom" and row.kind == "custom") or (group == "native" and row.kind ~= "custom")
end

local function addGroups(widget)
    widget:addOptionWithData("All categories", "all", "Every game, mod and custom category remains available.")
    widget:addOptionWithData("My categories", "custom", "Categories you created, including nested categories.")
    widget:addOptionWithData("Game and mod categories", "native", "Categories supplied by installed game content.")
    widget:addOptionWithData("Selected only", "selected", "Show only the categories checked in this view.")
end

local function addCategoryRow(widget, row, data)
    data = data or {}
    data.key = row.id
    data.tone = row.kind == "custom" and "custom" or "muted"
    data.segments = { { text = row.kind == "custom" and "My category" or "Game category", tone = data.tone },
        { text = row.name, tone = "item" } }
    widget:addItem(row.name, data, row.name .. "\n" .. (row.kind == "custom" and "Custom reusable category." or "Game or mod category.")
        .. "\nID: " .. row.id)
end

local function routeText(request)
    local f = request.filter or {}
    local names = {}
    for _, id in ipairs(f.ids or {}) do
        local definition = App.category(id)
        local raw = id:match("^native:(.+)$")
        local translated = raw and getText("IGUI_ItemCat_" .. raw)
        names[#names + 1] = definition and definition.name or (raw and translated ~= "IGUI_ItemCat_" .. raw and translated) or raw or id
    end
    for _, fullType in ipairs(f.types or {}) do names[#names + 1] = getItemNameFromFullType(fullType) or fullType end
    local selection = f.all and "all unprotected items" or table.concat(names, ", ")
    if #names > 3 and not f.all then selection = tostring(#names) .. " selected groups or item types" end
    if selection == "" then selection = "the supplies you choose" end
    local source = request.scope == "container" and request.sourceContainer and containerName(request.sourceContainer)
        or sourceNames[request.scope] or "the chosen source"
    if request.includeInventory and request.scope ~= "inventory" then source = source .. " and my carried items" end
    local destination = request.destination or {}
    local target = destination.kind == "container" and destination.ref and containerName(destination.ref)
        or (destination.kind == "vehicle" and destination.ref and vehicleName(destination.ref))
        or (destination.kind == "matching" and (destination.mode == "displayed" and "the displayed loot container, matching item types" or "nearby containers, matching item types"))
        or destinationNames[destination.kind] or "the chosen destination"
    return "Move " .. selection .. " from " .. source .. " to " .. target .. "."
end

local function pendingSummary(plan)
    if plan.condense then
        return tostring(plan.condense.eligible or 0) .. " eligible items   " .. tostring(plan.condense.bagCount or 0) .. " eligible bags"
    end
    local rooms = plan.building and plan.building.roomsTotal or 0
    local sources = math.max(0, (plan.pending or 0) - rooms)
    if rooms > 0 then
        return tostring(rooms) .. " rooms to survey" .. (sources > 0 and ("   " .. tostring(sources) .. " sources to inspect") or "")
    end
    return tostring(sources) .. " sources to inspect"
end

local function reviewRows(widget, plan)
    local rooms = plan.building and plan.building.roomsTotal or 0
    if rooms > 0 then
        detailRow(widget, tostring(rooms) .. " building rooms", "To search", "The job walks through their floors and adds matching items as it finds them.", "accent")
    end
    local pending = math.max(0, (plan.pending or 0) - rooms)
    if pending > 0 and plan.condense then
        detailRow(widget, "Further arrangements", "Recheck", "Current contents and native capacity are checked after each completed arrangement.", "accent")
    elseif pending > 0 then
        detailRow(widget, tostring(pending) .. " sources", "To inspect", "Contents will be checked after approach. Empty multiplayer replies can remain unconfirmed.", "accent")
    end
    for _, row in ipairs(plan.moves or {}) do
        local bagSetup = row.status == "Recheck after bag setup"
        detailRow(widget, row.itemName, plan.bin and "Will be deleted" or (plan.condense and row.status or (bagSetup and "After bag setup" or "Planned")),
            tostring(row.from or "Source") .. " -> " .. tostring(row.to or "Destination"),
            plan.bin and "danger" or (plan.condense and row.tone or (bagSetup and "warning" or "success")))
    end
    for _, row in ipairs(plan.skipped or {}) do
        detailRow(widget, row.itemName, row.status or "Stays here", row.reason or "No destination", row.tone or "warning")
    end
    for _, warning in ipairs(plan.warnings or {}) do
        local text = "Notice   " .. tostring(warning)
        widget:addItem(text, { segments = { { text = "Notice", tone = "warning" }, { text = warning, tone = "text" } } }, text)
    end
end

function Window:new(playerIndex, context, mode)
    local width = math.min(1080, getCore():getScreenWidth() - 40)
    local availableHeight = getCore():getScreenHeight() - 40
    local height = math.min(790, availableHeight)
    local o = ISCollapsableWindow.new(self, (getCore():getScreenWidth() - width) / 2,
        (getCore():getScreenHeight() - height) / 2, width, height)
    o.playerIndex, o.context, o.mode = playerIndex, context or {}, mode or "home"
    o.skipPreviewKey, o.skipPreviewDraft, o.skipPreviewInitial = o.context.skipPreviewKey, o.context.skipPreviewDraft, o.context.skipPreviewInitial
    o.resizable, o.title, o.backgroundColor = true, "LootBox", W.color("base")
    local minimumHeight = math.max(710, o:titleBarHeight() + 14 * H + 7 * GAP + 20 + bottomInset(o))
    o.minimumWidth, o.minimumHeight = math.min(760, width), math.min(minimumHeight, availableHeight)
    o:setHeight(math.max(height, o.minimumHeight))
    o:setY((getCore():getScreenHeight() - o.height) / 2)
    o.borderColor = W.color("border")
    local app = getSpecificPlayer(playerIndex) and App.get(playerIndex)
    local request
    if o.context.request then request = o.context.request
    elseif o.context.item then
        request = { scope = o.context.scope or "inventory", includeBags = true,
            filter = { ids = {}, types = { o.context.item:getFullType() }, all = false }, destination = { kind = "inventory" } }
    elseif app then request, o.initialNotice = app:lastSetup(o.context) end
    o.initialNotice = UI.notices[playerIndex] or o.initialNotice
    o:setRequest(request or { scope = o.context.scope or "inventory", includeBags = true,
        filter = { ids = {}, types = {}, all = false }, destination = { kind = "inventory" } })
    o.editor = { types = {}, includes = {} }
    return o
end

function Window:setRequest(request)
    self.matchingSourceDraft = nil
    self.requestJustSet = self.body ~= nil
    self.request = copyRequest(request)
    self.selection = setOf(self.request.filter.ids)
    for _, id in ipairs(self.request.filter.types) do self.selection[id] = true end
    self.operationValue = self.request.destination.kind == "trash" and "clean"
        or (self.request.destination.kind == "inventory" and self.request.scope ~= "inventory" and "loot" or "move")
    self.selectorKindValue = #self.request.filter.types > 0 and "items" or "categories"
    self.searchDraft = ""
    if not self.request.filter.all then
        if #self.request.filter.types == 1 and #self.request.filter.ids == 0 then self.searchDraft = self.request.filter.types[1]
        elseif #self.request.filter.ids == 1 and #self.request.filter.types == 0 then self.searchDraft = self.request.filter.ids[1] end
    end
end

function Window:app()
    return getSpecificPlayer(self.playerIndex) and App.get(self.playerIndex) or nil
end

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    enableResize(self)
    self.collapseButton:setVisible(false)
    local navY, x = self:titleBarHeight() + GAP, GAP
    self.nav = {}
    local pages = { { "home", "Home", 82 }, { "compose", "Actions", 92 }, { "categories", "Categories", 112 },
        { "labels", "Labels", 88 }, { "help", "Help", 78 }, { "settings", "Settings", 92 } }
    for _, page in ipairs(pages) do
        local mode = page[1]
        self.nav[mode] = button(self, x, navY, page[3], page[2], self, function(s) s:show(mode) end,
            "Open " .. page[2]:lower() .. ".")
        x = x + page[3] + 6
    end
    self.jobTab = button(self, self.width - 135 - GAP, navY, 135, "Current job", self,
        function(s) UI.showProgress(s.playerIndex) end, "Show progress, pause, resume, or cancel the active job. Also available from LootBox right-click menus and the Current job key.")
    self.jobTab:setEnable(self:app() ~= nil)
    self.contentY = navY + H + GAP
    self:show(self.mode)
end

function Window:onResize()
    ISCollapsableWindow.onResize(self)
    if not self.body then return end
    place(self.jobTab, self.width - 135 - GAP)
    place(self.body, GAP, self.contentY, self.width - 2 * GAP, self.height - self.contentY - bottomInset(self))
    if self.body.layout then self.body.layout() end
end

function Window:rememberDraft()
    if self.mode ~= "compose" or not self.scope then return end
    local app = self:app()
    if not app then return end
    local request = self:readRequest(false)
    if not request then return end
    self.request = request
    self.operationValue, self.selectorKindValue, self.searchDraft = value(self.operation), value(self.selectorKind), self.search:getText()
    self.setupNameDraft = self.setupName:getText()
    if hasSelection(request) then
        local ok, err = app:rememberSetup(request)
        if not ok then
            self.draftError = "The setup could not be remembered: " .. tostring(err)
            UI.notices[self.playerIndex] = self.draftError
        end
    end
end

function Window:show(mode)
    if mode ~= "compose" and mode ~= "preview" then self.skipPreviewKey, self.skipPreviewDraft, self.skipPreviewInitial = nil, nil, nil end
    local replacing = self.requestJustSet
    self.requestJustSet = nil
    if not replacing then self:rememberDraft() end
    if mode == "compose" and not self:app() then mode = "home" end
    if self.mode == "categories" and self.categoryName then
        self.editorDefinition = { id = self.editor.id, name = self.categoryName:getText(),
            types = arrayOf(self.editor.types), includes = arrayOf(self.editor.includes) }
    end
    if self.body then W.unfocus(self.body); self:removeChild(self.body) end
    self.mode = mode
    self.body = ISPanel:new(GAP, self.contentY, self.width - 2 * GAP, self.height - self.contentY - bottomInset(self))
    self.body:initialise()
    self.body.background = false
    self:addChild(self.body)
    self.message, self.messagePanel = nil, nil
    for key, widget in pairs(self.nav) do
        widget.backgroundColor = W.color(key == mode and "raised" or "base")
        widget.textColor = W.color(key == mode and "accent" or "text")
    end
    if mode == "categories" then self:buildCategories()
    elseif mode == "labels" then self:buildLabels()
    elseif mode == "preview" then self:buildPreview()
    elseif mode == "help" then self:buildHelp()
    elseif mode == "settings" then self:buildSettings()
    elseif mode == "compose" then self:buildComposer()
    else self:buildHome() end
    if self.draftError or self.initialNotice then
        self:messageText(self.draftError or self.initialNotice)
        self.draftError, self.initialNotice, UI.notices[self.playerIndex] = nil, nil, nil
    end
end

function Window:messageText(text)
    self.message = tostring(text or "")
    if self.messagePanel then W.setText(self.messagePanel, self.message) end
end

function Window:catalog()
    local catalog, problem = App.catalog()
    self.catalogData = catalog or { items = {}, categories = {}, error = problem }
    return self.catalogData
end

function Window:openHelp(id)
    self.context.guide = id
    self:show("help")
end

function Window:useTask(id)
    local request, err = Guides.prepare(id, self:app(), self.context)
    if not request then self:messageText(err or "Enter a game to prepare this workflow."); return end
    self:setRequest(request)
    self.taskTitle = nil
    for _, task in ipairs(Guides.tasks) do
        if task.id == id then self.taskTitle, self.taskGuide = task.title, task.guide; break end
    end
    self:show("compose")
    self:messageText(hasSelection(request) and "Setup prepared. Review the source and destination, then Preview."
        or "Choose the categories or item types to look for, then Preview.")
end

function Window:buildHome()
    local body, app = self.body, self:app()
    W.heading(body, 0, 0, "What would you like to do?")
    local introduction = wrapped(body, 0, H + 2, body.width, H + 8, "Choose a workflow, continue a saved setup, or use right-click shortcuts in the world.")
    local tasks = {}
    for _, task in ipairs(Guides.tasks) do
        local id = task.id
        local action = button(body, 0, 0, 100, task.title, self, function(s) s:useTask(id) end, task.summary, "accent")
        action:setEnable(app ~= nil)
        tasks[#tasks + 1] = { action = action, summary = wrapped(body, 8, 0, 100, H + 3, task.summary) }
    end
    local savedHeading = W.heading(body, 0, 2 * H + GAP, "Your saved setups")
    local saved, savedError
    if app then saved, savedError = app:getSetups() else saved = { presets = {} } end
    local presets = saved and saved.presets or {}
    self.homeSetupList = list(body, 0, 3 * H + GAP, 100, 5 * H, self, function(s, row)
        s.selectedSetupId, s.setupNameDraft = row.id, row.name
        local request, err = s:app():loadSetup(row.id, s.context)
        if request then s:setRequest(request) end
        s:show("compose")
        if not request then s:messageText(err) end
    end)
    for _, preset in ipairs(presets) do self.homeSetupList:addItem(preset.name, preset,
        "Load this complete setup. Clicked containers bind to the current context; vehicles use your remembered car.") end
    local empty
    if #presets == 0 then
        empty = wrapped(body, 0, 3 * H + GAP + 10, 100, 4 * H,
            app and "No saved setups yet. Configure an action, give it a name, and choose Save new setup."
                or "Enter a game to save complete action setups. Categories and workflow guides are available now.")
    end
    local continueButton = button(body, 0, 8 * H + 2 * GAP, 100, "Continue last setup", self, function(s)
        local request, err = s:app():lastSetup(s.context)
        if not request then s:messageText(err or "No previous setup has been saved yet."); return end
        s:setRequest(request); s:show("compose")
    end, "Restore your last source, destination, item selection, and bag options.")
    continueButton:setEnable(app ~= nil and saved ~= nil and saved.lastSetup ~= nil)
    local firstRun = button(body, 0, 9 * H + 3 * GAP, 100, "Read the first-run guide", self,
        function(s) s:openHelp("first-run") end, "A complete introduction with expected results and where to start.", "custom")
    local categories = button(body, 0, 10 * H + 4 * GAP, 100, "Manage categories", self,
        function(s) s:show("categories") end, "Create reusable item groups and combine nested categories.")
    local tips
    if App.getPreferences().showTips then
        tips = wrapped(body, 0, 11 * H + 5 * GAP, 100, 3 * H,
            "Quick actions use the same planner as the full window. Transfer previews, cleanup previews and bin reviews are optional in Settings.")
    end
    self.messagePanel = wrapped(body, 0, 0, body.width, 2 * H, "")
    body.layout = function()
        local width = body.width
        local leftWidth, rightX = math.floor(width * 0.57), math.floor(width * 0.57) + 2 * GAP
        local rightWidth = width - rightX
        place(introduction, 0, H + 2, width)
        local step = math.max(H + 5, math.min(2 * H + 5, math.floor((body.height - 4 * H - GAP) / #tasks)))
        local y = 2 * H + GAP
        for _, task in ipairs(tasks) do
            place(task.action, 0, y, leftWidth)
            place(task.summary, 8, y + H, leftWidth - 8)
            task.summary:setVisible(step >= 2 * H + 3)
            y = y + step
        end
        place(savedHeading, rightX)
        place(self.homeSetupList, rightX, nil, rightWidth)
        place(empty, rightX + 10, nil, rightWidth - 20)
        place(continueButton, rightX, nil, rightWidth)
        place(firstRun, rightX, nil, rightWidth)
        place(categories, rightX, nil, rightWidth)
        place(tips, rightX, nil, rightWidth, math.max(H, body.height - (11 * H + 5 * GAP) - 2 * H))
        place(self.messagePanel, 0, body.height - 2 * H, width)
    end
    body.layout()
    if savedError then self:messageText(savedError) end
end

function Window:buildComposer()
    local body, width = self.body, self.body.width
    self:catalog()
    W.heading(body, 0, 0, self.taskTitle or "Move, loot or clean")
    local workflowHelp = button(body, width - 120, 0, 120, "Workflow help", self, function(s) s:openHelp(s.taskGuide or "first-run") end,
        "Read complete workflows and expected results.", "custom")
    local app = self:app()
    local saved, savedError = app:getSetups()
    self.setupPicker = combo(body, 0, H + GAP, math.floor(width * 0.65), self, Window.selectNamedSetup,
        "A saved setup includes the item selection, source, destination and bag options.")
    self.setupPicker:addOptionWithData("Choose a saved setup", false)
    for _, preset in ipairs(saved and saved.presets or {}) do self.setupPicker:addOptionWithData(preset.name, preset.id) end
    self.setupPicker:selectData(self.selectedSetupId or false)
    local loadSetup = button(body, math.floor(width * 0.65) + GAP, H + GAP, 110, "Load setup", self, Window.loadNamedSetup,
        "Load the selected setup and bind any clicked container to this context.")
    local col = math.floor((width - 2 * GAP) / 3)
    local headingY, rowY = 2 * H + 2 * GAP, 3 * H + 2 * GAP
    label(body, 0, headingY, "Task", true)
    local sourceHeading = label(body, col + GAP, headingY, "Where to look", true)
    local destinationHeading = label(body, 2 * (col + GAP), headingY, "Where items go", true)
    self.operation = combo(body, 0, rowY, col, self, function(s, widget)
        if value(widget) == "loot" then s.destination:selectData("inventory")
        elseif value(widget) == "clean" then s.destination:selectData("trash") end
        s:onDestinationChanged()
    end)
    self.operation:addOptionWithData("Move or sort items", "move", "Transfer a selection to a container, floor, labels or vehicle.")
    self.operation:addOptionWithData("Loot matching items", "loot", "Use Smart Load to fill carried bags first, then main inventory.")
    self.operation:addOptionWithData("Clean and delete items", "clean", "Haul selected items to real trash cans, then delete approved batches.")
    self.operation:selectData(self.operationValue or "move")
    self.scope = combo(body, col + GAP, rowY, col, self, function(s) s:onScopeChanged() end)
    local scopes = {
        { "My carried items", "inventory", "Items in your inventory. Bag contents are included when enabled below." },
        { "Within reach", "reach", "Loaded storage and floor locations currently accessible nearby." },
        { "Current room", "room", "Walk through the room you are standing in and inspect native sources." },
        { "Current building", "building", "Walk and search the building section by section across its floors. Unsearched areas and unconfirmed multiplayer sources stay visible." },
        { "A selected area", "area", "Choose two corners in the world on your current floor." },
        { "Containers with a label", "labeled", "Use known loaded containers with the selected label." },
    }
    for _, pair in ipairs(scopes) do self.scope:addOptionWithData(pair[1], pair[2], pair[3]) end
    if self.context.container or self.context.sourceContainer then self.scope:addOptionWithData("Container you clicked", "container", "Only the actual selected container supplies items.") end
    if self.request.scope == "lootPane" then self.scope:addOptionWithData("Captured loot-pane containers", "lootPane", "Only the sources captured for this request, still visible and accessible.") end
    self.scope:selectData(self.request.scope)
    self.destination = combo(body, 2 * (col + GAP), rowY, col, self, function(s) s:onDestinationChanged() end)
    self.destination:addOptionWithData("My inventory (Smart Load)", "inventory", "Fill eligible carried bags first, preferring useful weight reduction, then use main inventory. Existing contents and native capacity still matter.")
    self.destination:addOptionWithData("Floor at this location", "floor", "Explicitly drop items at the clicked tile or your current square.")
    if self.context.container or self.context.targetContainer then self.destination:addOptionWithData("Container you clicked", "container", "Store items in the container selected for this context.") end
    self.destination:addOptionWithData("My remembered vehicle", "vehicle", "Prefer its trunk, then available native seat and other storage.")
    self.destination:addOptionWithData("Matching labeled storage", "labels", "Store items where any matching category label says they belong.")
    self.destination:addOptionWithData("Matching item types", "matching", "Transfer only item types already represented in the displayed loot container or nearby containers.")
    self.destination:addOptionWithData("Known trash cans", "trash", "Fill native trash cans and delete batches. Optional reviews are controlled in Settings; current protection and native rules always apply.")
    self.destination:selectData(self.request.destination.kind)
    local optionsY = rowY + H + 7
    self.includeInventory = check(body, 0, optionsY, col, "Also use my carried items", self.request.includeInventory, self, nil,
        "Include carried items as sources alongside the room, area or other selected scope.")
    self.includeBags = check(body, col + GAP, optionsY, col, "Search inside bags", self.request.includeBags, self, nil,
        "Include nested contents in the selected sources. Native access rules still apply. Nonempty bags themselves remain protected.")
    self.endpoint = combo(body, 2 * (col + GAP), optionsY, col, self)
    local specificY = optionsY + H + 6
    self.areaButton = button(body, 0, specificY, 210, "Choose area in the world", self, Window.selectArea,
        "Click two corners. Escape or right-click cancels without replacing the old area.")
    self.areaSummary = wrapped(body, 220, specificY, col + GAP - 220 + col, H + 7, self.request.area
        and (tostring(math.abs(self.request.area.x2 - self.request.area.x1) + 1) .. " x " .. tostring(math.abs(self.request.area.y2 - self.request.area.y1) + 1)
            .. " tiles on floor " .. tostring(self.request.area.z)) or "No area selected yet.")
    self.sourceEndpoint = combo(body, 0, specificY, 2 * col + GAP, self)
    local sourceSeen = {}
    local sourceContainer = self.context.sourceContainer or self.context.container
    if sourceContainer then
        self.sourceEndpoint:addOptionWithData(containerName(sourceContainer), sourceContainer)
        sourceSeen[sourceContainer] = true
    end
    for _, container in ipairs(self.context.containers or {}) do
        if not sourceSeen[container] then
            self.sourceEndpoint:addOptionWithData(containerName(container), container)
            sourceSeen[container] = true
        end
    end
    self.sourceEndpoint:selectData(self.request.sourceContainer or self.context.sourceContainer or self.context.container)
    self.sourceLabel = combo(body, 0, specificY, 2 * col + GAP, self)
    self.sourceLabel:addOptionWithData("Choose the source container label", false)
    for _, category in ipairs(categoryRows(self.catalogData)) do self.sourceLabel:addOptionWithData(category.name, category.id, category.id) end
    self.sourceLabel:selectData(self.request.sourceLabels and self.request.sourceLabels[1] or false)
    local searchY = specificY + H + GAP
    self.selectorKind = combo(body, 0, searchY, 160, self, function(s) s:fillSelectionList() end)
    self.selectorKind:addOptionWithData("Choose categories", "categories", "Reusable groups, including nested custom categories.")
    self.selectorKind:addOptionWithData("Choose item types", "items", "Every eligible copy of each exact item type you select.")
    self.selectorKind:selectData(self.selectorKindValue or "categories")
    self.selectionGroup = combo(body, 170, searchY, 190, self, function(s) s:fillSelectionList() end)
    addGroups(self.selectionGroup)
    self.search = entry(body, 370, searchY, width - 370, self.searchDraft or "", self, function(s) s:fillSelectionList() end,
        "Search display names and exact IDs. Clear the search to browse other choices. Hover a row for details.", "Search names or exact IDs")
    local footerY, listY = body.height - 5 * H - GAP, searchY + H + 7
    self.selectionList = list(body, 0, listY, width, footerY - listY - GAP, self, function(s, row)
        s.selection[row.key] = not s.selection[row.key]
        s:refreshSelectionCount()
    end, self.selection)
    self.countLabel = label(body, 0, footerY, "")
    self.allItems = check(body, width - 260, footerY, 260, "All unprotected items", self.request.filter.all, self,
        function(s) s:refreshSelectionCount() end, "Select every eligible item. Keep, favorites and equipped items stay protected.")
    local saveY = footerY + H
    self.setupName = entry(body, 0, saveY, math.max(190, width - 620), self.setupNameDraft or "", nil, nil,
        "Name a reusable setup, for example Food to storage. Container targets bind to the container you click next time.", "Setup name, e.g. Food to storage")
    local saveX = self.setupName.width + GAP
    local saveSetup = button(body, saveX, saveY, 140, "Save new setup", self, function(s) s:saveNamedSetup(false) end,
        "Remember this whole workflow, not only the selected items.", "custom")
    self.updateSetupButton = button(body, saveX + 150, saveY, 105, "Update setup", self, function(s) s:saveNamedSetup(true) end,
        "Replace the selected saved setup with the current workflow.")
    self.updateSetupButton:setEnable(self.selectedSetupId ~= nil)
    self.deleteSetupButton = button(body, saveX + 265, saveY, 95, "Delete setup", self, Window.deleteNamedSetup,
        "Delete this saved setup only. Items and categories are unchanged.")
    self.deleteSetupButton:setEnable(self.selectedSetupId ~= nil)
    local preview = button(body, width - 330, saveY + H + 5, 160, "Preview job", self, Window.preview,
        "Explicitly inspect destinations, exclusions, capacity and deletion warnings before starting.")
    self.startButton = button(body, width - 160, saveY + H + 5, 160, "Start job", self, Window.start,
        "Plan against current items and start. Reviews appear only when you have enabled them in Settings.", "accent")
    local saveChecklist = button(body, 0, saveY + H + 5, 160, "Save loot checklist", self, Window.saveChecklist,
        "Remember only the item selection for Loot room and Loot area shortcuts.")
    local loadChecklist = button(body, 170, saveY + H + 5, 160, "Load loot checklist", self, Window.loadChecklist,
        "Replace the item selection while preserving the source and destination.")
    self.messagePanel = wrapped(body, 0, saveY + 2 * H + 8, width, 2 * H - 8, "")
    body.layout = function()
        local w, colWidth = body.width, math.floor((body.width - 2 * GAP) / 3)
        place(workflowHelp, w - 120)
        place(self.setupPicker, 0, nil, math.floor(w * 0.65))
        place(loadSetup, math.floor(w * 0.65) + GAP)
        place(sourceHeading, colWidth + GAP)
        place(destinationHeading, 2 * (colWidth + GAP))
        place(self.operation, 0, nil, colWidth)
        place(self.scope, colWidth + GAP, nil, colWidth)
        place(self.destination, 2 * (colWidth + GAP), nil, colWidth)
        place(self.includeInventory, 0, nil, colWidth)
        place(self.includeBags, colWidth + GAP, nil, colWidth)
        place(self.endpoint, 2 * (colWidth + GAP), nil, colWidth)
        place(self.areaSummary, 220, nil, 2 * colWidth + GAP - 220)
        place(self.sourceEndpoint, 0, nil, 2 * colWidth + GAP)
        place(self.sourceLabel, 0, nil, 2 * colWidth + GAP)
        place(self.search, 370, nil, w - 370)
        local footer = body.height - 5 * H - GAP
        place(self.selectionList, 0, listY, w, footer - listY - GAP)
        place(self.countLabel, 0, footer)
        place(self.allItems, w - 260, footer)
        local save = footer + H
        place(self.setupName, 0, save, math.max(190, w - 620))
        local sx = self.setupName.width + GAP
        place(saveSetup, sx, save)
        place(self.updateSetupButton, sx + 150, save)
        place(self.deleteSetupButton, sx + 265, save)
        place(preview, w - 330, save + H + 5)
        place(self.startButton, w - 160, save + H + 5)
        place(saveChecklist, 0, save + H + 5)
        place(loadChecklist, 170, save + H + 5)
        place(self.messagePanel, 0, save + 2 * H + 8, w)
    end
    body.layout()
    self:fillSelectionList()
    self:onScopeChanged()
    self:onDestinationChanged()
    if self.catalogData.error or savedError then self:messageText(self.catalogData.error or savedError) end
end

function Window:onScopeChanged()
    local scope = value(self.scope)
    self.areaButton:setVisible(scope == "area")
    self.areaSummary:setVisible(scope == "area")
    self.sourceEndpoint:setVisible(scope == "container")
    self.sourceLabel:setVisible(scope == "labeled")
    self.includeInventory:setVisible(scope ~= "inventory")
end

function Window:onDestinationChanged()
    local previous, previousKind = self.endpoint:getOptionData(self.endpoint.selected), self.endpointKind
    self.endpoint:clear()
    self.endpoint:setSelected(0)
    local kind = value(self.destination)
    self.endpointKind = kind
    local matching = kind == "matching"
    if matching then
        if not self.matchingSourceDraft then
            self.matchingSourceDraft = {scope = value(self.scope), includeBags = self.includeBags:isSelected(1),
                includeInventory = self.includeInventory:isSelected(1)}
        end
        self.scope:selectData("inventory")
        self.includeBags:setSelected(1, true)
        self.includeInventory:setSelected(1, false)
    elseif self.matchingSourceDraft then
        self.scope:selectData(self.matchingSourceDraft.scope)
        self.includeBags:setSelected(1, self.matchingSourceDraft.includeBags)
        self.includeInventory:setSelected(1, self.matchingSourceDraft.includeInventory)
        self.matchingSourceDraft = nil
    end
    self.scope:setEnabled(not matching)
    self.includeBags.enable = not matching
    self.includeBags.tooltip = matching and "Matching transfers always search every carried container, including nested bags."
        or "Include nested contents in the selected sources. Native access rules still apply. Nonempty bags themselves remain protected."
    for _, option in ipairs(self.scope.options) do
        if option.data == "inventory" then
            option.tooltip = matching and "Matching transfers always use all carried containers as their source."
                or "Items in your inventory. Bag contents are included when enabled below."
            break
        end
    end
    self:onScopeChanged()
    self.endpoint:setVisible(kind == "container" or kind == "vehicle" or kind == "labels" or matching)
    if self.startButton then
        self.startButton:setTitle(kind == "trash" and "Start cleanup" or "Start job")
        self.startButton.textColor = W.color(kind == "trash" and "danger" or "accent")
    end
    if kind == "container" then
        local targetSeen = {}
        local targetContainer = self.context.targetContainer or self.context.container
        if targetContainer then
            self.endpoint:addOptionWithData(containerName(targetContainer), targetContainer)
            targetSeen[targetContainer] = true
        end
        for _, container in ipairs(self.context.containers or {}) do
            if not targetSeen[container] then
                self.endpoint:addOptionWithData(containerName(container), container)
                targetSeen[container] = true
            end
        end
    elseif kind == "vehicle" then
        self.endpoint:addOptionWithData("Remembered vehicle", false, "Use the vehicle saved through Remember this vehicle.")
        for _, vehicle in ipairs(self:app():knownVehicles()) do self.endpoint:addOptionWithData(vehicleName(vehicle), vehicle, "Use this loaded vehicle for this job only.") end
        if self.context.vehicle then self.endpoint:addOptionWithData("Clicked " .. vehicleName(self.context.vehicle), self.context.vehicle) end
    elseif kind == "matching" then
        self.endpoint:addOptionWithData("All nearby containers", "nearby", "Match types already held by each nearby loot-window container. Items use the first matching destination with room.")
        self.endpoint:addOptionWithData("Displayed loot container", "displayed", "Match types already held by the currently displayed loot container.")
    elseif kind == "labels" then
        self.endpoint:addOptionWithData("Any matching category label", false, "Match any label assigned to the destination containers.")
        for _, category in ipairs(categoryRows(self.catalogData)) do self.endpoint:addOptionWithData(category.name, category.id, category.id) end
    end
    if self.request.destination.kind == kind then
        if kind == "container" or kind == "vehicle" then self.endpoint:selectData(self.request.destination.ref or false)
        elseif kind == "matching" then self.endpoint:selectData(self.request.destination.mode or "nearby")
        elseif kind == "labels" then self.endpoint:selectData(self.request.destination.labels and self.request.destination.labels[1] or false) end
    end
    if previousKind == kind and previous ~= nil then self.endpoint:selectData(previous) end
end

function Window:fillSelectionList()
    if not self.selectionList then return end
    self.selectionList:clear()
    local query, kind = string.lower(self.search:getText()), value(self.selectorKind)
    self.selectionGroup:setVisible(kind == "categories")
    if kind == "items" then
        for _, row in ipairs(self.catalogData.items) do
            if matchesSearch(row.name .. " " .. row.fullType, query) then
                self.selectionList:addItem(row.name, { key = row.fullType, segments = { { text = row.name, tone = "item" }, { text = row.fullType, tone = "muted" } } }, row.name .. "\nExact item type: " .. row.fullType .. "\nSelects every eligible copy of this type.")
            end
        end
    else
        for _, row in ipairs(categoryRows(self.catalogData)) do
            if categoryMatches(row, value(self.selectionGroup), self.selection) and matchesSearch(row.name .. " " .. row.id, query) then
                addCategoryRow(self.selectionList, row)
            end
        end
    end
    self:refreshSelectionCount()
end

function Window:refreshSelectionCount()
    if not self.countLabel or not self.allItems then return end
    local categories, items = 0, 0
    for _, key in ipairs(arrayOf(self.selection)) do
        if key:match("^native:") or key:match("^custom:") then categories = categories + 1 else items = items + 1 end
    end
    self.countLabel:setName(self.allItems:isSelected(1) and "All eligible items; protections still apply."
        or ("Selected categories: " .. tostring(categories) .. "   Item types: " .. tostring(items)))
end

function Window:readRequest(validate)
    local filter = { ids = {}, types = {}, all = self.allItems:isSelected(1) }
    for _, key in ipairs(arrayOf(self.selection)) do
        local into = (key:match("^native:") or key:match("^custom:")) and filter.ids or filter.types
        into[#into + 1] = key
    end
    local scope, kind = value(self.scope), value(self.destination)
    local request = { scope = scope, sourceContainer = value(self.sourceEndpoint) or self.context.sourceContainer or self.context.container,
        includeInventory = self.includeInventory:isSelected(1), includeBags = self.includeBags:isSelected(1),
        excludeUnwanted = self.request.excludeUnwanted == true,
        filter = filter, destination = { kind = kind } }
    if kind == "matching" then
        scope = "inventory"
        request.scope, request.includeInventory, request.includeBags = scope, false, true
    end
    if scope == "lootPane" then
        request.sourceContainers = copyRequest(self.request).sourceContainers
        request.includeInventory, request.includeBags = false, false
    end
    if scope == "labeled" then
        local id = value(self.sourceLabel)
        if not id and validate ~= false then return nil, "Choose which label the source containers must have." end
        request.sourceLabels = id and { id } or {}
    end
    if kind == "container" then
        request.destination.ref = value(self.endpoint)
        if not request.destination.ref and validate ~= false then return nil, "Open LootBox from the destination container first." end
    elseif kind == "matching" then request.destination.mode = value(self.endpoint) or "nearby"
    elseif kind == "vehicle" then request.destination.ref = value(self.endpoint) or nil
    elseif kind == "floor" then
        local player = getSpecificPlayer(self.playerIndex)
        request.destination.ref = self.context.square or (player and player:getSquare())
    elseif kind == "labels" and value(self.endpoint) then request.destination.labels = { value(self.endpoint) } end
    if scope == "area" then
        request.area = self.request.area
        if not request.area and validate ~= false then return nil, "Choose the area in the world before previewing." end
    end
    return request
end

function Window:loadNamedSetup()
    local id = value(self.setupPicker)
    if not id then self:messageText("Choose a saved setup first."); return end
    self:selectNamedSetup()
    local request, err = self:app():loadSetup(id, self.context)
    if not request then self:messageText(err); return end
    self.taskTitle, self.taskGuide = nil, nil
    self:setRequest(request)
    self:show("compose")
    self:messageText("Setup loaded. Review any context-bound container or saved area before starting.")
end

function Window:selectNamedSetup()
    local id = value(self.setupPicker)
    self.selectedSetupId, self.setupNameDraft = id or nil, ""
    local saved = self:app():getSetups()
    for _, preset in ipairs(saved and saved.presets or {}) do
        if preset.id == id then self.setupNameDraft = preset.name; break end
    end
    self.setupName:setText(self.setupNameDraft)
    self.updateSetupButton:setEnable(id ~= nil and id ~= false)
    self.deleteSetupButton:setEnable(id ~= nil and id ~= false)
end

function Window:saveNamedSetup(update)
    local request, err = self:readRequest(false)
    if not request then self:messageText(err); return end
    local name = self.setupName:getText()
    local selected = value(self.setupPicker)
    if update and not selected then self:messageText("Choose a saved setup to update."); return end
    local id
    id, err = self:app():saveSetup(name, request, update and selected or nil)
    if not id then self:messageText(err); return end
    self.request, self.selectedSetupId, self.setupNameDraft = request, id, name
    self:show("compose")
    self:messageText("Setup saved. Clicked containers bind to the new context when you reuse it.")
end

function Window:deleteNamedSetup()
    local id = value(self.setupPicker)
    if not id then self:messageText("Choose a saved setup to delete."); return end
    local ok, err = self:app():deleteSetup(id)
    if not ok then self:messageText(err); return end
    self.selectedSetupId, self.setupNameDraft = nil, ""
    self:show("compose")
    self:messageText("Saved setup deleted.")
end

function Window:saveChecklist()
    local request = self:readRequest(false)
    if not hasSelection(request) then self:messageText("Choose some categories or item types first."); return end
    local ok, err = self:app():setChecklist(request.filter)
    self:messageText(ok and "Loot checklist saved. Room and area loot shortcuts can reuse this selection." or err)
end

function Window:loadChecklist()
    local filter = self:app():getChecklist()
    self.selection = setOf(filter.ids)
    for _, id in ipairs(filter.types or {}) do self.selection[id] = true end
    self.selectionList.selection = self.selection
    self.allItems:setSelected(1, filter.all == true)
    self:fillSelectionList()
    self:messageText("Loot selection loaded. Your source and destination are unchanged.")
end

function Window:prepareAction(direct)
    local request, err = self:readRequest()
    if not request then self:messageText(err); return end
    if not hasSelection(request) then self:messageText("Choose categories, item types, or All unprotected items."); return end
    local app = self:app()
    local plan
    plan, err = app:preview(request)
    if not plan then self:messageText(err); return end
    self.request, self.plan = request, plan
    self.operationValue, self.selectorKindValue = value(self.operation), value(self.selectorKind)
    self.searchDraft, self.setupNameDraft = self.search:getText(), self.setupName:getText()
    local remembered, saveError = app:rememberSetup(request)
    local notice = not remembered and ("The setup could not be remembered: " .. tostring(saveError)) or nil
    local required, _, preferenceError = App.reviewPreference(request)
    if direct and not required then
        local ok
        ok, err = app:start(plan)
        if ok then W.unfocus(self.body); self:setVisible(false); UI.showProgress(self.playerIndex, notice); return end
        notice = "The job could not start: " .. tostring(err)
    elseif preferenceError then notice = "Review settings could not be read; this review is shown: " .. tostring(preferenceError) end
    self.requestJustSet = true
    self:show("preview")
    if notice then self:messageText(notice) end
end

function Window:preview() return self:prepareAction(false) end
function Window:start() return self:prepareAction(true) end

function Window:buildPreview()
    local body, plan = self.body, self.plan
    local moves, skipped = plan.moves or {}, plan.skipped or {}
    W.heading(body, 0, 0, self.request.destination.kind == "trash" and "Review cleanup and deletion" or "Review this job")
    local summary = label(body, 0, H + 4, tostring(#moves) .. (plan.building and " observed moves   " or " planned moves   ")
        .. tostring(#skipped) .. " stay here   " .. pendingSummary(plan))
    local description = wrapped(body, 0, 2 * H + 8, body.width, 2 * H,
        routeText(self.request) .. (self.request.destination.kind == "trash"
            and " The native trash command deletes the entire bin, including approved existing contents."
            or " Live capacity, access and item ownership are checked again during execution."))
    local rows = list(body, 0, 4 * H + GAP, body.width, body.height - 9 * H - 2 * GAP, self)
    reviewRows(rows, plan)
    local required, key = App.reviewPreference(self.request)
    if self.skipPreviewKey ~= key then self.skipPreviewDraft, self.skipPreviewInitial = not required, not required end
    if self.skipPreviewInitial == nil then self.skipPreviewInitial = not required end
    self.skipPreviewKey = key
    local choice = reviewChoices[key]
    local y = body.height - 4 * H
    self.skipPreviewCheck = check(body, 0, y + H + 3, body.width, choice.label, self.skipPreviewDraft,
        self, function(owner, index, selected) owner.skipPreviewDraft = selected == true end, choice.tooltip)
    self.skipPreviewCheck.initialReviewSelection = self.skipPreviewInitial
    local adjust = button(body, 0, y, 140, "Adjust setup", self, function(s) s:show("compose") end, "Return to the same source, item selection and destination.")
    self.runButton = button(body, body.width - 250, y, 250, self.request.destination.kind == "trash" and "Start cleanup and delete" or "Start job", self, function(s)
        local ok, err = s:app():start(s.plan)
        if not ok then s:messageText(err); return end
        local notice = rememberReviewChoice(s.skipPreviewCheck, s.skipPreviewKey)
        W.unfocus(s.body); s:setVisible(false); UI.showProgress(s.playerIndex, notice)
    end, self.request.destination.kind == "trash" and "Approve deletion of the reviewed items and existing bin contents." or "Begin native movement and transfers.",
        self.request.destination.kind == "trash" and "danger" or "accent")
    self.runButton:setEnable(#moves > 0 or (plan.pending or 0) > 0)
    if #moves == 0 and (plan.pending or 0) == 0 then self.runButton:setTooltip("Nothing eligible is planned. Read the exclusion reasons or adjust your setup.") end
    local skipReviews
    if self.request.destination.kind == "trash" and App.reviewPreference(nil, true) then
        skipReviews = button(body, body.width - 520, y, 260, "Start and skip bin reviews", self, function(s)
            local ok, err = s:app():start(s.plan, {reviewBins = false})
            if not ok then s:messageText(err); return end
            local notice = rememberReviewChoice(s.skipPreviewCheck, s.skipPreviewKey)
            W.unfocus(s.body); s:setVisible(false); UI.showProgress(s.playerIndex, notice)
        end, "Skip bin reviews for this job only. The checkbox remembers the separate preview choice for future actions. Protected items, permissions and native rules still apply.", "danger")
        skipReviews:setEnable(#moves > 0 or (plan.pending or 0) > 0)
    end
    self.messagePanel = wrapped(body, 0, y + 2 * H + 5, body.width, 2 * H - 5, "")
    body.layout = function()
        place(summary, 0, nil, body.width)
        place(description, 0, nil, body.width)
        place(rows, 0, 4 * H + GAP, body.width, body.height - 9 * H - 2 * GAP)
        local footer = body.height - 4 * H
        place(adjust, 0, footer)
        place(self.runButton, body.width - 250, footer)
        place(skipReviews, body.width - 520, footer)
        place(self.skipPreviewCheck, 0, footer + H + 3, body.width)
        place(self.messagePanel, 0, footer + 2 * H + 5, body.width)
    end
    body.layout()
end

function Window:buildCategories()
    local body, width = self.body, self.body.width
    local leftWidth = math.floor(width * 0.3)
    local rightX, rightWidth = leftWidth + GAP, width - leftWidth - GAP
    self:catalog()
    W.heading(body, 0, 0, "Reusable categories")
    local categoryGuide = button(body, width - 140, 0, 140, "Category guide", self, function(s) s:openHelp("categories") end,
        "Learn how to combine item types and nested categories.", "custom")
    self.categoryGroup = combo(body, 0, H + GAP, leftWidth, self, function(s) s:fillCategoryList() end)
    addGroups(self.categoryGroup)
    self.categorySearch = entry(body, 0, 2 * H + 2 * GAP, leftWidth, "", self, function(s) s:fillCategoryList() end,
        "Search category names or IDs. Custom categories are listed first.", "Find a category")
    local listY = 3 * H + 3 * GAP
    self.categoryList = list(body, 0, listY, leftWidth, body.height - listY - H - GAP, self, function(s, row)
        s:editCategory(row.definition)
    end)
    local newCategory = button(body, 0, body.height - H, leftWidth, "New custom category", self, function(s) s:editCategory(nil) end,
        "Create a reusable union of item types and categories. A clicked item type is included automatically.", "custom")
    local nameLabel = label(body, rightX, H + GAP, "Name your category", true)
    self.categoryName = entry(body, rightX, 2 * H + 2 * GAP, rightWidth, self.editor.name or "", self,
        function(s) s:updateMemberCount() end, "Use a name that describes your workflow, for example Run supplies.")
    self.memberKind = combo(body, rightX, listY, math.floor(rightWidth * 0.43), self, function(s) s:fillMemberList() end)
    self.memberKind:addOptionWithData("Include categories", "includes", "Select any number of game, mod or custom categories. Their contents form a union.")
    self.memberKind:addOptionWithData("Include item types", "types", "Include every copy of the exact item types you select.")
    self.memberSearch = entry(body, rightX + math.floor(rightWidth * 0.43) + GAP, listY,
        rightWidth - math.floor(rightWidth * 0.43) - GAP, "", self, function(s) s:fillMemberList() end, "Search member names or IDs.", "Search members")
    local memberY, footerY = listY + H + GAP, body.height - 4 * H - GAP
    self.memberList = list(body, rightX, memberY, rightWidth, footerY - memberY - GAP, self, function(s, row)
        if s.editor.native then return end
        local selected = s.editor[value(s.memberKind)]
        selected[row.key] = not selected[row.key]
        s:updateMemberCount()
    end, self.editor.includes)
    self.memberCount = label(body, rightX, footerY, "", true)
    self.saveCategoryButton = button(body, rightX, footerY + H, 150, "Save category", self, Window.saveCategory,
        "Save this category. Included categories remain linked and update as their contents change.", "custom")
    self.deleteCategoryButton = button(body, rightX + 160, footerY + H, 150, "Delete category", self, Window.deleteCategory,
        "Delete only an unused custom category. Referenced categories must be unlinked first.")
    self.messagePanel = wrapped(body, rightX, footerY + 2 * H + 4, rightWidth, 2 * H - 4, "")
    body.layout = function()
        local w, left = body.width, math.floor(body.width * 0.3)
        local right, available = left + GAP, w - left - GAP
        place(categoryGuide, w - 140)
        place(self.categoryGroup, 0, nil, left)
        place(self.categorySearch, 0, nil, left)
        place(self.categoryList, 0, listY, left, body.height - listY - H - GAP)
        place(newCategory, 0, body.height - H, left)
        place(nameLabel, right)
        place(self.categoryName, right, nil, available)
        local picker = math.floor(available * 0.43)
        place(self.memberKind, right, nil, picker)
        place(self.memberSearch, right + picker + GAP, nil, available - picker - GAP)
        local footer = body.height - 4 * H - GAP
        place(self.memberList, right, memberY, available, footer - memberY - GAP)
        place(self.memberCount, right, footer)
        place(self.saveCategoryButton, right, footer + H)
        place(self.deleteCategoryButton, right + 160, footer + H)
        place(self.messagePanel, right, footer + 2 * H + 4, available)
    end
    body.layout()
    self:fillCategoryList()
    self:editCategory(self.editorDefinition)
    if self.catalogData.error then self:messageText(self.catalogData.error) end
end

function Window:fillCategoryList()
    self.categoryList:clear()
    local query, group = string.lower(self.categorySearch:getText()), value(self.categoryGroup)
    local selected = self.editor.id and { [self.editor.id] = true } or {}
    for _, definition in ipairs(categoryRows(self.catalogData)) do
        if categoryMatches(definition, group, selected) and matchesSearch(definition.name .. " " .. definition.id, query) then
            addCategoryRow(self.categoryList, definition, { definition = definition })
            if definition.id == self.editor.id then self.categoryList.selected = #self.categoryList.items end
        end
    end
end

function Window:editCategory(definition)
    self.editorDefinition = definition
    self.editor = { id = definition and definition.id, name = definition and definition.name or "",
        types = setOf(definition and definition.types), includes = setOf(definition and definition.includes),
        native = definition and definition.id and string.find(definition.id, "native:", 1, true) == 1 }
    self.categoryList.selected = 0
    for index, row in ipairs(self.categoryList.items) do
        if row.item.definition.id == self.editor.id then self.categoryList.selected = index; break end
    end
    if not definition and self.context.item then self.editor.types[self.context.item:getFullType()] = true end
    self.categoryName:setText(self.editor.name)
    self.categoryName:setEditable(not self.editor.native)
    self.memberKind:setEnabled(not self.editor.native)
    if self.editor.native then self.memberKind:selectData("types") end
    self.saveCategoryButton:setEnable(not self.editor.native)
    self.deleteCategoryButton:setEnable(not self.editor.native and self.editor.id ~= nil)
    self:messageText(self.editor.native and "Game categories follow installed content. Create a custom category and include this one to extend it."
        or "Check categories or exact item types to include. Nested inclusions form a union; circular definitions are refused.")
    self:fillMemberList()
end

function Window:fillMemberList()
    if not self.memberList then return end
    self.memberList:clear()
    local kind = value(self.memberKind)
    if self.editor.native then self.memberList.selection = nil else self.memberList.selection = self.editor[kind] end
    local rows = kind == "types" and self.catalogData.items or categoryRows(self.catalogData)
    local query = string.lower(self.memberSearch:getText())
    for _, row in ipairs(rows) do
        local key = kind == "types" and row.fullType or row.id
        if key ~= self.editor.id and (not self.editor.native or row.categoryId == self.editor.id)
            and matchesSearch(row.name .. " " .. key, query) then
            if kind == "types" then self.memberList:addItem(row.name, { key = key, segments = { { text = row.name, tone = "item" }, { text = key, tone = "muted" } } }, row.name .. "\nExact item type: " .. key)
            else addCategoryRow(self.memberList, row) end
        end
    end
    self:updateMemberCount()
end

function Window:updateMemberCount()
    if not self.memberCount then return end
    local definitions = {}
    for _, definition in ipairs(self.catalogData.categories) do
        if definition.id:match("^custom:") and definition.id ~= self.editor.id then definitions[#definitions + 1] = definition end
    end
    local id = self.editor.id or "custom:editor-preview"
    if not self.editor.native then
        local name = self.categoryName:getText()
        definitions[#definitions + 1] = { id = id, name = name:find("%S") and name or "New category",
            types = arrayOf(self.editor.types), includes = arrayOf(self.editor.includes) }
    end
    local graph, err = Categories.new(definitions)
    if not graph then self.memberCount:setName("Check the category inclusions."); self.memberProblem = true; self:messageText(err); return end
    if self.memberProblem then self.memberProblem = false; self:messageText("") end
    local count = 0
    for _, item in ipairs(self.catalogData.items) do if graph:matches(id, item) then count = count + 1 end end
    self.memberCount:setName(tostring(count) .. " matching item types; nested categories stay linked.")
end

function Window:saveCategory()
    local id, err = App.saveCategory({ id = self.editor.id, name = self.categoryName:getText(),
        types = arrayOf(self.editor.types), includes = arrayOf(self.editor.includes) })
    if not id then self:messageText(err); return end
    self:catalog(); self:fillCategoryList()
    for _, definition in ipairs(self.catalogData.categories) do if definition.id == id then self:editCategory(definition); break end end
    self:messageText("Category saved. It is available in selections, storage labels, and item tags.")
end

function Window:deleteCategory()
    if not self.editor.id then return end
    local ok, err = App.deleteCategory(self.editor.id)
    if not ok then self:messageText(err); return end
    self:catalog(); self:fillCategoryList(); self:editCategory(nil)
    self:messageText("Custom category deleted.")
end

function Window:buildLabels()
    local body, width, app = self.body, self.body.width, self:app()
    W.heading(body, 0, 0, "Storage rules and item tags")
    local labelGuide = button(body, width - 130, 0, 130, "Label guide", self, function(s) s:openHelp("sorting") end,
        "A complete sorting workflow and the difference between types, copies, and Keep.", "custom")
    if not app then
        local explanation = wrapped(body, 0, 2 * H, width, 3 * H, "Enter a game and open LootBox from a container or item to edit its labels.")
        body.layout = function()
            place(labelGuide, body.width - 130)
            place(explanation, 0, nil, body.width)
        end
        return
    end
    local containers = self.context.containers or {}
    if #containers == 0 and self.context.container then containers = { self.context.container } end
    self.labelContainers = containers
    local mode = self.context.labelKind or (#containers > 0 and "container" or "item")
    self.labelKind = combo(body, 0, H + GAP, math.floor(width * 0.38), self, function(s)
        s.context.labelKind = value(s.labelKind); s:fillLabelTargets()
    end)
    if #containers > 0 then self.labelKind:addOptionWithData("Storage rules: what belongs here", "container", "Labels on a container route matching items into it during sorting.") end
    if self.context.item then self.labelKind:addOptionWithData("Item tags: only this copy", "item", "Add this particular item to categories without changing all copies of its type.") end
    self.labelKind:selectData(mode)
    self.labelTarget = combo(body, math.floor(width * 0.38) + GAP, H + GAP, width - math.floor(width * 0.38) - GAP, self,
        function(s) s:loadLabels() end)
    self.labelExplanation = wrapped(body, 0, 2 * H + 2 * GAP, width, 2 * H,
        "Choose whether you are describing storage or adding a tag to an individual item.")
    local searchY = 4 * H + 2 * GAP
    self.labelGroup = combo(body, 0, searchY, 240, self, function(s) s:fillLabelList() end)
    addGroups(self.labelGroup)
    self.labelSearch = entry(body, 250, searchY, width - 250, "", self, function(s) s:fillLabelList() end,
        "Search labels by name or ID. Check more than one category when several kinds of item belong here.", "Find a category to label")
    local listY, footerY = searchY + H + GAP, body.height - 5 * H - GAP
    self.labelList = list(body, 0, listY, width, footerY - listY - GAP, self, function(s, row)
        s.labelSelection[row.key] = not s.labelSelection[row.key]
        s:updateLabelCount()
    end, {})
    self.labelCount = label(body, 0, footerY, "", true)
    self.keep = check(body, 0, footerY + H, width - 280, "Keep this copy out of automatic movement and deletion", false, self, nil,
        "Keep applies to this individual item. Other copies can still be moved. Equipped, held and favorite items are also protected.")
    self.saveLabelsButton = button(body, 0, footerY + 2 * H, 180, "Save labels and Keep", self, Window.saveLabels,
        "Save checked category memberships and the Keep flag for the selected target.", "custom")
    local rememberVehicle, typeCategory
    if self.context.vehicle then
        rememberVehicle = button(body, 190, footerY + 2 * H, 230, "Remember this vehicle", self, function(s)
            local ok, err = app:rememberVehicle(s.context.vehicle)
            s:messageText(ok and "Vehicle remembered. Hauling prefers its trunk, then available native storage." or err)
        end, "Save this car as the destination of future hauling setups.", "accent")
    end
    if self.context.item then
        typeCategory = button(body, width - 260, footerY + H, 260, "Category for every copy of this type", self, function(s)
            s.editorDefinition = nil; s:show("categories")
        end, "Create a custom category prefilled with this exact item type, instead of tagging copies one by one.")
    end
    self.messagePanel = wrapped(body, 0, footerY + 3 * H + 4, width, 2 * H - 4, "")
    body.layout = function()
        local w, kindWidth = body.width, math.floor(body.width * 0.38)
        place(labelGuide, w - 130)
        place(self.labelKind, 0, nil, kindWidth)
        place(self.labelTarget, kindWidth + GAP, nil, w - kindWidth - GAP)
        place(self.labelExplanation, 0, nil, w)
        place(self.labelSearch, 250, nil, w - 250)
        local footer = body.height - 5 * H - GAP
        place(self.labelList, 0, listY, w, footer - listY - GAP)
        place(self.labelCount, 0, footer)
        place(self.keep, 0, footer + H, w - 280)
        place(self.saveLabelsButton, 0, footer + 2 * H)
        place(rememberVehicle, 190, footer + 2 * H)
        place(typeCategory, w - 260, footer + H)
        place(self.messagePanel, 0, footer + 3 * H + 4, w)
    end
    body.layout()
    self:catalog(); self:fillLabelTargets()
    if self.catalogData.error then self:messageText(self.catalogData.error) end
end

function Window:fillLabelTargets()
    local previous = value(self.labelTarget)
    self.labelTarget:clear()
    self.labelTarget:setSelected(0)
    if value(self.labelKind) == "item" and self.context.item then
        self.labelTarget:addOptionWithData(self.context.item:getName(), { kind = "item", ref = self.context.item },
            "Only this copy receives tags or Keep. Use a custom category to select every copy of its type.")
    elseif value(self.labelKind) == "container" then
        for _, container in ipairs(self.labelContainers) do
            self.labelTarget:addOptionWithData(containerName(container), { kind = "container", ref = container },
                "Matching items may be routed to this storage container when sorting.")
        end
    end
    if previous then
        for _, option in ipairs(self.labelTarget.options) do
            if option.data.kind == previous.kind and option.data.ref == previous.ref then
                self.labelTarget:selectData(option.data)
                break
            end
        end
    end
    self:loadLabels()
end

function Window:loadLabels()
    local target = value(self.labelTarget)
    self.saveLabelsButton:setEnable(target ~= nil)
    self.keep:setVisible(target ~= nil and target.kind == "item")
    if not target then self.labelList:clear(); self.labelCount:setName("No label target. Open LootBox from an item or storage container."); return end
    local app = self:app()
    self.labelSelection = setOf(target.kind == "item" and app:itemLabels(target.ref) or app:labels(target.ref))
    self.labelList.selection = self.labelSelection
    if target.kind == "item" then
        self.keep:setSelected(1, app:isKept(target.ref))
        W.setText(self.labelExplanation, "These tags add only " .. tostring(target.ref:getName()) .. " to categories. Keep separately protects this copy from automatic jobs.")
        self.saveLabelsButton:setTitle("Save tags and Keep")
    else
        W.setText(self.labelExplanation, "Checked categories describe what belongs in " .. containerName(target.ref)
            .. ". During sorting, an item can match any of these labels.")
        self.saveLabelsButton:setTitle("Save storage labels")
    end
    self:fillLabelList()
end

function Window:updateLabelCount()
    if self.labelCount then self.labelCount:setName("Selected labels: " .. tostring(#arrayOf(self.labelSelection)) .. ". Click a box to add or remove a label.") end
end

function Window:fillLabelList()
    if not self.labelList then return end
    self.labelList:clear()
    local query, group = string.lower(self.labelSearch:getText()), value(self.labelGroup)
    for _, category in ipairs(categoryRows(self.catalogData)) do
        if categoryMatches(category, group, self.labelSelection) and matchesSearch(category.name .. " " .. category.id, query) then
            addCategoryRow(self.labelList, category)
        end
    end
    self:updateLabelCount()
end

function Window:saveLabels()
    local target, app = value(self.labelTarget), self:app()
    if not target then return end
    local ok, err
    if target.kind == "container" then ok, err = app:setLabels(target.ref, arrayOf(self.labelSelection))
    else
        ok, err = app:setItemLabels(target.ref, arrayOf(self.labelSelection))
        if ok then ok, err = app:protect(target.ref, self.keep:isSelected(1)) end
    end
    self:messageText(ok and (target.kind == "container" and "Storage labels saved. Use Matching labeled storage to sort items here."
        or "Item tags and Keep saved. Other copies of this type are unchanged.") or err)
end

local function guideText(guide)
    local lines = { "<SIZE:medium> <RGB:0.835,0.694,0.427> " .. W.escape(guide.title) .. " <RGB:0.91,0.898,0.851> <SIZE:small> <LINE> <LINE> ", W.escape(guide.summary), " <LINE> <LINE> " }
    local function section(title, text)
        lines[#lines + 1] = "<RGB:0.59,0.77,0.82> " .. title .. " <RGB:0.91,0.898,0.851> <LINE> " .. W.escape(text) .. " <LINE> <LINE> "
    end
    if guide.prerequisites then section("Before you start", guide.prerequisites) end
    lines[#lines + 1] = "<RGB:0.59,0.77,0.82> Steps <RGB:0.91,0.898,0.851> <LINE> "
    for index, step in ipairs(guide.steps or {}) do lines[#lines + 1] = tostring(index) .. ". " .. W.escape(step) .. " <LINE> <LINE> " end
    if guide.expected then section("What success looks like", guide.expected) end
    if #(guide.troubleshooting or {}) > 0 then
        lines[#lines + 1] = "<RGB:0.59,0.77,0.82> If something blocks the job <RGB:0.91,0.898,0.851> <LINE> "
        for _, text in ipairs(guide.troubleshooting) do lines[#lines + 1] = "- " .. W.escape(text) .. " <LINE> <LINE> " end
    end
    return table.concat(lines)
end

function Window:buildHelp()
    local body, width = self.body, self.body.width
    W.heading(body, 0, 0, "Workflow field guide")
    label(body, 0, H + 4, "Complete workflows, expected results, and what to do when a job cannot continue.", true)
    local leftWidth, rightX = math.floor(width * 0.3), math.floor(width * 0.3) + GAP
    self.guideSearch = entry(body, 0, 2 * H + GAP, leftWidth, "", self, function(s) s:fillGuideList() end,
        "Search guide titles and workflow descriptions.", "Find a workflow")
    self.guideList = list(body, 0, 3 * H + 2 * GAP, leftWidth, body.height - 3 * H - 2 * GAP, self, function(s, row)
        s.context.guide = row.id; s:selectGuide(row.id)
    end)
    self.guidePanel = wrapped(body, rightX, 2 * H + GAP, width - rightX, body.height - 4 * H - 2 * GAP, "", true)
    self.guideSetupButton = button(body, rightX, body.height - H, width - rightX, "Set up this workflow", self, function(s)
        if s.currentGuide and s.currentGuide.task then s:useTask(s.currentGuide.task) end
    end, "Open the action composer with this workflow prepared. Nothing runs until you review and start it.", "accent")
    body.layout = function()
        local left = math.floor(body.width * 0.3)
        local right = left + GAP
        place(self.guideSearch, 0, nil, left)
        place(self.guideList, 0, 3 * H + 2 * GAP, left, body.height - 3 * H - 2 * GAP)
        place(self.guidePanel, right, 2 * H + GAP, body.width - right, body.height - 4 * H - 2 * GAP)
        place(self.guideSetupButton, right, body.height - H, body.width - right)
    end
    body.layout()
    self:fillGuideList()
    self:selectGuide(self.context.guide or "first-run")
end

function Window:fillGuideList()
    self.guideList:clear()
    local query = string.lower(self.guideSearch:getText())
    for _, guide in ipairs(Guides.list) do
        if matchesSearch(guide.title .. " " .. guide.summary, query) then self.guideList:addItem(guide.title, guide, guide.summary) end
    end
end

function Window:selectGuide(id)
    local guide = Guides.get(id) or Guides.list[1]
    if not guide then return end
    self.currentGuide = guide
    self.guideList.selected = 0
    for index, row in ipairs(self.guideList.items) do
        if row.item.id == guide.id then self.guideList.selected = index; break end
    end
    W.setText(self.guidePanel, guideText(guide), true)
    self.guideSetupButton:setEnable(self:app() ~= nil and guide.task ~= nil)
    self.guideSetupButton:setTooltip(guide.task and "Prepare the complete workflow in Actions. Review the choices before starting."
        or "This is a reference guide. Use the relevant manager page or right-click action described in its steps.")
end

local preferenceRows = {
    { key = "contextMenus", title = "Show LootBox in right-click menus", description = "Turn off the LootBox menu entry entirely. The full manager remains available in Options." },
    { key = "inventoryShortcuts", title = "Inventory and container shortcuts", description = "Show item actions, Select amount for stacks, and container contents actions for looting, emptying onto the floor, sorting, moving, cleanup, and labels. Use a container icon, a bag, or an empty pane." },
    { key = "worldShortcuts", title = "World storage, room and area shortcuts", description = "Show container transfers, storage labels, looting, area selection and cleanup in the world." },
    { key = "vehicleShortcuts", title = "Vehicle shortcuts", description = "Show vehicle memory, hauling and storage actions in the relevant context." },
    { key = "categoryShortcuts", title = "Category shortcuts", description = "Offer actions for categories relevant to the item you clicked." },
    { key = "savedShortcuts", title = "Saved setups in right-click menus", description = "Reuse your named setups from their current clicked context." },
    { key = "confirmQuickMoves", title = "Review quick transfers first", description = "Optional preview for ordinary quick transfers and the Start job button. Off starts directly after current item and capacity checks; Preview job always remains available." },
    { key = "confirmQuickCleanup", title = "Review quick cleanup first", description = "Optional deletion preview for quick cleanup and Start cleanup. Off lets those actions delete eligible items directly. Bin review has its own setting." },
    { key = "confirmBinReviews", title = "Review bins on arrival", description = "Optional contents approval at each newly inspected bin. Off approves eligible bins automatically. Protected items, permissions and native deletion rules still apply." },
    { key = "matchingTransferButtons", title = "Smart Take and all-container transfer buttons", description = "Add Smart Take All and Smart Take Matching beside native loot controls, plus Match Displayed and Match Nearby for matching transfers from all carried containers. Smart Take checks all carried bags and fills similar bags before other bags and main inventory." },
    { key = "smartTakeAllContainers", title = "Smart Take: all visible loot containers", description = "On by default. Smart Take All and Matching search eligible containers shown in the loot pane, including when the active container is empty. Off searches only the active container. Hidden containers and nested contents are not added." },
    { key = "showQuickProgress", title = "Open Current job for quick actions", description = "Show Progress after a direct quick action starts. Off keeps quick actions quiet; F7 and Current job still show their result. Important startup notices remain visible." },
    { key = "rememberLastSetup", title = "Remember my last action setup", description = "Restore the last source, destination, selection and bag options when continuing a setup." },
    { key = "showTips", title = "Show workflow tips", description = "Show additional guidance in the Home view. Tooltips and the Help field guide stay available." },
    { key = "tillFullEnabled", title = "Show Til Full in Eat and Drink", description = "Add Til Full beside native consumption amounts for the selected stack. Native restrictions still apply." },
    { key = "tillFullBothNeeds", title = "Til Full: satisfy both needs", description = "Off makes Eat restore hunger and Drink restore thirst, even when the item affects both. On targets both needs the item can restore and may consume beyond one already satisfied need. Native fullness limits still apply." },
    { key = "autoDrinkEquipped", title = "Drink from equipped vessels", description = "While idle and thirsty, use a safe drink in worn, held or belt-attached gear. Requires the game's Auto-Drink setting. Normal vanilla water drinking gets first chance." },
    { key = "autoConsumeCarried", title = "Eat and drink from carried supplies", description = "When hungry or thirsty and safe to stop, use one unprotected supply in your inventory or directly inside a carried bag. Drinking requires the game's Auto-Drink setting." },
    { key = "autoConsumeNested", title = "Carried supplies: search bags inside bags", description = "Only affects Eat and drink from carried supplies. Off searches one bag deep; on also checks bags nested inside your carried bags. Never searches the ground or nearby storage." },
    { key = "autoConsumeRiskyOpen", title = "Carried supplies: allow risky can opening", description = "If no eligible can opener is available, allow the game's sharp-tool recipe at a reachable work surface. It can damage the tool and cut your hand. Only affects automatic eating." },
    { key = "pourLootToLoot", title = "Pour Into: display loot-to-loot targets", description = "Off by default. When pouring from the selected reachable loot pane, also offer compatible vessels in that exact pane. Never searches nearby storage." },
    { key = "pourMostRoomFirst", title = "Fill All: most room left first", description = "Off fills the vessels with least room left first. On fills those with most room left first. Each inventory group is sorted separately." },
    { key = "pourEquippedFirst", title = "Fill All: equipped storage first", description = "Off fills main inventory first, then worn or held vessels and contents of equipped bags. On reverses these groups. Optional displayed loot destinations come last." },
    { key = "pourMainOnly", title = "Fill All: main inventory only", description = "Off includes equipped items and bags. On limits the batch to loose main-inventory vessels. Explicit individual targets remain available." },
    { key = "condenseButton", title = "Show Condense before Transfer All", description = "Add a Condense button to the inventory footer. It uses main inventory and eligible carried bags, independently of the pane you are viewing." },
    { key = "condenseRebalance", title = "Condense: optimize bag contents", description = "Off packs main-inventory items heaviest first into the best useful bags and leaves existing contents alone. On also redistributes contents and considers useful multi-item exchanges. Weight reduction comes first; at equal carried weight it groups matching types into fewer bags. It searches for an improvement, without promising a global optimum." },
    { key = "condenseUseUnequipped", title = "Condense: include unequipped bags", description = "Off leaves unequipped loot bags and their contents alone. On makes other carried bags eligible too. They are never automatically equipped, and their printed reduction does not apply while unequipped." },
    { key = "condenseNested", title = "Condense: include nested contents", description = "Allow nested contents within eligible carried bags to participate. Bag objects stay fixed. An inner bag uses its outer carried bag's actual reduction; the percentages do not multiply." },
}

local function wrapPreferenceDescription(text, width)
    local lines, current = {}, ""
    for word in text:gmatch("%S+") do
        local candidate = current == "" and word or current .. " " .. word
        if current ~= "" and getTextManager():MeasureStringX(UIFont.Small, candidate) > width then
            lines[#lines + 1], current = current, word
        else current = candidate end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

function Window:buildSettings()
    local body, width = self.body, self.body.width
    local preferences, err = App.getPreferences()
    W.heading(body, 0, 0, "Make LootBox fit your play style")
    local introduction = wrapped(body, 0, H + 4, width, 2 * H, "Choose which contextual shortcuts appear and how repeated workflows are remembered. These preferences are local to you.")
    introduction:removeScrollBars()
    introduction.vscroll = nil
    self.preferenceSelection = {}
    for _, row in ipairs(preferenceRows) do self.preferenceSelection[row.key] = preferences[row.key] == true end
    local viewport = list(body, 0, 0, width, H, self, function(s, row)
        if row.key then s.preferenceSelection[row.key] = not s.preferenceSelection[row.key]
        else s.preferenceViewport.selected = 0 end
    end, self.preferenceSelection)
    self.preferenceViewport = viewport
    viewport:addItem("Right-click shortcuts", {selectable = false, tone = "custom"})
    local rows = {}
    for index, row in ipairs(preferenceRows) do
        if index == 7 then viewport:addItem("Review and reuse", {selectable = false, tone = "custom"}) end
        if row.key == "autoDrinkEquipped" then viewport:addItem("Automatic food and drink", {selectable = false, tone = "custom"}) end
        if row.key == "pourLootToLoot" then viewport:addItem("Pour Into", {selectable = false, tone = "custom"}) end
        if row.key == "condenseButton" then viewport:addItem("Condense", {selectable = false, tone = "custom", condenseSection = true}) end
        rows[#rows + 1] = viewport:addItem(row.title, {key = row.key, description = row.description},
            row.title .. "\n" .. row.description)
    end
    introduction.onMouseWheel = function(_, delta) return viewport:onMouseWheel(delta) end
    local y = body.height - 3 * H
    local save = button(body, 0, y, 180, "Save preferences", self, Window.savePreferences,
        "Save only LootBox preferences. Other mods' Options settings are not reloaded.", "accent")
    self.messagePanel = wrapped(body, 0, y + H + 5, width, 2 * H - 5, err or "Changes apply to future actions. Toolbar visibility updates immediately.")
    body.layout = function()
        local scroll = viewport:getYScroll()
        place(introduction, 0, H + 4, body.width)
        introduction:paginate()
        local introductionHeight = math.max(2 * H, introduction:getScrollHeight())
        place(introduction, nil, nil, nil, introductionHeight)
        local top, footer = H + 4 + introductionHeight + GAP, body.height - 3 * H
        place(viewport, 0, top, body.width, footer - top - GAP)
        local detailWidth, fontHeight = math.max(1, viewport.width - 50), getTextManager():getFontHeight(UIFont.Small)
        for _, row in ipairs(rows) do
            row.item.details = wrapPreferenceDescription(row.item.description, detailWidth)
            row.height = H + #row.item.details * fontHeight + GAP
        end
        local contentHeight = 0
        for _, row in ipairs(viewport.items) do contentHeight = contentHeight + row.height end
        viewport:setScrollHeight(contentHeight)
        viewport:setYScroll(scroll)
        local saveWidth = math.max(180, getTextManager():MeasureStringX(UIFont.Small, "Save preferences") + 2 * GAP)
        place(save, 0, footer, saveWidth)
        place(self.messagePanel, 0, footer + H + 5, body.width)
    end
    body.layout()
    if self.context.settingsSection == "condense" then
        local offset = 0
        for _, row in ipairs(viewport.items) do
            if row.item.condenseSection then viewport:setYScroll(-offset); break end
            offset = offset + row.height
        end
    end
end

function Window:savePreferences()
    local nextPreferences = {}
    for _, row in ipairs(preferenceRows) do nextPreferences[row.key] = self.preferenceSelection[row.key] == true end
    local ok, err = App.setPreferences(nextPreferences)
    self:messageText(ok and "Preferences saved. Future actions use these choices; toolbar visibility updates immediately." or err)
end

function Window:close()
    self:rememberDraft()
    if self.areaPicker then self.areaPicker:finish(nil, false) end
    W.unfocus(self.body)
    self:setVisible(false)
    self:removeFromUIManager()
    UI.windows[self.playerIndex] = nil
end

function Window:selectArea()
    local player = getSpecificPlayer(self.playerIndex)
    if not player or not player:getCurrentSquare() or player:isDead() then self:messageText("Enter the world before choosing an area."); return end
    self.request = self:readRequest(false)
    self.operationValue, self.selectorKindValue, self.searchDraft = value(self.operation), value(self.selectorKind), self.search:getText()
    if self.areaPicker then self.areaPicker:finish(nil, false) end
    local picker = AreaPicker:new(self, self.playerIndex)
    picker:initialise(); picker:setWantKeyEvents(true); picker:setWantMouseEvents(true)
    W.unfocus(self.body)
    self:setVisible(false); self.areaPicker = picker; UI.areaPickers[self.playerIndex] = picker
    picker:addToUIManager(); picker:bringToTop()
end

function AreaPicker:new(window, playerIndex, callback)
    local o = ISPanel.new(self, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    o.window, o.playerIndex, o.callback = window, playerIndex or window.playerIndex, callback
    o.player = getSpecificPlayer(o.playerIndex)
    o.z = o.player:getCurrentSquare():getZ()
    o.background, o.border, o.hint = false, false, "Click the first corner of the area."
    return o
end

function AreaPicker:point()
    local x = math.floor(screenToIsoX(self.playerIndex, getMouseX(), getMouseY(), self.z))
    local y = math.floor(screenToIsoY(self.playerIndex, getMouseX(), getMouseY(), self.z))
    local square = getCell():getGridSquare(x, y, self.z)
    if not square or not square:getFloor() then return nil end
    return { x = x, y = y }
end

function AreaPicker:prerender()
    local point = self:point()
    if point then
        local first = self.first or point
        addAreaHighlightForPlayer(self.playerIndex, math.min(first.x, point.x), math.min(first.y, point.y),
            math.max(first.x, point.x) + 1, math.max(first.y, point.y) + 1, self.z, C.accent.r, C.accent.g, C.accent.b, 0.4)
    end
    local width = math.min(720, self.width - 40)
    local x = (self.width - width) / 2
    self:drawRect(x, 24, width, 2 * H + GAP, 0.97, C.base.r, C.base.g, C.base.b)
    self:drawRectBorder(x, 24, width, 2 * H + GAP, 1, C.accent.r, C.accent.g, C.accent.b)
    self:drawTextCentre(self.hint .. "  Floor " .. tostring(self.z), self.width / 2, 30, C.text.r, C.text.g, C.text.b, 1, UIFont.Small)
    self:drawTextCentre("Escape or right-click cancels. Nothing moves until review and Start.", self.width / 2, 30 + H,
        C.muted.r, C.muted.g, C.muted.b, 1, UIFont.Small)
end

function AreaPicker:update()
    if getSpecificPlayer(self.playerIndex) ~= self.player or self.player:isDead() then
        self:finish(nil, false)
        if self.window then self.window:close() end
    end
end

function AreaPicker:onMouseDown()
    local point = self:point()
    if not point then self.hint = "Choose a loaded floor tile."; return true end
    if self.first then self.last = point else self.first = point; self.hint = "Click the opposite corner." end
    return true
end

function AreaPicker:onMouseUp()
    if self.last then
        self:finish({ x1 = math.min(self.first.x, self.last.x), y1 = math.min(self.first.y, self.last.y),
            x2 = math.max(self.first.x, self.last.x), y2 = math.max(self.first.y, self.last.y), z = self.z }, true)
    end
    return true
end

function AreaPicker:onRightMouseDown() return true end
function AreaPicker:onRightMouseUp() self:finish(nil, true); return true end
function AreaPicker:isKeyConsumed(key) return key == Keyboard.KEY_ESCAPE end
function AreaPicker:onKeyPress(key)
    if self:isKeyConsumed(key) then self:finish(nil, true); GameKeyboard.eatKeyPress(key); return true end
    return false
end
function AreaPicker:onKeyRelease(key)
    if self:isKeyConsumed(key) then self:finish(nil, true); return true end
    return false
end

function AreaPicker:finish(area, restore)
    if self.closed then return end
    self.closed = true
    self:setVisible(false); self:removeFromUIManager()
    UI.areaPickers[self.playerIndex] = nil
    if self.window then
        self.window.areaPicker = nil
        if area then self.window.request.area = area end
        if restore then
            self.window:show("compose"); self.window:setVisible(true); self.window:bringToTop()
            self.window:messageText(area and "Area selected. Preview its matching items before starting." or "Area selection cancelled; the previous area is retained.")
        end
    elseif restore and self.callback then self.callback(area) end
end

function QuickReview:new(playerIndex, context, request, plan, notice)
    local availableHeight = getCore():getScreenHeight() - 80
    local width, height = math.min(650, getCore():getScreenWidth() - 40), math.min(520, availableHeight)
    local o = ISCollapsableWindow.new(self, (getCore():getScreenWidth() - width) / 2,
        (getCore():getScreenHeight() - height) / 2, width, height)
    o.playerIndex, o.context, o.request, o.plan, o.notice = playerIndex, context, request, plan, notice
    o.title = context.condense and "LootBox - review Condense" or context.binReview and "LootBox - review bin contents"
        or (request.destination.kind == "trash" and "LootBox - review deletion" or "LootBox - quick action")
    o.resizable, o.backgroundColor, o.borderColor = true, W.color("base"), W.color("border")
    local minimumHeight = math.max(440, o:titleBarHeight() + (request.destination.kind == "trash" and 12 or (context.condense and 11 or 10)) * H + 3 * GAP + bottomInset(o))
    o.minimumWidth, o.minimumHeight = math.min(540, width), math.min(minimumHeight, availableHeight)
    o:setHeight(math.max(height, o.minimumHeight))
    o:setY((getCore():getScreenHeight() - o.height) / 2)
    return o
end

function QuickReview:createChildren()
    ISCollapsableWindow.createChildren(self)
    enableResize(self)
    self.collapseButton:setVisible(false)
    local y, width = self:titleBarHeight() + GAP, self.width - 2 * GAP
    local moves, skipped, pending = #(self.plan.moves or {}), #(self.plan.skipped or {}), self.plan.pending or 0
    local binReview = self.context.binReview
    local condense = self.context.condense and self.plan.condense or nil
    local trash = self.request.destination.kind == "trash"
    local showSkip = trash and (binReview ~= nil or App.reviewPreference(nil, true))
    local footerRows = showSkip and 6 or 5
    local heading = W.heading(self, GAP, y, condense and condenseMode(condense) or binReview and ("Use " .. tostring(self.plan.bin.name) .. " for cleanup?")
        or (tostring(moves) .. (self.plan.building and " observed moves" or " planned moves")))
    if binReview then heading.r, heading.g, heading.b = C.item.r, C.item.g, C.item.b end
    local summary = label(self, GAP, y + H, condense and pendingSummary(self.plan) or binReview and (tostring(moves + skipped) .. " existing items observed   "
        .. (skipped > 0 and tostring(skipped) .. " protected - approval blocked" or "Job waiting for your choice"))
        or (tostring(skipped) .. " stay here   " .. pendingSummary(self.plan)), true)
    if binReview and skipped > 0 then summary.r, summary.g, summary.b = C.warning.r, C.warning.g, C.warning.b end
    local description = condense and condenseDescription(condense) or routeText(self.request)
    if binReview then
        local bin, point = self.plan.bin, self.plan.bin.point
        description = "Floor " .. tostring(point.z) .. " at " .. tostring(point.x) .. ", " .. tostring(point.y)
        if bin.capacity and bin.used then
            description = description .. string.format("   Observed load %.1f / %.1f   Free %.1f", bin.used, bin.capacity, math.max(0, bin.capacity - bin.used))
        end
        description = description .. "\n" .. (bin.routing or "Approve this destination, or try another bin while keeping the current job.")
    end
    local descriptionHeight = (binReview or condense) and 3 * H or 2 * H
    local descriptionPanel = wrapped(self, GAP, y + 2 * H, width, descriptionHeight, description)
    local listY, footerY = y + 2 * H + descriptionHeight + GAP, self.height - footerRows * H - bottomInset(self)
    self.rows = list(self, GAP, listY, width, footerY - listY - GAP, self)
    reviewRows(self.rows, self.plan)
    if moves == 0 and pending == 0 and skipped == 0 then
        self.rows:addItem(condense and (condense.reason or "No useful arrangement was found for the current eligible bags.")
            or (binReview and "No existing items are currently observed in this bin." or "No eligible matching items were observed."), { tone = "muted" },
            binReview and "This is a client observation. Multiplayer cannot certify an empty bin or make shared-bin deletion atomic."
                or "Adjust the item selection or source. Unopened multiplayer sources may remain unconfirmed.")
    end
    local required, key = App.reviewPreference(self.request, binReview ~= nil)
    local choice = reviewChoices[key]
    self.skipPreviewKey = key
    local selected, initial
    if self.context.skipPreviewKey == key then selected, initial = self.context.skipPreviewDraft, self.context.skipPreviewInitial end
    if selected == nil then selected = not required end
    if initial == nil then initial = not required end
    self.skipPreviewCheck = check(self, GAP, footerY + (showSkip and 2 or 1) * H + 8, width, choice.label, selected,
        self, nil, choice.tooltip)
    self.skipPreviewCheck.initialReviewSelection = initial
    local backButton = button(self, GAP, footerY, 100, binReview and "Back" or "Cancel", self, function(s) s:close() end,
        binReview and "Close this window and leave the current job paused for review." or "Close this review without starting a job.")
    local adjustButton = button(self, GAP + 110, footerY, (binReview or condense) and 145 or 115,
        condense and "Condense settings" or (binReview and "Try another bin" or "Adjust setup"), self, function(s)
        if s.context.condense then
            s:close(); UI.open(s.playerIndex, {settingsSection = "condense"}, "settings")
            return
        end
        if s.context.binReview then
            local app, problem = App.get(s.playerIndex)
            if not app then W.setText(s.messagePanel, problem); return end
            local ok, err = app:rejectBin(s.context.binReview)
            if not ok then W.setText(s.messagePanel, err); return end
            s:close(); UI.showProgress(s.playerIndex)
            return
        end
        local context = {}
        for k, v in pairs(s.context or {}) do context[k] = v end
        context.request = s.request
        context.skipPreviewKey, context.skipPreviewDraft = s.skipPreviewKey, s.skipPreviewCheck:isSelected(1)
        context.skipPreviewInitial = s.skipPreviewCheck.initialReviewSelection
        s:close(); UI.open(s.playerIndex, context, "compose")
    end, condense and "Choose packing mode and eligible bags. Press Condense again afterward for a fresh plan."
        or (binReview and "Skip this bin and let the current job try another eligible destination." or "Open the full manager with this exact setup."))
    local runText = condense and "Start Condense" or binReview and "Approve bin and continue" or (trash and "Start cleanup and delete" or "Start quick job")
    self.runButton = button(self, self.width - GAP - 240, footerY, 240, runText, self, function(s)
        local app, problem = App.get(s.playerIndex)
        if not app then W.setText(s.messagePanel, problem); return end
        local ok, err
        if s.context.binReview then ok, err = app:approveBin(s.context.binReview, s.skipPreviewCheck:isSelected(1) and {reviewBins = false} or nil)
        else ok, err = app:start(s.plan) end
        if not ok then W.setText(s.messagePanel, err); return end
        local note = rememberReviewChoice(s.skipPreviewCheck, s.skipPreviewKey, s.notice)
        s:close(); UI.showProgress(s.playerIndex, note)
    end, binReview and "Approve native whole-bin deletion of these observed existing contents and the selected items delivered by this job."
        or (trash and "Approve whole-bin deletion of the reviewed items, including the listed existing contents." or "Start this reviewed native job."), trash and "danger" or "accent")
    self.runButton:setEnable(binReview and self.plan.canApprove == true or (not binReview and (moves > 0 or pending > 0)))
    if showSkip then
        self.skipReviewsButton = button(self, GAP, footerY + H + 5, width,
            binReview and "Approve and skip further bin reviews" or "Start and skip bin reviews", self, function(s)
                local app, problem = App.get(s.playerIndex)
                if not app then W.setText(s.messagePanel, problem); return end
                local ok, err
                if s.context.binReview then ok, err = app:approveBin(s.context.binReview, {reviewBins = false})
                else ok, err = app:start(s.plan, {reviewBins = false}) end
                if not ok then W.setText(s.messagePanel, err); return end
                local note = rememberReviewChoice(s.skipPreviewCheck, s.skipPreviewKey, s.notice)
                s:close(); UI.showProgress(s.playerIndex, note)
            end, "Skip bin reviews for this job only. Use the checkbox to remember your review choice for future jobs. Every bin is still inspected and protected items, changed contents and native rules can block it.", "danger")
        self.skipReviewsButton:setEnable(binReview and self.plan.canApprove == true or (not binReview and (moves > 0 or pending > 0)))
    end
    self.messagePanel = wrapped(self, GAP, footerY + (showSkip and 3 or 2) * H + 8, width, 3 * H - 8,
        self.notice or (condense and (condense.reason or "Condense checks one arrangement at a time. Optimization may temporarily use main inventory. Native working-space limits and protected items remain respected.")
            or (binReview and "Approve permits whole-bin deletion of the observed contents above and items this job delivers. The job keeps its selection and search progress. Protected or changed contents block approval. Back leaves the job waiting."
            or (trash and "Deletion is permanent. The native trash command empties the entire bin; protected or new unapproved contents block deletion."
            or "Capacity, access and item ownership are rechecked while the job runs."))))
    self.layout = function()
        local w = self.width - 2 * GAP
        local footer = self.height - footerRows * H - bottomInset(self)
        place(heading, GAP, nil, w)
        place(summary, GAP, nil, w)
        place(descriptionPanel, GAP, nil, w)
        place(self.rows, GAP, listY, w, footer - listY - GAP)
        place(backButton, GAP, footer)
        place(adjustButton, GAP + 110, footer)
        place(self.runButton, self.width - GAP - 240, footer)
        place(self.skipReviewsButton, GAP, footer + H + 5, w)
        place(self.skipPreviewCheck, GAP, footer + (showSkip and 2 or 1) * H + 8, w)
        place(self.messagePanel, GAP, footer + (showSkip and 3 or 2) * H + 8, w)
    end
    self.layout()
end

function QuickReview:onResize()
    ISCollapsableWindow.onResize(self)
    if self.layout then self.layout() end
end

function QuickReview:close()
    self:setVisible(false); self:removeFromUIManager()
    UI.quickWindows[self.playerIndex] = nil
end

function Progress:new(playerIndex)
    local availableHeight = getCore():getScreenHeight() - 100
    local width, height = math.min(640, getCore():getScreenWidth() - 40), math.min(480, availableHeight)
    local o = ISCollapsableWindow.new(self, 20, 80, width, height)
    o.playerIndex, o.title, o.resizable = playerIndex, "LootBox - current job", true
    local minimumHeight = math.max(410, o:titleBarHeight() + 10 * H + 3 * GAP + bottomInset(o))
    o.minimumWidth, o.minimumHeight = math.min(520, width), math.min(minimumHeight, availableHeight)
    o:setHeight(math.max(height, o.minimumHeight))
    o.backgroundColor, o.borderColor = W.color("base"), W.color("border")
    return o
end

function Progress:createChildren()
    ISCollapsableWindow.createChildren(self)
    enableResize(self)
    self.collapseButton:setVisible(false)
    local y = self:titleBarHeight() + GAP
    self.statusLabel = W.heading(self, GAP, y, "")
    self.countLabel = label(self, GAP, y + H, "")
    self.surveyPanel = wrapped(self, GAP, y + 2 * H, self.width - 2 * GAP, 2 * H, "")
    self.reasonPanel = wrapped(self, GAP, y + 4 * H, self.width - 2 * GAP, 3 * H, "")
    self.listY = y + 7 * H + GAP
    self.reasonsList = list(self, GAP, self.listY, self.width - 2 * GAP, H, self)
    self.reasonCount, self.surveyReasonRows = 0, {}
    self.cancelButton = button(self, GAP, 0, 100, "Cancel job", self, function(s) App.get(s.playerIndex):cancel() end,
        "Stop owned work and discard this job after native cleanup. Use Pause to keep resumable work. Sent trash commands cannot be recalled.", "danger")
    self.pauseButton = button(self, GAP, 0, 100, "Pause job", self, function(s)
        local ok, err = App.get(s.playerIndex):pause()
        if not ok then s.notice = err else s.notice = nil end
    end, "Pause safely after any in-flight native action settles. Deal with a threat, then choose Resume job.", "accent")
    self.resumeButton = button(self, GAP, 0, 100, "Resume job", self, function(s)
        local ok, err = App.get(s.playerIndex):resume()
        if not ok then s.notice = err else s.notice = nil end
    end, "Continue the stopped job from its remaining work. Current items, access, and deletion approvals are checked again.", "success")
    self.reviewBinButton = button(self, GAP, 0, 100, "Review bin", self,
        function(s) UI.showBinReview(s.playerIndex) end, "Check the inspected bin, approve whole-bin deletion, or try another destination.", "accent")
    self.openManagerButton = button(self, GAP, 0, 100, "Open manager", self, function(s) UI.open(s.playerIndex) end,
        "Open the full manager without cancelling this job.")
    self.recoverButton = button(self, GAP, 0, 100, "Recover gear", self, function(s)
        local ok, err = App.get(s.playerIndex):recoverPersonalGear()
        if not ok then s.notice = err else s.notice = nil end
    end, "Return personal items temporarily stored for a heavy haul. Recovery checks the original containers and equipment slots.", "success")
    self.footer = wrapped(self, GAP, 0, self.width - 2 * GAP, H, "Closing hides this panel. Running jobs continue.")
    self.resumeButton:setVisible(false)
    self.pauseButton:setVisible(false)
    self.reviewBinButton:setVisible(false)
    self.recoverButton:setVisible(false)
    self:layoutControls()
end

function Progress:layoutControls()
    if not self.reasonsList then return end
    local width, footer = self.width - 2 * GAP, self.height - 2 * H - bottomInset(self)
    place(self.countLabel, GAP, nil, width)
    place(self.surveyPanel, GAP, nil, width)
    place(self.reasonPanel, GAP, nil, width)
    place(self.reasonsList, GAP, self.listY, width, footer - self.listY - GAP)
    local buttons = { self.cancelButton }
    if self.showPause then buttons[#buttons + 1] = self.pauseButton end
    if self.showResume then buttons[#buttons + 1] = self.resumeButton end
    if self.showBinReview then buttons[#buttons + 1] = self.reviewBinButton end
    if self.showRecovery then buttons[#buttons + 1] = self.recoverButton end
    buttons[#buttons + 1] = self.openManagerButton
    local buttonWidth = math.floor((width - (#buttons - 1) * GAP) / #buttons)
    for index, widget in ipairs(buttons) do place(widget, GAP + (index - 1) * (buttonWidth + GAP), footer, buttonWidth) end
    place(self.footer, GAP, footer + H + 3, width, H - 3)
end

function Progress:onResize()
    ISCollapsableWindow.onResize(self)
    self:layoutControls()
end

function Progress:update()
    ISCollapsableWindow.update(self)
    if not getSpecificPlayer(self.playerIndex) then self:close(); return end
    local app = App.get(self.playerIndex)
    local status = app:status()
    local condense = status.condense
    self.statusLabel:setName(status.waiting and "Waiting for your action"
        or (status.intent == "pour" and status.state == "running" and "Pouring"
            or condense and status.state == "running" and "Condensing" or states[status.state] or "Working"))
    local color = status.state == "failed" and C.danger
        or ((status.state == "pausing" or status.state == "paused" or status.state == "cancelled" or status.state == "needs_review" or status.waiting) and C.warning)
        or (status.state == "running" and C.accent or C.success)
    self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = color.r, color.g, color.b
    local counts = tostring(status.done or 0) .. ((status.cleared or 0) > 0 and " processed of " or " moved of ") .. tostring(status.total or 0)
    if status.intent == "pour" then
        counts = string.format("%d of %d vessels | %.3f L confirmed",status.done or 0,status.total or 0,status.pourLiters or 0)
    elseif condense then
        counts = tostring(condense.itemsMoved or 0) .. " items reorganized   " .. tostring(condense.transfers or 0) .. " transfers"
    elseif (status.cleared or 0) > 0 then
        counts = counts .. "   " .. tostring(status.moved or 0) .. " moved, " .. tostring(status.cleared) .. " cleared in place"
    end
    self.countLabel:setName(counts .. "   " .. tostring(status.skipped or 0) .. " notes to review")
    local survey = status.survey
    self.surveyPanel.textColor = W.color(condense and "item" or "text")
    if condense then
        W.setText(self.surveyPanel, condenseMode(condense)
            .. string.format("\nCurrent carried weight %.2f; started at %.2f.", condense.currentWeight or 0, condense.beforeWeight or 0))
    else
        W.setText(self.surveyPanel, survey and ("Rooms processed " .. tostring(survey.roomsDone) .. " of " .. tostring(survey.roomsTotal)
            .. ". Sections searched " .. tostring(survey.sectionsSearched) .. ", unsearched " .. tostring(survey.sectionsUnsearched) .. ".") or "")
    end
    local text = status.waiting or status.reason or ""
    if condense then
        local saved = condense.saved or 0
        text = text .. (text ~= "" and "\n" or "") .. (saved < 0
            and string.format("Temporary increase from rearrangement: %.2f.", -saved)
            or string.format("Estimated reduction from transfers: %.2f.", saved))
        if (condense.buffered or 0) > 0 then
            text = text .. " " .. tostring(condense.buffered) .. " working-space items remain in carried storage."
            if status.state ~= "running" then text = text .. " Resume to finish the arrangement." end
        end
        if condense.limited then text = text .. " Search is bounded; this is the best improvement found." end
    end
    if status.routing then text = text .. (text ~= "" and "\n" or "") .. "Destination choice: " .. status.routing end
    if self.notice then text = text .. (text ~= "" and "\n" or "") .. self.notice end
    local recovery = app:recoveryStatus()
    if recovery.pending then
        text = text .. (text ~= "" and "\n" or "") .. "Personal gear recovery: " .. tostring(recovery.count or 0) .. " items"
        if recovery.location then text = text .. " at " .. recovery.location end
        if recovery.reason then text = text .. ". " .. recovery.reason end
    end
    W.setText(self.reasonPanel, text)
    local reasons = status.reasons or {}
    if self.reasonSource ~= status.reasons then
        self.reasonsList:clear()
        self.reasonSource, self.reasonCount, self.surveyReasonRows = status.reasons, 0, {}
    end
    for index = self.reasonCount + 1, #reasons do
        local row = reasons[index]
        detailRow(self.reasonsList, row.itemName, row.status or "Note", row.reason or "No destination", row.tone or "warning")
    end
    self.reasonCount = #reasons
    for _, room in ipairs(survey and survey.unsearchedRooms or {}) do
        local id = room.roomId
        local name, reason = tostring(room.roomName) .. " / floor " .. tostring(room.z), tostring(room.reason)
        local row = self.surveyReasonRows[id]
        if row then
            row.text, row.tooltip = name .. "   Unsearched   " .. reason, name .. "   Unsearched   " .. reason
            row.item.segments[3].text = reason
        else self.surveyReasonRows[id] = detailRow(self.reasonsList, name, "Unsearched", reason, "danger") end
    end
    self.showResume, self.showPause = status.canResume == true, status.canPause == true
    self.showBinReview, self.showRecovery = status.state == "needs_review", recovery.pending == true
    self.pauseButton:setVisible(self.showPause)
    self.pauseButton:setEnable(self.showPause)
    self.resumeButton:setVisible(self.showResume)
    self.resumeButton:setEnable(self.showResume)
    self.reviewBinButton:setVisible(self.showBinReview)
    self.reviewBinButton:setEnable(self.showBinReview)
    self.recoverButton:setVisible(self.showRecovery)
    self.recoverButton:setEnable(self.showRecovery and not status.canPause and status.state ~= "cancelling" and status.state ~= "pausing")
    self.cancelButton:setEnable(status.state == "running" or status.state == "cancelling" or status.state == "needs_review" or status.state == "paused")
    self:layoutControls()
end

function Progress:close()
    self:setVisible(false); self:removeFromUIManager()
    UI.progressWindows[self.playerIndex] = nil
end

function UI.open(playerIndex, context, mode)
    playerIndex = playerIndex or 0
    local previous = UI.windows[playerIndex]
    if previous then previous:close() end
    local window = Window:new(playerIndex, context, mode)
    window:initialise(); window:addToUIManager()
    UI.windows[playerIndex] = window
    return window
end

function UI.showProgress(playerIndex, notice)
    playerIndex = playerIndex or 0
    local window = UI.progressWindows[playerIndex]
    if not window then window = Progress:new(playerIndex); window:initialise(); window:addToUIManager(); UI.progressWindows[playerIndex] = window end
    if notice then window.notice = notice end
    window:setVisible(true); window:bringToTop()
    return window
end

function UI.showBinReview(playerIndex)
    playerIndex = playerIndex or 0
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    local status = app:status()
    UI.reviewVisits[playerIndex] = {app = app, id = status.reviewId}
    local current = UI.quickWindows[playerIndex]
    if current and current.context.binReview and current.context.reviewApp == app and current.context.reviewId == status.reviewId then
        current:setVisible(true); current:bringToTop()
        return current
    end
    local plan
    plan, err = app:reviewBin()
    if not plan then UI.showProgress(playerIndex, err); return nil, err end
    if UI.windows[playerIndex] then W.unfocus(UI.windows[playerIndex].body) end
    if UI.quickWindows[playerIndex] then UI.quickWindows[playerIndex]:close() end
    local request = {scope = "inventory", filter = {all = true, ids = {}, types = {}}, destination = {kind = "trash"}}
    local review = QuickReview:new(playerIndex, {binReview = plan, reviewId = status.reviewId, reviewApp = app}, request, plan)
    review:initialise(); review:addToUIManager()
    UI.quickWindows[playerIndex] = review
    return review
end

function UI.quickAction(playerIndex, context, request, pickArea)
    playerIndex, context, request = playerIndex or 0, context or {}, copyRequest(request)
    if UI.windows[playerIndex] then W.unfocus(UI.windows[playerIndex].body) end
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    if not hasSelection(request) then
        local nextContext = {}
        for key, val in pairs(context) do nextContext[key] = val end
        nextContext.request = request
        local window = UI.open(playerIndex, nextContext, "compose")
        window:messageText("Choose the categories or item types for this shortcut. Save a loot checklist to reuse that selection next time.")
        return window
    end
    if pickArea and not request.area then
        local player = getSpecificPlayer(playerIndex)
        if not player or not player:getCurrentSquare() or player:isDead() then return nil, "Enter the world before choosing an area." end
        if UI.areaPickers[playerIndex] then UI.areaPickers[playerIndex]:finish(nil, false) end
        local picker = AreaPicker:new(nil, playerIndex, function(area)
            if not area then return end
            request.area = area
            UI.quickAction(playerIndex, context, request, false)
        end)
        picker:initialise(); picker:setWantKeyEvents(true); picker:setWantMouseEvents(true)
        UI.areaPickers[playerIndex] = picker
        picker:addToUIManager(); picker:bringToTop()
        return picker
    end
    local plan
    plan, err = app:preview(request)
    if not plan then
        if request.shortcutIntent or app:status().canPreview == false then
            UI.showProgress(playerIndex, "This shortcut did not start. " .. tostring(err))
            return nil, err
        end
        local nextContext = {}
        for key, val in pairs(context) do nextContext[key] = val end
        nextContext.request = request
        local window = UI.open(playerIndex, nextContext, "compose")
        window:messageText(err)
        return nil, err
    end
    if request.shortcutIntent and request.shortcutIntent:match("^smart:")
        and #(plan.moves or {}) == 0 and (plan.pending or 0) == 0 then return true end
    local saved, saveError = app:rememberSetup(request)
    local notice = not saved and ("The job can run, but its setup could not be remembered: " .. tostring(saveError)) or nil
    local required, _, preferenceError = App.reviewPreference(request)
    if preferenceError then notice = "Review settings could not be read; this review is shown: " .. tostring(preferenceError) end
    if not required then
        local ok
        ok, err = app:start(plan)
        if ok then
            if UI.quickWindows[playerIndex] then UI.quickWindows[playerIndex]:close() end
            local preferences = App.getPreferences()
            if preferences.showQuickProgress == true or notice then return UI.showProgress(playerIndex, notice) end
            return true
        end
        notice = "This shortcut could not start: " .. tostring(err)
    end
    if UI.quickWindows[playerIndex] then UI.quickWindows[playerIndex]:close() end
    local review = QuickReview:new(playerIndex, context, request, plan, notice)
    review:initialise(); review:addToUIManager()
    UI.quickWindows[playerIndex] = review
    return review
end

function UI.replaceAction(playerIndex, callback)
    playerIndex = playerIndex or 0
    if UI.windows[playerIndex] then W.unfocus(UI.windows[playerIndex].body) end
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    if UI.quickWindows[playerIndex] then UI.quickWindows[playerIndex]:close() end
    local result
    result, err = app:replaceJob(callback)
    if not result and err then UI.showProgress(playerIndex, err) end
    return result, err
end

function UI.condense(playerIndex, ready)
    playerIndex = playerIndex or 0
    if not ready then return UI.replaceAction(playerIndex, function() return UI.condense(playerIndex, true) end) end
    local app, err = App.get(playerIndex)
    if not app then return nil, err end
    local plan
    plan, err = app:previewCondense()
    if not plan then UI.showProgress(playerIndex, err); return nil, err end
    local request = {scope = "inventory", includeBags = true,
        filter = {all = true, ids = {}, types = {}}, destination = {kind = "condense"}}
    local required, _, preferenceError = App.reviewPreference(request)
    local notice = preferenceError and ("Review settings could not be read; this review is shown: " .. tostring(preferenceError)) or nil
    if not required then
        local ok
        ok, err = app:start(plan)
        if ok then
            if UI.quickWindows[playerIndex] then UI.quickWindows[playerIndex]:close() end
            local preferences = App.getPreferences()
            if preferences.showQuickProgress == true then return UI.showProgress(playerIndex) end
            return true
        end
        notice = "Condense could not start: " .. tostring(err)
    end
    if UI.quickWindows[playerIndex] then UI.quickWindows[playerIndex]:close() end
    local review = QuickReview:new(playerIndex, {condense = true}, request, plan, notice)
    review:initialise(); review:addToUIManager()
    UI.quickWindows[playerIndex] = review
    return review
end

function UI.closeAll()
    local windows = {}
    for _, registry in ipairs({ UI.windows, UI.progressWindows, UI.quickWindows }) do
        for _, window in pairs(registry) do windows[#windows + 1] = window end
    end
    for _, picker in pairs(UI.areaPickers) do picker:finish(nil, false) end
    for _, window in ipairs(windows) do window:close() end
    UI.reviewVisits = {}
end

function UI.tick()
    if getCore():isDoingTextEntry() then return end
    for playerIndex = 0, getNumActivePlayers() - 1 do
        local app = App.peek(playerIndex)
        if app then
            local status, visit = app:status(), UI.reviewVisits[playerIndex]
            if status.state == "needs_review" and status.reviewId ~= nil
                and (not visit or visit.app ~= app or visit.id ~= status.reviewId) then
                UI.showBinReview(playerIndex)
            end
        end
    end
end

function UI.onKeyStartPressed(key)
    if getCore():isDoingTextEntry() or not getCore():isKey("LootBoxCurrentJob", key) then return end
    if not getSpecificPlayer(0) then return end
    local app = App.get(0)
    if app and (app:status().state ~= "idle" or app:recoveryStatus().pending) then UI.showProgress(0) end
end

function UI.install()
    if UI.installed then return end
    UI.installed = true
    require("LootBox/Menus").install(UI)
    require "keyBinding"
    local hasBinding = false
    for _, binding in ipairs(keyBinding) do
        if binding.value == "LootBoxCurrentJob" then hasBinding = true; break end
    end
    if not hasBinding then
        keyBinding[#keyBinding + 1] = {value = "[LootBox]"}
        keyBinding[#keyBinding + 1] = {value = "LootBoxCurrentJob", key = Keyboard.KEY_F7}
    end
    require("LootBox/Navigation").install()
    Events.OnTick.Add(UI.tick)
    Events.OnKeyStartPressed.Add(UI.onKeyStartPressed)
    if Events.OnDisconnect then Events.OnDisconnect.Add(UI.closeAll) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(UI.closeAll) end
    local options = PZAPI.ModOptions:getOptions("LootBox") or PZAPI.ModOptions:create("LootBox", "LootBox")
    options:addTitle("LootBox")
    require("LootBox/ContainerFocus").register(options)
    options:addDescription("Loot, sort, haul and clean with reusable setups, contextual shortcuts and complete workflow guides.")
    options:addButton("openManager", "Open LootBox", "Choose a task or continue a saved setup.", function() UI.open(0) end)
    options:addButton("manageCategories", "Manage categories", "Browse every active item category and create nested custom groups.", function() UI.open(0, nil, "categories") end)
    options:addButton("help", "Workflow help", "Read complete workflows, expected results and troubleshooting.", function() UI.open(0, { guide = "first-run" }, "help") end)
    options:addButton("settings", "Settings", "Control right-click shortcuts, quick-action review and setup reuse.", function() UI.open(0, nil, "settings") end)
end

UI.Window, UI.Progress, UI.QuickReview, UI.AreaPicker = Window, Progress, QuickReview, AreaPicker
return UI

