"""Single source of truth for gameplay collision on Geometry Dash object scenes.

The generated ``scenes/gd_objects/gd_<id>.tscn`` scenes are pure artwork + a
``Collision`` body. This module decides which IDs are gameplay objects (solid,
slope, rectangular hazard, circular hazard) and what their PRISTINE hitbox is,
in scene pixels relative to the object's node origin (the node origin is the
same anchor the level importer places objects on, so shapes written here land
exactly where the artwork is placed in a level).

Value policy, per the unification plan (GD_UNIFICATION_PLAN.md):

1. IDs that had an old Godot Dash level-component scene reuse that scene's
   hitbox geometry verbatim - the user sanctioned reusing them where they
   exist, and they were hand-tuned against the real game.
2. IDs in the solid-block ranges with no old equivalent get GD's own
   content-size rule: the hitbox is the object's frame content size measured in
   GD units (the atlas stores -hd pixels at 2 px per GD unit).
3. Everything else is decoration and carries no gameplay collision.

Geometry here is authored in scene pixels (y down, centred node origins).
Units: 1 GD cell = 30 GD units = ``Constants.CELL_SIZE`` (128) scene px, and
the atlas is -hd (2 px per GD unit), so scene px per hd px = 128/30/2.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"
DEFAULT_ATLAS_JSON = ATLAS_DIR / "gd_objects_atlas.json"
DEFAULT_FRAMES_JSON = ATLAS_DIR / "object_frames.json"

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
# IDs in these ranges that are not explicitly listed in SPECS below are solid
# blocks whose hitbox follows GD's content-size rule (rule 2 above).

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


# --- explicit specs (rule 1: old-scene geometry) ------------------------------
#
# Geometry below was lifted verbatim from the old Godot Dash level-component
# scenes the same GD IDs used to import into (see GMDObjects.MAP): the scene's
# collision root layer plus every Hitbox CollisionShape2D's shape and transform,
# expressed in scene px around the node origin. Provenance per entry.

def _r(size: tuple[float, float], pos: tuple[float, float] = (0.0, 0.0)) -> Rect:
    return Rect(size, pos)


def _c(radius: float) -> Circle:
    return Circle(radius)


SPECS: dict[int, CollisionSpec] = {
    # --- solids (old NinePatchBlock.tscn root: RigidBody2D frozen, layer 2) ---
    **{gid: CollisionSpec(BodyKind.SOLID, [_r((130.0, 130.0))],
                          note="old NinePatchBlock.tscn / PixelBlock.tscn hitbox 130x130")
       for gid in [1, 2, 3, 4, 5, 6, 7, 467, 468, 469, 470]},
    # --- slopes (old DefaultSlopeNormal/Large.tscn: layer 66, ConvexPolygon) --
    289: CollisionSpec(BodyKind.SLOPE,
                       [Polygon([(-66.414, 65.0), (65.0, -66.414), (65.0, 65.0)])],
                       note="old DefaultSlopeNormal.tscn polygon"),
    290: CollisionSpec(BodyKind.SLOPE,
                       [Polygon([(-66.414, 65.0), (65.0, -66.414), (65.0, 65.0)])],
                       note="old DefaultSlopeNormal.tscn polygon (scene 290 artwork absent; kept for mapping)"),
    291: CollisionSpec(BodyKind.SLOPE,
                       [Polygon([(-136.472, 66.0), (130.0, -67.236), (130.0, 66.0)])],
                       note="old DefaultSlopeLarge.tscn polygon"),
    292: CollisionSpec(BodyKind.SLOPE,
                       [Polygon([(-136.472, 66.0), (130.0, -67.236), (130.0, 66.0)])],
                       note="old DefaultSlopeLarge.tscn polygon (scene 292 artwork absent; kept for mapping)"),
    # --- rectangular hazards (spikes; old scenes: Area2D layer 4) -------------
    # GD keeps spike lethality below the visual tip: the old author measured
    # these inset boxes against Geometry Dash; reuse them.
    8: CollisionSpec(BodyKind.RECT_HAZARD, [_r((20.0, 31.0), (0.0, 27.5))],
                     note="old Spike.tscn hitbox"),
    39: CollisionSpec(BodyKind.RECT_HAZARD, [_r((20.0, 15.5), (0.0, 37.5))],
                      note="old SpikeFlat.tscn hitbox (20x31 scaled y0.5)"),
    103: CollisionSpec(BodyKind.RECT_HAZARD, [_r((13.333333, 20.666667), (0.0, 34.5))],
                       note="old SpikeMedium.tscn hitbox"),
    392: CollisionSpec(BodyKind.RECT_HAZARD, [_r((12.0, 18.0), (0.0, 43.5))],
                       note="old SpikeSmall.tscn hitbox"),
    216: CollisionSpec(BodyKind.RECT_HAZARD, [_r((120.0, 20.0), (0.0, 50.0))],
                       note="old GroundSpike.tscn hitbox (chain of ground spikes)"),
    217: CollisionSpec(BodyKind.RECT_HAZARD, [_r((120.0, 20.0), (0.0, 50.0))],
                       note="old GroundSpike.tscn hitbox"),
    # --- circular hazards (saws; old scenes: Area2D layer 2048) ---------------
    88: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(140.35669)],
                      note="old Sawblade.tscn radius"),
    89: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(96.10411)],
                      note="old SawbladeMedium.tscn radius"),
    98: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(64.0)],
                      note="old SawbladeSmall.tscn radius"),
    397: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(140.35669)],
                       note="old Sawblade.tscn radius (coloured variant)"),
    398: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(96.10411)],
                       note="old SawbladeMedium.tscn radius (coloured variant)"),
    399: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(64.0)],
                       note="old SawbladeSmall.tscn radius (coloured variant)"),
    675: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(140.35669)],
                       note="old Sawblade.tscn radius (variant)"),
    676: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(96.10411)],
                       note="old SawbladeMedium.tscn radius (variant)"),
    677: CollisionSpec(BodyKind.CIRCLE_HAZARD, [_c(64.0)],
                       note="old SawbladeSmall.tscn radius (variant)"),
}


def spec_for(gd_id: int) -> CollisionSpec | None:
    """Explicit spec first, then the solid-block content-size rule."""
    if gd_id in SPECS:
        return SPECS[gd_id]
    if in_block_ranges(gd_id) and gd_id not in _EXPLICITLY_NON_SOLID:
        content = _content_rect(gd_id)
        if content is not None:
            return CollisionSpec(
                BodyKind.SOLID,
                content,
                note="content-size rule: atlas frame source size in GD units",
            )
    return None


# IDs in the block ranges that must NOT become solids. Block ranges were already
# vetted one id at a time by GMDObjects; keep an explicit carve-out list empty
# until a GD hitbox-viewer check finds a non-solid frame inside a range.
_EXPLICITLY_NON_SOLID: set[int] = set()


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
        return [_r((CELL_SIZE, CELL_SIZE))]
    return [_r((source_w * ART_SCALE, source_h * ART_SCALE))]


def report() -> str:
    """Human-readable provenance report for the whole spec set."""
    _load_tables()
    lines: list[str] = []
    for gid in sorted(SPECS):
        spec = SPECS[gid]
        kind_layer = f"{spec.kind} (layer {BodyKind.LAYERS[spec.kind]})"
        shapes = ", ".join(
            f"{type(s).__name__.lower()}:{_shape_text(s)}" for s in spec.shapes
        )
        lines.append(f"{gid:4d}  {kind_layer:34s} {shapes:40s} # {spec.note}")
    auto = [g for g in sorted(_automatic_ids()) if g not in SPECS]
    lines.append("")
    lines.append(f"auto content-size solids ({len(auto)}): {auto}")
    return "\n".join(lines)


def _automatic_ids() -> set[int]:
    _load_tables()
    out: set[int] = set()
    for a, b in BLOCK_ID_RANGES:
        for gid in range(a, b + 1):
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
