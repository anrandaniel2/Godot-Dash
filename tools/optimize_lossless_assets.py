#!/usr/bin/env python3
"""Losslessly optimize runtime PNG/JSON/plist sources, retaining only smaller files.

Install tools/lossless_assets_requirements.txt. Default is a dry run; --apply
writes verified candidates atomically. No runtime decoder or import settings
change. Font bundles (checksum-pinned) and excluded atlas source PNGs stay put.
Atlas plists are shipped fallback metadata, so their container indentation can shrink.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import plistlib
import xml.parsers.expat
from pathlib import Path
import os
import struct
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("Not a PNG")
    offset = len(PNG_SIGNATURE)
    result = []
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + size
        if end > len(data):
            raise ValueError("Truncated PNG payload")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("PNG CRC mismatch")
        result.append((kind, payload))
        offset = end
        if kind == b"IEND":
            if payload or offset != len(data):
                raise ValueError("Invalid PNG end/trailing data")
            break
    if not result or result[0][0] != b"IHDR" or len(result[0][1]) != 13:
        raise ValueError("Missing/invalid PNG header")
    if result[-1][0] != b"IEND" or not any(k == b"IDAT" for k, _ in result):
        raise ValueError("Incomplete PNG")
    return result


def png_pixels(data: bytes) -> tuple[str, tuple[int, int], bytes]:
    # Pillow independently decodes the optimizer's result. Restrict this tool
    # to <=8-bit images: Pillow downconverts multi-channel 16-bit PNGs, which
    # would make a byte equality test insufficient for those assets.
    from PIL import Image
    chunks = png_chunks(data)
    if chunks[0][1][8] > 8 or any(k == b"acTL" for k, _ in chunks):
        raise ValueError("16-bit/APNG assets need a separate full-fidelity verifier")
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        return image.mode, image.size, image.tobytes()


def verify_png(before: bytes, after: bytes) -> str:
    # Keep IHDR, palette/transparency, ICC/gamma/sRGB and ALL other chunks
    # byte-identical and in order. Only IDAT representation may change.
    metadata = lambda data: [(k, v) for k, v in png_chunks(data) if k != b"IDAT"]
    if metadata(before) != metadata(after):
        raise ValueError("PNG format/metadata changed")
    old_pixels = png_pixels(before)
    if old_pixels != png_pixels(after):
        raise ValueError("PNG decoded samples changed (including transparent RGB)")
    return hashlib.sha256(old_pixels[2]).hexdigest()


def preserve_png_metadata(before: bytes, optimized: bytes) -> bytes:
    original = png_chunks(before)
    candidate = png_chunks(optimized)
    if original[0] != candidate[0]:
        raise ValueError("Optimizer changed PNG header")
    # Even with strip=none, optimizers may trim redundant tRNS bytes. Keep
    # original chunks verbatim; take ONLY the new compressed image stream.
    idat = b"".join(value for kind, value in candidate if kind == b"IDAT")
    output = bytearray(PNG_SIGNATURE)
    emitted = False
    for kind, value in original:
        if kind == b"IDAT":
            if emitted:
                continue
            value = idat
            emitted = True
        output.extend(struct.pack(">I", len(value)))
        output.extend(kind)
        output.extend(value)
        output.extend(struct.pack(">I", zlib.crc32(kind + value)))
    return bytes(output)


def optimize_png(data: bytes, level: int = 2) -> tuple[bytes, str]:
    import oxipng
    if level not in range(7):
        raise ValueError("PNG effort must be between 0 and 6")
    png_pixels(data)  # Reject unsupported inputs before optimization.
    candidate = oxipng.optimize_from_memory(
        data, level=level, optimize_alpha=False, bit_depth_reduction=False,
        color_type_reduction=False, palette_reduction=False,
        grayscale_reduction=False, scale_16=False, fix_errors=False,
        strip=oxipng.StripChunks.none(),
    )
    candidate = preserve_png_metadata(data, candidate)
    pixel_hash = verify_png(data, candidate)
    return (candidate if len(candidate) < len(data) else data), pixel_hash


def compact_json(data: bytes) -> bytes:
    # Remove only insignificant JSON whitespace. Do NOT parse/re-serialize
    # numbers, escapes or key order: their original tokens stay byte-identical.
    json.loads(data)
    result = bytearray()
    quoted = escaped = False
    for byte in data:
        if quoted:
            result.append(byte)
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
            result.append(byte)
        elif byte not in b" \t\r\n":
            result.append(byte)
    candidate = bytes(result)
    if json.loads(data) != json.loads(candidate):
        raise ValueError("JSON values changed")
    return candidate


def compact_plist(data: bytes) -> bytes:
    """Remove only container indentation, preserving original XML/value tokens.

    The Godot fallback parser walks tags and decodes a small set of XML entities.
    Re-serializing XML could change its inputs (e.g. numeric entity spelling), so
    use Expat's byte offsets to delete only literal whitespace in plist/dict/array.
    Never fetch DTDs, expand custom entities, or strip comments/string contents.
    """
    data.decode("utf-8")  # This asset tool intentionally handles UTF-8 XML only.
    parser = xml.parsers.expat.ParserCreate()
    stack = []
    spans = []
    in_cdata = False

    def start(name, attributes):
        preserve = stack[-1][1] if stack else False
        preserve = attributes.get("xml:space", "preserve" if preserve else "default") == "preserve"
        stack.append((name, preserve))

    def text(value):
        if in_cdata or not stack or stack[-1][0] not in ("plist", "dict", "array") or stack[-1][1]:
            return
        raw = value.encode("utf-8")
        offset = parser.CurrentByteIndex
        # Entity callbacks and CRLF normalization must not corrupt byte offsets.
        if raw and all(byte in b" \t\r\n" for byte in raw) and data[offset:offset + len(raw)] == raw:
            spans.append((offset, offset + len(raw)))

    def cdata_start():
        nonlocal in_cdata
        in_cdata = True

    def cdata_end():
        nonlocal in_cdata
        in_cdata = False

    def reject_entity(*_args):
        raise ValueError("Custom XML entities are not supported")

    parser.StartElementHandler = start
    parser.EndElementHandler = lambda _name: stack.pop()
    parser.CharacterDataHandler = text
    parser.StartCdataSectionHandler = cdata_start
    parser.EndCdataSectionHandler = cdata_end
    parser.EntityDeclHandler = reject_entity
    parser.ExternalEntityRefHandler = lambda *_args: 1  # No network/file lookup.
    parser.Parse(data, True)
    pieces = []
    previous = 0
    for start_offset, end_offset in spans:
        pieces.append(data[previous:start_offset])
        previous = end_offset
    pieces.append(data[previous:])
    candidate = b"".join(pieces)
    if plistlib.loads(data) != plistlib.loads(candidate):
        raise ValueError("Plist values changed")
    return candidate


def asset_paths(root: Path) -> list[Path]:
    paths = []
    assets = root / "assets"
    for path in sorted(assets.rglob("*")):
        relative = path.relative_to(root)
        if relative.is_relative_to("assets/fonts") or (relative.is_relative_to("assets/textures/gd_atlas/source") and path.suffix != ".plist"):
            continue
        if path.suffix not in (".png", ".json", ".plist") or not path.is_file() or path.is_symlink():
            continue
        if not path.resolve().is_relative_to(assets.resolve()):
            raise ValueError(f"Asset escapes root: {path}")
        paths.append(path)
    return paths


def atomic_replace(path: Path, before: bytes, after: bytes) -> None:
    # Don't clobber an edit made while compression was running.
    if path.read_bytes() != before:
        raise ValueError(f"Asset changed during optimization: {path}")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(after)
        temporary.chmod(path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="write verified smaller files (default: dry run)")
    parser.add_argument("--report", type=Path, help="write per-file sizes and verification hashes as JSON")
    parser.add_argument("--png-level", type=int, choices=range(7), default=2, help="offline PNG effort: 2 is fast, 6 searches more filters")
    args = parser.parse_args()
    files = []
    for path in asset_paths(ROOT):
        before = path.read_bytes()
        pixel_hash = None
        if path.suffix == ".png":
            after, pixel_hash = optimize_png(before, args.png_level)
        elif path.suffix == ".plist":
            after = compact_plist(before)
        else:
            after = compact_json(before)
        if len(after) >= len(before):
            after = before
        changed = before != after
        if changed and args.apply:
            atomic_replace(path, before, after)
        record = {
            "path": path.relative_to(ROOT).as_posix(), "before_bytes": len(before),
            "after_bytes": len(after), "before_sha256": hashlib.sha256(before).hexdigest(),
            "after_sha256": hashlib.sha256(after).hexdigest(),
        }
        if pixel_hash is not None:
            record["decoded_samples_sha256"] = pixel_hash
        files.append(record)
        if changed:
            print(f"{'WROTE' if args.apply else 'WOULD SAVE'} {record['path']} {len(before)} -> {len(after)}", flush=True)
    report = {
        "applied": args.apply, "png_level": args.png_level, "files_scanned": len(files),
        "files_changed": sum(f["before_sha256"] != f["after_sha256"] for f in files),
        "before_bytes": sum(f["before_bytes"] for f in files),
        "after_bytes": sum(f["after_bytes"] for f in files), "files": files,
    }
    print(json.dumps({k: v for k, v in report.items() if k != "files"}), flush=True)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
