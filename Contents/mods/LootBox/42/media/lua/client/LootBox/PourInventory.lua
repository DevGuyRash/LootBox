local Pour = {}
local MAX_ITEMS, MAX_CONTAINERS, MAX_DEPTH = 4096, 48, 1
local MAX_TARGETS = 512

local function call(object, method, arg, second)
    if not object then return nil end
    local ok, value = pcall(function()
        local fn = object[method]
        if not fn then return nil end
        if arg == nil then return fn(object) end
        if second ~= nil then return fn(object,arg,second) end
        return fn(object, arg)
    end)
    if ok then return value end
end

local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function count(list)
    local n = call(list, "size")
    return finite(n) and math.max(0, math.floor(n)) or nil
end

local function equipped(player, item)
    return item == call(player, "getPrimaryHandItem") or item == call(player, "getSecondaryHandItem")
        or call(player, "isEquippedClothing", item) == true or call(player, "isAttachedItem", item) == true
        or call(call(player, "getWornItems"), "contains", item) == true
        or call(call(player, "getAttachedItems"), "contains", item) == true
end

local function itemName(item)
    local name = call(item, "getName")
    return type(name) == "string" and name ~= "" and name or "Container"
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
    local object = item
    if not finite(id) or call(item, "isSealed") ~= false then return nil end
    local fluid=call(item,"getFluidContainer")
    if call(container, "getType") == "floor" then
        -- Stock input resolution is item-first. Item-owned fluid cannot be
        -- operated on while on the Floor, and this route never picks it up.
        local floorObject=call(item,"getWorldItem")
        if fluid then return nil end
        local component=call(floorObject,"getFluidContainer")
        if not component or call(floorObject,"getItem")~=item or not adjacentFloor(player,floorObject) then return nil end
        object,fluid=floorObject,component
    end
    if not fluid or call(fluid, "getOwner") ~= object or call(fluid, "canPlayerEmpty") ~= true then return nil end
    local capacity, amount, free = call(fluid, "getCapacity"), call(fluid, "getAmount"), call(fluid, "getFreeCapacity")
    if not finite(capacity) or capacity <= 0 or not finite(amount) or amount < 0 or not finite(free) or free < 0 then return nil end
    local where=path or (scope=="main" and "Main inventory" or scope=="equipped" and "Equipped" or "Displayed loot")
    local label=itemName(item) .. " | " .. where
    return {id=id, fullType=fullType, item=item, object=object, container=container, scope=scope, fluid=fluid,
        capacity=capacity, amount=amount, free=free, label=label, icon=call(item, "getTex")}
end

local function round(n)
    if not FluidUtil or not FluidUtil.roundTransfer then return 0 end
    local ok, value = pcall(FluidUtil.roundTransfer, n)
    return ok and finite(value) and value or 0
end

function Pour.compatible(source, target)
    if not source or not target or source.item == target.item or source.id == target.id
        or source.fluid == target.fluid or (source.object ~= source.item and target.object ~= target.item)
        or round(math.min(source.amount, target.free)) <= 0
        or not FluidContainer or not FluidContainer.CanTransfer then return false end
    local ok, allowed = pcall(FluidContainer.CanTransfer, source.fluid, target.fluid)
    return ok and allowed == true
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
                    local gear = container == main and equipped(player,item)
                    local id = call(item, "getID")
                    if finite(id) then
                        if ids[id] then ambiguous[id]=true end
                        ids[id]=true
                    end
                    local entry = entryFor(player,item,container,scope or (gear and "equipped" or "main"),current.path)
                    if entry and (scope~="loot" or (world and (call(container,"getType")=="floor"
                        or (call(item,"isFavorite")~=true and call(world,"protected",item)~=true))
                        and call(world,"consumptionSource",item,container)==true)) then
                        result[#result+1]=entry
                    end
                    if gear and current.depth < MAX_DEPTH then
                        local bag=call(item,"getInventory")
                        if bag and not containers[bag] and call(bag,"getContainingItem") == item then
                            if #todo<MAX_CONTAINERS then
                                todo[#todo+1]={container=bag, scope="equipped", depth=current.depth+1, path=itemName(item)}
                            else truncated=true end
                        end
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
local function get(entries, item)
    for _, e in ipairs(entries) do if e.item == item then return e end end
end

local function legalScope(source, target, options)
    return target.scope ~= "loot" or source.scope == "loot" and source.container == target.container
        and options.pourLootToLoot == true
end

function Pour.collect(player, world, sourceItem, lootPane, options)
    options=options or {}
    local entries,truncated=scan(player,world,lootPane,call(sourceItem,"getContainer")==lootPane)
    local source=get(entries,sourceItem)
    if not source or round(source.amount)<=0 then return nil,"The selected vessel cannot pour from here" end
    local targets,fill,names,refs={},{},{},{[source.fluid]=true}
    table.sort(entries,order)
    for _, entry in ipairs(entries) do
        if not refs[entry.fluid] and legalScope(source,entry,options) and Pour.compatible(source,entry) then
            refs[entry.fluid]=true
            if #targets>=MAX_TARGETS then truncated=true;break end
            targets[#targets+1]=entry
            names[entry.label]=(names[entry.label] or 0)+1
            if options.pourFillScope ~= "main-only" or entry.scope=="main" then fill[#fill+1]=entry end
        end
    end
    local indices={}
    for _, entry in ipairs(targets) do
        if names[entry.label]>1 then
            local label=entry.label
            indices[label]=(indices[label] or 0)+1
            entry.label=label.." #"..indices[label]
        end
        local free=string.format("%.3f",entry.free):gsub("0+$",""):gsub("%.$","")
        entry.label=entry.label.." | "..free.." L free"
    end
    local weight=options.pourFillScope=="equipped-first" and {equipped=1,main=2,loot=3}
        or {main=1,equipped=2,loot=3}
    table.sort(fill,function(a,b)
        if a.scope~=b.scope then return weight[a.scope]<weight[b.scope] end
        if a.free~=b.free then
            if options.pourFillOrder=="largest-first" then return a.free>b.free end
            return a.free<b.free
        end
        return order(a,b)
    end)
    return {source=source,targets=targets,fill=truncated and {} or fill,truncated=truncated}
end

local function member(container, item)
    local list = call(container,"getItems")
    local result = call(list,"contains",item)
    if type(result)=="boolean" then return result end
    for index=0,math.min(count(list) or 0,MAX_ITEMS)-1 do if call(list,"get",index)==item then return true end end
    return false
end

function Pour.accessible(player, world, entry, lootPane, allowFluidRefresh)
    if not entry or call(entry.item,"getContainer")~=entry.container then return false end
    local main, container, child=call(player,"getInventory"), entry.container, entry.item
    if not main or not member(container, child) then return false end
    local scope
    if entry.scope=="loot" then
        if container~=lootPane or not world or world:consumptionSource(child,container)~=true
            or call(container,"isLockedToCharacter",player)~=false then return false end
        scope="loot"
    else
        local seen={}
        for depth=0,MAX_DEPTH do
            if not container or seen[container] or call(container,"isLockedToCharacter",player)~=false then return false end
            if container==main then
                local gear=equipped(player,child)
                if depth>0 and not gear then return false end
                scope=gear and "equipped" or "main"
                break
            end
            seen[container]=true
            child=call(container,"getContainingItem")
            if not child or call(child,"getInventory")~=container then return false end
            container=call(child,"getContainer")
            if not member(container,child) then return false end
        end
    end
    if scope~=entry.scope then return false end
    local live=entryFor(player,entry.item,entry.container,scope)
    if not live or live.id~=entry.id or live.fullType~=entry.fullType or (not allowFluidRefresh and live.fluid~=entry.fluid) or live.object~=entry.object then return false end
    return true,live
end

function Pour.stillHere(player, world, entry, lootPane, options)
    local ok=Pour.accessible(player,world,entry,lootPane)
    return ok == true
end

function Pour.rebind(player, world, entry, returnedItem, holder, lootPane)
    local main=call(player,"getInventory")
    if not entry or not returnedItem or not holder or entry.object~=entry.item
        or (holder~=main and (entry.scope~="loot" or holder~=entry.container or holder~=lootPane))
        or call(returnedItem,"getContainer")~=holder or not member(holder,returnedItem) then return nil end
    local fresh=entryFor(player,returnedItem,holder,holder==main and "main" or "loot")
    if not fresh or fresh.id~=entry.id or type(fresh.fullType)~="string"
        or fresh.fullType~=entry.fullType or fresh.object~=returnedItem then return nil end
    local ok=Pour.accessible(player,world,fresh,lootPane)
    if ok then return fresh end
end

function Pour.mix(entry)
    local sample=entry and call(entry.fluid,"createFluidSample")
    if not sample then return nil end
    local ok, ratios=pcall(function()
        local size=sample:size()
        if size<1 or size>128 then return nil end
        local result={}
        for index=0,size-1 do
            local kind,ratio=sample:getFluid(index),sample:getPercentage(index)
            if not kind or not finite(ratio) or ratio<0 or result[kind]~=nil then return nil end
            if ratio>0 then result[kind]=ratio end
        end
        if next(result) then return result end
    end)
    local released=pcall(function() sample:release() end)
    if ok and released then return ratios end
end

function Pour.sameMix(entry, original)
    local current=type(original)=="table" and Pour.mix(entry)
    if not current then return false end
    for fluid,ratio in pairs(original) do
        if not current[fluid] or math.abs(ratio-current[fluid])>.00001 then return false end
    end
    for fluid in pairs(current) do if not original[fluid] then return false end end
    return true
end

function Pour.revalidate(player, world, entry, lootPane, options, sourceEntry)
    local admitted,live=Pour.accessible(player,world,entry,lootPane)
    if not admitted then return false end
    if sourceEntry then
        local sourceAllowed,source=Pour.accessible(player,world,sourceEntry,lootPane)
        if not sourceAllowed or not legalScope(source,live,options or {}) or not Pour.compatible(source,live) then
            return false
        end
    elseif round(live.amount)<=0 then return false end
    return true,live
end

return Pour
