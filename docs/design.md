# LootBox design

LootBox is a provisional name. This is an independent Build 42 client mod, with executable code exclusively in `media/lua/client`. A multiplayer host may enable the mod through the normal mod list, but installs no LootBox server logic. Native game actions remain authoritative. It has no dependency on LuaBuddy or any of the four reference mods.

## One language for the player

A category is a reusable selection of items. Native categories come from the current game's item catalog, including installed mods; no fixed category mapping compresses or drops them. A custom category contains item types, native categories, and other custom categories. Includes mean union. Cycles are refused. Stable IDs are independent of translated names.

Container labels describe what belongs there and accept multiple categories. Item labels add a particular instance to categories; adding an item type to a custom category affects every instance instead. Keep protects an instance from automated movement and deletion. Loot checklists describe what the player wants to find and require no tagging of world containers or individual loot. These are different player intentions with separate controls.

## One job model

Every operation is a source scope, an item selection, and a destination. Loot brings matching items to carried storage. Move sends them to a selected container, a floor location, the remembered vehicle, or labeled storage. Clean hauls them to real trash cans and batches native deletion. The same selection supports an item type, multiple native or custom categories, or all unprotected items. Source scopes include inventory, within reach, current room, current building, and a rectangle on one floor; including carried contents and recursing into bags are explicit options.

Jobs take a finite source snapshot and revalidate each action against live state. They do not scan unloaded containers, inspect sealed unexplored buildings remotely, assume another player's inventory remains unchanged, or wait forever for future loot respawns. A job reports items moved, items left behind, and concrete blocking reasons. Cancel stops owned work and restores temporary vehicle access where native actions permit restoration. The engine queues a bounded step at a time rather than an entire building's actions.

## Routing and capacity

Explicit destinations win. Labeled storage considers every matching label, then stable destination order, while reserving shared capacity across the planned batch. The runner rechecks actual capacity before transfer. Vehicle storage prefers the trunk, then native seat/other storage; access uses native doors, seats, keys and unlock actions. A full destination does not silently become a floor drop. Floor placement is an explicit destination.

Trash discovery remembers the identity and location of observed bins, validates that a remembered bin is still the same real trash object, and distinguishes an unloaded location from a bin observed to be gone. Cleanup fills a bin before emptying it, empties existing contents before concluding an item cannot fit, uses another known bin for items too large for an empty one, and observes completion before continuing. Native empty-trash deletes the entire bin, so preview includes existing contents. Multiplayer `TrashDeleteAll` must permit the action. Cleanup does not change respawn settings or guarantee respawn; the server owns that policy.

## Interface

One LootBox context-menu entry contains only relevant shortcuts for an item, category, actual clicked container, floor location, or vehicle. Settings can hide the entry or individual groups. Ordinary shortcuts open a compact review, with Adjust setup leading to the full manager. Optional confirmation-free ordinary moves still use the same fresh plan and native runner. Cleanup always keeps its explicit review and whole-bin deletion approval.

Home offers common tasks, saved setups, last-setup continuation, and the first-run guide. Actions retains the full "Move [what] from [where] to [destination]" composer. Category lists distinguish custom and game content without removing native categories. Labels separates storage rules from item-copy tags and Keep. Help contains complete workflows, prerequisites, expected results, troubleshooting, and setup links. Native Options entry buttons expose the manager, categories, Help, and Settings without reloading other mods' preferences.

Named setups capture portable request fields rather than native object handles or approvals. Container targets bind to fresh context, vehicles use the remembered car, and area coordinates remain world-scoped. Optional setups and global interface preferences have their own checked Store documents, separate from categories, labels, and Keep. Their failure does not disable ordinary transfers. An explicit contextual action takes priority over remembered broad selections.

The visual layer uses measured native fonts, slate panels, amber actions, cyan custom content, sage results, and coral deletion/error cues. Labels and markers accompany color. The local row renderer constrains complete glyph rectangles and backgrounds to the viewport even when a partial row would otherwise be submitted. Native combo popups remain independent. Native control colors are copied per instance, and only owned text entries are unfocused when their page is removed or hidden.

## Runtime module contract

`Categories` owns category IDs, graph validation and matching. `Store` owns local versioned persistence. `Catalog` reads installed native script items. `World` owns observed source and destination discovery. `Native` owns native action submission and observation. `Jobs` owns finite planning and one-step execution. `Setups` validates portable requests and interface preferences. `App` owns per-local-player state and persistence APIs. `Widgets` owns themed controls, viewport bounds, and text-entry focus ownership. `Menus` builds context requests; `Guides` supplies workflow records; `UI` owns manager, review, progress, and area-picker windows. Every execution path calls the same App preview/start API.

`App.catalog()` returns `{items={{fullType,name,categoryId}}, categories={{id,name,kind}}}`. Native category IDs are `native:<raw display category>` and missing categories use the item's native type category. Custom categories use `custom:<stable ID>`. Custom definitions are `{id,name,types={fullType,...},includes={categoryId,...}}`. `App.saveCategory(definition)` returns `id` or `nil,error`; `App.deleteCategory(id)` refuses deletion while referenced.

`App.get(playerIndex)` returns a per-player application. `app:preview(request)` returns a plan with `moves`, `skipped`, `warnings` and `request`; each display row has `itemName`, `from`, `to` and an optional `reason`. `app:start(plan)` starts the reviewed plan, `app:cancel()` cancels owned work, and `app:status()` returns `{state,done,total,reason}`. Requests have `{scope,area,sourceContainer,includeInventory,includeBags,filter,destination}`. Filter is `{ids={categoryId,...},types={fullType,...},all=boolean}`. Destination is `{kind,ref,labels}` with kind `inventory`, `floor`, `container`, `vehicle`, `labels`, or `trash`. Area is `{x1,y1,x2,y2,z}`.

`app:labels(container)` returns category IDs; `app:setLabels(container,ids)` persists them. `app:itemLabels(item)` and `app:setItemLabels(item,ids)` manage instance memberships; `app:protect(item,value)` changes Keep. `app:rememberVehicle(vehicle)` sets the hauling vehicle. `app:knownVehicles()` returns observed vehicles. `app:currentContainer()` returns the selected native loot container. Persistence is local; sharing labels between players is outside the client-only contract.

## Acceptance

Independent expected behavior comes from the original user request and installed native game sources. Build the whole runtime before adding tests. Verify player workflows first in an isolated game cache and display, then integration and category/persistence contracts where gameplay does not cover boundaries. Multiplayer requires a disposable normal server with client mod activation and no LootBox server files. No test may modify the user's running game, personal saves or Workshop sources. Portable and native-interpreter tests alone cannot establish working multiplayer gameplay.
