"""Dump teleport portals and the objects around them from a .gmd level.

Used by the bli-levels workflow to check the 747 exit height and the
sandwich position against the level data itself. Usage:
    python3 tools/gd_teleport_dump.py LEVEL.gmd [x_lo x_hi y_lo y_hi]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gd_level_scan as g  # noqa: E402

TELEPORT_IDS = {747, 749, 2902, 3022, 3027}
KEYS = ["2", "3", "6", "4", "5", "32", "51", "54", "71", "351", "352", "353", "354", "580"]


def fmt(o: dict) -> str:
    return " ".join("%s=%s" % (k, o[k]) for k in KEYS if k in o)


def main() -> int:
    path = sys.argv[1]
    box = [float(v) for v in sys.argv[2:6]] if len(sys.argv) >= 6 else [80.0, 130.0, 1100.0, 1250.0]
    text = open(path, encoding="utf-8", errors="replace").read()
    level = g.decode_level(text)
    chunks = level.split(";")
    objects = [g.pairs(c) for c in chunks[1:] if c]
    print("DUMP objects=%d" % len(objects))
    for index, o in enumerate(objects):
        if o.get("1", "") in {str(i) for i in TELEPORT_IDS}:
            print("DUMP TELEPORT #%d id=%s %s" % (index, o.get("1"), fmt(o)))
            print("DUMP RAW #%d %s" % (index, ";".join("%s,%s" % kv for kv in o.items())))
    # Every object in the sandwich's block group (25) with its position, so the
    # real extent of the sandwich can be read off the level data.
    for index, o in enumerate(objects):
        groups = o.get("57", "").split(".")
        if "25" in groups:
            print("DUMP GROUP25 #%d id=%s x=%s y=%s rot=%s scale=%s" % (
                index, o.get("1"), o.get("2"), o.get("3"), o.get("6", "0"), o.get("32", "1")))
    x_lo, x_hi, y_lo, y_hi = box
    for index, o in enumerate(objects):
        try:
            x = float(o.get("2", "nan"))
            y = float(o.get("3", "nan"))
        except ValueError:
            continue
        if x_lo <= x <= x_hi and y_lo <= y <= y_hi:
            print("DUMP BOX #%d id=%s %s" % (index, o.get("1"), fmt(o)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
