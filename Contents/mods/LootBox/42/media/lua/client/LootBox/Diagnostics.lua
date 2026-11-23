local Diagnostics = {}

-- Console only. Pass fixed event/reason codes and counts, never UI reasons,
-- exceptions, object handles, item identifiers, or user-supplied labels.
function Diagnostics.emit(action, event, state, phase, code, format, ...)
    pcall(function(...)
        local mode = isServer and isServer() and "server" or isClient and isClient() and "MP" or "SP"
        local line = string.format("[LootBox] action=%s event=%s state=%s phase=%s mode=%s reason=%s",
            action, event, state, phase, mode, code)
        print(line .. (format and string.format(format, ...) or ""))
    end, ...)
end

return Diagnostics
