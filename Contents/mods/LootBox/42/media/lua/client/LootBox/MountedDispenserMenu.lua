local Feature=require "LootBox/MountedDispenser"
local Inventory=require "LootBox/PourInventory"
local Rows=require "LootBox/FluidRows"
local Log=require "LootBox/Log"
local Menu={}
local TANK="Item_WaterTank"

local function litres(amount,capacity) return Inventory.litres(amount).." / "..Inventory.litres(capacity).." L" end
local function contents(reading) return reading.amount>0 and Inventory.liquid(reading.fluid) or nil end
local function relation(source,bottle)
    return Inventory.relation(source.pourSignature,bottle.state.amount,bottle.state.mix)
end

local function captureChoices(index,app)
    local p=getSpecificPlayer(index)
    if not p or not getCell or not p.getCurrentSquare or isClient() and not Feature.mountedMPEnabled() then return {} end
    local here,cell=p:getCurrentSquare(),getCell()
    if not here or not cell then return {} end
    local result={}
    for dx=-1,1 do for dy=-1,1 do
        local square=cell:getGridSquare(here:getX()+dx,here:getY()+dy,here:getZ())
        if square then
            local objects=square:getObjects()
            if objects:size()<=128 then
                local selected={}
                for i=0,objects:size()-1 do selected[#selected+1]=objects:get(i) end
                local anchor=Feature.capture(p,selected)
                if anchor and anchor.kind=="mounted" then
                    local bottle=Feature.destinations(p,app.world,anchor)[1]
                    if bottle then result[#result+1]={anchor=anchor,bottle=bottle} end
                end
            end
        end
    end end
    return result
end
function Menu.nearby(index,app) return Log.guard("MountedDispenserMenu.nearby",captureChoices,index,app) or {} end
function Menu.targets(choices,source,world)
    local result={}
    if source and source.scope~="loot" and source.pourSignature and not Inventory.reserved(world,source.item) then
        for _,choice in ipairs(choices) do
            if Log.guard("MountedDispenser.canFill",Feature.canFill,source,choice.bottle) then result[#result+1]=choice end
        end
    end
    return result
end

local function start(ctx,anchor,donor,bottle,origin)
    return function(id)
        anchor.interaction=id
        return ctx.app:refillDispenser(anchor,donor,bottle,origin)
    end
end

-- Mounted dispensers beside the player, as choices in an item's Pour Into.
function Menu.rows(ctx,choices,source)
    local rows={}
    for _,choice in ipairs(choices) do
        local bottle=choice.bottle
        local how,liquid=relation(source,bottle),contents(bottle.state)
        local title="Water Dispenser"
        if liquid and how~="mixes" then title=title.." ("..liquid..")" end
        title=title..", "..litres(bottle.state.amount,bottle.state.cap)
        if how=="mixes" then title=title.." (mixes with "..(liquid or "other liquid")..")" end
        rows[#rows+1]={title=title,relation=how,texture=TANK,
            tip="Takes the bottle off the stand, pours this vessel into it and fits it again.",
            start=start(ctx,choice.anchor,source,bottle,"inventoryShortcuts")}
    end
    return rows
end

-- What one bottle can be filled from: every source of one liquid at once, or one.
local function donorRows(ctx,anchor,bottle,donors,truncated)
    local rows,liquids={},{}
    for _,e in ipairs(donors) do
        local how=relation(e,bottle)
        local liquid=Inventory.liquid(e.fluid)
        local title=Inventory.vesselName(e)
        if liquid then title=title.." ("..liquid..")" end
        title=title..", "..litres(e.amount,e.capacity)
        if how=="mixes" then title=title.." (mixes with "..(contents(bottle.state) or "other liquid")..")" end
        rows[#rows+1]={title=title,kind=Inventory.vesselName(e)..(liquid and " ("..liquid..")" or ""),place=e.place,item=e.item,
            tip="From "..e.label..". Takes the bottle, pours and fits the same bottle again.",
            start=start(ctx,anchor,e,bottle,"worldShortcuts")}
        if how~="mixes" and not truncated then
            local group
            for _,known in ipairs(liquids) do if Inventory.sameLiquid(known.mix,e.pourSignature) then group=known;break end end
            if not group then group={mix=e.pourSignature,name=liquid or "liquid",sources={}};liquids[#liquids+1]=group end
            if #group.sources<Feature.MAX_DONORS then group.sources[#group.sources+1]=e end
        end
    end
    Rows.disambiguate(rows)
    for index=#liquids,1,-1 do
        local group=liquids[index]
        if #group.sources>1 and anchor.kind=="mounted" then
            table.insert(rows,1,{title="Fill from all "..group.name.." ("..#group.sources..")",texture=TANK,
                tip="Takes the bottle once and pours these in order until it is full, then fits it again.",
                start=start(ctx,anchor,group.sources,bottle,"worldShortcuts")})
        end
    end
    return rows
end

local function add(given)
    local player=getSpecificPlayer(given.playerIndex)
    local anchor=player and Feature.capture(player,given.objects or {})
    if not anchor or anchor.kind=="mounted" and isClient() and not Feature.mountedMPEnabled() then return false end
    local app=given.app
    local ctx={playerIndex=given.playerIndex,app=app,tooltip=given.tooltip,interaction=given.interaction,origin="menu.world",click={}}
    local snapshot=Inventory.snapshot(player,app.world,nil,nil)
    local bottles=Feature.destinations(player,app.world,anchor,snapshot)
    local rows,total={},0
    for _,bottle in ipairs(bottles) do
        local donors,truncated={},snapshot.truncated
        for _,entry in ipairs(snapshot.entries) do
            if not Inventory.reserved(app.world,entry.item) and Feature.canFill(entry,bottle) then
                entry.pourSignature=entry.pourSignature or Inventory.mix(entry)
                if entry.pourSignature then
                    if total>=128 then truncated=true;break end
                    donors[#donors+1]=entry
                    total=total+1
                end
            end
        end
        if #donors>0 then
            local choices=donorRows(ctx,anchor,bottle,donors,truncated)
            if anchor.kind=="mounted" then rows=choices
            else
                rows[#rows+1]={title=Inventory.vesselName({item=bottle.item,fluid=bottle.state.fluid,amount=bottle.state.amount})
                    ..", "..litres(bottle.state.amount,bottle.state.cap),item=bottle.item,children=choices}
            end
        end
    end
    local title=anchor.kind=="bare" and "Refill and fit a bottle" or "Refill dispenser"
    local tip="Choose the bottle, then what to fill it from."
    if anchor.kind=="mounted" then
        local state=bottles[1] and bottles[1].state
        tip=state and ((contents(state) or "Empty")..", "..litres(state.amount,state.cap)) or nil
    end
    local added=Rows.add(ctx,given.parent,title,TANK,nil,tip,rows)
    Log.trace(nil,"MENU","menu","dispenser","stand",anchor.kind,"square",Log.point(anchor.square),"bottles",#bottles,
        "sources",total,"added",added)
    return added
end
function Menu.add(ctx) return Log.guard("MountedDispenserMenu.add",add,ctx)==true end
return Menu
