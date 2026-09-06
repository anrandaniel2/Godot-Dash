#!/usr/bin/env python3
"""Build the object-ID -> atlas-frame mapping used by Godot Dash.

Where the mapping comes from
----------------------------
Geometry Dash keeps this table inside its compiled ``ObjectToolbox::init`` -
roughly four thousand ``{objectID: "frame_name.png"}`` pairs - and does not ship
it as data. This script therefore takes the table as *input*: a plain text file
of ``<objectID>:<frame name>`` lines, one per object, dumped from the game.

    1:square_01_001.png
    8:spike_01_001.png
    36:ring_01_001.png

Every line is then validated against the atlases that ship in
``assets/textures/gd_atlas``. An entry whose frame does not exist in any atlas
is dropped rather than written, so the generated table can never point at
artwork that isn't there.

Layer discovery
---------------
Geometry Dash draws most objects as up to three stacked sprites, distinguished
by a suffix on the base frame name::

    square_01_001.png         base silhouette
    square_01_color_001.png   recolourable detail layer
    square_01_glow_001.png    additive glow layer

The extra layers are found by probing those names against the atlases, so only
layers that genuinely exist are recorded.

Usage
-----
    python3 tools/build_object_frames.py --id-list path/to/id_list.txt
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"

# Loaded in priority order: the first atlas to define a frame owns it.
SHEETS = [
    "GJ_GameSheet02",
    "GJ_GameSheet",
    "GJ_GameSheet03",
    "GJ_GameSheet04",
    "GJ_GameSheetGlow",
    "GJ_ParticleSheet",
    "FireSheet_01",
    "GroundSheet_01",
    "PixelSheet_01",
]

# "<stem>_001.png" -> stem, index
BASE_RE = re.compile(r"^(?P<stem>.+)_(?P<index>\d{3})\.png$")

# Suffix -> layer name. Ordered by how common they are in the atlases.
LAYER_SUFFIXES = {
    "color": "detail",
    "glow": "glow",
    "extra": "extra",
}

# Frames that are editor UI rather than level artwork. Several UI buttons are
# genuinely referenced by the toolbox table (the editor reuses object IDs for
# its own buttons), but they must never be drawn as level objects.
# Editor chrome that the toolbox table also references: the editor reuses object
# ids for its own buttons, and those must never be drawn as level objects.
#
# The match is deliberately narrow. A broader "gj_" rule also caught gj_drops,
# gj_smoke, gj_bubble and gj_lightning - genuine level decoration - and silently
# dropped ~190 objects from every import.
UI_PREFIXES = ("edit_", "GJ_", "difficulty", "diff", "emoji")

# Frame families that begin with "gj_" but are real artwork, not editor UI.
GJ_ART_PREFIXES = ("gj_drops", "gj_smoke", "gj_bubble", "gj_lightning", "gj_hand", "gjHand")


def is_editor_ui(frame: str) -> bool:
    """True when a frame is editor chrome rather than level artwork."""
    if frame.startswith(GJ_ART_PREFIXES):
        return False
    if frame.startswith("gj_"):
        return True
    return frame.startswith(UI_PREFIXES)


def load_atlas_frames(atlas_dir: Path) -> dict[str, str]:
    """frame name -> owning atlas, across every sheet present."""
    owner: dict[str, str] = {}
    for sheet in SHEETS:
        for suffix in ("-hd", ""):
            plist_path = atlas_dir / f"{sheet}{suffix}.plist"
            if not plist_path.exists():
                continue
            with plist_path.open("rb") as handle:
                data = plistlib.load(handle)
            for frame in data.get("frames", {}):
                owner.setdefault(frame, sheet)
            break
    return owner


def parse_id_list(path: Path) -> dict[int, str]:
    """Read ``<id>:<frame>`` lines, tolerating CRLF and stray blanks."""
    mapping: dict[int, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or ":" not in line:
            continue
        left, right = line.split(":", 1)
        left, right = left.strip(), right.strip()
        if not left.isdigit() or not right:
            continue
        mapping[int(left)] = right
    return mapping


def find_layers(base: str, owner: dict[str, str]) -> dict[str, str]:
    """Locate the detail/glow/extra companions of a base frame."""
    match = BASE_RE.match(base)
    if not match:
        return {}
    stem = match.group("stem")
    index = match.group("index")

    layers: dict[str, str] = {}
    for suffix, layer in LAYER_SUFFIXES.items():
        candidate = f"{stem}_{suffix}_{index}.png"
        if candidate in owner:
            layers[layer] = candidate

    # Geometry Dash has a second convention for the recolourable layer:
    #
    #     square_01_001.png       -> square_01_color_001.png   (suffix)
    #     Fire_03_looped_001.png  -> Fire_03_2_looped_001.png  (infix)
    #
    # Animated objects put "_2" in the middle, because the frame number has to
    # stay at the end. Checking only the suffix missed 58 detail layers.
    if "detail" not in layers:
        infix = re.sub(r"^([A-Za-z]+)_(\d+)_", r"\1_\2_2_", stem, count=1)
        candidate = f"{infix}_{index}.png"
        if infix != stem and candidate in owner:
            layers["detail"] = candidate

    return layers


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--id-list", type=Path, required=True, help="<id>:<frame> text dump")
    parser.add_argument("--atlas-dir", type=Path, default=DEFAULT_ATLAS_DIR)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    if not args.id_list.exists():
        sys.exit(f"id list not found: {args.id_list}")
    if not args.atlas_dir.is_dir():
        sys.exit(f"atlas directory not found: {args.atlas_dir}")

    owner = load_atlas_frames(args.atlas_dir)
    if not owner:
        sys.exit(f"no .plist atlases found in {args.atlas_dir}")
    print(f"{len(owner):,} frames across the atlases")

    raw = parse_id_list(args.id_list)
    print(f"{len(raw):,} id -> frame pairs in {args.id_list.name}")

    entries: dict[int, dict] = {}
    missing: list[tuple[int, str]] = []
    skipped_ui = 0

    for object_id, frame in sorted(raw.items()):
        if is_editor_ui(frame):
            skipped_ui += 1
            continue
        if frame not in owner:
            missing.append((object_id, frame))
            continue
        entry = {"base": frame, "sheet": owner[frame]}
        entry.update(find_layers(frame, owner))
        entries[object_id] = entry

    detail_count = sum(1 for e in entries.values() if "detail" in e)
    glow_count = sum(1 for e in entries.values() if "glow" in e)

    print(f"\nverified entries : {len(entries):,}")
    print(f"  with detail    : {detail_count:,}")
    print(f"  with glow      : {glow_count:,}")
    print(f"  editor UI skipped: {skipped_ui:,}")
    print(f"  frame not in atlas: {len(missing):,}")
    if missing:
        preview = ", ".join(f"{i}:{f}" for i, f in missing[:5])
        print(f"    e.g. {preview}")

    out_path: Path = args.out or (args.atlas_dir / "object_frames.json")
    payload = {
        "_source": "ObjectToolbox id list, validated against the shipped atlases",
        "_verified": "every frame below exists in an atlas plist",
        "_count": len(entries),
        "frames": {str(i): entries[i] for i in sorted(entries)},
    }
    out_path.write_text(json.dumps(payload, indent="\t"))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
