#!/usr/bin/env python3
"""Let the pinned godot-cpp build wasm64 web GDExtensions.

godot-cpp 6cceaf6 accepts only wasm32 on the web. The engine template used by
the web export is built as wasm64, and a side module must use the same memory
model to load into it. This script makes three exact edits and refuses to run
if any anchor is missing, so a godot-cpp bump fails loudly instead of silently
building wasm32.

usage: godot_cpp_wasm64.py <path to godot-cpp checkout>
"""

import pathlib
import sys


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
    path.write_text(text.replace(old, new))
    print(f"patched {path}: {old.strip()[:60]!r}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = pathlib.Path(sys.argv[1])
    replace_once(
        root / "tools/godotcpp.py",
        '    "wasm32",\n]',
        '    "wasm32",\n    "wasm64",\n]',
    )
    replace_once(
        root / "tools/web.py",
        'if env["arch"] not in ("wasm32"):',
        'if env["arch"] not in ("wasm32", "wasm64"):',
    )
    replace_once(
        root / "tools/web.py",
        '    env.Append(LINKFLAGS=["-sWASM_BIGINT"])\n',
        '    env.Append(LINKFLAGS=["-sWASM_BIGINT"])\n\n'
        '    # 64-bit linear memory. Must match the engine template exactly.\n'
        '    if env["arch"] == "wasm64":\n'
        '        env.Append(CCFLAGS=["-sMEMORY64=1"])\n'
        '        env.Append(LINKFLAGS=["-sMEMORY64=1"])\n',
    )


if __name__ == "__main__":
    main()
