-- Nearby fixtures as choices inside an item's own Pour Into and Fill From. The
-- game's world menu already fills from and adds liquid to a clicked fixture.
local W=require "LootBox/WorldFluids"
local Inventory=require "LootBox/PourInventory"
local Menu={}

function Menu.fixtures(player) return player and getCell and W.objects(player) or {} end

local function title(a,relation,contents)
    local text=a.label
    local liquid=W.liquid(a)
    if relation=="mixes" and contents then liquid=nil end
    if liquid then text=text.." ("..liquid..")" end
    if not a.unlimited then text=text..", "..Inventory.litres(a.amount).." / "..Inventory.litres(a.capacity).." L" end
    if relation=="mixes" then text=text.." (mixes with "..(contents or "other liquid")..")" end
    return text
end
local function tip(a,text)
    return (a.unlimited and getText("Tooltip_WaterUnlimited") or string.format("%.2f / %.2f L",a.amount,a.capacity))..". "..text
end

local function start(ctx,a,take,entries)
    return function(id)
        a.interaction=id
        return ctx.app:worldPour(a,take,entries,id)
    end
end

-- Fill carried vessels from a fixture: one, or all that it would not mix.
function Menu.fillRows(ctx,anchors,entries)
    local rows={}
    for _,a in ipairs(anchors) do
        local ready,recipe={},W.recipe(a)
        for _,e in ipairs(entries) do
            if W.permits(ctx.player,ctx.app.world,a,e,true) and W.signature(e) then
                e.relation=W.relation(recipe,e)
                ready[#ready+1]=e
            end
        end
        local batch=#entries>1 and not ctx.snapshot.truncated and Inventory.batch(ready,ctx.options) or {}
        if #ready==1 then
            local e=ready[1]
            rows[#rows+1]={title=title(a,e.relation,Inventory.liquid(e.fluid)),relation=e.relation,texture="Item_WaterDrop",
                tip=tip(a,"Fills "..Inventory.vesselName(e)..", "..Inventory.litres(e.free).." L of room."),start=start(ctx,a,true,{e})}
        elseif #batch>0 and #batch<=512 then
            local one=batch[1]
            local children={{title="Fill one",item=one.item,tip=tip(a,"Fills "..Inventory.vesselName(one).."."),
                start=start(ctx,a,true,{one})}}
            if #batch>1 then
                table.insert(children,1,{title="Fill all ("..#batch..")",texture="Item_WaterDrop",
                    tip=tip(a,"One confirmed fill at a time, in your fill order."),start=start(ctx,a,true,batch)})
            end
            rows[#rows+1]={title=title(a),relation=one.relation,texture="Item_WaterDrop",children=children}
        end
    end
    return rows
end

-- Fill one clicked loot vessel: it is fetched, filled and put back.
function Menu.lootRows(ctx,anchors,target)
    local rows={}
    if ctx.app.world:protected(target.item)~=false or target.item:isFavorite() then return rows end
    for _,a in ipairs(anchors) do
        local source=W.recipe(a)
        if source and W.canReceive(ctx.player,a,target) then
            local relation=W.relation(source,target)
            rows[#rows+1]={title=title(a,relation,Inventory.liquid(target.fluid)),relation=relation,texture="Item_WaterDrop",
                tip=tip(a,"Takes the vessel, fills it here and puts it back where it was."),start=start(ctx,a,true,{target})}
        end
    end
    return rows
end

function Menu.pourRows(ctx,anchors,source)
    local rows={}
    for _,a in ipairs(anchors) do
        if W.permits(ctx.player,ctx.app.world,a,source,false) then
            local into=a.amount>0 and W.recipe(a)
            local relation=a.amount==0 and "empty" or into and Inventory.sameLiquid(source.pourSignature,into.mix) and "same" or "mixes"
            rows[#rows+1]={title=title(a,relation,W.liquid(a)),relation=relation,texture="Item_WaterDrop",
                tip=tip(a,"Pours this vessel into it; your hands stay as they are."),start=start(ctx,a,false,{source})}
        end
    end
    return rows
end

return Menu
