local Inventory = require "LootBox/PourInventory"
local Log = require "LootBox/Log"

local Pour = {}
Pour.__index = Pour
-- Litres are Java floats that a pour rounds every frame (see PourNative).
local function sameAmount(a,b) return type(a)=="number" and type(b)=="number" and math.abs(a-b)<=.005 end
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
local Actor = require "LootBox/PourActor"
local function slot(e) return {selected=e,live=e,signature=e.pourSignature or (e.amount>0 and Inventory.mix(e))} end
local function held(slot_) return slot_ and slot_.borrowed end

local function scopeOf(entry)
    if not entry then return "none" end
    if entry.scope=="loot" then return (entry.groundSquare or entry.groundAnchor) and "ground" or "loot" end
    return entry.scope
end
local function describe(entry,player)
    return "{"..Log.item(entry.item,player).." scope="..scopeOf(entry).." place="..tostring(entry.place)
        ..string.format(" litres=%.5f/%.5f",entry.amount or 0,entry.capacity or 0).." relation="..tostring(entry.relation).."}"
end

-- Only snapshots from this click may be used. A new target is never discovered
-- after a native action, and a display label is never an inventory identity.
function Pour.new(player,world,source,targets,options,read,clickedReceiver)
    local id=options and options.interaction or Log.intent("pour","Pour "..tostring(source and source.label),player)
    local function refuse(check,reason,...)
        Log.warn(id,"REFUSED","op","pour-start","check",check,"reason",reason,...)
        return nil,reason
    end
    if not source or not targets or #targets<1 or #targets>512 or type(read)~="function" then
        return refuse("selection","Choose at least one exact destination.","targets",targets and #targets)
    end
    if clickedReceiver and (#targets~=1 or not targets[1] or targets[1].item~=clickedReceiver
        or targets[1].scope~="loot") then return refuse("receiver","The selected receiver changed.","targets",#targets) end
    local seen, frozen = {[source.id]=true}, {}
    for _,e in ipairs(targets) do
        if not e or seen[e.id] or not Inventory.legalScope(source,e,options,clickedReceiver) then
            return refuse("destination-scope","The chosen destinations changed.","target",e and describe(e,player),
                "duplicate",e and seen[e.id]==true,"sourceScope",scopeOf(source),"lootToLoot",options.pourLootToLoot)
        end
        seen[e.id],frozen[#frozen+1]=true,slot(e)
    end
    local origin=clickedReceiver and targets[1] or source.scope=="loot" and source
    local shelf=origin and origin.container
    local inPlaceGround=origin and origin.groundSquare~=nil
    local anchor=origin and origin.pourAnchor
    if shelf and shelf:getType()~="floor" then
        if not anchor and not clickedReceiver then anchor=world:pourShelfAnchor(shelf) end
        if not anchor or not world:pourShelfReachable(shelf,anchor) then
            return refuse("storage-unreachable","The selected storage moved or closed.","shelf",Log.container(shelf,player),
                "anchored",anchor~=nil,"player",Log.player(player))
        end
    end
    local Fluid, Move = require "LootBox/PourNative", require "LootBox/PourMove"
    Log.info(id,"START","op","pour","route",options.pourRoute,"source",describe(source,player),"targets",#targets,
        "fillScope",options.pourFillScope,"fillOrder",options.pourFillOrder,"lootToLoot",options.pourLootToLoot,
        "container",Log.container(source.container,player),"shelf",shelf and Log.container(shelf,player) or nil,
        "player",Log.player(player))
    for index,e in ipairs(targets) do
        if index>40 then Log.trace(id,"TARGET","more",#targets-40);break end
        Log.trace(id,"TARGET","n",index,"vessel",describe(e,player),"container",Log.container(e.container,player))
    end
    return setmetatable({player=player, world=world, source=slot(source), targets=frozen, read=read, options=options,
        shelf=shelf,anchor=anchor,inPlaceGround=inPlaceGround,expected=source.amount, index=1,count=0,liters=0,
        interaction=id,startedAt=getTimestampMs(),move=Move.new(player,id), pour=Fluid.new(player,id),
        state="running", name="Pour Into"}, Pour)
end

-- Whether work may go on, or the reason it may not.
function Pour:allowed()
    local prefs, pane = self.read(self.shelf)
    if not prefs then return false,"Pour controls or the current context are unavailable." end
    local blocked = Actor.blocked(self.player)
    if blocked then return false,blocked end
    if self.cancelReason then return false,"Cancellation was already requested." end
    if self.shelf and pane~=self.shelf then
        -- A stock ground pour turns the character; the game may automatically
        -- select a different loot tab. Let the already-owned action settle
        -- against the same reachable world item, but never start another
        -- destination because of a stale view. Loans still require that tab.
        local owned=self.inPlaceGround and self.pour:isBusy() and self.target and
            (self.target.selected.scope~="loot" or self.source.selected.scope~="loot")
        local done=self.inPlaceGround and not self.target and not self.moving and not self.endReason and self.count>0
            and (self.index>#self.targets or FluidUtil.roundTransfer(self.expected)<=0)
        if not owned and not done then return false,"The selected loot pane changed or closed." end
    end
    if self.shelf and self.shelf:getType()~="floor" and not self.world:pourShelfReachable(self.shelf,self.anchor) then
        return false,"The original loot container is no longer accessible."
    end
    for _,s in ipairs({self.source,self.target or false}) do
        if s and s.selected.groundAnchor
            and not require("LootBox/PourGround").reachable(self.player,s.selected.groundAnchor) then
            return false,"The original ground position is no longer accessible."
        end
    end
    if self.options.pourLootToLoot~=prefs.pourLootToLoot or self.options.pourFillScope~=prefs.pourFillScope
        or self.options.pourFillOrder~=prefs.pourFillOrder then
        return false,"Pour settings changed."
    end
    return true
end

function Pour:isBusy() return self.state=="running" or self.state=="cancelling" end
function Pour:status()
    return {state=self.state,reason=self.reason,action="pour",intent="pour",done=self.count,total=#self.targets,pourLiters=self.liters,
        moved=self.count,skipped=0,reasons={},hasJob=self:isBusy(),canPreview=not self:isBusy(),canPause=false,canResume=false}
end

function Pour:finish(state, reason)
    if not self:isBusy() then return end
    self.state,self.reason=state,reason
    local diagnostic=self.endReason or self.cancelDiagnostic or reason or "Reason unavailable."
    local active=self.target or self.targets[self.index] or self.targets[#self.targets]
    local emit=state=="finished" and Log.info or Log.warn
    emit(self.interaction,"END","op","pour","state",state,"reason",diagnostic,"phase",self.stopPhase or self.phase or "prepare",
        "vessels",self.count,"of",#self.targets,"litres",self.liters,"submitted",self.launched==true,
        "elapsedMs",getTimestampMs()-self.startedAt,"source",Log.item(self.source.live.item,self.player),
        "target",active and Log.item(active.live.item,self.player) or nil,"player",Log.player(self.player))
    -- The active target may have been retired. Audit every original lease,
    -- not just the current target, including an unconfirmed in-flight move.
    local remaining, places = {}, {main=0, original=0, unknown=0}
    local function report(s)
        if not (held(s) or s.retained or s.uncertain or self.moving==s) then return end
        local place,where="unknown","location unconfirmed; check main inventory and the original storage"
        -- A changed capacity invalidates the action, not the exact location
        -- of an otherwise identified vessel. A pending native receipt is
        -- different: a local replica alone cannot resolve a disputed loan.
        if not s.uncertain and self.moving~=s then
            local known,live=Log.guard("Pour.finish",Inventory.accessible,self.player,self.world,s.live,self.shelf,true)
            if known then
                if live.container==self.player:getInventory() then place,where="main","confirmed in main inventory"
                elseif live.container==s.selected.container then place,where="original","confirmed in original displayed storage" end
            end
        end
        places[place]=places[place]+1
        remaining[#remaining+1]=s.selected.label.." [ID "..tostring(s.selected.id).."]: "..where
        Log.warn(self.interaction,"VESSEL-LEFT","vessel",Log.item(s.live.item,self.player),"place",place,
            "uncertain",s.uncertain==true,"moving",self.moving==s)
    end
    report(self.source)
    for _,e in ipairs(self.targets) do report(e) end
    if #remaining>0 then self.reason=(self.reason or "Stopped.").." Vessel locations: "..table.concat(remaining,"; ").."." end
    if self.launched and not self.silent and PZActionCompletionHUD then
        Log.guard("Pour.card",function()
            local note = ""
            if places.main>0 then note=note.."In main inventory: "..places.main..". " end
            if places.unknown>0 then note=note.."Location unconfirmed: "..places.unknown..". Check Current job. " end
            if places.original>0 then note=note.."In original storage: "..places.original..". " end
            note=note..(reason or "Stopped.")
            PZActionCompletionHUD.show(self.player:getPlayerNum(),{brand="LOOTBOX",theme="loot",
                title=state=="finished" and "Pour complete" or "Pour stopped",status=state~="finished" and "stopped" or nil,
                detail=string.format("%d vessel%s | %.3f L confirmed",self.count,self.count==1 and "" or "s",self.liters),
                note=state~="finished" and note or nil})
        end)
    end
end

function Pour:cancel(silent, diagnostic)
    if not self:isBusy() then return true end
    self.cancelDiagnostic=self.cancelDiagnostic or diagnostic or (silent and "Session cleanup." or "Cancel requested.")
    self.stopPhase=self.stopPhase or self.phase
    self.silent,self.cancelReason,self.state=silent,diagnostic or "Pour cancelled or interrupted.","cancelling"
    if self.pour:isBusy() then self.pour:cancel() end
    if self.move:isBusy() then self.move:cancel() end
    if not self.pour:isBusy() and not self.move:isBusy() then self:finish("cancelled",self.cancelReason) end
    return true
end

function Pour:accessible(s,refresh)
    local ok,entry=Inventory.accessible(self.player,self.world,s.live,self.shelf,refresh)
    -- Amounts legitimately evolve through stock pours. Capacity was part of
    -- the selected fill ratio and maximum volume; never silently increase it.
    if not ok then return false,entry end
    if not sameAmount(entry.capacity,s.selected.capacity) then
        return false,string.format("capacity: %.5f selected, %.5f now",s.selected.capacity,entry.capacity)
    end
    return true,entry
end
local function safeToMove(self,item)
    local protected,reason=self.world:protected(item)
    return item:isFavorite()==false and protected==false,reason
end

-- A lease can be returned only while its exact replica, volume, mixture and
-- protections still match. A changed target is not permission to move it back.
function Pour:unchanged(s)
    local ok,entry=self:accessible(s)
    if not ok then return false,entry end
    local amount=s==self.source and self.expected or s.settledAmount or s.selected.amount
    local mix=s.signature
    if s.hasSettled then mix=s.settledMix end
    if not sameAmount(entry.amount,amount) then return false,string.format("litres: %.5f expected, %.5f now",amount,entry.amount) end
    return entry.amount==0 or Inventory.sameMix(entry,mix),"mixture-changed"
end

local function idle(player)
    local q=ISTimedActionQueue.getTimedActionQueue(player)
    return q and not q.current and #q.queue==0 and not player:hasTimedActions()
end

-- Failed/changed work never advances to a new target. If the player is still
-- idle, offer each other unchanged shelf loan ONE ordinary return, target
-- before source. Cancellation, foreign work or lost visibility start no moves.
function Pour:unwind(reason,blocked,check)
    self.stopPhase=self.stopPhase or self.phase or "prepare"
    if reason~=self.endReason then
        Log.warn(self.interaction,"STOPPED","phase",self.stopPhase,"reason",reason,"check",check,
            "vessel",blocked and Log.item(blocked.live.item,self.player) or nil)
    end
    self.endReason=self.endReason or reason
    if blocked then blocked.noReturn=true end
    local allowed,why=self:allowed()
    if not allowed or not idle(self.player) then
        Log.trace(self.interaction,"NO-RETURN","reason",why or "queue-busy")
        self:finish("cancelled",self.endReason);return
    end
    for _,s in ipairs({self.target or false,self.source}) do
        if held(s) and not s.noReturn then
            s.noReturn=true
            if self:unchanged(s) and safeToMove(self,s.live.item) then self:transfer(s,true);return end
        end
    end
    self:finish("cancelled",self.endReason)
end

function Pour:transfer(s,returning)
    self.phase=(s==self.source and "source-" or "target-")..(returning and "return" or "pickup")
    local p,original=self.player,s.selected
    local check=not loanable(original) and "not-loanable"
    if not check then
        local ok,why=self:allowed()
        if ok then ok,why=self:unchanged(s) end
        if ok then ok,why=safeToMove(self,s.live.item);why=not ok and "protected: "..tostring(why) end
        check=not ok and why
    end
    if check then self:unwind("The original location or vessel is no longer available.",s,check);return end
    if original.groundAnchor and not self.groundMove then
        self.move=require("LootBox/PourGround").new(p,self.interaction)
        self.groundMove=true -- all loans in a captured floor pane use this route
    end
    local from=s.live.container
    local to=returning and original.container or p:getInventory()
    self.moving,self.returning=s,returning
    local ok,why=self.move:start(s.live.item,from,to,function(phase,item)
        local allowed,why=self:allowed()
        if not allowed then return false,why end
        if phase=="admit" then
            local same,check=self:unchanged(s)
            if not same then return false,check end
            local movable,protection=safeToMove(self,item)
            return movable,not movable and "protected: "..tostring(protection) or nil
        end
        return true -- receipt may precede the mirrored remove/add
    end,original.groundAnchor)
    if not ok then self.moving,self.returning=nil,nil;self:unwind(why or "The game refused to move this vessel.",s);return end
    self.launched=true
end

function Pour:tickMove()
    local ok,why,item,retained=self.move:poll()
    if ok==nil then return end
    local s,returning=self.moving,self.returning
    self.moving,self.returning=nil,nil
    if not ok then
        local stayed=retained~=nil and retained==s.live.item
        s.uncertain,s.retained=not stayed,stayed and not returning
        if self.cancelReason then self:finish("cancelled",self.cancelReason)
        else self:unwind(why or "The exact inventory move was not confirmed.",s) end
        return
    end
    local holder=returning and s.selected.container or self.player:getInventory()
    local fresh=Inventory.rebind(self.player,self.world,s.selected,item,holder,self.shelf)
    Log.trace(self.interaction,"LOAN",returning and "returned" or "borrowed",Log.item(item,self.player),"recognised",fresh~=nil)
    if not fresh then
        s.uncertain=true
        self:unwind("The received vessel did not match the selected item.",s);return
    end
    s.live,s.borrowed,s.uncertain,s.retained=fresh,not returning,false,false
    if self.cancelReason then self:finish("cancelled",self.cancelReason);return end
    if not sameAmount(fresh.capacity,s.selected.capacity) then
        self:unwind("The received vessel capacity changed; no further pour was requested.",s);return
    end
    if returning and s==self.target and not self.endReason then self.index,self.target=self.index+1,nil end
    self.phase="prepare"
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
        self:unwind("The exact vessels no longer match the confirmed amounts.",nil,not a and b or not c and d
            or string.format("source %.5f expected, %.5f now; target %.5f expected, %.5f now; tolerance .005",
                self.expected-amount,b.amount,self.targetStart+amount,d.amount));return
    end
    self.count,self.expected,self.source.live,self.target.live=self.count+1,b.amount,b,d
    if held(self.target) then
        self.target.hasSettled,self.target.settledAmount,self.target.settledMix=true,d.amount,Inventory.mix(d)
        self:transfer(self.target,true)
    else self.index,self.target=self.index+1,nil;self.phase="prepare" end
end

function Pour:step()
    if not self:isBusy() then return end
    if not self.cancelReason then
        local allowed, reason=self:allowed()
        if not allowed then
            Log.warn(self.interaction,"STOPPED","phase",self.phase or "prepare","reason",reason,"player",Log.player(self.player))
            self:cancel(nil,reason);return
        end
    end
    if self.move:isBusy() then self:tickMove();return end
    if self.pour:isBusy() then self:tickFluid();return end
    if self.cancelReason then self:finish("cancelled",self.cancelReason);return end
    if not idle(self.player) then
        Log.warn(self.interaction,"STOPPED","reason","queue-busy","queue",Log.queue(self.player))
        self:cancel(nil,"Another action was active.");return
    end
    if self.endReason then self:unwind(self.endReason);return end
    local valid,src=self:accessible(self.source)
    local changed=not valid and src or not sameAmount(src.amount,self.expected)
        and string.format("litres: %.5f expected, %.5f now",self.expected,src.amount)
        or src.amount>0 and not Inventory.sameMix(src,self.source.signature) and "mixture-changed"
    if changed then self:unwind("The selected source changed.",self.source,changed);return end
    self.source.live=src
    if self.index>#self.targets or FluidUtil.roundTransfer(self.expected)<=0 then
        if held(self.source) then self:transfer(self.source,true);return end
        self:finish("finished","The selected pouring work is complete.");return
    end
    self.target=self.targets[self.index]
    local ready,dst=self:accessible(self.target)
    changed=not ready and dst or not sameAmount(dst.amount,self.target.selected.amount)
        and string.format("litres: %.5f selected, %.5f now",self.target.selected.amount,dst.amount)
        or dst.amount>0 and not Inventory.sameMix(dst,self.target.signature) and "mixture-changed"
        or not Inventory.compatible(src,dst) and "game-refuses-transfer"
    if changed then
        self:unwind("A selected destination changed; no further pour was requested.",self.target,changed);return
    end
    self.target.live=dst
    if loanable(self.source.selected) and not held(self.source) then self:transfer(self.source,false);return end
    if loanable(self.target.selected) and not held(self.target) then self:transfer(self.target,false);return end
    self.targetStart=dst.amount
    local checkedMix
    self.phase="fluid"
    local ok,why=self.pour:start(src.item,dst.item,nil,function(_,_,phase)
        local allowed,why=self:allowed()
        if not allowed then return false,why end
        local post=phase=="observe"
        local sok,sn=self:accessible(self.source,post)
        local tok,tn=self:accessible(self.target,post)
        if not sok then return false,"source: "..tostring(sn) end
        if not tok then return false,"target: "..tostring(tn) end
        if phase=="admit" then
            return sameAmount(sn.amount,self.expected) and sameAmount(tn.amount,self.targetStart)
                and Inventory.sameMix(sn,self.source.signature) and (tn.amount==0 or Inventory.sameMix(tn,self.target.signature)),
                string.format("contents: source %.5f expected, %.5f now; target %.5f expected, %.5f now, or a mixture changed",
                    self.expected,sn.amount,self.targetStart,tn.amount)
        end
        local ms=getTimestampMs()
        if not checkedMix or ms-checkedMix>=500 then
            if sn.amount>0 and not Inventory.sameMix(sn,self.source.signature) then return false,"source-mixture" end
            -- Once stock has mixed the target its recipe may legitimately differ.
            -- Before any actual gain, its originally chosen mixture still must match.
            if tn.amount>0 and tn.amount<=self.targetStart
                and not Inventory.sameMix(tn,self.target.signature) then return false,"target-mixture" end
            checkedMix=ms
        end
        return true
    end)
    if ok then self.launched=true else self:unwind(why or "The game refused this fluid transfer.") end
end

function Pour:tick()
    if not self:isBusy() then return end
    local ok,err=pcall(self.step,self)
    if not ok then
        Log.fault(self.interaction,"Pour.step",err,"phase",self.phase,"index",self.index)
        self:cancel(nil,"Pour stopped because a game binding changed.")
        if not self.move:isBusy() and not self.pour:isBusy() then self:finish("failed","Pour stopped because a game binding changed.") end
    end
end
return Pour
