package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

-- The single way a click becomes work. Windows are doubles; UI and Log are real.
local passed, f = 0, nil
function getTimestampMs() return 1 end
Events = nil
function instanceof() return false end
function getSpecificPlayer() return f and f.player end
HaloTextHelper = {addBadText = function(_, text) f.bad = text end, addGoodText = function(_, text) f.good = text end}
package.loaded["PZAPI/ModOptions"] = true
package.loaded["LootBox/App"] = {get = function() return f.app end, peek = function() return f.app end, preference = function(key) return f.preferences[key] end,
    reviewPreference = function(request)
        local key = request and request.destination.kind == "trash" and "confirmQuickCleanup" or "confirmQuickMoves"
        return f.preferences[key] == true, key
    end}
package.loaded["LootBox/UIKit"] = {resetLayout = function() end}
package.loaded["LootBox/MainWindow"] = {open = {}, show = function(_, page, context) f.page, f.pageContext = page, context end, closeAll = function() end}
package.loaded["LootBox/JobBar"] = {bars = {}, show = function() f.bar = {}; return f.bar end, tick = function() end, closeAll = function() end}
package.loaded["LootBox/Review"] = {open = {}, show = function(_, options) f.review = options; return options end, closeAll = function() end}
package.loaded["LootBox/AreaPicker"] = {open = {}, start = function(_, done) f.areaDone = done; return {} end, closeAll = function() end}
package.loaded["LootBox/PlanList"] = {}
local UI = require "LootBox/UI"
local function test(name, run)
    f = {player = {}, preferences = {jobBar = true}, plan = {moves = {{}}, skipped = {}, label = "Take nails"}}
    f.app = {player = f.player, preview = function(_, request) f.previewed = request; return f.plan, f.problem end,
        start = function(_, plan, options) f.started, f.startOptions = plan, options; if f.refuse then return nil, f.refuse end return true end,
        world = {owns = function(_, c) return c == "bag" end},
        rememberSetup = function() f.remembered = true; return true end, previewCondense = function() return f.plan, f.problem end}
    run()
    passed = passed + 1
    print("PASS " .. name)
end
local function request(kind) return {scope = "room", filter = {all = true, ids = {}, types = {}}, destination = {kind = kind or "inventory", labels = {}}} end

test("a click starts the job at once when no review is wanted", function()
    assert(UI.act(0, request()))
    assert(f.started == f.plan and type(f.startOptions.interaction) == "number" and not f.review and not f.page)
end)

test("nothing to do says why, opens nothing and starts nothing", function()
    f.plan = {moves = {}, skipped = {{itemName = "Axe", reason = "Equipped"}}, pending = 0}
    assert(UI.act(0, request()))
    assert(f.bad == "Axe: Equipped" and not f.started and not f.review and not f.page and not f.remembered)
end)

test("a refused plan tells the player and opens no window", function()
    f.plan, f.problem = nil, "No usable known trash can"
    local ok, err = UI.act(0, request("trash"))
    assert(ok == nil and err == f.problem and f.bad == f.problem and not f.page)
end)

test("a wanted review waits, then starts with the same plan", function()
    f.preferences.confirmQuickCleanup = true
    UI.act(0, request("trash"))
    assert(f.review and not f.started and f.review.preference == "confirmQuickCleanup")
    assert(f.review.start() and f.started == f.plan)
    f.review.other()
    assert(f.page == "plan" and f.pageContext.request.destination.kind == "trash")
end)

test("deleting carried items is always confirmed, from any entrance", function()
    for _, change in ipairs({{scope = "inventory"}, {includeInventory = true}, {scope = "container", sourceContainer = "bag"}}) do
        f.review = nil
        local what = request("trash")
        for key, value in pairs(change) do what[key] = value end
        UI.act(0, what, {quiet = true})
        assert(f.review and f.review.preference == nil and not f.started)
    end
    f.review = nil
    UI.act(0, request("trash"))
    assert(not f.review and f.started, "Loot that is not carried follows the player's setting")
end)

test("a review can skip trash can checks for this job only", function()
    f.preferences.confirmQuickCleanup = true
    local App = package.loaded["LootBox/App"]
    local before = App.reviewPreference
    App.reviewPreference = function(what, bin) if bin then return true, "confirmBinReviews" end return before(what) end
    UI.act(0, request("trash"))
    assert(f.review.startWithoutBins() and f.startOptions.reviewBins == false)
    App.reviewPreference = before
end)

test("an area job asks for the area first and cancels quietly", function()
    local what = request()
    what.scope = "area"
    UI.act(0, what, {area = true})
    assert(f.areaDone and not f.previewed)
    f.areaDone(nil)
    assert(not f.previewed and not f.started)
    f.areaDone({x1 = 1, y1 = 1, x2 = 2, y2 = 2, z = 0})
    assert(f.previewed.area.x2 == 2 and f.started)
end)

test("a start refusal is told to the player", function()
    f.refuse = "Get out of the vehicle first"
    UI.act(0, request())
    assert(f.bad == f.refuse)
end)

test("condense says when bags are already packed well", function()
    f.plan = {moves = {}, skipped = {}, pending = 0, condense = {reason = "Already packed"}}
    assert(UI.condense(0) and f.good == "Already packed" and not f.started)
end)

print(passed .. " UI action cases passed (window and engine doubles)")
