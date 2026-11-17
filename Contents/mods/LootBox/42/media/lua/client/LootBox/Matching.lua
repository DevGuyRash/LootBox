local available = pcall(require, "ISUI/InventoryWindow/ISInventoryWindowContainerControls")
local Matching = {}
if not available or not ISInventoryWindowControlHandler or not ISInventoryWindowControlHandler.derive
    or not ISInventoryWindowContainerControls or not ISInventoryWindowContainerControls.AddHandler
    or type(ISInventoryWindowContainerControls_HandlerList) ~= "table" then
    function Matching.install() return false end
    return Matching
end

local App = require "LootBox/App"
local Handler = ISInventoryWindowControlHandler:derive("LootBoxMatchingTransfer")

local modes = {
    displayed = {
        peer = "ISInventoryWindowControlHandler_TransferSameType",
        title = "Match Displayed",
        tooltip = "Transfer matching items from ALL carried containers to the displayed loot container.\nIncludes nested carried bags. Keep, favorite, equipped and attached items stay protected.",
    },
    nearby = {
        peer = "ISInventoryWindowControlHandler_TransferSameTypeMultiContainer",
        title = "Match Nearby",
        tooltip = "Transfer matching items from ALL carried containers to nearby loot containers.\nUses the native target order, including matching floor stacks. Includes nested carried bags and respects LootBox protection.",
    },
}

local function peerPresent(mode)
    for _, class in ipairs(ISInventoryWindowContainerControls_HandlerList) do
        if class.Type == modes[mode].peer then return true end
    end
    return false
end

local function hidden(self)
    if self.isMouseOver and self.control then self:onMouseOutButton() end
    return false
end

function Handler:shouldBeVisible()
    if getCore():isTutorial() or not peerPresent(self.mode) then return hidden(self) end
    local preferences, err = App.getPreferences()
    if err or preferences.matchingTransferButtons == false then return hidden(self) end
    local player = self.playerObj
    local loot = getPlayerLoot(self.playerNum)
    if not player or not player:getCurrentSquare() or not loot or not loot.inventoryPane or not loot.inventoryPane.inventory then return hidden(self) end
    if player:getInventory():isEmpty() then return hidden(self) end
    if self.mode == "displayed" and loot.inventoryPane.inventory:isEmpty() then return hidden(self) end
    return true
end

function Handler:getControl()
    local button = self:getButtonControl(modes[self.mode].title)
    local height = getTextManager():getFontHeight(UIFont.Small)
    button.textColor = {r = 0.68, g = 0.86, b = 0.75, a = 1}
    button:setHeight(height + 4)
    button:setTooltip(modes[self.mode].tooltip)
    button:setOnMouseOverFunction(self.onMouseOverButton)
    button:setOnMouseOutFunction(self.onMouseOutButton)
    self.control = button
    return button
end

function Handler:getItemsToTransfer()
    local app = App.get(self.playerNum)
    if not app then return {}, {} end
    local records, _, err = app.world:matchingRecords(self.mode)
    self.matchingError = err
    local items, selected = {}, {}
    for _, record in ipairs(records or {}) do
        items[#items + 1] = record.item
        selected[record.item] = true
    end
    return items, selected
end

function Handler:onMouseOverButton()
    local stamp = getTimestampMs()
    local loot = getPlayerLoot(self.playerNum)
    local inventoryRevision = self.inventoryWindow.inventoryPane.refreshContainerCount
    local lootRevision = loot and loot.inventoryPane and loot.inventoryPane.refreshContainerCount
    local inventoryContainer = self.inventoryWindow.inventoryPane.inventory
    local lootContainer = loot and loot.inventoryPane and loot.inventoryPane.inventory
    if not self.isMouseOver or not self.highlightStamp or stamp - self.highlightStamp >= 250
        or self.inventoryRevision ~= inventoryRevision or self.lootRevision ~= lootRevision
        or self.inventoryContainer ~= inventoryContainer or self.lootContainer ~= lootContainer then
        local _, selected = self:getItemsToTransfer()
        self.itemsToTransferMap = selected
        self.highlightStamp, self.inventoryRevision, self.lootRevision = stamp, inventoryRevision, lootRevision
        self.inventoryContainer, self.lootContainer = inventoryContainer, lootContainer
    end
    self.isMouseOver = true
    self.inventoryWindow.inventoryPane:setItemsToHighlight(self.control, self.itemsToTransferMap)
end

function Handler:onMouseOutButton()
    self.inventoryWindow.inventoryPane:setItemsToHighlight(self.control, nil)
    self.isMouseOver, self.highlightStamp, self.itemsToTransferMap = false, nil, nil
end

function Handler:perform()
    if isGamePaused() then return end
    local app, err = App.get(self.playerNum)
    if not app then return end
    local records, targets
    records, targets, err = app.world:matchingRecords(self.mode)
    if not records then Matching.UI.showProgress(self.playerNum, err); return end
    if #records == 0 then return Matching.UI.replaceAction(self.playerNum, function() return true end) end
    local types, seen = {}, {}
    for _, record in ipairs(records) do
        local fullType = tostring(record.item:getFullType())
        if not seen[fullType] then types[#types + 1] = fullType; seen[fullType] = true end
    end
    local request = {shortcutIntent = "matching:" .. self.mode, scope = "inventory", includeInventory = false, includeBags = true,
        filter = {all = false, ids = {}, types = types},
        destination = {kind = "matching", mode = self.mode}}
    local playerNum, mode = self.playerNum, self.mode
    return Matching.UI.replaceAction(playerNum, function()
        local _, current, problem = app.world:matchingRecords(mode)
        if not current then Matching.UI.showProgress(playerNum, problem); return nil, problem end
        local changed = #current ~= #targets
        for index, target in ipairs(targets) do
            local other = current[index]
            if not other or target.ref ~= other.ref then changed = true
            elseif target.point or other.point then
                local left, right = target.point or {}, other.point or {}
                if left.x ~= right.x or left.y ~= right.y or left.z ~= right.z then changed = true end
            end
        end
        if changed then
            problem = "The matching destinations changed while the previous job stopped. Click again to use the current destinations."
            Matching.UI.showProgress(playerNum, problem)
            return nil, problem
        end
        return Matching.UI.quickAction(playerNum, {kind = "matching", scope = "inventory"}, request)
    end)
end

function Handler:new()
    return ISInventoryWindowControlHandler.new(self)
end

local Displayed = Handler:derive("LootBoxMatchingTransferDisplayed")
Displayed.mode = "displayed"
local Nearby = Handler:derive("LootBoxMatchingTransferNearby")
Nearby.mode = "nearby"
local Condense = ISInventoryWindowControlHandler:derive("LootBoxCondense")

function Condense:shouldBeVisible()
    if getCore():isTutorial() then return false end
    local peer
    for _, class in ipairs(ISInventoryWindowContainerControls_HandlerList) do
        if class.Type == "ISInventoryWindowControlHandler_TransferAll" then peer = true; break end
    end
    if not peer then return false end
    local preferences, err = App.getPreferences()
    if err or preferences.condenseButton == false then return false end
    local player = self.playerObj
    return player ~= nil and player:getCurrentSquare() ~= nil and not player:getInventory():isEmpty()
end

function Condense:getControl()
    local preferences = App.getPreferences()
    local mode = preferences.condenseRebalance and "Optimize bag contents" or "Pack main inventory, heaviest first"
    local scope = preferences.condenseUseUnequipped and "Equipped and unequipped carried bags" or "Equipped bags only"
    local nested = preferences.condenseNested and "Nested contents included" or "Nested contents left in place"
    local button = self:getButtonControl("Condense")
    button:setTooltip(mode .. ".\n" .. scope .. ". " .. nested
        .. ".\nUses actual equipped reduction and native capacity. Bag objects stay in place. F7 opens Current job.")
    self.control = button
    return button
end

function Condense:perform()
    if isGamePaused() then return end
    Matching.UI.condense(self.playerNum)
end

function Condense:new()
    return ISInventoryWindowControlHandler.new(self)
end

local lootAvailable = pcall(require, "ISUI/LootWindow/ISLootWindowContainerControls")
local SmartTake = ISInventoryWindowControlHandler:derive("LootBoxSmartTake")

function SmartTake:shouldBeVisible()
    if getCore():isTutorial() then return hidden(self) end
    local preferences, err = App.getPreferences()
    if err or preferences.matchingTransferButtons == false then return hidden(self) end
    local list = self.floor and ISLootWindowContainerControls_FloorHandlerList or ISLootWindowContainerControls_HandlerList
    local present = false
    for _, class in ipairs(list or {}) do if class.Type == self.peer then present = true; break end end
    if not present or not self.playerObj or not self.playerObj:getCurrentSquare()
        or not self.container then return hidden(self) end
    if preferences.smartTakeAllContainers ~= false then return true end
    if self.container:isEmpty() then return hidden(self) end
    if self.mode == "all" and self.container.isEmptyOrUnwanted and self.container:isEmptyOrUnwanted(self.playerObj) then return hidden(self) end
    if self.mode == "matching" and self.playerObj:getInventory():isEmpty() then return hidden(self) end
    return true
end

function SmartTake:getControl()
    local title = self.mode == "all" and "Smart Take All" or "Smart Take Matching"
    local button = self:getButtonControl(title)
    local height = getTextManager():getFontHeight(UIFont.Small)
    button:setHeight(height + 4)
    button.textColor = {r = 0.68, g = 0.86, b = 0.75, a = 1}
    button:setTooltip((self.mode == "all" and "Smart Take All from eligible loot containers."
        or "Smart Take Matching: take types already present anywhere in your carried storage, including nested bags.")
        .. "\nFill bags with similar items first, then other carried bags by useful reduction, then main inventory."
        .. "\nSettings: all visible loot containers (default), or active container only."
        .. "\nProtected and unwanted items stay in place. Native capacity and your optional quick-review settings apply.")
    button:setOnMouseOverFunction(self.onMouseOverButton)
    button:setOnMouseOutFunction(self.onMouseOutButton)
    self.control = button
    return button
end

function SmartTake:getItemsToTransfer()
    local app = App.get(self.playerNum)
    if not app then return {}, {} end
    local records = app.world:smartLootRecords(self.mode, self.container, App.getPreferences().smartTakeAllContainers ~= false)
    local items, selected = {}, {}
    for _, record in ipairs(records or {}) do
        items[#items + 1], selected[record.item] = record.item, true
    end
    return items, selected
end

function SmartTake:onMouseOverButton()
    local stamp = getTimestampMs()
    if not self.isMouseOver or self.highlightContainer ~= self.container
        or not self.highlightStamp or stamp - self.highlightStamp >= 250 then
        local _, selected = self:getItemsToTransfer()
        self.itemsToTransferMap, self.highlightStamp, self.highlightContainer = selected, stamp, self.container
    end
    self.isMouseOver = true
    self.lootWindow.inventoryPane:setItemsToHighlight(self.control, self.itemsToTransferMap)
end

function SmartTake:onMouseOutButton()
    if self.lootWindow and self.lootWindow.inventoryPane then self.lootWindow.inventoryPane:setItemsToHighlight(self.control, nil) end
    self.isMouseOver, self.highlightStamp, self.itemsToTransferMap = false, nil, nil
end

function SmartTake:perform()
    if isGamePaused() then return end
    local app = App.get(self.playerNum)
    if not app then return end
    local allContainers = App.getPreferences().smartTakeAllContainers ~= false
    local records, err, sources = app.world:smartLootRecords(self.mode, self.container, allContainers)
    if not records then Matching.UI.showProgress(self.playerNum, err); return end
    if #records == 0 then return Matching.UI.replaceAction(self.playerNum, function() return true end) end
    local types, seen = {}, {}
    for _, record in ipairs(records) do
        local fullType = tostring(record.item:getFullType())
        if not seen[fullType] then types[#types + 1], seen[fullType] = fullType, true end
    end
    local request = {shortcutIntent = "smart:" .. self.mode, scope = allContainers and "lootPane" or "container", sourceContainer = not allContainers and self.container or nil,
        sourceContainers = allContainers and sources or nil, includeInventory = false, includeBags = false,
        excludeUnwanted = true, filter = {all = self.mode == "all", ids = {}, types = types}, destination = {kind = "inventory"}}
    local playerNum, context = self.playerNum, {kind = "container", container = self.container}
    return Matching.UI.replaceAction(playerNum, function()
        return Matching.UI.quickAction(playerNum, context, request)
    end)
end

function SmartTake:new() return ISInventoryWindowControlHandler.new(self) end

local smartClasses = {}
for _, floor in ipairs({false, true}) do
    for _, mode in ipairs({"all", "matching"}) do
        local prefix = floor and "ISLootWindowFloorControlHandler_" or "ISLootWindowObjectControlHandler_"
        local suffix = mode == "all" and "TakeAll" or "TakeSameType"
        local class = SmartTake:derive("LootBoxSmart" .. (floor and "Floor" or "Object") .. suffix)
        class.floor, class.mode, class.peer = floor, mode, prefix .. suffix
        smartClasses[#smartClasses + 1] = class
    end
end

local function installSmartTake()
    if not lootAvailable or not ISLootWindowContainerControls then return end
    for _, class in ipairs(smartClasses) do
        local list = class.floor and ISLootWindowContainerControls_FloorHandlerList or ISLootWindowContainerControls_HandlerList
        local add = class.floor and ISLootWindowContainerControls.AddFloorHandler or ISLootWindowContainerControls.AddHandler
        if type(list) == "table" and type(add) == "function" then
            add(class)
            for index = #list, 1, -1 do if list[index].Type == class.Type then table.remove(list, index) end end
            for index, peer in ipairs(list) do
                if peer.Type == class.peer then table.insert(list, index + 1, class); break end
            end
        end
    end
end

local function insertBefore(class, peer)
    ISInventoryWindowContainerControls.AddHandler(class)
    local list = ISInventoryWindowContainerControls_HandlerList
    for index = #list, 1, -1 do
        if list[index].Type == class.Type then table.remove(list, index) end
    end
    for index, candidate in ipairs(list) do
        if candidate.Type == peer then table.insert(list, index, class); return end
    end
    list[#list + 1] = class
end

local function insertAfter(class, peer)
    ISInventoryWindowContainerControls.AddHandler(class)
    local list = ISInventoryWindowContainerControls_HandlerList
    for index = #list, 1, -1 do
        if list[index].Type == class.Type then table.remove(list, index) end
    end
    for index, candidate in ipairs(list) do
        if candidate.Type == peer then table.insert(list, index + 1, class); return end
    end
    list[#list + 1] = class
end

function Matching.install(ui)
    if Matching.installed then return end
    Matching.installed, Matching.UI = true, ui
    installSmartTake()
    insertBefore(Condense, "ISInventoryWindowControlHandler_TransferAll")
    insertAfter(Displayed, modes.displayed.peer)
    insertAfter(Nearby, modes.nearby.peer)
end

Matching.Displayed, Matching.Nearby, Matching.Condense = Displayed, Nearby, Condense
Matching.SmartTake, Matching.smartClasses = SmartTake, smartClasses
return Matching
