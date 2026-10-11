#!/usr/bin/env python3
"""Summarise one level_probe run (the sandwich-only probe) from its own log.

Usage: sandwich_probe_summary.py LOG RC
Prints one GitHub notice with the cube's first tick, whether it reached the
sandwich lock (x >= 123), whether it fell out (py < 1000), the max x, and the
probe's own END / placement lines. Reads only LOG, so it is not mixed with the
full probe's interleaved output.
"""
import re
import sys

HIT = re.compile(r"PROBE HIT tick=(\d+) x=([-\d.]+) py=([-\d.]+) floor=(\w+) ceil=(\w+)")
KEEP = ("PROBE END", "PROBE CAM finished", "PROBE CAM start", "pre-place", "SCRIPT ERROR")


def esc(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


def main() -> None:
    log_path, rc = sys.argv[1], sys.argv[2]
    hits = []
    extra = []
    with open(log_path, errors="replace") as log:
        for line in log:
            m = HIT.match(line)
            if m:
                hits.append((int(m[1]), float(m[2]), float(m[3]), m[4] == "true", m[5] == "true"))
            elif any(k in line for k in KEEP):
                extra.append("SW " + line.strip()[:160])
    out = [f"SW rc={rc} hits={len(hits)}"]
    if hits:
        t, x, py, floor, ceil = hits[0]
        out.append(f"SW first tick={t} x={x:.1f} py={py:.1f} floor={floor} ceil={ceil}")
        past = [h for h in hits if h[1] >= 123]
        out.append("SW reached x>=123: " + (f"tick={past[0][0]} x={past[0][1]:.1f} py={past[0][2]:.1f}" if past else "never"))
        fell = [h for h in hits if h[2] < 1000]
        out.append("SW py<1000 (fell out): " + (f"tick={fell[0][0]} x={fell[0][1]:.1f} py={fell[0][2]:.1f}" if fell else "never"))
        out.append(f"SW max x={max(h[1] for h in hits):.1f} last tick={hits[-1][0]} x={hits[-1][1]:.1f} py={hits[-1][2]:.1f}")
        out.append(f"SW floor ticks={sum(h[3] for h in hits)} ceil ticks={sum(h[4] for h in hits)}")
    out.extend(extra)
    print("::notice title=sandwich-only summary::" + esc("\n".join(out)))


if __name__ == "__main__":
    main()
