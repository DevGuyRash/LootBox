package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;' .. package.path
package.loaded.keyBinding = true
Keyboard = {KEY_HOME=199, KEY_END=207, KEY_PRIOR=201, KEY_NEXT=209, KEY_LSHIFT=42, KEY_RSHIFT=54}
local codes = {LootBoxScrollTop=199, LootBoxScrollBottom=207, LootBoxScrollPageUp=201, LootBoxScrollPageDown=209}
local textEntry, modal, context, dead, joypad, eaten = false, false, false, false, -1, nil
local mouseX,mouseY=35,53
function getMouseX() return mouseX end
function getMouseY() return mouseY end
local highlighted
Key={setHighlightDoors=function(_,item) highlighted=item end}
local core = {isDoingTextEntry=function() return textEntry end, isKey=function(_,name,key) return codes[name] ~= 0 and codes[name] == key end}
function getCore() return core end
UIManager = {isModalVisible=function() return modal end}
ISMouseDrag = {}
GameKeyboard = {eatKeyPress=function(key) eaten=key end}
local player={isDead=function() return dead end,getJoypadBind=function() return joypad end}
function getSpecificPlayer() return player end
function getPlayerContextMenu() return {isAnyVisible=function() return context end} end
local function pane(over)
 local p={over=over,visible=true,itemHgt=20,height=115,total=1000,y=0,selected={sentinel=true},
  player=0,parent={onCharacter=over},inventory={},mouseOverOption=0}
 function p:isVisible() return self.visible end
 function p:isMouseOver() return self.over end
 function p:getScrollAreaHeight() return self.height end
 function p:getScrollHeight() return self.total end
 function p:getYScroll() return self.y end
 function p:setYScroll(y) self.y=y end
 function p:hideButtons() self.buttons=false end
 function p:onMouseMove() self.mouseOverOption=math.floor((getMouseY()-self.y-20)/self.itemHgt)+1 end
 function p:updateTooltip()
  if not self.grid then self:onMouseMove(0,0) end
  local row=self.doController and self.joyselection+1 or self.mouseOverOption
  if not self.over or row<1 then return end
  local tip=self.toolRender or {isVisible=function(t) return t.visible end,
   setVisible=function(t,v) t.visible=v end,removeFromUIManager=function(t) t.attached=false end}
  self.toolRender=tip;tip.visible=true;tip.attached=true;tip.item=row
  if self.parent.onCharacter then highlighted=row end
 end
 function p:onMouseDown(...) self.clicked=self.mouseOverOption;return 'left',... end
 function p:onRightMouseUp(...) self.rightClicked=self.mouseOverOption;return 'right',... end
 function p:onMouseWheel(del) self.wheel=del;return true end
 return p
end
local inventory,loot=pane(true),pane(false)
local ip={visible=true,inventoryPane=inventory,isVisible=function(self) return self.visible end}
local lp={visible=true,inventoryPane=loot,isVisible=function(self) return self.visible end}
function getPlayerInventory() return ip end
function getPlayerLoot() return lp end
local callbacks={}
local onGameStart
Events={OnKeyStartPressed={Add=function(f) callbacks[#callbacks+1]=f end,
 Remove=function(f) for i,v in ipairs(callbacks) do if v==f then table.remove(callbacks,i);return end end end},
 OnGameStart={Add=function(f) onGameStart=f end}}
keyBinding={{value='[LootBox]'},{value='LootBoxScrollTop',key=55}}
local N=require 'LootBox/Navigation'
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end

test('registration preserves existing bindings and is idempotent',function()
 N.install();N.install();assert(#callbacks==1 and #keyBinding==5 and keyBinding[2].key==55)
 assert(keyBinding[3].key==207 and keyBinding[4].key==201 and keyBinding[5].key==209)
end)
test('Home and End use native scroll area without changing selection',function()
 local selected=inventory.selected
 assert(N.onKeyStartPressed(207));assert(inventory.y==-885 and loot.y==0 and eaten==207)
 assert(N.onKeyStartPressed(199));assert(inventory.y==0 and inventory.selected==selected)
end)
test('PageDown and PageUp keep a row overlap even with partial visible rows',function()
 assert(N.onKeyStartPressed(209));assert(inventory.y==-80)
 assert(N.onKeyStartPressed(201));assert(inventory.y==0)
end)
test('only the currently hovered loot pane moves',function()
 inventory.over=false;loot.over=true;assert(N.onKeyStartPressed(209));assert(loot.y==-80 and inventory.y==0)
 loot.over=false;inventory.over=true
end)
test('live rebound and unbound keys respected',function()
 codes.LootBoxScrollBottom=99;eaten=nil;assert(not N.onKeyStartPressed(207) and eaten==nil)
 assert(N.onKeyStartPressed(99) and inventory.y==-885)
 codes.LootBoxScrollBottom=0;assert(not N.onKeyStartPressed(99));codes.LootBoxScrollBottom=207
end)
test('no movement outside inventory or on ambiguous overlap',function()
 inventory.over=false;assert(not N.onKeyStartPressed(199));inventory.over=true;loot.over=true
 assert(not N.onKeyStartPressed(199));loot.over=false
end)
test('hidden and collapsed pages are untouched',function()
 ip.visible=false;assert(not N.onKeyStartPressed(199));ip.visible=true
 ip.isCollapsed=true;assert(not N.onKeyStartPressed(199));ip.isCollapsed=false
 inventory.visible=false;assert(not N.onKeyStartPressed(199));inventory.visible=true
end)
test('text input modal context menu dragging death and gamepad retain their keys',function()
 local y=inventory.y;eaten=nil
 textEntry=true;assert(not N.onKeyStartPressed(199));textEntry=false
 modal=true;assert(not N.onKeyStartPressed(199));modal=false
 context=true;assert(not N.onKeyStartPressed(199));context=false
 ISMouseDrag.dragging={};assert(not N.onKeyStartPressed(199));ISMouseDrag.dragging=nil
 dead=true;assert(not N.onKeyStartPressed(199));dead=false
 joypad=0;assert(not N.onKeyStartPressed(199));joypad=-1
 local old=player;player=nil;assert(not N.onKeyStartPressed(199));player=old
 assert(eaten==nil and inventory.y==y)
end)
test('duplicate custom mappings are rejected rather than choosing a direction',function()
 codes.LootBoxScrollTop=209;assert(not N.onKeyStartPressed(209));codes.LootBoxScrollTop=199
end)
test('pending mousewheel target is the navigation origin and old animation is retired',function()
 inventory.y=-20;inventory.smoothScrollY=-20;inventory.smoothScrollTargetY=-100
 assert(N.onKeyStartPressed(209));assert(inventory.y==-180)
 assert(inventory.smoothScrollY==nil and inventory.smoothScrollTargetY==nil)
end)
test('repeated page movement reaches both ends without skipping any viewport interval',function()
 for _,height in ipairs({1,10,20,39,40,95,100,115,120}) do
  local p=pane(true);p.height=height
  for _=1,1500 do
   local old=p.y;N.scroll(p,'down');assert(old-p.y<=height and p.y<=old)
   if height>p.itemHgt then assert(height-(old-p.y)>=p.itemHgt) end
   if p.y==-(p.total-height) then break end
   assert(p.y<old)
  end
  assert(p.y==-(p.total-height));N.scroll(p,'down');assert(p.y==-(p.total-height))
  for _=1,1500 do
   local old=p.y;N.scroll(p,'up');assert(p.y-old<=height and p.y>=old)
   if p.y==0 then break end
  end
  assert(p.y==0)
 end
end)
test('non-aligned scrolling retains a full native row when viewport permits',function()
 local p=pane(true);p.y=-7;local old=p.y;N.scroll(p,'down')
 assert(p.height-(old-p.y)>=p.itemHgt)
end)
test('short and empty contents clamp safely; resize clamps stale offsets',function()
 local p=pane(true);p.total=0;assert(N.scroll(p,'bottom') and p.y==0)
 p.total=50;p.y=-900;assert(N.scroll(p,'down') and p.y==0)
 p.total=200;p.y=-900;assert(N.scroll(p,'bottom') and p.y==-85)
end)
test('malformed geometry and unknown actions cause no mutation',function()
 local p=pane(true);p.height=0;assert(not N.scroll(p,'down'));p.height=100
 p.itemHgt=0;assert(not N.scroll(p,'down'));p.itemHgt=20
 p.total=0/0;assert(not N.scroll(p,'down'));p.total=1000
 assert(not N.scroll(p,'other') and p.y==0)
end)
test('stationary pointer never opens a row after End or repeated Home; movement restores hover',function()
 local p=inventory
 p:updateTooltip();assert(p.toolRender.visible and p.toolRender.attached)
 local selected=p.selected
 for _,key in ipairs({207,199,199}) do
  assert(N.onKeyStartPressed(key))
  assert(p.y==(key==207 and -885 or 0) and p.selected==selected and not p.toolRender.visible)
  for _=1,4 do p:onMouseMove(0,0);p:updateTooltip() end
  assert(p.mouseOverOption==0 and not p.toolRender.attached and highlighted==nil)
 end
 mouseX=mouseX+1;p:onMouseMove(1,0);p:updateTooltip()
 assert(p.mouseOverOption==2 and p.toolRender.item==2 and p.toolRender.visible)
end)
test('unmoved clicks target the newly visible row; page and wheel keep native hover',function()
 local p=inventory;p.grid=true
 for _,entry in ipairs({{207,'onMouseDown','left',46},{199,'onRightMouseUp','right',2}}) do
  assert(N.onKeyStartPressed(entry[1]));local which,arg=p[entry[2]](p,123)
  assert(which==entry[3] and arg==123 and p.mouseOverOption==entry[4])
  p:updateTooltip();assert(p.toolRender.visible and p.toolRender.item==entry[4])
 end
 N.onKeyStartPressed(199);assert(p:onMouseWheel(-1) and p.wheel==-1)
 p:updateTooltip();assert(p.toolRender.visible)
 N.onKeyStartPressed(199);N.onKeyStartPressed(209);p:updateTooltip()
 assert(p.y==-80 and p.toolRender.visible and p.toolRender.item==6);p.grid=nil
end)
test('NeatUI receives unclaimed controls, not consumed endpoints that would select and show a keyboard tooltip',function()
 local calls=0;local keys={}
 function keys.leaveKeyMode(p) p.ninvKeyMode=false;p.doController=false end
 function keys.onKeyStartPressed(key)
  calls=calls+1
  if NeatInventory.Settings and NeatInventory.Settings.panel then return end
  if NeatInventory.Category and NeatInventory.Category.popup then return end
  if key==199 or key==207 then
   inventory.ninvKeyMode=true;inventory.doController=true;inventory.joyselection=49
   inventory.selected={fromNeat=true}
  end
 end
 NeatInventory={Keys=keys}
 Events.OnKeyStartPressed.Add(keys.onKeyStartPressed);assert(onGameStart);onGameStart();onGameStart()
 local function press(key) for _,f in ipairs(callbacks) do f(key) end end
 inventory.ninvKeyMode=true;inventory.doController=true
 local old=inventory.selected
 press(207);inventory:updateTooltip()
 assert(calls==0 and inventory.y==-885 and inventory.selected==old and not inventory.doController)
 assert(not inventory.toolRender.visible)
 press(199);assert(calls==0 and inventory.y==0)
 press(200);press(209);assert(calls==2)
 codes.LootBoxScrollBottom=99;press(207);assert(calls==3 and inventory.selected.fromNeat)
 old=inventory.selected;press(99);assert(calls==3 and inventory.y==-885 and inventory.selected==old)
 inventory.over=false;press(199);assert(calls==4)
 inventory.over=true;keys.leaveKeyMode(inventory);codes.LootBoxScrollBottom=207
 local stopped,held
 NeatInventory.Shared={Repeat={stop=function(k) if k==held then held=nil;stopped=k end end}}
 press(200);held=200;press(Keyboard.KEY_LSHIFT);press(207)
 assert(held==nil and stopped==200 and inventory.y==-885)
 NeatInventory.Settings={panel={}};press(199);assert(inventory.y==-885);NeatInventory.Settings.panel=nil
 NeatInventory.Category={popup={}};press(199);assert(inventory.y==-885);NeatInventory.Category.popup=nil
end)
test('Home still suppresses hover when a late inventory callback enables keyboard cursor',function()
 local p=inventory;p.y=-240;p.over=true;p.doController=false;p.ninvKeyMode=false
 assert(N.onKeyStartPressed(199));assert(p.y==0)
 p.ninvKeyMode=true;p.doController=true;p.joyselection=0
 p:updateTooltip()
 assert(p.mouseOverOption==0 and not p.toolRender.visible and not p.doController)
 joypad=0;p.doController=true;p:updateTooltip();assert(p.toolRender.visible)
 joypad=-1;p.doController=false
end)
test('Home and End also work over the provider inventory chrome, not a foreign page',function()
 NeatInventory.Keys.hoveredPage=function() return ip end
 inventory.over=false;loot.over=false;inventory.y=-50
 assert(N.onKeyStartPressed(199) and inventory.y==0)
 assert(N.onKeyStartPressed(207) and inventory.y==-885)
 NeatInventory.Keys.hoveredPage=function() return {} end
 assert(not N.onKeyStartPressed(199) and inventory.y==-885)
 NeatInventory.Keys.hoveredPage=nil;inventory.over=true
end)
print(count..' inventory navigation cases passed (native UI/input boundaries doubled)')
