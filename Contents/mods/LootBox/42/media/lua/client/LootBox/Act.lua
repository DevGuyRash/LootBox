-- Owns the stock actions one step of ours queued, from the click to the end.
-- Everything else in the player's queue is theirs and is never disturbed.
require "TimedActions/ISTimedActionQueue"
local Log = require "LootBox/Log"

local Act = {}
Act.__index = Act
Act.LIMIT_MS = 120000

local function queueOf(player) return ISTimedActionQueue.getTimedActionQueue(player) end

local function queued(queue, action)
    for _, entry in ipairs(queue.queue) do if entry == action then return true end end
    return false
end

function Act.idle(player)
    local queue = queueOf(player)
    return not queue.current and #queue.queue == 0 and not player:hasTimedActions()
end

-- The local player's own movement. The generic moving flag also covers being
-- pushed, sitting down and animations.
function Act.moving(player)
    if player.pressedMovement and player:pressedMovement(false) then return true end
    if player.isPlayerMoving then return player:isPlayerMoving() end
    return player:isMoving()
end

-- What makes the player unable or plainly unwilling to go on, or nil.
function Act.blocked(player)
    if not player:isLocalPlayer() or not player:getCurrentSquare() then return "You are not in the world" end
    if player:isDead() or player:isAsleep() then return "You cannot act now" end
    if player:isAiming() then return "You aimed" end
    if player:isAttacking() or player:isShoving() then return "You attacked or shoved" end
    if player:isRunning() or player:isSprinting() then return "You ran" end
    if player:isClimbing() or player:isKnockedDown() or (player.isbFalling and player:isbFalling())
        or (player.isPerformingGrappleAnimation and player:isPerformingGrappleAnimation()) then
        return "You cannot act in this state"
    end
    if player.isDraggingCorpse and player:isDraggingCorpse() then return "Put down the corpse first" end
    local trade = ISTradingUI and ISTradingUI.GetUIForPlayer and ISTradingUI.GetUIForPlayer(player)
    if trade and trade:isVisible() then return "Finish trading first" end
end

-- Runs a stock callback that resets the queue without losing what else is in
-- it: the player's own actions, and follow-ups of ours that must still happen.
local function sparing(self, callback, action, ...)
    local queue, spared = queueOf(self.player), {}
    if queue.current ~= action then return callback(action, ...) end
    for _, entry in ipairs(queue.queue) do
        if entry ~= action and (not self.owned[entry] or self.keep[entry]) then spared[#spared + 1] = entry end
    end
    for _, entry in ipairs(spared) do queue:removeFromQueue(entry) end
    local ok, result = pcall(callback, action, ...)
    for _, entry in ipairs(spared) do if not queued(queue, entry) then queue:addToQueue(entry) end end
    if not ok then error(result, 0) end
    return result
end

local function allowed(self, phase)
    if self.problem then return false end
    if not self.allow then return true end
    local ok, why, check = Log.guard("Act.allow", self.allow, phase)
    if ok then return true end
    self.problem, self.check = why or "The game or your selection changed", check
    return false
end

local function hook(self, action)
    local stop = action.stop
    function action:canMergeAction() return false end
    action.stop = function(stopping, ...)
        if not self.keep[action] then
            self.stopped = true
            self.problem = self.problem or Act.blocked(self.player) or Act.moving(self.player) and "You moved"
                or "The game stopped the action"
        end
        return sparing(self, stop, stopping, ...)
    end
end

-- The action that does the work. It is checked at the last moment before the
-- game commits to it (in multiplayer: before the request is sent).
local function hookMain(self, action)
    local wait, start, perform, valid = action.waitToStart, action.start, action.perform, action.isValid
    action.waitToStart = function(waiting, ...)
        if not allowed(self, "start") then waiting:forceStop(); return true end
        if wait(waiting, ...) ~= false then return true end
        if not valid(waiting) then
            self.problem = self.problem or "The game refused the action"
            waiting:forceStop()
            return true
        end
        return false
    end
    action.start = function(starting, ...)
        self.started = true
        local result = start(starting, ...)
        if self.onStart then Log.guard("Act.onStart", self.onStart, starting) end
        return result
    end
    action.perform = function(performing, ...)
        self.performed = true
        if self.onPerform then Log.guard("Act.onPerform", self.onPerform, performing) end
        return perform(performing, ...)
    end
end

-- Queues stock actions and follows them.
--   begin    queues the actions with the game's own functions
--   main     main(action): which of them does the work; default the last one
--   allow    allow(phase) with phase "start" or "run"; false, reason stops it
--   keepAfter  what is queued behind it must happen even if the work stops
--   onStart, onPerform, limitMs
function Act.run(player, opts)
    local queue = queueOf(player)
    if not Act.idle(player) then return nil, "Finish the current action first", "busy" end
    local blocked = Act.blocked(player)
    if blocked then return nil, blocked, "blocked" end
    local self = setmetatable({ player = player, op = opts.op, interaction = opts.interaction, allow = opts.allow, owned = {}, keep = {},
        onStart = opts.onStart, onPerform = opts.onPerform, startedAt = getTimestampMs(),
        limit = opts.limitMs or Act.LIMIT_MS }, Act)
    local ok, why = pcall(opts.begin)
    if not ok then
        Log.fault(self.interaction, "Act.begin:" .. tostring(opts.op), why)
        why = "The game could not start this action"
    end
    local main
    for _, action in ipairs(queue.queue) do
        self.owned[action] = true
        if not opts.main or opts.main(action) then main = action end
    end
    local past = false
    for _, action in ipairs(queue.queue) do
        if past and opts.keepAfter then self.keep[action] = true end
        past = past or action == main
        hook(self, action)
    end
    if main then hookMain(self, main) end
    self.action = main
    if not ok or not main then
        why = not ok and why or "The game did not start this action"
        self:cancel(why)
        return nil, why, "not-started"
    end
    Log.trace(self.interaction, "OP", "op", self.op, "action", main.Type, "queue", Log.queue(player))
    return self
end

-- Something the player queued behind ours.
function Act:foreign()
    for _, entry in ipairs(queueOf(self.player).queue) do if not self.owned[entry] then return true end end
    return false
end

function Act:cancel(reason)
    self.problem = self.problem or reason or "Cancelled"
    local queue = queueOf(self.player)
    local current = queue.current
    for index = #queue.queue, 1, -1 do
        local action = queue.queue[index]
        if self.owned[action] and not self.keep[action] and action ~= current then
            action:forceCancel()
            queue:removeFromQueue(action)
        end
    end
    if current and self.owned[current] and not self.keep[current] and not self.stopSent and current.action then
        self.stopSent = true
        current:forceStop()
    end
end

-- nil while any of it is queued, then true, or false and the reason.
function Act:poll()
    local queue = queueOf(self.player)
    local busy = false
    for action in pairs(self.owned) do if queued(queue, action) then busy = true; break end end
    if busy then
        if not self.performed then
            if getTimestampMs() - self.startedAt >= self.limit then self:cancel("The action took too long")
            elseif self.problem or not allowed(self, "run") then self:cancel(self.problem) end
        end
        return nil
    end
    local ok = self.performed == true
    local why = not ok and (self.problem or "The action ended early") or nil
    local emit = ok and Log.trace or Log.warn
    emit(self.interaction, "OP-END", "op", self.op, "ok", ok, "reason", why, "check", not ok and self.check or nil,
        "started", self.started == true, "stopped", self.stopped == true, "elapsedMs", getTimestampMs() - self.startedAt,
        "player", not ok and Log.player(self.player) or nil)
    return ok, why, self.check
end

return Act
