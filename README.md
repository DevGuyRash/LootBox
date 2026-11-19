# LootBox

LootBox is a standalone Project Zomboid Build 42 client mod for reusable item categories, storage labels, looting, sorting, hauling, and batch cleanup. It includes contextual shortcuts, named reusable setups, and complete in-game workflow guides. LootBox is the working name. See [verification](docs/verification.md) for the exercised workflows and platform limits.

All executable mod files are client-side. A multiplayer host can enable `LootBox` in its normal mod list without running LootBox server scripts. With native Lua checksums enabled, the host still needs matching distributed client files and a normal restart after an update; client-only describes where the mod executes. The mod uses the game's native walking, transfer transactions, vehicle interactions, and trash command. Host permissions, locked storage, safehouses, capacity, and native action rejection remain authoritative. It has no dependency on LuaBuddy, Area Tasks, Easy Drop'n'Loot, or LootSense.

## Install locally

Subscribe to [LootBox on Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3838652822), or install the local package. The Workshop ID is `3838652822`, and the mod ID is `LootBox`.

Extract the built `LootBox-0.9.11.zip` package. Copy its `Contents/mods/LootBox` directory into your game's local `Zomboid/mods` directory and enable LootBox in the game's Mods menu. Preserve both the `42` and `common` directories. Existing saves and multiplayer servers have their own mod selections. No helper mod or development tools are required to play.

For a development build, use Python 3.10 or later and Lua 5.1.

```sh
python3 tools/build.py
```

The archive is `dist/LootBox-0.9.11.zip`. `dist/manifest.json` records its file hashes. The build does not download game files or alter a running game. After updating, reconnect or restart to load the new Lua environment. Workshop listing metadata and the preview are kept in `workshop/`; release uploads use the shared SteamWorkshopPublisher.

## Start with a workflow

Open **Options > Mods > LootBox > Open LootBox**, or choose **LootBox > Open LootBox** from a right-click menu. Home offers room and area looting, carried-item sorting, vehicle hauling, and room or area cleanup. Each opens the detailed Actions page with the source and destination prepared. Choose a selection, then use Start to run it or Preview to inspect it first. Review settings can make Start show a review; previews are optional.

Home also offers **Loot this building** and **Clean this building**. A building search follows the game's room metadata on each actual floor and walks through small sections as needed. It loads sources through normal movement instead of making one enormous tile query. Progress distinguishes rooms processed, sections searched, and sections left unsearched. A blocked stairway, missing geometry, denied permission, or unstreamed section remains visible in the result. Buildings have no 16,384-tile scan cap; the existing room and drawn-area limits remain. A drawn area still covers one floor.

Drag the lower-right corner or bottom edge to resize the manager, quick review, bin review, or progress window. Existing text drafts, selected items and labels, and scroll positions stay in place. Settings uses scrollable preference rows so descriptions remain reachable above the fixed Save controls at narrower sizes and larger fonts. Item names, decision statuses, and explanations use separate colors; the full explanation remains available in the row tooltip.

Closing any LootBox window keeps its job running. Press **F7** or choose **LootBox > Current job** to reopen it; F7 can be rebound in native key settings and ignores text entry. Ordinary walking and queued player actions temporarily yield control, then the job continues automatically. **Pause job**, Escape, aiming, attacking, or shoving pause it until you choose **Resume job**. Deliberate running or sprinting also pause it with a resumable checkpoint. **Cancel job** permanently discards the stopped job after native cleanup settles; it cannot be resumed. Escape cancels Til Full, which cannot be paused. Resume keeps progress and original locations while checking current items and storage again. A fresh footer action cancels the previous job before starting new work. Job checkpoints last for the current player session. Personal-gear recovery receipts survive reconnects.

Help is available from the main menu and in game. Its complete walkthroughs include prerequisites, numbered steps, expected results, troubleshooting, and a **Set up this workflow** button for runnable workflows. Categories and Settings also work before entering a world.

Right-clicking an inventory item offers bulk actions for its exact type and relevant categories, Keep for that copy, item tags, and category creation. Right-click a container icon in either inventory pane, a bag item, or an empty pane to work on its contents. These shortcuts offer looting or unpacking, emptying onto the floor, sorting into labeled storage, cleanup, moving to another visible container or your remembered vehicle, storage labels, and the full item/category composer. The clicked container stays the source even if another container is selected. Bag-content actions live under **Contents of <bag name>**, separate from actions on the bag itself. A world container offers the same contents workflows and carried-item transfers. Floor context offers room, building, reach, and area workflows. Vehicle context offers memory, hauling, and compartment labels. Saved setups are available in the context menu when you have created them. The original game and other mods' menu entries remain available.

**Empty contents onto floor here** moves eligible contents to your current floor location without deleting them. **Clean contents (delete)** hauls eligible contents to a trash can and deletes batches, using your review preferences. **Sort contents...** uses category labels on destination storage; label your storage first, then review any unmatched or full destinations. For a carried bag, **Unpack contents to main inventory...** targets main inventory rather than distributing items back into bags. Nested contents are included by default and can be disabled through **Adjust setup**. The source container itself is never part of its contents selection.

Every LootBox context entry has a native game icon, including submenu headings, category actions, saved setups, and destination choices. Different actions have distinct symbols. Repeated targets of the same action keep a consistent symbol, while bag-content groups show the bag itself.

Quick context actions start directly by default, including cleanup, and normally leave the game view open. Press F7 for Current job. Settings independently controls transfer previews, cleanup previews, arrival bin reviews, and automatic quick-job progress display. Explicit saved review choices are preserved. Every visible review has a Skip future checkbox for that review type; its choice is saved after a successful start or approval, and Cancel leaves it unchanged. Settings can enable any review again. The full manager keeps separate Start and Preview actions.

## Matching transfer buttons

The inventory footer keeps each native matching-transfer icon and places **Match Displayed** or **Match Nearby** immediately after it. Match Displayed targets the displayed loot container; Match Nearby targets nearby loot containers in the native order. Both buttons search main inventory and every nested carried container, independently of which inventory pane is selected. They use the game's matching item-type and clothing-variant rules, retain LootBox protections and native capacity checks, and avoid duplicate item transfers. The nearby mode includes matching floor stacks, as the native button does.

Each LootBox footer click requests fresh work, replacing the previous job after its owned native actions finish cancelling. You do not need to click again after cleanup. Repeated clicks replace the pending request with the latest one; they never silently resume an old checkpoint. Only **Resume job** resumes a paused job. Smart Take with no eligible items does nothing and does not open a setup menu. Personal-gear recovery remains required when indicated. F7 or Current job opens progress.

**Smart Take: all visible loot containers** is on by default in LootBox Settings. Smart Take All and Smart Take Matching consider eligible containers shown in the loot pane, even if the active container is empty. Turn it off for active-container-only behavior. Each click captures fresh sources; a review never expands to containers that appear later. Hidden containers, nested loot contents, protected or unwanted items, inaccessible storage, and gear-recovery storage remain excluded.

The companions respect tutorial visibility and use native target conditions in active-container-only mode; all-visible Smart Take also works with an empty active container. They use compact native text-button sizing and can be hidden through Settings. Hover highlights matches in the current pane. Each new job checks fresh items and captures its targets, so changing the displayed pane afterward does not redirect the running job. Empty matching pools do nothing, like the native buttons. The same displayed/nearby mode is available in Actions for carried matching items.

The loot footer adds **Smart Take All** immediately after native Take All and a **Smart Take Matching** companion after native Take Matching, for both containers and the floor. Smart Take Matching looks for types in every carried container, including nested bags, rather than only the inventory pane being viewed. Both actions take from the displayed source and distribute into all eligible carried bags using Smart Load, preferring bags holding similar items and falling back as each fills. Main inventory is last. Protected and unwanted loot stays in place. Hover highlights candidates; empty matching pools do nothing. The toolbar setting controls these and the inventory matching companions. Quick transfer previews and Progress follow the same optional preferences as other quick actions.

**Condense** appears before Transfer All in the inventory footer. By default it moves loose main-inventory items, heaviest first, into equipped bags with the best useful weight reduction. **Condense: optimize bag contents** also searches for beneficial exchanges between bags, using carried storage as temporary working space when native capacity permits. Settings separately opt into unequipped bags and nested contents; unequipped loot bags remain untouched by default. At equal carried weight, optimization groups matching types into fewer bags, including protected items as fixed grouping seeds. Bag objects and equipment stay in place. The bounded search finds useful improvements and does not promise a globally optimal packing. Keep, favorite, equipped, held and attached items remain protected. Pause, Resume, aiming interruption and F7 Current job use the existing runner. Cancelling an incomplete exchange leaves its items safely carried and reports any temporary placement.

## Select an exact stack amount

Right-click a stack with at least two items and choose **Select amount...** directly in the normal item context menu. Enter a whole number and confirm. This highlights that many items in the pane you clicked. It starts no transfer or LootBox job. The existing **Inventory and container shortcuts** preference controls the option.

For a partial amount, the stack expands and only the chosen item rows or cells are selected. Drag those highlighted rows, or right-click a highlighted row and use the game's ordinary Take, Put in Container, Drop, or other action. Right-clicking an unselected stack header changes the selection normally. Choosing the whole stack selects its collapsed header. Cancel or Escape leaves the current selection alone. The same workflow applies to carried inventory, bags, loot containers, and visible floor stacks.

Counts and source identity are checked again before selection. A stale stack or changed pane is refused rather than silently selecting different loot or reducing the amount. Larger partial selections use the active view's expanded rows or cells in that pane. This is a mouse workflow; controller selection is not qualified. LootBox shortcuts named All of this type retain their bulk meaning, so use normal game actions for the highlighted amount.

## Save a complete setup

Configure an action, give it a name, and choose **Save new setup**. A named setup remembers its item selection, source scope, destination kind, and bag options. Load it from Home, Actions, or the Saved setups submenu. Update and delete controls manage the selected setup. **Continue last setup** restores the last meaningful action when remembering is enabled.

Saved containers bind to the container you click next time. Vehicles use your remembered car. Floor destinations bind to the current clicked tile, while saved areas retain their world coordinates and floor. Every run still gets current capacity, permission, item, and trash checks. Saved setups never retain a deletion approval or native object reference.

## Use categories and labels

Open **Options > Mods > LootBox > Manage categories**, or use the Categories page. Native categories come from the active game's item catalog, including enabled mods; there is no fixed list of ten labels. My categories, Game and mod categories, Selected only, and search help narrow the list without removing categories. A custom category can include individual item types, native categories, and other custom categories. Included categories form a union and stay current as the catalog changes. Circular definitions are rejected.

Storage rules mean "these categories belong here" and can contain multiple labels. Item-copy tags add only that particular copy to categories. Add an item type to a custom category to include every copy. **Keep** protects an individual copy. Equipped, held, attached, favorite items and nonempty bags are protected automatically; their eligible contents can still be selected when bag traversal is enabled. Labels separates storage targets from individual-copy tags and explains both choices.

## Loot, sort, move, and clean

Choose an item checklist, a source, and a destination in the action composer. Sources include carried inventory, a selected container, within reach, the current room, the current building, a visually selected area on one floor, or known containers with a chosen label. Including carried inventory and traversing bags are explicit options. Native transfers can refuse nested contents inside external fixtures; affected items remain in place and appear in the result. Save and load a reusable checklist without changing the source or destination.

Destinations include carried storage, a selected container, a chosen floor location, the remembered vehicle, matching labeled storage, and known trash cans. Preview shows observed moves, exclusions, pending exploration, and deletion warnings. Start runs a finite job. The progress window separates moved items, retained or unconfirmed items, their reasons, and job controls. A bin review identifies the actual bin, floor, coordinates, observed contents weight, capacity and free space before asking for whole-bin deletion approval. Hauling uses available bag space before main inventory and retries temporary capacity failures after unloading. Unrelated carried items stay protected; a truly hard-limit-blocked cleanup item can use the temporary personal-gear workflow below. A full destination leaves an item behind with a reason. Native floor dropping can use an adjacent permitted tile when the original tile is blocked or full; the job retains that original drop area if the player moves away during an interruption.

Automatic pickup uses the main inventory's live native hard capacity and current capacity weight. The HUD's normal encumbrance threshold does not block hauling; over-encumbrance is allowed. Eligible carried bags are tried before main inventory, independently of whether source-bag searching is enabled. The aggregate destination is named **My inventory (Smart Load)**. Bags already containing similar item types are preferred, across all carried storage. Full or unsuitable bags spill into the next eligible bag; other bags are ordered by actual weight reduction, and main inventory is last. Native clothing-variant aliases count as matching types. Individual bag and main-inventory destinations remain available and receive a direct transfer. Before collecting, LootBox can equip useful carried or found bags in compatible free worn locations, including extra locations declared by other mods, then free hands when the load needs them. It considers existing contents and preparation cost, and retains occupied user equipment. Native bag conversions preserve observed contents and migrate LootBox labels and Keep to the observed replacement. Only an equipped outer bag's reduction affects nested contents; unequipped bags still count at full carried weight. Preview shares a body-mass reservation across the bags, and each native pickup rechecks item rules, capacity and server acceptance. Unloading and weight-reducing rearrangement remain available while overloaded.

Vehicle hauling prefers native trunk storage, then available seat and other storage. The client uses legitimate driver access to unlock storage when possible and restores the player's original seat or outside state. Occupied seats, moving vehicles, inaccessible keys/doors, blocked exits, and unusual modded vehicle access can prevent the operation. A failed restoration is reported with the remaining player location.

Cleanup discovers native trash-bin locations on nearby loaded floors, including outside a building. It compares carrying trips, available bin capacity, expected emptying operations, and travel and deletion still owed to other bins already used by that job. A larger bin wins when its savings outweigh travel; the biggest bin is not an unconditional preference. Initial travel is estimated. Successful owned walks supply observed travel costs for later choices, and failed routes are avoided during that job. Capacity and access are checked again on arrival. A full chosen bin is emptied before rejecting an item that might fit; a bin whose empty capacity is already too small is not visited merely to empty it.

An uninspected or unloaded bin is approached before use. Its review opens automatically on arrival, even with the progress window closed, and waits while you type. Closing it leaves the job waiting without repeatedly reopening it; **Review bin** reopens it. **Approve bin and continue** approves the inspected contents for native whole-bin deletion. **Try another bin** keeps the job and chooses a different destination. Arrival reviews are optional and off by default. When enabled, **Skip future bin reviews** remembers automatic handling after successful approval. The separate **Start and skip bin reviews** or **Approve and skip further bin reviews** action changes only the current job. Protected items, permissions, identity and native rules are still checked. Approval tokens and skip choices are never saved in a setup. Eligible items already in a usable approved trash can are cleared in place and counted separately from hauled items.

If a cleanup item still exceeds the live hard carry budget after unloading and preparing bags, LootBox can temporarily store whole top-level personal items or bags in ordinary permitted world storage. The staging container is separate from trash, and it plus the recorded personal items and descendants are excluded from cleanup. A local recovery receipt is saved before any movement. LootBox delivers and deletes the heavy load, then restores the personal items and original equipment slots. Planning checks the temporary raw weight needed to pick bags back up, including their contents. If no safe storage and restoration route fits, the item stays with a reason. An interruption, missing item, changed slot or unavailable container retains the receipt and its coordinates; choose **Recover gear** from Current job. User equipment changes are retained, and occupied original slots must be cleared before restoration. A changed world-object index while disconnected can require manual recovery at the recorded location.

The native trash command empties the whole server bin and does not accept an atomic client approval list. Multiplayer has no reliable Lua acknowledgment of an empty container reply; the inspection wait is not proof of server synchronization. Reviews show client-observed contents, and a client mod cannot guarantee protection against unseen or concurrent server changes. Multiplayer servers must allow `TrashDeleteAll`. Cancel cannot recall a trash command that has already been sent. Cleanup does not change server loot respawn rules or guarantee respawn.

## Client-only boundaries

Item discovery is limited to physically loaded, permitted native locations. Building geometry comes from native metadata; walking can stream distant sections before inspecting their sources. Source fixtures, bags, keyed vehicle storage, and floor locations are resolved again after a long delivery trip, while item IDs and types remain strict. Unkeyed vehicles can be used through their live handle but are not adopted after unloading. Multiplayer's Lua API does not acknowledge an empty container-content response, and its normal inventory UI marks exploration before synchronization completes. Jobs move observed eligible items and report newly searched sources as unconfirmed; they cannot certify a fully cleared building from an empty local list. Human corpse hauling is excluded because its special native action can change held equipment. Native failure remains visible instead of becoming a direct inventory mutation.

Categories, interface preferences, checklists, and setups are private local data. Container and instance labels and named setups persist per world and player; they are not automatically shared with other clients. Optional setup and preference documents are separate from labels and Keep, so a damaged optional file does not block ordinary item handling. Native fixture identity has no persistent UUID, so an identical replacement in the same location and slot cannot always be distinguished across reconnect. Vehicle memory and labels use the native key ID and model. Lookup requires a unique loaded match and never adopts a nearby car by its appearance or position. Native key IDs are key associations rather than guaranteed UUIDs; keyed-alike modded vehicles can remain ambiguous. Explicit rekeying or a model change requires remembering and labeling the vehicle again. Unloaded remembered locations remain unverified, and observed missing trash cans are retired.

## Develop and verify

```sh
python3 tools/verify.py
python3 tools/verify.py --game /path/to/ProjectZomboid/projectzomboid
python3 tools/play.py --game /path/to/ProjectZomboid/projectzomboid --evidence /path/to/fresh/evidence
```

Portable verification builds the full package before running contracts. The optional native lane needs JDK 25 and repeats contracts in the installed game's Kahlua interpreter. Boundary doubles are explicitly separate from actual gameplay. `tools/play.py` starts an owned Xvfb display and an isolated game cache using the stock game JRE, without reading launcher overrides or touching personal saves. Stop its owning process to terminate and reap its client/display. `--resume` restarts a stopped owned cache for persistence checks. See [verification](docs/verification.md), [design](docs/design.md), [reference findings](docs/research.md), and the [user's own requirements](docs/request.md).

## Eat or drink Til Full

**Til Full** appears alongside vanilla amounts in eligible Eat and Drink submenus.
Right-click the actual item in your inventory, a nearby loot container, or the nearby **Floor** pane. The game handles pickup and any normal return; another item of the same type is not a substitute. A container that moves out of reach or becomes locked cannot supply another item.
It uses only the clicked selection/stack, one native consumption action at a time,
and stops when the chosen action's need is restored: Eat targets hunger, Drink targets thirst, even when the item restores both. It does not aim for maximum stuffed moodles or find extra items elsewhere.
In single-player, **Open and Eat > Til Full** opens one selected can at a time and measures the exact food it produced before eating. It does not open another can when the hunger target is met. In multiplayer, use the game's **Open** action. Then right-click the opened food and choose **Eat > Til Full**. LootBox leaves sealed food menus unchanged because the server does not tell the client which opened item it created.

**Open and Drink > Til Full** opens eligible sealed vessels with the native recipe and drinks only after their contents can be checked. The normal opener is still required. Alcohol, poison and unsafe mixtures remain excluded; use a native amount instead. Food requiring an additional item for eating still uses the normal Eat action. Favorited items are allowed for this explicit consumption action. Food and fluid vessels already in the player's main inventory may be worn, held, or attached: normal native consumption runs without LootBox unequipping them. Keep and personal-gear recovery protections still apply, as do native vessel-size and safety restrictions. Unsafe, changed, or unavailable items
stop the request; normal native admission rules still apply.

In LootBox Settings, **Show Til Full in Eat and Drink** controls the menu entry.
**Til Full: satisfy both needs** is off by default: Eat targets hunger and Drink targets thirst. Turn it on to continue until both are satisfied,
which may consume beyond one already satisfied need. An item must restore the chosen action's need; otherwise the request stops rather than silently switching goals. The normal context-menu setting also controls this entry.

The menu action starts directly without opening another window. A refusal uses compact native feedback; Current job remains available if you want details or to cancel consumption. Movement/action interruption or another queued
player action prevents further stack consumption. Native mask/item restoration is
preserved, so cancellation can remain pending during cleanup. No-progress or
unavailable native actions stop safely rather than repeatedly queuing items.
In single-player, a partial portion completes when the exact amount and its native effect are confirmed. It does not take another bite just for hunger or thirst accrued during that action. In multiplayer, a confirmed partial portion does not start a second action just to chase normal metabolism. If the exact amount was consumed and the observed remaining need rounds to zero percent, LootBox reports the portion consumed rather than claiming an exact server zero. When a whole selected item is confirmed exhausted but the server reports a small residual change, any next portion is capped at the original remaining need. The stock multiplayer drink action can leave slightly less in the bottle than projected. LootBox reports that difference and never queues a second sip for a planned partial.
“Til Full” requests a stop at the observed target; native partial consumption and
multiplayer latency mean it cannot promise exact quantities or instantaneous
stopping. See [verification](docs/verification.md) for the coverage and limits of each workflow.


### Inventory navigation shortcuts

Hover the item list in your inventory or the loot window, then use **Home** or
**End** to reach its top or bottom. **Page Up** and **Page Down** move one viewport
with a row of overlap so partially visible rows are not skipped. These shortcuts
only scroll the hovered list; they do not select, transfer, or consume items.
Home and End leave the item popup closed until you move the mouse again.
You can also click the row under the pointer without moving it first.
Change or unbind all four under **Options > Key bindings > LootBox**. Text entry,
context menus, modal dialogs, and item dragging leave the shortcuts inactive.
