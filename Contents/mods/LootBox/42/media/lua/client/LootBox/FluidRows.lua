-- The rows of LootBox's fluid menus: one shared click, and never more than a
-- screenful in any submenu.
local Log = require "LootBox/Log"
local Rows = {LIMIT = 8}
local marker = {}

function Rows.present(menu, title)
    for _, option in ipairs(menu.options or {}) do
        if option.target == marker and option.name == title then return true end
    end
    return false
end

-- Another mod's entry of the same name keeps the place it already has.
function Rows.claimed(menu, title)
    for _, option in ipairs(menu.options or {}) do
        if option.target ~= marker and type(option.name) == "string"
            and option.name:lower():gsub("[%s%.]+$", "") == title:lower() then return true end
    end
    return false
end

local function stockFluid(menu)
    local stock = ISFluidContainerMenu
    for _, option in ipairs(menu.options or {}) do
        local child = stock and option.subOption and menu.getSubMenu and menu:getSubMenu(option.subOption)
        for _, row in ipairs(child and child.options or {}) do
            if row.onSelect and (row.onSelect == stock.transferFluids or row.onSelect == stock.showInfo) then return option.name end
        end
    end
    local name = getText and getText("ContextMenu_Fluid")
    for _, option in ipairs(menu.options or {}) do if option.name == name then return name end end
end

-- Directly after the game's own Fluid entry, or last when it has none.
function Rows.entry(menu, title)
    local after = menu.insertOptionAfter and stockFluid(menu)
    if after then return menu:insertOptionAfter(after, title, marker, nil) end
    return menu:addOption(title, marker, nil)
end

function Rows.icon(option, texture, item)
    option.iconTexture = texture and getTexture(texture) or nil
    option.itemForTexture = not option.iconTexture and item or nil
end

function Rows.run(row)
    local ctx = row.ctx
    if ctx.click.used then return end
    ctx.click.used = true
    local player = getSpecificPlayer(ctx.playerIndex)
    local label = ctx.title .. " > " .. row.title
    local id = ctx.interaction and ctx.interaction(ctx.origin, label) or Log.intent(ctx.origin, label, player)
    local app = require("LootBox/App").get(ctx.playerIndex)
    local ok, reason
    if app == ctx.app then ok, reason = row.start(id) else reason = "The session changed; reopen the menu." end
    if not ok then
        local text = ctx.title .. ": " .. tostring(reason or "The selection is no longer available.")
        Log.warn(id, "REFUSED", "at", "start", "reason", text, "player", Log.player(player))
        if player and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(player, text) end
    end
    return ok, reason
end

local function grouped(rows)
    local groups, byKind = {}, {}
    for _, row in ipairs(rows) do
        local group = row.kind and byKind[row.kind]
        if group then group[#group + 1] = row
        else
            group = {row}
            groups[#groups + 1] = group
            if row.kind then byKind[row.kind] = group end
        end
    end
    if #groups == #rows then return rows end
    local out = {}
    for _, group in ipairs(groups) do
        local first, count, children = group[1], 0, {}
        if #group == 1 then out[#out + 1] = first
        else
            children[1] = first.all and first.all(group) or nil
            for _, row in ipairs(group) do
                children[#children + 1] = row
                count = count + (row.count or 1)
            end
            out[#out + 1] = {title = first.kind .. " (" .. count .. ")", item = first.item,
                texture = first.texture, children = children, flat = true}
        end
    end
    return out
end

local show
-- row: title, start(id) or children, and optionally kind (what it is grouped
-- by), count (vessels it stands for), all(rows) (one row for a whole group),
-- item or texture, and tip.
function Rows.fill(ctx, menu, rows, flat)
    if #rows > Rows.LIMIT and not flat then rows = grouped(rows) end
    local last = #rows > Rows.LIMIT and Rows.LIMIT - 1 or #rows
    for index = 1, last do show(ctx, menu, rows[index]) end
    if last == #rows then return end
    local rest = {}
    for index = last + 1, #rows do rest[#rest + 1] = rows[index] end
    show(ctx, menu, {title = "More (" .. #rest .. ")", children = rest, flat = true})
end

show = function(ctx, menu, row)
    row.ctx = ctx
    local option = row.children and menu:addOption(row.title, marker, nil) or menu:addOption(row.title, row, Rows.run)
    if not option then return end
    Rows.icon(option, row.texture, row.item)
    if row.tip then ctx.tooltip(option, row.title, row.tip) end
    if row.children then
        local child = ISContextMenu:getNew(menu)
        menu:addSubMenu(option, child)
        Rows.fill(ctx, child, row.children, row.flat)
    end
end

-- One entry with its rows; nothing at all when there is nothing to choose.
function Rows.add(ctx, menu, title, texture, item, tip, rows)
    if #rows == 0 or Rows.present(menu, title) then return false end
    local option = Rows.entry(menu, title)
    if not option then return false end
    Rows.icon(option, texture, item)
    if tip then ctx.tooltip(option, title, tip) end
    local child = ISContextMenu:getNew(menu)
    menu:addSubMenu(option, child)
    Rows.fill(setmetatable({title = title}, {__index = ctx}), child, rows)
    return true
end

-- Identical names get the place each vessel is in.
function Rows.disambiguate(rows)
    local places, counts = {}, {}
    for _, row in ipairs(rows) do
        places[row.title] = places[row.title] or {}
        if row.place and not places[row.title][row.place] then
            places[row.title][row.place] = true
            counts[row.title] = (counts[row.title] or 0) + 1
        end
    end
    for _, row in ipairs(rows) do
        if (counts[row.title] or 0) > 1 then row.suffix = " - " .. row.place end
    end
    for _, row in ipairs(rows) do if row.suffix then row.title, row.suffix = row.title .. row.suffix, nil end end
    return rows
end

return Rows
