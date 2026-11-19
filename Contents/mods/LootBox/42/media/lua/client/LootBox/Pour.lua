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

function Pour.displayed(index)
    local page = getPlayerLoot and getPlayerLoot(index)
    if not page or not page.inventoryPane then return nil end
    local visible = page.getIsVisible or page.isVisible
    if type(visible)~="function" or not visible(page) then return nil end
    return page.inventoryPane.inventory
end

local function shelved(entry) return entry.scope=="loot" and entry.container:getType()~="floor" end
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
    local Fluid, Move = require "LootBox/PourNative", require "LootBox/PourMove"
    return setmetatable({player=player, world=world, source=slot(source), targets=frozen, read=read, options=options,
        shelf=source.scope=="loot" and source.container or nil, expected=source.amount, index=1,count=0,liters=0,
        move=Move.new(player), pour=Fluid.new(player), state="running", name="Pour Into"}, Pour)
end

function Pour:allowed()
    local prefs, pane = self.read()
    if not prefs or not mobile(self.player) or self.cancelReason then return false end
    if self.shelf and pane~=self.shelf then return false end
    if self.shelf and self.shelf:getType()~="floor" and not self.world:pourShelfReachable(self.shelf) then return false end
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
    local heldNames,known={},{}
    for _,s in ipairs({self.source,self.target or false,self.moving or false}) do
        if s and not known[s] and (held(s) or self.moving==s) then
            heldNames[#heldNames+1]=s.selected.label;known[s]=true
        end
    end
    if #heldNames>0 then self.reason=(self.reason or "Stopped.").." Check main inventory for "..table.concat(heldNames,", ").."." end
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
    return Inventory.accessible(self.player,self.world,s.live,self.shelf,refresh)
end
local function safeToMove(self,item)
    return item:isFavorite()==false and self.world:protected(item)==false
end

function Pour:transfer(s,returning)
    local p,original=self.player,s.selected
    if not shelved(original) or not self:allowed() or not self:accessible(s) or not safeToMove(self,s.live.item) then
        self:finish("cancelled","The original shelf or vessel is no longer available.");return
    end
    local from=s.live.container
    local to=returning and original.container or p:getInventory()
    self.moving,self.returning=s,returning
    local ok,why=self.move:start(s.live.item,from,to,function(phase,item)
        if not self:allowed() then return false end
        if phase=="admit" then return self:accessible(s) and safeToMove(self,item) end
        return true -- receipt may precede the mirrored remove/add
    end)
    if not ok then self.moving=nil;self:finish("failed",why or "The game refused to move this vessel.");return end
    self.launched=true
end

function Pour:tickMove()
    local ok,why,item=self.move:poll()
    if ok==nil then return end
    if not ok or self.cancelReason then self:finish("cancelled",self.cancelReason or why or "The exact inventory move was not confirmed.");return end
    local s,returning=self.moving,self.returning
    local holder=returning and s.selected.container or self.player:getInventory()
    local fresh=Inventory.rebind(self.player,self.world,s.selected,item,holder,self.shelf)
    if not fresh then self:finish("cancelled","The received vessel did not match the selected item.");return end
    s.live,s.borrowed=fresh,not returning
    self.moving,self.returning=nil,nil
    if returning and s==self.target then self.index,self.target=self.index+1,nil end
end

function Pour:tickFluid()
    local ok,why,amount=self.pour:poll()
    if ok==nil then return end
    if amount and amount>0 then self.liters=self.liters+amount end
    if not ok or self.cancelReason then self:finish("cancelled",self.cancelReason or why or "The fluid transfer was not confirmed.");return end
    local a,b=self:accessible(self.source,true)
    local c,d=self:accessible(self.target,true)
    if not a or not c or not sameAmount(b.amount,self.expected-amount) or not sameAmount(d.amount,self.targetStart+amount) then
        self:finish("failed","The exact vessels no longer match the confirmed amounts.");return
    end
    self.count,self.expected,self.source.live,self.target.live=self.count+1,b.amount,b,d
    if held(self.target) then self:transfer(self.target,true) else self.index,self.target=self.index+1,nil end
end

function Pour:step()
    if not self:isBusy() then return end
    if not self.cancelReason and not self:allowed() then self:cancel();return end
    if self.move:isBusy() then self:tickMove();return end
    if self.pour:isBusy() then self:tickFluid();return end
    if self.cancelReason then self:finish("cancelled",self.cancelReason);return end
    local q=ISTimedActionQueue.getTimedActionQueue(self.player)
    if not q or q.current or #q.queue~=0 or self.player:hasTimedActions() then self:cancel();return end
    local valid,src=self:accessible(self.source)
    if not valid or not sameAmount(src.amount,self.expected)
        or (src.amount>0 and not Inventory.sameMix(src,self.source.signature)) then self:finish("cancelled","The selected source changed.");return end
    self.source.live=src
    if self.index>#self.targets or FluidUtil.roundTransfer(self.expected)<=0 then
        if held(self.source) then self:transfer(self.source,true);return end
        self:finish(self.endReason and "cancelled" or "finished",self.endReason or "The selected pouring work is complete.");return
    end
    self.target=self.targets[self.index]
    local ready,dst=self:accessible(self.target)
    if not ready or not sameAmount(dst.amount,self.target.selected.amount) or (dst.amount>0 and not Inventory.sameMix(dst,self.target.signature))
        or not Inventory.compatible(src,dst) then
        -- No rejected or newly-filled target turns into permission to pour into
        -- a different one. Restore a previously staged source if still safe.
        if held(self.source) then
            self.endReason="A selected destination changed; remaining pours were stopped."
            self.index=#self.targets+1;self.target=nil;self:transfer(self.source,true);return
        end
        self:finish("cancelled","A selected destination changed; no further pour was requested.");return
    end
    self.target.live=dst
    if shelved(self.source.selected) and not held(self.source) then self:transfer(self.source,false);return end
    if shelved(self.target.selected) and not held(self.target) then self:transfer(self.target,false);return end
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
    if ok then self.launched=true else self:finish("failed",why or "The game refused this fluid transfer.") end
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
