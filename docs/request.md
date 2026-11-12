# User requirements

These are excerpts of the user's own words from the creation request in the Codex chat on November 10, 2026. They govern the design; the design document is an implementation proposal. LootBox is a working name: "Not sure on a name yet. Maybe LootBox or something?"

"Would be in ~/repos and client-side fully in that it works completely client-only."

"It's client-only, though mp servers can enable it as needed. But we want it to work client-side, not server-side"

"Build 42, including multiplayer (Recommended)"

"The idea is to combine the capabilities of all of these while GREATLY improving on all of them too!"

"Would love the ability to label crates the exact same way via category, but the issue with the existing mod is that it does not support all existing categories in the game."

"Want the ability to create custom categories as well, where a user can put as many items as they want in it, or a custom category can also consist of nested existing categories or other custom categories. The idea would be that they can do this in the main menu, where they can see all items and everything in one place, or they can do it in-game via the context menu, whichever is easier for them. Although making sure there's no clutter is extremely important. The user experience above all."

"you can drop all of any category, that you can put all of a category into a container, take all of a category out of a container, that you can do the same thing with all of an item. And this should be something that spans across all of your carried containers too, with the option to go into bags as well."

"if there's a bag in your inventory that you can't see because it needs to be equipped, then it will equip it, or put it on the ground if that works, and then go through that as well, and then put it back to where it was, picking it up or putting it back in the inventory or wherever it was."

"what if we also have the ability to tag certain items as things to look for on a loot run ... when it finds those, it goes ahead and picks them all up ... like auto loot."

"we would probably want the ability to put multiple labels on something rather than just a single one. I'm also thinking about the ability of tagging multiple labels on an item too."

"look for specific categories, not just individual items ... go and find all of this specific category in this area ... in my current room, or within reach, or within a specific area ... a button that says loot this building ... or loot this room ... maybe a checklist of categories you want to loot for"

"take all items of this loot type in this room or this area or within reach, and we can either drop them on the floor ... move them to a container ... move them to my car ... remembers where your car was and goes to the trunk and fills that up, and then it fills up the other seats as needed ... account for if it's locked ... get in the driver's seat to unlock it."

"moves it to the nearest trash can. Ideally it's keeping track of trash cans it finds, and it also updates when that trash can is no longer there. Like if it sees that it's moved or gone. And then it also takes into account the size of the trash can too, and how much it can hold"

"a button too that just says clean, like room or clean area ... the trash can may not always be in the same room. It could be outside. It could be somewhere else."

"if the trash can's not big enough, then it walks to the next known trash can location to delete it there instead ... fill it up and then delete, fill it up, delete. If there's not enough space, it deletes first before assuming that there's just not enough."

"clear out as specified rooms, areas within reach, or whatever, or even all containers marked for, like, junk ... mark categories of containers ... take this category and put it in this type of container, or these types of containers. Go ... automatically goes and takes all items of, like, you know, X and moves it to Y."

"we have a super sorter, a super looter, a super loot clearing system, automatic hauling and transferring of items, like from A to B."

"also use [@pstack:poteto-agent](subagent://pstack:poteto-agent) please!"

When told that earlier instructions required Claude for UI code, the user explicitly changed that requirement for this work: "no claude for this. Not needed".

## Usability follow-up

The user reported scrolling text clipping and asked for clearer workflows, visuals, tooltips, and more ways to act alongside the full manager.

"There's no help menu, there's no guides for how to do several different workflows. All this should be built in, basically. It should explain how to do complete workflows, not just one-off things."

"we should be able to control those with options if we want to be able to disable them or not."

"But these are not to replace the menu. These are just adding more ways to work with it that are a bit more immersive. We don't want just a single way, and I think we should keep the menu and improve it, but also add more ways to interact and use this."

"assume new people won't have luabuddy so this needs to hold on it's own too"

## Building and destination follow-up

"does it work in multi-floor houses if the trash can is outside and the person is on the 2f? can it identify a "whole building" and not just current room (even multi-floor)? what about an enormous building? etc"

"and is it smart enough to know when to go to the closest vs next closest but biggest?"

"implement the features please"

## References supplied by the user

- [Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745)
- [Easy Drop'n'Loot](https://steamcommunity.com/sharedfiles/filedetails/?id=2871469707)
- [LootSense: QuickStack](https://steamcommunity.com/sharedfiles/filedetails/?id=3733862305)
- [LootSense: Storage](https://steamcommunity.com/sharedfiles/filedetails/?id=3733326180)

## Window and job control follow-up

"Make sure the window can be resized too andt hat you can exit out of the menu and it still functions unless cancelled by the user (explicit action  like aiming; some actions are allowed like slight movement and trying to eat/drink, etc. I don't want to list all allowed; I'd rather list disallowed like aiming and other explicit things that might indicate the user wants to stop)"

"also make better use of colors too for all this. Like here we can highlight the item one, the status anothER (like Protected), leave description normal, etc. apply this kind of change throughout though and not only in one place. Also make this easier to understand, the planning easier to understand, the bin itself when it finds one and asks for approval, etc"

"and add a resume button too"

## Per-container workflows

"also would love the ability to right click a container itself in the inventory/loot thing and choose to empty container, loot container, clean container, etc just at a per container level too! if not already existing"

"also the other stuff like organizing and all that too! Just general lootbox capabilities"

## Context-menu icons

"can we please add icons for all places for lootbox? not just some? I mean in context menus. Ideally they fit the option/action too! I like the ones you've made so far! They fit zomboid perfectly. Though I don't think we should have duplicates"

## Stack amount selection

"ALSO another thing I wanted is to add th ability to "take X amount" so you can right click a stack and "Take X amount" or similar. Doesn't have to be inside of the lootbox menu. Just added as a conditional one when right clicking an item. then you can type an amount and it only takes that much. Same with when putting into containers. Not sure how to pull that one off! Maybe select X amount is better for both directions?"

"then it just selects them and the user can do whatever they want next"

## Hauling and job-control follow-up

"Also, another thing is that I want it to fill carrying bags the user has on first (or equip them if in inventory or if found). It should equip the main bag, if there is a mod allowing for lower back too then a duffle bag there, bags inside of primary and secondary too! Also consider what should happen if there's things in those bags as well. It should basically try to fill all bags first before the main one. That way each trip is as impactful as it can be"

"also, I love that it reviews the bin but there should be a button to just start job and skip bin review too. and ideally a faster way to get back to the current job as well!"

"and for some of the items it's saying changed source after preview, those were things already in the trash basically."

"if something truly is too heavy, I would think we really want the place cleaned out right? Maybe it starts putting the user's things into a bin just to remove the heavy things (putting entire bags/containers instead of their contents so that we don't have to refill them) until it's light enough, then after the next delete it goes back and re-equips the things where they go and puts items back into correct spots"

"also I do have enough capacity to have taken the salt lick. It just never went back after deleting the current batches"

"and why do I have to manually click "Review bin"? Seems a bit counterintuitive"

"we can leave it, but shouldn't it just pop up upon arrival?"

"also maybe a pause option incase we need to deal with a zombie and resume?"

"yeah it's not filling all the containers available to it to the max before going over (though this isn't always the best strategy so keep that in mind; but it may be faster!)"

"also check latest run. It kind of bugged out and stopped"

"It's because I'm at the limit of 14/14 but really the limit is 50. It shouldn't matter that we're at the normal limit. Over-encumberance is fine. Check the ACTUAL upper hard carry limit when computing, (might change server to server but I think 50 is default). Using code to check is ideal"

## Optional quick actions, Smart Load and matching toolbar

"I think it's a bit clunky too for several quick actions having to preview and then approve jobs. Maybe whenever we see this, there's a checkbox that you can tick to not see the preview again? Like if I want to get all items from a container to my bag via conext menu I want it to just work, not see a preview and then hit approve and all."

"Also, would love a mode when transferring to "My inventory" where it's Smart Load or similar. I love right nowt hat you can choose individuals, but smart load just loads all of your containers first and THEN your main inventory. You can make it even smarter however you see fit and apply this logic wherever it makes sense to too!"

"I think the first part of what I said is related to the bin reviews too so something to consider generally"

"For quick cleanup shouldn't we just disable them? It's a context menu quick option"

"maybe we should just make all of them optional"

"also naturally add another icon next to the "Transfer items of matching types to nearby containers" and "Transfer items of matching types to the displayed container". Make the icons similar to those ones and make them next to their respective ones. Inspect how they work since they can appear situationally as ours should. The idea is that the second button next to each transfers from ALL of our containers to displayed (matching items) or ALL of our containers to all nearby containers (matching items). Like:"

`<theirs> <ours> <theirs> <ours>`

## Condense carried inventory

"what if we have an option too that is before Transfer all called like Condense? It moves all items from the main inventory starting by heaviesty (for encumberance reduction) to the bag with the most reduction that can hold it. and it moves things around too to optimize bags basically. This can be in settings to change behavior, but I imagine a few different ways it can work. One, for example, is it looks at all held bags. You know, it can obviously look at nested too, and then it looks at basic, and it takes into account too whether or not they're actually equipped. Since if they're not equipped, what if the user doesn't even want to use those bags and those are just, like, loot. So basically it just kind of, like, looks at all bags that are equipped, possibly ones that are just, like, in inventory too but unequipped. And one of the modes is first it just kind of moves everything from the main inventory into bags as needed. And the other mode is a bit more in depth in that it can basically transfer things around in bags so that it basically looks at what items should go in which bags for the maximum reduction count. So, like, for example, say there's something in a military— or not in a military backpack, in a duffel bag, and the duffel bag may not have the most encumbrance reduction, and there's room in the military backpack. So it moves it there instead, and then it takes something out of the military backpack that doesn't weigh much and puts it in, like, the duffel bag. And it basically shuffles all the bags around to be optimal first, and then it kind of moves things into those bags, or it even takes them out of the bags and puts them in the main inventory if it would make more sense to do it that way. I think you're smarter than me, so think of a few different ways that these should interact, and then multiple different, like, scenarios too about how things should go, basically."

## Smart Take buttons and grouping

"continue where LootBox left off. Also, would it help if there was also a button for smart loot next to the loot one for take all / items of matching type? Please do so. So one for smart take all of matching type and smart take all"

"should also be smart enough to know to put similar items in all containers too nad not just a single one."

For this continuation the user again explicitly waived Claude: "no claude for this." They also requested "also use [@pstack:poteto-agent](subagent://pstack:poteto-agent)".

## Condense grouping and Workshop publication

"Does Condense also keep similar items together across bags when optimizing? If not, please make it do that too while still prioritizing weight reduction."

"Then, please publish the mod using the SteamWorkshop after in ~/repos"
