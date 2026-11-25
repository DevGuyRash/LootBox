local Pour = require "LootBox/Pour"
local Inventory = require "LootBox/PourInventory"
local Stacks = require "LootBox/PourStacks"
local Rows = require "LootBox/FluidRows"
local Log = require "LootBox/Log"
local WorldMenu = require "LootBox/WorldFluidMenu"
local MountedMenu = require "LootBox/DispenserMenu"

local Menu = {}
local DROP = "Item_WaterDrop"
local RELATION = {same=1,empty=2,mixes=4}
local SCOPE = {main=1,equipped=2,carried=3,loot=4}

-- Most right-clicked items hold no liquid; find that out before anything else.
local function anyFluid(items)
    for _,row in ipairs(items or {}) do
        if instanceof(row,"InventoryItem") then
            if Inventory.hasFluid(row) then return true end
        elseif type(row)=="table" then
            for _,item in ipairs(row.items or {}) do if Inventory.hasFluid(item) then return true end end
        end
    end
    return false
end

-- A mod that already owns this top-level entry keeps it; ours joins LootBox.
local function host(ctx,title)
    if Rows.claimed(ctx.parent,title) then return ctx.branded() end
    local mods=title=="Pour Into" and getActivatedMods and getActivatedMods()
    if mods and (mods:contains("PourIntoContainer") or mods:contains("\\PourIntoContainer")) then return ctx.branded() end
    return ctx.parent
end

-- "Water Bottle (Water), 0.6 / 1 L", or "Water Bottle, 0.6 / 1 L (mixes with Water)"
local function kind(e,relation)
    local name,liquid=Inventory.vesselName(e),Inventory.liquid(e.fluid)
    if not liquid or relation=="mixes" then return name end
    return name.." ("..liquid..")"
end
local function title(e,relation,contents)
    local text=kind(e,relation)..", "..Inventory.litres(e.amount).." / "..Inventory.litres(e.capacity).." L"
    if relation=="mixes" then text=text.." (mixes with "..(contents or "other liquid")..")" end
    return text
end

local function startPour(ctx,source,targets)
    return function(id) return ctx.app:startPour(source,targets,id) end
end

-- One row per distinguishable destination; identical vessels in one place share.
local function destinations(ctx,source,targets,batchAllowed)
    local rows,same={},{}
    local function all(group)
        local entries={}
        for _,row in ipairs(group) do for _,e in ipairs(row.entries) do entries[#entries+1]=e end end
        local fill=batchAllowed and Inventory.batch(entries,ctx.options) or {}
        if #fill<2 then return nil end
        return {title="All ("..#fill..")",texture=DROP,tip="Fills these one after another until the source is empty.",
            start=startPour(ctx,source,fill)}
    end
    for _,e in ipairs(targets) do
        local name=title(e,e.relation,Inventory.liquid(e.fluid))
        local key=name.."\n"..tostring(e.place)
        local row=same[key]
        if row then row.entries[#row.entries+1]=e;row.count=row.count+1
        else
            row={title=name,kind=kind(e,e.relation),relation=e.relation,scope=e.scope,place=e.place,id=e.id,item=e.item,
                entries={e},count=1,all=all,tip="From "..source.label.." to "..e.label..".",
                start=startPour(ctx,source,{e})}
            same[key]=row
            rows[#rows+1]=row
        end
    end
    Rows.disambiguate(rows)
    for _,row in ipairs(rows) do
        local every=row.count>1 and all({row})
        if every then
            row.children={every,{title="One",item=row.item,tip=row.tip,start=row.start}}
            row.title=row.title.." ("..row.count..")"
        end
    end
    return rows
end

local function ordered(rows)
    table.sort(rows,function(a,b)
        local ra,rb=RELATION[a.relation] or 3,RELATION[b.relation] or 3
        if ra~=rb then return ra<rb end
        local sa,sb=SCOPE[a.scope] or 5,SCOPE[b.scope] or 5
        if sa~=sb then return sa<sb end
        if a.title~=b.title then return a.title<b.title end
        return (a.id or 0)<(b.id or 0)
    end)
    return rows
end

local function pourInto(ctx,plan,anchors,mounted)
    local source=plan.source
    local rows=destinations(ctx,source,plan.targets,not plan.truncated)
    for _,row in ipairs(MountedMenu.rows(ctx,mounted,source)) do rows[#rows+1]=row end
    for _,row in ipairs(WorldMenu.pourRows(ctx,anchors,source)) do rows[#rows+1]=row end
    ordered(rows)
    if #plan.fill>=2 then
        table.insert(rows,1,{title="Pour into all ("..#plan.fill..")",
            texture="media/ui/inventoryPanes/TransferSameTypeMultiContainer.png",item=source.item,
            tip="Only empty vessels and those with the same liquid, in your fill order.",
            start=startPour(ctx,source,plan.fill)})
    end
    local tip=title(source).." | "..tostring(source.place)
    if #ctx.members>1 then tip=tip..". Pours from the least filled vessel of this stack." end
    return Rows.add(ctx,host(ctx,"Pour Into"),"Pour Into",DROP,source.item,tip,rows)
end

local function fillFrom(ctx,inverse,anchors)
    local targets=inverse and inverse.targets or {}
    if #targets==0 then return false end
    local first=targets[1]
    local rows={}
    for _,donor in ipairs(inverse.donors) do
        local e=donor.source
        local row
        if #targets==1 then
            local target=donor.targets[1]
            row={title=title(e,target.relation,Inventory.liquid(target.fluid)),relation=target.relation,
                start=startPour(ctx,e,{target})}
        else
            local fill=not inverse.truncated and Inventory.batch(donor.targets,ctx.options) or {}
            if #fill>0 then
                local one={title="Fill one",item=fill[1].item,tip="Fills "..fill[1].label..".",start=startPour(ctx,e,{fill[1]})}
                row={title=title(e),relation=fill[1].relation,children={one}}
                if #fill>1 then
                    table.insert(row.children,1,{title="Fill all ("..#fill..")",texture=DROP,
                        tip="One after another until the source is empty.",start=startPour(ctx,e,fill)})
                end
            end
        end
        if row then
            row.kind,row.scope,row.place,row.id,row.item=kind(e,row.relation),e.scope,e.place,e.id,e.item
            row.tip="From "..e.label.."."
            rows[#rows+1]=row
        end
    end
    Rows.disambiguate(rows)
    local fixtures=first.scope=="loot" and WorldMenu.lootRows(ctx,anchors,first) or WorldMenu.fillRows(ctx,anchors,targets)
    for _,row in ipairs(fixtures) do rows[#rows+1]=row end
    ordered(rows)
    local tip=#targets==1 and title(first).." | "..tostring(first.place) or #targets.." selected vessels with room"
    return Rows.add(ctx,host(ctx,"Fill From"),"Fill From",DROP,first.item,tip,rows)
end

local function add(given)
    if not anyFluid(given.items) then return false end
    local index=given.playerIndex
    local members=Stacks.selection(given.items,index)
    if not members or #members==0 then return false end
    local app=given.app
    local player=getSpecificPlayer(index)
    local holder=members[1]:getContainer()
    local viewed=Pour.displayed(index,holder)
    local ctx={playerIndex=index,player=player,parent=given.parent,branded=given.branded,app=app,tooltip=given.tooltip,
        interaction=given.interaction,origin="menu.item",options=Pour.options(given.preferences),members=members,click={},
        snapshot=Inventory.snapshot(player,app.world,holder,viewed)}
    local anchors=WorldMenu.fixtures(player)
    local mounted
    local function mountedTargets(e)
        mounted=mounted or MountedMenu.nearby(index,app)
        return MountedMenu.targets(mounted,e,app.world)
    end

    local inverse=Inventory.fillFrom(ctx.snapshot,members,ctx.options)

    -- A collapsed row delegates the choice; an expanded individual never does.
    local plan,why
    if #members==1 then plan,why=Inventory.plan(ctx.snapshot,members[1],ctx.options)
    else
        plan,why=Inventory.choose(ctx.snapshot,members,ctx.options,function(e)
            return #WorldMenu.pourRows(ctx,anchors,e)>0 or #mountedTargets(e)>0
        end)
    end
    -- Both go directly after the game's Fluid entry, so the last one is first.
    local filled=fillFrom(ctx,inverse,anchors)
    local poured=plan and pourInto(ctx,plan,anchors,mountedTargets(plan.source)) or false
    Log.trace(nil,"MENU","menu","fluid","vessel",Log.item(members[1],player),"selected",#members,"vessels",#ctx.snapshot.entries,
        "truncated",ctx.snapshot.truncated,"fixtures",#anchors,"pourInto",poured,"why",not poured and why or nil,
        "targets",plan and #plan.targets or 0,"fillFrom",filled,"donors",inverse and #inverse.donors or 0)
    return filled or poured
end

function Menu.add(ctx) return Log.guard("PourMenu.add",add,ctx)==true end

return Menu
