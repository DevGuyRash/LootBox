-- Observes ONE unqueued native MP Take Bottle action. Never queues, stops,
-- creates, moves, pours or refits anything; the owner retains stock callbacks.
local Receipt = require "LootBox/CreatedItemReceipt"
local Inventory = require "LootBox/PourInventory"
local Actor = require "LootBox/PourActor"
local Take = {}
Take.__index = Take
local ACTION, BOTTLE = "ISAddTakeDispenserBottle", "Base.WaterDispenserBottle"
local TOLERANCE, MAX_OBJECTS = .00005, 128

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function integer(n) return finite(n) and n==math.floor(n) end
local function near(a,b) return finite(a) and finite(b) and math.abs(a-b)<=TOLERANCE end

local function kind(object)
    local script=object.getEntityScript and object:getEntityScript()
    local module=script and script:getModule()
    if not module or module:getName()~="Base" then return end
    local name=script:getName()
    if name=="WaterDispenser" then return "mounted" end
    if name=="WaterDispenserNoBottle" then return "bare" end
end

-- Distinguish a loaded but temporarily empty slot from an invalid observation.
-- This lane deliberately admits just one stock dispenser on the whole square.
local function slot(self)
    local rows=self.square:getObjects()
    local n=rows:size()
    if not integer(n) or n<0 or n>MAX_OBJECTS then return nil,"The dispenser square cannot be inspected" end
    local found, state
    for index=0,n-1 do
        local object=rows:get(index)
        if not object then return nil,"The dispenser square cannot be inspected" end
        local objectKind=kind(object)
        if objectKind then
            if found or object:getSquare()~=self.square or object:getObjectIndex()~=index
                or object:getFacing()~=self.facing then return nil,"The dispenser slot is ambiguous or changed facing" end
            found,state=object,objectKind
        elseif object==self.old then
            return nil,"The original dispenser changed script"
        end
    end
    if found==self.old and state=="mounted" then return state,found end
    if self.old:getObjectIndex()~=-1 then return nil,"The original dispenser did not retire from its slot" end
    if not found then return "absent" end
    if state~="bare" or found:getFluidContainer() or found:hasComponent(ComponentType.FluidContainer) then
        return nil,"The dispenser slot has an unexpected successor"
    end
    return state,found
end

-- Use actual litres per native Fluid, not the dominant fluid, labels, capacity
-- ratios or the stock script's default fill. Exact zero is an explicit
-- opt-in; no near-zero or unknown contents, and no reliance on fluid identity
-- to discriminate an empty jug.
local function sample(component,owner,locked,allowEmpty)
    if not component or component:getOwner()~=owner or component:isInputLocked()~=locked
        or not component:canPlayerEmpty() or component:isMultiTileMoveable() then return end
    local capacity, amount=component:getCapacity(),component:getAmount()
    if not finite(capacity) or capacity<=0 or not finite(amount) or amount<0 or amount>capacity+TOLERANCE then return end
    if amount==0 then
        if allowEmpty and component:isEmpty()==true then return {capacity=capacity,amount=0,parts={}} end
        return
    end
    if amount<=TOLERANCE then return end
    local parts=Inventory.mix({fluid=component})
    if not parts then return end
    local total=0
    for fluid, ratio in pairs(parts) do
        local litres=ratio*amount
        if not finite(litres) or litres<=0 then return end
        parts[fluid],total=litres,total+litres
    end
    if not near(total,amount) then return end
    return {capacity=capacity,amount=amount,parts=parts}
end

local function same(a,b)
    if not a or not b or not near(a.capacity,b.capacity) or not near(a.amount,b.amount) then return false end
    for fluid, litres in pairs(a.parts) do if not near(litres,b.parts[fluid]) then return false end end
    for fluid in pairs(b.parts) do if not a.parts[fluid] then return false end end
    return true
end

local function context(self, phase)
    local p,o,s=self.player,self.action,self.square
    if not isClient() or isServer() or not p:isLocalPlayer() or getSpecificPlayer(self.playerNum)~=p
        or p:getOnlineID()~=self.online or p:getInventory()~=self.main or getCell()~=self.cell
        or self.cell:getGridSquare(self.x,self.y,self.z)~=s or ISTimedActionQueue.getTimedActionQueue(p)~=self.queue
        or getmetatable(o)~=self.class or o.Type~=ACTION or o.character~=p
        or o.waterdispenser~=self.old or o.square~=s or o.bottle~=nil then
        return false,"The selected dispenser action, actor or square changed"
    end
    if Actor.blocked(p) then return false,"The player interrupted the dispenser take" end
    local here=p:getCurrentSquare()
    local x,y=p:getX(),p:getY()
    if not here or here~=self.from or p:getSquare()~=here or here:getZ()~=self.z
        or not finite(x) or not finite(y) or math.abs(x-(self.x+.5))>1.6 or math.abs(y-(self.y+.5))>1.6
        or not here:canReachTo(s) or not SafeHouse or not SafeHouse.isSafehouseAllowInteract(s,p) then
        return false,"The selected dispenser is not reachable or allowed"
    end
    local trade=ISTradingUI and ISTradingUI.GetUIForPlayer(p)
    if trade and trade:isVisible() then return false,"Finish trading before taking the dispenser bottle" end
    if self.allow(phase)~=true then return false,"The dispenser take is no longer allowed" end
    return true
end

local function guard(self, owner, destination, phase)
    if owner~=self.action or destination~=self.main then return false,"Another action owns the dispenser receipt" end
    local ok, reason=context(self,phase)
    if not ok then return false,reason end
    local q, java=self.queue,self.player:getCharacterActions()
    local size, handle=java:size(),owner.action
    if not handle or (self.handle and self.handle~=handle) then return false,"The native dispenser action changed" end
    if phase=="perform" or phase=="settling" then
        if q.current or #q.queue~=0 or size>1 or (size==1 and java:get(0)~=handle) then
            return false,"Another player action interrupted the dispenser take"
        end
        self.idle=size==0
    elseif q.current~=owner or #q.queue~=1 or q.queue[1]~=owner or size~=1 or java:get(0)~=handle then
        return false,"Another player action interrupted the dispenser take"
    end
    self.handle=handle
    local state, object=slot(self)
    if not state then return false,object end
    local before=phase=="start" or phase=="before-start"
    if before and (state~="mounted" or self.canAdmit()~=true) then
        return false,"The selected dispenser or receiving space changed before the take"
    end
    if state=="mounted" then
        if self.sawAbsent or self.bare then return false,"The dispenser transition was reversed" end
        local component=self.old:getFluidContainer()
        if component~=self.component or not same(self.liquid,sample(component,self.old,true,self.empty)) then
            return false,"The original dispenser contents changed"
        end
    elseif state=="absent" then
        if self.bare then return false,"The bare dispenser successor disappeared" end
        self.sawAbsent=true
    else
        if self.bare and self.bare~=object then return false,"The bare dispenser successor changed" end
        self.bare=object
    end
    return true
end

local function begin(player, action, selected, policy)
    if not player or type(action)~="table" or not selected or type(policy)~="table" or not action.square
        or type(policy.allow)~="function" or type(policy.canAdmit)~="function" or type(policy.canUseItem)~="function"
        or type(ISAddTakeDispenserBottle)~="table" or getmetatable(action)~=ISAddTakeDispenserBottle
        or action.waterdispenser~=selected or kind(selected)~="mounted" or action.action then
        return nil,"Select one fresh stock mounted dispenser Take action"
    end
    local s, facing=action.square,selected:getFacing()
    local x,y,z=s:getX(),s:getY(),s:getZ()
    local cell, main, q=getCell(),player:getInventory(),ISTimedActionQueue.getTimedActionQueue(player)
    local playerNum, online=player:getPlayerNum(),player:getOnlineID()
    if not integer(x) or not integer(y) or not integer(z) or not integer(playerNum) or not integer(online) or online<0
        or (facing~=IsoDirections.N and facing~=IsoDirections.E and facing~=IsoDirections.S and facing~=IsoDirections.W)
        or not cell or not main or not q or q.current or #q.queue~=0 or player:getCharacterActions():size()~=0 then
        return nil,"Finish current work before observing the exact dispenser take"
    end
    local self=setmetatable({player=player,action=action,old=selected,square=s,from=player:getCurrentSquare(),
        class=ISAddTakeDispenserBottle,main=main,queue=q,cell=cell,x=x,y=y,z=z,facing=facing,playerNum=playerNum,
        online=online,allow=policy.allow,canAdmit=policy.canAdmit,phase="waiting"},Take)
    local ok, reason=context(self,"begin")
    if not ok then return nil,reason end
    local state, object=slot(self)
    if state~="mounted" or object~=selected or self.canAdmit()~=true then
        return nil,"The exact mounted dispenser or receiving space is unavailable"
    end
    self.component=selected:getFluidContainer()
    self.liquid=sample(self.component,selected,true,policy.allowEmpty==true)
    if not self.liquid then return nil,"The mounted bottle has no verifiable eligible fluid state" end
    self.empty=self.liquid.amount==0
    local function eligible(item)
        return item:getContainer()==main and not item:getWorldItem() and not item:isSealed() and not item:isFavorite()
            and not item:isWorn() and not player:isEquipped(item) and not player:isAttachedItem(item)
            and policy.canUseItem(item)==true
    end
    local function matching(item)
        local reading=sample(item:getFluidContainer(),item,false,self.empty)
        return reading and (not self.empty or reading.amount==0) and same(self.liquid,reading)==true
    end
    local function exactEmpty(item)
        if not eligible(item) or not matching(item) then
            return false,"The possible empty jug was not exact, safe zero when observed"
        end
        return true
    end
    self.receipt,reason=Receipt.begin(action,{
        inventory=function() return player:getInventory() end,
        matches=function(item) return item:getFullType()==BOTTLE end,
        anchor=function() return self.bare~=nil end,
        clock=getTimestampMs, preserveMatching=true, maxMatches=64,
        correlation={
            actionTimeoutMs=20000,
            guard=function(owner,destination,phase) return guard(self,owner,destination,phase) end,
            strictDelta=self.empty or policy.strictDelta==true,
            observeValue=self.empty and exactEmpty or nil,
            value=function(item)
                if not eligible(item) then return false,"The new bottle is not safe to use in main inventory" end
                if not matching(item) then
                    return false,"The new bottle does not match the original dispenser contents"
                end
                if self.idle then return true end -- never use an item under the remaining Java action
            end,
        },
    })
    if not self.receipt then return nil,reason end
    return self
end

-- policy.allow(phase) protects the job throughout, not the retired fixture;
-- canAdmit() checks live donor/preview headroom only before start; canUseItem
-- checks application-level protection of the exact captured candidate.
function Take.begin(player,action,selected,policy)
    local ok, observer, reason=pcall(begin,player,action,selected,policy)
    if ok then return observer,reason end
    return nil,"The exact native dispenser take could not be inspected"
end

function Take:cancel(reason)
    if self.phase~="closed" then
        self.phase,self.problem="closed",reason or "The dispenser take was interrupted"
        self.receipt:cancel(self.problem)
    end
    return nil,self.problem
end

local function observe(self)
    local status, reason=self.receipt:poll()
    if status~=nil then return self:cancel(reason) end
    return true
end

-- Call just after the stock wait callback, in the same Lua waitToStart. True
-- holds before Java start/send. A reason also tells the owner to stop/clean up
-- its unstarted action; forceStop in Lua start alone cannot prevent sending.
function Take:waitToStart(owner,stockWaiting)
    self.admitted=false
    if owner~=self.action or self.phase~="waiting" or type(stockWaiting)~="boolean" then
        self:cancel("The exact dispenser wait could not be verified")
        return true,self.problem
    end
    if not observe(self) then return true,self.problem end
    self.admitted=not stockWaiting
    return stockWaiting
end

function Take:beforeStart(owner)
    if owner~=self.action or self.phase~="waiting" or not self.admitted then
        return self:cancel("The dispenser take did not pass its admission fence")
    end
    if not observe(self) then return nil,self.problem end
    self.admitted,self.phase=false,"starting"
    return true
end

-- Called before returning from the original Lua start wrapper; success flag
-- means the stock callback returned without error, not that the server acted.
function Take:started(owner,stockReturned)
    if owner~=self.action or self.phase~="starting" or stockReturned~=true then
        return self:cancel("The stock dispenser start could not be verified")
    end
    local ready, reason=self.receipt:start(owner)
    if not ready then return self:cancel(reason) end
    self.phase="running"
    return true
end

-- Capture the visible candidate before stock perform advances the Lua queue.
-- A failure here must NOT prevent the owner from running stock perform.
function Take:beforePerform(owner)
    if owner~=self.action or self.phase~="running" then return self:cancel("The exact dispenser perform was not owned") end
    if not observe(self) then return nil,self.problem end
    self.phase="performing"
    return true
end

function Take:performed(owner,stockReturned)
    if owner~=self.action or self.phase~="performing" or stockReturned~=true then
        return self:cancel("The stock dispenser completion could not be verified")
    end
    local completed, reason=self.receipt:complete(owner,{correlated=true})
    if not completed then return self:cancel(reason) end
    self.phase="settling"
    return true
end

function Take:poll()
    if self.phase=="closed" then return false,self.problem end
    if self.phase=="starting" or self.phase=="performing" then return nil end
    local confirmed, item=self.receipt:poll()
    if confirmed==false then self:cancel(item);return false,self.problem end
    if confirmed==true then
        self.phase,self.problem="closed","The dispenser receipt was already delivered"
        return true,{item=item,id=item:getID(),stand=self.bare,square=self.square,facing=self.facing}
    end
end

return Take
