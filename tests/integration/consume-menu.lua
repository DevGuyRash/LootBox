-- Til Full rows on the game's own Eat, Drink and Open menus. The menus, items
for _, name in ipairs({ 'TimedActions/ISTimedActionQueue', 'TimedActions/ISInventoryTransferUtil' }) do package.loaded[name] = package.loaded[name] or true end
-- and recipes are doubles; ConsumeMenu and, where named, TillFull are real.
package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path
local Menu = {}
Menu.__index = Menu
function Menu:new() return setmetatable({ options = {} }, self) end
function Menu:addOption(name, target, action)
    local option = { name = name, target = target, onSelect = action }
    self.options[#self.options + 1] = option
    return option
end
local current
function getTimestampMs() return 1000 end
function isServer() return false end
function isClient() return false end
function instanceof(object, class) return type(object) == "table" and object.classes and object.classes[class] == true end
function getSpecificPlayer() return current.player end
function getText(key) return key end
ISInventoryPaneContextMenu = { addToolTip = function() return {} end }
CharacterStat = { HUNGER = { getMinimumValue = function() return 0 end }, THIRST = { getMinimumValue = function() return 0 end } }
package.loaded["LootBox/App"] = { get = function() return current.app end }
local TillFull = require "LootBox/TillFull"
local ConsumeMenu = require "LootBox/ConsumeMenu"
local realOffers = TillFull.offers
local function add(parent, items) return ConsumeMenu.add(0, parent, items, current.app, current.preferences) end
local function container(kind) return { kind = kind, getType = function(self) return self.kind end } end
local function item(source, kind)
    return { classes = { InventoryItem = true }, source = source,
        getContainer = function(self) return self.source end,
        getFullType = function() return kind or "Base.Apple" end,
        getName = function(self) return self.name or kind or "Apple" end }
end
local function fixture()
    local f = { preferences = {} }
    current = f
    f.inventory, f.crate = container("inventory"), container("crate")
    f.player = { getInventory = function() return f.inventory end }
    f.app = { world = {} }
    f.apple = item(f.inventory)
    TillFull.offers = function() return true end
    return f
end
local tests = 0
local function test(name, fn)
    fn(fixture())
    tests = tests + 1
    print("PASS " .. name)
end

test("Til Full binds native intent to one exact selected stack", function(f)
    local oldPane = ISInventoryPane
    local second, foreign, otherRow = item(f.inventory), item(f.crate), item(f.inventory)
    f.bandage = item(f.inventory, "Base.Bandage")
    local stack = {items = {f.apple, f.apple, second, foreign, f.bandage}}
    local selected = {stack, otherRow, f.bandage}
    ISInventoryPane = {getActualItems = function(items)
        local result = {}
        for _, row in ipairs(items or {}) do
            for _, actual in ipairs(row.items or {row}) do result[#result + 1] = actual end
        end
        return result
    end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    ISInventoryPaneContextMenu.onDrinkFluid = function() end
    f.preferences.tillFullEnabled = true
    f.app.tillFull = function(_, items, kind) f.consumed, f.consumeKind = items, kind; return true end
    for _, kind in ipairs({"food", "fluid"}) do
        local parent, child = Menu:new(), Menu:new()
        local root = parent:addOption("Localized native label", nil, nil)
        root.subOption = 37
        root.itemForTexture = f.apple
        parent.getSubMenu = function(_, id) assert(id == 37); return child end
        local callback = kind == "food" and ISInventoryPaneContextMenu.onEatItems or ISInventoryPaneContextMenu.onDrinkFluid
        local original = child:addOption("Localized fraction", kind == "food" and selected or f.apple, callback)
        add(parent, selected)
        assert(#child.options == 2 and child.options[1] == original and original.onSelect == callback)
        local added = child.options[2]
        assert(added.name == "Til Full" and added.itemForTexture == f.apple)
        assert(added.child == nil and added.subOption == nil)
        -- Later selection mutation cannot widen the captured stack.
        stack.items[#stack.items + 1] = otherRow
        added.onSelect(added.target)
        assert(f.consumeKind == kind and #f.consumed == 2 and f.consumed[1] == f.apple and f.consumed[2] == second)
        table.remove(stack.items)
        add(parent, selected)
        assert(#child.options == 2)
    end
    -- A foreign native submenu cannot authorize an unselected item.
    local parent, child = Menu:new(), Menu:new()
    local root = parent:addOption("Drink", foreign, nil); root.subOption = 1
    parent.getSubMenu = function() return child end
    child:addOption("All", foreign, ISInventoryPaneContextMenu.onDrinkFluid)
    add(parent, {f.apple})
    assert(#child.options == 1)
    ISInventoryPane = oldPane
end)

test("Til Full captures expanded selected children but never unselected peers", function(f)
    local oldPane = ISInventoryPane
    ISInventoryPane = {getActualItems = function(items) return items end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    f.preferences.tillFullEnabled = true
    f.app.tillFull = function(_, items) f.consumed = items; return true end
    local second, foreign, different = item(f.inventory), item(f.crate), item(f.inventory, "Base.Other")
    for _, selected in ipairs({{f.apple,second,foreign,different}, {f.apple}}) do
        local parent, child = Menu:new(), Menu:new()
        local root = parent:addOption("Eat", nil, nil); root.subOption = 1
        parent.getSubMenu = function() return child end
        child:addOption("All", selected, ISInventoryPaneContextMenu.onEatItems)
        add(parent, selected)
        local added = child.options[2]; assert(added)
        added.onSelect(added.target)
        local expected = #selected > 1 and 2 or 1
        assert(#f.consumed == expected and f.consumed[1] == f.apple)
        if expected == 2 then assert(f.consumed[2] == second) end
    end
    ISInventoryPane = oldPane
end)

test("Til Full refusal uses compact native feedback without another window", function(f)
    local oldPane, oldHalo = ISInventoryPane, HaloTextHelper
    ISInventoryPane = {getActualItems = function() return {f.apple} end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    f.preferences.tillFullEnabled = true
    f.app.tillFull = function() return nil, "Keep" end
    local message, recipient
    HaloTextHelper = {addBadText = function(player, text) recipient, message = player, text end}
    local parent, child = Menu:new(), Menu:new()
    local root = parent:addOption("Eat", nil, nil); root.subOption = 1
    parent.getSubMenu = function() return child end
    child:addOption("All", {}, ISInventoryPaneContextMenu.onEatItems)
    add(parent, {f.apple})
    local added = child.options[2]
    local ok, err = added.onSelect(added.target)
    assert(not ok and err == "Keep" and message == "Til Full: Keep" and recipient == getSpecificPlayer(0))
    assert(added.child == nil)
    HaloTextHelper = nil
    assert(not added.onSelect(added.target))
    ISInventoryPane, HaloTextHelper = oldPane, oldHalo
end)

test("Til Full respects disabled, unavailable and stale native opening recipes", function(f)
    local oldPane = ISInventoryPane
    ISInventoryPane = {getActualItems = function() return {f.apple} end}
    ISInventoryPaneContextMenu.onEatItems = function() end
    for _, mode in ipairs({"disabled", "parent", "child", "recipe", "foreign"}) do
        local parent, child = Menu:new(), Menu:new()
        local root = parent:addOption("Eat", nil, nil)
        root.subOption = 1
        parent.getSubMenu = function() return child end
        local original = child:addOption("All", {}, mode == "foreign" and function() end or ISInventoryPaneContextMenu.onEatItems)
        f.preferences.tillFullEnabled = mode ~= "disabled"
        root.notAvailable = mode == "parent"
        original.notAvailable = mode == "child"
        original.param3 = mode == "recipe" and {} or nil
        add(parent, {f.apple})
        assert(#child.options == 1, mode)
    end
    ISInventoryPane = oldPane
end)

test("Til Full follows a native Open and Eat or Drink recipe without relying on labels", function(f)
    local oldPane, oldManager, oldClient = ISInventoryPane, getScriptManager, isClient
    isClient=function() return false end
    local recipe = {}
    getScriptManager = function() return {getCraftRecipe=function(_,key) return key=="OpenMe" and recipe end} end
    ISInventoryPane = {getActualItems = function(selected) return selected end}
    ISInventoryPaneContextMenu.onEatItems, ISInventoryPaneContextMenu.onDrinkFluid = function() end, function() end
    f.apple.getOpeningRecipe = function() return "OpenMe" end
    f.preferences.tillFullEnabled = true
    f.app.tillFull = function(_,items,kind,opening)
        assert(#items == 1 and items[1] == f.apple and opening == recipe)
        f.consumeKind = kind;return true
    end
    for _, kind in ipairs({"food","fluid"}) do
        local parent, child = Menu:new(), Menu:new()
        local root = parent:addOption("Native localized name", nil, nil);root.subOption=7
        parent.getSubMenu = function() return child end
        local original
        if kind == "food" then original = child:addOption("1/4", {f.apple}, ISInventoryPaneContextMenu.onEatItems)
        else original = child:addOption("All", f.apple, ISInventoryPaneContextMenu.onDrinkFluid);original.param4=f.apple end
        original.param3 = recipe
        add(parent, {f.apple});add(parent, {f.apple})
        assert(#child.options==2 and child.options[1]==original and original.param3==recipe)
        local added=child.options[2];assert(added.name==(kind=="food" and "Open and Eat Til Full" or "Open and Drink Til Full") and added.itemForTexture==f.apple)
        assert(added.onSelect(added.target) and f.consumeKind==kind)
    end
    ISInventoryPane, getScriptManager, isClient = oldPane, oldManager, oldClient
end)

test("nearby loot Eat/Drink follows nested native rows and preserves exact clicked source", function(f)
    local oldPane, oldManager, oldClient = ISInventoryPane, getScriptManager, isClient
    ISInventoryPane = {getActualItems = function(rows)
        local out = {}
        for _, row in ipairs(rows) do
            if row.items then for n=2,#row.items do out[#out+1] = row.items[n] end
            else out[#out+1] = row end
        end
        return out
    end}
    local recipe = {}
    isClient = function() return false end
    getScriptManager = function() return {getCraftRecipe=function(_,key) return key=="OpenMe" and recipe end} end
    ISInventoryPaneContextMenu.onEatItems, ISInventoryPaneContextMenu.onDrinkFluid = function() end, function() end
    f.preferences.tillFullEnabled = true
    local picked, peer, decoy = item(f.crate), item(f.crate), item(f.inventory)
    picked.getOpeningRecipe = function() return "OpenMe" end
    local rows = {{items={picked,picked,peer}}, decoy}
    local originalSource = f.crate
    for _, kind in ipairs({"food", "fluid"}) do for _, closed in ipairs({false,true}) do
        local parent, group, amounts = Menu:new(), Menu:new(), Menu:new()
        local menus = {group, amounts}
        parent.getSubMenu = function(_,id) return menus[id] end
        local use = parent:addOption("Container actions",nil,nil);use.subOption=1
        local action=group:addOption("Localized native action",nil,nil);action.subOption=2
        local original = amounts:addOption("1/4", kind=="food" and rows or picked,
            kind=="food" and ISInventoryPaneContextMenu.onEatItems or ISInventoryPaneContextMenu.onDrinkFluid)
        original.param3=closed and recipe or nil
        original.param4=kind=="fluid" and picked or 25
        use.notAvailable=true
        add(parent, rows);assert(#amounts.options==1)
        use.notAvailable=false
        add(parent, rows);add(parent, rows)
        assert(#amounts.options==2 and amounts.options[1]==original)
        local added=amounts.options[2];assert(added.name==(closed and (kind=="food" and "Open and Eat Til Full" or "Open and Drink Til Full") or "Til Full"))
        local captured
        f.app.tillFull = function(_,items,actionKind,open,source)
            assert(#items==2 and items[1]==picked and items[2]==peer and actionKind==kind)
            assert(open==original.param3 and source==originalSource)
            captured=true;return true
        end
        picked.source=f.inventory -- menu never recaptures a moved item at click time
        assert(added.onSelect(added.target) and captured)
        picked.source=originalSource
    end end
    ISInventoryPane, getScriptManager, isClient = oldPane, oldManager, oldClient
end)

test("stock plain recipe rows retain the exact source for mapped MP opening and fall back for unknown producers",function(f)
    local oldPane,oldManager,oldCraft,oldFlags,oldMoodle,oldClient = ISInventoryPane,getScriptManager,CraftRecipeManager,InputFlag,MoodleType,isClient
    local oldResource=ResourceType
    local oldNew,oldEat = ISInventoryPaneContextMenu.OnNewCraft,ISInventoryPaneContextMenu.onEatItems
    ISInventoryPane={getActualItems=function(rows) return rows end}
    ISInventoryPaneContextMenu.OnNewCraft,ISInventoryPaneContextMenu.onEatItems=function() end,function() end
    InputFlag={IsSealed={},Unseal={}};MoodleType={FOOD_EATEN={}}
    ResourceType={Item={}}
    f.preferences.tillFullEnabled=true
    local drink={getName=function() return "OpenCanOfBeverage" end,isVanilla=function() return true end,getOutputCount=function() return 0 end}
    local food={getName=function() return "OpenCannedFood" end,isVanilla=function() return true end,getOutputCount=function() return 1 end}
    local unknown={getName=function() return "UnpackEverything" end,isVanilla=function() return true end,getOutputCount=function() return 1 end}
    local ration={getName=function() return "OpenWaterRationCan" end,isVanilla=function() return true end,getOutputCount=function() return 0 end}
    local jar={getName=function() return "OpenJarOfFood" end,isVanilla=function() return true end,getOutputCount=function() return 1 end}
    local registry={OpenCanOfBeverage=drink,OpenCannedFood=food,UnpackEverything=unknown,OpenWaterRationCan=ration,OpenJarOfFood=jar}
    local catalog={}
    getScriptManager=function() return {getCraftRecipe=function(_,n) return registry[n] end,getItem=function(_,n) return catalog[n] end} end
    local mealLevel=0;f.player.getMoodles=function() return {getMoodleLevel=function() return mealLevel end} end
    for _,name in ipairs({"CannedPeaches","CannedMilk","CannedFruitBeverage","Pop","WaterRationCan","CannedTomato"}) do
        for _,mode in ipairs({"plain","amount-and-plain","multiplayer","unmapped-mp","unknown","disabled","full","not-selected","wrong-player"}) do
            isClient=function() return mode=="multiplayer" or mode=="unmapped-mp" end
            local source = name=="Pop" and f.inventory or f.crate
            local chosen,decoy=item(source),item(source)
            local r=mode=="unknown" and unknown or (name=="Pop" and drink or name=="WaterRationCan" and ration
                or name=="CannedTomato" and jar or food)
            chosen.classes.Food=name~="Pop"
            chosen.getFullType=function() return "Base."..name end;decoy.getFullType=chosen.getFullType
            chosen.getOpeningRecipe=function()
                return (name=="CannedMilk" or name=="CannedPeaches") and "OpenCannedFood" or nil
            end
            chosen.isSealed=function() return name=="Pop" end
            chosen.getFluidContainer=function()
                if name=="Pop" then return {isEmpty=function() return false end,getCapacity=function() return .3 end,
                    getProperties=function() return {getHungerChange=function() return -.05 end} end} end
            end
            local slot={isKeep=function() return name=="Pop" end,
                hasFlag=function(_,k) return name=="Pop" and (k==InputFlag.IsSealed or k==InputFlag.Unseal) end,
                getResourceType=function() return ResourceType.Item end,getAmount=function() return 1 end}
            CraftRecipeManager={getValidInputScriptForItem=function(recipe,selected,player)
                assert(selected==chosen and player==f.player)
                return slot
            end}
            local function pack(value) return {size=function() return 1 end,get=function() return value end} end
            local closed={}
            chosen.getScriptItem=function() return closed end
            local opened={getFullName=function() return "Base."..name.."Open" end,
                getActualWeight=function() return .25 end,isCantEat=function() return false end}
            catalog["Base.WaterRationCanEmpty"]=mode~="unmapped-mp" and {getFullName=function() return "Base.WaterRationCanEmpty" end,
                getActualWeight=function() return .2 end} or nil
            catalog["Base.JarLid"]={getFullName=function() return "Base.JarLid" end,
                getActualWeight=function() return .1 end,getConditionMax=function() return 10 end}
            local mapper={getResultItems=function() return pack(opened) end,
                getPatternForResult=function() return pack(closed) end}
            local out={getAmount=function() return 1 end,getResourceType=function() return ResourceType.Item end,
                getOutputMapper=function() if mode~="unmapped-mp" then return mapper end end}
            for _,route in ipairs({food,jar,ration}) do
                route.getInputs=function() return pack(slot) end
                route.getIndexForIO=function() return 1 end
                route.isInHandCraftCraft=function() return true end
            end
            food.getOutputs=function() return pack(out) end
            jar.getOutputs=food.getOutputs
            ration.getOutputs=function() return {size=function() return 0 end} end
            mealLevel=mode=="full" and 3 or 0
            local parent,recipes,amounts=Menu:new(),Menu:new(),Menu:new()
            parent.getSubMenu=function(_,id) return id==1 and recipes or amounts end
            parent:addOption("Localized cooking",nil,nil).subOption=1
            local standard=recipes:addOption("Localized Open",chosen,ISInventoryPaneContextMenu.OnNewCraft)
            standard.param1,standard.param2,standard.param3=r,mode=="wrong-player" and 1 or 0,false
            standard.notAvailable=mode=="disabled"
            local both=mode=="amount-and-plain" and chosen:getOpeningRecipe()~=nil
            if both then
                parent:addOption("Localized Open & Eat",nil,nil).subOption=2
                local row=amounts:addOption("All",{chosen},ISInventoryPaneContextMenu.onEatItems)
                row.param3=r
            end
            local rows=mode=="not-selected" and {decoy} or {chosen}
            add(parent, rows);add(parent, rows)
            assert(recipes.options[1]==standard and standard.onSelect==ISInventoryPaneContextMenu.OnNewCraft)
            local supported=mode=="plain" or mode=="multiplayer" or mode=="unmapped-mp" or mode=="amount-and-plain"
            assert(#recipes.options==(supported and not both and 2 or 1),name..":"..mode)
            assert(#amounts.options==(both and 2 or 0))
            if supported then
                local added=both and amounts.options[2] or recipes.options[2]
                local drinkIntent=name~="CannedPeaches" and name~="CannedTomato"
                assert(added.name==(drinkIntent and "Open and Drink Til Full" or "Open and Eat Til Full"))
                f.app.tillFull=function(_,list,kind,recipe,container)
                    assert(#list==1 and list[1]==chosen and recipe==r and container==source)
                    assert(kind==((name=="Pop" or name=="WaterRationCan") and "fluid" or (drinkIntent and "drinkFood" or "food")));return true
                end
                assert(added.onSelect(added.target))
            end
        end
    end
    ISInventoryPane,getScriptManager,CraftRecipeManager,InputFlag,MoodleType,isClient=oldPane,oldManager,oldCraft,oldFlags,oldMoodle,oldClient
    ResourceType=oldResource
    ISInventoryPaneContextMenu.OnNewCraft,ISInventoryPaneContextMenu.onEatItems=oldNew,oldEat
end)
test("opened stock Food drinks retain the Food callback while selecting thirst even from the loot pane",function(f)
    local prev=ISInventoryPane;ISInventoryPane={getActualItems=function(rows) return rows end}
    ISInventoryPaneContextMenu.onEatItems=function() end
    local opened=item(f.crate);opened.getCustomMenuOption=function() return getText("ContextMenu_Drink") end
    local parent,amount=Menu:new(),Menu:new();parent.getSubMenu=function() return amount end
    parent:addOption("Localized stock Drink",nil,nil).subOption=1
    local row=amount:addOption("All",{opened},ISInventoryPaneContextMenu.onEatItems)
    f.preferences.tillFullEnabled=true;add(parent, {opened});add(parent, {opened})
    assert(#amount.options==2 and amount.options[1]==row and amount.options[2].name=="Til Full")
    f.app.tillFull=function(_,list,kind,recipe,source)
        assert(#list==1 and list[1]==opened and kind=="drinkFood" and not recipe and source==f.crate);return true
    end
    assert(amount.options[2].onSelect(amount.options[2].target));ISInventoryPane=prev
end)
test("native ground Drink binds its real world wrapper only to the selected floor item", function(f)
    local oldPane = ISInventoryPane
    ISInventoryPane = {getActualItems = function(rows) return rows end}
    ISInventoryPaneContextMenu.onDrinkFluid = function() end
    f.preferences.tillFullEnabled=true
    local floor = container("floor",false)
    local chosen,other = item(floor),item(floor)
    local function world(value)
        return {classes={IsoWorldInventoryObject=true},getItem=function() return value end}
    end
    local owner,foreign = world(chosen),world(other)
    f.app.tillFull = function(_,items,kind,recipe,source)
        assert(kind=="fluid" and not recipe and source==floor and #items==1 and items[1]==chosen)
        f.groundConsumed = true;return true
    end
    for _, mode in ipairs({"pane","world","foreign","mismatch","stale"}) do
        local parent,amounts=Menu:new(),Menu:new()
        parent.getSubMenu=function() return amounts end
        local root=parent:addOption("Drink",nil,nil);root.subOption=1
        local native=amounts:addOption("All",mode=="foreign" and foreign or owner, ISInventoryPaneContextMenu.onDrinkFluid)
        native.param4=mode=="mismatch" and other or (mode=="foreign" and other or chosen)
        if mode=="stale" then chosen.source=nil end
        if mode=="pane" then add(parent, {chosen})
        else add(parent,{owner}) end
        local added=amounts.options[2]
        if mode=="pane" or mode=="world" then
            f.groundConsumed=false
            assert(added and added.onSelect(added.target) and f.groundConsumed)
        else assert(not added) end
    end
    ISInventoryPane=oldPane
end)

-- From here on the real TillFull decides.
local function amounts(f, anchor, kind)
    local parent, child = Menu:new(), Menu:new()
    parent:addOption(kind == "food" and "Eat" or "Drink").subOption = 1
    parent.getSubMenu = function() return child end
    if kind == "food" then child:addOption("All", {anchor}, ISInventoryPaneContextMenu.onEatItems)
    else child:addOption("All", anchor, ISInventoryPaneContextMenu.onDrinkFluid) end
    return parent, child
end
local function meal(f)
    ISInventoryPane = { getActualItems = function(rows) return rows end }
    ISInventoryPaneContextMenu.onEatItems, ISInventoryPaneContextMenu.onDrinkFluid = function() end, function() end
    f.preferences = { tillFullEnabled = true }
    f.hunger, f.thirst = .4, 0
    f.player.getStats = function() return { get = function(_, stat) return stat == CharacterStat.HUNGER and f.hunger or f.thirst end } end
    f.app.world = {
        consumptionSource = function(_, food, source) return not f.unreachable and food.source == source, "The selected source is not reachable" end,
        protected = function(_, food, options)
            if food.kept then return true, "Keep" end
            if food.favorite and not options.allowFavorite then return true, "Favorite" end
            return false
        end }
    f.app.tillFull = function(_, items, kind, recipe, source)
        f.started = { items = items, kind = kind, recipe = recipe, source = source }
        return true
    end
    local apple = f.apple
    apple.classes.Food = true
    apple.relief, apple.quench = .2, .05
    apple.getID = function() return 7 end
    for _, name in ipairs({"isSealed", "isRotten", "isBurnt", "isFrozen", "isTainted", "isPoison", "isAlcoholic", "isbDangerousUncooked"}) do
        apple[name] = function(self) return self[name] == name end
    end
    apple.isRotten = function(self) return self.rotten == true end
    apple.getPoisonPower = function() return 0 end
    apple.getFoodSicknessChange = function() return 0 end
    apple.getHungerChange = function(self) return -self.relief end
    apple.getThirstChange = function(self) return -self.quench end
    apple.getScriptItem = function() return { isCantEat = function() return false end } end
    apple.getRequireInHandOrInventory = function() end
    local held = { getItems = function() return { size = function() return 0 end } end }
    f.player.getInventory = function() return held end
    f.player.getCurrentSquare = function() end
    apple.source.getItemWithID = function(_, id) return id == 7 and apple or nil end
    TillFull.offers = realOffers
    return apple
end

test("the row appears exactly when eating would do something", function(f)
    local apple = meal(f)
    local function rows()
        local parent, child = amounts(f, apple, "food")
        local added = add(parent, {apple})
        assert(added == (#child.options == 2))
        return child.options[2]
    end
    local row = assert(rows())
    assert(row.name == "Til Full" and not row.notAvailable and row.onSelect(row.target))
    assert(f.started.kind == "food" and f.started.items[1] == apple and f.started.source == f.inventory and f.started.items.interaction)
    apple.favorite = true; assert(rows(), "eating a favorite by hand is allowed"); apple.favorite = nil
    f.hunger = 0; assert(not rows(), "no hunger, nothing to fill"); f.hunger = .4
    f.hunger, f.thirst = 0, .5; assert(not rows(), "thirst is not hunger")
    f.preferences.tillFullBothNeeds = true; assert(rows(), "unless both needs were asked for")
    f.preferences.tillFullBothNeeds, f.hunger, f.thirst = nil, .4, 0
    apple.rotten = true; assert(not rows()); apple.rotten = nil
    apple.kept = true; assert(not rows()); apple.kept = nil
    f.unreachable = true; assert(not rows()); f.unreachable = nil
    apple.relief = 0; assert(not rows(), "it feeds nobody"); apple.relief = .2
    assert(rows())
end)

test("Drink follows thirst and the vessel, and errors show no row but are reported", function(f)
    local apple = meal(f)
    apple.classes.Food = nil
    local empty, capacity = false, 1
    local water = { isCategory = function(_, category) return category == "water" end, isPoisonous = function() return false end,
        getProperties = function() return { getPoison = function() return 0 end, getAlcohol = function() return 0 end,
            getFoodSicknessChange = function() return 0 end } end }
    FluidCategory = { Beverage = "beverage", Water = "water", Hazardous = "hazardous", Alcoholic = "alcoholic" }
    local properties = { getAlcohol = function() return 0 end, getPoison = function() return 0 end, getFoodSicknessChange = function() return 0 end,
        getHungerChange = function() return 0 end, getThirstChange = function() return -.5 end }
    local fluid = { getProperties = function() return properties end, isEmpty = function() return empty end, canPlayerEmpty = function() return true end,
        isPoisonous = function() return false end, isTainted = function() return false end, getCapacity = function() return capacity end,
        createFluidSample = function() return { size = function() return 1 end, getPercentage = function() return 1 end,
            getFluid = function() return water end, release = function() end } end }
    apple.getFluidContainer = function() return fluid end
    local function rows()
        local parent, child = amounts(f, apple, "fluid")
        add(parent, {apple})
        return child.options[2]
    end
    assert(not rows(), "not thirsty")
    f.thirst = .3
    local row = assert(rows())
    assert(row.onSelect(row.target) and f.started.kind == "fluid")
    empty = true; assert(not rows()); empty = false
    capacity = 10; assert(not rows(), "a bucket is not a drinking vessel"); capacity = 1
    local Log, fault = require "LootBox/Log", nil
    local saved = Log.fault
    Log.fault = function(_, site) fault = site end
    fluid.getProperties = nil
    assert(not rows())
    Log.fault = saved
    assert(fault == "TillFull.offers")
end)
print("PASS " .. tests .. " consume menu scenarios")
