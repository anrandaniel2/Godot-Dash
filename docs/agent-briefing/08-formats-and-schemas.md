# 08 — On-disk formats and data schemas

## 1. Level data dictionary (internal)

Produced by `Level.to_data(reason)` (`src/Level.gd`), consumed by `Level.use_data(data, options)`
and by `LevelBuildJob`. Stored as gzip `.bin`; also the shape of practice snapshots and of the
in-memory caches (`GameScene.cached_level_data`, `Editor.level_data_snapshot`).

```gdscript
{
  "game_version": String,                 # ProjectSettings application/config/version
  "name": String, "creator": String, "description": String,
  "creation_date": int, "rating": int, "flashing_lights": bool, "is_editable": bool,
  "song_path": String, "song_start_time": float,
  "platformer": bool,
  "start_position": Vector2,
  "start_internal_gamemode": int, "start_displayed_gamemode": int,
  "start_freefly": bool,
  "start_speed": float, "start_speed_preset": int, "start_reverse": bool,
  "start_gameplay_rotation_degrees": float,
  "start_gravity_multiplier": float, "start_gravity_flip": int,
  "default_background_color": Color, "default_ground_color": Color,
  "default_line_color": Color,
  "transition_width": float, "fade_power": float, "move_power": float, "scale_power": float,
  "color_channels": [ColorChannelData.to_data, …],
  "duration": float,
  "native_trigger_records": [ … ],        # generic 2.2 triggers elided from the tree
  "layers": [
    { "name": String, "locked": bool, "objects": [ <object entry>, … ] },
    …
  ],
  "active_layer_idx": int,
  "player_data": { "groups": [...], "hsv": {...} },
  "practice_data": {                       # only for Serialize.Reason.PRACTICE
    "player_velocity": Vector2,
    "replay": Replay,
    "physics_tick": int,
    "elapsed_time": float,
  },
}
```

### Object entry

Two shapes share keys; `decoration` distinguishes them.

```gdscript
# gameplay object
{
  "name": String,
  "scene_file_path": "scenes/components/level_components/orbs/YellowOrb.tscn",
  "gd_object_id": int,                    # present once on the gd-scene pipeline
  "transform": Serialize.Transform2D,     # {"x":[..],"y":[..],"origin":[..]}
  "groups": [...], "hsv": {...},
  "components": { "<ClassName>": { <exported fields> } },
  "markers": [ "<ClassName>", … ],
  "attributes": [ "LDM", … ],             # script basenames under src/attributes/
  "physics": { … },                       # physics overrides
  "texture_override": { … },
}

# decoration object (generated gd scene, or batched)
{
  "name": String,
  "decoration": true,
  "gd_object_id": int,
  "transform": …, "groups": …, "color_channels"/"hsv": …,
  "z_layer": int, "z_order": int, "blending": bool, "glow": bool,
  "high_detail": bool,
}
```

Serialization rules: `Serialize.Reason.SAVE` requires explicit resource handling
(`Component._field_to_data` assert); `PRACTICE` keeps live objects. `DecorationBatch`es expand to
one entry per object via `GDDecorationLoader.serialize_batch`; native-elided triggers are
re-appended from `native_trigger_records` when the runtime omitted them.

## 2. `.gmd` / `.gmd2` (GDShare)

Apple plist XML. `GMD.Key`:

| Key | Meaning |
| --- | --- |
| `k2` | level name |
| `k3` | description (base64) |
| `k4` | level string (gzip + URL-safe base64) |
| `k5` | creator |
| `k8` | official song id |
| `k45` | custom song id |
| `k46` | revision |
| `k50` | version / binary version |
| `k18` | attempts |
| `k23` | length |
| `k13` | bool flag (e.g. two-player) |

`.gmd2` is the zipped variant that can also carry the level's song. `.lvl` is accepted by the
import filter. Official levels omit the gzip header prefix (`H4sIAAAAAAAAA`).

### GD level string grammar

```
<header chunk> ; <object chunk> ; <object chunk> ; …
```

- Chunks are `;`-separated; each chunk is `key,value,key,value,…`.
- Header carries level-wide keys (song, colours `kS38`, start state, `kA*` settings).
- Object keys: `1` id, `2` x, `3` y, `4`/`5` flip x/y, `6` rotation, `21`/`22` main/detail
  channel, `32` scale, `57` groups (`.`-separated), `41`/`43` main HSV, `25` z order,
  `35` opacity, `51` target group, `71` centre group, `110` static exit, `10` duration,
  `31` text, `128`/`129` scale x/y, `11` touch triggered, `7`/`8`/`9` RGB, `15`/`16` player
  colours, `50` copied colour id, `49` copied-colour HSV, `60` copy opacity, `17` blending,
  `28`/`29` move x/y, `23` target colour, `68` degrees, `33` legacy single group, `30` easing,
  `45` fade-in, `97` spin, `96` glow, `103` high detail, `24` z layer.
- Unknown ids are recorded in `ImportReport.skipped_ids`; per-object conversion errors are
  caught and skipped.

## 3. `.gdr` replays (GDR 1)

- Container: MessagePack (preferred) or JSON; see `src/static/MsgPack.gd` for the hand-written
  codec and `src/static/GDRFormat.gd` for semantics.
- Document: author/bot/level metadata, `framerate` (240 standard), `inputs` =
  `[{ "2p": bool, "btn": 1|2|3, "down": bool, "frame": int }, …]` sorted by frame.
- Buttons: `1` jump, `2` left, `3` right. Platformer wave-descend edges live in a `dashExt`
  dictionary (xdBot-style extension) so other tools ignore them and Godot Dash round-trips
  losslessly.
- Constants: `BOT_NAME = "Godot-Dash"`, `GAME_VERSION = 2.2`, `FORMAT_VERSION = 1.0`,
  `FILE_EXTENSION = ".gdr"`, `GDR_STANDARD_FRAMERATE = 240`, `MAX_IMPORT_TICKS = 240*3600`.
- Impimport resamples foreign framerates; player-2 events are ignored (duals mirror player 1).
- Golden bytes in `tools/gdr_selftest.gd` embed the app version — regenerating them is required
  after a version bump.

## 4. `.meta` level sidecars

Written by `LevelOperationsHandler.write_level_meta(path, data)` next to each `.bin`
(`LEVEL_META_EXTENSION = ".meta"`). The level selector reads only sidecars (never decodes a
level just to list it). Fields mirror the list UI: name, creator, description, rating,
flashing-lights flag, creation date, duration, version.

## 5. Config (`user://config.cfg`)

A `ConfigFile` with sections matching `Config` groups; see `02-runtime-architecture.md` §3 for
the full key list. Notable specials:

- `Keybinds/input_map` — `Dictionary[StringName, Array]` of action → events.
- `Performance/defaults_version` — migration counter.
- `Graphics/web_soft_glow` — one-time web bloom migration marker.
- `Graphics/max_fps` — defaults to the detected panel refresh rate on first launch.

## 6. Input actions (`project.godot [input]`)

Gameplay: `jump`, `move_left`, `move_right`, `platformer_wave_down`, `restart_level`,
`pause_level`, `toggle_hitbox_visibility`, `practice_create_checkpoint`,
`practice_remove_checkpoint`.

Editor: `editor_add`, `editor_add_swipe`, `editor_remove`, `editor_remove_swipe`,
`editor_rotate_90`, `editor_rotate_45`, `editor_place_mode`, `editor_edit_mode`,
`editor_selection_filters_mode`, `editor_delete`, `editor_select_all`, `editor_deselect`,
`editor_selection_remove`, `editor_duplicate`, `editor_selection_area_move`, `editor_flip_h`,
`editor_flip_v`, `editor_new_level`, `editor_save`, `editor_save_as`, `editor_open_level`,
`editor_import_level`, `editor_export_level`, `editor_hide_panels`, `editor_rotate_free`,
`editor_quick_rotate_free`, `editor_scale`, `editor_quick_scale`, `editor_focus_input`,
`editor_move`, `editor_quick_move`, `editor_toggle_playtest`, `editor_move_left/right/up/down`.

Misc: `gui_input_reset_default`, `ui_accept_keep_focus`, `hide_pause_menu`, plus the standard
`ui_*` actions. Shader globals exposed to the editor: `menu_blur`, `blur_strength`, `ui_color`,
`icon_hue_shift_speed` (`[shader_globals]`).

## 7. Asset pipeline artefacts

| File | Producer | Consumer | Shape |
| --- | --- | --- | --- |
| `assets/textures/gd_atlas/object_frames.json` | `build_object_frames.py` | `GDObjectFrames.gd`, `build_godot_atlas.py`, `build_gd_object_scenes.py` | GD id → ordered sprites (frame, colour class `base/detail/black/glow`, position, scale, flips, rotation, content size, draw order, default z layer/order) |
| `assets/textures/gd_atlas/gd_objects_atlas_0.png` (+ `_1`, …) | `build_godot_atlas.py` | Godot importer / scenes | 4096² pages, lossless, no mipmaps, UID preserved on regeneration |
| `assets/textures/gd_atlas/gd_objects_atlas.json` | `build_godot_atlas.py` | `GDSpriteSheet.load_all()` | frame name → page + rect + trim offset + untrimmed size |
| `assets/textures/gd_atlas/source/*-hd.{png,plist}` | GD (vendored) | atlas builder; runtime plist fallback | cocos2d sheets |
| `tools/gd_hitbox_data.json` | `extract_gd_hitboxes.py` | `gd_collision_specs.py` | GD-exact hitboxes per object id |
| `tools/gd_object_id_list.txt` | dumped from GD | `build_object_frames.py` | `<id>:<frame name>` lines |
| `tools/gdrweb_objects.json`, `tools/gdrweb_objects_22.json` | GDRWeb dumps | `build_object_frames.py` | per-id sprite stacks (2.1 opacity, 2.2 geometry) |
| `scenes/gd_objects/gd_<id>.tscn` | `build_gd_object_scenes.py` | `Level`, editor | generated object scenes (see below) |

### Generated scene contract

```
[gd_scene load_steps=N format=3 uid="uid://…"]     # UID preserved across regeneration
ext: src/GDObject.gd, EditorSelectionCollider.gd, atlas page texture, AdditiveBlendingMaterial.tres
node GD<id>            Node2D, texture_filter = 1, gd_id, bounds, description = "Geometry Dash object 8 (spike_01_001.png)"
├── Base / Detail …    sprites (AtlasTexture sub-resources with regions)
├── Collision          StaticBody2D (solids layer) + Hitbox placeholder
└── EditorSelectionCollider
```

`Base`/`Detail` node names are the contract used by `Level`, `PlaceHandler`, `BaseDetailHandler`
and the colour-watcher wiring. `Collision` subtrees are preserved by the generator.

## 8. Metadata keys and group names

| Kind | Name | Meaning |
| --- | --- | --- |
| group | `g_<id>` | GD group id |
| group | `c_<id>` | colour channel |
| group | `watcher_<id>` | `ColorChannelWatcher` registries |
| group | `decobatch_<channel>` | decoration batches following a channel |
| group | `_gd_native_trigger` | triggers handed to the native runtime |
| meta | `layer` (`Constants.LAYER_META`) | owning `Layer` |
| meta | `texture_override`, `attributes`, `hsv_watcher`, `base`, `detail` | object/component wiring |
| meta | `gd_object_id`, `gd_properties`, `gd_trigger_flags`, `gd_source_order` | GD trigger metadata |
| meta | `gd_gameplay` | marks a gameplay placement on the gd-scene path |
| meta | `_gd_level_physics_*` | `LevelPhysics` bookkeeping (body/merged/snapshot/descriptors/dirty/shapes/dynamic groups) |
| setting | `network/cors_proxy` | web relay URL prefix |

## 9. `third_party/gdrweb/`

Vendored MIT TypeScript reference implementation of GD level rendering (licence and
`VENDOR_NOTE.md` inside). Used as the semantics reference for colour channels, copy channels and
trigger tracks — changes that touch those semantics should be checked against it. Attribution is
in `CREDITS.md` (object geometry/defaults/z-order data by Opstic & Maxnut via GDRWeb).
