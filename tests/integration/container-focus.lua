-- Explicit renderer/Java boundaries; check-active-container-stock.py substitutes
-- the installed stock selector, input/selection and NeatUI input/geometry Lua.
package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Focus = require "LootBox/ContainerFocus"
local Clicks = require "LootBox/PaneClicks"
local f, total = nil, 0
local function wipe(t) for k in pairs(t) do t[k] = nil end end
table.wipe = table.wipe or wipe
function instanceof(v, t) return t == "InventoryItem" and v and v.isItem == true or false end
function getSpecificPlayer(n) assert(n==0); return f.actor end
function isClient() return true end
function isCtrlKeyDown() return f.ctrl == true end
function isShiftKeyDown() return f.shift == true end
function getTimestampMs() return 100 end
function getCore() return {getGameMode=function()return "Survival"end} end
JoypadState = {players={}}
ISMouseDrag = {}
local function itemsOf(rows)
    local list, seen = {}, {}
    local function add(v) if not seen[v] then seen[v]=true; list[#list+1]=v end end
    for _,r in ipairs(rows) do
        if r.isItem then add(r) else for j=2,#r.items do add(r.items[j]) end end
    end
    return list
end
local function model(Views)
    local P, W = {}, {}
    P.getActualItems = itemsOf
    function P:selectIndex(i) self.selected[i]=self.items[i] end
    function P:saveSelection(out)
        for _,r in pairs(self.selected) do
            if r.isItem then out[r]=out[r] or "item" else out[r.items[1]]="group" end
        end
        return out
    end
    function P:restoreSelection(saved)
        for i,r in ipairs(self.items) do
            if (r.isItem and saved[r]=="item") or (not r.isItem and saved[r.items[1]]=="group") then self.selected[i]=r end
        end
    end
    function P:onMouseDown(x,y)
        local i=Views.indexAt(self,Views.grid(self),x,y)
        self.downX,self.downY,self.mouseOverOption=x,y,i
        if not self.items[i] then self.draggingMarquis=true; return true end
        if not f.ctrl and not f.shift and not self.selected[i] then self.selected={} end
        if f.shift and self.firstSelect then
            for j=math.min(i,self.firstSelect),math.max(i,self.firstSelect) do self.selected[j]=self.items[j] end
        else
            self.firstSelect=i
            if f.ctrl and self.selected[i] then self.selected[i]=nil else self.selected[i]=self.items[i] end
        end
        self.dragging=i; self.dragStarted=false; ISMouseDrag.draggingFocus=self
        ISMouseDrag.dragging={}; for j,r in ipairs(self.items) do if self.selected[j] then table.insert(ISMouseDrag.dragging,r) end end
        if f.onCount and not f.ctrl and not f.shift then self.ninvPress=i end
    end
    function P:onMouseUp(x,y)
        if self.ninvPress and not self.dragStarted and self.items[self.ninvPress] then Views.toggle(self,self.ninvPress) end
        self.ninvPress=nil; self.dragging=nil; self.draggingMarquis=false; ISMouseDrag.dragging=nil; ISMouseDrag.draggingFocus=nil
        return true
    end
    function P:onRightMouseUp(x,y)
        local i=self.mouseOverOption
        if self.items[i] and not self.selected[i] then self.selected={}; self:selectIndex(i) end
        local rows={}; for j,r in ipairs(self.items) do if self.selected[j] then rows[#rows+1]=r end end
        ISInventoryPaneContextMenu.createMenu(0,self.inventory:isInCharacterInventory(f.actor),rows,x+21,y+32+self.scroll)
        return true
    end
    function W:selectContainer(b)
        self.inventoryPane.inventory=b.inventory; self.inventoryPane.lastinventory=b.inventory; self.inventoryPane.selected={}
        if not b.inventory:isExplored() then b.inventory:requestServerItemsForContainer(); b.inventory:setExplored(true) end
        self.title=b.name; self.capacity=b.capacity; self:refreshBackpacks()
    end
    return P,W
end

local Views = { isGrid=function()return f.grid end, multi=function()return f.multi end, combined=function()return f.combined end,
    controlAt=function()end, chevronAt=function()end, clickOpens=function()return false end,
    containerAt=function()return nil end, onCount=function()return f.onCount end,
    headAt=function()end, isOpen=function(p,r)
        local c=r.ninvMerged and "combined" or p.ninvSections[r.ninvSection].container
        return p.open[c] and #r.items>2
    end}
function Views.grid(p)
    local rows={}; for i=1,#p.items do rows[i]={first=i,last=i,y=10+(i-1)*18,x=5} end
    return {x0=5,y0=10,cols=1,cellW=120,cellH=18,layout={rows=rows,heads={}}}
end
function Views.indexAt(p,g,x,y)
    if x<g.x0 or x>=g.x0+g.cellW or y<g.y0 then return 0 end
    local i=1+math.floor((y-g.y0)/g.cellH); return p.items[i] and i or 0
end
function Views.sectionOfRow(p,i)
    for j=i,1,-1 do local r=p.items[j]; if not r.isItem then return p.ninvSections[r.ninvSection] end end
end
function Views.buildItems(p)
    wipe(p.items); p.ninvItemsGen=p.ninvRefreshGen
    for _,r in ipairs(p.itemslist) do p.items[#p.items+1]=r; if Views.isOpen(p,r) then for j=2,#r.items do p.items[#p.items+1]=r.items[j] end end end
end
function Views.toggle(p,i)
    local r=p.items[i]; if r.isItem or #r.items<=2 then return end
    local c=r.ninvMerged and "combined" or p.ninvSections[r.ninvSection].container
    p.open[c]=not p.open[c]; Views.buildItems(p); return true
end
local P,W,stockOptions,stockAPI
if LOOTBOX_TEST_CLICK_STOCK then P,W,stockOptions,stockAPI=LOOTBOX_TEST_CLICK_STOCK(Views) else P,W=model(Views) end
ISInventoryPane=P
P.MAX_ITEMS_IN_STACK_TO_RENDER=50
local function c(label)
    return {kind=label,getParent=function()return nil end,isLockedToCharacter=function(self)return self.locked==true end,
        isInCharacterInventory=function()return f.page.onCharacter end,isExplored=function(self)return self.explored==true end,
        setExplored=function(self,x)self.explored=x end,requestServerItemsForContainer=function(self)self.requests=(self.requests or 0)+1 end}
end
local function item(container) return {isItem=true,owner=container,getContainer=function(self)return self.owner end} end
local function mkrow(p,list)
    local vals={list[1]}; for _,i in ipairs(list) do vals[#vals+1]=i end
    return {items=vals,name="Same display name",count=#vals,invPanel=p}
end
function getPlayerInventory() return f.page end
function getPlayerLoot() return f.page end
ISInventoryPaneContextMenu = { createMenu=function(n,carried,rows,x,y)
    f.menus=f.menus+1; f.menuActive=f.pane.inventory; f.menuItems=itemsOf(rows); f.xy={x,y}; f.carried=carried
    return nil
end }
local opts=stockOptions or {data={},dict={},getOption=function(self,id)return self.dict[id]end,
    addTickBox=function(self,id,name,on)
        local o={id=id,value=on,getValue=function(v)return v.value end,setValue=function(v,b)v.value=b end}
        self.dict[id]=o; self.data[#self.data+1]=o; return o
    end}
Focus.register(opts); Focus.register(opts)
local opt=opts:getOption("activateClickedContainer"); assert(#opts.data==1 and opt:getValue()==true)
local function setup(char)
    f={grid=true,multi=true,combined=false,menus=0,refreshes=0,actor={nullifyAiming=function()end}}
    local p=setmetatable({player=0,headerHgt=10,width=140,height=180,column2=12,column3=130,itemHgt=18,scroll=0,
        items={},itemslist={},selected={},open={},collapsed={["Same display name"]=true},
        getYScroll=function(self)return self.scroll end,getAbsoluteX=function()return 21 end,getAbsoluteY=function()return 32 end,
        draggedItems={reset=function()end},getMouseY=function()return 0 end,getMouseX=function()return 30 end}, {__index=P})
    local page=setmetatable({player=0,backpacks={},onCharacter=char==true,inventoryPane=p,
        playContainerOpenCloseSounds=function()end}, {__index=W})
    f.page,f.pane=page,p; p.inventoryPage=page; p.parent=page
    f.c={c("same"),c("same"),c("floor")}
    f.a,f.b,f.b2,f.z=item(f.c[1]),item(f.c[2]),item(f.c[2]),item(f.c[3])
    f.lists={{f.a},{f.b,f.b2},{f.z}}
    for i,cont in ipairs(f.c) do
        page.backpacks[i]={inventory=cont,name="Same",capacity=40,parent={parent=page},onRightMouseDown=function()end}
    end
    function f.render()
        p.ninvRefreshGen=(p.ninvRefreshGen or 0)+1
        p.ninvSections={}; p.itemslist={}
        for i=1,#f.lists do
            if f.multi or p.inventory==f.c[i] then
                local row=mkrow(p,f.lists[i])
                p.itemslist[#p.itemslist+1]=row
                local sec={container=f.c[i],button=page.backpacks[i],index=i}
                p.ninvSections[i]=sec; row.ninvSection=i
                if f.combined then row.ninvMerged=true end
            end
        end
        p.ninvCombinedBuilt=f.combined
        Views.buildItems(p)
    end
    function page:refreshBackpacks()
        f.refreshes=f.refreshes+1; self.inventory=p.inventory; self.selectedButton=Focus.button(page,self.inventory)
        if f.change then f.change() end
        f.render(); Clicks.attach(p) -- real selection re-enters refresh end
    end
    p.inventory=f.c[1]; p.lastinventory=f.c[1]; page.inventory=f.c[1]
    f.render(); NeatInventory={enabled=true,Views=Views}; opt:setValue(true)
    ISMouseDrag={}; JoypadState.players={}; Clicks.attach(p)
end
local function test(label,fn) setup(); fn(); total=total+1; print("PASS "..label) end
local function point(i) return 30,12+(i-1)*18 end
local function right(i,x,y) f.pane.mouseOverOption=i; if not x then x,y=point(i) end; return f.pane:onRightMouseUp(x,y) end
local function down(i) local x,y=point(i); f.pane.mouseOverOption=i; return f.pane:onMouseDown(x,y) end
local function up(i) return f.pane:onMouseUp(point(i)) end
local function has(list,v) for _,i in ipairs(list) do if i==v then return true end end end

test("right item in loot and carried pane selects its physical owner before the native item menu, original screen location, and a single explorer request",function()
    for _,inv in ipairs({false,true}) do setup(inv); assert(right(2)==true)
        assert(f.menus==1 and f.menuActive==f.c[2] and f.carried==inv and f.page.selectedButton==f.page.backpacks[2])
        assert(#f.menuItems==2 and has(f.menuItems,f.b) and has(f.menuItems,f.b2) and f.xy[1]==51 and f.xy[2]==62)
        right(2); assert(f.refreshes==1 and f.c[2].requests==1 and f.menus==2)
    end
end)
test("native left press and release retain selection, firstSelect and ordinary drag setup; hovering or pressing alone never selects a new container",function()
    down(2); assert(f.refreshes==0 and f.pane.inventory==f.c[1] and f.pane.dragging==2 and ISMouseDrag.draggingFocus==f.pane)
    assert(has(itemsOf(ISMouseDrag.dragging),f.b) and up(2)==true)
    assert(f.refreshes==1 and f.pane.inventory==f.c[2] and f.pane.firstSelect==2 and f.pane.selected[2]==f.pane.items[2])
    assert(ISMouseDrag.dragging==nil and f.menus==0)
end)
test("shift range and ctrl append across three containers survive native focus and subsequent right menus; only clicked row decides active",function()
    down(1); up(1); f.shift=true; down(3); up(3); f.shift=false
    assert(f.pane.inventory==f.c[3] and f.pane.firstSelect==1 and f.pane.selected[1] and f.pane.selected[3])
    right(2); assert(f.menuActive==f.c[2] and #f.menuItems==4 and has(f.menuItems,f.a) and has(f.menuItems,f.z))
    setup(); down(1);up(1);f.ctrl=true;down(2);up(2);f.ctrl=false
    right(2); assert(#f.menuItems==3 and has(f.menuItems,f.a) and has(f.menuItems,f.b2))
end)
test("Combined unique child vs mixed stack, expanded stack press/count and multi-view stay native",function()
    f.combined=true; f.lists[1]={f.a,f.b}; f.render(); right(1)
    assert(f.refreshes==0 and #f.menuItems==2)
    f.onCount=true; down(1);up(1); f.onCount=false
    assert(f.pane.items[3]==f.b and f.combined and f.refreshes==0)
    right(3); assert(f.menuActive==f.c[2] and #f.menuItems==1 and f.menuItems[1]==f.b and f.combined)
end)
test("same-name section row that now belongs to another container, old grid generation, clipped header, stray click, gutter, stale pooled section and unknown member never focus",function()
    f.b.owner=f.c[3]; right(2); assert(f.refreshes==0); f.b.owner=f.c[2]
    f.pane.ninvItemsGen=0; right(2); assert(f.refreshes==0); f.render()
    right(2,131,30); f.pane.scroll=-30; right(2); f.pane.scroll=0; right(2,30,160)
    f.pane.mouseOverOption=1; f.pane:onRightMouseUp(point(2)); assert(f.refreshes==0)
    f.page.backpacks[2].inventory=f.c[3]; right(2); assert(f.refreshes==0)
    setup(); f.b2.owner=nil; right(2); assert(f.refreshes==0 and f.menus==1)
end)
test("locked target, active controller and a detached button never change focus; native gesture kept",function()
    f.c[2].locked=true;right(2); f.c[2].locked=false;JoypadState.players[1]={};right(2)
    JoypadState.players[1]=nil;f.page.backpacks[2].parent=nil;right(2); assert(f.refreshes==0 and f.menus==3)
end)
test("switch off takes effect on existing widgets for left and right; restoring option restores focus and no extra menu",function()
    opt:setValue(false);down(2);up(2);right(2); assert(f.refreshes==0 and f.menus==1 and f.menuActive==f.c[1])
    opt:setValue(true);right(2);assert(f.refreshes==1 and f.menus==2 and f.menuActive==f.c[2])
end)
test("ordinary vanilla items stay in the active container without extra selection; a stale foreign row cannot focus anything",function()
    NeatInventory=nil;f.grid=false;f.multi=false;f.render();right(1);down(1);up(1)
    assert(f.refreshes==0 and f.menus==1);f.pane.items[1]=mkrow(f.pane,{f.b});right(1);assert(f.refreshes==0)
end)
test("a native drag is not reinterpreted as a click or as a drop onto a second container",function()
    down(2);f.pane.dragStarted=true;up(2); assert(f.refreshes==0 and not ISMouseDrag.dragging)
    -- Last click having been a drag must not block a later standalone right click.
    right(2); assert(f.refreshes==1 and f.menus==1)
end)
test("membership change during focus never dispatches context on a replacement item",function()
    f.change=function() f.lists[2]={item(f.c[2])} end
    assert(right(2)==true and f.menus==0 and f.refreshes==1)
end)
test("cooperative callbacks remain once-only through repeated native refresh; prior return values, including nil holes, propagate",function()
    local p=f.pane; local old=p.onRightMouseUp;local calls=0
    p.onRightMouseUp=function(...)calls=calls+1;old(...);return nil,"tail",3 end
    Clicks.attach(p);Clicks.attach(p);local a,b,n=right(2)
    assert(a==nil and b=="tail" and n==3 and calls==1 and f.menus==1 and f.refreshes==1)
end)
if stockAPI then test("installed Mod Options saves an off value and reloads it on a new registration without a second preference store",function()
    local lines={}
    getFileWriter=function(path) assert(path=="ModOptions.ini");return {write=function(_,line)lines[#lines+1]=line:gsub("[\r\n]+$","") end,close=function()end} end
    opt:setValue(false);stockAPI:save();assert(lines[1]=="tickbox|LootBox|activateClickedContainer|false")
    stockAPI.Data={};stockAPI.Dict={};local fresh=stockAPI:create("LootBox","LootBox");Focus.register(fresh)
    assert(Focus.enabled());local i=0
    getFileReader=function(path)assert(path=="ModOptions.ini");return {readLine=function()i=i+1;return lines[i] end,close=function()end} end
    luautils={split=function(line) local fields={};for part in line:gmatch("[^|]+") do fields[#fields+1]=part end;return fields end}
    stockAPI:load();assert(not Focus.enabled() and #fresh.data==1)
end) end
print(total.." active-container mouse/identity/option cases passed; Java/UI boundaries simulated")
