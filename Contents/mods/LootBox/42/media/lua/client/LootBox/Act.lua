-- Owns the stock actions one step of ours queued, from the click to the end.
-- Everything else in the player's queue is theirs and is never disturbed.
require "TimedActions/ISTimedActionQueue"
local Clock = require "LootBox/Clock"
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

-- Stock stop resets the whole queue, and after the player moves or aims the
-- engine clears what was started inside it too. What must survive waits here
-- until the player is free.
local spared = {}

function Act.spare(player, keeps)
    local queue, held = queueOf(player), spared[player]
    for index = 1, #queue.queue do
        local entry = queue.queue[index]
        if entry ~= queue.current and keeps(entry) then
            held = held or { since = Clock.now() }
            held[#held + 1] = entry
        end
    end
    spared[player] = held
    for _, entry in ipairs(held or {}) do queue:removeFromQueue(entry) end
end

-- The player's own movement, aim, fight or death ends their queue, as ever.
function Act.yields(player) return Act.moving(player) or Act.blocked(player) ~= nil end

function Act.restore()
    for player, held in pairs(spared) do
        if player:isDead() or Clock.now() - held.since >= Act.LIMIT_MS then spared[player] = nil
        elseif Act.idle(player) and not Act.yields(player) then
            spared[player] = nil
            local queue = queueOf(player)
            for _, entry in ipairs(held) do queue:addToQueue(entry) end
        end
    end
end

function Act.holding(player) return spared[player] ~= nil end

local function waiting(self)
    for _, entry in ipairs(spared[self.player] or {}) do if self.owned[entry] then return true end end
    return false
end

local function spare(self)
    local yields = Act.yields(self.player)
    Act.spare(self.player, function(entry) return self.keep[entry] or not self.owned[entry] and not yields end)
end

local function allowed(self, phase)
    if self.problem then return false end
    if not self.allow then return true end
    local ok, why = Log.guard("Act.allow", self.allow, phase, self.action)
    if ok then return true end
    self.problem = why or "The game or your selection changed"
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
        spare(self)
        return stop(stopping, ...)
    end
end

-- The action that does the work. It is checked at the last moment before the
-- game commits to it (in multiplayer: before the request is sent).
local function hookMain(self, action, lasting)
    local wait, start, perform, valid = action.waitToStart, action.start, action.perform, action.isValid
    local function refuse()
        self.problem = self.problem or "The game refused the action"
        self:cancel(self.problem)
        return true
    end
    action.isValid = function(...) return valid(...) or lasting ~= nil and self.started == true and lasting() end
    action.waitToStart = function(...)
        if not allowed(self, "start") then return refuse() end
        if wait(...) ~= false then return true end
        if not valid(...) then return refuse() end
        return false
    end
    action.start = function(...)
        self.started = true
        return start(...)
    end
    action.perform = function(...)
        -- The game also "performs" a bite whose food vanished before it began.
        if self.started then self.performed, self.performedAt = true, Clock.now()
        else self.problem = self.problem or "The item is gone" end
        return perform(...)
    end
end

-- Queues stock actions and follows them.
--   begin    queues the actions with the game's own functions
--   main     main(action): which of them does the work; default the first
--   allow    allow(phase, action), phase "start" or "run"; false, reason stops it
--   keepAfter  what is queued behind it must happen even if the work stops
--   lasting    finishing can make the game call the action invalid an instant
--              before it ends (a drained bottle); lasting() says it may go on
--   limitMs
function Act.run(player, opts)
    if not Act.idle(player) then return nil, "Finish the current action first", "busy" end
    local blocked = Act.blocked(player)
    if blocked then return nil, blocked, "blocked" end
    local self = setmetatable({ player = player, op = opts.op, interaction = opts.interaction, allow = opts.allow, owned = {}, keep = {},
        startedAt = Clock.now(), limit = opts.limitMs or Act.LIMIT_MS }, Act)
    -- The game may start the first action inside the call that queues it, so
    -- each is taken in hand on its way there.
    local add = ISTimedActionQueue.add
    ISTimedActionQueue.add = function(action)
        if action.character == player then
            local after = self.action ~= nil
            self.owned[action] = true
            if after and opts.keepAfter then self.keep[action] = true end
            hook(self, action)
            if not after and (not opts.main or opts.main(action)) then
                self.action = action
                hookMain(self, action, opts.lasting)
            end
        end
        return add(action)
    end
    local ok, why = pcall(opts.begin)
    ISTimedActionQueue.add = add
    if not ok then
        Log.fault(self.interaction, "Act.begin:" .. tostring(opts.op), why)
        why = "The game could not start this action"
    end
    local main = self.action
    if main and not self.performed and not self.stopped and not queued(queueOf(player), main) then main = nil end
    if not ok or not main then
        why = not ok and why or self.problem or "The game did not start this action"
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
        -- The game drops an unstarted action without stopping it, then resets the queue.
        if not current:isStarted() then spare(self) end
        current:forceStop()
    end
end

-- nil while any of it is queued, then true, or false and the reason.
function Act:poll()
    local queue = queueOf(self.player)
    local busy = waiting(self)
    for action in pairs(self.owned) do if queued(queue, action) then busy = true; break end end
    if busy then
        if self.performed then
            -- Follow-ups are the game's own; do not wait on them for ever.
            if Clock.now() - self.performedAt < self.limit then return nil end
        else
            local blocked = Act.blocked(self.player)
            if blocked then self:cancel(blocked)
            elseif Clock.now() - self.startedAt >= self.limit then self:cancel("The action took too long")
            elseif self.problem or not allowed(self, "run") then self:cancel(self.problem) end
            return nil
        end
    end
    local ok = self.performed == true
    local why = not ok and (self.problem or "The action ended early") or nil
    local emit = ok and Log.trace or Log.warn
    emit(self.interaction, "OP-END", "op", self.op, "ok", ok, "reason", why, "started", self.started == true, "stopped", self.stopped == true, "elapsedMs", Clock.now() - self.startedAt,
        "player", not ok and Log.player(self.player) or nil)
    return ok, why
end

return Act
