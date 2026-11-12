#!/usr/bin/env python3
"""Build the standalone client mod without downloading or modifying game files."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def build(output: Path) -> Path:
    compiler = shutil.which("luac5.1")
    if compiler is None:
        raise RuntimeError("Install Lua 5.1 (luac5.1) to build the mod")
    files = sorted(path for path in (ROOT / "Contents").rglob("*") if path.is_file())
    scripts = [path for path in files if path.suffix == ".lua"]
    if not scripts:
        raise RuntimeError("No runtime modules found")
    for path in scripts:
        if "/media/lua/client/" not in path.as_posix():
            raise RuntimeError(f"Executable Lua outside client: {path.relative_to(ROOT)}")
        path.read_text(encoding="ascii")
        subprocess.run([compiler, "-p", str(path)], check=True, timeout=30)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "LootBox-0.4.1.zip"
    hashes = {}
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            data = path.read_bytes()
            package.writestr(relative, data)
            hashes[relative] = hashlib.sha256(data).hexdigest()
    manifest = {"modId": "LootBox", "version": "0.4.1", "scripts": len(scripts), "files": hashes,
                "archiveSha256": hashlib.sha256(archive.read_bytes()).hexdigest()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Built {archive} ({len(scripts)} client modules)")
    return archive


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    build(args.out.expanduser().resolve())
