"""Single source of truth for gameplay collision on Geometry Dash object scenes.

The generated ``scenes/gd_objects/gd_<id>.tscn`` scenes are pure artwork + a
``Collision`` body. This module decides which IDs are gameplay objects (solid,
slope, rectangular hazard, circular hazard) and what their PRISTINE hitbox is,
in scene pixels relative to the object's node origin (the node origin is the
same anchor the level importer places objects on, so shapes written here land
exactly where the artwork is placed in a level).

Value policy, per the unification plan (GD_UNIFICATION_PLAN.md rule 4: GD
hitboxes must be pristine - exact GD metrics):

1. **Game-extracted hitbox data** (``tools/gd_hitbox_data.json``, built by
   ``tools/extract_gd_hitboxes.py`` from the OpenGD project's preservation of
   Geometry Dash's own hitbox tables + object classification): every solid,
   hazard, slope and breakable-brick ID gets its exact GD geometry -
   rects/radii in GD units converted at ``GD_TO_WORLD``, slopes as exact
   triangles inside their GD rect bounds with the orientation derived from the
   game artwork. IDs the game classifies as decoration/interactable carry no
   static collision (interactables keep their hand-made scenes; their GD
   trigger rects live in the data file for future use).
2. IDs in the solid-block ranges that the game data does not cover at all
   (Geometry Dash 2.2-only objects, IDs > 1911) keep GD's content-size rule:
   the hitbox is the object's frame content size measured in GD units (the
   atlas stores -hd pixels at 2 px per GD unit).
3. Everything else is decoration and carries no gameplay collision.

The pre-2026-09 hand-tuned spec table (geometry lifted from the old Godot Dash
level-component scenes) was a starting reference only and has been replaced by
the game-extracted data; where the two disagreed the game data wins (e.g. the
block hitbox is exactly 30x30 GD units = 128x128 scene px, not the old
130x130; the spike hitbox is GD's thin 6x12-unit box centred in the spike, not
the old inset base box).

Geometry here is authored in scene pixels (y down, centred node origins).
Units: 1 GD cell = 30 GD units = ``Constants.CELL_SIZE`` (128) scene px, and
the atlas is -hd (2 px per GD unit), so scene px per hd px = 128/30/2.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"
DEFAULT_ATLAS_JSON = ATLAS_DIR / "gd_objects_atlas.json"
DEFAULT_FRAMES_JSON = ATLAS_DIR / "object_frames.json"
HITBOX_DATA_JSON = Path(__file__).resolve().parent / "gd_hitbox_data.json"

# Must match Constants / GMDConverter / build_gd_object_scenes.py.
CELL_SIZE = 128.0
GD_CELL_SIZE = 30.0
HD_PX_PER_GD_UNIT = 2.0
ART_SCALE = CELL_SIZE / GD_CELL_SIZE / HD_PX_PER_GD_UNIT  # scene px per hd px
GD_TO_WORLD = CELL_SIZE / GD_CELL_SIZE                    # scene px per GD unit


# --- shape model --------------------------------------------------------------


@dataclass
class Rect:
    """Axis-aligned rectangle in scene px, centred on ``pos``."""
    size: tuple[float, float]
    pos: tuple[float, float] = (0.0, 0.0)
    rotation: float = 0.0  # degrees, clockwise on screen (Godot convention)


@dataclass
class Circle:
    radius: float
    pos: tuple[float, float] = (0.0, 0.0)


@dataclass
class Polygon:
    """Convex polygon points in scene px, relative to ``pos``."""
    points: list[tuple[float, float]]
    pos: tuple[float, float] = (0.0, 0.0)


Shape = Rect | Circle | Polygon


class BodyKind:
    SOLID = "solid"                # StaticBody2D, layer 2
    SLOPE = "slope"                # StaticBody2D, layers 2 + 7 (slope enabler)
    RECT_HAZARD = "rect_hazard"    # Area2D, layer 3 (rectangular hazards)
    CIRCLE_HAZARD = "circle_hazard"  # Area2D, layer 12 (circular hazards)

    LAYERS = {
        SOLID: 2,
        SLOPE: 66,  # 2 | 1 << 6 (slope_enablers)
        RECT_HAZARD: 4,
        CIRCLE_HAZARD: 2048,
    }


@dataclass
class CollisionSpec:
    kind: str
    shapes: list[Shape]
    note: str = ""  # provenance; where the geometry came from


# --- solid-block ranges (mirror of GMDObjects.BLOCK_ID_RANGES) -----------------
#
# Ranges are now only the LEGACY fallback: they apply to IDs the game-extracted
# data does not classify at all (GD 2.2-only objects, IDs > 1911). IDs inside
# these ranges that the game data does classify follow the game data, even when
# that removes collision (decoration false positives from the old importer -
# see DEMOTED notes in report()) or turns them into hazards/slopes.

BLOCK_ID_RANGES: list[tuple[int, int]] = [
    (1, 7), (40, 40), (83, 83), (90, 91), (96, 96), (116, 122), (146, 147),
    (160, 165), (170, 174), (192, 194), (245, 245), (259, 261), (263, 266),
    (273, 275), (277, 282), (294, 296), (317, 317), (321, 321), (325, 329),
    (331, 331), (333, 333), (337, 337), (343, 343), (345, 345), (349, 349),
    (351, 351), (369, 370), (373, 374), (467, 470), (474, 481), (492, 493),
    (586, 593), (639, 640), (662, 664), (688, 692), (719, 721), (766, 766),
    (768, 769), (1202, 1205), (1220, 1222),
]


def in_block_ranges(gd_id: int) -> bool:
    return any(a <= gd_id <= b for a, b in BLOCK_ID_RANGES)


# --- game-extracted hitbox data (rule 1) ---------------------------------------

# Invisible solid blocks: the game classification calls them decoration, but
# their texture is emptyFrame and the game hitbox table carries a full rect -
# these are GD's invisible blocks (solid).
INVISIBLE_BLOCK_IDS = {1886, 1887, 1888}

# Object types in the game data that are static collision. Everything else
# (portals, pads, rings, collectibles, decoration, ...) is not: interactables
# keep their hand-made scenes, decoration carries none.
SOLID_TYPES = {0, 21}  # block / breakable brick
HAZARD_TYPE = 2
SLOPE_TYPE = 25

# The solid half of a slope's rect bounds (GD units, y up), per orientation
# derived from the game artwork. floor_r rises to the right ("/"), floor_l to
# the left ("\"), ceil_* are the ceiling-attached mirrors.
_SLOPE_TRIANGLES = {
    "floor_r": lambda x0, y0, x1, y1: [(x0, y0), (x1, y0), (x1, y1)],
    "floor_l": lambda x0, y0, x1, y1: [(x0, y1), (x0, y0), (x1, y0)],
    "ceil_r": lambda x0, y0, x1, y1: [(x0, y1), (x1, y1), (x1, y0)],
    "ceil_l": lambda x0, y0, x1, y1: [(x0, y1), (x1, y1), (x0, y0)],
}


def _gd_rect_shape(rect: list[float]) -> Rect:
    """GD hitbox rect ``[h, w, x, y]`` (y up, origin at object centre) -> scene px."""
    h, w, x, y = rect
    return Rect(
        size=(w * GD_TO_WORLD, h * GD_TO_WORLD),
        pos=((x + w / 2.0) * GD_TO_WORLD, -(y + h / 2.0) * GD_TO_WORLD),
    )


def _slope_polygon(rect: list[float], orientation: str) -> Polygon:
    """The slope's solid triangle: half its GD rect bounds, oriented per art."""
    h, w, x, y = rect
    x0, x1, y0, y1 = x, x + w, y, y + h
    corners = _SLOPE_TRIANGLES[orientation](x0, y0, x1, y1)
    return Polygon([(gx * GD_TO_WORLD, -gy * GD_TO_WORLD) for gx, gy in corners])


_hitbox_cache: dict | None = None


def _hitbox_data() -> dict:
    global _hitbox_cache
    if _hitbox_cache is None:
        _hitbox_cache = json.loads(HITBOX_DATA_JSON.read_text(encoding="utf-8"))
    return _hitbox_cache


_specs_cache: dict[int, CollisionSpec] | None = None
_classified_ids_cache: set[int] | None = None


def _build_specs() -> tuple[dict[int, CollisionSpec], set[int]]:
    """Per-id specs from the game-extracted table + the set of classified ids."""
    specs: dict[int, CollisionSpec] = {}
    classified: set[int] = set()
    for key, entry in _hitbox_data().get("objects", {}).items():
        gd_id = int(key)
        obj_type = entry.get("type")
        rect = entry.get("rect")
        radius = entry.get("radius")
        if gd_id in INVISIBLE_BLOCK_IDS:
            specs[gd_id] = CollisionSpec(
                BodyKind.SOLID,
                [_gd_rect_shape(rect)],
                note="GD hitbox table: invisible block (emptyFrame), "
                     f"{rect[1]:g}x{rect[0]:g} GD units",
            )
        elif obj_type in SOLID_TYPES and rect:
            specs[gd_id] = CollisionSpec(
                BodyKind.SOLID,
                [_gd_rect_shape(rect)],
                note=f"GD hitbox table: {rect[1]:g}x{rect[0]:g} GD units",
            )
        elif obj_type == HAZARD_TYPE and (rect or radius):
            if radius:
                specs[gd_id] = CollisionSpec(
                    BodyKind.CIRCLE_HAZARD,
                    [Circle(radius * GD_TO_WORLD)],
                    note=f"GD hitbox table: radius {radius:g} GD units",
                )
            else:
                specs[gd_id] = CollisionSpec(
                    BodyKind.RECT_HAZARD,
                    [_gd_rect_shape(rect)],
                    note=f"GD hitbox table: {rect[1]:g}x{rect[0]:g} GD units",
                )
        elif obj_type == SLOPE_TYPE and rect:
            orientation = entry.get("slope")
            if orientation not in _SLOPE_TRIANGLES:
                continue  # unclassifiable slope (no artwork): stays decoration
            note = "GD hitbox bounds + artwork orientation"
            if entry.get("note"):
                note += f" ({entry['note']})"
            if entry.get("iou") is not None:
                note += f", IoU {entry['iou']:.2f}"
            specs[gd_id] = CollisionSpec(BodyKind.SLOPE, [_slope_polygon(rect, orientation)], note=note)
        classified.add(gd_id)
    return specs, classified


def _specs() -> dict[int, CollisionSpec]:
    global _specs_cache, _classified_ids_cache
    if _specs_cache is None:
        _specs_cache, _classified_ids_cache = _build_specs()
    return _specs_cache


def _classified_ids() -> set[int]:
    global _specs_cache, _classified_ids_cache
    if _classified_ids_cache is None:
        _specs_cache, _classified_ids_cache = _build_specs()
    return _classified_ids_cache


def spec_for(gd_id: int) -> CollisionSpec | None:
    """Game-extracted spec first, then the legacy solid-block content-size rule.

    IDs classified by the game data never fall through to the legacy rule: the
    game says decoration/interactable -> no static collision, even when the id
    sits in a solid-block range.
    """
    spec = _specs().get(gd_id)
    if spec is not None:
        return spec
    if gd_id in _classified_ids():
        return None
    if in_block_ranges(gd_id) and gd_id not in _EXPLICITLY_NON_SOLID:
        content = _content_rect(gd_id)
        if content is not None:
            return CollisionSpec(
                BodyKind.SOLID,
                content,
                note="content-size rule (legacy; id not in the game data): "
                     "atlas frame source size in GD units",
            )
    return None


# Manual carve-outs from the legacy content-size rule (IDs the game data does
# not cover but that are known not to be solid). Empty until a GD
# hitbox-viewer check finds a non-solid frame inside a range.
_EXPLICITLY_NON_SOLID: set[int] = set()


# --- atlas frame tables (legacy content-size rule) -----------------------------

_frames_cache: dict | None = None
_atlas_cache: dict | None = None


def _load_tables():
    global _frames_cache, _atlas_cache
    if _frames_cache is None:
        _frames_cache = json.loads(DEFAULT_FRAMES_JSON.read_text(encoding="utf-8"))
        _frames_cache = _frames_cache.get("frames", _frames_cache)
    if _atlas_cache is None:
        _atlas_cache = json.loads(DEFAULT_ATLAS_JSON.read_text(encoding="utf-8"))
        _atlas_cache = _atlas_cache.get("frames", _atlas_cache)


def base_frame_name(gd_id: int) -> str | None:
    _load_tables()
    entry = _frames_cache.get(str(gd_id))
    if not isinstance(entry, dict):
        return None
    return entry.get("base")


def _content_rect(gd_id: int) -> list[Rect] | None:
    """GD content-size hitbox: the frame's source size in GD units -> scene px.

    ``None`` when the object has no single base frame (no artwork, or a
    parts-only tree whose base is missing), so those ids stay decoration.
    """
    _load_tables()
    entry = _frames_cache.get(str(gd_id))
    if not isinstance(entry, dict):
        return None
    base = entry.get("base")
    if not base:
        return None
    frame = _atlas_cache.get(base)
    if not frame:
        return None
    # frame = [page, x, y, w, h, offset_x, offset_y, source_w, source_h, sheet]
    source_w, source_h = float(frame[7]), float(frame[8])
    if source_w <= 0.0 or source_h <= 0.0:
        return None
    # An empty/invisible frame means an invisible block: it still collides as a
    # full cell in GD.
    if base == "emptyFrame.png":
        return [Rect((CELL_SIZE, CELL_SIZE))]
    return [Rect((source_w * ART_SCALE, source_h * ART_SCALE))]


# --- reports -------------------------------------------------------------------


def report() -> str:
    """Human-readable provenance report for the whole spec set."""
    specs = _specs()
    classified = _classified_ids()
    lines: list[str] = []

    kinds: dict[str, list[int]] = {}
    for gid, spec in specs.items():
        kinds.setdefault(spec.kind, []).append(gid)
    lines.append("== game-extracted specs (tools/gd_hitbox_data.json)")
    for kind in (BodyKind.SOLID, BodyKind.SLOPE, BodyKind.RECT_HAZARD, BodyKind.CIRCLE_HAZARD):
        ids = sorted(kinds.get(kind, []))
        lines.append(f"  {kind} ({len(ids)}): {ids}")

    legacy = [
        g for g in sorted(_legacy_content_ids())
        if g not in classified
    ]
    lines.append("")
    lines.append(f"== legacy content-size solids ({len(legacy)}; ids the game data does not cover)")
    lines.append(f"  {legacy}")

    demoted = sorted(
        g for g in _block_range_ids()
        if g in classified and g not in specs
    )
    lines.append("")
    lines.append(
        f"== demoted: in the old solid-block ranges but decoration per the game ({len(demoted)})"
    )
    textures = _hitbox_data().get("objects", {})
    lines.append("  " + ", ".join(f"{g}({textures.get(str(g), {}).get('texture', '?')})" for g in demoted))
    reclassified = sorted(
        g for g in _block_range_ids()
        if g in specs and specs[g].kind in (BodyKind.SLOPE, BodyKind.RECT_HAZARD, BodyKind.CIRCLE_HAZARD)
    )
    lines.append("")
    lines.append(
        f"== reclassified within the ranges (slope/hazard instead of solid): {reclassified}"
    )
    lines.append("")
    lines.append("== per-id geometry (game-extracted)")
    for gid in sorted(specs):
        spec = specs[gid]
        shapes = ", ".join(f"{type(s).__name__.lower()}:{_shape_text(s)}" for s in spec.shapes)
        lines.append(f"{gid:4d}  {spec.kind:14s} {shapes:44s} # {spec.note}")
    return "\n".join(lines)


def _block_range_ids() -> set[int]:
    out: set[int] = set()
    for a, b in BLOCK_ID_RANGES:
        out.update(range(a, b + 1))
    return out


def _legacy_content_ids() -> set[int]:
    _load_tables()
    out: set[int] = set()
    for gid in _block_range_ids():
        entry = _frames_cache.get(str(gid))
        if isinstance(entry, dict) and entry.get("base"):
            out.add(gid)
    return out


def _shape_text(shape: Shape) -> str:
    if isinstance(shape, Rect):
        return f"{shape.size[0]:g}x{shape.size[1]:g}@({shape.pos[0]:g},{shape.pos[1]:g})"
    if isinstance(shape, Circle):
        return f"r{shape.radius:g}"
    return f"{len(shape.points)}pts"


if __name__ == "__main__":
    print(report())
