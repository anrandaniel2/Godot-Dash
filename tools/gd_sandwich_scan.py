#!/usr/bin/env python3
"""What touches the cube while it sits in the Change of scene sandwich?

Reads one .gmd file (raw level string, as tools/gd_level_scan.py expects) and
prints, in order:

  1. every object whose 30x30 box overlaps the sandwich box (the cube's
     hitbox while it rests at y ~1155 between the blocks at x=120)
  2. every trigger that targets group 1 or group 25 (the sandwich groups)
  3. every trigger with key 56 (activate group) or key 62 (spawn triggered)
  4. the Pulse (1006) breakdown by key 48 (mode), 52 (target type) and
     whether it targets a group

Usage: gd_sandwich_scan.py LEVEL.gmd [--box x0,x1,y0,y1]
"""

import collections
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("gls", os.path.join(HERE, "gd_level_scan.py"))
gls = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gls)

GROUP_TARGET_KEY = "51"
ACTIVATE_GROUP_KEY = "56"
SPAWN_KEY = "62"
SANDWICH_GROUPS = {"1", "25"}
PULSE_ID = "1006"


def load_objects(path: str) -> list:
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    chunks = gls.decode_level(text).split(";")
    return [gls.pairs(chunk) for chunk in chunks[1:] if chunk]


def in_box(obj: dict, box: tuple) -> bool:
    x0, x1, y0, y1 = box
    try:
        x = float(obj.get("2", 0) or 0)
        y = float(obj.get("3", 0) or 0)
    except ValueError:
        return False
    return x + 15 >= x0 and x - 15 <= x1 and y + 15 >= y0 and y - 15 <= y1


def row(index: int, obj: dict) -> str:
    keep = ("1", "2", "3", "51", "56", "57", "58", "59", "10", "62", "48", "52", "49", "50", "6", "155")
    return "#%d " % index + ",".join("%s=%s" % (k, obj[k]) for k in keep if k in obj)


def main(argv: list) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    box = (60.0, 200.0, 1100.0, 1200.0)
    if "--box" in argv:
        box = tuple(float(v) for v in argv[argv.index("--box") + 1].split(","))
    objects = load_objects(path)
    print(f"objects={len(objects)} box={box}")

    print("== 1. objects overlapping the sandwich box")
    for index, obj in enumerate(objects):
        if in_box(obj, box):
            print(row(index, obj))

    print("== 2. triggers targeting group 1 or 25")
    for index, obj in enumerate(objects):
        if obj.get(GROUP_TARGET_KEY, "") in SANDWICH_GROUPS:
            print(row(index, obj))

    print("== 3. triggers with activate-group (56) or spawn (62)")
    counts = collections.Counter()
    for index, obj in enumerate(objects):
        if obj.get(ACTIVATE_GROUP_KEY) or obj.get(SPAWN_KEY):
            counts[obj.get("1", "?")] += 1
            if counts[obj.get("1", "?")] <= 40:
                print(row(index, obj))
    print("counts by id:", dict(counts))

    print("== 4. pulse (1006) breakdown")
    pulse = [o for o in objects if o.get("1") == PULSE_ID]
    by = collections.Counter()
    for obj in pulse:
        by[(obj.get("48", "-"), obj.get("52", "-"), "tgt" if obj.get(GROUP_TARGET_KEY) else "no-tgt")] += 1
    print(f"pulses={len(pulse)}")
    for key, count in by.most_common(20):
        print(f"  key48={key[0]} key52={key[1]} {key[2]}: {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
