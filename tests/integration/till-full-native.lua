-- Actual adapter with native queue/action boundary doubles; not game acceptance.
package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
package.preload["TimedActions/ISTimedActionQueue"] = function() end
package.preload["ISUI/ISInventoryPaneContextMenu"] = function() end
local Native = require "LootBox/TillFullNative"
local tests = 0
local function fixture()
    local f = {time = 0, target = false, actions = {}, calls = {}}
    getTimestampMs = function() return f.time end
    f.player = {getPlayerNum = function() return 2 end}
    f.item = {isSealed = function() return false end, getOpeningRecipe = function() return nil end}
    local q = {queue = {}}
    function q:removeFromQueue(a) for i,v in ipairs(self.queue) do if v == a then table.remove(self.queue,i); return end end end
    function q:addToQueue(a)
        table.insert(self.queue,a)
        if not self.current then self.current = a; a.action = {}; a:start() end
    end
    f.queue = q
    function f:action(kind)
        local a = {Type = kind, start = function() end, forceCancel = function(self) self.cancelled = true end}
        function a:stop() q.queue = {}; q.current = nil; self.stopped = true end
        function a:forceStop() self:stop() end
        function a:perform()
            self.performed = true; q:removeFromQueue(self); q.current = nil
            if q.queue[1] then q.current = q.queue[1]; q.current.action = {}; q.current:start() end
        end
        f.actions[#f.actions+1] = a
        return a
    end
    ISTimedActionQueue = {getTimedActionQueue = function() return q end,add=function(a) return q:addToQueue(a) end}
    function f:dispatch(kind, portion)
        f.calls[#f.calls+1] = {kind,portion}
        if not f.noPrep then q:addToQueue(f:action("Transfer")) end
        if f.throwBeforeConsume then error("wrapper failed") end
        q:addToQueue(f:action(kind == "food" and "ISEatFoodAction" or "ISDrinkFluidAction"))
        q:addToQueue(f:action("WearMask")); q:addToQueue(f:action("ReturnContainer"))
    end
    ISInventoryPaneContextMenu = {
        eatItem = function(item,p,player) assert(item==f.item and player==2); f:dispatch("food",p) end,
        onDrinkFluid = function(item,p,player) assert(item==f.item and player==f.player); f:dispatch("fluid",p) end,
    }
    f.native = Native.new(f.player)
    function f:begin(kind,p) return self.native:begin(self.item,kind or "food",p or .25,function() return self.target end) end
    function f:finish() while q.current do q.current:perform() end end
    return f
end
local function test(name,fn) fn(fixture()); tests=tests+1; print("PASS "..name) end

test("wrapper portions and complete restoration for both native kinds",function(f)
    for _,kind in ipairs({"food","fluid"}) do
        assert(f:begin(kind,.4)); assert(f.native:poll()==nil)
        f:finish(); assert(f.native:poll()==true and not f.native:isBusy())
        assert(f.calls[#f.calls][1]==kind and f.calls[#f.calls][2]==.4)
    end
end)
test("reject invalid admission before wrapper dispatch",function(f)
    for _,p in ipairs({0,-1,1.01,math.huge,0/0}) do assert(not f.native:begin(f.item,"food",p,function() return false end)) end
    f.item.isSealed=function() return true end; assert(not f:begin())

    assert(#f.calls==0)
end)
test("busy and already full do not queue",function(f)
    f.target=true; assert(not f:begin()); f.target=false
    f.queue:addToQueue(f:action("Foreign")); assert(not f:begin() and #f.calls==0)
end)
test("target stops only consumption and preserves restoration and foreign ordering",function(f)
    assert(f:begin()); f.queue.current:perform() -- transfer -> consume
    local consume=f.queue.current
    local foreign=f:action("Foreign"); f.queue:addToQueue(foreign)
    f.target=true
    assert(f.native:poll()==nil and consume.stopped)
    assert(f.queue.queue[1].Type=="WearMask" and f.queue.queue[2].Type=="ReturnContainer" and f.queue.queue[3]==foreign)
    f.queue.current:perform(); f.queue.current:perform()
    local done,reason=f.native:poll(); assert(done==false and reason:find("limit") and f.queue.current==foreign)
    assert(not foreign.cancelled and not foreign.stopped)
end)
test("foreign work cancels preparation without running consumption",function(f)
    assert(f:begin()); local foreign=f:action("Foreign"); f.queue:addToQueue(foreign)
    local done,reason=f.native:poll()
    assert(done==nil and f.queue.current.Type=="WearMask")
    f.queue.current:perform(); f.queue.current:perform()
    done,reason=f.native:poll()
    assert(done==false and reason:find("Another") and f.queue.current==foreign)
    for _,a in ipairs(f.actions) do if a.Type=="ISEatFoodAction" then assert(a.cancelled and not a.performed) end end
end)
test("manual native consumption stop cannot auto resume but restores",function(f)
    assert(f:begin()); f.queue.current:perform(); f.queue.current:stop()
    f:finish(); local done,reason=f.native:poll()
    assert(done==false and reason:find("interrupted") and #f.calls==1)
end)
test("wrapper failure cleans own preparation",function(f)
    f.throwBeforeConsume=true
    local ok,reason=f:begin(); assert(not ok and reason:find("preparation failed"))
    assert(f.native:poll()==false and #f.queue.queue==0 and not f.native:isBusy())
end)
test("predicate errors cancel owned action only",function(f)
    assert(f.native:begin(f.item,"food",.5,function() if f.time>0 then error("bad stat") end return false end))
    f.time=1; f.native:poll(); f:finish(); local done,reason=f.native:poll(); assert(done==false and reason:find("fullness"))
end)
test("timeout and player interruption are terminal",function(f)
    assert(f:begin()); f.time=120001; f.native:poll(); f:finish(); local done,reason=f.native:poll(); assert(done==false and reason:find("timed out"))
    assert(f:begin()); f.player.isRunning=function() return true end
    f.native:poll(); f:finish(); done,reason=f.native:poll(); assert(done==false and reason:find("interrupted"))
end)
test("missing completion observation never reports success",function(f)
    assert(f:begin()); f.queue.queue={}; f.queue.current=nil
    assert(f.native:poll()==false)
end)
test("unsealed recipe metadata does not block ordinary native consumption",function(f)
    f.item.getOpeningRecipe=function() return "OpenCan" end
    assert(f:begin()); f:finish(); assert(f.native:poll()==true)
end)
test("native invalid restoration cannot discard foreign queued work",function(f)
    assert(f:begin()); f.queue.current:perform()
    local foreign=f:action("Foreign"); f.queue:addToQueue(foreign)
    -- Native onCompleted invalid-start path cancels remaining actions/resetQueue.
    -- Invoke the original behavior via the captured closure's queue mutation.
    local wear=f.queue.queue[2]
    wear.start=function()
        for _,a in ipairs(f.queue.queue) do a:forceCancel() end
        f.queue.queue={}; f.queue.current=nil
    end
    f.queue.current:perform()
    local done,reason=f.native:poll()
    assert(done==false and reason and f.queue.current==foreign and not foreign.cancelled)
end)
test("interrupted player and required adjunct reject before any preparation",function(f)
    for _,name in ipairs({"isDead","isAsleep","isRunning","isSprinting","isAiming","isAttacking"}) do
        f.player[name]=function() return true end
        assert(not f:begin() and #f.calls==0)
        f.player[name]=nil
    end
    f.item.getRequireInHandOrInventory=function() return {size=function() return 1 end} end
    assert(not f:begin() and #f.calls==0)
    f.item.getRequireInHandOrInventory=function() return {size=function() return 0 end} end
    assert(f:begin())
end)
test("carried worn held and attached consumption does not mutate equipment",function()
    for _,kind in ipairs({"food","fluid"}) do
    for _,equipment in ipairs({"worn","held","attached"}) do
        for _,cancel in ipairs({false,true}) do
            local f=fixture()
            f.noPrep=true -- Carried item: native wrapper needs no inventory transfer.
            local inventory={}
            f.item.getContainer=function() return inventory end
            f.player.getInventory=function() return inventory end
            f.item.isWorn=function() return equipment=="worn" end
            f.item.isEquipped=function() return equipment=="worn" or equipment=="held" end
            f.player.isEquipped=function(_,item) return item==f.item and equipment~="attached" end
            f.player.getPrimaryHandItem=function() return equipment=="held" and f.item or nil end
            f.item.getAttachedSlot=function() return equipment=="attached" and 2 or -1 end
            local function forbidden() error("Consumption adapter must not mutate equipment") end
            f.player.setPrimaryHandItem=forbidden
            f.player.setSecondaryHandItem=forbidden
            f.player.setWornItem=forbidden
            f.player.removeWornItem=forbidden
            f.player.setAttachedItem=forbidden
            f.player.removeAttachedItem=forbidden
            f.item.setAttachedSlot=forbidden
            f.item.setAttachedSlotType=forbidden
            assert(f:begin(kind,.25))
            local actionType=kind=="food" and "ISEatFoodAction" or "ISDrinkFluidAction"
            assert(f.queue.current.Type==actionType and f.calls[1][1]==kind)
            if cancel then
                f.native:cancel("User cancelled")
                assert(f.queue.current.Type=="WearMask")
            end
            f:finish()
            local done,reason=f.native:poll()
            assert(done==not cancel and not f.native:isBusy())
            if cancel then assert(reason=="User cancelled") end
            assert(f.item:getContainer()==inventory)
            assert(f.item:isWorn()==(equipment=="worn"))
            assert(f.item:isEquipped()==(equipment=="worn" or equipment=="held"))
            assert(f.player:getPrimaryHandItem()==(equipment=="held" and f.item or nil))
            assert(f.item:getAttachedSlot()==(equipment=="attached" and 2 or -1))
            assert(#f.calls==1)
        end
    end
    end
end)
test("real controller and adapter wait for deferred item and nutrition completion",function(f)
    CharacterStat={HUNGER={getMinimumValue=function() return 0 end},THIRST={getMinimumValue=function() return 0 end}}
    function instanceof(item,name) return name=='Food' end
    local Full=require 'LootBox/TillFull'
    local inv={}
    f.player.h=.1;f.player.t=0
    function f.player:getStats() return {get=function(_,k) return k==CharacterStat.HUNGER and f.player.h or f.player.t end} end
    function f.player:getInventory() return inv end
    function f.player:isDead() return false end
    function f.player:isAsleep() return false end
    local item={h=.2,base=.2}
    f.item=item
    function item:getID() return 1 end
    function item:getFullType() return 'Base.Candy' end
    function item:getContainer() return inv end
    function item:getHungerChange() return -self.h end
    function item:getHungChange() return -self.h end
    function item:getBaseHunger() return -self.base end
    function item:getThirstChange() return 0 end
    function item:getScriptItem() return {isCantEat=function() return false end} end
    for _,k in ipairs({'isSealed','isRotten','isBurnt','isFrozen','isTainted','isPoison','isAlcoholic','isbDangerousUncooked'}) do item[k]=function() return false end end
    function item:getPoisonPower() return 0 end
    function item:getFoodSicknessChange() return 0 end
    local c=assert(Full.new(f.player,{protected=function() return false end},{item},'food'))
    c:tick();assert(#f.calls==1)
    f:finish() -- Actual adapter hooks perform(), no nutrition applied yet.
    c:tick();assert(#f.calls==1 and c:isBusy())
    f.time=100;item.h=.1;f.player.h=0 -- Deferred completion from game boundary.
    c:tick();assert(#f.calls==1 and c.state=='finished')
end)

local function openingFixture(f)
    local inventory, source, recipe = {}, {}, {}
    f.inventory, f.source, f.recipe = inventory, source, recipe
    f.player.getInventory = function() return inventory end
    f.item = {id=1, sealed=true, container=source, kind="food"}
    function f.item:getID() return self.id end
    function f.item:getContainer() return self.container end
    function f.item:isSealed() return self.sealed end
    function f.item:getOpeningRecipe() return "OpenTest" end
    function f.item:getFluidContainer() return self.kind=="fluid" and {} or nil end
    f.outputs={}
    isClient=function() return f.client==true end
    instanceof=function(item,name) return name=="Food" and item.kind=="food" end
    ArrayList={new=function()
        return {values={},size=function(self) return #self.values end,get=function(self,i) return self.values[i+1] end}
    end}
    getScriptManager=function() return {getCraftRecipe=function(_,name) return name=="OpenTest" and recipe end} end
    ISEntityUI={HandcraftStart=function(player,logic,force,addToQueue,eat)
        assert(player==f.player and not force and eat==0)
        if f.noCraft then return end
        local a=f:action("ISHandcraftAction")
        a.character=f.player;a.craftRecipe=recipe;a.eatPercentage=eat
        a.manualInputs={[1]={size=function() return 1 end,get=function() return f.wrongInput or f.item end}}
        if f.autoInputs then a.manualInputs=false end
        a.logic={getRecipeData=function()
            return {getAllCreatedItems=function()
                return {size=function() return #f.outputs end,get=function(_,i) return f.outputs[i+1] end}
            end}
        end}
        local perform=a.perform
        function a:perform()
            if f.unseal then f.item.sealed=false;f.item.container=inventory end
            return perform(self)
        end
        if addToQueue then f.queue:addToQueue(a) end
        return a
    end}
    f.originalHandcraftStart=ISEntityUI.HandcraftStart
    ISInventoryPaneContextMenu.OnNewCraft=function(item,r,p,all,eat)
        assert(item==f.item and r==recipe and p==2 and all==false and eat==0)
        f.calls[#f.calls+1]={"opening",eat}
        f.queue:addToQueue(f:action("Transfer"))
        ISEntityUI.HandcraftStart(f.player,{},false,true,eat)
        f.queue:addToQueue(f:action("ReturnOpener"))
    end
    function f:open(kind) return self.native:beginOpen(self.item,kind or "food",recipe,function() return self.target end) end
    function f:output(kind)
        local result={kind=kind or "food",container=inventory}
        function result:getContainer() return self.container end
        function result:isSealed() return false end
        function result:getFluidContainer() return self.kind=="fluid" and {} or nil end
        f.outputs[#f.outputs+1]=result
        return result
    end
end

test("opening dispatch never requests native auto-eat and returns exact craft result",function(f)
    openingFixture(f)
    local result=f:output()
    assert(f:open());assert(f.native:poll()==nil);f:finish()
    local done,reason,item=f.native:poll()
    assert(done and reason=="opened" and item==result and #f.calls==1 and f.calls[1][2]==0)
end)
test("MP fluid opening waits for exact item unseal not client perform",function(f)
    openingFixture(f);f.client=true;f.item.kind="fluid"
    assert(f:open("fluid"));f:finish();assert(f.native:poll()==nil)
    f.time=500;assert(f.native:poll()==nil)
    f.item.sealed=false;f.item.container=f.inventory
    local done,reason,item=f.native:poll()
    assert(done and reason=="opened" and item==f.item)
end)
test("MP food opens only and asks the user to choose the actual result",function(f)
    openingFixture(f);f.client=true
    assert(f:open());assert(f.native:poll()==nil);f:finish()
    local done,reason,item=f.native:poll()
    assert(done and reason=="chooseOpened" and item==nil and #f.calls==1 and f.calls[1][2]==0)
    assert(not f.native:isBusy() and #f.queue.queue==0)
    assert(f.item.sealed) -- client perform is not an acknowledgement of server output.
end)
test("MP food fallback never reports a choice after target or cancellation stops opening",function()
    for _,mode in ipairs({"target","cancel","timeout","missing"}) do
        local f=fixture();openingFixture(f);f.client=true;assert(f:open())
        if mode=="target" then f.target=true
        elseif mode=="cancel" then f.native:cancel("User cancelled")
        elseif mode=="timeout" then f.time=120001
        else f.queue.queue={};f.queue.current=nil end
        f.native:poll();f:finish()
        local done,reason,item=f.native:poll()
        assert(done==false and reason~="chooseOpened" and item==nil and #f.calls==1)
    end
end)
test("opening requires current recipe and empty queue before native dispatch",function(f)
    openingFixture(f)
    assert(not f.native:beginOpen(f.item,"food",{},function() return false end))
    f.target=true;assert(not f:open());f.target=false
    f.queue:addToQueue(f:action("Foreign"));assert(not f:open() and #f.calls==0)
end)
test("missing or ambiguous opening output never guesses an inventory peer",function(f)
    openingFixture(f);f.item.sealed=false
    assert(f:open());f:finish();assert(f.native:poll()==nil)
    f.time=2001;local done,reason=f.native:poll()
    assert(done==false and reason:find("not confirmed") and #f.calls==1)
    f.outputs={};f:output();f:output();assert(f:open());f:finish()
    done,reason=f.native:poll();assert(done==false and reason:find("multiple"))
end)
test("MP unseal requires stable item identity and authorized source",function(f)
    openingFixture(f);f.client=true;f.item.kind="fluid"
    assert(f:open("fluid"));f:finish()
    f.item.sealed=false;f.item.id=2;assert(f.native:poll()==nil)
    f.item.id=1;f.item.container={};assert(f.native:poll()==nil)
    f.time=2001;assert(f.native:poll()==false and #f.calls==1)
end)
test("opening stop preserves returned opener and foreign work",function(f)
    openingFixture(f)
    assert(f:open());f.queue.current:perform()
    local craft=f.queue.current;local foreign=f:action("Foreign");f.queue:addToQueue(foreign)
    f.native:cancel("User cancelled")
    assert(craft.stopped and f.queue.current.Type=="ReturnOpener")
    f.queue.current:perform()
    local done,reason=f.native:poll()
    assert(done==false and reason=="User cancelled" and f.queue.current==foreign)
    assert(not foreign.cancelled and not foreign.stopped and #f.calls==1)
end)
test("failed opening preparation cancels owned actions without consumption",function(f)
    openingFixture(f);f.noCraft=true
    assert(not f:open());f:finish();local done=f.native:poll()
    assert(done==false and not f.native:isBusy() and #f.queue.queue==0)
end)
test("native manual input binding rejects a substituted peer before craft admission",function()
    for _,mode in ipairs({"other","auto"}) do
        local f=fixture();openingFixture(f)
        if mode=="other" then f.wrongInput={} else f.autoInputs=true end
        local ok,reason=f:open()
        assert(not ok and reason:find("bind") and f.queue.current.Type=="ReturnOpener")
        assert(ISEntityUI.HandcraftStart==f.originalHandcraftStart)
        for _,action in ipairs(f.queue.queue) do assert(action.Type~="ISHandcraftAction") end
        f:finish();assert(f.native:poll()==false)
    end
end)
test("scoped craft guard restores the original factory after native exceptions",function(f)
    openingFixture(f)
    ISInventoryPaneContextMenu.OnNewCraft=function() error("native dispatch failure") end
    assert(not f:open())
    assert(ISEntityUI.HandcraftStart==f.originalHandcraftStart)
    assert(f.native:poll()==false)
end)

print("PASS "..tests.." Till Full native boundary scenarios")

