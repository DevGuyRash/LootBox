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
        return v
    end
    local main=container()
    local f={main=main,where=main,elsewhere=container(),at=0,anchored=false,predecessor={},owner={}}
    function f:add(id,fullType,dest)
        local item={id=id,fullType=fullType or "Base.CannedPeachesOpen",container=dest or main}
        function item:getID() return self.id end
        function item:getContainer() return self.container end
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
print("PASS "..count.." exact created item receipt scenarios")
