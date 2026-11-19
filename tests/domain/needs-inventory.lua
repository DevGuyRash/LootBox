package.path = "Contents/mods/LootBox/42/media/lua/client/?.lua;" .. package.path

local sampled = 0
package.loaded["LootBox/TillFull"] = {automaticEffects = function(item, kind, opening)
    assert(not opening)
    sampled = sampled + 1
    if item.kind == kind and not item.unsafe then return {hunger=0.2, thirst=0.2} end
end}
local Open = {}
function Open.plan(_, options, kind, _, item, callbacks)
    if item.kind ~= kind or (not item.sealed and not item.cantEat) or not item.openingTool
        or not callbacks.toolAccessible(item.openingTool) or item.risky and not options.autoConsumeRiskyOpen then return nil end
    return {item=item, kind=kind, tool=item.openingTool, risky=item.risky}
end
function Open.validate(player, options, kind, world, item, plan, callbacks)
    local fresh = Open.plan(player, options, kind, world, item, callbacks)
    return fresh ~= nil and fresh.tool == plan.tool and fresh.risky == plan.risky
end
package.loaded["LootBox/NeedsOpening"] = Open
local Inventory = require "LootBox/NeedsInventory"

local function list(items)
    return {size=function() return #items end, get=function(_, i) return items[i + 1] end}
end

local function container(bag)
    local c = {items={}, bag=bag}
    function c:getItems()
        local items = list(self.items)
        function items:contains(item)
            for _, value in ipairs(c.items) do if value == item then return true end end
            return false
        end
        return items
    end
    function c:getContainingItem() return self.bag end
    function c:isLockedToCharacter() return self.lock == true end
    return c
end

local function item(c, kind)
    local i = {source=c, kind=kind}
    function i:getContainer() return self.source end
    function i:isFavorite() return self.favorite == true end
    function i:isSealed() return self.sealed == true end
    function i:getFluidContainer() return self.kind == "fluid" and {} or nil end
    function i:getInventory() return self.contents end
    function i:getOpeningRecipe() return self.openingTool and "OpenKnownFood" end
    if c then c.items[#c.items+1] = i end
    return i
end

local function fixture()
    local p = {main=container(), attached={}, worn={}}
    function p:getInventory() return self.main end
    function p:getPrimaryHandItem() return self.primary end
    function p:getSecondaryHandItem() return self.secondary end
    function p:isAttachedItem(i) return self.attached[i] == true end
    function p:isEquippedClothing(i) return self.worn[i] == true end
    local world={}
    function world:protected(i, flags)
        if i.keep then return true, "Keep" end
        if i.recovery then return true, "Personal gear reserved for recovery" end
        if i.favorite then return true, "Favorite" end
        if not (flags and flags.allowEquippedConsumption) then
            if p.worn[i] or p.attached[i] or p.primary == i or p.secondary == i then return true, "Equipped" end
        end
        if i.contents then return true, "Bag contains items" end
        return false
    end
    function world:consumptionSource() error("Auto self-care touched the world") end
    return p, world
end

local function bag(c)
    local b = item(c)
    b.contents = container(b)
    return b
end

local count = 0
local function test(name, run)
    run()
    count = count + 1
    print("ok " .. name)
end

test("all defaults off, nested and risky toggles do not enable parent", function()
    local p,w=fixture()
    local f=item(p.main,"food")
    local options={autoConsumeNested=true,autoConsumeRiskyOpen=true}
    assert(Inventory.select(p,options,"food",w)==nil)
    assert(not Inventory.eligible(p,options,"food",w,f))
    assert(Inventory.select(p,{autoConsumeCarried=true},"food",nil)==nil)
end)

test("only actual equipped vessel with a fluid component gets equipped priority", function()
    local p,w=fixture()
    local spare=item(p.main,"fluid")
    spare.fakeAttachedSlot=1
    local dried=item(p.main,"fluid")
    function dried:getFluidContainer() return nil end
    p.attached[dried]=true
    local worn=item(p.main,"fluid");p.worn[worn]=true
    local heldFood=item(p.main,"food");p.primary=heldFood
    local options={autoDrinkEquipped=true,autoConsumeCarried=true}
    assert(Inventory.select(p,options,"fluid",w)==worn)
    assert(Inventory.select(p,{autoDrinkEquipped=true},"food",w)==nil)
    assert(Inventory.select(p,{autoConsumeCarried=true},"fluid",w)==spare)
    assert(not Inventory.eligible(p,{autoDrinkEquipped=true},"fluid",w,spare))
    p.worn[worn]=nil
    assert(not Inventory.eligible(p,{autoDrinkEquipped=true},"fluid",w,worn))
    p.secondary=worn
    assert(Inventory.eligible(p,{autoDrinkEquipped=true},"fluid",w,worn))
end)

test("generic first-level bags work; nested is a subordinate explicit opt-in", function()
    local p,w=fixture()
    local b=bag(p.main);p.worn[b]=true
    local f=item(b.contents,"food")
    local inner=bag(b.contents)
    local drink=item(inner.contents,"fluid")
    local opts={autoConsumeCarried=true}
    assert(Inventory.select(p,opts,"food",w)==f)
    assert(Inventory.select(p,opts,"fluid",w)==nil)
    opts.autoConsumeNested=true
    assert(Inventory.select(p,opts,"fluid",w)==drink)
    b.favorite=true
    assert(Inventory.select(p,opts,"food",w)==nil and not Inventory.eligible(p,opts,"fluid",w,drink))
    b.favorite=false;b.keep=true
    assert(not Inventory.eligible(p,opts,"fluid",w,drink))
    b.keep=false;inner.recovery=true
    assert(not Inventory.eligible(p,opts,"fluid",w,drink))
end)

test("unsafe, protected, stale, external, locked and excluded items never qualify", function()
    local p,w=fixture()
    local external=container()
    local other=item(external,"fluid");p.attached[other]=true
    local a=item(p.main,"fluid");a.unsafe=true
    local b=item(p.main,"fluid");b.favorite=true
    local c=item(p.main,"fluid");c.keep=true
    local d=item(p.main,"fluid");d.recovery=true
    local e=item(p.main,"fluid");p.main.items[#p.main.items]=nil;p.worn[e]=true
    local f=item(p.main,"fluid");f.source=external;p.secondary=f
    local pack=bag(p.main);pack.contents.lock=true
    local locked=item(pack.contents,"fluid")
    local g=item(p.main,"fluid")
    local opts={autoDrinkEquipped=true,autoConsumeCarried=true,autoConsumeNested=true}
    for _, invalid in ipairs({other,a,b,c,d,e,f,locked}) do
        assert(not Inventory.eligible(p,opts,"fluid",w,invalid))
    end
    assert(Inventory.select(p,opts,"fluid",w)==g)
    assert(Inventory.select(p,opts,"fluid",w,{[g]=true})==nil)
    g.source=external
    assert(not Inventory.eligible(p,opts,"fluid",w,g))
end)

test("bag back-reference, cycles and item budget fail closed", function()
    local p,w=fixture()
    local b=bag(p.main)
    local f=item(b.contents,"food")
    b.contents.bag=nil
    local opts={autoConsumeCarried=true,autoConsumeNested=true}
    assert(not Inventory.eligible(p,opts,"food",w,f))
    b.contents=p.main;p.main.bag=b
    for _=1,1024 do item(p.main,"food").unsafe=true end
    local late=item(p.main,"food")
    assert(not Inventory.select(p,opts,"food",w))
    assert(Inventory.eligible(p,opts,"food",w,late), "explicit validation need not repeat discovery")
end)

test("live guard checks the exact path without sampling contents", function()
    local p,w=fixture()
    local outer=bag(p.main)
    local inner=bag(outer.contents)
    local drink=item(inner.contents,"fluid")
    local opts={autoConsumeCarried=true,autoConsumeNested=true}
    local before=sampled
    assert(Inventory.accessible(p,opts,"fluid",w,drink))
    assert(Inventory.sourceAccessible(p,opts,w,inner.contents))
    assert(not Inventory.sourceAccessible(p,{autoConsumeCarried=true},w,inner.contents))
    assert(Inventory.sourceAccessible(p,{autoDrinkEquipped=true},w,p.main))
    assert(sampled==before)
    drink.unsafe=true
    assert(Inventory.accessible(p,opts,"fluid",w,drink))
    assert(not Inventory.eligible(p,opts,"fluid",w,drink))
    assert(sampled==before+1)
    outer.source=container()
    assert(not Inventory.accessible(p,opts,"fluid",w,drink))
    assert(not Inventory.sourceAccessible(p,opts,w,inner.contents))
    assert(sampled==before+1)
end)

test("sealed routes stay closed without a carried-only native opening proof", function()
    local p,w=fixture()
    local sealed=item(p.main,"food");sealed.sealed=true
    local wet=item(p.main,"fluid");wet.sealed=true;p.attached[wet]=true
    local opts={autoConsumeCarried=true,autoDrinkEquipped=true,autoConsumeRiskyOpen=true}
    assert(not Inventory.eligible(p,opts,"food",w,sealed,{}))
    assert(not Inventory.select(p,opts,"food",w) and not Inventory.select(p,opts,"fluid",w))
end)
test("opening is a fallback, requires an exact carried tool, and prefers normal over risky", function()
    local p,w=fixture()
    for _=1,30 do item(p.main,"unrelated") end
    local risky,safe=item(p.main,"food"),item(p.main,"food")
    risky.sealed,risky.risky=true,true
    safe.cantEat,safe.unsafe=true,true
    risky.openingTool,safe.openingTool=item(p.main,"blade"),item(p.main,"opener")
    local n=bag(p.main)
    local unsealed=item(n.contents,"food")
    local opts={autoConsumeCarried=true,autoConsumeRiskyOpen=true}
    assert(Inventory.select(p,opts,"food",w)==unsealed)
    unsealed.unsafe=true
    local chosen, plan=Inventory.select(p,opts,"food",w)
    assert(chosen==safe and plan.tool==safe.openingTool)
    local riskTool=risky.openingTool
    safe.openingTool.keep=true
    assert(not Inventory.accessible(p,opts,"food",w,safe,plan))
    assert(not Inventory.eligible(p,opts,"food",w,safe,plan))
    chosen,plan=Inventory.select(p,opts,"food",w)
    assert(chosen==risky and plan.tool==riskTool and plan.risky)
    opts.autoConsumeRiskyOpen=false
    assert(not Inventory.accessible(p,opts,"food",w,risky,plan))
    assert(Inventory.select(p,opts,"food",w)==nil)
    opts.autoConsumeRiskyOpen=true
    riskTool.source=container()
    assert(Inventory.select(p,opts,"food",w)==nil)
end)
test("exact attached hydration bag uses its own fluid without admitting its pouch contents", function()
    local p,w=fixture()
    p.isAttachedItem=nil
    function p:getAttachedItems()
        return {contains=function(_, item) return p.attached[item] == true end}
    end
    local pack=bag(p.main)
    local bottled=item(pack.contents,"fluid")
    p.attached[pack]=true
    local opts={autoDrinkEquipped=true}
    assert(Inventory.select(p,opts,"fluid",w)==nil)
    assert(not Inventory.accessible(p,opts,"fluid",w,bottled))
    local ownFluid={}
    pack.kind="fluid"
    function pack:getFluidContainer() return ownFluid end
    assert(Inventory.select(p,opts,"fluid",w)==pack)
    assert(Inventory.eligible(p,opts,"fluid",w,pack))
    for _, field in ipairs({"favorite","keep","recovery"}) do
        pack[field]=true
        assert(not Inventory.eligible(p,opts,"fluid",w,pack))
        pack[field]=nil
    end
    assert(not Inventory.eligible(p,{autoConsumeCarried=true},"fluid",w,pack))
    ownFluid=pack.contents
    assert(not Inventory.eligible(p,opts,"fluid",w,pack))
    ownFluid={}
    p.attached[pack]=nil
    assert(not Inventory.eligible(p,opts,"fluid",w,pack))
end)

print("PASS " .. count .. " NeedsInventory scenarios")

test("after MP opening a fresh selection considers only ready food, never even calls a crafting planner",function()
    local p,w=fixture();local opts={autoConsumeCarried=true,autoConsumeNested=true,autoConsumeRiskyOpen=true}
    local can=item(p.main,"food");can.sealed=true;can.openingTool=item(p.main)
    assert(Inventory.select(p,opts,"food",w)==can)
    local old=Open.plan;local planned=0
    Open.plan=function(...) planned=planned+1;return old(...) end
    assert(Inventory.select(p,opts,"food",w,nil,nil,true)==nil and planned==0)
    local inner=bag(bag(p.main).contents);local safe=item(inner.contents,"food")
    assert(Inventory.select(p,opts,"food",w,nil,nil,true)==safe and planned==0)
    safe.keep=true;assert(Inventory.select(p,opts,"food",w,nil,nil,true)==nil and planned==0)
    Open.plan=old
end)
