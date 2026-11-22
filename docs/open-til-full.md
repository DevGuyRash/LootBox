# Open and use the live Til Full amount (42.22.2)

This is a client-only convenience over ordinary inventory amount and handcraft actions, not a new recipe or a network command. Only the selected stack and its original reachable source/main inventory are eligible. A successful opening by itself never counts as food or drink consumed.

- **Mapped replacement in single player:** the stock handcraft's own created-item data must supply exactly one suitable output. For a fresh object, the same completed craft must list the selected shell as consumed. If the server/game drops or does not identify the output, select it manually. No inventory scan by type, list position, or before/after comparison.
- **Kept item in multiplayer:** a native keep + IsSealed + Unseal input and a unique network ID/full type allow a follow-up after the inventory copy is actually unsealed. Native transfers can reconstruct the Java reference; a different ID never qualifies. Inventory collisions, expired updates and cancellation do not trigger consumption.
- **Replacement in ordinary multiplayer:** the game normally synchronizes the destination inventory and new item but sends no input-to-output receipt with plain Open. The player uses plain Open, then explicitly selects the opened item. The grey note does not start a craft. Phase-two sizing is never done from a guessed replacement or the closed shell.
- **Canned drinks:** vanilla opened canned fruit beverage and canned milk are Food items with the native Drink command. The native food action/quantity units apply; the actual thirst change of the opened item determines the requested portion. Fluid cans still use the native fluid action. The existing optional both-needs preference is unchanged.
- A fallback sibling is added only for an enabled native OnNewCraft row for a supported food can/jar or kept sealed beverage can. A normal amount submenu wins when both exist. Unavailable tools, hazardous substitutions, unrelated and batch unpack recipes are not synthesized.

## Stock evidence

- `media/scripts/generated/recipes/recipes_cannedFood.txt`: OpenCannedFood consumes the can and maps Base.CannedPeaches to Base.CannedPeachesOpen. OpenCannedFood2 is also a mapper; the opening callback is RecipeCodeOnCreate.openAndEat.
- `media/scripts/generated/items/food.txt`: closed CannedMilk has OpeningRecipe but not CantEat; CannedFruitBeverage lacks OpeningRecipe. Both opened Food items have CustomContextMenu = Drink. Their exact live values may differ from defaults.
- `media/scripts/generated/recipes/recipes_fluids.txt`: OpenCanOfBeverage keeps its selected item and unseals it; no new item is a receipt. Alcohol stays excluded. OpenWaterRationCan, by contrast, creates a vessel as a callback side effect rather than as a normal result; this patch does not guess it.
- `media/lua/client/ISUI/ISInventoryPaneContextMenu.lua`: the regular amount and plain-recipe callbacks are independent. OnNewCraft builds native handcraft/transfer/return actions from clicked inputs. The stock tool, source and action requirements remain in charge.
- `media/lua/shared/Entity/TimedActions/ISHandcraftAction.lua`: local perform executes the recipe only when not an MP client. On the server complete executes it, and the normal add/drop routine sends only the destination and new item. Stock records how many inputs of a given type an output used, not their individual IDs.
- Installed `zombie.scripting.logic.RecipeCodeOnCreate.openAndEat` returns for a nonpositive eat percentage (or a full moodle). A positive percentage sends only onlineID, output itemId, and the fixed fraction. `media/lua/client/ServerCommands.lua` immediately enqueues that exact fixed bite if the item is already present. This is not an opening-only receipt; there is no transaction/input ID in the command. LootBox never requests a dummy serving, hooks that handler, or issues a server command.

## Reproduce without starting the game

```sh
python3 tools/verify.py --game "$PZ_GAME_DIR" --evidence /path/to/new-evidence-directory
lua5.1 tests/stock/open-til-full.lua "$PZ_GAME_DIR"
javap -c -p -classpath "$PZ_GAME_DIR/projectzomboid.jar" zombie.scripting.logic.RecipeCodeOnCreate
```

The optional stock smoke executes the installed stock Lua against mocked Java/transport edges. The verifier's installed-Kahlua run is also offline. Neither is a live game or multiplayer playtest.
