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
        texture = "media/ui/inventoryPanes/TransferSameTypeOneContainer.png",
        tooltip = "Transfer matching items from ALL carried containers to the displayed loot container.\nIncludes nested carried bags. Keep, favorite, equipped and attached items stay protected.",
    },
    nearby = {
        peer = "ISInventoryWindowControlHandler_TransferSameTypeMultiContainer",
        texture = "media/ui/inventoryPanes/TransferSameTypeMultiContainer.png",
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
    if self.isMouseOver and self.control and self.inventoryWindow and self.inventoryWindow.inventoryPane then self:onMouseOutButton() end
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
    local button = self:getButtonControl("ALL")
    local texture = getTexture(modes[self.mode].texture)
    local height = getTextManager():getFontHeight(UIFont.Small)
    local width = texture:getWidth() / texture:getHeight() * height
    button.titleLeft = true
    button.iconRight, button.iconRightHeight, button.iconRightWidth = texture, height, width
    button.textColor = {r = 0.68, g = 0.86, b = 0.75, a = 1}
    button:setWidth(getTextManager():MeasureStringX(UIFont.Small, "ALL") + width + 10)
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
    local records, _
    records, _, err = app.world:matchingRecords(self.mode)
    if not records then Matching.UI.showProgress(self.playerNum, err); return end
    if #records == 0 then return end
    local types, seen = {}, {}
    for _, record in ipairs(records) do
        local fullType = tostring(record.item:getFullType())
        if not seen[fullType] then types[#types + 1] = fullType; seen[fullType] = true end
    end
    local request = {scope = "inventory", includeInventory = false, includeBags = true,
        filter = {all = false, ids = {}, types = types},
        destination = {kind = "matching", mode = self.mode}}
    Matching.UI.quickAction(self.playerNum, {kind = "matching", scope = "inventory"}, request)
end

function Handler:new()
    return ISInventoryWindowControlHandler.new(self)
end

local Displayed = Handler:derive("LootBoxMatchingTransferDisplayed")
Displayed.mode = "displayed"
local Nearby = Handler:derive("LootBoxMatchingTransferNearby")
Nearby.mode = "nearby"

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
    insertAfter(Displayed, modes.displayed.peer)
    insertAfter(Nearby, modes.nearby.peer)
end

Matching.Displayed, Matching.Nearby = Displayed, Nearby
return Matching
