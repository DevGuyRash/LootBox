-- Time for deadlines. A paused game or a stalled frame does not use it up.
local Clock = {}
local FRAME_MS = 250
local last, total = nil, 0

function Clock.now()
    local stamp = getTimestampMs()
    local passed = last and not (isGamePaused and isGamePaused()) and stamp - last or 0
    total = total + math.max(0, math.min(FRAME_MS, passed))
    last = stamp
    return total
end

return Clock
