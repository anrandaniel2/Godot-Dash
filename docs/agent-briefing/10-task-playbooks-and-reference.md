# 10 — Task playbooks, glossary and reference

## 1. Task playbooks

### Add a new gameplay component (behaviour)

1. Create `src/interactables/public_components/MyComponent.gd`:
   `@abstract`-free, `class_name MyComponent`, `extends Component`, typed `@export`s,
   `require([OtherComponent])` for dependencies.
2. Add the node to the relevant scene under `scenes/components/level_components/**`, named
   **exactly** `MyComponent` (the component's global class name).
3. If it must import from GD, add it to the `GMDObjects.MAP` entry's `"components"` list.
4. Serialization is automatic for exported fields; override `_field_to_data`/`_field_from_data`
   for `Resource` fields (asserted for `SAVE`).
5. Editor: exported fields appear in the Interactable/Attribute panels through
   `PropertyGenerator`; add to `COMPONENT_BLACKLIST`/`MARKER_COMPONENTS` if it should be hidden
   or treated as a marker.
6. If it maps to a GD trigger, mirror the parse in `GMDConverter` and, when native-evaluated, in
   `parse_trigger_effect` (+ `native/tests/test_trigger_effect_parse.cpp`).
7. Verify by placing the object in the editor and round-tripping a save; if native, run
   `tools/native_color_selftest.tscn`-style checks where applicable.

### Add support for a new GD object type

1. Ensure the id is in `tools/gd_object_id_list.txt` and regenerate
   `object_frames.json` (+ atlas) if its frames are new.
2. Run `tools/build_gd_object_scenes.py` to produce/refresh `scenes/gd_objects/gd_<id>.tscn`.
3. Add the id → scene mapping in `GMDObjects.MAP` (`scene`, `name`, `colorable`, `components`,
   `type`, optional `id`) — required for import and for the reverse export mapping.
4. Add defaults to `GMDDefaultChannels` if its channels differ from `1004`/`1`.
5. Give it a hitbox: hand-author the `Collision` subtree in the scene (preserved by
   regeneration) or add the shape to `tools/gd_collision_specs.py`/`gd_hitbox_data.json` and
   regenerate.
6. Import a real `.gmd` containing it, verify in the editor, save, and export back.

### Add a new setting

Follow `CONTRIBUTING.md` exactly (see `09-conventions-invariants-verification.md` §1):
`Config` var/enum + load in `_init` + write in `save()` + a control in the settings menu in the
same order; `@export_storage` for intermediates.

### Add an editor command or shortcut

1. Add/extend an action in `src/editor/menu_bar/Actions.gd` (and the owning menu).
2. Implement in `EditHandler` (or the relevant system) and record undo through
   `Editor.version_history` (`UndoRedo`), emitting the existing signals so the inspector and
   tree stay in sync.
3. Add the input action to `project.godot [input]` and to `Config.input_map` handling if
   remappable.
4. Expose it on mobile (`Editor.swipe`, `Editor.delete`, `EditorMoveControls`).

### Performance work

1. Measure first; the game already prints level-open stats, memory and streaming overlays.
2. Choose the right lever: LDM (`DisabledInLowDetailModeAttribute`), culling
   (`Config.culling_buffer_cells`), batching (`DecorationBatch` keys), the shared physics chunks
   (`LevelPhysics.CHUNK_CELLS`), or the native indices.
3. Keep per-frame work bounded in **time** (milliseconds) not work units; slice anything that
   can burst (follow the plan doc's seventh-pass pattern: persistent accumulators, per-pass
   slices, wall-clock budgets).
4. Verify on the smallest device you can and re-check the Android open path.

### Fix a bug

1. Reproduce (or read the device report in `reports/`).
2. Identify the invariant violated from the §2 list in `09-conventions-invariants-verification.md`.
3. Fix at the right layer with the smallest diff; keep native and GDScript paths in sync.
4. If the bug class can recur, add a CI-able assertion in the repo's established style
   (`_test_*` in the visual smoke test, a check in `gdscript_probe.gd`, or a new
   `*_selftest.gd/.tscn` + workflow gate).
5. Document the *why* in a `##` comment referencing the symptom.

### Touch the GD object pipeline

Read `GD_UNIFICATION_PLAN.md` first; respect the locked decisions (static world merges,
interactables keep `Area2D`s, per-shape lethal-block handling) and the current milestone status
(M3 partial). Never delete `GDArtSwap` or the old component scenes before M5.

### Change the web/relay configuration

Update the Worker (`tools/web_relay_worker.js`), keep
`tools/web_relay_worker_selftest.mjs` passing, update `network/cors_proxy` in `project.godot`
and the README table, and remember the local `serve_web.py` relay must stay compatible.

## 2. Glossary

| Term | Meaning |
| --- | --- |
| **GD** | Geometry Dash (the original game) |
| **gmd** | GDShare's level exchange format (plist + level string) |
| **gdr** | GD Replay interchange format (MessagePack, 240 ticks/s) |
| **LDM** | Low Detail Mode — drops objects flagged by `DisabledInLowDetailModeAttribute` |
| **GDObject** | A node instancing a generated `gd_<id>.tscn` object scene |
| **DecorationBatch** | A node drawing many decoration sprites that share group+z+blend |
| **FrustumCuller** | Per-level node that hides objects outside the camera buffer |
| **LevelPhysics** | Shared chunked bodies for static world geometry |
| **wx / cells** | Geometry Dash grid units; 30 GD units = 1 cell = 128 px |
| **Pristine hitbox** | A hitbox matching GD's own collision exactly |
| **RobTop** | Developer of Geometry Dash; `boomlings.com` is the official server |
| **GDBrowser / GDHistory** | Community mirrors used for search/download fallbacks |
| **hogdot** | Godot 4.7.2 fork with the WebGPU driver used for the web export |
| **dlink** | Emscripten dynamic linking; the web template is a dlink build (side wasm) |
| **COOP/COEP** | Headers enabling Cross-Origin Isolation (required for SharedArrayBuffer) |
| **warnings_once** | `Toasts.warning_once(key, …)` — shows a repeated warning only once |

## 3. Cheat sheet — numbers

| Quantity | Value |
| --- | --- |
| Cell size | 30 GD units = 128 px |
| Art scale | `128 / 30 / 2 ≈ 2.1333` (hd atlas) |
| Player gravity / speed / terminal | 10600 / (1250, 2395) / 3000 (fly 1800) |
| Gamemode gravity multipliers | fly 0.5, UFO 0.7, spider 0.65 |
| Player scales | mini 0.6, wave 0.6, normal 1.0, big 1.4 |
| Player body mask | 122 |
| Layer values | solids 2, rect hazards 3, interactables 4, triggers 5, ground 6, slopes 66, solid-overlap 10, circular hazards 2048 |
| LevelPhysics | `MERGEABLE_LAYERS=[2,66,4,2048]`, `CHUNK_CELLS=24` |
| FrustumCuller | `BUCKET_CELLS=8`, `OVERSIZE_CELLS=64`, `BEHIND_BUFFER_CELLS=8`, `EDGE_EPSILON=2` |
| DecorationBatch | `BUCKET_WIDTH=256`, `CULL_THRESHOLD=1`, z stride 64, gameplay z layer 4 |
| GDObject | `Z_INDEX_LIMIT=4096`, `Z_LAYER_STRIDE=64`, `Z_LAYER_GAMEPLAY=4` |
| Colour | `COPY_ITERATIONS=8`, prefixes `g_`/`c_`/`watcher_`/`decobatch_` |
| Level open | budget 40 ms/frame; toast if open > 400 ms |
| Culling default | 5 cells |
| GDR | 240 ticks/s, `MAX_IMPORT_TICKS=240*3600` |
| RobTop | `GAME_VERSION="22"`, `PC_BINARY_VERSION="47"`, `MOBILE_BINARY_VERSION="48"`, `PAGE_SIZE=10` |
| GD defaults | `OBJ_CHANNEL=1004`, `DEFAULT_DETAIL_CHANNEL=1` |
| Editor tree | `MAX_ITEMS_PER_LAYER=1000`, throttle 0.2 s |
| Android | NDK 28.1.13356709, arm64 only, largeHeap, JDK 17 |
| Web | hogdot 4.7.2-r19, emscripten pool 8, godot pool 4, initial memory 256 MB |
| Godot | 4.7 / CI 4.7.2 |
| Godot-cpp pin | `6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918` |

## 4. Key-file index

| Need | File |
| --- | --- |
| Game loop / level open | `src/GameScene.gd`, `src/LevelBuildJob.gd` |
| Level data model | `src/Level.gd`, `src/Layer.gd` |
| Player physics | `src/Player.gd`, `src/PlayerCamera.gd` |
| Shared physics | `src/LevelPhysics.gd` |
| Decoration render path | `src/DecorationBatch.gd`, `src/static/GDDecorationLoader.gd` |
| Culling | `src/FrustumCuller.gd` |
| GD object node | `src/GDObject.gd` |
| Colours | `src/ColorChannelWatcher.gd`, `src/HSVWatcher.gd`, `src/resources/ColorChannelData.gd` |
| Interactables | `src/interactables/**` |
| Native bridge | `src/static/NativeCore.gd`, `src/NativeTriggerBridge.gd`, `native/src/gdash_native.cpp` |
| Import/export | `src/static/GMD.gd`, `GMDConverter.gd`, `GMDObjects.gd`, `GMDDefaultChannels.gd` |
| Replays | `src/static/GDRFormat.gd`, `src/static/MsgPack.gd`, `src/Replay.gd`, `src/ReplayPanelLoader.gd` |
| Online levels | `src/RobTopLevels.gd`, `src/LevelPanelLoader.gd` |
| Editor | `src/EditorScene.gd`, `src/autoloads/Editor.gd`, `src/editor/**`, `src/gui/properties/**` |
| Settings | `src/autoloads/Config.gd`, `src/SettingsMenu.gd` |
| Web | `tools/serve_web.py`, `tools/web_relay_worker.js`, `tools/pin_webgpu_templates.py`, `src/WebSoftEffects.gd` |
| CI | `.github/workflows/main.yml`, `.github/workflows/web.yml` |
| Plan of record | `GD_UNIFICATION_PLAN.md` |

## 5. Open items and unresolved questions

1. **Physics tick rate (resolved).** `project.godot` sets `physics_ticks_per_second = 240`, matching
   the 240 Hz player loop and `GDRFormat`'s 240/s file standard. Replays store no tick rate, so replays
   recorded at 120 ticks/s before this change play back at double speed.
2. **Plan milestones.** M3 is partial (editor palette repoint and `GDArtSwap` retirement
   pending), M4/M5 not started. Do not delete old component scenes or their SVG art yet.
3. **Hitbox follow-ups.** Invisible slopes 1344/1345 (homology-resolved, wants a GD
   hitbox-viewer double-check); 2.1 persp blocks 1561–1569 (solids with no atlas art, no scenes).
4. **Native unit tests are not in CI.** Six `native/tests/*.cpp` exist; none are compiled by a
   workflow. Wiring the standalone three in would be a cheap win.
5. **Amethyst/Beam diagnostics** remain device-driven; `reports/amethyst_glow.md` currently
   records failed downloads rather than analysis.
6. **`export_presets.cfg`** is tracked despite `.gitignore` listing it — keep that in mind when
   editing presets.
7. **No tags in this checkout**; history is a single squashed commit, so `git blame` gives no
   authorship signal.

## 6. Response protocol for expert-pool answers

1. **Restate** the goal in one sentence, with inferred scope.
2. **Ground** it: cite files, classes, constants (`src/LevelPhysics.gd CHUNK_CELLS=24`).
3. **Plan** the smallest change at the right layer; name touched invariants.
4. **Execute** matching the style guide; list every file changed.
5. **Verify**: name the exact commands run and what could not be run here.
6. **Risk register**: web export, Android open time, replay compatibility, editor
   serialization, native fallback — and how each would be detected.
7. **Open questions**: state unknowns as unknowns with a proposed measurement.

If a request violates a hard rule (`01-repo-and-constraints.md` §6), say so, give the reason
with evidence, and offer the compliant alternative. Ask at most one clarifying question, and
only when the answer changes the implementation.
