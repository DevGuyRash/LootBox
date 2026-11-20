local Inventory = require "LootBox/PourInventory"

local Pour = {}
Pour.__index = Pour
local function sameAmount(a,b)
    return type(a)=="number" and type(b)=="number" and math.abs(a-b)<=math.max(.000001,math.min(.00025,math.max(math.abs(a),math.abs(b))*.00005))
end
function Pour.options(p)
    return {pourLootToLoot=p.pourLootToLoot==true,
        pourFillScope=p.pourMainOnly and "main-only" or p.pourEquippedFirst and "equipped-first" or "main-first",
        pourFillOrder=p.pourMostRoomFirst and "largest-first" or "smallest-first"}
end

function Pour.displayed(index,holder)
    return require("LootBox/PourStacks").displayedLoot(index,holder)
end

local function loanable(entry)
    return entry.scope=="loot" and (entry.container:getType()~="floor" or entry.groundAnchor~=nil)
end
local function mobile(p)
    return p:isLocalPlayer() and p:getCurrentSquare() and not p:isDead() and not p:isAsleep()
        and not p:isMoving() and not p:isRunning() and not p:isSprinting() and not p:isAiming()
        and not p:isAttacking() and not p:isShoving() and not p:isClimbing() and not p:isKnockedDown()
end
local function slot(e) return {selected=e,live=e,signature=e.pourSignature or (e.amount>0 and Inventory.mix(e))} end
function Pour.capture(entry)
    if entry.amount>0 then entry.pourSignature=Inventory.mix(entry);return entry.pourSignature~=nil end
    return true
end
local function held(slot_) return slot_ and slot_.borrowed end

-- Only snapshots from this click may be used. A new target is never discovered
-- after a native action, and a display label is never an inventory identity.
function Pour.new(player,world,source,targets,options,read)
    if not source or not targets or #targets<1 or #targets>512 or type(read)~="function" then
        return nil,"Choose at least one exact destination."
    end
    local seen, frozen = {[source.id]=true}, {}
    for _,e in ipairs(targets) do
        if not e or seen[e.id] or e.scope=="loot" and (not options.pourLootToLoot
            or source.scope~="loot" or source.container~=e.container) then return nil,"The chosen destinations changed." end
        seen[e.id],frozen[#frozen+1]=true,slot(e)
    end
    local shelf=source.scope=="loot" and source.container or nil
    local inPlaceGround=shelf and shelf:getType()=="floor" and source.object and source.object~=source.item
    local anchor=source.pourAnchor
    if shelf and shelf:getType()~="floor" then
        anchor=anchor or world:pourShelfAnchor(shelf)
        if not anchor or not world:pourShelfReachable(shelf,anchor) then return nil,"The selected storage moved or closed." end
    end
    local Fluid, Move = require "LootBox/PourNative", require "LootBox/PourMove"
    return setmetatable({player=player, world=world, source=slot(source), targets=frozen, read=read, options=options,
        shelf=shelf,anchor=anchor,inPlaceGround=inPlaceGround,expected=source.amount, index=1,count=0,liters=0,
        move=Move.new(player), pour=Fluid.new(player), state="running", name="Pour Into"}, Pour)
end

function Pour:allowed()
    local prefs, pane = self.read()
    if not prefs or not mobile(self.player) or self.cancelReason then return false end
    if self.shelf and pane~=self.shelf then
        -- A stock ground pour turns the character; the game may automatically
        -- select a different loot tab. Let the already-owned action settle
        -- against the same reachable world item, but never start another
        -- destination because of a stale view. Loans still require that tab.
        local owned=self.inPlaceGround and self.pour:isBusy() and self.target and self.target.selected.scope~="loot"
        local done=self.inPlaceGround and not self.target and not self.moving and not self.endReason and self.count>0
            and (self.index>#self.targets or FluidUtil.roundTransfer(self.expected)<=0)
        if not owned and not done then return false end
    end
    if self.shelf and self.shelf:getType()~="floor" and not self.world:pourShelfReachable(self.shelf,self.anchor) then return false end
    for _,s in ipairs({self.source,self.target or false}) do
        if s and s.selected.groundAnchor
            and not require("LootBox/PourGround").reachable(self.player,s.selected.groundAnchor) then return false end
    end
    return self.options.pourLootToLoot==prefs.pourLootToLoot and self.options.pourFillScope==prefs.pourFillScope
        and self.options.pourFillOrder==prefs.pourFillOrder
end

function Pour:isBusy() return self.state=="running" or self.state=="cancelling" end
function Pour:status()
    return {state=self.state,reason=self.reason,action="pour",intent="pour",done=self.count,total=#self.targets,pourLiters=self.liters,
        moved=self.count,skipped=0,reasons={},hasJob=self:isBusy(),canPreview=not self:isBusy(),canPause=false,canResume=false}
end

function Pour:finish(state, reason)
    if not self:isBusy() then return end
    self.state,self.reason=state,reason
    -- The active target may have been retired. Audit every original lease,
    -- not just the current target, including an unconfirmed in-flight move.
    local remaining={}
    local function report(s)
        if not (held(s) or s.uncertain or self.moving==s) then return end
        local where="location unconfirmed; check the original displayed storage as well"
        -- A changed capacity invalidates the action, not the exact location
        -- of an otherwise identified vessel when reporting an outstanding loan.
        local ok,known,live=pcall(Inventory.accessible,self.player,self.world,s.live,self.shelf,true)
        if ok and known then
            if live.container==self.player:getInventory() then where="confirmed in main inventory"
            elseif live.container==s.selected.container then where="confirmed in original displayed storage" end
        end
        remaining[#remaining+1]=s.selected.label.." [ID "..tostring(s.selected.id).."]: "..where
    end
    report(self.source)
    for _,e in ipairs(self.targets) do report(e) end
    if #remaining>0 then self.reason=(self.reason or "Stopped.").." Check main inventory: "..table.concat(remaining,"; ").."." end
    if self.launched and not self.silent and PZActionCompletionHUD then
        pcall(function() PZActionCompletionHUD.show(self.player:getPlayerNum(),{brand="LOOTBOX",theme="loot",
            title=state=="finished" and "Pour complete" or "Pour stopped",status=state~="finished" and "stopped" or nil,
            detail=string.format("%d vessel%s | %.3f L confirmed",self.count,self.count==1 and "" or "s",self.liters),
            note=state~="finished" and self.reason or nil}) end)
    end
end

function Pour:cancel(silent)
    if not self:isBusy() then return true end
    self.silent,self.cancelReason,self.state=silent,"Pour cancelled or interrupted.","cancelling"
    if self.pour:isBusy() then self.pour:cancel() end
    if self.move:isBusy() then self.move:cancel() end
    if not self.pour:isBusy() and not self.move:isBusy() then self:finish("cancelled",self.cancelReason) end
    return true
end

function Pour:accessible(s,refresh)
    local ok,entry=Inventory.accessible(self.player,self.world,s.live,self.shelf,refresh)
    -- Amounts legitimately evolve through stock pours. Capacity was part of
    -- the selected fill ratio and maximum volume; never silently increase it.
    if not ok or not sameAmount(entry.capacity,s.selected.capacity) then return false end
    return true,entry
end
local function safeToMove(self,item)
    return item:isFavorite()==false and self.world:protected(item)==false
end

-- A lease can be returned only while its exact replica, volume, mixture and
-- protections still match. A changed target is not permission to move it back.
function Pour:unchanged(s)
    local ok,entry=self:accessible(s)
    if not ok then return false end
    local amount=s==self.source and self.expected or s.settledAmount or s.selected.amount
    local mix=s.signature
    if s.hasSettled then mix=s.settledMix end
    return sameAmount(entry.amount,amount) and (amount==0 or Inventory.sameMix(entry,mix))
end

local function idle(player)
    local q=ISTimedActionQueue.getTimedActionQueue(player)
    return q and not q.current and #q.queue==0 and not player:hasTimedActions()
end

-- Failed/changed work never advances to a new target. If the player is still
-- idle, offer each other unchanged shelf loan ONE ordinary return, target
-- before source. Cancellation, foreign work or lost visibility start no moves.
function Pour:unwind(reason,blocked)
    self.endReason=self.endReason or reason
    if blocked then blocked.noReturn=true end
    if not self:allowed() or not idle(self.player) then self:finish("cancelled",self.endReason);return end
    for _,s in ipairs({self.target or false,self.source}) do
        if held(s) and not s.noReturn then
            s.noReturn=true
            if self:unchanged(s) and safeToMove(self,s.live.item) then self:transfer(s,true);return end
        end
    end
    self:finish("cancelled",self.endReason)
end

function Pour:transfer(s,returning)
    local p,original=self.player,s.selected
    if not loanable(original) or not self:allowed() or not self:unchanged(s) or not safeToMove(self,s.live.item) then
        self:unwind("The original location or vessel is no longer available.",s);return
    end
    if original.groundAnchor and not self.groundMove then
        self.move=require("LootBox/PourGround").new(p)
        self.groundMove=true -- all loans in a captured floor pane use this route
    end
    local from=s.live.container
    local to=returning and original.container or p:getInventory()
    self.moving,self.returning=s,returning
    local ok,why=self.move:start(s.live.item,from,to,function(phase,item)
        if not self:allowed() then return false end
        if phase=="admit" then return self:unchanged(s) and safeToMove(self,item) end
        return true -- receipt may precede the mirrored remove/add
    end,original.groundAnchor)
    if not ok then self.moving,self.returning=nil,nil;self:unwind(why or "The game refused to move this vessel.",s);return end
    self.launched=true
end

function Pour:tickMove()
    local ok,why,item=self.move:poll()
    if ok==nil then return end
    local s,returning=self.moving,self.returning
    self.moving,self.returning=nil,nil
    if not ok then
        s.uncertain=true
        if self.cancelReason then self:finish("cancelled",self.cancelReason)
        else self:unwind(why or "The exact inventory move was not confirmed.",s) end
        return
    end
    local holder=returning and s.selected.container or self.player:getInventory()
    local fresh=Inventory.rebind(self.player,self.world,s.selected,item,holder,self.shelf)
    if not fresh then
        s.uncertain=true
        self:unwind("The received vessel did not match the selected item.",s);return
    end
    s.live,s.borrowed,s.uncertain=fresh,not returning,false
    if self.cancelReason then self:finish("cancelled",self.cancelReason);return end
    if not sameAmount(fresh.capacity,s.selected.capacity) then
        self:unwind("The received vessel capacity changed; no further pour was requested.",s);return
    end
    if returning and s==self.target and not self.endReason then self.index,self.target=self.index+1,nil end
end

function Pour:tickFluid()
    local ok,why,amount=self.pour:poll()
    if ok==nil then return end
    if amount and amount>0 then self.liters=self.liters+amount end
    if self.cancelReason then self:finish("cancelled",self.cancelReason);return end
    if not ok then self:unwind(why or "The fluid transfer was not confirmed.");return end
    local a,b=self:accessible(self.source,true)
    local c,d=self:accessible(self.target,true)
    if not a or not c or not sameAmount(b.amount,self.expected-amount) or not sameAmount(d.amount,self.targetStart+amount) then
        self:unwind("The exact vessels no longer match the confirmed amounts.");return
    end
    self.count,self.expected,self.source.live,self.target.live=self.count+1,b.amount,b,d
    if held(self.target) then
        self.target.hasSettled,self.target.settledAmount,self.target.settledMix=true,d.amount,Inventory.mix(d)
        self:transfer(self.target,true)
    else self.index,self.target=self.index+1,nil end
end

function Pour:step()
    if not self:isBusy() then return end
    if not self.cancelReason and not self:allowed() then self:cancel();return end
    if self.move:isBusy() then self:tickMove();return end
    if self.pour:isBusy() then self:tickFluid();return end
    if self.cancelReason then self:finish("cancelled",self.cancelReason);return end
    if not idle(self.player) then self:cancel();return end
    if self.endReason then self:unwind(self.endReason);return end
    local valid,src=self:accessible(self.source)
    if not valid or not sameAmount(src.amount,self.expected)
        or (src.amount>0 and not Inventory.sameMix(src,self.source.signature)) then self:unwind("The selected source changed.",self.source);return end
    self.source.live=src
    if self.index>#self.targets or FluidUtil.roundTransfer(self.expected)<=0 then
        if held(self.source) then self:transfer(self.source,true);return end
        self:finish("finished","The selected pouring work is complete.");return
    end
    self.target=self.targets[self.index]
    local ready,dst=self:accessible(self.target)
    if not ready or not sameAmount(dst.amount,self.target.selected.amount) or (dst.amount>0 and not Inventory.sameMix(dst,self.target.signature))
        or not Inventory.compatible(src,dst) then
        self:unwind("A selected destination changed; no further pour was requested.",self.target);return
    end
    self.target.live=dst
    if loanable(self.source.selected) and not held(self.source) then self:transfer(self.source,false);return end
    if loanable(self.target.selected) and not held(self.target) then self:transfer(self.target,false);return end
    self.targetStart=dst.amount
    local checkedMix
    local ok,why=self.pour:start(src.item,dst.item,nil,function(_,_,phase)
        if not self:allowed() then return false end
        local post=phase=="observe"
        local sok,sn=self:accessible(self.source,post)
        local tok,tn=self:accessible(self.target,post)
        if not sok or not tok then return false end
        if phase=="admit" then
            return sameAmount(sn.amount,self.expected) and sameAmount(tn.amount,self.targetStart)
                and Inventory.sameMix(sn,self.source.signature) and (tn.amount==0 or Inventory.sameMix(tn,self.target.signature))
        end
        local ms=getTimestampMs()
        if not checkedMix or ms-checkedMix>=500 then
            if sn.amount>0 and not Inventory.sameMix(sn,self.source.signature) then return false end
            -- Once stock has mixed the target its recipe may legitimately differ.
            -- Before any actual gain, its originally chosen mixture still must match.
            if tn.amount>0 and sameAmount(tn.amount,self.targetStart)
                and not Inventory.sameMix(tn,self.target.signature) then return false end
            checkedMix=ms
        end
        return true
    end)
    if ok then self.launched=true else self:unwind(why or "The game refused this fluid transfer.") end
end

function Pour:tick()
    if not self:isBusy() then return end
    local ok=pcall(self.step,self)
    if not ok then
        self:cancel()
        if not self.move:isBusy() and not self.pour:isBusy() then self:finish("failed","Pour stopped because a game binding changed.") end
    end
end
return Pour
