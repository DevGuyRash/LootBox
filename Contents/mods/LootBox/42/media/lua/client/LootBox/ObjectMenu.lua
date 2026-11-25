-- The original right-click options of one container's own object, added to a
-- container icon's menu. Options the bare floor also offers, or that act on a
-- different object on that tile, are not about this container and are dropped.
local Log = require "LootBox/Log"

local ObjectMenu = {}
local active
local NO_PICK = -100000 -- off-screen, so screen pickers find nothing

function ObjectMenu.building() return active ~= nil end

local function resolve(container)
    if not container or container:getContainingItem() or container:getVehiclePart() or container:getType() == "floor" then return end
    local owner = container:getParent()
    if not owner or not instanceof(owner, "IsoObject") then return end
    if instanceof(owner, "IsoDeadBody") then
        local square = owner:getSquare()
        return square and owner or nil, square
    end
    if instanceof(owner, "IsoMovingObject") or instanceof(owner, "IsoWorldInventoryObject") then return end
    local square = owner:getSquare()
    if not square then return end
    local objects, index = square:getObjects(), owner:getObjectIndex()
    if index < 0 or index >= objects:size() or objects:get(index) ~= owner then return end
    local slot = owner:getContainerIndex(container)
    if slot < 0 or owner:getContainerByIndex(slot) ~= container then return end
    return owner, square
end

local function remove(menu, index)
    local option = menu.options[index]
    table.remove(menu.options, index)
    if menu.optionPool then table.insert(menu.optionPool, option) end
    menu.numOptions = menu.numOptions - 1
    for i = index, #menu.options do menu.options[i].id = i end
end

local function resize(menu)
    if menu.calcHeight then menu:calcHeight() end
    if menu.calcWidth then menu:setWidth(menu:calcWidth()) end
end

local function submenu(menu, option)
    return option.subOption and menu:getSubMenu(option.subOption) or nil
end

-- "mine": acts on this object. "other": acts on something else on the tile.
local function subject(scope, option)
    local result
    local function check(value)
        if value == nil or rawequal(value, scope.objects) or rawequal(value, scope.actor) or rawequal(value, scope.root) then return end
        if rawequal(value, scope.owner) or rawequal(value, scope.container) then result = "mine"; return end
        local kind = type(value)
        if kind ~= "table" and kind ~= "userdata" then return end
        if instanceof(value, "ItemContainer") then
            if value:getContainingItem() == nil and value:getParent() ~= scope.actor then result = result or "other" end
        elseif instanceof(value, "IsoObject") then
            if not instanceof(value, "IsoPlayer") then result = result or "other" end
        elseif kind == "table" then
            local object = rawget(value, "object")
            if rawequal(object, scope.owner) then result = "mine"
            elseif object ~= nil then result = result or "other" end
        end
    end
    check(option.target)
    for index = 1, 10 do check(option["param" .. index]) end
    return result
end

local function prune(scope, menu, first, baseline, prefix, depth)
    for index = #menu.options, first, -1 do
        local option = menu.options[index]
        local path = prefix .. tostring(option.name)
        local child = depth < 8 and submenu(menu, option) or nil
        local about, keep = subject(scope, option), nil
        if child then
            prune(scope, child, 1, baseline, path .. "\1", depth + 1)
            keep = #child.options > 0 or (about == "mine" and option.onSelect ~= nil)
        elseif depth == 1 and baseline[path] then keep = false -- "Walk to" and the like, even when they name this object
        elseif about == "mine" then keep = true
        elseif about == "other" or baseline[path] then keep = false
        else keep = option.onSelect ~= nil or not baseline[path] end
        if not keep then
            remove(menu, index)
        end
    end
    resize(menu)
end

local function collect(menu, first, names, prefix, depth)
    for index = first, #menu.options do
        local option = menu.options[index]
        local path = prefix .. tostring(option.name)
        names[path] = true
        local child = depth < 8 and submenu(menu, option) or nil
        if child then collect(child, 1, names, path .. "\1", depth + 1) end
    end
end

-- The game finds furniture to dismantle again by sprite. When that lookup
-- would hit a neighbour, the option must not run.
local function guardScrap(scope, menu, depth)
    local scrap = ISDisassembleMenu and ISDisassembleMenu.disassemble
    if not scrap then return end
    for index = #menu.options, 1, -1 do
        local option = menu.options[index]
        local child = depth < 8 and submenu(menu, option) or nil
        if child then guardScrap(scope, child, depth + 1) end
        if option.onSelect == scrap then
            local entry = option.param1
            local props = type(entry) == "table" and entry.moveProps
            local ok, found = pcall(function()
                return props and props.findOnSquare and props.spriteName and entry.square and props:findOnSquare(entry.square, props.spriteName)
            end)
            if ok and found and found ~= scope.owner then option.notAvailable = true end
        end
    end
end

local function scoped(scope, run)
    local undo = {}
    local function replace(owner, key, value)
        undo[#undo + 1] = { owner = owner, key = key, before = owner[key], installed = value }
        owner[key] = value
    end
    for _, key in ipairs({ "getMouseXScaled", "getMouseYScaled" }) do
        local original = _G[key]
        if original then replace(_G, key, function(...) if active == scope then return NO_PICK end return original(...) end) end
    end
    local get = ISContextMenu.get
    replace(ISContextMenu, "get", function(player, ...)
        -- Java providers need a real root menu (they read its instanceMap).
        if active == scope and player == scope.player then return scope.root end
        return get(player, ...)
    end)
    local logic = ISWorldObjectContextMenuLogic
    replace(_G, "ISWorldObjectContextMenuLogic", setmetatable({
        fetch = function(fetch, object, player, scan)
            if active ~= scope or player ~= scope.player then return logic.fetch(fetch, object, player, scan) end
            logic.fetch(fetch, object, player, false)
            fetch.building = scope.square:getBuilding()
            if SafeHouse then
                fetch.safehouse = SafeHouse.getSafeHouse(scope.square)
                fetch.safehouseAllowInteract = SafeHouse.isSafehouseAllowInteract(scope.square, scope.actor)
                fetch.safehouseAllowLoot = SafeHouse.isSafehouseAllowLoot(scope.square, scope.actor)
            end
            ISWorldObjectContextMenu.fetchSquares[scope.square] = true
        end,
    }, { __index = logic }))
    if ISVehicleMenu and ISVehicleMenu.FillMenuOutsideVehicle then
        local fill = ISVehicleMenu.FillMenuOutsideVehicle
        replace(ISVehicleMenu, "FillMenuOutsideVehicle", function(...) if active ~= scope then return fill(...) end end)
    end
    local world = scope.manager.getWorldMenu()
    local expand = world.getObjectsSquare
    replace(world, "getObjectsSquare", function(data, square)
        if active == scope and data.playerNum == scope.player then
            if square == scope.square and #data.squares == 0 then data.squares[1] = square end
            return
        end
        return expand(data, square)
    end)
    active = scope
    local ok, err = pcall(run)
    active = nil
    for index = #undo, 1, -1 do
        local entry = undo[index]
        if entry.owner[entry.key] == entry.installed then entry.owner[entry.key] = entry.before end
    end
    if not ok then Log.fault(scope.interaction, "ObjectMenu", err, "container", Log.container(scope.container, scope.actor)) end
    return ok
end

local function available(player, actor, square)
    if active or not ISContextManager or not ISContextManager.getInstance or not ISWorldObjectContextMenuLogic
        or not ISWorldObjectContextMenu or ISWorldObjectContextMenu.disableWorldMenu then return nil end
    local manager = ISContextManager.getInstance()
    if not manager or not manager.createWorldMenu or not manager.getWorldMenu or not manager.getWorldMenu() then return nil end
    if not actor or actor:isDead() or actor:isAsleep() then return nil end
    if JoypadState and JoypadState.players[player + 1] then return nil end
    if ISWorldMap_instance and ISWorldMap_instance:isVisible() then return nil end
    local trade = ISTradingUI and ISTradingUI.GetUIForPlayer(actor)
    if trade and trade:isVisible() then return nil end
    if SafeHouse and (not SafeHouse.isSafehouseAllowInteract(square, actor) or not SafeHouse.isSafehouseAllowLoot(square, actor)) then return nil end
    return manager
end

-- Adds the object's own options to root. Returns how many rows were added and
-- the world objects they describe.
function ObjectMenu.append(player, root, container, interaction)
    local actor = getSpecificPlayer(player)
    local part = container and container:getVehiclePart()
    if part then
        local vehicle = part:getVehicle()
        if not vehicle or actor:getVehicle() or not ISVehicleMenu or not ISVehicleMenu.FillMenuOutsideVehicle then return 0 end
        local first = #root.options
        Log.guard("ObjectMenu.vehicle", ISVehicleMenu.FillMenuOutsideVehicle, player, root, vehicle, false)
        -- What concerns the vehicle stays; what concerns another of its parts does not.
        local function other(option)
            for index = 0, 10 do
                local value = index == 0 and option.target or option["param" .. index]
                if value ~= nil and not rawequal(value, part) and instanceof(value, "VehiclePart") then return true end
            end
            return false
        end
        for index = #root.options, first + 1, -1 do if other(root.options[index]) then remove(root, index) end end
        resize(root)
        return #root.options - first
    end
    local owner, square = resolve(container)
    if not owner then return 0 end
    local manager = available(player, actor, square)
    if not manager then return 0 end
    local scope = { player = player, root = root, container = container, owner = owner, square = square,
        objects = { owner }, actor = actor, manager = manager, interaction = interaction }
    local start = #root.options
    local x, y = root.x, root.y
    local floor, baseline = square:getFloor(), {}
    if floor and floor ~= owner then
        local ground = { floor }
        scoped(scope, function() manager.createWorldMenu(player, floor, ground, NO_PICK, NO_PICK) end)
        collect(root, start + 1, baseline, "", 1)
        for index = #root.options, start + 1, -1 do remove(root, index) end
    end
    scoped(scope, function() manager.createWorldMenu(player, owner, scope.objects, NO_PICK, NO_PICK) end)
    local built = #root.options - start
    local liveOwner, liveSquare = resolve(container)
    if liveOwner ~= owner or liveSquare ~= square then
        for index = #root.options, start + 1, -1 do remove(root, index) end
        resize(root)
        return 0
    end
    prune(scope, root, start + 1, baseline, "", 1)
    guardScrap(scope, root, 1)
    if x and root.setX then root:setX(x); root:setY(y) end
    Log.trace(interaction, "object-menu", "container", Log.container(container, actor), "built", built,
        "kept", #root.options - start, "floorBaseline", floor ~= nil)
    return #root.options - start, scope.objects
end

return ObjectMenu
