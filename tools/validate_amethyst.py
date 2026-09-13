#!/usr/bin/env python3
"""Validate the object artwork mapping against a real Geometry Dash level.

Downloads Amethyst (level 119550490, a 2.2 Extreme Demon by iMist with ~65k
placed objects), decodes its level string, collects every placed object id
and diffs it against the artwork mapping: [code]object_frames.json[/code]
for the runtime path and [code]scenes/gd_objects[/code] for the editor path.

The report is written to [code]reports/amethyst_validation.md[/code]; the
workflow that runs this script commits it back to the branch, because the
Actions log viewer is unreachable from the development sandbox.
"""

from __future__ import annotations

import base64
import gzip
import json
import sys
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
LEVEL_ID = 119550490
LEVEL_NAME = "Amethyst"
REPORT_PATH = PROJECT / "reports" / "amethyst_validation.md"
USER_AGENT = ""  # RobTop's server rejects anything that looks like a script


def download_robtop() -> str:
    """Raw downloadGJLevel22.php response (section 0 holds the level)."""
    url = "https://www.boomlings.com/database/downloadGJLevel22.php"
    body = urllib.parse.urlencode(
        {
            "levelID": LEVEL_ID,
            "secret": "Wmfd2893gb7",
            "gameVersion": "22",
            "binaryVersion": "47",
        }
    ).encode()
    request = urllib.request.Request(url, data=body, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8", "replace")


def download_gdbrowser() -> dict:
    url = f"https://gdbrowser.com/api/level/{LEVEL_ID}?download=true"
    request = urllib.request.Request(url, headers={"User-Agent": "Godot-Dash validation"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def looks_like_level_string(text: str) -> bool:
    return "1:" in text[:200] and text.count(";") > 100


def decode_gzip_b64(text: str) -> str:
    """RobTop level strings are gzipped and URL-safe base64 encoded."""
    padded = text.replace("-", "+").replace("_", "/")
    padded += "=" * (-len(padded) % 4)
    return gzip.decompress(base64.b64decode(padded)).decode("utf-8", "replace")


def fetch_level_string() -> str:
    errors: list[str] = []
    for name, download in (("boomlings", download_robtop), ("gdbrowser", download_gdbrowser)):
        try:
            payload = download()
        except Exception as error:  # noqa: BLE001 - report and try the mirror
            errors.append(f"{name}: {type(error).__name__}: {error}")
            continue
        if name == "boomlings":
            section = payload.split("#")[0]
            fields = section.split(":")
            values = dict(zip(fields[0::2], fields[1::2]))
            raw = values.get("4", "")
            try:
                level = decode_gzip_b64(raw)
            except Exception as error:  # noqa: BLE001
                errors.append(f"boomlings decode: {error}")
                continue
        else:
            raw = payload.get("data") or ""
            try:
                level = raw if looks_like_level_string(raw) else decode_gzip_b64(raw)
            except Exception as error:  # noqa: BLE001
                errors.append(f"gdbrowser decode: {error}")
                continue
        if looks_like_level_string(level):
            return level
        errors.append(f"{name}: decoded payload is not a level string")
    sys.exit("could not download the level:\n  " + "\n  ".join(errors))


def parse_objects(level: str) -> Counter:
    """Placed object ids (key 1) with their placement counts."""
    ids: Counter = Counter()
    for chunk in level.split(";"):
        if not chunk:
            continue
        fields = chunk.split(":")
        values = dict(zip(fields[0::2], fields[1::2]))
        object_id = values.get("1")
        if object_id and object_id.isdigit():
            ids[int(object_id)] += 1
    return ids


def main() -> None:
    level = fetch_level_string()
    placed = parse_objects(level)
    frames = json.loads((PROJECT / "assets/textures/gd_atlas/object_frames.json").read_text())["frames"]
    mapped = {int(key) for key in frames}
    scenes = {int(path.stem.split("_")[1]) for path in (PROJECT / "scenes/gd_objects").glob("gd_*.tscn")}

    total = sum(placed.values())
    distinct = len(placed)
    unmapped = {oid: count for oid, count in placed.items() if oid not in mapped}
    no_scene = {oid: count for oid, count in placed.items() if oid in mapped and oid not in scenes}
    covered = total - sum(unmapped.values())
    known_ui = sum(count for oid, count in unmapped.items() if oid >= 900 and oid <= 950)

    lines = [
        f"# {LEVEL_NAME} mapping validation",
        "",
        f"Level {LEVEL_ID} ({LEVEL_NAME}) decoded: **{total:,} placed objects**,",
        f"{distinct} distinct ids.",
        "",
        f"- artwork mapped: **{covered / total * 100:.2f}%** ({covered:,}/{total:,} placements)",
        f"- unmapped ids: {len(unmapped)} distinct ids, {sum(unmapped.values()):,} placements",
        f"- ids without an editor scene: {len(no_scene)} distinct ids, {sum(no_scene.values()):,} placements",
        "",
        "## Unmapped object ids",
        "",
        "| id | placements | editor scene |",
        "| --- | --- | --- |",
    ]
    for oid, count in sorted(unmapped.items(), key=lambda item: -item[1])[:80]:
        lines.append(f"| {oid} | {count:,} | {'yes' if oid in scenes else 'no'} |")
    if not unmapped:
        lines.append("| (none) | | |")
    lines += [
        "",
        "## Ids mapped at runtime but without a scene",
        "",
        "These render in game but have no editor artwork.",
        "",
    ]
    for oid, count in sorted(no_scene.items(), key=lambda item: -item[1])[:40]:
        lines.append(f"- {oid}: {count:,} placements")
    if not no_scene:
        lines.append("(none)")

    REPORT_PATH.parent.mkdir(exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines) + "\n")
    print(f"coverage {covered / total * 100:.2f}%  unmapped {len(unmapped)} ids  ({sum(unmapped.values()):,} placements)")
    print(f"report written to {REPORT_PATH.relative_to(PROJECT)}")


if __name__ == "__main__":
    main()
