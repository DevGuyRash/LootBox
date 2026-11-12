local Guides = {}

Guides.tasks = {
    { id = "loot-room", title = "Loot this room", summary = "Bring the supplies you choose into your carried storage.", guide = "looting" },
    { id = "loot-building", title = "Loot this building", summary = "Walk and search its rooms and floors for your selected supplies.", guide = "buildings" },
    { id = "loot-area", title = "Loot a selected area", summary = "Choose two corners, then collect your selected supplies.", guide = "looting" },
    { id = "sort-carried", title = "Sort my carried items", summary = "Put eligible items into storage with matching labels.", guide = "sorting" },
    { id = "haul-car", title = "Haul supplies to my car", summary = "Fill your remembered vehicle, starting with the trunk.", guide = "vehicles" },
    { id = "clean-room", title = "Clean this room", summary = "Review and haul unprotected items to real trash cans for deletion.", guide = "cleaning" },
    { id = "clean-building", title = "Clean this building", summary = "Search its rooms and floors, then haul approved items to trash cans.", guide = "buildings" },
    { id = "clean-area", title = "Clean a selected area", summary = "Choose an area and review its unprotected items for deletion.", guide = "cleaning" },
}

Guides.list = {
    {
        id = "first-run", title = "Start here: your first loot run",
        summary = "Choose what you want, where to look, and where it should go.",
        prerequisites = "Enable LootBox through the game's Mods menu and the save or server mod list you use. No helper mod is required. Stand in a small, safe room with free carrying capacity and a few spare items.",
        steps = {
            "Choose Loot this room on Home, or right-click the floor and open LootBox > Loot supplies > Current room.",
            "Choose categories or item types to look for. Categories select a reusable group; an item type selects every matching copy. You do not need to label the room's containers.",
            "Leave the destination as My carried storage. Include bags lets the job use and inspect nested bags without changing your equipment.",
            "Review the proposed moves. Check the item count, destinations, exclusions, and any sources that still need inspection.",
            "Start the job. The character walks and transfers through ordinary game actions. Closing any LootBox window keeps it running. Open Current job to check progress or choose Cancel job.",
            "Check the actual inventory and the result panel. Save the setup with a name if you want to repeat this workflow.",
        },
        expected = "Matching eligible items reach carried storage. Held, equipped, attached, favorite, and kept items stay protected. Items without capacity or access remain with a reason.",
        troubleshooting = {
            "No selection: choose at least one category or item type before reviewing.",
            "No room: stand inside the room, or choose Within reach or An area.",
            "Unconfirmed source: multiplayer has not supplied a reliable acknowledgment of that container's contents. The job cannot certify that the room is empty.",
        },
        task = "loot-room",
    },
    {
        id = "looting", title = "Loot a room, building, or area",
        summary = "Collect a checklist without marking every container you visit.",
        prerequisites = "Choose the supplies you want. The character must be able to walk to the selected sources and inspect them through native actions.",
        steps = {
            "Open Actions and choose Loot matching items. Choose Current room, Current building, Within reach, or A selected area as the source.",
            "For an area, choose Select area and click two opposite corners on the current floor. Escape or right-click cancels selection.",
            "Select one or more categories or item types. A custom category can combine a complete loot-run checklist.",
            "Choose My carried storage, or use Move if you want a different destination. Include my carried items is separate from the world source and is optional.",
            "Review before starting. Unopened containers may need an approach and native inspection; locally empty multiplayer sources can remain unconfirmed.",
            "Start, watch progress, and check left-behind reasons. Save the setup to reuse its selection and routing.",
        },
        expected = "The job makes finite trips through the selected scope. Building jobs walk and inspect small sections across the building's floors. The item count grows as matching contents are observed.",
        troubleshooting = {
            "A building job must walk before inspecting distant sections. Blocked routes and sections that do not load remain unsearched in progress and the result.",
            "A selected area is tied to its saved world coordinates and floor. Review those bounds before reusing it.",
            "A job does not wait for future loot respawns. Run it again when you want another pass.",
        },
        task = "loot-area",
    },
    {
        id = "buildings", title = "Search or clean a whole multi-floor building",
        summary = "Walk through a large building in sections and keep track of areas the job could not search.",
        prerequisites = "Stand inside the building with a safe route through its doors and stairs. Cleanup also needs an accessible native bin and multiplayer TrashDeleteAll permission. A detached garage or neighboring building is a separate scope.",
        steps = {
            "Choose Loot this building or Clean this building on Home. The floor context menu also offers Loot supplies > Current building and Clean and delete > Clean current building.",
            "Check Current building under Where to look. Choose your item types or categories, or All unprotected items for a broad cleanup. Carried items are separate and remain excluded unless you enable them.",
            "Review the observed items and the number of rooms to survey. The room count is an itinerary, not a claim that every container has already been searched.",
            "Start the reviewed job. The character walks through small sections on each room's floor and inspects sources as those locations load. Large buildings do not need a single complete tile scan before starting.",
            "Watch Rooms processed, Sections searched, and Unsearched in Current job. Read the unsearched-room rows for the room, floor, and blocking reason. Pause job returns control when a route becomes unsafe; Resume job continues the same search afterward.",
            "During cleanup, a bin may be outside or on another floor. Bin choice compares travel, carrying trips, and bin emptyings. Travel starts as an estimate and improves from completed walks; the biggest bin is not always the least work.",
            "If a destination needs inspection, the character approaches it. A bin review opens automatically on arrival unless you chose to skip reviews for this job. Approve bin and continue retains this building search and item selection; Try another bin skips that destination. Closing the review leaves the job waiting. Reopen it with Review bin in Current job.",
            "Check the final result and actual storage. Resolve blocked stairs, permissions, or unavailable sections before another pass. A multiplayer source reported as unconfirmed is not certified empty.",
        },
        expected = "Accessible building sections are inspected in a finite pass across the native building's rooms and floors. Observed matching items are handled, while unsearched sections and unconfirmed sources remain visible.",
        troubleshooting = {
            "Rooms processed means their geometry has been attempted. Check Sections unsearched and the reason rows before treating a building as searched.",
            "Bin discovery identifies native bins in nearby loaded locations on the ground and the current building's floors. Finding a static bin does not approve its contents. If no bin can be found or reached, approach one before another pass.",
            "The bin review identifies its name, floor, location, and observed load and free capacity. Review its existing items before choosing Approve bin and continue. Protected observed items block approval. Try another bin keeps the current job and chooses another destination.",
            "The bin review shows client-observed contents. Multiplayer does not acknowledge empty replies to Lua, and a client mod cannot make deletion atomic against concurrent shared-bin changes.",
            "A route estimate is not an independent native path query. Failed routes are avoided during the job; changed doors, stairs, capacity, and contents are checked again during movement and transfer.",
        },
        task = "loot-building",
    },
    {
        id = "categories", title = "Build a reusable custom category",
        summary = "Combine individual item types, game categories, and other custom categories.",
        prerequisites = "The category editor works from the main menu as well as in game.",
        steps = {
            "Open Categories and choose New custom category. Give it a name that describes your intention, such as Run supplies.",
            "Choose Include categories and select the game or mod categories you want. All native categories remain available; My categories narrows the list to your own definitions.",
            "Switch to Include item types to add specific exceptions, such as Bandage. Search by display name or exact item ID.",
            "Include another custom category when you want a nested group. Included groups form a union, so an item is matched once even when several rules include it.",
            "Check the matching-item count and save. Circular category definitions are refused with a reason.",
            "Use the category in an action checklist or as a storage label. Editing it updates future matching without relabeling every item.",
        },
        expected = "Your category appears separately from game categories and persists across restarts. Native categories follow the installed item catalog rather than a fixed preset list.",
        troubleshooting = {
            "Game categories are read-only. Include one in a custom category to extend it.",
            "Item type means every copy of that type. A label on an individual item affects that copy only.",
            "A referenced category cannot be deleted until its inclusions and active labels are removed.",
        },
    },
    {
        id = "sorting", title = "Label storage, then sort your bags",
        summary = "Teach containers what belongs there and reuse those rules.",
        prerequisites = "Choose one or more accessible containers. Labels are private preferences for this world and player.",
        steps = {
            "Right-click the actual container and choose LootBox > Label this container, or open Labels and choose the storage target.",
            "Select every category the container should accept, then save. A crate may accept Food and Medical at the same time.",
            "For a special copy you want to retain, open that item's tags and turn on Keep. Favorites, held equipment, attachments, and nonempty bags are also protected automatically.",
            "Choose Sort my carried items on Home. Its source is carried inventory, including nested bags, and its destination is Labeled storage.",
            "Review the routes. Each eligible item should have a matching destination; unlabeled, full, unavailable, or disallowed storage gives a left-behind reason.",
            "Start and inspect the result. Save a named setup if you want to sort only a narrower selection next time.",
        },
        expected = "Eligible items move to containers with matching labels. Kept items stay carried. A full container does not silently cause a floor drop.",
        troubleshooting = {
            "No matching storage: label a loaded container with a category that actually matches the item.",
            "Storage rules and item tags are different. A storage label accepts matching items; an item tag adds only that copy to a category.",
            "A multi-compartment fixture can have different labels per compartment. Check the target name before saving.",
        },
        task = "sort-carried",
    },
    {
        id = "select-amount", title = "Select an exact amount from a stack",
        summary = "Highlight a chosen number of items, then use the game's normal inventory actions.",
        prerequisites = "Use the mouse and open an inventory, bag, floor, or loot pane containing at least two items in one stack. Enable Inventory and container shortcuts in Settings.",
        steps = {
            "Right-click the stack or one of its expanded item rows and choose Select amount. This option is directly in the item's context menu.",
            "Enter a whole number from 1 to the shown stack count. Confirm with OK or Enter. Cancel or Escape leaves your selection unchanged.",
            "A partial amount expands the stack and highlights only that many real items. Large partial amounts expand far enough to include your chosen items. Selecting the whole stack keeps its header selected.",
            "Drag the highlighted items, or right-click a highlighted item row and choose the normal Take, Put in Container, Drop, or other game action. The same selection works in both inventory and loot panes.",
            "Check the result in the source and destination. Select amount only changes the highlight; it does not start a LootBox job or move anything by itself.",
        },
        expected = "The requested number is highlighted in the pane you clicked. Native actions can use that selection afterward.",
        troubleshooting = {
            "No option: the clicked native stack must contain at least two real items and remain visible in a mouse-controlled inventory or loot pane.",
            "Use a highlighted child row after a partial selection. Right-clicking an unselected stack header normally replaces the selection with that whole stack.",
            "If the stack or pane changes while the prompt is open, close it and right-click the stack again. Counts are checked again before selecting; amounts are never silently reduced.",
            "LootBox shortcuts named All of this type still use their stated bulk scope. Use the game's normal actions when you want only the highlighted items.",
        },
    },
    {
        id = "container-contents", title = "Loot, empty, sort, or clean one container",
        summary = "Act on the contents of the exact bag, crate, corpse, or vehicle compartment you click.",
        prerequisites = "Enable Inventory and container shortcuts in Settings. Open an accessible container in the inventory or loot window. For sorting, label destination storage first. Cleanup needs an accessible native trash can and multiplayer TrashDeleteAll permission.",
        steps = {
            "Right-click the container's sidebar icon and open LootBox. Right-clicking a bag item opens its item actions; choose Contents of the named bag to act on what is inside. An empty inventory or loot pane also offers its displayed container's actions. Use the sidebar icon when a pane contains items.",
            "Choose Loot contents for external storage. For a carried bag, Unpack contents to main inventory moves eligible contents into your main inventory. Neither action moves the bag or other containers' items.",
            "Choose Empty contents onto floor here to place eligible contents at your current position. Emptying never deletes items. The floor itself does not offer this action.",
            "Choose Sort contents to use matching storage labels. Move contents to offers the visible inventory and loot containers plus your remembered vehicle. Each named compartment is a separate destination.",
            "Choose Label this container to set every category that belongs there. To move only selected categories or item types, choose Choose items and categories. Actions opens with the clicked container as the source.",
            "Choose Clean contents only when you intend deletion. Review selected items and existing trash-can contents before approval. A later bin review opens automatically on arrival. Approve it or try another bin. Start and skip bin reviews authorizes eligible inspected bins for this job while retaining protection and native checks.",
            "Check the source and destination names in the review. Include bags controls nested contents. Protected items stay excluded, and the source container itself stays in place.",
            "Start and inspect the result. Closing a window keeps the job running. Pause job lets you deal with a threat; after the pause settles, Resume job continues remaining work with fresh checks.",
        },
        expected = "Only eligible contents of the chosen source move or get deleted. Other open containers do not become sources because you selected a different sidebar icon earlier.",
        troubleshooting = {
            "No contents actions: check Settings > Inventory and container shortcuts. The context-menu master setting must also be enabled.",
            "Unpack leaves items behind: main inventory still needs native carrying capacity. Review the reported reason or choose another container under Move contents to.",
            "A nonempty nested bag stays protected, while its eligible contents can move when Include bags is enabled. Keep, favorites, held equipment, and equipped items remain protected.",
            "Move contents to lists currently visible storage icons. Open the intended destination nearby, or use your remembered vehicle. Locked, forbidden, missing, or full storage still follows native access and capacity checks.",
            "Native transfers can refuse nested contents inside external storage. Carry that bag first and try its Contents menu again. Review anything left behind.",
            "Cleanup deletes contents through approved trash batches. The clicked crate, bag, or vehicle compartment itself is never deleted by a contents action.",
        },
    },
    {
        id = "bags", title = "Move one item type across nested bags",
        summary = "Use a right-click shortcut for repeated take, put, or drop operations.",
        prerequisites = "Have some spare matching items in carried storage or a nearby container.",
        steps = {
            "Right-click an item and open the LootBox submenu. The type shortcuts refer to every eligible copy of that exact item type.",
            "Choose Drop all of this type, Take all of this type, or Put all of this type in the shown container. Available actions depend on the clicked source and the currently selected storage destination.",
            "Use the category submenu for a broader native or custom category. Its label tells you which group will be selected.",
            "Review the compact summary. Adjust setup opens the full composer when you want a different scope, destination, or bag option.",
            "Start and compare the moved count with the actual inventories. Nested carried bags are inspected through native transfers without equipping or dropping them.",
        },
        expected = "All eligible copies in the chosen source are handled. An equipped or nonempty bag itself remains protected while eligible contents can move.",
        troubleshooting = {
            "Turn on Include bags when you want nested contents included.",
            "Protected copies are deliberately excluded. Check Keep, favorite, equipped, held, and attached state.",
            "Put here uses the named selected container. Use Adjust setup if that is not the target you intended.",
        },
    },
    {
        id = "vehicles", title = "Remember a car and haul supplies",
        summary = "Use native vehicle access, trunk capacity, and available seat storage.",
        prerequisites = "Use a loaded vehicle you can legitimately access. Do not begin while it is moving.",
        steps = {
            "Right-click the vehicle and choose LootBox > Remember this vehicle. You can also use the control in Labels while seated inside it.",
            "Choose Haul supplies to my car, then select categories or item types. Choose carried inventory or a world source such as a room or area.",
            "Leave My remembered vehicle selected, or choose the explicit loaded car you intend to use.",
            "Review the routes and capacity. Trunk storage is preferred, followed by available seat and other storage.",
            "Start. When needed, the character uses native driver access to unlock storage, opens the appropriate door, transfers items, and restores the original seat or outside state.",
            "Inspect the car and result panel. The remembered key association and model can resolve again after reconnect; an explicit rekey or model change needs a new selection.",
        },
        expected = "The chosen supplies reach available vehicle storage. No unrelated seat cargo is displaced to make driver entry possible.",
        troubleshooting = {
            "Locked or inaccessible: provide legitimate key or driver access; the mod cannot bypass native permission checks.",
            "Multiple cars share a key and model: select the intended car explicitly. Native key associations are not guaranteed unique identifiers.",
            "Restoration blocked: read the reported player location and finish the seat or exit action manually before another job.",
        },
        task = "haul-car",
    },
    {
        id = "cleaning", title = "Clean a room, building, or area in batches",
        summary = "Haul approved items to real trash cans, fill them, then delete a batch.",
        prerequisites = "Locate an accessible native trash can. Begin with throwaway items and an empty bin. Multiplayer must allow TrashDeleteAll.",
        steps = {
            "Right-click the floor and open LootBox > Clean and delete > Clean current room, Clean current building, or Clean an area. Actions also offers Clean and delete items with narrower category or item-type filters.",
            "Check the scope carefully. Room, building, and area shortcuts select all unprotected items in that world scope; carried inventory is not included automatically. A selected area covers one floor.",
            "Read the cleanup review. The native trash command empties the entire bin, so listed existing bin contents are included in the approval. Static bin discovery does not approve unseen contents.",
            "Choose Start cleanup and delete after checking the items and warnings to review each new bin on arrival. Start and skip bin reviews instead approves eligible inspected bins automatically for this job. Both choices retain native access, protected-item, changed-content, and server deletion checks. A saved setup never reuses this permission.",
            "When an uninspected destination is found, the job approaches it. With reviews enabled, the bin review opens automatically on arrival and waits while you are typing. Check the observed contents, then choose Approve bin and continue or Try another bin. Approve and skip further bin reviews changes only this job. Back leaves the job waiting; Review bin in Current job reopens it.",
            "The job collects a carrying load and compares eligible bins using travel, carrying trips, and bin emptyings. It fills the selected bin, empties approved batches, and repeats.",
            "Inspect the result. Items already in the bin can be cleared in place and are counted separately from hauled items. An eligible full bin can be emptied and reused. An item too large for its empty capacity needs another bin. Missing or inaccessible bins, protected contents, and changed unapproved contents are reported.",
        },
        expected = "Items are deleted in capacity-filled batches rather than one deletion command per item. Observed protected possessions and unapproved new bin contents block deletion. A bin review continues the existing job without requiring another item selection.",
        troubleshooting = {
            "Cancel cannot recall a deletion command already sent to the host.",
            "A bin can be outside the room or on another floor. The job approaches a remembered location and revalidates the real bin before use. Blocked stairs, missing bins, and locations that do not load remain reported failures.",
            "Initial travel costs are estimates; completed native walks improve later choices. Every new bin is inspected. Manual approval is the default; only the explicit skip-review choice enables automatic approval for this job.",
            "A multiplayer bin review shows client observations. Empty replies are not acknowledged to Lua, and concurrent shared-bin changes cannot be made atomic by a client mod. The review cannot certify that unseen server contents are absent.",
            "Cleanup does not change loot-respawn settings or guarantee that a room will respawn loot.",
        },
        task = "clean-room",
    },
    {
        id = "setups", title = "Save a complete setup and repeat it",
        summary = "Remember your selection, source, destination, and bag options together.",
        prerequisites = "Configure an action that you expect to repeat. Named setups belong to the current world and player.",
        steps = {
            "Open Actions and configure what to move, where to look, where it goes, and whether to include carried or nested bag contents.",
            "Give the setup a descriptive name and save it. Use the named setup picker or the Saved setups context submenu to use it later.",
            "Review the resolved targets. A selected-container setup uses the container you click next time; it does not keep a stale native container object.",
            "Room and building scopes use your current location. Floor placement uses the clicked or current tile. A saved area retains its world coordinates and floor.",
            "Adjust or update the setup when your intention changes. Delete a saved setup when you no longer need it; this does not delete its categories or items.",
            "Remember last setup can retain an unfinished action between visits. A specific right-click type or category action still takes priority over that remembered setup.",
        },
        expected = "Repeated actions need less setup. Every run gets a fresh preview and current item, permission, capacity, and trash checks.",
        troubleshooting = {
            "Missing clicked container: right-click the desired container, or choose another destination in Actions.",
            "A removed category or unavailable item selection needs editing; the saved setup is not silently erased.",
            "Save checklist stores only what to select. A named setup also stores the source, destination, and options.",
        },
    },
    {
        id = "settings", title = "Choose your interaction style",
        summary = "Keep the full manager, enable useful shortcuts, and hide unwanted groups.",
        prerequisites = "Open Settings in LootBox, or use its Settings button in the game's Mods options.",
        steps = {
            "Use the context-menu master setting to show or hide LootBox's right-click entry.",
            "Choose the inventory, world, vehicle, category, and saved-setup shortcut groups you want. Turning off a group does not change categories or stored items.",
            "Leave quick-move confirmation enabled while learning. If disabled, ordinary quick transfers can start after planning without a confirmation window.",
            "Cleanup always requires an explicit review and deletion approval, regardless of the quick-move preference.",
            "Choose whether the manager remembers the last setup and shows inline tips. The full manager and Help remain available from the game's Mods options.",
        },
        expected = "Preferences persist locally without resetting another mod's pending options or changing native server settings.",
        troubleshooting = {
            "No right-click entry: open Options > Mods > LootBox and check the context-menu settings.",
            "No LootBox controls after joining multiplayer: the client scripts must be active through the host's normal mod selection or your supported client loader.",
        },
    },
    {
        id = "problems", title = "Understand exclusions, progress, and cancellation",
        summary = "Read what moved, what stayed, and what the game could not confirm.",
        prerequisites = "Open the review or Current job panel for the action you are checking.",
        steps = {
            "Compare the proposed source and destination with the actual target names before starting.",
            "Read each decision row. Item names are blue, the status has its own color, and the explanation stays normal text. Protected means the item stays safe; its exact reason tells you whether it is kept, favorite, equipped, held, attached, or a nonempty bag.",
            "Unopened containers can require native inspection after approach. An unconfirmed multiplayer response does not establish an empty container or a fully cleared room.",
            "For building jobs, rooms processed counts attempted geometry. Sections searched and unsearched, plus the unsearched-room rows, show which floors and locations still need attention.",
            "Drag the bottom-right grip to resize the manager, a review, or Current job. Existing choices, unsaved edits, and search text stay in place.",
            "Closing any LootBox window hides that window and keeps the job running. Reopen Current job from a LootBox right-click menu, the manager, or its key, F7 by default. Change the key in Options > Key bindings > LootBox.",
            "Choose Pause job before dealing with a threat. Aiming or combat also pauses automatic work. Slight movement and ordinary queued actions such as eating or drinking let the job wait and continue automatically. Cancel job stops it.",
            "After the pause or stop has settled, choose Resume job to continue the remaining work. A fresh bin review may be needed. Resume does not bypass changed items, protection, access, or capacity checks.",
            "If personal gear was temporarily stored for a heavy haul, Current job offers Recover gear even after cancellation or reconnect. Read its saved storage location and recovery reason. Recovery checks the original containers and equipment slots before returning items.",
            "If a destination or source changes during a job, the next native action is checked again. No direct inventory mutation is used to force a rejected transfer.",
            "Check the real inventories and the final moved and cleared-in-place counts and notes. A note may describe a protected item, an unavailable destination, or an unconfirmed source; it is not always another item left behind.",
        },
        expected = "A successful queued action is counted only after its observed native result. Failure stays visible with the remaining item or player location.",
        troubleshooting = {
            "Native locks, safehouses, carrying limits, and server trash policy remain authoritative.",
            "Human corpse hauling is excluded because its special native action can change held equipment.",
            "If saved preferences are damaged, the error is shown without overwriting the damaged document or your unrelated category and label data.",
        },
    },
}

local taskRequests = {
    ["loot-room"] = { scope = "room", kind = "inventory" },
    ["loot-building"] = { scope = "building", kind = "inventory" },
    ["loot-area"] = { scope = "area", kind = "inventory" },
    ["sort-carried"] = { scope = "inventory", kind = "labels", all = true },
    ["haul-car"] = { scope = "inventory", kind = "vehicle" },
    ["clean-room"] = { scope = "room", kind = "trash", all = true },
    ["clean-building"] = { scope = "building", kind = "trash", all = true },
    ["clean-area"] = { scope = "area", kind = "trash", all = true },
}

function Guides.get(id)
    for _, guide in ipairs(Guides.list) do if guide.id == id then return guide end end
end

function Guides.prepare(id, app, context)
    local task = taskRequests[id]
    if not task then return nil, "Choose an available workflow" end
    if not app then return nil, "Enter a game to set up this workflow" end
    local filter = task.all and { ids = {}, types = {}, all = true } or app:getChecklist()
    return app:resolveSetup({ scope = task.scope, includeInventory = false, includeBags = true,
        filter = filter, destination = { kind = task.kind }, sourceLabels = {} }, context or {})
end

return Guides
