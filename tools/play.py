#!/usr/bin/env python3
"""Launch the packaged mod in an owned, isolated Linux game session."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import zipfile

from build import build


def run(game: Path, evidence: Path, resume: bool = False, luabuddy_runtime: Path | None = None) -> int:
    game, evidence = game.resolve(), evidence.expanduser().resolve()
    if not (game / "projectzomboid.jar").is_file() or not (game / "jre64/bin/java").is_file():
        raise ValueError("--game must contain projectzomboid.jar and jre64/bin/java")
    previous = {}
    if resume:
        previous = json.loads((evidence / "session.json").read_text())
        if previous.get("cache") != str(evidence / "cache") or previous.get("game") != str(game):
            raise ValueError("Session identity does not match this cache/game")
        for key in ("ownerPid", "clientPid", "displayPid"):
            try:
                os.kill(previous[key], 0)
            except ProcessLookupError:
                pass
            else:
                raise ValueError("The previous owned session has not stopped")
    else:
        evidence.mkdir(parents=True, exist_ok=False)
    launch = previous.get("launch", 0) + 1
    archive = build(evidence / f"package-{launch}")
    cache = evidence / "cache"
    if resume:
        shutil.rmtree(cache / "mods/LootBox")
    with zipfile.ZipFile(archive) as package:
        for name in package.namelist():
            relative = Path(name).relative_to("Contents")
            target = cache / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(package.read(name))
    if not resume:
        (cache / "mods/default.txt").write_text("VERSION = 1,\nmods\n{\n    mod = LootBox,\n}\nmaps\n{\n}\n", encoding="utf-8")
        (cache / "options.ini").write_text(
            "version=7\nwidth=1280\nheight=900\nfullScreen=false\nborderless=false\n"
            "tutorialDone=true\ndoneNewSaveFolder=true\n", encoding="utf-8")
    adapter = None
    if luabuddy_runtime is not None:
        runtime = luabuddy_runtime.expanduser().resolve()
        if not runtime.is_file() or any(character in str(runtime) for character in "=\n\r"):
            raise ValueError("--luabuddy-runtime must identify an installed native runtime")
        runtime_dir = evidence / "adapter"
        runtime_dir.mkdir(exist_ok=True)
        snapshot = runtime_dir / runtime.name
        digest = hashlib.sha256(runtime.read_bytes()).hexdigest()
        if snapshot.exists() and hashlib.sha256(snapshot.read_bytes()).hexdigest() != digest:
            raise ValueError("The runtime changed; use a fresh evidence directory")
        if not snapshot.exists():
            shutil.copy2(runtime, snapshot)
        profiles = runtime_dir / "profiles"
        templates = runtime_dir / "templates"
        profiles.mkdir(exist_ok=True)
        templates.mkdir(exist_ok=True)
        (profiles / "LootBox.properties").write_text("id=LootBox\n", encoding="ascii")
        adapter = {"source": str(runtime), "snapshot": str(snapshot), "sha256": digest,
                   "profiles": str(profiles), "templates": str(templates)}
    processes = []
    try:
        with (evidence / f"display-{launch}.log").open("wb") as display_log, (evidence / f"client-{launch}.log").open("wb") as client_log:
            read_fd, write_fd = os.pipe()
            try:
                display = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1280x900x24", "-nolisten", "tcp"],
                                           pass_fds=(write_fd,), stdout=display_log, stderr=subprocess.STDOUT)
                processes.append(display)
                os.close(write_fd)
                write_fd = None
                if not select.select([read_fd], [], [], 10)[0]:
                    raise RuntimeError("Isolated display did not become ready")
                display_name = ":" + os.read(read_fd, 32).decode("ascii").strip()
            finally:
                os.close(read_fd)
                if write_fd is not None:
                    os.close(write_fd)
            env = {key: value for key, value in os.environ.items() if key not in {
                "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "JAVA_OPTS", "CLASSPATH", "LD_PRELOAD"}}
            env.update(DISPLAY=display_name, LD_LIBRARY_PATH=f"{game}:{game / 'natives'}:{game / 'jre64/lib'}")
            command = [str(game / "jre64/bin/java"), "-Xms512m", "-Xmx2048m", "-XX:+UseZGC",
                       "--enable-native-access=ALL-UNNAMED", "--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED",
                       "-Dzomboid.steam=0", "-Djava.library.path=.:natives", "-cp", ".:projectzomboid.jar",
                       "zombie.gameStates.MainScreenState", f"-cachedir={cache}", "-nosteam", "-nosound", "-novoip",
                       "-modfolders", "mods"]
            if adapter is not None:
                command[1:1] = [f"-agentpath:{adapter['snapshot']}", f"-Dluabuddy.config={adapter['profiles']}",
                                f"-Dluabuddy.templates={adapter['templates']}"]
            client = subprocess.Popen(command, cwd=game, env=env, stdin=subprocess.DEVNULL,
                                      stdout=client_log, stderr=subprocess.STDOUT)
            processes.append(client)
            state = {"ownerPid": os.getpid(), "clientPid": client.pid, "displayPid": display.pid,
                     "display": display_name, "cache": str(cache), "game": str(game), "launch": launch,
                     "adapter": adapter}
            (evidence / "session.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(state), flush=True)
            return client.wait()
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--resume", action="store_true", help="Restart a stopped owned session, retaining its disposable saves/preferences")
    parser.add_argument("--luabuddy-runtime", type=Path, help="Snapshot an installed LuaBuddy runtime and use an isolated ID-only local-mod profile")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    raise SystemExit(run(args.game, args.evidence, args.resume, args.luabuddy_runtime))
