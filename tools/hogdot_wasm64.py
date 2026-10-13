#!/usr/bin/env python3
"""Make the pinned hogdot engine template correct for wasm64.

Two patches, both refusing to run when the pinned source does not match:

1. platform/web/detect.py: hogdot appends -sWASM_MEM_MAX=2048MB for threaded
   builds. That flag is applied after the command-line linkflags, so
   -sMAXIMUM_MEMORY=16GB is silently overridden. The line is replaced.

2. platform/web/js/libs/*.js: under wasm64 every C pointer is a 64-bit value.
   Emscripten hands a 64-bit argument to a JS library function as a BigInt
   unless the function's __sig says 'p' (pointer), in which case it converts it
   to a Number first. Godot's libraries were written for wasm32 and declare
   every pointer as 'i', so the first pointer arithmetic in JS throws
   "Cannot mix BigInt and other types". This rewrites each __sig so a letter is
   'p' exactly where the C prototype in platform/web/*.h has a pointer, a
   function pointer or an array. Argument counts must match the prototype, and
   every JS function with a __sig must have a prototype, or the script stops.

usage: hogdot_wasm64.py <path to hogdot checkout>
       hogdot_wasm64.py --dry-run <path to hogdot checkout>   (report only)
"""

import pathlib
import re
import sys

OLD = 'env.Append(LINKFLAGS=["-sWASM_MEM_MAX=2048MB"])'
NEW = 'env.Append(LINKFLAGS=["-sWASM_MEM_MAX=16GB"])'

SIG_RE = re.compile(r"^(\s*)([A-Za-z_]\w*)__sig:\s*'([a-zA-Z]+)',?\s*$", re.MULTILINE)
PROTO_RE = re.compile(r"^[ \t]*(?:extern[ \t]+)?([A-Za-z_][\w \t*]*?)[ \t*]*\b(\w+)\s*\(([^;{}]*?)\)\s*;", re.M)


def patch_detect(root: pathlib.Path) -> None:
    path = root / "platform/web/detect.py"
    text = path.read_text()
    count = text.count(OLD)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {OLD!r}")
    path.write_text(text.replace(OLD, NEW))
    print(f"patched {path}: WASM_MEM_MAX 2048MB -> 16GB")


def split_params(text: str) -> list[str]:
    """Splits a C parameter list on top-level commas (function pointers nest)."""
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current.strip())
    # Default arguments (int p = -1) do not change the type.
    parts = [p.split("=")[0].strip() for p in parts]
    return [p for p in parts if p not in ("", "void")]


TYPEDEF_RE = re.compile(r"typedef\s+([^;]+?)\s+(\w+)\s*(\[[^\]]*\])?\s*;")


def load_typedefs(root: pathlib.Path) -> dict[str, str]:
    """typedef name -> the C type it declares; array typedefs become pointers."""
    typedefs: dict[str, str] = {}
    for header in sorted((root / "platform/web").rglob("*.h")):
        for match in TYPEDEF_RE.finditer(re.sub(r"//[^\n]*", "", header.read_text(errors="replace"))):
            base, name, array = match.group(1), match.group(2), match.group(3)
            typedefs[name] = base + (" *" if array else "")
    return typedefs


def is_pointer(decl: str, typedefs: dict[str, str]) -> bool:
    if "*" in decl or "[" in decl or "(*" in decl:
        return True
    words = re.findall(r"[A-Za-z_]\w*", decl)
    return any(w in typedefs and is_pointer(typedefs[w], {}) for w in words)


def letter(decl: str, typedefs: dict[str, str]) -> str:
    """Emscripten signature letter for one C parameter or return type."""
    if is_pointer(decl, typedefs):
        return "p"
    words = set(re.findall(r"[A-Za-z_]\w*", decl))
    if "void" in words:
        return "v"
    if "double" in words:
        return "d"
    if "float" in words:
        return "f"
    if words & {"int64_t", "uint64_t", "long", "size_t"}:
        return "j"
    return "i"


def load_prototypes(root: pathlib.Path) -> dict[str, tuple[str, list[str]] | None]:
    """name -> (signature letters: return then parameters, from the C prototype)."""
    typedefs = load_typedefs(root)
    protos: dict[str, tuple[str, list[str]]] = {}
    for source in sorted([*(root / "platform/web").rglob("*.h"), *(root / "platform/web").rglob("*.cpp")]):
        text = source.read_text(errors="replace")
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        text = re.sub(r"//[^\n]*", "", text)
        for match in PROTO_RE.finditer(text):
            ret, name, params = match.group(1), match.group(2), match.group(3)
            if set(re.findall(r"\w+", ret)) & {"return", "else", "case", "new", "delete", "throw", "goto"}:
                continue  # a call statement, not a declaration
            args = [letter(p, typedefs) for p in split_params(params)]
            found = (letter(ret, typedefs), args)
            if name in protos and protos[name] != found:
                # Another declaration (for example a class method) shares the
                # name. Only a name a JS library needs is an error.
                protos[name] = None
                continue
            protos.setdefault(name, found)
    return protos


def retype(root: pathlib.Path, dry_run: bool) -> int:
    protos = load_prototypes(root)
    changed = 0
    for js in sorted((root / "platform/web/js/libs").glob("*.js")):
        text = js.read_text()
        problems: list[str] = []

        def rewrite(match: re.Match) -> str:
            nonlocal changed
            name, sig = match.group(2), match.group(3)
            if protos.get(name) is None:
                problems.append(f"{name}: no unambiguous prototype in platform/web")
                return match.group(0)
            ret, args = protos[name]
            # Pointers always become 'p'. Every other letter keeps the JS
            # signature's letter (so wasm32 behaviour is unchanged); only a
            # position the JS signature lacks takes the C-derived letter.
            old = sig + "?" * (len(args) + 1 - len(sig))
            new = ("p" if ret == "p" else old[0]) + "".join(
                "p" if c == "p" else (old[i + 1] if old[i + 1] != "?" else c)
                for i, c in enumerate(args)
            )
            if new == sig:
                return match.group(0)
            print(f"  {js.name}: {name} '{sig}' -> '{new}'")
            changed += 1
            return match.group(0).replace(f"'{sig}'", f"'{new}'")

        new_text = SIG_RE.sub(rewrite, text)
        if problems:
            raise SystemExit(f"{js}: " + "; ".join(problems))
        if new_text != text and not dry_run:
            js.write_text(new_text)
    return changed


# Exact replacements in hogdot's runtime helpers (library_godot_runtime.js).
# Under memory64 the wasm exports _malloc/_free and the i64 heap accessors take
# and return BigInt, and pointers in arrays are 8 bytes. Each old text must
# match exactly once or the script stops.
RUNTIME_PATCHES = [
    ("return _malloc(p_size);",
     "return Number(_malloc(BigInt(p_size)));"),
    ("_free(p_ptr);",
     "_free(BigInt(p_ptr));"),
    ("return getValue(p_ptr, p_type);",
     "const value = getValue(p_ptr, p_type);\n\t\t\treturn typeof value === 'bigint' ? Number(value) : value;"),
    ("setValue(p_ptr, p_value, p_type);",
     "setValue(p_ptr, p_type === '*' || p_type === 'i64' ? BigInt(p_value) : p_value, p_type);"),
    ("const ptrs = GodotRuntime.heapSub(HEAP32, p_ptr, p_size); // TODO wasm64",
     "const ptrs = [];\n\t\t\tfor (let i = 0; i < p_size; i++) {\n\t\t\t\tptrs.push(Number(getValue(p_ptr + i * 8, '*')));\n\t\t\t}"),
    ("const c_ptr = GodotRuntime.malloc(size * 4);",
     "const c_ptr = GodotRuntime.malloc(size * 8);"),
    ("HEAP32[(c_ptr >> 2) + i] = GodotRuntime.allocString(p_strings[i]);",
     "setValue(c_ptr + i * 8, BigInt(GodotRuntime.allocString(p_strings[i])), '*');"),
    # Function tables are 64-bit too: a function pointer is a BigInt index.
    ("return wasmTable.get(ptr);",
     "return wasmTable.get(BigInt(ptr));"),
]


# EM_ASM_PTR bodies return pointers. Under memory64 the JS side must return a
# BigInt, so plain Number results are converted (0 is 0n). importJsDevice's
# default parent (parentPtr=0) is a Number that the 64-bit exports reject, so
# the parent is passed explicitly as 0n.
EM_ASM_PATCHES = [
    ("drivers/webgpu/rendering_context_driver_webgpu.cpp",
     "if (!d) {\n\t\t\treturn 0;\n\t\t}\n\t\treturn WebGPU[\"importJsDevice\"](d);",
     "if (!d) {\n\t\t\treturn 0n;\n\t\t}\n\t\treturn BigInt(WebGPU[\"importJsDevice\"](d, 0n));"),
    ("drivers/webgpu/rendering_context_driver_webgpu.cpp",
     "if (!info) {\n\t\t\treturn 0;\n\t\t}",
     "if (!info) {\n\t\t\treturn 0n;\n\t\t}"),
    ("drivers/webgpu/rendering_context_driver_webgpu.cpp",
     "return stringToNewUTF8(joined);",
     "return BigInt(stringToNewUTF8(joined));"),
]


def patch_em_asm(root: pathlib.Path) -> None:
    for name, old, new in EM_ASM_PATCHES:
        path = root / name
        text = path.read_text()
        count = text.count(old)
        if count != 1:
            raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
        path.write_text(text.replace(old, new))
    print(f"patched {len(EM_ASM_PATCHES)} EM_ASM pointer returns")


def patch_runtime(root: pathlib.Path) -> None:
    path = root / "platform/web/js/libs/library_godot_runtime.js"
    text = path.read_text()
    for old, new in RUNTIME_PATCHES:
        count = text.count(old)
        if count != 1:
            raise SystemExit(f"{path}: expected one match, found {count}: {old!r}")
        text = text.replace(old, new)
    path.write_text(text)
    print(f"patched {path}: {len(RUNTIME_PATCHES)} memory64 runtime helpers")


def main() -> None:
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    root = pathlib.Path(args[0])
    if not dry_run:
        patch_detect(root)
        patch_runtime(root)
        patch_em_asm(root)
    changed = retype(root, dry_run)
    print(f"{'would retype' if dry_run else 'retyped'} {changed} JS signatures for wasm64 pointers")
    if changed == 0:
        raise SystemExit("no JS signatures changed: the pinned hogdot source no longer matches")


if __name__ == "__main__":
    main()
