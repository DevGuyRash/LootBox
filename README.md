# LootBox

LootBox is a standalone Project Zomboid Build 42 client mod for reusable item categories, loot checklists, storage labels, sorting, hauling, and batch cleanup. LootBox is the working name. This development version has been checked on Linux 42.22.2 in single-player and multiplayer. See [verification](docs/verification.md) for the exercised workflows and platform limits.

All executable mod files are client-side. A multiplayer host can enable `LootBox` in its normal mod list without running LootBox server scripts. With native Lua checksums enabled, the host still needs matching distributed client files and a normal restart after an update; client-only describes where the mod executes. The mod uses the game's native walking, transfer transactions, vehicle interactions, and trash command. Host permissions, locked storage, safehouses, capacity, and native action rejection remain authoritative. It has no dependency on LuaBuddy, Area Tasks, Easy Drop'n'Loot, or LootSense.

## Install locally

Build the package with Python 3.10 or later and Lua 5.1 installed, then extract it. Copy the `Contents/mods/LootBox` directory into your game's local `Zomboid/mods` directory and enable LootBox in the game's Mods menu. Preserve both the `42` and `common` directories. In multiplayer, the host may need to enable the mod so the game loads its client scripts after connection.

```sh
python3 tools/build.py
```

The archive is `dist/LootBox-0.1.0.zip`. `dist/manifest.json` records its file hashes. The build does not download game files or alter a running game. Workshop publication and a final product name are still separate release steps.

## Use categories and labels

Open **Options > Mods > LootBox > Manage categories** from the main menu, or **LootBox** in an inventory or world context menu. Native categories come from the active game's item catalog, including enabled mods; there is no fixed list of ten labels. A custom category can include individual item types, native categories, and other custom categories. Included categories form a union and stay current as the catalog changes. Circular definitions are rejected.

Container labels mean "these categories belong here" and can contain multiple categories. Item labels add only that particular copy to categories. Add an item type to a custom category to include every copy. **Keep** protects an individual copy. Equipped, held, attached, favorite items and nonempty bags are protected automatically; their eligible contents can still be selected when bag traversal is enabled. Labels appear in the tooltip on LootBox's context entry.

## Loot, sort, move, and clean

Choose an item checklist, a source, and a destination in the action composer. Sources include carried inventory, a selected container, within reach, the current room, the current building, a visually selected area on one floor, or known containers with a chosen label. Including carried inventory and traversing bags are explicit options. Save and load a reusable checklist without changing the source or destination.

Destinations include carried storage, a selected container, a chosen floor location, the remembered vehicle, matching labeled storage, and known trash cans. Preview shows observed moves, exclusions, pending exploration, and deletion warnings. Start runs a finite job. The progress window shows moved items, items left behind, reasons, and Cancel. Hauling fills available carried capacity before making delivery trips; it preserves unrelated carried items. A full destination leaves an item behind with a reason unless the player explicitly chose the floor.

Vehicle hauling prefers native trunk storage, then available seat and other storage. The client uses legitimate driver access to unlock storage when possible and restores the player's original seat or outside state. Occupied seats, moving vehicles, inaccessible keys/doors, blocked exits, and unusual modded vehicle access can prevent the operation. A failed restoration is reported with the remaining player location.

Cleanup uses real observed trash cans. It fills a bin before deleting a batch, empties approved existing contents before declaring a capacity failure, and tries another known bin for items that cannot fit. The vanilla command empties the entire bin; preview includes its existing contents, and protected or newly unapproved contents block deletion. Multiplayer servers must allow `TrashDeleteAll`. Cancel cannot recall a trash command that has already been sent. Cleanup does not change server loot respawn rules or guarantee respawn.

## Client-only boundaries

Source discovery is limited to loaded, permitted native locations. Multiplayer's Lua API does not acknowledge an empty container-content response, and its normal inventory UI marks exploration before synchronization completes. Jobs move observed eligible items and report newly searched sources as unconfirmed; they cannot certify a fully cleared building from an empty local list. Human corpse hauling is excluded because its special native action can change held equipment. Native failure remains visible instead of becoming a direct inventory mutation.

Categories and checklists are private local preferences. Container and instance labels persist locally per world and player; they are not automatically shared with other clients. Native fixture identity has no persistent UUID, so an identical replacement in the same location and slot cannot always be distinguished across reconnect. Vehicle memory and labels use the native key ID and model. Lookup requires a unique loaded match and never adopts a nearby car by its appearance or position. Native key IDs are key associations rather than guaranteed UUIDs; keyed-alike modded vehicles can remain ambiguous. Explicit rekeying or a model change requires remembering and labeling the vehicle again. Unloaded remembered locations remain unverified, and observed missing trash cans are retired.

## Develop and verify

```sh
python3 tools/verify.py
python3 tools/verify.py --game /path/to/ProjectZomboid/projectzomboid
python3 tools/play.py --game /path/to/ProjectZomboid/projectzomboid --evidence /path/to/fresh/evidence
```

Portable verification builds the full package before running contracts. The optional native lane needs JDK 25 and repeats contracts in the installed game's Kahlua interpreter. Boundary doubles are explicitly separate from actual gameplay. `tools/play.py` starts an owned Xvfb display and an isolated game cache using the stock game JRE, without reading launcher overrides or touching personal saves. Stop its owning process to terminate and reap its client/display. `--resume` restarts a stopped owned cache for persistence checks. See [verification](docs/verification.md), [design](docs/design.md), [reference findings](docs/research.md), and the [user's own requirements](docs/request.md).
