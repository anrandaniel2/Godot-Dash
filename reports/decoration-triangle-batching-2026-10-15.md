# Decoration triangle-array batching — 2026-10-15

## Goal and change

The retained native decoration renderer previously emitted one texture-rectangle command
per visible sprite. `NativeDecorationRenderer::rebuild_commands()` now bakes each sprite's
current transform into four vertices and emits one indexed `canvas_item_add_triangle_array`
per consecutive run of the same texture on each blend-target canvas RID. Vertices carry the
sprite's normalized atlas UVs and repeated per-vertex modulation color.

This reduces RenderingServer canvas command construction and gives the canvas renderer a
single geometry command for a whole same-texture run rather than transform/texture-rect
commands for each sprite. It is batching, not hardware instancing. It preserves each
sprite's content and current transforms, colors, pulse/tint, culling selection, draw order,
blend routing, UI layout, and spin state. It does not reorder texture runs or records. The
GDScript fallback is unchanged. No compute shader was introduced: the rendering work here
is sprite geometry/texture sampling, not a demonstrated parallel compute bottleneck; a
compute path would also require a behavior-identical WebGL/GLES fallback and careful
synchronization.

## Synthetic gate

`tools/renderer_cache_selftest.gd` now configures 256 sprite records with the same texture
and checks that all 256 remain submitted while `draw_commands_last_rebuild()` reports one
triangle-array canvas command. That fixture corresponds to 256-to-1 (99.6%) fewer
RenderingServer commands. It also checks different transforms share a batch without being
equalized, near-equal geometry stays distinct, and a separate additive target receives its
own batch. These are assertions added to the engine test; the Godot executable is not
available in this workspace, so the fixture has **not run** here. Do not report its expected
ratio as a completed runtime measurement.

The command counter measures calls handed to RenderingServer—not backend driver draw calls,
GPU frame time, or FPS. Because array geometry must be baked and copied, CPU-side rebuild
time and allocation cost also need profiling. A real-renderer SubViewport pixel-comparison test has been added to
`tools/runtime_visual_smoke_test.gd`; it covers atlas regions, translucent overlap, rotated,
nonuniform-scaled and sheared transforms against the legacy texture-rect path. That engine
test is not available to execute here, so actual pixel parity and runtime behavior remain
unverified.

## Verification and limits

- Linux x86-64 release native GDExtension compiled and linked against pinned Godot 4.7
  godot-cpp after the change.
- The `canvas_item_add_triangle_array` generated Godot binding signature is available and
  compiles with the implementation.
- No Godot runtime is installed here: `tools/renderer_cache_selftest.tscn`, visual/pixel
  parity, Windows CI, WebGL/GLES, WebGPU, Android Mobile, GPU captures, real-level frame
  time, and device FPS have not run.
- Need parity coverage for rotated/scaled sprites, atlas UVs, translucent overlap and all
  blend/material paths before relying on this as visually equivalent. Need same-device
  before/after profiling with representative levels to determine whether CPU/GPU time
  actually improves. Roll back or gate this path if parity fails or end-to-end timing loses.
- The previous exact-transform-state coalescing report is historical and superseded by this
  implementation. It did not claim measured FPS.

## Changed files

- `native/src/gdash_native.cpp`
- `tools/renderer_cache_selftest.gd`
- `tools/runtime_visual_smoke_test.gd`
- `docs/agent-briefing/06-native-extension.md`
- `docs/agent-briefing/09-conventions-invariants-verification.md`
- This report

No commit or push performed. Unrelated working-tree changes were left intact.
