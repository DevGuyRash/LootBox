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
    end,
}
local function init()
    f = {now=0,thirst=.31,stock=true,admitted={},allow=true,mp=false}
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
        assert(x==f.bottle and original==f.pouch)
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
f.mp=true; assert(not begin() and #f.admitted==0)
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

print("PASS: exact vanilla water loan, no competing stock source, no MP, no unresolved or unsafe return")
