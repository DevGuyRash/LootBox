local Feature=require "LootBox/MountedDispenser"
local Inventory=require "LootBox/PourInventory"
local Menu={}
local MARKER={}

local function run(pick)
    if pick.once.used then return end
    pick.once.used=true
    local app=require("LootBox/App").get(pick.index)
    local ok,reason
    if app==pick.app then ok,reason=app:refillDispenser(pick.anchor,pick.donor,pick.bottle) end
    if not ok then
        local p=getSpecificPlayer(pick.index)
        local text="Refill Dispenser: "..tostring(reason or "The selection is no longer available.")
        if p and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(p,text)
        else print("[LootBox] "..text) end
    end
end

local function add(index,host,objects,app,tip)
    for _,old in ipairs(host.options or {}) do if old.target==MARKER then return end end
    local player=getSpecificPlayer(index)
    if not player then return end
    local anchor=Feature.capture(player,objects)
    if not anchor then return end
    local mpTopUp=anchor.kind=="mounted" and isClient() and Feature.mountedMPEnabled()
    local title=mpTopUp and "Top up mounted dispenser"
        or anchor.kind=="bare" and "Refill and fit a bottle" or "Refill mounted dispenser"
    local function root()
        local option=host:addOption(title,MARKER,nil)
        if option then option.iconTexture=getTexture("Item_WaterTank") end
        return option
    end
    if anchor.kind=="mounted" and isClient() and not mpTopUp then
        local option=root()
        if option then
            option.notAvailable=true
            tip(option,title,"Use stock Take Bottle, then right-click this empty stand and choose the exact bottle and source. Use stock Transfer Fluids to pour directly from a mounted dispenser.")
        end
        return
    end
    local bottles,donors=Feature.destinations(player,app.world,anchor),Feature.donors(player,app.world)
    local rows,total={},0
    for _,bottle in ipairs(bottles) do
        local options={}
        for _,entry in ipairs(donors) do
            if not app.world:protected(entry.item) and Feature.canFill(entry,bottle) then
                entry.pourSignature=entry.pourSignature or Inventory.mix(entry)
                if entry.pourSignature then options[#options+1]=entry;total=total+1 end
            end
            if total>128 then break end
        end
        if #options>0 then rows[#rows+1]={bottle=bottle,donors=options} end
        if total>128 then break end
    end
    local option=root()
    if not option then return end
    if #rows==0 or total>128 then
        option.notAvailable=true
        tip(option,title,total>128 and "Too many vessel pairs. Put spare bottles or sources away and reopen the menu."
            or "Carry a compatible liquid source and, for an empty stand, the bottle you want to fill in main inventory. Stock reach and capacity apply.")
        return
    end
    tip(option,title,mpTopUp and "Adds up to 0.25 L and refits this exact bottle using stock actions."
        or anchor.kind=="mounted" and "Takes, fills, and refits this exact bottle using stock actions."
        or "Choose the exact bottle first, then its source. On multiplayer the stock refit is requested, not assumed confirmed.")
    local submenu=ISContextMenu:getNew(host)
    host:addSubMenu(option,submenu)
    local once={}
    for i,record in ipairs(rows) do
        local target=submenu
        if anchor.kind=="bare" then
            local b=record.bottle
            local name=string.format("%s #%d | %.3fL / %.3fL",b.label,i,b.state.amount,b.state.cap)
            local choice=submenu:addOption(name,nil,nil)
            if not choice then return end
            choice.itemForTexture=b.item
            target=ISContextMenu:getNew(submenu);submenu:addSubMenu(choice,target)
        end
        local counts={}
        for _,entry in ipairs(record.donors) do counts[entry.label]=(counts[entry.label] or 0)+1 end
        local seen={}
        for _,entry in ipairs(record.donors) do
            local name=entry.label
            if counts[name]>1 then seen[name]=(seen[name] or 0)+1;name=name.." #"..seen[name] end
            local planned=mpTopUp and Feature.plannedMountedTopUp(entry,record.bottle)
            local label=planned and string.format("%s | add %.2f L (%.3f L available)",name,planned,entry.amount)
                or string.format("%s | %.3fL",name,entry.amount)
            local row=target:addOption(label,
                {index=index,app=app,anchor=anchor,donor=entry,bottle=record.bottle,once=once},run)
            if row then
                row.itemForTexture=entry.item
                tip(row,title,"Uses only these selected vessels and this stand. A stopped or uncertain action is never retried.")
            end
        end
    end
end
function Menu.add(index,host,objects,app,tip)
    -- Missing stock/modded UI bindings cannot break another provider's menu.
    pcall(add,index,host,objects,app,tip)
end
return Menu
