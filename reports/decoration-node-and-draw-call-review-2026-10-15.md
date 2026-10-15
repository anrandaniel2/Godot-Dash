# Decoration node / draw-call follow-up review — 2026-10-15

## Findings

- All frames in the currently generated runtime decoration atlas point to one packed page:
  `assets/textures/gd_atlas/gd_objects_atlas_0.png`. `gd_objects_atlas.json` lists one page.
  A second global atlas or texture array would not reduce atlas switches for this workload.
- Rendering is already implemented in C++ using retained RenderingServer canvas-item RIDs and
  indexed `canvas_item_add_triangle_array` batches. In the production packed-atlas path, a
  same-texture run is one RenderingServer geometry command per blend-target canvas. The last
  change's renderer counter records these API commands; it is not a GPU-driver draw-call count.
- Sprite nodes have already been eliminated. Decoration is represented by approximately
  800 `DecorationBatch` Node2D group proxies for a large ~170k-sprite level (repository
  architecture estimate), not one node per sprite. Those proxies are the current targets for
  group transforms and channel/pulse effects.
- A literal one-draw-call renderer cannot retain all current compositing: gameplay objects
  are interleaved with GD z-layers, and additive/normal material passes must remain separate.
  Texture-array shading would not remove these ordering/material boundaries and would add
  upload/memory work. The safe lower bound is one pass per contiguous compatible
  texture/material/z-order run, not one call for the whole level.
- PhysicsServer is not a substitute for DecorationBatch nodes: the static decoration records
  are not physics bodies. Migrating gameplay colliders to low-level server handles would be a
  separate high-risk physics change and is not included.

## Instrumentation

`NativeLevelRuntime.render_stats()` now includes `batch_owner_nodes` (unique CanvasItem owners),
`canvas_draw_commands` (last emitted indexed-array/rect commands summed across native
renderers), and existing renderer/record/culling counts. The native runtime visual smoke now
requires these counters to be populated. These metrics provide a real-level baseline when
run in Godot; they intentionally do not label RenderingServer calls as actual GPU draw calls.

## Decision / next step

No texture-array or global-atlas rewrite was made: the production object-art pipeline already
uses a single packed page, so it cannot reduce per-renderer texture runs. No node proxy was
removed yet: doing so requires replacing Node2D-based GD group targets with a native
transform/effect registry while preserving Move/Rotate/Scale/Alpha, channel, pulse, UI,
visibility, editor, streaming, and save behavior. That is the meaningful next node-count
experiment; it is larger than changing the atlas and needs real-engine visual, trigger, and
platform testing before replacing the working proxy path.

The current workspace has no Godot executable, so `render_stats()` and the new runtime checks
have not been executed here. No physical-device GPU call count or FPS claim follows from this
review.
