#!/usr/bin/env python3
"""Guard: every game-extracted outline block (object type 40) is a solid block.

Geometry Dash's outline blocks (blockOutline_*) are platforms: the cube stands on
them and dies when it hits them from the side or below. Level Change of scene
uses one of them (ID 1859, the "H" block) to pin the cube between a block and the
H block above it. Before this guard, IDs with type 40 had no collision: they were
not in GMDObjects.GENERATED_STATIC_IDS and their generated scenes had an empty
Hitbox placeholder, so the cube passed straight through them.

For every type-40 entry in tools/gd_hitbox_data.json this checks that:
  1. the ID is listed in GMDObjects.GENERATED_STATIC_IDS (so it imports as a
     static gameplay object), and
  2. its generated scene scenes/gd_objects/gd_<id>.tscn gives the Hitbox node a
     real shape (the scene is not just the empty placeholder).

Exit status 1 on any mismatch. Run from the repository root.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HITBOX_JSON = ROOT / "tools" / "gd_hitbox_data.json"
GMDOBJECTS = ROOT / "src" / "static" / "GMDObjects.gd"
SCENES = ROOT / "scenes" / "gd_objects"
OUTLINE_TYPE = 40


def outline_ids() -> dict[int, str]:
    data = json.loads(HITBOX_JSON.read_text(encoding="utf-8"))["objects"]
    found: dict[int, str] = {}
    for key, entry in data.items():
        if entry.get("type") == OUTLINE_TYPE and entry.get("rect"):
            found[int(key)] = entry.get("texture", "?")
    return found


def generated_static_ids() -> set[int]:
    text = GMDOBJECTS.read_text(encoding="utf-8")
    start = text.index("const GENERATED_STATIC_IDS")
    body = text[text.index("= [", start) + 3:]
    body = body[:body.index("]")]
    return {int(n) for n in re.findall(r"\d+", body)}


def hitbox_has_shape(scene_text: str) -> bool:
    match = re.search(r'\[node name="Hitbox" type="CollisionShape2D"[^\]]*\]\n(.*?)(?=\n\[|\Z)',
                      scene_text, re.S)
    return bool(match) and "shape = SubResource" in match.group(1)


def main() -> int:
    failures: list[str] = []
    static_ids = generated_static_ids()
    for gd_id, texture in sorted(outline_ids().items()):
        if gd_id not in static_ids:
            failures.append(f"{gd_id} ({texture}): not in GENERATED_STATIC_IDS, cube passes through it")
        scene = SCENES / f"gd_{gd_id}.tscn"
        if not scene.exists():
            failures.append(f"{gd_id}: scene {scene.relative_to(ROOT)} is missing")
        elif not hitbox_has_shape(scene.read_text(encoding="utf-8")):
            failures.append(f"{gd_id}: {scene.relative_to(ROOT)} Hitbox has no shape")
    if failures:
        print("outline block collision check FAILED:")
        for line in failures:
            print("  - " + line)
        return 1
    print("outline block collision check passed (%d outline IDs)" % len(outline_ids()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
