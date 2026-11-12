package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

for _, name in ipairs({ "ISLabel", "ISPanel", "ISButton", "ISRichTextPanel", "ISComboBox",
    "ISScrollingListBox", "ISTextEntryBox", "ISTickBox" }) do package.loaded["ISUI/" .. name] = {} end

UIFont = { Small = "small" }
local fontHeight = 16
local manager = {
    getFontHeight = function() return fontHeight end,
    MeasureStringX = function(_, _, text) return #text * 7 end,
}
function getTextManager() return manager end

ISScrollingListBox = {}
function ISScrollingListBox:new(x, y, width, height)
    local object = { x = x, y = y, width = width, height = height, scroll = 0, draws = {} }
    function object:initialise() end
    function object:instantiate() end
    function object:getYScroll() return self.scroll end
    function object:setYScroll(value) self.scroll = value end
    function object:setScrollHeight(value) self.scrollHeight = value end
    function object:clear() self.items, self.selected = {}, 1 end
    function object:isVScrollBarVisible() return self.scrollbar == true end
    function object:setOnMouseDownFunction(target, callback) self.target, self.callback = target, callback end
    function object:drawRect(dx, dy, dw, dh)
        self.draws[#self.draws + 1] = { kind = "rect", x = dx, y = dy + self.scroll, width = dw, height = dh }
    end
    function object:drawRectBorder(dx, dy, dw, dh)
        self.draws[#self.draws + 1] = { kind = "border", x = dx, y = dy + self.scroll, width = dw, height = dh }
    end
    function object:drawText(text, dx, dy, r, g, b)
        self.draws[#self.draws + 1] = { kind = "text", text = text, x = dx, r = r, g = g, b = b,
            y = dy + self.scroll, height = fontHeight, width = #text * 7 }
    end
    return object
end

ISComboBox = {}
function ISComboBox:new(x, y, width, height)
    local object = {x = x, y = y, width = width, height = height, options = {}, selected = 0, tooltip = nil}
    function object:initialise() end
    function object:setToolTipMap(values) self.tooltip = values end
    function object:addOptionWithData(text, data, tooltip)
        self.options[#self.options + 1] = {text = text, data = data, tooltip = tooltip}
        if self.selected == 0 then self.selected = 1 end
    end
    function object:getOptionTooltip(index)
        local option = self.options[index]
        if option then
            if type(option) == "table" then
                if option.tooltip then return option.tooltip end
                if self.tooltip then return self.tooltip[option.text] or self.tooltip.defaultTooltip end
            elseif self.tooltip then return self.tooltip[option] or self.tooltip.defaultTooltip end
        end
    end
    return object
end

local Widgets = require "LootBox/Widgets"
local parent = { addChild = function() end }
local function newList(selection)
    return Widgets.list(parent, 0, 0, 240, 100, nil, nil, selection)
end
local function draw(widget, y, text, data)
    widget:doDrawItem(y, { index = 1, text = text or "Animal category", item = data or { key = "native:Animal" } }, true)
end
local function count(widget, kind)
    local result = 0
    for _, row in ipairs(widget.draws) do if row.kind == kind then result = result + 1 end end
    return result
end
local function contained(widget)
    for _, row in ipairs(widget.draws) do
        assert(row.y >= 1, row.kind .. " escaped above the list viewport")
        assert(row.y + row.height <= widget.height - 1, row.kind .. " escaped below the list viewport")
        assert(row.x >= 1 and row.x + row.width <= widget.width - 1, row.kind .. " escaped the list width")
    end
end
local passed = 0
local function test(name, run)
    run()
    passed = passed + 1
    print("PASS " .. name)
end

test("native disabled-button styling cannot mutate the palette or another control", function()
    ISButton = { new = function()
        return {
            initialise = function() end,
            setTooltip = function() end,
            setEnable = function(self, enabled)
                if not enabled then
                    self.borderColor.r, self.borderColor.g, self.borderColor.b = 0.7, 0.1, 0.1
                    self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b = 0, 0, 0
                end
            end,
        }
    end }
    local expected = { r = Widgets.colors.border.r, g = Widgets.colors.border.g,
        b = Widgets.colors.border.b, raised = Widgets.colors.raised.r }
    local first = Widgets.button(parent, 0, 0, 120, "Unavailable", nil, nil)
    local second = Widgets.button(parent, 0, 30, 120, "Available", nil, nil)
    first:setEnable(false)
    assert(second.borderColor.r == expected.r and second.borderColor.g == expected.g and second.borderColor.b == expected.b)
    assert(second.backgroundColor.r == expected.raised)
    assert(Widgets.colors.border.r == expected.r and Widgets.colors.border.g == expected.g and Widgets.colors.border.b == expected.b)
    assert(Widgets.colors.raised.r == expected.raised)
end)

test("search changes settle during native text-entry painting before rebuilding the list", function()
    local clock, callbacks, nativePaints = 0, 0, 0
    function getTimestampMs() return clock end
    ISTextEntryBox = { new = function(_, text)
        return { text = text,
            initialise = function() end, instantiate = function() end, setTooltip = function() end,
            setPlaceholderText = function(self, value) self.placeholder = value end,
            getText = function(self) return self.text end,
            prerender = function() nativePaints = nativePaints + 1 end,
        }
    end }
    local observed
    local widget = Widgets.entry(parent, 0, 0, 200, "", {}, function(_, field)
        callbacks, observed = callbacks + 1, field:getText()
    end, "Find supplies", "Search items")
    assert(widget.placeholder == "Search items")
    widget.text = "B"
    widget.onTextChangeFunction(nil, widget)
    clock = 80
    widget:prerender()
    assert(callbacks == 0)
    widget.text = "Bandage"
    widget.onTextChangeFunction(nil, widget)
    clock = 160
    widget:prerender()
    assert(callbacks == 0)
    clock = 201
    widget:prerender()
    widget:prerender()
    assert(callbacks == 1 and observed == "Bandage" and nativePaints == 4)
end)

test("closing an owned editor releases only its own focused text entry", function()
    local focused
    ISTextEntryBox = { new = function(_, text)
        local field = { text = text, initialise = function() end, instantiate = function() end, setTooltip = function() end }
        function field:isFocused() return focused == self end
        function field:unfocus() assert(focused == self); focused = nil end
        return field
    end }
    local owned = { addChild = function() end }
    local first = Widgets.entry(owned, 0, 0, 200, "Search draft")
    local second = Widgets.entry(owned, 0, 30, 200, "Setup name")
    local foreign = {}
    focused = foreign
    Widgets.unfocus(owned)
    assert(focused == foreign)
    focused = second
    Widgets.unfocus(owned)
    assert(focused == nil and first.text == "Search draft" and second.text == "Setup name")
end)

test("a partially scrolled top label cannot draw into the header", function()
    local widget = newList()
    widget.scroll = -17
    draw(widget, 0)
    assert(count(widget, "text") == 0)
    assert(count(widget, "rect") > 0)
    contained(widget)
end)

test("replacing a filtered list resets scrolling without selecting a different row", function()
    local widget = newList()
    widget.scroll, widget.smoothScrollTargetY, widget.selected = -80, -120, 4
    widget:clear()
    assert(widget.scroll == 0 and widget.smoothScrollTargetY == nil and widget.scrollHeight == 0)
    assert(widget.selected == 0)
    draw(widget, 0)
    assert(count(widget, "text") == 1 and count(widget, "rect") == 1)
    contained(widget)
end)

test("a complete selected row still draws text and its selection marker", function()
    local widget = newList({ ["native:Animal"] = true })
    widget.scroll = -17
    draw(widget, Widgets.H)
    assert(count(widget, "text") == 1)
    assert(count(widget, "border") == 1)
    contained(widget)
end)

test("a bottom label cannot draw into the footer", function()
    local widget = newList()
    draw(widget, 90)
    assert(count(widget, "text") == 0)
    contained(widget)
end)

test("scrolling each row through the viewport never submits an overflowing draw", function()
    for offset = -100, 70 do
        local widget = newList({ ["native:Animal"] = true })
        widget.scroll = offset
        for y = 0, 168, Widgets.H do draw(widget, y) end
        contained(widget)
    end
end)

test("long labels leave room for the native scrollbar", function()
    local widget = newList()
    widget.scrollbar = true
    draw(widget, 0, string.rep("Long category ", 20), { key = "custom:1", badge = "Mine" })
    local found
    for _, row in ipairs(widget.draws) do
        if row.kind == "text" then
            if row.text ~= "Mine" then
                found = row
                assert(row.text:sub(-3) == "...")
            end
            assert(row.x + row.width <= widget.width - 20)
        end
    end
    assert(found)
    contained(widget)
end)

test("font-height changes cannot leak a label above or below the list", function()
    for _, height in ipairs({ 12, 20, 32 }) do
        fontHeight = height
        for offset = -34, 34 do
            local widget = newList()
            widget.scroll = offset
            for y = 0, 140, Widgets.H do draw(widget, y) end
            contained(widget)
        end
    end
    fontHeight = 16
end)

local function texts(widget)
    local result = {}
    for _, row in ipairs(widget.draws) do if row.kind == "text" then result[#result + 1] = row end end
    return result
end

local function hasColor(draw, color)
    return draw.r == color.r and draw.g == color.g and draw.b == color.b
end

local function decision()
    return {segments = {
        {text = string.rep("Very long item name ", 20), tone = "item", share = .32},
        {text = "Protected", tone = "warning", share = .20},
        {text = "Bag contains items", tone = "text"},
    }}
end

test("long item names preserve a separately colored status and normal explanation", function()
    for _, width in ipairs({520, 640, 950}) do
        local widget = newList()
        widget.width, widget.scrollbar = width, true
        draw(widget, 0, "Long item   Protected   Bag contains items", decision())
        local submitted = texts(widget)
        assert(#submitted == 3)
        assert(submitted[1].text:sub(-3) == "..." and hasColor(submitted[1], Widgets.colors.item))
        assert(submitted[2].text == "Protected" and hasColor(submitted[2], Widgets.colors.warning))
        assert(submitted[3].text == "Bag contains items" and hasColor(submitted[3], Widgets.colors.text))
        assert(submitted[1].x + submitted[1].width < submitted[2].x)
        assert(submitted[2].x + submitted[2].width < submitted[3].x)
        assert(submitted[3].x + submitted[3].width <= width - 20)
        contained(widget)
    end
end)

test("resizing a decision list refits its names without losing the semantic status", function()
    local widget, row = newList(), decision()
    widget.width = 520
    draw(widget, 0, "Full item name and reason", row)
    local narrow = texts(widget)
    widget.width, widget.draws = 950, {}
    draw(widget, 0, "Full item name and reason", row)
    local wide = texts(widget)
    assert(#wide[1].text > #narrow[1].text and wide[2].text == narrow[2].text)
    assert(wide[3].text == "Bag contains items")
    contained(widget)
end)

test("each colored segment keeps the same top and bottom viewport protection", function()
    for _, height in ipairs({12, 20, 32}) do
        fontHeight = height
        for offset = -70, 70 do
            local widget = newList()
            widget.width, widget.scroll = 520, offset
            for y = 0, 168, Widgets.H do draw(widget, y, "Full decision", decision()) end
            contained(widget)
        end
    end
    fontHeight = 16
end)

test("category badges and names have separate colors without removing selection markers", function()
    local widget = newList({["custom:1"] = true})
    draw(widget, 0, "Run supplies", {key = "custom:1", segments = {
        {text = "My", tone = "custom"}, {text = "Run supplies", tone = "item"},
    }})
    local submitted = texts(widget)
    assert(#submitted == 2 and submitted[1].text == "My" and submitted[2].text == "Run supplies")
    assert(hasColor(submitted[1], Widgets.colors.custom) and hasColor(submitted[2], Widgets.colors.item))
    assert(count(widget, "border") == 1)
    contained(widget)
end)

test("a tall preference row paints visible details after its title scrolls away", function()
    local widget = newList({setting = true})
    widget.scroll = -Widgets.H
    local row = {index = 1, text = "Preference title", height = Widgets.H + 3 * fontHeight + 10,
        item = {key = "setting", details = {"First explanation", "Second explanation", "Third explanation"}}}
    assert(widget:doDrawItem(0, row, true) == row.height)
    local shown = texts(widget)
    assert(#shown == 2 and shown[1].text == "Second explanation" and shown[2].text == "Third explanation")
    assert(hasColor(shown[1], Widgets.colors.text) and count(widget, "border") == 0)
    contained(widget)
end)

test("section rows never draw a checkbox or selection marker", function()
    local widget = newList({section = true})
    widget.selected = 1
    widget:doDrawItem(0, {index = 1, text = "Review and reuse", height = Widgets.H,
        item = {key = "section", selectable = false, tone = "custom"}}, true)
    local shown = texts(widget)
    assert(#shown == 1 and hasColor(shown[1], Widgets.colors.custom) and count(widget, "border") == 0)
    contained(widget)
end)

test("variable height preference rows never paint into fixed headers or footers", function()
    for _, height in ipairs({12, 19, 26, 33, 38}) do
        fontHeight = height
        for offset = -240, 120, 3 do
            local widget = newList({setting = true})
            widget.height, widget.itemheight, widget.scroll = 180, height + 12, offset
            local row = {index = 1, text = "Preference", height = widget.itemheight + 3 * height + 10,
                item = {key = "setting", details = {"One explanation", "Two explanations", "Three explanations"}}}
            local y = 0
            for _ = 1, 3 do y = widget:doDrawItem(y, row, true) end
            assert(y == 3 * row.height)
            contained(widget)
        end
    end
    fontHeight = 16
end)

test("combo default help uses the native map while per-option help retains precedence", function()
    local widget = Widgets.combo(parent, 0, 0, 200, nil, nil, "Choose a saved workflow")
    widget:addOptionWithData("Choose a setup", false)
    widget:addOptionWithData("Medical supplies", "medical", "Only first aid items")
    assert(type(widget.tooltip) == "table" and widget:getOptionTooltip(1) == "Choose a saved workflow")
    assert(widget:getOptionTooltip(2) == "Only first aid items")
    widget.tooltip["Medical supplies"] = "Map fallback must not replace option help"
    assert(widget:getOptionTooltip(2) == "Only first aid items")
end)

test("a combo without default help safely reads plain and individually described options", function()
    local widget = Widgets.combo(parent, 0, 0, 200, nil, nil)
    widget:addOptionWithData("No help", false)
    widget:addOptionWithData("Carried items", "inventory", "Includes eligible bags")
    assert(type(widget.tooltip) == "table" and widget:getOptionTooltip(1) == nil)
    assert(widget:getOptionTooltip(2) == "Includes eligible bags" and widget:getOptionTooltip(3) == nil)
end)

print(passed .. " widget viewport cases passed (explicit native drawing boundary doubles)")
