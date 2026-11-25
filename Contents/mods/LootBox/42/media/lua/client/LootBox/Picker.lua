-- One way to choose categories and item types, used by the loot list, category
-- members, storage labels and job selections. Left: search and browse. Right:
-- what is chosen. Clicking moves entries across.
local K = require "LootBox/UIKit"
local App = require "LootBox/App"
local Describe = require "LootBox/Describe"

local Picker = {}
Picker.__index = Picker
local LIMIT = 250

function Picker.new(parent, options)
    local self = setmetatable({ parent = parent, options = options or {}, mode = options.mode or "categories", query = "" }, Picker)
    self.selection = options.selection or { ids = {}, types = {} }
    self.search = K.entry(parent, "Search", self, function(owner, text) owner.query = string.lower(text or ""); owner:browse() end)
    self.categoryTab = K.button(parent, "Categories", self, function(owner) owner:setMode("categories") end, "ghost")
    self.itemTab = K.button(parent, "Items", self, function(owner) owner:setMode("items") end, "ghost")
    self.list = K.list(parent, self, function(owner, row) owner:toggle(row) end)
    self.list.emptyText = "No matches."
    self.chosenLabel = K.label(parent, options.chosenTitle or "Chosen", "accent")
    self.chosen = K.list(parent, self, function(owner, row) owner:toggle(row) end)
    self.chosen.emptyText = options.emptyText or "Click entries on the left to add them."
    self:refresh()
    return self
end

local function has(list, value)
    for index, entry in ipairs(list) do if entry == value then return index end end
end

function Picker:setMode(mode)
    self.mode = mode
    self:browse()
end

function Picker:setSelection(selection, keep)
    self.selection = selection
    self:refresh(keep)
end

function Picker:toggle(row)
    if not row.key then return end
    local list = row.kind == "type" and self.selection.types or self.selection.ids
    local index = has(list, row.key)
    if index then table.remove(list, index) else list[#list + 1] = row.key end
    self:refresh(true)
    if self.options.changed then self.options.changed(self.options.owner, self.selection) end
end

function Picker:browse(keep)
    local catalog, err = App.catalog()
    local rows, hidden = {}, 0
    local query = self.query
    local function matches(text) return query == "" or string.lower(text):find(query, 1, true) ~= nil end
    local function add(row)
        if #rows < LIMIT then rows[#rows + 1] = row else hidden = hidden + 1 end
    end
    if not catalog then rows[1] = { title = tostring(err), tone = "warn" }
    elseif self.mode == "items" then
        for _, item in ipairs(catalog.items) do
            if matches(item.name .. " " .. item.fullType) then
                if #rows < LIMIT then
                    add({ title = item.name, key = item.fullType, kind = "type", icon = Describe.texture(item.fullType) or false,
                        check = has(self.selection.types, item.fullType) ~= nil, tooltip = item.name .. "\n" .. item.fullType })
                else hidden = hidden + 1 end
            end
        end
    else
        local custom, native = {}, {}
        for _, category in ipairs(catalog.categories) do
            if category.id ~= self.options.exclude and matches(category.name .. " " .. category.id) then
                local into = category.kind == "custom" and custom or native
                into[#into + 1] = category
            end
        end
        for _, pair in ipairs({ { "My categories", custom }, { "Game categories", native } }) do
            if #pair[2] > 0 then
                rows[#rows + 1] = { heading = true, title = pair[1], right = tostring(#pair[2]) }
                for _, category in ipairs(pair[2]) do
                    add({ title = category.name, key = category.id, kind = "category", check = has(self.selection.ids, category.id) ~= nil,
                        tone = category.kind == "custom" and "info" or "text" })
                end
            end
        end
    end
    if hidden > 0 then rows[#rows + 1] = { title = tostring(hidden) .. " more. Type to narrow the list.", tone = "faint" } end
    self.list:fill(rows, keep)
    self.categoryTab:setTone(self.mode == "categories" and "primary" or "ghost")
    self.itemTab:setTone(self.mode == "items" and "primary" or "ghost")
end

function Picker:refresh(keep)
    local rows = {}
    for _, id in ipairs(self.selection.ids) do
        rows[#rows + 1] = { title = App.categoryName(id), key = id, kind = "category", right = "remove", rightTone = "faint",
            tone = id:match("^custom:") and "info" or "text" }
    end
    for _, fullType in ipairs(self.selection.types) do
        rows[#rows + 1] = { title = Describe.type(fullType), key = fullType, kind = "type", icon = Describe.texture(fullType) or false,
            right = "remove", rightTone = "faint", tooltip = fullType }
    end
    self.chosen:fill(rows, keep)
    self.chosenLabel:set((self.options.chosenTitle or "Chosen") .. (#rows > 0 and ("  " .. #rows) or ""))
    self:browse(keep)
end

function Picker:layout(x, y, width, height)
    local left = math.floor((width - K.GAP) * 0.56)
    local right = width - left - K.GAP
    local tabs = self.categoryTab.width + self.itemTab.width + K.GAP
    K.place(self.search, x, y + math.floor((K.ROW - K.ENTRY) / 2), left - tabs)
    K.place(self.categoryTab, x + left - tabs + K.GAP, y)
    K.place(self.itemTab, x + left - self.itemTab.width, y)
    K.place(self.list, x, y + K.ROW + K.GAP, left, height - K.ROW - K.GAP)
    K.place(self.chosenLabel, x + left + K.GAP, y + 5)
    K.place(self.chosen, x + left + K.GAP, y + K.ROW + K.GAP, right, height - K.ROW - K.GAP)
end

function Picker:setVisible(visible)
    for _, widget in ipairs({ self.search, self.list, self.chosen, self.chosenLabel }) do widget:setVisible(visible) end
    self.categoryTab:setVisible(visible); self.itemTab:setVisible(visible)
end

return Picker
