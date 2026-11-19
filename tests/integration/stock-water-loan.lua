package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Loan = require "LootBox/StockWaterLoan"
local f
local function list()
    local l = {}
    function l:add(x) self[#self+1] = x end
    function l:get(i) return self[i+1] end
    function l:size() return #self end
    return l
end
ArrayList = {new=list}
CharacterStat = {THIRST={}}
function getTimestampMs() return f.now end
function isClient() return f.mp end
function isServer() return false end
function isItemTransactionDone(id) return f.transactions[id] == "done" end
function isItemTransactionRejected(id) return f.transactions[id] == "rejected" end
function getCore() return {getOptionAutoDrink=function() return f.stock end} end
local function container()
    local c = {items=list()}
    function c:contains(item)
        for _, x in ipairs(self.items) do if x == item then return true end end
        return false
    end
    function c:getItems() return self.items end
    function c:getContainingItem() return self.bag end
    function c:isItemAllowed() return true end
    function c:hasRoomFor() return not self.full end
    return c
end
local function put(item, dest)
    local old = item.container
    if old then
        for i, x in ipairs(old.items) do
            if x == item then table.remove(old.items,i); break end
        end
    end
    item.container = dest
    dest.items:add(item)
end
local function item(id)
    local x = {id=id, favorite=false}
    function x:getID() return self.id end
    function x:getFullType() return self.fullType or "Base.WaterBottle" end
    function x:getContainer() return self.container end
    function x:getInventory() return self.contents end
    function x:isFavorite() return self.favorite end
    function x:getFluidContainer() return self.fluid end
    function x:isWaterOnlySource() return self.fluid ~= nil end
    function x:isSealed() return false end
    return x
end
package.loaded["TimedActions/ISInventoryTransferUtil"] = true
ISInventoryTransferUtil = {newInventoryTransferAction=function(character, i, from, to)
    local action = {action={},item=i,from=from,to=to,character=character,srcContainer=from,destContainer=to}
    function action:isValid() return true end
    function action:start()
        if f.mp then
            self.transactionId = #f.admitted
            f.transactions[self.transactionId] = "pending"
        end
    end
    function action:perform()
        if self:isValid() then self.performed = true end
        self.transactionId = 0
        local q = f.queue
        table.remove(q.queue,1)
        q.current = q.queue[1]
    end
    function action:transferItem(item) put(item,self.to) end
    function action:forceCancel() self.cancelled = true end
    function action:forceStop() self:stop() end
    function action:stop() f.queue.current = nil; f.queue.queue = {} end
    return action
end}
ISTimedActionQueue = {
    getTimedActionQueue=function() return f.queue end,
    add=function(action)
        f.admitted[#f.admitted + 1] = action
        f.queue:addToQueue(action)
        action:start()
    end,
}
local function init()
    f = {now=0,thirst=.31,stock=true,admitted={},allow=true,mp=false,transactions={},playerStock=true}
    f.main, f.pouch, f.bag, f.bottle = container(), container(), item(1), item(2)
    f.pouch.bag, f.bag.contents = f.bag, f.pouch
    put(f.bag,f.main); put(f.bottle,f.pouch)
    f.bottle.fluid = {quantity=.51,
        getAmount=function(self) return self.quantity end,
        isPoisonous=function() return false end,
        isTainted=function() return false end,
        canPlayerEmpty=function() return true end,
        getProperties=function() return {getThirstChange=function() return -.2 end} end}
    f.player = {
        getInventory=function() return f.main end,
        getAutoDrink=function() return f.playerStock end,
        hasTimedActions=function() return f.queue.current ~= nil end,
        getStats=function() return {get=function() return f.thirst end} end,
        getWaterSource=function(_, items)
            for i=0,items:size()-1 do
                local x = items:get(i)
                if x.fluid and x.fluid.quantity > 0 then return x end
            end
        end,
    }
    f.queue = {queue={},
        addToQueue=function(self, action) self.queue[#self.queue+1]=action; self.current=self.current or action end,
        removeFromQueue=function(self, action)
            for i, x in ipairs(self.queue) do
                if x==action then table.remove(self.queue,i); return end
            end
        end,
    }
    f.guard = function(x, original, phase)
        assert(x:getID()==f.bottle:getID() and original==f.pouch)
        return f.allow and (phase~="return" or not f.denyReturn)
    end
end
local function begin() return Loan.new(f.player,f.bottle,f.guard) end
local function complete()
    local q = f.queue
    if q.current then
        local action = q.current
        action:transferItem(action.item)
        table.remove(q.queue,1)
        q.current=q.queue[1]
    end
end
init()
f.mp=true; f.playerStock=false; assert(not begin() and #f.admitted==0)
f.mp=false; f.stock=false; assert(not begin() and #f.admitted==0)
f.stock=true
local native = item(3); native.fluid=f.bottle.fluid; put(native,f.main)
assert(not begin() and #f.admitted==0)
init()
assert(Loan.canOffer(f.player,f.bottle));f.main.full=true;assert(not Loan.canOffer(f.player,f.bottle));f.main.full=false
local loan=assert(begin())
assert(loan:isBusy() and #f.admitted==1 and f.admitted[1].item==f.bottle and f.admitted[1].to==f.main)
complete(); loan:tick(); assert(#f.admitted==1 and loan.count==0)
f.bottle.fluid.quantity=.08; f.thirst=.06
loan:tick(); assert(#f.admitted==2 and f.admitted[2].item==f.bottle and f.admitted[2].to==f.pouch and loan.count==1)
complete(); loan:tick()
assert(not loan:isBusy() and loan.state=="finished" and f.bottle.container==f.pouch and loan:status().done==1)

init()
loan=assert(begin()); complete(); loan:tick()
f.bottle.fluid.quantity=.08
loan:tick(); assert(loan.count==0 and #f.admitted==2)
complete(); loan:tick(); assert(loan.state=="failed")

init()
loan=assert(begin()); complete(); loan:tick(); f.now=3500; loan:tick()
assert(#f.admitted==2); complete(); loan:tick(); assert(loan.state=="failed" and loan.count==0)

init()
loan=assert(begin()); local manual={}; f.queue:addToQueue(manual)
loan:tick()
assert(loan.state=="cancelled" and f.queue.current==manual and #f.queue.queue==1 and f.bottle.container==f.pouch)

init()
loan=assert(begin()); complete(); loan:tick()
f.bottle.favorite=true
loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1 and f.bottle.container==f.main)

init()
loan=assert(begin()); complete(); loan:tick()
f.pouch.full=true; f.bottle.fluid.quantity=.2; f.thirst=.1
loan:tick()
assert(loan.count==1 and #f.admitted==1 and f.bottle.container==f.main and not loan:isBusy())
init()
loan=assert(begin())
local floor=container()
put(f.bag,floor)
complete()
assert(f.bottle.container==f.pouch and #f.admitted==1)
loan:tick(); assert(loan.state=="cancelled")

init()
loan=assert(begin()); complete(); loan:tick()
f.bottle.fluid.quantity=.21; f.thirst=.07; loan:tick()
assert(#f.admitted==2)
put(f.bag,container())
complete(); loan:tick()
assert(f.bottle.container==f.main and loan.state=="cancelled")

init()
loan=assert(begin()); f.now=11000; complete(); loan:tick()
assert(f.bottle.container==f.main and loan:isBusy())

init()
loan=assert(begin())
local ours=f.queue.current
local manual=ISInventoryTransferUtil.newInventoryTransferAction(f.player,item(99),f.pouch,f.main)
assert(ours.stopOnWalk and ours.stopOnAim and ours.stopOnRun and not ours:canMergeAction(manual))
f.queue:addToQueue(manual);loan:tick()
assert(f.bottle.container==f.pouch and f.queue.current==manual and #f.queue.queue==1 and not manual.cancelled)

-- The client requests only ordinary stock transfer. Server and replica steps
-- explicitly arrive at different times; the local transfer effect is never called.
local function mpStart()
    init(); f.mp=true
    local result=assert(begin())
    assert(f.transactions[1]=="pending" and f.bottle.container==f.pouch)
    return result
end
local function ack(id)
    f.transactions[id]="done"
    f.queue.current:perform()
end
loan=mpStart()
loan:tick(); assert(loan:isBusy() and #f.admitted==1 and loan.count==0)
ack(1)
loan:tick(); assert(loan:isBusy() and #f.admitted==1 and loan.count==0)
put(f.bottle,f.main); f.now=f.now+250; loan:tick()
f.bottle.fluid.quantity=.08; loan:tick()
assert(loan.count==0 and #f.admitted==1)
f.thirst=.06; loan:tick()
assert(loan.count==1 and #f.admitted==2 and f.transactions[2]=="pending")
put(f.bottle,f.pouch); loan:tick()
assert(loan:isBusy())
ack(2); loan:tick()
assert(loan.state=="finished" and f.bottle.container==f.pouch)

loan=mpStart(); put(f.bottle,f.main); ack(1); loan:tick()
f.thirst=.06; loan:tick(); assert(loan.count==0 and #f.admitted==1)
f.bottle.fluid.quantity=.08; loan:tick(); assert(loan.count==1 and #f.admitted==2)

loan=mpStart(); put(f.bottle,f.main); ack(1); loan:tick()
f.bottle.fluid.quantity=.08; f.now=8000; loan:tick()
assert(loan.state=="failed" and loan.count==0 and #f.admitted==1 and f.bottle.container==f.main)

loan=mpStart(); f.transactions[1]="rejected"; f.queue.current:stop(); loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1 and not begin())

loan=mpStart(); f.now=31000; loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1)
put(f.bottle,f.main); f.transactions[1]="done"; loan:tick()
assert(#f.admitted==1 and loan.count==0, "late approval deterministically never triggers return or a retry")

local function duplicate(original, target, remaining)
    local replica = item(original.id)
    replica.fluid = setmetatable({quantity=remaining or original.fluid.quantity}, {__index=original.fluid})
    put(replica,target)
    return replica
end
local function remove(x)
    local c=x.container
    for index,v in ipairs(c.items) do if v==x then table.remove(c.items,index); break end end
    x.container=nil
end

loan=mpStart()
local old = f.bottle
local received=duplicate(old,f.main,.08)
loan:tick(); assert(loan:isBusy() and loan.item==old and loan.count==0)
ack(1); loan:tick()
assert(loan:isBusy() and loan.item==old and f.queue.current==nil)
remove(old); f.now=f.now+250; f.thirst=.06; loan:tick()
assert(loan.item==received and loan.count==1 and #f.admitted==2 and f.admitted[2].item==received)
remove(received); ack(2); loan:tick(); assert(loan:isBusy())
local returned=duplicate(received,f.pouch)
f.now=f.now+250; loan:tick()
assert(loan.state=="finished" and loan.item==returned and f.pouch:contains(returned))

loan=mpStart()
remove(f.bottle); ack(1); loan:tick(); assert(loan:isBusy() and loan.count==0)
received=duplicate(f.bottle,f.main); received.fullType="Base.NotWaterBottle"
f.now=f.now+250; loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1 and loan.item==f.bottle)

loan=mpStart()
remove(f.bottle); ack(1)
duplicate(f.bottle,f.main); duplicate(f.bottle,f.main)
loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1)

loan=mpStart()
put(f.bottle,f.main); ack(1); loan:tick()
local alternate=item(44)
alternate.fluid=setmetatable({quantity=.8},{__index=f.bottle.fluid})
f.bottle.fluid.quantity=0; f.thirst=.035
put(alternate,f.main)
loan:tick()
assert(loan.state=="cancelled" and loan.count==0 and #f.admitted==1)

loan=mpStart()
put(f.bottle,f.main); ack(1); loan:tick()
f.bottle.fluid.quantity=0; f.thirst=.035
loan:tick()
assert(loan.count==1 and #f.admitted==2, "verified empty bottle may no longer be picked by vanilla")

loan=mpStart()
for i=1,1025 do put(item(i+55),f.pouch) end
loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1)

loan=mpStart()
remove(f.bottle); ack(1); loan:tick()
f.allow=false; loan:tick()
assert(loan.state=="cancelled" and #f.admitted==1)

print("PASS: exact vanilla water loan, SP/MP exact water loan, MP rejection and timeout, no unresolved or unsafe return")
