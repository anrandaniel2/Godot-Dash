#!/usr/bin/env python3
"""Scan an online Geometry Dash level and print a compact report.

Used by .github/workflows/level-scan.yml, which downloads the level on the
runner (the level string is never committed) and surfaces the report as
check-run annotations. Usage:

    gd_level_scan.py LEVEL_FILE [--focus-from FRACTION]

LEVEL_FILE may be a .gmd2 zip, a GDHistory .gmd plist, a raw boomlings
downloadGJLevel22 response, or a plain/encoded level string.
"""

import base64
import collections
import gzip
import re
import sys
import zipfile
import zlib

TRIGGER_IDS = {
    22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 55, 56, 57, 58, 59,
    104, 105, 221, 717, 718, 743, 744, 899, 900, 901, 915, 1006, 1007,
    1049, 1268, 1346, 1347, 1520, 1585, 1595, 1611, 1612, 1613, 1615,
    1616, 1811, 1812, 1814, 1815, 1817, 1818, 1819, 1912, 1913, 1914,
    1915, 1916, 1917, 1931, 1932, 1934, 1935, 2015, 2016, 2062, 2063,
    2066, 2067, 2068, 2899, 2900, 2901, 2903, 2904, 2905, 2907, 2909,
    2910, 2911, 2912, 2913, 2914, 2915, 2916, 2917, 2919, 2920, 2921,
    2922, 2923, 2924, 2925, 2999, 3006, 3007, 3008, 3009, 3010, 3011,
    3012, 3013, 3014, 3015, 3016, 3017, 3018, 3019, 3020, 3021, 3022,
    3023, 3024, 3029, 3030, 3031, 3032, 3033, 3600, 3602, 3603, 3604,
    3605, 3606, 3607, 3608, 3609, 3612, 3613, 3614, 3615, 3617, 3618,
    3619, 3620, 3640, 3641, 3642, 3643, 3660, 3661, 3662,
}


def decode_level(raw: str) -> str:
    match = re.search(r"<k>k4</k><s>([^<]+)</s>", raw)
    if match:
        raw = match.group(1)
    elif raw.count("#") >= 2 and raw.startswith("1:"):
        parts = raw.split("#")[0].split(":")
        fields = dict(zip(parts[0::2], parts[1::2]))
        raw = fields.get("4", "")
    raw = raw.strip()
    if raw.startswith("kS38") or raw.startswith("kA"):
        return raw
    data = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data).decode("utf-8", "replace")
    return zlib.decompress(data).decode("utf-8", "replace")


def pairs(chunk: str, sep: str = ",") -> dict:
    fields = chunk.split(sep)
    return dict(zip(fields[0::2], fields[1::2]))


def main() -> int:
    if zipfile.is_zipfile(sys.argv[1]):
        with zipfile.ZipFile(sys.argv[1]) as archive:
            text = archive.read("level.data").decode("utf-8", "replace")
    else:
        text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    focus = 0.9
    if "--focus-from" in sys.argv:
        focus = float(sys.argv[sys.argv.index("--focus-from") + 1])
    level = decode_level(text)
    chunks = level.split(";")
    header = pairs(chunks[0])
    objects = [pairs(c) for c in chunks[1:] if c]
    out = []
    out.append("objects=%d header_keys=%s" % (len(objects), ",".join(sorted(header))))
    out.append("header(non-colour)=" + ",".join(
        "%s:%s" % (k, v[:40]) for k, v in sorted(header.items()) if k != "kS38"))

    defined = {}
    for entry in header.get("kS38", "").split("|"):
        if entry:
            props = pairs(entry, "_")
            defined[props.get("6", "?")] = props
    out.append("kS38 channels(%d)=%s" % (len(defined), " ".join(
        "%s{%s}" % (ch, ",".join("%s=%s" % kv for kv in sorted(p.items()) if kv[0] != "6"))
        for ch, p in sorted(defined.items(), key=lambda kv: int(kv[0]) if kv[0].lstrip("-").isdigit() else 0))))

    ids = collections.Counter(o.get("1", "?") for o in objects)
    out.append("trigger ids=" + " ".join(
        "%s:%d" % (k, v) for k, v in sorted(ids.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)
        if k.isdigit() and int(k) in TRIGGER_IDS))
    out.append("all ids(%d)=" % len(ids) + " ".join(
        "%s:%d" % (k, v) for k, v in sorted(ids.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)))

    # Colour channels used by objects vs defined/triggered.
    triggered = collections.Counter()
    for o in objects:
        if o.get("1") in ("899", "29", "30", "105", "744", "915", "221", "717", "718", "743", "900", "1006"):
            triggered[o.get("23", "?")] += 1
    used = collections.Counter()
    for o in objects:
        for key in ("21", "22"):
            if key in o:
                used[o[key]] += 1
    out.append("channels used by objects=" + " ".join(
        "%s:%d%s" % (ch, n, "" if ch in defined else ("(trig)" if ch in triggered else "(UNDEF)"))
        for ch, n in sorted(used.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)))
    out.append("channels targeted by colour triggers=" + " ".join(
        "%s:%d" % kv for kv in sorted(triggered.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)))
    keys = collections.Counter()
    for o in objects:
        keys.update(o.keys())
    out.append("object keys=" + " ".join("%s:%d" % kv for kv in sorted(keys.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0)))

    xs = [float(o.get("2", "0") or 0) for o in objects if o.get("1", "").isdigit() and int(o["1"]) not in TRIGGER_IDS]
    max_x = max(xs) if xs else 0.0
    out.append("max_x(non-trigger)=%.1f focus_from=%.1f" % (max_x, max_x * focus))
    print("\n".join(out))
    print("=====FOCUS=====")
    focus_rows = []
    for index, o in enumerate(objects):
        oid = o.get("1", "")
        if not oid.isdigit() or int(oid) not in TRIGGER_IDS:
            continue
        x = float(o.get("2", "0") or 0)
        if x >= max_x * focus:
            focus_rows.append((x, index, o))
    focus_rows.sort(key=lambda row: row[0])
    members = collections.defaultdict(collections.Counter)
    for o in objects:
        for group in o.get("57", "").split("."):
            if group:
                members[group][o.get("1", "?")] += 1
    targets = set()
    for x, index, o in focus_rows:
        print("#%d " % index + ",".join("%s=%s" % (k, v) for k, v in o.items()))
        for key in ("51", "71"):
            if o.get(key, "0") not in ("", "0"):
                targets.add(o[key])
    print("=====TARGET GROUPS=====")
    for group in sorted(targets, key=lambda g: int(g) if g.isdigit() else 0):
        print("g%s: %s" % (group, " ".join("%s:%d" % kv for kv in members[group].most_common(12))))
    print("=====TEXT=====")
    for index, o in enumerate(objects):
        if o.get("1") == "914" and float(o.get("2", "0") or 0) >= max_x * focus:
            try:
                label = base64.urlsafe_b64decode(o.get("31", "") + "==").decode("utf-8", "replace")
            except ValueError:
                label = "?"
            print("#%d x=%s y=%s groups=%s text=%r color=%s" % (index, o.get("2"), o.get("3"), o.get("57", ""), label, o.get("21", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
