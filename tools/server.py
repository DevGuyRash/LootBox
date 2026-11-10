#!/usr/bin/env python3
"""Own a disposable loopback Project Zomboid server with normal LootBox activation."""

import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

from build import build


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def identity(pid: int):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return {"pid": pid, "startTicks": fields[19], "state": fields[0]}
    except FileNotFoundError:
        return None


def owned(record: dict, token: str) -> bool:
    current = identity(record["pid"])
    if current is None or current["state"] == "Z":
        return False
    if current["startTicks"] != record["startTicks"]:
        raise ValueError("Recorded process identity changed; refusing to signal")
    command = Path(f"/proc/{record['pid']}/cmdline").read_bytes().split(b"\0")
    if token.encode() not in command:
        raise ValueError("Recorded process command changed; refusing to signal")
    return True


def free_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as handle:
        handle.bind(("127.0.0.1", 0))
        return handle.getsockname()[1]


def stop(evidence: Path) -> int:
    session = json.loads((evidence / "server-session.json").read_text())
    if session["evidence"] != str(evidence) or session["cache"] != str(evidence / "server-cache"):
        raise ValueError("Recorded session does not own this cache")
    if Path(session["ownerScript"]).name != Path(__file__).name:
        raise ValueError("Recorded launcher script does not match")
    if not owned(session["owner"], session["ownerScript"]):
        if owned(session["server"], f"-cachedir={evidence / 'server-cache'}"):
            raise ValueError("Owner is gone while server is alive; inspect before cleanup")
        print("Owned server is stopped")
        return 0
    os.kill(session["owner"]["pid"], signal.SIGTERM)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        server_alive = owned(session["server"], f"-cachedir={evidence / 'server-cache'}")
        owner_alive = owned(session["owner"], session["ownerScript"])
        if not server_alive and not owner_alive:
            print("Owned server stopped")
            return 0
        time.sleep(0.1)
    raise RuntimeError("The owned server did not stop before the cleanup deadline")


def launch(game: Path, evidence: Path, memory_cache: bool = False) -> int:
    if not memory_cache:
        return launch_in_cache(game, evidence, None)
    with tempfile.TemporaryDirectory(prefix="lootbox-server-", dir="/dev/shm") as temporary:
        try:
            return launch_in_cache(game, evidence, temporary)
        finally:
            cache = evidence / "server-cache"
            if cache.is_symlink() and os.readlink(cache) == temporary:
                cache.unlink()


def launch_in_cache(game: Path, evidence: Path, temporary: str | None) -> int:
    game = game.expanduser().resolve()
    if not (game / "projectzomboid.jar").is_file() or not (game / "jre64/bin/java").is_file():
        raise ValueError("--game must contain projectzomboid.jar and jre64/bin/java")
    evidence.mkdir(parents=True, exist_ok=False)
    evidence.chmod(0o700)
    archive = build(evidence / "package")
    cache = evidence / "server-cache"
    if temporary is not None:
        cache.symlink_to(temporary, target_is_directory=True)
    with zipfile.ZipFile(archive) as package:
        for name in package.namelist():
            relative = Path(name).relative_to("Contents")
            target = cache / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(package.read(name))
    nonclient = [path for path in (cache / "mods").rglob("*.lua") if "/media/lua/client/" not in path.as_posix()]
    if nonclient:
        raise ValueError("The staged mod contains executable Lua outside client")
    server_dir = cache / "Server"
    server_dir.mkdir(parents=True)
    port, udp_port = free_udp_port(), free_udp_port()
    while port == udp_port:
        udp_port = free_udp_port()
    (server_dir / "LootBoxProbe.ini").write_text(
        f"DefaultPort={port}\nUDPPort={udp_port}\nMods=LootBox\nWorkshopItems=\n"
        "DoLuaChecksum=true\nPublic=false\nUPnP=false\nOpen=true\nAutoCreateUserInWhiteList=true\n"
        "MaxPlayers=4\nPVP=false\nPauseEmpty=true\nMap=Muldraugh, KY\nRCONPassword=\n"
        "Password=\nTrashDeleteAll=true\nItemNumbersLimitPerContainer=0\n", encoding="utf-8")
    (server_dir / "LootBoxProbe_SandboxVars.lua").write_text(
        "SandboxVars = { VERSION = 6, Zombies = 6, StarterKit = true, ZombieConfig = {"
        "PopulationMultiplier = 0.0, PopulationStartMultiplier = 0.0, PopulationPeakMultiplier = 0.0} }\n",
        encoding="ascii")
    console = evidence / "server-console.in"
    os.mkfifo(console, 0o600)
    console_fd = os.open(console, os.O_RDWR)
    admin_name, admin_password = "lootbox_probe_" + secrets.token_hex(4), secrets.token_urlsafe(32)
    command = [str(game / "jre64/bin/java"), "-Xms512m", "-Xmx2048m", "-XX:+UseZGC",
               "--enable-native-access=ALL-UNNAMED", "--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED",
               "-Djava.awt.headless=true", "-Dzomboid.steam=0", "-Djava.library.path=.:natives",
               "-cp", ".:projectzomboid.jar", "zombie.network.GameServer", f"-cachedir={cache}", "-nosteam",
               "-servername", "LootBoxProbe", "-ip", "127.0.0.1", "-port", str(port), "-udpport", str(udp_port),
               "-adminusername", admin_name, "-adminpassword", admin_password]
    env = {key: value for key, value in os.environ.items() if key not in {
        "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "JAVA_OPTS", "CLASSPATH", "LD_PRELOAD"}}
    env["LD_LIBRARY_PATH"] = f"{game}:{game / 'natives'}:{game / 'jre64/lib'}"
    process = None
    reader = None
    session = None
    try:
        process = subprocess.Popen(command, cwd=game, env=env, stdin=console_fd, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        session = {"status": "starting", "owner": identity(os.getpid()), "server": identity(process.pid),
                   "ownerScript": sys.argv[0],
                   "evidence": str(evidence), "cache": str(cache), "game": str(game),
                   "host": "127.0.0.1", "port": port, "udpPort": udp_port,
                   "console": str(console), "modId": "LootBox", "serverModLuaFiles": len(nonclient),
                   "packageManifest": str(evidence / "package/manifest.json")}
        if temporary is not None:
            session["temporaryCache"] = temporary
        write_json(evidence / "server-session.json", session)

        def capture():
            with (evidence / "server.log").open("w", encoding="utf-8") as output:
                for line in process.stdout:
                    output.write(line.replace(admin_password, "<ephemeral-test-password>"))
                    output.flush()
                    if "SERVER STARTED" in line:
                        session["status"] = "ready"
                        write_json(evidence / "server-session.json", session)

        reader = threading.Thread(target=capture, name="lootbox-server-log")
        reader.start()
        print(json.dumps(session), flush=True)
        return process.wait()
    finally:
        if process is not None and process.poll() is None:
            os.write(console_fd, b"quit\n")
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        os.close(console_fd)
        if reader is not None:
            reader.join(timeout=10)
            if reader.is_alive():
                raise RuntimeError("Server output capture did not finish")
        if process is not None and process.stdout is not None:
            process.stdout.close()
        if session is not None:
            session["status"] = "stopped"
            session["exitCode"] = process.returncode
            write_json(evidence / "server-session.json", session)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("launch", "stop", "status"))
    parser.add_argument("--game", type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--memory-cache", action="store_true", help="Use an owned temporary /dev/shm cache, removed on stop")
    args = parser.parse_args()
    evidence = args.evidence.expanduser().resolve()
    if args.command == "launch":
        if args.game is None:
            parser.error("launch requires --game")
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        raise SystemExit(launch(args.game, evidence, args.memory_cache))
    if args.command == "stop":
        raise SystemExit(stop(evidence))
    session = json.loads((evidence / "server-session.json").read_text())
    session["serverAlive"] = owned(session["server"], f"-cachedir={evidence / 'server-cache'}")
    print(json.dumps(session, indent=2))
