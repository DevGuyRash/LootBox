-- The stock Take/Transfer/Add actions execute on the multiplayer authority.
-- Admission here only checks the client bindings needed to observe them.
local function enabled()
    return isClient() and not isServer()
        and type(getSpecificPlayer)=="function" and type(getCell)=="function"
        and type(getTimestampMs)=="function" and ISTimedActionQueue~=nil
        and ISTimedActionQueue.getTimedActionQueue~=nil and SafeHouse~=nil
        and SafeHouse.isSafehouseAllowInteract~=nil and SafeHouse.isSafehouseAllowLoot~=nil
end
return {enabled=enabled}
