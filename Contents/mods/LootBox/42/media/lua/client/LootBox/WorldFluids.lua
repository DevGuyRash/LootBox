-- Fixed world fluids are IsoObjects, not InventoryItems. Let the object's
-- directional rules choose the liquid (including plumbing and taint).
local Inventory=require "LootBox/PourInventory"
local Log=require "LootBox/Log"
local W={}
local donorPolicy={allowEquippedConsumption=true}
local receiverPolicy={allowMainInventoryFluidReceive=true}
-- The fixture is still there, allowed and beside the player.
function W.live(p,a)
    local o,s,here=a.object,a.square,p:getCurrentSquare()
    if not here or not s or o:getSquare()~=s or o:getObjectIndex()<0 then return false,"it is gone" end
    if not SafeHouse.isSafehouseAllowInteract(s,p) or not SafeHouse.isSafehouseAllowLoot(s,p) then return false,"safehouse" end
    local corrected=luautils.getCorrectSquareForWall(p,s)
    return here:getZ()==s:getZ() and corrected~=nil and math.abs(here:getX()-s:getX())<=1
        and math.abs(here:getY()-s:getY())<=1 and here:canReachTo(corrected),"too far"
end

local function capture(p,o)
    if not o or not instanceof(o,"IsoObject") or instanceof(o,"IsoWorldInventoryObject") or instanceof(o,"IsoMovingObject") then return end
    if instanceof(o,"IsoFeedingTrough") then o=o:getMasterTrough();if not o then return end end
    local s=o:getSquare()
    local a={object=o,square=s}
    if not s or not o:getSprite() or not W.live(p,a) then return end
    local cap,amount=o:getFluidCapacity(),o:getFluidAmount()
    if not (cap>0 and (o:hasFluid() or amount<cap and not o:isFluidInputLocked())) then return end
    a.capacity,a.amount,a.primary,a.tainted=cap,amount,o:getPrimaryFluid(),o:isTaintedWater()
    -- A large, full finite tank is not natural/mains unlimited water.
    local component=o:getFluidContainer()
    a.unlimited=cap>=9999 and amount==cap and not o:getUsesExternalWaterSource()
        and (not component or component:getAmount()==0)
    -- The game lets any rained-on floor tile be a water source.
    if not a.unlimited and IsoFlagType and o:getSprite():getProperties():has(IsoFlagType.solidfloor)
        and not s:getProperties():has(IsoFlagType.water) then return end
    local name=ISWorldObjectContextMenu.getMoveableDisplayName(o)
    a.natural=a.unlimited and not name and o:hasWater()
    a.name=name or (o:hasWater() and getText("ContextMenu_NaturalWaterSource")) or o:getFluidUiName() or "Fluid source"
    local here=p:getCurrentSquare()
    local dx,dy=s:getX()-here:getX(),s:getY()-here:getY()
    a.distance=dx*dx+dy*dy
    local vertical,horizontal=dy<0 and "north" or dy>0 and "south",dx<0 and "west" or dx>0 and "east"
    a.direction=vertical and horizontal and vertical.."-"..horizontal or vertical or horizontal or "here"
    return a
end

-- Usable fixtures around the player, nearest first. One shoreline is one source.
function W.objects(p)
    local out,seen,natural={},{},nil
    local here=p and p:getCurrentSquare()
    if not here or not getCell then return out end
    local function add(o)
        if not o or seen[o] then return end
        seen[o]=true
        local a=Log.guard("WorldFluids.capture",capture,p,o)
        if not a or a.object~=o and seen[a.object] then return end
        seen[a.object]=true
        if not a.natural then out[#out+1]=a
        elseif not natural or a.distance<natural.distance then natural=a end
    end
    for dx=-1,1 do for dy=-1,1 do
        local s=getCell():getGridSquare(here:getX()+dx,here:getY()+dy,here:getZ())
        if s then
            local obs=s:getObjects()
            for i=0,obs:size()-1 do add(obs:get(i)) end
        end
    end end
    if natural then out[#out+1]=natural end
    for index,a in ipairs(out) do a.order=index end
    table.sort(out,function(a,b)
        if a.distance~=b.distance then return a.distance<b.distance end
        return a.order<b.order
    end)
    local counts,seen={},{}
    for _,a in ipairs(out) do counts[a.name]=(counts[a.name] or 0)+1 end
    for _,a in ipairs(out) do
        a.label=counts[a.name]>1 and a.name..", "..a.direction or a.name
        seen[a.label]=(seen[a.label] or 0)+1
        if seen[a.label]>1 then a.label=a.label.." ("..seen[a.label]..")" end
    end
    return out
end

function W.liquid(a)
    if not a.primary then return nil end
    if type(a.primary)=="string" then return a.primary end
    return a.primary.getTranslatedName and a.primary:getTranslatedName() or nil
end

function W.describe(a)
    if not a then return "{none}" end
    return "{"..tostring(a.name).." at="..Log.point(a.square).." liquid="..tostring(W.liquid(a))
        ..string.format(" litres=%.5f/%.5f",a.object:getFluidAmount(),a.object:getFluidCapacity())
        .." unlimited="..tostring(a.unlimited).." tainted="..tostring(a.object:isTaintedWater())
        .." plumbed="..tostring(a.object:getUsesExternalWaterSource()).."}"
end

local function normalized(mix)
    if not mix then return end
    local total=0
    for _,ratio in pairs(mix) do total=total+ratio end
    if math.abs(total-1)<=.00001 then return mix end
end

-- What a fill from this fixture delivers, and the component that feeds it.
local function recipe(a)
    local o=a.object
    local external=o:getUsesExternalWaterSource()
    local provider=o
    if external then
        -- Ask the native plumbing resolver for the feed, not the tap's
        -- own component or just its primary fluid. A feed we cannot pin
        -- and independently verify is not an admissible fixture loan.
        provider=o:FindExternalWaterSource()
        if not provider or provider==o or not provider:isExistInTheWorld()
            or provider:getUsesExternalWaterSource() then return end
    end
    local component=provider:getFluidContainer()
    if component and component:getAmount()>0 then
        local raw=normalized(Inventory.mix({fluid=component}))
        if not raw then return end
        local mix=raw
        if external then
            mix={}
            for kind,ratio in pairs(raw) do
                -- The stock tap's createSampleAndPurifyWater replaces only
                -- TaintedWater. Other components remain in the same ratios.
                local out=kind==Fluid.TaintedWater and Fluid.Water or kind
                mix[out]=(mix[out] or 0)+ratio
            end
        end
        local primary=o:getPrimaryFluid()
        if not primary or not mix[primary] then return end
        return {provider=provider,component=component,mix=mix}
    end
    if external then return end
    -- Natural, mains and reserve sources without a populated component
    -- synthesize one native water type rather than a mixture.
    local kind=o:getPrimaryFluid() or o:isTaintedWater() and Fluid.TaintedWater
    if kind~=Fluid.Water and kind~=Fluid.TaintedWater then return end
    return {provider=o,component=component,mix={[kind]=1}}
end
function W.recipe(a) return Log.guard("WorldFluids.recipe",recipe,a) end

function W.relation(source,e)
    return Inventory.relation(source and source.mix,e.amount,e.pourSignature)
end

-- The installed stock fill menu requires a non-full Water-accepting receiver
-- AND the exact fixture's directional check (also checks its actual fluid).
function W.canReceive(p,a,e)
    local o=a.object
    if not o:hasFluid() or o:getFluidAmount()<=0 then return false,"fixture-empty" end
    if e.free<=0 or e.fluid:isFull() then return false,"vessel-full" end
    if p:hasFullInventory() or p:getFreeInventoryCapacity()<=0 then return false,"no-carry-capacity" end
    return e.fluid:canAddFluid(Fluid.Water) and o:canTransferFluidTo(e.fluid),"game-refuses-transfer"
end
function W.can(p,world,a,e,take)
    if not e or e.scope=="loot" or e.object~=e.item then return false,"vessel-not-carried" end
    local main=p:getInventory()
    if take then
        -- From a bag the game carries the vessel out and back, which Keep and
        -- Favorite do forbid.
        local held,reason
        if e.container==main then held=Inventory.reserved(world,e.item,receiverPolicy)
        else held,reason=world:protected(e.item,receiverPolicy) end
        if held then return false,"protected: "..tostring(reason) end
        return W.canReceive(p,a,e)
    end
    if Inventory.reserved(world,e.item,donorPolicy) then return false,"protected" end
    -- Stock ISAddFluidFromItemAction requires the donor in main inventory.
    -- It does not require a free primary hand, nor a particular equipped item.
    local o=a.object
    if e.container~=main then return false,"vessel-not-in-main" end
    if not (e.amount>0 and e.item:canStoreWater() and e.fluid:canPlayerEmpty()) then return false,"vessel-cannot-pour" end
    if o:isFluidInputLocked() or o:getFluidAmount()>=o:getFluidCapacity() then return false,"fixture-full-or-locked" end
    return o:canTransferFluidFrom(e.fluid),"game-refuses-transfer"
end

function W.permits(p,world,a,e,take)
    return Log.guard("WorldFluids.can",W.can,p,world,a,e,take)==true
end

function W.signature(e)
    if e.amount==0 then return true end
    e.pourSignature=e.pourSignature or Inventory.mix(e)
    return e.pourSignature~=nil
end

return W
