# LootBox

LootBox is a standalone Project Zomboid Build 42 client mod for looting, sorting, hauling and cleaning up, with categories of your own, storage labels and one-click jobs. LootBox is the working name.

It runs entirely on the client through the game's own actions. There is no server script, command channel or helper mod. A host may distribute it through the ordinary mod list; server permissions, locks, safehouses and capacity always apply. See [verification](docs/verification.md) for what has been tested.

## Install locally

Subscribe to [LootBox on Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3838652822), or install the local package. The Workshop ID is `3838652822`, and the mod ID is `LootBox`.

Extract the built `LootBox-<version>.zip` package. Copy its `Contents/mods/LootBox` directory into your game's local `Zomboid/mods` directory and enable LootBox in the game's Mods menu. Preserve both the `42` and `common` directories. Existing saves and multiplayer servers have their own mod selections. No helper mod or development tools are required to play.

For a development build, use Python 3.10 or later and Lua 5.1.

```sh
python3 tools/build.py
```

The archive is `dist/LootBox-<version>.zip`. `dist/manifest.json` records its file hashes. The build does not download game files or alter a running game. After updating, reconnect or restart to load the new Lua environment. Workshop listing metadata and the preview are kept in `workshop/`; release uploads use the shared SteamWorkshopPublisher.

## How it works

Right-click an item, a container, a container's icon or title, a vehicle, or the ground indoors. LootBox appears as one entry and only when there is something useful to do there: no disabled rows, no settings or help entries, nothing about trash before a trash can is known, nothing about sorting before storage is labelled. One choice is a single row; several become a submenu.

| You right-click | You can get |
| --- | --- |
| An item | All of that type, of its category, or of one of your categories: put in the open container, put away, haul, drop, throw away, or take. Also **On my loot list**, **Keep**, and **Categories** ticks. |
| A container, its icon, its NeatUI title or its empty space | The object's original options (for example Turn on, Settings, Disassemble), then **Take everything**, **Take my loot list**, **Take what I already carry**, **Move contents**, **Put in**, **Throw away contents**, and **Belongs here** ticks. |
| A vehicle | **Load**, **My vehicle**, and the compartments you can reach. |
| The ground | **Around here**: within reach, this room, this building, or an area you mark. |
| The ground, while a job runs | **Job: ...** with Pause, Resume, Stop and Show progress. |

Choosing an action starts it at once. A strip appears when a job takes a while or needs you. It can be dragged, hidden, and clicked open for notes. Press the job key (**F7**, rebindable) to bring it back, or to open the planner when nothing is running.

Starting a new job sets the current one aside; the strip offers to resume it afterwards. Planning or a click with nothing to do never disturbs a running job. Eating, drinking and pouring pause the job and it carries on by itself. Aiming, fighting, running and Escape pause it until you press Resume. Escape that closes a window, menu or text box does not.

## The window

Open it with the job key, from **Around here > Plan a job**, or from **Options > Mods > LootBox**.

- **Plan a job:** choose what, from where and to where. The list below shows what would move, what stays and why. Presets save the whole job and then appear in right-click menus where they fit.
- **Loot list:** categories and items to pick up whenever you loot.
- **Categories:** groups of items, game categories and your other categories. Deleting one removes it wherever it was used.
- **Storage:** every labelled container, where it is, and what belongs in it.
- **Settings:** each switch applies as soon as you click it.
- **Help:** short walkthroughs.

## Inventory buttons

**Smart Take All** and **Smart Take Matching** take from the open containers into your bags. **Match Displayed** and **Match Nearby** put carried items where the same kind already is. They appear only while they have something to do. **Condense** packs loose items into the bags that reduce weight most, keeping the same things together where the weight is equal; Settings adds rearranging what is already in bags, unworn bags and bags inside bags. Keys stay in main inventory or go on a key ring, because the game looks for them nowhere else, and a labelled bag takes only what its label names.

## Container icons and titles

Right-clicking a container's icon, or its title in NeatUI Inventory, gives the options of exactly that object. Options the bare floor also offers (Walk to, Sit, other mods' global entries) and options about other objects on the same tile are left out. When the game's own lookup would dismantle a lookalike instead, Disassemble is unavailable there. **Options > Mods > LootBox > Activate the clicked container** controls whether the click also selects it.

## Pouring

Right-click a vessel and choose **Pour Into** or **Fill From**, directly after the game's Fluid entry. Only vessels and fixtures that fit are listed, each with its contents and space. **Pour into all** and **Fill all** need at least two targets and never mix liquids; mixing is always a single row that says so. Favorite and Keep vessels can be filled in place. If another mod already provides Pour Into, LootBox keeps its entry inside its own submenu.

A vessel on a shelf or on the ground is fetched, used and put back where it was. If something stops the work, what was fetched goes back when it can, and otherwise the message says what you are still carrying.

### Water dispenser

Right-click a carried vessel and choose **Pour Into > Water Dispenser**, or right-click the stand and choose **Refill dispenser**. Pick one source, or **Fill from all <liquid>**. LootBox walks to the stand, takes the bottle, pours, and fits the same bottle again, with the game's own actions in single-player and multiplayer. Other things may happen in your inventory meanwhile. If nothing can be poured the bottle is put back; if you stop, the message says the bottle is in your inventory. For an empty stand, **Refill and fit a bottle** lets you choose which loose bottle. To pour out of a mounted dispenser, use the game's **Transfer Fluids**.

## Select an exact stack amount

Right-click a stack with at least two items and choose **Select amount...** directly in the normal item context menu. Enter a whole number and confirm. This highlights that many items in the pane you clicked. It starts no transfer or LootBox job. The **On items and containers** setting controls the option.

For a partial amount, the stack expands and only the chosen item rows or cells are selected. Drag those highlighted rows, or right-click a highlighted row and use the game's ordinary Take, Put in Container, Drop, or other action. Right-clicking an unselected stack header changes the selection normally. Choosing the whole stack selects its collapsed header. Cancel or Escape leaves the current selection alone. The same workflow applies to carried inventory, bags, loot containers, and visible floor stacks.

Counts and source identity are checked again before selection. A stale stack or changed pane is refused rather than silently selecting different loot or reducing the amount. Larger partial selections use the active view's expanded rows or cells in that pane. This is a mouse workflow; controller selection is not qualified. LootBox shortcuts named All of this type retain their bulk meaning, so use normal game actions for the highlighted amount.

## Details

Choose an item checklist, a source, and a destination in the planner. Sources include carried inventory, a selected container, within reach, the current room, the current building, a visually selected area on one floor, or known containers with a chosen label. Including what you carry and looking inside bags are separate switches. Native transfers can refuse nested contents inside external fixtures; affected items remain in place and appear in the result.

Destinations include carried storage, a selected container, a chosen floor location, the remembered vehicle, matching labeled storage, and known trash cans. The list under the choices shows what would move, what stays and why, and what is still to be searched. Start runs a finite job, and the job strip's notes keep the reasons. A trash can check identifies the actual bin, floor, coordinates, observed contents weight, capacity and free space before asking for whole-bin deletion approval. Hauling uses available bag space before main inventory and retries temporary capacity failures after unloading. Unrelated carried items stay protected; a truly hard-limit-blocked cleanup item can use the temporary personal-gear workflow below. A full destination leaves an item behind with a reason. Native floor dropping can use an adjacent permitted tile when the original tile is blocked or full; the job retains that original drop area if the player moves away during an interruption.

Automatic pickup uses the main inventory's live native hard capacity and current capacity weight. The HUD's normal encumbrance threshold does not block hauling; over-encumbrance is allowed. Eligible carried bags are tried before main inventory, independently of whether source-bag searching is enabled. The aggregate destination is named **My inventory (Smart Load)**. Worn bags, held bags and key rings count as storage; the Condense settings add bags that are not worn and bags inside bags. Bags already containing similar item types are preferred. Full or unsuitable bags spill into the next eligible bag; other bags are ordered by actual weight reduction, and main inventory is last. Native clothing-variant aliases count as matching types. Individual bag and main-inventory destinations remain available and receive a direct transfer. Before collecting, LootBox can equip useful carried or found bags in compatible free worn locations, including extra locations declared by other mods, then free hands when the load needs them. It considers what the bag would accept of the load, the room worn bags still have, existing contents and preparation cost, and retains occupied user equipment. A bag that is itself being moved is not put on, except when it is being taken for the player. Native bag conversions preserve observed contents and migrate LootBox labels and Keep to the observed replacement. Only an equipped outer bag's reduction affects nested contents; unequipped bags still count at full carried weight. Preview shares a body-mass reservation across the bags, and each native pickup rechecks item rules, capacity and server acceptance. Unloading and weight-reducing rearrangement remain available while overloaded.

Vehicle hauling prefers native trunk storage, then available seat and other storage. The client uses legitimate driver access to unlock storage when possible and restores the player's original seat or outside state. Occupied seats, moving vehicles, inaccessible keys/doors, blocked exits, and unusual modded vehicle access can prevent the operation. A failed restoration is reported with the remaining player location.

Cleanup discovers native trash-bin locations on nearby loaded floors, including outside a building. It compares carrying trips, available bin capacity, expected emptying operations, and travel and deletion still owed to other bins already used by that job. A larger bin wins when its savings outweigh travel; the biggest bin is not an unconditional preference. Initial travel is estimated. Successful owned walks supply observed travel costs for later choices, and failed routes are avoided during that job. Capacity and access are checked again on arrival. A full chosen bin is emptied before rejecting an item that might fit; a bin whose empty capacity is already too small is not visited merely to empty it.

An uninspected or unloaded bin is approached before use. Its review opens automatically on arrival, even with the progress window closed, and waits while you type. Closing it leaves the job waiting without repeatedly reopening it; **Review bin** reopens it. **Approve bin and continue** approves the inspected contents for native whole-bin deletion. **Try another bin** keeps the job and chooses a different destination. Arrival reviews are optional and off by default. When enabled, **Skip future bin reviews** remembers automatic handling after successful approval. The separate **Start and skip bin reviews** or **Approve and skip further bin reviews** action changes only the current job. Protected items, permissions, identity and native rules are still checked. Approval tokens and skip choices are never saved in a setup. Eligible items already in a usable approved trash can are cleared in place and counted separately from hauled items.

If a cleanup item still exceeds the live hard carry budget after unloading and preparing bags, LootBox can temporarily store whole top-level personal items or bags in ordinary permitted world storage. The staging container is separate from trash, and it plus the recorded personal items and descendants are excluded from cleanup. A local recovery receipt is saved before any movement. LootBox delivers and deletes the heavy load, then restores the personal items and original equipment slots. Planning checks the temporary raw weight needed to pick bags back up, including their contents. If no safe storage and restoration route fits, the item stays with a reason. An interruption, missing item, changed slot or unavailable container retains the receipt and its coordinates; choose **Fetch my gear** on the job strip. **Forget it** stops tracking gear that can no longer be found. User equipment changes are retained, and occupied original slots must be cleared before restoration. A changed world-object index while disconnected can require manual recovery at the recorded location.

The native trash command empties the whole server bin and does not accept an atomic client approval list. Multiplayer has no reliable Lua acknowledgment of an empty container reply; the inspection wait is not proof of server synchronization. Reviews show client-observed contents, and a client mod cannot guarantee protection against unseen or concurrent server changes. Multiplayer servers must allow `TrashDeleteAll`. Cancel cannot recall a trash command that has already been sent. Cleanup does not change server loot respawn rules or guarantee respawn.

## Client-only boundaries

Item discovery is limited to physically loaded, permitted native locations. Building geometry comes from native metadata; walking can stream distant sections before inspecting their sources. Source fixtures, bags, keyed vehicle storage, and floor locations are resolved again after a long delivery trip, while item IDs and types remain strict. Unkeyed vehicles can be used through their live handle but are not adopted after unloading. Multiplayer's Lua API does not acknowledge an empty container-content response, and its normal inventory UI marks exploration before synchronization completes. Jobs move observed eligible items and report newly searched sources as unconfirmed; they cannot certify a fully cleared building from an empty local list. Human corpse hauling is excluded because its special native action can change held equipment. Native failure remains visible instead of becoming a direct inventory mutation.

Categories, interface preferences, checklists, and setups are private local data. Container and instance labels and named setups persist per world and player; they are not automatically shared with other clients. Optional setup and preference documents are separate from labels and Keep, so a damaged optional file does not block ordinary item handling. Native fixture identity has no persistent UUID, so an identical replacement in the same location and slot cannot always be distinguished across reconnect. Vehicle memory and labels use the native key ID and model. Lookup requires a unique loaded match and never adopts a nearby car by its appearance or position. Native key IDs are key associations rather than guaranteed UUIDs; keyed-alike modded vehicles can remain ambiguous. Explicit rekeying or a model change requires remembering and labeling the vehicle again. Unloaded remembered locations remain unverified, and observed missing trash cans are retired.

## Logs

LootBox keeps a local trace in `Zomboid/Lua/LootBox/log/session-<n>.txt` (five sessions, 4 MB each). Every click is one numbered interaction: what was asked and from which control, your character's position, load, bags and action queue, the containers involved, the plan and every reason for leaving an item, each native operation with the state before and after, and how it ended. Starts, ends and problems also go to `console.txt` as `[LootBox] #n`. **Settings > Write a snapshot to the log** adds a full picture for a report; **Keep a detailed log** turns the per-step lines off. The files contain item and container names and coordinates, never leave your computer, and can be deleted at any time.

## Develop and verify

```sh
python3 tools/verify.py
python3 tools/verify.py --game /path/to/ProjectZomboid/projectzomboid
python3 tools/play.py --game /path/to/ProjectZomboid/projectzomboid --evidence /path/to/fresh/evidence
```

Portable verification builds the full package before running contracts. The optional native lane needs JDK 25 and repeats contracts in the installed game's Kahlua interpreter. Boundary doubles are explicitly separate from actual gameplay. `tools/play.py` starts an owned Xvfb display and an isolated game cache using the stock game JRE, without reading launcher overrides or touching personal saves. Stop its owning process to terminate and reap its client/display. `--resume` restarts a stopped owned cache for persistence checks. See [verification](docs/verification.md), [design](docs/design.md), [reference findings](docs/research.md), and the [user's own requirements](docs/request.md).

## Eat or drink Til Full

**Til Full** appears beside the game's own Eat and Drink amounts, only when it would do something. It uses only the items you clicked, one at a time, and stops when that need is met: Eat follows hunger, Drink follows thirst. **Til Full satisfies hunger and thirst together** in Settings makes it continue until both are.

**Open and Eat Til Full** and **Open and Drink Til Full** use the game's own opening recipe, then eat or drink exactly what came out, in single-player and multiplayer. The game fetches the can and the opener and puts the opener back. Other things may arrive or move in your inventory meanwhile. If you are over the carrying limit the game drops the opened food at your feet and LootBox tells you so. Knives (which can injure), alcohol, and packs that hold several items are left to the game's own menu.

Walking is fine where the game allows it. Aiming, fighting, running, Escape or Cancel stop it; an action you queue yourself simply goes first. Spoiled, burnt, frozen, poisonous or alcoholic items and Keep items are refused; favorites are fine when you chose them.

## Automatic food and drink

In **LootBox > Settings > Eating and drinking**, all four switches start **off**:

- **Drink from equipped vessels:** use the liquid in a worn, held or belt-attached vessel. This includes the reservoir in a hydration backpack; it does not mean drinking every bottle in its pockets.
- **Eat and drink from carried supplies:** choose one safe food or beverage from the main inventory or directly inside a carried bag. Nothing on the floor, in a nearby crate or in a vehicle is considered.
- **Carried supplies: search bags inside bags:** extend the second switch into nested carried bags. By itself this does nothing. Locked or protected bags are not traversed.
- **Carried supplies: allow risky can opening:** prefer an ordinary can opener in both single-player and multiplayer. With this switch on, supported stock food cans may instead use the game's sharp-tool recipe at an adjacent craft surface. The game can damage the tool and cut your hand. No bare-handed opening is invented. For automatic opening, the can and tool must be in main inventory; unknown recipes and outputs are skipped.

**Drinking requires Project Zomboid's own Auto-Drink option.** The game already drinks from many equipped pure-water vessels and LootBox leaves that to it. In single-player, an equipped vessel the game selects but does not use gets one retry after 20 seconds of rising thirst. Water and drinks in bags are drunk with the game's ordinary Drink action, which takes the vessel out and puts it back.

A can is opened with the game's recipe and what comes out is eaten at once, in single-player and multiplayer alike.

Automatic intake waits for meaningful thirst (20%) or hunger (25%), then uses one native portion for that need. The manual **Til Full satisfies hunger and thirst together** preference is not used for background intake. LootBox does not interrupt movement, aiming, combat, existing queued actions, an active or paused LootBox job, or pending gear recovery. It skips unsafe, spoiled, alcoholic, medical and unrecognized supplies; favorites and **Keep** items are never chosen. A canceled or unconfirmed portion is not automatically retried in the same need episode. In multiplayer the client can stop requesting work, but it cannot recall a bite or sip the server has already accepted. Manual Eat, Drink and Til Full remain available.

## Inventory navigation shortcuts

Hover the item list in your inventory or the loot window, then use **Home** or
**End** to reach its top or bottom. **Page Up** and **Page Down** move one viewport
with a row of overlap so partially visible rows are not skipped. These shortcuts
only scroll the hovered list; they do not select, transfer, or consume items.
Home and End leave the item popup closed until you move the mouse again.
You can also click the row under the pointer without moving it first.
Change or unbind all four under **Options > Key bindings > LootBox**. Text entry,
context menus, modal dialogs, and item dragging leave the shortcuts inactive.
