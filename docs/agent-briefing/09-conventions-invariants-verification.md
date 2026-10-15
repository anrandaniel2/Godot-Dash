# 09 — Conventions, invariants and the verification playbook

## 1. Style rules (`CONTRIBUTING.md`, binding)

- **PRs/branches**: descriptive names grouped by topic (`spawn-trigger-crash-fix`, not `fix`).
- **Formatter**: GDQuest's GDScript formatter; Godot's GDScript style guide.
- **Explicit types everywhere.** If a type genuinely must change, use `Variant` — never drop the
  annotation.
- **`class_name`** on every class referenced elsewhere; `@abstract` for categorisation-only base
  classes (`Component`, `GMD`, `GMDObjects`, `Serialize`, `Constants`, `Attribute`, `Builder`).
- **No upward node paths** (`../..`). Use `@export var x: Type`, or constructor arguments stored
  in public vars when the script is code-instantiated:

  ```gdscript
  var keybind_loader: KeybindLoader

  func _init(_keybind_loader: KeybindLoader) -> void:
      keybind_loader = _keybind_loader
  ```

- **Signals**: `signal.connect(callable)`, never `connect("name", callable)`.
- **Strings**: format strings (`"%s objects" % n`), not `str() + "…"`.
- **No commented-out code** in PRs.
- **Naming**: folders `snake_case`, files/scripts `PascalCase` (generated `gd_<id>.tscn` is the
  documented exception).
- **Comments** explain *why*, in the repo's voice (device bugs, CI steps, measured behaviour).

### New settings checklist

1. Same order in the settings menu and in `Config`.
2. **Add loading in `Config._init` and writing in `Config.save`** — both.
3. Booleans non-inverted (`Enabled`, default `true` rather than `Disabled`).
4. Enums live in `Config`; "Disabled" first; variants ordered low → high.
5. Multiple related booleans → consider one bit flag (`@export var x: int`).
6. Intermediate variables (e.g. `touch_screen_mode` → `is_touch_screen`) are `@export_storage`
   and booleans start with `is_`.

## 2. Invariants and landmines (the list to check before every change)

1. **Autoload order** matters (`Config` before readers, `Editor` before `in_editor` users,
   `LevelManager` before the live level).
2. `LevelManager.current_level` must be published **before** stepping a `LevelBuildJob`
   (component setters consult it).
3. `LevelManager.ground_down/ground_up` can be null during detached builds — setters guard.
4. `ProjectSettings` version string is embedded in replays and update checks; bumping it
   invalidates the GDR golden bytes (`tools/gdr_selftest.gd`).
5. Player collision mask/pysics layers are a contract; `LevelPhysics` merges only
   `[2, 66, 4, 2048]` and never merges dynamic transform groups.
6. Interactables keep per-object `Area2D`s (locked decision).
7. `GDObject` frees an empty `Collision` body in `_ready()`; adding shapes to a generated scene
   affects **every** placement of that type.
8. `DecorationBatch` serializes by expanding items back into per-object entries — new `Item`
   fields must round-trip.
9. Culling must never hide group-driven/trigger-controlled/toggle-hidden objects.
10. Never hand-edit `scenes/gd_objects/*.tscn` — regenerate (the generator preserves `Collision`
    subtrees and UIDs).
11. `Base`/`Detail` node names on object scenes are load-bearing for channel wiring.
12. Component nodes are named exactly after their script's global class name — renaming breaks
    saved levels.
13. Native classes only via `ClassDB` lookups; keep the GDScript fallback correct.
14. Never make the web export depend on anything the browser forbids (direct RobTop requests,
    fullscreen without a gesture, `gl_compatibility`).
15. `rendering_method.web` stays `mobile`; `driver/threads/thread_model` stays Safe.
16. `export_presets.cfg` Web custom templates are rewritten by CI; do not rely on hand edits.
17. Web `include_filter`/`exclude_filter` must still cover new runtime data files.
18. `Engine.time_scale` is a gameplay mechanic (`TimescaleChangerComponent`) — reset it in scene
    transitions.
19. Particle settings are bitflags; read them with bitwise checks.
20. `physics_interpolation=true` is deliberate.
21. `Level.to_data` must stay lossless for native-elided triggers (`native_trigger_records`).
22. `Save`-reason serialization of components with `Resource` fields requires
    `_field_to_data`/`_field_from_data` overrides (asserted).
23. `EditorSelectionCollider` children (type + id) drive picking and the Interactable tab.
24. Ground material is shared between ground sprites; line colour is a shader parameter.
25. `Config` writes to disk in setters — avoid assigning settings in loops.
26. `GD_UNIFICATION_PLAN.md` status gates what may be deleted (`GDArtSwap`, old component scenes).
27. `.gmd` import must stay "skip, never fatal".
28. `LevelBuildJob` is the only build path (editor = unlimited step; game = budgeted steps).
29. Streaming budgets are wall-clock milliseconds, never work units.
30. Anything added to the exported web build must not exceed what the unstripped template keeps
    (`Line2D`, physics shapes, MP3 are asserted present — don't rely on modules hogdot strips).
31. Test probes are **scenes** (`*.tscn`) launched by path, not `--script`: a `--script` SceneTree
    probe hung in CI. Success is judged from log markers, because engine shutdown can hang or
    segfault after a clean run (exit 139 tolerated by the smoke step).
32. `LFS`: only `*.so *.dylib *.dll *.ico` are LFS-tracked; everything else binary (PNGs, atlases)
    is committed normally. Run `git lfs install` before touching LFS files.

## 3. Verification playbook

Cheapest first. **State exactly which step you ran and which you could not.**

### Step 0 — understand the blast radius

Grep before editing:

```bash
# who reads this constant / calls this method?
grep -rn "CHUNK_CELLS\|_gd_level_physics" src/ native/
# who references this scene/script?
grep -rn "gd_objects/gd_8\|GDObject" src/ tools/ | head
```

### Step 1 — static checks (always available)

```bash
python3 -m py_compile tools/*.py
python3 -m json.tool assets/textures/gd_atlas/object_frames.json   > /dev/null
python3 -m json.tool assets/textures/gd_atlas/gd_objects_atlas.json > /dev/null
python3 -m json.tool tools/gd_hitbox_data.json                     > /dev/null
node tools/web_relay_worker_selftest.mjs
```

Plus: `git diff --check` (whitespace), a scan of the diff for style rules from §1, and a grep
that no new `../..` node paths or untyped variables slipped in.

### Step 2 — generator idempotence (needs Pillow)

```bash
python3 tools/build_gd_object_scenes.py     # re-run; expect no unintended diffs
git diff --stat
git diff scenes/gd_objects/gd_8.tscn        # Collision subtree + UID preserved
```

### Step 3 — C++ unit tests (needs a C++17 compiler)

```bash
g++ -std=c++17 -O2 -o /tmp/test_physics native/tests/test_physics.cpp && /tmp/test_physics
g++ -std=c++17 -O2 -o /tmp/test_portal  native/tests/test_gravity_portal.cpp && /tmp/test_portal
g++ -std=c++17 -O2 -o /tmp/test_ui      native/tests/test_ui_trigger.cpp && /tmp/test_ui
# godot-cpp-dependent ones (needs native/godot-cpp checkout):
g++ -std=c++17 -I native/godot-cpp/include -I native/godot-cpp/gen/include \
    -o /tmp/test_color native/tests/test_color_channel_math.cpp && /tmp/test_color
```

### Step 4 — in-engine gates (needs Godot 4.7; CI runs these)

```bash
godot --headless --path . --import            # scripts compile during import

xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/gdscript_probe.tscn             # gate: ^PROBE_SUMMARY, no ^PROBE FAIL

xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/gdr_selftest.tscn               # gate: GDR_SELFTEST_SUMMARY … failed=0

xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/native_color_selftest.tscn      # gate: NATIVE_COLOR_SELFTEST_SUMMARY … failed=0

xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/runtime_visual_smoke_test.tscn  # gate: VISUAL_SMOKE size= (exit 139 ok after pass)
```

### Step 5 — export smoke (needs toolchains)

- Android: Gradle export via the CI steps (or `godot --headless --export-release "Android"` with
  the SDK/JDK/NDK installed), then inspect the APK for arm64 + `gdash_native`.
- Web (wasm64): patch godot-cpp with `tools/godot_cpp_wasm64.py` and hogdot with
  `tools/hogdot_wasm64.py`, build the wasm64 unstripped template and the wasm64 `gdash_native`
  library, then `tools/pin_webgpu_templates.py`, then
  `godot --headless --rendering-method mobile --export-release "Web" export/Web/index.html`. Check
  that `tools/check_wasm64.py` passes on `index.wasm`, `index.side.wasm` and the native library,
  check for `webgpu` in `index.html`, and check for `Line2D`/`CircleShape2D`/`AudioStreamMP3` in
  `index.side.wasm`. Also run `tools/check_wasm_engine.mjs` on all three wasm files under
  Node 24; this validates binaries but does not instantiate them. The workflow additionally
  checks the GLES3 driver strings and `godotPickRenderingDriver` fallback shell. Its Chrome
  smoke step is report-only: read browser console output before claiming a runtime fix.

### Step 6 — manual (user-side, documented in the plan doc)

Open/play a level, playtest from the editor, import/export a `.gmd`, verify block/slope/spike/saw
touchboxes and wall-kill behaviour, and check the editor selection.

## 4. Debugging aids built into the game

| Aid | How to read it |
| --- | --- |
| Level-open toast | `"Level open: X s · N objects · M nodes · native yes/no"` when open > 400 ms |
| Native probe print | `[gdash] native core loaded: … (self-check add(2, 3) == 5 …)` |
| Native missing diagnostic | `[gdash] native unavailable diagnostic=v5 manifest_error=… libraries=… os=… arch=…` |
| Memory heartbeat | `[gdash-mem] <tag> | VmRSS… | VmHWM…` (level open/play, every 10 s while playing) |
| BEAMDIAG | `BEAMDIAG live …` every 5 s (`recolors`, `colored`) for colour-trigger investigations |
| Streaming overlay | `stream Xms`, `live`, `deco <live>(+<building>)` |
| Debug menu | `DebugMenu` autoload overlay (FPS/memory/level stats), `Config.draw_debug_overlays` |
| Toasts | `Toasts.new_toast/error/warning/warning_once` — use `warning_once(key, …)` for repeat noise |

## 5. Writing style for changes in this repo

- Match the existing comment voice: explain the *why*, reference the symptom, the device, the CI
  step, or the file that motivated it.
- Keep functions small and typed; prefer early returns.
- Prefer `push_error`/`push_warning` + graceful fallback over crashes in import paths; assert
  only for programming errors (the repo asserts in `Component.require`, serialization
  invariants, etc.).
- When adding a CI-able assertion for a bug class, follow the established patterns:
  `_test_*` functions inside `tools/runtime_visual_smoke_test.gd`, checks in
  `tools/gdscript_probe.gd`, or a new `tools/*_selftest.gd/.tscn` pair with a
  `*_SELFTEST_SUMMARY … failed=0` gate wired into the workflow.

## 6. Editor picking gate (M1)

`tools/picking_check.tscn` compares hit sets (not selection order) for 3,000 cursor circles
and 600 rectangles against a real level's enabled rectangular GDObject selectors. Run with
`GDASH_MEM_LEVEL=/path/level.gmd` after importing project resources. The `picking-check.yml`
workflow builds the Linux extension and imports before running this scene. Do not change
production picking order based on synthetic candidates: the M1 picking-order gate is still
required before any production picking-order change.

## 7. Renderer cache and decoration ordering gates

`tools/renderer_cache_selftest.tscn` exercises the actual native renderer's mutable records,
command/selection rebuild counts, channel tint, group pulse, spin reconfiguration and compact
spatial reconfiguration. `tools/runtime_visual_smoke_test.gd` is the real-renderer pixel gate
for generated artwork and native dynamic culling/channel behavior. Headless command counters
are not pixel, GPU, or device proof; the visual scene should run with the native extension.
Triangle-array aggregation was reverted after Android Mobile pixel parity detected atlas-edge
mismatches because it did not reproduce `clip_uv`. The retained SubViewport gate compares the
active clipped-rectangle path against a direct RenderingServer texture-rect reference for atlas
UVs, translucent overlaps, and rotated/scaled/sheared transforms.

Static frustum movement uses edge-band traversal only for overlapping old/new ranges; first
setup and disjoint/teleport views reconcile full ranges. `test_frustum_transition_ranges.cpp`
compares against a full-state oracle; the dynamic path keeps fresh ObjectDB lookups because
visibility callbacks can free nodes synchronously. See `06 §§13–15` and the frustum/node
reports for exact scope and measurements.

## 8. Renderer hot-path optimization evidence

Native spin coefficient reuse and channel-tint decomposition have standalone correctness tests
against the prior formulas. The compact section index and frustum edge sweep have SDK-free
oracle tests and synthetic benchmarks. These measurements are local C++ CPU/helper timings,
not level-open time, full-level FPS, GPU time, or device results. Preserve the reports' exact
benchmark scope when quoting them; see the linked `reports/decoration-*-2026-10-15.md` files.

Renderer command rebuilding preserves per-sprite clipped texture-rectangle submissions and
ordered transform/blend behavior. The triangle-array candidate was rejected after Android
Mobile pixel parity found atlas-region edge mismatches; its historical 256-to-1 synthetic
command reduction is not a current result. `renderer_cache_selftest.gd` checks sprite
retention and ordered rect submissions. `render_stats()` reports `batch_owner_nodes` and
`canvas_draw_commands`; the latter counts RenderingServer API submissions, not driver draw
calls. The current production atlas manifest has one page, so a texture-array/global-atlas
rewrite will not reduce texture switches for packed objects. Group, z-layer and blend ordering
remain separate constraints. See `reports/decoration-triangle-batching-2026-10-15.md` and
`reports/decoration-node-and-draw-call-review-2026-10-15.md`.

## 9. Render/recolor follow-up (2026-10-14)

`tools/renderer_cache_selftest.tscn` also exercises simultaneous completed culling, spin and
pulse updates, requiring at most one command rebuild per frame and actual cell-range changes.
Renderer HSV snapshots are tested through same-size reconfiguration. `tools/color_refresh_selftest.tscn`
compares the production portable recolor path bit-exactly against the frozen Build 15 loop,
checks native values/base mirrors, copy cycles, opacity, neutral/non-neutral HSV and editor
highlights, then reports synchronous CPU timings for 2000 watchers/60 updates. Current native
timing is NOT a before/after native benchmark. Both tests are strict Windows packaging gates
(completion marker plus script-error checks). The script probe respects `.gdignore` so isolated
benchmark projects are not loaded with the main project's res:// root. Ordinary runtime and
test scripts remain checked. No full-level FPS, GPU/pixel parity, or M1 picking-order acceptance
follows from these tests.

## 10. Build production / monster timeline gates

`tools/test_production_build.py` runs in Windows/Android/Web CI: release command/flags,
resource filters, bytecode/shader baking, wasm64/threads, architecture, native cache rollover,
and idempotent fail-closed Web release staging. Windows exported smoke rejects debug builds.
Windows also runs the strict monster timeline parity/timing and packed trigger origin/schema
scenes; Android retains its origin and visual gates. CPU-only Android tests now run headless,
not in Xvfb, to avoid spending whole timeouts on GL teardown after completion. This is not a
substitute for visual tests. Native clock performance acceptance requires the actual benchmark,
not just successful compilation. See the build-production report for current evidence.

## 11. Usage-based texture import policy

The user explicitly replaced the lossless-only policy on 2026-10-15:
`tools/check_texture_compression.py` assigns gameplay/atlas art to VRAM mode 2
(S3TC + ETC2, high_quality=false for broad backend compatibility), UI/editor art
to lossy mode 1 at quality 0.90, and font/data-mask textures to lossless mode 0.
Run `--apply` after importing new textures; unknown asset categories fail closed.
Project defaults remain safely lossless for newly generated font/data sidecars.
Keep UIDs, dimensions, existing mipmaps and alpha-processing settings unchanged.
Vendored editor addon icons and intentional keep/skip resources are outside this gate.

Windows/Android/Web builds run `python3 tools/check_texture_compression.py --imported`
after import and before export. The check requires both S3TC/ETC2 gameplay variants,
verifies GPU block formats/payload sizes including mips (rejects uncompressed raw
pixels), requires lossy VP8 for UI, and PNG/VP8L for lossless exceptions. It rejects
stale remaps, missing outputs, auto-3D flags and malformed container bounds, and
logs CTEX byte totals. It does not decode pixels or inspect final PCK/APK contents.
`tools/test_production_build.py` covers role assignment, idempotence and codec gates.

`TextureReadback` decompresses only CPU image copies before editor crop/blend work;
original gameplay texture resources stay GPU-compressed. `ObjectThumbnail` keeps
its decoded-page cache; `LayeredSprite` uses the same image preparation. Runtime
SVG recoloring/custom player icons remain runtime-created textures, outside the
Godot import pipeline. Windows renderer-cache tests include CPU DXT1/ETC2 fixtures;
the visual smoke includes real imported atlas crop, blend and object thumbnail checks.
Those new in-engine cases still require a Godot/CI run; Python/static checks alone
are not device, visual, package-size or FPS proof.

See `reports/godot-texture-compression-2026-10-15.md` for executed versus pending checks.
