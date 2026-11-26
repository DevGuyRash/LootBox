-- The review window's answer. Widgets and the app are doubles; Review is real.
if package then package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path end
local f
local Window = {}
function Window:derive() local class = setmetatable({}, {__index = Window}); class.__index = class; return class end
function Window.close(self) self.closed = true end
package.loaded["LootBox/UIKit"] = {Window = Window}
package.loaded["LootBox/PlanList"] = {}
package.loaded["LootBox/Log"] = {info = function() end}
package.loaded["LootBox/App"] = {setPreferences = function(patch) f.patch = patch; return f.saved, f.why end}
package.loaded["LootBox/UI"] = {say = function(_, text) f.said = text end}
local Review = require "LootBox/Review"
local function window()
    local w = setmetatable({playerIndex = 0, skip = {on = true}, options = {preference = "confirmQuickMoves", start = function() return true end}}, Review)
    function w:fail(text) f.failed = text end
    return w
end
local passed = 0
local function test(name, run) f = {}; run(); passed = passed + 1; print("PASS " .. name) end

test("Don't ask again turns the setting off once the job has started", function()
    f.saved = true
    local w = window()
    w:accept()
    assert(f.patch.confirmQuickMoves == false and w.closed and not f.said)
end)

test("a setting that could not be saved is told, and the job still runs", function()
    f.saved, f.why = nil, "The disk is full"
    local w = window()
    w:accept()
    assert(w.closed and f.said == "Started, but the setting could not be saved: The disk is full")
end)

test("a job that cannot start changes no setting", function()
    local w = window()
    w.options.start = function() return nil, "Get out of the vehicle first" end
    w:accept()
    assert(not f.patch and not w.closed and f.failed == "Get out of the vehicle first")
end)

print(passed .. " review cases passed")
