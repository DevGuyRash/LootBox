-- Settings apply as soon as they are clicked. Help is short, and about the
-- thing you are trying to do.
local K = require "LootBox/UIKit"
local App = require "LootBox/App"
local Help = require "LootBox/Help"

local Settings = { id = "settings", title = "Settings" }
local HelpPage = { id = "help", title = "Help" }

local groups = {
    { "Right-click menus", {
        { "contextMenus", "Show LootBox in right-click menus" },
        { "inventoryShortcuts", "On items and containers" },
        { "worldShortcuts", "In the world" },
        { "vehicleShortcuts", "On vehicles" },
        { "categoryShortcuts", "Rows for whole categories" },
        { "savedShortcuts", "Presets" } } },
    { "Inventory buttons", {
        { "matchingTransferButtons", "Smart Take and Match buttons", "Shown only while there is something for them to do." },
        { "smartTakeAllContainers", "Smart Take uses every open container", "Off takes only from the selected one." },
        { "putAwayButton", "Put Away button", "Shown while you carry something that belongs in storage nearby." },
        { "condenseButton", "Condense button" } } },
    { "Storage", {
        { "storageTitles", "Show what belongs in a container on its title and icon" },
        { "storageTips", "Show where an item goes in its tooltip" },
        { "autoPutAway", "Put away what I bring home by myself", "Once you are home, standing still and safe. Only what you did not leave with, and it stops when you move or act." } } },
    { "While a job runs", {
        { "jobBar", "Show the job strip", "Off shows it only when a job needs you. The job key always brings it back." },
        { "confirmQuickMoves", "Ask before moving items" },
        { "confirmQuickCleanup", "Ask before throwing things away" },
        { "confirmBinReviews", "Ask at each trash can" },
        { "rememberLastSetup", "Reopen the planner with my last job" } } },
    { "Condense", {
        { "condenseRebalance", "Also rearrange what is already in bags", "Looks for swaps between bags that lower your encumbrance." },
        { "condenseUseUnequipped", "Use bags I am not wearing", "Also for loot that goes into your bags." },
        { "condenseNested", "Use bags inside bags", "Also for loot that goes into your bags." } } },
    { "Eating and drinking", {
        { "tillFullEnabled", "Til Full in the Eat and Drink menus" },
        { "tillFullBothNeeds", "Til Full satisfies hunger and thirst together" },
        { "autoDrinkEquipped", "Drink from worn and held bottles by myself", "Needs the game's own Auto-Drink option." },
        { "autoConsumeCarried", "Eat and drink carried supplies by myself" },
        { "autoConsumeNested", "Also from bags inside bags" },
        { "autoConsumeRiskyOpen", "Open cans with a blade if there is no opener", "Can damage the blade and cut your hand." } } },
    { "Pouring", {
        { "pourLootToLoot", "Pour between two vessels in the same open container" },
        { "pourMostRoomFirst", "Pour into all: emptiest first", "Off fills the nearly full ones first." },
        { "pourEquippedFirst", "Pour into all: worn and held first", "Off starts with main inventory." },
        { "pourMainOnly", "Pour into all: main inventory only" } } },
    { "Troubleshooting", {
        { "detailedLog", "Keep a detailed log", "Records what you asked for, your state, the containers involved and every step, in Zomboid/Lua/LootBox/log." } } },
}

function Settings.build(win, body)
    local page = { win = win, body = body }
    page.list = K.list(body, page, function(p, row)
        if not row.key then return end
        local ok, err = App.setPreferences({ [row.key] = not row.check })
        p.message:set(ok and "" or tostring(err), "bad")
        Settings.refresh(p)
    end)
    page.message = K.text(body, "", "dim")
    page.snapshot = K.button(body, "Write a snapshot to the log", page, function(p)
        local path = require("LootBox/UI").snapshot(p.win.playerIndex)
        p.message:set(path and ("Saved in " .. path) or "The log file could not be written.", path and "good" or "bad")
    end, "ghost", "Records your character, nearby containers, labels and settings. Useful when reporting a problem.")
    return page
end

function Settings.refresh(page)
    local preferences, rows = App.getPreferences(), {}
    for _, group in ipairs(groups) do
        rows[#rows + 1] = { heading = true, title = group[1] }
        for _, entry in ipairs(group[2]) do
            local key = entry[1]
            rows[#rows + 1] = { key = key, title = entry[2], sub = entry[3], check = preferences[key] == true }
        end
    end
    page.list:fill(rows, true)
end

function Settings.opened(page) Settings.refresh(page) end

function Settings.layout(page)
    local body = page.body
    K.place(page.list, 0, 0, body.width, body.height - K.ROW - K.GAP)
    K.place(page.snapshot, body.width - page.snapshot.width, body.height - K.ROW)
    K.place(page.message, 0, body.height - K.ROW + 6, body.width - page.snapshot.width - K.GAP, K.LINE)
end

Settings.groups = groups

-- Help ---------------------------------------------------------------------

local function render(topic)
    local accent, text, dim = " <RGB:0.93,0.64,0.29> ", " <RGB:0.92,0.91,0.88> ", " <RGB:0.62,0.62,0.60> "
    local out = { " <SIZE:medium> " .. text .. K.escape(topic.title) .. " <SIZE:small> <LINE> <LINE> " .. dim .. K.escape(topic.summary) .. " <LINE> <LINE> " }
    for index, step in ipairs(topic.steps or {}) do
        out[#out + 1] = accent .. tostring(index) .. "." .. text .. " " .. K.escape(step) .. " <LINE> <LINE> "
    end
    if topic.notes then
        out[#out + 1] = accent .. "If something stays put <LINE> "
        for _, note in ipairs(topic.notes) do out[#out + 1] = dim .. "- " .. K.escape(note) .. " <LINE> " end
    end
    return table.concat(out)
end

function HelpPage.build(win, body)
    local page = { win = win, body = body }
    page.list = K.list(body, page, function(p, row) HelpPage.choose(p, row.id) end)
    page.text = K.rich(body)
    page.try = K.button(body, "Set this up", page, function(p)
        local app = getSpecificPlayer(p.win.playerIndex) and App.get(p.win.playerIndex)
        if not app or not p.topic.request then return end
        p.win:go("plan", { request = p.topic.request(app) })
    end, "primary")
    return page
end

function HelpPage.choose(page, id)
    page.topic = Help.get(id)
    local rows = {}
    for _, topic in ipairs(Help.topics) do rows[#rows + 1] = { title = topic.title, id = topic.id, current = topic.id == page.topic.id } end
    page.list:fill(rows, true)
    page.text:set(render(page.topic))
    page.try:setVisible(page.topic.request ~= nil and getSpecificPlayer(page.win.playerIndex) ~= nil)
    HelpPage.layout(page)
end

function HelpPage.opened(page, context) HelpPage.choose(page, context and context.topic or (page.topic and page.topic.id)) end

function HelpPage.layout(page)
    local body, left = page.body, math.floor(page.body.width * 0.28)
    K.place(page.list, 0, 0, left, body.height)
    local foot = page.try:isVisible() and (K.ROW + K.GAP) or 0
    K.place(page.text, left + K.PAD, 0, body.width - left - K.PAD, body.height - foot)
    K.place(page.try, body.width - page.try.width, body.height - K.ROW)
    page.text:paginate()
end

return { Settings = Settings, Help = HelpPage }
