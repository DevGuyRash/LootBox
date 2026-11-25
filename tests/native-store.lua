local Store = require "LootBox/Store"
local base = "LootBox/categories"
local missing, missingError = Store.load(base)
assert(missing == nil and missingError == nil, "The isolated native cache must start without settings")
assert(getFileWriter(base .. ".a", true, false) == nil, "The installed game must reject the original unsupported extension")

local first = { name = NativeUnicodeFixture, controls = "first\nsecond\r\t\000", enabled = false, ids = { "native:Food", "custom:camp" } }
assert(Store.save(base, first))
local restored = assert(Store.load(base))
assert(restored.name == first.name, "Real native Unicode text must survive local persistence")
assert(restored.controls == first.controls, "Control characters must survive local persistence")
assert(restored.enabled == false and restored.ids[2] == "custom:camp", "Nested values must survive local persistence")
assert(Store.save(base, { name = "Second complete save" }))
assert(assert(Store.load(base)).name == "Second complete save", "Reopening must observe the newest complete save")

local writer = assert(getFileWriter(base .. ".b.txt", true, false))
writer:write("corrupted storage fixture")
writer:close()
local fallback, fallbackError, metadata = Store.load(base)
assert(fallbackError == nil and fallback.name == first.name and metadata.recovered == true,
    "A damaged newest native slot must retain the preceding complete save")

local longPath = "LootBox/world/" .. string.rep("a", 96) .. "/" .. string.rep("b", 96) .. "/" .. string.rep("c", 96)
assert(#longPath > 256, "The native identity fixture must exceed the former total-path restriction")
assert(Store.save(longPath, { labels = { "native:Food", "native:Tool" } }))
assert(assert(Store.load(longPath)).labels[2] == "native:Tool", "Native parent-directory creation must support chunked identities")
local damagedBase = "LootBox/damaged"
for _, slot in ipairs({ ".a.txt", ".b.txt" }) do
    local damaged = assert(getFileWriter(damagedBase .. slot, true, false))
    damaged:write("damaged" .. slot)
    damaged:close()
end
local unusable, _, state = Store.load(damagedBase)
assert(unusable == nil and state.damaged == true, "Two damaged slots must be reported")
assert(Store.save(damagedBase, { name = "Started over" }), "Damaged slots must not block saving forever")
assert(assert(Store.load(damagedBase)).name == "Started over")
local backup = assert(getFileReader(damagedBase .. ".damaged.txt", false), "The damaged text must be kept")
assert(tostring(backup:readLine()) == "damaged.a.txt" and tostring(backup:readLine()) == "damaged.b.txt")
backup:close()
assert(Store.save(damagedBase, { name = "Started over" }), "Saving unchanged data succeeds")

print("Native storage contracts passed using the installed game's real file readers and writers")
