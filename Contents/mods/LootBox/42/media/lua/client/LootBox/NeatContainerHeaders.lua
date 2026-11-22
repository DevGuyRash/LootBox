-- Optional NeatUI Inventory hit-test adapter; the click/selection policy is
-- shared with vanilla. Content coordinates from the native event, not a pick
-- from the screen or the last hovered/selected item.
local Neat = {}
local Focus = require "LootBox/ContainerFocus"

local function views(pane)
    local v = NeatInventory and NeatInventory.enabled and NeatInventory.Views
    if v and v.isGrid and v.multi and v.combined and v.grid and v.headAt and v.isGrid(pane) then return v end
end

-- nil = ordinary stock layout; "none" = this view owns the point but there is
-- no proven item or title (gutter, clipped/stale cells, Equipped heading...).
function Neat.hit(pane, x, y, wantRow)
    local v, page = views(pane), pane.inventoryPage
    if not v or not page then return end
    local grid = v.grid(pane)
    local multi, combined = v.multi(pane), v.combined(pane)
    local head = v.headAt(pane, grid, x, y)
    if head then
        local seg = head.seg
        if not multi or combined or not seg or seg.equipped or not seg.container then return "none" end
        local b = seg.button
        if not b or not b.onRightMouseDown or Focus.button(page, seg.container, b) ~= b then return "stale" end
        return "title", b
    end
    if not wantRow or not v.indexAt then return "none" end
    if pane.ninvItemsGen ~= pane.ninvRefreshGen or (multi and (pane.ninvCombinedBuilt == true) ~= (combined == true)) then return "none" end
    local i = v.indexAt(pane, grid, x, y)
    if not i or i < 1 or not pane.items or not pane.items[i] then return "none" end
    if multi and not combined then
        local sec = v.sectionOfRow and v.sectionOfRow(pane, i)
        if not sec or not sec.button or Focus.button(page, sec.container, sec.button) ~= sec.button then return "none" end
        return "row", i, sec.container
    end
    if multi then return "row", i end -- Combined: require unanimous actual row ownership
    return "row", i, pane.inventory
end

-- ISInventoryPage:selectContainer refreshes itemslist; NeatUI normally waits
-- until render to flatten it into items. A menu built during this same event
-- must see the new row objects now, without painting, scrolling or toggling.
function Neat.syncRows(pane)
    local v = views(pane)
    if v and v.buildItems and pane.items and pane.itemslist then v.buildItems(pane) end
end

return Neat
