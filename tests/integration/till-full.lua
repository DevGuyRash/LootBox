package.path = 'Contents/mods/LootBox/42/media/lua/client/?.lua;' .. package.path
-- Real controller; native action and Java item/stat boundaries are doubles.
local now, count = 0, 0
function getTimestampMs() return now end
CharacterStat = { HUNGER = {getMinimumValue=function() return 0 end}, THIRST = {getMinimumValue=function() return 0 end} }
function instanceof(item, name) return name == 'Food' and item.food end
local created
package.loaded['LootBox/TillFullNative'] = {new=function()
 local n = {busy=false, calls={}}
 function n:isBusy() return self.busy end
 function n:begin(item, kind, portion, target)
  self.busy=true; self.calls[#self.calls+1]={item=item,kind=kind,portion=portion}; self.target=target
  if self.refuse then return nil,'refused after preparation' end
  return true
 end
 function n:poll() if self.pending then return nil end; self.busy=false; return self.result ~= false, self.reason end
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
 function f:getScriptItem() return {isCantEat=function() return false end} end
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
print('Til Full controller: '..count..' scenarios passed')

