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
local aEntry,bEntry,cEntry,dEntry=target(a,.4,2),target(b,.3,1),target(c,.25,1,"Base.One"),target(d,.1,1,"Mod.Two")
local aBag,bBag,cBag,dBag=target(a1,.2,1,nil,"equipped"),target(b1,.1,2,nil,"equipped"),target(a2,0,1,nil,"equipped"),target(b2,0,1,nil,"equipped")
local plan={targets={aEntry,bEntry,cEntry,dEntry,aBag,bBag,cBag,dBag},fill={bEntry,aEntry,cEntry}}
local invPage={inventoryPane=p,getIsVisible=function()return true end}
local lootPage={inventoryPane=q,getIsVisible=function()return true end}
function getPlayerInventory(index)assert(index==0);return invPage end
function getPlayerLoot(index)assert(index==0);return lootPage end
local groups=Stacks.targets(plan,0)
assert(#groups==6 and groups[1].entry==aEntry and groups[1].count==2,"normalized volume beats lower absolute amount")
assert(groups[2].entry==cEntry and groups[3].entry==dEntry,"native same-name row cannot conflate full types")
assert(groups[4].entry==bBag and groups[4].count==2)
assert(groups[5].entry==cBag and groups[6].entry==dBag,"hidden bag does not get scanned")
q.visible=false
assert(#Stacks.targets(plan,0)==7)
q.visible=true;p.collapsed.Bottle=false
assert(#Stacks.targets(plan,0)==7)
p.collapsed.Bottle=true
local qAlt=pane(bag2);row(qAlt,"Bottle",a2,a2,b2);invPage.inventoryPane=qAlt
groups=Stacks.targets(plan,0)
assert(#groups==6 and groups[6].entry==cBag and groups[6].count==2 and groups[6].members[2]==dBag,
    "two visible same-name bag objects never merge; immutable ID breaks ratio/amount tie")
assert(Stacks.lessFilled(target(a,.3,1),target(b,.6,2)),"same normalized ratio uses absolute amount")
assert(#plan.fill==3 and plan.fill[1]==bEntry and plan.fill[2]==aEntry and plan.fill[3]==cEntry)
local forbiddenPane=setmetatable({inventory=holder()},{__index=function(_,key)
    if key=="itemslist" then error("non-target pane was read") end
end})
lootPage.inventoryPane=forbiddenPane;invPage.inventoryPane=p
groups=Stacks.targets({targets={aEntry,bEntry}},0)
assert(#groups==1 and groups[1].count==2, "no rows are read from holders outside the admitted target plan")
print("PASS visible compatible target rows, tiered tie-break, holder scan limit, and unchanged Fill All")

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
local fast={targets={target(first,.25,1),target(second,.5,1)}}
assert(#Stacks.targets(fast,0)==2,"visible row proof exceeding aggregate budget falls back to individuals")
assert(big.snapshots==1 and not big.containsCalls,
    "visible grouping cannot walk holder contents or invoke native contains per stock row")
for i=1,110 do vessel(big,i+10000) end
assert(not Stacks.selection({fullRow},0),"oversized holder membership fails closed")
print("PASS current pane provenance and bounded linear native holder reads")

local floatSmall=target(first,.30000001192092896,1)
local floatLarge=target(second,.89999997615814209,3)
assert(Stacks.lessFilled(floatSmall,floatLarge) and not Stacks.lessFilled(floatLarge,floatSmall),
    "nominally equal Java fractions are ordered by absolute volume")
invPage.inventoryPane=bp
bp.itemslist={fullRow} -- only the authoritative target row is visible for this case
assert(Stacks.targets({targets={floatLarge,floatSmall}},0)[1].entry==floatSmall,
    "grouped direct targets share the comparator")
local low=target(first,.29999949,1)
local middle=target(second,.29999951,1)
local high=target(vessel(big,32),.30000051,1)
local order={high,middle,low}
table.sort(order,Stacks.lessFilled)
assert(order[1]==low and order[2]==middle and order[3]==high)
assert(Stacks.lessFilled(low,high) and not Stacks.lessFilled(high,low),
    "near adjacent buckets still impose strict order")
print("PASS nominal Java float ties and deterministic adjacent buckets")
