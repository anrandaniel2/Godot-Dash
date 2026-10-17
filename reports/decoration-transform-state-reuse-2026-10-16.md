# Exact transform-state reuse in decoration rendering — 2026-10-16

## Change

`NativeDecorationRenderer::rebuild_commands()` now skips a redundant
`canvas_item_add_set_transform` when the immediately preceding texture-rectangle
command on the **same CanvasItem RID** used a bit-for-bit equal `Transform2D`.
The inherited, normal-override, and additive-override RIDs each have independent
state. State is reset on every rebuild; UI-layout transforms are compared after
being computed. NaN values compare unequal and therefore conservatively emit state.

Every clipped `canvas_item_add_texture_rect_region` remains in its original order,
with the same texture, region, color, pulse, blend route, and transform. No sorting,
geometry, culling, visibility, gameplay, timing, or pixel content is changed. This
is a CPU-side RenderingServer command reduction candidate; possible GPU/backend
batching effects have not been measured.

## Instrumentation and tests added

- `NativeDecorationRenderer.transform_commands_last_rebuild()` counts emitted
  transform-state commands beside the existing rectangle-command count.
- `NativeLevelRuntime.render_stats()` reports aggregate rectangle commands,
  transform commands, and the difference from the one-transform-per-rectangle
  baseline. These counters are API submission counts, not GPU draw calls.
- The native renderer self-test asserts: `A,A,B,A` emits four rectangle commands
  and three transform commands; a near-equal edit is not coalesced; 256 distinct
  transforms retain 256 state commands; three equal transforms split across two
  blend RIDs use two independent states.
- The runtime visual smoke gate checks counter consistency while retaining its
  existing reference-renderer visual comparison.

## Verification run here

- Full Linux x86-64 release GDExtension compiled and linked against the pinned
  godot-cpp commit `6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918`, Godot API 4.7,
  `lto=none` after this change.
- SDK-free native suites: visibility cache **8,411 checks**, UI alignment,
  decoration spin, spin cache **7,380,199 checks**, compact sections **15,052
  checks**, and frustum transition ranges **108,004 checks** all passed.
- Both modified GDScript test files passed `gdparse` and `gdformat --check`;
  `git diff --check` passed for the scoped files.
- Godot runtime tests and a real-level profile could not run locally. The Godot
  download redirects to a release-assets host blocked by this sandbox. No real-level
  CPU-time, GPU-time, FPS, or physical-device improvement is claimed.

## Scope / next measurement

The test fixture's deliberate `A,A,B,A` sequence saves one of four transform
commands (25% for that fixture only). It is not a real-level hit rate. Use the new
`NATIVE_RENDER_STATS` fields from the visual/runtime smoke on actual level content,
then compare frame CPU and GPU timings under the same renderer/device/build before
making a performance claim. Existing Windows Forward+, Android Mobile, and Web
WebGPU/WebGL2 parity gates remain required.

No commit or push performed. The repository's pre-existing dirty work was preserved.
