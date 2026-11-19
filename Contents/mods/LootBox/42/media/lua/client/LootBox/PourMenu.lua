local Pour = require "LootBox/Pour"
local Inventory = require "LootBox/PourInventory"
local Stacks = require "LootBox/PourStacks"

local Menu = {}
local marker = {}

local function hasFluid(item)
    if not item or not item.getFluidContainer then return false end
    if item:getFluidContainer() then return true end
    local ground=item.getWorldItem and item:getWorldItem()
    return ground and ground:getFluidContainer() ~= nil
end

local function already(menu)
    for _,o in ipairs(menu.options or {}) do
        -- The native pool clears/reassigns target even when reusing an option.
        if o.name=="Pour Into" and o.target==marker then return true end
    end
    return false
end

local function otherPourMenu(parent)
    for _,o in ipairs(parent.options or {}) do
        if o.name=="Pour Into" and o.target~=marker then return true end
    end
    local mods=getActivatedMods and getActivatedMods()
    return mods and (mods:contains("PourIntoContainer") or mods:contains("\\PourIntoContainer"))
end

local function builtinIcon(option, key, fallback)
    if not option then return end
    option.iconTexture=getTexture(key)
    option.itemForTexture=not option.iconTexture and fallback or nil
end

local function run(pick)
    if pick.click.used then return nil,"Reopen the inventory menu to start another pour." end
    pick.click.used=true
    local app,err=pick.app.get(pick.index)
    local ok
    if app==pick.instance then ok,err=app:startPour(pick.source,pick.targets,pick.prefs) end
    if not ok then
        local reason="Pour Into: "..tostring(err or "The selected vessels are no longer available.")
        local p=getSpecificPlayer(pick.index)
        if p and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(p,reason)
        else print("[LootBox] "..reason) end
    end
    return ok,err
end

-- Do not change stock Fluid or replace callbacks installed by another mod.
-- When migrating with the legacy provider enabled, put ours under LootBox.
function Menu.add(index,parent,branded,items,instance,prefs,tooltip)
    if already(parent) or already(branded) then return end
    if #items==1 and instanceof(items[1],"InventoryItem") and not hasFluid(items[1]) then return end
    local members=Stacks.selection(items,index)
    if not members or #members==0 then return end
    local anyFluid
    for _,member in ipairs(members) do if hasFluid(member) then anyFluid=true;break end end
    if not anyFluid then return end
    local options=Pour.options(prefs)
    local snapshot=Inventory.snapshot(getSpecificPlayer(index),instance.world,members[1]:getContainer(),Pour.displayed(index))
    -- A collapsed row delegates the choice; an expanded individual never does.
    local plan
    if #members==1 then plan=Inventory.plan(snapshot,members[1],options,true)
    else plan=Inventory.choose(snapshot,members,options) end
    if not plan or #plan.targets==0 then return end
    local item=plan.source.item
    if plan.source.scope=="loot" and plan.source.container:getType()~="floor" then
        plan.source.pourAnchor=instance.world:pourShelfAnchor(plan.source.container)
        if not plan.source.pourAnchor then return end
    end
    local targets,fill=plan.targets,plan.fill

    local host=otherPourMenu(parent) and branded or parent
    local root=host:addOption("Pour Into",marker,nil)
    if not root then return end
    builtinIcon(root,"Item_WaterDrop",item) -- stock ISFluidContainerMenu icon
    local source=string.format("%s | %.3f L available",plan.source.label,plan.source.amount)
    if #members>1 then
        local ok,fluidName=pcall(function() return plan.source.fluid:getUiName() end)
        if ok and type(fluidName)=="string" and fluidName~="" then source=source.." | "..fluidName end
        source=source..string.format(" (%.1f%% full; least-filled eligible vessel in this stack)",
            100*plan.source.amount/plan.source.capacity)
    end
    tooltip(root,"Pour Into",source)
    local child=ISContextMenu:getNew(host)
    host:addSubMenu(root,child)

    local app,click=require "LootBox/App",{}
    local function choice(title,list)
        return child:addOption(title,{app=app,click=click,index=index,instance=instance,source=plan.source,
            targets=list,prefs=options},run)
    end
    if #fill>0 then
        local batch=choice("Fill All",fill)
        builtinIcon(batch,"media/ui/inventoryPanes/TransferSameTypeMultiContainer.png",item)
        local groups=options.pourFillScope=="main-only" and "main inventory only" or
            options.pourFillScope=="equipped-first" and "equipped first" or "main inventory first"
        tooltip(batch,"Fill All",string.format("%s. %d destination(s), %s; %s room left first within each group.",
            source,#fill,groups,options.pourFillOrder=="largest-first" and "most" or "least"))
    end
    -- A direct choice from one native destination stack binds one exact
    -- vessel. The independent Fill All callback above still owns the full list.
    for _,group in ipairs(Stacks.targets({targets=targets},index)) do
        local e=group.entry
        local title=e.label
        if group.count>1 then title=title.." ("..group.count.." stacked)" end
        local row=choice(title,{e})
        if row then
            row.iconTexture,row.itemForTexture=nil,e.item
            local detail=group.count>1 and " Uses the least-filled compatible vessel in this stack." or ""
            tooltip(row,"Pour Into",source..". Destination: "..e.label.."."..detail.." Starts one native pour.")
        end
    end
    return true
end

return Menu
