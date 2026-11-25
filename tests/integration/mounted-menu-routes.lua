-- The item Pour Into and the clicked stand, with real menu and row modules.
-- The dispenser engine and the world are explicit doubles.
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local enabled,denied,truncated=true,false,false
local player,driver={},{}
local function donor(name,liquid,amount)
    local item={getContainer=function()return player end,getName=function()return name end}
    function item:getFluidContainer()return self.fluid end
    item.fluid={getUiName=function()return liquid end,getAmount=function()return amount end}
    return item,{label=name.." | Main inventory",place="Main inventory",item=item,fluid=item.fluid,amount=amount,capacity=amount,
        scope="main",pourSignature={[liquid]=1}}
end
local donorA,a=donor("Canteen","Water",2)
local donorB,b=donor("Canteen","Milk",1)
local donorC,c=donor("Flask","Water",.5)
local function coord(x,y)
    return {getX=function()return x end,getY=function()return y end,getZ=function()return 0 end}
end
local here, there = coord(10,10),coord(10,11)
function player:getCurrentSquare() return here end
local object={}
local anchor={object=object,kind="mounted",square=there}
local jug={state={amount=5,cap=15,fluid=a.fluid,mix={Water=1}}}
function there:getObjects()
    return {size=function()return 1 end,get=function(_,i)assert(i==0);return object end}
end
function getSpecificPlayer(index) assert(index==0);return player end
function getCell()
    return {getGridSquare=function(_,x,y,z) if x==10 and y==11 and z==0 then return there end end}
end
function getActivatedMods() return nil end
function instanceof(i,k) return (i==donorA or i==donorB or i==donorC) and k=="InventoryItem" end
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
    calls[#calls+1]={src=src,origin=origin,interaction=dst.interaction};return true
end
package.loaded["LootBox/App"]={get=function(index)assert(index==0);return driver end}
package.loaded["LootBox/Pour"]={options=function()return {} end,displayed=function()end}
package.loaded["LootBox/PourStacks"]={selection=function(items)return items end}
local Inventory=require "LootBox/PourInventory"
local snapshots=0
Inventory.snapshot=function() snapshots=snapshots+1;return {entries={a,b,c},truncated=truncated} end
Inventory.fillFrom=function() end
Inventory.plan=function(_,i)return {source=i==donorA and a or i==donorB and b or c,targets={},fill={}} end
package.loaded["LootBox/MountedDispenser"]={
    MAX_DONORS=128,
    capture=function(_,objects)
        if not denied and #objects==1 and objects[1]==object then return anchor end
    end,
    mountedMPEnabled=function()return enabled end,
    destinations=function(_,__,dst)assert(dst==anchor);return {jug} end,
    canFill=function(e,j) return not e.item.incompatible and j==jug end,
}
package.loaded["LootBox/WorldFluidMenu"]={fixtures=function()return {} end,fillRows=function()return {} end,
    lootRows=function()return {} end,pourRows=function()return {} end}
local PourMenu=require "LootBox/PourMenu"
local MountedMenu=require "LootBox/MountedDispenserMenu"
local function ctx(items,objects)
    return {playerIndex=0,parent=menu(),items=items,objects=objects,app=driver,preferences={},tooltip=toolTip,
        branded=function()error("not needed")end,interaction=function()return 12 end}
end
local route="Water Dispenser (Water), 5 / 15 L"

local click=ctx({donorA})
assert(PourMenu.add(click) and #click.parent.options==1)
local o=assert(find(assert(find(click.parent,"Pour Into").child),route))
o.onSelect(o.target);o.onSelect(o.target)
assert(#calls==1 and calls[1].src==a and calls[1].origin=="inventoryShortcuts" and calls[1].interaction==12 and snapshots==1)
click=ctx({donorB});PourMenu.add(click)
assert(find(find(click.parent,"Pour Into").child,"Water Dispenser, 5 / 15 L (mixes with Water)"))
print("PASS inventory Pour Into offers the exact nearby mounted dispenser once, says when it would mix")

click=ctx(nil,{object});snapshots=0
assert(MountedMenu.add(click) and #click.parent.options==1 and snapshots==1)
local child=find(click.parent,"Refill dispenser").child
assert(#child.options==4)
o=assert(find(child,"Fill from all Water (2)"));o.onSelect(o.target)
local direct=assert(find(child,"Canteen (Milk), 1 / 1 L (mixes with Water)"))
direct.onSelect(direct.target)
assert(#calls==2 and #calls[2].src==2 and calls[2].src[1]==a and calls[2].src[2]==c and calls[2].origin=="worldShortcuts")
print("PASS clicked stand offers each source and one batch per liquid from one inventory snapshot")

truncated=true
click=ctx(nil,{object});MountedMenu.add(click)
assert(not find(find(click.parent,"Refill dispenser").child,"Fill from all Water (2)"))
truncated=false
donorB.incompatible=true
click=ctx(nil,{object});MountedMenu.add(click)
assert(#find(click.parent,"Refill dispenser").child.options==3)
donorB.incompatible=false
for _,reason in ipairs({"native-api","reach","protected","incompatible"}) do
    enabled,denied,donorA.protected,donorA.incompatible=reason~="native-api",reason=="reach",reason=="protected",reason=="incompatible"
    click=ctx({donorA})
    assert(not PourMenu.add(click) and #click.parent.options==0,reason)
end
enabled,denied=false,false
click=ctx(nil,{object});assert(not MountedMenu.add(click) and #click.parent.options==0)
enabled,denied=true,true
click=ctx(nil,{object});assert(not MountedMenu.add(click) and #click.parent.options==0)
print("PASS no stale, protected, incompatible, truncated batch, or shortcuts without native APIs; nothing is shown instead")
