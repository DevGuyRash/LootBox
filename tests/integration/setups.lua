package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local files, denied = {}, false
function getFileReader(path)
    if not files[path] then return nil end
    local read = false
    return { readLine = function() if not read then read = true; return files[path] end end, close = function() end }
end
function getFileWriter(path)
    if denied then return nil end
    local text = ""
    return { write = function(_, part) text = text .. part end, close = function() files[path] = text end }
end

local worldName, username, player
function getSpecificPlayer() return player end
function getWorld() return { getWorld = function() return worldName end } end
function getTimestampMs() return 0 end
function getText(key) return key end
function getAllItems()
    return { size = function() return 2 end, get = function(_, index)
        return { getObsolete = function() return false end, isHidden = function() return false end,
            getFullName = function() return index == 0 and "Example.Widget" or "Base.Apple" end,
            getDisplayName = function() return index == 0 and "Widget" or "Apple" end,
            getDisplayCategory = function() return index == 0 and "Tool" or "Food" end }
    end }
end
Events = nil
package.loaded["LootBox/World"] = { new = function(_, state)
    return { key = function(_, container) return container.id end, itemId = function(_, item) return item.id end,
        discover = function() end, observeNearby = function() return false end,
        protected = function(_, item) return state.keep[item.id] == true end }
end }
package.loaded["LootBox/Jobs"] = { new = function()
    return { status = function() return { state = "idle" } end, cancel = function() return true end,
        tick = function() end, start = function() return true end }
end }
package.loaded["LootBox/TillFull"] = {new = function() error("Unexpected consumption boundary") end}
package.loaded["LootBox/AutoNeeds"] = {interruptObservation = function() end, step = function() end}
local App = require "LootBox/App"
local Store = require "LootBox/Store"
local function fixture()
    App.reset()
    files, denied, worldName, username = {}, false, "server:one", "Alice"
    player = { getUsername = function() return username end, getPlayerNum = function() return 0 end,
        getSquare = function(self) return self.square end, square = { name = "current floor" } }
    return assert(App.get(0))
end

local function request(scope, destination)
    return { scope = scope or "inventory", includeInventory = true, includeBags = false,
        filter = { ids = { "native:Tool" }, types = { "Base.Bandage" }, all = false },
        destination = { kind = destination or "labels", labels = { "native:Tool" } },
        sourceLabels = { "native:Food" } }
end

local passed = 0
local function test(name, run)
    local app = fixture()
    run(app)
    passed = passed + 1
    print("PASS " .. name)
end

test("Smart Take all visible containers defaults on and stores only scope not native references", function(app)
    local preferences = assert(App.getPreferences())
    assert(preferences.smartTakeAllContainers == true)
    preferences.smartTakeAllContainers = false
    assert(App.setPreferences(preferences))
    assert(App.getPreferences().smartTakeAllContainers == false)
    local Setups = require "LootBox/Setups"
    local saved = assert(Setups.request({scope = "lootPane", includeBags = true, includeInventory = true,
        sourceContainers = {{native = true}}, filter = {all = true}, destination = {kind = "inventory"}}))
    assert(saved.scope == "lootPane" and saved.sourceContainers == nil and not saved.includeBags and not saved.includeInventory)
    local visible = {{id = "a"}, {id = "b"}}
    app.world.smartLootSources = function(_, container, all) assert(container == nil and all); return visible end
    assert(app:resolveSetup(saved).sourceContainers == visible)
end)

test("quick reviews default off while interface features stay on and copies remain independent", function()
    local preferences, err = App.getPreferences()
    assert(not err)
    for _, name in ipairs({ "tillFullEnabled", "contextMenus", "inventoryShortcuts", "worldShortcuts", "vehicleShortcuts",
        "matchingTransferButtons", "rememberLastSetup", "jobBar", "detailedLog" }) do
        assert(preferences[name] == true)
    end
    for _, name in ipairs({"tillFullBothNeeds", "confirmQuickMoves", "confirmQuickCleanup", "confirmBinReviews"}) do assert(preferences[name] == false) end
    preferences.contextMenus = false
    assert(App.getPreferences().contextMenus == true)
end)

test("context toggles survive an application restart and apply across worlds", function()
    assert(App.setPreferences({ contextMenus = false, vehicleShortcuts = false }))
    App.reset()
    assert(App.getPreferences().contextMenus == false)
    assert(App.getPreferences().vehicleShortcuts == false)
    assert(App.getPreferences().jobBar == true)
    worldName = "server:two"
    assert(App.get(0))
    assert(App.getPreferences().contextMenus == false)
end)

test("unknown settings and failed writes do not alter active preferences", function()
    assert(not App.setPreferences({ madeUpOption = true }))
    assert(not App.setPreferences({ contextMenus = "off" }))
    denied = true
    assert(not App.setPreferences({ contextMenus = false }))
    assert(App.getPreferences().contextMenus == true)
    denied = false
    App.reset()
    assert(App.getPreferences().contextMenus == true)
end)

test("saved workflows survive restart without retaining runtime references", function(app)
    local setup = request("container", "container")
    local nativeRef = {}; nativeRef.self = nativeRef
    setup.sourceContainer, setup.destination.ref = nativeRef, nativeRef
    setup.callback = function() error("Must not be serialized") end
    local id = assert(app:saveSetup("  Store tools  ", setup))
    App.reset()
    app = assert(App.get(0))
    local presets = app:getSetups().presets
    assert(#presets == 1 and presets[1].id == id and presets[1].name == "Store tools")
    local saved = presets[1].setup
    assert(saved.sourceContainer == nil and saved.destination.ref == nil and saved.callback == nil)
    assert(saved.scope == "container" and saved.destination.kind == "container")
    assert(saved.includeInventory == true and saved.includeBags == false)
    assert(saved.filter.ids[1] == "native:Tool" and saved.filter.types[1] == "Base.Bandage")
    assert(saved.sourceLabels[1] == "native:Food")
    assert(saved.destination.labels[1] == "native:Tool")
    presets[1].setup.filter.types[1] = "Do.Not.Mutate"
    assert(app:getSetups().presets[1].setup.filter.types[1] == "Base.Bandage")
end)

test("a reused setup binds source and destination to the freshly clicked containers", function(app)
    local id = assert(app:saveSetup("Move between selected containers", request("container", "container")))
    local first, second, third = { id = "first" }, { id = "second" }, { id = "third" }
    local resolved = assert(app:loadSetup(id, { sourceContainer = first, targetContainer = second }))
    assert(resolved.sourceContainer == first and resolved.destination.ref == second)
    resolved = assert(app:loadSetup(id, { container = third }))
    assert(resolved.sourceContainer == third and resolved.destination.ref == third)
    assert(not app:loadSetup(id, {}))
end)

test("vehicle presets use remembered routing and floor presets use the current target", function(app)
    local setup = request("inventory", "vehicle")
    setup.destination.ref = { oldVehicle = true }
    local car = assert(app:saveSetup("Haul to my car", setup))
    local resolved = assert(app:loadSetup(car, { vehicle = { otherVehicle = true } }))
    assert(resolved.destination.kind == "vehicle" and resolved.destination.ref == nil)
    local floor = assert(app:saveSetup("Drop here", request("inventory", "floor")))
    local clicked = { name = "clicked floor" }
    assert(app:loadSetup(floor, { square = clicked }).destination.ref == clicked)
    assert(app:loadSetup(floor, {}).destination.ref == player.square)
    local moved = { name = "new player square" }; player.square = moved
    assert(app:loadSetup(floor, {}).destination.ref == moved)
end)

test("an area workflow can request a fresh picker or reuse finite integer corners", function(app)
    local id = assert(app:saveSetup("Choose area", request("area", "inventory")))
    assert(app:loadSetup(id, {}).area == nil)
    local setup = request("area", "inventory")
    setup.area = { x1 = -2, y1 = 1, x2 = 4, y2 = 5, z = -1 }
    assert(app:saveSetup("Known area", setup, id))
    local area = assert(app:loadSetup(id, {})).area
    assert(area.x1 == -2 and area.y1 == 1 and area.x2 == 4 and area.y2 == 5 and area.z == -1)
end)

test("presets remain independent between worlds and player accounts", function(app)
    local id = assert(app:saveSetup("Alice tools", request()))
    worldName = "server:two"
    assert(#App.get(0):getSetups().presets == 0)
    worldName, username = "server:one", "Bob"
    assert(#App.get(0):getSetups().presets == 0)
    username = "Alice"
    local restored = App.get(0):getSetups().presets
    assert(#restored == 1 and restored[1].id == id and restored[1].name == "Alice tools")
end)

test("updating a preset retains its ID and deleting it never aliases a later setup", function(app)
    local first = assert(app:saveSetup("First", request()))
    assert(app:saveSetup("Renamed", request("room", "inventory"), first) == first)
    assert(#app:getSetups().presets == 1 and app:getSetups().presets[1].name == "Renamed")
    assert(app:deleteSetup(first))
    App.reset(); app = assert(App.get(0))
    local second = assert(app:saveSetup("Second", request()))
    assert(second ~= first and not app:loadSetup(first, {}))
    assert(not app:saveSetup("Missing", request(), first))
end)

test("last workflow survives reopening and its preference can suspend remembering", function(app)
    assert(app:rememberSetup(request("building", "vehicle")))
    App.reset(); app = assert(App.get(0))
    assert(app:lastSetup({}).scope == "building")
    assert(App.setPreferences({ rememberLastSetup = false }))
    assert(app:rememberSetup(request("room", "inventory")))
    assert(app:lastSetup({}) == nil)
    assert(app:getSetups().lastSetup.scope == "building")
    assert(App.setPreferences({ rememberLastSetup = true }))
    assert(app:lastSetup({}).scope == "building")
end)

test("failed setup writes preserve the last workflow preset list and next identity", function(app)
    local first = assert(app:saveSetup("First", request()))
    assert(app:rememberSetup(request("room", "inventory")))
    denied = true
    assert(not app:saveSetup("Unwritten", request()))
    assert(not app:deleteSetup(first))
    assert(not app:rememberSetup(request("building", "vehicle")))
    assert(#app:getSetups().presets == 1 and app:lastSetup({}).scope == "room")
    denied = false
    local second = assert(app:saveSetup("Second", request()))
    assert(first == "setup:1" and second == "setup:2")
    App.reset(); app = assert(App.get(0))
    assert(#app:getSetups().presets == 2 and app:lastSetup({}).scope == "room")
end)

test("invalid request shapes are rejected without losing an existing setup", function(app)
    assert(app:saveSetup("Valid", request()))
    local invalid = {
        { scope = "unknown" }, { scope = false }, { destination = false }, { filter = false },
        { destination = { kind = "unknown" } }, { includeBags = "yes" },
        { filter = { ids = { [1] = "native:Tool", [3] = "native:Food" } } },
        { filter = { types = false } }, { sourceLabels = { "not-a-category" } },
        { area = { x1 = 0, y1 = 0, x2 = 1, y2 = 1, z = 0 / 0 } },
        { area = { x1 = 2, y1 = 0, x2 = 1, y2 = 1, z = 0 } },
    }
    local cycle = {}; cycle[1] = cycle
    invalid[#invalid + 1] = { filter = { ids = cycle } }
    for _, setup in ipairs(invalid) do assert(not app:saveSetup("Invalid", setup)) end
    assert(not app:saveSetup("   ", request()))
    assert(not app:saveSetup(string.rep("x", 81), request()))
    assert(not app:saveSetup("Bad\nName", request()))
    assert(#app:getSetups().presets == 1 and app:getSetups().presets[1].name == "Valid")
end)

test("legacy explicit review values survive while missing review settings use direct defaults", function()
    assert(Store.save("LootBox/preferences", {confirmQuickMoves = true, matchingTransferButtons = false}))
    App.reset()
    local preferences, err = App.getPreferences()
    assert(not err and preferences.confirmQuickMoves == true and preferences.matchingTransferButtons == false)
    assert(preferences.confirmQuickCleanup == false and preferences.confirmBinReviews == false)
end)

test("review and quick-progress choices persist independently across restarts", function()
    assert(App.setPreferences({confirmQuickMoves = true, confirmQuickCleanup = true, confirmBinReviews = true}))
    assert(App.setPreferences({confirmQuickCleanup = false}))
    App.reset()
    local preferences = App.getPreferences()
    assert(preferences.confirmQuickMoves and not preferences.confirmQuickCleanup and preferences.confirmBinReviews)
end)

test("matching setups normalize all carried sources and retain only portable destination mode", function(app)
    local setup = request("room", "matching")
    setup.destination.mode = "displayed"
    local native = {}; native.self = native
    setup.sourceContainer, setup.destination.targets = native, {{container = native, types = {['Base.Apple'] = true}}}
    local id = assert(app:saveSetup("All carried matches", setup))
    assert(setup.scope == "room" and setup.includeBags == false and setup.includeInventory == true)
    App.reset(); app = assert(App.get(0))
    local resolved = assert(app:loadSetup(id, {}))
    assert(resolved.scope == "inventory" and resolved.includeBags == true and resolved.includeInventory == false)
    assert(resolved.destination.kind == "matching" and resolved.destination.mode == "displayed")
    assert(resolved.sourceContainer == nil and resolved.destination.targets == nil and resolved.destination.ref == nil)
end)

test("matching modes are bounded and invalid updates preserve an existing setup", function(app)
    local setup = request("inventory", "matching")
    local id = assert(app:saveSetup("Nearby matches", setup))
    assert(app:loadSetup(id, {}).destination.mode == "nearby")
    for _, mode in ipairs({"everywhere", false, 3}) do
        setup.destination.mode = mode
        assert(not app:saveSetup("Invalid matching mode", setup, id))
        local existing = app:getSetups().presets[1]
        assert(existing.name == "Nearby matches" and existing.setup.destination.mode == "nearby")
    end
end)

test("Smart Take unwanted exclusion survives named and remembered setup roundtrips", function(app)
    local setup = request("container", "inventory")
    setup.excludeUnwanted, setup.sourceLabels = true, {}
    local id = assert(app:saveSetup("Smart Take All", setup))
    assert(app:rememberSetup(setup))
    App.reset(); app = assert(App.get(0))
    local source = {id = "selected-container"}
    local named = assert(app:loadSetup(id, {container = source}))
    local remembered = assert(app:lastSetup({container = source}))
    assert(named.excludeUnwanted == true and remembered.excludeUnwanted == true)
    assert(named.sourceContainer == source and remembered.sourceContainer == source)
    assert(named.destination.kind == "inventory" and remembered.destination.kind == "inventory")
end)

test("unwanted exclusion accepts booleans and rejects invalid setup updates", function(app)
    local setup = request()
    local id = assert(app:saveSetup("Existing workflow", setup))
    assert(app:loadSetup(id, {}).excludeUnwanted == false)
    for _, value in ipairs({"yes", 1, {}}) do
        setup.excludeUnwanted = value
        assert(not app:saveSetup("Invalid unwanted policy", setup, id))
        assert(app:getSetups().presets[1].name == "Existing workflow")
        assert(app:loadSetup(id, {}).excludeUnwanted == false)
    end
    setup.excludeUnwanted = false
    assert(app:saveSetup("Existing workflow", setup, id))
end)

test("Condense defaults keep unequipped and nested loot bags untouched and choices persist", function()
    local preferences = assert(App.getPreferences())
    assert(preferences.condenseButton == true)
    assert(preferences.condenseRebalance == false and preferences.condenseUseUnequipped == false and preferences.condenseNested == false)
    assert(App.setPreferences({condenseButton = false, condenseRebalance = true, condenseUseUnequipped = true, condenseNested = true}))
    App.reset(); preferences = assert(App.getPreferences())
    assert(not preferences.condenseButton and preferences.condenseRebalance and preferences.condenseUseUnequipped and preferences.condenseNested)
end)

test("Til Full policy preferences persist and reject non-booleans", function()
    assert(App.setPreferences({tillFullEnabled = false, tillFullBothNeeds = true}))
    App.reset()
    local preferences = App.getPreferences()
    assert(not preferences.tillFullEnabled and preferences.tillFullBothNeeds)
    assert(not App.setPreferences({tillFullBothNeeds = "both"}))
    assert(App.getPreferences().tillFullBothNeeds)
end)

test("a retired or damaged preference falls back alone and settings stay editable", function()
    assert(Store.save("LootBox/preferences", {contextMenus = "bad", showTips = true, confirmQuickMoves = true}))
    App.reset()
    local preferences = App.getPreferences()
    assert(preferences.contextMenus == true and preferences.confirmQuickMoves == true and preferences.showTips == nil)
    assert(App.setPreferences({contextMenus = false}))
    App.reset(); assert(App.getPreferences().contextMenus == false and App.getPreferences().confirmQuickMoves == true)
end)

test("damaged presets are dropped one by one and the rest stay usable", function(app)
    assert(Store.save(app.path .. "/setups", {nextId = 2, presets = {
        {id = "setup:1", name = "One", setup = request()}, {id = "setup:1", name = "Duplicate", setup = request()},
        {id = "setup:7", name = "Seven", setup = {scope = "nowhere"}}, "junk"}, lastSetup = {scope = "nowhere"}}))
    App.reset(); app = assert(App.get(0))
    local saved = app:getSetups()
    assert(#saved.presets == 1 and saved.presets[1].name == "One" and saved.lastSetup == nil)
    local id = assert(app:saveSetup("Two", request()))
    assert(id ~= "setup:1")
end)

test("deleting a category removes it from presets and keeps the preset", function(app)
    local category = assert(App.saveCategory({name = "Temporary", types = {"Example.Widget"}, includes = {}}))
    local setup = request(); setup.filter.ids = {category, "native:Tool"}
    local id = assert(app:saveSetup("Temporary category workflow", setup))
    assert(App.deleteCategory(category))
    local resolved = assert(app:loadSetup(id, {}))
    assert(#resolved.filter.ids == 1 and resolved.filter.ids[1] == "native:Tool")
end)

test("at most 32 presets are kept", function(app)
    for index = 1, 32 do assert(app:saveSetup("Preset " .. index, request())) end
    assert(not app:saveSetup("Thirty-third", request()) and #app:getSetups().presets == 32)
end)

print(passed .. " setup and preference integration cases passed (explicit world/action and native file doubles)")
