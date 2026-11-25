-- One window, one rail, one thing per page.
local K = require "LootBox/UIKit"
local Picker = require "LootBox/Picker"
local Lists = require "LootBox/ListPages"
local Info = require "LootBox/InfoPages"

local Main = K.Window:derive("LootBoxMain")
Main.open = {}
local pages = { require "LootBox/PlanPage", Lists.Loot, Lists.Categories, Lists.Storage, Info.Settings, Info.Help }

function Main.show(playerIndex, pageId, context)
    local window = Main.open[playerIndex]
    if not window then
        window = K.Window.new(Main, "main", 780, 540, 640, 400)
        window.playerIndex, window.title, window.pages = playerIndex, "LootBox", {}
        window.startPage, window.startContext = pageId or "plan", context
        Main.open[playerIndex] = window
        window.onClosed = function() Main.open[playerIndex] = nil end
        K.Window.show(window)
        return window
    end
    window:setVisible(true)
    window:bringToTop()
    window:go(pageId or window.current, context)
    return window
end

function Main:build()
    self.tabs = {}
    for _, definition in ipairs(pages) do
        local id = definition.id
        self.tabs[id] = K.tab(self, definition.title, self, function(window) window:go(id) end)
    end
    self:go(self.startPage, self.startContext)
end

function Main:rail()
    local width = 0
    for _, definition in ipairs(pages) do width = math.max(width, K.width(definition.title)) end
    return width + 4 * K.PAD
end

function Main:go(id, context)
    local definition
    for _, candidate in ipairs(pages) do if candidate.id == id then definition = candidate end end
    if not definition then return end
    K.unfocus(self)
    for key, page in pairs(self.pages) do page.body:setVisible(key == id) end
    self.current = id
    local page = self.pages[id]
    if not page then
        local body = ISPanel:new(0, 0, 10, 10)
        body:initialise()
        body.background, body.border = false, false
        self:addChild(body)
        page = definition.build(self, body)
        page.screen = definition
        self.pages[id] = page
    end
    for key, tab in pairs(self.tabs) do tab.current = key == id end
    self:layout()
    definition.opened(page, context)
    self:layout()
end

function Main:layout()
    if not self.tabs then return end
    local rail, y = self:rail(), self:top()
    for _, definition in ipairs(pages) do
        K.place(self.tabs[definition.id], 1, y, rail - 1)
        y = y + K.ROW + 2
    end
    local page = self.pages[self.current]
    if not page then return end
    K.place(page.body, rail + K.PAD, self:top() + 4, self.width - rail - 2 * K.PAD, self:bottom() - self:top() - 4)
    page.screen.layout(page)
end

function Main:prerender()
    K.Window.prerender(self)
    local rail, c = self:rail(), K.colors.sheet
    self:drawRect(1, self:titleBarHeight(), rail, self.height - self:titleBarHeight() - 1, c.a, c.r, c.g, c.b)
end

function Main:update()
    K.Window.update(self)
    local page = self.pages[self.current]
    if page and page.screen.tick then page.screen.tick(page) end
end

-- A small "choose several" window over the current page.
local PickWindow = K.Window:derive("LootBoxPick")

function PickWindow:build()
    self.picker = Picker.new(self, { selection = self.selection, chosenTitle = "Chosen", onlyCategories = self.onlyCategories })
    self.ok = K.button(self, "Use these", self, function(window) window.done(window.picker.selection); window:close() end, "primary")
    self.no = K.button(self, "Cancel", self, PickWindow.close, "ghost")
end

function PickWindow:layout()
    if not self.ok then return end
    local footer = self:bottom() - K.ROW
    self.picker:layout(K.PAD, self:top(), self.width - 2 * K.PAD, footer - self:top() - K.GAP)
    K.place(self.ok, self.width - K.PAD - self.ok.width, footer)
    K.place(self.no, K.PAD, footer)
end

function Main:pick(title, filter, done)
    local selection = { ids = {}, types = {} }
    for _, id in ipairs(filter.ids or {}) do selection.ids[#selection.ids + 1] = id end
    for _, fullType in ipairs(filter.types or {}) do selection.types[#selection.types + 1] = fullType end
    if self.picking then self.picking:close() end
    local window = K.Window.new(PickWindow, "pick", 560, 420, 460, 320)
    window.title, window.selection, window.done = title, selection, done
    window.onClosed = function() if self.picking == window then self.picking = nil end end
    self.picking = window
    return K.Window.show(window)
end

function Main.pickCategories(title, ids, done)
    local window = K.Window.new(PickWindow, "pick", 560, 420, 460, 320)
    local selection = { ids = {}, types = {} }
    for _, id in ipairs(ids) do selection.ids[#selection.ids + 1] = id end
    window.title, window.selection, window.onlyCategories = title, selection, true
    window.done = function(chosen) done(chosen.ids) end
    return K.Window.show(window)
end

function Main:close()
    if self.picking then self.picking:close() end
    K.Window.close(self)
end

function Main.closeAll()
    local active = {}
    for _, window in pairs(Main.open) do active[#active + 1] = window end
    for _, window in ipairs(active) do window:close() end
end

return Main
