# Godot lossless texture import policy — 2026-10-15

## Finding and correction of scope

Godot decodes source PNGs and writes imported `.ctex` resources. Compressing the source PNG stream does **not** establish an equivalent saving in the imported resource, exported game, or GPU memory. The prior reports' 4,800,192-byte combined saving remains a **source-file** measurement only.

The current checkout already had **417 game Texture2D imports under `assets/`, all with `compress/mode=0` (Lossless)** and `process/size_limit=0`. None needed conversion from lossy to lossless. However, all 417 still had `detect_3d/compress_to=1`: Godot may automatically change these to VRAM compression and enable mipmaps if detected in 3D. That automatic switch is now disabled.

Godot's Lossless mode normally stores lossless WebP inside CTEX, or PNG when required/selected. `CompressedTexture2D` is a resource class, not a guarantee of lossless compression: the same class also supports lossy and VRAM-compressed modes. WebP storage likewise needs its actual codec checked: VP8L is lossless; VP8 is lossy.

Lossless disk compression is decoded for GPU use. It does **not** give BC/ETC/ASTC-style VRAM/bandwidth savings, and it does not by itself establish better FPS. Compression may trade storage/I/O against load-time decode cost. No new build-size, load-time, memory, or FPS improvement is claimed here.

## Changes

- **417 `assets/**/*.import` files:** changed only `detect_3d/compress_to=1` to `0`. Existing Lossless mode, UIDs, paths, dimensions, alpha/channel processing, and mipmap settings are untouched. The existing mipmap split remains 319 disabled / 98 enabled.
- **`project.godot`:** added `importer_defaults/texture` with `compress/mode=0` and `detect_3d/compress_to=0`, protecting newly imported textures. Clarified the Android ETC2/ASTC capability comment without changing its value. This flag does not override per-texture lossless import mode.
- **`tools/build_godot_atlas.py`:** the import template now emits disabled automatic 3D conversion, so regeneration preserves the policy. No atlas repack, scene regeneration, or art changes were performed.
- **`tools/check_texture_compression.py`:** stdlib-only settings audit; optional `--imported` inspects the real generated CTEX files referenced by game imports. Requires PNG or VP8L lossless WebP for every mip level; rejects raw/VRAM/BasisU storage, lossy/animated WebP, stale auto-3D flags, missing files and malformed container bounds. Logs imported byte totals for future comparisons. This is a codec/header audit, not a pixel decoder.
- **`tools/test_production_build.py`:** nine texture-policy/container regression tests added to the five existing production tests. Uses real one-pixel PNG/lossless-WebP/lossy-WebP payloads in synthetic CTEX containers, including negative and mixed-mipmap cases.
- **`.github/workflows/main.yml`, `.github/workflows/web.yml`, `tools/windows_ci.py`:** added the `--imported` gate after successful Godot import and before export. Existing platform workflows already run the production test suite. No engine/template changes, template cache-key changes, export preset changes, or renderer/architecture changes.
- **Briefing files 07 and 09:** documented the policy, actual-codec guard, and source/import/export/GPU distinction.

Scope: game Texture2D imports under `assets/`. Intentional keep/skip SVGs, non-texture imports, and vendored editor addon icons are not converted. Newly generated game import sidecars are included by the post-import audit. Fonts/audio/source art and prior optimization audit files remain unchanged.

## Verification executed locally

- `python3 tools/check_texture_compression.py`: **417 texture imports PASS**. Source-settings mode intentionally reports zero inspected CTEX files; it is not an exported-texture verification.
- `python3 -m unittest discover -s tools -p test_production_build.py`: **14 PASS**.
- `python3 -m unittest discover -s tools -p test_windows_export.py`: **12 PASS**.
- `PYTHONPATH=/home/user/.cache/gdash-compression/python python3 -m unittest discover -s tools -p test_lossless_assets.py`: **16 PASS**.
- `python3 tools/font_bundle.py --check`: **123 files / 10,614,772 bytes PASS**.
- Compared all 417 sidecars with a pre-edit snapshot: **only the automatic-3D field changed**.
- Checked SHA-256 of all **223** previously optimized source assets against `lossless-assets-deep-2026-10-15.json`: **all match**.
- Changed Python files compiled; scoped whitespace checks passed. Workflow indentation reviewed; no YAML parser was installed locally.

## Pending verification

There is no local Godot executable. No real reimport, generated-CTEX audit, export, device/GPU test, or package-size comparison was run. The new post-import CI gates are wired but **not executed in CI for these local edits**. They inspect generated cache resources, not the final PCK/APK; final package size and runtime performance still need measurement. No commit or push performed.

After a Godot import:

```bash
python3 tools/check_texture_compression.py --imported
```

A future size comparison should use the same engine, preset, source content, and build environment and compare imported CTEX totals plus final exported package sizes—not PNG source sizes.

## Engine implementation consulted

Read directly from the pinned Godot 4.7.2 source via GitHub API:

- [Texture importer](https://github.com/godotengine/godot/blob/4.7.2-stable/editor/import/resource_importer_texture.cpp): automatic 3D mode rewrite; lossless PNG/WebP packing; GST2 header and mip layout.
- [Compressed texture format](https://github.com/godotengine/godot/blob/4.7.2-stable/scene/resources/compressed_texture.h): version 1, data-format enum and automatic-3D flag.
- [WebP packer](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/webp/webp_common.cpp): lossless mode sets `lossless=1`, `exact=1`, and writes the RIFF WebP payload.
- [Editor filesystem importer](https://github.com/godotengine/godot/blob/4.7.2-stable/editor/file_system/editor_file_system.cpp): applies `importer_defaults/<importer>` for new/default imports.
