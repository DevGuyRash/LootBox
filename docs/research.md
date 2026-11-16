# Reference findings and native constraints

The four Workshop references were read on November 10, 2026, and their locally installed Build 42 Lua was inspected in place. No upstream code, assets, or game files are included in this repository. These findings describe the inspected versions; they do not establish every reported gameplay failure or every future Workshop update.

| Reference | Useful behavior to retain | Concrete boundary addressed here |
| --- | --- | --- |
| [Area Tasks](https://steamcommunity.com/sharedfiles/filedetails/?id=3793163745) | Finite area selection, native job actions, source identity checks, path retries, and separate action completion observation. Its installed implementation is already substantially developed. | LootBox combines the area job model with reusable item/category selections, source labels, destination labels, capacity-filled hauling trips, and batch trash cleanup. It does not recreate unrelated farming, construction, or corpse-management tasks. |
| [Easy Drop'n'Loot](https://steamcommunity.com/sharedfiles/filedetails/?id=2871469707) | Bulk item-type/category selection and native inventory transfers. | The inspected `EDNLMain.lua` operates on selected source/destination inventory panes. LootBox uses the same selection concept across carried/nested storage and finite world scopes through one composer. |
| [LootSense: Storage](https://steamcommunity.com/sharedfiles/filedetails/?id=3733326180) | Container labels, instance tags, visual intent, and separate slots for multi-container fixtures. | Its inspected presets expose ten broad labels and one label per slot. LootBox discovers native categories and accepts multiple native/custom category IDs. Its current version already removed automatic item renaming; that historical defect should not be described as an unfixed current bug. LootBox never renames items to display labels. |
| [LootSense: QuickStack](https://steamcommunity.com/sharedfiles/filedetails/?id=3733862305) | Preview, revalidation, item protections, and native multiplayer transaction handling. | Its inspected `PQS_Categories.lua` maps a limited category list into broad Storage labels and leaves `Material` and `WaterContainer` unmapped. LootBox matches raw native category IDs instead of approximating them into a smaller taxonomy. It uses native timed transfers in both single-player and multiplayer. |

## Native evidence

Paths below are relative to the installed game root. They document the inspected Linux 42.22.2 engine and must be rechecked for another game build.

- `media/lua/client/ISUI/AdminPanel/ISItemsListViewer.lua` and `ISItemsListTable.lua` use `getAllItems()`, script display categories, native item type fallback, and hidden/obsolete filtering. These support a dynamic main-menu catalog.
- `media/lua/client/TimedActions/ISInventoryTransferAction.lua` explicitly permits sources nested inside the player's carried inventory. `ISInventoryPage.lua` restricts which bags receive visible buttons separately. A missing bag button does not establish a need to equip or drop it.
- `media/lua/shared/TimedActions/ISInventoryTransferUtil.lua` supplies the native transfer factory. Human corpse pickup is a special action; `ISGrabCorpseItem.lua` can drop held heavy items. LootBox excludes that special workflow.
- Native transfer validity checks include live capacity, item restrictions, containment, transaction consistency, trading, and `ItemNumbersLimitPerContainer`. Queue submission is not a completed transfer.
- Native multiplayer container packets deserialize replacement item objects through `CompressIdenticalItems.load`. A successful transfer can therefore invalidate the original Lua item handle. Completion resolves the immutable item ID and full type only in the intended destination after it leaves the original source; the job follows that current handle. Floor completion checks actual world objects on the chosen tile.
- `media/lua/client/Vehicles/TimedActions/ISPathFindAction.lua` supplies native location, object, vehicle-area and seat approaches. `media/lua/server/Vehicles/Vehicles.lua` requires appropriate storage doors to be open, so unlocking alone is insufficient.
- `media/lua/client/ISUI/LootWindow/Handlers/RemoveAll.lua` checks `PropertyContainer:has("IsTrashCan")` and multiplayer `TrashDeleteAll`. `ISInventoryPane.lua:onConfirmDelete` sends vanilla `object.emptyTrash`. The native server handler empties the default bin container; no custom server code is required.
- Native `LuaManager.GlobalObject.getFileWriter` permits only selected extensions, including `.txt`; an internal `.a`/`.b` generation suffix alone is refused. Store generation files therefore end in `.a.txt` and `.b.txt`.
- Native `RequestItemsForContainerPacket.processServer` replies to a newly explored container, including an empty item list, but returns without a reply for an already explored container. `AddInventoryItemToContainerPacket` adds unknown item IDs rather than replacing the full list. Its client receiver emits no correlated Lua acknowledgment and changes no exploration flag for an empty reply. Meanwhile native `ISInventoryPage:checkExplored` sets explored at request time. An empty local list, changed item handle, or changed explored flag is insufficient proof of synchronization. `requestSync()` supplies no receipt.
- Native object network identity derives from coordinates and object index. It cannot establish persistent continuity for an identical replacement after reconnect without additional world metadata. LootBox uses local observations and reports unresolved locations.
- `BuildingDef:getSquares()` allocates and visits an expanded bounding box across floors -32 through 30 before returning. A limit checked afterward cannot bound that work. Building jobs instead consume `BuildingDef:getRooms()` and each `RoomDef`'s native rectangle list lazily, dividing each rectangle into sections of at most 8 by 8 tiles. Rectangle upper bounds are exclusive; source scans still check native room and building membership. Native metadata on floor 31 is retained.
- A first multiplayer character can reach `OnCreatePlayer` and `OnGameStart` with the native placeholder username `Bob`. `ConnectedPacket` assigns the actual local username after the player-connect handshake. App state is bound lazily when the player opens an interactive control, and reuse checks the current account scope.
- `BaseVehicle.load()` reads a saved mechanical ID, but `addToWorld()` then calls `createPhysics()`, which replaces it with `Rand.Next(100000)` on the client. Mechanical ID therefore cannot identify the same car across a normal reconnect. The inherited native key ID survives that recreation and is also copied into native smashed replacements. Network IDs can be reallocated and the client does not receive SQL identity. LootBox uses key ID and model, retains the network ID only as a current lookup hint, and rejects multiple observed loaded matches. Native key IDs are key associations rather than guaranteed UUIDs. The mod never adopts a vehicle by its coordinates or appearance.

The design follows these native behaviors instead of copying a transfer engine, rewriting categories, forcing server state, renaming inventory items, or adding equipment choreography without a demonstrated need.

## Building-hauling API findings

`PathFindBehavior2` construction for the real player cancels that player's path, and independent `PolygonalMap2` callbacks are not exposed to ordinary client Lua. LootBox keeps terrain routing in owned native `ISPathFindAction` instances. Initial destination costs estimate distance and floor changes; successful owned movement supplies bounded directional observations. The policy is a heuristic and does not claim the shortest possible stair route or globally optimal final tour.

Native character mass comes from `getInventoryWeight()` and `getMaxWeight()`. Nested contents receive only the equipped outer bag's actual weight reduction. Unequipped outer bags contribute full contents weight, and attached bags use their native equipped/unequipped ratio. Per-container admission alone permits substantially more weight than the character's normal limit, so hauling reserves both storage capacity and weighted character mass.

The server implementation of `object.emptyTrash` removes every server item from the chosen native bin. It ignores a client item-ID approval list. LootBox reviews client-observed existing contents and rejects changed observed contents, but cannot make deletion atomic against unseen or concurrent multiplayer changes without server code.

## Interruption and floor placement findings

`ISPathFindAction:update` stops on native movement or cancel input even though its aim/walk/run flags permit those states. External inventory transfers can stop on walking, and transfers stop on running. `ISBaseTimedAction:stop` resets the native queue, so LootBox temporarily detaches and restores foreign pending actions while stopping only owned work. Food and drink can queue preparation, transfers and restoration; classifying arbitrary foreign actions as job cancellation cannot support those workflows.

`ISInventoryTransferAction:getNotFullFloorSquare` first tries the character's square and then the adjacent 3 by 3 area if that square is blocked or full. Its existing `canDropOnFloor` checks native floor, wall, window and stair constraints. Exact-origin completion checks can therefore miss real successful drops. LootBox asks the admitted native action which nearby squares are permitted while the character is at the frozen origin, stores their coordinates, and later checks the immutable item ID and type there after it leaves the original source. It neither copies the chooser nor switches to the character's new position after a pause.

## Til Full source research (cloud, November 15, 2026)

This feature was researched separately from the installed-game evidence above. The
[Build 42.22 vanilla Lua mirror commit](https://github.com/Project-Zomboid-Community-Modding/ProjectZomboid-Vanilla-Lua/tree/3b21e63fe4905a0a300a4021d05d01a9bb534729)
and official [Stats](https://projectzomboid.com/modding/zombie/characters/Stats.html)
and [Food](https://projectzomboid.com/modding/zombie/inventory/types/Food.html)
API references informed the implementation. No installed game or multiplayer
server was available for this feature's acceptance testing.

Native inventory menu callbacks, rather than translated labels, identify Eat and
Drink submenus. `ISInventoryPane.getActualItems` expands a clicked stack without
its duplicate representative. `onEatItems` consumes only one actual item; finite
stack continuation therefore belongs to LootBox. Food percentages are measured
against original base hunger, requiring conversion for partially eaten food.
`eatItem` and `onDrinkFluid` retain vanilla transfers, mask removal/restoration,
and container return; LootBox does not mutate nutrition or item quantities.
`ISDrinkFromBottle` uses a different units contract and is not used here.

Eating can apply nutrition at native completion or partial interruption rather
than each frame; fluid actions update consumed fractions during progress. Native
stopping and server latency can therefore overshoot a requested target. The
controller observes needs and requests an owned-action stop, never promises an
instantaneous server rollback, and never resets unrelated queued actions. Client
completion is not a server acknowledgment: absent observed need improvement it
waits briefly and stops rather than queuing the rest of the stack blindly.
Restoration may itself stall; cancellation keeps ownership until native cleanup
settles rather than claiming masks or items have been restored.

The target is no positive hunger/thirst (zero, bounded by the native minimum), not
maximum stuffed moodles. The default follows native action intent: Eat targets hunger, Drink targets thirst,
even for mixed food/drink. The optional both-needs policy may exceed one already
satisfied need. A harmful effect is not a restorative need. Portable tests use
actual controller/menu/adapter Lua with explicit game-boundary doubles; they are
not proof of in-game timing, traits, modded nutrition, or multiplayer behavior.


### Deferred completion follow-up

The installed game's action sources were checked again November 16. Food
`perform()` handles UI/queue cleanup; `complete()` calls `character:Eat`.
Drink `complete()` calls `updateEat(1)`, while server animation progress can
apply partial fluid changes. Consequently observing any need improvement after
client action removal does not prove the requested portion completed. Food
confirmation uses remaining raw `getHungChange()` (the same base-portion units
used by the native action); fluid confirmation uses `getFilledRatio()` and the
requested fraction. Both must reach the planned remaining quantity before another
item can be queued. These are conservative observed-state checks, not a server
transaction receipt; latency or unavailable state stops continuation safely.
