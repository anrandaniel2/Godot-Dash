#!/usr/bin/env python3
"""Where is the glow in Amethyst, and what drives its colour?

Downloads the real Amethyst level string and reports, per 1000-unit X bucket:
- how many placed objects have glow enabled (key 96 != 1),
- which colour channels (key 21) those objects sit on,
plus the channel table from kS38 (copy channels, opacity, blending) and the
colour triggers (object 899; legacy 29/30/32/33) that retarget those channels.
"""

from __future__ import annotations

import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from validate_amethyst import fetch_level_string  # noqa: E402

COLOR_TRIGGER_IDS = {899, 29, 30, 32, 33, 105}
LEGACY_TRIGGER_NAMES = {29: "BG", 30: "Ground", 32: "Line?", 33: "Line2?", 105: "Obj"}


def parse_pairs(text: str) -> dict[str, str]:
    pairs = text.split(",")
    return {pairs[i]: pairs[i + 1] for i in range(0, len(pairs) - 1, 2)}


def main() -> None:
    level = fetch_level_string()
    chunks = level.split(";")
    header = parse_pairs(chunks[0])
    objects = [parse_pairs(chunk) for chunk in chunks[1:] if "1" in parse_pairs(chunk)]
    print(f"objects: {len(objects):,}")

    # Channel table (kS38): entry = k_v pairs separated by '_'.
    channels: dict[int, dict[str, str]] = {}
    for entry in header.get("kS38", "").split("|"):
        if not entry:
            continue
        data = parse_pairs(entry.replace("_", ","))
        channels[int(data.get("6", "0"))] = data
    copy_channels = {cid: c["9"] for cid, c in channels.items() if c.get("9", "0") not in ("", "0")}
    print(f"channels: {len(channels)}, copy channels (k9): {len(copy_channels)}")
    for cid in sorted(copy_channels):
        data = channels[cid]
        print(
            f"  ch {cid}: copies {copy_channels[cid]}"
            f" opacity(k7)={data.get('7', '?')} blending(k5)={data.get('5', '?')}"
            f" rgb=({data.get('1', '?')},{data.get('2', '?')},{data.get('3', '?')})"
        )

    glow_buckets: dict[int, Counter] = defaultdict(Counter)
    disabled_buckets: Counter = Counter()
    glow_channel_objects: Counter = Counter()
    explicit_channel_glow: Counter = Counter()
    for props in objects:
        oid = int(props.get("1", "0"))
        x = float(props.get("2", "0"))
        bucket = int(x // 1000)
        glow_off = props.get("96", "0") == "1"
        if glow_off:
            disabled_buckets[bucket] += 1
            continue
        channel = props.get("21", "")
        glow_buckets[bucket]["count"] += 1
        glow_buckets[bucket][f"ch{channel or 'default'}"] += 1
        glow_channel_objects[channel or "default"] += 1
        if channel:
            explicit_channel_glow[channel] += 1

    print("\n== glow-enabled objects (key 96 != 1) per 1000 x-units ==")
    for bucket in sorted(glow_buckets):
        top = [
            (key, value)
            for key, value in glow_buckets[bucket].most_common(4)
            if key != "count"
        ]
        print(
            f"x {bucket * 1000:>7,}: {glow_buckets[bucket]['count']:>5,} glow objects   top: {top}"
        )

    print("\n== glow objects by channel (key 21) ==")
    for channel, count in glow_channel_objects.most_common(15):
        note = ""
        cid = int(channel) if channel.isdigit() else -1
        if cid in copy_channels:
            note = f"  <-- COPY channel (copies {copy_channels[cid]})"
        elif cid in channels:
            note = f"  opacity(k7)={channels[cid].get('7', '?')}"
        print(f"  channel {channel or '(default)':>8}: {count:>6,}{note}")

    print("\n== colour triggers by X ==")
    trigger_buckets: dict[int, list[dict[str, str]]] = defaultdict(list)
    for props in objects:
        oid = int(props.get("1", "0"))
        if oid in COLOR_TRIGGER_IDS:
            trigger_buckets[int(float(props.get("2", "0")) // 1000)].append(props)
    for bucket in sorted(trigger_buckets):
        targets: Counter = Counter()
        for props in trigger_buckets[bucket]:
            oid = int(props["1"])
            target = props.get("23", LEGACY_TRIGGER_NAMES.get(oid, str(oid)))
            targets[f"{target}{'(copy)' if props.get('50', '0') not in ('', '0') else ''}"] += 1
        print(f"x {bucket * 1000:>7,}: {len(trigger_buckets[bucket]):>3} colour triggers  targets: {targets.most_common(6)}")

    # Cross-reference: channels that glow objects use AND colour triggers target.
    glow_channel_ids = {int(c) for c in glow_channel_objects if c.isdigit()}
    print("\n== colour triggers that target a glow-decorated channel ==")
    for props in objects:
        if int(props.get("1", "0")) != 899:
            continue
        target = props.get("23", "")
        if target.isdigit() and int(target) in glow_channel_ids:
            x = float(props.get("2", "0"))
            print(
                f"  x {x:>8,.0f} -> channel {target}"
                f" rgb=({props.get('7', '?')},{props.get('8', '?')},{props.get('9', '?')})"
                f" opacity(k35)={props.get('35', 'default')}"
                f" copied_from(k50)={props.get('50', '-')}"
                f" copy_opacity(k60)={props.get('60', '-')}"
                f" duration(k10)={props.get('10', '?')}"
            )


if __name__ == "__main__":
    main()
