local Pour = require "LootBox/Pour"
local Inventory = require "LootBox/PourInventory"
local Stacks = require "LootBox/PourStacks"

local WorldMenu = require "LootBox/WorldFluidMenu"

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
        if type(o.name)=="string" and o.target~=marker then
            local name=o.name:lower():gsub("[%s%.]+$","")
            if name=="pour into" then return true end
        end
    end
    local mods=getActivatedMods and getActivatedMods()
    return mods and (mods:contains("PourIntoContainer") or mods:contains("\\PourIntoContainer"))
end

local function builtinIcon(option, key, fallback)
    if not option then return end
    option.iconTexture=getTexture(key)
    option.itemForTexture=not option.iconTexture and fallback or nil
end

local function entrances(parent,branded,render)
    if not otherPourMenu(parent) then render(parent) end
    render(branded)
end

local function unavailable(parent,branded,item,tooltip,reason)
    entrances(parent,branded,function(host)
        local root=host:addOption("Pour Into",marker,nil)
        if not root then return end
        root.notAvailable=true
        builtinIcon(root,"Item_WaterDrop",item)
        tooltip(root,"Pour Into",reason)
    end)
    return true
end

local function liters(amount)
    -- Preserve native three-decimal precision; a whole number still reads as 1.0L.
    return (string.format("%.3f",amount):gsub("0+$",""):gsub("%.$",".0"))
end

local function destinationText(entry)
    local percent=math.floor(math.min(1,entry.amount/entry.capacity)*100+0.5)
    return string.format("%d%% | %sL / %sL",percent,liters(entry.amount),liters(entry.capacity))
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
    local holder=members[1]:getContainer()
    local viewed=Pour.displayed(index,holder)
    local snapshot=Inventory.snapshot(getSpecificPlayer(index),instance.world,holder,viewed)
    -- Empty carried vessels still need Fill From even when they cannot pour.
    local worldOK,world=pcall(WorldMenu.inventory,index,parent,branded,members,snapshot,instance,options,tooltip)
    if not worldOK then world=nil end
    -- A collapsed row delegates the choice; an expanded individual never does.
    local plan,reason
    if #members==1 then plan,reason=Inventory.plan(snapshot,members[1],options,true)
    else plan,reason=Inventory.choose(snapshot,members,options,function(e) return #WorldMenu.destinations(world,e)>0 end) end
    if not plan then
        -- For an exact non-empty loot row explain a source failure rather than
        -- leaving an ambiguous invisible shortcut. Never authorize the row.
        if #members==1 and viewed and holder==viewed then
            local candidate=members[1]
            local ok,hasContents=pcall(function()
                local fluid=candidate:getFluidContainer()
                if not fluid then
                    local world=candidate:getWorldItem()
                    fluid=world and world:getFluidContainer()
                end
                return fluid and fluid:getAmount()>0
            end)
            if ok and hasContents then
                return unavailable(parent,branded,candidate,tooltip,reason or "That vessel cannot pour from here.")
            end
        end
        return
    end
    local item=plan.source.item
    if plan.source.scope=="loot" and plan.source.container:getType()~="floor" then
        plan.source.pourAnchor=instance.world:pourShelfAnchor(plan.source.container)
        if not plan.source.pourAnchor then
            return unavailable(parent,branded,item,tooltip,"The selected storage is out of reach or cannot return this vessel. Move closer or carry the source.")
        end
    end
    local targets,fill=plan.targets,plan.fill
    local fixtures=WorldMenu.destinations(world,plan.source)

    local source=string.format("%s | %.3f L available",plan.source.label,plan.source.amount)
    if #members>1 then
        local ok,fluidName=pcall(function() return plan.source.fluid:getUiName() end)
        if ok and type(fluidName)=="string" and fluidName~="" then source=source.." | "..fluidName end
        source=source..string.format(" (%.1f%% full; least-filled eligible vessel in this stack)",
            100*plan.source.amount/plan.source.capacity)
    end
    local app,click=require "LootBox/App",{}
    local groups=Stacks.targets({targets=targets},index)
    local function render(host)
        local root=host:addOption("Pour Into",marker,nil)
        if not root then return end
        builtinIcon(root,"Item_WaterDrop",item)
        if #targets==0 and #fixtures==0 then
            root.notAvailable=true
            local help="No compatible destination with space. Carry an empty or compatible vessel."
            if plan.source.scope=="loot" and not options.pourLootToLoot then
                help=help.." Enable loot-to-loot in LootBox settings to use targets in this same loot pane."
            end
            tooltip(root,"Pour Into",source..". "..help)
            return
        end
        tooltip(root,"Pour Into",source)
        local child=ISContextMenu:getNew(host)
        host:addSubMenu(root,child)
        local function choice(title,list)
            return child:addOption(title,{app=app,click=click,index=index,instance=instance,source=plan.source,
                targets=list,prefs=options},run)
        end
        if #fill>0 then
            local batch=choice("Fill All",fill)
            builtinIcon(batch,"media/ui/inventoryPanes/TransferSameTypeMultiContainer.png",item)
            local order=options.pourFillScope=="main-only" and "main inventory only" or
                options.pourFillScope=="equipped-first" and "equipped first" or "main inventory first"
            tooltip(batch,"Fill All",string.format("%s. %d destination(s), %s; %s room left first within each group.",
                source,#fill,order,options.pourFillOrder=="largest-first" and "most" or "least"))
        end
        WorldMenu.addTargets(child,world,fixtures,plan.source,click)
        -- A direct stack entry binds one exact vessel; Fill All uses the whole list.
        for _,group in ipairs(groups) do
            local e=group.entry
            local row=choice(destinationText(e),{e})
            if row then
                row.iconTexture,row.itemForTexture=nil,e.item
                local detail=group.count>1 and (" Uses the least-filled of "..group.count.." compatible vessels in this stack.") or ""
                tooltip(row,"Pour Into",source..". Destination: "..e.label.."."..detail.." Starts one native pour.")
            end
        end
    end
    -- The two entrances share the same frozen plan and one dispatch latch.
    -- Never replace a different mod's top-level action.
    entrances(parent,branded,render)
    return true
end

return Menu
