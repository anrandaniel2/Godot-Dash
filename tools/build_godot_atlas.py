#!/usr/bin/env python3
"""Pack the cocos2d ``-hd`` sprite sheets into a Godot-native atlas.

Geometry Dash ships its artwork as cocos2d sheets: a PNG plus a ``.plist``
listing every frame's rectangle, trim offset and whether it was packed rotated
by 90 degrees. Godot cannot read those directly, and ``AtlasTexture`` cannot
express a rotated region, so the runtime used to parse the plists itself and
un-rotate frames pixel by pixel on every launch.

This tool does that work once, offline:

* every frame the game can draw (the ones ``object_frames.json`` refers to,
  or everything with ``--all``) is copied out of its sheet, un-rotated, and
  packed into as few 4096x4096 pages as it takes;
* ``gd_objects_atlas.json`` records, per frame, the page and rectangle it
  landed in plus its trim offset and untrimmed size, i.e. exactly what the
  plists carried, in a shape ``GDSpriteSheet.gd`` can load in one pass;
* a ``.png.import`` is written for each new page (lossless, no mipmaps),
  keeping the page's existing Godot UID when the page is regenerated so the
  object scenes referencing it stay valid.

Usage::

    python3 tools/build_godot_atlas.py             # frames used by objects
    python3 tools/build_godot_atlas.py --all       # every frame in the sheets

Run it again whenever the source sheets or ``object_frames.json`` change,
then ``tools/build_gd_object_scenes.py`` to refresh the object scenes.

Requires Pillow (``pip install pillow``).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import random
import re
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # pragma: no cover - depends on the machine
    sys.exit("Pillow is required: pip install pillow")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas" / "source"
DEFAULT_OUT_DIR = PROJECT_ROOT / "assets" / "textures" / "gd_atlas"
DEFAULT_FRAMES_JSON = DEFAULT_OUT_DIR / "object_frames.json"

ATLAS_BASENAME = "gd_objects_atlas"
PAGE_SIZE = 4096
# Transparent gutter between frames, so linear filtering never bleeds a
# neighbour in. The cocos2d sheets use the same spacing.
PADDING = 2
# The frame Geometry Dash gives objects whose root sprite draws nothing. Always
# packed so the runtime can resolve it like any other frame.
EMPTY_FRAME = "emptyFrame.png"

# Same order as GDSpriteSheet.SHEET_NAMES: when two sheets carry a frame of the
# same name the first one listed wins, so the runtime and this tool agree.
SHEETS = [
    "PixelSheet_01",
    "GJ_GameSheet02",
    "GJ_GameSheet",
    "GJ_GameSheet03",
    "GJ_GameSheet04",
    "GJ_GameSheetGlow",
    "GJ_ParticleSheet",
    "FireSheet_01",
    "GroundSheet_01",
]

IMPORT_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"
uid="{uid}"
path="res://.godot/imported/{file}-{md5}.ctex"
metadata={{
"vram_texture": false
}}

[deps]

source_file="{res_path}"
dest_files=["res://.godot/imported/{file}-{md5}.ctex"]

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=false
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
"""


# --- Godot UIDs ---------------------------------------------------------------


def godot_uid_text(value: int) -> str:
    """Encode a positive 63-bit integer the way ``ResourceUID::id_to_text`` does.

    Godot's alphabet is ``a``-``y`` for 0-24 and ``0``-``8`` for 25-33 (base 34,
    an off-by-one in the engine that is now part of the format).
    """
    char_count = ord("z") - ord("a")  # 25
    base = char_count + (ord("9") - ord("0"))  # 34
    text = ""
    while value:
        digit = value % base
        if digit < char_count:
            text = chr(ord("a") + digit) + text
        else:
            text = chr(ord("0") + digit - char_count) + text
        value //= base
    return "uid://" + text


def new_godot_uid() -> str:
    return godot_uid_text(random.getrandbits(63) | (1 << 62))


def read_import_uid(import_path: Path) -> str | None:
    if not import_path.exists():
        return None
    match = re.search(r'^uid="(uid://[^"]+)"', import_path.read_text(encoding="utf-8"), re.M)
    return match.group(1) if match else None


def write_import(png_path: Path, res_path: str, uid: str) -> None:
    md5 = hashlib.md5(res_path.encode("utf-8")).hexdigest()
    import_path = png_path.with_name(png_path.name + ".import")
    import_path.write_text(
        IMPORT_TEMPLATE.format(uid=uid, file=png_path.name, md5=md5, res_path=res_path),
        encoding="utf-8",
    )


# --- source sheets ------------------------------------------------------------


@dataclass
class SourceFrame:
    name: str
    sheet: str
    png: Path
    x: int
    y: int
    width: int  # upright size, after un-rotating
    height: int
    rotated: bool
    offset_x: float
    offset_y: float
    source_width: float
    source_height: float


def parse_numbers(text: str) -> list[float]:
    return [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", str(text))]


def find_sheet(source_dir: Path, name: str) -> tuple[Path, Path] | None:
    for suffix in ("-hd", ""):
        plist = source_dir / f"{name}{suffix}.plist"
        png = source_dir / f"{name}{suffix}.png"
        if plist.exists() and png.exists():
            return plist, png
    return None


def collect_frames(source_dir: Path) -> dict[str, SourceFrame]:
    frames: dict[str, SourceFrame] = {}
    for sheet in SHEETS:
        found = find_sheet(source_dir, sheet)
        if found is None:
            continue
        plist_path, png_path = found
        with plist_path.open("rb") as handle:
            data = plistlib.load(handle)
        for name, entry in data.get("frames", {}).items():
            if name in frames or not isinstance(entry, dict):
                continue
            rect = parse_numbers(entry.get("textureRect") or entry.get("frame") or "")
            if len(rect) < 4 or rect[2] <= 0 or rect[3] <= 0:
                continue
            rotated = bool(entry.get("textureRotated", entry.get("rotated", False)))
            offset = parse_numbers(entry.get("spriteOffset") or entry.get("offset") or "{0,0}")
            source = parse_numbers(
                entry.get("spriteSourceSize") or entry.get("sourceSize") or "{0,0}"
            )
            width, height = int(rect[2]), int(rect[3])
            frames[name] = SourceFrame(
                name=name,
                sheet=sheet,
                png=png_path,
                x=int(rect[0]),
                y=int(rect[1]),
                width=width,
                height=height,
                rotated=rotated,
                offset_x=offset[0] if len(offset) > 0 else 0.0,
                offset_y=offset[1] if len(offset) > 1 else 0.0,
                source_width=source[0] if len(source) > 0 and source[0] > 0 else float(width),
                source_height=source[1] if len(source) > 1 and source[1] > 0 else float(height),
            )
    return frames


def frames_used_by_objects(frames_json: Path) -> set[str]:
    """Every frame name ``object_frames.json`` can ask for."""
    if not frames_json.exists():
        sys.exit(f"object frame table not found: {frames_json}")
    data = json.loads(frames_json.read_text(encoding="utf-8"))
    table = data.get("frames", data)
    used: set[str] = {EMPTY_FRAME}
    for entry in table.values():
        if isinstance(entry, str):
            used.add(entry)
            continue
        if not isinstance(entry, dict):
            continue
        for key in ("base", "detail", "glow", "extra"):
            value = entry.get(key)
            if value:
                used.add(str(value))
        for part in entry.get("parts", []):
            if isinstance(part, dict) and part.get("frame"):
                used.add(str(part["frame"]))
    return used


# --- packing ------------------------------------------------------------------


class Skyline:
    """Bottom-left skyline packer for one page."""

    def __init__(self, width: int, height: int) -> None:
        self.width = width
        self.height = height
        # (x, y, width) segments covering [0, width), left to right.
        self.nodes: list[tuple[int, int, int]] = [(0, 0, width)]
        self.used_height = 0

    def _fit(self, index: int, width: int, height: int) -> int | None:
        x = self.nodes[index][0]
        if x + width > self.width:
            return None
        remaining = width
        y = 0
        i = index
        while remaining > 0:
            if i >= len(self.nodes):
                return None
            node_x, node_y, node_w = self.nodes[i]
            y = max(y, node_y)
            if y + height > self.height:
                return None
            remaining -= node_w
            i += 1
        return y

    def insert(self, width: int, height: int) -> tuple[int, int] | None:
        best: tuple[int, int, int] | None = None  # (y + height, x, index)
        for index in range(len(self.nodes)):
            y = self._fit(index, width, height)
            if y is None:
                continue
            candidate = (y + height, self.nodes[index][0], index)
            if best is None or candidate < best:
                best = candidate
        if best is None:
            return None
        top, x, index = best
        y = top - height
        # Raise the skyline under the new rectangle.
        self.nodes.insert(index, (x, top, width))
        i = index + 1
        while i < len(self.nodes):
            node_x, node_y, node_w = self.nodes[i]
            if node_x < x + width:
                shrink = x + width - node_x
                if shrink >= node_w:
                    del self.nodes[i]
                    continue
                self.nodes[i] = (node_x + shrink, node_y, node_w - shrink)
            break
        # Merge neighbours at the same height.
        i = 0
        while i < len(self.nodes) - 1:
            a, b = self.nodes[i], self.nodes[i + 1]
            if a[1] == b[1]:
                self.nodes[i] = (a[0], a[1], a[2] + b[2])
                del self.nodes[i + 1]
            else:
                i += 1
        self.used_height = max(self.used_height, top)
        return x, y


@dataclass
class Placement:
    frame: SourceFrame
    page: int
    x: int
    y: int


def pack(frames: list[SourceFrame], page_size: int) -> tuple[list[Placement], list[int]]:
    """Returns placements and the used height of every page."""
    ordered = sorted(frames, key=lambda f: (-f.height, -f.width, f.name))
    pages: list[Skyline] = []
    placements: list[Placement] = []
    for frame in ordered:
        padded_w = frame.width + PADDING
        padded_h = frame.height + PADDING
        if padded_w > page_size or padded_h > page_size:
            sys.exit(f"{frame.name} ({frame.width}x{frame.height}) does not fit a page")
        placed = False
        for page_index, page in enumerate(pages):
            spot = page.insert(padded_w, padded_h)
            if spot is not None:
                placements.append(Placement(frame, page_index, spot[0] + PADDING, spot[1] + PADDING))
                placed = True
                break
        if not placed:
            page = Skyline(page_size, page_size)
            pages.append(page)
            spot = page.insert(padded_w, padded_h)
            assert spot is not None
            placements.append(Placement(frame, len(pages) - 1, spot[0] + PADDING, spot[1] + PADDING))
    heights = [min(page_size, page.used_height + PADDING) for page in pages]
    return placements, heights


# --- output -------------------------------------------------------------------


def number(value: float) -> int | float:
    return int(value) if float(value).is_integer() else round(float(value), 3)


def build(source_dir: Path, out_dir: Path, frames_json: Path, pack_all: bool, page_size: int) -> None:
    sheets = collect_frames(source_dir)
    if not sheets:
        sys.exit(f"no cocos2d sheets found in {source_dir}")
    print(f"{len(sheets):,} frames across {len({f.sheet for f in sheets.values()})} sheets")

    if pack_all:
        wanted = set(sheets)
    else:
        wanted = frames_used_by_objects(frames_json)
        missing = sorted(name for name in wanted if name not in sheets)
        if missing:
            print(f"  {len(missing)} referenced frames are not in any sheet, e.g. {missing[:3]}")
        wanted = {name for name in wanted if name in sheets}
    selected = [sheets[name] for name in sorted(wanted)]
    total_area = sum((f.width + PADDING) * (f.height + PADDING) for f in selected)
    print(f"packing {len(selected):,} frames ({total_area / 1e6:.1f} Mpx with padding)")

    placements, heights = pack(selected, page_size)
    print(f"  -> {len(heights)} page(s): " + ", ".join(f"{page_size}x{h}" for h in heights))

    out_dir.mkdir(parents=True, exist_ok=True)
    images: dict[Path, Image.Image] = {}
    pages = [Image.new("RGBA", (page_size, height), (0, 0, 0, 0)) for height in heights]
    for placement in placements:
        frame = placement.frame
        if frame.png not in images:
            images[frame.png] = Image.open(frame.png).convert("RGBA")
        source = images[frame.png]
        if frame.rotated:
            # A rotated frame occupies a region with width and height swapped
            # and its pixels turned 90 degrees clockwise; rotating the crop
            # anticlockwise (PIL's positive direction) puts it upright.
            crop = source.crop((frame.x, frame.y, frame.x + frame.height, frame.y + frame.width))
            crop = crop.rotate(90, expand=True)
        else:
            crop = source.crop((frame.x, frame.y, frame.x + frame.width, frame.y + frame.height))
        assert crop.size == (frame.width, frame.height), frame.name
        pages[placement.page].paste(crop, (placement.x, placement.y))

    page_files: list[str] = []
    for index, page in enumerate(pages):
        name = f"{ATLAS_BASENAME}_{index}.png"
        path = out_dir / name
        page.save(path, optimize=True)
        res_path = "res://" + path.relative_to(PROJECT_ROOT).as_posix()
        uid = read_import_uid(path.with_name(name + ".import")) or new_godot_uid()
        write_import(path, res_path, uid)
        page_files.append(name)
        print(f"  wrote {path.relative_to(PROJECT_ROOT)} ({path.stat().st_size // 1024} KB, {uid})")

    # Stale pages from a previous, larger run must not linger: Godot would
    # still import them.
    for stale in sorted(out_dir.glob(f"{ATLAS_BASENAME}_*.png")):
        if stale.name not in page_files:
            stale.unlink()
            stale_import = stale.with_name(stale.name + ".import")
            if stale_import.exists():
                stale_import.unlink()
            print(f"  removed stale {stale.name}")

    sheet_names = sorted({f.sheet for f in selected}, key=SHEETS.index)
    table: dict[str, list] = {}
    for placement in sorted(placements, key=lambda p: p.frame.name):
        frame = placement.frame
        table[frame.name] = [
            placement.page,
            placement.x,
            placement.y,
            frame.width,
            frame.height,
            number(frame.offset_x),
            number(frame.offset_y),
            number(frame.source_width),
            number(frame.source_height),
            sheet_names.index(frame.sheet),
        ]
    payload = {
        "_source": "cocos2d -hd sheets from assets/textures/gd_atlas/source, repacked by tools/build_godot_atlas.py",
        "_format": "frame: [page, x, y, width, height, offset_x, offset_y, source_width, source_height, sheet]; "
        "pixels are -hd atlas pixels (2 per Geometry Dash unit); offset is the trim offset, y up, as cocos2d stores it; "
        "rotated source frames are stored upright",
        "_count": len(table),
        "page_size": page_size,
        "padding": PADDING,
        "pages": page_files,
        "sheets": sheet_names,
        "frames": table,
    }
    json_path = out_dir / f"{ATLAS_BASENAME}.json"
    json_path.write_text(json.dumps(payload, indent="\t", separators=(",", ": ")), encoding="utf-8")
    print(f"  wrote {json_path.relative_to(PROJECT_ROOT)} ({json_path.stat().st_size // 1024} KB)")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR, help="cocos2d plist/png sheets")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR, help="where the pages and JSON go")
    parser.add_argument("--frames-json", type=Path, default=DEFAULT_FRAMES_JSON, help="object_frames.json, selects the frames to pack")
    parser.add_argument("--all", action="store_true", help="pack every frame, not just the ones objects use")
    parser.add_argument("--page-size", type=int, default=PAGE_SIZE)
    args = parser.parse_args()
    if not args.source_dir.is_dir():
        sys.exit(f"source directory not found: {args.source_dir}")
    build(args.source_dir, args.out_dir, args.frames_json, args.all, args.page_size)


if __name__ == "__main__":
    main()
