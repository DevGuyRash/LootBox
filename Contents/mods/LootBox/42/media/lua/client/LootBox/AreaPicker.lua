-- Drag (or click two corners) on the ground to mark an area on one floor.
local K = require "LootBox/UIKit"

local AreaPicker = ISPanel:derive("LootBoxAreaPicker")
AreaPicker.open = {}

function AreaPicker.start(playerIndex, done)
    local player = getSpecificPlayer(playerIndex)
    if not player or player:isDead() or not player:getCurrentSquare() then return nil, "Enter the world first" end
    if AreaPicker.open[playerIndex] then AreaPicker.open[playerIndex]:finish(nil) end
    local o = ISPanel.new(AreaPicker, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    o.playerIndex, o.player, o.done = playerIndex, player, done
    o.z = player:getCurrentSquare():getZ()
    o.background, o.border = false, false
    o:initialise()
    o:setWantKeyEvents(true)
    o:setWantMouseEvents(true)
    AreaPicker.open[playerIndex] = o
    o:addToUIManager()
    o:bringToTop()
    return o
end

function AreaPicker:point()
    local x = math.floor(screenToIsoX(self.playerIndex, getMouseX(), getMouseY(), self.z))
    local y = math.floor(screenToIsoY(self.playerIndex, getMouseX(), getMouseY(), self.z))
    local square = getCell():getGridSquare(x, y, self.z)
    if square and square:getFloor() then return { x = x, y = y } end
end

local function box(a, b, z)
    return { x1 = math.min(a.x, b.x), y1 = math.min(a.y, b.y), x2 = math.max(a.x, b.x), y2 = math.max(a.y, b.y), z = z }
end

function AreaPicker:prerender()
    local point = self:point() or self.last
    self.last = point
    local text = self.first and "Release or click the opposite corner" or "Drag across the area, or click its first corner"
    if point then
        local area = box(self.first or point, point, self.z)
        local c = K.colors.accent
        addAreaHighlightForPlayer(self.playerIndex, area.x1, area.y1, area.x2 + 1, area.y2 + 1, self.z, c.r, c.g, c.b, 0.4)
        if self.first then text = (area.x2 - area.x1 + 1) .. " x " .. (area.y2 - area.y1 + 1) .. " tiles. " .. text end
    end
    text = text .. ". Right-click or Escape cancels."
    local width, height = K.width(text) + 4 * K.PAD, K.ROW + 4
    local x = (self.width - width) / 2
    local g, l, t = K.colors.glass, K.colors.accent, K.colors.text
    self:drawRect(x, 24, width, height, g.a, g.r, g.g, g.b)
    self:drawRectBorder(x, 24, width, height, 0.6, l.r, l.g, l.b)
    self:drawTextCentre(text, self.width / 2, 24 + (height - K.LINE) / 2, t.r, t.g, t.b, 1, K.FONT)
end

function AreaPicker:update()
    if getSpecificPlayer(self.playerIndex) ~= self.player or self.player:isDead() then self:finish(nil) end
end

function AreaPicker:onMouseDown()
    local point = self:point()
    if not point then return true end
    if self.first then self.second = point else self.first, self.dragging = point, true end
    return true
end

function AreaPicker:onMouseUp()
    local point = self.second or (self.dragging and self:point())
    if self.second or (point and (point.x ~= self.first.x or point.y ~= self.first.y)) then
        self:finish(box(self.first, point, self.z))
    end
    self.dragging = false
    return true
end

function AreaPicker:onRightMouseDown() return true end
function AreaPicker:onRightMouseUp() self:finish(nil); return true end
function AreaPicker:isKeyConsumed(key) return key == Keyboard.KEY_ESCAPE end
function AreaPicker:onKeyPress(key)
    if not self:isKeyConsumed(key) then return false end
    self:finish(nil)
    if GameKeyboard and GameKeyboard.eatKeyPress then GameKeyboard.eatKeyPress(key) end
    return true
end
function AreaPicker:onKeyRelease(key) return self:isKeyConsumed(key) end

function AreaPicker:finish(area)
    if self.closed then return end
    self.closed = true
    AreaPicker.open[self.playerIndex] = nil
    self:setVisible(false)
    self:removeFromUIManager()
    if self.done then self.done(area) end
end

function AreaPicker.closeAll()
    local active = {}
    for _, picker in pairs(AreaPicker.open) do active[#active + 1] = picker end
    for _, picker in ipairs(active) do picker.done = nil; picker:finish(nil) end
end

return AreaPicker
