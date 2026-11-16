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

local function hoveredPane()
    local result
    for _, page in pairs({getPlayerInventory(0), getPlayerLoot(0)}) do
        local pane = page and page.inventoryPane
        if pane and page:isVisible() and not page.isCollapsed and pane:isVisible()
            and pane:isMouseOver() then
            if result and result ~= pane then return nil end
            result = pane
        end
    end
    return result
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
    local pane = hoveredPane()
    if not pane or not Navigation.scroll(pane, action) then return false end
    if GameKeyboard and GameKeyboard.eatKeyPress then GameKeyboard.eatKeyPress(key) end
    return true
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
    Events.OnKeyStartPressed.Add(Navigation.onKeyStartPressed)
end

return Navigation
