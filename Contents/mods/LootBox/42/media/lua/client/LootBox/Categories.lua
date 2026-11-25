local Sort = require "LootBox/Sort"

local Categories = {}
local Graph = {}
Graph.__index = Graph

local function nonempty(value)
    return type(value) == "string" and value:find("%S") ~= nil
end

local function categoryId(value)
    return type(value) == "string"
        and (value:match("^native:.+") ~= nil or value:match("^custom:.+") ~= nil)
end

local function array(value, label, validate)
    if type(value) ~= "table" then return nil, label .. " must be a list" end
    local count, seen, result = 0, {}, {}
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #value then
            return nil, label .. " must be a dense list"
        end
        count = count + 1
    end
    if count ~= #value then return nil, label .. " must be a dense list" end
    for index, entry in ipairs(value) do
        if not validate(entry) then return nil, label .. " contains an invalid value" end
        if seen[entry] then return nil, label .. " contains a duplicate value" end
        seen[entry] = true
        result[index] = entry
    end
    return result
end

local function copyDefinition(definition)
    local copy = { id = definition.id, name = definition.name, types = {}, includes = {} }
    for index, value in ipairs(definition.types) do copy.types[index] = value end
    for index, value in ipairs(definition.includes) do copy.includes[index] = value end
    return copy
end

function Categories.new(definitions)
    if type(definitions) ~= "table" then return nil, "Categories must be a list" end
    local count = 0
    for index in pairs(definitions) do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #definitions then
            return nil, "Categories must be a dense list"
        end
        count = count + 1
    end
    if count ~= #definitions then return nil, "Categories must be a dense list" end
    local graph = setmetatable({ definitions = {}, byId = {} }, Graph)
    for _, source in ipairs(definitions) do
        if type(source) ~= "table" or type(source.id) ~= "string" or not source.id:match("^custom:.+") then
            return nil, "A custom category needs a stable custom: ID"
        end
        if graph.byId[source.id] then return nil, "Duplicate category ID " .. source.id end
        if not nonempty(source.name) then return nil, "A category needs a name" end
        local sourceTypes, sourceIncludes = source.types, source.includes
        if sourceTypes == nil then sourceTypes = {} end
        if sourceIncludes == nil then sourceIncludes = {} end
        local types, err = array(sourceTypes, source.name .. " item types", nonempty)
        if not types then return nil, err end
        local includes
        includes, err = array(sourceIncludes, source.name .. " included categories", categoryId)
        if not includes then return nil, err end
        local definition = { id = source.id, name = source.name, types = types, includes = includes, typeSet = {} }
        for _, fullType in ipairs(types) do definition.typeSet[fullType] = true end
        graph.definitions[#graph.definitions + 1] = definition
        graph.byId[definition.id] = definition
    end
    local parents, remaining, ready = {}, {}, {}
    for _, definition in ipairs(graph.definitions) do
        local children = 0
        for _, child in ipairs(definition.includes) do
            if child:sub(1, 7) == "custom:" then
                if not graph.byId[child] then return nil, "Missing included category " .. child end
                children = children + 1
                parents[child] = parents[child] or {}
                parents[child][#parents[child] + 1] = definition.id
            end
        end
        remaining[definition.id] = children
        if children == 0 then ready[#ready + 1] = definition.id end
    end
    local cursor = 1
    while cursor <= #ready do
        for _, parent in ipairs(parents[ready[cursor]] or {}) do
            remaining[parent] = remaining[parent] - 1
            if remaining[parent] == 0 then ready[#ready + 1] = parent end
        end
        cursor = cursor + 1
    end
    if #ready ~= #graph.definitions then
        for _, definition in ipairs(graph.definitions) do
            if remaining[definition.id] > 0 then return nil, "Category cycle includes " .. definition.name end
        end
    end
    return graph
end

local function cleanList(value, validate, refused)
    local result, seen = {}, {}
    if type(value) ~= "table" then
        if value ~= nil then refused("is not a list") end
        return result
    end
    local indexes = {}
    for index in pairs(value) do
        if type(index) == "number" then indexes[#indexes + 1] = index else refused("has a named entry") end
    end
    for _, index in ipairs(Sort(indexes)) do
        local entry = value[index]
        if not validate(entry) then refused("has an unusable value " .. tostring(entry))
        elseif seen[entry] then refused("repeats " .. entry)
        else seen[entry] = true; result[#result + 1] = entry end
    end
    return result
end

-- Keeps every usable part of damaged definitions. Returns a graph and a list of
-- plain notes, one per category dropped or value removed. No notes means nothing was lost.
function Categories.salvage(definitions)
    local notes, kept, byId = {}, {}, {}
    local function note(text) notes[#notes + 1] = text end
    if type(definitions) ~= "table" then
        note("Dropped every category: the saved list is unreadable")
        definitions = {}
    end
    local indexes = {}
    for index in pairs(definitions) do
        if type(index) == "number" then indexes[#indexes + 1] = index else note("Dropped the unnumbered entry " .. tostring(index)) end
    end
    for _, index in ipairs(Sort(indexes)) do
        local source = definitions[index]
        if type(source) ~= "table" or type(source.id) ~= "string" or not source.id:match("^custom:.+") then
            note("Dropped entry " .. tostring(index) .. ": it has no category ID")
        elseif byId[source.id] then note("Dropped a second copy of " .. source.id)
        else
            local entry = {id = source.id, name = source.name}
            if not nonempty(entry.name) then
                entry.name = source.id:sub(8)
                note("Renamed a category without a name to " .. entry.name)
            end
            local function refused(list) return function(why) note(entry.name .. ": its " .. list .. " " .. why) end end
            entry.types = cleanList(source.types, nonempty, refused("item list"))
            entry.includes = cleanList(source.includes, categoryId, refused("included categories"))
            kept[#kept + 1], byId[entry.id] = entry, entry
        end
    end
    -- Follow each chain once; an inclusion that leads back into its own chain is the one that closes a cycle.
    local state = {}
    for _, root in ipairs(kept) do
        local stack = not state[root.id] and {{entry = root, at = 1}} or {}
        if stack[1] then state[root.id] = "open" end
        while #stack > 0 do
            local top = stack[#stack]
            local child = top.entry.includes[top.at]
            if not child then state[top.entry.id] = "done"; table.remove(stack)
            elseif child:sub(1, 7) ~= "custom:" then top.at = top.at + 1
            elseif not byId[child] or state[child] == "open" then
                note(top.entry.name .. ": removed the included category " .. child
                    .. (byId[child] and ", which includes it in return" or ", which no longer exists"))
                table.remove(top.entry.includes, top.at)
            else
                top.at = top.at + 1
                if not state[child] then
                    state[child] = "open"
                    stack[#stack + 1] = {entry = byId[child], at = 1}
                end
            end
        end
    end
    return Categories.new(kept), notes
end

local function matches(graph, id, descriptor, labels, visited)
    local stack = { id }
    while #stack > 0 do
        local current = table.remove(stack)
        if not visited[current] then
            visited[current] = true
            if labels[current] or descriptor.categoryId == current then return true end
            local definition = graph.byId[current]
            if definition then
                if definition.typeSet[descriptor.fullType] then return true end
                for _, child in ipairs(definition.includes) do stack[#stack + 1] = child end
            end
        end
    end
    return false
end

local function labelSet(descriptor)
    local result = {}
    for _, id in ipairs(descriptor.labels or {}) do result[id] = true end
    return result
end

function Graph:matches(id, descriptor)
    return matches(self, id, descriptor, labelSet(descriptor), {})
end

function Graph:matchesFilter(filter, descriptor)
    if filter.all == true then return true end
    for _, fullType in ipairs(filter.types or {}) do
        if descriptor.fullType == fullType then return true end
    end
    local labels, visited = labelSet(descriptor), {}
    for _, id in ipairs(filter.ids or {}) do
        if matches(self, id, descriptor, labels, visited) then return true end
    end
    return false
end

-- IDs of the custom categories this item belongs to.
function Graph:customMatches(descriptor)
    local result, labels = {}, labelSet(descriptor)
    for _, definition in ipairs(self.definitions) do
        if matches(self, definition.id, descriptor, labels, {}) then result[#result + 1] = definition.id end
    end
    return result
end

function Graph:list()
    local result = {}
    for index, definition in ipairs(self.definitions) do result[index] = copyDefinition(definition) end
    return result
end

return Categories
