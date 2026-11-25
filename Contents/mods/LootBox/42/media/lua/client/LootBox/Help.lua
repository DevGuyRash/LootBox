-- Workflows, start to finish, in the words used on screen.
local Help = {}

local function request(scope, kind, all)
    return function(app)
        local list = app:getChecklist()
        return { scope = scope, includeInventory = false, includeBags = true, sourceLabels = {},
            filter = all and { all = true, ids = {}, types = {} } or { ids = list.ids, types = list.types, all = false },
            destination = { kind = kind, labels = {} } }
    end
end

Help.topics = {
    { id = "start", title = "Start here", summary = "LootBox moves things for you: loot, sort, haul, and throw away. Right-click is the quick way in, the planner covers everything else.",
        steps = {
            "Right-click an item, a container, its icon in the loot window, or the ground indoors. LootBox appears only when it has something useful to do there.",
            "Choose what you want. The job starts straight away and your character does the walking. Close any window; the job keeps going.",
            "A small strip shows progress when a job takes a while. Click it for notes. Press the job key (F7 unless you changed it) to bring it back, or to open the planner when nothing is running.",
            "Aiming, fighting, running or Escape pauses the job. Eating, drinking and small movements don't cancel it. Press Resume when you are safe.",
        } },
    { id = "loot", title = "Loot a room or building", summary = "Collect only what you care about.",
        steps = {
            "Build a loot list once: right-click things you like and tick Pick up when looting, or use the Loot list page.",
            "Stand in the room and right-click the floor. Choose LootBox, Around here, This room, Take my loot list.",
            "This building works the same way and walks every floor it can reach.",
            "Items go into your bags first, next to similar items, then into your main inventory.",
        },
        notes = { "Keep, favorite, worn and held items stay with you.", "A place your character cannot reach is listed in the notes instead of being retried forever." },
        request = request("room", "inventory") },
    { id = "sort", title = "Put things away", summary = "Tell LootBox once where things go. One button does the rest.",
        steps = {
            "Open a container, right-click something in it and tick Belongs here. Every one of that kind now goes there. For many at once, right-click the container and use Belongs here, Label with the categories inside.",
            "The container's title and icon say what belongs in it. Hover any item to see where it goes.",
            "Carry your loot home and press Put Away in the inventory window. Hover the button first to see what goes where.",
            "Right-click an item and open Where it goes to choose among all your storage, for its whole category, or for this one item only.",
            "On the Storage page give a container a name, fill it first or last, or let it take anything else. Show me points the way to it.",
        },
        notes = { "An item without a place stays with you.", "Keep, favorite, worn and held items stay with you.",
            "A label for that very item counts most, then where the same thing already is, then one of your categories, then a game category, then the nearest." },
        request = request("inventory", "labels", true) },
    { id = "home", title = "Put away by itself", summary = "Off unless you turn it on in Settings, Storage.",
        steps = {
            "Home is anywhere near storage you have labelled. Leaving it, LootBox notes what you carry; that stays with you.",
            "Back home, stand still for a moment. What you picked up on the way is put in its places. So is what you take out of a vehicle.",
            "Move, fight, open a menu or start anything yourself and it stops for good. Put Away finishes the rest whenever you like.",
        },
        notes = { "It waits while zombies are near.", "It never touches what you left with, or Keep, favorite, worn and held items." } },
    { id = "categories", title = "Make your own categories", summary = "One name for any mix of items and other categories.",
        steps = {
            "Open the Categories page and press New category, or right-click an item and choose Categories, New category.",
            "Pick items, game categories, or your other categories. They are added together.",
            "Use it anywhere: the loot list, storage labels, and the planner.",
        } },
    { id = "haul", title = "Haul to your car", summary = "Trunk first, then the seats.",
        steps = {
            "Right-click your car and tick My vehicle. LootBox remembers it.",
            "Right-click a container and choose Move contents, My vehicle. Or use the planner to send a whole room.",
            "If the car is locked and you have the key, your character unlocks it from the driver's seat and comes back out.",
        },
        notes = { "When the car is full the job pauses instead of walking back and forth." },
        request = request("room", "vehicle") },
    { id = "clean", title = "Clean up", summary = "Throw things away in real trash cans.",
        steps = {
            "Walk past a trash can once so LootBox knows it. It uses the cans within 150 tiles.",
            "Right-click the floor and choose LootBox, Around here, This room, Throw everything away. Or right-click one container and choose Throw away contents.",
            "Your character fills the can, empties it, and carries on until the room is clear. The nearest can is used, or a bigger one close by when the load is big.",
            "Emptying a can deletes everything in it. Turn on Ask at each trash can in Settings to be asked whenever a can holds something you have not agreed to lose.",
        },
        notes = { "A can holding a Keep or favorite item is never emptied.", "If no can works, the job pauses with your load. Resume tries again.", "Something too heavy to carry can wait while your own gear is set aside. Fetch my gear brings it back." },
        request = request("room", "trash", true) },
    { id = "condense", title = "Condense bags", summary = "Lower your encumbrance without dropping anything.",
        steps = {
            "Press Condense in the inventory window. Loose items move into the worn bags with the best weight reduction, heaviest first.",
            "Turn on Also rearrange what is already in bags for a deeper pass that swaps items between bags and keeps the same things together.",
        } },
    { id = "select", title = "Take an exact amount", summary = "Pick five nails out of a hundred.",
        steps = { "Right-click a stack and choose Select amount.", "Type a number. That many items are highlighted.", "Drag them, or right-click them, for any normal action." } },
    { id = "pour", title = "Pour and fill", summary = "Move liquids without the transfer panel.",
        steps = {
            "Right-click a vessel with liquid and choose Pour Into, or an empty one and choose Fill From. Only vessels that fit are listed.",
            "Pour into all fills several in one go, and never mixes different liquids.",
            "Beside a water dispenser, choose it in Pour Into to refill the bottle it holds.",
        } },
    { id = "presets", title = "Save a job", summary = "Set it up once, run it with one click.",
        steps = {
            "Set the job up in the planner, then use Presets, Save as a preset.",
            "It appears in the right-click menu wherever it makes sense: container presets on containers, room presets indoors.",
            "Containers and rooms are taken from where you are when you run it. A marked area keeps its place.",
        } },
    { id = "stopped", title = "Why did it stop?", summary = "Every job says why, in its notes.",
        steps = {
            "Click the job strip to see what stayed behind and the reason.",
            "Starting a new job sets the current one aside. The strip offers to resume the previous job afterwards.",
            "For a problem worth reporting, use Settings, Write a snapshot to the log. The log sits in Zomboid/Lua/LootBox/log.",
        } },
}

function Help.get(id)
    for _, topic in ipairs(Help.topics) do if topic.id == id then return topic end end
    return Help.topics[1]
end

return Help
