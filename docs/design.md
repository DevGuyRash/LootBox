# LootBox design

LootBox is a provisional name. This is an independent Build 42 client mod, with executable code exclusively in `media/lua/client`. A multiplayer host may enable the mod through the normal mod list, but installs no LootBox server logic. Native game actions remain authoritative. It has no dependency on LuaBuddy or any of the four reference mods.

## One language for the player

A category is a reusable selection of items. Native categories come from the current game's item catalog, including installed mods; no fixed category mapping compresses or drops them. A custom category contains item types, native categories, and other custom categories. Includes mean union. Cycles are refused. Stable IDs are independent of translated names.

Container labels describe what belongs there and accept multiple categories. Item labels add a particular instance to categories; adding an item type to a custom category affects every instance instead. Keep protects an instance from automated movement and deletion. Loot checklists describe what the player wants to find and require no tagging of world containers or individual loot. These are different player intentions with separate controls.

## One job model

Every operation is a source scope, an item selection, and a destination. Loot brings matching items to carried storage. Move sends them to a selected container, a floor location, the remembered vehicle, or labeled storage. Clean hauls them to real trash cans and batches native deletion. The same selection supports an item type, multiple native or custom categories, or all unprotected items. Source scopes include inventory, within reach, current room, current building, and a rectangle on one floor; including carried contents and recursing into bags are explicit options.

Jobs take a finite source snapshot and revalidate each action against live state. They do not scan unloaded containers, inspect sealed unexplored buildings remotely, assume another player's inventory remains unchanged, or wait forever for future loot respawns. A job reports items moved, items left behind, and concrete blocking reasons. Cancel stops owned work and restores temporary bag/equipment changes where native actions permit restoration. The engine queues a bounded step at a time rather than an entire building's actions.

## Routing and capacity

Explicit destinations win. Labeled storage considers every matching label, then stable destination order, while reserving shared capacity across the planned batch. The runner rechecks actual capacity before transfer. Vehicle storage prefers the trunk, then native seat/other storage; access uses native doors, seats, keys and unlock actions. A full destination does not silently become a floor drop. Floor placement is an explicit destination or explicitly selected overflow policy.

Trash discovery remembers the identity and location of observed bins, validates that a remembered bin is still the same real trash object, and distinguishes an unloaded location from a bin observed to be gone. Cleanup fills a bin before emptying it, empties existing contents before concluding an item cannot fit, uses another known bin for items too large for an empty one, and observes completion before continuing. Native empty-trash deletes the entire bin, so preview includes existing contents. Multiplayer `TrashDeleteAll` must permit the action. Cleanup does not change respawn settings or guarantee respawn; the server owns that policy.

## Interface

One LootBox context-menu entry opens a compact action composer. Its sentence is "Move [what] from [where] to [destination]"; Loot and Clean prefill the destination. Category management is available from the main menu and in game with search, all item types, inclusion editing and a live count. The preview explains destinations and exclusions. A small job panel exposes progress and Cancel. Context actions on an item preselect its type/category; actions on containers preselect the source or destination and offer Labels. Avoid a submenu for every possible combination.

## Runtime module contract

`Categories` owns category IDs, graph validation and matching. `Store` owns local versioned persistence. `Catalog` reads installed native script items. `World` owns observed source and destination discovery. `Native` owns native action submission and observation. `Jobs` owns finite planning and one-step execution. `App` owns per-local-player state and the public UI API. `UI` owns native controls and menu registration. Module dependencies point toward category and persistence primitives; UI calls App.

`App.catalog()` returns `{items={{fullType,name,categoryId}}, categories={{id,name,kind}}}`. Native category IDs are `native:<raw display category>` and missing categories use the item's native type category. Custom categories use `custom:<stable ID>`. Custom definitions are `{id,name,types={fullType,...},includes={categoryId,...}}`. `App.saveCategory(definition)` returns `id` or `nil,error`; `App.deleteCategory(id)` refuses deletion while referenced.

`App.get(playerIndex)` returns a per-player application. `app:preview(request)` returns a plan with `moves`, `skipped`, `warnings` and `request`; each display row has `itemName`, `from`, `to` and an optional `reason`. `app:start(plan)` starts the reviewed plan, `app:cancel()` cancels owned work, and `app:status()` returns `{state,done,total,reason}`. Requests have `{scope,area,sourceContainer,includeInventory,includeBags,filter,destination}`. Filter is `{ids={categoryId,...},types={fullType,...},all=boolean}`. Destination is `{kind,ref,labels}` with kind `inventory`, `floor`, `container`, `vehicle`, `labels`, or `trash`. Area is `{x1,y1,x2,y2,z}`.

`app:labels(container)` returns category IDs; `app:setLabels(container,ids)` persists them. `app:itemLabels(item)` and `app:setItemLabels(item,ids)` manage instance memberships; `app:protect(item,value)` changes Keep. `app:rememberVehicle(vehicle)` sets the hauling vehicle. `app:knownVehicles()` returns observed vehicles. `app:currentContainer()` returns the selected native loot container. Persistence is local; sharing labels between players is outside the client-only contract.

## Acceptance

Independent expected behavior comes from the original user request and installed native game sources. Build the whole runtime before adding tests. Verify player workflows first in an isolated game cache and display, then integration and category/persistence contracts where gameplay does not cover boundaries. Multiplayer requires a disposable normal server with client mod activation and no LootBox server files. No test may modify the user's running game, personal saves or Workshop sources. Portable and native-interpreter tests alone cannot establish working multiplayer gameplay.
