-- The optional "before it starts" dialog, and the trash-can check on arrival.
local K = require "LootBox/UIKit"
local App = require "LootBox/App"
local PlanList = require "LootBox/PlanList"
local Log = require "LootBox/Log"

local Review = K.Window:derive("LootBoxReview")
Review.open = {}

local choices = { confirmQuickMoves = "Don't ask before moving items", confirmQuickCleanup = "Don't ask before throwing things away",
    confirmBinReviews = "Don't ask at trash cans" }

-- options: {kind="plan"|"bin"|"condense", plan, title, request, notice, interaction, start=function(skip) -> ok, err}
function Review.show(playerIndex, options)
    if Review.open[playerIndex] then Review.open[playerIndex]:close() end
    local o = K.Window.new(Review, "review", 480, 420, 400, 300)
    o.playerIndex, o.options = playerIndex, options
    o.title = options.title or "Review"
    Review.open[playerIndex] = o
    return K.Window.show(o)
end

function Review:build()
    local options, plan = self.options, self.options.plan
    local trash = options.kind == "bin" or (options.request and options.request.destination.kind == "trash")
    self.heading = K.label(self, "", "text", K.TITLE)
    self.sub = K.text(self, "", "dim")
    self.rows = K.list(self, self)
    if options.kind == "bin" then
        local bin, existing = plan.bin, #(plan.moves or {})
        self.heading:set("Empty this trash can?")
        local space = bin.capacity and bin.used and string.format("%.1f of %.1f full. ", bin.used, bin.capacity) or ""
        self.sub:set(space .. (#(plan.skipped or {}) > 0 and "It holds protected items, so it cannot be used."
            or existing > 0 and "Everything in it now is deleted together with what you throw away."
            or "It looks empty. Only what you throw away is deleted."), #(plan.skipped or {}) > 0 and "warn" or "dim")
        self.rows:fill(PlanList.rows(plan, { heading = "Already in there", tone = "bad" }))
        self.rows.emptyText = "Nothing in it."
    else
        self.heading:set(options.heading or options.title)
        self.sub:set(options.notice or (PlanList.summary(plan) .. (trash and ". Thrown away items are gone for good." or ".")), options.notice and "warn" or "dim")
        self.rows:fill(PlanList.rows(plan, { tone = trash and "bad" or nil }))
        self.rows.emptyText = plan.condense and (plan.condense.reason or "Your bags are already packed well.") or "Nothing here can be moved."
    end
    local key = options.preference
    if key then self.skip = K.toggle(self, choices[key], false, self, nil, "You can turn this back on in LootBox settings.") end
    local ready = options.kind == "bin" and plan.canApprove == true or (options.kind ~= "bin" and (#plan.moves > 0 or (plan.pending or 0) > 0))
    self.go = K.button(self, options.kind == "bin" and "Empty and continue" or trash and "Throw away" or "Start", self, Review.accept, trash and "danger" or "primary")
    self.go:setEnable(ready)
    if options.startWithoutBins then
        self.withoutBins = K.button(self, "Throw away, skip can checks", self, function(window) window:accept(nil, window.options.startWithoutBins) end, "danger",
            "Does not stop to ask at trash cans, for this job only.")
        self.withoutBins:setEnable(ready)
    end
    self.other = K.button(self, options.kind == "bin" and "Use another can" or "Change...", self, Review.alternative, "plain")
    if not options.other then self.other:setVisible(false) end
    self.cancel = K.button(self, options.kind == "bin" and "Not now" or "Cancel", self, Review.close, "ghost")
end

function Review:layout()
    if not self.rows then return end
    local x, y, width = K.PAD, self:top(), self.width - 2 * K.PAD
    K.place(self.heading, x, y)
    y = y + getTextManager():getFontHeight(K.TITLE) + 4
    local height = self.sub:measure(width)
    K.place(self.sub, x, y, width, height)
    y = y + height + K.GAP
    local footer = self:bottom() - K.ROW
    local skipY = footer - ((self.skip or self.withoutBins) and (K.ROW + 4) or 0)
    K.place(self.rows, x, y, width, skipY - y - K.GAP)
    if self.skip then K.place(self.skip, x, skipY) end
    K.place(self.cancel, x, footer)
    K.place(self.other, x + self.cancel.width + K.GAP, footer)
    K.place(self.go, x + width - self.go.width, footer)
    if self.withoutBins then K.place(self.withoutBins, x + width - self.withoutBins.width, skipY) end
end

function Review:fail(text)
    self.sub:set(text, "bad")
    self:layout()
end

function Review:accept(_, start)
    local ok, err = (start or self.options.start)(self.skip and self.skip.on)
    Log.info(self.options.interaction, "REVIEW", "answer", "start", "ok", ok ~= nil and ok ~= false, "error", err)
    if not ok then self:fail(tostring(err or "This could not start.")); return end
    if self.skip and self.skip.on then App.setPreferences({ [self.options.preference] = false }) end
    self:close()
end

function Review:alternative()
    local ok, err = self.options.other()
    if ok == nil and err then self:fail(tostring(err)); return end
    self:close()
end

function Review:close()
    if not self.closed then Review.open[self.playerIndex] = nil end
    K.Window.close(self)
end

function Review.closeAll()
    local active = {}
    for _, window in pairs(Review.open) do active[#active + 1] = window end
    for _, window in ipairs(active) do window:close() end
end

return Review
