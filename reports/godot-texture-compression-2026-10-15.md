# Gameplay VRAM / UI lossy texture policy — 2026-10-15

## User-directed policy revision

The user explicitly requested VRAM compression for gameplay objects/atlases and lossy compression for UI. This **supersedes the previous lossless-only import policy**. The original PNG/SVG/JSON/plist source assets are not recompressed lossily or resized; Godot will encode the imported resources on reimport. Compression artifacts are now an accepted possibility, not a claim of pixel-identical output.

| Imported asset role | Count in current sidecars | Godot settings |
|---|---:|---|
| Gameplay artwork | **299** | `compress/mode=2` (VRAM Compressed), `compress/high_quality=false` |
| UI/editor artwork | **117** | `compress/mode=1` (Lossy), `compress/lossy_quality=0.9` |
| Particle-emission data mask | **1** | `compress/mode=0` (Lossless) |

**416 import sidecars changed in this request.** All 417 retain disabled automatic 3D conversion and zero size-limit downscaling. Existing mipmap flags, alpha processing, channel remapping, UIDs, asset paths, atlas layout, dimensions and scene geometry are unchanged. The retained mipmap split is 319 disabled / 98 enabled.

Per-file settings audit: `reports/godot-texture-compression-2026-10-15.json`.

## Classification and platform formats

`tools/check_texture_compression.py` is the shared assignment/checking policy:

- **VRAM:** packed `gd_atlas`, GD backgrounds/grounds/middlegrounds under `gd_art`, other backgrounds/grounds, checkpoints, hazards, solids, orbs, pads, portals, particles and imported player/effect/trail textures. Shared artwork used both in gameplay and palette previews stays in this category.
- **Lossy UI:** `guis`, `icons`, editor trigger glyphs, the ArrowedLine/Circle/Cross/Text editor helper graphics, logos and splash.
- **Lossless exceptions:** font bitmaps and particle-emission masks are glyph/placement data, not ordinary UI artwork. Source sheets under `.gdignore` remain excluded. The 123-file font source bundle is unchanged.
- **Untouched:** intentional keep/skip resources, vendored editor addon assets, runtime SVG recoloring/custom player icons, dynamically created textures and excluded source sheets. Runtime-colored player SVGs are deliberately loaded as source text; changing their importer to Texture2D would break that path. This pass targets Godot-imported textures, not a redesign of dynamic icon generation.
- Unknown texture categories fail the audit rather than receiving a guessed role. New textures use safe lossless defaults until their imported sidecars are assigned with `--apply`; generated font pages therefore remain lossless.

Both `textures/vram_compression/import_s3tc_bptc` and `import_etc2_astc` are enabled. With `compress/high_quality=false`, gameplay gets **S3TC/BC-family desktop variants and ETC2 mobile variants**, without requiring BC7/ASTC-only support. Web retains both desktop/mobile export variants, wasm64, threads, WebGPU-first and its existing GLES fallback. Windows remains Forward+; Android stays on its existing renderer/threading settings. No engine/template changes or template cache-key changes.

VRAM compression targets GPU storage and bandwidth. It is not a promise of higher FPS, and fixed-size blocks plus multiple platform variants can **increase download size** relative to compact lossless art. Actual memory, artifact size, appearance and performance remain unmeasured here.

## CPU image compatibility

The editor crops atlas regions and blends images for object thumbnails. `Image.get_region`, resize and blend operations cannot operate directly on GPU-compressed block data.

- Added **`src/static/TextureReadback.gd`** to decompress only a CPU image copy and normalize it to RGBA8 for blending. For AtlasTexture it decodes the parent before cropping, matching the engine's region-size handling.
- **`src/static/ObjectThumbnail.gd`** keeps its existing decoded-page cache, routes readback through the helper, and handles failed/empty images without attempting invalid crops/blends.
- **`src/LayeredSprite.gd`** prepares CPU images before compositing.
- Original Texture2D/AtlasTexture resources used for drawing remain compressed; no per-frame decompression path is introduced. The packed gameplay atlas loader already uses imported texture resources and did not need changes.

## Build checks and regeneration

- **`tools/build_godot_atlas.py`:** future generated page imports use mode 2, no automatic 3D conversion, and the existing no-mipmap setting. No atlas or object scenes were regenerated.
- **`tools/check_texture_compression.py`:** `--apply` assigns roles to existing sidecars; default invocation audits only. `--imported` requires real generated CTEX outputs and checks the role-specific payload: S3TC/ETC2 GPU formats and block/mipmap byte lengths for gameplay, lossy VP8 for UI, PNG/VP8L for lossless exceptions. Both gameplay platform variants are required; missing/stale files, raw uncompressed payloads, wrong codecs and mismatched variants fail.
- Existing post-import gates in **`.github/workflows/main.yml`, `.github/workflows/web.yml`, `tools/windows_ci.py`** now enforce the revised policy. Step/log names were updated from lossless-only terminology. No new automatic push/build was triggered.
- **`tools/test_production_build.py`:** updated policy tests and added role, UI quality, idempotence, GPU block/mipmap, family, variant and gate-wiring tests.
- **`tools/renderer_cache_selftest.gd`:** added CPU DXT1/ETC2 decompression/crop fixtures to the existing Windows headless test.
- **`tools/runtime_visual_smoke_test.gd`:** added real imported-atlas readback/crop, LayeredSprite blend and GD object thumbnail assertions to the existing visual test.
- Briefing files **05, 07, 09** now describe the revised policy rather than the superseded lossless-only rule. Prior reports/audits remain historical records.

## Local verification

- Settings audit: **417 imports PASS — 299 VRAM / 117 lossy UI / 1 lossless mask**.
- Applying the policy again changes **zero files**.
- Production tests: **20 PASS**; Windows packaging tests: **12 PASS**; lossless source-asset tests: **16 PASS** — **48 Python tests total**.
- Font manifest: **123 files / 10,614,772 bytes PASS**.
- Compared all changed sidecars with the pre-request snapshot: only `compress/mode` and UI `compress/lossy_quality` changed.
- All **223** optimized source assets still match their prior audit SHA-256 values.
- Five changed/new GDScript files parsed with gdtoolkit. This checks syntax, **not Godot type analysis or runtime execution**.
- Changed Python files compiled; modified workflow YAML and scoped whitespace checks verified.

## Still pending

No local Godot executable: **no real reimport/export, generated-CTEX inspection, new in-engine test execution, GPU/visual comparison, physical-device check, or performance/package-size measurement**. The generated remap/cache metadata in existing sidecars is intentionally left for Godot to regenerate; the post-import gate rejects stale lossless outputs. The new checks are wired into existing CI but have not run there for these edits. No commit or push performed.

Suggested verification order: fresh Godot import → `--imported` audit → existing renderer/visual smoke gates → Windows/Android/Web exports → inspect artwork (especially alpha edges, thin lines, gradients and atlas borders), GPU memory and frame times on target devices.

```bash
python3 tools/check_texture_compression.py              # settings only
python3 tools/check_texture_compression.py --apply      # assign existing sidecars
# After Godot reimport:
python3 tools/check_texture_compression.py --imported
```
