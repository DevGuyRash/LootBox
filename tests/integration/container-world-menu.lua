-- Explicit UI/Java doubles; tools/check-container-world-stock.py can run the
-- same gestures with the installed world/menu/NeatUI hit-test Lua in Kahlua.
package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local f
local Menus
local Bridge = require "LootBox/ContainerWorldMenu"
for _, name in ipairs({"ISUI/ISPanel","ISUI/ISContextMenu","ISUI/ISToolTip","TimedActions/ISBaseTimedAction","LootBox/Catalog","LootBox/Guides",
    "LootBox/PourMenu","TimedActions/ISInventoryTransferUtil"}) do package.loaded[name] = {} end
package.loaded["LootBox/Selection"] = { attach = function() end }
package.loaded["LootBox/App"] = { getPreferences = function() return { contextMenus = false } end }
local function wipe(t) for k in pairs(t) do t[k] = nil end end
table.wipe = table.wipe or wipe
function instanceof(o, kind) return o and o.classes and o.classes[kind] or false end
function getSpecificPlayer(p) assert(p == f.playerIndex); return f.actor end
function getMouseX() return 683 end
function getMouseY() return 221 end
function getMouseXScaled() return 1366 end
function getMouseYScaled() return 442 end
local Focus = require "LootBox/ContainerFocus"
Focus.register({getOption=function()end, addTickBox=function(_,id,name,default)
    assert(default==true and id=="activateClickedContainer")
    return {getValue=function()return f.focus~=false end}
end})
function getPlayerContextMenu(p) assert(p == f.playerIndex); return f.menu end
function isGamePaused() return f.pause end
function getCore() return {isTutorial=function()return f.tutorial end, getZoom=function()return 1 end,
    getBadHighlitedColor=function()return {} end,getScreenHeight=function()return 1080 end,
    getOptionSingleContextMenu=function()return f.single end,getOptionContextMenuFont=function()return "Medium" end} end
function getTimestampMs() return 100 end
function getText(key) return key end
function getTexture(path) return path end
function isAdmin() return f.admin end
Events = {OnPressWalkTo={Add=function()end}}
UIManager = {getSpeedControls=function()return {getCurrentGameSpeed=function()return f.pause and 0 or 1 end} end}
JoypadState = {players={}}
FishingState = {instance=function()return "fishing" end}
ISTradingUI = {GetUIForPlayer=function()return {isVisible=function()return f.trading end} end}
ISWorldMap_instance = {isVisible=function()return f.map end}
ISInventoryPaneContextMenu = {createMenu=function(player, carried, items, x, y)
    local menu = ISContextMenu.get(player, x, y)
    menu:addOption("Genuine item menu", items[1], function(target)f.bagAction=target end)
    return menu
end}
ISLootZed = {cheat=false}
SafeHouse = {
    getSafeHouse=function(sq) assert(sq==f.square); return "home" end,
    isSafehouseAllowInteract=function(sq, actor)return sq == f.square and actor == f.actor and f.allowInteract end,
    isSafehouseAllowLoot=function(sq,actor)return sq == f.square and actor == f.actor and f.allowLoot end,
}
function getCell() return {setDrag=function()end,getGridSquare=function(_,x)return x>=0 and f.behind or nil end} end
ISCoordConversion = {ToWorld=function(x,y)return x,y end}
IsoObjectPicker = {Instance={PickCorpse=function(_,x,y) return x>=0 and y>=0 and f.corpse or nil end}}

local function option(menu, name)
    for _, v in ipairs(menu.options) do if v.name == name then return v end end
end
local function submenu(menu, name)
    local o = option(menu,name)
    return o and menu:getSubMenu(o.subOption)
end
local function invoke(menu, name)
    local o = assert(option(menu, name), name)
    o.onSelect(o.target, o.param1, o.param2, o.param3, o.param4, o.param5, o.param6, o.param7, o.param8, o.param9, o.param10)
end
local function hits(list)
    return {size=function()return #list end,get=function(_,index)return list[index+1] end}
end
-- UI/rendering doubles. The installed stock lane executes the real menu
-- class, including the shared flat submenu pool and single-menu breadcrumbs.
ISPanel = {}
function ISPanel:derive()
    local class = {}
    class.__index=class
    return setmetatable(class,{__index=self})
end
function ISPanel:new(x,y,w,h) return setmetatable({x=x,y=y,width=w,height=h},{__index=self}) end
function ISPanel:initialise() end
function ISPanel:instantiate() end
function ISPanel:addToUIManager() self.attached=true end
function ISPanel:removeFromUIManager() self.attached=false end
function ISPanel:setVisible(yes) self.visible=yes end
function ISPanel:getIsVisible() return self.visible end
function ISPanel:isReallyVisible() return self.visible end
function ISPanel:setForceCursorVisible() end
function ISPanel:bringToTop() self.raised=true end
function ISPanel:setX(x) self.x=x end
function ISPanel:setY(y) self.y=y end
function ISPanel:getX() return self.x end
function ISPanel:getY() return self.y end
function ISPanel:setWidth(w) self.width=w end
function ISPanel:setHeight(h) self.height=h end
function ISPanel:getHeight() return self.height end
function ISPanel:setScrollHeight(h) self.scrollHeight=h end
function ISPanel:getScrollHeight() return self.scrollHeight or 0 end
function ISPanel:getYScroll() return 0 end
UIFont={Medium=1}
function getTextManager() return {getFontFromEnum=function()return {getLineHeight=function()return 12 end} end,
    getFontHeight=function()return 12 end, MeasureStringX=function(_,_,str)return #str end} end
ISContextMenu = ISPanel:derive()
function ISContextMenu:new()
    return setmetatable({options={},numOptions=1,forceVisible=true},self)
end
function ISContextMenu:clear() self.options,self.numOptions={},1 end
function ISContextMenu:getSubMenu(id) return f.menu.instanceMap[id] end
function ISContextMenu:addSubMenu(o,child) o.subOption=child.subOptionNums end
function ISContextMenu:removeLastOption() table.remove(self.options); self.numOptions=#self.options+1 end
function ISContextMenu:calcHeight() self:setHeight((self.numOptions-1)*24) end
function ISContextMenu:calcWidth() return 100 end
function ISContextMenu:addOption(name,target,action,...)
    local o={name=name,target=target,onSelect=action,id=self.numOptions}
    for i=1,select("#",...) do o["param"..i]=select(i,...) end
    self.options[#self.options+1]=o; self.numOptions=#self.options+1; return o
end
function ISContextMenu:addGetUpOption(name,target,action,...)
    return self:addOption(name,self,self.onGetUpAndThen,action,target,...)
end
function ISContextMenu:getNew(parent)
    local root=f.menu
    local child=table.remove(root.subMenuPool) or ISContextMenu:new()
    child:clear()
    root.subOptionNums=root.subOptionNums+1
    child.parent,child.player,child.subOptionNums=parent,parent.player,root.subOptionNums
    child.forceVisible=true
    child:setX(parent:getX()); child:setY(parent:getY())
    child:setVisible(false); child:addToUIManager()
    root.instanceMap[child.subOptionNums]=child
    return child
end
function ISContextMenu.get(p,x,y)
    assert(p==f.playerIndex)
    local root=f.menu
    root:clear()
    root.subMenuPool=root.subMenuPool or {}
    for _, panel in ipairs(root.instanceMap or {}) do
        panel:setVisible(false); panel:removeFromUIManager()
        root.subMenuPool[#root.subMenuPool+1]=panel
    end
    root.instanceMap,root.subOptionNums,root.player={},0,p
    root.requestX,root.requestY,root.x,root.y,root.visible=x,y,x,y,true
    return root
end
if LOOTBOX_TEST_LOAD_CONTEXT_MENU then
    ISBaseTimedAction=ISPanel:derive()
    ISBaseTimedAction.new=function(self,player) return setmetatable({character=player},self) end
    ISBaseTimedAction.perform=function()end
    ISBaseTimedAction.beginAddingActions=function()end
    ISBaseTimedAction.endAddingActions=function()end
    ISBaseTimedAction.forceComplete=function(self) self:perform() end
    LOOTBOX_TEST_LOAD_CONTEXT_MENU()
    LOOTBOX_TEST_LOAD_GET_UP()
end
local nativeGet = ISContextMenu.get
ISContextMenu.get=function(...)
    f.gets=f.gets+1
    return nativeGet(...)
end
local function menu() return ISContextMenu:new(0,0,1,1,1.5) end
local function makeSubmenu(parent,name)
    local child=ISContextMenu:getNew(parent)
    parent:addSubMenu(parent:addOption(name),child)
    return child
end
local function makeObj(square, class)
    local o={classes={IsoObject=true},containers={},square=square,name="Crate",
        getSquare=function(self)return self.square end,
        getObjectIndex=function(self)
            for i,v in ipairs(self.square.objects) do if v==self then return i-1 end end; return -1
        end,
        getContainerIndex=function(self,c)
            for i,v in ipairs(self.containers) do if v==c then return i-1 end end; return -1
        end,
        getContainerCount=function(self)return #self.containers end,
        getContainerByIndex=function(self,i)return self.containers[i+1] end}
    if class then o.classes[class]=true end
    square.objects[#square.objects+1]=o
    return o
end
local function container(o, kind)
    local c={classes={ItemContainer=true},kind=kind or "crate",owner=o,
        getParent=function(self)return self.owner end,getType=function(self)return self.kind end,
        getContainingItem=function(self)return self.item end,getVehiclePart=function(self)return self.part end}
    if o and o.containers then o.containers[#o.containers+1]=c end
    return c
end
local function sq()
    return {objects={}, getX=function()return 33 end,getY=function()return 44 end,getZ=function()return 1 end, getObjects=function(self)return hits(self.objects) end,
        getBuilding=function()return "building" end,getRoom=function()end}
end
local function log(name) f.events[#f.events+1]=name end
ISRadioAndTvMenu = {createMenu=function(objects, m, actor)
    assert((m==f.menu or m.parent==f.menu) and actor==f.actor)
    f.radios=objects
    for _,o in ipairs(objects) do m:addOption("Native device",actor,ISRadioAndTvMenu.openTvPanel,o) end
end}
ISRadioAndTvMenu.openTvPanel=function(_,o) f.radio=o end
ISDisassembleMenu = {createMenu=function(objects,m,actor)
    assert((m==f.menu or m.parent==f.menu) and actor==f.actor)
    f.disassembly=objects
    -- Native provider's actual shape: a submenu, actor target, object-bound
    -- descriptor; findOnSquare() is repeated on selection.
    local child=makeSubmenu(m,"Native disassemble")
    for _,o in ipairs(objects) do
        if o~=f.skipTeardown then
        local props={spriteName="furniture_storage_"..tostring(o.spriteNumber or o:getObjectIndex()),
            findOnSquare=function(_,square,name)
                for i=#square.objects,1,-1 do
                    local obj=square.objects[i]
                    if name=="furniture_storage_"..tostring(obj.spriteNumber or obj:getObjectIndex()) then return obj end
                end
            end}
        child:addOption("Native teardown",actor,ISDisassembleMenu.disassemble,{object=o,square=o:getSquare(),moveProps=props})
        end
    end
    if f.fail == "provider" then error("injected provider exception") end
end}
ISDisassembleMenu.disassemble=function(_,entry) f.torn=entry.moveProps:findOnSquare(entry.square,entry.moveProps.spriteName) end
ISVehicleMenu = {FillMenuOutsideVehicle=function(p,m,v) m:addOption("Screen vehicle",v,function()end) end}
function triggerEvent(name,p,m,objects,test)
    assert(p==f.playerIndex and (m==f.menu or m.parent==f.menu) and not test)
    if name=="OnPreFillWorldObjectContextMenu" then
        log("pre"); f.prefill=objects
        if m~=f.menu then f.worldGroup=m end
        if f.collision then f.preForeign=m:addOption("Native device",f.obj[3],function(o)f.foreignTarget=o end) end
    elseif name=="OnFillWorldObjectContextMenu" then
        f.fillCoords={getMouseXScaled(),getMouseYScaled(),getMouseX(),getMouseY()}
        if f.shelf then f.shelf(p,m,objects,test) end
        if f.extraWorld then f.extraWorld(p,m,objects) end
        if f.nestedProbe then f.nestedProbe(p) end
        if f.fail=="subscriber" then error("injected scaled-reader exception") end
        log("fill"); f.fill=objects
        -- Arbitrary provider installed after the adapter was loaded. It knows
        -- nothing about labels, LootBox, panes, storage types or NeatUI.
        local o=objects[1]
        f.modOption=m:addOption(f.action,nil,function(target,p1,p2,p3)
            assert(target==nil and p1=="arg" and p2==nil and p3==7)
            f.last=o
        end,"arg",nil,7)
        if f.modGroups then
            local one=makeSubmenu(m,"Mod group")
            local two=makeSubmenu(one,"Mod subgroup")
            f.deepOption=two:addOption("Closure-bound action",nil,function() f.deepTarget=o end)
            f.deepOption.iconTexture, f.deepOption.toolTip = {icon=true}, {tip=true}
        end
        if f.fakeMouseVehicle then ISVehicleMenu.FillMenuOutsideVehicle(p,m,f.fakeMouseVehicle) end
        if Menus then Menus.worldMenu(p,m,objects,test) end
    else error(name) end
end
local logic = {
    fetch=function(fetch,obj,player,scanSquare)
        f.scanSquare=scanSquare
        local targets = scanSquare and obj:getSquare().objects or {obj}
        for _,v in ipairs(targets)do fetch.c=fetch.c+1; fetch.item=v end
        if scanSquare then fetch.safehouseAllowInteract=true; fetch.safehouseAllowLoot=true end
    end,
    createMenuEntries=function(fetch,m,p,objects,x,y,test)
        log("native"); assert(not test)
        if f.collision then f.providerForeign=m:addOption("Native device",f.obj[3],function(o)f.foreignTarget=o end) end
        m:addOption("Native fixture property", fetch.item, function(o)f.prop=o end)
        if fetch.body then m:addOption("Mouse corpse",fetch.body,function()end) end
        if fetch.safehouseAllowInteract then
            -- The two expanded-input provider calls in 42.22's Java builder.
            local wider=objects[1]:getSquare().objects
            -- LuaManager.getFunctionObject caches both callback closures by
            -- name for Java. Changing the class field does NOT change a hit.
            f.cachedRadio=f.cachedRadio or ISRadioAndTvMenu.createMenu
            f.cachedDisassembly=f.cachedDisassembly or ISDisassembleMenu.createMenu
            f.cachedRadio(wider,m,f.actor)
            f.cachedDisassembly(wider,m,f.actor)
        end
        f.pickX,f.pickY=x,y
    end}
ISWorldObjectContextMenuLogic=logic

ISWorldObjectContextMenu={fetchVars={},fetchSquares={}}
function ISWorldObjectContextMenu.createMenu(p,objects,x,y)
    local m=ISContextMenu.get(p,x,y)
    local w=ISWorldObjectContextMenu
    w.fetchVars={c=0}; w.fetchSquares={}
    for _,o in ipairs(objects) do ISWorldObjectContextMenuLogic.fetch(w.fetchVars,o,p,true) end
    triggerEvent("OnPreFillWorldObjectContextMenu",p,m,objects)
    w.fetchVars.body=IsoObjectPicker.Instance:PickCorpse(x,y)
    ISWorldObjectContextMenuLogic.createMenuEntries(w.fetchVars,m,p,objects,x,y,false)
    if w.fetchVars.safehouseAllowInteract then triggerEvent("OnFillWorldObjectContextMenu",p,m,objects) end
    return m
end
local function element(data)
    log("element"); f.data=data
    assert(data.player==f.actor and (data.context==f.menu or data.context.parent==f.menu))
    for _,obj in ipairs(data.objects) do data.context:addOption("Registered element",obj,function(o)f.element=o end) end
    if f.fail=="element" then error("injected element exception") end
end
ISMenuElement={new=function()
    return { elements={indexIterator=function() return ipairs({{createMenu=element}}) end} }
end}
local function modelWorld()
    local w={getObjectsSquare=function(data,square)
        if not square then return end
        data.squares[#data.squares+1]=square
        for _,v in ipairs(square.objects)do if not data.contains[v] then
            data.contains[v]=true; data.objects[#data.objects+1]=v
        end end
    end}
    function w.createMenu(p,owner,objects,x,y)
        local m=ISWorldObjectContextMenu.createMenu(p,objects,x,y) or ISContextMenu.get(p,x,y)
        local data={playerNum=p,player=f.actor,context=m,object=owner,objects={},contains={},squares={}}
        for _,v in ipairs(objects)do
            w.getObjectsSquare(data,v:getSquare())
            if not data.contains[v] then data.contains[v]=true; data.objects[#data.objects+1]=v end
        end
        w.getObjectsSquare(data,getCell():getGridSquare(x,y,0))
        element(data)
        return m
    end
    return w
end
local originalIcon = function(b)
    local p,c=b.parent.parent.player,b.inventory
    local m=ISContextMenu.get(p,getMouseX(),getMouseY())
    if c:getContainingItem() then return ISInventoryPaneContextMenu.createMenu(p,true,{c:getContainingItem()},getMouseX(),getMouseY()) end
    local t=c:getType()
    if t~="floor" and t~="inventorymale" and t~="inventoryfemale" and not instanceof(c:getParent(),"BaseVehicle")
        and c:getParent() and SafeHouse.isSafehouseAllowInteract(c:getParent():getSquare(),getSpecificPlayer(p)) then
        m:addOption("ContextMenu_RenameBag",c,function(v)f.renamed=v end)
        if f.admin then m:addOption("ContextMenu_RefillContainer",c,function()end) end
    end
end
-- Scratch verifier may substitute *installed* stock high-level entrypoints
-- and NeatUI's headAt(), leaving only JVM objects/widgets simulated.
local realWorldFactory, realHead
if LOOTBOX_TEST_LOAD_STOCK then realWorldFactory, originalIcon, realHead=LOOTBOX_TEST_LOAD_STOCK() end
local function addButton(page,c)
    local b={inventory=c,parent={parent=page},getMouseX=function()return 600 end,getMouseY=function()return -29 end}
    b.onRightMouseDown=function(self,x,y)
        f.icons=f.icons+1; f.activeAtIcon=page.inventoryPane.inventory
        originalIcon(self,x,y)
        -- A cooperatively-added pane submenu must survive as the same objects.
        local m=f.menu; local child=makeSubmenu(m,"Foreign pane group")
        child:addOption("Genuine pane action",c,function(target)f.paneTarget=target end)
        f.foreign, f.foreignChild=option(m,"Foreign pane group"),child
        return "upstream"
    end
    page.backpacks[#page.backpacks+1]=b
    return b
end
local function setup()
    f={allowInteract=true,allowLoot=true,events={},gets=0,icons=0,action="Inspect maker's mark",playerIndex=1}
    f.square,f.behind,f.menu=sq(),sq(),menu()
    f.actor={classes={IsoObject=true,IsoMovingObject=true,IsoPlayer=true},getCurrentSquare=function()return f.square end,
        getSquare=function()return f.square end,getCurrentState=function()return "idle" end,
        isAsleep=function()return f.asleep end,isDead=function()return f.dead end,getZ=function()return 0 end,
        getInventory=function()return {} end}
    f.corpse,f.fakeMouseVehicle=makeObj(f.behind,"IsoMovingObject"),makeObj(f.behind,"BaseVehicle")
    f.page={player=f.playerIndex,onCharacter=false,backpacks={},selectContainer=function(self,b)
        f.focusCalls=(f.focusCalls or 0)+1
        self.inventoryPane.inventory=b.inventory
        if f.poolSwap then f.poolSwap(self,b) end
    end}
    f.pane={player=f.playerIndex,inventoryPage=f.page,headerHgt=10,width=400,scroll=-20,
        getYScroll=function(self)return self.scroll end,
        onRightMouseUp=function(_,x,y) f.pass=(f.pass or 0)+1; return x+y end}
    f.page.inventoryPane=f.pane
    f.obj,f.c,f.b={},{},{}
    for i=1,3 do f.obj[i]=makeObj(f.square); f.c[i]=container(f.obj[i]); f.b[i]=addButton(f.page,f.c[i]) end
    f.pane.inventory=f.c[3]
    f.ground=addButton(f.page,container(f.actor,"floor"))
    f.world=realWorldFactory and realWorldFactory() or modelWorld()
    ISContextManager={getInstance=function()return {getWorldMenu=function()return f.world end,createWorldMenu=f.world.createMenu} end}
    f.heads={}
    for i=1,3 do f.heads[i]={hx0=0,hx1=185,y=30+(i-1)*20,h=18,seg={button=f.b[i],container=f.c[i],title="Crate"}} end
    f.heads[4]={hx0=190,hx1=380,y=30,h=18,seg={button=f.ground,container=f.ground.inventory,title="Ground"}}
    NeatInventory={enabled=true,Views={
        isGrid=function()return true end,multi=function()return true end,combined=function()return f.combined end,
        grid=function()return {layout={heads=f.heads}} end,
        headAt=realHead or function(_,g,x,y)
            for _,h in ipairs(g.layout.heads) do
                if x>=h.hx0 and x<h.hx1 and y>=h.y and y<h.y+h.h then return h end
            end
        end}}
    return f
end
Menus=require "LootBox/Menus"
local function resetGesture()
    f.events={}; f.gets=0; f.icons=0; f.prefill=nil; f.fill=nil; f.last=nil; f.data=nil; f.prop=nil; f.torn=nil; f.renamed=nil
    f.worldGroup=nil
end
local function expectExact(i)
    assert(table.concat(f.events,",")=="pre,native,fill,element","wrong providers/order: "..table.concat(f.events,","))
    assert(f.gets==1 and f.icons==1,"rebuilt singleton or repeated native button")
    assert(f.menu.requestX==getMouseX() and f.menu.requestY==getMouseY(),"wrong popup position")
    local world=assert(submenu(f.menu,"World Actions"))
    local dis=assert(submenu(world,"Native disassemble"))
    assert(world==f.worldGroup and world.parent==f.menu and not world.visible and world.forceVisible)
    assert(dis.parent==world and not dis.visible and dis.forceVisible)
    assert(f.pickX<0 and f.pickY<0 and not option(world,"Mouse corpse") and not option(world,"Screen vehicle"))
    assert(not f.scanSquare and #f.prefill==1 and #f.fill==1 and f.prefill[1]==f.obj[i] and f.fill[1]==f.obj[i])
    assert(#f.radios==3 and #f.disassembly==3) -- real native expansion occurred
    local devices=0; for _,o in ipairs(f.menu.options)do if o.name=="Native device" then devices=devices+1 end end
    assert(devices==1 and not option(world,"Native device") and #dis.options==1,"widened stock options survived")
    assert(f.data.object==f.obj[i] and #f.data.objects==1 and f.data.objects[1]==f.obj[i])
    assert(#f.data.squares==1 and f.data.squares[1]==f.square and f.data.playerNum==f.playerIndex)
    assert(ISWorldObjectContextMenu.fetchVars.safehouseAllowInteract and ISWorldObjectContextMenu.fetchVars.safehouseAllowLoot)
    assert(f.foreign==option(f.menu,"Foreign pane group") and submenu(f.menu,"Foreign pane group")==f.foreignChild)
    assert(#f.menu.options==7 and not option(f.menu,f.action))
    for _,panel in ipairs({f.menu,world,dis}) do
        assert(panel.numOptions==#panel.options+1)
        for index,row in ipairs(panel.options) do assert(row.id==index) end
    end
    assert(option(f.menu,"ContextMenu_RenameBag").target==f.c[i] and option(f.menu,"ContextMenu_RefillContainer").target==f.c[i])
    assert(not f.last and not f.prop and not f.torn, "opening a menu ran actions")
    invoke(world,f.action); invoke(f.menu,"Native fixture property"); invoke(dis,"Native teardown"); invoke(f.menu,"Registered element"); invoke(f.menu,"Native device")
    assert(f.last==f.obj[i] and f.prop==f.obj[i] and f.torn==f.obj[i] and f.element==f.obj[i] and f.radio==f.obj[i])
    assert(Bridge.current(f.playerIndex,f.menu,f.fill)==nil)
end
local passed=0
local function test(name,fn)
    setup(); fn(); passed=passed+1; print("PASS "..name)
end
test("all three same-name stacked fixtures: each icon and header, native and mod actions, same popup; option off keeps previous focus",function()
    f.admin=true; f.focus=false
    Menus.refreshContainers(f.page,"end")
    for i=1,3 do
        resetGesture(); assert(f.b[i]:onRightMouseDown(8,9)=="upstream"); expectExact(i)
        resetGesture(); f.action="Provider option "..i
        assert(f.pane:onRightMouseUp(80,31+(i-1)*20)==true); expectExact(i)
        assert(f.pane.inventory==f.c[3])
    end
end)
test("registered world elements and normal world clicks no longer restricted after a pane click",function()
    f.admin=true; Menus.refreshContainers(f.page,"end"); f.b[1]:onRightMouseDown(1,2); expectExact(1)
    resetGesture(); f.world.createMenu(f.playerIndex,f.obj[1],{f.obj[1]},20,30)
    assert(f.scanSquare and #f.radios==3 and #f.data.objects>3 and option(f.menu,"Screen vehicle") and option(f.menu,"Mouse corpse"))
    assert(f.gets==1 and f.menu.requestX==20 and f.menu.requestY==30)
end)
test("engine provider cache already warm from a ground/world click: each crate still distinct and normal clicks unaffected",function()
    f.admin=true
    f.world.createMenu(f.playerIndex,f.obj[3],{f.obj[3]},30,40)
    assert(#f.disassembly==3 and #f.radios==3 and f.cachedDisassembly==ISDisassembleMenu.createMenu)
    Menus.refreshContainers(f.page,"end")
    for i=1,3 do resetGesture(); f.b[i]:onRightMouseDown(3,4); expectExact(i) end
    resetGesture(); f.world.createMenu(f.playerIndex,f.obj[2],{f.obj[2]},30,40)
    assert(#f.disassembly==3 and #f.radios==3 and #f.data.objects>3)
end)
test("ambiguous stock scrap is disabled, and a sprite replaced after opening cannot redirect a previously available callback",function()
    f.admin=true; Menus.refreshContainers(f.page,"end")
    f.obj[1].spriteNumber=77; f.obj[2].spriteNumber=77
    f.b[1]:onRightMouseDown(1,1)
    local world=submenu(f.menu,"World Actions")
    local dis=submenu(world,"Native disassemble")
    assert(option(dis,"Native teardown").notAvailable==true and #dis.options==1)
    assert(option(world,f.action)==f.modOption and option(f.menu,"ContextMenu_RenameBag").target==f.c[1])
    f.b[2]:onRightMouseDown(1,1)
    local live=option(submenu(submenu(f.menu,"World Actions"),"Native disassemble"),"Native teardown")
    assert(not live.notAvailable)
    f.obj[3].spriteNumber=77; f.torn=nil; live.onSelect(live.target,live.param1); assert(f.torn==nil)
end)
test("same-name foreign entries, callbacks and submenus survive; empty native sibling-only group does not",function()
    Menus.refreshContainers(f.page,"end")
    f.collision=true; f.skipTeardown=f.obj[1]
    f.b[1]:onRightMouseDown(1,2)
    local world=submenu(f.menu,"World Actions")
    local total=0
    for _,o in ipairs(world.options)do if o.name=="Native device" then
        total=total+1
        assert(o==f.preForeign or o==f.providerForeign)
        o.onSelect(o.target); assert(f.foreignTarget==f.obj[3])
    end end
    local bound=option(f.menu,"Native device")
    assert(bound.onSelect==ISRadioAndTvMenu.openTvPanel and bound.param1==f.obj[1])
    assert(total==2 and not option(world,"Native disassemble") and option(world,f.action)==f.modOption)
end)
test("opaque mod callbacks and nested submenus stay bound while pane entries stay on their original path",function()
    f.admin=true; f.modGroups=true; Menus.refreshContainers(f.page,"end")
    f.b[2]:onRightMouseDown(1,1)
    local world=assert(submenu(f.menu,"World Actions"))
    local two=assert(submenu(assert(submenu(world,"Mod group")),"Mod subgroup"))
    local action=option(two,"Closure-bound action")
    assert(action==f.deepOption and action.target==nil and action.iconTexture.icon and action.toolTip.tip)
    assert(not two.visible and two.forceVisible and not option(f.menu,"Mod group"))
    invoke(f.foreignChild,"Genuine pane action"); assert(f.paneTarget==f.c[2])
    invoke(two,"Closure-bound action"); assert(f.deepTarget==f.obj[2])
    expectExact(2)
end)
test("explicit fixture or compartment arguments promote; ambiguous actions and mixed or aliased submenus are not guessed",function()
    local owner, chosen = f.obj[2], f.c[2]
    local sibling=container(owner,"crate")
    local other=f.obj[1]
    local noop=function()end
    local cycle={}; cycle.self=cycle; cycle.alien={{other}}
    local nativeList={classes={ArrayList=true},size=function()return 1 end,get=function()return sibling end}
    f.extraWorld=function(_,m,objects)
        f.explicit=m:addOption("Foreign pane group",chosen,function(v) f.exact=v end)
        f.late=m:addOption("Positional identity",nil,function(_,_,_,_,_,_,_,_,_,_,v) f.lateTarget=v end,
            nil,nil,nil,nil,nil,nil,nil,nil,nil,owner)
        f.late.iconTexture,f.late.toolTip={},{}
        m:addOption("Wrong compartment",owner,noop,nil,sibling)
        m:addOption("Different object",chosen,noop,other)
        m:addOption("Foreign in plain data",owner,noop,cycle)
        m:addOption("Foreign in native list",owner,noop,nativeList)
        m:addOption("Only as context",objects,noop)
        m:addOption("Only as metadata",nil,noop,{clicked=owner})
        local hover=m:addOption("Highlight only",nil,noop)
        hover.onHighlight,hover.onHighlightParams=noop,{owner}
        local preview=makeSubmenu(m,"Highlight group")
        local previewRow=preview:addOption("Preview",owner)
        previewRow.onHighlight,previewRow.onHighlightParams=noop,{owner}
        f.mixed=makeSubmenu(m,"Mixed actions")
        f.mixed:addOption("Explicit",owner,noop)
        f.mixed:addOption("Context",objects,noop)
        f.shared=makeSubmenu(m,"Shared entry")
        f.shared:addOption("Explicit",owner,noop)
        m:addSubMenu(m:addOption("Shared alias"),f.shared)
    end
    Menus.refreshContainers(f.page,"end"); f.pane:onRightMouseUp(110,52)
    local world=assert(submenu(f.menu,"World Actions"))
    assert(f.menu.options[2]==f.foreign and option(f.menu,"Positional identity")==f.late)
    assert(f.explicit.target==chosen and f.late.param10==owner)
    assert(not option(world,"Positional identity") and not option(world,"Foreign pane group"))
    for _, name in ipairs({"Wrong compartment","Different object","Foreign in plain data","Foreign in native list","Only as context",
        "Only as metadata","Highlight only","Highlight group","Mixed actions","Shared entry","Shared alias"}) do
        assert(option(world,name) and not option(f.menu,name),name)
    end
    assert(submenu(world,"Mixed actions")==f.mixed and f.mixed.parent==world)
    assert(submenu(world,"Shared entry")==f.shared and submenu(world,"Shared alias")==f.shared and f.shared.parent==world)
    invoke(f.menu,"Positional identity"); assert(f.lateTarget==owner)
    f.explicit.onSelect(f.explicit.target); assert(f.exact==chosen)
end)
test("pooled button and cooperative wrappers only dispatch once; uses current owner on inventory pane/player",function()
    f.admin=true; f.page.onCharacter=true
    Menus.refreshContainers(f.page,"end")
    local button=f.b[2]; local wrapped=button.onRightMouseDown
    button.onRightMouseDown=function(self,...)f.foreignWrap=(f.foreignWrap or 0)+1; return wrapped(self,...) end
    Menus.refreshContainers(f.page,"end"); Menus.refreshContainers(f.page,"end")
    button.inventory=f.c[1]
    assert(button:onRightMouseDown(5,6)=="upstream"); expectExact(1); assert(f.foreignWrap==1)
end)
test("header hit-test: folded titles, scrolled fixed strip, neighboring Ground column, gaps, stale button and combined view",function()
    f.admin=true; Menus.refreshContainers(f.page,"end"); f.heads[2].seg.folded=true
    assert(f.pane:onRightMouseUp(110,52)==true); expectExact(2)
    resetGesture(); f.pane:onRightMouseUp(220,32); assert(f.icons==1 and #f.events==0 and not option(f.menu,f.action))
    resetGesture(); assert(f.pane:onRightMouseUp(187,32)==219 and f.icons==0) -- gutter
    assert(f.pane:onRightMouseUp(50,69)==119 and f.icons==0) -- row gap
    f.pane.scroll=-40; assert(f.pane:onRightMouseUp(50,32)==82 and f.icons==0)
    f.pane.scroll=-20; f.b[1].inventory=f.c[2]; local passedToItem=f.pass
    assert(f.pane:onRightMouseUp(50,32)==true and f.icons==0 and f.pass==passedToItem)
    f.heads[2].seg.equipped=true; assert(f.pane:onRightMouseUp(50,52)==102 and f.icons==0)
    f.combined=true; assert(f.pane:onRightMouseUp(50,72)==122 and f.icons==0)
end)
test("item-backed, player, vehicle/part, corpse, unattached and replaced fixtures get no substitute world target",function()
    local item={}; local itemC=container(f.actor,"bag"); itemC.item=item
    local bag=addButton(f.page,itemC); local car=container(f.fakeMouseVehicle); car.part={}
    local extra={container(f.actor,"inventorymale"),car,container(f.corpse,"inventoryfemale"),container(f.obj[3],"floor")}
    for _,c in ipairs(extra) do addButton(f.page,c) end
    Menus.refreshContainers(f.page,"end")
    bag:onRightMouseDown(1,1); assert(option(f.menu,"Genuine item menu").target==item and #f.events==0)
    f.heads[1].seg={container=itemC,button=bag}
    f.pane:onRightMouseUp(50,33); assert(option(f.menu,"Genuine item menu").target==item and #f.events==0)
    for i=6,#f.page.backpacks do f.page.backpacks[i]:onRightMouseDown(1,1); assert(#f.events==0) end
    f.obj[1].containers={}; f.b[1]:onRightMouseDown(1,1); assert(#f.events==0)
    table.remove(f.square.objects,2); f.b[2]:onRightMouseDown(1,1); assert(#f.events==0)
end)
test("vanilla with NeatUI disabled, missing APIs or no installed mod keeps native icons and unrelated pane clicks",function()
    local original=f.pane.onRightMouseUp
    NeatInventory=nil; Menus.refreshContainers(f.page,"end")
    assert(f.pane:onRightMouseUp(20,50)==70 and f.icons==0)
    f.admin=true; f.b[2]:onRightMouseDown(1,1); expectExact(2)
    resetGesture(); NeatInventory={enabled=true,Views={headAt=function()error("incomplete")end}}
    Menus.refreshContainers(f.page,"end")
    assert(f.pane:onRightMouseUp(20,50)==70 and f.icons==0)
end)
test("denied, trading, paused, sleeping, dead, tutorial, world map and disabled world menu do not dispatch world hooks",function()
    Menus.refreshContainers(f.page,"end")
    for _,key in ipairs({"allowInteract","allowLoot","pause","asleep","dead","tutorial","map","trading"}) do
        local old=f[key]; f[key]=not old; f.b[1]:onRightMouseDown(2,3); f[key]=old; assert(#f.events==0,key)
    end
    ISWorldObjectContextMenu.disableWorldMenu=true; f.b[1]:onRightMouseDown(2,3); ISWorldObjectContextMenu.disableWorldMenu=nil
    JoypadState.players[f.playerIndex+1]={}; f.b[1]:onRightMouseDown(2,3); JoypadState.players[f.playerIndex+1]=nil
    assert(#f.events==0)
end)
test("provider errors leave existing pane entries and restore every scoped native override",function()
    Menus.refreshContainers(f.page,"end")
    local get,radio,dis,iterate=ISContextMenu.get,ISRadioAndTvMenu.createMenu,ISDisassembleMenu.createMenu,ipairs
    local vehicle,expand=ISVehicleMenu.FillMenuOutsideVehicle,f.world.getObjectsSquare
    local mx,my=getMouseXScaled,getMouseYScaled
    local worldCreate,entryCreate=f.world.createMenu,ISWorldObjectContextMenu.createMenu
    for _,phase in ipairs({"provider","subscriber","element"}) do
        resetGesture(); f.fail=phase; assert(f.b[1]:onRightMouseDown(1,1)=="upstream")
        assert(option(f.menu,"ContextMenu_RenameBag") and option(f.menu,"Foreign pane group"))
        assert(not option(f.menu,"World Actions") and not f.worldGroup.visible)
        for _,panel in ipairs(f.menu.instanceMap) do assert(not panel.visible) end
        assert(ISWorldObjectContextMenuLogic==logic and ISContextMenu.get==get and ISRadioAndTvMenu.createMenu==radio and ipairs==iterate)
        assert(ISDisassembleMenu.createMenu==dis and ISVehicleMenu.FillMenuOutsideVehicle==vehicle and f.world.getObjectsSquare==expand)
        assert(Bridge.current(f.playerIndex,f.menu,f.prefill)==nil)
        assert(getMouseXScaled==mx and getMouseYScaled==my and f.world.createMenu==worldCreate and ISWorldObjectContextMenu.createMenu==entryCreate)
        assert(mx()==1366 and my()==442)
    end
    f.fail=nil; resetGesture(); f.admin=true; f.b[3]:onRightMouseDown(3,2); expectExact(3)
end)
test("an empty world result leaves only the original pane options and the next click can repopulate it",function()
    local ordinary=f.world.createMenu
    f.world.createMenu=function(p,_,_,x,y) return ISContextMenu.get(p,x,y) end
    Menus.refreshContainers(f.page,"end")
    f.b[1]:onRightMouseDown(1,2)
    assert(#f.menu.options==2 and not option(f.menu,"World Actions") and option(f.menu,"ContextMenu_RenameBag"))
    assert(f.menu.instanceMap[2].visible==false)
    f.world.createMenu=ordinary; resetGesture(); f.admin=true
    f.b[3]:onRightMouseDown(2,3); expectExact(3)
end)
test("a build with only exact actions needs no World Actions heading",function()
    f.world.createMenu=function(p,owner,_,x,y)
        local m=ISContextMenu.get(p,x,y)
        f.bound=m:addOption("Only fixture",owner,function(v)f.exact=v end)
        return m
    end
    Menus.refreshContainers(f.page,"end"); f.b[1]:onRightMouseDown(1,2)
    assert(option(f.menu,"Only fixture")==f.bound and not option(f.menu,"World Actions"))
    invoke(f.menu,"Only fixture"); assert(f.exact==f.obj[1])
end)
test("default selects the exact icon or folded title before native and third-party world menus; a repeated click does not reselect",function()
    f.admin=true; Menus.refreshContainers(f.page,"end")
    f.b[1]:onRightMouseDown(1,2); expectExact(1)
    assert(f.activeAtIcon==f.c[1] and f.pane.inventory==f.c[1] and f.focusCalls==1)
    resetGesture(); f.heads[2].seg.folded=true; f.pane:onRightMouseUp(77,52); expectExact(2)
    assert(f.activeAtIcon==f.c[2] and f.pane.inventory==f.c[2] and f.focusCalls==2)
    resetGesture(); f.b[2]:onRightMouseDown(1,2); expectExact(2); assert(f.focusCalls==2)
end)
test("selecting recycles the pressed button onto a sibling; use only the new live widget and its own upstream callback, once",function()
    f.admin=true; Menus.refreshContainers(f.page,"end")
    local old=f.b[1]
    f.poolSwap=function(page,clicked)
        assert(clicked==old)
        old.inventory=f.c[2]; f.b[2].inventory=f.c[1]
        local previous=f.b[2].onRightMouseDown
        f.b[2].onRightMouseDown=function(self,x,y)
            assert(self==f.b[2] and x==600 and y==-29); f.newChain=(f.newChain or 0)+1
            return previous(self,x,y)
        end
        Menus.refreshContainers(page,"end")
    end
    assert(old:onRightMouseDown(1,2)=="upstream"); expectExact(1)
    assert(f.newChain==1 and f.focusCalls==1 and f.activeAtIcon==f.c[1])
end)
test("a nested ordinary stock menu reads the real world pointer then restores the fixture subscriber scope",function()
    local nested={f.obj[3]}; local called=0
    local previous=ISWorldObjectContextMenu.createMenu
    ISWorldObjectContextMenu.createMenu=function(player,objects,...)
        if objects==nested then assert(getMouseXScaled()==1366 and getMouseYScaled()==442); called=called+1; return 121 end
        return previous(player,objects,...)
    end
    f.nestedProbe=function(player)
        assert(getMouseXScaled()<0 and ISWorldObjectContextMenu.createMenu(player,nested,12,14)==121 and getMouseYScaled()<0)
    end
    Menus.refreshContainers(f.page,"end");f.b[1]:onRightMouseDown(2,3)
    assert(called==1 and getMouseXScaled()==1366 and getMouseYScaled()==442)
    ISWorldObjectContextMenu.createMenu=previous
end)
test("a nested same-player world click takes over the shared root without recycling the still-running fixture panel",function()
    f.admin=true; f.modGroups=true
    f.nestedProbe=function(p)
        local abandoned=f.worldGroup
        f.nestedProbe=nil
        f.world.createMenu(p,f.obj[1],{f.obj[1]},41,62)
        assert(f.scanSquare,"nested world click on same physical object must keep its normal full tile scan")
        assert(not abandoned.attached)
        for _,panel in ipairs(f.menu.instanceMap) do assert(panel~=abandoned) end
        assert(option(f.menu,"Screen vehicle") and option(f.menu,"Mouse corpse"))
    end
    Menus.refreshContainers(f.page,"end"); f.b[1]:onRightMouseDown(5,6)
    assert(not option(f.menu,"World Actions") and f.menu.requestX==41 and f.menu.requestY==62)
    assert(not f.worldGroup.visible and not f.worldGroup.attached)
    assert(option(f.menu,f.action) and not option(f.menu,"ContextMenu_RenameBag") and f.gets==2)
    assert(#submenu(f.menu,"Native disassemble").options==3)
    resetGesture(); f.b[2]:onRightMouseDown(1,2); expectExact(2)
end)
test("if an icon disappears during native focus, never open the object that inherited its pooled button",function()
    Menus.refreshContainers(f.page,"end")
    local b=f.b[1]; f.poolSwap=function() b.inventory=f.c[2] end
    assert(b:onRightMouseDown(1,2)==true and f.icons==0 and #f.events==0)
end)

test("scaled vehicle-first picker sees no screen vehicle on a crate, raw popup stays put; normal vehicle menus still pick it",function()
    f.playerIndex=0; f.page.player=0; f.pane.player=0
    local vehicle=f.fakeMouseVehicle; vehicle.getSqlId=function()return 781 end
    IsoObjectPicker.Instance.PickVehicle=function(_,x,y) return x==1366 and y==442 and vehicle or nil end
    local data={bases={}}
    if LOOTBOX_TEST_LOAD_SHELF then
        f.shelf=LOOTBOX_TEST_LOAD_SHELF({getData=function()return data end,L=function(k)return k end,markDirty=function()end})
    else
        f.shelf=function(_,m,objects)
            local picked=IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(),getMouseYScaled())
            if picked then m:addOption("base_register_vehicle",picked,function()end)
            else m:addOption("base_register",nil,function()
                local sq=objects[1]:getSquare(); data.bases[1]={x=sq:getX(),y=sq:getY(),z=sq:getZ()}
            end) end
        end
    end
    for _,on in ipairs({true,false}) do
        f.focus=on; resetGesture(); Menus.refreshContainers(f.page,"end"); f.b[1]:onRightMouseDown(9,10)
        local world=assert(submenu(f.menu,"World Actions"))
        assert(option(world,"base_register") and not option(world,"base_register_vehicle") and not option(f.menu,"base_register"))
        assert(f.fillCoords[1]<0 and f.fillCoords[2]<0 and f.fillCoords[3]==683 and f.fillCoords[4]==221)
        assert(f.menu.requestX==683 and f.menu.requestY==221)
        invoke(world,"base_register")
        assert(#data.bases==1 and data.bases[1].x==33 and data.bases[1].y==44 and data.bases[1].z==1)
        data.bases={}; resetGesture()
        f.world.createMenu(f.playerIndex,f.obj[1],{f.obj[1]},1366,442)
        assert(option(f.menu,"base_register_vehicle") and not option(f.menu,"base_register"))
        assert(f.fillCoords[1]==1366 and f.fillCoords[2]==442 and f.fillCoords[3]==683 and f.fillCoords[4]==221)
    end
end)
if LOOTBOX_TEST_LOAD_PROVIDERS then
    test("installed stock radio, scrap and sprite resolver with cached callbacks on three overlapping identical sprites",function()
        LOOTBOX_TEST_LOAD_PROVIDERS()
        local props={get=function()end,has=function()return false end}
        local sprite={getProperties=function()return props end,getName=function()return "same_crate_sprite" end}
        for _,o in ipairs(f.obj) do
            o.classes.IsoWaveSignal=true
            o.getSprite=function()return sprite end; o.getProperties=function()return props end; o.getModData=function()return {} end
        end
        ISMoveableSpriteProps.fromObject=function(o)
            return {name="Crate",spriteName=sprite:getName(),object=o,findOnSquare=ISMoveableSpriteProps.findOnSquare,
                canScrapObject=function()return {craftValid=true,canScrap=true} end,getInfoPanelDescription=function()return {} end}
        end
        getTexture=function(s)return s end
        Translator={getMoveableDisplayName=function(name)return name end}
        ISToolTip={GetFont=function()return {} end,new=function()return {initialise=function()end,
            setVisible=function()end,setTexture=function()end} end}
        f.world.createMenu(f.playerIndex,f.obj[3],{f.obj[3]},30,40)
        assert(#submenu(f.menu,"ContextMenu_Disassemble").options==3) -- actual cached wide provider
        Menus.refreshContainers(f.page,"end")
        for i=1,3 do
            f.b[i]:onRightMouseDown(1,2)
            local world=assert(submenu(f.menu,"World Actions"))
            local group=assert(submenu(world,"ContextMenu_Disassemble"))
            assert(#group.options==1 and group.parent==world)
            local one=group.options[1]
            assert(one.param1.object==f.obj[i] and one.notAvailable==(i<3))
            local witnessed=0
            for _,o in ipairs(f.menu.options) do if o.onSelect==ISRadioAndTvMenu.openTvPanel then
                witnessed=witnessed+1; assert(o.param1==f.obj[i])
            end end
            assert(witnessed==1)
        end
        f.world.createMenu(f.playerIndex,f.obj[3],{f.obj[3]},30,40)
        assert(#submenu(f.menu,"ContextMenu_Disassemble").options==3)
    end)
end
if LOOTBOX_TEST_LOAD_CONTEXT_MENU then
    test("stock water source shape promotes its Wash/Drink/Fill subtree and keeps native seated dispatch",function()
        f.single=true; f.seated=true
        f.actor.isSitting=function()return f.seated end
        f.actor.setVariable=function(_,name,value) assert(name=="forceGetUp" and value); f.getUp=true end
        f.actor.getTimedActionToRetrigger=function()end
        f.actor.setTimedActionToRetrigger=function()end
        local queue={}
        ISTimedActionQueue={add=function(action) queue[#queue+1]=action end}
        luautils={walkAdjObject=function(actor,object) return actor==f.actor and object==f.obj[2] end}
        ISWashYourself={new=function(_,actor,object) return {actor=actor,object=object,wash=true} end}
        f.extraWorld=function(_,m,objects)
            -- Installed 42.22.2 Java doWashClothingOrYourselfMenu and leaf builders:
            -- a neutral source heading and Wash/Fill headings, plus an explicit
            -- source as a forwarded action argument on each usable leaf.
            local obj=objects[1]
            local source=makeSubmenu(m,"Water source")
            f.oldSource=source
            f.sourceHeading=option(m,"Water source")
            local wash=makeSubmenu(source,"Wash")
            f.oldWash=wash
            f.wash=wash:addGetUpOption("Yourself",f.actor,ISWorldObjectContextMenu.onWashYourself,obj,{})
            source:addGetUpOption("Drink",objects,function()end,obj,f.playerIndex)
            if f.noBottle then
                source:addOption("Fill",objects).notAvailable=true
            else
                local fill=makeSubmenu(source,"Fill")
                fill:addGetUpOption("Fill All",objects,function()end,obj,{},nil,f.playerIndex)
            end
            f.direct=m:addGetUpOption("Fixture action",f.actor,ISWorldObjectContextMenu.onWashYourself,obj,{})
        end
        local function check()
            local source=assert(submenu(f.menu,"Water source"))
            local wash=assert(submenu(source,"Wash"))
            assert(source==f.oldSource and source.parent==f.menu and not source.visible)
            assert(option(f.menu,"Water source")==f.sourceHeading and not option(submenu(f.menu,"World Actions"),"Water source"))
            assert(source.subOptionNums==f.sourceHeading.subOption and wash==f.oldWash and wash.parent==source)
            assert(f.wash==option(wash,"Yourself") and f.wash.param3==f.obj[2] and f.wash.target==wash)
            assert(option(f.menu,"Fixture action")==f.direct and f.direct.target==f.worldGroup)
            return source,wash
        end
        Menus.refreshContainers(f.page,"end")
        f.b[2]:onRightMouseDown(4,5); check()
        f.noBottle=true
        f.b[2]:onRightMouseDown(4,5)
        local source,wash=check()
        assert(option(source,"Fill").notAvailable and not submenu(source,"Fill"))
        f.menu:displaySubMenu(source,f.sourceHeading)
        source:displaySubMenu(wash,option(source,"Wash"))
        assert(wash:getDefaultOptionCount()==2 and wash.options[1].param1==f.menu and wash.options[2].param1==source)
        wash.mouseOver=f.wash.id; wash:onMouseUp(1,wash:getItemY(wash.mouseOver)-wash:getY()+1)
        assert(#queue==1 and queue[1].character==f.actor and not f.menu.visible)
        queue[1]:start(); assert(f.getUp and #queue==1)
        f.seated=false; queue[1]:update()
        assert(#queue==2 and queue[2].wash and queue[2].actor==f.actor and queue[2].object==f.obj[2])
    end)
    test("installed single-menu navigation enters World Actions and shows correct back paths through mod submenus",function()
        f.single=true; f.modGroups=true; Menus.refreshContainers(f.page,"end")
        f.b[3]:onRightMouseDown(4,5)
        local group=option(f.menu,"World Actions")
        local world=f.menu:getSubMenu(group.subOption)
        f.menu:displaySubMenu(world,group)
        assert(world.visible and not f.menu.visible and world:getDefaultOptionCount()==1 and world.options[1].param1==f.menu)
        local modGroup=option(world,"Mod group")
        local one=world:getSubMenu(modGroup.subOption)
        world:displaySubMenu(one,modGroup)
        local nested=option(one,"Mod subgroup")
        local two=one:getSubMenu(nested.subOption)
        one:displaySubMenu(two,nested)
        assert(two:getDefaultOptionCount()==3)
        assert(two.options[1].param1==f.menu and two.options[2].param1==world and two.options[3].param1==one)
        two.mouseOver=option(two,"Closure-bound action").id
        two:onMouseUp(1,two:getItemY(two.mouseOver)-two:getY()+1)
        assert(f.deepTarget==f.obj[3] and not two.visible and not one.visible and not world.visible and not f.menu.visible)
    end)
end
print(tostring(passed).." exact container-context integration cases passed; JVM boundaries simulated")
