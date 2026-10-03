#!/usr/bin/env python3
"""Point the Web export preset at hogdot's threaded WebGPU templates.

Official Godot's web templates are WebGL. The shipping HTML5 build uses the
hogdot editor, which reads custom_template/debug and custom_template/release
from preset.3 (the Web preset). Other presets are left alone.
"""

import pathlib
import re
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: pin_webgpu_templates.py <debug.zip> <release.zip>")
    debug = str(pathlib.Path(sys.argv[1]).resolve())
    release = str(pathlib.Path(sys.argv[2]).resolve())
    for label, path in (("debug", debug), ("release", release)):
        if not pathlib.Path(path).is_file():
            raise SystemExit(f"{label} template is not a file: {path}")

    preset = pathlib.Path("export_presets.cfg")
    text = preset.read_text()
    marker = "[preset.3.options]"
    start = text.index(marker)
    end = text.find("\n[", start + 1)
    if end < 0:
        end = len(text)
    section = text[start:end]
    if "custom_template/debug=" not in section or "custom_template/release=" not in section:
        raise SystemExit("Web preset is missing custom_template paths")
    section = re.sub(
        r'custom_template/debug="[^"]*"',
        f'custom_template/debug="{debug}"',
        section,
        count=1,
    )
    section = re.sub(
        r'custom_template/release="[^"]*"',
        f'custom_template/release="{release}"',
        section,
        count=1,
    )
    preset.write_text(text[:start] + section + text[end:])
    print(f"Web debug template:   {debug}")
    print(f"Web release template: {release}")


if __name__ == "__main__":
    main()
