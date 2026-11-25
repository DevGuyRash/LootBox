local Sort = require "LootBox/Sort"

local Catalog = {}

local function rawCategory(item)
    local category = item:getDisplayCategory()
    if category ~= nil and tostring(category) ~= "" then return tostring(category) end
    if item.getItemType then return tostring(item:getItemType():toString()) end
    return tostring(item:getCategory())
end

function Catalog.categoryId(item)
    return "native:" .. rawCategory(item)
end

local function categoryName(raw)
    if type(getText) ~= "function" then return raw end
    local key = "IGUI_ItemCat_" .. raw
    local translated = getText(key)
    if translated == nil or translated == "" or translated == key then return raw end
    return translated
end

local function ordered(entry) return string.lower(entry.name), entry.id or entry.fullType end

function Catalog.read()
    if type(getAllItems) ~= "function" then return nil, "The game item catalog is not available yet" end
    local source = getAllItems()
    if not source then return nil, "The game item catalog is not available yet" end
    local result, categories, seen = { items = {}, categories = {} }, {}, {}
    for index = 0, source:size() - 1 do
        local item = source:get(index)
        if not item:getObsolete() and not item:isHidden() then
            local fullType = tostring(item:getFullName())
            if not seen[fullType] then
                seen[fullType] = true
                local raw = rawCategory(item)
                local id = "native:" .. raw
                result.items[#result.items + 1] = {
                    fullType = fullType,
                    name = tostring(item:getDisplayName() or item:getName()),
                    categoryId = id,
                }
                if not categories[id] then
                    categories[id] = true
                    result.categories[#result.categories + 1] = { id = id, name = categoryName(raw), kind = "native" }
                end
            end
        end
    end
    Sort(result.items, ordered)
    Sort(result.categories, ordered)
    return result
end

return Catalog
