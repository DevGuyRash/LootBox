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
- `media/lua/client/Vehicles/TimedActions/ISPathFindAction.lua` supplies native location, object, vehicle-area and seat approaches. `media/lua/server/Vehicles/Vehicles.lua` requires appropriate storage doors to be open, so unlocking alone is insufficient.
- `media/lua/client/ISUI/LootWindow/Handlers/RemoveAll.lua` checks `PropertyContainer:has("IsTrashCan")` and multiplayer `TrashDeleteAll`. `ISInventoryPane.lua:onConfirmDelete` sends vanilla `object.emptyTrash`. The native server handler empties the default bin container; no custom server code is required.
- Native `LuaManager.GlobalObject.getFileWriter` permits only selected extensions, including `.txt`; an internal `.a`/`.b` generation suffix alone is refused. Store generation files therefore end in `.a.txt` and `.b.txt`.
- Native `RequestItemsForContainerPacket.processServer` always replies to a newly explored container, including an empty item list. Its client receiver emits no Lua acknowledgment event and only sets explored while adding a new item. Meanwhile native `ISInventoryPage:checkExplored` sets explored at request time. An empty local list or changed explored flag is insufficient proof of synchronization.
- Native object network identity derives from coordinates and object index. It cannot establish persistent continuity for an identical replacement after reconnect without additional world metadata. LootBox uses local observations and reports unresolved locations.

The design follows these native behaviors instead of copying a transfer engine, rewriting categories, forcing server state, renaming inventory items, or adding equipment choreography without a demonstrated need.
