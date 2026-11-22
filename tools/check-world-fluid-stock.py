#!/usr/bin/env python3
"""Exercise the release modules with the installed game's actual queue, wrappers and water actions, without starting PZ."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WORLD = Path("tests/integration/world-fluids.lua")
INVENTORY = Path("tests/integration/pour-native.lua")
STOCK = ("shared/ISBaseObject", "shared/TimedActions/ISBaseTimedAction",
         "client/TimedActions/ISTimedActionQueue", "shared/TimedActions/ISTakeWaterAction",
         "shared/TimedActions/ISAddFluidFromItemAction", "client/ISUI/ISWorldObjectContextMenu")

def stock_loader(install, name, sources):
    body = [f"function {name}()"]
    for relative in sources:
        body.extend(("do", (install / (relative + ".lua")).read_text(encoding="utf-8-sig"), "end",
                     'package.loaded["' + relative.split("/", 1)[1] + '"]=true'))
    return "\n".join(body + ["end", ""])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", required=True, type=Path)
    args = parser.parse_args()
    game = args.game.expanduser().resolve()
    install = game / "media/lua"
    with tempfile.TemporaryDirectory(prefix="world-fluid-stock-") as td:
        tmp = Path(td)
        (tmp / "Contents").symlink_to(ROOT / "Contents", target_is_directory=True)
        loaders = {
            WORLD: stock_loader(install, "WORLD_FLUID_STOCK", STOCK),
            INVENTORY: stock_loader(install, "EQUIPPED_STOCK_FLUIDS", tuple(
                "shared/Fluids/" + name for name in ("ISFluidContainer", "ISFluidUtil", "ISFluidTransferAction"))),
        }
        for suite, loader in loaders.items():
            target = tmp / suite
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(loader + (ROOT/suite).read_text())
            subprocess.run(["lua5.1", str(suite)], cwd=tmp, check=True)
        jar = game / "projectzomboid.jar"
        subprocess.run(["javac","--release","25","-cp",str(jar),"-d",str(tmp), str(ROOT/"tools/KahluaCheck.java")],check=True)
        subprocess.run([str(game/"jre64/bin/java"),"-Xmx512m","-Djava.awt.headless=true","-cp",str(tmp)+os.pathsep+str(jar),
                        "KahluaCheck",str(tmp),*(str(suite) for suite in loaders)],cwd=game,check=True)

if __name__=="__main__":
    main()
