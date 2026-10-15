#!/usr/bin/env python3
"""Use the verified release side module for Web exports and preset validation.

Workspace-only staging, like pin_windows_extension.py. No debug library is built
or renamed: every existing Web selector explicitly points to the release file.
"""
from pathlib import Path
import re

LIBRARY = "libgdash_native.web.template_release.wasm64.wasm"


def pin(root: Path) -> None:
    library = root / "native/bin/web" / LIBRARY
    with library.open("rb") as stream:
        if stream.read(8) != b"\0asm\x01\0\0\0":
            raise ValueError("Missing/invalid release WebAssembly side module")
    descriptor = root / "native/bin/gdash_native.gdextension"
    text = descriptor.read_text(encoding="utf-8")
    text, count = re.subn(r'^web\.[^=\n]+=[^\n]+$',
                         lambda m: m[0].split('=')[0] + f'= "./web/{LIBRARY}"',
                         text, flags=re.MULTILINE)
    if count == 0:
        raise ValueError("No Web selectors found")
    descriptor.write_text(text, encoding="utf-8")
    print(f"Web release staging: {count} selectors -> {LIBRARY}")


if __name__ == "__main__":
    pin(Path(__file__).resolve().parents[1])
