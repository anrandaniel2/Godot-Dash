# Additional lossless asset compression — 2026-10-15

## Result

This second pass saves **another 2,124,130 bytes (2.12 MB)** relative to the completed first pass, without changing decoded pixels, PNG metadata, atlas values, asset paths, import settings, or runtime loaders.

| Selected source assets | Scanned | Smaller this pass | Before this pass | After this pass | Additional saving |
|---|---:|---:|---:|---:|---:|
| Runtime PNGs | 211 | 197 | 10,276,294 B | 10,128,272 B | 148,022 B |
| Atlas JSON | 3 | 0 | 888,177 B | 888,177 B | 0 B |
| Atlas source plist metadata | 9 | 9 | 4,475,352 B | 2,499,244 B | 1,976,108 B |
| **Total** | **223** | **206** | **15,639,823 B** | **13,515,693 B** | **2,124,130 B** |

Across both passes, the **same expanded 223-file scope** shrinks from **18,315,885 B to 13,515,693 B**, saving **4,800,192 B (26.21%)**. The first report covered only 214 files; the nine newly included plist files explain the larger baseline here. This is not a percentage of the entire repository or exported game. Relative to Git HEAD, 221 selected asset files now differ; some files improved in both passes.

Audit: `reports/lossless-assets-deep-2026-10-15.json`. The first audit and report remain unchanged at `reports/lossless-assets-2026-10-15.{json,md}`. Work is on `arena/ce99f0ac-godot-dash`, based on HEAD `58d3ede`, with no commit or push performed for this request.

## Changes

- Extended `tools/optimize_lossless_assets.py` with `--png-level 0..6`, keeping its previous default of 2. Applied level 6 for a more extensive offline PNG filter/compression search. Retained only strictly smaller candidates.
- Preserved all existing PNG fidelity guards: no alpha optimization, palette/color-type/bit-depth/grayscale reductions, resizing, or 16-bit scaling. Only optimized IDAT data is used; all original non-IDAT chunks are retained byte-for-byte and in order. Pillow independently verifies decoded samples, including hidden RGB under transparent pixels.
- Added UTF-8 XML plist compaction using Expat byte offsets: delete only literal whitespace within `plist`, `dict`, and `array` containers. Preserve tag spelling, scalar contents, entity spellings, comments, declarations, CDATA, and `xml:space` preservation. Do not fetch external DTDs; reject custom entity declarations.
- Atlas source **PNGs remain excluded and unchanged**. Source **plists are explicitly included by export filters**, and their indentation can be removed without changing the fallback data. `GDSpriteSheet.gd` was inspected: its parser finds tags with `_next_tag` and reads scalar bodies directly. Neither that parser nor any asset generator was changed.
- Font bundles, audio, SVGs, import/export configuration, scenes, gameplay code, platform builds, saved-data contracts, and unrelated pre-existing edits were not changed by this pass.

## Verification

- **16 Python regression tests passed**, including level-6 pixel/metadata equality and fixture idempotence; plist scalar whitespace, numeric/entity spelling, comments/declarations, UTF-8/CRLF byte offsets, CDATA, `xml:space`, malformed XML and entity rejection; plus prior PNG/JSON/scope/concurrent-write guards.
- Independently checked **all 223 current files against their actual Git HEAD bytes**. Verified current sizes/SHA-256 against this audit and original sizes/SHA-256 against the first audit (or this audit for newly included plists). This pass's before hashes/sizes exactly match the first pass's after hashes/sizes for all 214 overlapping files.
- PNG decoded samples and non-IDAT metadata match HEAD; decoded sample hashes match the audit. JSON tokens match HEAD.
- All nine plists have identical `plistlib` values. Independent lexical comparisons confirm exact XML tag sequences and scalar bodies, including all **8,155 frame records**, their keys, rectangles, rotations, offsets, and entity spellings. Plist compaction is idempotent on all nine real files.
- The complete changed `assets/` path set equals the 221 audited files differing from HEAD: no other assets were changed.
- Font checksum check passed: **123 files / 10,614,772 bytes**.
- A complete **default level-2 dry run** after the stronger pass scanned all 223 files and proposed **zero changes**. This is not a second full level-6 run; level-6 idempotence was tested on a regression fixture only.
- Python compilation and scoped `git diff --check` passed.

## Reproduction

Dependencies are offline-tool-only; no new game dependency or runtime decompressor is needed.

```bash
python3 -m pip install --target /home/user/.cache/gdash-compression/python \
  -r tools/lossless_assets_requirements.txt
export PYTHONPATH=/home/user/.cache/gdash-compression/python
python3 -m unittest discover -s tools -p test_lossless_assets.py
python3 tools/font_bundle.py --check

# Dry run first. Level 6 can take several minutes on this asset set.
python3 tools/optimize_lossless_assets.py --png-level 6
# Apply only verified, smaller files; use a NEW report path to retain prior audits.
python3 tools/optimize_lossless_assets.py --png-level 6 --apply \
  --report reports/lossless-assets-next-pass.json
```

## Limits

These measurements are **source-file bytes**, not measured PCK/APK/installer/ZIP savings. Godot imports already use lossless compression and re-encode PNGs; outer archive compression can also absorb much of XML indentation. No Godot reimport, export, fallback-parser execution, GPU/device test, browser test, or package-size comparison was run locally. No FPS or runtime speedup is claimed. No change was made to engine compression, texture formats, display/renderer configuration, or unresolved platform issues.
