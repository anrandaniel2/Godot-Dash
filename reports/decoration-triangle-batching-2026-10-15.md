# Decoration triangle-array aggregation — rejected 2026-10-15

## Outcome

The indexed triangle-array candidate in `NativeDecorationRenderer::rebuild_commands()` was
reverted and is **not** the production rendering path. The active renderer uses ordered
`canvas_item_add_texture_rect_region` commands with `clip_uv=true`, retaining Godot's atlas
sampling behavior, blend routing, transforms, pulse/tint, UI layout, culling, draw order, and
spin behavior. No batching, draw-call, or FPS gain is claimed for the reverted candidate.

## Failure evidence

Android Mobile run `38819120173` reported:

```text
NATIVE_TRIANGLE_PARITY pixels=9216 mismatches=11 covered=167/167
max_delta=0.219608 at (54,55)
```

The first mismatch was `(58,42)`; both screenshots covered all 167 expected pixels. The
reference path was `canvas_item_add_texture_rect_region(..., clip_uv=true)`. Godot clamps the
fragment UV to half a texture pixel inside the source region. `canvas_item_add_triangle_array`
does not expose this rectangle flag, and the candidate passed edge UVs through unchanged,
allowing samples outside the intended atlas region. The run then reported leaked CanvasItem
RIDs/ObjectDB objects and segfaulted during teardown. Diagnostics are not evidence of parity.

The implementation was reverted to the clipped rectangle path rather than weakening the pixel
tolerance or accepting visual differences. `tools/runtime_visual_smoke_test.gd` retains a
reference-image smoke check for the active native renderer; `tools/renderer_cache_selftest.gd`
now checks ordered rect submissions and blend routing rather than triangle batching.

## Historical scope (not a current result)

A synthetic test had expected 256 same-texture records to become one triangle-array command,
which would have been a 99.6% reduction in calls to the RenderingServer API. That expectation
was never an actual driver draw-call or GPU/FPS measurement, and it is no longer a valid current
renderer result. The Godot canvas backend's own batching behavior was not measured. A future
aggregation approach must reproduce clip-UV semantics and pass real-renderer pixel parity on
the target renderer before it can replace the current path.
