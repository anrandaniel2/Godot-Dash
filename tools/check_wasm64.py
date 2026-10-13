#!/usr/bin/env python3
"""Check that wasm files use 64-bit memory and report the memory limits.

Reads the binary import section of each file (no external tools) and prints
the memory import's flags, minimum and maximum. A file passes only when its
memory import is a memory64 type whose maximum is above the wasm32 ceiling of
4 GiB, so a 4 GB build cannot pass as wasm64.

usage: check_wasm64.py <file.wasm> [more.wasm ...]
"""

import pathlib
import sys

PAGE = 65536
WASM32_MAX_PAGES = 65536  # 4 GiB


def read_leb(data: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return result, pos


def read_name(data: bytes, pos: int) -> tuple[str, int]:
    length, pos = read_leb(data, pos)
    return data[pos:pos + length].decode("utf-8", "replace"), pos + length


def read_limits(data: bytes, pos: int) -> tuple[int, int | None, int, int]:
    flags = data[pos]
    pos += 1
    minimum, pos = read_leb(data, pos)
    maximum = None
    if flags & 0x01:
        maximum, pos = read_leb(data, pos)
    return flags, maximum, minimum, pos


def memory_imports(path: pathlib.Path) -> list[tuple[str, str, int, int | None, int]]:
    data = path.read_bytes()
    if data[:4] != b"\0asm":
        raise SystemExit(f"{path}: not a wasm binary")
    pos = 8
    found = []
    while pos < len(data):
        section_id = data[pos]
        size, body = read_leb(data, pos + 1)
        end = body + size
        if section_id == 2:
            count, p = read_leb(data, body)
            for _ in range(count):
                module, p = read_name(data, p)
                field, p = read_name(data, p)
                kind = data[p]
                p += 1
                if kind == 0:  # function: type index
                    _, p = read_leb(data, p)
                elif kind == 1:  # table: reftype + limits
                    p += 1
                    _, _, _, p = read_limits(data, p)
                elif kind == 2:  # memory: limits
                    flags, maximum, minimum, p = read_limits(data, p)
                    found.append((module, field, flags, maximum, minimum))
                elif kind == 3:  # global: valtype + mutability
                    p += 2
                elif kind == 4:  # tag: attribute + type index
                    p += 1
                    _, p = read_leb(data, p)
                else:
                    raise SystemExit(f"{path}: unknown import kind {kind}")
        pos = end
    return found


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    failed = False
    for name in sys.argv[1:]:
        path = pathlib.Path(name)
        memories = memory_imports(path)
        if not memories:
            print(f"::notice::{path}: no memory import (ok for side modules)")
            continue
        for module, field, flags, maximum, minimum in memories:
            is_64 = bool(flags & 0x04)
            max_bytes = None if maximum is None else maximum * PAGE
            print(
                f"::notice::{path}: import {module}.{field} memory64={is_64} "
                f"min={minimum * PAGE / 2**20:.0f} MiB "
                f"max={'none' if max_bytes is None else f'{max_bytes / 2**30:.2f} GiB'}"
            )
            if not is_64 or maximum is None or maximum <= WASM32_MAX_PAGES:
                print(
                    f"::error::{path}: memory import {module}.{field} is not a "
                    f"wasm64 memory above 4 GiB (flags=0x{flags:02x}, "
                    f"min_pages={minimum}, max_pages={maximum})"
                )
                failed = True
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
