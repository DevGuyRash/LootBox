-- Native Build 42 world context for an explicit pane target, not a mouse pick.
-- Stock and mods fill one native menu. Exact bindings can move to the pane
-- without copying callbacks; everything else stays in World Actions.
local Bridge = {}
local active
local NO_PICK = -100000 -- outside the render/picker list; NOT the popup position

function Bridge.current(player, menu, objects)
    if active and active.player == player and active.menu == menu and active.objects == objects then
        return active.container
    end
end

local function fixture(container)
    if not container or not instanceof(container, "ItemContainer") or container:getContainingItem()
        or container:getVehiclePart() or container:getType() == "floor" then return end
    local owner = container:getParent()
    if not owner or not instanceof(owner, "IsoObject") or instanceof(owner, "IsoMovingObject")
        or instanceof(owner, "BaseVehicle") or instanceof(owner, "IsoWorldInventoryObject") then return end
    local square = owner:getSquare()
    if not square then return end
    -- Pooling, removing/replacing furniture and multi-compartment fixtures:
    -- prove both directions against the current native objects, never a name.
    local objects, index = square:getObjects(), owner:getObjectIndex()
    if index < 0 or index >= objects:size() or objects:get(index) ~= owner then return end
    local slot = owner:getContainerIndex(container)
    if slot < 0 or slot >= owner:getContainerCount() or owner:getContainerByIndex(slot) ~= container then return end
    return owner, square
end

-- Only the Java builder's two tile-expanded providers need reconciliation.
-- Snapshot options by identity so nothing from the pane, pre-fill, or an
-- unrelated provider is removed just because it has the same display name.
local function visit(menu, fn, seen)
    if seen[menu] then return false end
    seen[menu] = true
    local removed = false
    for i = #menu.options, 1, -1 do
        local option = menu.options[i]
        local child = option.subOption and menu:getSubMenu(option.subOption)
        local emptied = child and visit(child, fn, seen) and #child.options == 0
        if fn(option, emptied) then
            -- 42 has removeLastOption and removeOptionByName, not removal by
            -- reference. Move just this entry to the end, preserving the
            -- order/ids of equally named siblings and normal option pooling.
            table.remove(menu.options, i)
            table.insert(menu.options, option)
            for j = i, #menu.options - 1 do menu.options[j].id = j end
            menu:removeLastOption()
            removed = true
        end
    end
    return removed
end

local function scrapResolves(object, entry)
    if not entry or entry.object ~= object or not entry.square or object:getSquare() ~= entry.square then return false end
    local props = entry.moveProps
    if not props or not props.findOnSquare or not props.spriteName then return false end
    -- This is the native callback's own lookup. A lower crate can share a
    -- sprite with another crate, even though the option descriptor was right.
    local ok, result = pcall(props.findOnSquare, props, entry.square, props.spriteName)
    return ok and result == object
end

local function exactEntries(s, logic, fetch, menu, p, objects, x, y, test)
    if active ~= s or menu ~= s.menu or p ~= s.player or objects ~= s.objects then
        return logic.createMenuEntries(fetch, menu, p, objects, x, y, test)
    end
    local before = {}
    visit(menu, function(option) before[option] = true end, {})
    local ok, result = pcall(logic.createMenuEntries, fetch, menu, p, objects, x, y, test)
    if not ok then error(result, 0) end
    if s.superseded then return result end
    -- Java caches stock Lua functions by name, so temporarily replacing the
    -- providers does not work once they have been called. Instead inspect
    -- their *fresh, bound* options while still inside native generation.
    -- Mods' ordinary fill subscribers haven't run, and every unrelated
    -- callback (including a same-named third-party one) is left intact.
    visit(menu, function(option, emptied)
        if before[option] then return false end
        local fn = option.onSelect
        if not fn then return emptied end
        local radio, scrap = ISRadioAndTvMenu, ISDisassembleMenu
        if radio and (fn == radio.openTvPanel or fn == radio.openRadioPanel) then
            return option.param1 ~= s.owner
        end
        if scrap and fn == scrap.disassemble then
            local entry = option.param1
            if not entry or entry.object ~= s.owner then return true end
            if not scrapResolves(s.owner, entry) then
                option.notAvailable = true
                if option.toolTip then
                    option.toolTip.description = (option.toolTip.description or "") ..
                        " <LINE> LootBox: the game's sprite lookup does not resolve this exact fixture."
                end
            else
                local owner = s.owner
                option.onSelect = function(actor, data, ...)
                    if scrapResolves(owner, data) then return fn(actor, data, ...) end
                end
            end
        end
    end, {})
    return result
end

local function inWorldMenu(s, menu)
    while menu and menu ~= s.root do
        if menu == s.menu then return true end
        menu = menu.parent
    end
    return false
end

local function releaseWorldMenu(s)
    if not s.menu then return end
    -- getNew registers every descendant with the player's root. Hide only
    -- this subtree; leave forceVisible on for native cascading submenus.
    for _, menu in pairs(s.root.instanceMap) do
        if inWorldMenu(s, menu) then menu:setVisible(false) end
    end
    for _, menu in ipairs(s.retired) do
        menu:setVisible(false)
        table.insert(s.root.subMenuPool, menu)
    end
end

local function binding(s, menu, option)
    local function exact(value)
        return rawequal(value, s.container) or rawequal(value, s.owner)
    end
    local budget, seen = 160, {}
    local function conflict(value, depth)
        local kind = type(value)
        if kind ~= "table" and kind ~= "userdata" then return false end
        if exact(value) or rawequal(value, s.actor) or rawequal(value, s.square)
            or rawequal(value, menu) or rawequal(value, s.menu) or rawequal(value, s.root) then return false end
        if kind == "table" and getmetatable(value) ~= nil then return true end
        if instanceof(value, "IsoObject") or instanceof(value, "ItemContainer") or instanceof(value, "IsoGridSquare") then return true end
        if instanceof(value, "InventoryItem") or seen[value] then return false end
        seen[value] = true
        -- Collections can veto on a competing object, not prove an action
        -- belongs here. In particular {owner} is the ambient world hit list.
        if kind == "table" or instanceof(value, "ArrayList") then
            if depth > 4 or budget <= 0 then return true end
            if instanceof(value, "ArrayList") then
                local size = value:size()
                if size > budget then return true end
                budget = budget - size
                for index = 0, size - 1 do if conflict(value:get(index), depth + 1) then return true end end
            else
                for key, member in pairs(value) do
                    budget = budget - 1
                    if budget < 0 or conflict(key, depth + 1) or conflict(member, depth + 1) then return true end
                end
            end
        end
        return false
    end
    local bound, target = false, option.target
    if conflict(target, 0) then return end
    bound = exact(target)
    for index = 1, 10 do
        local value = option["param" .. index]
        if conflict(value, 0) then return end
        bound = bound or exact(value)
    end
    if conflict(option.onHighlightParams, 0) then return end
    return bound
end

local function promotion(s)
    local links = {}
    local function countLinks(menu)
        for _, option in ipairs(menu.options) do
            local id = option.subOption
            if id then links[id] = (links[id] or 0) + 1 end
        end
    end
    countLinks(s.root)
    for _, menu in pairs(s.root.instanceMap) do countLinks(menu) end
    local left = 512
    local function branch(menu, option, depth)
        left = left - 1
        if left < 0 or depth > 12 then return end
        local bound = binding(s, menu, option)
        local action = option.onSelect ~= nil
        if bound == nil or ((action or option.onHighlight ~= nil) and not bound) then return end
        local id = option.subOption
        if id then
            local child = s.root.instanceMap[id]
            -- Only move a native subtree with an unambiguous parent and no
            -- previously built back-navigation options.
            if links[id] ~= 1 or not child or child.parent ~= menu or child.addedDefaultOptions then return end
            for _, entry in ipairs(child.options) do
                local exact = branch(child, entry, depth + 1)
                if exact == nil then return end
                action = action or exact
            end
        end
        -- Inert text (e.g. a disabled stock Fill with no bottle) is neutral.
        return action
    end
    local exact = {}
    for index, option in ipairs(s.menu.options) do exact[index] = branch(s.menu, option, 0) == true end
    return exact
end

local function promote(s, exact)
    local root, world = s.root, s.menu
    if not root.calcHeight or not root.calcWidth or not world.calcHeight or not world.calcWidth then return end
    local from, into = world.options, root.options
    local kept, originalCount = 0, #into
    local count = #from
    for index = 1, count do
        local option = from[index]
        if exact[index] then
            option.id = #into + 1
            into[option.id] = option
            -- Native submenu IDs are owned by the root instanceMap. Reparent
            -- the attached subtree only; keep every option and ID in it.
            if option.subOption then root.instanceMap[option.subOption].parent = root end
        else
            kept = kept + 1
            option.id = kept
            from[kept] = option
        end
    end
    if #into == originalCount then return end
    for index = kept + 1, count do from[index] = nil end
    world.numOptions, root.numOptions = kept + 1, #into + 1
    world:calcHeight()
    world:setWidth(world:calcWidth())
    root:calcHeight()
    root:setWidth(root:calcWidth())
end

local function build(s, replace)
    local world, logic, wm = ISWorldObjectContextMenu, ISWorldObjectContextMenuLogic, s.manager.getWorldMenu()
    -- A screen picker has *no* target during this synthetic fixture gesture.
    -- Some ordinary event subscribers ignore x/y and read world-scaled mouse
    -- coordinates directly (e.g. vehicle-first providers). The popup still
    -- uses real, unscaled UI coordinates. Also leave nested unrelated world
    -- menu builds their normal cursor. All hooks unwind in append's finally.
    local exactPointer = true
    for _, key in ipairs({ "getMouseXScaled", "getMouseYScaled" }) do
        local original = _G[key]
        if original then
            replace(_G, key, function(...)
                if active == s and exactPointer then return NO_PICK end
                return original(...)
            end)
        end
    end
    local function gate(t, matches)
        local original = t.createMenu
        if not original then return end
        replace(t, "createMenu", function(...)
            local before = exactPointer
            exactPointer = before and matches(...)
            local ok, result = pcall(original, ...)
            exactPointer = before
            if not ok then error(result, 0) end
            return result
        end)
    end
    gate(wm, function(p, owner, objects, x, y)
        return p == s.player and owner == s.owner and objects == s.objects and x == NO_PICK and y == NO_PICK
    end)
    gate(world, function(p, objects, x, y)
        return p == s.player and objects == s.objects and x == NO_PICK and y == NO_PICK
    end)
    local get = ISContextMenu.get
    -- Keep the original pane popup and use a genuine native submenu as the
    -- world context. Providers can add their own nested native menus unchanged.
    replace(ISContextMenu, "get", function(player, x, y)
        if active == s and player == s.player then
            if exactPointer and x == NO_PICK and y == NO_PICK then
                if not s.menu then s.menu = ISContextMenu:getNew(s.root) end
                return s.menu
            end
            -- A real nested menu for this player owns the root from here on.
            -- Native get recycles its submenus; hold just our old subtree out
            -- of the pool until callbacks still referencing it finish.
            s.superseded = true
            local context = get(player, x, y)
            local pool = s.root.subMenuPool
            for i = #pool, 1, -1 do
                if inWorldMenu(s, pool[i]) then
                    s.retired[#s.retired + 1] = table.remove(pool, i)
                end
            end
            return context
        end
        return get(player, x, y)
    end)

    -- 42.22's Java fetch(...,true) walks the whole tile and overwrites e.g.
    -- fetch.item and padlockThump. Its single-object mode omits square-level
    -- permissions too, so supply the actual stock decisions for this square.
    replace(_G, "ISWorldObjectContextMenuLogic", setmetatable({
        createMenuEntries = function(...) return exactEntries(s, logic, ...) end,
        fetch = function(fetch, obj, player, scanSquare)
            if active ~= s or not exactPointer or obj ~= s.owner or player ~= s.player or not scanSquare then
                return logic.fetch(fetch, obj, player, scanSquare)
            end
            logic.fetch(fetch, obj, player, false)
            fetch.building = s.square:getBuilding()
            fetch.safehouse = SafeHouse.getSafeHouse(s.square)
            fetch.safehouseAllowInteract = SafeHouse.isSafehouseAllowInteract(s.square, s.actor)
            fetch.safehouseAllowLoot = SafeHouse.isSafehouseAllowLoot(s.square, s.actor)
            world.fetchSquares[s.square] = true
        end,
    }, { __index = logic }))

    -- This stock fill subscriber ignores worldobjects and picks a vehicle at
    -- the live mouse (or near a controller player). This scope is a *fixture*.
    if ISVehicleMenu and ISVehicleMenu.FillMenuOutsideVehicle then
        local fill = ISVehicleMenu.FillMenuOutsideVehicle
        replace(ISVehicleMenu, "FillMenuOutsideVehicle", function(player, menu, ...)
            if active == s and player == s.player and menu == s.menu then return end
            return fill(player, menu, ...)
        end)
    end

    -- The second half of the stock manager feeds its registered world menu
    -- elements. getAllObjects already inserts the supplied object(s); stop its
    -- extra enumeration of the object's tile and the tile under the cursor.
    local expand = wm.getObjectsSquare
    replace(wm, "getObjectsSquare", function(data, square)
        if active == s and data.context == s.menu and data.object == s.owner and data.playerNum == s.player then
            if square == s.square and #data.squares == 0 then data.squares[1] = square end
            return
        end
        return expand(data, square)
    end)
    -- This owns pre-fill, native entries, fill, and registered context
    -- elements, in their normal order. No separate event replay or menu copy.
    return s.manager.createWorldMenu(s.player, s.owner, s.objects, NO_PICK, NO_PICK)
end

function Bridge.append(player, menu, container)
    if active or not menu or not ISContextManager or not ISContextManager.getInstance
        or not ISContextMenu or not ISContextMenu.get or not ISContextMenu.getNew or not menu.addSubMenu
        or not menu.instanceMap or not menu.subMenuPool or not ISWorldObjectContextMenuLogic
        or not ISWorldObjectContextMenuLogic.fetch or not ISWorldObjectContextMenuLogic.createMenuEntries
        or not ISWorldObjectContextMenu or ISWorldObjectContextMenu.disableWorldMenu or not SafeHouse then return end
    local owner, square = fixture(container)
    if not owner then return end
    local actor, manager = getSpecificPlayer(player), ISContextManager.getInstance()
    if not actor or actor:isDead() or actor:isAsleep() or not manager or not manager.createWorldMenu
        or not manager.getWorldMenu or not manager.getWorldMenu() or not manager.getWorldMenu().getObjectsSquare then return end
    -- In controller targeting mode native itself enumerates nearby items and
    -- actors independent of x/y. Leave that player's existing pane menu alone.
    if JoypadState and JoypadState.players[player + 1] then return end
    if ISWorldMap_instance and ISWorldMap_instance:isVisible() then return end
    local trade = ISTradingUI and ISTradingUI.GetUIForPlayer(actor)
    if trade and trade:isVisible() then return end
    if not SafeHouse.isSafehouseAllowInteract(square, actor) or not SafeHouse.isSafehouseAllowLoot(square, actor) then return end

    local scope = { player = player, root = menu, container = container, owner = owner, square = square,
        objects = { owner }, actor = actor, manager = manager, retired = {} }
    local undo = {}
    local function replace(t, k, value)
        undo[#undo + 1] = { t = t, k = k, before = t[k], installed = value }
        t[k] = value
    end
    active = scope
    local ok, result = pcall(build, scope, replace)
    active = nil
    for i = #undo, 1, -1 do
        local e = undo[i]
        if e.t[e.k] == e.installed then e.t[e.k] = e.before end
    end
    releaseWorldMenu(scope)
    if scope.superseded then return nil, true end
    if not ok then print("[LootBox] Exact container world menu: " .. tostring(result)); return end
    if not scope.menu or result ~= scope.menu then return end
    local liveOwner, liveSquare = fixture(container)
    if liveOwner ~= owner or liveSquare ~= square then return end
    -- A provider can give an unusual opaque argument. If inspection fails,
    -- retain its complete original menu instead of jeopardizing the popup.
    local classified, exact = pcall(promotion, scope)
    if classified then promote(scope, exact) end
    if scope.menu.numOptions > 1 then
        local option = menu:addOption("World Actions")
        option.iconTexture = getTexture("media/ui/LootableMaps/map_house.png")
        menu:addSubMenu(option, scope.menu)
    end
    return scope.objects
end

return Bridge
