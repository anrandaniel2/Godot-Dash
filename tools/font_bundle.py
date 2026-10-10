#!/usr/bin/env python3
"""Font bundle manifest, export and check.

The game's font files (assets/fonts: Inter, Outfit, Pusab and the GD bitmap
fonts under assets/fonts/gd) are meant to be hosted outside the repo and
downloaded on demand. This tool keeps that bundle honest:

  python3 tools/font_bundle.py --check
      Verify assets/fonts against tools/font_manifest.json (sizes and SHA-256).
      Exits 1 on any mismatch, missing file, or unlisted font file. CI runs this.

  python3 tools/font_bundle.py --write
      Regenerate tools/font_manifest.json from assets/fonts.

  python3 tools/font_bundle.py --export DIR
      Copy the bundle into DIR as fonts/ plus manifest.json, ready to upload.
      The manifest's file paths are relative to fonts/.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FONT_DIR = REPO / "assets" / "fonts"
MANIFEST = REPO / "tools" / "font_manifest.json"
FONT_SUFFIXES = {".ttf", ".otf", ".ttc"}
GD_SUFFIXES = {".fnt", ".png"}
GD_SUBDIR = "gd"


def is_font_file(relative: Path) -> bool:
    if relative.parts and relative.parts[0] == GD_SUBDIR:
        return relative.suffix in GD_SUFFIXES
    return relative.suffix in FONT_SUFFIXES


def discover() -> list[Path]:
    """Font files under assets/fonts, as paths relative to FONT_DIR, sorted."""
    found = []
    for path in FONT_DIR.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(FONT_DIR)
        if is_font_file(relative):
            found.append(relative)
    return sorted(found, key=lambda p: p.as_posix())


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest() -> dict:
    files = []
    for relative in discover():
        path = FONT_DIR / relative
        files.append({
            "file": relative.as_posix(),
            "size": path.stat().st_size,
            "sha256": sha256_of(path),
        })
    return {"version": 1, "root": "assets/fonts", "files": files}


def load_manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def check() -> int:
    if not MANIFEST.exists():
        print(f"FAIL: {MANIFEST.relative_to(REPO)} is missing; run --write")
        return 1
    expected = {entry["file"]: entry for entry in load_manifest()["files"]}
    actual = build_manifest()["files"]
    problems: list[str] = []
    seen = set()
    for entry in actual:
        name = entry["file"]
        seen.add(name)
        if name not in expected:
            problems.append(f"not in manifest: {name}")
            continue
        want = expected[name]
        if want["size"] != entry["size"]:
            problems.append(f"size changed: {name} ({want['size']} -> {entry['size']})")
        if want["sha256"] != entry["sha256"]:
            problems.append(f"hash changed: {name}")
    for name in sorted(set(expected) - seen):
        problems.append(f"listed in manifest but missing from assets/fonts: {name}")
    if problems:
        print("FAIL: font bundle does not match tools/font_manifest.json")
        for line in problems:
            print("  " + line)
        print("If the change is intended, run: python3 tools/font_bundle.py --write")
        return 1
    total = sum(entry["size"] for entry in actual)
    print(f"OK: {len(actual)} font files match tools/font_manifest.json ({total} bytes)")
    return 0


def write() -> int:
    manifest = build_manifest()
    MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print(f"Wrote {MANIFEST.relative_to(REPO)} with {len(manifest['files'])} files")
    return 0


def export(destination: Path) -> int:
    manifest = build_manifest()
    fonts_out = destination / "fonts"
    if fonts_out.exists():
        shutil.rmtree(fonts_out)
    for entry in manifest["files"]:
        target = fonts_out / entry["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(FONT_DIR / entry["file"], target)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print(f"Exported {len(manifest['files'])} files to {destination}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="verify assets/fonts against the manifest (default)")
    group.add_argument("--write", action="store_true", help="regenerate the manifest")
    group.add_argument("--export", metavar="DIR", type=Path, help="copy the bundle into DIR")
    args = parser.parse_args(argv)
    if args.write:
        return write()
    if args.export:
        return export(args.export)
    return check()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
