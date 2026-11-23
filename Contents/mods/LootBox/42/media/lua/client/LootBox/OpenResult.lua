-- Observe one stock handcraft. This supplies the producer-specific guards
-- to CreatedItemReceipt; it never opens a package or queues a bite.
local Actor=require "LootBox/PourActor"
local OpenFull=require "LootBox/OpenFull"
local Receipt=require "LootBox/CreatedItemReceipt"
local Result={}
Result.__index=Result
local QUIET, PICKUP_WAIT, MAX_FLOOR = 200,2000,512
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function integer(n) return finite(n) and n==math.floor(n) end
local function attempt(f,...)
    local ok,a,b=pcall(f,...)
    if ok then return a,b end
    return false,"The stock opening or receiving inventory could not be inspected"
end

local function context(self,phase)
    local p,a=self.player,self.action
    if isClient()~=self.mp or isServer() or getSpecificPlayer(self.index)~=p or p:getOnlineID()~=self.online
        or p:getInventory()~=self.main or getCell()~=self.cell or p:getCurrentSquare()~=self.square
        or self.cell:getGridSquare(self.x,self.y,self.z)~=self.square
        or getmetatable(a)~=self.class or a.Type~="ISHandcraftAction" or a.character~=p
        or a.craftRecipe~=self.recipe.recipe or a.force or a.eatPercentage~=0 or a.craftBench
        or ISTimedActionQueue.getTimedActionQueue(p)~=self.queue then
        return false,"The selected craft, player, or location changed"
    end
    if Actor.blocked(p) or not self.allow(phase) then return false,"Opening was interrupted" end
    if self.eventProblem then return false,self.eventProblem end
    if self.mp and self.recipe.event and getNumActivePlayers()~=1 then return false,"The local player for the opened item changed" end
    local trade=ISTradingUI and ISTradingUI.GetUIForPlayer(p)
    if trade and trade:isVisible() then return false,"Finish trading before opening the package" end
    return true
end

local function primary(self,item)
    return self.recipe.scripts[item:getFullType()]~=nil
end

local function lid(self,item)
    return item:getScriptItem()==self.recipe.lid and not item:getWorldItem() and item:getCondition()==self.lidCondition
end

local function lidCondition(shell)
    local value=shell:getModData().LidCondition
    local integerValue=finite(value) and (value<0 and math.ceil(value) or math.floor(value)) or -1
    if integerValue==-1 then integerValue=9 end
    return math.min(10,math.max(0,integerValue))
end

local function capsule(self,item)
    if item:getScriptItem()~=self.recipe.scripts[item:getFullType()] or item:isSealed() or item:getWorldItem() then return false end
    if self.recipe.ration then
        -- It is the already-filled native side effect, not the dummy
        -- WaterRationCan_Open or an unrelated empty/similar vessel.
        local fluid=item:getFluidContainer()
        local water=Fluid and Fluid.Water
        return fluid and water and fluid:getOwner()==item and not fluid:isTainted() and fluid:canPlayerEmpty()==true
            and math.abs(fluid:getCapacity()-.3)<.00001 and math.abs(fluid:getAmount()-.3)<.00001
            and math.abs(fluid:getSpecificFluidAmount(water)-.3)<.00001
    end
    if not instanceof(item,"Food") or item:getScriptItem():isCantEat() then return false end
    if self.recipe.unlabeled then
        local tag=item:getModData().NoLabel
        if tag~=true and tag~="true" then return false end
    end
    return true
end

-- Stock may drop an output at the player's square instead of adding it to
-- main. This negative witness refuses a new matching object on that square
-- (or a loaded adjacent square), including the old input if it was dropped.
local function floors(self,baseline)
    local ids,count={},0
    for dx=-1,1 do for dy=-1,1 do
        local s=self.cell:getGridSquare(self.x+dx,self.y+dy,self.z)
        local key=(dx+1)*3+dy+2
        if baseline then self.squares[key]=s or false
        elseif (s or false)~=self.squares[key] then return false end
        if s then
            local list=s:getWorldObjects()
            local size=list:size()
            count=count+size
            if not integer(size) or size<0 or count>MAX_FLOOR then return false end
            for i=0,size-1 do
                local object=list:get(i)
                local item=object and object:getItem()
                local id=item and item:getID()
                if not integer(id) then return false end
                if id==self.id or primary(self,item) or (self.recipe.lid and item:getFullType()=="Base.JarLid") then
                    if ids[id] or id==self.id or object:getSquare()~=s then return false end
                    ids[id]=object
                    if not baseline and self.floor[id]~=object then return false end
                end
            end
        end
    end end
    if baseline then self.floor=ids
    else for id,object in pairs(self.floor) do if ids[id]~=object then return false end end end
    return true
end

local function queueOwner(self,settling)
    local q,a,java=self.queue,self.action,self.player:getCharacterActions()
    local n,handle=java:size(),a.action
    if not handle or (self.handle and self.handle~=handle) then return false end
    if settling then
        if q.current or #q.queue~=0 or n>1 or (n==1 and java:get(0)~=handle) then return false end
        self.idle=n==0
    elseif q.current~=a or #q.queue~=1 or q.queue[1]~=a or n~=1 or java:get(0)~=handle then
        return false
    end
    self.handle=handle
    return true
end

local function detach(self)
    if self.listener then
        local event,listener=self.event,self.listener
        self.event,self.listener=nil,nil
        pcall(event.Remove,listener)
    end
end

-- Listen alongside the stock cosmetic handler, do not replace it or send
-- anything. The published output ID corroborates the strict inventory proof;
-- a matching add alone or a cosmetic message alone cannot finish this route.
local function subscribe(self)
    if not self.mp or not self.recipe.event then return true end
    local event=Events.OnServerCommand
    local listener=function(module,command,args)
        if self.phase~="running" or module~="recipe" or (command~="OpenMysteryCan" and command~="OpenDentedCan") then return end
        local ok,accepted=pcall(function()
            if command~=self.recipe.event or self.resultID or not context(self,"running") or not queueOwner(self,false)
                or type(args)~="table" or not integer(args.itemId) or args.itemId==self.id then return false end
            self.resultID=args.itemId
            return true
        end)
        if not ok or not accepted then self.eventProblem="The stock can-result notice was missing context or conflicted" end
    end
    self.event,self.listener=event,listener
    event.Add(listener)
    return true
end

local function exactInputs(self,expected)
    local input=self.action.manualInputs
    if not input then return false end
    local scanned={}
    for index,items in pairs(input) do
        if items:size()~=1 or (index~=self.recipe.inputIndex and not self.recipe.kept[index]) then return false end
        local item=items:get(0)
        if not item then return false end
        if index==self.recipe.inputIndex then
            if item~=expected and item~=self.original then return false end
        elseif item:getContainer()~=self.main or not self.main:getItems():contains(item) then return false end
        scanned[index]=true
    end
    for index in pairs(self.recipe.kept) do if not scanned[index] then return false end end
    return scanned[self.recipe.inputIndex]==true
end

local function shellRetired(self)
    -- The receipt independently checks exact disappearance from the entire
    -- carried tree. Absence from the source alone is not retirement.
    local original=self.original
    return self.shell:getContainer()==nil and not self.shell:getWorldItem()
        and (self.source==self.main or (not self.source:containsID(self.id) and not original:getWorldItem()))
end

local function guard(self,owner,destination,phase)
    if owner~=self.action or destination~=self.main then return false,"Another craft owns the receipt" end
    local ok,why=context(self,phase)
    if not ok then return false,why end
    if not queueOwner(self,phase=="perform" or phase=="settling") then
        return false,"Another player action interrupted the opening"
    end
    if not floors(self,false) then return false,"A possible opened item or the observing floor changed" end
    local capacity=destination:getEffectiveCapacity(self.player)
    if capacity~=self.capacity then return false,"The receiving carry capacity changed" end
    local current=destination:getCapacityWeight()
    if not finite(current) or current>capacity then return false,"The opened item may have been placed on the floor" end
    return true
end

function Result.new(player,queue,action,original,source,recipe,allow,ready)
    return attempt(function()
        local index,online,mp=player:getPlayerNum(),player:getOnlineID(),isClient()
        local square,cell=player:getCurrentSquare(),getCell()
        if not integer(index) or not integer(online) or (mp and online<0) or not square or not cell or type(ISHandcraftAction)~="table"
            or type(ready)~="function" then return false,"Stock opening identity is unavailable" end
        local self=setmetatable({player=player,queue=queue,action=action,class=ISHandcraftAction,recipe=recipe,original=original,
            source=source,id=original:getID(),inputType=original:getFullType(),index=index,online=online,
            main=player:getInventory(),cell=cell,square=square,x=square:getX(),y=square:getY(),z=square:getZ(),
            allow=allow,ready=ready,squares={},phase="wait",mp=mp},Result)
        local ok,why=context(self,"setup")
        if not ok then return false,why end
        return self
    end)
end

local function admit(self)
    if self.phase~="wait" then return false,"The opening action was not waiting to start" end
    local ok,why=context(self,"before-start")
    if not ok then return false,why end
    if not queueOwner(self,false) then return false,"Finish other work; keep the can opener in main inventory for one-click opening" end
    local t=getTimestampMs()
    self.untilAt=self.untilAt or t+PICKUP_WAIT
    if self.receipt then
        local done,reason=self.receipt:poll()
        if done~=nil then return false,reason end
        if t<self.quietAt then return nil end
        if not exactInputs(self,self.shell) or self.ready()~=true then return false,"The exact stock inputs changed before opening" end
        return true
    end
    local shell,problem=OpenFull.networkItem(self.main,self.source,self.id,self.inputType)
    if problem then return false,problem end
    if not shell or shell:getContainer()~=self.main then
        if t>=self.untilAt then return false,"The selected package pickup was not confirmed" end
        return nil
    end
    if shell:getWorldItem() or not exactInputs(self,shell) or self.ready()~=true then return false,"The exact stock inputs changed before opening" end
    local cap,weight=self.main:getEffectiveCapacity(self.player),self.main:getCapacityWeight()
    if not finite(cap) or not finite(weight) or weight+self.recipe.weight+.001>cap
        or not self.main:hasRoomFor(self.player,self.recipe.weight+.001) then
        return false,"Make space in main inventory for the opened item"
    end
    self.shell,self.capacity=shell,cap
    if self.recipe.lid then self.lidCondition=lidCondition(shell) end
    if not floors(self,true) then return false,"The place where the game can drop the opened item is unavailable" end
    local correlation={
        strictDelta=true,retiredItem=shell,readyAtPerform=true,
        guard=function(owner,inventory,phase) return guard(self,owner,inventory,phase) end,
        observeValue=function(item)
            return capsule(self,item)==true,"The new item did not match the native opened food or drink"
        end,
        value=function() if self.idle then return true end end,
    }
    if self.recipe.lid then
        correlation.companions={lid=function(item) return lid(self,item) end}
        correlation.companionRole=function(item) if item:getFullType()=="Base.JarLid" then return "lid" end end
    end
    if self.mp and self.recipe.event then
        correlation.atPerform=function(item)
            return self.resultID==item:getID(),"The native opened-can notice did not identify this exact new item"
        end
    end
    local receipt,failure=Receipt.begin(self.action,{
        inventory=function() return self.player:getInventory() end,
        matches=function(item) return primary(self,item) end,
        anchor=function() return shellRetired(self) end,
        clock=getTimestampMs,correlation=correlation,
    })
    if not receipt then return false,failure end
    self.receipt,self.quietAt=receipt,t+QUIET
end

function Result:admit() return attempt(admit,self) end

function Result:started()
    return attempt(function()
        local a,s=self.action,self.shell
        local logic=a.logic
        if self.phase~="wait" or not self.receipt or getTimestampMs()<self.quietAt or a.craftStarted~=true
            or not logic or logic:getRecipe()~=self.recipe.recipe or not exactInputs(self,s)
            or a.manualInputs[self.recipe.inputIndex]:get(0)~=s then
            return false,"The native opening did not bind the exact selected item"
        end
        local data=logic:getRecipeData()
        if not data or not data:getAllInputItems():contains(s) or (self.recipe.mapper and self.recipe.mapper:getOutputItem(data,true)~=self.recipe.script) then
            return false,"The native opening changed its mapped output"
        end
        local ok,reason=self.receipt:start(a)
        if not ok then return false,reason end
        self.phase="running"
        subscribe(self)
        return true
    end)
end

function Result:beforePerform()
    if self.phase~="running" then return false,"The owned stock opening never started" end
    detach(self)
    local status,why=self.receipt:poll()
    if status~=nil then return false,why end
    self.phase="performing"
    return true
end

function Result:performed()
    if self.phase~="performing" then return false,"The stock opening did not complete in the owned action" end
    local ok,why=self.receipt:complete(self.action,{correlated=true})
    if not ok then return false,why end
    self.phase="settling"
    return true
end

function Result:poll()
    if self.receipt then return self.receipt:poll() end
    local ok,why=attempt(context,self,"preparing")
    if not ok then return false,why end
end

function Result:cancel(reason)
    self.phase="closed"
    detach(self)
    if self.receipt then self.receipt:cancel(reason) end
end

return Result
