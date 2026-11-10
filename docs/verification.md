# Verification

Build the complete mod before adding or running focused tests. Python 3.10 or later and Lua 5.1 (`lua5.1`, `luac5.1`) are development tools; they are not runtime dependencies for players.

```sh
python3 tools/build.py
python3 tools/verify.py
```

The build enforces ASCII runtime source, Lua 5.1 syntax, and executable Lua exclusively under `media/lua/client`. It packages the `common` resource directory and the versioned mod and records file and archive hashes. The verifier runs category/storage and native-boundary integration suites, keeps logs and a JSON report outside Git, and fails if source files change during the run. Tests derive expected category unions, capacity-limited trips, cleanup batches, protected items, and cancellation behavior from the request or explicit hand-worked fixtures.

## Native interpreter and file APIs

Use a legally installed game directory containing `projectzomboid.jar`, `stdlib.lua`, and `jre64/bin/java`. JDK 25 is required to compile the development-only Java runner against the inspected game JAR.

```sh
python3 tools/verify.py --game /path/to/ProjectZomboid/projectzomboid
```

This lane runs the production Lua modules in the installed game's Kahlua engine. Native object/action doubles remain doubles, even in Kahlua. The file-I/O smoke check uses actual native file readers/writers with a temporary cache and home; it must roundtrip production Store data and validate native generation files. Compiled classes and temporary cache contents are removed. Licensed game files are read in place and are never packaged.

## Actual game checks

Launch an isolated client with a fresh cache, owned Xvfb display, packaged mod, and stock JRE. The launcher bypasses installed launcher overrides and does not touch a user's running game.

```sh
python3 tools/play.py --game /path/to/ProjectZomboid/projectzomboid --evidence /path/to/fresh/evidence
```

Read `session.json` for its display and owned process identities. Drive only that display. Use native Mods and Options controls to check discovery, category creation, nesting, item-type selection, errors, and reopening. Use an isolated save for actual looting, room/building/area jobs, carried nested bags, multi-label routing, vehicle access and fallback, repeated fill/delete cycles, cancellation, changed destinations, and reconnect persistence. A normal multiplayer server may enable the mod; it must have no LootBox executable server/shared files. Keep host trash and item-count policy enabled/disabled cases separate.

Stop the launcher owner and wait for its client/display to be reaped. `--resume` can restart that stopped owned cache to test saved preferences. Keep selected logs, screenshots, package hashes and reports outside Git. Remove disposable worlds, generated test credentials and caches when no longer needed. Do not claim complete room clearing from an unacknowledged native multiplayer container response.

## Current qualification

The current development candidate was checked on Linux with the installed Project Zomboid 42.22.2 engine. The complete verifier passed with stable source: 25 category/storage, 7 App, 22 job, 23 native-adapter, and 24 world-boundary cases passed in both Lua 5.1 and Kahlua, plus actual native file-I/O verification. Those 101 contracts in each interpreter remain distinct from gameplay.

| Real user path | Observed result |
| --- | --- |
| Main-menu installation and category management | Native Mods discovery and Options entry worked. A custom Food inclusion matched 707 native types. Another category nested it and added `Base.Bandage`, matching 708 types; both saved and reopened after a process restart. |
| Single-player looting and cancellation | The character walked to native storage and collected 9 selected food items. Cancel stopped the job before the tenth. |
| Multiple labels, Keep, and sorting | A container accepted Food and a custom category; an instance received two custom memberships and Keep. Sorting moved the other 8 food items into labeled storage and retained the kept item. |
| Visual area selection | Two world clicks rendered the native highlight and restored a 1-by-2 tile selection on floor 0. Right-click cancellation retained the previous area. Escape cancellation restored the composer and retained its filters in multiplayer. |
| Normal multiplayer activation | An ordinary disposable account joined a loopback native server with `Mods=LootBox`, `DoLuaChecksum=true`, and zero executable LootBox server/shared Lua files. Matching source files were staged at server startup. A running host's cached checksum correctly rejected a client-only source update until a fresh matching server was started. |
| Nested carried bags and batch cleanup in multiplayer | An unequipped small backpack inside an equipped larger backpack held 8 nails; the outer bag also held 4 planks. The job moved all 12 selected items without changing equipment. A 10-capacity native bin already contained 8 approved nails. Unmodified server logs recorded exactly two `object.emptyTrash` calls, removing batches of 11 and 9 items: three planks plus existing nails, then one plank plus the nested nails. The final bin was empty and unrelated bag contents remained. |
| Multiplayer floor transfers | Four canned items were dropped through LootBox and then taken back through the floor inventory context menu. Each job reported 4 moved and zero left; the native floor and inventory views confirmed the changes. |
| Vehicle access and hauling in multiplayer | The job entered the driver's seat, unlocked storage through native actions, restored the original outside state, opened the trunk, and moved all 5 selected food items into it. |
| Vehicle capacity and remembered target | The Remember vehicle control saved successfully. A 19-plank, 57-weight floor load was hauled to that remembered vehicle; the job finished with 19 moved and zero left. Preview reserved 17 planks for the trunk and 2 for the driver's seat, and the native seat view showed those 2 planks at weight 6 of 20. |
| Repeated no-op requests | Two consecutive previews with no eligible carried materials showed zero moves and disabled Start. |
| Multiplayer reconnect persistence | The final package saved a remembered vehicle and a First Aid label on its driver's seat. After a normal disconnect and reconnect to the same host, the default remembered destination resolved to the trunk, and labeled storage resolved to that seat. A transfer to the remembered car finished with 1 moved and zero left. The native trunk inventory showed the bandage and the character returned outside. |

Evidence is outside Git under the app-verification LootBox state directory. `verify-delivery/report.json` records the final stable-source aggregate. The final client package is `20261110-first/package-8/`, and the matching host package is `mp-stable-keys/package/`; their file manifests match the verified source. Screenshots 267, 268, 275, 276, 277, and 280 record the final remember, label, reconnect, preview, and completed transfer controls. Earlier batch and overflow gameplay used client package 5 with host `mp-identity-fixed`; the Native and Jobs modules are unchanged in the final package. `mp-identity-fixed/batch-deletion-proof.json` records the native removal groups. Selected screenshots, native command excerpts, and videos show the actual controls and resulting states. Live checks rejected the initial reference-based transfer observer, premature account binding, and mechanical vehicle identity. The final package uses immutable item IDs, interactive account binding, and persisted vehicle key associations.

Windows, macOS, controller navigation, mod combinations, unusually large buildings or vehicle collections, modded vehicle door rules, blocked restoration under live multiplayer contention, and every moved/removed trash-can case are not qualified by these runs. Multiplayer's unacknowledged empty-source limitation remains an explicit incomplete result; the mod does not claim complete building clearance from it. Workshop publication and subscribe-only installation were not performed.
