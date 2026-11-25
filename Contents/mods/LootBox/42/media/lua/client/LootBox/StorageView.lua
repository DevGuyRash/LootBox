-- Labels where the player is already looking: container titles, icons and
-- tooltips, "Goes to Kitchen crate" on an item, and a marker that leads there.
local App = require "LootBox/App"
local Describe = require "LootBox/Describe"
local Facts = require "LootBox/Facts"
local K = require "LootBox/UIKit"
local Labels = require "LootBox/Labels"
local Log = require "LootBox/Log"

local View = { shown = {} }
local LINES_MS, SHOW_MS, NEAR_MS, MARK = 500, 20000, 5000, 8
local orders = { first = "Filled before others", last = "Filled when others are full" }

-- Containers ---------------------------------------------------------------

local function describe(app, container)
    if container:getType() == "floor" or container == app.player:getInventory() then return nil end
    local labels, details = app:labels(container), app:storageDetails(container)
    if #labels == 0 and not details.name and not details.order then return nil end
    return labels, details
end

-- "Crate: Nails, Tools +2"
function View.title(name, labels)
    return #labels > 0 and name .. ": " .. Describe.labels(labels, App.category, 2) or name
end

local function drawMark(button)
    if not button.lootBoxLabelled then return end
    local c = K.colors.accent
    button:drawRect(3, button.height - MARK - 3, MARK, MARK, 1, 0, 0, 0)
    button:drawRect(4, button.height - MARK - 2, MARK - 2, MARK - 2, 1, c.r, c.g, c.b)
end

-- The window names its icons anew at every refresh, so this starts from its own text.
local function decorate(page, button, app, titles)
    local container = button.inventory
    local labels, details = nil, nil
    if container then labels, details = describe(app, container) end
    button.lootBoxLabelled = titles and labels ~= nil and #labels > 0
    if not labels or not titles then return end
    local given = app.world:givenName(container)
    local name = given or button.name or Describe.container(container)
    -- The game compares a bag's icon with the bag's own name.
    if not container:getContainingItem() then button.name = K.fit(View.title(name, labels), math.max(80, page.width * 0.5)) end
    local tip = { given or button.tooltip or name }
    if #labels > 0 then tip[#tip + 1] = "Belongs here: " .. Describe.labels(labels, App.category, 8) end
    if details.order then tip[#tip + 1] = orders[details.order] end
    button.tooltip = table.concat(tip, "\n")
    if not button.lootBoxMark then
        button.lootBoxMark = true
        local render = button.render
        function button:render(...)
            render(self, ...)
            drawMark(self)
        end
    end
end

-- A bag keeps its own name on its icon, so only the window that shows it can say more.
local function titleBag(page, app)
    local container = page.inventoryPane and page.inventoryPane.inventory
    if not page.title or not container or not container:getContainingItem() or not App.preference("storageTitles") then return end
    local labels = app:labels(container)
    if #labels > 0 then page.title = K.fit(View.title(page.title, labels), math.max(80, page.width * 0.5)) end
end

-- Once every icon is there and before the window, or NeatUI, reads their names.
function View.refreshContainers(page, phase)
    if phase == "end" then
        local app = App.peek(page.player)
        if app then titleBag(page, app) end
        return
    end
    if phase ~= "buttonsAdded" then return end
    local app = App.get(page.player)
    if not app then return end
    local titles = App.preference("storageTitles")
    app.world:pass(function()
        for _, button in ipairs(page.backpacks or {}) do decorate(page, button, app, titles) end
    end)
end

-- Labels change what the windows say, so they are drawn again.
function View.refresh(playerIndex)
    for _, page in ipairs({ getPlayerInventory(playerIndex) or false, getPlayerLoot(playerIndex) or false }) do
        if page and page.refreshBackpacks then page:refreshBackpacks() end
    end
end

-- Items --------------------------------------------------------------------

function View.where(storage)
    if storage.carried then return storage.name .. " (carried)" end
    if storage.tiles == math.huge or storage.container and storage.tiles <= 2 then return storage.name end
    return storage.name .. " (" .. Facts.awayText(storage.tiles) .. ")"
end

local function lines(app, item)
    local result = {}
    local function add(text, tone) result[#result + 1] = { text = text, color = K.colors[tone] } end
    local inside = item.getInventory and item:getInventory()
    if inside then
        local labels = app:labels(inside)
        if #labels > 0 then add("Belongs inside: " .. Describe.labels(labels, App.category, 4), "accent") end
    end
    local home, placed, full = app.world:home(item)
    if home then add("Goes to " .. View.where(home), "accent")
    elseif full then add("Goes to " .. full.name .. ", which is full", "warn")
    elseif placed then add("In its place", "good") end
    if app:isKept(item) or app:isTypeKept(tostring(item:getFullType())) then add("Keep", "info") end
    if not app.world:owns(item:getContainer()) and app.world.graph
        and app.world.graph:matchesFilter(app:getChecklist(), app.world:describe(item)) then add("On your loot list", "info") end
    return result
end

local known = {}
function View.lines(item, playerIndex)
    if not item or not instanceof(item, "InventoryItem") or App.preference("storageTips") == false then return {} end
    local stamp = getTimestampMs()
    playerIndex = playerIndex or 0
    if known.item == item and known.player == playerIndex and stamp >= known.stamp and stamp - known.stamp < LINES_MS then return known.lines end
    known = { item = item, player = playerIndex, stamp = stamp, lines = {} }
    local app = App.peek(playerIndex)
    if app then known.lines = Log.guard("StorageView.lines", lines, app, item) or {} end
    return known.lines
end

local function ownerOf(tip) return tip.owner and tip.owner.player or 0 end

local function drawBelow(tip)
    if tip.contextMenu then return end
    local shown = tip.item and tip:isVisible() and not (ISContextMenu.instance and ISContextMenu.instance.visibleCheck) and View.lines(tip.item, ownerOf(tip)) or {}
    if #shown == 0 then return end
    local width, height = tip.width, #shown * K.LINE + 8
    for _, line in ipairs(shown) do width = math.max(width, K.width(line.text) + 16) end
    local y = tip.height
    -- A controller's tooltip hangs over the window it belongs to.
    if tip.anchorBottomLeft and not tip.followMouse or tip:getAbsoluteY() + y + height > getCore():getScreenHeight() then y = -height end
    if tip:getAbsoluteY() + y < 0 then y = tip.height end
    local x = math.min(0, getCore():getScreenWidth() - tip:getAbsoluteX() - width)
    local b, e = tip.backgroundColor, tip.borderColor
    tip:drawRect(x, y, width, height, b.a, b.r, b.g, b.b)
    tip:drawRectBorder(x, y, width, height, e.a, e.r, e.g, e.b)
    for index, line in ipairs(shown) do
        tip:drawText(line.text, x + 8, y + 4 + (index - 1) * K.LINE, line.color.r, line.color.g, line.color.b, 1, K.FONT)
    end
end

-- Tooltip replacements load after LootBox, so this waits until the game starts.
local function hookTooltip()
    if View.hooked or not ISToolTipInv then return end
    View.hooked = true
    local neat = NeatInventory and NeatInventory.enabled and NeatInventory.Tooltip
    if neat and type(neat.extraLines) == "function" then
        local extra = neat.extraLines
        function neat.extraLines(tip, ...)
            local result = extra(tip, ...)
            tip.lootBoxDrawn = true
            for _, line in ipairs(tip.contextMenu == nil and View.lines(tip.item, ownerOf(tip)) or {}) do result[#result + 1] = line end
            return result
        end
    end
    -- Another mod may draw some tooltips itself, without NeatUI's lines.
    local render = ISToolTipInv.render
    function ISToolTipInv:render(...)
        self.lootBoxDrawn = nil
        render(self, ...)
        if not self.lootBoxDrawn then Log.guard("StorageView.tooltip", drawBelow, self) end
    end
end

-- Show me ------------------------------------------------------------------

local function unmark(playerIndex)
    local shown = View.shown[playerIndex]
    if not shown then return end
    View.shown[playerIndex] = nil
    if shown.marker then getWorldMarkers():removePlayerHomingPoint(shown.player, shown.marker) end
    if shown.object then shown.object:setOutlineHighlight(playerIndex, false) end
end

-- storage comes from world:storages(). Returns what to tell the player.
function View.show(playerIndex, storage)
    unmark(playerIndex)
    local player = getSpecificPlayer(playerIndex)
    if storage.carried then return true, "You are carrying " .. storage.name end
    local point = storage.point
    if not player or not point then return nil, "Where " .. storage.name .. " is now is not known" end
    local c = K.colors.accent
    local shown = { player = player, point = point, since = getTimestampMs(),
        marker = getWorldMarkers():addPlayerHomingPoint(player, point.x, point.y, c.r, c.g, c.b, 1) }
    local parent = storage.container and storage.container:getParent()
    if parent and not instanceof(parent, "IsoPlayer") and parent.setOutlineHighlight then
        shown.object = parent
        parent:setOutlineHighlight(playerIndex, true)
        parent:setOutlineHighlightCol(playerIndex, c.r, c.g, c.b, 1)
    end
    View.shown[playerIndex] = shown
    local floors = point.z - player:getCurrentSquare():getZ()
    return true, View.where(storage) .. (floors > 0 and ", upstairs" or floors < 0 and ", downstairs" or "")
end

function View.tick()
    for playerIndex, shown in pairs(View.shown) do
        local square = getSpecificPlayer(playerIndex) == shown.player and shown.player:getCurrentSquare()
        local near = square and square:getZ() == shown.point.z
            and math.abs(square:getX() - shown.point.x) <= 1 and math.abs(square:getY() - shown.point.y) <= 1
        local now = getTimestampMs()
        -- Once there, the outline alone still tells it from its neighbours for a moment.
        if square and near and shown.marker then
            getWorldMarkers():removePlayerHomingPoint(shown.player, shown.marker)
            shown.marker, shown.till = nil, now + NEAR_MS
        end
        if not square or now >= (shown.till or shown.since + SHOW_MS) or now < shown.since then
            unmark(playerIndex)
            return
        end
    end
end

function View.closeAll()
    View.shown, known = {}, {}
end

function View.install()
    Events.OnRefreshInventoryWindowContainers.Add(function(page, phase) Log.guard("StorageView.containers", View.refreshContainers, page, phase) end)
    Events.OnGameStart.Add(hookTooltip)
end

View.hookTooltip = hookTooltip
return View
