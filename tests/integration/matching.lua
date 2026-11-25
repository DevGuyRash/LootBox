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
    self.control.width = getTextManager():MeasureStringX(UIFont.Small, title) + 10
    return self.control
end

package.loaded["ISUI/InventoryWindow/ISInventoryWindowContainerControls"] = true
package.loaded["ISUI/LootWindow/ISLootWindowContainerControls"] = true
package.loaded["LootBox/App"] = {
    getPreferences = function() return current.preferences, current.preferenceError end,
    preference = function(key) if current.preferences[key] == nil then return key == "smartTakeAllContainers" or nil end return current.preferences[key] end,
    get = function(playerNum) current.appPlayer = playerNum; return current.app end,
}
function getPlayerLoot() return current.loot end
function getPlayerInventory() return current.inventoryWindow end
local function changed(f) f.loot.inventoryPane.refreshContainerCount = f.loot.inventoryPane.refreshContainerCount + 1; f.now = f.now + 1000 end
function getCore() return {isTutorial = function() return current.tutorial end} end
function getTimestampMs() return current.now end
function isGamePaused() return current.paused end
UIFont = {Small = "small"}
function getTextManager() return {
    getFontHeight = function(_, font) assert(font == UIFont.Small); return current.fontHeight end,
    MeasureStringX = function(_, font, text) assert(font == UIFont.Small); return #text * current.fontWidth end,
} end
local function item(fullType)
    return {getFullType = function() return fullType end}
end

local function fixture()
    local f = {preferences = {matchingTransferButtons = true, smartTakeAllContainers = false}, now = 1000, fontHeight = 14, fontWidth = 7,
        calls = 0, quick = {}, progress = {}, records = {{item = item("Base.Hinge")}}}
    current = f
    local inventory = {isEmpty = function() return f.emptyInventory == true end}
    local selectedBag = {isEmpty = function() return true end}
    local displayed = {isEmpty = function() return f.emptyTarget == true end,
        isEmptyOrUnwanted = function(_, player) assert(player == f.player); return f.emptyTarget or f.onlyUnwanted or false end}
    f.displayed = displayed
    f.inventoryPane = {inventory = selectedBag, refreshContainerCount = 1,
        setItemsToHighlight = function(s, owner, items)
            if items ~= nil then s.owner, s.highlighted = owner, items
            elseif s.owner == owner then s.owner, s.highlighted = nil, nil end
        end}
    f.inventoryWindow = {inventoryPane = f.inventoryPane, player = 3}
    f.loot = {inventoryPane = {inventory = displayed, refreshContainerCount = 1,
        setItemsToHighlight = f.inventoryPane.setItemsToHighlight}}
    f.player = {getInventory = function() return inventory end,
        getCurrentSquare = function() return not f.noSquare and {} or nil end}
    f.app = {world = {matchingRecords = function(_, mode)
        f.calls, f.lastMode = f.calls + 1, mode
        if f.matchingError then return nil, nil, f.matchingError end
        return f.records, f.targets or {}
    end, smartLootRecords = function(_, mode, source, allContainers)
        f.smartAll = allContainers
        f.smartCalls, f.smartMode, f.smartSource = (f.smartCalls or 0) + 1, mode, source
        if f.smartError then return nil, f.smartError end
        return f.records, nil, f.sources or {source}
    end}}
    local one = {Type = "ISInventoryWindowControlHandler_TransferSameType", perform = function() end}
    local all = {Type = "ISInventoryWindowControlHandler_TransferSameTypeMultiContainer", perform = function() end}
    local transfer = {Type = "ISInventoryWindowControlHandler_TransferAll"}
    f.transferPeer = transfer
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
    local objectAll = {Type = "ISLootWindowObjectControlHandler_TakeAll", perform = function() end}
    local objectMatching = {Type = "ISLootWindowObjectControlHandler_TakeSameType", perform = function() end}
    local floorAll = {Type = "ISLootWindowFloorControlHandler_TakeAll", perform = function() end}
    local floorMatching = {Type = "ISLootWindowFloorControlHandler_TakeSameType", perform = function() end}
    f.lootForeign = {Type = "ForeignLootControl"}
    f.lootPeers = {objectAll, objectMatching, floorAll, floorMatching}
    f.lootCallbacks = {objectAll.perform, objectMatching.perform, floorAll.perform, floorMatching.perform}
    ISLootWindowContainerControls_HandlerList = {objectAll, objectMatching, f.lootForeign}
    ISLootWindowContainerControls_FloorHandlerList = {floorAll, floorMatching}
    local function add(list, class)
        for index, candidate in ipairs(list) do
            if candidate.Type == class.Type then list[index] = class; return end
        end
        list[#list + 1] = class
    end
    ISLootWindowContainerControls = {
        AddHandler = function(class) add(ISLootWindowContainerControls_HandlerList, class) end,
        AddFloorHandler = function(class) add(ISLootWindowContainerControls_FloorHandlerList, class) end,
    }
    f.ui = {condense = function(playerNum) f.condensePlayer = playerNum end, act = function(playerNum, request, options)
        f.quick[#f.quick + 1] = {player = playerNum, request = request, options = options}
    end, say = function(playerNum, reason)
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
    function f:smart(mode, floor)
        for _, class in ipairs(self.module.smartClasses) do
            if class.mode == mode and class.floor == (floor == true) then
                local value = class:new()
                value.playerNum, value.playerObj, value.lootWindow = 3, self.player, self.loot
                value.container = displayed
                value:getControl()
                return value
            end
        end
        error("Missing Smart Take class")
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
    assert(#classes == 7 and classes[1] == f.module.Condense and classes[2] == f.transferPeer)
    assert(classes[3] == f.peers[1] and classes[4] == f.module.Displayed)
    assert(classes[5] == f.foreign and classes[6] == f.peers[2] and classes[7] == f.module.Nearby)
    assert(f.peers[1].perform == f.originalCallbacks[1] and f.peers[2].perform == f.originalCallbacks[2])
end)

test("repeated installation cannot duplicate or move controls", function(f)
    local before = {}
    for index, value in ipairs(ISInventoryWindowContainerControls_HandlerList) do before[index] = value end
    f.module.install(f.ui)
    for index, value in ipairs(ISInventoryWindowContainerControls_HandlerList) do assert(value == before[index]) end
    assert(#ISInventoryWindowContainerControls_HandlerList == 7)
end)

test("inventory matching companions name distinct destinations with compact native sizing", function(f)
    local displayed, nearby = f:handler("displayed"), f:handler("nearby")
    assert(displayed.control.title == "Match Displayed" and nearby.control.title == "Match Nearby")
    assert(displayed.control.width == 115 and displayed.control.height == 18)
    assert(nearby.control.width == 94 and nearby.control.height == 18)
    assert(not displayed.control.iconRight and not displayed.control.titleLeft)
    assert(not nearby.control.iconRight and not nearby.control.titleLeft)
    assert(displayed.control.tooltip:find("all your bags", 1, true) and nearby.control.tooltip:find("nearby", 1, true))
    local displayedControl, nearbyControl = displayed.control, nearby.control
    f.fontHeight, f.fontWidth = 20, 10
    assert(displayed:getControl() == displayedControl and nearby:getControl() == nearbyControl)
    assert(displayedControl.width == 160 and displayedControl.height == 24)
    assert(nearbyControl.width == 130 and nearbyControl.height == 24)
    f.fontHeight, f.fontWidth = 14, 7
    assert(displayed:getControl() == displayedControl and nearby:getControl() == nearbyControl)
    assert(displayedControl.width == 115 and displayedControl.height == 18)
    assert(nearbyControl.width == 94 and nearbyControl.height == 18)
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
    for index, class in ipairs(classes) do if class == f.peers[1] then table.remove(classes, index); break end end
    assert(not f:handler("displayed"):shouldBeVisible())
    assert(f:handler("nearby"):shouldBeVisible())
end)

test("a disabled preference hides the extension", function(f)
    local handler = f:handler("displayed")
    f.preferences.matchingTransferButtons = false; assert(not handler:shouldBeVisible())
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
    assert(call.player == 3)
    assert(call.request.scope == "inventory" and call.request.includeBags == true and call.request.includeInventory == false)
    assert(call.request.destination.kind == "matching" and call.request.destination.mode == "nearby")
    assert(call.request.shortcutIntent == "matching:nearby")
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

test("paused game input does not plan or start a transfer", function(f)
    f.paused = true
    f:handler("nearby"):perform()
    assert(f.calls == 0 and #f.quick == 0 and not f.continueCalls)
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
    assert(#ISInventoryWindowContainerControls_HandlerList == 7 and #f.quick == 0)
end)

test("Smart Take companions follow each native object and floor peer without changing callbacks", function(f)
    local object, floor = ISLootWindowContainerControls_HandlerList, ISLootWindowContainerControls_FloorHandlerList
    assert(#object == 5 and object[1] == f.lootPeers[1] and object[3] == f.lootPeers[2] and object[5] == f.lootForeign)
    assert(object[2].mode == "all" and object[4].mode == "matching")
    assert(#floor == 4 and floor[1] == f.lootPeers[3] and floor[3] == f.lootPeers[4])
    assert(floor[2].floor and floor[2].mode == "all" and floor[4].floor and floor[4].mode == "matching")
    for index, peer in ipairs(f.lootPeers) do assert(peer.perform == f.lootCallbacks[index]) end
    local beforeObject, beforeFloor = {}, {}
    for index, class in ipairs(object) do beforeObject[index] = class end
    for index, class in ipairs(floor) do beforeFloor[index] = class end
    f.module.install(f.ui)
    assert(#object == 5 and #floor == 4)
    for index, class in ipairs(object) do assert(class == beforeObject[index]) end
    for index, class in ipairs(floor) do assert(class == beforeFloor[index]) end
end)

test("Smart Take All captures one displayed source and uses all carried destinations for its player", function(f)
    for _, floor in ipairs({false, true}) do
        f.records = {{item = item("Base.Nails")}}
        local handler = f:smart("all", floor)
        assert(handler:shouldBeVisible())
        handler:perform()
        local call = f.quick[#f.quick]
        assert(call.player == 3 and f.appPlayer == 3)
        assert(call.request.scope == "container" and call.request.sourceContainer == f.displayed)
        assert(call.request.shortcutIntent == "smart:all")
        assert(call.request.includeInventory == false and call.request.includeBags == false and call.request.excludeUnwanted == true)
        assert(call.request.filter.all == true and call.request.destination.kind == "inventory")
        f.loot.inventoryPane.inventory = {}
        assert(call.request.sourceContainer == f.displayed)
    end
end)

test("Smart Take Matching checks fresh records and deduplicates actual types on each click", function(f)
    local handler, old, fresh = f:smart("matching"), item("Base.Nails"), item("Base.Bandage")
    f.records = {{item = old}}; handler:onMouseOverButton()
    f.records = {{item = fresh}, {item = fresh}, {item = item("Base.Bandage")}}
    handler:perform()
    assert(f.smartCalls == 2 and f.smartMode == "matching" and f.smartSource == f.displayed)
    local chosen = f.quick[1].request
    assert(chosen.filter.all == false and #chosen.filter.types == 1 and chosen.filter.types[1] == "Base.Bandage")
    assert(chosen.destination.kind == "inventory" and chosen.sourceContainer == f.displayed)
    f.records = {{item = old}}; handler:perform()
    assert(f.smartCalls == 3 and f.quick[2].request.filter.types[1] == "Base.Nails")
end)

test("Smart matching remains visible when the selected carried bag is empty", function(f)
    assert(f.inventoryPane.inventory:isEmpty() and f:smart("matching"):shouldBeVisible())
    f.records = {}
    assert(not f:smart("matching"):shouldBeVisible())
end)

test("Smart Take hover follows the displayed container and clears only its own highlight", function(f)
    local handler, nail, bandage = f:smart("matching", true), item("Base.Nails"), item("Base.Bandage")
    f.records = {{item = nail}}; handler:onMouseOverButton()
    assert(f.loot.inventoryPane.owner == handler.control and f.loot.inventoryPane.highlighted[nail])
    f.records, f.now = {{item = bandage}}, 1249; handler:onMouseOverButton()
    assert(f.smartCalls == 1 and f.loot.inventoryPane.highlighted[nail])
    f.now = 1250; handler:onMouseOverButton()
    assert(f.smartCalls == 2 and f.loot.inventoryPane.highlighted[bandage])
    handler.container = {}; handler:onMouseOverButton(); assert(f.smartCalls == 3 and f.smartSource == handler.container)
    local foreign = {}; f.loot.inventoryPane:setItemsToHighlight(foreign, {foreign = true})
    handler:onMouseOutButton()
    assert(f.loot.inventoryPane.owner == foreign and f.loot.inventoryPane.highlighted.foreign)
    handler:onMouseOverButton(); handler:onMouseOutButton()
    assert(f.loot.inventoryPane.owner == nil and not handler.isMouseOver)
end)

test("Smart Take visibility follows tutorial preference world state and native unwanted-only sources", function(f)
    local handler = f:smart("all")
    handler:onMouseOverButton()
    f.tutorial = true; assert(not handler:shouldBeVisible() and f.loot.inventoryPane.owner == nil)
    f.tutorial, f.preferences.matchingTransferButtons = false, false; assert(not handler:shouldBeVisible())
    f.preferences.matchingTransferButtons, f.noSquare = true, true; assert(not handler:shouldBeVisible())
    f.noSquare, f.records = false, {}; changed(f); assert(not handler:shouldBeVisible(), "Nothing eligible")
    f.records = {{item = item("Base.Nails")}}; changed(f); assert(handler:shouldBeVisible())
end)

test("removing object or floor native peers hides only the corresponding Smart Take action", function(f)
    for _, floor in ipairs({false, true}) do
        local list = floor and ISLootWindowContainerControls_FloorHandlerList or ISLootWindowContainerControls_HandlerList
        for index, class in ipairs(list) do
            if class.Type == (floor and f.lootPeers[3].Type or f.lootPeers[1].Type) then table.remove(list, index); break end
        end
        assert(not f:smart("all", floor):shouldBeVisible() and f:smart("matching", floor):shouldBeVisible())
    end
end)

test("Smart Take empty matches paused input and native failures cannot start partial jobs", function(f)
    local handler = f:smart("matching")
    f.records = {}
    handler:perform(); assert(#f.quick == 0 and f.progress[1].reason == "Nothing to take")
    f.paused = true; handler:perform(); assert(f.smartCalls == 1 and #f.quick == 0)
    f.paused, f.smartError = false, "Displayed source changed"; handler:perform()
    assert(#f.quick == 0 and f.progress[2].player == 3 and f.progress[2].reason == f.smartError)
end)





test("Smart Take buttons use compact native title sizing on object and floor footers", function(f)
    for _, floor in ipairs({false, true}) do
        f.fontHeight, f.fontWidth = 14, 7
        local matching, all = f:smart("matching", floor), f:smart("all", floor)
        local matchingControl, allControl = matching.control, all.control
        assert(matchingControl.title == "Smart Take Matching" and matchingControl.width == 143 and matchingControl.height == 18)
        assert(allControl.title == "Smart Take All" and allControl.width == 108 and allControl.height == 18)
        assert(not matchingControl.iconRight and not matchingControl.titleLeft)
        assert(matchingControl.tooltip:find("similar items first", 1, true))
        f.fontHeight, f.fontWidth = 20, 10
        assert(matching:getControl() == matchingControl and all:getControl() == allControl)
        assert(matchingControl.width == 200 and matchingControl.height == 24)
        assert(allControl.width == 150 and allControl.height == 24)
        f.fontHeight, f.fontWidth = 14, 7
        assert(matching:getControl() == matchingControl and matchingControl.width == 143 and matchingControl.height == 18)
        assert(all:getControl() == allControl and allControl.width == 108 and allControl.height == 18)
    end
end)

test("Condense belongs before Transfer All and follows its own visibility preference", function(f)
    local handler = f.module.Condense:new()
    handler.playerNum, handler.playerObj = 3, f.player
    assert(handler:shouldBeVisible())
    handler:getControl(); assert(handler.control.title == "Condense" and handler.control.tooltip:find("Equipped bags only", 1, true))
    handler:perform(); assert(f.condensePlayer == 3)
    f.condensePlayer, f.paused = nil, true; handler:perform(); assert(f.condensePlayer == nil)
    f.paused, f.preferences.condenseButton = false, false; assert(not handler:shouldBeVisible())
    f.preferences.condenseButton, f.tutorial = true, true; assert(not handler:shouldBeVisible())
    f.tutorial, f.emptyInventory = false, true; assert(not handler:shouldBeVisible())
end)

test("all-visible Smart Take supports empty active sources and captures eligible sources", function(f)
    f.preferences.smartTakeAllContainers = true
    f.emptyTarget = true
    f.sources = {{}, {}}
    f.records = {{item = item("Base.Nails")}}
    for _, mode in ipairs({"all", "matching"}) do
        local handler = f:smart(mode)
        assert(handler:shouldBeVisible())
        handler:perform()
        local request = f.quick[#f.quick].request
        assert(f.smartAll and request.scope == "lootPane" and request.sourceContainer == nil)
        assert(request.sourceContainers == f.sources)
    end
end)

test("Smart Take default is all-visible and active-only preference is honored", function(f)
    f.preferences.smartTakeAllContainers = nil
    f.records = {{item = item("Base.Nails")}}
    f:smart("all"):perform()
    assert(f.smartAll and f.quick[1].request.scope == "lootPane")
    f.preferences.smartTakeAllContainers = false
    f:smart("all"):perform()
    assert(not f.smartAll and f.quick[2].request.scope == "container")
end)

test("matching buttons appear only while something matches, without rescanning every frame", function(f)
    local handler = f:handler("displayed")
    assert(handler:shouldBeVisible() and f.calls == 1)
    for _ = 1, 20 do f.now = f.now + 1000; handler:shouldBeVisible() end
    assert(f.calls == 1, "Nothing changed, so nothing is rescanned")
    f.records = {}; changed(f)
    assert(not handler:shouldBeVisible() and f.calls == 2)
    f.app.active = function() return true end
    changed(f); handler:shouldBeVisible()
    assert(f.calls == 2, "Not while a job keeps changing containers")
    f.app.active, f.loot.isCollapsed, f.inventoryWindow.isCollapsed = nil, true, true
    changed(f)
    assert(not handler:shouldBeVisible() and f.calls == 2)
    f.inventoryWindow.isCollapsed = nil
end)

test("a click with nothing to do says so and starts nothing", function(f)
    f.records = {}
    f:handler("nearby"):perform()
    assert(#f.quick == 0 and f.progress[1].reason == "Nothing matches")
end)

test("toolbar clicks carry one logged interaction", function(f)
    f.records = {{item = item("Base.Nails")}}
    f:handler("displayed"):perform(); f:smart("all"):perform()
    local first, second = f.quick[1].options.interaction, f.quick[2].options.interaction
    assert(type(first) == "number" and type(second) == "number" and first ~= second)
end)

print(passed .. " matching toolbar cases passed (explicit native handler and App boundary doubles)")
