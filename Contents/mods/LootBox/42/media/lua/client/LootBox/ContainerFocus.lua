-- One native Mod Options value for every mouse surface; no polling or shadow save.
local Focus = {}
local option
local id = "activateClickedContainer"

function Focus.register(options)
    option = options:getOption(id) or options:addTickBox(id, "Activate the clicked container", true,
        "Make the clicked item's container active in either window. Right-clicking a container icon or section title also selects it before opening its menu.")
end

function Focus.enabled() return not option or option:getValue() == true end

-- Resolve by native identity, never a name, slot number, item type or tile.
-- Prefer the original widget when it still owns the target after a sidebar
-- rebuild. Otherwise require a unique replacement for that exact container.
function Focus.button(page, container, preferred)
    if not page or not container then return end
    local found, ambiguous
    for _, b in ipairs(page.backpacks or {}) do
        if b.inventory == container and b.parent and b.parent.parent == page then
            if b == preferred then return b end
            if found then ambiguous = true end
            found = b
        end
    end
    if not ambiguous then return found end
end

local function itemOwner(item)
    if item and instanceof(item, "InventoryItem") then return item:getContainer() end
end

-- Native groups have a dummy first entry, followed by the actual members.
-- A merged stack with multiple physical sources has no one container to focus.
function Focus.owner(row)
    if not row then return end
    if instanceof(row, "InventoryItem") then return itemOwner(row) end
    local items = type(row) == "table" and row.items
    if type(items) ~= "table" or #items < 2 then return end
    local container = itemOwner(items[2])
    if not container then return end
    for j = 3, #items do if itemOwner(items[j]) ~= container then return end end
    return container
end

-- Refreshes can replace a stock group table, not its item objects. Never use
-- just the representative item to redirect an input onto a different stack.
function Focus.sameRow(a, b)
    if not a or not b then return false end
    if a == b then return true end
    if instanceof(a, "InventoryItem") or instanceof(b, "InventoryItem") then return false end
    if type(a.items) ~= "table" or type(b.items) ~= "table" or #a.items ~= #b.items then return false end
    for j = 2, #a.items do if a.items[j] ~= b.items[j] then return false end end
    return #a.items >= 2
end

-- Use the real native selector, including its locked-container, exploration,
-- sound and host-owned inventory semantics. Do not call onBackpackClick: that
-- represents a different gesture and NeatUI would switch off Combined view.
function Focus.select(page, container, preferred, syncRows)
    local pane = page and page.inventoryPane
    if not Focus.enabled() or not pane or not page.selectContainer or not container
        or pane.inventory == container or page.isCollapsed
        or (JoypadState and JoypadState.players and JoypadState.players[page.player + 1]) then return false end
    local button = Focus.button(page, container, preferred)
    if not button or (preferred and button ~= preferred) then return false end
    local actor = getSpecificPlayer(page.player)
    if not actor or (container.isLockedToCharacter and container:isLockedToCharacter(actor)) then return false end
    local markers = pane.selected and pane.saveSelection and pane.restoreSelection and pane:saveSelection({})
    local anchor = pane.items and pane.firstSelect and pane.items[pane.firstSelect]
    page:selectContainer(button) -- clears selection and recycles pooled buttons synchronously
    if page.inventoryPane == pane then
        if syncRows then syncRows(pane) end
        if markers then pane:restoreSelection(markers) end
        if anchor and not Focus.sameRow(anchor, pane.items and pane.items[pane.firstSelect]) then
            pane.firstSelect = nil
            for i, row in ipairs(pane.items or {}) do
                if Focus.sameRow(anchor, row) then pane.firstSelect = i; break end
            end
        end
    end
    return true -- attempted; caller must revalidate target after native callbacks
end

return Focus
