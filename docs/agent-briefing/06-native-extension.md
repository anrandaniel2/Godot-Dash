# 06 — Native GDExtension (`native/`)

## 1. Why it exists

The README is explicit: the optional GDExtension carries the hot paths that per-object GDScript
cannot — the packed trigger scheduler, the retained-RID decoration renderer with worker-thread
culling, the node visibility index, incremental level construction, shared-physics shape
commits and (since 1.10) colour-channel propagation. Everything it does **also exists in
GDScript**; native is an accelerator, never a requirement.

## 2. The contract (memorize)

1. Native classes are reached **only** through `ClassDB.class_exists()` /
   `ClassDB.instantiate()` string lookups. A static type reference stops a script from parsing
   on builds without the library (e.g. desktop/editor builds).
2. The switch is `Config.use_native_core`.
3. All access goes through `src/static/NativeCore.gd`, which wraps each native call with a
   GDScript fallback and logs a diagnostic once when the library is missing.
4. Web has no GDExtension on desktop browsers but the wasm library is built and **bundled into
   the web export** (`libgdash_native.web.template_release.wasm32.wasm` is verified present).
   Android bundles the arm64 `.so`; desktop/source builds usually run without it.
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
| `NativeLevelRuntime` | per-level runtime: `bind_context` (level, camera, Config, ShaderLayer, UILayer), `bind_shader_layer` / `bind_ui_layer`, `register_channel`, `register_trigger`, `advance_player`, `apply_ui_triggers`, `restore_ui_objects`, `is_ui_applied`, `compute_ui_anchor`, `trigger_count` |
| `NativeFrustumIndex` | packed node-visibility index: `configure`, `build_x_buckets`, `set_view`, `set_visible_buckets`, `visible_bucket_keys`, `hidden_count`, `tracked_count` |
| `NativeColorChannelIndex` | one-call channel propagation: `configure`, `set_group_members`, `apply_channel_color`, `set_channel_blending`, `clear` |
| `NativeLevelBuildJob` | incremental construction: `initialize(data, drop_decoration)`, `step(ms)`, `is_finished`, `get_level` |
| `NativeDecorationRenderer` | retained-RID sprite renderer: `initialize`, `set_item_transform`, `set_item_color`, `get_item_*`, `sort_decoration_indices`, `render_stats`, `queue_redraw`, `item_count`, `last_drawn_count` |
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
scons platform=<linux|android|web> target=<template_debug|template_release> arch=<x86_64|arm64|wasm32> \
      api_version=4.7 [debug_symbols=yes] [lto=none] [threads=yes]
```

- `bin/gdash_native.gdextension` (committed) declares the library paths:
  `linux.x86_64.single.debug`, `android.arm64.single.debug|release`, and a full matrix of
  `web.wasm32[.threads][.debug|.release]` entries. `compatibility_minimum = "4.1"`,
  `entry_symbol = "gdash_native_library_init"`, `reloadable = false`.
- `build_profile.json` trims godot-cpp bindings (CI asserts ~29 generated class files and that
  `fast_noise_lite.cpp`/`camera2d.cpp` exist).
- CI compiles a Linux debug lib (symbols kept for addr2line) before the in-engine selftests,
  then the Android arm64 release lib for the APK, and the web wasm lib in the web workflow.
- `native/godot-cpp/` is cloned at the pinned commit; `native/bin/` is gitignored
  (`.gitignore`: `native/godot-cpp/`, `native/bin/`, `native/.sconsign.dblite`, `native/.scons-*`,
  `*.os`).

## 6. Tests

| File | Type |
| --- | --- |
| `native/tests/test_physics.cpp` | standalone; duplicates player physics constants, exercises the velocity/gravity/slope math |
| `native/tests/test_gravity_portal.cpp` | standalone; uses `../src/gravity_portal.h` |
| `native/tests/test_ui_trigger.cpp` | standalone (duplicated constants) |
| `native/tests/test_color_channel_math.cpp` | needs `godot_cpp/variant/color.hpp` |
| `native/tests/test_online_parser.cpp` | needs godot-cpp headers |
| `native/tests/test_trigger_effect_parse.cpp` | includes the whole `../src/gdash_native.cpp`; needs godot-cpp |

**No workflow currently compiles or runs them.** If you touch those modules, run them locally:

```bash
g++ -std=c++17 -O2 -o /tmp/t native/tests/test_physics.cpp && /tmp/t
g++ -std=c++17 -I native/godot-cpp/include -I native/godot-cpp/gen/include \
    -o /tmp/tc native/tests/test_color_channel_math.cpp && /tmp/tc
```

Wiring them into CI is a legitimate, welcome change — keep the standalone ones dependency-free.

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
4. Update `bin/gdash_native.gdextension` only if the library layout changes (it is committed).
5. If you touch trigger parsing, extend `native/tests/test_trigger_effect_parse.cpp` and
   `native/tests/test_ui_trigger.cpp`.
6. Remember the build profile: adding a class binding grows `gen/src/classes/*` (CI asserts the
   trimmed count).
