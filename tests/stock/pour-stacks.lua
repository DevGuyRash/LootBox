-- Optional stock-source smoke, not installed game/Kahlua and not portable suite.
local path=assert(arg[1],"provide the pinned stock ISInventoryPane.lua path")
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
for _,module in ipairs({"ISUI/ISPanel","ISUI/ISButton","ISUI/ISMouseDrag","ISUI/ISInventoryItem",
    "TimedActions/ISTimedActionQueue","TimedActions/ISEatFoodAction","BodyDragging/corpseStorageCheck",
    "TimedActions/ISInventoryTransferUtil"}) do package.loaded[module]=true end
ISPanel={derive=function() return {} end}
ISMouseDrag={}
JoypadState={players={}}
function getCore() return {getGoodHighlitedColor=function() return {} end} end
function getPlayerHotbar() return nil end
function table.wipe(t) for k in pairs(t) do t[k]=nil end end
function instanceof(item,kind) return kind=="InventoryItem" and item.physical==true end
assert(loadfile(path))()
local Stacks=require "LootBox/PourStacks"
local Inventory=require "LootBox/PourInventory"
local function list(rows)
    return {size=function() return #rows end,get=function(_,i) return rows[i+1] end}
end
local main={rows={}}
function main:contains(item)
    for _,v in ipairs(self.rows) do if v==item then return true end end
    return false
end
function main:getItems() return list(self.rows) end
function main:getType() return "inventory" end
function main:isLockedToCharacter() return false end
function main:isInCharacterInventory() return true end
function main:setDrawDirty() end
local player={getInventory=function() return main end}
function getSpecificPlayer() return player end
FluidContainer={CanTransfer=function(a,b) return a~=b end}
FluidUtil={roundTransfer=function(n) return n end}
local stockFluid = {}
local function newItem(id,name,amount,capacity)
    local i={id=id,name=name,physical=true}
    local f={amount=amount}
    function i:getID() return self.id end
    function i:getName() return self.name end
    function i:getContainer() return main end
    function i:getFullType() return "Base."..self.name end
    function i:isSealed() return false end
    function i:getFluidContainer() return f end
    function i:isHidden() return false end
    function i:IsFood() return false end
    function i:getUnequippedWeight() return 1 end
    function i:getDisplayCategory() return "Container" end
    function f:getAmount() return self.amount end
    function f:getCapacity() return capacity end
    function f:getFreeCapacity() return capacity-self.amount end
    function f:getOwner() return i end
    function f:canPlayerEmpty() return true end
    function f:createFluidSample()
        return {size=function() return self.amount>0 and 1 or 0 end,
            getFluid=function(_,index) if index==0 then return stockFluid end end,
            getPercentage=function(_,index) if index==0 then return 1 end end,
            release=function() end}
    end
    table.insert(main.rows,i)
    return i,f
end
local representative,above=newItem(77,"Carton",.8,1)
local least,below=newItem(43,"Carton",.9,2)
local _,unused=newItem(55,"OtherBottle",0,1)
local nop=function() end
local toggle={setVisible=nop}
local pane=setmetatable({inventory=main,parent={},player=0,items={},collapsed={},selected={},
    expandAll=toggle,collapseAll=toggle,itemSortFunc=function(a,b) return a.name<b.name end,
    updateScrollbars=nop,isMouseOver=function() return false end,updateWorldObjectHighlight=nop,
    getIsVisible=function() return true end,
    getAbsoluteX=function() return 0 end,getAbsoluteY=function() return 0 end,getYScroll=function() return 0 end},
    {__index=ISInventoryPane})
local page={inventoryPane=pane,getIsVisible=function()return true end}
pane.inventoryPage=page
function getPlayerInventory(index) if index==0 then return page end end
local choices,actual,plan
ISInventoryPaneContextMenu={createMenu=function(index,inInventory,rows)
    assert(index==0 and inInventory)
    actual=ISInventoryPane.getActualItems(rows)
    choices=assert(Stacks.selection(rows,index))
    plan=assert(Inventory.choose(Inventory.snapshot(player,{},main,nil),choices,{}))
    return {numOptions=2}
end}
local function refresh()
    pane:refreshContainer() -- real stock grouping/dummy header/restoration
    pane.items={}
    -- Rendering projection, not group minting. Stock creates the groups
    -- above; UI rendering itself remains a boundary double.
    for _,row in ipairs(pane.itemslist) do
        pane.items[#pane.items+1]=row
        if not pane.collapsed[row.name] then
            for j=2,#row.items do pane.items[#pane.items+1]=row.items[j] end
        end
    end
end
local function click(index)
    pane.selected={};pane.mouseOverOption=index
    assert(pane:onRightMouseUp(100,100)) -- real selection + context event input
end
refresh()
local stock=pane.itemindex.Carton
assert(stock.invPanel==pane and stock.items[1]==representative and stock.items[2]==representative)
assert(pane.collapsed.Carton)
click(1)
assert(#actual==2 and #choices==2 and plan.source.item==least and plan.source.amount==.9)
assert(above.amount==.8 and below.amount==.9 and unused.amount==0,"opening a menu cannot pour")
pane.collapsed.Carton=false
refresh()
assert(pane.items[2]==representative and pane.items[3]==least)
click(2)
assert(#actual==1 and #choices==1 and plan.source.item==representative)
above.amount=.5 -- simulate an external observed fluid update, not a pour action
refresh()
click(2)
assert(#actual==1 and plan.source.item==representative and plan.source.amount==.5 and below.amount==.9)
print("PASS stock refresh/right-click/flatten -> exact collapsed least-filled and expanded singleton; no transfer")
