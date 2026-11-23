local Pour = require "LootBox/Pour"
local Inventory = require "LootBox/PourInventory"
local Stacks = require "LootBox/PourStacks"

local WorldMenu = require "LootBox/WorldFluidMenu"
local MountedMenu = require "LootBox/MountedDispenserMenu"

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
        if o.target==marker and (o.name=="Pour Into" or o.name=="Fill From") then return true end
    end
    return false
end

local function otherTitle(parent,title)
    for _,o in ipairs(parent.options or {}) do
        if type(o.name)=="string" and o.target~=marker then
            local name=o.name:lower():gsub("[%s%.]+$","")
            if name==title then return true end
        end
    end
end

local function otherPourMenu(parent)
    if otherTitle(parent,"pour into") then return true end
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
    if app==pick.instance then
        local options={}
        for k,v in pairs(pick.prefs) do options[k]=v end
        options.pourRoute=pick.route
        ok,err=app:startPour(pick.source,pick.targets,options,pick.receiver)
    end
    if not ok then
        local reason=(pick.receiver and "Fill From: " or "Pour Into: ")..tostring(err or "The selected vessels are no longer available.")
        local p=getSpecificPlayer(pick.index)
        if p and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(p,reason)
        else print("[LootBox] "..reason) end
    end
    return ok,err
end

local function fillFrom(host,plan,index,instance,options,app,click,tooltip,world)
    if otherTitle(host,"fill from") then return end
    local dst=plan.target
    local root=host:addOption("Fill From",marker,nil)
    if not root then return end
    builtinIcon(root,"Item_WaterDrop",dst.item)
    if #plan.donors==0 and #plan.fixtures==0 then
        root.notAvailable=true
        local help="No compatible source with liquid. Carry a donor or stand beside a usable fixture, then reopen this menu."
        if not options.pourLootToLoot then help=help.." Enable loot-to-loot to use another vessel in this same loot container." end
        tooltip(root,"Fill From",help)
        return
    end
    local help="Fill "..dst.label.." ("..destinationText(dst)..") from one exact source."
    if plan.truncated then help=help.." Inventory scan limit reached; only verified individual sources are shown." end
    tooltip(root,"Fill From",help)
    local child=ISContextMenu:getNew(host)
    host:addSubMenu(root,child)
    WorldMenu.addLootSources(child,world,plan.fixtures,dst)
    local counts={}
    for _,e in ipairs(plan.donors) do counts[e.label]=(counts[e.label] or 0)+1 end
    for _,e in ipairs(plan.donors) do
        local name=e.label
        if counts[name]>1 then name=name.." #"..tostring(e.id) end
        local ok,liquid=pcall(function() return e.fluid:getUiName() end)
        if ok and type(liquid)=="string" and liquid~="" and not name:find(liquid,1,true) then name=name.." ("..liquid..")" end
        local title=name.." | "..liters(e.amount).."L"
        local row=child:addOption(title,{app=app,click=click,index=index,instance=instance,source=e,
            targets={dst},receiver=dst.item,prefs=options,route="portable-fill-from"},run)
        if row then
            row.iconTexture,row.itemForTexture=nil,e.item
            tooltip(row,"Fill From",name.." ("..destinationText(e).."). Destination: "..dst.label..". Uses only these two vessels.")
        end
    end
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
    -- Forward and inverse entrances share one click and the physical holder
    -- captured here, including an explicit section of a combined loot view.
    local app,click=require "LootBox/App",{}
    local checkedAnchor,anchor=false,nil
    local function pin(e)
        if e.scope~="loot" or e.container:getType()=="floor" then return true end
        if not checkedAnchor then anchor=instance.world:pourShelfAnchor(e.container);checkedAnchor=true end
        e.pourAnchor=anchor
        return anchor~=nil
    end
    local inverse
    if #members==1 and viewed and holder==viewed then
        inverse=Inventory.fillFrom(snapshot,members[1],options)
        if inverse and not pin(inverse.target) then inverse=nil end
    end
    -- Empty carried vessels still need Fill From even when they cannot pour.
    local worldOK,world=pcall(WorldMenu.inventory,index,parent,branded,members,snapshot,instance,options,tooltip)
    if not worldOK then world=nil end
    if inverse then
        local ok,fixtures=pcall(WorldMenu.lootSources,world,inverse.target,click)
        inverse.fixtures=ok and fixtures or {}
        fillFrom(parent,inverse,index,instance,options,app,click,tooltip,world)
        fillFrom(branded,inverse,index,instance,options,app,click,tooltip,world)
    end
    local mounted=MountedMenu.nearby(index,instance)
    local function mountedTargets(e) return MountedMenu.targets(mounted,e,instance.world) end
    -- A collapsed row delegates the choice; an expanded individual never does.
    local plan,reason
    if #members==1 then plan,reason=Inventory.plan(snapshot,members[1],options,true)
    else plan,reason=Inventory.choose(snapshot,members,options,function(e) return #WorldMenu.destinations(world,e)>0 or #mountedTargets(e)>0 end) end
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
        return inverse~=nil or nil
    end
    local item=plan.source.item
    if not pin(plan.source) then
        return unavailable(parent,branded,item,tooltip,"The selected storage is out of reach or cannot return this vessel. Move closer or carry the source.")
    end
    local targets,fill=plan.targets,plan.fill
    local fixtures=WorldMenu.destinations(world,plan.source)
    local mountedJugs=mountedTargets(plan.source)

    local source=string.format("%s | %.3f L available",plan.source.label,plan.source.amount)
    if #members>1 then
        local ok,fluidName=pcall(function() return plan.source.fluid:getUiName() end)
        if ok and type(fluidName)=="string" and fluidName~="" then source=source.." | "..fluidName end
        source=source..string.format(" (%.1f%% full; least-filled eligible vessel in this stack)",
            100*plan.source.amount/plan.source.capacity)
    end
    local groups=Stacks.targets({targets=targets},index)
    local function render(host)
        local root=host:addOption("Pour Into",marker,nil)
        if not root then return end
        builtinIcon(root,"Item_WaterDrop",item)
        if #targets==0 and #fixtures==0 and #mountedJugs==0 then
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
        local function choice(title,list,route)
            return child:addOption(title,{app=app,click=click,index=index,instance=instance,source=plan.source,
                targets=list,prefs=options,route=route},run)
        end
        if #fill>0 then
            local batch=choice("Fill All",fill,"fill-all")
            builtinIcon(batch,"media/ui/inventoryPanes/TransferSameTypeMultiContainer.png",item)
            local order=options.pourFillScope=="main-only" and "main inventory only" or
                options.pourFillScope=="equipped-first" and "equipped first" or "main inventory first"
            tooltip(batch,"Fill All",string.format("%s. %d destination(s), %s; %s room left first within each group.",
                source,#fill,order,options.pourFillOrder=="largest-first" and "most" or "least"))
        end
        WorldMenu.addTargets(child,world,fixtures,plan.source,click)
        MountedMenu.addTargets(child,mountedJugs,index,instance,plan.source,click,tooltip)
        -- A direct stack entry binds one exact vessel; Fill All uses the whole list.
        for _,group in ipairs(groups) do
            local e=group.entry
            local row=choice(destinationText(e),{e},"single")
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
