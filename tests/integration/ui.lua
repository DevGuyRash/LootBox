package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

for _, name in ipairs({ "ISCollapsableWindow", "ISPanel", "ISToolTip" }) do package.loaded["ISUI/" .. name] = true end
package.loaded["PZAPI/ModOptions"] = true
local function derive(parent)
    local class = {}
    class.__index = class
    return setmetatable(class, { __index = parent })
end
ISCollapsableWindow = { derive = derive }
ISPanel = { derive = derive }

local current
package.loaded["LootBox/App"] = {
    get = function() return current.app end,
    getPreferences = function() return current.preferences end,
}
package.loaded["LootBox/Categories"] = {}
package.loaded["LootBox/Widgets"] = { H = 28, GAP = 10, colors = {}, unfocus = function(body) current.unfocused = body end }
local UI = require "LootBox/UI"

local function fakeReview(_, playerIndex, context, request, plan, notice)
    current.review = { playerIndex = playerIndex, context = context, request = request, plan = plan, notice = notice,
        initialise = function() end, addToUIManager = function() end, close = function() end }
    return current.review
end
UI.QuickReview.new = fakeReview
UI.showProgress = function(_, notice) current.progress = { notice = notice }; return current.progress end
UI.open = function(playerIndex, context, mode)
    current.opened = { playerIndex = playerIndex, context = context, mode = mode }
    return { messageText = function(_, text) current.opened.message = text end }
end
local function fixture()
    local f = { previews = 0, starts = 0, remembered = 0, preferences = { confirmQuickMoves = true } }
    current = f
    UI.quickWindows, UI.areaPickers = {}, {}
    UI.windows = {}
    f.plan = { moves = { { itemName = "Bandage", to = "Crate" } }, skipped = {}, pending = 0 }
    f.app = {
        preview = function(_, request) f.previews = f.previews + 1; f.reviewed = request; return f.plan end,
        start = function(_, plan)
            f.starts = f.starts + 1
            assert(plan == f.plan, "A quick action must start its current reviewed plan")
            if f.startError then return nil, f.startError end
            return true
        end,
        rememberSetup = function()
            f.remembered = f.remembered + 1
            if f.saveError then return nil, f.saveError end
            return true
        end,
    }
    return f
end
local function request(kind)
    return { scope = "inventory", includeBags = true, filter = { ids = {}, types = { "Base.Bandage" }, all = false },
        destination = { kind = kind or "container", ref = {} } }
end

local function setupWindow(f, chosen, loaded)
    local currentRequest = request("floor")
    f.app.getSetups = function()
        return { presets = { { id = "setup:1", name = "First aid" }, { id = "setup:2", name = "Unavailable supplies" } } }
    end
    f.app.loadSetup = function() return nil, "Category custom:1 is unavailable" end
    f.app.deleteSetup = function(_, id) f.deleted = id; return true end
    f.app.saveSetup = function(_, name, setup, id) f.saved = { name = name, setup = setup, id = id }; return id end
    local function button() return { setEnable = function(self, enabled) self.enabled = enabled end } end
    return setmetatable({
        selectedSetupId = loaded, context = {},
        setupPicker = { selected = 1, data = chosen, getOptionData = function(self) return self.data end },
        setupName = { text = "Replacement workflow", setText = function(self, text) self.text = text end,
            getText = function(self) return self.text end },
        updateSetupButton = button(), deleteSetupButton = button(),
        app = function() return f.app end,
        readRequest = function() return currentRequest end,
        show = function(self, mode) self.shown = mode end,
        messageText = function(self, text) self.message = text end,
    }, { __index = UI.Window })
end

local passed = 0
local function test(name, run)
    run(fixture())
    passed = passed + 1
    print("PASS " .. name)
end

test("ordinary shortcuts show a compact review by default", function(f)
    local result = UI.quickAction(0, {}, request())
    assert(result == f.review and f.review.plan == f.plan)
    assert(f.previews == 1 and f.starts == 0)
end)

test("disabling quick confirmation starts only the current ordinary reviewed plan", function(f)
    f.preferences.confirmQuickMoves = false
    local result = UI.quickAction(0, {}, request())
    assert(result == f.progress and f.previews == 1 and f.starts == 1 and not f.review)
end)

test("cleanup always shows a fresh explicit review even with quick confirmation off", function(f)
    f.preferences.confirmQuickMoves = false
    local result = UI.quickAction(0, {}, request("trash"))
    assert(result == f.review and result.request.destination.kind == "trash")
    assert(f.previews == 1 and f.starts == 0)
end)

test("a setup write failure does not prevent a valid quick transfer", function(f)
    f.preferences.confirmQuickMoves = false
    f.saveError = "Local storage is read-only"
    UI.quickAction(0, {}, request())
    assert(f.starts == 1 and f.progress.notice:find(f.saveError, 1, true))
end)

test("a rejected automatic start remains visible in a review", function(f)
    f.preferences.confirmQuickMoves = false
    f.startError = "Finish or cancel the current job"
    local result = UI.quickAction(0, {}, request())
    assert(result == f.review and f.review.notice:find(f.startError, 1, true))
    assert(not f.progress)
end)

test("an empty selection opens the composer without starting or inspecting sources", function(f)
    local setup = request()
    setup.filter.types = {}
    UI.quickAction(0, {}, setup)
    assert(f.opened.mode == "compose" and f.opened.message:find("Choose", 1, true))
    assert(f.previews == 0 and f.starts == 0)
end)

test("area shortcuts inspect nothing until the player finishes the area picker", function(f)
    local square = { getZ = function() return 0 end }
    function getSpecificPlayer() return { getCurrentSquare = function() return square end, isDead = function() return false end } end
    UI.AreaPicker.new = function(_, _, _, callback)
        f.pick = callback
        return { initialise = function() end, setWantKeyEvents = function() end,
            setWantMouseEvents = function() end, addToUIManager = function() end, bringToTop = function() end }
    end
    local setup = request("trash")
    setup.scope = "area"
    UI.quickAction(0, {}, setup, true)
    assert(f.previews == 0 and f.starts == 0 and f.pick)
    f.pick(nil)
    assert(f.previews == 0)
    f.pick({ x1 = 1, x2 = 2, y1 = 3, y2 = 4, z = 0 })
    assert(f.previews == 1 and f.review.request.area.x1 == 1 and f.starts == 0)
end)

test("adjusting a full preview retains the task selector search and setup name", function(f)
    local setup = request("trash")
    local function choice(data) return { selected = 1, getOptionData = function() return data end } end
    local window = {
        readRequest = function() return setup end,
        app = function() return f.app end,
        operation = choice("clean"), selectorKind = choice("items"),
        search = { getText = function() return "Bandage" end },
        setupName = { getText = function() return "Medical cleanup" end },
        show = function(self, mode) self.shown = mode end,
        messageText = function(self, text) self.message = text end,
    }
    UI.Window.preview(window)
    assert(window.shown == "preview" and window.request == setup)
    assert(window.operationValue == "clean" and window.selectorKindValue == "items")
    assert(window.searchDraft == "Bandage" and window.setupNameDraft == "Medical cleanup")
end)

test("an explicit single selection is visible when entering the full picker", function()
    local window = {}
    UI.Window.setRequest(window, request())
    assert(window.selectorKindValue == "items" and window.searchDraft == "Base.Bandage")
    UI.Window.setRequest(window, { scope = "room", filter = { ids = { "native:Food" }, types = {}, all = false },
        destination = { kind = "inventory" } })
    assert(window.selectorKindValue == "categories" and window.searchDraft == "native:Food")
    UI.Window.setRequest(window, { scope = "room", filter = { ids = {}, types = {}, all = true }, destination = { kind = "trash" } })
    assert(window.operationValue == "clean" and window.searchDraft == "")
end)

test("closing the manager releases its field focus before hiding and detaching", function(f)
    local body = {}
    local window = { playerIndex = 0, body = body, rememberDraft = function() end,
        setVisible = function(_, visible) assert(not visible and f.unfocused == body); f.hidden = true end,
        removeFromUIManager = function() assert(f.hidden); f.removed = true end }
    UI.windows[0] = window
    UI.Window.close(window)
    assert(f.removed and UI.windows[0] == nil)
end)

test("a shortcut releases focus from an existing LootBox editor", function(f)
    local body = {}
    UI.windows[0] = { body = body }
    UI.quickAction(0, {}, request())
    assert(f.unfocused == body and f.review)
end)

test("an unavailable chosen setup remains deletable without deleting the previously loaded setup", function(f)
    local window = setupWindow(f, "setup:2", "setup:1")
    window:loadNamedSetup()
    assert(window.message:find("unavailable", 1, true))
    assert(window.deleteSetupButton.enabled and window.updateSetupButton.enabled)
    assert(window.setupName:getText() == "Unavailable supplies")
    window:deleteNamedSetup()
    assert(f.deleted == "setup:2")
end)

test("updating a setup replaces the visible picker selection rather than the previously loaded setup", function(f)
    local window = setupWindow(f, "setup:2", "setup:1")
    local replacement = window:readRequest()
    window:saveNamedSetup(true)
    assert(f.saved.id == "setup:2" and f.saved.name == "Replacement workflow")
    assert(f.saved.setup == replacement)
end)

test("clearing the setup picker disables management and cannot create or delete a setup", function(f)
    local window = setupWindow(f, false, "setup:1")
    window:selectNamedSetup()
    assert(not window.updateSetupButton.enabled and not window.deleteSetupButton.enabled)
    assert(window.setupName:getText() == "")
    window:saveNamedSetup(true)
    window:deleteNamedSetup()
    assert(not f.saved and not f.deleted)
end)

print(passed .. " UI workflow cases passed (explicit native window and job boundary doubles)")
