-- One thing the player asked for, carried out as a series of stock actions.
-- A subclass decides the next step; this waits its turn, follows the action,
-- looks for its result and ends cleanly. One step runs at a time, the player's
-- own queued actions go first, and nothing new starts once they intervene.
local Act = require "LootBox/Act"
local Items = require "LootBox/Items"
local Clock = require "LootBox/Clock"
local Log = require "LootBox/Log"
local Feedback = require "LootBox/CompletionFeedback"

local Flow = {}
Flow.__index = Flow
-- How long a confirmed result may take to show up, and how long the player's
-- own queue may keep us waiting.
Flow.SETTLE_MS, Flow.PATIENCE_MS = 4000, 30000

function Flow.class()
    local class = setmetatable({}, { __index = Flow })
    class.__index = class
    return class
end

function Flow.begin(class, player, interaction, fields)
    local self = setmetatable(fields or {}, class)
    self.player, self.interaction, self.state, self.startedAt = player, interaction, "running", Clock.now()
    self.count, self.liters, self.total = self.count or 0, self.liters or 0, self.total or 1
    return self
end

function Flow:isBusy() return self.state == "running" or self.state == "cancelling" end

function Flow:status()
    return { state = self.state, reason = self.reason, action = self.action, intent = self.action, done = self.count, moved = self.count,
        total = self.total, pourLiters = self.liters, skipped = self.skipped or 0, reasons = {}, hasJob = self:isBusy(),
        canPause = false, canResume = false }
end

-- Runs stock actions when the player is free, then done(). failed(why)
-- defaults to ending the flow.
function Flow:act(opts, done, failed) self.pending = { opts = opts, done = done, failed = failed } end

local function launch(self)
    local pending = self.pending
    self.pending = nil
    local opts = pending.opts
    opts.interaction = self.interaction
    local run, why, code = Act.run(self.player, opts)
    if run then
        self.launched, self.run, self.done, self.failed = true, run, pending.done, pending.failed
        return
    end
    Log.warn(self.interaction, "REFUSED", "op", opts.op, "reason", why, "check", code, "queue", Log.queue(self.player),
        "player", Log.player(self.player))
    if pending.failed then return pending.failed(why) end
    return self:finish("cancelled", why)
end

-- Looks for a result until look() returns something, then done(result).
function Flow:await(look, done, missed, ms)
    self.waiting = { look = look, done = done, missed = missed, untilAt = Clock.now() + (ms or Flow.SETTLE_MS) }
end

function Flow:cancel(silent, reason)
    if not self:isBusy() or self.stopping then return true end
    self.silent, self.stopping, self.state = silent, reason or "Cancelled", "cancelling"
    if self.run then self.run:cancel(self.stopping) else self:finish("cancelled", self.stopping) end
    return true
end

-- Extra facts for the log line that ends the flow, and the player's card.
function Flow:facts() end
function Flow:card() end

function Flow:finish(state, reason)
    if not self:isBusy() then return end
    self.state, self.reason, self.waiting, self.pending = state, reason, nil, nil
    local good = state == "finished"
    local emit = good and Log.info or Log.warn
    emit(self.interaction, "END", "op", self.action, "state", state, "reason", reason, "done", self.count, "of", self.total,
        "litres", self.liters > 0 and string.format("%.3f", self.liters) or nil, "submitted", self.launched == true,
        "elapsedMs", Clock.now() - self.startedAt, "player", Log.player(self.player))
    if self.launched and not self.silent and not self.automatic then
        local card = Log.guard("Flow.card", self.card, self)
        if card then
            Feedback.show(self.player, card.title, card.detail or {}, Clock.now() - self.startedAt, not good and "stopped" or nil,
                card.note or not good and reason or nil)
        end
    end
end

local function step(self)
    if self.run then
        local ok, why, check = self.run:poll()
        if ok == nil then return end
        local done, failed = self.done, self.failed
        self.run, self.done, self.failed = nil, nil, nil
        if self.stopping then return self:finish("cancelled", self.stopping) end
        if ok then return done() end
        if failed then return failed(why, check) end
        return self:finish("cancelled", why)
    end
    if self.waiting then
        local waiting = self.waiting
        local found, extra, more = waiting.look()
        if found then
            self.waiting = nil
            return waiting.done(found, extra, more)
        elseif Clock.now() >= waiting.untilAt then
            self.waiting = nil
            return waiting.missed()
        end
        return
    end
    local blocked = Act.blocked(self.player)
    if blocked then return self:finish("cancelled", blocked) end
    if not Act.idle(self.player) or Act.moving(self.player) then
        self.heldAt = self.heldAt or Clock.now()
        if Clock.now() - self.heldAt >= Flow.PATIENCE_MS then
            return self:finish("cancelled", "You were busy with something else")
        end
        return
    end
    self.heldAt = nil
    if not self.pending then self:next() end
    if self.pending and self:isBusy() then launch(self) end
end

function Flow:tick()
    if not self:isBusy() then return end
    local ok, err = pcall(step, self)
    if ok then return end
    Log.fault(self.interaction, "Flow." .. tostring(self.action), err)
    if self.run then self:cancel(false, "Something in the game changed")
    else self:finish("failed", "Something in the game changed") end
end

Flow.Act, Flow.Items = Act, Items
return Flow
