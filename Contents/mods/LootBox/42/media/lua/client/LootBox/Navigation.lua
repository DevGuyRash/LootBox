-- View-only shortcuts for the inventory/loot list under the mouse.
local Navigation = {}
local bindings = {
    {name = "LootBoxScrollTop", key = "KEY_HOME", action = "top"},
    {name = "LootBoxScrollBottom", key = "KEY_END", action = "bottom"},
    {name = "LootBoxScrollPageUp", key = "KEY_PRIOR", action = "up"},
    {name = "LootBoxScrollPageDown", key = "KEY_NEXT", action = "down"},
}
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Navigation.scroll(pane, action)
    local height, total, row = pane:getScrollAreaHeight(), pane:getScrollHeight(), pane.itemHgt
    local current = pane.smoothScrollTargetY or pane:getYScroll()
    if not finite(height) or height <= 0 or not finite(total) or total < 0
        or not finite(row) or row <= 0 or not finite(current) then return false end
    local maximum = math.max(0, total - height)
    current = math.max(-maximum, math.min(0, current))
    -- Retain one row of overlap, including when the viewport has a partial row.
    -- A very short viewport still moves no further than its visible height.
    local distance = math.min(height > row and height - row or height,
        math.max(1, math.floor(height / row) - 1) * row)
    local target
    if action == "top" then target = 0
    elseif action == "bottom" then target = -maximum
    elseif action == "up" then target = current + distance
    elseif action == "down" then target = current - distance
    else return false end
    pane.smoothScrollY, pane.smoothScrollTargetY = nil, nil
    pane:setYScroll(math.max(-maximum, math.min(0, target)))
    return true
end

local function hoveredPane(endpoint, neat)
    local inventoryPage, lootPage = getPlayerInventory(0), getPlayerLoot(0)
    local result
    for _, page in pairs({inventoryPage, lootPage}) do
        local pane = page and page.inventoryPane
        if pane and page:isVisible() and not page.isCollapsed and pane:isVisible()
            and pane:isMouseOver() then
            if result and result ~= pane then return nil end
            result = pane
        end
    end
    if not result and endpoint and neat and neat.Keys and neat.Keys.hoveredPage then
        -- Some inventory views receive keyboard input over the page chrome,
        -- outside the rows' hit box. Use that same scope for view-only jumps.
        local page = neat.Keys.hoveredPage()
        if page and (page == inventoryPage or page == lootPage) and page:isVisible() and not page.isCollapsed
            and page.inventoryPane and page.inventoryPane:isVisible() then
            return page.inventoryPane
        end
    end
    return result
end

local function leaveKeyboardCursor(pane)
    local keys = NeatInventory and NeatInventory.Keys
    if pane.ninvKeyMode and keys and keys.leaveKeyMode then keys.leaveKeyMode(pane) end
end

local function clearHover(pane)
    pane.mouseOverOption, pane.buttonOption = 0, 0
    pane:hideButtons()
    if pane.toolRender and pane.toolRender:isVisible() then
        pane.toolRender:removeFromUIManager()
        pane.toolRender:setVisible(false)
    end
    if pane.parent.onCharacter then Key.setHighlightDoors(pane.player, nil) end
end

-- A changed scroll offset is not mouse input. Use screen coordinates, not
-- pane-relative Y (which changes when the contents scroll under the pointer).
local function holdHover(pane)
    if not pane.lootBoxHoverHooks then
        pane.lootBoxHoverHooks = true
        for _, name in ipairs({"onMouseMove", "updateTooltip"}) do
            local previous = pane[name]
            pane[name] = function(self, ...)
                local at = self.lootBoxHoverAt
                if at and self.inventory == at.inventory and getMouseX() == at.x and getMouseY() == at.y then
                    local player = getSpecificPlayer(self.player)
                    if player and player:getJoypadBind() == -1 then
                        -- A late inventory key listener can create a mouse-only
                        -- keyboard cursor after the endpoint has been handled.
                        leaveKeyboardCursor(self)
                        if not self.doController then
                            clearHover(self)
                            return
                        end
                    end
                end
                self.lootBoxHoverAt = nil
                return previous(self, ...)
            end
        end
        -- Native mouse-down and context menus consume the last hit-tested row.
        -- Re-hit-test through the active list/grid view before a stationary click.
        for _, name in ipairs({"onMouseDown", "onRightMouseUp", "onMouseWheel"}) do
            local previous = pane[name]
            pane[name] = function(self, ...)
                if self.lootBoxHoverAt then
                    self.lootBoxHoverAt = nil
                    self:onMouseMove(0, 0)
                end
                return previous(self, ...)
            end
        end
    end
    pane.lootBoxHoverAt = {x = getMouseX(), y = getMouseY(), inventory = pane.inventory}
    clearHover(pane)
end

function Navigation.onKeyStartPressed(key)
    local core = getCore()
    if core:isDoingTextEntry() or (UIManager and UIManager.isModalVisible and UIManager.isModalVisible())
        or (ISMouseDrag and ISMouseDrag.dragging) then return false end
    local player = getSpecificPlayer(0)
    if not player or player:isDead() or player:getJoypadBind() ~= -1 then return false end
    local menu = getPlayerContextMenu and getPlayerContextMenu(0)
    if menu and menu:isAnyVisible() then return false end
    local action
    for _, binding in ipairs(bindings) do
        if core:isKey(binding.name, key) then
            -- Ambiguous duplicate bindings do not move an unexpected direction.
            if action then return false end
            action = binding.action
        end
    end
    if not action then return false end
    local endpoint = action == "top" or action == "bottom"
    local neat = NeatInventory
    if endpoint and neat and ((neat.Settings and neat.Settings.panel) or (neat.Category and neat.Category.popup)) then
        return false
    end
    local pane = hoveredPane(endpoint, neat)
    if not pane or pane.dragging or pane.draggingMarquis or not Navigation.scroll(pane, action) then return false end
    if endpoint then
        leaveKeyboardCursor(pane)
        holdHover(pane)
    elseif pane.lootBoxHoverAt then
        pane.lootBoxHoverAt = nil
        pane:onMouseMove(0, 0)
    end
    if GameKeyboard and GameKeyboard.eatKeyPress then GameKeyboard.eatKeyPress(key) end
    return true, endpoint, pane
end

local neatKeyStart, lastNeatKey, endpointPane
local function dispatch(key)
    local handled, endpoint, pane = Navigation.onKeyStartPressed(key)
    if endpoint then
        endpointPane = pane
    elseif endpointPane and key ~= Keyboard.KEY_LSHIFT and key ~= Keyboard.KEY_RSHIFT
        and key ~= Keyboard.KEY_HOME and key ~= Keyboard.KEY_END then
        -- A fresh non-endpoint key may legitimately request a keyboard cursor.
        endpointPane.lootBoxHoverAt = nil
        endpointPane = nil
    end
    if neatKeyStart then
        if not endpoint then
            if key ~= Keyboard.KEY_LSHIFT and key ~= Keyboard.KEY_RSHIFT then lastNeatKey = key end
            return neatKeyStart(key)
        end
        -- Neat normally stops the previous held key at the start of an event.
        -- Its repeat listener still runs, even when we own this endpoint.
        local repeatTimer = NeatInventory.Shared and NeatInventory.Shared.Repeat
        if lastNeatKey and repeatTimer then repeatTimer.stop(lastNeatKey) end
        lastNeatKey = nil
    end
    return handled
end
local function attachNeatKeys()
    -- NeatUI's independent Home/End listener also selects a row and enables
    -- its controller tooltip. EatKeyPress does not stop other Lua listeners.
    local keys = NeatInventory and NeatInventory.Keys
    if keys and keys.leaveKeyMode and keys.onKeyStartPressed and keys.onKeyStartPressed ~= neatKeyStart then
        Events.OnKeyStartPressed.Remove(keys.onKeyStartPressed)
        neatKeyStart = keys.onKeyStartPressed
    end
end

function Navigation.install()
    if Navigation.installed then return end
    Navigation.installed = true
    require "keyBinding"
    local known = {}
    for _, binding in ipairs(keyBinding) do known[binding.value] = true end
    if not known["[LootBox]"] then keyBinding[#keyBinding + 1] = {value = "[LootBox]"} end
    for _, binding in ipairs(bindings) do
        if not known[binding.name] then
            keyBinding[#keyBinding + 1] = {value = binding.name, key = Keyboard[binding.key]}
        end
    end
    attachNeatKeys()
    Events.OnKeyStartPressed.Add(dispatch)
    Events.OnGameStart.Add(attachNeatKeys)
end

return Navigation
