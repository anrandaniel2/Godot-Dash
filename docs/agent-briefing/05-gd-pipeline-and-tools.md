# 05 — Geometry Dash data pipeline and offline tools

This is the subsystem that makes Godot Dash able to open real Geometry Dash levels: a set of
GDScript decoders/encoders plus a Python asset pipeline that turns GD's cocos2d sprite sheets
into Godot-native atlases and scenes.

## 1. Import: `.gmd` → Godot level data

```
.gmd / .gmd2 / .lvl
   │  GMD.read_file / GMD.parse             (plist container)
   ├─ k4 = level string  (gzip + URL-safe base64)
   ▼
GMDConverter.import_level_string
   │  header chunk → level fields (colours, song, start state, …)
   │  object chunks → per-object dicts
   │  unknown / failing objects → ImportReport.skipped_ids (never fatal)
   ▼
GMDObjects.MAP : GD id → scene + name + components + selection type
   ▼
Level data → LevelBuildJob
```

### `GMD.gd` — container

- A `.gmd` is an Apple plist XML document; `GMD.Document` exposes `entries` and the
  decompressed `level_string`; `read_file`/`parse` never assert.
- Keys (`GMD.Key`): `k2` name, `k3` description (base64), `k4` level string, `k5` creator,
  `k8` official song, `k45` song id, `k46` revision, `k50` version/binary version, `k18`
  attempts, `k23` length.
- `k4` is gzip + **URL-safe** base64 (`-`/`_`), padding optionally stripped; official levels
  omit the standard gzip prefix (`H4sIAAAAAAAAA`).
- `write_file`/serialization handle the reverse for export.

### `GMDConverter.gd` — semantics (1,823 lines, largest script)

- `Prop` is the object-key table: `1` id, `2`/`3` x/y, `4`/`5` flips, `6` rotation,
  `21`/`22` main/secondary colour, `32` scale, `57` groups, `41`/`43` main HSV,
  `25` z-order, `35` opacity, `51` target group, `71` centre group, `110` camera-static exit,
  `10` duration, `31` text, `128`/`129` scale x/y, `11` touch-triggered, `7`/`8`/`9` RGB,
  `15`/`16` player colours, `50` copied colour id, `49` copied-colour HSV, `60` copy opacity,
  `17` blending, `28`/`29` move x/y, `23` target colour id, `68` degrees, `33` legacy single
  group, `30` easing, `45` fade-in, `97` spin, `96` glow, `103` high detail, `24` z layer.
- Header fields map to `Level` exports (song, colour channels `kS38`, start state, etc.);
  `GMDDefaultChannels` supplies per-object default channels (see §5).
- Colour, copy-channel and trigger-track semantics were ported from GDRWeb's TypeScript
  implementation (vendored under `third_party/gdrweb/`, MIT, credited in `CREDITS.md`).
- Export reverses the mapping: `Level.to_data` → object dicts → level string
  (`GMDObjects.get_gd_id` recovers ids), written back into a plist.

### `GMDObjects.gd` — id table

- `MAP: Dictionary[int, Dictionary]`, each entry
  `{"scene": "<path under res://>", "name": "<node name>", "colorable": bool, "components": [...], "type": EditorSelectionCollider.Type, "id": <variant>}`.
- Directory constants: `SOLIDS`, `HAZARDS`, `ORBS`, `PADS`, `GAMEMODE_PORTALS`,
  `OTHER_PORTALS`, `SPEED_PORTALS`, `TRIGGERS`, `LEVEL_COMPONENTS`, and `GD_OBJECT_SCENES`
  (`scenes/gd_objects/`) for the generated family.
- `NATIVE_EFFECT_TRIGGER_IDS` lists trigger families executed by C++ (`NativeTriggerBridge`
  consults it before disabling trigger `Area2D`s).
- Policy: **only mapped ids import**; everything else is skipped and counted.

### `GMDDefaultChannels.gd`

- `OBJ_CHANNEL = 1004` (most bases), `DEFAULT_DETAIL_CHANNEL = 1`; `BASE`/`DETAIL` dictionaries
  list exceptions only (e.g. `1010` Black for pits/saws, `1005`/`1006` families, `0` = untinted
  for portals/pads/orbs/coins).
- Rationale (from the header): treating a missing key as "no channel" produced solid white
  blocks, because many GD frames are white masks meant to be tinted.

### `GDObjectFrames.gd` + `GDSpriteSheet.gd`

- `GDObjectFrames` loads `res://assets/textures/gd_atlas/object_frames.json`, optionally merged
  with `user://gd_object_frames.json`; colour classes `base`/`detail`/`black`/`glow`;
  `EMPTY_FRAME = "emptyFrame.png"`, `Z_UNKNOWN = -9999`.
- `GDSpriteSheet.load_all()` loads the packed atlas JSON in one pass
  (`ATLAS_JSON = assets/textures/gd_atlas/gd_objects_atlas.json`); if absent it falls back to
  parsing the cocos2d `.plist` sources in `assets/textures/gd_atlas/source/` and un-rotating
  frames at runtime (`_load_cocos_into`, `_unrotate`, `parse_plist` — a hand-written plist
  parser). The packed path is the shipping one.

### `GDDecorationLoader.gd` — decoration → batches

- Static, lazily loads the sheet; `art_scale()`, `can_draw(gd_id)`, `diagnose()`,
  `_note_bad_frame` diagnostics.
- `build_batches(objects, art_scale)` (one-shot) and `new_batches()` / `add_object()` /
  `finish_batches()` (sliced, streaming-friendly).
- Batch keys combine group set + z layer + blend mode; `Z_LAYER_STRIDE = 64`,
  `Z_LAYER_GAMEPLAY = 4`; draw orders `DRAW_ORDER_GLOW = -1000`, `ROOT = 0`, `DETAIL = 1000`;
  channel groups `decobatch_<channel>`.
- `serialize_batch(batch, art_scale)` expands a batch back into per-object export entries.

## 2. Export: Godot level data → `.gmd`

- `Serialize.gd` / `Deserialize.gd` handle Godot-typed values (Transform2D, Vector2/2i,
  Color, PackedStringArray, …) inside the level dictionary; `Serialize.Reason` is `SAVE`
  (file-safe, resources must be explicit) or `PRACTICE` (transient).
- `Level.to_data` produces the full document (see `08-formats-and-schemas.md`); decoration
  batches expand to individual entries; native-elided triggers are re-appended from
  `native_trigger_records`.
- Export goes through `LevelOperationsHandler._on_export_level_dialog_file_selected`, comparing
  the level's `game_version` and warning about unsupported features.

## 3. Object scene generation (Python → 3,936 scenes)

Run in this order:

```bash
python3 tools/build_object_frames.py --id-list tools/gd_object_id_list.txt
python3 tools/build_godot_atlas.py            # add --all to include unused frames
python3 tools/build_gd_object_scenes.py       # --keep-existing / --only 8,39 for control
```

### Step 1 — `build_object_frames.py` → `assets/textures/gd_atlas/object_frames.json`

- The GD object→frame table lives inside the game binary (`ObjectToolbox::init`) and is not
  shipped as data, so the tool consumes a dumped list (`tools/gd_object_id_list.txt`,
  `<id>:<frame name>` lines).
- Multi-sprite objects come from `tools/gdrweb_objects_22.json` (GDRWeb 2.2 table, ids 1–4539):
  each sprite's texture, colour class, position, scale, flip, rotation, content size, draw
  order. Positions are converted with `center = position + R(rot)·S(scale)·(contentSize/2)`;
  sprite opacity still comes from the older `tools/gdrweb_objects.json` dump (~70 sprites need
  it).
- Validated against the 2.1-era dump: for the ~1,600 objects both tables describe, sprite
  centres agree within 0.01 units.
- Output per id: the ordered sprite stack with trim offsets + default z layer/order.

### Step 2 — `build_godot_atlas.py` → `assets/textures/gd_atlas/gd_objects_atlas_*.png` + `.json`

- Copies each needed frame out of its cocos2d sheet, **un-rotates** 90°-packed frames, packs
  into as few 4096² pages as possible (currently one page, `gd_objects_atlas_0.png`, 2.9 MB),
  and writes `gd_objects_atlas.json` = per-frame page/rect/trim offset/untrimmed size, exactly
  what the plists carried, in a shape `GDSpriteSheet.gd` loads in one pass.
- Writes/updates a `.png.import` per page, **preserving the Godot UID** so regenerating keeps
  the generated scenes valid. Pages are lossless, no mipmaps.

### Step 3 — `build_gd_object_scenes.py` → `scenes/gd_objects/gd_<id>.tscn`

Scene layout:

```
GD<id>                       Node2D + src/GDObject.gd (gd_id, bounds)
├── [Detail]                 Node2D — secondary-channel sprites when GD draws them under the base
├── Base                     Node2D — main-channel sprites (always-black tinted black)
│   ├── [Glow]               Sprite2D additive, hidden unless the placement asks for glow
│   ├── Root                 the object's own sprite
│   └── Sprite<n>            extra parts in draw order
├── [Detail]                 …or here when GD draws detail on top
├── Collision                StaticBody2D on the solids layer — hand-authored shapes live here
│   └── Hitbox               CollisionShape2D placeholder
└── EditorSelectionCollider  editor picking box sized to the artwork; freed in game
```

- Constants shared with runtime: `SCRIPT_PATH = res://src/GDObject.gd`,
  `ADDITIVE_MATERIAL_PATH = res://resources/AdditiveBlendingMaterial.tres`, and the
  128 px/cell ÷ 30 GD-units art scale.
- Re-running **preserves the `Collision` subtree** (and anything it references) plus the scene
  UID, so hand-authored hitboxes survive atlas updates. `--keep-existing` skips existing
  scenes; `--only 8,39` limits the run.
- Each generated scene sets `texture_filter = 1` (nearest) and `metadata/_editor_description_`
  naming the source frame (e.g. `"Geometry Dash object 8 (spike_01_001.png)"`).
- Hitbox generation uses `tools/gd_collision_specs.py`, which reads
  `tools/gd_hitbox_data.json` (game-extracted) plus a legacy block rule, and emits real shapes
  while keeping `Collision` replaceable until hand-edited.

## 4. Hitbox data quality (`GD_UNIFICATION_PLAN.md` §4 / TODOs)

Resolved via `tools/gd_hitbox_data.json`:

- `1202–1205` / `1220–1222` (`blockOutlineThick_*`): 1202/1220 are solid thin bars
  (30×3 / 30×6 GD-unit strips), 1203/1204 and 1221/1222 solid full squares, 1205 decoration.
- Sawblade family radii **32.3 / 21.6 / 12 GD units** → 137.8 / 92.2 / 51.2 scene px.
- Spikes use the real thin box centred in the spike (6×12 GD units for id 8) rather than the
  old inset base box.

Remaining/lower confidence:

- Invisible slopes 1344/1345 orientations (resolved by homology with 1341/1342; a GD
  hitbox-viewer double-check is still wanted).
- 2.1 "persp" blocks 1561–1569 are solids per game data but have **no atlas art**, so no scenes
  exist for them yet.

## 5. The unification plan — `GD_UNIFICATION_PLAN.md` (769 lines)

The plan of record. Read it before touching `Level`, `LevelPhysics`, `GDObject`, `GDArtSwap`,
`GMDConverter`, `GMDObjects` or the editor object pipeline.

**Goal:** use the generated `scenes/gd_objects/gd_<id>.tscn` scenes *instead of* the hand-made
`scenes/components/level_components/**` object scenes (solids, hazards, orbs, pads, portals,
triggers, letter objects) everywhere, including the editor; draw object art only from the GD
atlases; one physics body per level; pristine GD hitboxes.

**Locked decisions:**

- Merge the **static world only** — solids/slopes/ground into shared `StaticBody2D`s,
  rectangular hazards into one shared hazard `Area2D`, circular hazards into another.
  Interactables keep per-object `Area2D`s (editor tab, components, signals depend on them).
- Lethal wall/ceiling hits keep today's behaviour via per-shape disable/re-enable.
- Saved-level migration is **not required**; old levels referencing deleted component scenes
  may break.

**Milestones:**

| | Status |
| --- | --- |
| M1 — collision data + generator (`gd_collision_specs.py`, `gd_hitbox_data.json`) | done |
| M2 — shared level body + Player per-shape death (`LevelPhysics`) | **shipped 2026-09-07** |
| M3 — gameplay objects instantiate from gd scenes (static set) | **partial**: import + load/save shipped; editor palette repoint + `GDArtSwap` retirement pending |
| M4 — interactables on gd scenes (behaviour subtree, editor mapping, palette swap) | pending |
| M5 — deletion & cleanup (old object scenes, SVG art, `GDArtSwap`, docs) | pending |

**Target shape for gameplay entries** (from the plan):

```gdscript
{
  "scene_file_path": "scenes/gd_objects/gd_8.tscn",  # identity
  "gd_object_id": 8,                                   # kept on gameplay too
  "name": ..., "transform": ..., "groups": ..., "color_channels": ..., "hsv": ...,
  "components"/"markers": ...,                          # interactables only
  "attributes"/"physics"/"texture_override": ...,
}
```

**Interactable gd-scene shape (M4):**

```
GD<id> (Node2D + GDObject: art, channels, groups)
├── Base/Detail …
├── Collision              (data; consumed by the level physics builder, freed at build)
└── Behaviour (Area2D + OrbInteractable/PadInteractable/TriggerInteractable…)
    ├── JumpBoostComponent …  (per-ID exports identical to the old scenes)
    ├── Hitbox                (PRISTINE touch hitbox)
    └── EditorSelectionCollider
```

Also documented there: the transform-changer carve-out (solids driven by move/rotate/scale
triggers cannot merge), the streaming redesign passes with their time-budget rule, and device
investigation notes (Amethyst, Orbit, white beams).

## 6. Online level access — `src/RobTopLevels.gd` (996 lines)

- Endpoints: `SEARCH_URL`, `DOWNLOAD_URL`, `SONG_INFO_URL` on `www.boomlings.com/database/`
  (plus a non-www fallback), `COMMON_SECRET = "Wmfd2893gb7"`, `GAME_VERSION = "22"`,
  `PC_BINARY_VERSION = "47"`, `MOBILE_BINARY_VERSION = "48"`, `PAGE_SIZE = 10`,
  `TRANSIENT_HTTP_STATUSES = [408,425,429,500,502,503,504]`, `NETWORK_ATTEMPTS = 3`.
- Search uses GDBrowser (CORS-friendly) for web; downloads go direct on desktop/Android,
  falling back to GDHistory (`history.geometrydash.eu/api/v1/level/<id>/`) and custom-song CDNs
  (`_download_custom_song`, `_download_audio`), with progress reporting.
- Web: `downloads_available()`, `web_relay()` read `network/cors_proxy` (project) or
  `Config.cors_proxy` (user); when absent the build shows `WEB_RELAY_REQUIRED`/`WEB_RELAY_HINT`
  instead of throwing CORS errors. `_served_from_dev_server()` detects the local
  `serve_web.py` relay.
- `download_sfx(sfx_id)` feeds `SFXManager`; `preload_sfx` preloads ids found via
  `NativeCore.extract_level_sfx_ids`.
- `LevelPanelLoader` (`src/LevelPanelLoader.gd`) is the UI driver: local/online browsing
  (`ONLINE_CATEGORY_TYPES = [4, 3, 1, 2, 6, 11]`), paging, threaded `.meta` reads, download +
  import, Android SAF picker, sorting (`reorder`).

## 7. Level list and metadata

- Levels live in `user://created_levels/levels/*.bin` (gzip) with `<name>.meta` sidecars
  written by `LevelOperationsHandler.write_level_meta`.
- `LevelPanel` (`src/LevelPanel.gd` + `scenes/components/game_components/LevelPanel.tscn`)
  renders one list row (title, creator, description, version, rating, flashing-lights badge,
  play/edit/remove buttons); `LevelPanelLoader` builds/sorts them and handles import/export.
- The menu never decodes a level to display it — that is the sidecar's purpose.

## 8. Amethyst investigation tooling

Device crash/visual investigations have permanent tools (keep them working):

| Tool | Purpose |
| --- | --- |
| `tools/amethyst_boot_test.gd/.tscn` | boots the Amethyst level through the native runtime to reproduce the device crash in CI |
| `tools/analyze_amethyst_glow.py` | static analysis of the level's glow/colour usage; writes `reports/amethyst_glow.md` |
| `tools/validate_amethyst.py` | downloads the level (GDHistory → boomlings → GDBrowser → committed snapshot) and validates structure; used by the analysis |
| `src/GameScene.gd` `_print_process_memory` | prints `/proc/self/status` RSS/HWM at level lifecycle points (`grep gdash-mem`) |
| `Level._print_beam_diagnostics_live` | rolling BEAMDIAG heartbeat every 5 s (`grep "BEAMDIAG live"`) |

`reports/amethyst_glow.md` currently records a CI run where every download source failed
(403/SSL/no snapshot) — treat downloaded-level analyses as best-effort and commit snapshots
when possible.
