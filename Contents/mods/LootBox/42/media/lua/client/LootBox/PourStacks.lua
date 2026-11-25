local Log = require "LootBox/Log"
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

local function hasRow(rows,value)
    if type(rows)~="table" then return false end
    for i,row in ipairs(rows) do
        if i>LIMIT then return false end
        if row==value then return true end
    end
    return false
end

local function displayedLoot(index,holder)
    local page=getPlayerLoot and getPlayerLoot(index)
    local pane=page and page.inventoryPane
    local visible=page and (page.getIsVisible or page.isVisible)
    if not pane or type(visible)~="function" or not visible(page) then return nil end
    if not holder then return pane.inventory end
    local sections,byHolder=pane.ninvSections,pane.ninvSectionOf
    local sectionMode=pane.ninvCombinedBuilt==false and type(sections)=="table" and type(byHolder)=="table"
    if pane.inventory==holder and not sectionMode then return holder end
    if not pane.getIsVisible or not pane:getIsVisible() then return nil end
    -- A different holder can only participate if the actual pane shows it.
    -- A nearby tab on its own is never proof the holder was displayed.
    local button
    for i,b in ipairs(page.backpacks or {}) do
        if i>256 then return nil end
        if b.inventory==holder then button=b;break end
    end
    if not button then return nil end
    -- Composite views can show a holder even when the last item is on loan.
    -- Only recognize consistent section bookkeeping on the visible pane.
    if sectionMode then
        local section=byHolder[holder]
        if type(section)=="table" and sections[section.index]==section and section.button==button
            and section.container==holder and section.folded==false then return holder end
        return nil -- never reopen a known hidden or folded section
    end
    -- Generic rendered row path for views without an exposed section table.
    for i,row in ipairs(pane.items or {}) do
        if i>LIMIT then return nil end
        if physical(row) then
            if direct(row,holder) then return holder end
        elseif type(row)=="table" and row.invPanel==pane and not row.ninvMerged
            and row.items and direct(row.items[2],holder) and hasRow(pane.itemslist,row) then
            return holder
        end
    end
end

function Stacks.displayedLoot(index,holder)
    return Log.guard("PourStacks.displayedLoot",displayedLoot,index,holder)
end

-- Stock refresh assigns invPanel and name to its own itemindex row, then
-- duplicates the first physical member at index 1 for the details header.
local function rowMembers(row,index,membership)
    local pane=row.invPanel
    if not pane or (index~=nil and pane.player~=index) or type(pane.itemindex)~="table"
        or type(pane.collapsed)~="table" or type(row.name)~="string"
        or pane.collapsed[row.name]~=true or row.ninvMerged then return nil end
    local count=dense(row.items,LIMIT+1)
    if not count or count<2 then return nil end
    local result,refs,ids={}, {}, {}
    local first=row.items[2]
    local holder=physical(first) and first:getContainer()
    if not holder then return nil end
    if pane.itemindex[row.name]~=row or pane.inventory~=holder then
        if not hasRow(pane.itemslist,row) or not hasRow(pane.items,row) then return nil end
        if pane.inventory~=holder and Stacks.displayedLoot(index,holder)~=holder then return nil end
    end
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
            local first=type(row.items)=="table" and row.items[2] or nil
            local holder=physical(first) and first:getContainer()
            local membership=holder and directMembers(holder)
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
    local item
    for candidate in pairs(directItems) do
        if item then return nil end
        item=candidate
    end
    if item and direct(item,item:getContainer()) and finite(item:getID()) then return {item} end
end

-- A sole raw InventoryItem is how stock passes explicitly expanded members.
-- An arbitrary set of distinct raw objects is not evidence of a stack click.
function Stacks.selection(items,index)
    return Log.guard("PourStacks.selection",selection,items,index)
end

return Stacks
