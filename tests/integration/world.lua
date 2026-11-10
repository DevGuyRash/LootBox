if type(package) == "table" and type(package.path) == "string" then
    package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
end

local World = require "LootBox/World"
local Categories = require "LootBox/Categories"
local saved = {getCell = getCell, instanceof = instanceof, isClient = isClient,
    ISInventoryPaneContextMenu = ISInventoryPaneContextMenu, getTextOrNull = getTextOrNull, getVehicleById = getVehicleById}
local failures, passed = {}, 0

local function list(values)
    return {size = function() return #values end, get = function(_, index) return values[index + 1] end}
end

local function equal(actual, expected, message)
    assert(actual == expected, (message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture()
    local squares, vehicles, ids = {}, {}, 0
    local function square(x, y)
        local value = {x = x, y = y, objects = {}, moving = {}, corpses = {}, ground = {}}
        function value:getX() return self.x end
        function value:getY() return self.y end
        function value:getZ() return 0 end
        function value:getObjects() return list(self.objects) end
        function value:getMovingObjects() return list(self.moving) end
        function value:getStaticMovingObjects() return list(self.corpses) end
        function value:getWorldObjects() return list(self.ground) end
        function value:isSeen() return true end
        function value:canReachTo(other) return math.abs(self.x - other.x) <= 1 and math.abs(self.y - other.y) <= 1 end
        squares[x .. ":" .. y .. ":0"] = value
        return value
    end
    local origin, far = square(0, 0), square(50, 50)
    local function container(kind, parent)
        local value = {kind = kind, parent = parent, items = {}}
        function value:getType() return self.kind end
        function value:getParent() return self.parent end
        function value:getSourceGrid() return self.parent and self.parent.square end
        function value:getItems() return list(self.items) end
        function value:isExplored() return true end
        function value:isLockedToCharacter() return false end
        function value:getOutermostContainer() return self end
        function value:contains(item)
            for _, entry in ipairs(self.items) do if entry == item then return true end end
            return false
        end
        return value
    end
    local inventory = container("inventory")
    local player = {}
    function player:getInventory() return inventory end
    function player:getPlayerNum() return 0 end
    function player:getCurrentSquare() return origin end
    function player:getSquare() return origin end
    function player:getX() return 0.5 end
    function player:getY() return 0.5 end
    function player:getZ() return 0 end
    local function item(source, name, category)
        ids = ids + 1
        local value = {id = ids, source = source, name = name, category = category or "Food"}
        function value:getID() return self.id end
        function value:getContainer() return self.source end
        function value:getName() return self.name end
        function value:getFullType() return "Fixture." .. self.name end
        function value:getDisplayCategory() return self.category end
        function value:getCategory() return self.category end
        if source then source.items[#source.items + 1] = value end
        return value
    end
    local function crate(where, name)
        local object = {square = where, sprite = name}
        local storage = container("crate", object)
        object.storage = storage
        function object:getSquare() return self.square end
        function object:getSpriteName() return self.sprite end
        function object:getContainerCount() return 1 end
        function object:getContainerByIndex(index) if index == 0 then return self.storage end end
        function object:getContainerIndex(value) return value == self.storage and 0 or -1 end
        function object:getObjectIndex()
            for index, value in ipairs(self.square.objects) do if value == self then return index - 1 end end
            return -1
        end
        where.objects[#where.objects + 1] = object
        return storage
    end
    local junk, unlabeled, tools, remote = crate(origin, "junk"), crate(origin, "unlabeled"), crate(origin, "tools"), crate(far, "remote")
    item(junk, "Beans")
    item(junk, "Scrap", "Material")
    item(unlabeled, "Cake")
    item(tools, "Soup")
    item(remote, "Apple")
    item(inventory, "CarriedFood")
    origin.ground[1] = {}
    getCell = function()
        return {getGridSquare = function(_, x, y, z) return squares[x .. ":" .. y .. ":" .. z] end,
            getVehicles = function()
                return {iterator = function()
                    local index = 0
                    return {hasNext = function() return index < #vehicles end,
                        next = function() index = index + 1; return vehicles[index] end}
                end}
            end}
    end
    instanceof = function() return false end
    isClient = function() return false end
    getTextOrNull = function() return nil end
    getVehicleById = function(id)
        for _, vehicle in ipairs(vehicles) do if vehicle:getId() == id then return vehicle end end
    end
    ISInventoryPaneContextMenu = {getContainers = function() return list({inventory, junk, unlabeled, tools}) end}
    local state = {containerLabels = {}, itemLabels = {}, keep = {}, trash = {}}
    local world = World.new(player, state)
    state.containerLabels[assert(world:key(junk))] = {"native:Junk", "native:Material"}
    state.containerLabels[assert(world:key(tools))] = {"native:Tool"}
    state.containerLabels[assert(world:key(remote))] = {"native:Junk"}
    local graph = assert(Categories.new({}))
    local function names(scan, filter)
        local selected = {}
        for _, record in ipairs(scan.items) do
            if not filter or graph:matchesFilter(filter, record.descriptor) then selected[#selected + 1] = record.itemName end
        end
        table.sort(selected)
        return table.concat(selected, ",")
    end
    return {world = world, state = state, player = player, squares = squares, origin = origin, far = far,
        junk = junk, tools = tools, unlabeled = unlabeled, remote = remote, inventory = inventory,
        container = container, item = item, names = names, vehicles = vehicles}
end

local function case(name, run)
    local ok, err = pcall(function() run(fixture()) end)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failures[#failures + 1] = name .. ": " .. tostring(err); print("FAIL " .. failures[#failures]) end
end

print("World integration uses native source-boundary doubles; it does not prove native access, movement, or multiplayer synchronization")

case("Junk source labels select only matching loaded containers across rooms", function(f)
    local reconnected = World.new(f.player, f.state)
    local scan = assert(reconnected:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans")
    equal(#scan.groundSquares, 0)
    equal(#scan.sources, 2)
end)

case("Multiple source labels form a union while container labels can overlap", function(f)
    local scan = assert(f.world:scan({scope = "labeled", sourceLabels = {"native:Junk", "native:Tool"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans,Soup")
    equal(#scan.sources, 3)
end)

case("Any labeled source excludes unlabeled containers", function(f)
    local scan = assert(f.world:scan({scope = "labeled", sourceLabels = {}}))
    equal(f.names(scan), "Apple,Beans,Scrap,Soup")
end)

local function car(f, keyId, id, script, square)
    local vehicle, part = {id = id or 72, keyId = keyId or 78341922, script = script or "Fixture.Car",
        square = square or f.far, mechanicalId = 41863}, {}
    local storage = f.container("TruckBed", vehicle)
    function storage:getVehiclePart() return part end
    function vehicle:getId() return self.id end
    function vehicle:getKeyId() return self.keyId end
    function vehicle:getMechanicalID() return self.mechanicalId end
    function vehicle:getSquare() return self.square end
    function vehicle:isRemovedFromWorld() return self.removed == true end
    function vehicle:getScriptName() return self.script end
    function vehicle:getPartCount() return 1 end
    function vehicle:getPartByIndex(index) if index == 0 then return part end end
    function part:getVehicle() return vehicle end
    function part:getIndex() return 0 end
    function part:getId() return "TruckBed" end
    function part:getItemContainer() return storage end
    f.vehicles[#f.vehicles + 1] = vehicle
    return vehicle, storage
end

case("Saved vehicle labels survive native network and mechanical ID changes", function(f)
    local vehicle, storage = car(f)
    f.item(storage, "VehicleFood")
    f.state.containerLabels["vehicle:78341922:Fixture.Car:TruckBed"] = {"native:Junk"}
    local world = World.new(f.player, f.state)
    local scan = assert(world:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans,VehicleFood")
    vehicle.id, vehicle.mechanicalId = 73, 41864
    scan = assert(World.new(f.player, f.state):scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans,VehicleFood")
    vehicle.keyId = 78341923
    scan = assert(world:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans")
    scan = assert(World.new(f.player, f.state):scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans")
end)

case("A recreated native vehicle retains labels on the same loaded square", function(f)
    local previous, storage = car(f)
    f.item(storage, "OldFood")
    f.state.containerLabels["vehicle:78341922:Fixture.Car:TruckBed"] = {"native:Junk"}
    assert(f.world:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    previous.removed = true
    local _, replacement = car(f, 78341922, 73)
    f.item(replacement, "NewFood")
    local scan = assert(f.world:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans,NewFood")
    assert(f.state.containerLabels["vehicle:78341922:Fixture.Car:TruckBed"])
end)

case("A remembered vehicle survives client recreation of the mechanical ID", function(f)
    local vehicle = car(f)
    assert(f.world:rememberVehicle(vehicle))
    vehicle.mechanicalId = 999
    equal(World.new(f.player, f.state):vehicle(), vehicle)
end)

case("A recycled native ID with the same model cannot adopt a different keyed car", function(f)
    local vehicle = car(f)
    assert(f.world:rememberVehicle(vehicle))
    vehicle.keyId = 78341923
    equal(World.new(f.player, f.state):vehicle(), nil)
end)

case("A changed native network ID resolves the unique loaded keyed car and updates its hint", function(f)
    local vehicle = car(f)
    assert(f.world:rememberVehicle(vehicle))
    vehicle.id = 73
    car(f, 78341923, 72)
    local reconnected = World.new(f.player, f.state)
    equal(reconnected:vehicle(), vehicle)
    equal(f.state.vehicle.id, 73)
    assert(reconnected:observeNearby(), "The changed native hint must notify local persistence")
end)

case("A different vehicle model cannot use a remembered key association", function(f)
    local vehicle = car(f)
    assert(f.world:rememberVehicle(vehicle))
    vehicle.script = "Fixture.OtherCar"
    equal(World.new(f.player, f.state):vehicle(), nil)
end)

case("Ambiguous loaded key associations block remembered hauling and labels", function(f)
    local vehicle, storage = car(f)
    f.item(storage, "VehicleFood")
    assert(f.world:rememberVehicle(vehicle))
    f.state.containerLabels["vehicle:78341922:Fixture.Car:TruckBed"] = {"native:Junk"}
    local _, otherStorage = car(f, 78341922, 73)
    f.item(otherStorage, "OtherVehicleFood")
    local reconnected = World.new(f.player, f.state)
    local resolved, reason = reconnected:vehicle()
    equal(resolved, nil)
    assert(reason:find("Multiple loaded vehicles", 1, true))
    local destinations, err = reconnected:destinations({destination = {kind = "vehicle"}}, nil)
    equal(destinations, nil)
    equal(err, reason)
    assert(not reconnected:rememberVehicle(vehicle))
    assert(not reconnected:key(storage))
    local scan = assert(reconnected:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan, {ids = {"native:Food"}}), "Apple,Beans")
end)

case("An absent negative or malformed native key association cannot be remembered", function(f)
    local vehicle = car(f)
    for _, invalid in ipairs({-1, 1.5}) do
        vehicle.keyId = invalid
        assert(not f.world:rememberVehicle(vehicle))
    end
    vehicle.keyId = nil
    assert(not f.world:rememberVehicle(vehicle))
    f.state.vehicle = {id = 72, script = "Fixture.Car", x = 50, y = 50, z = 0}
    local resolved, reason = World.new(f.player, f.state):vehicle()
    equal(resolved, nil)
    assert(type(reason) == "string" and #reason > 0)
    vehicle.keyId = 0
    assert(f.world:rememberVehicle(vehicle), "Zero is a valid native random key association")
end)

case("Stationary vehicles are discovered through the native loaded Set", function(f)
    local vehicle = car(f, 123, 74, "Fixture.OtherCar", f.origin)
    equal(#f.origin.moving, 0)
    local known = f.world:knownVehicles()
    equal(#known, 1)
    equal(known[1], vehicle)
end)

case("Unloaded matching keyed cars do not substitute for loaded observations", function(f)
    local vehicle = car(f)
    assert(f.world:rememberVehicle(vehicle))
    f.squares["50:50:0"] = nil
    equal(World.new(f.player, f.state):vehicle(), nil)
    equal(f.state.vehicle.keyId, 78341922)
end)

case("Inventory is independently optional beside labeled sources", function(f)
    local request = {scope = "labeled", sourceLabels = {"native:Junk"}, includeInventory = true}
    equal(f.names(assert(f.world:scan(request)), {ids = {"native:Food"}}), "Apple,Beans,CarriedFood")
    request.includeInventory = false
    equal(f.names(assert(f.world:scan(request)), {ids = {"native:Food"}}), "Apple,Beans")
end)

case("An area source-label filter excludes unlabeled storage and ground loot", function(f)
    local request = {scope = "area", area = {x1 = 0, x2 = 0, y1 = 0, y2 = 0, z = 0}, sourceLabels = {"native:Junk"}}
    local scan = assert(f.world:scan(request))
    equal(f.names(scan), "Beans,Scrap")
    equal(#scan.groundSquares, 0)
    request.includeInventory = true
    equal(f.names(assert(f.world:scan(request))), "Beans,CarriedFood,Scrap")
end)

case("Empty extra source-label selection preserves an ordinary area scope", function(f)
    local scan = assert(f.world:scan({scope = "area", area = {x1 = 0, x2 = 0, y1 = 0, y2 = 0, z = 0}, sourceLabels = {}}))
    equal(f.names(scan), "Beans,Cake,Scrap,Soup")
    equal(#scan.groundSquares, 1)
end)

case("Reach source labels do not expand the native accessible-container set", function(f)
    local scan = assert(f.world:scan({scope = "reach", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan), "Beans,Scrap")
    equal(#scan.groundSquares, 0)
end)

case("Unloaded labeled sources remain remembered and are reported unavailable", function(f)
    local key = assert(f.world:key(f.remote))
    f.squares["50:50:0"] = nil
    local scan = assert(World.new(f.player, f.state):scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(f.names(scan), "Beans,Scrap")
    assert(f.state.containerLabels[key], "An unloaded source must retain its saved labels")
    assert(#scan.warnings > 0, "Unavailable labeled sources must remain visible in the preview")
end)

case("A source label restriction requires a dense list", function(f)
    for _, invalid in ipairs({"native:Junk", {[2] = "native:Junk"}, {true}}) do
        local scan, err = f.world:scan({scope = "labeled", sourceLabels = invalid})
        equal(scan, nil)
        assert(type(err) == "string" and #err > 0)
    end
end)

case("A floor bag resolves its live world-item square", function(f)
    local bag = f.item(nil, "FloorBag", "Container")
    local storage = f.container("bag")
    function storage:getContainingItem() return bag end
    local worldItem = {getSquare = function() return f.far end}
    function bag:getWorldItem() return worldItem end
    equal(f.world:square(storage), f.far)
end)

case("A nested bag resolves its enclosing container anchor without moving equipment", function(f)
    local outer = f.item(f.junk, "OuterBag", "Container")
    local outerStorage = f.container("bag")
    function outerStorage:getContainingItem() return outer end
    local inner = f.item(outerStorage, "InnerBag", "Container")
    local innerStorage = f.container("bag")
    function innerStorage:getContainingItem() return inner end
    equal(f.world:square(innerStorage), f.origin)
end)

case("A malformed cyclic bag anchor terminates without a location", function(f)
    local bag = f.item(nil, "CyclicBag", "Container")
    local storage = f.container("bag")
    function storage:getContainingItem() return bag end
    bag.source = storage
    equal(f.world:square(storage), nil)
end)

case("This building excludes exterior squares returned by the native bounding-box query", function(f)
    local definition = { getSquares = function() return list({ f.origin, f.far }) end }
    local building = { getDef = function() return definition end }
    function f.origin:getBuilding() return building end
    function f.far:getBuilding() return nil end
    local scan = assert(f.world:scan({ scope = "building" }))
    equal(f.names(scan), "Beans,Cake,Scrap,Soup")
    equal(#scan.sources, 3)
end)

case("Direct selected-container preview observes current safehouse permission", function(f)
    local previous = SafeHouse
    local checks = 0
    isClient = function() return true end
    SafeHouse = { isSafehouseAllowLoot = function() checks = checks + 1; return false end }
    local scan = assert(f.world:scan({ scope = "container", sourceContainer = f.junk }))
    SafeHouse = previous
    equal(#scan.items, 0)
    equal(#scan.sources, 0)
    assert(checks > 0)
    assert(#scan.warnings > 0)
end)

getCell, instanceof, isClient = saved.getCell, saved.instanceof, saved.isClient
ISInventoryPaneContextMenu, getTextOrNull = saved.ISInventoryPaneContextMenu, saved.getTextOrNull
getVehicleById = saved.getVehicleById
assert(#failures == 0, table.concat(failures, "\n"))
print("PASS world source-boundary integration cases: " .. passed)
