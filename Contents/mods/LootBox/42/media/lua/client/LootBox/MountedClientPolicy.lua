-- Only the native multiplayer mod set can admit the mounted shortcut.
-- Standalone Lua restoration does not enter the stock active mod set.
local function listed()
    local mods=getActivatedMods()
    local count=mods and mods:size()
    if type(count)~="number" or count<1 or count>4096 or count%1~=0 then return false end
    local matches=0
    for i=0,count-1 do
        local id=mods:get(i)
        if type(id)~="string" then return false end
        if id:lower()=="lootbox" then
            if id~="LootBox" then return false end
            matches=matches+1
        end
    end
    return matches==1
end
local function enabled()
    if not isClient() or isServer() or type(getActivatedMods)~="function" then return false end
    local ok,value=pcall(listed)
    return ok and value==true
end
return {enabled=enabled}
