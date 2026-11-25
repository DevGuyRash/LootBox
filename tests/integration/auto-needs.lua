package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
-- B42 boundary doubles: the stock source selector sees only its passed Java-style list.
local time,client,vanilla,foreign,source,seal,selected,attempts,sips,checks,first,kindSeen,mode
local options,p,stats,bag,main,world,inst,queue,needs,object,stock,guard
local function yes() return true end
local function no() return false end
local function nilv() return nil end
function isClient() return client end
function isServer() return false end
function getTimestampMs() return time end
function getCore() return {getOptionAutoDrink=function() return vanilla end} end
CharacterStat={HUNGER='h',THIRST='t'}
ISTimedActionQueue={getTimedActionQueue=function() return queue end}
ISInventoryPaneContextMenu={getEatingMask=function(player) return player.mask end}
local function controller()
 return {state='running',count=0,isBusy=function(s)return s.state=='running' end,
         tick=function() end,cancel=function(s)s.state='cancelled' end}
end
package.loaded['LootBox/NeedsInventory']={
 select=function(_,o,k) checks=checks+1; if selected[k] then return selected[k],seal end end,
 accessible=function(_,o,k,w,i) return i==object and ((k=='fluid' and o.autoDrinkEquipped) or o.autoConsumeCarried) end,
 eligible=function(_,o,k,w,i,recipe) return i==object and not i.unsafe end,
 sourceAccessible=function(_,o,w,src) return src==main or (src==bag and o.autoConsumeCarried and not bag.dropped) end}
package.loaded['LootBox/TillFull']={new=function(_,_,items,opts)
 assert(#items==1 and items[1]==object and not opts.both);attempts=attempts+1;guard=opts.automatic.guard;kindSeen=opts.kind;first=controller();return first end}
local Auto=require 'LootBox/AutoNeeds'
local function reset()
 time,client,vanilla,seal,source,attempts,sips,checks=0,false,true,nil,nil,0,0,0
 options={autoDrinkEquipped=false,autoConsumeCarried=false,autoConsumeNested=false}
 stats={h=0,t=0,get=function(s,k)return s[k] end,getNumVisibleZombies=function(s)return s.z or 0 end,getNumChasingZombies=function()return 0 end,getNumVeryCloseZombies=function()return 0 end}
 main={getItems=function()return 'main' end};bag={};queue={queue={}}
 p={getCurrentSquare=yes,isLocalPlayer=yes,getInventory=function()return main end,
 getStats=function()return stats end,getVehicle=nilv,getAutoDrink=function()return p.synced~=false end,
 getWaterSource=function(_,l) assert(l=='main');return source end,
 autoDrink=function()sips=sips+1;if not p.veto then object.amount=object.amount-.5;stats.t=0 end end}
 for _,name in ipairs({'isDead','isAsleep','isMoving','isRunning','isSprinting','isAiming','isAttacking','isShoving','isClimbing','isKnockedDown','isbFalling','isPerformingGrappleAnimation','hasTimedActions'})do p[name]=no end
 world={};inst={player=p,world=world,jobs={status=function()return {hasJob=inst.job==true,canStart=true} end},recovery={status=function()return {pending=inst.recover==true} end}}
 local component={getAmount=function()return object.amount end}
 object={amount=1,holder=main,getContainer=function(s)return s.holder end,getFluidContainer=function()return component end,
 isWaterOnlySource=function(s)return s.water==true end}
 selected={};guard=nil
end
local function step(ms) time=ms;Auto.step(inst,options,function()return options end,time) end
local function run(name,f)reset();f();print('PASS '..name) end
run('defaults and nested alone never examine contents or enqueue',function()
 options.autoConsumeNested=true;stats.h=1;stats.t=1;selected={food=object,fluid=object};step(0);assert(checks==0 and attempts==0)
end)
run('equipped option only serves significant thirst, never hunger or a sip for a trivial change',function()
 options.autoDrinkEquipped=true;stats.h=.8;stats.t=.04;selected.fluid=object;step(0);assert(attempts==0)
 stats.t=.35;step(6000);assert(attempts==1 and kindSeen=='fluid' and guard(object,main));step(15000);assert(attempts==1)
 p.isMoving=yes;assert(not guard(object,main));p.isMoving=no;options.autoDrinkEquipped=false;assert(not guard(object,main))
end)
run('carried hunger works with vanilla thirst disabled and opening never uses a broad wrapper',function()
 options.autoConsumeCarried=true;vanilla=false;stats.h=.51;stats.t=.6;selected.food=object;selected.fluid=object
 step(0);assert(attempts==1 and kindSeen=='food');object.unsafe=true;assert(not guard(object,main))
end)
run('native selection observes real progress, source changes reset the bounded stall window',function()
 options.autoDrinkEquipped=true;stats.t=.30;selected.fluid=object;object.water=true;source=object
 step(0);stats.t=.31;step(9000);object.amount=.9;stats.t=.32;step(16000);assert(sips==0)
 local other={getFluidContainer=object.getFluidContainer};source=other;step(23000);source=object;step(29000);stats.t=.36;step(40000);assert(sips==0 and attempts==0)
 stats.t=.37;step(52000);assert(sips==1 and attempts==0 and stats.t==0)
end)
run('native veto is respected and only tried once; unconscious, MP and disabled modes do not poke stock',function()
 options.autoDrinkEquipped=true;stats.t=.30;selected.fluid=object;source=object;object.water=true;p.veto=true
 step(0);stats.t=.32;step(23000);stats.t=.38;step(48000);assert(sips==1 and attempts==0)
 p.isMoving=yes;Auto.interruptObservation(inst);p.isMoving=no;step(54000);stats.t=.42;step(85000);assert(sips==1)
 for _,mp in ipairs({false,true}) do reset();options.autoDrinkEquipped=true;stats.t=.3;selected.fluid=object;source=object;client=mp
   if not mp then p.isAsleep=yes end;step(0);stats.t=.4;step(30000);assert(sips==0 and attempts==0) end
end)
run('an unchanged need in a paused simulation is not a missed vanilla sip',function()
 options.autoDrinkEquipped=true;stats.t=.4;source=object;selected.fluid=object;step(0);step(30000);assert(sips==0 and attempts==0)
end)
run('manual queue, native timed action, visible zombies, vehicle, movement, preserved paused job block automation',function()
 local preds={'isAiming','isAttacking','isRunning','isMoving','isSprinting','hasTimedActions'}
 for _,k in ipairs(preds)do reset();p[k]=yes;options.autoConsumeCarried=true;stats.h=.46;selected.food=object;step(0);assert(checks==0 and attempts==0,k) end
 reset();queue.queue={9};options.autoConsumeCarried=true;stats.h=.5;selected.food=object;step(0);assert(checks==0)
 queue.queue={};stats.z=1;step(5000);assert(checks==0);stats.z=0;inst.job=true;step(10000);assert(checks==0)
 inst.job=false;inst.recover=true;step(15000);assert(checks==0)
end)
run('unconfirmed intake does not start a different item or repeat in the same need episode',function()
 options.autoConsumeCarried=true;stats.h=.55;selected.food=object;step(0);assert(attempts==1)
 first.state='failed';step(16000);step(42000);assert(attempts==1)
 stats.h=.04;step(49000);stats.h=.51;step(65000);assert(attempts==2)
end)
run('after a confirmed bite re-read live need and cooldown before selecting another',function()
 options.autoConsumeCarried=true;stats.h=.65;selected.food=object;step(0)
 first.state='finished';first.count=1;stats.h=.35;step(4000);step(8000);assert(attempts==1)
 step(20000);assert(attempts==2);options.autoConsumeNested=false
end)

run('a new native sip attempt never also starts a food action in that pass',function()
 options.autoDrinkEquipped=true;options.autoConsumeCarried=true;stats.t=.31;selected.fluid=object;source=object;step(0)
 selected.food=object;stats.t=.38;stats.h=.4;step(22000);assert(sips==1 and attempts==0)
end)
run('an unknown MP hydration setting cannot block safe independent hunger',function()
 client=true;options.autoConsumeCarried=true;p.getAutoDrink=nil;stats.t=.4;stats.h=.5;selected.food=object;step(0)
 assert(attempts==1 and kindSeen=='food')
end)

run('ordinary loose stock water is never retried solely by the carried option',function()
 options.autoConsumeCarried=true;stats.t=.32;selected.fluid=object;source=object;step(0)
 stats.t=.4;step(25000);assert(sips==0 and attempts==0)
end)

run('any observed thirst improvement restarts the stock stall clock even above the initial value',function()
 options.autoDrinkEquipped=true;selected.fluid=object;source=object;stats.t=.30;step(0)
 stats.t=.45;step(13000);stats.t=.41;step(19000);stats.t=.44;step(27000);assert(sips==0)
 stats.t=.46;step(43000);assert(sips==1)
end)



run('an interrupted meal is tried again after the cooldown; an unconfirmed one is not',function()
 options.autoConsumeCarried=true;stats.h=.6;selected.food=object;step(0);assert(attempts==1)
 first.state='cancelled';step(4000);step(9000);assert(attempts==1,'within the cooldown')
 step(16500);assert(attempts==2,'walking away once does not end eating')
 first.state='cancelled';step(21000);step(33000);assert(attempts==3)
 first.state='failed';step(37000);step(60000);step(90000);assert(attempts==3)
end)
run('an attempt the game refuses outright backs off for a minute',function()
 options.autoConsumeCarried=true;stats.h=.6;selected.food=object;step(0)
 first.state='cancelled';first.goal='food';step(4000)
 step(30000);step(60000);assert(attempts==1);step(64500);assert(attempts==2)
end)
run('a search that finds nothing is not repeated before the cooldown',function()
 options.autoConsumeCarried=true;stats.h=.6;stats.t=.6
 step(0);assert(checks==2,'one search per need')
 step(4000);step(8000);step(11900);assert(checks==2)
 step(16000);assert(checks==4)
 selected.food=object;step(24000);assert(attempts==0);step(30000);assert(attempts==1)
end)
run('the controller and its trace share the automatic interaction',function()
 local Log=require 'LootBox/Log'
 local intent,saved=nil,Log.intent
 Log.intent=function(origin,label) intent={origin,label};return 314 end
 options.autoConsumeCarried=true;stats.h=.6;selected.food=object
 local policy
 local till=package.loaded['LootBox/TillFull']
 local make=till.new
 till.new=function(a,b,c,opts) policy=opts;return make(a,b,c,opts) end
 step(0)
 till.new,Log.intent=make,saved
 assert(intent[1]=='auto' and intent[2]=='eat' and policy.interaction==314)
end)

run('nested pure water is drunk with the ordinary action, which fetches and returns it; a dropped bag stops it',function()
 options.autoConsumeCarried=true;stats.t=.4;object.holder=bag;object.water=true;selected.fluid=object;step(0)
 assert(attempts==1 and kindSeen=='fluid' and sips==0);assert(guard(object,bag) and guard());bag.dropped=true;assert(not guard(object,bag))
end)
run('a drink that did not help is not repeated; one that helped may be',function()
 options.autoConsumeCarried=true;stats.t=.5;object.holder=bag;selected.fluid=object;step(0)
 first.state='finished';first.count=1;step(16000);step(40000);assert(attempts==1)
end)

run('a mask is never taken off for a background bite',function()
 options.autoConsumeCarried=true;stats.h=.6;selected.food=object;p.mask={};step(0);assert(attempts==0)
 p.mask=nil;step(16000);assert(attempts==1)
end)
