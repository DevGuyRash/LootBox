require "ISUI/ISCollapsableWindow"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISRichTextPanel"
require "ISUI/ISComboBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"
require "ISUI/ISToolTip"
require "PZAPI/ModOptions"

local App = require "LootBox/App"
local Categories = require "LootBox/Categories"
local UI = { windows = {}, progressWindows = {} }
local Window = ISCollapsableWindow:derive("LootBoxWindow")
local Progress = ISCollapsableWindow:derive("LootBoxProgress")
local AreaPicker = ISPanel:derive("LootBoxAreaPicker")
local H = getTextManager():getFontHeight(UIFont.Small) + 10
local GAP = 10
local states = { idle = "No active job", running = "Working", cancelling = "Stopping",
    cancelled = "Cancelled", failed = "Stopped after an error", complete = "Finished",
    finished = "Finished", finished_with_skips = "Finished with items left behind" }

local function setOf(values)
    local result = {}
    for _, value in ipairs(values or {}) do result[value] = true end
    return result
end

local function arrayOf(values)
    local result = {}
    for key, value in pairs(values or {}) do
        if value then result[#result + 1] = key end
    end
    table.sort(result)
    return result
end

local function label(parent, x, y, text, dim)
    local color = dim and 0.65 or 0.92
    local child = ISLabel:new(x, y, H, text, color, color, color, 1, UIFont.Small, true)
    child:initialise()
    parent:addChild(child)
    return child
end

local function plainText(text)
    return tostring(text or ""):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\r", ""):gsub("\n", " <LINE> ")
end

local function setWrapped(panel, text)
    text = tostring(text or "")
    if panel.plainText == text then return end
    panel.plainText = text
    panel.text = plainText(text)
    panel:paginate()
    panel:setYScroll(0)
end

local function wrapped(parent, x, y, width, height, text)
    local child = ISRichTextPanel:new(x, y, width, height)
    child:initialise()
    child.autosetheight = false
    child.clip = true
    child.background = false
    child.defaultFont = UIFont.Small
    child:setMargins(0, 2, 18, 2)
    parent:addChild(child)
    child:addScrollBars()
    setWrapped(child, text)
    return child
end

local function button(parent, x, y, width, text, target, callback)
    local child = ISButton:new(x, y, width, H, text, target, callback)
    child:initialise()
    parent:addChild(child)
    return child
end

local function entry(parent, x, y, width, text, target, callback)
    local child = ISTextEntryBox:new(text or "", x, y, width, H)
    child:initialise()
    child:instantiate()
    child.target = target
    child.onTextChangeFunction = callback
    parent:addChild(child)
    return child
end

local function combo(parent, x, y, width, target, callback)
    local child = ISComboBox:new(x, y, width, H, target, callback)
    child:initialise()
    parent:addChild(child)
    return child
end

local function check(parent, x, y, width, text, selected, target, callback)
    local child = ISTickBox:new(x, y, width, H, "", target, callback)
    child:initialise()
    child:addOption(text)
    child:setSelected(1, selected == true)
    parent:addChild(child)
    return child
end

local function value(widget)
    return widget:getOptionData(widget.selected)
end

local function matchesSearch(text, query)
    return query == "" or string.find(string.lower(text), query, 1, true) ~= nil
end

local function list(parent, x, y, width, height, target, onSelect, selected)
    local child = ISScrollingListBox:new(x, y, width, math.max(H, height))
    child:initialise()
    child:instantiate()
    child.itemheight = H
    child.font = UIFont.Small
    child.drawBorder = true
    child.selection = selected
    child:setOnMouseDownFunction(target, onSelect)
    child.doDrawItem = function(self, rowY, row, alternate)
        if rowY + self:getYScroll() + self.itemheight < 0 or rowY + self:getYScroll() >= self.height then
            return rowY + self.itemheight
        end
        local checked = self.selection and self.selection[row.item.key]
        if row.index == self.selected or checked then
            self:drawRect(0, rowY, self.width, self.itemheight, 0.65, 0.16, 0.28, 0.3)
        elseif alternate then
            self:drawRect(0, rowY, self.width, self.itemheight, 0.15, 0.3, 0.3, 0.3)
        end
        local prefix = self.selection and (checked and "[x] " or "[ ] ") or ""
        self:drawText(prefix .. row.text, 7, rowY + 4, 0.92, 0.92, 0.92, 1, self.font)
        return rowY + self.itemheight
    end
    parent:addChild(child)
    return child
end

local function containerName(container)
    if not container then return "No selected container" end
    local item = container:getContainingItem()
    if item then return tostring(item:getName()) end
    local parent = container:getParent()
    local index = parent and parent:getContainerIndex(container)
    return tostring(container:getType()) .. (index and (" #" .. tostring(index)) or "")
end

local function vehicleName(vehicle)
    if ISVehicleMenu and ISVehicleMenu.getVehicleDisplayName then
        return ISVehicleMenu.getVehicleDisplayName(vehicle)
    end
    return vehicle:getScript():getName()
end

function Window:new(playerIndex, context, mode)
    local width = math.min(1060, getCore():getScreenWidth() - 40)
    local height = math.min(760, getCore():getScreenHeight() - 40)
    local o = ISCollapsableWindow.new(self, (getCore():getScreenWidth() - width) / 2,
        (getCore():getScreenHeight() - height) / 2, width, height)
    o.playerIndex = playerIndex
    o.context = context or {}
    o.mode = mode or "compose"
    o.resizable = false
    o.title = "LootBox"
    o.backgroundColor = { r = 0.055, g = 0.065, b = 0.07, a = 0.98 }
    o.request = { scope = o.context.scope or (o.context.container and "container" or "inventory"),
        includeInventory = false, includeBags = true, filter = { ids = {}, types = {}, all = false },
        destination = { kind = "inventory" } }
    if o.context.item then o.request.filter.types = { o.context.item:getFullType() } end
    o.selection = {}
    for _, id in ipairs(o.request.filter.ids) do o.selection[id] = true end
    for _, id in ipairs(o.request.filter.types) do o.selection[id] = true end
    o.editor = { types = {}, includes = {} }
    return o
end

function Window:initialise()
    ISCollapsableWindow.initialise(self)
end

function Window:app()
    if getSpecificPlayer(self.playerIndex) then return App.get(self.playerIndex) end
    return nil
end

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.collapseButton:setVisible(false)
    local navY = self:titleBarHeight() + GAP
    self.actionTab = button(self, GAP, navY, 120, "Actions", self, function(s) s:show("compose") end)
    self.categoryTab = button(self, 140, navY, 150, "Categories", self, function(s) s:show("categories") end)
    self.labelsTab = button(self, 300, navY, 120, "Labels", self, function(s) s:show("labels") end)
    self.jobTab = button(self, 430, navY, 120, "Current job", self, function(s) UI.showProgress(s.playerIndex) end)
    self.actionTab:setEnable(self:app() ~= nil)
    self.labelsTab:setEnable(self:app() ~= nil and (self.context.item ~= nil or self.context.container ~= nil or self.context.vehicle ~= nil))
    self.jobTab:setEnable(self:app() ~= nil)
    self.contentY = navY + H + GAP
    self:show(self.mode)
end

function Window:show(mode)
    if mode == "compose" and not self:app() then mode = "categories" end
    if self.mode == "compose" and self.scope then
        local request = self:readRequest(false)
        if request then self.request = request end
        self.operationValue = value(self.operation)
        self.selectorKindValue = value(self.selectorKind)
        self.searchDraft = self.search:getText()
    elseif self.mode == "categories" and self.categoryName then
        self.editorDefinition = { id = self.editor.id, name = self.categoryName:getText(),
            types = arrayOf(self.editor.types), includes = arrayOf(self.editor.includes) }
    end
    if self.body then self:removeChild(self.body) end
    self.mode = mode
    self.body = ISPanel:new(GAP, self.contentY, self.width - 2 * GAP, self.height - self.contentY - GAP)
    self.body:initialise()
    self.body.backgroundColor.a = 0
    self.body.borderColor.a = 0
    self:addChild(self.body)
    self.message = nil
    self.messagePanel = nil
    self.messageLabel = nil
    if mode == "categories" then self:buildCategories()
    elseif mode == "labels" then self:buildLabels()
    elseif mode == "preview" then self:buildPreview()
    else self:buildComposer() end
end

function Window:messageText(text)
    self.message = tostring(text or "")
    if self.messagePanel then setWrapped(self.messagePanel, self.message) end
end

function Window:catalog()
    local catalog, problem = App.catalog()
    self.catalogData = catalog or { items = {}, categories = {}, error = problem }
    return self.catalogData
end

function Window:buildComposer()
    local body, width = self.body, self.body.width
    self:catalog()
    local col = math.floor((width - 2 * GAP) / 3)
    label(body, 0, 0, "Choose what to move, where to find it, and where it belongs.")
    label(body, 0, H + 3, "Start with", true)
    label(body, col + GAP, H + 3, "From", true)
    label(body, 2 * (col + GAP), H + 3, "To", true)
    local rowY = 2 * H + 3
    self.operation = combo(body, 0, rowY, col, self, function(s, widget)
        local kind = value(widget)
        if kind == "loot" then s.destination:selectData("inventory")
        elseif kind == "clean" then s.destination:selectData("trash") end
        s:onDestinationChanged()
    end)
    self.operation:addOptionWithData("Loot", "loot")
    self.operation:addOptionWithData("Move", "move")
    self.operation:addOptionWithData("Clean", "clean")
    self.operation:selectData(self.operationValue or "move")
    self.scope = combo(body, col + GAP, rowY, col, self, function(s) s:onScopeChanged() end)
    local scopes = { { "My carried items", "inventory" }, { "Within reach", "reach" },
        { "This room", "room" }, { "This building", "building" }, { "An area", "area" },
        { "Containers with a label", "labeled" } }
    for _, pair in ipairs(scopes) do self.scope:addOptionWithData(pair[1], pair[2]) end
    if self.context.container then self.scope:addOptionWithData("Selected container", "container") end
    self.scope:selectData(self.request.scope)
    self.destination = combo(body, 2 * (col + GAP), rowY, col, self, function(s) s:onDestinationChanged() end)
    self.destination:addOptionWithData("My carried storage", "inventory")
    self.destination:addOptionWithData("Floor here", "floor")
    if self.context.container then self.destination:addOptionWithData("Selected container", "container") end
    self.destination:addOptionWithData("My remembered vehicle", "vehicle")
    self.destination:addOptionWithData("Labeled storage", "labels")
    self.destination:addOptionWithData("Trash cans", "trash")
    self.destination:selectData(self.request.destination.kind)
    self.includeInventory = check(body, 0, rowY + H + GAP, col, "Include my carried items", self.request.includeInventory, self)
    self.includeBags = check(body, col + GAP, rowY + H + GAP, col, "Include bags inside bags", self.request.includeBags, self)
    self.endpoint = combo(body, 2 * (col + GAP), rowY + H + GAP, col, self)
    self.endpointLabel = label(body, 2 * (col + GAP), rowY + 2 * H + GAP, "", true)
    local areaY = rowY + 2 * H + GAP
    self.areaButton = button(body, 0, areaY, 230, "Select area in world", self, Window.selectArea)
    local area = self.request.area
    local summary = "Click two corners on the current floor."
    if area then
        summary = tostring(math.abs(area.x2 - area.x1) + 1) .. " x " .. tostring(math.abs(area.y2 - area.y1) + 1)
            .. " tiles on floor " .. tostring(area.z)
    end
    self.areaSummary = wrapped(body, 240, areaY, 2 * col + GAP - 240, 2 * H, summary)
    self.sourceEndpoint = combo(body, 0, areaY, 2 * col + GAP, self)
    for _, container in ipairs(self.context.containers or { self.context.container }) do
        if container then self.sourceEndpoint:addOptionWithData(containerName(container), container) end
    end
    self.sourceEndpoint:selectData(self.request.sourceContainer or self.context.container)
    self.sourceLabel = combo(body, 0, areaY, 2 * col + GAP, self)
    self.sourceLabel:addOptionWithData("Choose a source container label", false)
    for _, category in ipairs(self.catalogData.categories) do
        self.sourceLabel:addOptionWithData(category.name, category.id)
    end
    self.sourceLabel:selectData(self.request.sourceLabels and self.request.sourceLabels[1] or false)
    local searchY = areaY + 2 * H + GAP
    self.allItems = check(body, 0, searchY, col, "All unprotected items", self.request.filter.all, self, function(s)
        s:refreshSelectionCount()
    end)
    self.selectorKind = combo(body, col + GAP, searchY, col, self, function(s) s:fillSelectionList() end)
    self.selectorKind:addOptionWithData("Categories", "categories")
    self.selectorKind:addOptionWithData("Item types", "items")
    self.selectorKind:selectData(self.selectorKindValue or (self.context.item and "items" or "categories"))
    self.search = entry(body, 2 * (col + GAP), searchY, col, self.searchDraft or "", self, function(s) s:fillSelectionList() end)
    self.search:setTooltip("Search names or exact item IDs. Click rows to select more than one.")
    local listY, footerY = searchY + H + GAP, body.height - 4 * H - GAP
    self.selectionList = list(body, 0, listY, width, footerY - listY - GAP, self, function(s, row)
        s.selection[row.key] = not s.selection[row.key]
        s:refreshSelectionCount()
    end, self.selection)
    self.countLabel = label(body, 0, footerY, "")
    button(body, 0, footerY + H, 145, "Save checklist", self, Window.saveChecklist)
    button(body, 155, footerY + H, 145, "Load checklist", self, Window.loadChecklist)
    button(body, width - 170, footerY + H, 170, "Preview", self, Window.preview)
    self.messagePanel = wrapped(body, 0, footerY + 2 * H, width, 2 * H, "")
    self:fillSelectionList()
    self:onScopeChanged()
    self:onDestinationChanged()
    if self.catalogData.error then self:messageText(self.catalogData.error) end
end

function Window:onScopeChanged()
    local scope = value(self.scope)
    local isArea = scope == "area"
    self.areaButton:setVisible(isArea)
    self.areaSummary:setVisible(isArea)
    self.includeInventory:setVisible(scope ~= "inventory")
    self.sourceEndpoint:setVisible(scope == "container")
    self.sourceLabel:setVisible(scope == "labeled")
end

function Window:onDestinationChanged()
    self.endpoint:clear()
    local kind = value(self.destination)
    self.endpoint:setVisible(kind == "container" or kind == "vehicle" or kind == "labels")
    self.endpointLabel:setName("")
    if kind == "container" then
        for _, container in ipairs(self.context.containers or { self.context.container }) do
            if container then self.endpoint:addOptionWithData(containerName(container), container) end
        end
    elseif kind == "vehicle" then
        self.endpoint:addOptionWithData("Remembered vehicle", false)
        local vehicles = self:app():knownVehicles()
        for _, vehicle in ipairs(vehicles) do self.endpoint:addOptionWithData(vehicleName(vehicle), vehicle) end
        if self.context.vehicle then
            self.endpoint:addOptionWithData("Clicked " .. vehicleName(self.context.vehicle), self.context.vehicle)
            self.endpoint:selectData(self.context.vehicle)
        end
    elseif kind == "labels" then
        self.endpoint:addOptionWithData("Any matching label", false)
        for _, category in ipairs((self.catalogData or self:catalog()).categories) do
            self.endpoint:addOptionWithData(category.name, category.id)
        end
    elseif kind == "trash" then
        self.endpointLabel:setName("Preview includes existing bin contents.")
    end
    if self.request.destination.kind == kind then
        if kind == "container" or kind == "vehicle" then
            self.endpoint:selectData(self.request.destination.ref or false)
        elseif kind == "labels" then
            self.endpoint:selectData(self.request.destination.labels and self.request.destination.labels[1] or false)
        end
    end
end

function Window:fillSelectionList()
    if not self.selectionList then return end
    self.selectionList:clear()
    local query = string.lower(self.search:getText())
    local kind = value(self.selectorKind)
    local rows = self.catalogData[kind]
    for _, row in ipairs(rows) do
        local key = kind == "items" and row.fullType or row.id
        local text = row.name .. (kind == "items" and ("  [" .. row.fullType .. "]") or "")
        if matchesSearch(text, query) then self.selectionList:addItem(text, { key = key }) end
    end
    self:refreshSelectionCount()
end

function Window:refreshSelectionCount()
    if self.countLabel then
        local categories, items = 0, 0
        for _, key in ipairs(arrayOf(self.selection)) do
            if key:match("^native:") or key:match("^custom:") then categories = categories + 1 else items = items + 1 end
        end
        self.countLabel:setName(self.allItems:isSelected(1) and "All unprotected items selected"
            or ("Selected categories: " .. categories .. ". Item types: " .. items .. ". Click to add or remove."))
    end
end

function Window:readRequest(validate)
    local filter = { ids = {}, types = {}, all = self.allItems:isSelected(1) }
    for _, key in ipairs(arrayOf(self.selection)) do
        local destination = string.find(key, "native:", 1, true) == 1 or string.find(key, "custom:", 1, true) == 1
        local result = destination and filter.ids or filter.types
        result[#result + 1] = key
    end
    local scope, kind = value(self.scope), value(self.destination)
    local request = { scope = scope, sourceContainer = value(self.sourceEndpoint) or self.context.container,
        includeInventory = self.includeInventory:isSelected(1), includeBags = self.includeBags:isSelected(1),
        filter = filter, destination = { kind = kind } }
    if scope == "labeled" then
        local id = value(self.sourceLabel)
        if not id and validate ~= false then return nil, "Choose a source container label." end
        request.sourceLabels = id and { id } or {}
    end
    if kind == "container" then request.destination.ref = value(self.endpoint)
    elseif kind == "vehicle" then request.destination.ref = value(self.endpoint) or nil
    elseif kind == "floor" then request.destination.ref = self.context.square or getSpecificPlayer(self.playerIndex):getSquare()
    elseif kind == "labels" and value(self.endpoint) then request.destination.labels = { value(self.endpoint) } end
    if scope == "area" then
        if not self.request.area and validate ~= false then return nil, "Select an area in the world first." end
        request.area = self.request.area
    end
    return request
end

function Window:selectArea()
    local player = getSpecificPlayer(self.playerIndex)
    if not player or not player:getCurrentSquare() or player:isDead() then
        self:messageText("Enter the world before selecting an area.")
        return
    end
    local request = self:readRequest(false)
    self.request = request
    self.operationValue = value(self.operation)
    self.selectorKindValue = value(self.selectorKind)
    self.searchDraft = self.search:getText()
    if self.areaPicker then self.areaPicker:finish(nil, false) end
    local picker = AreaPicker:new(self)
    picker:initialise()
    picker:setWantKeyEvents(true)
    picker:setWantMouseEvents(true)
    self:setVisible(false)
    self.areaPicker = picker
    picker:addToUIManager()
    picker:bringToTop()
end

function AreaPicker:new(window)
    local o = ISPanel.new(self, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    o.window = window
    o.playerIndex = window.playerIndex
    o.player = getSpecificPlayer(o.playerIndex)
    o.z = o.player:getCurrentSquare():getZ()
    o.background = false
    o.border = false
    o.hint = "Click the first corner."
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
            math.max(first.x, point.x) + 1, math.max(first.y, point.y) + 1, self.z, 0.15, 0.8, 0.75, 0.4)
    end
    local width = math.min(700, self.width - 40)
    local x = (self.width - width) / 2
    self:drawRect(x, 24, width, 2 * H + GAP, 0.95, 0.04, 0.06, 0.07)
    self:drawTextCentre(self.hint .. "  Floor " .. tostring(self.z), self.width / 2, 29, 1, 1, 1, 1, UIFont.Small)
    self:drawTextCentre("Escape or right-click cancels.", self.width / 2, 29 + H, 0.7, 0.8, 0.8, 1, UIFont.Small)
end

function AreaPicker:update()
    if getSpecificPlayer(self.playerIndex) ~= self.player or self.player:isDead() then
        self:finish(nil, false)
        self.window:close()
    end
end

function AreaPicker:onMouseDown()
    local point = self:point()
    if not point then self.hint = "Choose a loaded floor tile."; return true end
    if self.first then self.last = point
    else self.first = point; self.hint = "Click the opposite corner." end
    return true
end

function AreaPicker:onMouseUp()
    if self.last then
        self:finish({ x1 = math.min(self.first.x, self.last.x), y1 = math.min(self.first.y, self.last.y),
            x2 = math.max(self.first.x, self.last.x), y2 = math.max(self.first.y, self.last.y), z = self.z }, true)
    end
    return true
end

function AreaPicker:onRightMouseDown()
    return true
end

function AreaPicker:onRightMouseUp()
    self:finish(nil, true)
    return true
end

function AreaPicker:isKeyConsumed(key)
    return key == Keyboard.KEY_ESCAPE
end

function AreaPicker:onKeyPress(key)
    if self:isKeyConsumed(key) then
        self:finish(nil, true)
        GameKeyboard.eatKeyPress(key)
        return true
    end
    return false
end

function AreaPicker:onKeyRelease(key)
    if self:isKeyConsumed(key) then self:finish(nil, true); return true end
    return false
end

function AreaPicker:finish(area, restore)
    if self.closed then return end
    self.closed = true
    self:setVisible(false)
    self:removeFromUIManager()
    self.window.areaPicker = nil
    if area then self.window.request.area = area end
    if restore then
        self.window:show("compose")
        self.window:setVisible(true)
        self.window:bringToTop()
        self.window:messageText(area and "Area selected. Preview the matching items before starting." or "Area selection cancelled.")
    end
end

function Window:saveChecklist()
    local request = self:readRequest(false)
    local filter = request.filter
    if not filter.all and #filter.ids == 0 and #filter.types == 0 then
        self:messageText("Choose at least one category or item type for the checklist.")
        return
    end
    local ok, problem = self:app():setChecklist(filter)
    self:messageText(ok and "Checklist saved. Only the item selection is remembered." or problem)
end

function Window:loadChecklist()
    local filter, problem = self:app():getChecklist()
    if not filter then self:messageText(problem or "No checklist has been saved yet."); return end
    self.selection = setOf(filter.ids)
    for _, fullType in ipairs(filter.types or {}) do self.selection[fullType] = true end
    self.selectionList.selection = self.selection
    self.allItems:setSelected(1, filter.all == true)
    self.selectorKind:selectData(#(filter.ids or {}) > 0 and "categories" or "items")
    self.selectorKindValue = value(self.selectorKind)
    self.search:setText("")
    self.searchDraft = ""
    self:fillSelectionList()
    self:messageText("Checklist loaded. Choose where to look and a destination.")
end

function Window:preview()
    local request, problem = self:readRequest()
    if not request then self:messageText(problem); return end
    if not request.filter.all and #request.filter.ids == 0 and #request.filter.types == 0 then
        self:messageText("Choose at least one category or item type.")
        return
    end
    self.request = request
    self.operationValue = value(self.operation)
    local plan, error = self:app():preview(request)
    if not plan then self:messageText(error); return end
    self.plan = plan
    self:show("preview")
end

function Window:buildPreview()
    local body, plan = self.body, self.plan
    local moves, skipped = plan.moves or {}, plan.skipped or {}
    local pending = tonumber(plan.pending) or 0
    label(body, 0, 0, tostring(#moves) .. " items to move. " .. tostring(#skipped) .. " items left behind.")
    label(body, 0, H, "Live access, capacity and item ownership are checked again while running.", true)
    local rows = list(body, 0, 2 * H + GAP, body.width, body.height - 6 * H - 2 * GAP, self, nil)
    if pending > 0 then
        local text = tostring(pending) .. " unopened containers or floor locations will be approached and checked for matching items."
        rows:addItem(text, {}, text)
    end
    for _, warning in ipairs(plan.warnings or {}) do
        local text = "NOTICE  " .. tostring(warning)
        rows:addItem(text, {}, text)
    end
    for _, move in ipairs(moves) do
        local text = tostring(move.itemName or "Item") .. "  |  " .. tostring(move.from or "Source") .. " -> " .. tostring(move.to or "Destination")
        rows:addItem(text, {}, text)
    end
    for _, item in ipairs(skipped) do
        local text = "LEFT  " .. tostring(item.itemName or "Item") .. "  |  " .. tostring(item.reason or "No destination")
        rows:addItem(text, {}, text)
    end
    local footerY = body.height - 3 * H
    button(body, 0, footerY, 120, "Back", self, function(s) s:show("compose") end)
    self.runButton = button(body, body.width - 200, footerY, 200,
        self.request.destination.kind == "trash" and "Start cleanup and delete" or "Start", self, function(s)
            local ok, problem = s:app():start(s.plan)
            if not ok then s:messageText(problem); return end
            s:setVisible(false)
            UI.showProgress(s.playerIndex)
        end)
    self.runButton:setEnable(#moves > 0 or pending > 0)
    self.messagePanel = wrapped(body, 0, footerY + H, body.width, 2 * H, "")
end

function Window:buildCategories()
    local body, width = self.body, self.body.width
    local leftWidth = math.floor(width * 0.29)
    self:catalog()
    label(body, 0, 0, "Reusable categories", true)
    self.categorySearch = entry(body, 0, H, leftWidth, "", self, function(s) s:fillCategoryList() end)
    self.categoryList = list(body, 0, 2 * H + GAP, leftWidth, body.height - 4 * H - GAP, self, function(s, row)
        s:editCategory(row.definition)
    end)
    button(body, 0, body.height - H, leftWidth, "New custom category", self, function(s) s:editCategory(nil) end)
    local rightX, rightWidth = leftWidth + GAP, width - leftWidth - GAP
    label(body, rightX, 0, "Category name", true)
    self.categoryName = entry(body, rightX, H, rightWidth, self.editor.name or "")
    self.memberKind = combo(body, rightX, 2 * H + GAP, rightWidth * 0.43, self, function(s) s:fillMemberList() end)
    self.memberKind:addOptionWithData("Include categories", "includes")
    self.memberKind:addOptionWithData("Include item types", "types")
    self.memberSearch = entry(body, rightX + rightWidth * 0.43 + GAP, 2 * H + GAP,
        rightWidth * 0.57 - GAP, "", self, function(s) s:fillMemberList() end)
    local listY, footerY = 3 * H + 2 * GAP, body.height - 4 * H - GAP
    self.memberList = list(body, rightX, listY, rightWidth, footerY - listY - GAP, self, function(s, row)
        if s.editor.native then return end
        local selected = s.editor[value(s.memberKind)]
        selected[row.key] = not selected[row.key]
        s:updateMemberCount()
    end, self.editor.includes)
    self.memberCount = label(body, rightX, footerY, "", true)
    self.saveCategoryButton = button(body, rightX, footerY + H, 140, "Save category", self, Window.saveCategory)
    self.deleteCategoryButton = button(body, rightX + 150, footerY + H, 140, "Delete category", self, Window.deleteCategory)
    self.messagePanel = wrapped(body, rightX, footerY + 2 * H, rightWidth, 2 * H, "")
    self:fillCategoryList()
    self:editCategory(self.editorDefinition)
    if self.catalogData.error then self:messageText(self.catalogData.error) end
end

function Window:fillCategoryList()
    self.categoryList:clear()
    local query = string.lower(self.categorySearch:getText())
    for _, definition in ipairs(self.catalogData.categories) do
        if matchesSearch(definition.name, query) then
            local text = definition.name .. (string.find(definition.id, "native:", 1, true) == 1 and "  (game)" or "")
            self.categoryList:addItem(text, { definition = definition })
        end
    end
end

function Window:editCategory(definition)
    self.editorDefinition = definition
    self.editor = { id = definition and definition.id, name = definition and definition.name or "",
        types = setOf(definition and definition.types), includes = setOf(definition and definition.includes),
        native = definition and definition.id and string.find(definition.id, "native:", 1, true) == 1 }
    if not definition and self.context.item then self.editor.types[self.context.item:getFullType()] = true end
    self.categoryName:setText(self.editor.name)
    self.categoryName:setEditable(not self.editor.native)
    self.saveCategoryButton:setEnable(not self.editor.native)
    self.deleteCategoryButton:setEnable(not self.editor.native and self.editor.id ~= nil)
    self:messageText(self.editor.native and "Game categories follow installed items. Include one in a custom category to extend it." or "")
    self:fillMemberList()
end

function Window:fillMemberList()
    self.memberList:clear()
    local kind = value(self.memberKind)
    self.memberList.selection = self.editor[kind]
    local rows = kind == "types" and self.catalogData.items or self.catalogData.categories
    local query = string.lower(self.memberSearch:getText())
    for _, row in ipairs(rows) do
        local key = kind == "types" and row.fullType or row.id
        local text = row.name .. (kind == "types" and ("  [" .. key .. "]") or "")
        if key ~= self.editor.id and matchesSearch(text, query) then self.memberList:addItem(text, { key = key }) end
    end
    self:updateMemberCount()
end

function Window:updateMemberCount()
    local definitions = {}
    for _, definition in ipairs(self.catalogData.categories) do
        if string.find(definition.id, "custom:", 1, true) == 1 and definition.id ~= self.editor.id then
            definitions[#definitions + 1] = definition
        end
    end
    local id = self.editor.id or "custom:editor-preview"
    if not self.editor.native then
        local name = self.categoryName:getText()
        definitions[#definitions + 1] = { id = id, name = name:find("%S") and name or "New category",
            types = arrayOf(self.editor.types), includes = arrayOf(self.editor.includes) }
    end
    local graph, problem = Categories.new(definitions)
    if not graph then
        self.memberCount:setName("Category inclusion needs attention.")
        self.memberProblem = true
        self:messageText(problem)
        return
    end
    if self.memberProblem then self.memberProblem = false; self:messageText("") end
    local count = 0
    for _, item in ipairs(self.catalogData.items) do
        if graph:matches(id, item) then count = count + 1 end
    end
    self.memberCount:setName(tostring(count) .. " matching item types. Included categories stay up to date.")
end

function Window:saveCategory()
    local id, problem = App.saveCategory({ id = self.editor.id, name = self.categoryName:getText(),
        types = arrayOf(self.editor.types), includes = arrayOf(self.editor.includes) })
    if not id then self:messageText(problem); return end
    self:catalog()
    self:fillCategoryList()
    for _, definition in ipairs(self.catalogData.categories) do
        if definition.id == id then self:editCategory(definition); break end
    end
    self:messageText("Category saved.")
end

function Window:deleteCategory()
    if not self.editor.id then return end
    local ok, problem = App.deleteCategory(self.editor.id)
    if not ok then self:messageText(problem); return end
    self:catalog()
    self:fillCategoryList()
    self:editCategory(nil)
    self:messageText("Category deleted.")
end

function Window:buildLabels()
    local body, app = self.body, self:app()
    if not app then label(body, 0, 0, "Open a game to label a container or item."); return end
    label(body, 0, 0, "Container labels say what belongs there. Item labels apply only to that copy.")
    self.labelTarget = combo(body, 0, H + GAP, body.width * 0.62, self, function(s) s:loadLabels() end)
    for _, container in ipairs(self.context.containers or { self.context.container }) do
        if container then self.labelTarget:addOptionWithData("Container accepts  " .. containerName(container), { kind = "container", ref = container }) end
    end
    if self.context.item then self.labelTarget:addOptionWithData("This item  " .. self.context.item:getName(), { kind = "item", ref = self.context.item }) end
    self.labelSearch = entry(body, body.width * 0.62 + GAP, H + GAP, body.width * 0.38 - GAP, "", self, function(s) s:fillLabelList() end)
    local listY, footerY = 2 * H + 2 * GAP, body.height - 4 * H - GAP
    self.labelList = list(body, 0, listY, body.width, footerY - listY - GAP, self, function(s, row)
        s.labelSelection[row.key] = not s.labelSelection[row.key]
    end, {})
    self.keep = check(body, 0, footerY, body.width * 0.6, "Keep this item out of automated jobs", false, self)
    self.saveLabelsButton = button(body, 0, footerY + H, 160, "Save labels", self, Window.saveLabels)
    if self.context.vehicle then
        button(body, 170, footerY + H, 230, "Remember this vehicle", self, function(s)
            local ok, problem = app:rememberVehicle(s.context.vehicle)
            s:messageText(ok and "Vehicle remembered for hauling." or problem)
        end)
    end
    self.messagePanel = wrapped(body, 0, footerY + 2 * H, body.width, 2 * H, "")
    self:catalog()
    self:loadLabels()
    if self.catalogData.error then self:messageText(self.catalogData.error) end
end

function Window:loadLabels()
    local target = value(self.labelTarget)
    if not target then
        self.keep:setVisible(false)
        self.saveLabelsButton:setEnable(false)
        self.labelList:clear()
        return
    end
    local app = self:app()
    self.saveLabelsButton:setEnable(true)
    self.labelSelection = setOf(target.kind == "item" and app:itemLabels(target.ref) or app:labels(target.ref))
    self.labelList.selection = self.labelSelection
    self.keep:setVisible(target.kind == "item")
    if target.kind == "item" then self.keep:setSelected(1, app:isKept(target.ref)) end
    self:fillLabelList()
end

function Window:fillLabelList()
    self.labelList:clear()
    local query = string.lower(self.labelSearch:getText())
    for _, category in ipairs(self.catalogData.categories) do
        if matchesSearch(category.name, query) then self.labelList:addItem(category.name, { key = category.id }) end
    end
end

function Window:saveLabels()
    local target, app = value(self.labelTarget), self:app()
    if not target then return end
    local ok, problem
    if target.kind == "container" then
        ok, problem = app:setLabels(target.ref, arrayOf(self.labelSelection))
    else
        ok, problem = app:setItemLabels(target.ref, arrayOf(self.labelSelection))
        if ok then ok, problem = app:protect(target.ref, self.keep:isSelected(1)) end
    end
    self:messageText(ok and "Labels saved." or problem)
end

function Window:close()
    if self.areaPicker then self.areaPicker:finish(nil, false) end
    self:setVisible(false)
    self:removeFromUIManager()
    UI.windows[self.playerIndex] = nil
end

function Progress:new(playerIndex)
    local width = math.min(500, getCore():getScreenWidth() - 40)
    local height = math.min(420, getCore():getScreenHeight() - 100)
    local o = ISCollapsableWindow.new(self, 20, 80, width, height)
    o.playerIndex = playerIndex
    o.title = "LootBox job"
    o.resizable = false
    return o
end

function Progress:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.collapseButton:setVisible(false)
    local y = self:titleBarHeight() + GAP
    self.statusLabel = label(self, GAP, y, "")
    self.countLabel = label(self, GAP, y + H, "")
    self.reasonPanel = wrapped(self, GAP, y + 2 * H, self.width - 2 * GAP, 2 * H, "")
    local listY, footerY = y + 4 * H + GAP, self.height - H - GAP
    self.reasonsList = list(self, GAP, listY, self.width - 2 * GAP, footerY - listY - GAP, self)
    self.reasonCount = 0
    self.cancelButton = button(self, GAP, footerY, 150, "Cancel job", self, function(s)
        App.get(s.playerIndex):cancel()
    end)
    button(self, self.width - 150 - GAP, footerY, 150, "Actions", self, function(s) UI.open(s.playerIndex) end)
end

function Progress:update()
    ISCollapsableWindow.update(self)
    if not getSpecificPlayer(self.playerIndex) then self:close(); return end
    local status = App.get(self.playerIndex):status()
    self.statusLabel:setName(states[status.state] or "Working")
    self.countLabel:setName(tostring(status.done or 0) .. " moved of " .. tostring(status.total or 0)
        .. ". " .. tostring(status.skipped or 0) .. " left behind.")
    setWrapped(self.reasonPanel, status.reason)
    local reasons = status.reasons or {}
    if self.reasonSource ~= status.reasons then
        self.reasonsList:clear()
        self.reasonSource, self.reasonCount = status.reasons, 0
    end
    for index = self.reasonCount + 1, #reasons do
        local row = reasons[index]
        local text = tostring(row.itemName or "Item") .. "  |  " .. tostring(row.reason or "No destination")
        self.reasonsList:addItem(text, {}, text)
    end
    self.reasonCount = #reasons
    self.cancelButton:setEnable(status.state == "running" or status.state == "cancelling")
end

function Progress:close()
    self:setVisible(false)
    self:removeFromUIManager()
    UI.progressWindows[self.playerIndex] = nil
end

function UI.open(playerIndex, context, mode)
    playerIndex = playerIndex or 0
    local previous = UI.windows[playerIndex]
    if previous then previous:close() end
    local window = Window:new(playerIndex, context, mode)
    window:initialise()
    window:addToUIManager()
    UI.windows[playerIndex] = window
    return window
end

function UI.showProgress(playerIndex)
    playerIndex = playerIndex or 0
    local previous = UI.progressWindows[playerIndex]
    if previous then previous:setVisible(true); previous:bringToTop(); return previous end
    local window = Progress:new(playerIndex)
    window:initialise()
    window:addToUIManager()
    UI.progressWindows[playerIndex] = window
    return window
end

local function selectedItem(items)
    for _, selected in ipairs(items or {}) do
        if instanceof(selected, "InventoryItem") then return selected end
        if type(selected) == "table" and selected.items then
            for _, item in ipairs(selected.items) do if instanceof(item, "InventoryItem") then return item end end
        end
    end
    return nil
end

local function labelName(id)
    if type(id) ~= "string" then return "Unavailable category" end
    if id:sub(1, 7) == "native:" then
        local raw = id:sub(8)
        local key = "IGUI_ItemCat_" .. raw
        local translated = getText(key)
        return translated and translated ~= key and translated or raw
    end
    local category = App.category(id)
    return category and category.name or id
end

local function addLabelTooltip(option, app, data)
    local lines = {}
    for _, container in ipairs(data.containers or {}) do
        local names = {}
        for _, id in ipairs(app:labels(container)) do names[#names + 1] = labelName(id) end
        if #names > 0 then lines[#lines + 1] = containerName(container) .. " accepts " .. table.concat(names, ", ") end
    end
    if data.item then
        local names = {}
        for _, id in ipairs(app:itemLabels(data.item)) do names[#names + 1] = labelName(id) end
        if #names > 0 then lines[#lines + 1] = "This item belongs to " .. table.concat(names, ", ") end
        if app:isKept(data.item) then lines[#lines + 1] = "Kept out of automated jobs." end
    end
    if #lines == 0 then lines[1] = "Move items, choose loot to look for, or manage categories and labels." end
    local tooltip = ISToolTip:new()
    tooltip:initialise()
    tooltip:setVisible(false)
    tooltip:setName("LootBox")
    tooltip.maxLineWidth = 450
    tooltip.description = plainText(table.concat(lines, "\n"))
    option.toolTip = tooltip
end

function UI.inventoryMenu(playerIndex, context, items)
    local item = selectedItem(items)
    local app = App.get(playerIndex)
    local container = app:currentContainer()
    local root = getSpecificPlayer(playerIndex):getInventory()
    local carried = item and item:getContainer() and item:getContainer():getOutermostContainer() == root
    if item and not carried then container = item:getContainer() end
    local containers = container and { container } or {}
    if item and instanceof(item, "InventoryContainer") then
        local bag = item:getInventory()
        if bag ~= container then containers[#containers + 1] = bag end
    end
    local data = { item = item, container = container, containers = containers,
        scope = carried and "inventory" or "container" }
    local option = context:addOption("LootBox", nil, function() UI.open(playerIndex, data) end)
    addLabelTooltip(option, app, data)
end

function UI.worldMenu(playerIndex, context, worldobjects, test)
    if test then return ISWorldObjectContextMenu.setTest() end
    local data = { containers = {} }
    local seen = {}
    for _, object in ipairs(worldobjects or {}) do
        if not data.square and object.getSquare then data.square = object:getSquare() end
        if object.getContainerCount then
            for index = 0, object:getContainerCount() - 1 do
                local container = object:getContainerByIndex(index)
                if container and not seen[container] then
                    seen[container] = true
                    data.containers[#data.containers + 1] = container
                end
            end
        end
    end
    data.container = data.containers[1]
    local player = getSpecificPlayer(playerIndex)
    data.vehicle = player:getVehicle()
    if not data.vehicle and IsoObjectPicker and IsoObjectPicker.Instance then
        data.vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
    end
    if not data.container then data.container = App.get(playerIndex):currentContainer() end
    if #data.containers == 0 and data.container then data.containers[1] = data.container end
    local option = context:addOption("LootBox", nil, function() UI.open(playerIndex, data) end)
    addLabelTooltip(option, App.get(playerIndex), data)
end

function UI.closeAll()
    local windows = {}
    for _, window in pairs(UI.windows) do windows[#windows + 1] = window end
    for _, window in pairs(UI.progressWindows) do windows[#windows + 1] = window end
    for _, window in ipairs(windows) do window:close() end
end

function UI.install()
    if UI.installed then return end
    UI.installed = true
    Events.OnFillInventoryObjectContextMenu.Add(UI.inventoryMenu)
    Events.OnFillWorldObjectContextMenu.Add(UI.worldMenu)
    if Events.OnDisconnect then Events.OnDisconnect.Add(UI.closeAll) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(UI.closeAll) end
    local options = PZAPI.ModOptions:getOptions("LootBox") or PZAPI.ModOptions:create("LootBox", "LootBox")
    options:addTitle("LootBox categories")
    options:addDescription("Create reusable categories here or through LootBox in an in-game context menu.")
    options:addButton("manageCategories", "Manage categories", "Browse all installed item types and combine categories.", function()
        UI.open(0, nil, "categories")
    end)
end

UI.Window = Window
UI.Progress = Progress
UI.AreaPicker = AreaPicker
return UI
