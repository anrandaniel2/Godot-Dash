#!/usr/bin/env python3
"""Audit game Texture2D imports; --imported also checks actual Godot 4.x CTEX codecs.

Gameplay uses S3TC/ETC2 VRAM compression; UI uses lossy WebP at quality 0.90.
Fonts and data masks remain lossless. Source art is never rewritten by this tool.
Format reference: Godot 4.7.2 resource_importer_texture.cpp / compressed_texture.h.
No Godot, Pillow, or other third-party dependency is needed for this build gate.
"""
from __future__ import annotations

import argparse
import configparser
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = {"compress/mode": 0, "detect_3d/compress_to": 0}
GAMEPLAY_DIRS = {"gd_atlas", "gd_art", "backgrounds", "grounds", "checkpoints",
                 "hazards", "solids", "orbs", "pads", "portals", "particles", "player"}
UI_DIRS = {"guis", "icons", "triggers"}
UI_FILES = {"ArrowedLine.svg", "Circle.svg", "Cross.svg", "Text.svg"}
# Godot 4.7 Image::Format: (name, bytes per 4x4 block).
GPU_FORMATS = {
    17: ("s3tc_dxt1", 8), 18: ("s3tc_dxt3", 16), 19: ("s3tc_dxt5", 16),
    20: ("s3tc_rgtc_r", 8), 21: ("s3tc_rgtc_rg", 16),
    26: ("etc2_r11", 8), 27: ("etc2_r11s", 8), 28: ("etc2_rg11", 16),
    29: ("etc2_rg11s", 16), 30: ("etc2_rgb8", 8), 31: ("etc2_rgba8", 16),
    32: ("etc2_rgb8a1", 8), 33: ("etc2_ra_as_rg", 16), 34: ("s3tc_ra_as_rg", 16),
}


def texture_mode(relative: Path) -> int:
    path = relative.as_posix().removesuffix(".import")
    if path.startswith(("assets/fonts/", "assets/textures/particle_emission_masks/",
                        "assets/textures/gd_atlas/source/")):
        return 0  # Glyph/placement data, and excluded source sheets, not display art.
    if path.startswith("assets/logo/") or path == "assets/splash.png":
        return 1
    parts = Path(path).parts
    if len(parts) >= 3 and parts[:2] == ("assets", "textures"):
        if parts[2] in UI_DIRS or (len(parts) == 3 and parts[2] in UI_FILES):
            return 1
        if parts[2] in GAMEPLAY_DIRS:
            return 2
    raise ValueError(f"Unclassified texture; assign a usage before export: {path}")


def import_policy(mode: int) -> dict[str, str]:
    if mode not in (0, 1, 2):
        raise ValueError("Unsupported texture policy mode")
    values = {"compress/mode": str(mode), "detect_3d/compress_to": "0", "process/size_limit": "0"}
    if mode == 1:
        values["compress/lossy_quality"] = "0.9"
    elif mode == 2:
        # S3TC + ETC2 also work with the WebGL fallback; do not require BC7/ASTC.
        values["compress/high_quality"] = "false"
    return values


def apply_policy(root: Path) -> int:
    changed = 0
    for path in sorted((root / "assets").rglob("*.import")):
        original = path.read_text(encoding="utf-8")
        if not re.search(r'^importer="texture"$', original, re.MULTILINE):
            continue
        text = original
        mode = texture_mode(path.relative_to(root))
        for key, value in import_policy(mode).items():
            text, count = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", f"{key}={value}", text)
            if count != 1:
                raise ValueError(f"{path}: missing/duplicate {key}; import in Godot first")
        check_import(flat_config(text), mode)
        if text != original:
            path.write_text(text, encoding="utf-8")
            changed += 1
    return changed


def check_defaults(project: str) -> None:
    section = re.search(r"(?ms)^\[importer_defaults\]\s*\n(.*?)(?=^\[|\Z)", project)
    setting = re.search(r"(?ms)^texture\s*=\s*(\{.*)", section[1]) if section else None
    if not setting:
        raise ValueError("Missing explicit lossless texture importer defaults")
    # Our defaults dictionary contains only JSON-compatible scalar options.
    defaults, _ = json.JSONDecoder().raw_decode(setting[1])
    for key, value in DEFAULTS.items():
        if type(defaults.get(key)) is not int or defaults[key] != value:
            raise ValueError(f"Texture default {key} must be {value}")

    rendering = re.search(r"(?ms)^\[rendering\]\s*\n(.*?)(?=^\[|\Z)", project)
    if not rendering:
        raise ValueError("Missing GPU import format settings")
    settings = flat_config("[rendering]\n" + rendering[1])["rendering"]
    for key in ("textures/vram_compression/import_s3tc_bptc", "textures/vram_compression/import_etc2_astc"):
        if settings.get(key) != "true":
            raise ValueError(f"Both GPU import families must be enabled: {key}")
        if any(option.startswith(key + ".") for option in settings):
            raise ValueError(f"Do not disable GPU import families via feature overrides: {key}")


def flat_config(text: str) -> configparser.ConfigParser:
    # Godot metadata dictionaries are not INI. Only consume flat settings;
    # remap paths and params used below are single-line scalar values.
    lines = [line for line in text.splitlines()
             if line.startswith("[") or re.match(r"^[\w/.-]+=", line)]
    config = configparser.ConfigParser(interpolation=None)
    config.read_string("\n".join(lines))
    return config


def check_import(config: configparser.ConfigParser, mode: int = 0) -> None:
    if config.get("remap", "type", fallback="") != '"CompressedTexture2D"':
        raise ValueError("Texture importer must produce CompressedTexture2D")
    params = config["params"]
    for key, value in import_policy(mode).items():
        if params.get(key) != str(value):
            raise ValueError(f"{key} must be {value}")
        if any(option.startswith(key + ".") for option in params):
            raise ValueError(f"Platform overrides of {key} are not permitted")
    if params.get("process/size_limit") != "0":
        raise ValueError("Texture downscaling is not permitted")


def check_webp(data: bytes, lossless: bool = True) -> None:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError("Invalid WebP container")
    if struct.unpack_from("<I", data, 4)[0] + 8 != len(data):
        raise ValueError("Truncated WebP container")
    offset = 12
    bitstreams = []
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Truncated WebP chunk")
        kind = data[offset:offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        start = offset + 8
        end = start + size
        if end + (size & 1) > len(data):
            raise ValueError("Truncated WebP payload")
        if kind in (b"ANIM", b"ANMF"):
            raise ValueError("Animated WebP is not a texture")
        if kind == b"VP8L":
            if size < 5 or data[start] != 0x2F:
                raise ValueError("Invalid lossless WebP header")
            bitstreams.append("lossless")
        if kind == b"VP8 ":
            if size < 10 or data[start + 3:start + 6] != b"\x9d\x01\x2a":
                raise ValueError("Invalid lossy WebP keyframe")
            bitstreams.append("lossy")
        offset = end + (size & 1)
    if bitstreams != ["lossless" if lossless else "lossy"]:
        raise ValueError("WebP bitstream does not match the requested compression mode")


def check_ctex(data: bytes, mode: int = 0) -> tuple[str, int]:
    import_policy(mode)  # Reject unsupported policies before interpreting bytes.
    # GST2 header: magic + 8 u32; image header: codec, u16 width/height,
    # mipmap count, Image::Format. Each PNG/WebP mip then has a u32 length.
    if len(data) < 52 or data[:4] != b"GST2":
        raise ValueError("Invalid/truncated CTEX header")
    version, width, height, flags = struct.unpack_from("<4I", data, 4)
    if version != 1 or not width or not height:
        raise ValueError("Unsupported CTEX version/dimensions")
    if flags & (1 << 24):
        raise ValueError("CTEX still allows automatic 3D recompression")
    codec, image_width, image_height, mipmaps, image_format = struct.unpack_from("<IHHII", data, 36)
    if not image_width or not image_height or mipmaps > 32:
        raise ValueError("Invalid CTEX image dimensions/mipmap count")
    if mode == 2:
        if codec != 0 or image_format not in GPU_FORMATS:
            raise ValueError("Gameplay CTEX must contain S3TC/ETC2 GPU blocks, not raw pixels/PNG/WebP")
        name, block_bytes = GPU_FORMATS[image_format]
        expected = 52
        for _ in range(mipmaps + 1):
            expected += ((image_width + 3) // 4) * ((image_height + 3) // 4) * block_bytes
            image_width = max(1, image_width // 2)
            image_height = max(1, image_height // 2)
        if len(data) != expected:
            raise ValueError("Incorrect GPU block payload/mipmap size")
        return name, mipmaps + 1
    if codec not in ((1, 2) if mode == 0 else (2,)):
        raise ValueError("CTEX codec does not match lossless/UI-lossy storage")
    offset = 52
    for _ in range(mipmaps + 1):
        if offset + 4 > len(data):
            raise ValueError("Missing CTEX mipmap")
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        if not size or offset + size > len(data):
            raise ValueError("Truncated CTEX mipmap")
        payload = data[offset:offset + size]
        if codec == 1:
            if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("Invalid PNG mipmap signature")
        else:
            check_webp(payload, lossless=mode == 0)
        offset += size
    if offset != len(data):
        raise ValueError("Unexpected trailing CTEX data")
    # Codec/header audit, not a pixel decoder or a visual parity test.
    return ("png" if codec == 1 else "webp_lossless" if mode == 0 else "webp_lossy"), mipmaps + 1


def audit(root: Path, imported: bool = False) -> dict:
    check_defaults((root / "project.godot").read_text(encoding="utf-8"))
    result = {"texture_imports": 0, "orphan_imports": 0, "ctex_files": 0, "ctex_bytes": 0, "mip_levels": 0, "codecs": {}, "modes": {}}
    seen = set()
    for path in sorted((root / "assets").rglob("*.import")):
        try:
            text = path.read_text(encoding="utf-8")
            if not re.search(r'^importer="texture"$', text, re.MULTILINE):
                continue  # Font imports can contain nested Object properties, not INI.
            config = flat_config(text)
            source_path = path.with_suffix("").resolve()
            if not source_path.is_relative_to(root.resolve()):
                raise ValueError("Texture source escapes project root")
            if not source_path.is_file():
                # Keep stale sidecars visible in the summary but don't mistake
                # their old remap for a newly imported shipping texture.
                result["orphan_imports"] += 1
                continue
            mode = texture_mode(path.relative_to(root))
            check_import(config, mode)
            result["modes"][str(mode)] = result["modes"].get(str(mode), 0) + 1
            result["texture_imports"] += 1
            if not imported:
                continue
            if mode == 2 and not {"path.s3tc", "path.etc2"}.issubset(config["remap"]):
                raise ValueError("Reimport gameplay texture: both S3TC and ETC2 variants are required")
            remaps = [json.loads(value) for key, value in config["remap"].items()
                      if key == "path" or key.startswith("path.")]
            if not remaps:
                raise ValueError("Missing CTEX remap")
            for remap in remaps:
                if not remap.startswith("res://.godot/imported/") or not remap.endswith(".ctex"):
                    raise ValueError(f"Unexpected CTEX remap: {remap}")
                target = (root / remap.removeprefix("res://")).resolve()
                if not target.is_relative_to((root / ".godot/imported").resolve()):
                    raise ValueError("CTEX remap escapes import cache")
                identity = (target, mode)
                if identity in seen:
                    continue
                seen.add(identity)
                data = target.read_bytes()  # Missing generated outputs fail the build.
                codec, levels = check_ctex(data, mode)
                if mode == 2:
                    family = "s3tc" if remap.endswith(".s3tc.ctex") else "etc2" if remap.endswith(".etc2.ctex") else ""
                    if not family or not codec.startswith(family + "_"):
                        raise ValueError("GPU payload does not match its platform variant")
                result["ctex_files"] += 1
                result["ctex_bytes"] += len(data)
                result["mip_levels"] += levels
                result["codecs"][codec] = result["codecs"].get(codec, 0) + 1
        except (ValueError, KeyError, OSError, configparser.Error) as error:
            raise ValueError(f"{path.relative_to(root)}: {error}") from error
    if not result["texture_imports"]:
        raise ValueError("No game texture imports found")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--apply", action="store_true", help="assign usage-based compression to existing imports, preserving other settings")
    actions.add_argument("--imported", action="store_true", help="require and inspect generated CTEX payloads after Godot import")
    args = parser.parse_args()
    if args.apply:
        print(f"Updated texture imports: {apply_policy(ROOT)}")
    print("TEXTURE_COMPRESSION_AUDIT " + json.dumps(audit(ROOT, args.imported), sort_keys=True))
