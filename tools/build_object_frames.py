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

Multi-sprite objects
--------------------
Many objects are not one sprite but a small tree of them: an outline with a
black fill behind it, a sawblade built from a half-blade mirrored twice, a
"perspective" block whose root sprite is an empty frame and whose visible
pieces are all children. Drawing only the root sprite of those objects is what
left hollow outlines, half sawblades and blank squares in imported levels.

That tree is not in the id list. It is taken from ``gdrweb_objects.json``, a
dump of the object table shipped by the MIT-licensed gdrweb renderer (itself
derived from the game's own object data). For every id it covers, the root
sprite's colour class, its default colour channels and every child sprite with
its transform are recorded as ``parts``, flattened into draw order.

Layer discovery
---------------
For ids the object table does not cover, Geometry Dash's naming convention is
used to find companion sprites::

    square_01_001.png         base silhouette
    square_01_color_001.png   recolourable detail layer
    square_01_glow_001.png    additive glow layer

The glow layer is probed for every object, since the object table does not
describe glow.

Usage
-----
    python3 tools/build_object_frames.py --id-list path/to/id_list.txt
"""

from __future__ import annotations

import argparse
import json
import math
import plistlib
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"
DEFAULT_GDRWEB_JSON = PROJECT_ROOT / "tools" / "gdrweb_objects.json"

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

# The frame Geometry Dash gives objects whose root sprite draws nothing.
EMPTY_FRAME = "emptyFrame.png"

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


def find_layers(base: str, owner: dict[str, str], detail: bool = True) -> dict[str, str]:
    """Locate the detail/glow/extra companions of a base frame.

    ``detail`` is False for objects whose sprite tree is known exactly: a
    ``_color_`` frame is then already accounted for as a part (or is genuinely
    unused), and guessing it back in would paint an opaque white fill over the
    object - which is precisely what several outline blocks looked like.
    """
    match = BASE_RE.match(base)
    if not match:
        return {}
    stem = match.group("stem")
    index = match.group("index")

    layers: dict[str, str] = {}
    for suffix, layer in LAYER_SUFFIXES.items():
        if layer == "detail" and not detail:
            continue
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
    if detail and "detail" not in layers:
        infix = re.sub(r"^([A-Za-z]+)_(\d+)_", r"\1_\2_2_", stem, count=1)
        candidate = f"{infix}_{index}.png"
        if infix != stem and candidate in owner:
            layers["detail"] = candidate

    return layers


# --- multi-sprite objects ---------------------------------------------------


def load_gdrweb(path: Path | None) -> dict[str, dict]:
    """The object table: id -> {texture, color_type, children[], ...}."""
    if path is None or not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    # Accept both the raw dump and the wrapped copy kept in tools/.
    objects = data.get("objects", data) if isinstance(data, dict) else {}
    return {str(k): v for k, v in objects.items() if isinstance(v, dict)}


def color_class(value: str | None) -> str:
    """Object table colour type -> the class name Godot Dash uses."""
    return {"Base": "base", "Detail": "detail", "Black": "black"}.get(value or "", "base")


def compose(parent: tuple, child: tuple) -> tuple:
    """Fold a child's (x, y, rot, sx, sy) into its parent's frame.

    Coordinates are Geometry Dash units with y up, rotations anticlockwise, as
    the object table stores them. The parent's scale is always uniform in
    magnitude (a flip at most), which is what lets the result stay a plain
    position/rotation/scale triple instead of a general matrix.
    """
    px, py, prot, psx, psy = parent
    cx, cy, crot, csx, csy = child
    # Child position: scaled, then rotated, in the parent's frame.
    scaled_x, scaled_y = cx * psx, cy * psy
    radians = math.radians(prot)
    cos, sin = math.cos(radians), math.sin(radians)
    x = px + cos * scaled_x - sin * scaled_y
    y = py + sin * scaled_x + cos * scaled_y
    # A single-axis flip in the parent mirrors the child's rotation.
    mirrored = (psx < 0) != (psy < 0)
    rot = prot - crot if mirrored else prot + crot
    return (x, y, rot, psx * csx, psy * csy)


def flatten_parts(root: dict, owner: dict[str, str]) -> tuple[list[dict], int, list[str]]:
    """Depth-first draw order of a sprite tree, relative to its root.

    Returns (parts, missing): ``parts`` in draw order, each with ``order``
    negative for sprites drawn behind the root and positive for those in front;
    ``missing`` lists child frames absent from the atlases (dropped).
    """
    sequence: list[tuple[dict, tuple]] = []  # (node, world (x, y, rot, sx, sy))
    missing: list[str] = []
    ROOT = object()

    def visit(node: dict, world: tuple, is_root: bool) -> None:
        children = [c for c in node.get("children", []) if isinstance(c, dict)]
        # The renderer keeps children sorted by z, stable for equal z.
        children.sort(key=lambda c: c.get("z", 0))
        composed = []
        for child in children:
            sx = float(child.get("scale_x", 1)) * (-1.0 if child.get("flip_x") else 1.0)
            sy = float(child.get("scale_y", 1)) * (-1.0 if child.get("flip_y") else 1.0)
            local = (
                float(child.get("x", 0)),
                float(child.get("y", 0)),
                float(child.get("rot", 0)),
                sx,
                sy,
            )
            composed.append((child, compose(world, local)))
        index = 0
        while index < len(composed) and composed[index][0].get("z", 0) < 0:
            visit(composed[index][0], composed[index][1], False)
            index += 1
        sequence.append((ROOT if is_root else node, world))
        while index < len(composed):
            visit(composed[index][0], composed[index][1], False)
            index += 1

    visit(root, (0.0, 0.0, 0.0, 1.0, 1.0), True)

    root_index = next(i for i, (node, _) in enumerate(sequence) if node is ROOT)
    parts: list[dict] = []
    for position, (node, world) in enumerate(sequence):
        if node is ROOT:
            continue
        frame = node.get("texture")
        if not frame or frame not in owner:
            missing.append(str(frame))
            continue
        x, y, rot, sx, sy = world
        part: dict = {"frame": frame, "order": position - root_index}
        # Defaults are omitted to keep the table small; the loader fills them.
        if abs(x) > 1e-6:
            part["x"] = round(x, 4)
        if abs(y) > 1e-6:
            part["y"] = round(y, 4)
        if abs(rot) > 1e-6:
            part["rot"] = round(rot, 4)
        if abs(sx - 1.0) > 1e-6:
            part["sx"] = round(sx, 4)
        if abs(sy - 1.0) > 1e-6:
            part["sy"] = round(sy, 4)
        anchor_x = float(node.get("anchor_x", 0) or 0)
        anchor_y = float(node.get("anchor_y", 0) or 0)
        if abs(anchor_x) > 1e-6:
            part["ax"] = round(anchor_x, 4)
        if abs(anchor_y) > 1e-6:
            part["ay"] = round(anchor_y, 4)
        klass = color_class(node.get("color_type"))
        if klass != "base":
            part["color"] = klass
        opacity = node.get("opacity")
        if opacity is not None and abs(float(opacity) - 1.0) > 1e-6:
            part["opacity"] = round(float(opacity), 4)
        parts.append(part)
    return parts, root_index, missing


def entry_from_gdrweb(frame: str, spec: dict, owner: dict[str, str]) -> tuple[dict | None, list[str]]:
    """Build a table entry from the object table, or None to fall back."""
    texture = spec.get("texture")
    if not texture or texture not in owner:
        return None, []
    # The object table is authoritative for the root frame too: the id list
    # occasionally names a sibling frame for the same object.
    entry: dict = {"base": texture, "sheet": owner[texture]}

    root_class = color_class(spec.get("color_type"))
    parts, _, missing = flatten_parts(spec, owner)

    # An object whose sprites are all "detail" follows the base channel, as it
    # does in the game (the renderer performs the same normalisation).
    classes = {root_class} | {p.get("color", "base") for p in parts}
    if classes == {"detail"}:
        root_class = "base"
        for part in parts:
            part.pop("color", None)

    if root_class != "base":
        entry["color"] = root_class
    opacity = spec.get("opacity")
    if opacity is not None and abs(float(opacity) - 1.0) > 1e-6:
        entry["opacity"] = round(float(opacity), 4)
    if parts:
        entry["parts"] = parts
    # Glow is not described by the object table, so it is still probed.
    entry.update(find_layers(texture, owner, detail=False))
    return entry, missing


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--id-list", type=Path, required=True, help="<id>:<frame> text dump")
    parser.add_argument("--atlas-dir", type=Path, default=DEFAULT_ATLAS_DIR)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument(
        "--gdrweb-json",
        type=Path,
        default=DEFAULT_GDRWEB_JSON,
        help="object table dump (id -> sprite tree); multi-sprite objects come from here",
    )
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

    gdrweb = load_gdrweb(args.gdrweb_json)
    print(f"{len(gdrweb):,} sprite trees in {args.gdrweb_json.name if gdrweb else '(no object table)'}")

    entries: dict[int, dict] = {}
    missing: list[tuple[int, str]] = []
    missing_parts: list[tuple[int, str]] = []
    skipped_ui = 0
    from_tree = 0

    # Every id either source knows about. The object table can describe an
    # object the id list lacks, but never a UI button as level art.
    all_ids = set(raw) | {int(k) for k in gdrweb if k.isdigit()}
    for object_id in sorted(all_ids):
        frame = raw.get(object_id, "")
        spec = gdrweb.get(str(object_id))
        tree_frame = spec.get("texture") if spec else None
        if is_editor_ui(frame) or (tree_frame and is_editor_ui(tree_frame)):
            skipped_ui += 1
            continue

        entry = None
        if spec is not None:
            entry, dropped = entry_from_gdrweb(frame, spec, owner)
            missing_parts.extend((object_id, name) for name in dropped)
        if entry is not None:
            from_tree += 1
        else:
            if not frame:
                continue
            if frame not in owner:
                missing.append((object_id, frame))
                continue
            entry = {"base": frame, "sheet": owner[frame]}
            entry.update(find_layers(frame, owner))
        entries[object_id] = entry

    detail_count = sum(1 for e in entries.values() if "detail" in e)
    glow_count = sum(1 for e in entries.values() if "glow" in e)
    parts_count = sum(1 for e in entries.values() if "parts" in e)
    empty_root = sum(1 for e in entries.values() if e["base"] == EMPTY_FRAME)

    print(f"\nverified entries : {len(entries):,}")
    print(f"  from sprite tree : {from_tree:,}")
    print(f"  with parts       : {parts_count:,}")
    print(f"  invisible root   : {empty_root:,}")
    print(f"  with detail      : {detail_count:,}")
    print(f"  with glow        : {glow_count:,}")
    print(f"  editor UI skipped: {skipped_ui:,}")
    print(f"  frame not in atlas: {len(missing):,}")
    if missing:
        preview = ", ".join(f"{i}:{f}" for i, f in missing[:5])
        print(f"    e.g. {preview}")
    print(f"  parts dropped (frame missing): {len(missing_parts):,}")
    if missing_parts:
        preview = ", ".join(f"{i}:{f}" for i, f in missing_parts[:5])
        print(f"    e.g. {preview}")

    out_path: Path = args.out or (args.atlas_dir / "object_frames.json")
    payload = {
        "_source": "ObjectToolbox id list, validated against the shipped atlases",
        "_parts_source": "gdrweb object table (MIT) for the sprite tree of multi-sprite objects",
        "_verified": "every frame below exists in an atlas plist",
        "_count": len(entries),
        "frames": {str(i): entries[i] for i in sorted(entries)},
    }
    out_path.write_text(json.dumps(payload, indent="\t"))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
