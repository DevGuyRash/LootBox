-- Exercise actual inventory Pour Into and stand menus; outside world and
-- engine execution are explicit test doubles here.
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local enabled,denied,truncated=true,false,false
local player,driver={},{}
local donorA,donorB={getFluidContainer=function()return {} end},{getFluidContainer=function()return {} end}
function donorA:getContainer() return player end
function donorB:getContainer() return player end
local a={label="Canteen",item=donorA,amount=2,capacity=2,scope="main",pourSignature={}}
local b={label="Canteen",item=donorB,amount=1,capacity=1,scope="main",pourSignature={}}
a.fluid={getUiName=function()return "Water" end}
b.fluid={getUiName=function()return "Milk" end}
local function coord(x,y)
    return {getX=function()return x end,getY=function()return y end,getZ=function()return 0 end}
end
local here, there = coord(10,10),coord(10,11)
function player:getCurrentSquare() return here end
local object={}
local anchor={object=object,kind="mounted",square=there}
local jug={state={amount=5,cap=15,fluid=a.fluid}}
function there:getObjects()
    return {size=function()return 1 end,get=function(_,i)assert(i==0);return object end}
end
function getSpecificPlayer(index) assert(index==0);return player end
function getCell()
    return {getGridSquare=function(_,x,y,z) if x==10 and y==11 and z==0 then return there end end}
end
function getActivatedMods() return nil end
function instanceof(i,k) return (i==donorA or i==donorB) and k=="InventoryItem" end
function isClient() return true end
function getTexture(i) return i end
local function menu()
    return {options={},addOption=function(self,k,t,f)
        local option={name=k,target=t,onSelect=f};self.options[#self.options+1]=option;return option
    end,addSubMenu=function(_,o,m)o.child=m end}
end
local function find(m,s)
    for _,o in ipairs(m.options) do if o.name==s then return o end end
end
ISContextMenu={getNew=menu}
local function toolTip(option,title,message) option.tip=message end
driver.world={protected=function(_,i)return i.protected==true end}
local calls={}
function driver:refillDispenser(dst,src,bottle,origin)
    assert(dst==anchor and bottle==jug)
    calls[#calls+1]={src=src,origin=origin};return true
end
package.loaded["LootBox/App"]={get=function(index)assert(index==0);return driver end}
package.loaded["LootBox/Pour"]={options=function()return {} end,displayed=function()end}
package.loaded["LootBox/PourStacks"]={selection=function(items)return items end,targets=function()return {} end}
package.loaded["LootBox/PourInventory"]={snapshot=function()return {} end,
    plan=function(_,i)return {source=i==donorA and a or b,targets={},fill={}} end,
    choose=function(_,items,_,extra)
        for _,i in ipairs(items) do
            local e=i==donorA and a or b
            if extra(e) then return {source=e,targets={},fill={}} end
        end
    end}
package.loaded["LootBox/MountedDispenser"]={
    capture=function(_,objects)
        if not denied and #objects==1 and objects[1]==object then return anchor end
    end,
    mountedMPEnabled=function()return enabled end,
    destinations=function(_,__,dst)assert(dst==anchor);return {jug} end,
    donors=function()return {a,b},truncated end,
    canFill=function(e,j) return not e.item.incompatible and j==jug end,
    plannedMountedTopUp=function(e)return e.amount end,
}
package.loaded["LootBox/WorldFluidMenu"]={inventory=function()end,destinations=function()return {} end,addTargets=function()end}
local PourMenu=require "LootBox/PourMenu"
local MountedMenu=require "LootBox/MountedDispenserMenu"

local parent,branded=menu(),menu()
PourMenu.add(0,parent,branded,{donorA},driver,{},toolTip)
local route="Water Dispenser (Water) | 5.000 / 15.000 L"
local o=assert(find(assert(find(parent,"Pour Into").child),route))
o.onSelect(o.target)
local duplicate=assert(find(assert(find(branded,"Pour Into").child),route))
duplicate.onSelect(duplicate.target)
assert(#calls==1 and calls[1].src==a and calls[1].origin=="inventoryShortcuts")
print("PASS inventory Pour Into exposes exact nearby mounted dispenser without portable targets; one shared dispatch")

parent,branded=menu(),menu()
local once={}
MountedMenu.add(0,parent,{object},driver,toolTip,true,once)
MountedMenu.add(0,branded,{object},driver,toolTip,false,once)
o=assert(find(assert(find(parent,"Top up mounted dispenser").child),"Fill from All"))
o.onSelect(o.target)
local direct=assert(find(assert(find(branded,"Top up mounted dispenser").child),"Canteen #2 (Milk) | add 1.000 L (1.000 L available)"))
direct.onSelect(direct.target)
assert(#calls==2 and calls[2].src[1]==a and calls[2].src[2]==b)
print("PASS clicked stand offers ordered exact individual sources or Fill from All")

truncated=true
parent=menu();MountedMenu.add(0,parent,{object},driver,toolTip,true)
assert(not find(find(parent,"Top up mounted dispenser").child,"Fill from All"))
truncated=false
donorB.incompatible=true
parent=menu();MountedMenu.add(0,parent,{object},driver,toolTip,true)
assert(#find(parent,"Top up mounted dispenser").child.options==1)
donorB.incompatible=false
for _,reason in ipairs({"native-api","reach","protected","incompatible"}) do
    enabled,denied,donorA.protected,donorA.incompatible=reason~="native-api",reason=="reach",reason=="protected",reason=="incompatible"
    parent,branded=menu(),menu()
    PourMenu.add(0,parent,branded,{donorA},driver,{},toolTip)
    assert(not find(parent,"Pour Into").child)
end
print("PASS no stale, protected, incompatible, truncated batch, or shortcuts without native APIs")
