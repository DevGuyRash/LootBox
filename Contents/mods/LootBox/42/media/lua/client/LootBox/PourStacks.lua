local Stacks = {}
local LIMIT = 4096

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end

function Stacks.lessFilled(a,b)
    -- Native amounts are Java floats. Use a shared integer ratio bucket so
    -- nominally equal fills tie without a non-transitive epsilon comparator.
    local ar=math.floor(a.amount/a.capacity*1000000+0.5)
    local br=math.floor(b.amount/b.capacity*1000000+0.5)
    if ar~=br then return ar<br end
    if a.amount~=b.amount then return a.amount<b.amount end
    return a.id<b.id
end

local function dense(list,limit)
    if type(list)~="table" or #list<1 or #list>limit then return nil end
    local n=0
    for k in pairs(list) do
        if type(k)~="number" or k%1~=0 or k<1 or k>#list then return nil end
        n=n+1
        if n>limit then return nil end
    end
    if n==#list then return n end
end

local function physical(item)
    return item~=nil and instanceof(item,"InventoryItem")
end

local function direct(item,holder)
    return physical(item) and item:getContainer()==holder and holder~=nil and holder:contains(item)==true
end

-- Stock refresh assigns invPanel and name to its own itemindex row, then
-- duplicates the first physical member at index 1 for the details header.
local function rowMembers(row,index,membership)
    local pane=row.invPanel
    if not pane or (index~=nil and pane.player~=index) or type(pane.itemindex)~="table"
        or type(pane.collapsed)~="table" or type(row.name)~="string"
        or pane.itemindex[row.name]~=row or pane.collapsed[row.name]~=true then return nil end
    local count=dense(row.items,LIMIT+1)
    if not count or count<2 then return nil end
    local result,refs,ids={}, {}, {}
    local holder=pane.inventory
    for i=2,count do
        local item=row.items[i]
        if not physical(item) or not holder or item:getContainer()~=holder
            or (membership and not membership[item]) or refs[item] then return nil end
        local id=item:getID()
        if not finite(id) or ids[id] then return nil end
        refs[item],ids[id]=true,true
        result[#result+1]=item
    end
    return result,refs
end

local function currentPane(pane,index)
    if not pane or not pane.getIsVisible or pane:getIsVisible()~=true then return false end
    local playerIndex=index or pane.player
    local function matches(page)
        return page and page.inventoryPane==pane
            and (not page.getIsVisible or page:getIsVisible()==true)
    end
    if getPlayerInventory or getPlayerLoot then
        return (getPlayerInventory and matches(getPlayerInventory(playerIndex)))
            or (getPlayerLoot and matches(getPlayerLoot(playerIndex)))
    end
    return pane.inventoryPage and matches(pane.inventoryPage)
end

local function directMembers(holder)
    if not holder then return nil end
    local items=holder:getItems()
    local n=items:size()
    if not finite(n) or n<1 or n>LIMIT or n%1~=0 then return nil end
    local members={}
    for i=0,n-1 do
        local item=items:get(i)
        if not physical(item) or members[item] then return nil end
        members[item]=true
    end
    return members
end

local function selection(items,index)
    if not dense(items,LIMIT) then return nil end
    local row, directItems = nil, {}
    for _,entry in ipairs(items) do
        if physical(entry) then
            directItems[entry]=true
        elseif type(entry)=="table" and not row then
            row=entry
        else
            return nil
        end
    end
    if row then
        local members,refs
        if row.invPanel then
            if not currentPane(row.invPanel,index) then return nil end
            local membership=directMembers(row.invPanel.inventory)
            if not membership then return nil end
            members,refs=rowMembers(row,index,membership)
        else
            -- Missing pane metadata can recover one real object, not authorize
            -- guessing a least-filled vessel from an unverified selection.
            local count=dense(row.items,LIMIT+1)
            if not count or count<2 then return nil end
            local only=row.items[2]
            if row.items[1]~=only or not physical(only) or not direct(only,only:getContainer())
                or not finite(only:getID()) then return nil end
            for i=3,count do if row.items[i]~=only then return nil end end
            members,refs={only},{[only]=true}
        end
        if not members then return nil end
        for item in pairs(directItems) do if not refs[item] then return nil end end
        return members
    end
    local item=next(directItems)
    if item and not next(directItems,item) and direct(item,item:getContainer()) and finite(item:getID()) then return {item} end
end

-- A sole raw InventoryItem is how stock passes explicitly expanded members.
-- An arbitrary set of distinct raw objects is not evidence of a stack click.
function Stacks.selection(items,index)
    local ok,result=pcall(selection,items,index)
    if ok then return result end
end

local function visibleRows(index,holders)
    local byItem, touched, inspected = {}, {}, 0
    local function add(page)
        local pane=page and page.inventoryPane
        if not pane or not holders[pane.inventory] or touched[pane] or not page.getIsVisible or not page:getIsVisible()
            or not pane.getIsVisible or not pane:getIsVisible() or type(pane.itemslist)~="table" then return end
        touched[pane]=true
        for i,row in ipairs(pane.itemslist) do
            if i>LIMIT then return false end
            if type(row)=="table" and row.invPanel==pane then
                inspected=inspected+(type(row.items)=="table" and #row.items or 1)
                if inspected>LIMIT then return false end
                -- The entries eligible for grouping have already had direct
                -- membership proved by the planner. Use the stock row's direct
                -- pointers here rather than calling native contains N times.
                local members=rowMembers(row,index)
                if members then
                    for _,item in ipairs(members) do
                        if byItem[item]~=nil then byItem[item]=false else byItem[item]=row end
                    end
                end
            end
        end
    end
    if getPlayerInventory and add(getPlayerInventory(index))==false then return {} end
    if getPlayerLoot and add(getPlayerLoot(index))==false then return {} end
    return byItem
end

-- Optional display-only grouping. Never changes plan.targets or plan.fill.
-- The entry is the single direct choice; members do not grant batch permission.
function Stacks.targets(plan,index)
    local entries=plan and plan.targets or {}
    local holders={}
    for _,entry in ipairs(entries) do if entry.container then holders[entry.container]=true end end
    local ok,rows=pcall(visibleRows,index,holders)
    if not ok then rows={} end
    local result,byRow={},{}
    for _,entry in ipairs(entries) do
        local row=rows[entry.item]
        local group
        if row and row.invPanel.inventory==entry.container and type(entry.fullType)=="string" and entry.fullType~="" then
            byRow[row]=byRow[row] or {}
            local scopes=byRow[row]
            scopes[entry.scope]=scopes[entry.scope] or {}
            local types=scopes[entry.scope]
            group=types[entry.fullType]
            if not group then
                group={entry=entry,count=0,members={}}
                types[entry.fullType]=group
                result[#result+1]=group
            end
        else
            group={entry=entry,count=0,members={}}
            result[#result+1]=group
        end
        group.count=group.count+1
        group.members[group.count]=entry
        if Stacks.lessFilled(entry,group.entry) then group.entry=entry end
    end
    for _,group in ipairs(result) do table.sort(group.members,Stacks.lessFilled) end
    return result
end

return Stacks
