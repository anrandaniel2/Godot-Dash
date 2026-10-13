#!/usr/bin/env python3
"""Stage Windows library mappings into the ignored build-output descriptor.

Run after building native/ with platform=windows target=template_release.
Both editor import and release export use the same optimized DLL. This does
not commit or replace any Android/web mapping.
"""
import argparse
import pathlib
import re
import struct

DLL = "libgdash_native.windows.template_release.x86_64.dll"


def check_pe(path: pathlib.Path) -> None:
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError(f"{path}: not a PE binary")
    offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[offset:offset + 4] != b"PE\0\0":
        raise ValueError(f"{path}: missing PE signature")
    if struct.unpack_from("<H", data, offset + 4)[0] != 0x8664:
        raise ValueError(f"{path}: not x86-64")


def pin(root: pathlib.Path) -> None:
    check_pe(root / "native/bin/windows" / DLL)
    descriptor = root / "native/bin/gdash_native.gdextension"
    text = descriptor.read_text(encoding="utf-8")
    if text.count("[libraries]") != 1:
        raise ValueError("Expected exactly one [libraries] section")
    lines = [line for line in text.splitlines() if not line.startswith("windows.")]
    text = "\n".join(lines).rstrip() + "\n"
    entries = "\n".join(
        f'windows.{target}.x86_64 = "./windows/{DLL}"'
        for target in ("debug", "release")
    )
    text = re.sub(r"\[libraries\]\n(?:[ \t]*\n)*", "[libraries]\n\n" + entries + "\n\n", text, count=1)
    descriptor.write_text(text, encoding="utf-8")
    print(f"Windows extension: {DLL} (PE x86-64 verified)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    pin(parser.parse_args().root)
