require "ISUI/ISButton"
require "ISUI/ISCollapsableWindow"
require "ISUI/ISContextMenu"
require "ISUI/ISLabel"
require "ISUI/ISPanel"
require "ISUI/ISRichTextPanel"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISToolTip"

-- The whole visual vocabulary: dark glass, one amber accent, item icons, and
-- buttons that stay quiet until hovered. Nothing else defines colours.
local K = {}

K.FONT, K.TITLE = UIFont.Small, UIFont.Medium
K.LINE = getTextManager():getFontHeight(K.FONT)
K.ROW = K.LINE + 12
K.PAD = 12
K.GAP = 8

K.colors = {
    glass = { r = 0.035, g = 0.037, b = 0.042, a = 0.94 },
    sheet = { r = 1, g = 1, b = 1, a = 0.035 },
    line = { r = 1, g = 1, b = 1, a = 0.10 },
    hover = { r = 1, g = 1, b = 1, a = 0.07 },
    pick = { r = 0.90, g = 0.60, b = 0.24, a = 0.16 },
    text = { r = 0.92, g = 0.91, b = 0.88, a = 1 },
    dim = { r = 0.62, g = 0.62, b = 0.60, a = 1 },
    faint = { r = 0.42, g = 0.42, b = 0.41, a = 1 },
    accent = { r = 0.93, g = 0.64, b = 0.29, a = 1 },
    good = { r = 0.56, g = 0.78, b = 0.50, a = 1 },
    warn = { r = 0.93, g = 0.76, b = 0.36, a = 1 },
    bad = { r = 0.90, g = 0.45, b = 0.38, a = 1 },
    info = { r = 0.55, g = 0.74, b = 0.88, a = 1 },
}

function K.color(name, alpha)
    local c = K.colors[name] or K.colors.text
    return { r = c.r, g = c.g, b = c.b, a = alpha or c.a }
end

function K.width(text, font) return getTextManager():MeasureStringX(font or K.FONT, text) end

function K.fit(text, width, font)
    text, font = tostring(text or ""), font or K.FONT
    if K.width(text, font) <= width then return text end
    if width <= K.width("...", font) then return "" end
    local low, high = 0, #text
    while low < high do
        local middle = math.ceil((low + high) / 2)
        if K.width(text:sub(1, middle) .. "...", font) <= width then low = middle else high = middle - 1 end
    end
    return text:sub(1, low) .. "..."
end

function K.wrap(text, width, font)
    local lines = {}
    for paragraph in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            local candidate = line == "" and word or (line .. " " .. word)
            if line ~= "" and K.width(candidate, font) > width then lines[#lines + 1], line = line, word else line = candidate end
        end
        lines[#lines + 1] = line
    end
    return lines
end

function K.escape(text)
    return (tostring(text or ""):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\r", ""):gsub("\n", " <LINE> "))
end

function K.place(widget, x, y, width, height)
    if not widget then return end
    if x and widget.x ~= x then widget:setX(x) end
    if y and widget.y ~= y then widget:setY(y) end
    if width and widget.width ~= width then widget:setWidth(math.max(1, width)) end
    if height and widget.height ~= height then widget:setHeight(math.max(1, height)) end
end

function K.tip(widget, text)
    if widget.setTooltip then widget:setTooltip(text) else widget.tooltip = text end
end

-- Buttons ----------------------------------------------------------------
-- tone: "primary" (one per screen), "plain", "ghost" (no frame), "danger".
local tones = {
    primary = { fill = { 0.93, 0.64, 0.29, 0.20 }, hover = { 0.93, 0.64, 0.29, 0.34 }, line = { 0.93, 0.64, 0.29, 0.65 }, text = "accent" },
    plain = { fill = { 1, 1, 1, 0.05 }, hover = { 1, 1, 1, 0.12 }, line = { 1, 1, 1, 0.14 }, text = "text" },
    ghost = { fill = { 1, 1, 1, 0 }, hover = { 1, 1, 1, 0.08 }, line = { 1, 1, 1, 0 }, text = "dim" },
    danger = { fill = { 0.90, 0.45, 0.38, 0.14 }, hover = { 0.90, 0.45, 0.38, 0.28 }, line = { 0.90, 0.45, 0.38, 0.5 }, text = "bad" },
}
local function rgba(list, scale) return { r = list[1], g = list[2], b = list[3], a = list[4] * (scale or 1) } end

local function paint(button)
    local tone = tones[button.tone] or tones.plain
    local scale = button.enable == false and 0.4 or 1
    button.backgroundColor, button.backgroundColorMouseOver = rgba(tone.fill, scale), rgba(tone.hover, scale)
    button.borderColor, button.textColor = rgba(tone.line, scale), K.color(tone.text)
end

function K.button(parent, text, target, action, tone, tooltip)
    local child = ISButton:new(0, 0, K.width(text) + 2 * K.PAD, K.ROW, text, target, action)
    child:initialise()
    child.tone = tone or "plain"
    local native = child.setEnable
    function child:setEnable(enabled)
        if self.enable == enabled then return end
        native(self, enabled)
        paint(self)
    end
    function child:setTone(name) if self.tone ~= name then self.tone = name; paint(self) end end
    paint(child)
    if tooltip then child:setTooltip(tooltip) end
    parent:addChild(child)
    return child
end

function K.icon(parent, texture, size, target, action, tooltip)
    local child = K.button(parent, "", target, action, "ghost", tooltip)
    child:setImage(type(texture) == "string" and getTexture(texture) or texture)
    child:setWidth(size); child:setHeight(size)
    child:forceImageSize(math.floor(size * 0.62), math.floor(size * 0.62))
    child.textureColor = K.color("text", 0.85)
    return child
end

-- Left-aligned entry of a navigation rail, with an amber bar when current.
function K.tab(parent, text, target, action)
    local child = K.button(parent, "", target, action, "ghost")
    child.caption = text
    child.titleLeft = true
    function child:render()
        ISButton.render(self)
        if self.current then
            self:drawRect(0, 0, self.width, self.height, 0.10, 1, 1, 1)
            self:drawRect(0, 0, 3, self.height, 1, K.colors.accent.r, K.colors.accent.g, K.colors.accent.b)
        end
        local tint = self.current and K.colors.text or K.colors.dim
        self:drawText(self.caption, K.PAD + 2, (self.height - K.LINE) / 2, tint.r, tint.g, tint.b, 1, K.FONT)
        if self.badge then
            local c = K.colors.accent
            self:drawTextRight(self.badge, self.width - K.PAD, (self.height - K.LINE) / 2, c.r, c.g, c.b, 1, K.FONT)
        end
    end
    return child
end

-- A choice shown as caption, value and detail. Clicking opens its menu.
function K.card(parent, caption, target, action, tooltip)
    local child = K.button(parent, "", target, action, "plain", tooltip)
    child.caption, child.value, child.detail = caption, "", ""
    child:setHeight(K.LINE * 3 + 18)
    function child:set(value, detail, tone)
        self.value, self.detail, self.valueTone = tostring(value or ""), tostring(detail or ""), tone or "text"
    end
    function child:render()
        ISButton.render(self)
        local room, x, y = self.width - 2 * K.PAD, K.PAD, 8
        local f, v, d = K.colors.faint, K.colors[self.valueTone or "text"], K.colors.dim
        self:drawText(self.caption, x, y, f.r, f.g, f.b, 1, K.FONT)
        self:drawTextRight("v", self.width - K.PAD, y, f.r, f.g, f.b, 1, K.FONT)
        self:drawText(K.fit(self.value, room), x, y + K.LINE + 1, v.r, v.g, v.b, 1, K.FONT)
        self:drawText(K.fit(self.detail, room), x, y + 2 * K.LINE + 2, d.r, d.g, d.b, 1, K.FONT)
    end
    return child
end

-- On/off choice on one line.
function K.toggle(parent, text, on, target, changed, tooltip)
    local box = math.floor(K.LINE * 0.8)
    local child = K.button(parent, "", target, nil, "ghost", tooltip)
    child.caption, child.on = text, on == true
    child:setWidth(box + K.GAP + K.width(text) + K.PAD)
    child.onclick = function(owner, widget)
        widget.on = not widget.on
        if changed then changed(owner, widget.on, widget) end
    end
    function child:render()
        ISButton.render(self)
        local c = self.on and K.colors.accent or K.colors.faint
        local y = math.floor((self.height - box) / 2)
        self:drawRectBorder(2, y, box, box, 1, c.r, c.g, c.b)
        if self.on then self:drawRect(5, y + 3, box - 6, box - 6, 1, c.r, c.g, c.b) end
        local t = self.enable and K.colors.text or K.colors.faint
        self:drawText(K.fit(self.caption, self.width - box - K.GAP - 2), box + K.GAP + 2, (self.height - K.LINE) / 2, t.r, t.g, t.b, 1, K.FONT)
    end
    parent:addChild(child)
    return child
end

-- Text -------------------------------------------------------------------

function K.label(parent, text, tone, font)
    local color = K.colors[tone or "text"]
    local child = ISLabel:new(0, 0, getTextManager():getFontHeight(font or K.FONT), text, color.r, color.g, color.b, 1, font or K.FONT, true)
    child:initialise()
    parent:addChild(child)
    function child:set(value, newTone)
        if newTone then local c = K.colors[newTone]; self.r, self.g, self.b = c.r, c.g, c.b end
        value = tostring(value or "")
        if self.shown ~= value then self.shown = value; self:setName(value) end
    end
    return child
end

-- Wrapped plain text that draws itself; no scrollbars, no rich-text markup.
function K.text(parent, text, tone)
    local child = ISPanel:new(0, 0, 10, K.LINE)
    child:initialise()
    child.background, child.border = false, false
    child.tone = tone or "dim"
    child.content = tostring(text or "")
    function child:set(value, newTone)
        value = tostring(value or "")
        if newTone then self.tone = newTone end
        if self.content ~= value then self.content, self.lines = value, nil end
    end
    function child:measure(width)
        if not self.lines or self.forWidth ~= width then self.lines, self.forWidth = K.wrap(self.content, width), width end
        return #self.lines * K.LINE
    end
    function child:prerender()
        self:measure(self.width)
        local tint = K.colors[self.tone]
        for index, line in ipairs(self.lines) do
            local y = (index - 1) * K.LINE
            if y + K.LINE > self.height + 2 then break end
            local last = y + 2 * K.LINE > self.height + 2 and index < #self.lines
            self:drawText(last and K.fit(line .. " ...", self.width) or line, 0, y, tint.r, tint.g, tint.b, 1, K.FONT)
        end
    end
    parent:addChild(child)
    return child
end

function K.rich(parent)
    local child = ISRichTextPanel:new(0, 0, 10, 10)
    child:initialise()
    child.autosetheight, child.clip, child.background = false, true, false
    child.defaultFont = K.FONT
    child:setMargins(0, 2, 16, 2)
    parent:addChild(child)
    child:addScrollBars()
    function child:set(text)
        if self.shown == text then return end
        self.shown, self.text = text, text
        self:paginate()
        self:setYScroll(0)
    end
    return child
end

-- Entry ------------------------------------------------------------------

function K.entry(parent, placeholder, target, changed)
    local child = ISTextEntryBox:new("", 0, 0, 100, K.ROW)
    child:initialise()
    child:instantiate()
    child.backgroundColor, child.borderColor = { r = 0, g = 0, b = 0, a = 0.5 }, K.color("line", 0.18)
    if placeholder and child.setPlaceholderText then child:setPlaceholderText(placeholder) end
    if child.setClearButton then child:setClearButton(true) end
    if changed then
        child.onTextChangeFunction = function(_, widget) widget.changedAt = getTimestampMs() end
        local native = child.prerender
        function child:prerender()
            if native then native(self) end
            if self.changedAt and getTimestampMs() - self.changedAt >= 120 then
                self.changedAt = nil
                changed(target, self:getText())
            end
        end
    end
    parent:addChild(child)
    local window = parent
    while window.parent do window = window.parent end
    window.lootBoxEntries = window.lootBoxEntries or {}
    table.insert(window.lootBoxEntries, child)
    return child
end

function K.unfocus(window)
    for _, entry in ipairs(window and window.lootBoxEntries or {}) do
        if entry:isFocused() then entry:unfocus() end
    end
end

-- Lists ------------------------------------------------------------------
-- A row is {title, sub, icon (texture), tone, right, rightTone, check (bool or
-- nil), heading, key, tooltip, indent}. Rows draw only where fully visible, so
-- text never bleeds over the frame.
function K.list(parent, target, click)
    local child = ISScrollingListBox:new(0, 0, 100, 100)
    child:initialise()
    child:instantiate()
    child.font, child.itemheight, child.selected = K.FONT, K.ROW, 0
    child.drawBorder = true
    child.backgroundColor, child.borderColor = { r = 0, g = 0, b = 0, a = 0.28 }, K.color("line")
    child.onmousedown = nil
    if click then
        child:setOnMouseDownFunction(target, function(owner, row)
            if row and not row.heading then click(owner, row, child) end
        end)
    end

    function child:fill(rows, keepScroll)
        local scroll = keepScroll and self:getYScroll() or 0
        self:clear()
        self.selected = 0
        self.smoothScrollTargetY, self.smoothScrollY = nil, nil
        local height = 0
        for _, row in ipairs(rows) do
            local entry = self:addItem(tostring(row.title or ""), row)
            entry.height = self:rowHeight(row)
            entry.tooltip = row.tooltip
            height = height + entry.height
        end
        self:setScrollHeight(height)
        self:setYScroll(math.min(0, math.max(scroll, math.min(0, self.height - height))))
        self.empty = #rows == 0
    end

    function child:rowHeight(row)
        if row.heading then return K.LINE + 14 end
        return row.sub and (2 * K.LINE + 12) or K.ROW
    end

    child.doDrawItem = function(self, y, entry)
        local row, height = entry.item, entry.height or K.ROW
        local top = y + self:getYScroll()
        if top + height <= 1 or top >= self.height - 1 then return y + height end
        local first, last = math.max(1, top), math.min(self.height - 1, top + height)
        local function visible(textTop, textHeight)
            local at = textTop + self:getYScroll()
            return at >= 1 and at + textHeight <= self.height - 1
        end
        local right = self.width - (self:isVScrollBarVisible() and 22 or K.GAP)
        if row.heading then
            local c = K.colors.accent
            local at = y + height - K.LINE - 4
            if visible(at, K.LINE) then
                self:drawText(K.fit(row.title, right - K.GAP), K.GAP, at, c.r, c.g, c.b, 1, K.FONT)
                if row.right then
                    local d = K.colors.dim
                    self:drawTextRight(row.right, right, at, d.r, d.g, d.b, 1, K.FONT)
                end
            end
            return y + height
        end
        local hovered = self.mouseoverselected == entry.index and self:isMouseOver()
        local picked = row.current or (self.highlight and entry.index == self.selected)
        if picked or hovered then
            local c = picked and K.colors.pick or K.colors.hover
            self:drawRect(1, first - self:getYScroll(), self.width - 2, last - first, c.a, c.r, c.g, c.b)
            if picked then
                local a = K.colors.accent
                self:drawRect(1, first - self:getYScroll(), 2, last - first, 1, a.r, a.g, a.b)
            end
        end
        local x = K.GAP + (row.indent or 0) * 14
        if row.check ~= nil then
            local box = math.floor(K.LINE * 0.8)
            local by = y + math.floor((height - box) / 2)
            if visible(by, box) then
                local c = row.check and K.colors.accent or K.colors.faint
                self:drawRectBorder(x, by, box, box, 1, c.r, c.g, c.b)
                if row.check then self:drawRect(x + 3, by + 3, box - 6, box - 6, 1, c.r, c.g, c.b) end
            end
            x = x + box + K.GAP
        end
        if row.icon ~= nil then
            local size = math.min(height - 6, K.LINE + 8)
            local iy = y + math.floor((height - size) / 2)
            if row.icon and visible(iy, size) then self:drawTextureScaledAspect(row.icon, x, iy, size, size, 1, 1, 1, 1) end
            x = x + size + K.GAP
        end
        local textTop = y + math.floor((height - (row.sub and 2 * K.LINE or K.LINE)) / 2)
        if row.right and visible(textTop, K.LINE) then
            local c = K.colors[row.rightTone or "dim"]
            local shown = K.fit(row.right, math.max(60, (right - x) * 0.55))
            self:drawTextRight(shown, right, textTop, c.r, c.g, c.b, 1, K.FONT)
            right = right - K.width(shown) - K.PAD
        end
        if visible(textTop, K.LINE) then
            local c = K.colors[row.tone or "text"]
            self:drawText(K.fit(row.title, right - x), x, textTop, c.r, c.g, c.b, 1, K.FONT)
        end
        if row.sub and visible(textTop + K.LINE, K.LINE) then
            local c = K.colors[row.subTone or "dim"]
            self:drawText(K.fit(row.sub, right - x), x, textTop + K.LINE, c.r, c.g, c.b, 1, K.FONT)
        end
        return y + height
    end

    local render = child.render
    function child:render()
        if render then render(self) end
        if self.empty and self.emptyText then
            local d = K.colors.faint
            for index, line in ipairs(K.wrap(self.emptyText, self.width - 4 * K.PAD)) do
                self:drawTextCentre(line, self.width / 2, K.PAD * 2 + (index - 1) * K.LINE, d.r, d.g, d.b, 1, K.FONT)
            end
        end
    end
    parent:addChild(child)
    return child
end

-- Menus opened from windows, so choices live in submenus and not in dropdowns.
function K.menu(playerIndex, anchor)
    local menu = ISContextMenu.get(playerIndex, anchor:getAbsoluteX(), anchor:getAbsoluteY() + anchor:getHeight())
    menu:bringToTop()
    return menu
end

function K.option(menu, title, action, icon, tooltip)
    local option = menu:addOption(title, nil, action)
    if not option then return end
    if type(icon) == "string" then option.iconTexture = getTexture(icon) elseif icon then option.iconTexture = icon end
    if tooltip then
        local tip = ISToolTip:new()
        tip:initialise(); tip:setVisible(false); tip:setName(title)
        tip.description = K.escape(tooltip)
        option.toolTip = tip
    end
    return option
end

function K.submenu(menu, title, icon)
    local option = K.option(menu, title, nil, icon)
    local child = ISContextMenu:getNew(menu)
    menu:addSubMenu(option, child)
    return child, option
end

-- Windows ----------------------------------------------------------------

local Window = ISCollapsableWindow:derive("LootBoxGlass")
K.Window = Window
local remembered = {}

function Window:new(name, width, height, minWidth, minHeight)
    local core = getCore()
    local saved = remembered[name] or {}
    local scale = math.max(1, K.LINE / 18)
    width = math.min(core:getScreenWidth() - 20, saved.width or math.floor(width * scale))
    height = math.min(core:getScreenHeight() - 20, saved.height or math.floor(height * scale))
    local o = ISCollapsableWindow.new(self, saved.x or math.floor((core:getScreenWidth() - width) / 2),
        saved.y or math.floor((core:getScreenHeight() - height) / 2), width, height)
    o.name = name
    o.minimumWidth, o.minimumHeight = math.min(width, math.floor((minWidth or 400) * scale)), math.min(height, math.floor((minHeight or 240) * scale))
    o.backgroundColor, o.borderColor = K.color("glass"), K.color("line", 0.22)
    o.resizable = true
    return o
end

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    self.collapseButton:setVisible(false)
    local function resize(target, width, height)
        target:setWidth(width); target:setHeight(height); target:onResize()
    end
    self.resizeWidget.resizeFunction, self.resizeWidget2.resizeFunction = resize, resize
    self:build()
    self:layout()
end

function Window:top() return self:titleBarHeight() + K.GAP end
function Window:bottom() return self.height - math.max(K.GAP, self:resizeWidgetHeight() + 2) end
function Window:build() end
function Window:layout() end

function Window:onResize()
    ISCollapsableWindow.onResize(self)
    if self.resizeWidget then self:layout() end
end

function Window:remember()
    remembered[self.name] = { x = self.x, y = self.y, width = self.width, height = self.height }
end

function Window:show()
    self:initialise()
    self:addToUIManager()
    self:setVisible(true)
    self:bringToTop()
    return self
end

function Window:close()
    if self.closed then return end
    self.closed = true
    self:remember()
    K.unfocus(self)
    self:setVisible(false)
    self:removeFromUIManager()
    if self.onClosed then self.onClosed(self) end
end

function K.resetLayout() remembered = {} end

return K
