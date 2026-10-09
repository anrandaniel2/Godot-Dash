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
    match = re.search(r"<k>k4</k>\s*<s>([^<]+)</s>", raw)
    if match:
        raw = match.group(1)
    elif raw.count("#") >= 2 and raw.startswith("1:"):
        parts = raw.split("#")[0].split(":")
        fields = dict(zip(parts[0::2], parts[1::2]))
        raw = fields.get("4", "")
    raw = raw.strip()
    # Plain level strings; 2.1-era headers open with the legacy kS1.. colours.
    if raw.startswith("kS") or raw.startswith("kA") or raw[:200].count(",") > 4:
        return raw
    data = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    for wbits in (47, -15):
        try:
            return zlib.decompress(data, wbits).decode("utf-8", "replace")
        except zlib.error:
            pass
    raise ValueError("undecodable level: text head=%r bytes head=%r" % (raw[:120], data[:16]))


def pairs(chunk: str, sep: str = ",") -> dict:
    fields = chunk.split(sep)
    return dict(zip(fields[0::2], fields[1::2]))


def big_report(objects: list) -> str:
    """Large rotated objects by id: channels, groups, flags and x range."""
    def num(o, k, d):
        try:
            return float(o.get(k, d) or d)
        except ValueError:
            return d
    rows = collections.defaultdict(list)
    for o in objects:
        oid = o.get("1", "")
        if not oid.isdigit() or int(oid) in TRIGGER_IDS:
            continue
        scale = max(num(o, "32", 1.0) * max(num(o, "128", 1.0), num(o, "129", 1.0)), num(o, "32", 1.0))
        rot = num(o, "6", 0.0) % 90.0
        if scale >= 2.5 and rot not in (0.0,):
            rows[oid].append(o)
    lines = []
    for oid, objs in sorted(rows.items(), key=lambda kv: -len(kv[1]))[:25]:
        keys = collections.Counter()
        chans = collections.Counter()
        groups = collections.Counter()
        for o in objs:
            keys.update(k for k in o if k not in ("1", "2", "3", "6", "32", "128", "129", "57", "21", "22", "155", "20", "24", "25"))
            chans["%s/%s" % (o.get("21", "-"), o.get("22", "-"))] += 1
            for g in o.get("57", "").split("."):
                if g:
                    groups[g] += 1
        xs = sorted(num(o, "2", 0.0) for o in objs)
        lines.append("id %s n=%d x=%.0f..%.0f chans=%s groups=%s keys=%s" % (
            oid, len(objs), xs[0], xs[-1],
            " ".join("%s:%d" % kv for kv in chans.most_common(5)),
            " ".join("%s:%d" % kv for kv in groups.most_common(8)),
            " ".join("%s:%d" % kv for kv in keys.most_common(14))))
        lines.append("  e.g. " + ",".join("%s=%s" % kv for kv in objs[0].items()))
    return "\n".join(lines)


def channel_report(channels: list, defined: dict, objects: list) -> str:
    """Definition, users, writers and copiers of each listed colour channel."""
    lines = []
    color_ids = {"899", "29", "30", "105", "744", "915", "221", "717", "718", "743", "900", "1006"}
    for ch in channels:
        lines.append("--- channel %s def=%s" % (ch, defined.get(ch, "UNDEFINED")))
        users = collections.Counter()
        xs = []
        for o in objects:
            if o.get("21") == ch or o.get("22") == ch:
                users["%s%s" % (o.get("1", "?"), "m" if o.get("21") == ch else "d")] += 1
                xs.append(float(o.get("2", "0") or 0))
        lines.append("  users=%d x=%s ids=%s" % (sum(users.values()),
            "%.0f..%.0f" % (min(xs), max(xs)) if xs else "-",
            " ".join("%s:%d" % kv for kv in users.most_common(10))))
        copiers = [c for c, d in defined.items() if d.get("9") == ch]
        lines.append("  header copies from it: %s" % (",".join(copiers) or "-"))
        for index, o in enumerate(objects):
            oid = o.get("1")
            hit = (oid in color_ids and o.get("23", "1" if oid == "899" else "") == ch) \
                or (oid in color_ids and o.get("50") == ch) \
                or (oid == "1006" and o.get("52", "0") != "1" and o.get("51") == ch)
            if hit:
                lines.append("  #%d %s" % (index, ",".join("%s=%s" % kv for kv in o.items()
                    if kv[0] in ("1", "2", "3", "23", "7", "8", "9", "10", "35", "17", "50", "49", "60", "51", "52", "48", "45", "46", "47", "62", "87", "57", "103"))))
    return "\n".join(lines)


CAMERA_IDS = {"1913", "1914", "1916", "2015", "2016", "2062", "2901", "2925", "1917", "1934"}
ROW_SKIP = {"20", "61", "64", "67", "155", "36", "156"}


def _row(index: int, o: dict) -> str:
    return "#%d " % index + ",".join("%s=%s" % (k, v) for k, v in o.items() if k not in ROW_SKIP)


def camera_report(objects: list) -> str:
    """Camera triggers, the members of their target groups and every Move /
    Follow that drives those groups (the cutscene camera paths)."""
    lines = []
    targets = set()
    for index, o in enumerate(objects):
        if o.get("1") in CAMERA_IDS:
            lines.append(_row(index, o))
            for key in ("71", "51"):
                if o.get(key, "0") not in ("", "0"):
                    targets.add(o[key])
    lines.append("--camera target groups--")
    for group in sorted(targets, key=lambda g: int(g) if g.isdigit() else 0):
        members = [(i, o) for i, o in enumerate(objects) if group in o.get("57", "").split(".")]
        lines.append("g%s members=%d first=%s" % (group, len(members), " | ".join(
            "id%s@(%s,%s)" % (o.get("1"), o.get("2"), o.get("3")) for _, o in members[:4])))
        for i, o in enumerate(objects):
            if o.get("1") in ("901", "1346", "1347", "1814", "2067", "1585") and o.get("51") == group:
                lines.append("  drive " + _row(i, o))
    return "\n".join(lines)


def window_report(objects: list, low: float, high: float) -> str:
    """Every trigger between two x positions, sorted by x."""
    rows = []
    for index, o in enumerate(objects):
        oid = o.get("1", "")
        if not oid.isdigit() or int(oid) not in TRIGGER_IDS:
            continue
        x = float(o.get("2", "0") or 0)
        if low <= x <= high:
            rows.append((x, _row(index, o)))
    rows.sort(key=lambda r: r[0])
    return "\n".join(r for _, r in rows)


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
    if "--big" in sys.argv:
        print("=====BIG ROTATED OBJECTS=====")
        print(big_report(objects))
    if "--channels" in sys.argv:
        print("=====CHANNELS=====")
        print(channel_report(sys.argv[sys.argv.index("--channels") + 1].split(","), defined, objects))
    if "--camera" in sys.argv:
        print("=====CAMERA=====")
        print(camera_report(objects))
    if "--window" in sys.argv:
        low, high = (float(v) for v in sys.argv[sys.argv.index("--window") + 1].split(":"))
        print("=====WINDOW %.2f-%.2f x=%.0f..%.0f=====" % (low, high, max_x * low, max_x * high))
        print(window_report(objects, max_x * low, max_x * high))
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
    print("=====ALL ROWS (899 1007 1268 1346 1347 1612 1613 1616 1812 1814 1819 22 32 33)=====")
    wanted = {"899", "1007", "1268", "1346", "1347", "1612", "1613", "1616", "1812", "1814", "1819", "22", "32", "33"}
    skip = {"20", "61", "64", "67", "155", "36"}
    for index, o in enumerate(objects):
        if o.get("1") in wanted:
            print("#%d " % index + ",".join("%s=%s" % (k, v) for k, v in o.items() if k not in skip))
    print("=====GROUPS OF 1007/1268/1049 TARGETS=====")
    alpha_targets = set()
    for o in objects:
        if o.get("1") in ("1007", "1268", "1049", "1612", "1613"):
            alpha_targets.add(o.get("51", ""))
    for group in sorted(alpha_targets, key=lambda g: int(g) if g.isdigit() else 0):
        print("g%s: %s" % (group, " ".join("%s:%d" % kv for kv in members[group].most_common(8))))
    print("=====TEXT=====")
    for index, o in enumerate(objects):
        if o.get("1") == "914":
            try:
                label = base64.urlsafe_b64decode(o.get("31", "") + "==").decode("utf-8", "replace")
            except ValueError:
                label = "?"
            print("#%d x=%s y=%s groups=%s text=%r color=%s" % (index, o.get("2"), o.get("3"), o.get("57", ""), label, o.get("21", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
