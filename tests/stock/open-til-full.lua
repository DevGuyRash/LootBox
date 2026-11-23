-- Optional: pinned stock Lua paths with Java/transport doubles; no game launched.
local game=assert(arg[1],"provide the installed Project Zomboid game directory")
local function stock(path) return assert(loadfile(game.."/media/lua/"..path))() end
local client,server=true,false
function isClient() return client end
function isServer() return server end
local serverCommand
Events={OnProcessAction={Add=function() end},OnServerCommand={Add=function(fn) serverCommand=fn end}}
DebugType={Lua={}};function log() end
ISBaseTimedAction={derive=function(self) return setmetatable({},{__index=self}) end,perform=function() end}
package.loaded["TimedActions/ISBaseTimedAction"]=true
stock("shared/Entity/TimedActions/ISHandcraftAction.lua")
stock("shared/ActionManager.lua")
stock("client/ServerCommands.lua")
assert(serverCommand)
local function list(items)
    return {add=function(_,v) items[#items+1]=v end,size=function() return #items end,get=function(_,i) return items[i+1] end}
end
ArrayList={new=function() return list({}) end}
ISInventoryPage={dirtyUI=function() end}
local function item(id,t)
    local data={}
    return {getID=function() return id end,getFullType=function() return t end,getModData=function() return data end}
end
local shell=item(10,"Base.CannedPeaches");local previous=item(11,"Base.CannedPeachesOpen");local actual=item(12,"Base.CannedPeachesOpen")
local inv={rows={previous,shell}}
function inv:contains(v) for _,i in ipairs(self.rows) do if i==v then return true end end return false end
function inv:getItemWithID(id) for _,i in ipairs(self.rows) do if i:getID()==id then return i end end end
function inv:AddItem(i) self.rows[#self.rows+1]=i end
function inv:getCapacityWeight() return 1 end
function inv:getEffectiveCapacity() return 10 end
local who={getInventory=function() return inv end}
function getPlayerByOnlineID(id) if id==7 then return who end end
local sync,bites,performed,createdCallback,retired,order={},{},0,0,0,{}
function sendAddItemToContainer(...)
    assert(inv:contains(shell),"stock adds its mapped output before retiring the selected input")
    order[#order+1]="add";sync[#sync+1]={...}
end
ISEatFoodAction={new=function(_,player,i,portion) return {who=player,item=i,portion=portion} end}
ISTimedActionQueue={add=function(a) bites[#bites+1]=a end}
local data={getAllConsumedItems=function() return list({shell}) end,luaCallOnCreate=function() createdCallback=createdCallback+1 end,
    processDestroyAndUsedItems=function()
        assert(inv:contains(actual) and inv.rows[2]==shell)
        table.remove(inv.rows,2);order[#order+1]="retire"
    end,setEatPercentage=function() error("plain Open set an eating amount") end}
local logic={getRecipeData=function() return data end,performCurrentRecipe=function() performed=performed+1;return true end,
    getCreatedOutputItems=function(_,out) out:add(actual) end}
local function action()
    return setmetatable({eatPercentage=0,character=who,logic=logic,clearItemsProgressBar=function() end,
        onCompleteFunc=function() retired=retired+1 end},{__index=ISHandcraftAction})
end
action():perform()
assert(performed==0 and #sync==0 and createdCallback==0 and retired==1)
client,server=false,true
assert(action():complete())
assert(performed==1 and createdCallback==1 and #sync==1 and #sync[1]==2 and sync[1][1]==inv and sync[1][2]==actual)
assert(table.concat(order,",")=="add,retire" and not inv:contains(shell) and inv:contains(previous))
assert(#bites==0 and actual:getModData()["Base.CannedPeaches"]==1)
client,server=true,false
serverCommand("recipe","openAndEat",{onlineID=7,itemId=12,eatPercentage=.25})
assert(#bites==1 and bites[1].who==who and bites[1].item==actual and bites[1].portion==.25)
serverCommand("recipe","openAndEat",{onlineID=7,itemId=99,eatPercentage=.5})
assert(#bites==1 and previous~=actual)
local function recipeFile(name)
    local file=assert(io.open(game.."/media/scripts/generated/recipes/"..name,"rb"))
    local text=file:read("*a");file:close();return text
end
local cans=recipeFile("recipes_cannedFood.txt")
local jars=recipeFile("recipes_jarring.txt")
for name,callback in pairs({OpenWaterRationCan="openWaterCan",OpenUnlabeledCan="openMysteryCan",OpenDentedUnlabeledCan="openDentedCan"}) do
    local block=assert(cans:match("craftRecipe "..name.."(%s*{.-)craftRecipe "))
    assert(block:find("OnCreate = RecipeCodeOnCreate."..callback,1,true))
    assert(block:match("outputs%s*{%s*}"),"callback-only result is not listed in handcraft's mapped outputs")
end
assert(jars:match("craftRecipe OpenJarOfFood%s*{.-RecipeCodeOnCreate%.applyLidCondition"))
assert(jars:find("Base.CannedTomato_Open = Base.CannedTomato",1,true))
local looks={}
function getPlayer() return who end
function getTexture(name) return name end
ModelKey={TIN_CAN_EMPTY="tin",MYSTERY_CAN_OPEN="mystery"}
function actual:setTexture(name) looks.texture=name end
function actual:setWorldStaticModel(name) looks.world=name end
function actual:setStaticModel(name) looks.static=name end
serverCommand("recipe","OpenMysteryCan",{itemId=12})
assert(looks.texture=="Item_CannedUnlabeled_Open" and looks.world=="tin" and looks.static=="mystery"
    and actual:getModData().NoLabel=="true")
serverCommand("recipe","OpenDentedCan",{itemId=12,modelName="base:dented"})
assert(looks.texture=="Item_CannedUnlabeled_Gross" and looks.static=="base:dented" and #bites==1)
print("PASS installed stock recipes, handcraft add-before-retire, and existing cosmetic output notices without a bite (Java/transport doubled)")
