package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;' .. package.path
package.loaded.keyBinding = true
Keyboard = {KEY_HOME=199, KEY_END=207, KEY_PRIOR=201, KEY_NEXT=209}
local codes = {LootBoxScrollTop=199, LootBoxScrollBottom=207, LootBoxScrollPageUp=201, LootBoxScrollPageDown=209}
local textEntry, modal, context, dead, joypad, eaten = false, false, false, false, -1, nil
local core = {isDoingTextEntry=function() return textEntry end, isKey=function(_,name,key) return codes[name] ~= 0 and codes[name] == key end}
function getCore() return core end
UIManager = {isModalVisible=function() return modal end}
ISMouseDrag = {}
GameKeyboard = {eatKeyPress=function(key) eaten=key end}
local player={isDead=function() return dead end,getJoypadBind=function() return joypad end}
function getSpecificPlayer() return player end
function getPlayerContextMenu() return {isAnyVisible=function() return context end} end
local function pane(over)
 local p={over=over,visible=true,itemHgt=20,height=115,total=1000,y=0,selected={sentinel=true}}
 function p:isVisible() return self.visible end
 function p:isMouseOver() return self.over end
 function p:getScrollAreaHeight() return self.height end
 function p:getScrollHeight() return self.total end
 function p:getYScroll() return self.y end
 function p:setYScroll(y) self.y=y end
 return p
end
local inventory,loot=pane(true),pane(false)
local ip={visible=true,inventoryPane=inventory,isVisible=function(self) return self.visible end}
local lp={visible=true,inventoryPane=loot,isVisible=function(self) return self.visible end}
function getPlayerInventory() return ip end
function getPlayerLoot() return lp end
local callbacks={}
Events={OnKeyStartPressed={Add=function(f) callbacks[#callbacks+1]=f end}}
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
print(count..' inventory navigation cases passed (native UI/input boundaries doubled)')
