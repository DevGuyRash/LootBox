package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local function list(...)
    local t = {...}
    function t:size() return #self end
    function t:get(i) return self[i+1] end
    function t:add(value) self[#self+1] = value end
    function t:contains(value) for _, entry in ipairs(self) do if entry == value then return true end end return false end
    return t
end

ArrayList = {new = list}
ResourceType = {Item = {}}
local realm = "sp"
function isClient() return realm == "client" end
function isServer() return realm == "server" end
local function fakeItem(id, fullType, owner, sealed, food)
    return {getID = function() return id end, getFullType = function() return fullType end,
        getContainer = function(self) return self.parent end, parent = owner, sealed = sealed,
        isSealed = function(self) return self.sealed end, isFavorite = function() return false end,
        getOpeningRecipe = function() return "OpenCannedFood" end,
        getScriptItem = function(self) return {isCantEat=function() return self.cantEat==true end} end,
        isRotten = function() return false end, isBurnt = function() return false end,
        isFrozen = function() return false end, isTainted = function() return false end,
        isPoison = function() return false end, getPoisonPower = function() return 0 end,
        getFoodSicknessChange = function() return 0 end, isAlcoholic = function() return false end,
        isbDangerousUncooked = function() return false end, food = food}
end
function instanceof(object, name) return name == "Food" and object.food == true end
package.loaded["LootBox/TillFull"] = {automaticEffects = function(item, kind)
    if kind == "food" and item.food and not item.sealed and not item.unsafe then return {hunger=.2, thirst=0} end
end}
local function recipe(name, toolType, cost)
    local toolSlot = {getResourceType=function() return ResourceType.Item end, match=function(i) return i:getFullType()==toolType end}
    local canSlot = {getResourceType=function() return ResourceType.Item end, match=function(i) return i:getFullType()=="Base.TinnedBeans" end}
    local inputs = list(toolSlot, canSlot)
    return {toolSlot=toolSlot,canSlot=canSlot, name=name, isVanilla=function(self) return not self.custom end,
        getName=function(self) return self.name end, getInputs=function() return inputs end,
        getOutputCount=function() return 1 end, getIndexForIO=function(_, slot) return slot==toolSlot and 0 or 1 end,
        getTime=function() return cost end, isInHandCraftCraft=function() return name=="OpenCannedFood" end,
        isAnySurfaceCraft=function() return name~="OpenCannedFood" end,
        getLuaCallString=function(_,which) return which end}
end
local safe = recipe("OpenCannedFood", "Base.CanOpener", 100)
local sharp = recipe("OpenCannedFoodWithKnifeOrSharpStoneFlake","Base.SharpedStone",80)
local recipes = {OpenCannedFood=safe, OpenCannedFoodWithKnifeOrSharpStoneFlake=sharp}
function getScriptManager() return {getCraftRecipe=function(_, name) return recipes[name] end} end
CraftRecipeManager = {isItemValidForInputScript = function(input, item) return input.match(item) end}
local main, other = {}, {}
function main:getItems() return self.items end
local function square(x,y,z,objects)
    return {getX=function() return x end, getY=function() return y end, getZ=function() return z end,
        getObjects=function() return objects end}
end
local here = square(500,500,0)
function here:isBlockedTo(_) return self.blocked == true end
local function bench(x,y,z)
    local object={}
    object.placed=true
    function object:getSquare() return square(x,y,z,self.placed and list(self) or list()) end
    return object
end
local adjacent, wrongFloor, far = bench(500,501,0), bench(500,501,1), bench(500,502,0)
local surface
local player = {getInventory=function() return main end, getCurrentSquare=function() return here end}
local can = fakeItem(1,"Base.TinnedBeans",main,true,true)
local opener = fakeItem(2,"Base.CanOpener",main,false)
local stone = fakeItem(3,"Base.SharpedStone",main,false)
local output = fakeItem(4,"Base.OpenBeans",main,false,true)
local foreign = fakeItem(5,"Base.CanOpener",other,false)
local canList, inputsSucceed, manualSucceed, substitute, extra, mutateAction
local counters = {}
HandcraftLogic = {new=function(character, bench, location)
    assert(character==player and bench==nil)
    local logic = {character=character,isoObject=location, manualInputs={}}
    function logic:findCraftSurface(who,radius) assert(who==player and radius==2); return surface end
    function logic:setContainers(items)
        assert(items:size()==1 and items:get(0)==main, "must never include an external container")
        self.containers=items
    end
    function logic:getContainers() return self.containers end
    function logic:getRecipe() return self.recipe end
    function logic:setRecipeFromContextClick(r, item) assert(item==can); self.recipe=r end
    function logic:setManualSelectInputs(enabled) assert(enabled); self.manual=true end
    function logic:clearManualInputs() self.manualInputs={} end
    function logic:setManualInputsFor(slot, values)
        assert(values:size()==1)
        local found=values:get(0)
        assert(found==can or found==opener or found==stone, "must never bind outdoor or unrelated supplies")
        self.manualInputs[self.recipe:getIndexForIO(slot)] = values
        return manualSucceed
    end
    function logic:canPerformCurrentRecipe() return inputsSucceed end
    function logic:getRecipeData()
        local found = self.manualInputs[0]:get(0)
        return {getAllInputItems=function()
            if extra then return list(can,found,foreign) end
            return list(can,substitute and foreign or found)
        end, getAllCreatedItems=function() return list(unpack(canList)) end}
    end
    return logic
end}
package.loaded["Entity/TimedActions/ISHandcraftAction"]=true
ISHandcraftAction = {FromLogic=function(logic, eat)
    counters.constructed = (counters.constructed or 0) + 1
    local action={Type="ISHandcraftAction", character=logic.character, logic=logic,
        craftRecipe=logic.recipe, containers=logic.containers,
        manualInputs=logic.manualInputs, items=logic:getRecipeData():getAllInputItems(),
        eatPercentage=eat, isoObject=logic.isoObject}
    if mutateAction then action.manualInputs[7]=list(foreign) end
    return action
end}
local selected = require "LootBox/NeedsOpening"
local opts, world, countersGuard = {autoConsumeCarried=true}, {}, 0
local protected = {}
local checks = {toolAccessible=function(item) return not protected[item] end}
local function guard() countersGuard=countersGuard+1; return true end
local function reset()
    opts.autoConsumeRiskyOpen=false; realm="sp"; safe.custom=false; surface=nil
    protected={}; can.parent=main; opener.parent=main; stone.parent=main
    can.sealed=true; can.cantEat=false; output.parent=main; output.unsafe=false
    main.items=list(can,opener,stone); canList={}
    inputsSucceed, manualSucceed, substitute, extra, mutateAction=true,true,false,false,false
    counters={}; countersGuard=0
end
local function plan()
    return selected.plan(player,opts,"food",world,can,checks)
end

reset()
local safePlan=assert(plan(), "normal carried can+opener should plan")
assert(safePlan.tool==opener and safePlan.item==can and safePlan.recipe==safe)
assert(selected.validate(player,opts,"food",world,can,safePlan,checks))
local action = assert(selected.action(player,safePlan,guard))
assert(action.manualInputs[0]:get(0)==opener and action.manualInputs[1]:get(0)==can)
assert(action.eatPercentage==0 and countersGuard>0)
assert(selected.ready(player,safePlan,action))
action.logic.containers=list(main,other)
assert(not selected.ready(player,safePlan,action), "reject broadened native start containers")
action.logic.containers=list(main)
substitute=true; assert(not selected.ready(player,safePlan,action), "reject native start substitutions")
substitute=false
assert(selected.output(player,safePlan,action)==nil, "nothing opened before craft completion")
can.parent=nil
main.items=list(opener,stone,output); canList={output}
assert(selected.output(player,safePlan,action)==output)
output.unsafe=true
assert(selected.output(player,safePlan,action)==nil)
output.unsafe=false
canList={output, fakeItem(6,"Base.OpenBeans",main,false,true)}
assert(selected.output(player,safePlan,action)==nil, "uncertain mapper result")
canList={output}; output.parent=other
assert(selected.output(player,safePlan,action)==nil, "native drop may not be consumed")
print("PASS exact owned opening action and unique safe native output")

reset(); opts.autoConsumeRiskyOpen=true
assert(assert(plan()).tool==opener, "injury recipe must never preempt safe opener")
main.items=list(can,stone); opts.autoConsumeRiskyOpen=false
assert(not plan(), "sharp stone is off by default")
main.items=list(can,foreign); opts.autoConsumeRiskyOpen=true
assert(not plan(), "do not use ground or foreign opener")
main.items=list(can,opener,stone); protected[opener]=true; opts.autoConsumeRiskyOpen=false
assert(not plan(), "respect protected tool")
reset(); realm="client"; assert(not plan(), "MP must not switch to unconfirmed mapper output")
reset(); safe.custom=true; assert(not plan(), "may not automatically run a recipe overriding the stock name")
reset(); can.parent=other; assert(not plan(), "nested, dangling, or ground cans do not reach this opening route")
print("PASS safer opener preference, tool protection, actual ownership and MP fail-closed")

reset(); local fresh = assert(plan())
protected[opener]=true
assert(not selected.validate(player,opts,"food",world,can,fresh,checks), "reevaluate exact tool immediately before dispatch")
protected[opener]=nil; opener.parent=other
assert(not selected.action(player,fresh,guard), "wrong tool source")
opener.parent=main
assert(not selected.action(player,fresh,function() return false end), "live movement/intent veto")
manualSucceed=false; assert(not selected.action(player,fresh,guard), "failed native exact bind")
manualSucceed=true; inputsSucceed=false; assert(not selected.action(player,fresh,guard), "native unavailable recipe")
inputsSucceed=true; substitute=true
assert(not selected.action(player,fresh,guard), "cannot use tool substitution from other source")
substitute=false; extra=true
assert(not selected.action(player,fresh,guard), "cannot let an unrelated third ingredient through")
extra=false; mutateAction=true
assert(not selected.action(player,fresh,guard), "serialized native inputs must also be exact")
print("PASS live gate and strict recipe/serialized inputs fail closed")

reset(); main.items=list(can,stone); opts.autoConsumeRiskyOpen=true
assert(not plan(), "native knife opening needs a surface")
surface=wrongFloor; assert(not plan(), "never walk to another floor")
surface=far; assert(not plan(), "never initiate a walk to a farther surface")
surface=adjacent; here.blocked=true
assert(not plan(), "reject an otherwise adjacent surface across a blocked edge")
here.blocked=false
local blade=assert(plan()); assert(blade.risky and blade.tool==stone)
local bladeAction=assert(selected.action(player,blade,guard))
assert(bladeAction.isoObject==adjacent and selected.ready(player,blade,bladeAction))
adjacent.placed=false
assert(not selected.ready(player,blade,bladeAction), "reject moved or removed native craft surface")
adjacent.placed=true
surface=nil; assert(not selected.action(player,blade,guard), "tool no longer has a viable surface")
opts.autoConsumeRiskyOpen=false; assert(not selected.validate(player,opts,"food",world,can,blade,checks))
print("PASS opted-in native knife route requires already-adjacent same-floor surface")

reset(); can.sealed=false; can.cantEat=true
assert(plan(), "native CantEat canned food is eligible even if generic isSealed is false")
can.cantEat=false
assert(not plan(), "recipe string alone cannot make an ordinary food eligible for opening")
print("PASS casing matches both native sealed and stock CantEat can representations")
