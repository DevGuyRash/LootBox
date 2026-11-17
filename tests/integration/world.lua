if type(package) == "table" and type(package.path) == "string" then
    package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
end

local World = require "LootBox/World"
local Categories = require "LootBox/Categories"
local saved = {getCell = getCell, instanceof = instanceof, isClient = isClient,
    ISInventoryPaneContextMenu = ISInventoryPaneContextMenu, getTextOrNull = getTextOrNull, getVehicleById = getVehicleById}
local failures, passed = {}, 0

local function list(values)
    return {size = function() return #values end, get = function(_, index) return values[index + 1] end,
        isEmpty = function() return #values == 0 end}
end

local function equal(actual, expected, message)
    assert(actual == expected, (message or "Values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fixture()
    local squares, vehicles, ids = {}, {}, 0
    local lookups = {}
    local function square(x, y, z)
        local value = {x = x, y = y, z = z or 0, objects = {}, moving = {}, corpses = {}, ground = {}, seen = true, free = true}
        function value:getX() return self.x end
        function value:getY() return self.y end
        function value:getZ() return self.z end
        function value:getObjects() return list(self.objects) end
        function value:getMovingObjects() return list(self.moving) end
        function value:getStaticMovingObjects() return list(self.corpses) end
        function value:getWorldObjects() return list(self.ground) end
        function value:isSeen() return self.seen end
        function value:getRoom() return self.room end
        function value:getBuilding() return self.building end
        function value:getFloor() if not self.noFloor then return {} end end
        function value:isFree() return self.free end
        function value:canReachTo(other) return self.z == other.z and math.abs(self.x - other.x) <= 1 and math.abs(self.y - other.y) <= 1 end
        squares[x .. ":" .. y .. ":" .. value.z] = value
        return value
    end
    local origin, far = square(0, 0), square(50, 50)
    local function container(kind, parent)
        local value = {kind = kind, parent = parent, items = {}, capacity = 10}
        function value:getType() return self.kind end
        function value:getParent() return self.parent end
        function value:getSourceGrid() return self.parent and self.parent.square end
        function value:getItems() return list(self.items) end
        function value:getItemWithID(id)
            for _, item in ipairs(self.items) do if item:getID() == id then return item end end
        end
        function value:getContainingItem() return self.bag end
        function value:getEffectiveCapacity() return self.capacity end
        function value:getCapacityWeight() return #self.items end
        function value:isExplored() return true end
        function value:isLockedToCharacter() return false end
        function value:getOutermostContainer()
            local seen, current = {}, self
            while current.bag and current.bag:getContainer() and not seen[current] do
                seen[current] = true
                current = current.bag:getContainer()
            end
            return current
        end
        function value:contains(item)
            for _, entry in ipairs(self.items) do if entry == item then return true end end
            return false
        end
        return value
    end
    local inventory = container("inventory")
    local player = {location = origin}
    function player:getInventory() return inventory end
    function player:getPlayerNum() return 0 end
    function player:getCurrentSquare() return self.location end
    function player:getSquare() return self.location end
    function player:getX() return self.location.x + 0.5 end
    function player:getY() return self.location.y + 0.5 end
    function player:getZ() return self.location.z end
    local function item(source, name, category)
        ids = ids + 1
        local value = {id = ids, source = source, name = name, category = category or "Food"}
        function value:getID() return self.id end
        function value:getContainer() return self.source end
        function value:getName() return self.name end
        function value:getFullType() return "Fixture." .. self.name end
        function value:getDisplayCategory() return self.category end
        function value:getCategory() return self.category end
        function value:getInventory() return self.inventory end
        function value:getWorldItem() return self.world end
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
        function object:getContainer() return self.storage end
        function object:getSprite()
            return {getProperties = function() return {has = function(_, key) return self.trash and key == "IsTrashCan" end} end}
        end
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
        return {getGridSquare = function(_, x, y, z)
                lookups[#lookups + 1] = {x = x, y = y, z = z}
                return squares[x .. ":" .. y .. ":" .. z]
            end,
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
        container = container, item = item, names = names, vehicles = vehicles, square = square, crate = crate, lookups = lookups}
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
    function vehicle:getPartById(id) if id == "TruckBed" then return part end end
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
    equal(f.world:sourceAnchor(storage), nil)
end)

local function building()
    local rooms = {}
    local definition = {getIDString = function() return "fixture-building" end,
        getRooms = function() return list(rooms) end,
        getMinLevel = function() return 0 end, getMaxLevel = function() return 31 end,
        getSquares = function() error("Building scope must not request a full native tile list") end}
    local native = {getDef = function() return definition end}
    local function room(id, z, x, y, width, height)
        local rectangle = {getX = function() return x end, getY = function() return y end,
            getX2 = function() return x + width end, getY2 = function() return y + height end}
        local value = {getIDString = function() return id end, getName = function() return id end,
            getZ = function() return z end, getBuilding = function() return definition end,
            getRects = function() return list({rectangle}) end,
            contains = function(_, px, py) return px >= x and px < x + width and py >= y and py < y + height end}
        rooms[#rooms + 1] = value
        local isoRoom = {getRoomDef = function() return value end}
        return value, function(square) square.room, square.building = isoRoom, native end
    end
    return definition, native, room
end

local function nextSection(survey)
    for _ = 1, 100 do
        local section = survey:next()
        if section ~= false then return section end
    end
    error("A small building survey did not yield a section")
end

case("Building preview captures metadata without scanning its full bounding box", function(f)
    local _, _, room = building()
    local _, attach = room("living room", 0, 0, 0, 2, 1)
    attach(f.origin)
    local before = #f.lookups
    local scan = assert(f.world:scan({scope = "building"}))
    equal(#scan.items, 0)
    equal(#scan.sources, 0)
    equal(#f.lookups, before)
    equal(scan.survey:status().roomsTotal, 1)
    local section = assert(nextSection(scan.survey))
    local outside = f.square(1, 0)
    f.item(f.crate(outside, "outside storage"), "OutsideFood")
    local partial, missing, denied = f.world:scanSection(section, {scope = "building"})
    equal(f.names(partial), "Beans,Cake,Scrap,Soup")
    equal(#partial.sources, 3)
    equal(missing, 1)
    equal(denied, 0)
end)

case("A building section includes native floor 31 and excludes another building", function(f)
    local _, _, room = building()
    local upper, attach = room("upper room", 31, -4, -3, 2, 1)
    local selected, neighbor = f.square(-4, -3, 31), f.square(-3, -3, 31)
    attach(selected)
    f.player.location = selected
    local storage = f.crate(selected, "upper storage")
    f.item(storage, "UpperFood")
    local _, _, otherRoom = building()
    local _, attachOther = otherRoom("other house", 31, -3, -3, 1, 1)
    attachOther(neighbor)
    f.item(f.crate(neighbor, "other house storage"), "OtherFood")
    local survey = assert(f.world:scan({scope = "building"})).survey
    local section = assert(nextSection(survey))
    equal(section.room, upper)
    equal(section.z, 31)
    local scan, missing = f.world:scanSection(section, {scope = "building"})
    equal(f.names(scan), "UpperFood")
    equal(missing, 1)
end)

case("Current-floor frontiers can lead toward stairs in an unloaded upper wing", function(f)
    for x = 3, 24, 3 do f.square(x, 0, 0) end
    local targets, direct = f.world:walkTargets({x = 200, y = 0, z = 1}, {})
    assert(targets and #targets > 0 and #targets <= 16)
    equal(direct, false)
    for _, target in ipairs(targets) do
        equal(target.z, 0)
        assert(target.x > 0 and target.x <= 24)
        equal(target.y, 0)
    end
end)

case("A distant upper destination first uses a loaded intermediate floor", function(f)
    f.square(3, 0, 1)
    local targets, direct = f.world:walkTargets({x = 200, y = 0, z = 31}, {})
    assert(targets and #targets > 0)
    equal(direct, false)
    equal(targets[1].z, 1)
end)

case("Known outside trash on another floor is discovered without changing the source floor", function(f)
    local _, _, room = building()
    local _, attach = room("upstairs", 1, 0, 0, 1, 1)
    local upstairs = f.square(0, 0, 1)
    attach(upstairs)
    f.player.location = upstairs
    local ground = f.square(3, 0, 0)
    local bin = f.crate(ground, "outside-bin")
    bin.parent.trash = true
    local bins = f.world:trashCandidates()
    equal(#bins, 1)
    equal(bins[1], bin)
    equal(f.player:getCurrentSquare(), upstairs)
    equal(f.world:trashTarget(bin).point.z, 0)
end)

case("Unseen outside trash is found from upstairs without enumerating its contents", function(f)
    local _, _, room = building()
    local _, attach = room("upstairs", 1, 0, 0, 1, 1)
    local upstairs = f.square(0, 0, 1)
    attach(upstairs)
    f.player.location = upstairs
    local ground = f.square(4, 0, 0)
    ground.seen = false
    local bin = f.crate(ground, "unseen outside bin")
    bin.parent.trash = true
    local contents = f.item(bin, "Unseen bin contents")
    local reads = 0
    function bin:getItems() reads = reads + 1; error("Static discovery must not enumerate bin contents") end
    local bins = f.world:trashCandidates()
    equal(#bins, 1)
    equal(bins[1], bin)
    equal(reads, 0)
    equal(bin.items[1], contents)
    equal(f.player:getCurrentSquare(), upstairs)
    local target = assert(f.world:trashTarget(bin))
    equal(target.point.z, 0)
    equal(target.needsInspection, true)
    equal(target.approved, nil)
    equal(reads, 0)
end)

case("Unseen ordinary storage does not become an observed source during bin discovery", function(f)
    local hidden = f.square(5, 0, 0)
    hidden.seen = false
    local storage = f.crate(hidden, "hidden storage")
    f.item(storage, "Hidden supplies")
    local reads = 0
    function storage:getItems() reads = reads + 1; error("Bin discovery must not inspect ordinary storage") end
    f.state.containerLabels = {[assert(f.world:key(storage))] = {"native:Junk"}}
    equal(#f.world:trashCandidates(), 0)
    local scan = assert(f.world:scan({scope = "labeled", sourceLabels = {"native:Junk"}}))
    equal(#scan.sources, 0)
    equal(#scan.items, 0)
    equal(reads, 0)
    assert(#scan.warnings > 0)
end)

case("A nearby static trash destination may belong to another building", function(f)
    local _, _, room = building()
    local _, attach = room("source upstairs", 1, 0, 0, 1, 1)
    local upstairs = f.square(0, 0, 1)
    attach(upstairs)
    f.player.location = upstairs
    local _, _, otherRoom = building()
    local _, attachOther = otherRoom("neighbor ground room", 0, 4, 0, 1, 1)
    local neighbor = f.square(4, 0, 0)
    attachOther(neighbor)
    neighbor.seen = false
    local bin = f.crate(neighbor, "neighbor bin")
    bin.parent.trash = true
    local bins = f.world:trashCandidates()
    equal(#bins, 1)
    equal(bins[1], bin)
    equal(f.world:trashTarget(bin).needsInspection, true)
end)

case("Safehouse denial excludes unseen static trash destinations", function(f)
    local location = f.square(4, 0, 0)
    location.seen = false
    local bin = f.crate(location, "denied bin")
    bin.parent.trash = true
    local previous = SafeHouse
    isClient = function() return true end
    SafeHouse = {isSafehouseAllowLoot = function(square) return square ~= location end}
    local bins = f.world:trashCandidates()
    SafeHouse = previous
    equal(#bins, 0)
    local remembered = 0
    for _ in pairs(f.state.trash) do remembered = remembered + 1 end
    equal(remembered, 0)
end)

case("A remembered bin is unavailable during safehouse denial without losing its location", function(f)
    local location = f.square(4, 0, 0)
    location.seen = false
    local bin = f.crate(location, "remembered permission bin")
    bin.parent.trash = true
    equal(f.world:trashCandidates()[1], bin)
    local key = assert(f.world:key(bin))
    local previous, allowed = SafeHouse, false
    isClient = function() return true end
    SafeHouse = {isSafehouseAllowLoot = function(square) return square ~= location or allowed end}
    local denied = f.world:trashCandidates()
    local retained = f.state.trash[key] ~= nil
    allowed = true
    local restored = f.world:trashCandidates()
    SafeHouse = previous
    equal(#denied, 0)
    assert(retained, "Temporary permission changes must retain the remembered location")
    equal(#restored, 1)
    equal(restored[1], bin)
end)

case("Bin inspection requires the real floor adjacency and reachable access", function(f)
    local bin = f.crate(f.origin, "inspection bin")
    bin.parent.trash = true
    local target = assert(f.world:trashTarget(bin))
    f.player.location = f.square(0, 0, 1)
    equal(f.world:binReachable(target), false)
    assert(not f.world:markTrashInspected(target))
    equal(f.world:trashTarget(bin).needsInspection, true)
    f.player.location = f.square(2, 0, 0)
    equal(f.world:binReachable(target), false)
    assert(not f.world:markTrashInspected(target))
    local adjacent = f.square(1, 0, 0)
    f.player.location = adjacent
    local reachable = adjacent.canReachTo
    function adjacent:canReachTo() return false end
    equal(f.world:binReachable(target), false)
    assert(not f.world:markTrashInspected(target))
    equal(f.world:trashTarget(bin).needsInspection, true)
    adjacent.canReachTo = reachable
    equal(f.world:binReachable(target), true)
    equal(f.world:markTrashInspected(target), true)
    assert(not f.world:trashTarget(bin).needsInspection)
    equal(target.approved, nil)
end)

case("Inspection knowledge stays local to the session and unloaded bins need another inspection", function(f)
    local location = f.square(1, 0, 0)
    local bin = f.crate(location, "session bin")
    bin.parent.trash = true
    local target = assert(f.world:trashTarget(bin))
    equal(f.world:markTrashInspected(target), true)
    f.player.location = f.square(5, 0, 0)
    assert(not f.world:trashTarget(bin).needsInspection)
    local reconnected = World.new(f.player, f.state)
    equal(reconnected:trashTarget(bin).needsInspection, true)
    f.squares["1:0:0"] = nil
    local unloaded = f.world:unloadedTrashTargets()
    equal(#unloaded, 1)
    equal(unloaded[1].key, target.key)
    equal(unloaded[1].needsInspection, true)
    equal(unloaded[1].approved, nil)
end)

case("Source storage rebinds after unloading and rejects a changed fixture", function(f)
    local anchor = assert(f.world:sourceAnchor(f.remote))
    equal(f.world:resolveSource(anchor), f.remote)
    f.squares["50:50:0"] = nil
    local storage, reason = f.world:resolveSource(anchor)
    equal(storage, nil)
    equal(reason, "unloaded")
    local reloaded = f.square(50, 50)
    local replacement = f.crate(reloaded, "remote")
    equal(f.world:resolveSource(anchor), replacement)
    replacement.parent.sprite = "different fixture"
    equal(f.world:resolveSource(anchor), nil)
end)

case("A selected source cannot adopt a live replacement with identical metadata", function(f)
    local location = f.square(3, 0)
    local original = f.crate(location, "identical source")
    local anchor = assert(f.world:sourceAnchor(original))
    local replacement = f.crate(location, "identical source")
    table.remove(location.objects, 1)
    assert(f.world:valid(replacement))
    local resolved, reason = f.world:resolveSource(anchor)
    equal(resolved, nil)
    assert(reason and reason:find("replaced", 1, true))
end)

local function bag(f, source, name, id)
    local value = f.item(source, name, "Container")
    if id then value.id = id end
    local storage = f.container("bag")
    value.inventory, storage.bag = storage, value
    return value, storage
end

local function weightedBag(f, source, name, reduction)
    local value, storage = bag(f, source, name)
    value.reduction, value.rawWeight, value.attachedSlot = reduction, 2, -1
    function value:getWeightReduction() return self.reduction end
    function value:getUnequippedWeight() return self.rawWeight end
    function value:getHotbarEquippedWeight() return self.hotbarWeight end
    function value:getAttachedSlot() return self.attachedSlot end
    function value:isFakeEquipped() return self.fakeEquipped == true end
    function f.player:isEquipped(item) return item.equipped == true end
    return value, storage
end

local function weightedItem(f, source, weight)
    local value = f.item(source, "Weighted supply")
    function value:getUnequippedWeight() return weight end
    return value
end

local function near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001, "Expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

case("Character carrying uses native weighted mass and the live hard capacity instead of comfort", function(f)
    function f.player:getInventoryWeight() error("HUD weight is not native admission") end
    function f.player:getMaxWeight() error("Comfort is not native admission") end
    function f.inventory:getCapacityWeight() return 12.5 end
    function f.inventory:getMaxWeight() error("Comfort is not native admission") end
    f.inventory.capacity = 50
    local mass, maximum = f.world:carrying()
    equal(mass, 12.5)
    equal(maximum, 50)
    f.inventory.capacity = 75
    local changedMass, changedMaximum = f.world:carrying()
    equal(changedMass, 12.5)
    equal(changedMaximum, 75)
end)

case("Native unlimited carry has no finite budget even when its reported weight is zero", function(f)
    function f.player:isUnlimitedCarry() return true end
    function f.inventory:getCapacityWeight() return 0 end
    local mass, maximum = f.world:carrying()
    equal(mass, 0)
    equal(maximum, math.huge)
end)

case("Main inventory and an unequipped outer bag add the full incoming weight", function(f)
    local _, storage = weightedBag(f, f.inventory, "Unequipped bag", 90)
    local selected = weightedItem(f, f.remote, 8)
    equal(f.world:carryDelta(selected, f.inventory), 8)
    equal(f.world:carryDelta(selected, storage), 8)
end)

case("Only the equipped outermost bag reduces incoming nested-bag contents", function(f)
    local outer, outerStorage = weightedBag(f, f.inventory, "Equipped outer", 80)
    outer.equipped = true
    local _, innerStorage = weightedBag(f, outerStorage, "Inner bag", 90)
    local selected = weightedItem(f, f.remote, 8)
    near(f.world:carryDelta(selected, outerStorage), 1.6)
    near(f.world:carryDelta(selected, innerStorage), 1.6)
end)

case("A fake-equipped outer bag follows its native weight reduction", function(f)
    local outer, storage = weightedBag(f, f.inventory, "Fake equipped", 60)
    outer.fakeEquipped = true
    near(f.world:carryDelta(weightedItem(f, f.remote, 8), storage), 3.2)
end)

case("An attached unequipped outer bag uses its native hotbar mass ratio", function(f)
    local outer, storage = weightedBag(f, f.inventory, "Attached outer", 90)
    outer.attachedSlot, outer.rawWeight, outer.hotbarWeight = 0, 10, 7
    near(f.world:carryDelta(weightedItem(f, f.remote, 8), storage), 5.6)
end)

case("A zero-weight attached bag cannot invent an unknown reduction", function(f)
    local outer, storage = weightedBag(f, f.inventory, "Empty attached outer", 90)
    outer.attachedSlot, outer.rawWeight, outer.hotbarWeight = 0, 0, 0
    equal(f.world:carryDelta(weightedItem(f, f.remote, 8), storage), 8)
end)

case("Actual equipped status takes precedence over an attached bag slot", function(f)
    local outer, storage = weightedBag(f, f.inventory, "Equipped attached outer", 80)
    outer.equipped, outer.attachedSlot, outer.rawWeight, outer.hotbarWeight = true, 0, 10, 7
    near(f.world:carryDelta(weightedItem(f, f.remote, 8), storage), 1.6)
end)

case("Carried rearrangement subtracts the source contribution before adding the destination", function(f)
    local outer, storage = weightedBag(f, f.inventory, "Equipped source", 80)
    outer.equipped = true
    local fromBag, fromMain = weightedItem(f, storage, 8), weightedItem(f, f.inventory, 8)
    near(f.world:carryDelta(fromBag, f.inventory), 6.4)
    near(f.world:carryDelta(fromMain, storage), -6.4)
    assert(f.world:carryDelta(fromBag, f.remote) <= 0, "Unloading carried contents cannot increase character mass")
end)

case("Carried bags remain destinations when source-bag searching is disabled and main inventory is last", function(f)
    local weak, weakStorage = weightedBag(f, f.inventory, "Equipped shoulder bag", 50)
    local strong, strongStorage = weightedBag(f, f.inventory, "Equipped backpack", 80)
    local _, unusedStorage = weightedBag(f, f.inventory, "Unequipped bag", 90)
    weak.equipped, strong.equipped = true, true
    local selected = weightedItem(f, f.remote, 3)
    local destinations = assert(f.world:destinations({includeBags = true, destination = {kind = "inventory"}}, selected))
    equal(destinations[1], strongStorage)
    equal(destinations[2], weakStorage)
    equal(destinations[3], unusedStorage)
    equal(destinations[4], f.inventory)
    local noSourceBags = assert(f.world:destinations({includeBags = false, destination = {kind = "inventory"}}, selected))
    equal(#noSourceBags, 4)
    equal(noSourceBags[1], strongStorage)
    equal(noSourceBags[2], weakStorage)
    equal(noSourceBags[3], unusedStorage)
    equal(noSourceBags[4], f.inventory)
end)

case("Zero-reduction and nested carried bags precede main inventory on equal carry cost", function(f)
    local outer, outerStorage = weightedBag(f, f.inventory, "Zero-reduction backpack", 0)
    outer.equipped = true
    local _, innerStorage = weightedBag(f, outerStorage, "Nested bag", 90)
    local _, spareStorage = weightedBag(f, f.inventory, "Spare bag", 90)
    local selected = weightedItem(f, f.remote, 1)
    local destinations = assert(f.world:destinations({includeBags = false, destination = {kind = "inventory"}}, selected))
    equal(#destinations, 4)
    local bags = {[outerStorage] = true, [innerStorage] = true, [spareStorage] = true}
    for index = 1, 3 do assert(bags[destinations[index]], "Every carried bag must precede main inventory") end
    equal(destinations[4], f.inventory)
    local repeated = assert(f.world:destinations({includeBags = false, destination = {kind = "inventory"}}, selected))
    for index = 1, 4 do equal(repeated[index], destinations[index]) end
end)

case("A live replacement bin cannot inherit inspection or an active target identity", function(f)
    local location = f.square(3, 0)
    local original = f.crate(location, "identical bin")
    original.parent.trash = true
    f.player.location = location
    local target = assert(f.world:trashTarget(original))
    assert(f.world:markTrashInspected(target))
    f.player.location = f.far
    assert(not f.world:trashTarget(original).needsInspection)
    local replacement = f.crate(location, "identical bin")
    replacement.parent.trash = true
    table.remove(location.objects, 1)
    local resolved, reason = f.world:resolveTrashTarget(target)
    equal(resolved, nil)
    assert(reason and reason:find("replaced", 1, true))
    local fresh = assert(f.world:trashTarget(replacement))
    equal(fresh.key, target.key)
    equal(fresh.needsInspection, true)
end)

case("A bin retired as missing requires inspection if the same object returns", function(f)
    local location = f.square(3, 0)
    local original = f.crate(location, "returning bin")
    original.parent.trash = true
    f.player.location = location
    local target = assert(f.world:trashTarget(original))
    assert(f.world:markTrashInspected(target))
    f.player.location = f.far
    location.objects = {}
    equal(#f.world:trashCandidates(), 0)
    equal(f.state.trash[target.key], nil)
    location.objects[1] = original.parent
    equal(f.world:trashTarget(original).needsInspection, true)
end)

case("Observed unloading retires inspection even when the original square returns", function(f)
    local location = f.square(3, 0)
    local original = f.crate(location, "reloaded original bin")
    original.parent.trash = true
    f.player.location = location
    local target = assert(f.world:trashTarget(original))
    assert(f.world:markTrashInspected(target))
    f.player.location = f.far
    f.squares["3:0:0"] = nil
    equal(#f.world:trashCandidates(), 0)
    assert(f.state.trash[target.key])
    f.squares["3:0:0"] = location
    equal(f.world:trashTarget(original).needsInspection, true)
end)

case("Resolving an unloaded target retires inspection before its square returns", function(f)
    local location = f.square(3, 0)
    local original = f.crate(location, "target lookup bin")
    original.parent.trash = true
    f.player.location = location
    local target = assert(f.world:trashTarget(original))
    assert(f.world:markTrashInspected(target))
    f.player.location = f.far
    f.squares["3:0:0"] = nil
    local resolved, reason = f.world:resolveTrashTarget(target)
    equal(resolved, nil)
    equal(reason, "unloaded")
    f.squares["3:0:0"] = location
    equal(f.world:trashTarget(original).needsInspection, true)
end)

case("Moving a bin away and back cannot revive inspection at its former key", function(f)
    local first, second = f.square(3, 0), f.square(6, 0)
    local original = f.crate(first, "moved bin")
    original.parent.trash = true
    f.player.location = first
    local target = assert(f.world:trashTarget(original))
    assert(f.world:markTrashInspected(target))
    f.player.location = f.far
    first.objects, second.objects[1], original.parent.square = {}, original.parent, second
    local away = assert(f.world:trashTarget(original))
    assert(away.key ~= target.key and away.needsInspection)
    second.objects, first.objects[1], original.parent.square = {}, original.parent, first
    local returned = assert(f.world:trashTarget(original))
    equal(returned.key, target.key)
    equal(returned.needsInspection, true)
end)

case("A carried nested source bag resolves its recreated native inventory by item ID", function(f)
    local outer, outerStorage = bag(f, f.inventory, "Outer carried")
    local inner, innerStorage = bag(f, outerStorage, "Inner carried")
    local anchor = assert(f.world:sourceAnchor(innerStorage))
    f.inventory.items = {}
    local _, nextOuter = bag(f, f.inventory, "Outer carried", outer.id)
    local _, nextInner = bag(f, nextOuter, "Inner carried", inner.id)
    equal(f.world:resolveSource(anchor), nextInner)
    f.inventory.items = {}
    equal(f.world:resolveSource(anchor), nil)
end)

case("Nested source bags rebind through their parent storage and immutable IDs", function(f)
    local outer, outerStorage = bag(f, f.junk, "Outer")
    local inner, innerStorage = bag(f, outerStorage, "Inner")
    local anchor = assert(f.world:sourceAnchor(innerStorage))
    equal(f.world:resolveSource(anchor), innerStorage)
    local parent = f.junk.parent
    local replacement = f.container("crate", parent)
    parent.storage = replacement
    local _, nextOuterStorage = bag(f, replacement, "Outer", outer.id)
    local nextInner, nextInnerStorage = bag(f, nextOuterStorage, "Inner", inner.id)
    equal(f.world:resolveSource(anchor), nextInnerStorage)
    nextInner.name = "DifferentType"
    equal(f.world:resolveSource(anchor), nil)
end)

case("A ground source bag rebinds only the matching ID and type on the saved tile", function(f)
    local original, storage = bag(f, nil, "GroundBag")
    original.world = {getSquare = function() return f.far end, getItem = function() return original end,
        getWorldObjectIndex = function() return 0 end}
    f.far.ground[1] = original.world
    local anchor = assert(f.world:sourceAnchor(storage))
    f.squares["50:50:0"] = nil
    local _, reason = f.world:resolveSource(anchor)
    equal(reason, "unloaded")
    local reloaded = f.square(50, 50)
    local replacement, replacementStorage = bag(f, nil, "GroundBag", original.id)
    replacement.world = {getSquare = function() return reloaded end, getItem = function() return replacement end,
        getWorldObjectIndex = function() return 0 end}
    reloaded.ground[1] = replacement.world
    equal(f.world:resolveSource(anchor), replacementStorage)
    replacement.id = original.id + 1
    equal(f.world:resolveSource(anchor), nil)
end)

case("A keyed vehicle source rebinds its storage after native handle recreation", function(f)
    local previous, storage = car(f)
    local anchor = assert(f.world:sourceAnchor(storage))
    previous.removed = true
    local replacement, nextStorage = car(f, 78341922, 73)
    equal(f.world:resolveSource(anchor), nextStorage)
    replacement.keyId = 78341923
    equal(f.world:resolveSource(anchor), nil)
end)

case("An unkeyed source vehicle remains usable only while its actual handle is live", function(f)
    local _, storage = car(f, -1)
    local anchor = assert(f.world:sourceAnchor(storage))
    equal(f.world:resolveSource(anchor), storage)
    f.squares["50:50:0"] = nil
    local resolved, reason = f.world:resolveSource(anchor)
    equal(resolved, nil)
    assert(reason and reason:find("unkeyed", 1, true))
end)

case("An unloaded trash target retains identity and refreshes capacity after reloading", function(f)
    local location = f.square(5, 0)
    local original = f.crate(location, "bin")
    original.parent.trash, original.capacity = true, 10
    local target = assert(f.world:trashTarget(original))
    f.squares["5:0:0"] = nil
    local resolved, reason = f.world:resolveTrashTarget(target)
    equal(resolved, nil)
    equal(reason, "unloaded")
    local remembered = f.world:unloadedTrashTargets()
    equal(#remembered, 1)
    equal(remembered[1].key, target.key)
    equal(remembered[1].capacity, 10)
    local reloaded = f.square(5, 0)
    local replacement = f.crate(reloaded, "bin")
    replacement.parent.trash, replacement.capacity = true, 40
    f.item(replacement, "Existing")
    equal(f.world:resolveTrashTarget(target), replacement)
    equal(target.capacity, 40)
    equal(target.used, 1)
    reloaded.objects = {}
    f.world:trashCandidates()
    equal(f.state.trash[target.key], nil)
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

case("Survey waypoints reject a loaded neighboring building while bin travel remains available", function(f)
    local original = building()
    local _, _, otherRoom = building()
    local _, attach = otherRoom("neighbor", 0, 50, 50, 1, 1)
    attach(f.far)
    local point = {x = 50, y = 50, z = 0}
    local targets, reason = f.world:walkTargets(point, {}, original)
    equal(targets, nil)
    assert(reason:find("original building", 1, true))
    local outside, direct = f.world:walkTargets(point, {})
    equal(outside[1], point)
    equal(direct, true)
end)

case("Moving outside does not change the captured building source scope", function(f)
    local _, _, room = building()
    local _, attach = room("original", 0, 0, 0, 1, 1)
    attach(f.origin)
    local survey = assert(f.world:scan({scope = "building"})).survey
    local section = assert(nextSection(survey))
    local _, _, neighbor = building()
    local _, attachOther = neighbor("other", 0, 50, 50, 1, 1)
    attachOther(f.far)
    f.player.location = f.far
    local scan, missing = f.world:scanSection(section, {scope = "building"})
    equal(f.names(scan), "Beans,Cake,Scrap,Soup")
    equal(missing, 0)
end)

case("Gear discovery includes carried nested bags and only the reviewed source containers", function(f)
    local bag = f.item(f.inventory, "PersonalBag", "Container")
    bag.inventory = f.container("bag")
    bag.inventory.bag = bag
    f.item(bag.inventory, "InsidePersonalBag")
    local found = f.world:gearRecords({f.junk, f.junk})
    local names = f.names({items = found})
    equal(names, "Beans,CarriedFood,InsidePersonalBag,PersonalBag,Scrap")
    assert(not names:find("Apple", 1, true))
end)

case("Safe staging uses ordinary accessible world storage and excludes trash and nested bags", function(f)
    f.junk.parent.trash = true
    local bag = f.item(f.tools, "FoundBag", "Container")
    bag.inventory = f.container("bag")
    bag.inventory.bag = bag
    f.world:_observe(bag.inventory)
    local candidates = f.world:safeStagingContainers()
    equal(#candidates, 3)
    for _, candidate in ipairs(candidates) do
        assert(candidate == f.tools or candidate == f.unlabeled or candidate == f.remote)
        assert(f.world:canAccess(candidate))
    end
end)

case("A recovery reservation protects its items and excludes its container from ordinary jobs", function(f)
    local selected = f.junk.items[1]
    f.world.recovery = {
        isProtected = function(_, item) return item == selected end,
        isReservedContainer = function(_, container) return container == f.junk end,
    }
    local protected, reason = f.world:protected(selected)
    equal(protected, true)
    equal(reason, "Personal gear reserved for recovery")
    local scan = assert(f.world:scan({scope = "container", sourceContainer = f.junk}))
    equal(#scan.items, 0)
    local destinations = assert(f.world:destinations({destination = {kind = "container", ref = f.junk}}, f.tools.items[1]))
    equal(#destinations, 0)
end)

case("Observed bag replacement migrates personal rules and forwards exact recovery identity", function(f)
    local old = f.item(f.inventory, "OldBag", "Container")
    local replacement = f.item(f.inventory, "NewBag", "Container")
    local before, after = tostring(old.id), tostring(replacement.id)
    f.state.keep[before] = true
    f.state.itemLabels[before] = {"custom:1"}
    f.state.containerLabels["bag:" .. before] = {"native:Food"}
    local forwarded
    f.world.recovery = {replaceIdentity = function(_, id, fullType, item) forwarded = {id, fullType, item} end}
    f.world:replaceGear(before, old:getFullType(), replacement)
    equal(f.state.keep[after], true)
    equal(f.state.keep[before], nil)
    equal(f.state.itemLabels[after][1], "custom:1")
    equal(f.state.containerLabels["bag:" .. after][1], "native:Food")
    equal(f.state.containerLabels["bag:" .. before], nil)
    equal(forwarded[1], before)
    equal(forwarded[2], old:getFullType())
    equal(forwarded[3], replacement)
    equal(f.world.dirty, true)
end)

local matchingGlobals = {rules = ISInventoryWindowControlHandler_TransferSameType,
    loot = getPlayerLoot, inventoryPage = ISInventoryPage, safeHouse = SafeHouse}
local function matchingFixture(f)
    local maps, calls = {
        [f.inventory] = {["Fixture.CarriedFood"] = {f.inventory.items[1]}},
        [f.junk] = {["Fixture.Beans"] = {f.junk.items[1]}, ["Fixture.Scrap"] = {f.junk.items[2]}},
        [f.tools] = {["Fixture.Soup"] = {f.tools.items[1]}},
        [f.unlabeled] = {["Fixture.Cake"] = {f.unlabeled.items[1]}},
    }, {}
    ISInventoryWindowControlHandler_TransferSameType = {getItemsTable = function(_, container)
        calls[container] = (calls[container] or 0) + 1
        assert(maps[container], "Native matching boundary needs an explicit fixture map")
        return maps[container]
    end}
    f.loot = {inventoryPane = {inventory = f.junk}, backpacks = {{inventory = f.junk}, {inventory = f.tools}}}
    getPlayerLoot = function() return f.loot end
    return maps, calls
end

case("All-carried matching discovers main and nested bag contents without requiring visible bag controls", function(f)
    local maps, calls = matchingFixture(f)
    local main = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {main}
    local outer = f.item(f.inventory, "OuterBag", "Container")
    outer.inventory = f.container("bag"); outer.inventory.bag = outer
    local first = f.item(outer.inventory, "Beans")
    local inner = f.item(outer.inventory, "InnerBag", "Container")
    inner.inventory = f.container("bag"); inner.inventory.bag = inner
    local second = f.item(inner.inventory, "Beans")
    maps[outer.inventory] = {["Fixture.Beans"] = {first}}
    maps[inner.inventory] = {["Fixture.Beans"] = {second}}
    local records, targets = assert(f.world:matchingRecords("displayed"))
    equal(#records, 3)
    equal(f.names({items = records}), "Beans,Beans,Beans")
    equal(#targets, 1)
    equal(calls[f.inventory], 1)
    equal(calls[outer.inventory], 1)
    equal(calls[inner.inventory], 1)
    equal(calls[f.junk], 1)
    equal(#f.loot.backpacks, 2)
end)

case("Nearby matching retains native target order while removing duplicate and carried targets", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    maps[f.tools]["Fixture.Beans"] = {f.tools.items[1]}
    f.loot.backpacks = {{inventory = f.tools}, {inventory = f.junk}, {inventory = f.tools}, {inventory = f.inventory}}
    local _, targets = f.world:matchingRecords("nearby")
    equal(#targets, 2)
    equal(targets[1].ref, f.tools)
    equal(targets[2].ref, f.junk)
end)

case("A displayed target remains pinned after another native loot pane is selected", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    local _, targets = f.world:matchingRecords("displayed")
    f.loot.inventoryPane.inventory = f.tools
    local destinations = assert(f.world:destinations({destination = {kind = "matching", targets = targets}}, beans))
    equal(#destinations, 1)
    equal(destinations[1], f.junk)
end)

case("Matching uses native clothing alias equivalence and deduplicates repeated alias hits", function(f)
    local maps = matchingFixture(f)
    local variant = f.item(f.inventory, "HolsterLeft")
    maps[f.inventory]["Native.HolsterAlias"] = {variant, variant}
    maps[f.inventory]["Native.SecondAlias"] = {variant}
    maps[f.junk] = {["Native.HolsterAlias"] = {f.junk.items[1]}, ["Native.SecondAlias"] = {f.junk.items[1]}}
    local records, targets = f.world:matchingRecords("displayed")
    equal(#records, 1)
    equal(records[1].item, variant)
    equal(targets[1].types[variant:getFullType()], true)
    equal(targets[1].types["Native.HolsterAlias"], nil)
end)

case("Explicit consumption favorite permission preserves every other protection", function(f)
    local selected = f.item(f.inventory, "Beans")
    function selected:isFavorite() return true end
    local allowed = {allowFavorite = true}
    local protected, reason = f.world:protected(selected)
    assert(protected and reason == "Favorite")
    assert(f.world:protected(selected, {}) and f.world:protected(selected, {allowFavorite = "true"}))
    assert(not f.world:protected(selected, allowed))
    f.state.keep[tostring(selected.id)] = true
    protected, reason = f.world:protected(selected, allowed)
    assert(protected and reason == "Keep")
    f.state.keep[tostring(selected.id)] = nil
    f.world.recovery = {isProtected = function() return true end}
    protected, reason = f.world:protected(selected, allowed)
    assert(protected and reason == "Personal gear reserved for recovery")
    f.world.recovery = nil
    function f.player:isEquipped(item) return item == selected end
    protected, reason = f.world:protected(selected, allowed)
    assert(protected and reason == "Equipped")
    function f.player:isEquipped() return false end
    function f.player:getPrimaryHandItem() return selected end
    protected, reason = f.world:protected(selected, allowed)
    assert(protected and reason == "Held")
    function f.player:getPrimaryHandItem() return nil end
    function selected:getAttachedSlot() return 0 end
    protected, reason = f.world:protected(selected, allowed)
    assert(protected and reason == "Attached")
    function selected:getAttachedSlot() return -1 end
    assert(not f.world:protected(selected, allowed))
    assert(f.world:protected(selected), "Default transfer/trash favorite policy must remain unchanged")
end)

case("Explicit consumption permits owned food and fluid equipment without weakening transfer safety", function(f)
    local vessel = f.item(f.inventory, "Canteen")
    local fluid = {}
    function vessel:getFluidContainer() return fluid end
    function vessel:isFavorite() return true end
    local policy = {allowFavorite = true, allowEquippedConsumption = true}
    local function assertEquipment()
        assert(f.world:protected(vessel, {allowFavorite = true}))
        assert(not f.world:protected(vessel, policy))
        assert(f.world:protected(vessel), "Default transfer/trash protections must remain")
    end
    function vessel:isWorn() return true end
    assertEquipment()
    function vessel:isWorn() return false end
    function f.player:isEquipped(item) return item == vessel end
    assertEquipment()
    function f.player:isEquipped() return false end
    function f.player:getPrimaryHandItem() return vessel end
    assertEquipment()
    function f.player:getPrimaryHandItem() return nil end
    function vessel:getAttachedSlot() return 0 end
    assertEquipment()
    f.state.keep[tostring(vessel.id)] = true
    local protected, reason = f.world:protected(vessel, policy)
    assert(protected and reason == "Keep")
    f.state.keep[tostring(vessel.id)] = nil
    f.world.recovery = {isProtected = function() return true end}
    protected, reason = f.world:protected(vessel, policy)
    assert(protected and reason == "Personal gear reserved for recovery")
    f.world.recovery = nil
    fluid = nil
    assert(f.world:protected(vessel, policy), "Non-fluid equipment must remain protected")
    fluid = {}
    local originalContainer = vessel.getContainer
    function vessel:getContainer() return f.junk end
    assert(f.world:protected(vessel, policy), "External or bag equipment must not be moved")
    function vessel:getContainer() return nil end
    assert(f.world:protected(vessel, policy))
    vessel.getContainer = originalContainer
    assert(not f.world:protected(vessel, policy))
    assert(f.world:protected(vessel, {allowFavorite = true, allowEquippedConsumption = "true"}))
    local bag = f.item(f.inventory, "WaterBag", "Container")
    bag.inventory = f.container("bag"); bag.inventory.bag = bag
    f.item(bag.inventory, "Beans")
    function bag:getFluidContainer() return fluid end
    function bag:isWorn() return true end
    protected, reason = f.world:protected(bag, policy)
    assert(protected and reason == "Bag contains items")
    local food = f.item(f.inventory, "Apple")
    local previousInstance = instanceof
    instanceof = function(value, class) return value == food and class == "Food" or previousInstance(value, class) end
    function f.player:getPrimaryHandItem() return food end
    assert(f.world:protected(food), "Held food remains protected for ordinary transfers")
    assert(not f.world:protected(food, policy), "Explicit consumption permits held native Food")
    f.state.keep[tostring(food.id)] = true
    assert(f.world:protected(food, policy), "Keep still protects held Food")
    f.state.keep[tostring(food.id)] = nil
    local foodContainer = food.getContainer
    function food:getContainer() return f.junk end
    assert(f.world:protected(food, policy), "External Food cannot use equipment exception")
    food.getContainer = foodContainer
    instanceof = previousInstance
end)

case("All-carried matching retains Keep favorite worn attached and whole-bag protection", function(f)
    local maps = matchingFixture(f)
    local normal = f.item(f.inventory, "Beans")
    local kept = f.item(f.inventory, "Beans"); f.state.keep[tostring(kept.id)] = true
    local favorite = f.item(f.inventory, "Beans"); function favorite:isFavorite() return true end
    local worn = f.item(f.inventory, "Beans"); function f.player:isEquipped(item) return item == worn end
    local attached = f.item(f.inventory, "Beans"); function attached:getAttachedSlot() return 0 end
    local bag = f.item(f.inventory, "Bag", "Container")
    bag.inventory = f.container("bag"); bag.inventory.bag = bag
    local child = f.item(bag.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {normal, kept, favorite, worn, attached, bag}
    maps[bag.inventory] = {["Fixture.Beans"] = {child}}
    local records = f.world:matchingRecords("displayed")
    equal(#records, 2)
    local actual = {[records[1].item] = true, [records[2].item] = true}
    assert(actual[normal] and actual[child])
end)

case("Matching reads each native source and target map once for a large source list", function(f)
    local maps, calls = matchingFixture(f)
    maps[f.inventory]["Fixture.Beans"] = {}
    for _ = 1, 100 do
        maps[f.inventory]["Fixture.Beans"][#maps[f.inventory]["Fixture.Beans"] + 1] = f.item(f.inventory, "Beans")
    end
    f.loot.backpacks = {{inventory = f.junk}, {inventory = f.junk}}
    local records = f.world:matchingRecords("nearby")
    equal(#records, 100)
    equal(calls[f.inventory], 1)
    equal(calls[f.junk], 1)
end)

case("Recovery-reserved targets do not enter matching routes", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    f.world.recovery = {isProtected = function() return false end,
        isReservedContainer = function(_, container) return container == f.junk end}
    local records, targets = f.world:matchingRecords("nearby")
    equal(#records, 0)
    equal(#targets, 1)
    equal(targets[1].ref, f.tools)
end)

case("Live permission excludes matching targets without blocking owned source discovery", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    maps[f.remote] = {["Fixture.Beans"] = {f.remote.items[1]}}
    f.loot.backpacks = {{inventory = f.junk}, {inventory = f.remote}}
    isClient = function() return true end
    SafeHouse = {isSafehouseAllowLoot = function(square) assert(square); return square == f.far end}
    local records, targets = f.world:matchingRecords("nearby")
    equal(#records, 1)
    equal(#targets, 1)
    equal(targets[1].ref, f.remote)
end)

case("A recreated native matching target rebinds through its original world anchor", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    local _, targets = f.world:matchingRecords("displayed")
    local reloaded = f.square(0, 0)
    local replacement = f.crate(reloaded, "junk")
    f.player.location = reloaded
    local destinations = f.world:destinations({destination = {kind = "matching", targets = targets}}, beans)
    equal(#destinations, 1)
    equal(destinations[1], replacement)
end)

case("A replacement object on the same loaded square cannot inherit a matching route", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    local _, targets = f.world:matchingRecords("displayed")
    table.remove(f.origin.objects, 1)
    local replacement = f.crate(f.origin, "junk")
    table.remove(f.origin.objects, #f.origin.objects)
    table.insert(f.origin.objects, 1, replacement.parent)
    local destinations = f.world:destinations({destination = {kind = "matching", targets = targets}}, beans)
    equal(#destinations, 0)
end)

case("Synthetic floor matching uses a loaded permission square and keeps its original drop point", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    local floor = f.container("floor")
    maps[floor] = {["Fixture.Beans"] = {f.item(floor, "Beans")}}
    f.loot.inventoryPane.inventory = floor
    ISInventoryPage = {GetFloorContainer = function() return floor end}
    local denied = false
    isClient = function() return true end
    SafeHouse = {isSafehouseAllowLoot = function(square)
        assert(square, "A native synthetic floor has no source-grid parent")
        return not denied or square ~= f.origin
    end}
    equal(floor:getSourceGrid(), nil)
    assert(f.world:canAccess(floor))
    local _, targets = f.world:matchingRecords("displayed")
    local request = {destination = {kind = "matching", targets = targets}}
    f.player.location = f.far
    local point = f.world:matchingPoint(request, floor)
    equal(point.x, 0); equal(point.y, 0); equal(point.z, 0)
    equal(f.world:destinations(request, beans)[1], floor)
    denied = true
    equal(#f.world:destinations(request, beans), 0)
end)

case("An unloaded matching floor retains a current native handle so the job can return to its point", function(f)
    local maps = matchingFixture(f)
    local beans = f.item(f.inventory, "Beans")
    maps[f.inventory]["Fixture.Beans"] = {beans}
    local floor = f.container("floor")
    maps[floor] = {["Fixture.Beans"] = {f.item(floor, "Beans")}}
    f.loot.inventoryPane.inventory = floor
    ISInventoryPage = {GetFloorContainer = function() return floor end}
    local _, targets = f.world:matchingRecords("displayed")
    f.squares["0:0:0"], f.player.location = nil, f.far
    local request = {destination = {kind = "matching", targets = targets}}
    equal(f.world:destinations(request, beans)[1], floor)
    equal(f.world:matchingPoint(request, floor).x, 0)
end)

case("Matching record ordering delegates to the native sorter without mutating its input", function(f)
    matchingFixture(f)
    local heavy, light = f.item(f.inventory, "Heavy"), f.item(f.inventory, "Light")
    local records = {{item = heavy}, {item = light}}
    local calls = 0
    f.loot.inventoryPane.sortItemsByTypeAndWeight = function(_, items)
        calls = calls + 1
        assert(items[1] == heavy and items[2] == light)
        items[1], items[2] = light, heavy
    end
    local ordered = f.world:matchingOrder(records)
    equal(calls, 1)
    equal(ordered[1], records[2]); equal(ordered[2], records[1])
    equal(records[1].item, heavy)
end)

case("A missing native sorter preserves order while a failing sorter cannot silently fall back", function(f)
    matchingFixture(f)
    local records = {{item = f.item(f.inventory, "Beans")}}
    equal(f.world:matchingOrder(records), records)
    f.loot.inventoryPane.sortItemsByTypeAndWeight = function() error("Native sorting failed") end
    local ordered, err = f.world:matchingOrder(records)
    equal(ordered, nil)
    assert(err:find("matching-transfer order", 1, true))
end)

case("Unavailable native matching rules or failed maps cannot broaden the selected transfer", function(f)
    matchingFixture(f)
    local records = f.world:records(f.inventory, true)
    ISInventoryWindowControlHandler_TransferSameType = nil
    local targets, err = f.world:matchingTargets("displayed", records)
    equal(targets, nil); assert(err:find("unavailable", 1, true))
    matchingFixture(f)
    ISInventoryWindowControlHandler_TransferSameType.getItemsTable = function() error("Native source map failed") end
    targets, err = f.world:matchingTargets("displayed", records)
    equal(targets, nil); assert(err:find("could not read", 1, true))
end)

case("Smart Take all-pane snapshots deduplicate visible eligible containers without widening to hidden storage", function(f)
    matchingFixture(f)
    f.loot.backpacks = {{inventory = f.junk}, {inventory = f.tools}, {inventory = f.tools}, {inventory = f.inventory}}
    local records, err, sources = f.world:smartLootRecords("all", f.junk, true)
    assert(not err); equal(#sources, 2); equal(#records, 3)
    equal(f.names({items = records}), "Beans,Scrap,Soup")
    equal(#assert(f.world:smartLootRecords("all", f.junk, false)), 2)
    f.junk.items = {}
    records = assert(f.world:smartLootRecords("all", f.junk, true))
    equal(#records, 1); equal(records[1].source, f.tools)
    f.loot.inventoryPane.inventory = f.tools
    f.loot.backpacks = {{inventory = f.tools}, {inventory = f.unlabeled}}
    local scan = assert(f.world:scan({scope = "lootPane", sourceContainers = sources, includeInventory = true, includeBags = true}))
    equal(f.names(scan), "Soup"); equal(#scan.warnings, 1)
    local nextSources = assert(f.world:smartLootSources(nil, true))
    equal(f.names(assert(f.world:scan({scope = "lootPane", sourceContainers = nextSources}))), "Cake,Soup")
end)

case("Smart Take all-pane excludes invalid locked recovery owned and permission-denied containers", function(f)
    matchingFixture(f)
    f.loot.backpacks = {{inventory = f.junk}, {inventory = f.tools}, {inventory = f.unlabeled}, {inventory = f.remote}, {inventory = f.inventory}}
    f.tools.isLockedToCharacter = function() return true end
    f.world.recovery = {isReservedContainer = function(_, container) return container == f.junk end,
        isProtected = function() return false end}
    f.unlabeled:getParent().getObjectIndex = function() return -1 end
    isClient = function() return true end
    SafeHouse = {isSafehouseAllowLoot = function(square) return square ~= f.far end}
    equal(#assert(f.world:smartLootSources(nil, true)), 0)
    equal(#assert(f.world:smartLootRecords("all", nil, true)), 0)
end)

case("Smart Take Matching preserves per-container native aliases across visible sources", function(f)
    local maps = matchingFixture(f)
    maps[f.inventory] = {["Shared.Alias"] = {f.inventory.items[1]}}
    maps[f.junk] = {["Shared.Alias"] = {f.junk.items[1]}}
    maps[f.tools] = {["Shared.Alias"] = {f.tools.items[1]}}
    local records = assert(f.world:smartLootRecords("matching", f.junk, true))
    equal(#records, 2); equal(f.names({items = records}), "Beans,Soup")
    f.state.keep[tostring(f.junk.items[1].id)] = true
    f.tools.items[1].isUnwanted = function() return true end
    equal(#assert(f.world:smartLootRecords("matching", f.junk, true)), 0)
end)

case("Loot-pane floor and crate scanning uses actual floor permissions and never widens a stale floor reference", function(f)
    matchingFixture(f)
    local floor = f.container("floor")
    local allowed, denied = f.item(floor, "AllowedFloor"), f.item(floor, "DeniedFloor")
    allowed.world = {getSquare = function() return f.origin end}
    denied.world = {getSquare = function() return f.far end}
    ISInventoryPage = {GetFloorContainer = function() return floor end}
    f.loot.inventoryPane.inventory = floor
    f.loot.backpacks = {{inventory = floor}, {inventory = f.junk}}
    isClient = function() return true end
    SafeHouse = {isSafehouseAllowLoot = function(square) assert(square, "Floor permission requires a square"); return square == f.origin end}
    equal(f.names({items = assert(f.world:smartLootRecords("all", floor, true))}), "AllowedFloor,Beans,Scrap")
    local sources = assert(f.world:smartLootSources(nil, true))
    local scan = assert(f.world:scan({scope = "lootPane", sourceContainers = sources}))
    equal(f.names(scan), "AllowedFloor,Beans,Scrap")
    equal(#scan.warnings, 1)
    local replacement = f.container("floor")
    f.item(replacement, "NewFloor")
    ISInventoryPage.GetFloorContainer = function() return replacement end
    f.loot.inventoryPane.inventory = replacement
    f.loot.backpacks = {{inventory = replacement}, {inventory = f.junk}}
    scan = assert(f.world:scan({scope = "lootPane", sourceContainers = sources}))
    equal(f.names(scan), "Beans,Scrap")
    equal(#scan.warnings, 1)
    ISInventoryPage = nil
end)

case("Loot-pane scans reject malformed snapshots and never recurse into source bags", function(f)
    matchingFixture(f)
    local _, nested = weightedBag(f, f.junk, "Source bag", 80)
    f.item(nested, "Hidden")
    local sources = assert(f.world:smartLootSources(nil, true))
    local scan = assert(f.world:scan({scope = "lootPane", sourceContainers = sources, includeBags = true, includeInventory = true}))
    for _, record in ipairs(scan.items) do assert(record.source ~= nested and record.source ~= f.inventory) end
    assert(not f.world:scan({scope = "lootPane", sourceContainers = {["bad"] = f.junk}}))
end)

case("Smart Take Matching finds native alias matches in every nested carried bag", function(f)
    local maps = matchingFixture(f)
    local outer, storage = weightedBag(f, f.inventory, "Outer", 80)
    local inner, nested = weightedBag(f, storage, "Inner", 90)
    local seed = f.item(nested, "Variant")
    maps[storage], maps[nested] = {}, {["Fixture.Alias"] = {seed}}
    maps[f.junk]["Fixture.Alias"] = {f.junk.items[1]}
    local records = assert(f.world:smartLootRecords("matching", f.junk))
    equal(#records, 1); equal(records[1].item, f.junk.items[1])
    equal(records[1].source, f.junk)
    f.loot.inventoryPane.inventory = f.tools
    records = assert(f.world:smartLootRecords("matching", f.junk))
    equal(#records, 1); equal(records[1].source, f.junk)
end)

case("Smart Take All leaves protected and unwanted source items and never opens source bags", function(f)
    matchingFixture(f)
    f.state.keep[tostring(f.junk.items[1].id)] = true
    f.junk.items[2].isUnwanted = function(_, player) return player == f.player end
    local _, nested = weightedBag(f, f.junk, "Source bag", 80)
    f.item(nested, "Hidden")
    local records = assert(f.world:smartLootRecords("all", f.junk))
    equal(#records, 0)
end)

case("Smart matching fails closed for missing native maps and rejects carried or recovery sources", function(f)
    matchingFixture(f)
    ISInventoryWindowControlHandler_TransferSameType = nil
    local records, err = f.world:smartLootRecords("matching", f.junk)
    equal(records, nil); assert(err:find("unavailable", 1, true))
    records = f.world:smartLootRecords("all", f.inventory); equal(records, nil)
    f.world.recovery = {isReservedContainer = function(_, container) return container == f.junk end}
    records, err = f.world:smartLootRecords("all", f.junk)
    equal(records, nil); assert(err:find("Recover", 1, true))
end)

case("Smart Load groups native alias matches across bags then orders remaining storage by reduction", function(f)
    local maps = matchingFixture(f)
    local weak, weakStorage = weightedBag(f, f.inventory, "Matching weak", 50)
    local strong, strongStorage = weightedBag(f, f.inventory, "Empty strong", 90)
    local second, secondStorage = weightedBag(f, f.inventory, "Matching strong", 80)
    weak.equipped, strong.equipped, second.equipped = true, true, true
    local seed1, seed2 = f.item(weakStorage, "Variant"), f.item(secondStorage, "Variant")
    local selected = f.junk.items[1]
    maps[f.junk]["Fixture.Alias"] = {selected}
    maps[weakStorage], maps[strongStorage], maps[secondStorage] = {["Fixture.Alias"] = {seed1}}, {}, {["Fixture.Alias"] = {seed2}}
    local destinations = assert(f.world:destinations({destination = {kind = "inventory"}}, selected))
    equal(#destinations, 4)
    equal(destinations[1], secondStorage); equal(destinations[2], weakStorage)
    equal(destinations[3], strongStorage); equal(destinations[4], f.inventory)
end)

ISInventoryWindowControlHandler_TransferSameType = matchingGlobals.rules
getPlayerLoot, ISInventoryPage, SafeHouse = matchingGlobals.loot, matchingGlobals.inventoryPage, matchingGlobals.safeHouse
getCell, instanceof, isClient = saved.getCell, saved.instanceof, saved.isClient
ISInventoryPaneContextMenu, getTextOrNull = saved.ISInventoryPaneContextMenu, saved.getTextOrNull
getVehicleById = saved.getVehicleById
assert(#failures == 0, table.concat(failures, "\n"))
print("PASS world source-boundary integration cases: " .. passed)
