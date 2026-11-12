package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local current, passed = nil, 0
local Base = {}
Base.__index = Base
function Base:derive(name)
    local class = setmetatable({Type = name}, {__index = self})
    class.__index = class
    return class
end
function Base:new() return setmetatable({altColor = false}, self) end
function Base:getButtonControl(title)
    if not self.control then
        self.control = {target = self,
            setWidth = function(s, value) s.width = value end,
            setHeight = function(s, value) s.height = value end,
            setTooltip = function(s, value) s.tooltip = value end,
            setOnMouseOverFunction = function(s, value) s.onmouseover = value end,
            setOnMouseOutFunction = function(s, value) s.onmouseout = value end,
        }
    end
    self.control.title = title
    return self.control
end

package.loaded["ISUI/InventoryWindow/ISInventoryWindowContainerControls"] = true
package.loaded["LootBox/App"] = {
    getPreferences = function() return current.preferences, current.preferenceError end,
    get = function(playerNum) current.appPlayer = playerNum; return current.app end,
}
function getPlayerLoot() return current.loot end
function getCore() return {isTutorial = function() return current.tutorial end} end
function getTimestampMs() return current.now end
function isGamePaused() return current.paused end
UIFont = {Small = "small"}
function getTextManager() return {
    getFontHeight = function(_, font) assert(font == UIFont.Small); return current.fontHeight end,
    MeasureStringX = function(_, font, text) assert(font == UIFont.Small); return #text * current.fontWidth end,
} end
function getTexture(path)
    return {path = path, getWidth = function() return 32 end, getHeight = function() return 16 end}
end

local function item(fullType)
    return {getFullType = function() return fullType end}
end

local function fixture()
    local f = {preferences = {matchingTransferButtons = true}, now = 1000, fontHeight = 14, fontWidth = 7,
        calls = 0, quick = {}, progress = {}, records = {}}
    current = f
    local inventory = {isEmpty = function() return f.emptyInventory == true end}
    local selectedBag = {isEmpty = function() return true end}
    local displayed = {isEmpty = function() return f.emptyTarget == true end}
    f.inventoryPane = {inventory = selectedBag, refreshContainerCount = 1,
        setItemsToHighlight = function(s, owner, items)
            if items ~= nil then s.owner, s.highlighted = owner, items
            elseif s.owner == owner then s.owner, s.highlighted = nil, nil end
        end}
    f.inventoryWindow = {inventoryPane = f.inventoryPane, player = 3}
    f.loot = {inventoryPane = {inventory = displayed, refreshContainerCount = 1}}
    f.player = {getInventory = function() return inventory end,
        getCurrentSquare = function() return not f.noSquare and {} or nil end}
    f.app = {world = {matchingRecords = function(_, mode)
        f.calls, f.lastMode = f.calls + 1, mode
        if f.matchingError then return nil, nil, f.matchingError end
        return f.records, {}
    end}}
    local one = {Type = "ISInventoryWindowControlHandler_TransferSameType", perform = function() end}
    local all = {Type = "ISInventoryWindowControlHandler_TransferSameTypeMultiContainer", perform = function() end}
    local transfer = {Type = "NativeTransferAll"}
    f.foreign = {Type = "ForeignModControl"}
    f.peers = {one, all}
    f.originalCallbacks = {one.perform, all.perform}
    ISInventoryWindowControlHandler = Base
    ISInventoryWindowContainerControls_HandlerList = {transfer, one, f.foreign, all}
    ISInventoryWindowContainerControls = {AddHandler = function(class)
        local classes = ISInventoryWindowContainerControls_HandlerList
        for index, candidate in ipairs(classes) do
            if candidate.Type == class.Type then classes[index] = class; return end
        end
        classes[#classes + 1] = class
    end}
    f.ui = {quickAction = function(playerNum, context, request)
        f.quick[#f.quick + 1] = {player = playerNum, context = context, request = request}
    end, showProgress = function(playerNum, reason)
        f.progress[#f.progress + 1] = {player = playerNum, reason = reason}
    end}
    package.loaded["LootBox/Matching"] = nil
    f.module = require "LootBox/Matching"
    f.module.install(f.ui)
    function f:handler(mode)
        local class = mode == "nearby" and self.module.Nearby or self.module.Displayed
        local value = class:new()
        value.playerNum, value.playerObj, value.inventoryWindow = 3, self.player, self.inventoryWindow
        value.container = selectedBag
        value:getControl()
        return value
    end
    return f
end

local function test(name, run)
    run(fixture())
    passed = passed + 1
    print("PASS " .. name)
end

test("companions follow their native peers and retain foreign handler order", function(f)
    local classes = ISInventoryWindowContainerControls_HandlerList
    assert(#classes == 6 and classes[2] == f.peers[1] and classes[3] == f.module.Displayed)
    assert(classes[4] == f.foreign and classes[5] == f.peers[2] and classes[6] == f.module.Nearby)
    assert(f.peers[1].perform == f.originalCallbacks[1] and f.peers[2].perform == f.originalCallbacks[2])
end)

test("repeated installation cannot duplicate or move controls", function(f)
    local before = {}
    for index, value in ipairs(ISInventoryWindowContainerControls_HandlerList) do before[index] = value end
    f.module.install(f.ui)
    for index, value in ipairs(ISInventoryWindowContainerControls_HandlerList) do assert(value == before[index]) end
    assert(#ISInventoryWindowContainerControls_HandlerList == 6)
end)

test("native matching images get a distinct all-source badge with measured sizing", function(f)
    local displayed, nearby = f:handler("displayed"), f:handler("nearby")
    assert(displayed.control.title == "ALL" and nearby.control.title == "ALL")
    assert(displayed.control.iconRight.path == "media/ui/inventoryPanes/TransferSameTypeOneContainer.png")
    assert(nearby.control.iconRight.path == "media/ui/inventoryPanes/TransferSameTypeMultiContainer.png")
    assert(displayed.control.width == 59 and displayed.control.height == 18)
    assert(displayed.control.iconRightWidth == 28 and displayed.control.iconRightHeight == 14 and displayed.control.titleLeft)
    assert(displayed.control.tooltip:find("ALL carried containers", 1, true))
    assert(nearby.control.tooltip:find("matching floor stacks", 1, true))
    local control = displayed.control
    f.fontHeight, f.fontWidth = 20, 10
    assert(displayed:getControl() == control and control.width == 80 and control.height == 24)
end)

test("aggregate sources remain available when the selected inventory bag is empty", function(f)
    assert(f:handler("displayed"):shouldBeVisible())
    assert(f:handler("nearby"):shouldBeVisible())
    f.emptyInventory = true
    assert(not f:handler("displayed"):shouldBeVisible() and not f:handler("nearby"):shouldBeVisible())
end)

test("an empty displayed target hides only its matching companion", function(f)
    f.emptyTarget = true
    assert(not f:handler("displayed"):shouldBeVisible())
    assert(f:handler("nearby"):shouldBeVisible())
end)

test("tutorial and incomplete world UI keep matching controls hidden", function(f)
    local handler = f:handler("displayed")
    f.tutorial = true; assert(not handler:shouldBeVisible())
    f.tutorial, f.noSquare = false, true; assert(not handler:shouldBeVisible())
    f.noSquare, f.loot = false, nil; assert(not handler:shouldBeVisible())
end)

test("removing a native peer does not leave an orphan companion", function(f)
    local classes = ISInventoryWindowContainerControls_HandlerList
    table.remove(classes, 2)
    assert(not f:handler("displayed"):shouldBeVisible())
    assert(f:handler("nearby"):shouldBeVisible())
end)

test("a disabled preference or damaged preferences hide the extension", function(f)
    local handler = f:handler("displayed")
    f.preferences.matchingTransferButtons = false; assert(not handler:shouldBeVisible())
    f.preferences.matchingTransferButtons, f.preferenceError = true, "Damaged preferences"
    assert(not handler:shouldBeVisible())
end)

test("hover previews cache ordinary frames and refresh hidden-source changes within the bounded age", function(f)
    local handler, first, second = f:handler("displayed"), item("Base.Nails"), item("Base.Bandage")
    f.records = {{item = first}}
    handler:onMouseOverButton()
    assert(f.calls == 1 and f.inventoryPane.highlighted[first])
    f.records, f.now = {{item = second}}, 1249
    handler:onMouseOverButton()
    assert(f.calls == 1 and f.inventoryPane.highlighted[first] and not f.inventoryPane.highlighted[second])
    f.now = 1250; handler:onMouseOverButton()
    assert(f.calls == 2 and f.inventoryPane.highlighted[second] and not f.inventoryPane.highlighted[first])
end)

test("inventory and loot revisions or selected identities refresh hover immediately", function(f)
    local handler = f:handler("displayed")
    handler:onMouseOverButton(); assert(f.calls == 1)
    f.inventoryPane.refreshContainerCount = 2; handler:onMouseOverButton(); assert(f.calls == 2)
    f.loot.inventoryPane.refreshContainerCount = 2; handler:onMouseOverButton(); assert(f.calls == 3)
    f.loot.inventoryPane.inventory = {isEmpty = function() return false end}
    handler:onMouseOverButton(); assert(f.calls == 4)
    f.inventoryPane.inventory = {}; handler:onMouseOverButton(); assert(f.calls == 5)
end)

test("mouse-out clears only the highlight owned by the companion", function(f)
    local handler = f:handler("displayed")
    handler:onMouseOverButton(); assert(f.inventoryPane.owner == handler.control)
    handler:onMouseOutButton(); assert(f.inventoryPane.owner == nil and not handler.isMouseOver)
    handler:onMouseOverButton()
    local foreign = {}; f.inventoryPane:setItemsToHighlight(foreign, {other = true})
    handler:onMouseOutButton(); assert(f.inventoryPane.owner == foreign and f.inventoryPane.highlighted.other)
end)

test("hiding a preference or losing startup state releases the companion highlight", function(f)
    local handler = f:handler("displayed")
    handler:onMouseOverButton()
    f.preferences.matchingTransferButtons = false
    assert(not handler:shouldBeVisible() and f.inventoryPane.owner == nil)
    f.preferences.matchingTransferButtons = true; handler:onMouseOverButton()
    f.noSquare = true
    assert(not handler:shouldBeVisible() and f.inventoryPane.owner == nil)
end)

test("click recomputes source matches and sends a deduplicated portable all-container request", function(f)
    local handler = f:handler("nearby")
    local old, currentItem = item("Base.Nails"), item("Base.Bandage")
    f.records = {{item = old}}; handler:onMouseOverButton()
    f.records = {{item = currentItem}, {item = currentItem}, {item = item("Base.Bandage")}}
    handler:perform()
    assert(f.calls == 2 and #f.quick == 1 and f.appPlayer == 3)
    local call = f.quick[1]
    assert(call.player == 3 and call.context.kind == "matching")
    assert(call.request.scope == "inventory" and call.request.includeBags == true and call.request.includeInventory == false)
    assert(call.request.destination.kind == "matching" and call.request.destination.mode == "nearby")
    assert(#call.request.filter.types == 1 and call.request.filter.types[1] == "Base.Bandage")
    assert(call.request.filter.all == false and call.request.destination.targets == nil)
end)

test("displayed clicks retain the displayed mode", function(f)
    f.records = {{item = item("Base.Nails")}}
    f:handler("displayed"):perform()
    assert(f.quick[1].request.destination.mode == "displayed")
end)

test("a matching click does not overwrite another mod's global placeholder", function(f)
    local previous, sentinel = _, {}
    _ = sentinel
    f.records = {{item = item("Base.Nails")}}
    f:handler("displayed"):perform()
    assert(_ == sentinel)
    _ = previous
end)

test("no matches is an ordinary native-style no-op", function(f)
    f:handler("nearby"):perform()
    assert(f.calls == 1 and #f.quick == 0 and #f.progress == 0)
end)

test("paused game input does not plan or start a transfer", function(f)
    f.paused = true
    f:handler("nearby"):perform()
    assert(f.calls == 0 and #f.quick == 0)
end)

test("native matching errors are reported without starting a partial transfer", function(f)
    f.matchingError = "Native matching rules are unavailable"
    f:handler("displayed"):perform()
    assert(#f.quick == 0 and #f.progress == 1 and f.progress[1].reason == f.matchingError)
end)

test("older builds without the native control system retain a harmless optional module", function(f)
    ISInventoryWindowControlHandler = nil
    package.loaded["LootBox/Matching"] = nil
    local unavailable = require "LootBox/Matching"
    assert(unavailable.install(f.ui) == false and unavailable.Displayed == nil)
    assert(#ISInventoryWindowContainerControls_HandlerList == 6 and #f.quick == 0)
end)

print(passed .. " matching toolbar cases passed (explicit native handler and App boundary doubles)")
