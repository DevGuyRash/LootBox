-- A small model of the game's own rules, written from its sources, for driving
-- the mod's flows end to end. Single player applies an action's effect when it
-- completes; a server applies it later, sends the changes in order and then
-- reports the action done (or rejected).
local Game = { now = 1000, client = false, lag = 250, log = {} }

local function list(values)
    local l = { values = values or {} }
    function l:size() return #self.values end
    function l:get(index) return self.values[index + 1] end
    function l:add(value) self.values[#self.values + 1] = value end
    function l:contains(value) for _, v in ipairs(self.values) do if v == value then return true end end return false end
    function l:remove(value) for i, v in ipairs(self.values) do if v == value then table.remove(self.values, i) return end end end
    return l
end
Game.list = list
ArrayList = { new = function() return list() end }

function getTimestampMs() return Game.now end
function isClient() return Game.client end
function isServer() return false end
function getText(key) return key end
function round(value) return value end
Events = setmetatable({}, { __index = function(t, k) local e = { Add = function() end, Remove = function() end }; rawset(t, k, e); return e end })
Keyboard = { KEY_ESCAPE = 1 }
function isKeyDown() return false end
MoodleType = { FOOD_EATEN = "eaten" }
ItemTag, CharacterTrait = nil, {}
CharacterStat = { HUNGER = { getMinimumValue = function() return 0 end }, THIRST = { getMinimumValue = function() return 0 end } }
FluidCategory = { Beverage = "Beverage", Water = "Water", Hazardous = "Hazardous", Alcoholic = "Alcoholic" }
InputFlag = { Unseal = "Unseal", IsSealed = "IsSealed" }
SafeHouse = { isSafehouseAllowInteract = function() return true end, isSafehouseAllowLoot = function() return true end }
FluidUtil = { roundTransfer = function(n) return math.floor(n * 1000 + 0.0001) / 1000 end }
function instanceof(object, class)
    if type(object) ~= "table" then return false end
    return class == "InventoryItem" and object.isItem == true or class == "Food" and object.food ~= nil
        or class == "InventoryContainer" and object.inside ~= nil or class == "IsoWorldInventoryObject" and object.isWorldItem == true
end

-- Liquids -----------------------------------------------------------------
local kinds = {}
function Game.liquid(name, thirst, flags)
    kinds[name] = kinds[name] or { name = name, thirst = thirst or 0, flags = flags or {},
        getTranslatedName = function() return name end, isPoisonous = function(self) return self.flags.poison == true end,
        isCategory = function(self, category)
            if category == "Water" then return name == "Water" end
            if category == "Beverage" then return name ~= "Water" end
            return category == "Alcoholic" and self.flags.alcohol == true
        end,
        getProperties = function(self) return { getPoison = function() return 0 end, getAlcohol = function() return self.flags.alcohol and 1 or 0 end,
            getFoodSicknessChange = function() return 0 end } end }
    if thirst then kinds[name].thirst = thirst end
    return kinds[name]
end
Game.liquid("Water")
local Fluid_ = {}
Fluid_.__index = Fluid_
function Game.fluid(owner, capacity, amount, name)
    return setmetatable({ owner = owner, capacity = capacity, amount = amount or 0, name = amount and amount > 0 and (name or "Water") or nil }, Fluid_)
end
function Fluid_:getOwner() return self.owner end
function Fluid_:getAmount() return self.amount end
function Fluid_:getCapacity() return self.capacity end
function Fluid_:getFreeCapacity() return self.capacity - self.amount end
function Fluid_:getFilledRatio() return self.amount / self.capacity end
function Fluid_:isEmpty() return self.amount <= 0 end
function Fluid_:isFull() return self.amount >= self.capacity end
function Fluid_:canAddFluid() return not self.locked and self.amount < self.capacity end
function Fluid_:isInputLocked() return self.locked == true end
function Fluid_:canPlayerEmpty() return not (self.owner.sealed or self.sealed) end
function Fluid_:isMultiTileMoveable() return false end
function Fluid_:isPoisonous() return false end
function Fluid_:isTainted() return false end
function Fluid_:isMixture() return false end
function Fluid_:getPrimaryFluid() return self.name and kinds[self.name] end
function Fluid_:getUiName() return self.name end
function Fluid_:getTranslatedContainerName() return self.owner.name end
function Fluid_:copyFluidsFrom(other) self.amount, self.name = other.amount, other.name end
function Fluid_:getProperties()
    local kind, amount = self.name and kinds[self.name], self.amount
    return { getAlcohol = function() return kind and kind.flags.alcohol and 1 or 0 end, getPoison = function() return 0 end,
        getFoodSicknessChange = function() return 0 end, getHungerChange = function() return 0 end,
        getThirstChange = function() return kind and -kind.thirst * amount or 0 end }
end
function Fluid_:createFluidSample()
    local name = self.name
    return { size = function() return name and 1 or 0 end, getFluid = function() return kinds[name] end, getPercentage = function() return 1 end,
        release = function() end }
end
FluidContainer = {
    CanTransfer = function(a, b) return a.amount > 0 and b.amount < b.capacity and not b.locked end,
}
function Game.transfer(a, b, litres)
    litres = math.min(litres, a.amount, b.capacity - b.amount)
    b.name = b.amount > 0 and b.name or a.name
    a.amount, b.amount = a.amount - litres, b.amount + litres
    if a.amount < 1e-9 then a.amount, a.name = 0, nil end
end

-- Containers and items ----------------------------------------------------
local Container = {}
Container.__index = Container
function Game.container(kind, fields)
    local c = setmetatable(fields or {}, Container)
    c.kind, c.items, c.capacity = kind, list(), c.capacity or 50
    return c
end
function Container:getItems() return self.items end
function Container:getType() return self.kind end
function Container:contains(item) return self.items:contains(item) end
function Container:getItemWithID(id) for _, i in ipairs(self.items.values) do if i.id == id then return i end end end
function Container:containsID(id) return self:getItemWithID(id) ~= nil end
function Container:getContainingItem() return self.bag end
function Container:getParent() return self.parent end
function Container:isLockedToCharacter() return false end
function Container:hasRoomFor() return true end
function Container:isItemAllowed() return true end
function Container:isRemoveItemAllowed() return true end
function Container:put(item)
    if item.container then item.container.items:remove(item) end
    item.container = self
    self.items:add(item)
    return item
end
function Container:take(item) self.items:remove(item); item.container = nil end

local Item = {}
Item.__index = Item
local nextId = 100
function Game.item(fullType, fields)
    local item = setmetatable(fields or {}, Item)
    nextId = nextId + 7
    item.isItem, item.fullType, item.id, item.name = true, fullType, item.id or nextId, item.name or fullType
    item.modData = item.modData or {}
    item.script = item.script or Game.script(fullType)
    if item.litres then item.fluid = Game.fluid(item, item.capacity or 1, item.litres, item.liquid) end
    return item
end
local scripts = {}
function Game.script(fullType, fields)
    scripts[fullType] = scripts[fullType] or setmetatable(fields or {}, { __index = {
        isCantEat = function(self) return self.cantEat == true end, getFullName = function() return fullType end } })
    for k, v in pairs(fields or {}) do scripts[fullType][k] = v end
    return scripts[fullType]
end
-- The same item as a new object under the same id, as a server sends it.
function Game.replica(item)
    local copy = setmetatable({}, Item)
    for k, v in pairs(item) do copy[k] = v end
    copy.container, copy.world = nil, nil
    if item.fluid then copy.fluid = Game.fluid(copy, item.fluid.capacity, item.fluid.amount, item.fluid.name) end
    return copy
end
function Item:getID() return self.id end
function Item:getFullType() return self.fullType end
function Item:getName() return self.name end
function Item:getContainer() return self.container end
function Item:getWorldItem() return self.world end
function Item:getInventory() return self.inside end
function Item:getFluidContainer() return not (self.world and self.world.fluid) and self.fluid or nil end
function Item:isSealed() return self.sealed == true end
function Item:isFavorite() return self.favorite == true end
function Item:isWorn() return false end
function Item:getModData() return self.modData end
function Item:getScriptItem() return self.script end
function Item:getCustomMenuOption() return self.drinkable and "ContextMenu_Drink" or nil end
function Item:getOpeningRecipe() return self.openingRecipe end
function Item:getRequireInHandOrInventory() return nil end
function Item:getHungerChange() return self.food and -self.food.hunger or 0 end
function Item:getHungChange() return self:getHungerChange() end
function Item:getThirstChange() return self.food and -(self.food.thirst or 0) or 0 end
function Item:getBaseHunger() return self.food and -(self.food.base or self.food.hunger) or 0 end
for _, name in ipairs({ "isRotten", "isBurnt", "isFrozen", "isTainted", "isPoison", "isAlcoholic", "isbDangerousUncooked", "isCooked" }) do
    Item[name] = function(self) return self.unsafe == name end
end
function Item:getPoisonPower() return 0 end
function Item:getFoodSicknessChange() return 0 end
function Item:getUnequippedWeight() return 1 end
function Item:getWorldZRotation() return self.rotation or 0 end
function Item:canStoreWater() return self.fluid ~= nil end
function Item:isInPlayerInventory()
    local c = self.container
    while c do
        if c == Game.player.main then return true end
        c = c.bag and c.bag.container
    end
    return false
end

-- World -------------------------------------------------------------------
local squares = {}
local function key(x, y, z) return x .. ":" .. y .. ":" .. z end
function Game.square(x, y, z)
    z = z or 0
    local k = key(x, y, z)
    if squares[k] then return squares[k] end
    local s = { x = x, y = y, z = z, objects = list(), ground = list() }
    function s:getX() return self.x end
    function s:getY() return self.y end
    function s:getZ() return self.z end
    function s:getObjects() return self.objects end
    function s:getWorldObjects() return self.ground end
    function s:getTotalWeightOfItemsOnFloor() return 0 end
    function s:canReachTo() return true end
    function s:isBlockedTo() return false end
    squares[k] = s
    return s
end
function getCell() return { getGridSquare = function(_, x, y, z) return squares[key(x, y, z)] end } end
-- Lays an item on a tile; the loot window's floor container lists it when open.
function Game.lay(item, square, pose)
    if item.container then item.container:take(item) end
    local w = { isWorldItem = true, item = item, square = square, pose = pose or { 0.5, 0.5, 0 }, fluid = item.fluid }
    -- Standing on the ground, a vessel's liquid belongs to its world object.
    if w.fluid then w.fluid.owner = w end
    function w:getItem() return self.item end
    function w:getSquare() return self.square end
    function w:isMultiTileMoveable() return false end
    function w:isExtendedPlacement() return false end
    function w:isExistInTheWorld() return true end
    function w:getOffX() return self.pose[1] end
    function w:getOffY() return self.pose[2] end
    function w:getOffZ() return self.pose[3] end
    function w:getFluidContainer() return self.fluid end
    item.world = w
    square.ground:add(w)
    if Game.floor then Game.floor:put(item) end
    return item
end
function Game.lift(item)
    if item.world then
        item.world.square.ground:remove(item.world)
        if item.fluid then item.fluid.owner = item end
        item.world = nil
    end
    if item.container then item.container:take(item) end
end

-- The player --------------------------------------------------------------
function Game.newPlayer()
    local p = { x = 10, y = 10, z = 0, hunger = 0, thirst = 0, actions = list(), main = Game.container("none"), index = 0 }
    p.main.parent = p
    for dx = -2, 2 do for dy = -2, 2 do Game.square(10 + dx, 10 + dy) end end
    function p:getInventory() return self.main end
    function p:getPlayerNum() return self.index end
    function p:getCurrentSquare() return Game.square(math.floor(self.x), math.floor(self.y), self.z) end
    function p:getSquare() return self:getCurrentSquare() end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:isLocalPlayer() return true end
    function p:getCharacterActions() return self.actions end
    function p:hasTimedActions() return self.actions:size() > 0 end
    function p:getPrimaryHandItem() return self.primary end
    function p:getSecondaryHandItem() return self.secondary end
    function p:getStats() return { get = function(_, stat) return stat == CharacterStat.HUNGER and p.hunger or p.thirst end } end
    function p:getMoodles() return { getMoodleLevel = function() return p.eaten or 0 end } end
    function p:tooDarkToRead() return false end
    function p:getFreeInventoryCapacity() return 20 end
    function p:hasFullInventory() return false end
    for name, field in pairs({ isDead = "dead", isAsleep = "asleep", isAiming = "aiming", isAttacking = "attacking", isShoving = "shoving",
        isRunning = "running", isSprinting = "sprinting", isClimbing = "climbing", isKnockedDown = "down", isPlayerMoving = "moving",
        isMoving = "moving", isDraggingCorpse = "dragging" }) do
        p[name] = function(self) return self[field] == true end
    end
    function p:pressedMovement() return self.moving == true end
    Game.player = p
    Game.floor = nil
    return p
end
function getSpecificPlayer() return Game.player end
function getPlayerInventory() end
function getPlayerLoot()
    return { refreshBackpacks = function()
        Game.floor = Game.floor or Game.container("floor")
        for _, s in pairs(squares) do for _, w in ipairs(s.ground.values) do if w.item.container ~= Game.floor then
            Game.floor.items:add(w.item); w.item.container = Game.floor end end end
    end }
end
Game.world = {
    protected = function(_, item, options)
        if item.keep then return true, "Keep" end
        if item.favorite and not (options and options.allowFavorite) then return true, "Favorite" end
        return false
    end,
    consumptionSource = function(_, item, source)
        if Game.unreachable then return nil, "The source is out of reach" end
        return item.container == source, "The selected item moved or changed"
    end,
    name = function(_, container) return container.kind end,
    owns = function(_, container) return container == Game.player.main end,
}

-- The action queue and the engine's action loop ----------------------------
ISTimedActionQueue = { queues = {} }
local Queue = {}
Queue.__index = Queue
function ISTimedActionQueue.getTimedActionQueue(player)
    local q = ISTimedActionQueue.queues[player]
    if not q then q = setmetatable({ queue = {}, character = player }, Queue); ISTimedActionQueue.queues[player] = q end
    return q
end
function Queue:indexOf(action) for i, v in ipairs(self.queue) do if v == action then return i end end return -1 end
function Queue:removeFromQueue(action) local i = self:indexOf(action); if i ~= -1 then table.remove(self.queue, i) end end
function Queue:addToQueue(action)
    self.queue[#self.queue + 1] = action
    if #self.queue == 1 then self.current = action; action:begin() end
end
function Queue:onCompleted(action)
    self:removeFromQueue(action)
    self.current = self.queue[1]
    if self.current then
        if self.current:isValidStart() then self.current:begin() else self:resetQueue() end
    end
end
-- The game clears a queue whose first action the engine no longer runs.
function Queue:tick()
    local first = self.queue[1]
    if first and not self.character.actions:contains(first.action) then self:resetQueue() end
end
function Queue:resetQueue()
    for _, a in ipairs(self.queue) do if not a:isStarted() then a:forceCancel() end end
    self.queue, self.current = {}, nil
end
function ISTimedActionQueue.add(action)
    if action.character.asleep or action.character.dragging then return end
    ISTimedActionQueue.getTimedActionQueue(action.character):addToQueue(action)
end

local Base = {}
Base.__index = Base
local function derive(name)
    local class = setmetatable({ Type = name }, { __index = Base })
    class.__index = class
    return class
end
function Base.create(class, player, fields)
    local o = setmetatable(fields or {}, class)
    o.character = player
    for _, name in ipairs({ "stopOnWalk", "stopOnRun", "stopOnAim" }) do if o[name] == nil then o[name] = true end end
    if o.duration == nil then o.duration = 500 end
    return o
end
function Base:isValidStart() return true end
function Base:isValid() return true end
function Base:waitToStart() return false end
function Base:start() end
function Base:update() end
function Base:stop() ISTimedActionQueue.getTimedActionQueue(self.character):resetQueue() end
function Base:perform() ISTimedActionQueue.getTimedActionQueue(self.character):onCompleted(self) end
function Base:forceCancel() end
function Base:forceStop() self.action.stopNow = true end
function Base:forceComplete() self.action.completeNow = true end
function Base:isStarted() return self.action and self.action.started end
function Base:canMergeAction() return false end
-- effect(): the changes, in the order a server sends them.
function Base:effect() return {} end
function Base:begin()
    self.action = { started = false, at = 0, table = self }
    local p = self.character
    p.actions.values = { self.action }
    -- The game tries to start at once, inside the call that queued it.
    if self:isValid() then Game.tryStart(p, self.action) end
end
function Game.tryStart(p, java)
    if java.table:waitToStart() ~= false then return end
    java.started, java.at = true, Game.now
    java.table:start()
    if Game.client and not java.stopNow then
        local action = java.table
        local finish = Game.now + Game.lag + action.duration + Game.lag
        local request = { due = finish, java = java }
        if Game.reject and Game.reject(action) then request.reject = true else request.changes = action end
        Game.server[#Game.server + 1] = request
    end
end
Game.server = {}

-- One engine frame: server messages first, then the player's action.
function Game.tick(ms)
    Game.now = Game.now + (ms or 100)
    local waiting = {}
    for _, request in ipairs(Game.server) do
        if request.java.gone and not request.sent then
            -- The player stopped it before the server finished.
        elseif request.due <= Game.now then
            if request.reject then request.java.rejected = true
            else
                for _, change in ipairs(request.changes:effect()) do change() end
                request.java.done = true
            end
        else waiting[#waiting + 1] = request end
    end
    Game.server = waiting
    if Game.onTick then Game.onTick() end
    local p = Game.player
    local java = p.actions:get(0)
    local halted = java and java.started and (p.moving and java.table.stopOnWalk or p.running and java.table.stopOnRun
        or p.aiming and java.table.stopOnAim)
    if halted then
        -- Walking, running and aiming stop the action, then drop whatever has started since.
        java.gone = true
        java.table:stop()
        p.actions.values = {}
        return
    end
    if java then
        local action = java.table
        local valid = action:isValid()
        if valid and not java.started then Game.tryStart(p, java)
        elseif valid and java.started then
            action:update()
            if Game.client then
                if java.done then java.completeNow = true elseif java.rejected then java.stopNow = true end
            elseif Game.now - java.at >= action.duration then java.completeNow = true end
        end
        if not valid or java.completeNow or java.stopNow then
            if java.completeNow then
                action:perform()
                if not Game.client then for _, change in ipairs(action:effect()) do change() end end
                java.gone = true
                p.actions:remove(java)
            else
                java.gone = true
                if java.started then action:stop() end
                p.actions:remove(java)
            end
        end
    end
end
function Game.run(flow, frames)
    for _ = 1, frames or 400 do
        ISTimedActionQueue.getTimedActionQueue(Game.player):tick()
        require("LootBox/Act").restore()
        flow:tick()
        if not flow:isBusy() then return flow end
        Game.tick(100)
    end
    error("The flow never ended: " .. tostring(flow.state))
end

-- Stock actions, as the game's sources define them --------------------------
local function carried(action) return Game.player.main:containsID(action.item.id) end

ISEatFoodAction = derive("ISEatFoodAction")
function ISEatFoodAction:new(player, item, percentage)
    return Base.create(self, player, { item = item, percentage = percentage, stopOnWalk = false, stopOnAim = false })
end
function ISEatFoodAction:isValidStart() return (self.character.eaten or 0) < 3 end
function ISEatFoodAction:isValid()
    if carried(self) then return true end
    if Game.client then self:forceComplete() end
    return false
end
function ISEatFoodAction:effect()
    local p, item = self.character, Game.player.main:getItemWithID(self.item.id)
    local share = math.min(1, (item.food.base or item.food.hunger) * self.percentage / item.food.hunger)
    local hunger, thirst = item.food.hunger * share, (item.food.thirst or 0) * share
    Game.consumed = (Game.consumed or 0) + 1
    local changes = {}
    local function needs() p.hunger, p.thirst = math.max(0, p.hunger - hunger), math.max(0, p.thirst - thirst) end
    changes[1] = function()
        item.food.hunger, item.food.thirst = item.food.hunger - hunger, (item.food.thirst or 0) - thirst
        if item.food.hunger < 0.0001 then Game.lift(item) end
    end
    if Game.needsLate then Game.lateNeeds = needs else changes[2] = needs end
    return changes
end

ISDrinkFluidAction = derive("ISDrinkFluidAction")
function ISDrinkFluidAction:new(player, target, percentage)
    local item = target.isWorldItem and target.item or target
    return Base.create(self, player, { item = item, fluidContainer = target:getFluidContainer(), percentage = percentage, stopOnWalk = false, stopOnAim = false })
end
function ISDrinkFluidAction:isValid() return not self.fluidContainer:isEmpty() and carried(self) end
function ISDrinkFluidAction:effect()
    local p, item = self.character, Game.player.main:getItemWithID(self.item.id)
    local fluid = item.fluid
    local litres = fluid.amount * self.percentage
    local relief = kinds[fluid.name].thirst * litres
    Game.consumed = (Game.consumed or 0) + 1
    return { function() fluid.amount = fluid.amount - litres; p.thirst = math.max(0, p.thirst - relief) end }
end

ISInventoryTransferAction = derive("ISInventoryTransferAction")
function ISInventoryTransferAction:new(player, item, from, to)
    return Base.create(self, player, { item = item, srcContainer = from, destContainer = to, duration = 300 })
end
function ISInventoryTransferAction:setAllowMissingItems() end
function ISInventoryTransferAction:effect()
    local item, from, to = self.srcContainer:getItemWithID(self.item.id), self.srcContainer, self.destContainer
    if not item then return {} end
    local arrival = Game.client and Game.replica(item) or item
    return { function()
        if item.world then
            Game.lift(item)
        else from:take(item) end
    end, function()
        if to.kind == "floor" then Game.lay(arrival, self.character:getCurrentSquare()) else to:put(arrival) end
    end }
end
ISInventoryTransferUtil = { newInventoryTransferAction = function(player, item, from, to) return ISInventoryTransferAction:new(player, item, from, to) end }

ISDropWorldItemAction = derive("ISDropWorldItemAction")
function ISDropWorldItemAction:new(player, item, sq, x, y, z, rotation)
    return Base.create(self, player, { item = item, sq = sq, pose = { x, y, z }, rotation = rotation, duration = 300 })
end
function ISDropWorldItemAction:effect()
    local item = Game.player.main:getItemWithID(self.item.id)
    local arrival = Game.client and Game.replica(item) or item
    return { function() Game.player.main:take(item) end, function() Game.lay(arrival, self.sq, self.pose) end }
end

ISFluidContainer = {}
function ISFluidContainer:new(fluid)
    return { getFluidObject = function() return fluid end, fluid = fluid, getOwner = function() return fluid.owner end }
end
ISFluidTransferAction = derive("ISFluidTransferAction")
function ISFluidTransferAction:new(player, from, a, to, b, amount)
    return Base.create(self, player, { from = a, into = b, amount = amount, duration = 600 })
end
function ISFluidTransferAction:isValid() return FluidContainer.CanTransfer(self.from, self.into) end
function ISFluidTransferAction:effect()
    local a, b, amount = self.from, self.into, self.amount
    if Game.pourFails then return {} end
    return { function() Game.transfer(a, b, amount) end }
end

-- Recipes: { name, makes = function(item) return new items, keeps = bool, output = type }
local recipes = {}
function Game.recipe(name, spec)
    local recipe = { name = name, spec = spec }
    function recipe:getName() return name end
    function recipe:isVanilla() return true end
    function recipe:getOutputCount() return spec.output and 1 or 0 end
    function recipe:canBeDoneInDark() return true end
    function recipe:getOutputs()
        if not spec.output then return list() end
        return list({ { getOutputMapper = function() return {
            getResultItems = function() return list({ Game.script(spec.output) }) end,
            getPatternForResult = function() return list({ Game.script(spec.input) }) end } end } })
    end
    local slot = { recipe = recipe, isKeep = function() return spec.keeps == true end, hasFlag = function(_, flag) return spec.keeps and flag == "Unseal" end }
    local tool = { tool = true }
    recipe.slot, recipe.tool = slot, tool
    function recipe:getInputs() return list({ tool, slot }) end
    recipes[name] = recipe
    return recipe
end
function getScriptManager() return { getCraftRecipe = function(_, name) return recipes[name] end } end
CraftRecipeManager = {
    getValidInputScriptForItem = function(recipe, item) return item.fullType == recipe.spec.input and recipe.slot or nil end,
    isItemValidForInputScript = function(slot, item)
        if slot.tool then return item.opener == true end
        return slot.recipe ~= nil and slot.recipe.spec.input == item.fullType
    end,
}
ISHandcraftAction = derive("ISHandcraftAction")
function ISHandcraftAction:new(player, recipe, item)
    return Base.create(self, player, { craftRecipe = recipe, item = item, manualInputs = { list({ item }) }, duration = 700, stopOnAim = false })
end
function ISHandcraftAction:effect()
    local p, item, spec = self.character, Game.player.main:getItemWithID(self.item.id), self.craftRecipe.spec
    if spec.keeps then
        local open = Game.client and Game.replica(item) or item
        return { function()
            if open ~= item then p.main:take(item); p.main:put(open) end
            open.sealed = nil
        end }
    end
    local changes = {}
    for _, made in ipairs(spec.makes(item)) do
        changes[#changes + 1] = function()
            -- The game drops the result when the player is overloaded.
            if Game.overloaded then Game.lay(made, p:getCurrentSquare()) else p.main:put(made) end
        end
    end
    changes[#changes + 1] = function() Game.lift(item) end
    return changes
end
HandcraftLogic = { new = function(player)
    local logic = { player = player }
    function logic:findCraftSurface() return nil end
    function logic:setContainers() end
    function logic:setRecipeFromContextClick(recipe, item) self.recipe, self.item = recipe, item end
    function logic:setManualSelectInputs() end
    function logic:clearManualInputs() end
    function logic:setManualInputsFor() return true end
    function logic:canPerformCurrentRecipe() return true end
    return logic
end }
ISHandcraftAction.FromLogic = function(logic) return ISHandcraftAction:new(logic.player, logic.recipe, logic.item) end

local function fetchFirst(player, item)
    if item.container ~= player.main then ISTimedActionQueue.add(ISInventoryTransferAction:new(player, item, item.container, player.main)) end
    return item.container
end
ISUnequipAction = derive("ISUnequipAction")
function ISUnequipAction:new(player, item) return Base.create(self, player, { item = item, duration = 300 }) end
function ISUnequipAction:effect() return { function() Game.player.mask, Game.player.maskOff = nil, self.item end } end
ISWearClothing = derive("ISWearClothing")
function ISWearClothing:new(player, item) return Base.create(self, player, { item = item, duration = 300 }) end
function ISWearClothing:effect() return { function() Game.player.mask, Game.player.maskOff = self.item, nil end } end
local function unmask()
    local mask = Game.player.mask
    if mask then ISTimedActionQueue.add(ISUnequipAction:new(Game.player, mask)) end
    return mask
end
ISInventoryPaneContextMenu = {
    getEatingMask = function(player) return player.mask end,
    OnNewCraft = function(item, recipe)
        fetchFirst(Game.player, item)
        ISTimedActionQueue.add(ISHandcraftAction:new(Game.player, recipe, item))
    end,
    eatItem = function(item, share)
        local from = fetchFirst(Game.player, item)
        local mask = unmask()
        ISTimedActionQueue.add(ISEatFoodAction:new(Game.player, item, share))
        if mask then ISTimedActionQueue.add(ISWearClothing:new(Game.player, mask)) end
        if from ~= Game.player.main then ISTimedActionQueue.add(ISInventoryTransferAction:new(Game.player, item, Game.player.main, from)) end
    end,
    onDrinkFluid = function(target, share)
        local item = target.isWorldItem and target.item or target
        local from = fetchFirst(Game.player, item)
        ISTimedActionQueue.add(ISDrinkFluidAction:new(Game.player, target, share))
        if from ~= Game.player.main then ISTimedActionQueue.add(ISInventoryTransferAction:new(Game.player, item, Game.player.main, from)) end
    end,
}

-- The water dispenser -------------------------------------------------------
local function standObject(name, square, facing)
    local o = { facing = facing, square = square }
    function o:getEntityScript() return { getName = function() return name end, getModule = function() return { getName = function() return "Base" end } end } end
    function o:getFacing() return self.facing end
    function o:getSquare() return self.square end
    function o:getFluidContainer() return self.fluid end
    function o:getObjectIndex() for i, v in ipairs(square.objects.values) do if v == self then return i - 1 end end return -1 end
    return o
end
function Game.dispenser(square, litres, facing, name)
    local o = standObject(litres and "WaterDispenser" or "WaterDispenserNoBottle", square, facing or "N")
    if litres then o.fluid = Game.fluid(o, 18.9, litres, name); o.fluid.locked = true end
    square.objects:add(o)
    return o
end
local BOTTLE = "Base.WaterDispenserBottle"
function Game.bottle(litres, name) return Game.item(BOTTLE, { name = "Dispenser bottle", litres = litres, capacity = 18.9, liquid = name }) end
function instanceItem() return Game.bottle(0) end
ISAddTakeDispenserBottle = derive("ISAddTakeDispenserBottle")
function ISAddTakeDispenserBottle:new(player, stand, bottle)
    return Base.create(self, player, { waterdispenser = stand, square = stand.square, bottle = bottle })
end
function ISAddTakeDispenserBottle:effect()
    local stand, square = self.waterdispenser, self.square
    local function gone() square.objects:remove(stand) end
    if not self.bottle then
        local jug = Game.bottle(0)
        jug.fluid:copyFluidsFrom(stand.fluid)
        return { function() Game.player.main:put(jug) end, gone, function() Game.dispenser(square, nil, stand.facing) end }
    end
    local bottle = Game.player.main:getItemWithID(self.bottle.id)
    local litres, name = bottle.fluid.amount, bottle.fluid.name
    return { gone, function() Game.dispenser(square, litres, stand.facing, name) end, function() Game.lift(bottle) end }
end
luautils = { walkAdj = function() return not Game.unreachable end, walkAdjObject = function() return not Game.unreachable end,
    getCorrectSquareForWall = function(_, s) return s end }

-- World fixtures -------------------------------------------------------------
function Game.fixture(square, litres, name)
    local o = { square = square, litres = litres, name = name or "Water", isFixture = true }
    function o:getSquare() return square end
    function o:getObjectIndex() return 0 end
    function o:getPrimaryFluid() return self.litres > 0 and kinds[self.name] or nil end
    function o:isTaintedWater() return false end
    function o:getFluidAmount() return self.litres end
    function o:getFluidCapacity() return 100 end
    function o:hasFluid() return self.litres > 0 end
    function o:canTransferFluidTo() return true end
    function o:canTransferFluidFrom() return true end
    function o:isFluidInputLocked() return false end
    function o:getUsesExternalWaterSource() return false end
    return o
end
ISTakeWaterAction = derive("ISTakeWaterAction")
function ISTakeWaterAction:new(player, item, object)
    return Base.create(self, player, { item = item, waterObject = object, waterUnit = math.min(item.fluid.capacity - item.fluid.amount, object.litres) })
end
function ISTakeWaterAction:isValid() return self.waterObject:hasFluid() and carried(self) end
function ISTakeWaterAction:effect()
    local item, object, litres = Game.player.main:getItemWithID(self.item.id), self.waterObject, self.waterUnit
    return { function() item.fluid.name = item.fluid.name or object.name; item.fluid.amount, object.litres = item.fluid.amount + litres, object.litres - litres end }
end
ISAddFluidFromItemAction = derive("ISAddFluidFromItemAction")
function ISAddFluidFromItemAction:new(player, item, object)
    return Base.create(self, player, { itemFrom = item, item = item, objectTo = object, addUnits = item.fluid.amount })
end
function ISAddFluidFromItemAction:effect()
    local item, object, litres = Game.player.main:getItemWithID(self.item.id), self.objectTo, self.addUnits
    return { function() item.fluid.amount, object.litres = item.fluid.amount - litres, object.litres + litres end }
end
ISWorldObjectContextMenu = { onTakeWater = function(_, object, _, item)
    local from = fetchFirst(Game.player, item)
    ISTimedActionQueue.add(ISTakeWaterAction:new(Game.player, item, object))
    ISTimedActionQueue.add(ISInventoryTransferAction:new(Game.player, item, Game.player.main, from))
end }

for _, name in ipairs({ "TimedActions/ISTimedActionQueue", "TimedActions/ISInventoryTransferUtil", "TimedActions/ISDropWorldItemAction",
    "TimedActions/ISAddTakeDispenserBottle", "Fluids/ISFluidTransferAction", "Entity/TimedActions/ISHandcraftAction" }) do
    package.loaded[name] = true
end

function Game.reset(client)
    for k in pairs(squares) do squares[k] = nil end
    ISTimedActionQueue.queues = {}
    Game.client, Game.server, Game.now = client == true, {}, Game.now + 60000
    Game.overloaded, Game.reject, Game.needsLate, Game.lateNeeds, Game.unreachable, Game.pourFails, Game.onTick, Game.consumed =
        nil, nil, nil, nil, nil, nil, nil, 0
    return Game.newPlayer()
end
-- Runs fn once when this many milliseconds have passed.
function Game.after(ms, fn)
    local due, previous = Game.now + ms, Game.onTick
    Game.onTick = function()
        if previous then previous() end
        if due and Game.now >= due then due = nil; fn() end
    end
end
return Game
