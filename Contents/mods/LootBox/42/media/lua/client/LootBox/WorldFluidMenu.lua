local W=require "LootBox/WorldFluids"
local Inventory=require "LootBox/PourInventory"
local Menu={}
local MARK={}
local function existing(host,name)
    for _,o in ipairs(host.options or {}) do if o.name==name then return true end end
end
local function child(host,title)
    local o=host:addOption(title,MARK,nil)
    if o then
        o.iconTexture=getTexture("Item_WaterDrop")
        local c=ISContextMenu:getNew(host)
        host:addSubMenu(o,c)
        return c
    end
end
local function descriptors(anchors)
    local counts={}
    for _,a in ipairs(anchors) do counts[a.name]=(counts[a.name] or 0)+1 end
    for _,a in ipairs(anchors) do
        a.label=counts[a.name]>1 and (a.name.." ("..a.place..")") or a.name
    end
end
local function detail(a)
    local amount=a.unlimited and getText("Tooltip_WaterUnlimited") or string.format("%.3f / %.3f L",a.amount,a.capacity)
    local fluid=a.object:getFluidUiName()
    return a.name.." ("..a.place.."): "..tostring(fluid or "").." | "..amount
end
local function run(v)
    if v.state.once.used then return end
    v.state.once.used=true
    local s=v.state
    local app=require("LootBox/App").get(s.index)
    local ok,reason
    if app==s.app then ok,reason=app:worldPour(v.anchor,v.take,v.entries,s.origin,s.options,v.loan) end
    if not ok then
        local p=getSpecificPlayer(s.index)
        local text=tostring(reason or "The selected world fluid or vessel is no longer available.")
        if p and HaloTextHelper and HaloTextHelper.addBadText then HaloTextHelper.addBadText(p,text)
        else print("[LootBox] "..text) end
    end
    return ok,reason
end
local function row(host,title,s,a,take,entries,help,icon,loan)
    local o=host:addOption(title,{state=s,anchor=a,take=take,entries=entries,loan=loan},run)
    if o then
        if icon then o.itemForTexture=icon else o.iconTexture=getTexture("Item_WaterDrop") end
        s.tip(o,title,detail(a)..". "..help)
    end
end
local function state(index,app,options,tip,origin,anchors)
    descriptors(anchors)
    return {index=index,app=app,player=getSpecificPlayer(index),world=app.world,once={},anchors=anchors,
        options=options,tip=tip,origin=origin}
end
local function eligible(s,a,entries,take)
    local out={}
    for _,e in ipairs(entries) do
        if W.permits(s.player,s.world,a,e,take) and W.signature(e) then out[#out+1]=e end
    end
    return out
end
local function batch(s,entries)
    local fill={}
    for _,e in ipairs(entries) do
        if s.options.pourFillScope~="main-only" or e.scope=="main" then fill[#fill+1]=e end
    end
    Inventory.sortFill(fill,s.options)
    return fill
end
local function itemText(e) return string.format("%s | %.3f / %.3f L",e.label,e.amount,e.capacity) end

function Menu.inventory(index,parent,branded,members,snapshot,app,options,tip)
    local p=getSpecificPlayer(index)
    if not getCell or not p or not p.getCurrentSquare then return end
    local anchors=W.objects(p,nil)
    if #anchors==0 then return end
    local s=state(index,app,options,tip,"inventoryShortcuts",anchors)
    local refs,selected={},{}
    for _,i in ipairs(members) do refs[i]=true end
    for _,e in ipairs(snapshot.entries) do if refs[e.item] and e.scope~="loot" then selected[#selected+1]=e end end
    if #selected==0 then return s end
    local sources={}
    for _,a in ipairs(anchors) do
        local available=eligible(s,a,selected,true)
        if #members>1 then available=batch(s,available) end
        if #available>0 and #available<=512 and (#members==1 or not snapshot.truncated) then
            sources[#sources+1]={anchor=a,entries=available}
        end
    end
    local function render(h)
        if #sources==0 or existing(h,"Fill From") then return end
        local c=child(h,"Fill From")
        if not c then return end
        for _,k in ipairs(sources) do
            local title=k.anchor.label..(#members>1 and (" | "..#k.entries.." selected vessel(s)") or "")
            row(c,title,s,k.anchor,true,k.entries,"Fill only the selected carried vessel(s) using stock fluid rules.")
        end
    end
    render(parent);render(branded)
    return s
end
-- The clicked loot receiver already has a Fill From submenu for portable
-- donors. Add fixtures to that same frozen plan (including world-only picks).
function Menu.lootSources(s,dst,click)
    local out={}
    if not s then return out end
    local Loan=require "LootBox/WorldLootFill"
    local lease=Loan.bind(s.player,s.world,dst)
    if not lease then return out end
    s.once=click
    for _,a in ipairs(s.anchors) do
        local source=Loan.source(s.player,a,dst)
        if source then out[#out+1]={a=a,lease=lease,source=source} end
    end
    return out
end
function Menu.addLootSources(host,s,choices,dst)
    for _,c in ipairs(choices) do
        row(host,c.a.label,s,c.a,true,{dst},
            "Borrow "..dst.label..", fill it using the game's fixture action, then return the same vessel.",
            nil,c)
    end
end
function Menu.destinations(s,source)
    local list={}
    if s then for _,a in ipairs(s.anchors) do
        if W.permits(s.player,s.world,a,source,false) then list[#list+1]=a end
    end end
    return list
end
function Menu.addTargets(host,s,anchors,source,click)
    if not s then return end
    -- Share the same latch as portable pours from either root.
    s.once=click
    for _,a in ipairs(anchors) do
        row(host,a.label,s,a,false,{source},"Pour from "..source.label.." without changing your equipped items.")
    end
end

local function world(index,host,objects,app,options,tip)
    for _,o in ipairs(host.options or {}) do if o.target==MARK then return end end
    local p=getSpecificPlayer(index)
    local anchors=W.objects(p,objects)
    if #anchors==0 then return end
    local s=state(index,app,options,tip,"worldShortcuts",anchors)
    local snapshot=Inventory.snapshot(p,app.world,nil,nil)
    for _,a in ipairs(anchors) do
        for _,dir in ipairs({"take","give"}) do
            local take=dir=="take"
            local choices=eligible(s,a,snapshot.entries,take)
            if #choices>0 then
                local title=(take and "Fill from " or "Pour into ")..a.label
                local c=child(host,title)
                if c then
                    local fill=take and not snapshot.truncated and batch(s,choices) or {}
                    if #fill>1 and #fill<=512 then
                        row(c,"Fill All",s,a,true,fill,"Fill eligible carried vessels in your preferred order, one confirmed transfer at a time.")
                    end
                    local labels={}
                    for _,e in ipairs(choices) do local n=itemText(e);labels[n]=(labels[n] or 0)+1 end
                    for _,e in ipairs(choices) do
                        local name=itemText(e)
                        if labels[name]>1 then name=name.." [ID "..tostring(e.id).."]" end
                        row(c,name,s,a,take,{e},take and "Fill this exact vessel from the selected fixture."
                            or "Pour from this main-inventory vessel; your hands stay as they were.",e.item)
                    end
                end
            end
        end
    end
end
function Menu.world(...) pcall(world,...) end
return Menu
