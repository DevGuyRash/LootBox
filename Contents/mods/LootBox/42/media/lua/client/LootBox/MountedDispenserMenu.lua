local Feature=require "LootBox/MountedDispenser"
local Inventory=require "LootBox/PourInventory"
local Menu={}
local MARKER={}
local function fluidName(e)
    local ok,name=pcall(function() return e.fluid:getUiName() end)
    return ok and type(name)=="string" and name~="" and name or nil
end

local function run(pick)
    if pick.once.used then return end
    pick.once.used=true
    local app=require("LootBox/App").get(pick.index)
    local ok,reason
    if app==pick.app then ok,reason=app:refillDispenser(pick.anchor,pick.donor,pick.bottle,pick.origin) end
    if not ok then
        local p=getSpecificPlayer(pick.index)
        local text="Refill Dispenser: "..tostring(reason or "The selection is no longer available.")
        if p and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(p,text)
        else print("[LootBox] "..text) end
    end
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
function Menu.nearby(index,app)
    local ok,choices=pcall(captureChoices,index,app)
    return ok and choices or {}
end
function Menu.targets(choices,source,world)
    local result={}
    if source and source.scope~="loot" and source.pourSignature then
        local allowed,protected=pcall(world.protected,world,source.item)
        if not allowed or protected then return result end
        for _,choice in ipairs(choices) do
            local ok,compatible=pcall(Feature.canFill,source,choice.bottle)
            if ok and compatible then result[#result+1]=choice end
        end
    end
    return result
end
function Menu.addTargets(host,choices,index,app,source,once,tip)
    for _,choice in ipairs(choices) do
        local a,b=choice.anchor,choice.bottle
        local name="Water Dispenser"
        if #choices>1 then name=string.format("%s (%d, %d)",name,a.square:getX(),a.square:getY()) end
        local contents=b.state.amount>0 and fluidName(b.state) or nil
        if contents then name=name.." ("..contents..")" end
        local label=string.format("%s | %.3f / %.3f L",name,b.state.amount,b.state.cap)
        local row=host:addOption(label,{index=index,app=app,anchor=a,donor=source,bottle=b,
            once=once,origin="inventoryShortcuts"},run)
        if row then
            row.iconTexture=getTexture("Item_WaterTank")
            local liquid=fluidName(source)
            tip(row,"Pour Into","Takes the mounted bottle, adds "..(liquid or "compatible liquid")
                .." from this vessel, then refits the same bottle. Compatible liquids may mix.")
        end
    end
end

local function add(index,host,objects,app,tip,includeFallback,showUnavailable,once)
    for _,old in ipairs(host.options or {}) do if old.target==MARKER then return end end
    local player=getSpecificPlayer(index)
    if not player then return end
    local anchor=Feature.capture(player,objects)
    if not anchor then return end
    local mpTopUp=anchor.kind=="mounted" and isClient()
    local title=anchor.kind=="bare" and "Refill and fit a bottle"
        or mpTopUp and "Top up mounted dispenser" or "Refill mounted dispenser"
    if anchor.kind=="bare" and not includeFallback then return end
    local function root()
        local option=host:addOption(title,MARKER,nil)
        if option then option.iconTexture=getTexture("Item_WaterTank") end
        return option
    end
    if mpTopUp and not Feature.mountedMPEnabled() then
        if not showUnavailable then return end
        local option=root()
        if option then
            option.notAvailable=true
            tip(option,title,"Use stock Take Bottle, then right-click this empty stand and choose the exact bottle and source. Use stock Transfer Fluids to pour directly from a mounted dispenser.")
        end
        return
    end
    local bottles=Feature.destinations(player,app.world,anchor)
    local donors,truncated=Feature.donors(player,app.world)
    if not showUnavailable and #bottles==0 then return end
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
    if not showUnavailable and (#rows==0 or total>128) then return end
    local option=root()
    if not option then return end
    if #rows==0 or total>128 then
        option.notAvailable=true
        tip(option,title,total>128 and "Too many vessel pairs. Put spare bottles or sources away and reopen the menu."
            or "Carry a compatible liquid source and, for an empty stand, the bottle you want to fill in main inventory. Stock reach and capacity apply.")
        return
    end
    local help=mpTopUp and "Adds as much compatible liquid as fits, then refits this exact bottle using stock actions."
        or anchor.kind=="mounted" and "Takes, fills, and refits this exact bottle using stock actions."
        or "Choose the exact bottle first, then its source. On multiplayer the stock refit is requested, not assumed confirmed."
    if anchor.kind=="mounted" then
        local current=bottles[1].state
        local contents=current.amount==0 and "empty" or fluidName(current)
        help=string.format("Mounted jug%s: %.3f / %.3f L. %s",
            contents and (" ("..contents..")") or "",current.amount,current.cap,help)
    end
    tip(option,title,help)
    local submenu=ISContextMenu:getNew(host)
    host:addSubMenu(option,submenu)
    once=once or {}
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
        if anchor.kind=="mounted" and #record.donors>1 and not truncated then
            local row=target:addOption("Fill from All",{index=index,app=app,anchor=anchor,
                donor=record.donors,bottle=record.bottle,once=once},run)
            if row then
                row.iconTexture=getTexture("Item_WaterTank")
                tip(row,title,"Takes the bottle once, pours from the listed sources in order until full or out of compatible liquid, then refits it. Compatible liquids may mix.")
            end
        end
        local counts={}
        for _,entry in ipairs(record.donors) do counts[entry.label]=(counts[entry.label] or 0)+1 end
        local seen={}
        for _,entry in ipairs(record.donors) do
            local name=entry.label
            if counts[name]>1 then seen[name]=(seen[name] or 0)+1;name=name.." #"..seen[name] end
            local liquid=fluidName(entry)
            if liquid and not name:find(liquid,1,true) then name=name.." ("..liquid..")" end
            local planned=mpTopUp and Feature.plannedMountedTopUp(entry,record.bottle)
            local label=planned and string.format("%s | add %.3f L (%.3f L available)",name,planned,entry.amount)
                or string.format("%s | %.3fL",name,entry.amount)
            local row=target:addOption(label,
                {index=index,app=app,anchor=anchor,donor=entry,bottle=record.bottle,once=once},run)
            if row then
                row.itemForTexture=entry.item
                tip(row,title,"Uses only these selected vessels and this stand. Compatible liquids may mix.")
            end
        end
    end
end
function Menu.add(index,host,objects,app,tip,primary,once)
    -- Missing stock/modded UI bindings cannot break another provider's menu.
    pcall(add,index,host,objects,app,tip,not primary,not primary,once)
end
return Menu
