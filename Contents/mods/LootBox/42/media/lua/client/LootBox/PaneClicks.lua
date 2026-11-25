local Focus = require "LootBox/ContainerFocus"
local Neat = require "LootBox/NeatContainerHeaders"
local Clicks = {}

local function pack(...) return { n = select("#", ...), ... } end

local function hit(pane, x, y, wantRow)
    if not pane or not pane.inventoryPage or type(x) ~= "number" or type(y) ~= "number" then return end
    local visibleY = y + pane:getYScroll()
    if pane.inventoryPage.isCollapsed or x < 0 or x >= (pane.width or math.huge)
        or visibleY < (pane.headerHgt or 0) or visibleY >= (pane.height or math.huge)
        or (pane.vscroll and pane:isMouseOverScrollBar()) then return end
    local kind, index, shown = Neat.hit(pane, x, y, wantRow)
    if kind and kind ~= "row" then return kind, index end
    if not wantRow or not pane.items then return end
    if not kind then
        if not pane.column3 or x >= pane.column3 or not pane.itemHgt or pane.itemHgt <= 0 then return end
        index = math.floor((y - pane.headerHgt) / pane.itemHgt) + 1
        shown = pane.inventory -- vanilla displays just this container
    end
    local row = pane.items[index]
    local container = Focus.owner(row)
    if container and (not shown or shown == container) and Focus.button(pane.inventoryPage, container) then
        return "row", index, container, row
    end
end

local function right(previous, pane, x, y, ...)
    local allowed = Focus.enabled() and (pane.player == nil or pane.player == 0)
    local kind, value, container, row = hit(pane, x, y, allowed)
    if kind == "stale" then return true end
    if kind == "title" then
        -- Delegate once to the real current sidebar callback, even when focus
        -- is off; this is the only owner of title/icon menu construction.
        value:onRightMouseDown(value:getMouseX(), value:getMouseY())
        return true
    end
    if kind == "row" and pane.mouseOverOption == value and not (pane.dragging and pane.dragStarted)
        and Focus.select(pane.inventoryPage, container, nil, Neat.syncRows) then
        local again, at, owner, current = hit(pane, x, y, true)
        -- Another mod/refresh can remove, replace or move the row synchronously.
        -- Do not ever open a sibling's menu on this gesture.
        if again ~= "row" or owner ~= container or not Focus.sameRow(row, current) then return true end
        pane.mouseOverOption = at
    end
    return previous(pane, x, y, ...)
end

local function left(previous, pane, x, y, ...)
    -- Native handles the press, modifiers, stack toggling, double clicks and
    -- every drag/drop. Focus after a completed real click only, not on hover,
    -- marquee, drag release, synthetic onMouseUp(0,0) or an outside release.
    local row, container
    if Focus.enabled() and (pane.player == nil or pane.player == 0) and type(pane.downX) == "number" and type(pane.downY) == "number"
        and math.abs(x - pane.downX) <= 4 and math.abs(y - pane.downY) <= 4
        and not pane.dragStarted and not pane.draggingMarquis and pane.dragging
        and (not ISMouseDrag or not ISMouseDrag.draggingFocus or ISMouseDrag.draggingFocus == pane) then
        local kind, i, c, r = hit(pane, x, y, true)
        if kind == "row" and i == pane.dragging then row, container = r, c end
    end
    local result = pack(previous(pane, x, y, ...))
    if row and Focus.owner(row) == container then Focus.select(pane.inventoryPage, container, nil, Neat.syncRows) end
    return unpack(result, 1, result.n)
end

-- Selection.attach owns onMouseDown (expanded stack cap). Never compete for
-- that method or add a global hover/tick hook. Cooperative outer wraps can be
-- seen at the next refresh; guard each operation against double dispatch.
local function attach(pane, state, name, handler)
    local previous = pane[name]
    if not previous or previous == state[name] then return end
    local busy = name .. "Active"
    local function wrapper(self, ...)
        if state[busy] then return previous(self, ...) end
        state[busy] = true
        local result = pack(pcall(handler, previous, self, ...))
        state[busy] = nil
        if not result[1] then error(result[2], 0) end
        return unpack(result, 2, result.n)
    end
    pane[name], state[name] = wrapper, wrapper
end

function Clicks.attach(pane)
    if not pane or not pane.inventoryPage then return end
    -- On an incomplete/older surface without native selection, retain .15's
    -- optional title forwarding only. Do not wrap a stock item-only pane there.
    local canSelect = pane.inventoryPage.selectContainer ~= nil
    local v = NeatInventory and NeatInventory.enabled and NeatInventory.Views
    if not canSelect and not (v and v.isGrid and v.multi and v.combined and v.grid and v.headAt) then return end
    local state = pane.lootBoxClicks or {}
    pane.lootBoxClicks = state
    attach(pane, state, "onRightMouseUp", right)
    if canSelect then attach(pane, state, "onMouseUp", left) end
end

return Clicks
