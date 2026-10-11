#!/usr/bin/env python3
"""Print a text file as chunked ::notice annotations (readable from the API).

Usage: gd_annotate.py TITLE FILE [CHUNK_CHARS]
"""

import sys


def esc(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


def main(argv: list) -> int:
    title, path = argv[1], argv[2]
    size = int(argv[3]) if len(argv) > 3 else 3500
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    for index in range(0, max(len(text), 1), size):
        part = index // size
        print(f"::notice title={title} {part}::" + esc(text[index:index + size]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
