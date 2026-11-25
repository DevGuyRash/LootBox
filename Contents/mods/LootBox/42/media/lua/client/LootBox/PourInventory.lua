local Stacks = require "LootBox/PourStacks"
local Items = require "LootBox/Items"
local Vessels = require "LootBox/Vessels"
local call = require "LootBox/Safe"
local Pour = {}
local MAX_ITEMS, MAX_CONTAINERS, MAX_DEPTH = 4096, 48, 8
local MAX_TARGETS, MAX_CHOICE_WORK = 512, 8192

local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function count(list)
    local n = call(list, "size")
    return finite(n) and math.max(0, math.floor(n)) or nil
end

local function text(value) return type(value) == "string" and value ~= "" and value or nil end
local function itemName(item) return text(call(item, "getName")) or "Container" end

-- The game's own names. A vessel's item name already spells out its contents in
-- the player's language, so the vessel and the liquid are read separately.
function Pour.liquid(fluid)
    if not fluid or call(fluid,"getAmount") == 0 then return nil end
    if call(fluid,"isMixture") == true then return getText and getText("Fluid_Mixture") or "Mixture" end
    local primary=call(fluid,"getPrimaryFluid")
    return text(call(primary,"getTranslatedName")) or text(primary) or text(call(fluid,"getUiName"))
end
function Pour.vesselName(entry)
    if entry.amount > 0 then return text(call(entry.fluid,"getTranslatedContainerName")) or itemName(entry.item) end
    return itemName(entry.item)
end
function Pour.litres(amount) return (string.format("%.2f",amount):gsub("0+$",""):gsub("%.$","")) end

-- Filling or pouring in place neither moves nor deletes a vessel, which is all
-- that Favorite and Keep guard against. Every other protection still applies.
function Pour.reserved(world,item,policy)
    local protected,reason=world:protected(item,policy)
    return protected==true and reason~="Favorite" and reason~="Keep"
end

local function adjacentFloor(player, object)
    local square, here=call(object,"getSquare"),call(player,"getSquare")
    if call(object,"isExistInTheWorld")~=true or not square or not here then return false end
    if square==here then return true end
    local x,y,z=call(square,"getX"),call(square,"getY"),call(square,"getZ")
    local px,py,pz=call(here,"getX"),call(here,"getY"),call(here,"getZ")
    return finite(x) and finite(y) and finite(z) and finite(px) and finite(py) and z==pz
        and math.abs(x-px)<=1 and math.abs(y-py)<=1 and call(here,"isBlockedTo",square)==false
end

local function entryFor(player, item, container, scope, path)
    local id,fullType = call(item, "getID"), call(item,"getFullType")
    local object,groundSquare = item,nil
    if not finite(id) or call(item, "isSealed") ~= false then return nil end
    local fluid=call(item,"getFluidContainer")
    if call(container, "getType") == "floor" then
        -- True world components transfer in place. Ordinary item-owned
        -- fluid is only eligible through an exact native ground loan.
        local floorObject=call(item,"getWorldItem")
        local component=call(floorObject,"getFluidContainer")
        if call(floorObject,"getItem")~=item or not adjacentFloor(player,floorObject) then return nil end
        if component and call(component,"getOwner")==floorObject then
            if call(component,"isMultiTileMoveable")~=false then return nil end
            object,fluid,groundSquare=floorObject,component,call(floorObject,"getSquare")
        else return nil end
    end
    if not fluid or call(fluid,"isMultiTileMoveable")==true or call(fluid, "getOwner") ~= object
        or call(fluid, "canPlayerEmpty") ~= true then return nil end
    local capacity, amount, free = call(fluid, "getCapacity"), call(fluid, "getAmount"), call(fluid, "getFreeCapacity")
    if not finite(capacity) or capacity <= 0 or not finite(amount) or amount < 0 or not finite(free) or free < 0 then return nil end
    local where=path or (scope=="main" and "Main inventory" or scope=="equipped" and "Equipped" or scope=="carried" and "Carried" or "Displayed loot")
    local label=itemName(item) .. " | " .. where
    return {id=id, fullType=fullType, item=item, object=object, container=container, scope=scope, fluid=fluid,
        groundSquare=groundSquare,
        capacity=capacity, amount=amount, free=free, label=label, place=where}
end

local function round(n) return Vessels.amount(n, n) or 0 end

function Pour.compatible(source, target)
    if not source or not target or source.item == target.item or source.id == target.id
        or source.fluid == target.fluid or (source.object ~= source.item and target.object ~= target.item)
        or round(math.min(source.amount, target.free)) <= 0
        or not FluidContainer or not FluidContainer.CanTransfer then return false end
    local ok, allowed = pcall(FluidContainer.CanTransfer, source.fluid, target.fluid)
    return ok and allowed == true
end

function Pour.hasFluid(item)
    if call(item,"getFluidContainer") then return true end
    return call(call(item,"getWorldItem"),"getFluidContainer") ~= nil
end

local function scan(player, world, loot, allowLoot)
    local main = call(player, "getInventory")
    if not main then return {},true end
    local todo = {{container=main, depth=0}}
    if allowLoot and loot and loot ~= main and call(loot,"isLockedToCharacter",player) == false
        and call(world,"owns",loot) ~= true then
        local name=call(world,"name",loot)
        local label=call(loot,"getType")=="floor" and "Displayed floor"
            or type(name)=="string" and name~="" and ("Displayed " .. name) or "Displayed loot"
        todo[#todo+1] = {container=loot, scope="loot", depth=0, path=label}
    end
    local result, refs, ids, ambiguous, containers, countSeen = {}, {}, {}, {}, {}, 0
    local truncated = false
    for pos=1, MAX_CONTAINERS do
        local current = todo[pos]
        if not current then break end
        local container, scope = current.container, current.scope
        if not containers[container] and call(container,"isLockedToCharacter",player) == false then
            containers[container] = true
            local items = call(container, "getItems")
            local rows=count(items)
            if not rows or rows>MAX_ITEMS-countSeen then truncated=true end
            for index=0,math.min(rows or 0,MAX_ITEMS-countSeen)-1 do
                countSeen = countSeen + 1
                local item = call(items, "get", index)
                if item and not refs[item] and call(item,"getContainer") == container then
                    refs[item]=true
                    local id = call(item, "getID")
                    if finite(id) then
                        if ids[id] then ambiguous[id]=true end
                        ids[id]=true
                    end
                    local bag = scope~="loot" and call(item,"getInventory") or nil
                    local vessel = Pour.hasFluid(item)
                    -- Ordinary cargo is neither, and most of an inventory is cargo.
                    local gear = (vessel or bag) and container == main and Items.equipped(player,item)
                    local entry = vessel and entryFor(player,item,container,scope or (gear and "equipped" or "main"),current.path)
                    if entry and (scope~="loot" or (world and (call(container,"getType")=="floor"
                        or (call(item,"isFavorite")~=true and call(world,"protected",item)~=true))
                        and call(world,"consumptionSource",item,container)==true)) then
                        result[#result+1]=entry
                    end
                    if bag and not containers[bag] and call(bag,"getContainingItem") == item then
                        if #todo<MAX_CONTAINERS and current.depth<MAX_DEPTH then
                            todo[#todo+1]={container=bag, scope=scope or (gear and "equipped" or "carried"),
                                depth=current.depth+1, path=itemName(item)}
                        else truncated=true end
                    end
                end
            end
        end
    end
    local exact={}
    for _, entry in ipairs(result) do
        if not ambiguous[entry.id] then exact[#exact+1]=entry end
    end
    return exact,truncated
end

local function order(a,b) return a.id<b.id end
local function copy(entry)
    local duplicate={}
    for key,value in pairs(entry) do duplicate[key]=value end
    return duplicate
end

-- A clicked receiver authorizes one inverse portable pour, not a wider
-- search from a carried source. Loot-to-loot always needs the opt-in.
function Pour.legalScope(source,target,options,clickedReceiver)
    if target.scope~="loot" then return true end
    if source.scope=="loot" then return source.container==target.container and options.pourLootToLoot==true end
    return target.item==clickedReceiver and clickedReceiver~=nil and
        (source.scope=="main" or source.scope=="carried" or source.scope=="equipped")
end

function Pour.snapshot(player, world, container, lootPane)
    local entries,truncated=scan(player,world,lootPane,container~=nil and container==lootPane)
    table.sort(entries,order)
    local sources={}
    for _,entry in ipairs(entries) do
        if entry.container==container and round(entry.amount)>0 then sources[entry.item]=entry end
    end
    return {entries=entries,sources=sources,truncated=truncated,mixtures={}}
end

function Pour.source(snapshot, item)
    local template=snapshot and snapshot.sources[item]
    return template and copy(template) or nil
end

-- A snapshot is a menu-open boundary, not action authorization. Cache both
-- successes and unreadable mixtures only here; execution still samples again.
local function mixture(snapshot,entry)
    if entry.amount==0 then return true end
    local result=snapshot.mixtures[entry.fluid]
    if result==nil then
        result=Pour.mix(entry) or false
        snapshot.mixtures[entry.fluid]=result
    end
    return result
end

-- The same liquid within a percent. Anything else would be contaminated by a
-- pour and is only ever offered as one explicit choice.
function Pour.sameLiquid(a,b)
    if type(a)~="table" or type(b)~="table" then return false end
    for kind,ratio in pairs(a) do if math.abs(ratio-(b[kind] or 0))>.01 then return false end end
    for kind,ratio in pairs(b) do if ratio>.01 and not a[kind] then return false end end
    return true
end
function Pour.relation(donorMix,targetAmount,targetMix)
    if targetAmount==0 then return "empty" end
    return Pour.sameLiquid(donorMix,targetMix) and "same" or "mixes"
end

-- Portable donors for explicitly selected receivers: one clicked loot vessel,
-- or carried vessels. Never infer a receiver from a type, label or later tab.
function Pour.fillFrom(snapshot,receivers,options)
    local wanted,targets={},{}
    for _,item in ipairs(receivers) do wanted[item]=true end
    for _,e in ipairs(snapshot.entries) do
        if wanted[e.item] and round(e.free)>0 and (e.scope~="loot" or #receivers==1) then
            local target=copy(e)
            local mix=mixture(snapshot,target)
            if mix then
                if type(mix)=="table" then target.pourSignature=mix end
                targets[#targets+1]=target
            end
        end
    end
    if #targets==0 then return nil end
    local donors,refs,truncated,work={},{},snapshot.truncated,MAX_CHOICE_WORK
    for _,e in ipairs(snapshot.entries) do
        local mix=not wanted[e.item] and not refs[e.fluid] and round(e.amount)>0 and mixture(snapshot,e)
        if mix then
            local accepts={}
            for _,target in ipairs(targets) do
                work=work-1
                if Pour.legalScope(e,target,options,target.item) and Pour.compatible(e,target) then
                    local choice=copy(target)
                    choice.relation=Pour.relation(mix,choice.amount,choice.pourSignature)
                    accepts[#accepts+1]=choice
                end
            end
            if #accepts>0 then
                local donor=copy(e)
                donor.pourSignature=mix
                donors[#donors+1]={source=donor,targets=accepts}
                refs[e.fluid]=true
            end
            if #donors>=MAX_TARGETS or work<=0 then truncated=true;break end
        end
    end
    return {targets=targets,donors=donors,truncated=truncated}
end

function Pour.sortFill(fill,options)
    local weight=options.pourFillScope=="equipped-first" and {equipped=1,main=2,carried=3,loot=4}
        or {main=1,equipped=2,carried=3,loot=4}
    table.sort(fill,function(a,b)
        if a.scope~=b.scope then return weight[a.scope]<weight[b.scope] end
        if a.free~=b.free then
            if options.pourFillOrder=="largest-first" then return a.free>b.free end
            return a.free<b.free
        end
        return order(a,b)
    end)
end

-- A batch never mixes liquids and follows the player's scope and order.
function Pour.batch(entries,options)
    local fill={}
    for _,e in ipairs(entries) do
        if e.relation~="mixes" and (options.pourFillScope~="main-only" or e.scope=="main") then fill[#fill+1]=e end
    end
    Pour.sortFill(fill,options)
    return fill
end

local function plan(snapshot, sourceItem, options, budget)
    options=options or {}
    local source=Pour.source(snapshot,sourceItem)
    if not source then return nil,"The selected vessel cannot pour from here" end
    source.pourSignature=mixture(snapshot,source)
    if not source.pourSignature then return nil,"The selected vessel's mixture is unavailable." end
    local truncated=snapshot.truncated
    local targets,refs={},{[source.fluid]=true}
    for _, template in ipairs(snapshot.entries) do
        if budget then
            if budget.left<=0 then return nil,"Too many vessel combinations; select one exact vessel." end
            budget.left=budget.left-1
        end
        if not refs[template.fluid] and Pour.legalScope(source,template,options) and Pour.compatible(source,template) then
            refs[template.fluid]=true
            local signature=mixture(snapshot,template)
            if signature then
                if #targets>=MAX_TARGETS then truncated=true;break end
                local entry=copy(template)
                if type(signature)=="table" then entry.pourSignature=signature end
                entry.relation=Pour.relation(source.pourSignature,entry.amount,entry.pourSignature)
                targets[#targets+1]=entry
            end
        end
    end
    return {source=source,targets=targets,fill=truncated and {} or Pour.batch(targets,options),truncated=truncated}
end

function Pour.plan(snapshot, sourceItem, options)
    return plan(snapshot,sourceItem,options)
end

function Pour.choose(snapshot, items, options, extraTarget)
    if not snapshot or snapshot.truncated or type(items)~="table" or #items>MAX_ITEMS then
        return nil,"The full stack could not be checked; select one exact vessel."
    end
    local choices,seen={},{}
    for _,item in ipairs(items) do
        local entry=snapshot.sources[item]
        if entry and not seen[entry.id] then
            seen[entry.id]=true
            choices[#choices+1]=entry
        end
    end
    table.sort(choices,Stacks.lessFilled)
    local budget={left=MAX_CHOICE_WORK}
    for _,candidate in ipairs(choices) do
        if mixture(snapshot,candidate) then
            local chosen,why=plan(snapshot,candidate.item,options,budget)
            if not chosen then return nil,why end
            if #chosen.targets>0 or (extraTarget and extraTarget(chosen.source)) then return chosen end
        end
    end
    return nil,"No selected vessel can pour into an eligible destination."
end

-- The vessel as it is now, wherever within reach it has got to, or nil and why.
function Pour.current(player, world, entry)
    local item,holder,place=Items.find(player,entry.id,{entry.container})
    if not item or item:getFullType()~=entry.fullType then return nil,"The vessel moved or is gone" end
    holder=holder or place=="ground" and entry.container or nil
    if place=="carried" then
        local main=player:getInventory()
        local scope=holder==main and (Items.equipped(player,item) and "equipped" or "main") or "carried"
        local live=entryFor(player,item,holder,scope)
        if live then return live end
        return nil,"The vessel cannot be used now"
    end
    local ok,why=world:consumptionSource(item,holder)
    if ok~=true then return nil,why or "The vessel is out of reach" end
    local live=entryFor(player,item,holder,"loot")
    if live then return live end
    return nil,"The vessel cannot be used now"
end

function Pour.mix(entry)
    local sample=entry and call(entry.fluid,"createFluidSample")
    if not sample then return nil end
    local ok, ratios=pcall(function()
        local size=sample:size()
        if size<1 or size>128 then return nil end
        local result,nonempty={},false
        for index=0,size-1 do
            local kind,ratio=sample:getFluid(index),sample:getPercentage(index)
            if not kind or not finite(ratio) or ratio<0 or result[kind]~=nil then return nil end
            if ratio>0 then result[kind]=ratio;nonempty=true end
        end
        if nonempty then return result end
    end)
    local released=pcall(function() sample:release() end)
    if ok and released then return ratios end
end

return Pour
