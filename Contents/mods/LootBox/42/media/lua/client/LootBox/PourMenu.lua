local Pour = require "LootBox/Pour"
local Inventory = require "LootBox/PourInventory"

local Menu = {}
local marker = {}

local function onlySource(items)
    -- getActualItems unwraps collapsed group rows (whose first item is a
    -- display representative). Never guess the first physical item in a stack.
    if not ISInventoryPane or not ISInventoryPane.getActualItems then return nil end
    local found
    for _,item in ipairs(ISInventoryPane.getActualItems(items) or {}) do
        if not instanceof(item,"InventoryItem") or found and item~=found then return nil end
        found=item
    end
    if not found or not found.getFluidContainer then return nil end
    local component=found:getFluidContainer()
    if not component and found.getWorldItem then
        local ground=found:getWorldItem()
        component=ground and ground:getFluidContainer()
    end
    return component and found or nil
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
    local item=onlySource(items)
    if not item then return end
    local options=Pour.options(prefs)
    local plan=Inventory.collect(getSpecificPlayer(index),instance.world,item,Pour.displayed(index),options)
    if not plan or #plan.targets==0 or not Pour.capture(plan.source) then return end
    if plan.source.scope=="loot" and plan.source.container:getType()~="floor" then
        plan.source.pourAnchor=instance.world:pourShelfAnchor(plan.source.container)
        if not plan.source.pourAnchor then return end
    end
    local targets, fill, admitted={},{},{}
    for _,e in ipairs(plan.targets) do
        if Pour.capture(e) then targets[#targets+1]=e;admitted[e]=true end
    end
    if #targets==0 then return end
    for _,e in ipairs(plan.fill) do if admitted[e] then fill[#fill+1]=e end end

    local host=otherPourMenu(parent) and branded or parent
    local root=host:addOption("Pour Into",marker,nil)
    if not root then return end
    builtinIcon(root,"Item_WaterDrop",item) -- stock ISFluidContainerMenu icon
    local source=string.format("%s | %.3f L available",plan.source.label,plan.source.amount)
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
    for _,e in ipairs(targets) do
        local row=choice(e.label,{e})
        if row then
            row.iconTexture,row.itemForTexture=nil,e.item -- native inventory icon, including modded vessels
            tooltip(row,"Pour Into",source..". Destination: "..e.label..". Starts one native pour.")
        end
    end
    return true
end

return Menu
