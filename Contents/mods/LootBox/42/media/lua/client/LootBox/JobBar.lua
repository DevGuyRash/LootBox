-- A small strip for the job in progress. It appears only when a job lasts or
-- needs you, stays out of the way, and unfolds when clicked.
local K = require "LootBox/UIKit"
local App = require "LootBox/App"

local JobBar = ISPanel:derive("LootBoxJobBar")
JobBar.bars = {}
local place
local WIDTH, LIST = 330, 190
local DELAY = 1200

local needs = { needs_review = true, paused = true, pausing = true, cancelling = true }

function JobBar.new(playerIndex)
    local width = math.max(WIDTH, math.floor(WIDTH * K.LINE / 18))
    local x = place and place.x or (getCore():getScreenWidth() - width - 24)
    local y = place and place.y or 110
    local o = ISPanel.new(JobBar, x, y, width, 10)
    o.playerIndex = playerIndex
    o.background, o.border = false, false
    o.moveWithMouse = false
    o:initialise()
    o:addToUIManager()
    return o
end

function JobBar:createChildren()
    self.pauseButton = K.button(self, "Pause", self, JobBar.pauseOrResume, "ghost")
    self.stopButton = K.button(self, "Stop", self, JobBar.stop, "ghost", "Stop this job for good. Nothing already moved is undone.")
    self.hideButton = K.button(self, "Hide", self, JobBar.hide, "ghost", "The job keeps running. The job key brings this back.")
    self.actionButton = K.button(self, "Check trash can", self, JobBar.action, "primary")
    self.forgetButton = K.button(self, "Forget it", self, JobBar.forget, "ghost", "Stop tracking gear that can no longer be found.")
    self.notes = K.list(self, self)
    self.notes.emptyText = "No notes yet."
    for _, button in ipairs({ self.pauseButton, self.stopButton, self.hideButton, self.forgetButton }) do button:setHeight(K.LINE + 6); button:setWidth(K.width(button.title) + 14) end
end

local function app(self) return App.peek(self.playerIndex) end

function JobBar:pauseOrResume()
    local instance = app(self)
    if not instance then return end
    local status, ok, err = instance:status()
    if self.mode == "previous" then ok, err = instance:resumePrevious()
    elseif status.canResume then ok, err = instance:resume()
    else ok, err = instance:pause() end
    self.problem = not ok and err or nil
end

function JobBar:stop()
    local instance = app(self)
    if not instance then return end
    if self.mode == "previous" then instance:discardPrevious() else
        local _, err = instance:cancel()
        self.problem = err
    end
end

function JobBar:hide() self.dismissed = true; self:setVisible(false) end

function JobBar:action()
    local instance = app(self)
    if not instance then return end
    if self.recovering then
        local ok, err = instance:recoverPersonalGear()
        self.problem = not ok and err or nil
    else require("LootBox/UI").showBinReview(self.playerIndex) end
end

function JobBar:forget()
    local instance = app(self)
    if instance then local ok, err = instance:forgetPersonalGear(); self.problem = not ok and err or nil end
end

function JobBar:onMouseDown(x, y)
    self.downX, self.downY, self.moving, self.dragged = getMouseX(), getMouseY(), true, false
    self:bringToTop()
    return true
end

function JobBar:drag()
    if not self.moving then return end
    local dx, dy = getMouseX() - self.downX, getMouseY() - self.downY
    if self.dragged or math.abs(dx) + math.abs(dy) > 4 then
        self.dragged = true
        self:setX(self.x + dx); self:setY(self.y + dy)
        self.downX, self.downY = getMouseX(), getMouseY()
        place = { x = self.x, y = self.y }
    end
end
function JobBar:onMouseMove() self:drag() end
function JobBar:onMouseMoveOutside() self:drag() end
function JobBar:onMouseUpOutside() self.moving = false end
function JobBar:onMouseUp()
    if self.moving and not self.dragged then self.open = not self.open end
    self.moving = false
    return true
end

local function noteRows(status)
    local rows, byReason = {}, {}
    for _, reason in ipairs(status.reasons or {}) do
        local key = tostring(reason.reason or reason.status)
        local row = byReason[key]
        if not row then
            row = { title = tostring(reason.itemName), sub = key, subTone = "warn", count = 0, tooltip = key }
            byReason[key] = row
            rows[#rows + 1] = row
        elseif row.count < 4 then row.title = row.title .. ", " .. tostring(reason.itemName) end
        row.count = row.count + 1
        row.right = tostring(row.count)
    end
    for _, room in ipairs(status.survey and status.survey.unsearchedRooms or {}) do
        rows[#rows + 1] = { title = tostring(room.roomName) .. ", floor " .. tostring(room.z), sub = tostring(room.reason), subTone = "bad" }
    end
    return rows
end

function JobBar:read(status)
    local previous = status.previous
    self.recovering = status.recovery and (status.recovery.blocking or (status.recovery.blocking == nil and status.recovery.pending)) or false
    self.mode = (status.hasJob or status.consuming) and "job" or self.recovering and "recovery" or previous and "previous" or "idle"
    local tone, line, fraction = "accent", "", nil
    local done, total = status.done or 0, status.total or 0
    if self.mode == "previous" then
        self.label, line, tone = previous.label or "Previous job", "Set aside. Resume it when you are ready.", "dim"
        done, total = previous.done or 0, previous.total or 0
    elseif self.mode == "recovery" then
        self.label = "Gear left in storage"
        line = tostring(status.recovery.reason or (tostring(status.recovery.count or 0) .. " items at " .. tostring(status.recovery.location or "a container")))
        tone = "warn"
    else
        self.label = status.label or "LootBox job"
        if status.state == "needs_review" then line, tone = "Check the trash can to continue", "warn"
        elseif status.state == "paused" then line, tone = "Paused. " .. tostring(status.reason or ""), "warn"
        elseif status.state == "pausing" then line, tone = "Pausing...", "warn"
        elseif status.state == "cancelling" then line, tone = "Stopping...", "warn"
        elseif status.state == "failed" then line, tone = tostring(status.reason or "Stopped"), "bad"
        else line = tostring(status.waiting or status.itemName or status.reason or "Working") end
    end
    if status.intent == "pour" then
        local litres = string.format("%.2f L poured", status.pourLiters or 0)
        line = line ~= "" and (line .. ". " .. litres) or litres
    elseif status.condense then
        line = tostring(status.condense.transfers or 0) .. " moves, carrying " .. string.format("%.1f", status.condense.currentWeight or 0)
            .. (status.state == "paused" and (". Paused. " .. tostring(status.reason or "")) or "")
    end
    local survey = status.survey
    if survey and status.state == "running" then line = "Room " .. tostring(math.min(survey.roomsTotal, survey.roomsDone + 1)) .. " of " .. tostring(survey.roomsTotal) .. ". " .. line end
    if total > 0 then fraction = math.min(1, done / total) end
    self.line, self.lineTone, self.fraction = self.problem or status.warning or line, self.problem and "bad" or tone, fraction
    self.count = total > 0 and (tostring(done) .. " / " .. tostring(total)) or nil
    self.skipped = status.skipped or 0
    self.pauseButton:setVisible(self.mode == "previous" or status.canPause == true or status.canResume == true)
    self.pauseButton:setTitle((self.mode == "previous" or status.canResume) and "Resume" or "Pause")
    self.pauseButton:setWidth(K.width(self.pauseButton.title) + 14)
    self.stopButton:setVisible(self.mode ~= "recovery")
    self.stopButton:setTitle(self.mode == "previous" and "Discard" or "Stop")
    self.stopButton:setWidth(K.width(self.stopButton.title) + 14)
    self.actionButton:setVisible(status.state == "needs_review" or self.mode == "recovery")
    self.actionButton:setTitle(self.mode == "recovery" and "Fetch my gear" or "Check trash can")
    self.forgetButton:setVisible(self.mode == "recovery")
    if self.open then
        local stamp = tostring(#(status.reasons or {})) .. ":" .. tostring(status.label)
        if stamp ~= self.noteStamp then self.noteStamp = stamp; self.notes:fill(noteRows(status), true) end
    end
end

function JobBar:arrange()
    local pad = K.PAD
    local y = pad + K.LINE + 8 + 6 + K.LINE + 8
    local right = self.width - pad + 6
    for _, button in ipairs({ self.hideButton, self.stopButton, self.pauseButton, self.forgetButton }) do
        if button:isVisible() then right = right - button.width; K.place(button, right, y); right = right - 2 end
    end
    if self.actionButton:isVisible() then K.place(self.actionButton, pad - 4, y - 3, K.width(self.actionButton.title) + 24, K.LINE + 10) end
    y = y + K.LINE + 6 + 8
    self.notes:setVisible(self.open == true)
    if self.open then
        K.place(self.notes, pad, y, self.width - 2 * pad, LIST)
        y = y + LIST + pad
    end
    if self.height ~= y then self:setHeight(y) end
end

function JobBar:prerender()
    local instance = app(self)
    if not instance then return end
    self:read(instance:status())
    self:arrange()
    local g, l, a = K.colors.glass, K.colors.line, K.colors[self.lineTone == "dim" and "dim" or self.lineTone] or K.colors.accent
    self:drawRect(0, 0, self.width, self.height, g.a, g.r, g.g, g.b)
    self:drawRectBorder(0, 0, self.width, self.height, 0.22, l.r, l.g, l.b)
    self:drawRect(0, 0, 3, self.height, 1, a.r, a.g, a.b)
    local pad, right = K.PAD, self.width - K.PAD
    if self.count then
        local d = K.colors.dim
        self:drawTextRight(self.count, right, pad, d.r, d.g, d.b, 1, K.FONT)
        right = right - K.width(self.count) - K.GAP
    end
    local t = K.colors.text
    self:drawText(K.fit(self.label, right - pad), pad, pad, t.r, t.g, t.b, 1, K.FONT)
    local y = pad + K.LINE + 6
    self:drawRect(pad, y, self.width - 2 * pad, 3, 0.14, 1, 1, 1)
    if self.fraction then
        local c = K.colors[self.lineTone == "warn" and "warn" or "accent"]
        self:drawRect(pad, y, (self.width - 2 * pad) * self.fraction, 3, 0.95, c.r, c.g, c.b)
    end
    local tint = K.colors[self.lineTone == "accent" and "dim" or self.lineTone] or K.colors.dim
    self:drawText(K.fit(self.line, self.width - 2 * pad), pad, y + 8, tint.r, tint.g, tint.b, 1, K.FONT)
end

function JobBar:onRightMouseUp() self.open = not self.open; return true end

function JobBar.show(playerIndex, problem)
    local bar = JobBar.bars[playerIndex]
    if not bar then bar = JobBar.new(playerIndex); JobBar.bars[playerIndex] = bar end
    bar.dismissed, bar.problem = false, problem
    bar:setVisible(true)
    bar:bringToTop()
    return bar
end

-- Called every frame with cheap checks only.
function JobBar.tick(playerIndex, instance, enabled)
    local bar = JobBar.bars[playerIndex]
    local jobs = instance.jobs:status()
    local active = instance:active()
    local now = getTimestampMs()
    if active and not instance.barSince then
        instance.barSince = now
        if bar then bar.dismissed, bar.problem, bar.open = false, nil, false end
    elseif not active then instance.barSince = nil end
    local recovery = instance:recoveryStatus()
    local blocking = recovery.blocking
    if blocking == nil then blocking = recovery.pending end
    local wanted = active and (needs[jobs.state] or now - (instance.barSince or now) > DELAY)
        or instance.parked ~= nil or blocking
    if bar and bar.dismissed then
        if not active and not instance.parked and not blocking then bar.dismissed = false end
        wanted = false
    end
    if bar and bar.pinned and not active then bar.pinned = false end
    if not enabled and not needs[jobs.state] and not (bar and bar.pinned) and not blocking then wanted = false end
    if wanted then
        if not bar then JobBar.show(playerIndex) elseif not bar:isVisible() then bar:setVisible(true) end
    elseif bar and bar:isVisible() and not bar.pinned then bar:setVisible(false) end
end

function JobBar.closeAll()
    for _, bar in pairs(JobBar.bars) do bar:setVisible(false); bar:removeFromUIManager() end
    JobBar.bars = {}
end

return JobBar
