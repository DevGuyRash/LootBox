require "ISUI/ISLabel"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISRichTextPanel"
require "ISUI/ISComboBox"
require "ISUI/ISScrollingListBox"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"

local W = {}
W.H = getTextManager():getFontHeight(UIFont.Small) + 12
W.GAP = 10
W.colors = {
    base = { r = 0.122, g = 0.153, b = 0.169, a = 0.98 },
    raised = { r = 0.18, g = 0.224, b = 0.239, a = 1 },
    text = { r = 0.91, g = 0.898, b = 0.851, a = 1 },
    muted = { r = 0.67, g = 0.73, b = 0.73, a = 1 },
    accent = { r = 0.835, g = 0.694, b = 0.427, a = 1 },
    success = { r = 0.569, g = 0.745, b = 0.655, a = 1 },
    danger = { r = 0.851, g = 0.51, b = 0.471, a = 1 },
    custom = { r = 0.59, g = 0.77, b = 0.82, a = 1 },
    item = { r = 0.62, g = 0.81, b = 0.88, a = 1 },
    warning = { r = 0.94, g = 0.75, b = 0.43, a = 1 },
    border = { r = 0.38, g = 0.45, b = 0.46, a = 0.9 },
}

function W.color(name)
    local source = W.colors[name or "text"] or W.colors.text
    return { r = source.r, g = source.g, b = source.b, a = source.a }
end

function W.unfocus(parent)
    for _, field in ipairs(parent and parent.lootBoxEntries or {}) do
        if field:isFocused() then field:unfocus() end
    end
end

function W.escape(text)
    return tostring(text or ""):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\r", ""):gsub("\n", " <LINE> ")
end

function W.setText(panel, text, rich)
    text = tostring(text or "")
    if panel.contentText == text and panel.contentRich == rich then return end
    panel.contentText, panel.contentRich = text, rich
    panel.text = rich and text or W.escape(text)
    panel:paginate()
    panel:setYScroll(0)
end

function W.text(parent, x, y, width, height, text, rich)
    local child = ISRichTextPanel:new(x, y, width, height)
    child:initialise()
    child.autosetheight = false
    child.clip = true
    child.background = false
    child.defaultFont = UIFont.Small
    child.textColor = W.color("text")
    child:setMargins(0, 2, 18, 2)
    parent:addChild(child)
    child:addScrollBars()
    W.setText(child, text, rich)
    return child
end

function W.label(parent, x, y, text, tone, font)
    local color = W.colors[tone or "text"] or W.colors.text
    local child = ISLabel:new(x, y, W.H, text, color.r, color.g, color.b, 1, font or UIFont.Small, true)
    child:initialise()
    parent:addChild(child)
    return child
end

function W.heading(parent, x, y, text)
    return W.label(parent, x, y, text, "accent", UIFont.Medium)
end

function W.button(parent, x, y, width, text, target, callback, tooltip, tone)
    local child = ISButton:new(x, y, width, W.H, text, target, callback)
    child:initialise()
    child.backgroundColor = W.color("raised")
    child.backgroundColorMouseOver = { r = 0.27, g = 0.32, b = 0.34, a = 1 }
    child.borderColor = W.color("border")
    child.textColor = W.color(tone)
    local nativeSetEnable = child.setEnable
    function child:setEnable(enabled)
        nativeSetEnable(self, enabled)
        if not enabled then
            self.borderColor = W.color("border")
            self.borderColor.a = 0.45
            self.backgroundColor = W.color("base")
        end
    end
    child:setTooltip(tooltip or text)
    parent:addChild(child)
    return child
end

function W.entry(parent, x, y, width, text, target, callback, tooltip, placeholder)
    local child = ISTextEntryBox:new(text or "", x, y, width, W.H)
    child:initialise()
    child:instantiate()
    child.target = target
    if callback then
        child.onTextChangeFunction = function(_, widget) widget.pendingChange = getTimestampMs() end
        local nativePrerender = child.prerender
        function child:prerender()
            if nativePrerender then nativePrerender(self) end
            if self.pendingChange and getTimestampMs() - self.pendingChange >= 120 then
                self.pendingChange = nil
                callback(target, self)
            end
        end
    end
    child.backgroundColor = { r = 0.07, g = 0.1, b = 0.11, a = 0.95 }
    child.borderColor = W.color("border")
    child:setTooltip(tooltip or "")
    if placeholder then child:setPlaceholderText(placeholder) end
    parent:addChild(child)
    parent.lootBoxEntries = parent.lootBoxEntries or {}
    parent.lootBoxEntries[#parent.lootBoxEntries + 1] = child
    return child
end

function W.combo(parent, x, y, width, target, callback, tooltip)
    local child = ISComboBox:new(x, y, width, W.H, target, callback)
    child:initialise()
    child.backgroundColor = { r = 0.09, g = 0.13, b = 0.14, a = 1 }
    child.backgroundColorMouseOver = W.color("raised")
    child.borderColor = W.color("border")
    child.textColor = W.color("text")
    child.tooltip = tooltip
    parent:addChild(child)
    return child
end

function W.check(parent, x, y, width, text, selected, target, callback, tooltip)
    local child = ISTickBox:new(x, y, width, W.H, "", target, callback)
    child:initialise()
    child:addOption(text)
    child:setSelected(1, selected == true)
    child.tooltip = tooltip
    child.textColor = W.color("text")
    parent:addChild(child)
    return child
end

local function fit(text, width, font)
    if width <= 0 then return "" end
    if getTextManager():MeasureStringX(font, "...") > width then return "" end
    if getTextManager():MeasureStringX(font, text) <= width then return text end
    local low, high = 0, #text
    while low < high do
        local middle = math.ceil((low + high) / 2)
        if getTextManager():MeasureStringX(font, text:sub(1, middle) .. "...") <= width then low = middle
        else high = middle - 1 end
    end
    return text:sub(1, low) .. "..."
end

function W.list(parent, x, y, width, height, target, onSelect, selection)
    local child = ISScrollingListBox:new(x, y, width, math.max(W.H, height))
    child:initialise()
    child:instantiate()
    child.selected = 0
    local nativeClear = child.clear
    if nativeClear then
        function child:clear()
            nativeClear(self)
            self.selected = 0
            self.smoothScrollTargetY, self.smoothScrollY = nil, 0
            self:setYScroll(0)
            self:setScrollHeight(0)
        end
    end
    child.itemheight = W.H
    child.font = UIFont.Small
    child.drawBorder = true
    child.backgroundColor = { r = 0.075, g = 0.105, b = 0.115, a = 1 }
    child.borderColor = W.color("border")
    child.selection = selection
    if onSelect then child:setOnMouseDownFunction(target, onSelect) end
    child.doDrawItem = function(self, rowY, row, alternate)
        local rowHeight = row.height or self.itemheight
        local top = rowY + self:getYScroll()
        local bottom = top + rowHeight
        if bottom <= 1 or top >= self.height - 1 then return rowY + rowHeight end
        local selectable = row.item.selectable ~= false
        local checked = selectable and self.selection and self.selection[row.item.key]
        local selected = selectable and (row.index == self.selected or checked)
        local fill = selected and W.colors.raised or W.colors.base
        local first, last = math.max(1, top), math.min(self.height - 1, bottom)
        self:drawRect(1, first - self:getYScroll(), self.width - 2, last - first,
            selected and 0.95 or (alternate and 0.5 or 0.16), fill.r, fill.g, fill.b)
        local fontHeight = getTextManager():getFontHeight(self.font)
        local textY = rowY + math.floor((self.itemheight - fontHeight) / 2)
        local visibleTextY = textY + self:getYScroll()
        if visibleTextY >= 1 and visibleTextY + fontHeight <= self.height - 1 then
            local color = W.colors[row.item.tone or (checked and "success" or "text")] or W.colors.text
            local textX = self.selection and selectable and 30 or 10
            if self.selection and selectable then
                local boxY = rowY + math.floor((self.itemheight - 12) / 2)
                self:drawRectBorder(9, boxY, 12, 12, 1, color.r, color.g, color.b)
                if checked then self:drawRect(12, boxY + 3, 6, 6, 1, color.r, color.g, color.b) end
            elseif selected then
                self:drawRect(2, first - self:getYScroll(), 3, last - first, 1,
                    W.colors.accent.r, W.colors.accent.g, W.colors.accent.b)
            end
            local available = self.width - textX - (self:isVScrollBarVisible() and 20 or 10)
            local segments = row.item.segments
            if not segments then
                segments = {}
                if row.item.badge then segments[#segments + 1] = { text = row.item.badge, tone = row.item.tone or "muted" } end
                segments[#segments + 1] = { text = row.text, tone = row.item.tone or (checked and "success" or "text") }
            end
            local gap = getTextManager():MeasureStringX(self.font, "   ")
            local totalWidth = available
            for _, segment in ipairs(segments) do
                local text = tostring(segment.text or "")
                if text ~= "" then
                    local columnWidth = segment.share and math.floor(totalWidth * segment.share) or available
                    local shown = fit(text, math.min(available, columnWidth), self.font)
                    local tint = W.colors[segment.tone or "text"] or W.colors.text
                    self:drawText(shown, textX, textY, tint.r, tint.g, tint.b, 1, self.font)
                    if shown ~= text and not segment.share then break end
                    local used = segment.share and (columnWidth + gap) or (getTextManager():MeasureStringX(self.font, shown) + gap)
                    textX, available = textX + used, available - used
                    if available <= 0 then break end
                end
            end
        end
        local detailX = self.selection and selectable and 30 or 10
        local available = self.width - detailX - (self:isVScrollBarVisible() and 20 or 10)
        for index, text in ipairs(row.item.details or {}) do
            local detailY = rowY + self.itemheight + (index - 1) * fontHeight
            local visibleY = detailY + self:getYScroll()
            if visibleY >= 1 and visibleY + fontHeight <= self.height - 1 then
                local tint = W.colors.text
                self:drawText(fit(text, available, self.font), detailX, detailY,
                    tint.r, tint.g, tint.b, 1, self.font)
            end
        end
        return rowY + rowHeight
    end
    parent:addChild(child)
    return child
end

function W.panel(parent, x, y, width, height)
    local child = ISPanel:new(x, y, width, height)
    child:initialise()
    child.backgroundColor = W.color("raised")
    child.borderColor = W.color("border")
    parent:addChild(child)
    return child
end

return W
