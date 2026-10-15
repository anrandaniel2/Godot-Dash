# Lossless asset compression — 2026-10-15

## Applied changes

Optimized the runtime PNG sources and compacted the three runtime JSON tables.
No runtime code, engine templates, export presets, import sidecars, asset paths,
texture dimensions, mipmaps, audio streams, physics or saved-data settings changed.
Pre-existing working-tree edits were left intact. This pass was not pushed/exported.

| Asset type | Scanned | Changed | Before (bytes) | After (bytes) | Saved |
| --- | ---: | ---: | ---: | ---: | ---: |
| PNG | 211 | 207 | 12,450,280 | 10,276,294 | 2,173,986 |
| JSON | 3 | 3 | 1,390,253 | 888,177 | 502,076 |
| **Total** | **214** | **210** | **13,840,533** | **11,164,471** | **2,676,062 (19.33%)** |

These are **source asset sizes**, not measured APK/PCK/installer reductions. Godot
already uses lossless texture imports and re-encodes source pixels into `.ctex`;
PNG source savings may therefore not carry into the exported textures. Runtime JSON
is included by the export filters, but ZIP/APK compression already removes much of
its redundancy. No FPS, VRAM or load-time improvement is claimed.

## Fidelity guarantees and verification

- PNG optimization changes only the IDAT image-data representation. All other chunks
  (including IHDR, palette, transparency, ICC/gamma/sRGB, text and other metadata)
  remain byte-identical and ordered. Color/depth/palette reductions and transparent
  RGB optimization are disabled. Candidates must independently decode to identical
  sample bytes before they can replace a source, and must be strictly smaller.
- Oxipng can trim redundant transparency bytes even with metadata stripping disabled.
  The tool therefore restores the original non-IDAT chunks rather than relying only
  on optimizer options. Independent verification rejects changed samples/metadata.
- JSON compaction removes only whitespace outside strings. Numeric token spelling,
  escapes, string whitespace, key order and all values are preserved; no numeric
  parse/re-serialization is used to produce the output.
- Checksum-pinned fonts and build-only atlas source sheets are excluded. Audio is
  untouched rather than transcoded. Existing `.import` UIDs/settings stay unchanged.
- All **214 assets** independently verified against Git baseline `58d3ede` using
  original bytes from `git show`: PNG decoded samples/metadata or JSON token equality.
  SHA-256 and per-file sizes are recorded in `lossless-assets-2026-10-15.json`.
- **11 tool regression tests PASS**, covering transparent RGB, indexed transparency,
  grayscale, metadata, malformed PNG/CRC, rejection of unsupported 16-bit/APNG,
  JSON token preservation, scope exclusions and concurrent-edit protection.
- `python3 tools/font_bundle.py --check`: **123 font files PASS**.
- Second full dry run: **zero candidates changed** (idempotent with pinned tools).
- Python compile and scoped whitespace checks PASS. No local Godot executable was
  available; new imports/platform exports and GPU rendering were not run.

## Reproduce

Install in a virtual environment, not in the game's dependencies:

```sh
python3 -m pip install -r tools/lossless_assets_requirements.txt
python3 -m unittest discover -s tools -p test_lossless_assets.py
python3 tools/optimize_lossless_assets.py           # dry run
python3 tools/optimize_lossless_assets.py --apply   # only verified smaller files
python3 tools/font_bundle.py --check
```

Optional `--report path.json` writes per-file hashes and sizes. Preserve the initial
report when measuring a fresh pass; a later run measures against the files as they
exist at that time. Unsupported formats fail closed, not silently downconvert.

Run this tool after regenerating atlas images/tables if desired. It is intentionally
**not added to every build**, avoiding repeated offline compression work in CI.
