# Historical: exact transform-command coalescing — 2026-10-15

> Historical only. Transform-state coalescing was superseded by the triangle-array candidate,
> which was subsequently reverted after the Android Mobile parity failure documented in
> `reports/decoration-triangle-batching-2026-10-15.md`. The active renderer restores the
> ordered texture-rectangle path; do not read this report as its current implementation.

## Goal and change

Focus: reduce main-thread CPU work in the renderer's per-frame draw-command rebuild path,
not another level-open or index-memory optimization.

`NativeDecorationRenderer::rebuild_commands()` used to issue a
`canvas_item_add_set_transform` for every visible sprite immediately before its texture
rect. It now tracks the last exact transform independently for each of the three canvas
RIDs (inherited, normal override, additive override) and emits that state command only
when the next sprite on that same RID has a different transform. First transform per RID
is always sent after clearing commands. **Every texture-rectangle command is still emitted**
in the exact original iteration order. Comparison is component-wise exact; near-equal
transforms are not merged. NaN components conservatively prevent merging.

This targets CPU-side RenderingServer command construction and can also allow better
canvas command batching when identical transform state no longer creates a barrier. The
potential benefit applies only to adjacent same-canvas sprites whose complete transforms
are identical. Distinct transforms, draw order, culling, colors, blending/materials, spin,
monster animation, group triggers and pixels are unchanged. No objects are removed or
hidden. No FMA/approximation or delta/tick change.

## Verification and measured scope

- Full current Linux x86-64 release GDExtension compiled and linked against the pinned
  godot-cpp, API 4.7, `lto=none` after the C++ change.
- `tools/renderer_cache_selftest.gd` now checks that four draw calls with transform pattern
  A, A, B, A still submit all four textures but issue **3 instead of 4** transform-state
  commands; a near-but-not-equal transform emits its own state, and blend-specific canvas
  RIDs maintain independent state. It prints
  `RENDERER_TRANSFORM_SUBMISSION draws=4 old_set=4 new_set=3 saved=1` when run.
- GDScript syntax parse and formatter passed; `git diff --check` passed.
- No Godot executable is available here: the native renderer scene, assertion marker,
  Windows CI gate, visuals and actual frame times have **not** run.

The 25% reduction above is only for the deliberately repeated-transform 4-sprite test
fixture. It is an exact command-count measurement, not an estimate for a real level.
Most ordinary single-sprite decorations will see no reduction; composite sprites that share
transforms may. A frame-time/FPS gain is **not yet demonstrated**. To evaluate actual
benefit, run `tools/renderer_cache_selftest.tscn` on Windows CI and profile a representative
level with `src/debug/PerformanceCapture.gd`, comparing same device, renderer, level, camera,
VSync and build before/after. The renderer scene is headless and does not prove GPU speed.

## Changed files

- `native/src/gdash_native.cpp`
- `tools/renderer_cache_selftest.gd`
- `docs/agent-briefing/06-native-extension.md`
- `docs/agent-briefing/09-conventions-invariants-verification.md`
- This report

No commit or push performed; existing unrelated working-tree changes were left intact.
