package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Stacks=require "LootBox/PourStacks"
local function contains(c,item)
    c.containsCalls=(c.containsCalls or 0)+1
    for _,v in ipairs(c.items) do if v==item then return true end end
    return false
end
local function holder()
    return {items={},contains=contains,getItems=function(self)
        self.snapshots=(self.snapshots or 0)+1
        return {size=function()return #self.items end,get=function(_,i)
            self.reads=(self.reads or 0)+1
            return self.items[i+1]
        end}
    end}
end
local function vessel(c,id)
    local item={inventory=true,getContainer=function()return c end,getID=function()return id end}
    c.items[#c.items+1]=item
    return item
end
function instanceof(item,typ) return type(item)=="table" and item.inventory==true and typ=="InventoryItem" end
local function pane(c,n)
    local p={inventory=c,itemindex={},itemslist={},collapsed={},player=n or 0,visible=true,
        getIsVisible=function(self)return self.visible end}
    p.inventoryPage={inventoryPane=p}
    return p
end
local function row(p,key,head,...)
    local r={name=key,invPanel=p,items={head,...}}
    p.itemindex[key]=r;p.itemslist[#p.itemslist+1]=r;p.collapsed[key]=true
    return r
end

local main,bag1,bag2=holder(),holder(),holder()
local p,q,r=pane(main),pane(bag1),pane(bag2)
local a,b,c,d=vessel(main,1),vessel(main,2),vessel(main,3),vessel(main,4)
local a1,b1,a2,b2=vessel(bag1,5),vessel(bag1,6),vessel(bag2,7),vessel(bag2,8)
local native=row(p,"Bottle",a,a,b)
local other=row(p,"Other",c,c,d)
local bagRow=row(q,"Bottle",a1,a1,b1)
row(r,"Bottle",a2,a2,b2)
local picked=assert(Stacks.selection({native,b,b},0))
assert(#picked==2 and picked[1]==a and picked[2]==b)
native.items[1]=c
picked=assert(Stacks.selection({native},0))
assert(#picked==2 and picked[1]==a and picked[2]==b, "stale representational row header is never physical input")
assert(not Stacks.selection({native,c},0))
assert(not Stacks.selection({native,other},0))
assert(not Stacks.selection({a,b},0))
assert(not Stacks.selection({native},1))
p.collapsed.Bottle=false
assert(not Stacks.selection({native},0))
assert(Stacks.selection({b},0)[1]==b,"individual expanded row stays exact")
assert(Stacks.selection({b,b},0)[1]==b,"repeated sole physical selection is still exact")
p.collapsed.Bottle=true
assert(not Stacks.selection({{items={a,b}}},0))
assert(Stacks.selection({{items={a,a}}},0)[1]==a)
assert(not Stacks.selection({{items={a,a,b}}},0))
assert(not Stacks.selection({{name="Bottle",invPanel=p,items={a,a,b}}},0))
native.items[3]=a1
assert(not Stacks.selection({native},0),"cross-holder stack fails closed")
native.items[3]=vessel(main,1)
assert(not Stacks.selection({native},0),"duplicate immutable ID is ambiguous")
native.items={[1]=a,[2]=a,[4]=b}
assert(not Stacks.selection({native},0),"sparse malformed stock row fails closed")
native.items={a,a,b}
local huge={}
for i=1,4098 do huge[i]=a end
local saved=native.items
native.items=huge
assert(not Stacks.selection({native},0))
native.items=saved
print("PASS authoritative collapsed row, exact expanded singleton, dummy and multi-selection rejection")

local function target(x,amount,capacity,kind,scope)
    return {item=x,id=x:getID(),container=x:getContainer(),fullType=kind or "Base.Bottle",
        scope=scope or "main",amount=amount,capacity=capacity,free=capacity-amount,label="Bottle"}
end
assert(Stacks.lessFilled(target(a,.3,1),target(b,.6,2)),"same normalized ratio uses absolute amount")
local invPage={inventoryPane=p,getIsVisible=function()return true end}
local lootPage={inventoryPane=q,getIsVisible=function()return true end}
function getPlayerInventory(index)assert(index==0);return invPage end
function getPlayerLoot(index)assert(index==0);return lootPage end
local oldPane=invPage.inventoryPane
invPage.inventoryPane=pane(main)
assert(not Stacks.selection({native},0),"an indexed but detached pane cannot authorize a collapsed source")
invPage.inventoryPane=oldPane
p.visible=false
assert(not Stacks.selection({native},0))
p.visible=true

local big=holder()
local bp=pane(big)
local first,second=vessel(big,30),vessel(big,31)
local fullRow=row(bp,"Vessels",first,first,second)
for i=1,3990 do
    local nail=vessel(big,i+100)
    row(bp,"Nail "..i,nail,nail)
end
invPage.inventoryPane=bp
assert(#Stacks.selection({fullRow},0)==2)
assert(big.snapshots==1 and big.reads==#big.items and not big.containsCalls,
    "source selection reads each physical member only once")
for i=1,110 do vessel(big,i+10000) end
assert(not Stacks.selection({fullRow},0),"oversized holder membership fails closed")
print("PASS current pane provenance and bounded linear native holder reads")

local floatSmall=target(first,.30000001192092896,1)
local floatLarge=target(second,.89999997615814209,3)
assert(Stacks.lessFilled(floatSmall,floatLarge) and not Stacks.lessFilled(floatLarge,floatSmall),
    "nominally equal Java fractions are ordered by absolute volume")
local low=target(first,.29999949,1)
local middle=target(second,.29999951,1)
local high=target(vessel(big,32),.30000051,1)
local order={high,middle,low}
table.sort(order,Stacks.lessFilled)
assert(order[1]==low and order[2]==middle and order[3]==high)
assert(Stacks.lessFilled(low,high) and not Stacks.lessFilled(high,low),
    "near adjacent buckets still impose strict order")
print("PASS nominal Java float ties and deterministic adjacent buckets")
