package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;' .. package.path
-- Real controller; native action and Java item/stat boundaries are doubles.
local now, count = 0, 0
function getTimestampMs() return now end
CharacterStat = { HUNGER = {getMinimumValue=function() return 0 end}, THIRST = {getMinimumValue=function() return 0 end} }
function instanceof(item, name) return name == 'Food' and item.food end
local created
package.loaded['LootBox/TillFullNative'] = {new=function()
 local n = {busy=false, calls={}, opens={}}
 function n:isBusy() return self.busy end
 function n:begin(item, kind, portion, target, sampler)
  self.busy=true; self.calls[#self.calls+1]={item=item,kind=kind,portion=portion}; self.target=target;self.sampler=sampler
  if self.refuse then return nil,'refused after preparation' end
  return true
 end
 function n:beginOpen(item,kind,recipe,target,source)
  self.busy=true;self.opening=true;self.opens[#self.opens+1]={item=item,kind=kind,recipe=recipe,source=source};self.target=target
  if self.refuse then return nil,'opening refused after preparation' end
  return true
 end
 function n:poll()
  if self.pending then return nil end
  self.busy=false
  if self.opening then self.opening=false;return self.result ~= false,self.reason or 'opened',self.opened end
  return self.result ~= false,self.reason,nil,self.receipt
 end
 function n:cancel() self.result=false end
 created=n; return n
end}
local Full=require 'LootBox/TillFull'
local inventory={}
local function player(h,t)
 local p={h=h,t=t}
 function p:getStats() return {get=function(_,k) return k==CharacterStat.HUNGER and p.h or p.t end} end
 function p:getInventory() return inventory end
 function p:isDead() return self.dead end
 function p:isAsleep() return false end
 return p
end
local function food(id,relief,base)
 local f={food=true,id=id,h=relief,t=0,base=base or relief,source=inventory}
 function f:getID() return self.id end
 function f:getFullType() return 'Base.Food' end
 function f:getContainer() return self.source end
 function f:isSealed() return self.sealed end
 function f:getOpeningRecipe() return 'metadata-on-unsealed' end
 function f:getHungerChange() return -self.h end
 function f:getThirstChange() return -self.t end
 function f:getHungChange() return -self.h end
 function f:getBaseHunger() return -self.base end
 function f:getScriptItem() return {isCantEat=function() return f.cantEat or false end} end
 for _,name in ipairs({'isRotten','isBurnt','isFrozen','isTainted','isPoison','isAlcoholic','isbDangerousUncooked'}) do f[name]=function(self) return self.unsafe or false end end
 function f:getPoisonPower() return 0 end
 function f:getFoodSicknessChange() return 0 end
 return f
end
local world={protected=function(_,f,options) return f.protected or (f.favorite and not (options and options.allowFavorite))
    or (f.equipped and not (options and options.allowEquippedConsumption)) end}
local function test(name,fn) fn(); count=count+1; print('ok '..name) end
local function close(a,b) assert(math.abs(a-b)<1e-9,tostring(a)..' ~= '..tostring(b)) end

test('portion follows native Eat or Drink intent, with explicit both override',function()
 close(Full.portion(.1,.3,.2,.2,false,'food'),.5)
 close(Full.portion(.1,.3,.2,.2,false,'fluid'),1)
 close(Full.portion(.1,.3,.2,.2,true,'food'),1)
 assert(Full.portion(0,.3,.2,.2,false,'food')==0)
 assert(Full.portion(0,.3,.2,.2,false,'fluid')==1)
 close(Full.portion(.1,0,.2,-.1,false,'food'),.5)
 assert(Full.portion(1,1,0,.2,false,'food')==nil)
 assert(Full.portion(1,1,.2,0,false,'fluid')==nil)
 assert(Full.portion(1,1,0/0,1,false,'food')==nil)
end)
test('partly eaten uses original base units',function()
 local c=assert(Full.new(player(.1,0),world,{food(1,.2,.4)},'food')); c:tick()
 close(created.calls[1].portion,.25)
end)
test('snapshot duplicate identity and stack exhaustion',function()
 local p=player(.5,0); local a,b,outside=food(1,.2),food(2,.2),food(3,.5)
 local c=assert(Full.new(p,world,{a,a,b},'food')); c:tick(); assert(#c.records==2)
 a.source=nil; p.h=.3; c:tick(); assert(#created.calls==2 and created.calls[2].item==b)
 b.source=nil; p.h=.1; c:tick(); assert(c.state=='finished' and c.records==nil and #created.calls==2)
 assert(outside.source==inventory)
end)
test('no observed progress stops boundedly',function()
 local c=assert(Full.new(player(.5,0),world,{food(1,.2)},'food')); c:tick(); c:tick()
 assert(c:isBusy()); now=now+2001; c:tick(); assert(c.state=='failed' and #created.calls==1)
end)
test('manual native interruption never continues',function()
 local c=assert(Full.new(player(.5,0),world,{food(1,.2),food(2,.2)},'food')); c:tick()
 created.result=false; c:tick(); assert(c.state=='cancelled' and #created.calls==1)
end)
test('explicit cancel waits native cleanup',function()
 local c=assert(Full.new(player(.5,0),world,{food(1,.2)},'food')); c:tick()
 created.pending=true; c:cancel(); c:tick(); assert(c:isBusy())
 created.pending=false; c:tick(); assert(not c:isBusy() and c.records==nil)
end)
test('native refusal cleanup remains owned',function()
 local c=assert(Full.new(player(.5,0),world,{food(1,.2)},'food')); created.refuse=true; created.pending=true
 c:tick(); assert(c.state=='cancelling'); c:tick(); assert(c:isBusy())
 created.pending=false; c:tick(); assert(c.state=='cancelled')
end)
test('target observation requests native stop',function()
 local p=player(.5,.5); local f=food(1,.2); f.t=.2
 local c=assert(Full.new(p,world,{f},'food',false)); c:tick(); p.h=0
 assert(created.target()); c:tick(); assert(c.state=='finished' and #created.calls==1)
end)
test('both needs waits for both',function()
 local p=player(.5,.5); local f=food(1,.2); f.t=.2
 local c=assert(Full.new(p,world,{f},'food',true)); c:tick(); p.h=0
 assert(not created.target()); p.t=0; assert(created.target())
end)
test('negative native hunger minimum does not cause stuffing',function()
 CharacterStat.HUNGER.getMinimumValue=function() return -1 end
 local c=assert(Full.new(player(0,.5),world,{food(1,.2)},'food')); c:tick()
 assert(c.state=='finished' and #created.calls==0)
 CharacterStat.HUNGER.getMinimumValue=function() return 0 end
end)
test('already satisfied queues nothing',function()
 local c=assert(Full.new(player(0,1),world,{food(1,.2)},'food')); c:tick()
 assert(c.state=='finished' and #created.calls==0)
end)
test('protected unsafe moved and sealed fail before dispatch',function()
 for _,mode in ipairs({'protected','unsafe','sealed','moved'}) do
  local f=food(1,.2); local c=assert(Full.new(player(.5,0),world,{f},'food'))
  if mode=='moved' then f.source={} else f[mode]=true end
  c:tick(); assert(c.state=='cancelled' and #created.calls==0,mode)
 end
end)
test('protection changed mid action stops continuation',function()
 local f=food(1,.2); local c=assert(Full.new(player(.5,0),world,{f},'food')); c:tick(); f.protected=true
 assert(created.target()); c:tick(); assert(c.state=='cancelled')
end)
test('invalid stats fail closed',function()
 local c=assert(Full.new(player(0/0,0),world,{food(1,.2)},'food')); c:tick()
 assert(c.state=='failed' and #created.calls==0)
end)
FluidCategory={Beverage='beverage',Water='water',Hazardous='hazard',Alcoholic='alcohol'}
local function bottle(id,relief)
 local f=food(id,0); f.food=false
 local properties={getPoison=function() return 0 end,getAlcohol=function() return 0 end,getFoodSicknessChange=function() return 0 end,
  getHungerChange=function() return 0 end,getThirstChange=function() return -relief end}
 local part={getProperties=function() return properties end,isCategory=function(_,c) return c=='water' end,isPoisonous=function() return false end}
 local fluid={empty=false,releases=0,ratio=1}
 function fluid:getProperties() return properties end
 function fluid:getFilledRatio() return self.empty and 0 or self.ratio end
 function fluid:isEmpty() return self.empty end
 function fluid:canPlayerEmpty() return true end
 function fluid:isPoisonous() return self.poison end
 function fluid:isTainted() return false end
 function fluid:getCapacity() return 1 end
 function fluid:createFluidSample() return {size=function() return 1 end,getPercentage=function() return 1 end,
  getFluid=function() return part end,release=function() fluid.releases=fluid.releases+1 end} end
 function f:getFluidContainer() return fluid end
 return f,fluid
end
test('fluid stack advances empty containers and does not adopt others',function()
 local p=player(0,.5); local a,fa=bottle(1,.2); local b,fb=bottle(2,.5)
 local c=assert(Full.new(p,world,{a,b},'fluid')); c:tick(); assert(created.calls[1].kind=='fluid')
 close(created.calls[1].portion,1); p.t=.3; fa.empty=true; c:tick()
 assert(created.calls[2].item==b); close(created.calls[2].portion,.6)
 assert(fa.releases>=1 and fb.releases>=1)
 p.t=0; assert(created.target()); c:tick(); assert(c.state=='finished')
end)
test('unsafe fluid does not dispatch',function()
 local a,fluid=bottle(1,.2); fluid.poison=true
 local c=assert(Full.new(player(0,.5),world,{a},'fluid')); c:tick()
 assert(c.state=='cancelled' and #created.calls==0)
end)
test('fluid becoming unsafe during action stops owned consumption',function()
 local a,fluid=bottle(1,.2); local c=assert(Full.new(player(0,.5),world,{a},'fluid')); c:tick()
 fluid.poison=true; assert(created.target()); c:tick(); assert(c.state=='cancelled')
end)
test('required adjunct food rejected before native preparation',function()
 local a=food(1,.2); function a:getRequireInHandOrInventory() return {size=function() return 1 end} end
 local c=assert(Full.new(player(.5,0),world,{a},'food')); c:tick()
 assert(c.state=='cancelled' and #created.calls==0)
end)
test('changed item identity during action stops',function()
 local a=food(1,.2); local c=assert(Full.new(player(.5,0),world,{a},'food')); c:tick()
 a.id=2; assert(created.target()); c:tick(); assert(c.state=='cancelled')
end)
test('oversized vessel and malformed selection fail safely',function()
 local a,fluid=bottle(1,.2); function fluid:getCapacity() return 4 end
 local c=assert(Full.new(player(0,.5),world,{a},'fluid')); c:tick()
 assert(c.state=='cancelled' and #created.calls==0)
 assert(Full.new(player(1,1),world,{},'food')==nil)
 assert(Full.new(player(1,1),world,{false},'food')==nil)
end)
test('explicit favorite stack consumption and live favorite flag are allowed',function()
 local p=player(.5,0); local a,b=food(1,.2),food(2,.2); a.favorite=true; b.favorite=true
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 assert(#created.calls==1 and not created.target())
 a.source=nil; p.h=.3; c:tick(); assert(#created.calls==2 and created.calls[2].item==b)
 assert(not created.target()); b.protected=true; assert(created.target())
 c:tick(); assert(c.state=='cancelled')
end)
test('explicit equipped fluid stack consumption keeps flags and remains cancellable',function()
 local p=player(0,.5); local a,fa=bottle(1,.2); local b,fb=bottle(2,.5)
 a.equipped=true; a.favorite=true; b.equipped=true
 local c=assert(Full.new(p,world,{a,b},'fluid')); c:tick()
 assert(#created.calls==1 and not created.target())
 fa.empty=true; p.t=.3; c:tick(); assert(#created.calls==2 and created.calls[2].item==b)
 assert(a.equipped and a.favorite and b.equipped)
 b.protected=true; assert(created.target()); c:tick(); assert(c.state=='cancelled')
 assert(a.equipped and b.equipped)
 local f=food(3,.2); f.equipped=true
 local foodJob=assert(Full.new(player(.5,0),world,{f},'food')); foodJob:tick()
 assert(foodJob:isBusy() and #created.calls==1 and not created.target())
 foodJob:cancel(); foodJob:tick(); assert(foodJob.state=='cancelled' and f.equipped)
end)
test('hydrating food continues to hunger target after thirst is satisfied',function()
 local p=player(.4,.01); local f=food(1,.5); f.t=.5
 local c=assert(Full.new(p,world,{f},'food')); c:tick(); close(created.calls[1].portion,.8)
 p.t=0; assert(not created.target()); p.h=0; assert(created.target())
end)
test('milk drinking targets thirst even with hunger already satisfied',function()
 local p=player(0,.3); local f,fluid=bottle(1,.5)
 function fluid:getProperties() return {getPoison=function() return 0 end,getAlcohol=function() return 0 end,
  getFoodSicknessChange=function() return 0 end,getHungerChange=function() return -.5 end,getThirstChange=function() return -.5 end} end
 local c=assert(Full.new(p,world,{f},'fluid')); c:tick(); close(created.calls[1].portion,.6)
 assert(not created.target()); p.t=0; assert(created.target()); c:tick(); assert(c.state=='finished')
end)
test('secondary-only improvement cannot continue a default drink job',function()
 local p=player(.5,.5); local f,fluid=bottle(1,.5)
 function fluid:getProperties() return {getPoison=function() return 0 end,getAlcohol=function() return 0 end,
  getFoodSicknessChange=function() return 0 end,getHungerChange=function() return -.5 end,getThirstChange=function() return -.5 end} end
 local c=assert(Full.new(p,world,{f},'fluid')); c:tick(); p.h=.1; c:tick()
 assert(c:isBusy() and #created.calls==1); now=now+2001; c:tick()
 assert(c.state=='failed' and #created.calls==1)
end)
test('already satisfied Drink does not eat for secondary hunger',function()
 local p=player(.5,0); local f,fluid=bottle(1,.5)
 function fluid:getProperties() return {getPoison=function() return 0 end,getAlcohol=function() return 0 end,
  getFoodSicknessChange=function() return 0 end,getHungerChange=function() return -.5 end,getThirstChange=function() return -.5 end} end
 local c=assert(Full.new(p,world,{f},'fluid')); c:tick(); assert(c.state=='finished' and #created.calls==0)
end)
test('delayed food completion does not consume the rest of the stack',function()
 local p=player(.1,0); local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 close(created.calls[1].portion,.5)
 c:tick(); assert(c:isBusy() and #created.calls==1)
 -- A small need update can arrive before the completion packet.
 p.h=.09; c:tick(); assert(#created.calls==1)
 a.h=.1; p.h=0; c:tick()
 assert(c.state=='finished' and #created.calls==1 and b.h==.2)
end)
test('partial item progress cannot acknowledge an entire requested food',function()
 local p=player(.5,0); local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 a.h=.1; p.h=.4; c:tick(); assert(#created.calls==1)
 a.h=0; p.h=.3; c:tick(); assert(#created.calls==2 and created.calls[2].item==b)
end)
test('item packet before needs waits without dispatching',function()
 local p=player(.5,0); local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 a.source=nil; c:tick(); assert(#created.calls==1)
 p.h=.3; c:tick(); assert(#created.calls==2)
end)
test('unconfirmed completion times out even with unrelated need improvement',function()
 local p=player(.5,0); local a=food(1,.2)
 local c=assert(Full.new(p,world,{a},'food')); c:tick(); p.h=.49; c:tick()
 now=now+2001; c:tick(); assert(c.state=='failed' and #created.calls==1)
end)
test('fluid partial progress waits for the requested quantity',function()
 local p=player(0,.5); local a,fa=bottle(1,.2); local b=bottle(2,.2)
 local c=assert(Full.new(p,world,{a,b},'fluid')); c:tick()
 p.t=.49; fa.ratio=.9; c:tick(); assert(#created.calls==1)
 fa.empty=true; p.t=.3; c:tick(); assert(#created.calls==2)
end)
test('full quantity with intermediate stat packet does not queue another bite',function()
 local p=player(.1,0); local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 a.h=.1; p.h=.08; c:tick(); assert(#created.calls==1)
 p.h=0; c:tick(); assert(c.state=='finished' and #created.calls==1)
end)
test('intermediate stats cannot overestimate the next item portion',function()
 local p=player(.3,0); local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 a.source=nil; p.h=.29; c:tick(); assert(#created.calls==1)
 p.h=.1; c:tick(); assert(#created.calls==2); close(created.calls[2].portion,.5)
end)
test('stack continues after observed hunger growth during native eating',function()
 local p=player(.2,0); local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food')); c:tick()
 created.pending=true; p.h=.2004; c:tick()
 created.pending=false; a.source=nil; p.h=.0004; c:tick()
 assert(#created.calls==2 and created.calls[2].item==b)
 close(created.calls[2].portion,.002)
end)
test('single item never adopts a stack peer after hunger growth',function()
 local p=player(.2,0); local a,outside=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a},'food')); c:tick()
 created.pending=true; p.h=.2004; c:tick()
 created.pending=false; a.source=nil; p.h=.0004; c:tick()
 assert(c.state=='finished' and #created.calls==1 and outside.source==inventory)
end)
test('fluid stack continues with observed thirst drift and full hunger',function()
 local p=player(0,.2); local a,fa=bottle(1,.2); local b=bottle(2,.2)
 local c=assert(Full.new(p,world,{a,b},'fluid')); c:tick()
 created.pending=true; p.t=.2003; c:tick()
 created.pending=false; fa.empty=true; p.t=.0003; c:tick()
 assert(#created.calls==2 and created.calls[2].item==b)
 close(created.calls[2].portion,.0015)
end)
test('initial full food and fluid never dispatch even from external containers',function()
 local a=food(1,.2); a.source={}; local b=bottle(2,.2); b.source={}
 for _,case in ipairs({{a,'food',0,.5},{b,'fluid',.5,0}}) do
  local c=assert(Full.new(player(case[3],case[4]),world,{case[1]},case[2])); c:tick()
  assert(c.state=='finished' and #created.calls==0)
 end
end)
local recipe={name='OpenCan'}
local function can(id)
 local f=food(id,0);f.cantEat=true;return f
end
test('sealed food opens exact selected can before sizing its replacement portion',function()
 local p=player(.1,0);local a,output,outside=can(10),food(20,.4),food(21,.4)
 local c=assert(Full.new(p,world,{a},'food',false,recipe));c:tick()
 assert(#created.opens==1 and created.opens[1].item==a and #created.calls==0)
 created.pending=true;c:tick();assert(#created.calls==0)
 created.pending=false;created.opened=output;a.source=nil;c:tick()
 assert(#created.calls==1 and created.calls[1].item==output and c.count==0)
 close(created.calls[1].portion,.25);assert(outside.h==.4)
end)
test('opening a fluid preserves its exact identity and rechecks need before consuming',function()
 local p=player(0,.3);local a,fluid=bottle(10,.5);a.sealed=true
 function fluid:canPlayerEmpty() return not a.sealed end
 local c=assert(Full.new(p,world,{a},'fluid',false,recipe));c:tick()
 assert(#created.opens==1 and #created.calls==0)
 a.sealed=false;created.opened=a;p.t=.1;c:tick()
 assert(created.calls[1].item==a);close(created.calls[1].portion,.2)
end)
test('already satisfied packaged food never opens even without source relief',function()
 local c=assert(Full.new(player(0,.5),world,{can(1)},'food',false,recipe))
 assert(c:alreadySatisfied());c:tick();assert(c.state=='finished' and #created.opens==0 and #created.calls==0)
end)
test('unsafe and protected cans are not opened and unsafe output is not eaten',function()
 for _,flag in ipairs({'unsafe','protected'}) do
  local a=can(1);a[flag]=true;local c=assert(Full.new(player(.1,0),world,{a},'food',false,recipe));c:tick()
  assert(c.state=='cancelled' and #created.opens==0)
 end
 local c=assert(Full.new(player(.1,0),world,{can(1)},'food',false,recipe));c:tick()
 created.opened=food(2,.2);created.opened.unsafe=true;c:tick()
 assert(c.state=='cancelled' and #created.calls==0)
end)
test('opening cannot guess missing output or accept one left outside main inventory',function()
 for _,mode in ipairs({'missing','external','sealed'}) do
  local c=assert(Full.new(player(.1,0),world,{can(1)},'food',false,recipe));c:tick()
  if mode~='missing' then created.opened=food(2,.2)
   if mode=='external' then created.opened.source={} else created.opened.sealed=true end
  end
  c:tick();assert(not c:isBusy() and #created.calls==0 and #created.opens==1,mode)
 end
end)
test('cancel during opening waits cleanup and never consumes confirmed output',function()
 local c=assert(Full.new(player(.1,0),world,{can(1)},'food',false,recipe));c:tick()
 created.pending=true;c:cancel();c:tick();assert(c:isBusy())
 created.pending=false;created.opened=food(2,.2);c:tick()
 assert(c.state=='cancelled' and #created.calls==0 and #created.opens==1)
end)
test('target reached during opening does not consume the newly opened food',function()
 local p=player(.1,0);local c=assert(Full.new(p,world,{can(1)},'food',false,recipe));c:tick()
 p.h=0;created.opened=food(2,.2);c:tick()
 assert(c.state=='finished' and #created.calls==0 and #created.opens==1)
end)
test('opening refusal after preparation retains cancellation cleanup',function()
 local c=assert(Full.new(player(.1,0),world,{can(1)},'food',false,recipe));created.refuse=true;created.pending=true
 c:tick();assert(c.state=='cancelling' and #created.opens==1);c:tick();assert(c:isBusy())
 created.pending=false;created.result=false;c:tick();assert(c.state=='cancelled' and #created.calls==0)
end)
test('selected packaged stack opens one can at a time only after exact consumption confirmation',function()
 local p=player(.3,0);local a,b,outside=can(1),can(2),can(3)
 local c=assert(Full.new(p,world,{a,b},'food',false,recipe));c:tick()
 local out=food(10,.2);created.opened=out;c:tick();assert(#created.opens==1 and #created.calls==1)
 c:tick();assert(#created.opens==1);out.source=nil;p.h=.1;c:tick()
 assert(#created.opens==2 and created.opens[2].item==b and outside.cantEat)
 created.opened=food(20,.2);c:tick();assert(#created.calls==2);close(created.calls[2].portion,.5)
end)
test('opening target and protection changes stop without consuming',function()
 local p=player(.1,0);local a=can(1);local c=assert(Full.new(p,world,{a},'food',false,recipe));c:tick()
 p.h=0;assert(created.target());created.result=false;c:tick();assert(c.state=='finished' and #created.calls==0)
 a=can(2);c=assert(Full.new(player(.1,0),world,{a},'food',false,recipe));c:tick()
 a.protected=true;assert(created.target());created.result=false;c:tick()
 assert(c.state=='cancelled' and #created.calls==0)
end)
test('opening never bypasses unsafe fluid or bounded work limits',function()
 local a,fluid=bottle(1,.5);a.sealed=true;fluid.poison=true
 local c=assert(Full.new(player(0,.3),world,{a},'fluid',false,recipe));c:tick()
 assert(c.state=='cancelled' and #created.opens==0)
 c=assert(Full.new(player(.1,0),world,{can(1)},'food',false,recipe));c.attempts=256;c:tick()
 assert(c.state=='cancelled' and #created.opens==0)
end)
local multiplayer=false
function isClient() return multiplayer end
test('multiplayer opening hands back exact choice without consuming or opening stack peers',function()
 multiplayer=true
 local first,second=can(1),can(2)
 local c=assert(Full.new(player(.3,0),world,{first,first,second},'food',false,recipe));c:tick()
 assert(#created.opens==1 and #c.records==2)
 created.reason='chooseOpened';c:tick()
 assert(c.state=='finished' and c.count==0 and c.records==nil and #created.calls==0 and #created.opens==1)
 assert(c.openedFoodPrompt=='When the opened food appears, right-click it and choose Eat > Til Full.')
 c.openedFoodPrompt=nil;c:tick();assert(c.openedFoodPrompt==nil and #created.opens==1)
 multiplayer=false
end)
test('opening fallback never prompts after cancellation refusal or satisfied hunger',function()
 multiplayer=true
 for _,mode in ipairs({'cancel','refuse','full','dead'}) do
  local p=player(.3,0);local c=assert(Full.new(p,world,{can(1),can(2)},'food',false,recipe));c:tick()
  created.reason='chooseOpened'
  if mode=='cancel' then c:cancel() elseif mode=='refuse' then created.result=false
  elseif mode=='full' then p.h=0 else p.dead=true end
  c:tick();assert(not c:isBusy() and c.openedFoodPrompt==nil and #created.calls==0 and #created.opens==1,mode)
 end
 multiplayer=false
end)
test('opening fallback is not accepted from single player or a fluid action',function()
 local c=assert(Full.new(player(.3,0),world,{can(1)},'food',false,recipe));c:tick()
 created.reason='chooseOpened';c:tick();assert(c.state=='failed' and c.openedFoodPrompt==nil)
 multiplayer=true;local item=bottle(2,.5);item.sealed=true
 c=assert(Full.new(player(0,.3),world,{item},'fluid',false,recipe));c:tick()
 created.reason='chooseOpened';c:tick();assert(c.state=='failed' and c.openedFoodPrompt==nil)
 multiplayer=false
end)
test('same exact opened fluid can return to its original bag but no unrelated bag',function()
 for _,move in ipairs({'original','other','changed-id'}) do
  local bag={};local item=bottle(1,.5);item.source=bag;item.sealed=true
  local c=assert(Full.new(player(0,.3),world,{item},'fluid',false,recipe));c:tick()
  item.source=inventory
  item.sealed=false;created.opened=item
  if move=='other' then item.source={} else item.source=bag end
  if move=='changed-id' then item.id=99 end
  c:tick()
  if move=='original' then assert(#created.calls==1 and created.calls[1].item==item)
  else assert(#created.calls==0 and c.state=='cancelled',move) end
 end
end)
test('both-needs mode does not open an unknown can solely for thirst but preserves known food relief',function()
 local c=assert(Full.new(player(0,.2),world,{can(1)},'food',true,recipe))
 assert(c:alreadySatisfied());c:tick();assert(c.state=='finished' and #created.opens==0)
 local known=food(2,.2);known.t=.4
 c=assert(Full.new(player(0,.2),world,{known},'food',true,recipe));c:tick()
 assert(#created.calls==1 and #created.opens==0);close(created.calls[1].portion,.5)
end)
test('direct food relief confirms exact partial amount despite hidden completion-frame metabolism',function()
 local p=player(.07015461474657059,0);local f=food(1,.14)
 local c=assert(Full.new(p,world,{f,food(2,.14)},'food'));c:tick()
 local h,t=created.sampler();close(h,p.h);close(t,0)
 created.receipt={item=f,hunger=p.h,thirst=0}
 f.h=.06984538584947586;p.h=.0011784672969952226;c:tick()
 assert(c.state=='finished' and c.count==1 and #created.calls==1)
 assert(c.reason=='The requested portion satisfied the need measured before consumption')
end)
test('direct progressive fluid relief does not chase metabolism into more sips',function()
 local p=player(0,.05);local f,fluid=bottle(1,.09)
 local c=assert(Full.new(p,world,{f,(bottle(2,.09))},'fluid'));c:tick()
 created.receipt={item=f,hunger=0,thirst=.05};fluid.ratio=.4444444477558136;p.t=.0010329603683203459;c:tick()
 assert(c.state=='finished' and c.count==1 and #created.calls==1)
end)
test('receipt cannot override missing quantity packet or partial consumption',function()
 local p=player(.1,0);local f=food(1,.2)
 local c=assert(Full.new(p,world,{f},'food'));c:tick()
 created.receipt={item=f,hunger=.1,thirst=0};p.h=.001;c:tick()
 assert(c:isBusy() and #created.calls==1)
 f.h=.15;c:tick();assert(c:isBusy())
 f.h=.1;c:tick();assert(c.state=='finished' and #created.calls==1)
end)
test('weak wrong identity malformed and multiplayer receipts never confirm a requested portion',function()
 for _,mode in ipairs({'weak','other','changed-id','nan','negative','mp'}) do
  local p=player(.1,0);local f=food(1,.2)
  local c=assert(Full.new(p,world,{f,food(2,.2)},'food'));c:tick()
  created.receipt={item=f,hunger=.1,thirst=0};f.h=.1;p.h=0
  if mode=='weak' then created.receipt.hunger=.099
  elseif mode=='other' then created.receipt.item=food(3,.2)
  elseif mode=='changed-id' then f.id=4
  elseif mode=='nan' then created.receipt.hunger=0/0
  elseif mode=='negative' then created.receipt.thirst=-.1
  elseif mode=='mp' then multiplayer=true end
  c:tick();assert(c:isBusy(),mode);now=now+2001;c:tick()
  assert(c.state=='failed' and #created.calls==1,mode);multiplayer=false
 end
end)
test('both targets require both directly measured relief amounts',function()
 local p=player(.1,.1);local f=food(1,.2);f.t=.2
 local c=assert(Full.new(p,world,{f},'food',true));c:tick()
 created.receipt={item=f,hunger=.1,thirst=.01};f.h=.1;p.h=0;p.t=0;c:tick()
 assert(c:isBusy());now=now+2001;c:tick();assert(c.state=='failed')
end)
test('full item receipt still permits bounded selected-peer continuation',function()
 local p=player(.3,0);local a,b=food(1,.2),food(2,.2)
 local c=assert(Full.new(p,world,{a,b},'food'));c:tick()
 created.receipt={item=a,hunger=.2,thirst=0};a.source=nil;p.h=.101;c:tick()
 assert(#created.calls==2 and created.calls[2].item==b);close(created.calls[2].portion,.505)
end)
local sourceWorld={protected=world.protected}
function sourceWorld:consumptionSource(item,source)
 if source.foreign then return nil,'Other player source' end
 if source.denied then return nil,'Access denied' end
 if source.far then return nil,'Out of reach' end
 if item:getContainer()==source then return true end
 if source.floor and not item:getContainer() and item.ground==source and source.members[item] then return true end
 return nil,'Exact source membership changed'
end
local function groundItem(id,source)
 local item=food(id,.2);item.source=nil;item.ground=source;source.members[item]=true
 function item:getWorldItem() return self.ground end
 return item
end
test('explicit menu source rejects stale and mixed selections before native dispatch',function()
 local crate={};local a,b=food(1,.2),food(2,.2);a.source=crate
 assert(Full.new(player(.1,0),sourceWorld,{a,b},'food',false,nil,crate)==nil)
 local c=assert(Full.new(player(.1,0),sourceWorld,{a},'food',false,nil,crate))
 a.source=inventory;c:tick();assert(c.state=='cancelled' and #created.calls==0)
 assert(Full.new(player(.1,0),sourceWorld,{a},'food',false,nil,crate)==nil)
end)
test('exact selected crate food transfers to main while outside decoy remains untouched',function()
 local crate={};local a,outside=food(1,.2),food(2,.2);a.source=crate;outside.source=crate
 local c=assert(Full.new(player(.1,0),sourceWorld,{a},'food',false,nil,crate));c:tick()
 assert(#created.calls==1 and created.calls[1].item==a);close(created.calls[1].portion,.5)
 a.source=inventory;crate.far=true;assert(not created.target())
 assert(outside.source==crate and outside.h==.2)
end)
test('source access and reach are checked again while native preparation is pending',function()
 for _,flag in ipairs({'far','denied','foreign'}) do
  local source={};local a=food(1,.2);a.source=source
  local c=assert(Full.new(player(.1,0),sourceWorld,{a},'food',false,nil,source));source[flag]=true
  c:tick();assert(c.state=='cancelled' and #created.calls==0,flag)
  source[flag]=false;c=assert(Full.new(player(.1,0),sourceWorld,{a},'food',false,nil,source));c:tick()
  source[flag]=true;assert(created.target());c:tick();assert(c.state=='cancelled',flag)
 end
end)
test('packaged external food and fluid retain exact source checks during opening',function()
 for _,kind in ipairs({'food','fluid'}) do
  local source={};local a=kind=='food' and can(1) or bottle(1,.5);a.source=source
  if kind=='fluid' then a.sealed=true end
  local c=assert(Full.new(player(.1,.1),sourceWorld,{a},kind,false,recipe,source));c:tick()
  assert(#created.opens==1 and created.opens[1].item==a and created.opens[1].source==source)
  source.far=true;assert(created.target());c:tick();assert(c.state=='cancelled' and #created.calls==0)
 end
end)
test('exact nil-container floor item is recognized only through live floor membership',function()
 local floor={floor=true,members={}};local a=groundItem(1,floor)
 local c=assert(Full.new(player(.1,0),sourceWorld,{a},'food',false,nil,floor));c:tick()
 assert(#created.calls==1 and created.calls[1].item==a);close(created.calls[1].portion,.5)
 a.source=inventory;a.ground=nil;assert(not created.target())
 local b=groundItem(2,floor)
 c=assert(Full.new(player(.1,0),sourceWorld,{b},'food',false,nil,floor));floor.members[b]=nil;c:tick()
 assert(c.state=='cancelled' and #created.calls==0)
 assert(Full.new(player(.1,0),sourceWorld,{food(3,.2)},'food',false,nil,floor)==nil)
end)
test('original own bag permits native restoration but not stale main or another bag',function()
 local bag={};local a=bottle(1,.5);a.sealed=true;a.source=bag
 local c=assert(Full.new(player(0,.1),sourceWorld,{a},'fluid',false,recipe,bag));c:tick()
 a.source=inventory;assert(not created.target());a.sealed=false;created.opened=a;a.source=bag;c:tick()
 assert(#created.calls==1 and created.calls[1].item==a)
 a.source={};assert(created.target());c:tick();assert(c.state=='cancelled')
end)
print('Til Full controller: '..count..' scenarios passed')

