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
- Web: hogdot editor + unstripped template + `tools/pin_webgpu_templates.py`, then
  `godot --headless --rendering-method mobile --export-release "Web" export/Web/index.html` and
  check for `webgpu` in `index.html` and `Line2D`/`CircleShape2D`/`AudioStreamMP3` in
  `index.side.wasm`.

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
