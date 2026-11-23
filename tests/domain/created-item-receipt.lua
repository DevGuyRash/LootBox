package.path="Contents/mods/LootBox/42/media/lua/client/?.lua;"..package.path
local Receipt=require "LootBox/CreatedItemReceipt"
local count=0
local function test(name,fn) fn();count=count+1;print("PASS "..name) end
local function fixture()
    local function container()
        local v={items={}}
        function v:getItems()
            return {size=function() return #self.items end,get=function(_,index) return self.items[index+1] end}
        end
        function v:getContainingItem() return self.owner end
        return v
    end
    local main=container()
    local f={main=main,where=main,elsewhere=container(),at=0,anchored=false,predecessor={},owner={}}
    function f:add(id,fullType,dest)
        local item={id=id,fullType=fullType or "Base.CannedPeachesOpen",container=dest or main}
        function item:getID() return self.id end
        function item:getContainer() return self.container end
        function item:getFullType() return self.fullType end
        function item:getWorldItem() return self.worldItem end
        item.container.items[#item.container.items+1]=item
        return item
    end
    function f:remove(item)
        for i,v in ipairs(item.container.items) do if v==item then table.remove(item.container.items,i);break end end
        item.container=nil
    end
    function f:watch(overrides)
        local opts={inventory=function() return self.where end,
            matches=function(item) return item.fullType=="Base.CannedPeachesOpen" end,
            anchor=function() return self.anchored,self.anchorFailure end,
            clock=function() return self.at end}
        for k,v in pairs(overrides or {}) do opts[k]=v end
        return Receipt.begin(self.owner,opts)
    end
    return f
end

test("an exact created reference wins among identical opened items",function()
    local f=fixture();local prior=f:add(2)
    local watch=assert(f:watch())
    local separate=f:add(3);local actual=f:add(5);f.anchored=true
    assert(watch:poll()==nil)
    assert(watch:complete(f.owner,{item=actual}))
    local ok,item=watch:poll();assert(ok and item==actual and item~=prior and item~=separate)
    assert(watch:poll()==false)
end)
test("an authoritative ID can wait for either sync phase, never consume an earlier or later lookalike",function()
    for _,order in ipairs({"input-first","output-first"}) do
        local f=fixture();f:add(1)
        local watch=assert(f:watch({timeoutMs=800}))
        assert(watch:complete(f.owner,{id=5}))
        local decoy=f:add(3);assert(watch:poll()==nil)
        local actual
        f.at=250
        if order=="input-first" then f.anchored=true else actual=f:add(5) end
        assert(watch:poll()==nil)
        f.at=350
        if order=="input-first" then actual=f:add(5) else f.anchored=true end
        local ok,item=watch:poll();assert(ok and item==actual and item~=decoy)
    end
end)
test("stock completion from a previous user action or another player cannot claim this receipt",function()
    local f=fixture();local watch=assert(f:watch())
    local old=f:add(3)
    assert(not watch:complete(f.predecessor,{item=old}))
    assert(watch:poll()==nil)
    f.anchored=true;local actual=f:add(5)
    assert(watch:complete(f.owner,{item=actual}))
    local ok,item=watch:poll();assert(ok and item==actual)
end)
test("real-Done, exact closed shell gone, and one fresh matching ID do not prove replacement lineage",function()
    -- The two histories expose the identical local main snapshot. In one
    -- history this is our can. In the other, ours dropped off the observed
    -- tile or its receive skipped, and a previous ordinary action sent this.
    for _,history in ipairs({"actual-visible","actual-unavailable-with-delayed-stock-add"}) do
        local f=fixture()
        local previous=f:add(2);local watch=assert(f:watch())
        if history~="actual-visible" then f:add(777,nil,f.elsewhere) end
        f.anchored=true;local only=f:add(5)
        local ok,reason=watch:complete(f.owner,nil)
        assert(not ok and reason:find("did not identify",1,true))
        assert(watch:poll()==false and only~=previous)
    end
end)
test("ordered observations cannot opt themselves in without an actual stock delivery contract",function()
    for _,guarantee in ipairs({"missing","floor-possible","receive-skipped","source-unchanged"}) do
        local f=fixture();local opts={}
        if guarantee~="missing" then opts.deliveredBeforeDone=function() return guarantee=="source-unchanged" end end
        local watch=assert(f:watch(opts));f.anchored=guarantee~="source-unchanged";f:add(3)
        local ok=watch:complete(f.owner,{ordered=true})
        assert(not ok and watch:poll()==false,guarantee)
    end
end)
test("verified ordered one-output contract freezes only the exact completion-time observed ID",function()
    local f=fixture();f:add(1)
    local watch=assert(f:watch({deliveredBeforeDone=function(action,inv) return action==f.owner and inv==f.main end}))
    f.anchored=true;local actual=f:add(5);f:add(6,"Base.Nails")
    assert(watch:complete(f.owner,{ordered=true}))
    local after=f:add(7)
    local ok,item=watch:poll();assert(ok and item==actual and item~=after)
end)
test("a verified ordered observer stops on an earlier matching add, missing-at-Done, or later change of the frozen result",function()
    for _,mode in ipairs({"prior-add","missing","moved","replaced"}) do
        local f=fixture();local watch=assert(f:watch({timeoutMs=500,deliveredBeforeDone=function() return true end}))
        local actual
        if mode~="missing" then actual=f:add(5) end
        if mode=="prior-add" then f:add(7) end
        f.anchored=true
        local ready=watch:complete(f.owner,{ordered=true})
        if mode=="moved" or mode=="replaced" then
            assert(ready);f:remove(actual)
            if mode=="replaced" then f:add(5) end
            f:add(7)
            if mode=="moved" then assert(watch:poll()==nil);f.at=500 end
        else assert(not ready);f:add(8) end
        local ok=watch:poll()
        assert(ok==false,mode)
    end
end)
test("a synchronous producer can pin previous matching references as a custody invariant",function()
    for _,mode in ipairs({"preserved","swapped-at-complete","moved-before-use","retagged"}) do
        local f=fixture();local old=f:add(2);local unrelated=f:add(3,"Base.Nails")
        local watch=assert(f:watch({preserveMatching=true,deliveredBeforeDone=function() return true end}))
        f.anchored=true;local actual=f:add(5);f:remove(unrelated)
        if mode=="swapped-at-complete" then f:remove(old);f:add(2) end
        if mode=="retagged" then old.fullType="Base.Nails" end
        local accepted=watch:complete(f.owner,{ordered=true})
        if mode=="moved-before-use" then assert(accepted);f:remove(old);f:add(2) end
        local ok,item=watch:poll()
        if mode=="preserved" then assert(ok and item==actual) else assert(ok==false,mode) end
    end
end)
test("previous IDs, duplicate IDs, changed destination and unauthorized source never qualify",function()
    for _,mode in ipairs({"old-id","duplicate","destination","source","contradiction"}) do
        local f=fixture();local prior=f:add(2)
        local watch=assert(f:watch({timeoutMs=100}))
        local actual=f:add(5,nil,mode=="source" and f.elsewhere or f.main)
        f.anchored=true
        local ready=watch:complete(f.owner,{item=mode=="old-id" and prior or actual})
        if mode=="old-id" then assert(not ready) else assert(ready) end
        if mode=="duplicate" then f:add(5) end
        if mode=="destination" then f.where=f.elsewhere end
        if mode=="contradiction" then f.anchorFailure="Input state contradicted receipt" end
        if mode=="source" then assert(watch:poll()==nil);f.at=100 end
        assert(watch:poll()==false,mode)
    end
end)
test("producers can bound both total inventory and expected output class",function()
    local f=fixture();f:add(2);f:add(3,"Base.Nails");f:add(4,"Base.Nails")
    assert(not f:watch({maxItems=50,maxMatches=51}))
    local watch=assert(f:watch({maxMatches=1}))
    local actual=f:add(5);f.anchored=true
    assert(not f:watch({maxMatches=1}))
    assert(watch:complete(f.owner,{item=actual}));assert(watch:poll()==false)
end)
test("expiry, bounded inventory, and cancelled/refused actions are terminal",function()
    local f=fixture();f:add(2)
    assert(not f:watch({maxItems=4097}));assert(not f:watch({timeoutMs=7001}))
    f:add(3);assert(not f:watch({maxItems=1}))
    local expired=assert(f:watch({timeoutMs=500}));assert(expired:complete(f.owner,{id=5}))
    f.anchored=true;f.at=500;f:add(5);assert(expired:poll()==false)
    local stopped=assert(f:watch());stopped:cancel("User cancelled")
    assert(not stopped:complete(f.owner,{id=3}))
    local ok,reason=stopped:poll();assert(ok==false and reason=="User cancelled")
end)
local function orderedReplacement(f,shell,options)
    local mode={guard=function(owner,pane) return owner==f.owner and pane==f.main and not f.interrupted end,
        value=function(i) return i.safe~=false end,settleMs=100,strictDelta=true,retiredItem=shell,readyAtPerform=true}
    for k,v in pairs(options or {}) do mode[k]=v end
    return f:watch({correlation=mode,timeoutMs=500})
end
test("strict replacement permits one exact retired input and preserves identical carried spares",function()
    local f=fixture()
    local shell=f:add(10,"Base.CannedPeaches")
    local previous=f:add(11)
    local bag=f:add(12,"Base.Bag")
    local pocket=f.elsewhere;pocket.owner=bag
    function bag:getInventory() return pocket end
    local nested=f:add(13,nil,pocket)
    local r=assert(orderedReplacement(f,shell));assert(r:poll()==nil and r:start(f.owner))
    f.at=10;local good=f:add(14)
    assert(r:poll()==nil)
    f:remove(shell);f.anchored=true
    assert(r:complete(f.owner,{correlated=true}));assert(r:poll()==nil)
    f.at=111
    local ok,out=r:poll()
    assert(ok and out==good and previous.container==f.main and nested.container==pocket)
end)
test("strict replacement never adopts a missing or post-barrier output, an overlap or a restored shell",function()
    for _,mode in ipairs({"late","second","not-retired","wrong-order","decoy-first","unrelated-add","unrelated-remove","restore","replaced"}) do
        local f=fixture()
        local shell=f:add(10,"Base.CannedPeaches")
        local old=f:add(11)
        local r=assert(orderedReplacement(f,shell))
        if mode=="decoy-first" then f:add(8);assert(not r:start(f.owner))
        else
            assert(r:start(f.owner))
            local good
            if mode~="late" and mode~="wrong-order" then good=f:add(12) end
            if mode=="second" then f:add(13) end
            if mode=="unrelated-add" then f:add(13,"Base.Nails") end
            if mode=="unrelated-remove" then f:remove(old) end
            if mode~="not-retired" then f:remove(shell);f.anchored=true end
            if mode=="wrong-order" then assert(r:poll()==false);f:add(12) end
            local ok=r:complete(f.owner,{correlated=true})
            if mode=="restore" or mode=="replaced" then
                assert(ok)
                if mode=="restore" then shell.container=f.main;f.main.items[#f.main.items+1]=shell
                else f:remove(good);f:add(12) end
            else assert(not ok,mode) end
            if mode=="late" then f:add(12) end
        end
        assert(r:poll()==false,mode)
    end
end)

test("strict typed companion validators preserve primary identity and exact cardinality",function()
    for _,mode in ipairs({"split","bad-companion-role","nested-companion","wrong-value","double-companion","post-done-change","native-disagrees"}) do
        local f=fixture()
        local shell=f:add(10,"Base.CannedPeaches")
        local old=f:add(12,"Base.Lid")
        local bag=f:add(13,"Base.Bag")
        f.elsewhere.owner=bag
        function bag:getInventory() return f.elsewhere end
        local options={
            companions={lid=function(i) return i.condition==6 end},
            companionRole=function(i)
                if i.fullType=="Base.Lid" then return mode=="bad-companion-role" and "other" or "lid" end
            end,
            atPerform=function(primary) return mode~="native-disagrees" and primary.id==15 end,
        }
        local r=orderedReplacement(f,shell,options)
        if mode=="bad-companion-role" then assert(not r)
        else
            assert(r:start(f.owner))
            local lid=f:add(16,"Base.Lid",mode=="nested-companion" and f.elsewhere or f.main)
            lid.condition=mode=="wrong-value" and 4 or 6
            if mode=="split" then assert(r:poll()==nil) end
            if mode=="double-companion" then f:add(17,"Base.Lid").condition=6 end
            local actual=f:add(15)
            f:remove(shell);f.anchored=true
            local good=mode=="split" or mode=="post-done-change"
            assert((r:complete(f.owner,{correlated=true})==true)==good)
            if mode=="post-done-change" then lid.condition=0 end
            if mode=="split" then
                assert(r:poll()==nil);f.at=101
                local ok,checked=r:poll();assert(ok and checked==actual and checked~=lid)
            else assert(r:poll()==false,mode) end
            assert(old.container==f.main)
        end
    end
end)
print("PASS "..count.." exact created item receipt scenarios")
