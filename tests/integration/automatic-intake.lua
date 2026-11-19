-- Actual automatic controller and native adapter; double engine boundary only.
package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
package.preload["TimedActions/ISTimedActionQueue"] = function() end
package.preload["ISUI/ISInventoryPaneContextMenu"] = function() end
package.loaded["LootBox/CompletionFeedback"] = {consume=function() error("Automatic intake must stay quiet") end}
CharacterStat = {HUNGER={getMinimumValue=function() return 0 end}, THIRST={getMinimumValue=function() return 0 end}}
CharacterTrait = {DISORGANIZED="disorganized"}
FluidCategory = {Water=1, Beverage=2, Hazardous=3, Alcoholic=4, Medical=5, Fuel=6, Industrial=7, Poisons=8, Blood=9, Drug=10}
local Full = require "LootBox/TillFull"

local function fixture(kind, nested)
    local f = {now=0, safe=true, bag={}, main={}, dispatch={}, applied=0, released=0}
    function getTimestampMs() return f.now end
    function isClient() return f.mp == true end
    function isServer() return false end
    function instanceof(item, class) return item.food and class == "Food" end
    local p = {h=.2,t=.2}
    function p:getStats() return {get=function(_,k) return k==CharacterStat.HUNGER and p.h or p.t end} end
    function p:getInventory() return f.main end
    function p:getPlayerNum() return 0 end
    function p:isDead() return false end
    function p:isAsleep() return false end
    function p:isPlayerMoving() return f.moving end
    function p:hasTrait() return f.disorganized end
    f.p = p
    local item = {food=kind=="food",id=42,amount=1,source=nested and f.bag or f.main}
    function item:getID() return self.id end
    function item:getContainer() return self.source end
    function item:getFullType() return "Base.TestIntake" end
    function item:isSealed() return f.sealed end
    function item:getScriptItem() return {isCantEat=function() return f.cantEat end} end
    function item:getHungerChange() return item.food and -.4*self.amount or 0 end
    function item:getThirstChange() return f.detrimental and .1 or 0 end
    function item:getHungChange() return self:getHungerChange() end
    function item:getBaseHunger() return -.4 end
    function item:getRequireInHandOrInventory() return f.required end
    function item:getPoisonPower() return f.poison or 0 end
    function item:getFoodSicknessChange() return 0 end
    function item:isMedical() return f.medical end
    function item:getCustomMenuOption() return f.custom end
    function item:getOnEat() return f.onEat end
    for _,name in ipairs({"isRotten","isBurnt","isFrozen","isTainted","isPoison","isAlcoholic","isbDangerousUncooked"}) do
        item[name]=function() return f[name] or false end
    end
    local props = {getHungerChange=function() return 0 end, getThirstChange=function() return -.4*item.amount end,
        getPoison=function() return 0 end,getAlcohol=function() return 0 end,getFoodSicknessChange=function() return 0 end}
    local fluid = {getCapacity=function() return 1 end,isEmpty=function() return item.amount<=0 end,
        getProperties=function() return props end,canPlayerEmpty=function() return true end,getFilledRatio=function() return item.amount end,
        isTainted=function() return false end,isPoisonous=function() return false end}
    local part = {isCategory=function(_,c) return c == FluidCategory.Water or (f.hazard and c==FluidCategory.Hazardous)
            or c==f.extraCategory end,
        isPoisonous=function() return false end,getProperties=function() return props end}
    function part:getCategories()
        return {size=function() return f.unknownCategory and 2 or (f.extraCategory and 2 or 1) end}
    end
    function fluid:isMixture() return not f.pure end
    function fluid:getPrimaryFluid() return part end
    function fluid:createFluidSample()
        return {size=function() return f.emptySample and 0 or 1 end,getPercentage=function() return 1 end,
            getFluid=function() return part end,release=function() f.released=f.released+1 end}
    end
    function item:getFluidContainer() if not self.food then return f.otherFluid or fluid end end
    f.item, f.original = item,item.source

    local q = {queue={}}
    function q:removeFromQueue(action)
        for i,a in ipairs(self.queue) do if a==action then table.remove(self.queue,i); return end end
    end
    function q:addToQueue(action)
        self.queue[#self.queue+1]=action
        if not self.current then
            self.current=action
            action.action={}
            action:start()
        end
    end
    ISTimedActionQueue = {getTimedActionQueue=function() return q end,add=function(a) return q:addToQueue(a) end}
    local function action(typ, exact)
        local a = {Type=typ,item=exact,character=p}
        function a:isValid() return true end
        function a:isValidStart() return not f.stuffed end
        function a:start() self.started=(self.started or 0)+1 end
        function a:forceCancel() self.cancelled=true end
        function a:stop()
            -- Stock food may apply partial nutrition on stop. Unsafe
            -- automatic interruption must not take that fallback route.
            if self.serverStop then self:serverStop() end
            for _,b in ipairs(q.queue) do if b~=self then b:forceCancel() end end
            q.queue={}; q.current=nil; self.stopped=true
        end
        function a:forceStop() self:stop() end
        function a:perform() q:removeFromQueue(self); q.current=nil; self.performed=true end
        return a
    end
    f.q, f.action = q, action
    local function consume(typ, exact, portion)
        local a = action(typ, exact)
        a.fluidContainer=exact:getFluidContainer()
        if exact.food then function a:serverStop() f.applied=f.applied+1 end end
        local function apply()
            f.applied=f.applied+1
            exact.amount=exact.amount-portion
            if exact.amount<=0 and exact.food then exact.source=nil end
            if exact.food then p.h=math.max(0,p.h-.4*portion) else p.t=math.max(0,p.t-.4*portion) end
            return true
        end
        if exact.food then
            function a:complete() return apply() end
            function a:update() self.updated=true end
        else
            function a:updateEat() return apply() end
            function a:complete() return self:updateEat(1) end
            function a:update() self.updated=true; return self:updateEat(.25) end
        end
        return a
    end
    ISEatFoodAction = {new=function(_,character,exact,portion)
        assert(character==p and (exact==item or exact==f.opened))
        f.dispatch[#f.dispatch+1]="eat"
        return consume("ISEatFoodAction", exact, portion)
    end}
    ISDrinkFluidAction = {new=function(_,character,exact,portion)
        assert(character==p and exact==item)
        f.dispatch[#f.dispatch+1]="drink"
        return consume("ISDrinkFluidAction", exact, portion)
    end}
    ISInventoryTransferUtil = {newInventoryTransferAction=function(character,exact,source,dest)
        assert(character==p and exact==item and source==item.source)
        f.dispatch[#f.dispatch+1]=dest==f.main and "pickup" or "return"
        local a=action("ISInventoryTransferAction",exact)
        a.srcContainer,a.destContainer=source,dest
        local perform=a.perform
        function a:perform()
            if self:isValid() and not f.unconfirmedTransfer then exact.source=dest end
            return perform(self)
        end
        return a
    end}
    ISInventoryPaneContextMenu = {
        getEatingMask=function(_, mutate) assert(mutate==false); return f.mask end,
        OnNewCraft=function() error("auto must not choose tools via stock wrapper") end,
        eatItem=function() error("auto must not use broad Eat wrapper") end,
        onDrinkFluid=function() error("auto must not use broad Drink wrapper") end,
    }
    f.world={protected=function() return false end}
    f.context={guard=function(exact, source, phase)
        assert((exact==item or exact==f.opened) and source==f.original)
        f.lastPhase=phase
        return f.safe and (phase~="return" or f.returnAllowed~=false)
    end}
    f.controller=assert(Full.new(p,f.world,{item},kind,false,nil,nil,f.context))
    function f:opening()
        self.sealed=true; self.openingPlan={}
        self.context.openingPlan=self.openingPlan
        self.controller=assert(Full.new(p,self.world,{item},kind,false,nil,nil,self.context))
        package.loaded["LootBox/NeedsOpening"] = {
            action=function(character,plan,allowed)
                assert(character==p and plan==f.openingPlan and allowed())
                local a=action("ISHandcraftAction", nil)
                local finished=a.perform
                function a:perform()
                    self:performRecipe()
                    return finished(self)
                end
                function a:performRecipe()
                    f.crafted=(f.crafted or 0)+1
                    local opened={}
                    for key,value in pairs(item) do opened[key]=value end
                    opened.id=43; function opened:isSealed() return false end
                    item.source=nil; f.opened=opened
                    return true
                end
                f.dispatch[#f.dispatch+1]="open"
                return a
            end,
            ready=function(character,plan,native)
                return character==p and plan==f.openingPlan and native.Type=="ISHandcraftAction" and not f.staleBinding
            end,
            output=function(character,plan,native)
                assert(character==p and plan==f.openingPlan and native.Type=="ISHandcraftAction" and not native.performed)
                return not f.missingOutput and f.opened or nil
            end,
        }
    end
    function f:tick(ms) self.now=self.now+(ms or 20); self.controller:tick() end
    function f:perform()
        local a=assert(q.current); a:perform(); if a.complete then a:complete() end
        return a
    end
    return f
end
local count=0
local function test(name,f) f(); count=count+1; print("PASS "..name) end

test("exact direct native food consumes one portion and ends silently",function()
    local f=fixture("food"); f:tick(); assert(f.lastPhase=="consume" and f.q.current.stopOnWalk and f.q.current.stopOnAim)
    f:perform(); f:tick(); f:tick()
    assert(f.applied==1 and f.p.h==0 and f.item.amount==.5 and not f.controller:isBusy() and #f.dispatch==1)
end)
test("exact nested intake picks up, then consumes and returns only the original candidate",function()
    local f=fixture("fluid",true); f:tick()
    assert(f.lastPhase=="prepare" and table.concat(f.dispatch,",")=="pickup" and not f.q.current:canMergeAction())
    f:perform(); f:tick(); assert(f.lastPhase=="consume" and f.item.source==f.main)
    f:perform(); f:tick(); assert(f.lastPhase=="return" and table.concat(f.dispatch,",")=="pickup,drink,return")
    f:perform(); f:tick()
    assert(f.item.source==f.bag and f.applied==1 and not f.controller:isBusy())
end)
test("bag or exact item identity ambiguity prevents any consumption after pickup",function()
    for _,problem in ipairs({"bag","identity","mp"}) do
        local f=fixture("food",true); f:tick()
        if problem=="mp" then f.mp=true; f.unconfirmedTransfer=true end
        f:perform()
        if problem=="bag" then f.safe=false elseif problem=="identity" then f.item.id=123 end
        f:tick(); f:tick(2001)
        assert(f.applied==0 and #f.dispatch==1 and not f.controller:isBusy())
    end
end)
test("movement or unsafe food invalidates the action without a partial stop bite",function()
    for _,problem in ipairs({"movement","poison","intent"}) do
        local f=fixture("food"); f:tick()
        local a=f.q.current
        if problem=="movement" then f.moving=true elseif problem=="poison" then f.poison=1 else f.safe=false end
        assert(not a:isValid())
        f:tick(); f:tick()
        assert(a.stopped and f.applied==0 and #f.dispatch==1 and not f.controller:isBusy())
    end
end)
test("foreign action wins without removal or unsafe completion even between ticks",function()
    local f=fixture("food"); f:tick()
    local foreign=f.action("Foreign", nil)
    f.q:addToQueue(foreign)
    f:perform(); f:tick()
    assert(f.q.current==foreign and f.q.queue[1]==foreign and foreign.started==1 and not foreign.cancelled)
    assert(f.applied==0 and #f.dispatch==1 and not f.controller:isBusy())
end)
test("a harmful mixture introduced during drinking does not reach native update",function()
    local f=fixture("fluid"); f:tick()
    local a=f.q.current
    f.hazard=true; a:update()
    assert(a.updated and f.applied==0)
    f:tick(); f:tick()
    assert(a.stopped and f.applied==0 and f.released>0)
end)
test("automatic liquid refuses medical or other forbidden secondary categories even with Water",function()
    for _, category in ipairs({"Medical","Fuel","Industrial","Poisons","Blood","Drug","unknown"}) do
        for _, pure in ipairs({false,true}) do
            local f=fixture("fluid")
            f.pure=pure
            f.extraCategory=FluidCategory[category]; f.unknownCategory=category=="unknown"
            assert(not Full.automaticEffects(f.item,"fluid"),category)
            assert(f.released==(pure and 0 or 1))
        end
    end
end)
test("eligibility uses the primary pure fluid, and samples a live mixture only at mutation",function()
    local f=fixture("fluid"); f.pure=true; f:tick()
    local a=f.q.current
    assert(a:isValid() and f.released==0)
    f:perform(); f:tick(); assert(f.applied==1 and f.released==0)
    f=fixture("fluid"); f:tick(); a=f.q.current
    local samples=f.released
    f:tick(); assert(a:isValid() and f.released==samples)
    a:update(); assert(f.applied==1 and f.released==samples+1)
end)
test("vanilla relief arriving after admission prevents another automatic bite",function()
    local f=fixture("food"); f:tick()
    local a=f.q.current
    f.p.h=0
    assert(not a:isValid())
    f:tick(); f:tick()
    assert(a.stopped and f.applied==0 and #f.dispatch==1)
end)
test("a competing transfer is not merged and wins without the automatic pickup",function()
    local f=fixture("food",true); f:tick()
    local own=f.q.current
    local other=f.action("ISInventoryTransferAction",nil)
    f.q:addToQueue(other)
    f:perform(); f:tick()
    assert(not own:canMergeAction(other) and f.item.source==f.bag and f.q.current==other)
    assert(other.started==1 and not other.cancelled and #f.dispatch==1 and f.applied==0)
end)
test("mask or native stuffed restriction blocks without gear or transfer actions",function()
    local f=fixture("fluid",true); f.mask=true; f:tick()
    assert(#f.dispatch==0 and not f.q.current and not f.controller:isBusy())
    f=fixture("food"); f.stuffed=true; f:tick()
    assert(#f.dispatch==1 and not f.q.current and f.applied==0 and not f.controller:isBusy())
end)
test("return yields if native new work or bag protection is present",function()
    local f=fixture("fluid",true); f:tick(); f:perform(); f:tick(); f:perform()
    local foreign=f.action("Foreign",nil)
    f.q:addToQueue(foreign)
    f:tick()
    assert(f.q.current==foreign and #f.dispatch==2 and f.item.source==f.main and not f.controller:isBusy())
    f=fixture("fluid",true); f:tick(); f:perform(); f:tick(); f:perform(); f.returnAllowed=false; f:tick()
    assert(#f.dispatch==2 and f.item.source==f.main and not f.controller:isBusy())
end)
test("automatic eligibility is fail-closed for medications, harmful effects, and openings",function()
    for _,mode in ipairs({"medical","sealed","detrimental","poison","onEat","custom","cantEat","required","isRotten"}) do
        local f=fixture("food")
        f[mode] = mode=="custom" and "Take a pill" or mode=="poison" and 1 or true
        assert(not Full.automaticEffects(f.item,"food"),mode)
        f:tick(); assert(not f.q.current and f.applied==0 and not f.controller:isBusy())
    end
    local plain=fixture("food")
    plain.required={size=function()return 0 end}
    assert(Full.automaticEffects(plain.item,"food"),"An empty native equipment-requirements list is not a requirement")
    plain.required={size=function()return 1 end}
    assert(not Full.automaticEffects(plain.item,"food"),"Do not silently skip required equipment")
    local f=fixture("fluid"); f.emptySample=true
    assert(not Full.automaticEffects(f.item,"fluid") and f.released==1)
    assert(not Full.new(f.p,f.world,{f.item},"fluid",false,{},nil,f.context))
end)

test("exact SP opener follows only its synchronously identified native output",function()
    local f=fixture("food"); f:opening(); f:tick()
    assert(f.q.current.Type=="ISHandcraftAction" and f.lastPhase=="open")
    f:perform(); f:tick()
    assert(f.crafted==1 and f.q.current.item==f.opened and f.q.current.item~=f.item)
    f:perform(); f:tick()
    assert(f.applied==1 and table.concat(f.dispatch,",")=="open,eat" and not f.controller:isBusy())
end)
test("unsafe or ambiguous opening has no automatic bite or second craft",function()
    for _,problem in ipairs({"foreign","stale-binding","absent-output","mp"}) do
        local f=fixture("food"); f:opening(); f.mp=problem=="mp"
        f:tick()
        if problem=="mp" then
            assert(not f.q.current and #f.dispatch==0)
        else
            local other
            if problem=="foreign" then other=f.action("Foreign",nil); f.q:addToQueue(other)
            elseif problem=="stale-binding" then f.staleBinding=true
            else f.missingOutput=true end
            f:perform(); f:tick()
            assert(f.q.current==other and not f.controller:isBusy())
            assert(f.applied==0 and #f.dispatch==1)
            if other then assert(not f.crafted and other.started==1 and not other.cancelled)
            elseif problem=="stale-binding" then assert(not f.crafted)
            else assert(f.crafted==1) end
        end
    end
end)

test("packaged scheduler, inventory filter and Til Full together run one native intake with the manager closed", function()
    for _,kind in ipairs({"food","fluid"}) do
        package.loaded["LootBox/AutoNeeds"], package.loaded["LootBox/NeedsInventory"], package.loaded["LootBox/NeedsOpening"]=nil,nil,nil
        local auto=require "LootBox/AutoNeeds"
        local f=fixture(kind);local p,item,main=f.p,f.item,f.main
        f.sealed=false;f.pure=true
        function item:isFavorite()return false end
        function item:isWaterOnlySource()return false end
        function main:getType()return "inventory" end
        function main:isLockedToCharacter()return false end
        function main:getItems()return {size=function()return 1 end,get=function()return item end,contains=function(_,v)return v==item end} end
        function p:isLocalPlayer()return true end;function p:getCurrentSquare()return {} end
        function p:getVehicle()return nil end;function p:getWaterSource()return nil end
        function p:getWornItems()return {contains=function(_,v)return kind=="fluid" and v==item end} end
        for _,k in ipairs({"isMoving","isSprinting","isRunning","isAttacking","isAiming","isKnockedDown","isClimbing","isbFalling","isPerformingGrappleAnimation","isShoving","hasTimedActions"}) do p[k]=function()return false end end
        local stat=p:getStats();for _,k in ipairs({"getNumVisibleZombies","getNumChasingZombies","getNumVeryCloseZombies"})do stat[k]=function()return 0 end end
        function p:getStats()return stat end;function getCore()return {getOptionAutoDrink=function()return true end} end
        if kind=="fluid" then
            local part=item:getFluidContainer():getPrimaryFluid()
            part.isCategory=function(_,cat)return cat==FluidCategory.Beverage end
            p.h,p.t=0,.3
        else p.h,p.t=.3,0 end
        local opts={autoDrinkEquipped=kind=="fluid",autoConsumeCarried=kind=="food"}
        local instance={player=p,world=f.world,recovery={status=function()return {pending=false} end},jobs={status=function()return {hasJob=false,canPreview=true} end}}
        auto.step(instance,opts,function()return opts end,0)
        assert(instance.consumption and f.q.current and f.q.current.item==item)
        f.controller=instance.consumption;f:perform();f:tick()
        assert(f.applied==1 and f.controller.state=="finished" and f.controller.count==1 and #f.dispatch==1)
    end
end)

print("PASS "..count.." native automatic intake contracts")
