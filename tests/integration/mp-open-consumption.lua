-- Production menu/planner and native action adapters; stock engine and Java
-- inventory/recipe boundaries are doubles, not a multiplayer gameplay pass.
package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
package.preload["TimedActions/ISTimedActionQueue"]=function() end
package.preload["ISUI/ISInventoryPaneContextMenu"]=function() end
local Full=require "LootBox/TillFull"
local Open=require "LootBox/OpenFull"
local total=0
local function test(name,fn) fn();total=total+1;print("PASS "..name) end
local function list(items)
    return {size=function() return #items end,get=function(_,i) return items[i+1] end,
        contains=function(_,v) for _,item in ipairs(items) do if item==v then return true end end;return false end}
end
local function fixture(name,loot,producer,sp)
    local f={at=1000,rows={},outside={},pockets={},java={},opens={},bites={},dropped={},h=.1,t=.2}
    local jar,ration=producer=="jar",producer=="ration"
    local kept=producer=="kept"
    local unknown=producer=="mystery" or producer=="dented"
    local recipeName=kept and "OpenCanOfBeverage" or jar and "OpenJarOfFood" or ration and "OpenWaterRationCan" or producer=="mystery" and "OpenUnlabeledCan"
        or producer=="dented" and "OpenDentedUnlabeledCan" or "OpenCannedFood"
    local function container(items)
        local c={rows=items,capacity=20,weight=5}
        function c:getItems() return list(self.rows) end
        function c:getContainingItem() return self.bag end
        function c:getCapacityWeight() return self.weight end
        function c:getEffectiveCapacity() return self.capacity end
        function c:hasRoomFor(_,weight) return self.weight+weight<=self.capacity end
        function c:getItemWithID(id) for _,v in ipairs(self.rows) do if v.id==id then return v end end end
        function c:containsID(id) return self:getItemWithID(id)~=nil end
        return c
    end
    f.main,f.loot,f.pocket=container(f.rows),container(f.outside),container(f.pockets)
    f.source=loot and f.loot or f.main
    local fName="Base."..(name or "CannedPeaches")
    local drink=name=="CannedMilk" or name=="CannedFruitBeverage"
    local base,opened,lid={},{},{}
    function base:getFullName() return fName end
    function opened:getFullName()
        if ration then return "Base.WaterRationCanEmpty" end
        if jar then return fName.."_Open" end
        if unknown then return "Base.CannedPeachesOpen" end
        return fName.."Open"
    end
    function opened:getActualWeight() return .25 end
    function base:isCantEat() return true end
    function opened:isCantEat() return false end
    function lid:getFullName() return "Base.JarLid" end
    function lid:getActualWeight() return .1 end
    function lid:getConditionMax() return 10 end
    local toolScript={getFullName=function() return "Base.CanOpener" end}
    local bagScript={getFullName=function() return "Base.Bag" end}
    local function item(id,script,holder)
        local i={id=id,script=script,holder=holder,food=script==base or (script==opened and not ration),h=.4,t=.5,baseH=.4,mod={},condition=9}
        if unknown and script==opened then i.mod.NoLabel=true end
        function i:getID() return self.id end
        function i:getContainer() return self.holder end
        function i:getFullType() return self.script:getFullName() end
        function i:getOpeningRecipe()
            if self.script==base and not producer and name~="CannedFruitBeverage" then return recipeName end
        end
        function i:getScriptItem() return self.script end
        function i:getWorldItem() return self.world end
        function i:getModData() return self.mod end
        function i:getCondition() return self.condition end
        function i:getHungerChange() return -self.h end
        function i:getHungChange() return -self.h end
        function i:getThirstChange() return -self.t end
        function i:getBaseHunger() return -self.baseH end
        function i:getCustomMenuOption() if drink then return "Drink" end end
        function i:getPoisonPower() return self.poison or 0 end
        function i:getFoodSicknessChange() return 0 end
        for _,k in ipairs({"isSealed","isRotten","isBurnt","isFrozen","isTainted","isPoison","isAlcoholic","isbDangerousUncooked"}) do
            i[k]=function() return false end
        end
        function i:isRotten() return self.unsafe==true end
        if kept and script==base then i.food=false;i.sealed=true;function i:isSealed() return self.sealed end end
        function i:getFluidContainer() return self.fluid end
        if (ration and script==opened) or (kept and script==base) then
            local fluid={amount=.3,water=.3,owner=i}
            i.fluid=fluid
            function fluid:getOwner() return self.owner end
            function fluid:getCapacity() return .3 end
            function fluid:getAmount() return self.amount end
            function fluid:getFilledRatio() return self.amount/.3 end
            function fluid:getSpecificFluidAmount(value) return value==Fluid.Water and self.water or 0 end
            function fluid:isTainted() return self.tainted==true end
            function fluid:isEmpty() return self.amount==0 end
            function fluid:canPlayerEmpty() return true end
            function fluid:isPoisonous() return false end
            function fluid:getProperties()
                return {getHungerChange=function() return 0 end,getThirstChange=function() return -.15 end,
                    getAlcohol=function() return 0 end,getPoison=function() return 0 end,getFoodSicknessChange=function() return 0 end}
            end
            function fluid:createFluidSample()
                local clean={isCategory=function(_,k) return k==FluidCategory.Water or k==FluidCategory.Beverage end,
                    getProperties=function() return fluid:getProperties() end,isPoisonous=function() return false end}
                return {size=function() return 1 end,getPercentage=function() return 1 end,getFluid=function() return clean end,release=function() end}
            end
        end
        if holder then holder.rows[#holder.rows+1]=i end
        return i
    end
    local function retire(i)
        for n,v in ipairs(i.holder.rows) do if v==i then table.remove(i.holder.rows,n);break end end
        i.holder=nil
    end
    f.shell=item(1,base,f.source)
    if not jar and not kept then f.tool=item(2,toolScript,f.main) end
    local bag=item(3,bagScript,f.main);f.pocket.bag=bag
    function bag:getInventory() return f.pocket end
    f.old,f.nested=item(4,opened,f.main),item(5,opened,f.pocket)
    local p,s={},{getX=function() return 10 end,getY=function() return 12 end,getZ=function() return 0 end}
    function s:getWorldObjects() return list(f.dropped) end
    local cell={getGridSquare=function(_,x,y,z) if x==10 and y==12 and z==0 then return s end end}
    function p:getPlayerNum() return 0 end
    function p:getOnlineID() return 11 end
    function p:getInventory() return f.main end
    function p:getCurrentSquare() return s end
    function p:getCharacterActions() return list(f.java) end
    function p:isLocalPlayer() return true end
    function p:isMoving() return self.move==true end
    function p:getStats() return {get=function(_,key) return key==CharacterStat.HUNGER and f.h or f.t end} end
    function p:getMoodles() return {getMoodleLevel=function() return 0 end} end
    for _,k in ipairs({"isDead","isAsleep","isRunning","isSprinting","isAiming","isAttacking","isShoving","isClimbing","isKnockedDown"}) do
        p[k]=function() return false end
    end
    local q={queue={}}
    -- Stock addToQueue -> begin -> IsoGameCharacter.StartAction pushes the
    -- Java owner, then validates/waits/starts synchronously on an idle actor.
    function f:engine(a)
        if a.isValid and not a:isValid() or a:waitToStart()~=false then return false end
        a:start()
        self.sends=self.sends or {}
        self.sends[a.Type]=(self.sends[a.Type] or 0)+1
        return true
    end
    function f:admit(action)
        action.action={}
        f.java[1]=action.action
        if (action.Type=="ISHandcraftAction" and f.eagerOpen)
            or (action.Type~="ISHandcraftAction" and f.eagerBite) then
            if f.atAdmission then f.atAdmission(action) end
            f:engine(action)
        end
    end
    function q:addToQueue(action)
        self.queue[#self.queue+1]=action
        if self.current then return end
        self.current=action;f:admit(action)
    end
    function q:removeFromQueue(action)
        for n,v in ipairs(self.queue) do if v==action then table.remove(self.queue,n);break end end
    end
    f.p,f.q=p,q
    ISTimedActionQueue={getTimedActionQueue=function() return q end,add=function(a)
        if f.rejectBefore and f.rejectBefore(a) then return end
        q:addToQueue(a)
    end}
    isClient=function() return not sp end
    isServer=function() return false end
    getCell=function() return cell end
    getTimestampMs=function() return f.at end
    getSpecificPlayer=function(index) assert(index==0);return p end
    local hooks={}
    f.hooks=hooks
    Events={OnServerCommand={Add=function(fn) hooks[#hooks+1]=fn end,Remove=function(fn)
        for i,v in ipairs(hooks) do if v==fn then table.remove(hooks,i);return end end
    end}}
    getNumActivePlayers=function() return f.players or 1 end
    function f:event(command,args)
        for _,fn in ipairs(hooks) do fn("recipe",command,args) end
    end
    instanceof=function(it,class) return class=="Food" and it.food==true end
    getText=function(k) return k=="ContextMenu_Drink" and "Drink" or k end
    CharacterStat={HUNGER={getMinimumValue=function() return 0 end},THIRST={getMinimumValue=function() return 0 end}}
    MoodleType={FOOD_EATEN={}}
    ResourceType={Item={}}
    Fluid={Water={}}
    FluidCategory={Water={},Beverage={},Hazardous={},Alcoholic={}}
    InputFlag={IsSealed={},Unseal={}}
    local shellSlot={isKeep=function() return kept end,hasFlag=function(_,flag)
        return kept and (flag==InputFlag.IsSealed or flag==InputFlag.Unseal)
    end}
    local toolSlot={isKeep=function() return true end}
    local out={}
    for _,entry in ipairs({shellSlot,toolSlot,out}) do
        function entry:getResourceType() return ResourceType.Item end
        function entry:getAmount() return 1 end
    end
    local mapper={}
    function mapper:getResultItems() return list(f.ambiguousMap and {opened,opened} or {opened}) end
    function mapper:getPatternForResult(result) return result==opened and list({base}) end
    function mapper:getOutputItem() return not f.changedMap and opened or nil end
    function out:getOutputMapper() return mapper end
    local recipe={getName=function() return recipeName end,isVanilla=function() return true end,
        isInHandCraftCraft=function() return true end,getInputs=function() return list((jar or kept) and {shellSlot} or {toolSlot,shellSlot}) end,
        getOutputCount=function() return (ration or unknown or kept) and 0 or 1 end,
        getOutputs=function() return list((ration or unknown or kept) and {} or {out}) end,
        getIndexForIO=function(_,slot) return slot==shellSlot and 2 or 1 end}
    local scripts={}
    getScriptManager=function() return {
        getCraftRecipe=function(_,n) if n==recipeName then return recipe end end,
        getItem=function(_,n)
            if n==lid:getFullName() then return lid end
            if n==opened:getFullName() then return opened end
            if unknown then
                scripts[n]=scripts[n] or {getFullName=function() return n end,getActualWeight=function() return .5 end,
                    isCantEat=function() return false end}
                return scripts[n]
            end
        end,
    } end
    CraftRecipeManager={getValidInputScriptForItem=function() return shellSlot end}
    f.recipe=recipe
    local function stop(a) q.current=nil;q.queue={};f.java={};a.stopped=true end
    local function perform(a)
        q:removeFromQueue(a);q.current=q.queue[1]
        if f.eagerAdvance and q.current then f:admit(q.current) end
    end
    local function forceStop(a) a:stop() end
    ISHandcraftAction={}
    ISEntityUI={HandcraftStart=function(player,_,force,addToQueue,percent)
        assert(player==p and not force and not addToQueue and percent==0)
        local a=setmetatable({Type="ISHandcraftAction",character=p,eatPercentage=percent,craftRecipe=recipe,
            manualInputs={[1]=not jar and list({f.tool}) or nil,[2]=list({f.shell})},waitToStart=function() return false end,
            stop=stop,forceStop=forceStop,forceCancel=function() end,perform=perform},ISHandcraftAction)
        function a:start()
            local shell=f.picked or f.shell
            self.manualInputs[2]=list({shell})
            self.logic={getRecipe=function() return recipe end,getRecipeData=function()
                return {getAllInputItems=function() return list(jar and {shell} or {f.tool,shell}) end}
            end}
            self.craftStarted=true
        end
        if sp then
            function a:perform()
                if f.synchronous then f.synchronous() end
                return perform(self)
            end
        end
        return a
    end}
    ISInventoryPaneContextMenu={}
    function ISInventoryPaneContextMenu.OnNewCraft(shell,r,index,all,eat)
        assert(shell==f.shell and r==recipe and index==0 and all==false and eat==0)
        f.opens[#f.opens+1]=eat
        if f.nativePickup then
            ISTimedActionQueue.add({Type="ISInventoryTransferAction",character=p,item=shell,srcContainer=f.source,destContainer=f.main,
                waitToStart=function() return false end,start=function() end,perform=perform,stop=stop,forceStop=forceStop})
        end
        f.action=ISEntityUI.HandcraftStart(p,{},false,true,eat)
    end
    local function make(value,portion,kind)
        f.bites[#f.bites+1]={value=value,portion=portion}
        local a={Type=kind,item=value,character=p,fluidContainer=value:getFluidContainer(),stop=stop,forceStop=stop,perform=perform,
            waitToStart=function() return false end,isValid=function() return true end}
        function a:start() self.item=f.main:getItemWithID(self.item:getID());f.requested=self.item end
        return a
    end
    ISEatFoodAction={new=function(_,who,value,portion) assert(who==p);return make(value,portion,"ISEatFoodAction") end}
    ISDrinkFluidAction={new=function(_,who,value,portion) assert(who==p);return make(value,portion,"ISDrinkFluidAction") end}
    function ISInventoryPaneContextMenu.getEatingMask(who,remove) assert(who==p and not remove);return f.mask end
    local function clothing(kind)
        return {new=function(_,who,item)
            assert(who==p and item==f.mask)
            return {Type=kind,character=who,item=item,waitToStart=function() return false end,
                start=function() end,perform=perform,stop=stop,forceStop=forceStop,forceCancel=function() end}
        end}
    end
    ISUnequipAction,ISWearClothing=clothing("ISUnequipAction"),clothing("ISWearClothing")
    function ISInventoryPaneContextMenu.eatItem(value,portion,index) assert(index==0);q:addToQueue(make(value,portion,"ISEatFoodAction")) end
    function ISInventoryPaneContextMenu.onDrinkFluid(value,portion,who) assert(who==p);q:addToQueue(make(value,portion,"ISDrinkFluidAction")) end
    local world={protected=function() return false end,consumptionSource=function(_,i,c) return i.holder==c end}
    f.job=assert(Full.new(p,world,{f.shell},(ration or kept) and "fluid" or drink and "drinkFood" or "food",false,recipe,f.source))
    function f:menu() f.job:tick();assert(#f.opens==1 and #f.bites==0 and f.action) end
    function f:start()
        assert(f.action:waitToStart())
        f.at=f.at+201
        assert(not f.action:waitToStart(),f.job.native.active.reason)
        f.action:start();f.sent=true
    end
    function f:pickup()
        retire(f.shell)
        f.picked=item(f.shell.id,base,f.main)
    end
    function f:add(id) return item(id,opened,f.main) end
    function f:lid(id,condition)
        local o=item(id,lid,f.main);o.condition=condition or 9;return o
    end
    function f:retire() retire(f.picked or f.shell) end
    function f:remove(i) retire(i) end
    function f:done()
        f.action:perform();f.java={}
    end
    function f:drop()
        local result=item(18,opened)
        f.dropped[#f.dropped+1]={getItem=function() return result end,getSquare=function() return s end}
    end
    function f:settle()
        f.job:tick()
        f.at=f.at+400
        f.job:tick()
    end
    return f
end

test("an idle native enqueue cannot send the mapped craft before its receipt is armed",function()
    local f=fixture()
    f.eagerOpen=true
    f:menu()
    assert(not f.action.craftStarted and not f.sends,"stock Open started inside add() before its quiet baseline")
    f.at=f.at+201
    assert(f:engine(f.action) and f.sends.ISHandcraftAction==1)
    local exact=f:add(6);f:retire();f:done();f:settle()
    assert(#f.bites==1 and f.q.current.item==exact,f.job.reason)
end)

test("idle mapped food and fluid follow-ups arm their exact guards before native enqueue can start",function()
    for _,entry in ipairs({{"CannedPeaches",false,"ISEatFoodAction"},{"WaterRationCan","ration","ISDrinkFluidAction"}}) do
        local f=fixture(entry[1],false,entry[2]);f.eagerBite=true
        f:menu();f:start()
        local exact=f:add(6);f:retire();f:done();f:settle()
        assert(f.requested==exact and f.sends and f.sends[entry[3]]==1,f.job.reason)
        assert(f.job.native.active.pinStarted==true,"stock bite/sip started before its exact guard")
    end
end)

test("a swapped opened item at eager admission cannot send the stock bite",function()
    local f=fixture();f.eagerOpen,f.eagerBite=true,true
    f:menu();f.at=f.at+201;assert(f:engine(f.action))
    local exact=f:add(6);f:retire();f:done()
    f.atAdmission=function(a)
        assert(a.item==exact)
        f:remove(exact);f:add(6)
    end
    f:settle();f.job:tick()
    assert(not f.requested and not f.sends.ISEatFoodAction and f.job.count==0)
end)

test("a stock kept soda in main waits for unseal and never sips a substituted fluid component",function()
    for _,swap in ipairs({false,true}) do
        local f=fixture("Pop2",false,"kept");f.eagerOpen,f.eagerBite=true,true
        f.t=.05;f:menu()
        assert(f.sends.ISHandcraftAction==1 and f.shell:isSealed())
        f:done();f.job:tick();assert(not f.requested and not f.q.current)
        f.shell.sealed=false
        if swap then f.atAdmission=function(a)
            assert(a.Type=="ISDrinkFluidAction")
            f.shell.fluid=setmetatable({owner=f.shell},{__index=f.shell.fluid})
        end end
        f.job:tick()
        if swap then
            assert(not f.requested and not f.sends.ISDrinkFluidAction,"sent a sip for a changed soda component")
        else
            assert(f.requested==f.shell and f.sends.ISDrinkFluidAction==1 and f.job.native.active.pinStarted)
            f.q.current:perform();f.java={};f.shell.fluid.amount=.2;f.t=0;f.job:tick()
            assert(f.job.count==1 and not f.job:isBusy(),f.job.reason)
        end
    end
end)

test("shelf soda uses its stock pickup, then the exact same-ID unsealed copy in main; an external survivor is not consumed",function()
    for _,stock in ipairs({true,false}) do
        local f=fixture("Pop2",true,"kept");f.eagerOpen,f.eagerBite,f.eagerAdvance=true,true,true;f.t=.05
        f.nativePickup=stock;f:menu()
        if stock then
            assert(f.q.current.Type=="ISInventoryTransferAction" and f.sends.ISInventoryTransferAction==1)
            f:pickup();f.q.current:perform()
            assert(f.q.current==f.action and f.picked~=f.shell and f.picked:getID()==f.shell:getID())
        end
        assert(f.sends.ISHandcraftAction==1)
        f:done();f.job:tick();assert(not f.requested)
        local result=f.picked or f.shell;result.sealed=false;f.job:tick()
        if stock then
            assert(f.requested==result and f.sends.ISDrinkFluidAction==1 and f.job.native.active.pinStarted)
            assert(#f.q.queue==1 and result:getContainer()==f.main) -- no stock return for this recipe
        else
            assert(not f.job:isBusy() and f.job.count==0 and f.job.reason==f.job.openedFoodPrompt
                and not f.sends.ISDrinkFluidAction and result:getContainer()==f.source)
        end
    end
end)

test("a mapped bite queued behind a mask keeps native mask restoration even when bite submission is declined",function()
    for _,reject in ipairs({false,true}) do
        local f=fixture();f.eagerBite,f.eagerAdvance=true,true;f.mask={}
        f:menu();f:start()
        local exact=f:add(6);f:retire();f:done()
        if reject then f.rejectBefore=function(a) return a.Type=="ISEatFoodAction" end end
        f:settle()
        if not reject then
            assert(f.q.current.Type=="ISUnequipAction" and #f.q.queue==3 and not f.requested)
            f.q.current:perform()
            assert(f.q.current.Type=="ISEatFoodAction" and f.requested==exact and f.job.native.active.pinStarted)
            f.q.current:perform()
        end
        assert(f.q.current and f.q.current.Type=="ISWearClothing" and f.q.current.item==f.mask)
        f.q.current:perform();f.java={};f.h=0;exact.h=.3;f.job:tick()
        assert(not f.q.current and (not reject or not f.requested))
    end
end)

test("reentrant work at eager craft admission is never claimed, stopped or lost",function()
    local f=fixture();f.eagerOpen=true
    local original=ISEntityUI.HandcraftStart
    local foreign={Type="ISReadABook",stop=function() error("foreign stop") end}
    f.atAdmission=function(a)
        assert(a.Type=="ISHandcraftAction" and ISEntityUI.HandcraftStart==original)
        f.q:addToQueue(foreign)
    end
    f:menu();f.job:tick()
    assert(f.q.current==foreign and #f.q.queue==1 and not f.sends and not f.requested)
    assert(ISEntityUI.HandcraftStart==original)
end)

test("real adapter uses exact stock mapped peach, milk and fruit beverage and samples need after opening",function()
    for _,name in ipairs({"CannedPeaches","CannedMilk","CannedFruitBeverage"}) do
        local f=fixture(name,name=="CannedMilk")
        local mapping=assert(Open.replacement(f.p,f.shell,f.recipe));assert(mapping.fullType=="Base."..name.."Open")
        f.p.isRunning,f.p.isSprinting=function() return true end,function() return true end -- stale native animation flags
        f:menu()
        if f.source~=f.main then assert(f.action:waitToStart());f:pickup() end
        f:start();f.job:tick();assert(#f.bites==0)
        local exact=f:add(6);f.job:tick();assert(#f.bites==0)
        f:retire();f:done()
        f.h,f.t=.04,.15
        f:settle()
        local bite=assert(f.bites[1],f.job.reason)
        local expected=name=="CannedPeaches" and .1 or .3
        assert(#f.bites==1 and bite.value==exact and math.abs(bite.portion-expected)<.00001 and f.job.count==0)
        assert(not f.q.current:waitToStart())
        f.q.current:start()
        assert(f.requested==exact)
        assert(f.old.h==.4 and f.nested.h==.4)
    end
end)

test("same-ID replica swap, carried ID overlap or actual movement at the readied bite cannot start consumption",function()
    for _,mode in ipairs({"replica-swap","inventory-shadow","real-movement"}) do
        local f=fixture()
        f:menu();f:start()
        local exact=f:add(6);f:retire();f:done();f:settle()
        local bite=assert(f.q.current)
        assert(bite.item==exact and #f.bites==1 and not f.requested)
        if mode=="replica-swap" then f:remove(exact);f:add(6)
        elseif mode=="inventory-shadow" then f.nested.id=6
        else f.p.move=true end
        assert(bite:waitToStart(),mode)
        f.job:tick()
        assert(not f.requested and not f.job:isBusy() and f.job.count==0)
    end
end)

test("pinned consumption also audits nested identity shadows when acknowledging the bite",function()
    for _,mode in ipairs({"exact","shadow","unadmitted"}) do
        local f=fixture();f:menu();f:start()
        local exact=f:add(6);f:retire();f:done();f:settle()
        local action=assert(f.q.current)
        if mode~="unadmitted" then assert(not action:waitToStart());action:start() end
        action:perform();f.java={}
        f.h=0;exact.h=.3
        if mode=="shadow" then f.nested.id=6 end
        f.job:tick()
        assert(#f.bites==1 and not f.job:isBusy() and f.job.count==(mode=="exact" and 1 or 0),mode)
    end
end)

test("MP opening declines late delivery, ambiguous outputs, floor drops, partial histories and other work",function()
    for _,mode in ipairs({"late","two-before","two-after","floor","floor-lookalike","no-shell-removal",
        "remove-spare","foreign","missing-perform","early-lookalike","cancel","changed-map","moved","no-room","already-full","unsafe"}) do
        local f=fixture()
        f:menu()
        if mode=="no-room" then
            f.main.weight=20;assert(f.action:waitToStart())
            f.job:tick()
        elseif mode=="early-lookalike" then
            assert(f.action:waitToStart());f:add(33)
            f.at=f.at+300;assert(f.action:waitToStart());f.job:tick()
        else
            f.changedMap=mode=="changed-map"
            f:start()
            local actual
            if mode~="late" and mode~="floor" then actual=f:add(6) end
            if mode=="unsafe" then actual.unsafe=true end
            if mode=="two-before" then f:add(7) end
            if mode=="floor" or mode=="floor-lookalike" then f:drop() end
            if mode=="remove-spare" then f:remove(f.old) end
            if mode~="no-shell-removal" then f:retire() end
            if mode=="moved" then f.p.move=true end
            if mode=="cancel" then f.job:cancel()
            elseif mode=="missing-perform" then f.q.current=nil;f.q.queue={};f.java={}
            else
                if mode=="foreign" then f.q.queue[2]={Type="ISReadABook"} end
                f:done()
            end
            if mode=="late" then f:add(6) end
            if mode=="two-after" then f:add(7) end
            if mode=="already-full" then f.h=0 end
            f:settle()
            if mode=="foreign" then assert(f.q.current==nil or f.q.current.Type=="ISReadABook") end
        end
        assert(#f.bites==0 and f.job.count==0 and not f.job:isBusy(),mode..": "..tostring(f.job.reason))
    end
end)

test("expected output must come from one unambiguous installed recipe mapper",function()
    local f=fixture();f.ambiguousMap=true
    assert(not Open.replacement(f.p,f.shell,f.recipe))
end)

test("a stock jar requires one mapped food and one freshly emitted lid with the selected jar's condition",function()
    for _,mode in ipairs({"food-first","lid-first","default","wrong-condition","old-only","two-lids","gone-lid",
        "changed-lid","two-foods","late-lid","loot"}) do
        local f=fixture("CannedTomato",mode=="loot","jar")
        local shellCondition=mode=="default" and nil or 6
        if mode~="default" then f.shell.mod.LidCondition=shellCondition end
        local oldLid=f:lid(14,6)
        f:menu()
        if mode=="loot" then
            assert(f.action:waitToStart());f:pickup();f.picked.mod.LidCondition=6
        end
        f:start()
        local result,newLid
        if mode=="lid-first" then newLid=f:lid(7,6);f.job:tick();assert(#f.bites==0) end
        result=f:add(6);f.job:tick();assert(#f.bites==0)
        if not newLid and mode~="old-only" and mode~="late-lid" then
            newLid=f:lid(7,mode=="wrong-condition" and 4 or mode=="default" and 9 or 6)
        end
        if mode=="two-lids" then f:lid(8,6) end
        if mode=="two-foods" then f:add(8) end
        f:retire();f:done()
        if mode=="late-lid" then f:lid(7,6) end
        if mode=="gone-lid" then f:remove(newLid) end
        if mode=="changed-lid" then newLid.condition=2 end
        f.h=.04;f:settle()
        local good=mode=="food-first" or mode=="lid-first" or mode=="default" or mode=="loot"
        if good then
            assert(#f.bites==1 and f.bites[1].value==result and f.q.current.item==result,f.job.reason)
            assert(newLid.holder==f.main and newLid.condition==(mode=="default" and 9 or 6))
        else assert(#f.bites==0 and not f.job:isBusy(),mode..": "..tostring(f.job.reason)) end
        assert(oldLid.holder==f.main and oldLid.condition==6)
    end
end)

test("ration cans drink the fresh native 0.300 L water result, not the shell or an existing water can",function()
    for _,mode in ipairs({"mp","sp","tainted","wrong-amount","mixture","lost","old-only","floor","fluid-replica"}) do
        local f=fixture("WaterRationCan",false,"ration",mode=="sp")
        assert(Open.recipeKind(f.p,f.shell,f.recipe)=="fluid")
        f:menu();f:start()
        local result
        local function deliver()
            if mode~="old-only" and mode~="floor" and mode~="lost" then result=f:add(6) end
            if mode=="tainted" then result.fluid.tainted=true end
            if mode=="wrong-amount" then result.fluid.amount=.1 end
            if mode=="mixture" then result.fluid.water=.15 end
            if mode=="floor" then f:drop() end
            f:retire()
        end
        if mode=="sp" then f.synchronous=deliver else deliver() end
        f:done()
        if mode=="lost" then f:add(6) end
        f.h,f.t=.2,.05;f:settle()
        local good=mode=="mp" or mode=="sp" or mode=="fluid-replica"
        if good then
            assert(#f.bites==1 and f.bites[1].value==result and math.abs(f.bites[1].portion-1/3)<.00001,f.job.reason)
            assert(f.q.current.Type=="ISDrinkFluidAction")
            if mode=="fluid-replica" then
                result.fluid=f.old.fluid
                assert(f.q.current:waitToStart())
                f.job:tick()
                assert(not f.requested and not f.job:isBusy())
            else
                assert(not f.q.current:waitToStart())
                f.q.current:start();assert(f.requested==result)
            end
        else assert(#f.bites==0 and not f.job:isBusy(),mode..": "..tostring(f.job.reason)) end
        assert(f.old.fluid.amount==.3 and f.nested.fluid.amount==.3)
    end
end)

test("unlabeled and dented cans require the stock read-only ID notice and still reject unsafe food",function()
    for _,mode in ipairs({"event-first","item-first","dented","sp","unsafe-dented","poison-dented","missing-event",
        "late-event","fake-id","prior-id","wrong-event","duplicate-event","two-items","no-label","split-screen","cancel"}) do
        local dented=mode=="dented" or mode=="unsafe-dented" or mode=="poison-dented"
        local f=fixture(dented and "DentedCan" or "MysteryCan",false,dented and "dented" or "mystery",mode=="sp")
        local cmd=dented and "OpenDentedCan" or "OpenMysteryCan"
        if mode=="split-screen" then
            f.players=2
            assert(Open.recipeKind(f.p,f.shell,f.recipe)=="food" and not Open.replacement(f.p,f.shell,f.recipe))
        else
            local foreignCalls=0
            local foreign=function() foreignCalls=foreignCalls+1 end
            Events.OnServerCommand.Add(foreign)
            f:menu()
            assert(#f.hooks==1,"observer never listens before owned native start")
            f:start()
            assert(#f.hooks==(mode=="sp" and 1 or 2))
            local result
            local function deliver()
                result=f:add(6)
                if mode=="two-items" then f:add(7) end
                if mode=="unsafe-dented" then result.unsafe=true end
                if mode=="poison-dented" then result.poison=3 end
                if mode=="no-label" then result.mod.NoLabel=nil end
            end
            if mode=="event-first" then
                f:event(cmd,{itemId=6});f.job:tick();assert(#f.bites==0)
            end
            if mode=="sp" then f.synchronous=function() deliver();f:retire() end
            else
                deliver()
                if mode=="item-first" then f.job:tick();assert(#f.bites==0) end
                if mode~="missing-event" and mode~="late-event" and mode~="event-first" then
                    local id=mode=="prior-id" and f.old.id or mode=="fake-id" and 999 or 6
                    f:event(mode=="wrong-event" and "OpenDentedCan" or cmd,{itemId=id})
                    if mode=="duplicate-event" then f:event(cmd,{itemId=6}) end
                end
                f:retire()
            end
            if mode=="cancel" then f.job:cancel() else f:done() end
            if mode=="late-event" then f:event(cmd,{itemId=6}) end
            f:settle()
            local good=mode=="event-first" or mode=="item-first" or mode=="dented" or mode=="sp"
            if good then assert(#f.bites==1 and f.bites[1].value==result,f.job.reason)
            else assert(#f.bites==0 and not f.job:isBusy(),mode..": "..tostring(f.job.reason)) end
            assert(#f.hooks==1 and f.hooks[1]==foreign,mode)
            if mode~="sp" and mode~="missing-event" then assert(foreignCalls>0) end
        end
    end
end)

print("PASS "..total.." mapped MP opening controller cases")
