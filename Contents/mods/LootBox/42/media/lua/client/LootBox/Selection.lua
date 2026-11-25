require "ISUI/ISInventoryPane"
require "ISUI/ISTextBox"

local K = require "LootBox/UIKit"
local Selection = {}
local panes = setmetatable({}, { __mode = "k" })
local dialogs = {}
local scopeDepth, scopeBase = 0, nil
local installed = false
local AmountBox = ISTextBox:derive("LootBoxAmountBox")

local function pack(...)
    return { n = select("#", ...), ... }
end

local function actualItems(group)
    return ISInventoryPane.getActualItems({ group })
end

local function gridView(pane)
    local views = NeatInventory and NeatInventory.Views
    if views and views.isGrid(pane) then return views end
end

local function normalizeSelection(pane, selected)
    local result
    for _, group in ipairs(pane.itemslist or {}) do
        local representative = group.items[1]
        if not pane.collapsed[group.name] and #group.items > 2 and selected[representative] == "item" then
            if not result then
                result = {}
                for item, marker in pairs(selected) do result[item] = marker end
            end
            result[representative] = true
        end
    end
    return result or selected
end

local function revealSelection(pane, state)
    if not state.reveal then return end
    state.reveal = nil
    local first
    for row in pairs(pane.selected) do
        if type(row) == "number" and (not first or row < first) then first = row end
    end
    if not first then return end
    local top = math.max(0, (first - 2) * pane.itemHgt)
    local views = gridView(pane)
    if views then
        local y, height = views.itemTop(pane, first)
        top = math.max(0, y - height - (pane.headerHgt or 0))
    end
    pane:setYScroll(-math.min(top, math.max(0, pane:getScrollHeight() - pane:getHeight())))
    pane.smoothScrollY, pane.smoothScrollTargetY = nil, nil
end

local function invoke(pane, previous, method, ...)
    local state = panes[pane]
    local args = pack(...)
    if method == "restoreSelection" and state.partial then
        args[1] = normalizeSelection(pane, args[1])
    end
    if not state.cap and scopeDepth == 0 then
        local result = pack(previous(pane, unpack(args, 1, args.n)))
        if method == "renderdetails" and args[1] == false then revealSelection(pane, state) end
        return unpack(result, 1, result.n)
    end
    local old = ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER
    if scopeDepth == 0 then scopeBase = old end
    scopeDepth = scopeDepth + 1
    ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER = math.max(scopeBase, state.cap or scopeBase)
    local result = pack(pcall(function()
        local result = pack(previous(pane, unpack(args, 1, args.n)))
        if method == "renderdetails" and args[1] == false then revealSelection(pane, state) end
        return unpack(result, 1, result.n)
    end))
    ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER = old
    scopeDepth = scopeDepth - 1
    if scopeDepth == 0 then scopeBase = nil end
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end

function Selection.attach(pane)
    if not pane then return end
    local state = panes[pane]
    if not state then state = { wrappers = {} }; panes[pane] = state end
    for _, name in ipairs({ "selectIndex", "onMouseDown", "restoreSelection", "renderdetails" }) do
        local previous = pane[name]
        if previous and previous ~= state.wrappers[name] then
            local method = name
            local wrapper = function(self, ...) return invoke(self, previous, method, ...) end
            state.wrappers[name], pane[name] = wrapper, wrapper
        end
    end
end

local function currentPane(playerIndex, pane)
    local inventory, loot = getPlayerInventory(playerIndex), getPlayerLoot(playerIndex)
    return (inventory and inventory.inventoryPane == pane) or (loot and loot.inventoryPane == pane)
end

local function containsReference(group, references)
    for index = 2, #group.items do if references[group.items[index]] then return true end end
    return false
end

local function currentGroup(target)
    if getSpecificPlayer(target.playerIndex) ~= target.player or target.player:isDead()
        or target.player:getJoypadBind() ~= -1 or not currentPane(target.playerIndex, target.pane)
        or target.pane.inventory ~= target.inventory then
        return nil, "The source pane changed. Close this prompt and right-click the stack again."
    end
    for _, group in ipairs(target.pane.itemslist or {}) do
        if group.name == target.groupName and containsReference(group, target.members) then return group end
    end
    return nil, "That stack is no longer shown in its original pane. Close this prompt and try again."
end

local function groupForRow(pane, row)
    if not row then return nil end
    if not instanceof(row, "InventoryItem") then
        if row.invPanel == pane and row.items then return row end
        return nil
    end
    for _, group in ipairs(pane.itemslist or {}) do
        for _, item in ipairs(actualItems(group)) do if item == row then return group end end
    end
end

local function overPane(pane)
    local x, y = getMouseX(), getMouseY()
    local left, top = pane:getAbsoluteX(), pane:getAbsoluteY()
    return x >= left and y >= top and x < left + pane:getWidth() and y < top + pane:getHeight()
end

function Selection.capture(playerIndex, contextItems)
    local player = getSpecificPlayer(playerIndex)
    if not player or player:isDead() or player:getJoypadBind() ~= -1 then return nil end
    local references = {}
    for _, item in ipairs(ISInventoryPane.getActualItems(contextItems or {})) do references[item] = true end
    local pages = { getPlayerInventory(playerIndex), getPlayerLoot(playerIndex) }
    local result
    for _, page in pairs(pages) do
        local pane = page and page.inventoryPane
        if pane and overPane(pane) then
            local group = groupForRow(pane, pane.items and pane.items[pane.mouseOverOption])
            if group and containsReference(group, references) then
                local members = actualItems(group)
                if #members > 1 then
                    if result then return nil end
                    local originals = {}
                    for _, item in ipairs(members) do originals[item] = true end
                    result = { playerIndex = playerIndex, player = player, pane = pane, inventory = pane.inventory,
                        groupName = group.name, members = originals, maxCount = #members, itemName = members[1]:getName() }
                end
            end
        end
    end
    return result
end

local function amount(text, maximum)
    if type(text) ~= "string" or not text:match("^%d+$") then return nil end
    local count = tonumber(text)
    if not count or count < 1 or count > maximum or count ~= math.floor(count) then return nil end
    return count
end

function Selection.apply(target, text)
    local count = amount(text, target.maxCount)
    if not count then return nil, "Enter a whole number from 1 to " .. tostring(target.maxCount) .. "." end
    local group, problem = currentGroup(target)
    if not group then return nil, problem end
    Selection.attach(target.pane)
    panes[target.pane].partial = true
    target.pane:refreshContainer()
    group, problem = currentGroup(target)
    if not group then return nil, problem end
    local members = actualItems(group)
    target.maxCount = #members
    if count > #members then return nil, "Only " .. tostring(#members) .. " items remain. Choose a smaller amount." end
    local pane, selected = target.pane, {}
    local state = panes[pane]
    local views = gridView(pane)
    if count < #members then
        state.cap = math.max(state.cap or scopeBase or ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER, count + 1)
    end
    if views then
        views.buildItems(pane)
        for index, row in ipairs(pane.items) do
            if row == group then views.setOpen(pane, index, count < #members); break end
        end
    else
        pane.collapsed[group.name] = count == #members
    end
    if count == #members then
        selected[group.items[1]] = "group"
    else
        for index = 1, count do selected[members[index]] = "item" end
    end
    pane.selected = {}
    pane:restoreSelection(selected)
    pane.firstSelect, pane.dragging, pane.dragStarted = nil, nil, false
    if ISMouseDrag.draggingFocus == pane then
        ISMouseDrag.dragging, ISMouseDrag.draggingFocus = nil, nil
    end
    state.reveal = true
    return true
end

function AmountBox:destroy()
    if self.destroyed then return end
    self.destroyed = true
    if self.entry and self.entry:isFocused() then self.entry:unfocus() end
    if self.colorPicker then
        self.colorPicker:setVisible(false)
        self.colorPicker:removeFromUIManager()
    end
    if dialogs[self.selectionTarget.playerIndex] == self then dialogs[self.selectionTarget.playerIndex] = nil end
    ISTextBox.destroy(self)
end

function AmountBox:refreshDescription()
    local text = self.selectionTarget.itemName .. "\nChoose 1-" .. tostring(self.selectionTarget.maxCount)
        .. " items.\nThen drag or right-click the highlighted items."
    if self.selectionError then text = text .. "\n" .. self.selectionError end
    self.description:set(text)
    local bodyHeight = math.min(self.description:measure(self.description.width), math.max(80, getCore():getScreenHeight() - 230))
    self.description:setHeight(bodyHeight)
    self.entry:setY(self.description.y + bodyHeight + 10)
    self.yes:setY(self.entry:getBottom() + 10)
    self.no:setY(self.yes.y)
    self:setHeight(self.yes:getBottom() + 11)
    self:setY(math.max(0, (getCore():getScreenHeight() - self.height) / 2))
end

function AmountBox:onChoice(button)
    if button.internal == "CANCEL" then self:destroy(); return end
    local ok, problem = Selection.apply(self.selectionTarget, self.entry:getText())
    if ok then self:destroy(); return end
    self.selectionError = problem
    self:refreshDescription()
    self.entry:focus()
    self.entry:selectAll()
end

function AmountBox:validate(text)
    local group, problem = currentGroup(self.selectionTarget)
    if not group then self:setValidateTooltipText(problem); return false end
    self:setValidateTooltipText("Enter a whole number from 1 to " .. tostring(self.selectionTarget.maxCount) .. ".")
    return amount(text, self.selectionTarget.maxCount) ~= nil
end

function AmountBox:onCommandEntered()
    self:updateButtons()
    if self.yes:isEnabled() then self.yes.onclick(self.yes.target, self.yes) end
end

function AmountBox:onOtherKey(key)
    if key == Keyboard.KEY_ESCAPE then self.no.onclick(self.no.target, self.no) end
end

function Selection.open(target)
    local _, problem = currentGroup(target)
    if dialogs[target.playerIndex] then dialogs[target.playerIndex]:destroy() end
    local width = math.min(460, getCore():getScreenWidth() - 20)
    local box = AmountBox:new(math.max(1, (getCore():getScreenWidth() - width) / 2), 100, width, 220,
        "Select amount", "1", nil, nil, target.playerIndex)
    box.selectionTarget, box.selectionError = target, problem
    box:initialise()
    box.yes.onclick, box.no.onclick = AmountBox.onChoice, AmountBox.onChoice
    box.backgroundColor, box.borderColor = K.color("glass"), K.color("line", 0.22)
    box.description = K.text(box, "", "text")
    K.place(box.description, 11, box:titleBarHeight() + 10, box.width - 22, 80)
    box:refreshDescription()
    box:setOnlyNumbers(true)
    box:setValidateFunction(box, AmountBox.validate)
    box.entry.onCommandEntered = function() box:onCommandEntered() end
    box.entry.onOtherKey = function(_, key) box:onOtherKey(key) end
    box:addToUIManager()
    box:bringToTop()
    box.entry:focus()
    box.entry:selectAll()
    dialogs[target.playerIndex] = box
    return box
end

function Selection.closeAll()
    local active = {}
    for _, dialog in pairs(dialogs) do active[#active + 1] = dialog end
    for _, dialog in ipairs(active) do dialog:destroy() end
end

function Selection.install()
    if installed then return end
    installed = true
    if Events.OnDisconnect then Events.OnDisconnect.Add(Selection.closeAll) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(Selection.closeAll) end
end

return Selection
