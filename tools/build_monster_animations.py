#!/usr/bin/env python3
"""Build the monster animation table used by the Animate trigger (1585).

Where the data comes from
-------------------------
Geometry Dash animates its monsters (Big Beast 918, the 2.1 monsters 1327 and
1328, the Bat 1584, the Spikeball 2012) from two resource files the game
ships, which this script takes as *input* and never copies into the repo:

* ``objectDefinitions.plist``: per monster (``GJBeast01``..``GJBeast05``) the
  default animation and, per animation, its frame count, per-frame ``delay``
  in seconds and ``looped`` flag.
* ``GJBeastNN_AnimDesc.plist``: per animation frame (``GJBeast01_bite_001.png``
  ...), every part sprite's texture, position (Geometry Dash units around the
  object's centre, y up), scale, rotation (degrees, clockwise), flip and z.

Only derived numbers are written out, in the same conventions as
``object_frames.json`` (whose part ``x``/``y`` match the AnimDesc positions).

Animation IDs
-------------
The Animate trigger's key 76 indexes a per-monster list shown in the editor's
help popup. The 2.1 community transcriptions of that popup (gdforum P1kachu
"How to use Triggers! [2.1]", GameBanana Q43939) give:

* Big Beast: 0 bite, 1 attack01, 2 attack01_end, 3 idle01
* Bat: 0 idle01, 1 idle02, 2 idle03, 3 attack01, 4 attack02, 5 attack02_end,
  6 sleep, 7 sleep_loop, 8 sleep_end

The Spikeball list is only described (NamuWiki: 0/1 basic, 2 reveals thorns,
3 launches the attack); ``idle01, idle02, toAttack01, attack02`` is a
hypothesis. 1327/1328 are not Animate targets in the help popup; they only
play their default idle.

Chaining
--------
A non-looped animation continues into ``<name>_loop`` when one exists
(attack01 -> attack01_loop, sleep -> sleep_loop), ``toAttack01`` into
``attack01`` and ``toAttack03`` into ``attack03``; any other non-looped
animation returns to the monster's default. Hypothesis: inferred from the
naming, not from decompiled code (AnimatedGameObject::playAnimation and
animationFinished have no decompiled bodies).

Usage::

    python3 tools/build_monster_animations.py <dir with the plists>
"""

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent.parent / "assets/textures/gd_atlas/monster_animations.json"

MONSTERS: dict[str, list[int]] = {
    "GJBeast01": [918],
    "GJBeast02": [1327],
    "GJBeast03": [1328],
    "GJBeast04": [1584],
    "GJBeast05": [2012],
}

ANIMATION_IDS: dict[str, list[str]] = {
    "GJBeast01": ["bite", "attack01", "attack01_end", "idle01"],
    "GJBeast04": [
        "idle01", "idle02", "idle03", "attack01", "attack02", "attack02_end",
        "sleep", "sleep_loop", "sleep_end",
    ],
    "GJBeast05": ["idle01", "idle02", "toAttack01", "attack02"],
}

EXPLICIT_NEXT: dict[str, str] = {"toAttack01": "attack01", "toAttack03": "attack03"}


def load_plist(path: Path) -> dict:
    # Some shipped plists start with a blank line, which plistlib rejects.
    return plistlib.loads(path.read_bytes().lstrip())


def pair(text: str) -> tuple[float, float]:
    a, b = text.strip("{} ").split(",")
    return float(a), float(b)


def frame_parts(frame: dict) -> list[list]:
    sprites = sorted(frame.items(), key=lambda item: int(item[0].split("_")[1]))
    parts: list[list] = []
    for _, sprite in sprites:
        x, y = pair(sprite["position"])
        sx, sy = pair(sprite["scale"])
        fx, fy = pair(sprite["flipped"])
        parts.append([
            sprite["texture"], round(x, 4), round(y, 4), round(sx, 5), round(sy, 5),
            round(float(sprite["rotation"]), 4), int(fx), int(fy), int(float(sprite["zValue"])),
        ])
    return parts


def build(source: Path) -> dict:
    definitions = load_plist(source / "objectDefinitions.plist")
    result: dict = {"_source": "objectDefinitions.plist + GJBeastNN_AnimDesc.plist", "monsters": {}, "objects": {}}
    for name, object_ids in MONSTERS.items():
        definition = definitions[name]
        container = load_plist(source / definition["animDesc"])["animationContainer"]
        animations: dict = {}
        names = list(definition["animations"].keys())
        for animation, info in definition["animations"].items():
            count = int(info["frames"])
            frames = []
            for index in range(1, count + 1):
                key = "%s_%s_%03d.png" % (name, animation, index)
                if key in container:
                    frames.append(frame_parts(container[key]))
            looped = info["looped"] == "1"
            following = ""
            if not looped:
                following = EXPLICIT_NEXT.get(animation, "")
                if not following and "%s_loop" % animation in names:
                    following = "%s_loop" % animation
            animations[animation] = {
                "delay": float(info["delay"]),
                "loop": looped,
                "next": following,
                "frames": frames,
            }
        result["monsters"][name] = {
            "default": definition.get("defaultAnimation", names[0]),
            "ids": ANIMATION_IDS.get(name, []),
            "animations": animations,
        }
        for object_id in object_ids:
            result["objects"][str(object_id)] = name
    return result


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    table = build(Path(sys.argv[1]))
    OUTPUT.write_text(json.dumps(table, separators=(",", ":"), sort_keys=True) + "\n")
    print("wrote %s (%d bytes)" % (OUTPUT, OUTPUT.stat().st_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
