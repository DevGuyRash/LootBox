#!/usr/bin/env python3
"""Build the mod, run portable contracts, and optionally repeat them in native Kahlua."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from build import ROOT, build


def fingerprint() -> str:
    digest = hashlib.sha256()
    for directory in ("Contents", "tests", "tools"):
        for path in sorted((ROOT / directory).rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                digest.update(path.relative_to(ROOT).as_posix().encode())
                digest.update(path.read_bytes())
    return digest.hexdigest()


def run(evidence: Path, name: str, command: list[str], *, env=None, timeout=180, cwd=ROOT) -> dict:
    log = evidence / f"{name}.log"
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    print(f"{name}: {'PASS' if result.returncode == 0 else 'FAIL'}", flush=True)
    return {"name": name, "passed": result.returncode == 0, "exitCode": result.returncode,
            "elapsedSeconds": round(time.monotonic() - started, 3), "log": str(log)}


def verify(evidence: Path, game: Path | None) -> bool:
    evidence = evidence.expanduser().resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    before = fingerprint()
    build(evidence / "package")
    lua = shutil.which("lua5.1")
    if not lua:
        raise RuntimeError("Install lua5.1 to run portable contracts")
    suites = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "tests").rglob("*.lua")
                    if path.parent.name in {"domain", "integration"})
    if not suites:
        raise RuntimeError("No contract suites found")
    checks = [run(evidence, f"lua-{Path(suite).stem}", [lua, suite]) for suite in suites]
    native = "not requested"
    if game:
        game = game.expanduser().resolve()
        jar, java = game / "projectzomboid.jar", game / "jre64/bin/java"
        compiler = shutil.which("javac")
        if not jar.is_file() or not java.is_file() or not compiler:
            raise RuntimeError("Native checks need the installed game JAR/JRE and JDK 25 javac")
        with tempfile.TemporaryDirectory(prefix="lootbox-kahlua-") as temporary:
            classes = Path(temporary)
            checks.append(run(evidence, "native-compile", [compiler, "--release", "25", "-cp", str(jar),
                "-d", str(classes), str(ROOT / "tools/KahluaCheck.java"), str(ROOT / "tools/NativeStoreCheck.java")]))
            if checks[-1]["passed"]:
                env = {key: value for key, value in os.environ.items() if key not in {
                    "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "JAVA_OPTS", "CLASSPATH", "LD_PRELOAD"}}
                for suite in suites:
                    checks.append(run(evidence, f"native-{Path(suite).stem}", [str(java), "-Xmx512m", "-Djava.awt.headless=true",
                        "-cp", os.pathsep.join((str(classes), str(jar))), "KahluaCheck", str(ROOT), suite], env=env, timeout=300, cwd=game))
                checks.append(run(evidence, "native-store-files", [str(java), "-Xmx512m", "-Djava.awt.headless=true",
                    "-cp", os.pathsep.join((str(classes), str(jar))), "NativeStoreCheck", str(ROOT)], env=env, cwd=game))
        native = "installed interpreter with explicit native-boundary doubles; not a gameplay or multiplayer proof"
    stable = before == fingerprint()
    report = {"passed": stable and all(check["passed"] for check in checks), "sourceStable": stable,
              "sourceSha256": before, "checks": checks, "nativeScope": native}
    (evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Report: {evidence / 'report.json'}", flush=True)
    return report["passed"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path)
    parser.add_argument("--evidence", type=Path,
                        default=Path.home() / ".local/state/app-verification/LootBox" / time.strftime("verify-%Y%m%d-%H%M%S", time.gmtime()))
    args = parser.parse_args()
    raise SystemExit(0 if verify(args.evidence, args.game) else 1)
