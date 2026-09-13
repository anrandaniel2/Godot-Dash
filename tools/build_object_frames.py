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

Multi-sprite objects
--------------------
Nearly every object is not one sprite but a small stack of them: a glow behind
a block, a black fill under an outline, a sawblade built from mirrored halves,
a "perspective" block whose root sprite is empty and whose visible pieces are
all children. Drawing only the root sprite of those objects is what left
hollow outlines, half sawblades and blank squares in imported levels.

The sprite stack is taken from ``tools/gdrweb_objects_22.json``: the 2.2-era
object table shipped by the MIT-licensed GDRWeb renderer
(github.com/iliasHDZ/GDRWeb, object data by Opstic & Maxnut), covering object
ids 1 to 4539. For every id it lists each sprite with its texture, colour
class (base/detail/black/glow), position, scale, flip, rotation and content
size, in draw order.

The table stores, per sprite, the position of the *untrimmed* content box's
bottom-left corner (Geometry Dash units, y up) plus the box's ``contentSize``;
the cocos2d trim offset is applied by the game at render time. Godot Dash's
loader applies the same trim offset from its own atlas, so the conversion is a
plain centre-of-box computation::

    center = position + R(rot) . S(scale) . (contentSize / 2)

validated against the previous (2.1-era) gdrweb dump: for the 1,600 objects
both tables describe, sprite centres agree to within 0.01 units. Where the
table's ``spriteOffset`` deviates from the atlas plist's trim offset (a handful
of frames), the difference is folded into the part position.

Only the *opacity* still comes from the old 2.1 dump
(``tools/gdrweb_objects.json``): the 2.2 table does not carry per-sprite
opacity, and ~70 sprites (semi-transparent block fills, pixel-art decor) need
it. Opacities are merged per (object id, texture).

Fallbacks and layer discovery
-----------------------------
For the handful of ids the object table does not describe, the toolbox frame is
used directly, and companion sprites are found by Geometry Dash's naming
convention::

    square_01_001.png         base silhouette
    square_01_color_001.png   recolourable detail layer
    square_01_glow_001.png    additive glow layer

Objects whose sprite tree already contains glow sprites are not probed for
glow, so the layer is never drawn twice.

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
DEFAULT_ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas" / "source"
DEFAULT_GDRWEB_JSON = PROJECT_ROOT / "tools" / "gdrweb_objects_22.json"
DEFAULT_LEGACY_JSON = PROJECT_ROOT / "tools" / "gdrweb_objects.json"
DEFAULT_OUT = PROJECT_ROOT / "assets" / "textures" / "gd_atlas" / "object_frames.json"

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
UI_PREFIXES = ("edit_", "GJ_", "difficulty", "diff", "emoji")

# Frame families that begin with "gj_" but are real artwork, not editor UI.
GJ_ART_PREFIXES = ("gj_drops", "gj_smoke", "gj_bubble", "gj_lightning", "gj_hand", "gjHand")

# The colour classes a 2.2-table sprite can carry; "glow" sprites are drawn
# additively and follow the base colour channel.
COLOR_CLASSES = {"base", "detail", "black", "glow"}


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


def load_atlas_offsets(atlas_dir: Path) -> dict[str, tuple[float, float]]:
    """frame name -> cocos2d trim offset (as stored in the plist, y down),
    converted to Geometry Dash units (atlas pixels / 2 for the -hd sheets)."""
    offsets: dict[str, tuple[float, float]] = {}
    for sheet in SHEETS:
        for suffix in ("-hd", ""):
            plist_path = atlas_dir / f"{sheet}{suffix}.plist"
            if not plist_path.exists():
                continue
            with plist_path.open("rb") as handle:
                data = plistlib.load(handle)
            divisor = 2.0 if suffix == "-hd" else 1.0
            for frame, info in data.get("frames", {}).items():
                raw = info.get("offset", info.get("spriteOffset"))
                values = _bracket_numbers(raw)
                if len(values) >= 2:
                    offsets[frame] = (values[0] / divisor, values[1] / divisor)
            break
    return offsets


def _bracket_numbers(value) -> list[float]:
    if isinstance(value, str):
        parts = value.replace("{", "").replace("}", "").split(",")
        try:
            return [float(part) for part in parts]
        except ValueError:
            return []
    if isinstance(value, (list, tuple)):
        return [float(v) for v in value]
    return []


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

    Only used for ids the object table does not describe: a tree carries its
    own detail and glow sprites, and guessing them back in would paint an
    opaque white fill over the object - which is precisely what several
    outline blocks looked like before the trees were trusted.
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


# --- the 2.2 object table ----------------------------------------------------


def load_object_table(path: Path | None) -> dict[str, dict]:
    """The 2.2 object table: id -> {spriteSheet, defaultZLayer, sprites[], ...}."""
    if path is None or not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    objects = data.get("objects", data) if isinstance(data, dict) else {}
    return {str(k): v for k, v in objects.items() if isinstance(v, dict)}


def load_legacy_opacities(path: Path | None) -> dict[int, dict[str, float]]:
    """Per-object sprite opacities from the 2.1-era dump: id -> texture -> opacity.

    The 2.2 table dropped per-sprite opacity; the semi-transparent block fills
    and pixel-art decor still need theirs.
    """
    result: dict[int, dict[str, float]] = {}
    if path is None or not path.exists():
        return result
    data = json.loads(path.read_text(encoding="utf-8"))
    objects = data.get("objects", data) if isinstance(data, dict) else {}
    for key, spec in objects.items():
        if not isinstance(spec, dict) or not key.isdigit():
            continue

        def visit(node: dict) -> None:
            opacity = node.get("opacity")
            texture = node.get("texture")
            if opacity is not None and texture:
                try:
                    value = float(opacity)
                except (TypeError, ValueError):
                    return
                if abs(value - 1.0) > 1e-6:
                    result.setdefault(int(key), {})[texture] = value
            for child in node.get("children", []):
                if isinstance(child, dict):
                    visit(child)

        visit(spec)
    return result


def sprite_center(sprite: dict, atlas_offsets: dict[str, tuple[float, float]]) -> tuple[float, float]:
    """The sprite's untrimmed-box centre, in Geometry Dash units, y up.

    The table places the box by its bottom-left corner and rotates/scales
    around that corner's transform, so the centre is the transformed half-size.
    A ``spriteOffset`` that disagrees with the atlas plist's trim offset (a
    handful of frames) shifts the box by the difference, y flipped, because the
    plist stores offsets y-down while positions are y-up.
    """
    px, py = (float(v) for v in sprite["position"])
    csx, csy = (float(v) for v in sprite["contentSize"])
    rot = math.radians(float(sprite.get("rotation", 0.0)))
    sx, sy = (float(v) for v in sprite.get("scale", (1.0, 1.0)))

    vx = csx / 2.0
    vy = csy / 2.0
    sox, soy = (float(v) for v in sprite.get("spriteOffset", (0.0, 0.0)))
    plist_offset = atlas_offsets.get(sprite["texture"])
    if plist_offset is not None:
        dx = sox - plist_offset[0]
        dy = -(soy - plist_offset[1])
        if abs(dx) > 1e-6 or abs(dy) > 1e-6:
            vx += dx
            vy += dy

    cos_r, sin_r = math.cos(rot), math.sin(rot)
    x = px + cos_r * sx * vx - sin_r * sy * vy
    y = py + sin_r * sx * vx + cos_r * sy * vy
    return x, y


def pick_root_index(sprites: list[dict], toolbox_frame: str, legacy_roots: dict[int, str], object_id: int) -> int:
    """Which sprite stands for the object: the one the toolbox names, else the
    one the 2.1 table called the root, else the largest. Glow sprites never
    stand in - the root path draws opaque, and an object's glow belongs to its
    positioned glow parts."""
    def eligible(index: int, sprite: dict) -> bool:
        return str(sprite.get("colorType", "base")) != "glow" or all(
            str(s.get("colorType", "base")) == "glow" for s in sprites
        )

    for index, sprite in enumerate(sprites):
        if sprite["texture"] == toolbox_frame and eligible(index, sprite):
            return index
    legacy = legacy_roots.get(object_id)
    if legacy:
        for index, sprite in enumerate(sprites):
            if sprite["texture"] == legacy and eligible(index, sprite):
                return index
    best, best_area = 0, -1.0
    for index, sprite in enumerate(sprites):
        if not eligible(index, sprite):
            continue
        csx, csy = (float(v) for v in sprite.get("contentSize", (0.0, 0.0)))
        sx, sy = (float(v) for v in sprite.get("scale", (1.0, 1.0)))
        area = abs(csx * csy * sx * sy)
        if area >= best_area:
            best, best_area = index, area
    return best


def entry_from_object_table(
    object_id: int,
    spec: dict,
    toolbox_frame: str,
    owner: dict[str, str],
    atlas_offsets: dict[str, tuple[float, float]],
    opacities: dict[str, float],
) -> tuple[dict | None, list[str]]:
    """Build a table entry from the 2.2 object table, or None to fall back."""
    raw_sprites = [s for s in spec.get("sprites", []) if isinstance(s, dict)]
    sprites = [s for s in raw_sprites if s.get("texture") and s["texture"] in owner]
    missing = [str(s.get("texture")) for s in raw_sprites if not s.get("texture") or s["texture"] not in owner]
    if not sprites:
        return None, missing

    root_index = pick_root_index(sprites, toolbox_frame, LEGACY_ROOTS, object_id)
    root = sprites[root_index]

    # An object whose sprites are all "detail" follows the base channel, as it
    # does in the game (the renderer performs the same normalisation).
    classes = {str(s.get("colorType", "base")) for s in sprites}
    all_detail = classes == {"detail"}

    parts: list[dict] = []
    has_glow_sprite = False
    for index, sprite in enumerate(sprites):
        if index == root_index:
            continue
        x, y = sprite_center(sprite, atlas_offsets)
        sx, sy = (float(v) for v in sprite.get("scale", (1.0, 1.0)))
        if sprite.get("flipX"):
            sx = -sx
        if sprite.get("flipY"):
            sy = -sy
        color = str(sprite.get("colorType", "base"))
        if color not in COLOR_CLASSES:
            color = "base"
        if all_detail and color == "detail":
            color = "base"
        if color == "glow":
            has_glow_sprite = True
        part: dict = {"frame": sprite["texture"], "order": index - root_index}
        # Defaults are omitted to keep the table small; the loader fills them.
        if abs(x) > 1e-4:
            part["x"] = round(x, 4)
        if abs(y) > 1e-4:
            part["y"] = round(y, 4)
        rot = float(sprite.get("rotation", 0.0))
        if abs(rot) > 1e-4:
            part["rot"] = round(rot, 4)
        if abs(sx - 1.0) > 1e-4:
            part["sx"] = round(sx, 4)
        if abs(sy - 1.0) > 1e-4:
            part["sy"] = round(sy, 4)
        if color != "base":
            part["color"] = color
        opacity = opacities.get(sprite["texture"])
        if opacity is not None:
            part["opacity"] = round(opacity, 4)
        parts.append(part)

    root_color = str(root.get("colorType", "base"))
    if root_color not in COLOR_CLASSES:
        root_color = "base"
    if all_detail and root_color == "detail":
        root_color = "base"
    entry: dict = {"base": root["texture"]}
    if root_color != "base":
        entry["color"] = root_color
    root_opacity = opacities.get(root["texture"])
    if root_opacity is not None:
        entry["opacity"] = round(root_opacity, 4)

    # The root sprite's own placement. Geometry Dash draws the root like any
    # other sprite - it can sit off the object's centre, be scaled, rotated or
    # mirrored - while the root path used to assume it was always centred and
    # untransformed, which misplaced half of the perspective blocks and every
    # flipped sawblade root.
    root_x, root_y = sprite_center(root, atlas_offsets)
    root_sx, root_sy = (float(v) for v in root.get("scale", (1.0, 1.0)))
    if root.get("flipX"):
        root_sx = -root_sx
    if root.get("flipY"):
        root_sy = -root_sy
    root_rot = float(root.get("rotation", 0.0))
    if abs(root_x) > 1e-4:
        entry["rx"] = round(root_x, 4)
    if abs(root_y) > 1e-4:
        entry["ry"] = round(root_y, 4)
    if abs(root_rot) > 1e-4:
        entry["rrot"] = round(root_rot, 4)
    if abs(root_sx - 1.0) > 1e-4:
        entry["rsx"] = round(root_sx, 4)
    if abs(root_sy - 1.0) > 1e-4:
        entry["rsy"] = round(root_sy, 4)

    if parts:
        entry["parts"] = parts

    # Where Geometry Dash draws the object when the level string carries no
    # explicit z layer (key 24) or z order (key 25): 1/3/5 are B2/B1/T1.
    z_layer = spec.get("defaultZLayer")
    z_order = spec.get("defaultZOrder")
    if z_layer is not None:
        entry["zl"] = int(z_layer)
    if z_order is not None:
        entry["zo"] = int(z_order)

    # Glow: the tree names its glow sprites explicitly, so the naming
    # convention is only probed for objects without any. Probing both would
    # draw the glow layer twice.
    if not has_glow_sprite:
        entry.update(find_layers(root["texture"], owner, detail=False))
    return entry, missing


# The 2.1 table's root texture per id, used only to keep root selection stable
# for the objects the toolbox names a sibling frame for. Filled by main().
LEGACY_ROOTS: dict[int, str] = {}


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
        help="2.2 object table (id -> flat sprite list); multi-sprite objects come from here",
    )
    parser.add_argument(
        "--legacy-gdrweb-json",
        type=Path,
        default=DEFAULT_LEGACY_JSON,
        help="2.1-era object table; only per-sprite opacities and root stability come from here",
    )
    args = parser.parse_args()

    if not args.id_list.exists():
        sys.exit(f"id list not found: {args.id_list}")
    if not args.atlas_dir.is_dir():
        sys.exit(f"atlas directory not found: {args.atlas_dir}")

    owner = load_atlas_frames(args.atlas_dir)
    if not owner:
        sys.exit(f"no .plist atlases found in {args.atlas_dir}")
    atlas_offsets = load_atlas_offsets(args.atlas_dir)
    print(f"{len(owner):,} frames across the atlases")

    raw = parse_id_list(args.id_list)
    print(f"{len(raw):,} id -> frame pairs in {args.id_list.name}")

    table = load_object_table(args.gdrweb_json)
    print(f"{len(table):,} sprite stacks in {args.gdrweb_json.name if table else '(no object table)'}")

    legacy = load_object_table(args.legacy_gdrweb_json)
    for key, spec in legacy.items():
        if key.isdigit() and isinstance(spec.get("texture"), str):
            LEGACY_ROOTS[int(key)] = spec["texture"]
    opacities = load_legacy_opacities(args.legacy_gdrweb_json)

    entries: dict[int, dict] = {}
    missing: list[tuple[int, str]] = []
    missing_parts: list[tuple[int, str]] = []
    skipped_ui = 0
    from_tree = 0
    glow_parts = 0

    # Every id either source knows about. The object table can describe an
    # object the id list lacks, but never a UI button as level art.
    all_ids = set(raw) | {int(k) for k in table if k.isdigit()}
    for object_id in sorted(all_ids):
        frame = raw.get(object_id, "")
        spec = table.get(str(object_id))
        if is_editor_ui(frame):
            skipped_ui += 1
            continue

        entry = None
        if spec is not None:
            entry, dropped = entry_from_object_table(
                object_id, spec, frame, owner, atlas_offsets, opacities.get(object_id, {})
            )
            missing_parts.extend((object_id, name) for name in dropped)
        if entry is not None:
            from_tree += 1
            glow_parts += sum(1 for p in entry.get("parts", []) if p.get("color") == "glow")
        else:
            if not frame:
                continue
            if frame not in owner:
                missing.append((object_id, frame))
                continue
            entry = {"base": frame}
            entry.update(find_layers(frame, owner))
        entries[object_id] = entry

    detail_count = sum(1 for e in entries.values() if "detail" in e)
    glow_count = sum(1 for e in entries.values() if "glow" in e)
    parts_count = sum(1 for e in entries.values() if "parts" in e)
    empty_root = sum(1 for e in entries.values() if e["base"] == EMPTY_FRAME)
    detail_parts = sum(1 for e in entries.values() for p in e.get("parts", []) if p.get("color") == "detail")
    black_parts = sum(1 for e in entries.values() for p in e.get("parts", []) if p.get("color") == "black")

    print(f"\nverified entries : {len(entries):,}")
    print(f"  from sprite stack : {from_tree:,}")
    print(f"  with parts        : {parts_count:,}")
    print(f"  invisible root    : {empty_root:,}")
    print(f"  with legacy detail: {detail_count:,}")
    print(f"  with legacy glow  : {glow_count:,}")
    print(f"  detail parts      : {detail_parts:,}")
    print(f"  black parts       : {black_parts:,}")
    print(f"  glow parts        : {glow_parts:,}")
    print(f"  editor UI skipped : {skipped_ui:,}")
    print(f"  frame not in atlas: {len(missing):,}")
    if missing:
        preview = ", ".join(f"{i}:{f}" for i, f in missing[:5])
        print(f"    e.g. {preview}")
    print(f"  parts dropped (frame missing): {len(missing_parts):,}")
    if missing_parts:
        preview = ", ".join(f"{i}:{f}" for i, f in missing_parts[:5])
        print(f"    e.g. {preview}")

    out_path: Path = args.out or DEFAULT_OUT
    payload = {
        "_source": "ObjectToolbox id list, validated against the shipped atlases",
        "_parts_source": "GDRWeb 2.2 object table (MIT, github.com/iliasHDZ/GDRWeb; object data by Opstic & Maxnut) for the sprite stack of multi-sprite objects and the default z layer/order (zl/zo)",
        "_verified": "every frame below exists in an atlas plist",
        "_count": len(entries),
        "frames": {str(i): entries[i] for i in sorted(entries)},
    }
    out_path.write_text(json.dumps(payload, indent="\t"))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
