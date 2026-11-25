-- Stable sort by precomputed keys. Kahlua's table.sort is a left-pivot
-- quicksort that is quadratic and recursive on ordered input.
-- key(value) returns up to three comparable values; without it the values sort themselves.

local function before(x, y)
    if x.a ~= y.a then return x.a < y.a end
    if x.b ~= y.b then return x.b < y.b end
    if x.c ~= y.c then return x.c < y.c end
    -- Never equal: native timSort has no equality result and rejects inconsistent ties.
    return x.order < y.order
end

local function merge(entries)
    local source, target, count, width = entries, {}, #entries, 1
    while width < count do
        for first = 1, count, width * 2 do
            local middle, last = math.min(first + width, count + 1), math.min(first + width * 2, count + 1)
            local left, right = first, middle
            for index = first, last - 1 do
                if left < middle and (right >= last or before(source[left], source[right])) then
                    target[index], left = source[left], left + 1
                else target[index], right = source[right], right + 1 end
            end
        end
        source, target, width = target, source, width * 2
    end
    return source
end

return function(list, key)
    local entries = {}
    for index, value in ipairs(list) do
        local a, b, c
        if key then a, b, c = key(value) else a = value end
        entries[index] = {value = value, a = a, b = b, c = c, order = index}
    end
    if timSort then timSort(entries, before) else entries = merge(entries) end
    for index, entry in ipairs(entries) do list[index] = entry.value end
    return list
end
