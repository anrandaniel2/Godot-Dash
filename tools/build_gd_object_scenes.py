#!/usr/bin/env python3
"""Generate one Godot scene per Geometry Dash object type.

Every object id in ``object_frames.json`` becomes ``scenes/gd_objects/gd_<id>.tscn``
with its full sprite tree already laid out from the packed atlas
(``tools/build_godot_atlas.py``). At runtime ``Level`` instances that scene once
per placement, so a level is made of ordinary nodes you can select, move,
recolour and - the point of this layout - give collision to.

Scene layout::

    GD<id>                      Node2D + src/GDObject.gd (gd_id, bounds)
    ├── [Detail]                Node2D, secondary-channel sprites, when GD draws them under the base
    ├── Base                    Node2D, main-channel sprites (always-black ones are tinted black)
    │   ├── [Glow]              Sprite2D, additive, hidden unless the placement asks for glow
    │   ├── Root                the object's own sprite
    │   └── Sprite<n>           extra parts of multi-sprite objects, in draw order
    ├── [Detail]                ... or here, when GD draws it on top
    ├── Collision               StaticBody2D on the solid layer - ADD YOUR SHAPES HERE
    │   └── Hitbox              empty CollisionShape2D placeholder (assign a shape)
    └── EditorSelectionCollider editor picking box sized to the artwork; freed in game

Re-running the tool rebuilds the artwork but **keeps the ``Collision`` subtree**
(and anything it references) from the existing scene, along with the scene's
UID, so hand-authored shapes survive an atlas update. ``--keep-existing``
leaves existing scenes completely untouched; ``--only 8,39`` limits the run.

Usage::

    python3 tools/build_gd_object_scenes.py
"""

from __future__ import annotations

import argparse
import json
import math
import random
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gd_collision_specs

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ATLAS_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"
DEFAULT_FRAMES_JSON = ATLAS_DIR / "object_frames.json"
DEFAULT_ATLAS_JSON = ATLAS_DIR / "gd_objects_atlas.json"
DEFAULT_OUT_DIR = PROJECT_ROOT / "scenes" / "gd_objects"

SCRIPT_PATH = "res://src/GDObject.gd"
SCRIPT_UID_FILE = PROJECT_ROOT / "src" / "GDObject.gd.uid"
SELECTOR_SCRIPT_PATH = "res://src/editor/EditorSelectionCollider.gd"
SELECTOR_SCRIPT_UID_FILE = PROJECT_ROOT / "src" / "editor" / "EditorSelectionCollider.gd.uid"
ADDITIVE_MATERIAL_PATH = "res://resources/AdditiveBlendingMaterial.tres"
ADDITIVE_MATERIAL_FILE = PROJECT_ROOT / "resources" / "AdditiveBlendingMaterial.tres"

# Must match GDDecorationLoader / GMDConverter: 128 px per cell, 30 GD units
# per cell, 2 atlas pixels per GD unit.
CELL_SIZE = 128.0
GD_CELL_SIZE = 30.0
HD_ART_UNITS_PER_GRID_UNIT = 2.0
ART_SCALE = CELL_SIZE / GD_CELL_SIZE / HD_ART_UNITS_PER_GRID_UNIT
GD_TO_WORLD = CELL_SIZE / GD_CELL_SIZE

EMPTY_FRAME = "emptyFrame.png"
# Legacy detail frames (objects without a known sprite tree) draw over the base.
LEGACY_DETAIL_ORDER = 1000
# EditorSelectionCollider.Type.DECORATION
SELECTOR_TYPE_DECORATION = 9
# Physics layer 2 is what the player treats as solid ground.
SOLID_LAYER = 2
MIN_SELECTION_SIZE = 24.0

COLLISION_DESCRIPTION = (
    "Collision for this Geometry Dash object type. tools/build_gd_object_scenes.py "
    "writes the hitbox for gameplay object types here automatically. Keep the node "
    "named Hitbox - gameplay and the level's shared physics builder look it up. To "
    "hand-edit a hitbox, edit the shapes below and DELETE the "
    "_editor_auto_collision_ metadata line on the Collision node: once the marker "
    "is gone a regeneration preserves your subtree instead of overwriting it."
)

# Marker + version stamped on auto-generated Collision subtrees. A subtree that
# carries the current marker is replaced wholesale on regeneration (so hitbox
# data improvements flow into scenes); a subtree without it is user content and
# is preserved verbatim, exactly like hand-authored collision before this
# feature existed.
COLLISION_AUTO_META = "_editor_auto_collision_"
COLLISION_AUTO_VERSION = "gd-hitboxes-2"

# Body kinds -> node type / collision layer, matching gd_collision_specs and the
# old level-component scenes' roots.
COLLISION_NODE_TYPE = {
    "solid": "StaticBody2D",
    "slope": "StaticBody2D",
    "rect_hazard": "Area2D",
    "circle_hazard": "Area2D",
}
COLLISION_NODE_LAYER = {
    "solid": 2,
    "slope": 66,
    "rect_hazard": 4,
    "circle_hazard": 2048,
}
COLLISION_DEBUG_COLOR = {
    "solid": (0, 0.07, 0.7, 0.25),
    "slope": (0, 0.07, 0.7, 0.25),
    "rect_hazard": (0.96, 0, 0, 0.25),
    "circle_hazard": (0.96, 0, 0, 0.25),
}


# --- Godot text helpers -------------------------------------------------------


def godot_uid_text(value: int) -> str:
    char_count = ord("z") - ord("a")
    base = char_count + (ord("9") - ord("0"))
    text = ""
    while value:
        digit = value % base
        text = (chr(ord("a") + digit) if digit < char_count else chr(ord("0") + digit - char_count)) + text
        value //= base
    return "uid://" + text


def new_uid() -> str:
    return godot_uid_text(random.getrandbits(63) | (1 << 62))


def num(value: float) -> str:
    if abs(value) < 1e-9:
        return "0"
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text if text not in ("", "-0") else "0"


def vec2(x: float, y: float) -> str:
    return f"Vector2({num(x)}, {num(y)})"


def rect2(x: float, y: float, w: float, h: float) -> str:
    return f"Rect2({num(x)}, {num(y)}, {num(w)}, {num(h)})"


def color(r: float, g: float, b: float, a: float) -> str:
    return f"Color({num(r)}, {num(g)}, {num(b)}, {num(a)})"


def gd_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def read_uid_file(path: Path) -> str:
    if not path.exists():
        sys.exit(f"missing {path.relative_to(PROJECT_ROOT)} - open the project in Godot once, or create it")
    return path.read_text(encoding="utf-8").strip()


def read_resource_uid(path: Path) -> str:
    match = re.search(r'uid="(uid://[^"]+)"', path.read_text(encoding="utf-8"))
    if not match:
        sys.exit(f"no uid in {path}")
    return match.group(1)


def read_import_uid(png: Path) -> str:
    import_file = png.with_name(png.name + ".import")
    if not import_file.exists():
        sys.exit(f"missing {import_file.name}; run tools/build_godot_atlas.py first")
    match = re.search(r'^uid="(uid://[^"]+)"', import_file.read_text(encoding="utf-8"), re.M)
    if not match:
        sys.exit(f"no uid in {import_file}")
    return match.group(1)


# --- atlas + object tables ----------------------------------------------------


@dataclass
class AtlasFrame:
    page: int
    x: int
    y: int
    w: int
    h: int
    offset_x: float
    offset_y: float


def load_atlas(path: Path) -> tuple[dict[str, AtlasFrame], list[str]]:
    if not path.exists():
        sys.exit(f"packed atlas table not found: {path} (run tools/build_godot_atlas.py)")
    data = json.loads(path.read_text(encoding="utf-8"))
    frames: dict[str, AtlasFrame] = {}
    for name, record in data["frames"].items():
        frames[name] = AtlasFrame(
            int(record[0]), int(record[1]), int(record[2]), int(record[3]), int(record[4]),
            float(record[5]), float(record[6]),
        )
    return frames, list(data["pages"])


def load_objects(path: Path) -> dict[int, dict]:
    if not path.exists():
        sys.exit(f"object frame table not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    table = data.get("frames", data)
    objects: dict[int, dict] = {}
    for key, value in table.items():
        if not str(key).isdigit():
            continue
        if isinstance(value, str):
            value = {"base": value}
        if isinstance(value, dict) and value.get("base"):
            objects[int(key)] = value
    return objects


# --- sprite layout ------------------------------------------------------------


@dataclass
class SpriteSpec:
    frame: str
    color_class: str  # base / detail / black
    order: int
    x: float = 0.0  # GD units, y up
    y: float = 0.0
    rot: float = 0.0  # degrees, anticlockwise
    sx: float = 1.0
    sy: float = 1.0
    ax: float = 0.0
    ay: float = 0.0
    opacity: float = 1.0
    is_root: bool = False

    def local_transform(self, atlas: AtlasFrame) -> tuple[float, float, float, float, float]:
        """(position_x, position_y, rotation, scale_x, scale_y) in Godot terms."""
        rotation = -math.radians(self.rot)
        px = self.x * GD_TO_WORLD
        py = -self.y * GD_TO_WORLD
        if self.ax or self.ay:
            # Anchor: a fraction of the frame's own size, in its own frame.
            shift_x = -self.ax * atlas.w * ART_SCALE
            shift_y = self.ay * atlas.h * ART_SCALE
            # basis = R(rotation) * S(sx, sy)
            cos_r, sin_r = math.cos(rotation), math.sin(rotation)
            bx = (cos_r * self.sx, sin_r * self.sx)
            by = (-sin_r * self.sy, cos_r * self.sy)
            px += bx[0] * shift_x + by[0] * shift_y
            py += bx[1] * shift_x + by[1] * shift_y
        return px, py, rotation, self.sx * ART_SCALE, self.sy * ART_SCALE


def sprites_of(entry: dict) -> list[SpriteSpec]:
    """The object's sprites in draw order, root included."""
    parts = sorted(
        (p for p in entry.get("parts", []) if isinstance(p, dict) and p.get("frame")),
        key=lambda p: int(p.get("order", 0)),
    )
    root_class = "black" if entry.get("color") == "black" else "base"
    root = SpriteSpec(entry["base"], root_class, 0, opacity=float(entry.get("opacity", 1.0)), is_root=True)
    result: list[SpriteSpec] = []
    root_placed = False
    for part in parts:
        order = int(part.get("order", 0))
        if order >= 0 and not root_placed:
            result.append(root)
            root_placed = True
        result.append(
            SpriteSpec(
                str(part["frame"]),
                str(part.get("color", "base")),
                order,
                float(part.get("x", 0.0)),
                float(part.get("y", 0.0)),
                float(part.get("rot", 0.0)),
                float(part.get("sx", 1.0)),
                float(part.get("sy", 1.0)),
                float(part.get("ax", 0.0)),
                float(part.get("ay", 0.0)),
                float(part.get("opacity", 1.0)),
            )
        )
    if not root_placed:
        result.append(root)
    if entry.get("detail") and not parts:
        result.append(SpriteSpec(str(entry["detail"]), "detail", LEGACY_DETAIL_ORDER))
    # The empty frame draws nothing.
    return [s for s in result if s.frame != EMPTY_FRAME]


def transformed_bounds(spec: SpriteSpec, atlas: AtlasFrame) -> tuple[float, float, float, float]:
    px, py, rotation, sx, sy = spec.local_transform(atlas)
    cos_r, sin_r = math.cos(rotation), math.sin(rotation)
    ox, oy = atlas.offset_x, -atlas.offset_y
    xs, ys = [], []
    for cx in (-atlas.w / 2.0, atlas.w / 2.0):
        for cy in (-atlas.h / 2.0, atlas.h / 2.0):
            lx, ly = (ox + cx) * sx, (oy + cy) * sy
            xs.append(px + cos_r * lx - sin_r * ly)
            ys.append(py + sin_r * lx + cos_r * ly)
    return min(xs), min(ys), max(xs), max(ys)


# --- existing scene preservation ---------------------------------------------


@dataclass
class Block:
    header: str
    body: list[str] = field(default_factory=list)

    @property
    def kind(self) -> str:
        return self.header[1:].split(" ", 1)[0].rstrip("]")

    def attr(self, name: str) -> str | None:
        match = re.search(rf'\b{name}="((?:[^"\\]|\\.)*)"', self.header)
        return match.group(1) if match else None

    def text(self) -> str:
        return "\n".join([self.header, *self.body]).rstrip("\n") + "\n"


def parse_blocks(text: str) -> list[Block]:
    blocks: list[Block] = []
    for line in text.splitlines():
        if line.startswith("[") and line.rstrip().endswith("]"):
            blocks.append(Block(line.rstrip()))
        elif blocks:
            blocks[-1].body.append(line)
    return blocks


@dataclass
class Preserved:
    uid: str | None = None
    ext_resources: list[Block] = field(default_factory=list)
    sub_resources: list[Block] = field(default_factory=list)
    nodes: list[Block] = field(default_factory=list)
    connections: list[Block] = field(default_factory=list)


def preserve_from(existing: Path) -> Preserved:
    """The scene UID plus the user's Collision subtree, verbatim."""
    result = Preserved()
    if not existing.exists():
        return result
    blocks = parse_blocks(existing.read_text(encoding="utf-8"))
    if not blocks or blocks[0].kind != "gd_scene":
        return result
    result.uid = blocks[0].attr("uid")

    def in_collision(block: Block) -> bool:
        parent = block.attr("parent") or ""
        name = block.attr("name") or ""
        return (name == "Collision" and parent == ".") or parent == "Collision" or parent.startswith("Collision/")

    result.nodes = [b for b in blocks if b.kind == "node" and in_collision(b)]
    if not result.nodes or is_untouched_placeholder(result.nodes):
        # Nothing hand-made here; let the current template be written.
        result.nodes = []
        return result
    if any(f"metadata/{COLLISION_AUTO_META}" in b.text() for b in result.nodes):
        # Auto-generated subtree from a previous run of this tool: replace it
        # wholesale so hitbox data improvements flow into the scene. Removing
        # the marker (see the Collision node description) opts a subtree into
        # preservation.
        result.nodes = []
        return result
    for block in blocks:
        if block.kind == "connection":
            endpoints = (block.attr("from") or "", block.attr("to") or "")
            if any(e == "Collision" or e.startswith("Collision/") for e in endpoints):
                result.connections.append(block)

    kept_text = "\n".join(b.text() for b in result.nodes + result.connections)
    sub_ids = set(re.findall(r'SubResource\("([^"]+)"\)', kept_text))
    subs = {b.attr("id"): b for b in blocks if b.kind == "sub_resource"}
    # Sub-resources can reference further sub-resources; close over them.
    pending = list(sub_ids)
    while pending:
        sub_id = pending.pop()
        block = subs.get(sub_id)
        if block is None:
            continue
        for ref in re.findall(r'SubResource\("([^"]+)"\)', block.text()):
            if ref not in sub_ids:
                sub_ids.add(ref)
                pending.append(ref)
    result.sub_resources = [b for b in blocks if b.kind == "sub_resource" and b.attr("id") in sub_ids]

    all_kept = kept_text + "\n".join(b.text() for b in result.sub_resources)
    ext_ids = set(re.findall(r'ExtResource\("([^"]+)"\)', all_kept))
    result.ext_resources = [b for b in blocks if b.kind == "ext_resource" and b.attr("id") in ext_ids]
    return result


def auto_collision_text(gd_id: int) -> tuple[list[str], list[str]]:
    """The generated Collision subtree for one object type.

    Returns (sub_resource_lines, node_lines). Without a collision spec the
    subtree is the classic empty placeholder, but it now carries the
    auto-collision marker so a later run can still replace it.
    """
    spec = gd_collision_specs.spec_for(gd_id)
    subs: list[str] = []
    nodes: list[str] = []
    if spec is not None:
        node_type = COLLISION_NODE_TYPE[spec.kind]
        layer = COLLISION_NODE_LAYER[spec.kind]
        r, g, b, a = COLLISION_DEBUG_COLOR[spec.kind]
        nodes.append(
            '[node name="Collision" type="'
            + node_type
            + '" parent="."]\n'
            + f"collision_layer = {layer}\n"
            + "collision_mask = 0\n"
            + f"metadata/_editor_description_ = {gd_string(COLLISION_DESCRIPTION)}\n"
            + f"metadata/{COLLISION_AUTO_META} = {gd_string(COLLISION_AUTO_VERSION)}\n"
        )
        for i, shape in enumerate(spec.shapes):
            shape_name = shape.__class__.__name__
            if isinstance(shape, gd_collision_specs.Rect):
                sub_id = f"RectangleShape2D_gdc{i}"
                subs.append(
                    f'[sub_resource type="RectangleShape2D" id="{sub_id}"]\n'
                    f"size = {vec2(shape.size[0], shape.size[1])}\n"
                )
            elif isinstance(shape, gd_collision_specs.Circle):
                sub_id = f"CircleShape2D_gdc{i}"
                subs.append(
                    f'[sub_resource type="CircleShape2D" id="{sub_id}"]\n'
                    f"radius = {num(shape.radius)}\n"
                )
            elif isinstance(shape, gd_collision_specs.Polygon):
                sub_id = f"ConvexPolygonShape2D_gdc{i}"
                pts = ", ".join(f"{num(p[0])}, {num(p[1])}" for p in shape.points)
                subs.append(
                    f'[sub_resource type="ConvexPolygonShape2D" id="{sub_id}"]\n'
                    f"points = PackedVector2Array({pts})\n"
                )
            else:  # pragma: no cover - spec module only makes the shapes above
                continue
            child_name = "Hitbox" if i == 0 else f"Hitbox{i + 1}"
            lines = [f'[node name="{child_name}" type="CollisionShape2D" parent="Collision"]']
            if shape.pos[0] or shape.pos[1]:
                lines.append(f"position = {vec2(shape.pos[0], shape.pos[1])}")
            if isinstance(shape, gd_collision_specs.Rect) and shape.rotation:
                lines.append(f"rotation = {num(math.radians(shape.rotation))}")
            lines.append(f'shape = SubResource("{sub_id}")')
            lines.append(f"debug_color = {color(r, g, b, a)}")
            nodes.append("\n".join(lines) + "\n")
        return subs, nodes

    # No gameplay collision: the classic empty placeholder body.
    nodes.append(
        '[node name="Collision" type="StaticBody2D" parent="."]\n'
        f"collision_layer = {SOLID_LAYER}\n"
        "collision_mask = 0\n"
        f"metadata/_editor_description_ = {gd_string(COLLISION_DESCRIPTION)}\n"
        f"metadata/{COLLISION_AUTO_META} = {gd_string(COLLISION_AUTO_VERSION)}\n"
    )
    nodes.append(
        '[node name="Hitbox" type="CollisionShape2D" parent="Collision"]\n'
        "debug_color = Color(0, 0.07, 0.7, 0.25)\n"
    )
    return subs, nodes


def is_untouched_placeholder(nodes: list[Block]) -> bool:
    """True when the Collision subtree is exactly the generated placeholder."""
    if len(nodes) != 2:
        return False
    hitbox = nodes[1]
    if hitbox.attr("name") != "Hitbox" or hitbox.attr("type") != "CollisionShape2D":
        return False
    body_text = "\n".join(line for line in hitbox.body if line.strip())
    # Any shape, polygon, transform or extra property means the user touched it.
    return "shape" not in body_text and "position" not in body_text and "rotation" not in body_text and "scale" not in body_text


# --- scene writer -------------------------------------------------------------


@dataclass
class Context:
    atlas: dict[str, AtlasFrame]
    pages: list[str]
    page_uids: list[str]
    script_uid: str
    selector_uid: str
    additive_uid: str


def build_scene(gd_id: int, entry: dict, ctx: Context, preserved: Preserved) -> str | None:
    sprites = [s for s in sprites_of(entry) if s.frame in ctx.atlas]
    glow = entry.get("glow") if entry.get("glow") in ctx.atlas else None
    if not sprites and not glow:
        return None

    detail = [s for s in sprites if s.color_class == "detail"]
    main = [s for s in sprites if s.color_class != "detail"]
    # Geometry Dash never interleaves the two classes; the detail layer sits
    # either wholly under or wholly over the main sprites.
    detail_under = bool(detail) and bool(main) and max(s.order for s in detail) < min(s.order for s in main)

    ext: list[str] = [
        f'[ext_resource type="Script" uid="{ctx.script_uid}" path="{SCRIPT_PATH}" id="gd_script"]',
    ]
    used_pages = sorted({ctx.atlas[s.frame].page for s in sprites} | ({ctx.atlas[glow].page} if glow else set()))
    for page in used_pages:
        ext.append(
            f'[ext_resource type="Texture2D" uid="{ctx.page_uids[page]}" '
            f'path="res://assets/textures/gd_atlas/{ctx.pages[page]}" id="gd_page{page}"]'
        )
    ext.append(
        f'[ext_resource type="Script" uid="{ctx.selector_uid}" path="{SELECTOR_SCRIPT_PATH}" id="gd_selector"]'
    )
    if glow:
        ext.append(
            f'[ext_resource type="Material" uid="{ctx.additive_uid}" path="{ADDITIVE_MATERIAL_PATH}" id="gd_additive"]'
        )

    subs: list[str] = []
    texture_ids: dict[str, str] = {}

    def texture_id(frame: str) -> str:
        if frame not in texture_ids:
            atlas = ctx.atlas[frame]
            sub_id = f"AtlasTexture_gd{len(texture_ids)}"
            texture_ids[frame] = sub_id
            subs.append(
                f'[sub_resource type="AtlasTexture" id="{sub_id}"]\n'
                f'atlas = ExtResource("gd_page{atlas.page}")\n'
                f"region = {rect2(atlas.x, atlas.y, atlas.w, atlas.h)}\n"
            )
        return texture_ids[frame]

    # Bounds of the artwork, for the selection box and culling.
    xs0, ys0, xs1, ys1 = [], [], [], []
    for spec in sprites:
        x0, y0, x1, y1 = transformed_bounds(spec, ctx.atlas[spec.frame])
        xs0.append(x0)
        ys0.append(y0)
        xs1.append(x1)
        ys1.append(y1)
    if sprites:
        bx0, by0, bx1, by1 = min(xs0), min(ys0), max(xs1), max(ys1)
    else:
        bx0, by0, bx1, by1 = -CELL_SIZE / 2, -CELL_SIZE / 2, CELL_SIZE / 2, CELL_SIZE / 2
    bw = max(bx1 - bx0, MIN_SELECTION_SIZE)
    bh = max(by1 - by0, MIN_SELECTION_SIZE)
    bcx, bcy = (bx0 + bx1) / 2.0, (by0 + by1) / 2.0

    subs.append(
        '[sub_resource type="RectangleShape2D" id="RectangleShape2D_gdsel"]\n'
        f"size = {vec2(bw, bh)}\n"
    )

    nodes: list[str] = []
    description = f"Geometry Dash object {gd_id} ({entry['base']})"
    nodes.append(
        f'[node name="GD{gd_id}" type="Node2D"]\n'
        # Linear, no mipmaps: the atlas carries none, and mips of a packed page
        # would blend neighbouring frames into each other.
        "texture_filter = 1\n"
        'script = ExtResource("gd_script")\n'
        f"gd_id = {gd_id}\n"
        f"bounds = {rect2(bcx - bw / 2.0, bcy - bh / 2.0, bw, bh)}\n"
        f"metadata/_editor_description_ = {gd_string(description)}\n"
    )

    sprite_index = 0

    def sprite_node(spec: SpriteSpec, parent: str) -> str:
        nonlocal sprite_index
        atlas = ctx.atlas[spec.frame]
        px, py, rotation, sx, sy = spec.local_transform(atlas)
        if spec.is_root:
            name = "Root"
        else:
            sprite_index += 1
            name = f"Sprite{sprite_index}"
        lines = [f'[node name="{name}" type="Sprite2D" parent="{parent}"]']
        if spec.color_class == "black":
            lines.append(f"self_modulate = {color(0, 0, 0, spec.opacity)}")
        elif spec.opacity < 0.9999:
            lines.append(f"self_modulate = {color(1, 1, 1, spec.opacity)}")
        lines.append("use_parent_material = true")
        if px or py:
            lines.append(f"position = {vec2(px, py)}")
        if rotation:
            lines.append(f"rotation = {num(rotation)}")
        lines.append(f"scale = {vec2(sx, sy)}")
        lines.append(f'texture = SubResource("{texture_id(spec.frame)}")')
        if atlas.offset_x or atlas.offset_y:
            lines.append(f"offset = {vec2(atlas.offset_x, -atlas.offset_y)}")
        return "\n".join(lines) + "\n"

    def detail_container() -> list[str]:
        out = ['[node name="Detail" type="Node2D" parent="."]\nuse_parent_material = true\n']
        out.extend(sprite_node(s, "Detail") for s in detail)
        return out

    if detail and detail_under:
        nodes.extend(detail_container())
    nodes.append('[node name="Base" type="Node2D" parent="."]\nuse_parent_material = true\n')
    if glow:
        atlas = ctx.atlas[glow]
        lines = [
            '[node name="Glow" type="Sprite2D" parent="Base"]',
            "visible = false",
            'material = ExtResource("gd_additive")',
            f"scale = {vec2(ART_SCALE, ART_SCALE)}",
            f'texture = SubResource("{texture_id(glow)}")',
        ]
        if atlas.offset_x or atlas.offset_y:
            lines.append(f"offset = {vec2(atlas.offset_x, -atlas.offset_y)}")
        nodes.append("\n".join(lines) + "\n")
    nodes.extend(sprite_node(s, "Base") for s in main)
    if detail and not detail_under:
        nodes.extend(detail_container())

    # Collision: the user's hand-made subtree when the scene has one (it never
    # carries this tool's auto marker); otherwise the generated subtree - the
    # real hitbox for gameplay object types (see gd_collision_specs.py) or the
    # empty placeholder for decorations.
    preserved_ext = [b.text() for b in preserved.ext_resources]
    preserved_sub = [b.text() for b in preserved.sub_resources]
    if preserved.nodes:
        nodes.extend(b.text() for b in preserved.nodes)
    else:
        auto_subs, auto_nodes = auto_collision_text(gd_id)
        subs.extend(auto_subs)
        nodes.extend(auto_nodes)

    nodes.append(
        '[node name="EditorSelectionCollider" type="Area2D" parent="."]\n'
        "collision_layer = 256\n"
        "collision_mask = 128\n"
        'script = ExtResource("gd_selector")\n'
        f"type = {SELECTOR_TYPE_DECORATION}\n"
        f"id = {gd_id}\n"
    )
    nodes.append(
        '[node name="EditorSelectionHitbox" type="CollisionShape2D" parent="EditorSelectionCollider"]\n'
        + (f"position = {vec2(bcx, bcy)}\n" if (bcx or bcy) else "")
        + 'shape = SubResource("RectangleShape2D_gdsel")\n'
        "debug_color = Color(0, 0.6, 0.7, 0)\n"
    )

    ext_all = ext + preserved_ext
    sub_all = subs + preserved_sub
    load_steps = len(ext_all) + len(sub_all) + 1
    uid = preserved.uid or new_uid()
    out = [f'[gd_scene load_steps={load_steps} format=3 uid="{uid}"]\n', "\n"]
    out.append("\n".join(line.rstrip("\n") for line in ext_all) + "\n\n")
    out.append("\n".join(sub_all) + "\n")
    out.append("\n".join(nodes))
    if preserved.connections:
        out.append("\n" + "\n".join(b.text() for b in preserved.connections))
    return "".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--frames-json", type=Path, default=DEFAULT_FRAMES_JSON)
    parser.add_argument("--atlas-json", type=Path, default=DEFAULT_ATLAS_JSON)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--keep-existing", action="store_true", help="never touch a scene that already exists")
    parser.add_argument("--only", type=str, default="", help="comma separated object ids to (re)build")
    parser.add_argument("--prune", action="store_true", help="delete gd_<id>.tscn files whose id is no longer in the table")
    args = parser.parse_args()

    atlas, pages = load_atlas(args.atlas_json)
    objects = load_objects(args.frames_json)
    page_uids = [read_import_uid(ATLAS_DIR / page) for page in pages]
    ctx = Context(
        atlas=atlas,
        pages=pages,
        page_uids=page_uids,
        script_uid=read_uid_file(SCRIPT_UID_FILE),
        selector_uid=read_uid_file(SELECTOR_SCRIPT_UID_FILE),
        additive_uid=read_resource_uid(ADDITIVE_MATERIAL_FILE),
    )
    only = {int(v) for v in args.only.split(",") if v.strip().isdigit()}
    args.out_dir.mkdir(parents=True, exist_ok=True)

    written = kept = skipped = preserved_count = 0
    for gd_id in sorted(objects):
        if only and gd_id not in only:
            continue
        path = args.out_dir / f"gd_{gd_id}.tscn"
        if args.keep_existing and path.exists():
            kept += 1
            continue
        preserved = preserve_from(path)
        text = build_scene(gd_id, objects[gd_id], ctx, preserved)
        if text is None:
            skipped += 1
            continue
        if preserved.nodes:
            preserved_count += 1
        if path.exists() and path.read_text(encoding="utf-8") == text:
            kept += 1
            continue
        path.write_text(text, encoding="utf-8")
        written += 1

    pruned = 0
    if args.prune:
        for path in args.out_dir.glob("gd_*.tscn"):
            stem = path.stem[3:]
            if stem.isdigit() and int(stem) not in objects:
                path.unlink()
                pruned += 1

    print(f"scenes written: {written:,}  unchanged/kept: {kept:,}  no artwork: {skipped:,}")
    print(f"collision subtrees carried over: {preserved_count:,}" + (f"  pruned: {pruned}" if args.prune else ""))
    print(f"-> {args.out_dir.relative_to(PROJECT_ROOT)}")


if __name__ == "__main__":
    main()
