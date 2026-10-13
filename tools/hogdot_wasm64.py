#!/usr/bin/env python3
"""Raise the memory ceiling of the pinned hogdot engine template to 16 GB.

hogdot's platform/web/detect.py appends -sWASM_MEM_MAX=2048MB for threaded
builds. That flag is applied after the command-line linkflags, so
-sMAXIMUM_MEMORY=16GB is silently overridden and the shared memory maximum
stays at 2 GiB. This script replaces that exact line and refuses to run if the
line is missing, so a hogdot bump fails loudly.

usage: hogdot_wasm64.py <path to hogdot checkout>
"""

import pathlib
import sys

OLD = 'env.Append(LINKFLAGS=["-sWASM_MEM_MAX=2048MB"])'
NEW = 'env.Append(LINKFLAGS=["-sWASM_MEM_MAX=16GB"])'


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    path = pathlib.Path(sys.argv[1]) / "platform/web/detect.py"
    text = path.read_text()
    count = text.count(OLD)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {OLD!r}")
    path.write_text(text.replace(OLD, NEW))
    print(f"patched {path}: WASM_MEM_MAX 2048MB -> 16GB")


if __name__ == "__main__":
    main()
