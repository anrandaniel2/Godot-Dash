#!/usr/bin/env python3
"""Validate the object artwork mapping against a real Geometry Dash level.

Downloads Amethyst (level 119550490, a 2.2 Extreme Demon by iMist with ~65k
placed objects), decodes its level string, collects every placed object id
and diffs it against the artwork mapping: [code]object_frames.json[/code]
for the runtime path and [code]scenes/gd_objects[/code] for the editor path.

Level string format (same as [code]GMDConverter._parse_pairs[/code]): the
string is [code];[/code]-separated chunks, the first of which is the header;
every other chunk is one object as [code]key,value[/code] pairs where key 1
is the object id.

The report is written to [code]reports/amethyst_validation.md[/code] even
when the download fails (then as a diagnostic dump), because the workflow
commits it back and the Actions log viewer is unreachable from the
development sandbox.
"""

from __future__ import annotations

import base64
import gzip
import json
import re
import sys
import time
import traceback
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
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.loads(response.read().decode("utf-8", "replace"))
        except Exception as error:  # noqa: BLE001 - retry, keep the last error
            last_error = error
            if attempt < 2:
                time.sleep(5)
    raise last_error  # type: ignore[misc]


def looks_like_level_string(text: str) -> bool:
    """A level string is [code];[/code]-separated comma-pair objects."""
    if not text or len(text) < 1000:
        return False
    return "kS38," in text[:200] or re.search(r"(?:^|;)1,\d+,2,", text) is not None


def decode_gzip_b64(text: str) -> str:
    """RobTop level strings are gzipped and URL-safe base64 encoded."""
    padded = text.replace("-", "+").replace("_", "/")
    padded += "=" * (-len(padded) % 4)
    return gzip.decompress(base64.b64decode(padded)).decode("utf-8", "replace")


def fetch_level_string() -> str:
    """Level string from boomlings, with gdbrowser as the fallback."""
    errors: list[str] = []
    for name, download in (("boomlings", download_robtop), ("gdbrowser", download_gdbrowser)):
        try:
            payload = download()
        except Exception as error:  # noqa: BLE001 - report and try the mirror
            errors.append(f"{name} download: {type(error).__name__}: {error}")
            continue
        candidates: list[str] = []
        if isinstance(payload, str):
            # RobTop response: '#' sections, section 0 = 'key:value' pairs.
            fields = payload.split("#")[0].split(":")
            values = dict(zip(fields[0::2], fields[1::2]))
            raw = values.get("4", "")
            candidates.append(("raw", raw))
            try:
                candidates.append(("decoded", decode_gzip_b64(raw)))
            except Exception as error:  # noqa: BLE001
                errors.append(f"{name} gunzip: {type(error).__name__}: {error}")
        else:
            raw = payload.get("data") or ""
            candidates.append(("raw", raw))
            try:
                candidates.append(("decoded", decode_gzip_b64(raw)))
            except Exception as error:  # noqa: BLE001
                errors.append(f"{name} gunzip: {type(error).__name__}: {error}")
        for label, candidate in candidates:
            if looks_like_level_string(candidate):
                print(f"level string from {name} ({label}): {len(candidate):,} chars")
                return candidate
        errors.append(f"{name}: payload is not a level string (start: {str(payload)[:120]!r})")
    raise RuntimeError("could not download the level:\n  " + "\n  ".join(errors))


def parse_objects(level: str) -> Counter:
    """Placed object ids (key 1) with their placement counts."""
    ids: Counter = Counter()
    for chunk in level.split(";"):
        if not chunk or chunk.startswith("kS"):
            continue
        fields = chunk.split(",")
        values = dict(zip(fields[0::2], fields[1::2]))
        object_id = values.get("1", "")
        if object_id.isdigit():
            ids[int(object_id)] += 1
    return ids


def load_trigger_ids() -> set[int]:
    """The project's trigger inventory: objects with no artwork by design."""
    source = (PROJECT / "src" / "static" / "GMDObjects.gd").read_text()
    match = re.search(r"const TRIGGER_IDS: Array\[int\] = \[(.*?)]", source, re.S)
    if not match:
        return set()
    return {int(id_text) for id_text in re.findall(r"\d+", match.group(1))}


# Objects that are invisible in Geometry Dash itself (colour channels, the
# start-position marker and hidden collision), beyond the trigger inventory.
ARTLESS_IDS = {29, 30, 105, 146, 147}


def write_report(lines: list[str]) -> None:
    REPORT_PATH.parent.mkdir(exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines) + "\n")
    print(f"report written to {REPORT_PATH.relative_to(PROJECT)}")


def main() -> None:
    try:
        level = fetch_level_string()
    except Exception:  # noqa: BLE001 - commit the diagnostics
        write_report(
            [
                f"# {LEVEL_NAME} mapping validation",
                "",
                "## Download failed",
                "",
                "```",
                traceback.format_exc().strip(),
                "```",
            ]
        )
        sys.exit(1)

    placed = parse_objects(level)
    frames = json.loads((PROJECT / "assets/textures/gd_atlas/object_frames.json").read_text())["frames"]
    mapped = {int(key) for key in frames}
    scenes = {int(path.stem.split("_")[1]) for path in (PROJECT / "scenes/gd_objects").glob("gd_*.tscn")}
    triggers = load_trigger_ids()
    artless = triggers | ARTLESS_IDS

    total = sum(placed.values())
    distinct = len(placed)
    unmapped = {oid: count for oid, count in placed.items() if oid not in mapped}
    missing_art = {oid: count for oid, count in unmapped.items() if oid not in artless}
    no_scene = {oid: count for oid, count in placed.items() if oid in mapped and oid not in scenes}
    covered = total - sum(unmapped.values())
    art_covered = total - sum(missing_art.values())

    lines = [
        f"# {LEVEL_NAME} mapping validation",
        "",
        f"Level {LEVEL_ID} ({LEVEL_NAME}) decoded: **{total:,} placed objects**,",
        f"{distinct} distinct ids.",
        "",
        f"- artwork mapped: **{covered / total * 100:.2f}%** ({covered:,}/{total:,} placements)",
        f"- artwork mapped, excluding triggers/hidden ids: **{art_covered / total * 100:.2f}%**",
        f"- unmapped ids: {len(unmapped)} distinct ({sum(unmapped.values()):,} placements),",
        f"  of which {len(missing_art)} are not triggers/hidden objects",
        f"- ids without an editor scene: {len(no_scene)} distinct ({sum(no_scene.values()):,} placements)",
        "",
        "## Unmapped object ids",
        "",
        "| id | placements | kind | editor scene |",
        "| --- | --- | --- | --- |",
    ]
    kinds = lambda oid: "trigger" if oid in triggers else ("hidden" if oid in ARTLESS_IDS else "ARTWORK MISSING")
    for oid, count in sorted(unmapped.items(), key=lambda item: -item[1])[:80]:
        lines.append(f"| {oid} | {count:,} | {kinds(oid)} | {'yes' if oid in scenes else 'no'} |")
    if not unmapped:
        lines.append("| (none) | | | |")
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

    write_report(lines)
    print(
        f"coverage {covered / total * 100:.2f}% "
        f"(excl. triggers {art_covered / total * 100:.2f}%), "
        f"artwork missing for {len(missing_art)} ids ({sum(missing_art.values()):,} placements)"
    )


if __name__ == "__main__":
    main()
