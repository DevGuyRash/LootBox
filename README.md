# LootBox

LootBox is a standalone Project Zomboid Build 42 client mod for reusable item categories, storage labels, looting, sorting, hauling, and batch cleanup. It includes contextual shortcuts, named reusable setups, and complete in-game workflow guides. LootBox is the working name. See [verification](docs/verification.md) for the exercised workflows and platform limits.

All executable mod files are client-side. A multiplayer host can enable `LootBox` in its normal mod list without running LootBox server scripts. With native Lua checksums enabled, the host still needs matching distributed client files and a normal restart after an update; client-only describes where the mod executes. The mod uses the game's native walking, transfer transactions, vehicle interactions, and trash command. Host permissions, locked storage, safehouses, capacity, and native action rejection remain authoritative. It has no dependency on LuaBuddy, Area Tasks, Easy Drop'n'Loot, or LootSense.

## Install locally

Extract the built `LootBox-0.4.1.zip` package. Copy its `Contents/mods/LootBox` directory into your game's local `Zomboid/mods` directory and enable LootBox in the game's Mods menu. Preserve both the `42` and `common` directories. Existing saves and multiplayer servers have their own mod selections. No helper mod or development tools are required to play.

For a development build, use Python 3.10 or later and Lua 5.1.

```sh
python3 tools/build.py
```

The archive is `dist/LootBox-0.4.1.zip`. `dist/manifest.json` records its file hashes. The build does not download game files or alter a running game. After updating, reconnect or restart to load the new Lua environment. Workshop publication and a final product name are separate release steps.

## Start with a workflow

Open **Options > Mods > LootBox > Open LootBox**, or choose **LootBox > Open LootBox** from a right-click menu. Home offers room and area looting, carried-item sorting, vehicle hauling, and room or area cleanup. Each opens the detailed Actions page with the source and destination prepared. Nothing runs until you choose a selection and review the job.

Home also offers **Loot this building** and **Clean this building**. A building search follows the game's room metadata on each actual floor and walks through small sections as needed. It loads sources through normal movement instead of making one enormous tile query. Progress distinguishes rooms processed, sections searched, and sections left unsearched. A blocked stairway, missing geometry, denied permission, or unstreamed section remains visible in the result. Buildings have no 16,384-tile scan cap; the existing room and drawn-area limits remain. A drawn area still covers one floor.

Drag the lower-right corner or bottom edge to resize the manager, quick review, bin review, or progress window. Existing text drafts, selected items and labels, and scroll positions stay in place. Settings uses scrollable preference rows so descriptions remain reachable above the fixed Save controls at narrower sizes and larger fonts. Item names, decision statuses, and explanations use separate colors; the full explanation remains available in the row tooltip.

Closing any LootBox window keeps its job running. Ordinary walking and queued player actions temporarily yield control, then the job continues automatically. Aiming, attacking or shoving, deliberate running or sprinting, and **Cancel job** stop it. **Resume job** continues the same job in the current session after the takeover ends, retaining its progress and original locations while checking current items and storage again. Starting another job replaces the stopped checkpoint; disconnecting or returning to the main menu ends it. Resumed cleanup requires a fresh bin contents review.

Help is available from the main menu and in game. Its complete walkthroughs include prerequisites, numbered steps, expected results, troubleshooting, and a **Set up this workflow** button for runnable workflows. Categories and Settings also work before entering a world.

Right-clicking an inventory item offers bulk actions for its exact type and relevant categories, Keep for that copy, item tags, and category creation. A world container offers transfers and storage labels. Floor context offers room, building, reach, and area workflows. Vehicle context offers memory, hauling, and compartment labels. Saved setups are available in the context menu when you have created them. The original game and other mods' menu entries remain available.

Ordinary shortcuts use a compact review with **Adjust setup** to open the full composer. Settings controls the menu entry, individual shortcut groups, confirmation for ordinary quick moves, inline tips, and last-setup reuse. Cleanup always requires a fresh explicit deletion review, even if ordinary quick-move confirmation is disabled.

## Save a complete setup

Configure an action, give it a name, and choose **Save new setup**. A named setup remembers its item selection, source scope, destination kind, and bag options. Load it from Home, Actions, or the Saved setups submenu. Update and delete controls manage the selected setup. **Continue last setup** restores the last meaningful action when remembering is enabled.

Saved containers bind to the container you click next time. Vehicles use your remembered car. Floor destinations bind to the current clicked tile, while saved areas retain their world coordinates and floor. Every run still gets current capacity, permission, item, and trash checks. Saved setups never retain a deletion approval or native object reference.

## Use categories and labels

Open **Options > Mods > LootBox > Manage categories**, or use the Categories page. Native categories come from the active game's item catalog, including enabled mods; there is no fixed list of ten labels. My categories, Game and mod categories, Selected only, and search help narrow the list without removing categories. A custom category can include individual item types, native categories, and other custom categories. Included categories form a union and stay current as the catalog changes. Circular definitions are rejected.

Storage rules mean "these categories belong here" and can contain multiple labels. Item-copy tags add only that particular copy to categories. Add an item type to a custom category to include every copy. **Keep** protects an individual copy. Equipped, held, attached, favorite items and nonempty bags are protected automatically; their eligible contents can still be selected when bag traversal is enabled. Labels separates storage targets from individual-copy tags and explains both choices.

## Loot, sort, move, and clean

Choose an item checklist, a source, and a destination in the action composer. Sources include carried inventory, a selected container, within reach, the current room, the current building, a visually selected area on one floor, or known containers with a chosen label. Including carried inventory and traversing bags are explicit options. Save and load a reusable checklist without changing the source or destination.

Destinations include carried storage, a selected container, a chosen floor location, the remembered vehicle, matching labeled storage, and known trash cans. Preview shows observed moves, exclusions, pending exploration, and deletion warnings. Start runs a finite job. The progress window separates moved items, retained or unconfirmed items, their reasons, and job controls. A bin review identifies the actual bin, floor, coordinates, observed contents weight, capacity and free space before asking for whole-bin deletion approval. Hauling fills available carried capacity before making delivery trips; it preserves unrelated carried items. A full destination leaves an item behind with a reason. Native floor dropping can use an adjacent permitted tile when the original tile is blocked or full; the job retains that original drop area if the player moves away during an interruption.

Automatic pickup respects the character's normal weighted carrying limit, rather than filling main inventory to its higher admission limit. With bag traversal enabled, carried storage with the best actual weight reduction is preferred. Only an equipped outer bag's reduction affects nested contents; unequipped bags still count at full carried weight. Preview shares one character-mass reservation across all bags, and runtime checks each pickup again. Items that cannot fit within these limits stay in place with a reason. Unloading and weight-reducing rearrangement remain available when the character is already overloaded.

Vehicle hauling prefers native trunk storage, then available seat and other storage. The client uses legitimate driver access to unlock storage when possible and restores the player's original seat or outside state. Occupied seats, moving vehicles, inaccessible keys/doors, blocked exits, and unusual modded vehicle access can prevent the operation. A failed restoration is reported with the remaining player location.

Cleanup discovers native trash-bin locations on nearby loaded floors, including outside a building. It compares carrying trips, available bin capacity, expected emptying operations, and travel and deletion still owed to other bins already used by that job. A larger bin wins when its savings outweigh travel; the biggest bin is not an unconditional preference. Initial travel is estimated. Successful owned walks supply observed travel costs for later choices, and failed routes are avoided during that job. Capacity and access are checked again on arrival. A full chosen bin is emptied before rejecting an item that might fit; a bin whose empty capacity is already too small is not visited merely to empty it.

An uninspected or unloaded bin is approached before use. The job pauses for **Review bin**, preserving its item selection and building search. **Approve bin and continue** approves the inspected existing contents for native whole-bin deletion. **Try another bin** retains the job and changes its destination. Closing the review leaves the job paused, and Cancel remains available. Bin approvals are transient and never saved in a setup. Observed protected or newly unapproved contents block approval and deletion.

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
