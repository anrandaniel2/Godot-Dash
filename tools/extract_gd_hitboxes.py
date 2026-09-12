#!/usr/bin/env python3
"""Build ``tools/gd_hitbox_data.json``: the pristine per-object-ID hitbox mapping.

Data sources
------------
Geometry Dash's own hitbox data, as preserved by the OpenGD project
(https://github.com/Open-GD/OpenGD, GPL-3.0). Two blobs are fetched from the
GitHub API (or read from local files via --longdata / --objects):

* ``Source/LongData.cpp`` - ``GameObject::_pHitboxes`` (435 axis-aligned rect
  hitboxes, one per object ID) and ``GameObject::_pHitboxRadius`` (38 circular
  hitbox radii). Struct order is ``{h, w, x, y}``: the rect spans
  ``(x, y)`` to ``(x + w, y + h)`` in **GD units** (30 per grid cell), in the
  object's local space, **y up**, origin at the object's centre - exactly the
  anchor the level importer places objects on.
* ``Content/Custom/object.json`` - the game's per-object classification
  (``object_type``) and base texture for 1541 IDs. Types that matter here:
  0 = solid block, 2 = hazard, 25 = slope, 7 = decoration; everything else is
  an interactable (pads / rings / portals / collectibles) whose rect is a
  trigger zone, not static collision.

Slope orientation
-----------------
The GD tables give slopes only their outer bounds. The solid half (the actual
triangle) is derived here from the game artwork in ``assets/textures/gd_atlas``:
each slope's sprites are rasterised exactly the way
``tools/build_gd_object_scenes.py`` emits them (position/rotation/scale/offset
semantics of a Godot Sprite2D), and the opaque coverage inside the table's
rect is matched against the four candidate triangles (floor/ceiling x
rising-left/rising-right) by IoU. Requires Pillow + numpy (only for running
this extractor; the committed JSON needs nothing).

Output
------
``tools/gd_hitbox_data.json`` - one entry per object ID with type, texture,
rect/radius, and (for slopes) orientation + classification confidence.
``tools/gd_collision_specs.py`` consumes it; regenerate scenes with
``tools/build_gd_object_scenes.py`` after changing it.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"
OUT_PATH = Path(__file__).resolve().parent / "gd_hitbox_data.json"

OPEND_REPO = "Open-GD/OpenGD"
OPEND_BRANCH = "main"
LONGDATA_BLOB = "c91916e7265aa043399d6dd83da7708f226c08b7"  # Source/LongData.cpp
OBJECTS_BLOB = "340b0ac4d93c73b3fa09d517440080bb93f7f404"  # Content/Custom/object.json
OPEND_TREE = "2a0e30793d86247ad5839a26a8f0ee586f9e84dd"  # main tree these blobs live in

# Geometry conventions shared with build_gd_object_scenes.py / gd_collision_specs.py.
CELL_SIZE = 128.0
GD_CELL_SIZE = 30.0
HD_PX_PER_GD_UNIT = 2.0
ART_SCALE = CELL_SIZE / GD_CELL_SIZE / HD_PX_PER_GD_UNIT  # scene px per hd px
GD_TO_WORLD = CELL_SIZE / GD_CELL_SIZE                    # scene px per GD unit

# Solid block, hazard, slope, solid-breakable (brick), decoration.
STATIC_TYPES = {0, 2, 25, 21}
SLOPE_TYPE = 25

# Invisible solid blocks: type says decoration but the texture is emptyFrame and
# the game hitbox table carries a full rect - these are GD's invisible blocks.
INVISIBLE_BLOCK_IDS = {1886, 1887, 1888}

# Mirrored slope IDs that appear in no GD table and in no artwork atlas; their
# geometry is the mirror of their sibling (289/291 are the rising-right pair).
DERIVED_SLOPE_MIRRORS = {290: 289, 292: 291}

# Stroke-only artwork (invisible-slope editor outlines): the hypotenuse alone
# cannot decide which side is solid, so the orientation is taken from the
# unambiguous sibling family (same pair structure, decisive artwork).
SLOPE_HOMOLOGY = {1344: 1341, 1345: 1342}


def fetch_blob(blob_sha: str, cache_name: str) -> bytes:
    cache = Path("/tmp") / cache_name
    if cache.exists():
        return cache.read_bytes()
    url = f"https://api.github.com/repos/{OPEND_REPO}/git/blobs/{blob_sha}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github.raw"})
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 - fixed https URL
        data = resp.read()
    cache.write_bytes(data)
    return data


def parse_longdata(src: str) -> tuple[dict[int, list[float]], dict[int, float]]:
    """Extract _pHitboxes {id: [h, w, x, y]} and _pHitboxRadius {id: r}."""
    rect_m = re.search(r"_pHitboxes\s*=\s*std::unordered_map[^{]*\{(.*?)\n\s*\};", src, re.S)
    radius_m = re.search(r"_pHitboxRadius\s*=\s*[^{]*\{(.*?)\};", src, re.S)
    if not rect_m or not radius_m:
        sys.exit("could not locate hitbox tables in LongData.cpp")
    rects = {
        int(i): [float(h), float(w), float(x), float(y)]
        for i, h, w, x, y in re.findall(
            r"\{\s*(\d+)\s*,\s*\{\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\}\s*\}",
            rect_m.group(1),
        )
    }
    radii = {
        int(i): float(r)
        for i, r in re.findall(r"\{(\d+),\s*([\d.]+)\}", radius_m.group(1))
    }
    return rects, radii


# --- artwork rasterisation (mirrors the builder's Sprite2D emission) ----------

N = 1024  # classification canvas, origin at the centre


def _load_atlas() -> tuple[dict, dict, "Image.Image"]:  # type: ignore[name-defined]
    import numpy as np  # noqa: F401
    from PIL import Image

    atlas = json.loads((ATLAS_DIR / "gd_objects_atlas.json").read_text(encoding="utf-8"))
    atlas = atlas.get("frames", atlas)
    frames = json.loads((ATLAS_DIR / "object_frames.json").read_text(encoding="utf-8"))
    frames = frames.get("frames", frames)
    sheet = Image.open(ATLAS_DIR / "gd_objects_atlas_0.png").convert("RGBA")
    return atlas, frames, sheet


def composite_alpha(gd_id: int, atlas: dict, frames: dict, sheet) -> "object":  # type: ignore[valid-type]
    """Opaque-pixel mask of the object's composite artwork, scene-px scale.

    ``None`` when the id has no artwork. Rendering matches the emitted scene:
    every sprite is scaled (incl. ART_SCALE), mirrored on negative scale,
    rotated by the Godot rotation, and its texture centre lands on
    ``position + R * S * offset``.
    """
    from PIL import Image

    entry = frames.get(str(gd_id))
    if not entry or not entry.get("base"):
        return None

    sprites: list[dict] = [
        {"frame": entry["base"], "x": 0.0, "y": 0.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "ax": 0.0, "ay": 0.0}
    ]
    for part in sorted(
        (p for p in entry.get("parts", []) if isinstance(p, dict) and p.get("frame")),
        key=lambda p: int(p.get("order", 0)),
    ):
        sprites.append(
            {
                "frame": str(part["frame"]),
                "x": float(part.get("x", 0.0)),
                "y": float(part.get("y", 0.0)),
                "rot": float(part.get("rot", 0.0)),
                "sx": float(part.get("sx", 1.0)),
                "sy": float(part.get("sy", 1.0)),
                "ax": float(part.get("ax", 0.0)),
                "ay": float(part.get("ay", 0.0)),
            }
        )
    sprites = [s for s in sprites if s["frame"] != "emptyFrame.png"]

    canvas = Image.new("L", (N, N), 0)
    for s in sprites:
        f = atlas.get(s["frame"])
        if not f:
            continue
        _page, x, y, w, h, ox, oy, _sw, _sh, _sheet = f
        tex = sheet.crop((x, y, x + w, y + h))

        rot_gd = -math.radians(s["rot"])  # Godot rotation (y down, CW positive)
        px = s["x"] * GD_TO_WORLD
        py = -s["y"] * GD_TO_WORLD
        sx = s["sx"] * ART_SCALE
        sy = s["sy"] * ART_SCALE
        if s["ax"] or s["ay"]:
            shift_x = -s["ax"] * w * ART_SCALE
            shift_y = s["ay"] * h * ART_SCALE
            cos_r, sin_r = math.cos(rot_gd), math.sin(rot_gd)
            bx = (cos_r * sx / ART_SCALE, sin_r * sx / ART_SCALE)
            by = (-sin_r * sy / ART_SCALE, cos_r * sy / ART_SCALE)
            px += bx[0] * shift_x + by[0] * shift_y
            py += bx[1] * shift_x + by[1] * shift_y

        img = tex.resize((max(1, round(abs(sx) * w)), max(1, round(abs(sy) * h))))
        if s["sx"] < 0:
            img = img.transpose(Image.FLIP_LEFT_RIGHT)
        if s["sy"] < 0:
            img = img.transpose(Image.FLIP_TOP_BOTTOM)
        deg = math.degrees(rot_gd)
        if abs(deg) > 1e-6:
            img = img.rotate(-deg, expand=True)

        vx, vy = sx * ox, sy * oy  # sx/sy already include ART_SCALE: matches pos + R*S*offset
        cos_r, sin_r = math.cos(rot_gd), math.sin(rot_gd)
        cx = px + vx * cos_r - vy * sin_r
        cy = py + vx * sin_r + vy * cos_r
        alpha = img.split()[3]
        canvas.paste(
            alpha,
            (round(N / 2 + cx - img.width / 2), round(N / 2 + cy - img.height / 2)),
            alpha,
        )
    import numpy as np

    return np.asarray(canvas) > 16


def classify_slope(alpha, rect: list[float]) -> tuple[str, float, dict[str, float]]:
    """Best-matching solid half of the slope's rect bounds, by IoU."""
    import numpy as np
    from PIL import Image, ImageDraw

    h, w, x, y = rect
    x0 = round(N / 2 + x * GD_TO_WORLD)
    x1 = round(N / 2 + (x + w) * GD_TO_WORLD)
    y0 = round(N / 2 - (y + h) * GD_TO_WORLD)
    y1 = round(N / 2 - y * GD_TO_WORLD)
    box = alpha[y0:y1, x0:x1]
    bh, bw = box.shape
    candidates = {
        "floor_r": [(0, bh - 1), (bw - 1, bh - 1), (bw - 1, 0)],  # BL BR TR, rises right
        "floor_l": [(0, 0), (0, bh - 1), (bw - 1, bh - 1)],       # TL BL BR, rises left
        "ceil_r":  [(0, 0), (bw - 1, 0), (bw - 1, bh - 1)],       # TL TR BR
        "ceil_l":  [(0, 0), (bw - 1, 0), (0, bh - 1)],            # TL TR BL
    }
    scores: dict[str, float] = {}
    for name, pts in candidates.items():
        img = Image.new("L", (bw, bh), 0)
        ImageDraw.Draw(img).polygon(pts, fill=255)
        mask = np.asarray(img) > 127
        union = int((box | mask).sum())
        scores[name] = (int((box & mask).sum()) / union) if union else 0.0
    best = max(scores, key=scores.get)  # type: ignore[arg-type]
    ordered = sorted(scores.values(), reverse=True)
    return best, scores[best], scores


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--longdata", type=Path, help="local copy of OpenGD Source/LongData.cpp")
    ap.add_argument("--objects", type=Path, help="local copy of OpenGD Content/Custom/object.json")
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    args = ap.parse_args()

    longdata_src = (
        args.longdata.read_text(encoding="utf-8")
        if args.longdata
        else fetch_blob(LONGDATA_BLOB, "opengd_longdata.cpp").decode("utf-8")
    )
    objects = json.loads(
        args.objects.read_text(encoding="utf-8")
        if args.objects
        else fetch_blob(OBJECTS_BLOB, "opengd_object.json").decode("utf-8")
    )
    rects, radii = parse_longdata(longdata_src)
    print(f"parsed {len(rects)} rect hitboxes, {len(radii)} circle radii, "
          f"{len(objects)} object classifications")

    # --- slope orientation from the artwork ---------------------------------
    atlas, frames, sheet = _load_atlas()
    slope_ids = sorted(int(k) for k, v in objects.items() if v.get("object_type") == SLOPE_TYPE)
    orientations: dict[int, dict] = {}
    low_confidence: list[int] = []
    for gd_id in slope_ids:
        if gd_id in SLOPE_HOMOLOGY:
            continue  # handled below via the sibling family
        alpha = composite_alpha(gd_id, atlas, frames, sheet)
        if alpha is None:
            orientations[gd_id] = {"slope": None, "note": "no artwork in atlas"}
            low_confidence.append(gd_id)
            continue
        best, score, scores = classify_slope(alpha, rects[gd_id])
        runner_up = sorted(scores.values(), reverse=True)[1]
        confident = score >= 0.55 or score >= 1.4 * runner_up
        orientations[gd_id] = {"slope": best, "iou": round(score, 3)}
        if not confident:
            low_confidence.append(gd_id)
    for gd_id, sibling in SLOPE_HOMOLOGY.items():
        sib = orientations.get(sibling, {})
        orientations[gd_id] = {
            "slope": sib.get("slope"),
            "note": f"stroke-only artwork; orientation by homology with {sibling}",
        }
    print(f"classified {len(slope_ids)} slopes "
          f"({len(low_confidence)} needed manual rules: {low_confidence})")

    # --- assemble the data file ---------------------------------------------
    out_objects: dict[str, dict] = {}
    for key, entry in objects.items():
        gd_id = int(key)
        record: dict = {"type": entry.get("object_type")}
        if entry.get("texture_name"):
            record["texture"] = entry["texture_name"]
        if gd_id in rects:
            record["rect"] = rects[gd_id]
        if gd_id in radii:
            record["radius"] = radii[gd_id]
        if gd_id in orientations:
            record.update(orientations[gd_id])
        out_objects[key] = record

    # IDs that have a game hitbox but no classification entry (orbs, editor UI,
    # collectibles...): keep the rect as trigger-zone reference data.
    for gd_id, rect in rects.items():
        key = str(gd_id)
        if key not in out_objects:
            out_objects[key] = {"type": None, "rect": rect}
    for gd_id, r in radii.items():
        key = str(gd_id)
        out_objects.setdefault(key, {"type": None})
        out_objects[key]["radius"] = r

    # Mirrored slope siblings absent from every table.
    for gd_id, sibling in DERIVED_SLOPE_MIRRORS.items():
        sib_rect = rects[sibling]
        out_objects[str(gd_id)] = {
            "type": SLOPE_TYPE,
            "rect": sib_rect,
            "slope": "floor_l" if orientations.get(sibling, {}).get("slope") == "floor_r" else "floor_r",
            "note": f"mirror of {sibling}; id absent from the GD tables and the artwork atlas",
        }

    data = {
        "_source": {
            "project": f"https://github.com/{OPEND_REPO} (GPL-3.0)",
            "description": "Geometry Dash hitbox geometry + object classification, "
                           "extracted from the game by the OpenGD project",
            "retrieved": "2026-09-12",
            "branch": OPEND_BRANCH,
            "tree_sha": OPEND_TREE,
            "files": {
                "Source/LongData.cpp": {
                    "blob_sha": LONGDATA_BLOB,
                    "tables": ["GameObject::_pHitboxes", "GameObject::_pHitboxRadius"],
                },
                "Content/Custom/object.json": {"blob_sha": OBJECTS_BLOB},
            },
            "rect_semantics": "struct Hitbox {h, w, x, y}: rect from (x, y) to "
                              "(x+w, y+h) in GD units (30 per cell), object-local, "
                              "y up, origin at the object centre",
            "radius_semantics": "circular hitbox radius in GD units, centred on the object",
            "object_type_semantics": "0 solid, 2 hazard, 25 slope, 7 decoration, "
                                     "21 breakable brick; other values are interactables "
                                     "(pads/rings/portals/collectibles) whose rect is a "
                                     "trigger zone, not static collision",
            "slope_orientations": "derived in this repo from the game artwork atlas "
                                  "(alpha IoU over the rect bounds); floor_r/ceil_r are "
                                  "solid on the right, floor_*/ceil_* differ by which "
                                  "edge the triangle is attached to",
            "invisible_blocks": "IDs 1886/1887/1888: type says decoration but the "
                                "texture is emptyFrame and a full hitbox rect exists - "
                                "treated as solid",
        },
        "objects": {k: out_objects[k] for k in sorted(out_objects, key=int)},
    }
    args.out.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes, "
          f"{len(out_objects)} object entries)")

    # --- summary -------------------------------------------------------------
    by_kind = {"solid": [], "hazard": [], "slope": [], "trigger_rect": []}
    for key, record in out_objects.items():
        gd_id = int(key)
        t = record.get("type")
        if gd_id in INVISIBLE_BLOCK_IDS or t in (0, 21):
            by_kind["solid"].append(gd_id)
        elif t == 2:
            by_kind["hazard"].append(gd_id)
        elif t == 25:
            by_kind["slope"].append(gd_id)
        elif "rect" in record or "radius" in record:
            by_kind["trigger_rect"].append(gd_id)
    print(f"static collision ids: {len(by_kind['solid'])} solids, "
          f"{len(by_kind['hazard'])} hazards, {len(by_kind['slope'])} slopes; "
          f"{len(by_kind['trigger_rect'])} interactable/decoration ids carry "
          f"trigger-rect reference data")


if __name__ == "__main__":
    main()
