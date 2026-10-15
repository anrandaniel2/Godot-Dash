# 06 — Native GDExtension (`native/`)

## 1. Why it exists

The README is explicit: the optional GDExtension carries the hot paths that per-object GDScript
cannot — the packed trigger scheduler, the retained-RID decoration renderer with worker-thread
culling, the node visibility index, incremental level construction, shared-physics shape
commits and (since 1.10) colour-channel propagation. The intended contract is native/GDScript
parity, but the checkout does not currently guarantee a native-free gameplay build: `LevelBuildJob._init` directly instantiates
`NativeLevelBuildJob` outside the editor, and `GDDecorationLoader` directly instantiates
its packed builder/renderer. Do not mistake the contract below for verified fallback coverage.

## 2. The contract (memorize)

1. Native classes are reached **only** through `ClassDB.class_exists()` /
   `ClassDB.instantiate()` string lookups. A static type reference stops a script from parsing
   on builds without the library (e.g. desktop/editor builds).
2. The switch is `Config.use_native_core`.
3. `src/static/NativeCore.gd` wraps helper calls and logs a diagnostic once when the library
   is missing. Performance subsystems also instantiate native classes directly (see §1);
   not all calls go through this helper and not every helper has a complete fallback.
4. The web GDExtension is a wasm side module **bundled into the web export**. The web library
   is **wasm64** (`libgdash_native.web.template_release.wasm64.wasm`,
   CI stages all Web selectors to that release binary with `tools/pin_web_extension.py`);
   CI checks that the release file is present. A
   wasm32 library cannot load into the wasm64 engine template.
   Android bundles the arm64 `.so`; native-free desktop/source builds have the gaps noted in §1.
5. Every native-only behaviour needs a GDScript equivalent that stays correct.

### `NativeCore` API (with fallbacks)

| Function | Purpose |
| --- | --- |
| `backend()` | one-time `ClassDB.instantiate(&"GdashNative")`; emits a diagnostic print when unavailable |
| `available()` | `backend() != null` |
| `is_html_error_response(response)` | detect HTML error pages from level hosts |
| `extract_level_data_string(payload)` | pull the level string out of a raw response |
| `extract_level_sfx_ids(level_string)` | SFX ids used by a level (`PackedInt32Array`; GDScript fallback parses chunks) |
| `resolve_proxy_url(endpoint, proxy_prefix)` | CORS relay URL composition (allorigins/codetabs aware) |
| `is_cors_error(result, http_status, is_web)` | classify web fetch failures |
| `is_audio_stream(bytes, extension)` | sniff OGG/WAV/MP3 vs HTML error bodies before writing files |

## 3. Registered classes

`gdash_native_initialize()` registers (at `MODULE_INITIALIZATION_LEVEL_SCENE`):

| Class | Role |
| --- | --- |
| `NativeTriggerRuntime` | packed trigger scheduler: parses GD trigger properties once, advances crossings per physics tick, executes colour/camera/player/shader/UI effects; API `register_packed_trigger`, `advance`, `tick`, `reset`, `trigger_count`, `active_fade_count` |
| `NativeLevelRuntime` | per-level runtime: `bind_context` (level, camera, Config, ShaderLayer, UILayer), `bind_shader_layer` / `bind_ui_layer`, `register_channel`, `register_trigger`, `prime_spawn`, `apply_ui_triggers`, `restore_ui_objects`, `is_ui_applied`, `compute_ui_anchor`, `trigger_count` |
| `NativeFrustumIndex` | packed node-visibility index: `configure`, `build_x_buckets`, `set_view`, `set_visible_buckets`, `visible_bucket_keys`, `hidden_count`, `tracked_count` |
| `NativeColorChannelIndex` | one-call channel propagation: `configure`, `set_group_members`, `apply_channel_color`, `set_channel_blending`, `clear` |
| `NativeLevelBuildJob` | incremental construction: `initialize(data, drop_decoration)`, `step(ms)`, `is_finished`, `get_level` |
| `NativeDecorationRenderer` | retained-RID sprite renderer: `configure`, `set_item_transform`, `set_item_color`, `get_item_*`, `sort_decoration_indices`, `render_stats`, `queue_redraw`, `item_count`, `last_drawn_count`, `draw_commands_last_rebuild`; consecutive same-texture sprites submit as indexed triangle-array batches |
| `NativeMonsterTimeline` | batched per-frame monster clocks; `configure`, `advance`, `size`; metadata cached per definition, mirrors public Monster state, returns only changed sprite-frame indices |
| `NativeDecorationCullWorker` | worker-thread culling coordinator (enter/exit, frame updates, stats) |
| `GdashNative` | entry point: `build_string`, `version`, `add` (self-check used by `GameScene._probe_native_core`), plus the parsing/CORS/audio helpers used by `NativeCore` |

Bound method names observed in `gdash_native.cpp` include: `activate_touch`, `advance`,
`advance_animation`, `advance_player`, `apply`, `apply_channel_color`, `apply_gravity_portal`,
`apply_ui_triggers`, `bind_context`, `bind_shader_layer`, `bind_ui_layer`, `build_string`,
`build_x_buckets`, `classify_collision`, `classify_collision_flags`, `clear`,
`commit_collision_shapes`, `compute`, `compute_player_velocity`,
`compute_player_velocity_packed`, `compute_ui_anchor`, `configure`, `decode_level_string`,
`encode_level_string`, `extract_level_data_string`, `extract_level_sfx_ids`,
`extract_object_geometry`, `finalize`, `get_item_blend`, `get_item_color`, `get_item_transform`,
`get_level`, `hidden_count`, `initialize`, `is_audio_stream`, `is_cors_error`, `is_finished`,
`is_html_error_response`, `is_ui_applied`, `item_count`, `last_drawn_count`,
`parse_channel_styles`, `parse_gd_pairs`, `parse_online_level`, `queue_redraw`,
`reenable_collision_shapes`, `register_channel`, `register_packed_trigger`, `register_trigger`,
`render_stats`, `reset`, `resolve_proxy_url`, `restore`, `restore_ui_objects`, `schedule_group`,
`set_channel_blending`, `set_group_members`, `set_item_color`, `set_item_transform`, `set_view`,
`set_visible_buckets`, `show_all`, `snapshot`, `sort_decoration_indices`, `step`, `tick`,
`tracked_count`, `trigger_count`, `update_camera_range`, `version`, `visible_bucket_keys`.

### Where GDScript consults native

| GDScript | Native use |
| --- | --- |
| `LevelBuildJob.gd` | `NativeLevelBuildJob` (`initialize`/`step`/`is_finished`/`get_level`) when available and not in the editor |
| `FrustumCuller.gd` | `NativeFrustumIndex` |
| `ColorChannelWatcher.gd` | `NativeColorChannelIndex` (`_refresh_native`) |
| `LevelPhysics.gd` | shared-physics shape commits (`commit_collision_shapes`, `reenable_collision_shapes`, `extract_object_geometry`, `classify_collision_flags`) |
| `NativeTriggerBridge.gd` | `NativeLevelRuntime` + `NativeTriggerRuntime` for generic 2.2 triggers |
| `Player.gd` | `compute_player_velocity_packed` (via `_physics_params`) |
| `GDDecorationLoader` / `DecorationBatch.gd` | `NativeDecorationRenderer`, cull worker, sorting |
| `NativeCore.gd` | `GdashNative` helpers (parsing, CORS, audio sniffing) |
| `RobTopLevels.gd` | `parse_online_level`, `resolve_proxy_url`, `is_cors_error` |
| `GameScene.gd` | probe + toast reporting whether native loaded |

## 4. Constants shared with GDScript

`gdash_native.cpp` mirrors the scene's units and physics:

```cpp
static constexpr double GD_CELL_SIZE = 30.0;
static constexpr double ENGINE_CELL_SIZE = 128.0;
static constexpr double CELLS_TO_PX_X =  ENGINE_CELL_SIZE / GD_CELL_SIZE;   //  4.2667
static constexpr double CELLS_TO_PX_Y = -ENGINE_CELL_SIZE / GD_CELL_SIZE;   // -4.2667
static constexpr double PLAYER_CAMERA_DEFAULT_ZOOM = 0.8;
static constexpr double TOUCH_HALF_EXTENT = ENGINE_CELL_SIZE;               // 128 px
```

Plus `ease_bounce_out`, `ease_weight(gd_easing, t)` (GD easing table), `prop_float/prop_int/
prop_bool` property readers, `parse_group_list`, `parse_copy_hsv`, `parse_color_source`,
`legacy_color_trigger_channel`, `level_color_property_for_channel`,
`shift_copy_hsv`, `apply_gravity_portal_player`. **These must stay in sync with the GDScript
implementations** (`EasingComponent`, `GMDConverter`, `Player`, colour channels).

## 5. Build

```bash
cd native
scons platform=<linux|android|web> target=<template_debug|template_release> arch=<x86_64|arm64|wasm64> \
      api_version=4.7 [debug_symbols=yes] [lto=none] [threads=yes]
```

Web builds need a patched godot-cpp. The pinned commit (`6cceaf6`) accepts only wasm32 on the web,
so CI runs `python3 tools/godot_cpp_wasm64.py native/godot-cpp` before the web library is built.
The script makes three exact edits and stops if an anchor is missing, so a godot-cpp bump fails
loudly rather than building wasm32. Do not commit the patched clone.

- `native/bin/gdash_native.gdextension` (tracked, although `native/bin/` is gitignored) declares
  the library paths: `linux.x86_64.single.debug`, `android.arm64.single.debug|release`, and
  a matrix of `web.wasm32[.threads][.debug|.release]` and `web.wasm64[...]` entries. Every web entry
  points at the wasm64 files, so the wasm32 keys are aliases, not a separate build.
  `compatibility_minimum = "4.1"`,
  `entry_symbol = "gdash_native_library_init"`, `reloadable = false`.
- Windows CI stages `windows.debug.x86_64` / `windows.release.x86_64` mappings with
  `tools/pin_windows_extension.py`, both to the optimized release DLL. These workspace-only
  descriptor edits are not committed; neither are the generated Windows binaries.
- `build_profile.json` trims godot-cpp bindings (CI asserts ~29 generated class files and that
  `fast_noise_lite.cpp`/`camera2d.cpp` exist).
- CI compiles a Linux debug lib (symbols kept for addr2line) before the in-engine selftests,
  then the Android arm64 release lib (speed + ThinLTO, stripped APK copy). Windows uses
  speed + full LTO/static CRT; Web builds one speed + full-LTO wasm64 release lib.
  Debug selectors in Web CI use that release lib, not a second compilation.
- `native/godot-cpp/` is cloned at the pinned commit; `native/bin/` is gitignored
  (`.gitignore`: `native/godot-cpp/`, `native/bin/`, `native/.sconsign.dblite`, `native/.scons-*`,
  `*.os`).

## 6. Tests

| File | Type |
| --- | --- |
| `native/tests/test_physics.cpp` | standalone; duplicates player physics constants, exercises the velocity/gravity/slope math |
| `native/tests/test_gravity_portal.cpp` | standalone; uses `../src/gravity_portal.h` |
| `native/tests/test_ui_trigger.cpp` | standalone; production `ui_alignment.h`, run by Windows CI |
| `native/tests/test_color_channel_math.cpp` | needs `godot_cpp/variant/color.hpp` |
| `native/tests/test_decoration_channel_tint.cpp` | production helper + pinned godot-cpp Color; separate SDK-linked Windows gate |
| `native/tests/test_online_parser.cpp` | needs godot-cpp headers |
| `native/tests/test_trigger_effect_parse.cpp` | includes the whole `../src/gdash_native.cpp`; needs godot-cpp |

Windows CI compiles/runs `test_ui_trigger.cpp`, `test_decoration_visibility_cache.cpp`,
`test_decoration_spin.cpp`, `test_decoration_spin_cache.cpp`,
`test_decoration_sections.cpp` and `test_frustum_transition_ranges.cpp` through
`tools/benchmarks/renderer_cache/SConstruct`. The visibility suite includes the production
neutral-HSV classification test; the spin-cache suite checks against a frozen pre-cache
formula and logs optional scoped CPU timings. Other standalone unit tests are not
automatically covered by that gate; run relevant ones locally:

```bash
g++ -std=c++17 -O2 -o /tmp/t native/tests/test_physics.cpp && /tmp/t
g++ -std=c++17 -I native/godot-cpp/include -I native/godot-cpp/gen/include \
    -o /tmp/tc native/tests/test_color_channel_math.cpp && /tmp/tc
```

Keep the SDK-free renderer-cache harness dependency-free. Tests requiring the exact Godot
Color implementation use the separate `tools/benchmarks/channel_tint/SConstruct`, after
building the pinned release SDK. Do not confuse CPU checks with GPU or real-level performance proof.

## 7. In-engine native gates (CI)

| Gate | Script | Expected output |
| --- | --- | --- |
| Native colour-trigger chain | `tools/native_color_selftest.gd/.tscn` | `NATIVE_COLOR_SELFTEST_SUMMARY … failed=0`; fails hard if `NativeTriggerRuntime` is unavailable (the Linux lib was just built) |
| Native runtime boot (Amethyst crash repro) | `tools/amethyst_boot_test.gd/.tscn` | boots the level through `NativeLevelRuntime` |
| Renderer/atlas smoke | `tools/runtime_visual_smoke_test.gd/.tscn` | checks both GD artwork paths render pixels; also asserts HSV-neutral handling and batch ordering across seals |

`tools/native_color_selftest.gd` documents the failure it was born from: a device run showed
348k "changed" emissions from colour-trigger fades while no channel left white — i.e. every fire
parsed as KEEP. The test pins the whole chain
`register_packed_trigger({7/8/9 RGB, 23 channel, 10 duration}) → advance() crossing →
capture_color_target → fade → apply_color → ColorChannelData.color changes`.

## 8. Rules for changing native code

1. Add the GDScript fallback first (or keep it working), then the native acceleration behind a
   `has_method` check.
2. Keep constants in sync with GDScript (`CELLS_TO_PX`, physics, easing, colour).
3. Do not add a native class whose absence changes behaviour — only performance.
4. Update `native/bin/gdash_native.gdextension` only if the library layout changes (it is committed).
5. If you touch trigger parsing, extend `native/tests/test_trigger_effect_parse.cpp` and
   `native/tests/test_ui_trigger.cpp`.
6. Remember the build profile: adding a class binding grows `gen/src/classes/*` (CI asserts the
   trimmed count).

## 9. Monster-clock acceleration

`DecorationBatch._advance_monsters` uses `NativeMonsterTimeline` when enabled/available,
otherwise the unchanged `_advance_monsters_portable`. Build/registration/Animate/restart
invalidate the snapshot, as does switching to fallback. Metadata is immutable until the
next configure; public frame/animation/elapsed values remain mirrored, and sprite placement
still runs in GDScript at the original callback/frame boundary. No new ticking node, thread,
physics clock, per-frame transform bake, or fmod/quotient shortcut is introduced.

`tools/monster_timeline_selftest.tscn` is a strict Windows gate (including script errors).
It compares against frozen d15e8de code across all bundled clip definitions, frame boundaries,
large/zero/negative deltas, default/next clips, missing/empty clips, restarts, fallback switching
and same-size reconfiguration. It times 2000 tracks / 240 ticks with placement included,
configuration excluded, warmup, three trials and rotated order. Not a full-level FPS test.


## 10. Decoration spin coefficient reuse

`NativeDecorationRenderer::index_records` profiles adjacent **spinning** rates once
(both array configuration and the packed builder use this entry). Speeds are immutable
until reconfiguration. If at least half the records repeat the previous rate, animation
uses a one-entry, exact-float-bit coefficient cache **local to each advance call**.
Other batches retain the uncached loop, selected once per call rather than per record.
If a future API mutates spin rates/order, it must rebuild this profile too.

Only cosine/sine coefficients are reused. Each record still reads its current transform
and pivot, applies the same parent-space operation order, and stores through `real_t`.
No reordering, skipped/offscreen animation, approximate trig, accumulated cached pose,
new tick/thread or visual/physics change. Empty/nonpositive-delta guards and redraw
semantics are unchanged; the GDScript path is unchanged.

Local GCC 12.2 CPU tests pass, including float/double incremental parity, mirrored/skewed
transforms, speed-bit edge cases and sanitizer checks. The revised Windows gate is wired,
not run here. `tools/renderer_cache_selftest.gd` adds actual-native same-size reconfigure,
cached/uncached/static transitions, changing delta and external transform checks; these
need Godot execution. See `reports/decoration-spin-cache-2026-10-15.md` for benchmark
method/results, rejected unconditional-cache regression and limitations. This is not
whole-level/FPS/GPU/device proof.


## 11. Decoration channel tint decomposition reuse

`NativeDecorationRenderer::apply_channel_color` uses `DecorationChannelTint<Color>`
from `native/src/decoration_channel_tint.h` to compute incoming RGB's h/s/v once,
lazily at the first non-neutral HSV record. The helper lives for **one call** only.
Neutral-only/empty/invalid selections never decompose; per-record neutral classification,
shift/clamp/from-HSV operation order, final base-alpha multiplication and exact dirty
assignment remain unchanged. No cached output color or cross-call invalidation state.
Do not apply this shortcut to `NativeColorChannelIndex`'s sequential s/v/h round-trips:
that is a different algorithm. GDScript/native behavior and callback timing are unchanged.

The new SDK-linked C++ gate uses the pinned godot-cpp Color, not a copied approximation,
and compares finite RGBA bits against the previous formula. It also checks lazy getter
counts, direct color overwrites, HDR/negative/black/white inputs and mixed shift modes.
Windows CI builds/runs it after the release extension and reports optional CPU benchmarks;
no performance threshold is used. Linux local execution, sanitizers on the test + Color
source, and full native release compilation passed. Windows job and Godot execution remain
pending. The renderer scene adds color-call/reconfigure/empty/invalid/duplicate selection
checks. See `reports/decoration-channel-tint-2026-10-15.md` for precise benchmark scope.


## 12. Compact decoration spatial index

`NativeDecorationRenderer::index_records` still computes exactly the original
conservative cell coverage into a temporary ordered map. It then consumes that map
into `CompactDecorationSections`: sorted columns, contiguous row spans and contiguous
record IDs **per column**. Each builder column is released immediately after copying;
this avoids keeping both complete indexes alive. Reconfigure releases old compact
storage before constructing the replacement and invalidates the visibility cache.

Cell traversal order, within-cell insertion order, duplicate occurrences and the
visibility cache's first-occurrence deduplication remain unchanged. No record-ID sort,
new culling threshold, skipped animation or editor-picking change. The existing mutable
map adapter remains available for tests; the renderer retains only compact storage.
Empty construction cells may be omitted because they emit nothing; production creates
cells only while pushing record IDs.

`test_decoration_sections.cpp` compares raw and deduplicated sequences to an independent
set oracle, tests empty/extreme ranges, wraparound, reconfiguration and live draw data,
and benchmarks against a frozen pre-compaction cache. Its test-only allocation counter
reports requested live/peak container bytes, not RSS. Full Linux native compilation and
local tests passed; the new Windows gate and native scene additions still need engine/CI
execution. Compaction trades a small construction pass for lower retained index memory
and faster changing-range queries; see `reports/decoration-sections-2026-10-15.md` for
measured construction peaks (including concentrated input) and limitations.

## 13. Decoration triangle-array batching

`NativeDecorationRenderer::rebuild_commands` bakes each selected sprite's current 2D
transform into its four quad vertices and submits indexed `canvas_item_add_triangle_array`
commands, coalescing consecutive records that share a texture and blend-target canvas RID.
The run order is never sorted or changed: each blend target receives its original ordered
subsequence, preserving overlapping translucent composition. Per-vertex UVs, colors,
channel tint, group pulse, UI offsets, spin, and the three inherited/normal/additive material
paths are retained. The fallback renderers in GDScript are untouched.

`tools/renderer_cache_selftest.gd` asserts every sprite is retained, that 256 same-texture
records become one triangle-array command (synthetic 99.6% command-count reduction), that
unequal transforms remain distinct geometry, and that separate blend targets stay separate.
This counter is a RenderingServer canvas command count, not measured driver draw calls or FPS.
`tools/runtime_visual_smoke_test.gd` adds a SubViewport image comparison against the old
texture-rect path, including atlas regions, alpha overlap, rotation, scale and shear; it still
needs an engine run. The native release extension compiles locally; pixel parity, Windows CI,
real-level frame time, and target GPU performance remain unverified. The implementation uses
portable canvas triangle arrays, not compute shaders or MultiMesh instancing: those would
require materially more shader/UV/material work and a GLES/WebGL-compatible fallback, and
no compute-workload bottleneck has been measured. See
`reports/decoration-triangle-batching-2026-10-15.md`.

## 14. Static frustum edge-band traversal

`NativeFrustumIndex::set_view` still performs a full exact reconciliation on first setup.
For subsequent changes with overlapping old/new horizontal views, it visits only spatial
sections swept by the two viewport edges, rather than every section under both complete
views. If the views do not overlap (such as a camera teleport), it visits both whole views
and never walks the travel gap. Candidate objects still use the same exact world interval
comparison; repeated section candidates remain generation-deduplicated. Grouped/dynamic
objects retain their per-frame live transform and Link Visible handling. Their desired-state
scratch vector is now retained and allocated only during `configure_dynamic`; fresh ObjectDB
resolution during the visibility pass remains to tolerate synchronous callbacks freeing nodes.

`test_frustum_transition_ranges.cpp` compares swept candidates against a full-state oracle
for 12,000 transitions, including disjoint views, negative/boundary coordinates, reversed
endpoints, narrow/large spans and teleport-like movement. It benchmarks 20,000 synthetic
entries over 2,000 small camera steps; local Linux selector time improved about 1.8x (1.76–1.81x in repeat runs) with 19.9%
fewer candidate visits. This is native index CPU time, not full-level FPS/GPU/device evidence.
The SDK-free SConstruct and Windows CPU gate run the helper benchmark; the in-engine runtime
smoke checks actual dynamic-object and Link Visible transitions. Full Linux native compile
passed; Godot/Windows/device runtime remains pending. See
`reports/frustum-edge-band-culling-2026-10-15.md`.

## 15. Batch-node / global draw-call limits

The current packed decoration asset manifest has one page (`gd_objects_atlas_0.png`), and
rendering already uses C++ `RenderingServer` canvas-item RIDs with indexed triangle-array
runs. A texture-array/global-atlas rewrite cannot collapse calls for the present packed-art
path. The remaining `DecorationBatch` nodes are group-transform/effect proxies, not per-sprite
nodes. Whole-level call collapse would have to respect intervening gameplay z layers and
normal/additive materials; PhysicsServer is unrelated to static decorations. The native
`render_stats()` adds `batch_owner_nodes` and `canvas_draw_commands`; the latter counts
RenderingServer geometry submissions, not driver calls. See
`reports/decoration-node-and-draw-call-review-2026-10-15.md` before attempting a native
trigger/group-transform rearchitecture.
