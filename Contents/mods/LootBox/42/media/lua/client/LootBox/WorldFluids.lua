-- Fixed world fluids are IsoObjects, not InventoryItems. Let the object's
-- directional rules choose the liquid (including plumbing and taint).
local Inventory=require "LootBox/PourInventory"
local W={}
local donorPolicy={allowEquippedConsumption=true}
local receiverPolicy={allowMainInventoryFluidReceive=true}
local function near(a,b)
    return type(a)=="number" and type(b)=="number" and math.abs(a-b)<=math.max(.000001,math.min(.001,math.max(math.abs(a),math.abs(b))*.0000002))
end
W.near=near

function W.live(p,a)
    if p~=getSpecificPlayer(p:getPlayerNum()) or ISWorldObjectContextMenu.disableWorldMenu
        or (ISWorldMap_instance and ISWorldMap_instance:isVisible()) then return false end
    local trade=ISTradingUI and ISTradingUI.GetUIForPlayer(p)
    if trade and trade:isVisible() then return false end
    local o,s=a.object,a.square
    local here=p:getCurrentSquare()
    if not here or not s or o:getSquare()~=s or here:getZ()~=s:getZ() or s:getBuilding()~=p:getBuilding()
        or getCell():getGridSquare(s:getX(),s:getY(),s:getZ())~=s then return false end
    local i=o:getObjectIndex()
    local objects=s:getObjects()
    if i<0 or i>=objects:size() or objects:get(i)~=o then return false end
    if not SafeHouse or not SafeHouse.isSafehouseAllowInteract(s,p) or not SafeHouse.isSafehouseAllowLoot(s,p) then return false end
    if a.nearby then
        local corrected=luautils.getCorrectSquareForWall(p,s)
        return corrected and math.abs(here:getX()-s:getX())<=1 and math.abs(here:getY()-s:getY())<=1 and here:canReachTo(corrected)
    end
    return true
end

local function capture(p,o,nearby)
    if not o or not instanceof(o,"IsoObject") or instanceof(o,"IsoWorldInventoryObject") or instanceof(o,"IsoMovingObject") then return end
    if instanceof(o,"IsoFeedingTrough") then o=o:getMasterTrough();if not o then return end end
    local s=o:getSquare()
    local a={object=o,square=s,nearby=nearby}
    if not s or not o:getSprite() or not W.live(p,a) then return end
    local cap,amount=o:getFluidCapacity(),o:getFluidAmount()
    if not (cap>0 and (o:hasFluid() or amount<cap and not o:isFluidInputLocked())) then return end
    a.capacity,a.amount,a.primary,a.tainted=cap,amount,o:getPrimaryFluid(),o:isTaintedWater()
    -- A large, full finite tank is not natural/mains unlimited water.
    local component=o:getFluidContainer()
    a.unlimited=cap>=9999 and amount==cap and not o:getUsesExternalWaterSource()
        and (not component or component:getAmount()==0)
    local name=ISWorldObjectContextMenu.getMoveableDisplayName(o)
    a.name=name or (o:hasWater() and getText("ContextMenu_NaturalWaterSource")) or o:getFluidUiName() or "Fluid source"
    -- Co-located fixtures and separate sections of shoreline are distinct.
    a.place=string.format("%d,%d z%d #%d",s:getX(),s:getY(),s:getZ(),o:getObjectIndex()+1)
    return a
end

function W.objects(p,clicked)
    local out,seen={},{}
    local function add(o)
        if not o or seen[o] then return end
        seen[o]=true
        local ok,a=pcall(capture,p,o,clicked==nil)
        if ok and a then
            for _,old in ipairs(out) do if old.object==a.object then return end end
            out[#out+1]=a
        end
    end
    if clicked then
        for _,o in ipairs(clicked) do add(o) end
        return out
    end
    local here=p and p:getCurrentSquare()
    if not here or not getCell then return out end
    for dx=-1,1 do for dy=-1,1 do
        local s=getCell():getGridSquare(here:getX()+dx,here:getY()+dy,here:getZ())
        if s then
            local obs=s:getObjects()
            for i=0,obs:size()-1 do add(obs:get(i)) end
        end
    end end
    return out
end

-- The installed stock fill menu requires a non-full Water-accepting receiver
-- AND the exact fixture's directional check (also checks its actual fluid).
function W.canReceive(p,a,e)
    local o=a.object
    return o:hasFluid() and o:getFluidAmount()>0 and e.free>0 and not p:hasFullInventory()
        and p:getFreeInventoryCapacity()>0 and not e.fluid:isFull() and e.fluid:canAddFluid(Fluid.Water)
        and o:canTransferFluidTo(e.fluid)
end
function W.can(p,world,a,e,take)
    if not e or e.scope=="loot" or e.object~=e.item or world:protected(e.item,take and receiverPolicy or donorPolicy) then return false end
    local o=a.object
    if take then
        return W.canReceive(p,a,e)
    end
    -- Stock ISAddFluidFromItemAction requires the donor in main inventory.
    -- It does not require a free primary hand, nor a particular equipped item.
    return e.container==p:getInventory() and e.amount>0 and e.item:canStoreWater() and e.fluid:canPlayerEmpty()
        and not o:isFluidInputLocked() and o:getFluidAmount()<o:getFluidCapacity() and o:canTransferFluidFrom(e.fluid)
end

function W.permits(p,world,a,e,take)
    local ok,yes=pcall(W.can,p,world,a,e,take)
    return ok and yes==true
end

function W.signature(e)
    if e.amount==0 then return true end
    e.pourSignature=e.pourSignature or Inventory.mix(e)
    return e.pourSignature~=nil
end

function W.allowedEntry(p,world,a,e,take)
    local ok,live=Inventory.accessible(p,world,e,nil)
    return ok and near(e.capacity,live.capacity) and near(e.amount,live.amount)
        and (e.amount==0 or Inventory.sameMix(live,e.pourSignature))
        and W.can(p,world,a,live,take) and live or nil
end

-- Native item-field sync may refresh the fluid component, but a direct fill
-- never replaces or moves the selected item or changes its equipment role.
function W.inPlaceReceiver(p,world,e)
    if e.container~=p:getInventory() or world:protected(e.item,receiverPolicy) then return end
    local ok,live=Inventory.accessible(p,world,e,nil,true)
    if ok and near(live.capacity,e.capacity) then return live end
end

-- Stock bag pickup/return may replace the local item replica. Confirm only a
-- unique ID+type in the original exact holder with its original carried scope.
function W.received(p,world,e)
    local list=e.container:getItems()
    local item
    for i=0,list:size()-1 do
        local candidate=list:get(i)
        if candidate:getID()==e.id then
            if item or candidate:getFullType()~=e.fullType then return nil end
            item=candidate
        end
    end
    if not item then return end
    local ref={item=item,object=item,id=e.id,fullType=e.fullType,scope=e.scope,container=e.container}
    local ok,live=Inventory.accessible(p,world,ref,nil,true)
    if ok and near(live.capacity,e.capacity) then return live end
end

return W
