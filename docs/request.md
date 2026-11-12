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
