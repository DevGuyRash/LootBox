#!/usr/bin/env python3
"""Run container menu and click-focus contracts through installed PZ/addon Lua entry points.

Does not launch the game, read saves, install a mod, or redistribute stock Lua.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SUITE = Path("tests/integration/container-world-menu.lua")


def snippet(path, start, stop):
    source = path.read_text(encoding="utf-8-sig")
    begin = source.index(start)
    return source[begin:source.index(stop, begin)]


def click_stock(lua_dir, neat_path):
    pane = lua_dir / "ISUI/ISInventoryPane.lua"
    page = lua_dir / "ISUI/ISInventoryPage.lua"
    options = lua_dir / "PZAPI/ModOptions.lua"
    # These are the unmodified function bodies from this installation. Grid
    # layout rows, native widgets and inventory/network objects remain doubles.
    return "\n".join(["function LOOTBOX_TEST_CLICK_STOCK(Views)",
        "local ISInventoryPane, ISInventoryPage, NInv = {}, {}, {}",
        "local PZAPI = {}",
        snippet(options, "PZAPI = ", "function Options:addTitle("),
        snippet(options, "function Options:addTickBox(", "function Options:addMultipleTickBox("),
        snippet(page, "function ISInventoryPage:selectContainer(", "function ISInventoryPage:setNewContainer("),
        snippet(pane, "function ISInventoryPane:selectIndex(", "function ISInventoryPane:onMouseMoveOutside("),
        snippet(pane, "function ISInventoryPane.getActualItems(", "function ISInventoryPane.getActualUniqueItems("),
        snippet(pane, "function ISInventoryPane:onRightMouseUp(", "function ISInventoryPane:getScrollAreaHeight("),
        snippet(pane, "function ISInventoryPane:onMouseUp(x", "function ISInventoryPane:canPutIn("),
        snippet(pane, "function ISInventoryPane:saveSelection(", "function ISInventoryPane:refreshContainer("),
        snippet(neat_path, "local function isGroup(row)", "function Views.pruneOpen("),
        snippet(neat_path, "function Views.indexAt(", "-- The column of containers under"),
        snippet(neat_path, "function Views.headAt(", "-- The container section under"),
        snippet(neat_path, "local prevRestoreSelection =", "-- Each window keeps its view"),
        "local vanilla = {onMouseDown=ISInventoryPane.onMouseDown,onMouseUp=ISInventoryPane.onMouseUp}",
        snippet(neat_path, "function ISInventoryPane:onMouseDown(", "-- A press on an object control released outside"),
        snippet(neat_path, "local function withoutCovered(", "local prevContextOnJoypad"),
        "function PZAPI.ModOptions:create(" + options.read_text(encoding="utf-8-sig").split("function PZAPI.ModOptions:create(", 1)[1],
        "return ISInventoryPane, ISInventoryPage, PZAPI.ModOptions:create('LootBox','LootBox'), PZAPI.ModOptions", "end", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True, help="Directory containing projectzomboid.jar and media/")
    parser.add_argument("--neat-views", type=Path, help="Installed NeatUI Inventory NInv_Views.lua (optional)")
    parser.add_argument("--shelf-entry", type=Path, help="Installed Shelf Aware SA_Entry.lua (optional)")
    args = parser.parse_args()
    game = args.game.expanduser().resolve()
    lua_dir = game / "media/lua/client"
    jar = game / "projectzomboid.jar"
    # The ISInventoryPage file also initializes unrelated UI on load; use its
    # whole original handler, not a reimplementation or a published stock copy.
    icon = snippet(lua_dir / "ISUI/ISInventoryPage.lua", "function ISInventoryPage:onBackpackRightMouseDown(",
                   "local sqsContainers")
    head = ""
    if args.neat_views:
        head = snippet(args.neat_views.expanduser(), "function Views.headAt(", "\n-- The container section")
    stock = "\n".join(["function LOOTBOX_TEST_LOAD_STOCK()", "ISInventoryPage = {}",
        (lua_dir / "ISUI/ISWorldObjectContextMenu.lua").read_text(encoding="utf-8-sig"),
        (lua_dir / "Context/ISMenuContextWorld.lua").read_text(encoding="utf-8-sig"),
        icon, "local Views = {}", head,
        "return ISMenuContextWorld.new, ISInventoryPage.onBackpackRightMouseDown, Views.headAt", "end", ""])
    stock += "\n".join(["function LOOTBOX_TEST_LOAD_CONTEXT_MENU()",
        (lua_dir / "ISUI/ISContextMenu.lua").read_text(encoding="utf-8-sig"), "end", ""])
    stock += "\n".join(["function LOOTBOX_TEST_LOAD_GET_UP()",
        (game / "media/lua/shared/TimedActions/ISWaitWhileGettingUp.lua").read_text(encoding="utf-8-sig"), "end", ""])
    stock += "\n".join(["function LOOTBOX_TEST_LOAD_PROVIDERS()", "ISMoveableSpriteProps = {}",
        snippet(game / "media/lua/shared/Moveables/ISMoveableSpriteProps.lua",
                "function ISMoveableSpriteProps:findOnSquare(", "function ISMoveableSpriteProps:findInInventory("),
        (lua_dir / "ISUI/ISDisassembleMenu.lua").read_text(encoding="utf-8-sig"),
        (lua_dir / "ISUI/ISRadioAndTvMenu.lua").read_text(encoding="utf-8-sig"), "end", ""])
    if args.shelf_entry:
        # Use its actual complete world subscriber plus its lookup/naming helpers;
        # do not load the unrelated HUD or redistribute Workshop code.
        stock += "\n".join(["function LOOTBOX_TEST_LOAD_SHELF(SA)", "local cb",
            "local Events={OnFillWorldObjectContextMenu={Add=function(fn) cb=fn end}}",
            snippet(args.shelf_entry.expanduser(), "local function findContainerObject(",
                    "Events.OnFillInventoryObjectContextMenu.Add("), "return cb", "end", ""])
    with tempfile.TemporaryDirectory(prefix="lootbox-exact-world-") as td:
        tmp = Path(td)
        (tmp / "Contents").symlink_to(ROOT / "Contents", target_is_directory=True)
        suites = {SUITE: stock}
        if args.neat_views:
            suites[Path("tests/integration/container-focus.lua")] = click_stock(lua_dir, args.neat_views.expanduser())
        for suite, injected in suites.items():
            path = tmp / suite
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(injected + (ROOT / suite).read_text(encoding="utf-8"), encoding="utf-8")
            subprocess.run([shutil.which("lua5.1") or "lua5.1", str(suite)], cwd=tmp, check=True)
        subprocess.run(["javac", "--release", "25", "-cp", str(jar), "-d", str(tmp),
                        str(ROOT / "tools/KahluaCheck.java")], check=True)
        java = game / "jre64/bin/java"
        env = {k: v for k, v in os.environ.items() if k not in {
            "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "JAVA_OPTS", "CLASSPATH", "LD_PRELOAD"}}
        subprocess.run([str(java), "-Xmx512m", "-Djava.awt.headless=true", "-cp",
                        os.pathsep.join([str(tmp), str(jar)]), "KahluaCheck", str(tmp), *map(str, suites)],
                       check=True, cwd=game, env=env)
    print("Stock Lua/Kahlua entrypoint checks passed (no renderer, live Java world or multiplayer).")


if __name__ == "__main__":
    main()
