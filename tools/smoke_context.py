#!/usr/bin/env python3
"""Prints the generated JavaScript around each error position in a smoke log.

usage: smoke_context.py <index.js> <smoke.log>

The smoke test reports errors as "index.js:1:<column>" (V8 stack frames). The
column is a character offset into the single-line minified bundle, so the text
around it shows which generated code threw. Output is GitHub notices.
"""

import re
import sys


def main() -> None:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    log = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    seen: list[int] = []
    for match in re.finditer(r"index\.js:1:(\d+)", log):
        column = int(match.group(1))
        if column in seen or len(seen) >= 3:
            continue
        seen.append(column)
        snippet = text[max(0, column - 350): column + 150].replace("\n", " ")
        message = f"index.js col {column}: {snippet}".replace("%", "%25")
        print(f"::notice title=web smoke code::{message}")


if __name__ == "__main__":
    main()
