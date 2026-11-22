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
local inv={rows={previous}}
function inv:contains(v) for _,i in ipairs(self.rows) do if i==v then return true end end return false end
function inv:getItemWithID(id) for _,i in ipairs(self.rows) do if i:getID()==id then return i end end end
function inv:AddItem(i) self.rows[#self.rows+1]=i end
function inv:getCapacityWeight() return 1 end
function inv:getEffectiveCapacity() return 10 end
local who={getInventory=function() return inv end}
function getPlayerByOnlineID(id) if id==7 then return who end end
local sync,bites,performed,createdCallback,retired={},{},0,0,0
function sendAddItemToContainer(...) sync[#sync+1]={...} end
ISEatFoodAction={new=function(_,player,i,portion) return {who=player,item=i,portion=portion} end}
ISTimedActionQueue={add=function(a) bites[#bites+1]=a end}
local data={getAllConsumedItems=function() return list({shell}) end,luaCallOnCreate=function() createdCallback=createdCallback+1 end,
    processDestroyAndUsedItems=function() end,setEatPercentage=function() error("plain Open set an eating amount") end}
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
assert(#bites==0 and actual:getModData()["Base.CannedPeaches"]==1)
client,server=true,false
serverCommand("recipe","openAndEat",{onlineID=7,itemId=12,eatPercentage=.25})
assert(#bites==1 and bites[1].who==who and bites[1].item==actual and bites[1].portion==.25)
serverCommand("recipe","openAndEat",{onlineID=7,itemId=99,eatPercentage=.5})
assert(#bites==1 and previous~=actual)
print("PASS installed ISHandcraftAction client/server split, ordinary inventory sync, immediate fixed-portion stock reply (Java/transport doubled)")
