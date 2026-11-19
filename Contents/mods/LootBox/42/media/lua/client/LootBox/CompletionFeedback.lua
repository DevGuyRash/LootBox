local Feedback = {}

local function countLabel(count, unit, action)
    return tostring(count) .. " " .. unit .. (count == 1 and "" or "s") .. " " .. action
end

local function show(player, title, detail, elapsed, status, note)
    local hud = PZActionCompletionHUD
    if not hud or not player.getPlayerNum then return end
    local ok, failure = pcall(function()
        detail[#detail + 1] = hud.duration(math.max(0, elapsed) / 1000)
        hud.show(player:getPlayerNum(), {brand = "LOOTBOX", theme = "loot", title = title,
            detail = table.concat(detail, " \226\128\162 "), status = status, note = note})
    end)
    if not ok then print("[LootBox] Completion card unavailable: " .. tostring(failure)) end
end

function Feedback.job(player, plan, view, measured, stamp)
    local destination = plan and plan.request and plan.request.destination.kind
    local condense = plan and plan.action == "condense"
    local kind = condense and "Condense" or destination == "trash" and "Cleanup"
        or destination == "inventory" and "Loot run" or destination == "vehicle" and "Vehicle haul"
        or (destination == "labels" or destination == "matching") and "Sort" or "Transfer"
    local detail = {}
    local moved, cleared = view.moved or 0, view.cleared or 0
    if destination == "trash" then
        if cleared > 0 then detail[#detail + 1] = countLabel(cleared, "item", "cleared in place") end
        if moved > 0 then detail[#detail + 1] = countLabel(moved, "item", "delivered to trash") end
    elseif moved > 0 then
        detail[#detail + 1] = countLabel(moved, condense and "transfer" or "item", condense and "made" or "moved")
        if not condense and measured.movedWeight > 0 then
            detail[#detail + 1] = string.format("%.1f weight", measured.movedWeight)
        end
    elseif view.state == "finished" then
        detail[#detail + 1] = condense and "No transfers needed" or "No items moved"
    end
    if (view.skipped or 0) > 0 then detail[#detail + 1] = countLabel(view.skipped, "item", "skipped") end
    local suffix, note, status = " complete", nil, nil
    if view.state == "finished_with_skips" then
        local row = view.reasons and view.reasons[1]
        suffix, note, status = " finished with notes", row and row.reason or view.reason, "stopped"
    elseif view.state == "failed" or view.state == "cancelled" then
        suffix, note, status = view.state == "failed" and " stopped" or " cancelled", view.reason, "stopped"
    end
    show(player, kind .. suffix, detail, (measured.pausedAt or stamp) - measured.startedAt, status, note)
end

function Feedback.consume(player, state, reason, outcome, count, elapsed)
    local detail, title, status, note = {}
    if count > 0 then detail[#detail + 1] = countLabel(count, "portion", "confirmed") end
    if state == "finished" then
        if outcome == "target" then title = "Selected need satisfied"
        elseif outcome == "exhausted" then title = "Selected stack exhausted"
        elseif outcome == "different_amount" then title, note = "Drink amount differed", reason
        else title = "Requested portion consumed" end
    else
        title, status, note = state == "failed" and "Til Full stopped" or "Til Full cancelled", "stopped", reason
    end
    show(player, title, detail, elapsed, status, note)
end

return Feedback
