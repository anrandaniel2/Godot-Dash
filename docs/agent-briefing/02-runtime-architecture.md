# 02 — Runtime architecture

## 1. Boot and singletons

`project.godot [autoload]`, in order:

| # | Name | Source | Responsibility |
| --- | --- | --- | --- |
| 1 | `LevelManager` | `src/autoloads/LevelManager.gd` | live game state: `game_scene`, `current_level`, `current_level_path`, `attempt`, `level_playing`, `pause_menu`, `player`, `player_duals`, `player_camera`, `background_sprites`, `ground_up/down`, `song_player`, `platformer`, `practice_mode`, `practice_level_snapshots`, `touchscreen_controls`; creates `user://` dirs on boot |
| 2 | `SFXManager` | `src/autoloads/SFXManager.gd` | pooled `AudioStreamPlayer`s, `play_sfx`/`play_sfx_id`, download-on-demand SFX (`_download_sfx_async`), `preload_sfx(ids)` |
| 3 | `GroundData` | `src/autoloads/GroundData.gd` | shared ground scroll state (`offset`, `distance`, `center`) |
| 4 | `MusicVolume` | `src/autoloads/MusicVolume.gd` | music bus level + spectrum scalar used by `Level.music_scale` |
| 5 | `Config` | `src/autoloads/Config.gd` | **all settings** (`user://config.cfg`), see §3 |
| 6 | `Toasts` | `src/autoloads/Toasts.gd` | toast notifications (`new_toast`, `error`, `warning`, `warning_once`) |
| 7 | `SceneManager` | `src/autoloads/SceneManager.gd` | `TITLE_SCREEN / EDITOR / LEVEL` tracking + transitions |
| 8 | `Files` | `scenes/autoloads/Files.tscn` | `FileDialog` flows: `load()`, `import_and_load()`, corrupted-level dialog |
| 9 | `AssetManager` | `src/autoloads/AssetManager.gd` | packed scenes, threaded song/font loading, icon cache, fade-enter shader |
| 10 | `Editor` | `src/autoloads/Editor.gd` | editor state (see `04-editor.md`) |
| 11 | `KeymapLoader` | `src/autoloads/KeymapLoader.gd` | resolves `Config.input_map` into actions |
| 12 | `InputUtils` | `src/autoloads/InputUtils.gd` | per-frame action state cache (`add_action`, `update`, `is_action_*`, `get_axis`), `confined_hidden_mouse_mode()` |
| 13 | `DebugMenu` | addon (uid `uid://cggqb75a8w8r`) | in-game debug overlay (FPS, memory, level stats) |
| 14 | `DiscordRPCManager` | `src/autoloads/DiscordRPCManager.gd` | Discord Rich Presence (`available` flag, presence updates) |
| 15 | `SignalLens` | addon (uid `uid://85rkx60vm7a7`) | signal inspection tool |
| 16 | `UpdateManager` | `uid://2ut2ck6qiter` | version check against Codeberg releases API; `Status.DISABLED` on web by design |

Rules: autoload **order** is load-bearing (`Config` before readers, `LevelManager` before
anything that touches the live level). `Editor.in_editor` is derived from `Editor.root != null`.

## 2. Scenes and flows

```
TitleScreen.tscn ──(SubsceneManager: LevelSelector / IconGarage / CommunityMenu / SettingsMenu)
       │  play / edit
       ▼
GameScene.tscn ──[LevelBuildJob]──► Level (Node2D) ── Layers ──► objects / batches
       ▲                                   ▲
       └── EditorScene.tscn ── playtest ───┘
```

- `SubsceneManager` (`src/SubsceneManager.gd`) drives the title-screen subscenes
  (`TITLE_SCREEN`, `LEVEL_SELECTOR`, `ICON_GARAGE`, `COMMUNITY_MENU`, `SETTINGS_MENU`),
  with camera, fade, menu loop, and a static `editor_scene` cache. Don't confuse it with
  `SceneManager` (the three main scenes).
- `MenuLoop` (`src/MenuLoop.gd`) is an `AudioStreamPlayer` that swaps between the default menu
  loop (`Config.menu_loop`) and a custom song while preserving playback position.
- `AssetManager` (`src/autoloads/AssetManager.gd`) preloads `player_packed`,
  `title_screen_packed`, `editor_packed`, `game_scene_packed`, `menu_loop`, the fade-enter
  shader + canvas-group variant, and the icon cache. Threaded song loading
  (`load_song_threaded_request` / `load_song_threaded_get`) is the norm — never block the main
  thread on audio.
- `FadeScreen` (`src/FadeScreen.gd`) + `Config.transition_duration` handle scene transitions;
  `anticipate_fade_out()` is used before a level's paced build.

## 3. Config

`src/autoloads/Config.gd` (437 lines) is a single `ConfigFile` (`user://config.cfg`) behind one
autoload. Exported groups → JSON keys:

| Group | Keys (file section) |
| --- | --- |
| Graphics | `max_fps` (defaults to the panel refresh rate), `vsync`, `window_mode` (forced `WINDOWED` on web — browsers require a user gesture for fullscreen), `render_scale`, `anti_aliasing`, `texture_filtering`, `bloom`, `menu_blur`, `blur_strength`, `ui_color`, `transition_duration` |
| Performance | `enable_title_screen_icons`, `ldm`, `culling_enabled`, `culling_buffer_cells` (4–200, default 5), `paced_level_open`, `level_open_frame_budget_ms` (4–120, default 40), `use_native_core`, `import_gd_decorations`, `use_gd_artwork`, `show_particles_in_editor`, `particles_visibility`, `preprocess_particles_in_editor`, `particles_preprocessing` |
| Gameplay | `show_percentage`, `click_on_steps`, `noclip` |
| Practice | `automatic_checkpoints`, `automatic_checkpoint_distance` (10.0) |
| Audio | `master_audio_level`, `music_audio_level`, `game_sfx_audio_level`, `in_level_sfx_audio_level`, `mute_game_on_unfocus`, `menu_loop` |
| Keybinds | `input_map` (`@export_storage` `Dictionary[StringName, Array]`) |
| Editor | `hide_grid_on_playtest`, `editor_trail`, `autosave_delay`, `username`, `default_render_mode`, `hidden_layers_alpha`, `selection_zone_color`/`_fill_alpha`, `trigger_hitbox_color`/`_fill_alpha`, `has_seen_navigation_help` |
| Debug | `draw_debug_overlays`, `touch_screen_mode` (`TouchScreenMode`), `is_touch_screen` (`@export_storage` intermediate) |
| Easter Eggs | `enable_easter_eggs` |
| Internet | `check_for_updates`, `discord_rich_presence`, `cors_proxy` |
| Icons | `primary_color`, `secondary_color`, `glow_color`, `outline_color`, `icon_paths`, `icon_hue_shift_speed` |
| Misc | `saved_window_size` |

Notable behaviours:

- A **`defaults_version` migration** exists under `Performance` (version 1 rewrites `max_fps`,
  `anti_aliasing`, `culling_buffer_cells` on upgrade).
- A **one-time web bloom migration** (`Graphics/web_soft_glow`) re-enables bloom because the old
  web build disabled Compatibility glow.
- Enums live in `Config`: `WindowMode`, `TextureFilteringMode`, `TouchScreenMode`,
  `ParticleVisibility`/`ParticlePreprocessing` (bitflags), `RenderMode.Mode`.
- New settings must follow `CONTRIBUTING.md`: same order in menu and `Config`, add load in
  `_init` **and** write in `save()`, no inverted booleans, enums start at "Disabled" and go
  low→high, related booleans may be a bit flag, intermediates are `@export_storage`.

## 4. Level lifecycle

### Build

`Level.from_data(data)` creates a `LevelBuildJob` and steps it with an unlimited budget; the game
uses the same job with a per-frame budget:

```gdscript
# GameScene._open_level_paced()
LevelManager.current_level = job.level          # publish BEFORE stepping (see below)
while not job.finished:
    job.step(Config.level_open_frame_budget_ms)
    await get_tree().process_frame
```

`LevelBuildJob` (`src/LevelBuildJob.gd`):

- Instantiates layer by layer, object by object (`_place`), one placement per `_work()` call.
- **Runtime:** decoration entries are appended to `_decoration_data` and flushed per layer into
  `DecorationBatch` nodes (`GDDecorationLoader.build_batches`) when the layer seals (`_seal_layer`).
- **Editor:** decoration keeps per-object `GDObject` scenes so they can be selected and edited.
- Gameplay entries always instantiate real scenes (`Level.instantiate_object_from_data`).
- `_finish()` calls `level.use_data(_data, true)` and connects
  `level.ready → setup_color_channel_watchers` one-shot.
- If the native core is available, `NativeLevelBuildJob` takes over (same public API:
  `initialize` / `step` / `is_finished` / `get_level`).

**Invariant:** publish `LevelManager.current_level` *before* stepping the job. Component setters
consult the current level; the comment in `GameScene._open_level_paced()` records that
publishing late caused thousands of colour-trigger errors.

### Play / restart / leave

- `Level.start_level()`: awaits unpause, plays the song (`song_start_time`), resets the
  stopwatch, calls `LevelPhysics.prepare(self)` (shared bodies built/rebuilt before the player
  moves), then sets `LevelManager.level_playing = true` — which is what starts `FrustumCuller`.
- `Level.stop_level()`: stops the song, clears `player_duals`, clears `level_playing`.
- `GameScene.restart_level()`: repositions the player, `reset()` (time scale, native runtime,
  ground, duals, player, camera), re-applies practice snapshot or cached level data, then
  `start_level()`.
- `GameScene._on_leave_pressed()`: stops levels, `LevelPhysics.teardown`, disables player and
  camera processing, fades in — the canonical teardown path; keep it leak-free.
- Practice: `Player.place_checkpoint()` → `CheckpointPlacementBuilder` (builder pattern; adds a
  `Checkpoint` sprite and appends `LevelManager.practice_level_snapshots` with a full
  `to_data(Serialize.Reason.PRACTICE)` snapshot). Restart restores the last snapshot, which
  duplicates the whole level (documented in `GameScene`).

### Streaming

For large imported levels, decoration (and later gameplay) is streamed in chunks by
time-budgeted queues rather than built at once. The design rule from `GD_UNIFICATION_PLAN.md`
(seventh pass) is binding: **budgets are wall-clock milliseconds, not work units**, with small
slice constants bounding overshoot (`PLAY_DRAIN_MS = 4`, `PRELOAD_DRAIN_MS = 8`, plus
`ATTEMPT_BOOST_FRAMES`/`MULTIPLIER`), a per-chunk `GDDecorationLoader` accumulator across
frames (`add_object` + `finish_batches`), and no "force-finish this chunk now" path. Overlay
counters: `stream Xms`, `live`, `deco <live>(+<building>)`.

## 5. Rendering pipeline for levels

### Decoration batching — `src/DecorationBatch.gd`

- A `DecorationBatch` is a `Node2D` drawing many sprites (an inner `Item` `RefCounted` class
  holds texture, atlas region, local transform, modulate, base alpha, HSV shift, z order, draw
  order, `gd_id`, colour channel, layer kind, spin state, etc.).
- Batch key: **GD group set + z layer + blend mode** (plus colour channel groups
  `decobatch_<channel>`). Target: ~800 batches for a ~170k-object import versus ~1M nodes.
- Culling: `BUCKET_WIDTH = 256`, `CULL_THRESHOLD = 1`, plus native canvas filtering when the
  extension is present (`get_item_transform`/`set_visible_buckets`/`sort_decoration_indices`).
- Saving expands each batch back into one data entry per object
  (`GDDecorationLoader.serialize_batch`). Any new `Item` field must survive that round trip.

### Node culling — `src/FrustumCuller.gd`

- Per-level node; buckets objects by horizontal cell span, toggles `visible` around the camera
  rect grown by `Config.culling_buffer_cells`.
- Constants: `BUCKET_CELLS=8`, `OVERSIZE_CELLS=64`, `BEHIND_BUFFER_CELLS=8`, `EDGE_EPSILON=2`.
- Never culled: group-driven objects (any GD group can be moved/rotated/scaled by triggers),
  triggers, portals, physics blocks, oversize objects, and Toggle-hidden objects.
- Active only while a level plays (and in playtests); native `NativeFrustumIndex` accelerates it.
- `GDObject` stops its own `_process` when invisible (spin only).

### Level colours and watchers

- `ColorChannelData` (resource) holds a channel's colour/blending/opacity/HSV/copy source.
- `ColorChannelWatcher` (one per channel) fans changes to `HSVWatcher`s and decoration batches;
  group prefix `watcher_`, `COPY_ITERATIONS = 8` for copy-channel chains; native
  `NativeColorChannelIndex` applies a whole channel in one call.
- `HSVWatcher` applies per-object HSV shift and saturation/value-multiply flags to modulate.
- `Level.background_color` / `ground_color` / `line_color` propagate to ground shader parameters
  and to the channels that copy them (`_background_copy_watchers`, `_ground_copy_watchers`,
  `_line_copy_watchers`). The ground material is shared between the two ground sprites.

### LDM, particles, filters

- `Config.ldm` drops objects carrying `DisabledInLowDetailModeAttribute` (LDM) at build time; it
  is disabled in the editor.
- Particles are gated per-category by bitflags in `Config` (`ParticleVisibility`,
  `ParticlePreprocessing`) and by `Config.show_particles_in_editor`.
- `RenderMode` (`src/RenderModes.gd`, `Mode { OBJECT_MODE, MATERIAL_MODE, RENDERED_MODE, TEMP }`)
  switches editor rendering: OBJECT mode shows solid object colours, MATERIAL shows channels,
  RENDERED is the game look. Level colour setters early-out in OBJECT mode.

## 6. Audio

- Buses come from `resources/default_bus_layout.tres`; master/music/game SFX/in-level SFX have
  `Config` levels. `MusicVolume.get_volume()` feeds `Level.music_scale` (used by `MusicScale`
  components).
- `SFXManager` keeps a stream cache and a pool of players, downloads missing SFX by id
  (RobTop CDN via `RobTopLevels.download_sfx`), preloads ids found in level data
  (`NativeCore.extract_level_sfx_ids`).
- `AssetManager` loads songs/fonts on worker threads; `user://created_levels/songs/` and
  `.../fonts/` hold imported assets, `res://assets/sounds/music/game_music/MenuLoop.mp3` is the
  shipped menu loop.

## 7. Persistence paths

| Path | Contents |
| --- | --- |
| `user://config.cfg` | `Config` (settings + keybinds + icon selection) |
| `user://created_levels/levels/` | levels (`*.bin` gzip) + `.meta` sidecars |
| `user://created_levels/songs/`, `.../sfx/`, `.../fonts/` | downloaded/imported assets |
| `user://replays/` | `.gdr` replays |
| `user://textures/player/` | custom icons |
| `user://.cache/player/` | generated coloured icons |
| `user://gd_object_frames.json` | optional user override of the GD object→frame table |

`LevelManager._ready()` creates the level/song/sfx/font directories if missing.
