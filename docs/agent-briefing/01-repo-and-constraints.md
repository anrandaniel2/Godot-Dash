# 01 — Repository identity, toolchain and hard constraints

## 1. Identity

| Fact | Value | Source |
| --- | --- | --- |
| Project | Godot Dash — Geometry Dash fangame | `README.md` |
| Engine | **Godot 4.7** (`config/features=PackedStringArray("4.7","Mobile")`) | `project.godot` |
| CI engine | Godot **4.7.2-stable** (Linux x86_64 + export templates) | `.github/workflows/main.yml` `env:` |
| Web engine | **hogdot 4.7.2-r19** fork (WebGPU driver) + an unstripped template built in CI | `README.md`, `.github/workflows/web.yml` |
| Version | `1.0.0-alpha.5` | `application/config/version` |
| Main scene | `res://scenes/TitleScreen.tscn` | `project.godot` |
| License | **GPL-3.0** | `LICENSE` |
| Public home / releases | Codeberg (`codeberg.org/godot-dash/godot-dash`) | `README.md`, `UpdateManager.gd` |
| CI / rolling releases | GitHub `anrandaniel2/Godot-Dash` (tags `android-debug`, `web-html5`) | workflows |
| Discord | linked in `README.md` | |

## 2. Scale (from the `14288b1` checkout)

| Metric | Value |
| --- | --- |
| GDScript under `src/` | **267 files, ~31,428 lines** |
| Largest scripts | `static/GMDConverter.gd` 1,823 · `Player.gd` 1,578 · `Level.gd` 1,310 · `RobTopLevels.gd` 996 · `editor/EditHandler.gd` 856 · `static/GDDecorationLoader.gd` 745 |
| Generated GD object scenes | **3,936** (`scenes/gd_objects/gd_<id>.tscn`) |
| Hand-made scenes | `scenes/components/**` (~130), plus `TitleScreen`, `EditorScene`, `GameScene` |
| Native | `native/src/gdash_native.cpp` **5,470 lines** (single TU), `gravity_portal.h`, 6 test `.cpp` |
| Tools | 11 Python files (~3,450 lines), 6 GDScript probes/selftests, 1 Node self-test |
| Tracked files | ~9,800 |
| Atlas assets | `assets/textures/gd_atlas/` — 1 packed page (2.9 MB PNG) + JSON + 16 source cocos2d `-hd` sheets |
| Subsystem sizes | `src/interactables` 84 files · `src/editor` 36 · `src/gui` 26 · `src/static` 22 · `src/attributes` 15 · `src/autoloads` 14 |

## 3. Project settings that matter

From `project.godot`:

```ini
config/features = PackedStringArray("4.7", "Mobile")
run/main_scene = "res://scenes/TitleScreen.tscn"
run/max_fps = 0

[display]
window/size/viewport_width  = 1920
window/size/viewport_height = 1080
window/stretch/mode         = "canvas_items"
window/stretch/aspect       = "expand"
window/vsync/vsync_mode     = 1
display_server/driver.linuxbsd = "wayland"

[physics]
common/physics_ticks_per_second      = 240
common/max_physics_steps_per_frame   = 12
common/physics_interpolation         = true

[rendering]
renderer/rendering_method            = "mobile"
renderer/rendering_method.mobile     = "mobile"
renderer/rendering_method.web        = "mobile"   # required for the WebGPU export
rendering_device/fallback_to_gl_compatibility = true
driver/threads/thread_model          = 0          # Safe; Separate stalls texture uploads
textures/canvas_textures/default_texture_filter = 2
textures/vram_compression/import_etc2_astc = true
viewport/hdr_2d                      = true
anti_aliasing/quality/msaa_2d        = 0
anti_aliasing/screen_space_roughness_limiter/enabled = false

[network]
cors_proxy = "https://gddash.anrandaniel2.workers.dev/?url="
```

Editor plugins enabled: `ReorderableContainer`, `SmoothScroll`, `StyleboxFancy`, `debug_menu`,
`nine_patch_sprite_2d`, `script-ide`, `search_bar_node`, `signal_lens`, `stopwatch`, `trail_2d`
(`[editor_plugins] enabled`).

## 4. Directory map

```
src/                      game GDScript
  autoloads/              16 singletons (see 02-runtime-architecture.md)
  editor/                 editor subsystems + panels + gizmos + menus
  interactables/          Interactable/Component/Marker + public_/private_ components
  gui/                    generic UI widgets + the Property inspector system
  static/                 stateless utility classes (Serialize, GMD*, Math, NodeUtils, …)
  attributes/             node "attribute" flags (LDM, hidden, music-scale, no-touch)
  builders/               Builder pattern (checkpoint placement)
  resources/              custom Resource types
  settings/               keybind UI
  refcounted/             Selection, BoundingBox, IconCache
  tests/                  in-editor test scenes (Gizmos)
scenes/                   TitleScreen / EditorScene / GameScene + components/ + gd_objects/
resources/                themes, materials, curves, gradients, shaders/ (.gdshader, web variants)
assets/                   textures, fonts, sounds, gd_atlas/ (source + packed)
native/                   GDExtension source, SConstruct, build profile, tests
tools/                    asset pipeline (Python), CI probes/selftests (GDScript), web server/relay
addons/                   12 vendored editor addons
dist/linux/               desktop integration
docs/agent-briefing/      this pack
GD_UNIFICATION_PLAN.md    plan of record for the GD object pipeline migration
reports/                  device investigation reports
.github/                  issue templates + the two workflows
```

## 5. Toolchain

### Game (no compilation)

Per `README.md`: install `git-lfs`, clone, open `project.godot` in Godot **4.7**, use
`Project → Export`. The project is written entirely in GDScript — no toolchains needed for the
game itself.

### Native GDExtension (`native/`)

`native/SConstruct` wraps `godot-cpp/SConstruct` with `api_version=4.7` and these defaults:

```python
ARGUMENTS.setdefault("build_profile", "build_profile.json")  # trimmed class bindings (~29 classes)
ARGUMENTS.setdefault("optimize", "speed")
ARGUMENTS.setdefault("debug_symbols", "no")
ARGUMENTS.setdefault("lto", "auto")
ARGUMENTS.setdefault("disable_exceptions", "yes")
ARGUMENTS.setdefault("deprecated", "no")
ARGUMENTS.setdefault("use_hot_reload", "no")
ARGUMENTS.setdefault("symbols_visibility", "hidden")
```

`native/godot-cpp/` is **not committed** (CI clones it at a pinned commit
`GODOT_CPP_REF=6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918`; there is no godot-cpp 4.6/4.7 tag yet).
Built libraries land in `native/bin/<platform>/` next to `gdash_native.gdextension` and are
gitignored.

CI build commands (reproduce these exactly):

```bash
cd native
# Linux test host, debug symbols kept so native crashes symbolize:
scons platform=linux   target=template_debug   arch=x86_64 api_version=4.7 debug_symbols=yes lto=none -j2
# Android release (arm64 only), NDK 28.1.13356709:
scons platform=android target=template_release arch=arm64  api_version=4.7 -j2
# Web (wasm32, threads):
scons platform=web     target=template_release arch=wasm32 api_version=4.7 threads=yes -j4
```

CI asserts the build profile was honoured: **~29 generated godot-cpp class files** (fails at
≥60) and that `fast_noise_lite.cpp` and `camera2d.cpp` bindings exist.

### Python tools

Python 3 + **Pillow** (`pip install pillow`) for `build_godot_atlas.py`,
`build_gd_object_scenes.py`, `build_object_frames.py`, `analyze_amethyst_glow.py`. Stdlib-only
for `serve_web.py`, `pin_webgpu_templates.py`, `extract_gd_hitboxes.py`, `validate_amethyst.py`.
Node (no deps) for `web_relay_worker_selftest.mjs`.

## 6. Hard constraints (violating these is a bug)

1. **Godot 4.7 only.** Never introduce APIs from other versions.
2. **GDScript-only game code.** No new native-only features: every native path has a GDScript
   fallback, and native classes are reached only via `ClassDB` string lookups
   (`src/static/NativeCore.gd` is the contract; `GameScene._probe_native_core()` is the probe).
3. **Web stays WebGPU.** `rendering_method.web = "mobile"`; the web export needs an unstripped
   threaded dlink template, COOP/COEP headers and the CORS relay. Never propose WebGL.
4. **Android stays safe.** arm64-v8a, Gradle, `largeHeap`, `thread_model=0` (Safe), paced level
   open (`Config.paced_level_open`), `max_physics_steps_per_frame=12`.
5. **Data contracts** (§05/§08): `.gmd`/`.gmd2`, internal `.bin` gzip level, `.gdr` replays,
   `.meta` sidecars, and the `user://` layout must round-trip. Unknown GD objects are skipped,
   never fatal.
6. **Physics contract** (see `03-gameplay-and-physics.md` §2): layers 1–12, Player mask 122,
   slopes 66, circular hazards 2048.
7. **One build path.** Editor and runtime both build via `LevelBuildJob`; a level must serialize
   identically either way.
8. **Performance code is load-bearing.** `DecorationBatch`, `FrustumCuller`, `LevelPhysics`,
   `GDDecorationLoader`, the chunked streaming and the native indices exist because per-object
   nodes do not survive real levels. Do not "simplify" them.
9. **Style** (`CONTRIBUTING.md`, see `09-conventions-invariants-verification.md`): explicit
   types everywhere, `class_name` on classes, no upward node paths, `signal.connect(callable)`,
   format strings over concatenation, no commented-out code, formatter-clean GDScript,
   `snake_case` dirs / `PascalCase` files, new settings wired into `Config._init` + `Config.save`
   + the settings menu in the same order.
10. **Artifacts.** Never commit `native/bin/`, `native/godot-cpp/`, `export/`, `android/`,
    `.godot/`, `__pycache__/`. LFS is configured for `*.so *.dylib *.dll *.ico` only.
    `export_presets.cfg` is gitignored but **tracked** (and its Web template paths are rewritten
    by `tools/pin_webgpu_templates.py` in CI).
11. **`arena/**` pushes trigger CI** (Android APK + web export). Push only when asked.

## 7. Sandbox reality check

A typical coding sandbox has **no Godot binary, no scons, no git-lfs, no `native/godot-cpp`**,
and `assets/logo/logo.ico` may be an LFS pointer. You *can* always run:

- Python: `python3 -m py_compile tools/*.py`, JSON validation of `tools/*.json` and
  `assets/textures/gd_atlas/*.json`, `tools/validate_amethyst.py` helpers (network permitting).
- Node: `node tools/web_relay_worker_selftest.mjs`.
- Shell/static: greps for invariants, scene/text edits, generator dry runs (need Pillow), diff
  reviews.
- C++: `g++` on the standalone tests (`test_physics.cpp`, `test_gravity_portal.cpp`,
  `test_ui_trigger.cpp`); the others need godot-cpp headers.

In-engine gates (probe, selftests, visual smoke, exports) only run in CI or on a machine with
Godot 4.7 — say so instead of pretending.
