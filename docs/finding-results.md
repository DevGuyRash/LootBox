# Finding what an action made (Build 42.22.2)

Some stock actions keep an item, some replace it. Unsealing a soda keeps the item and its ID. Opening a can, or taking a dispenser's bottle off its stand, deletes one thing and makes another with a random ID. In multiplayer any item that moves or syncs may also return as a new object under the same ID. `Items` is the one place that answers both questions: where is this item now (`Items.find`), and what did my action make (`Items.watch`).

## How a result is found

`Items.watch` notes the ID of everything carried and everything lying on and around the player's tile before the action is queued. After the action performs, `watch:find()` looks first for the original under its old ID, if the action keeps it (`ready`), and then for an item whose ID is new and that fits (`makes`). A carried answer comes before one on the player's own tile, then the best fit, then the main inventory before a bag. Two equally good answers are equally good: both belong to the player, are of the right kind, and did not exist when the action started.

Nothing else in the inventory matters. Items may arrive, leave or move meanwhile. An earlier version refused unless nothing but the expected change happened anywhere in the carried tree; a nail arriving during the action cancelled it.

## Why it can be looked up at once

In single player the result exists when the action completes. In multiplayer the server runs the action, sends the added and removed items and the changed world object, and then reports the action done. All of these use ordering channel 1 with reliable ordered delivery (`AddInventoryItemToContainerPacket`, `RemoveInventoryItemFromContainerPacket`, `AddItemToMapPacket`, `AddObjectToMapPacket`, `RemoveItemFromSquarePacket`, `NetTimedActionPacket`), and the client performs the action when it sees it done. Liquid amounts and other item fields travel as `SyncItemFieldsPacket`, which is not ordered, so a flow waits a few seconds for those and then goes by what it sees. A new stand's liquid travels as an entity packet and can even arrive before the stand, in which case the client shows a stale amount until the area reloads, with the stock actions too; the refill reads the bottle in the player's hands instead.

`Actions.addOrDropItem` drops a recipe's result at the player's feet when they are over the limit, so the ground is searched as well.

## Owning an action

`Act` owns the stock actions of one step. It takes each in hand while `ISTimedActionQueue.add` is being called, because `IsoGameCharacter.StartAction` may start the first one inside that call. It checks at the last moment before the game commits (in multiplayer, before the request is sent). Stock stop resets the whole queue, and after the player walks, runs or aims the engine also clears whatever started inside it. So what must survive waits in `Act.spare` and goes back once the player is calm: follow-ups such as putting a mask back on, and the player's own queued actions unless their own movement or fight ended them, as it always does. `Native` uses the same.

Finishing can make the game call an action invalid an instant before the server reports it done: a bottle drunk dry, a source poured out, a barrel emptied. Such actions are `lasting`.

`Flow` runs one thing the player asked for as a series of such steps. Between steps it waits for the player's own queue and movement; aiming, fighting or running ends it. `TillFull`, `Pour`, `Fixture` and `Dispenser` are flows; `Vessels` holds the steps they share (fetch, pour, put back).

## Who uses it

| Action | What happens to the item | Found as |
| --- | --- | --- |
| Open a can, jar, unlabelled or dented can | replaced, possibly dropped | new food of the recipe's output type, or any food stamped `NoLabel` |
| Open a ration | replaced by a filled vessel | new vessel; the game may auto-drink it first |
| Unseal a drink | kept | same ID, no longer sealed |
| Take a dispenser's bottle | stand replaced, bottle made | new bottle nearest the stand's litres, and the bare stand |
| Fit a bottle | bottle deleted, stand replaced | bottle gone and a filled stand there |
| Fetch or return a vessel | moved, maybe a new object | same ID in the expected place |
| Pour, fill | fields synced, maybe a new object | same ID, changed litres |

Eating never waits for the server's need values: each portion is planned from the smaller of the live need and what is left after the portions already eaten, so late values cannot cause overeating.
