# 03 — Gameplay, physics, interactables, colour, replays

## 1. Units and coordinates

| Quantity | Value |
| --- | --- |
| 1 GD cell | 30 GD units = **128 scene px** (`Constants.CELL_SIZE = 128`) |
| Scene px per GD unit | `128 / 30 ≈ 4.2667` (`CELLS_TO_PX = Vector2(CELL_SIZE, -CELL_SIZE)`) |
| Atlas resolution | cocos2d `-hd` sheets = **2 px per GD unit** |
| Art scale | `128 / 30 / 2 ≈ 2.1333` (`GDDecorationLoader.art_scale()`) |
| Y axis | flipped (`CELLS_TO_PX.y = -128`) |
| Default player position | `Vector2(640, 861)` |
| Default colours | background `#3670ff`, ground `#1b4bc4`, line white |

## 2. Physics layers (fixed contract)

`project.godot [layer_names]`:

| Bit | Layer name | Used by |
| --- | --- | --- |
| 1 | `player` | Player body |
| 2 | `solids` | blocks; slopes set `66 = 2 \| 64` |
| 3 | `rectangular_hazards` | spike hitboxes |
| 4 | `interactables` | orbs / pads / portals `Area2D`s |
| 5 | `triggers` | trigger areas |
| 6 | `ground` | ground planes |
| 7 | `slope_enablers` | slope flag bit |
| 8 | `editor` | editor-only picking |
| 9 | `editor_selection_colliders` | selection boxes |
| 10 | `solid_overlap_check` | lethal wall/ceiling detection |
| 11 | `velocity_redirectors` | redirect helper areas |
| 12 | `circular_hazards` | sawblades (layer value **2048**) |

Player body `collision_mask = 122` (= 2|8|16|32|64) and `platform_floor_layers` covers
solids/ground/slope; `Player.DEFAULT_COLLISION_MASK` mirrors it. Collision shapes are named
`Hitbox` on interactables (debug-tinted green) and live under `Collision` on generated GD scenes.

### Shared level physics — `src/LevelPhysics.gd`

- Merges static world geometry into chunked shared bodies: `MERGEABLE_LAYERS = [2, 66, 4, 2048]`,
  `CHUNK_CELLS = 24`, one shared `StaticBody2D`/`Area2D` per chunk per layer kind
  (`_body_for`, `_chunk_of`).
- Objects that a Move/Rotate/Scale trigger can drive (dynamic transform groups,
  `_dynamic_transform_groups`) are **never merged**; they keep their own bodies.
- Lethal wall/ceiling hits keep the old per-shape behaviour: the single block's
  `CollisionShape2D` is disabled on the shared body, the player's kill-collider path fires as
  before, and the shape is re-enabled on overlap exit (`_reenable_shapes`, `is_shared_body`,
  `Player._handle_collision`, `_on_solid_overlap_check_body_exited`).
- Metadata on bodies: `_gd_level_physics_body`, `_gd_level_physics_merged`,
  `_gd_level_physics_snapshot`, `_gd_level_physics_descriptors`, `_gd_level_physics_dirty`,
  `_gd_level_physics_shapes`, `_gd_level_physics_dynamic_groups`.
- API: `mark_dirty`, `prepare(level)` (called from `Level.start_level()`), `rebuild`,
  `teardown(level)` (called from `GameScene._on_leave_pressed`).
- **Interactables are excluded on purpose**: their root `Area2D`, the component model, the
  per-object `interacted` signal and the editor's Interactable tab all depend on per-object
  bodies. This is a locked decision in `GD_UNIFICATION_PLAN.md`.

## 3. Player — `src/Player.gd` (1,578 lines)

Gamemodes (`Player.Gamemode`): `CUBE, SHIP, UFO, BALL, WAVE, ROBOT, SPIDER, SWING`
(swing is the 2.2 addition). Internal vs displayed gamemode are separate
(`internal_gamemode`, `displayed_gamemode`).

Physics constants:

| Constant | Value |
| --- | --- |
| `GRAVITY` | 10600 |
| `SPEED` | `Vector2(1250, 2395)` |
| `TERMINAL_VELOCITY` | `Vector2(0, 3000)`; fly `1800` |
| `FLY_GRAVITY_MULTIPLIER` / `UFO_GRAVITY_MULTIPLIER` / `SPIDER_GRAVITY_MULTIPLIER` | 0.5 / 0.7 / 0.65 |
| `SPEED_MINI` / `SPEED_BIG` | `(1250, 1600)` / `(1250, 3000)` |
| `PLAYER_SCALE_WAVE` / `MINI` / `NORMAL` / `BIG` | 0.6 / 0.6 / 1.0 / 1.4 |
| `PLATFORMER_ACCELERATION` | 5.0 |
| `SPIDER_BOUNCE_MULTIPLIER` | 0.65 |
| `WAVE_TRAIL_WIDTH` / `LENGTH` | 50.0 / 250 |
| `GRAVITY_PORTAL_LAUNCH` | 0.42 (with `gravity_portal_pending`, `_grace`, `_launch_sign`) |

Structure worth knowing:

- `_compute_velocity(delta, velocity, direction, jump_state, on_slope)` (line ~780, the largest
  function) is the per-mode physics core; `_physics_params` is a `PackedFloat64Array` of 31
  values passed to the native kernel when available (`NativeCore.compute_player_velocity_packed`).
- Cached `@onready` node references (window, icon nodes, particles, robot/swing fire sprites)
  because `_update_sprites_rotation` alone resolved ~50 node paths per tick.
- Replay recording: one `PackedByteArray([jump_state, direction + 1])` per physics tick while
  `not in_replay`; `reset_replay()`, `replay_physics_tick`, `Replay`.
- State machines: `_spider_state_machine`, `_robot_state_machine` (`AnimationTree` playback).
- Interactable plumbing: `orb_queue: Array[OrbInteractable]` (front-inserted on touch),
  `colliding_pad: PadInteractable`, `_handle_velocity_interactable`, `_ensure_velocity_redirect`
  (layer 11), `dash_control: FireDashComponent`, `speed_0_portal_control`.
- Counters flipped by triggers: `allow_ceiling_hit_count`, `allow_wave_slide_count`,
  `no_auto_checkpoints_count`.
- Practice: `place_checkpoint()`, `last_automatic_checkpoint_position`, `Config.automatic_checkpoints`
  + `automatic_checkpoint_distance`.
- `up_direction = Vector2.UP.rotated(gameplay_rotation) * gravity_flip` — gravity flips and
  gameplay rotation both feed the floor test.
- `USED_ACTIONS = ["jump", "move_left", "move_right", "platformer_wave_down",
  "practice_create_checkpoint", "practice_remove_checkpoint"]` (registered via
  `InputUtils.add_action`).
- `_physics_params`, `no_auto_checkpoints`, `Noclip` (`Config.noclip`) and debug trails
  (`Config.editor_trail`, `refresh_debug_trail`) are used by tests and the editor.

`PlayerCamera` (`src/PlayerCamera.gd`): `DEFAULT_ZOOM (0.8, 0.8)`, `DEFAULT_OFFSET (400, 0)`,
`MAX_DISTANCE (400, 300)`, free-fly, smoothing (`position_smoothing` 0.1,
`offset_smoothing` 0.125), `gameplay_offset`/`additional_offset`/`static_factor`/`shake_offset`,
`snap_view()`, `reset()`, and per-frame logic for gameplay rotation and static-camera modes.

## 4. Interactables and components

### Base classes

- `Interactable` (`src/interactables/Interactable.gd`, `extends Area2D`):
  `signal interacted(player: Player)`; `components: Array[Component]`; `register_public`,
  `has(script)`, `query(script)`; serialization `components_to_data(reason)` /
  `use_component_data`, markers `markers_to_data()` / `markers_from_data`; `_ready()` tints the
  `Hitbox` debug colour.
- `Component` (`src/interactables/Component.gd`, `@abstract extends Node`): `parent`,
  `require([...])` (awaits `parent.ready` and asserts), automatic `to_data`/`use_data` from
  exported storage fields (skips `_`-prefixed and tool buttons), `get_property_default_value`
  for inspector resets, and an assert that `Resource` fields override `_field_to_data` when
  saved to file. **Component nodes are named exactly after their script's global class name** —
  renaming a class breaks saved levels and editor lookups.
- `Marker` (`src/interactables/Marker.gd`) is a `Component` used as a flag; marker scripts are
  listed in `InteractableEditor.MARKER_COMPONENTS` and included in
  `InteractableEditor.COMPONENT_BLACKLIST` (not serialized as components).

### Object families

- `OrbInteractable`: on `body_entered` pushes the orb to `player.orb_queue` front; removal on
  exit / `interacted`.
- `PadInteractable`, `TriggerInteractable` (emits `interacted` on `body_entered`).
- `TriggerHitboxComponent` picks the touch shape: `HitboxShape.LINE` → `SegmentShape2D` of
  `line_height` cells (default 64), `SQUARE` → one-cell `RectangleShape2D`, `DISABLED` → null
  shape. It is the node `NativeTriggerBridge` inspects before turning an Area's monitoring off.
- Scenes live in `scenes/components/level_components/{solids,hazards,orbs,pads,portals,triggers,letter_objects}`
  and each carries an `EditorSelectionCollider` child with `type` + `id`.
- Example (`YellowOrb.tscn`): root `Area2D` layer 8; `Hitbox` `RectangleShape2D 128²` scaled
  1.2; `JumpBoostComponent(jump_boost = 0.985)`; `DirectionChangerComponent`; visual components
  `PulseCircle`, `PulseRing`, `PulseScale`, `MusicScale`; `EditorSelectionCollider(type = INTERACTABLE)`.

### Component catalogue (80+ scripts)

`public_components/` — behaviour, serialized into levels: speed (`SpeedChangerComponent`,
`EasedSpeedChangerComponent`, `TimescaleChangerComponent`), gravity (`FlipGravityComponent`,
`GravityFlipChangerComponent`, `GravityMultiplierChangerComponent`), gamemode/state
(`GamemodeChangerComponent`, `PlayerScaleChangerComponent`, `PlayerCountChangerComponent`,
`StopDashComponent`, `FireDashComponent`, `SpiderDashComponent`, `StopHeldJumpComponent`),
movement (`PositionChangerComponent`, `RotationChangerComponent`, `ScaleChangerComponent`,
`DirectionChangerComponent`, `TeleportComponent`, `GroundMoverComponent`,
`EasingComponent`, `ToggleComponent`, `ReboundComponent`, `JumpBoostComponent`), camera
(`CameraOffsetChangerComponent`, `CameraGameplayOffsetChangerComponent`,
`CameraZoomChangerComponent`, `CameraRotationChangerComponent`, `CameraShakeComponent`,
`CameraStaticComponent`, `CameraEdgeComponent`), colour/visual (`ColorChannelChangerComponent`,
`TargetColorChannelComponent`, `AlphaChangerComponent`, `TextureRotateComponent`,
`TextureRotationPinComponent`, `TextComponent`, `EnterEffectChangerComponent`,
`NoEffectsComponent`), triggers and flow (`SpawnTriggerComponent`, `TargetGroupComponent`,
`TargetObjectComponent`, `TriggerHitboxComponent`, `LevelCheckpointComponent`,
`AutoCheckpointComponent`, `NoAutoCheckpointsComponent`, `EndLevelComponent`,
`SongChangerComponent`, `SingleUsageComponent`, `HideMarkersComponent`,
`DefaultPlayerDataComponent`, `AllowCeilingHitComponent`, `AllowWaveSlideComponent`).

`private_components/` — visuals only, not serialized: `PulseCircle/Ring/Scale/White`,
`MusicScale`, `ToggleTriggerSprite`, `TriggerSprite`, `GroupDisplay`, `ColorChannelDisplay`,
`HitboxDisplay`, `VariableFillColor`, `RemoveMaterial`, `GravityTextureFlip`,
`ArrowOrbTextureFlip`, `GameplayRotateTriggerIndicator/_Sprite`, rebound sprites, and
`fire_dash/*` (path-followed fire dash speeds).

### Triggers and the native runtime

- Editor/palette triggers: `AlphaTrigger`, `MoveTrigger`, `RotateTrigger`, `ScaleTrigger`,
  `ColorTrigger`, `ToggleTrigger`, `SpawnTrigger`, `SpeedTrigger`, `TeleportTrigger`,
  `TimewarpTrigger`, `GravityTrigger`, `SongTrigger`, camera triggers (`CameraOffset`,
  `CameraGameplayOffset`, `CameraZoom`, `CameraRotate`, `CameraShake`, `CameraStatic`,
  `CameraEdge`), `EndLevelTrigger`, `EnterEffectTrigger`, `GameplayRotateTrigger`,
  `AutoCheckpointTrigger`, and `NativeGenericTrigger` (a generic 2.2 trigger carrying
  packed properties).
- Generic 2.2 triggers are **elided from the SceneTree** into `Level.native_trigger_records`
  and executed in C++ by `NativeTriggerRuntime`, registered through `NativeTriggerBridge`
  (one per level; binds level/channels/camera/`Config`/`ShaderLayer`/`UILayer`, registers each
  trigger with `gd_source_order`, `gd_trigger_flags`, `gd_object_id`, `gd_properties`, and
  disables overlapping `Area2D` monitoring when C++ owns the family).
- Gravity portals (ids 10/11/2926) are deliberately left on the GDScript path — registering them
  natively turned off monitoring for the gravity pad path.
- If the native core is absent, the equivalent GDScript paths run. **Never make a behaviour
  native-only.**

## 5. Attributes and meta keys

`src/attributes/` extends `Attribute` (`@abstract extends Node`), which registers its script
path into the parent's `Constants.ATTRIBUTE_META` meta list. Known attributes:

| Class | Effect |
| --- | --- |
| `DisabledInLowDetailModeAttribute` | object dropped at runtime when `Config.ldm` |
| `HiddenOutsideEditorAttribute` | `parent.visible = Editor.in_editor` |
| `NoTouchAttribute` | disables monitoring/shape (`Area2D` or all shape owners) |
| `MusicScale*` (5 variants) | flags the parent for music-pulse scaling of sprite/detail/hitbox/particles |
| `LDMAttribute` (alias) | see above |

Meta keys used across the codebase (`Constants`): `layer`, `texture_override`, `attributes`,
`hsv_watcher`, `base`, `detail`, plus `GD_GAMEPLAY_META = &"gd_gameplay"` and the physical
`_gd_level_physics_*` / `gd_*` metas. Group prefixes: `g_` (GD groups),
`c_` (colour channels), `watcher_` (channel watchers), `decobatch_` (batch channel groups).

## 6. Colour system details

- Channel objects are `ColorChannelData` resources on `Level.color_channels`; special ids
  include `1004` (Obj), `1005`/`1006` (used by many defaults), `1010` (Black), `1000`/`1001`/`1002`
  (background/ground/line) — see `GMDDefaultChannels` for the per-object default table
  (`OBJ_CHANNEL = 1004`, `DEFAULT_DETAIL_CHANNEL = 1`).
- Copy channels: `COPY_ITERATIONS = 8`; `ColorChannelWatcher._rewire_copy_dependency()` keeps a
  dependency graph so a copy target update propagates; `Level._refresh_level_color_copies`
  re-runs watchers when level colours change.
- Pulse/blending: `blending` toggles additive (`AdditiveBlendingMaterial.tres`), applied through
  `ColorChannelWatcher._apply_blending_if_changed`; `PulseWhiteMaterial`, `ColorPulse.gdshader`.
- HSV: per-object shift + saturation/value multiply flags live on `HSVWatcher`
  (`to_data`/`use_data`, `update_color`, `reset_color`), and per-item in decoration batches.
  All-zero HSV strings mean "no shift", never "multiply by zero" (see the smoke test's
  `_test_hsv_neutral`).

## 7. Replays and practice

- `Replay` (`src/Replay.gd`): `author`, `description`, `level_id`, `platformer`, and per-tick
  accessors `pressing_jump`, `pressing_down`, `get_direction`, `just_pressed_jump`,
  `just_released_jump`; `save(name)`.
- Format: **GDR 1** (`src/static/GDRFormat.gd` + hand-written `MsgPack.gd`), a MessagePack (or
  JSON) document with author/bot/level metadata, `framerate` (240 standard), and an `inputs`
  array of edges `{2p, btn: 1=Jump/2=Left/3=Right, down, frame}`. Conversion: jump edges ↔
  per-tick pairs; platformer wave-descend stored in a `dashExt` bot-extension dictionary
  (xdBot-style) so foreign tools ignore it; 240-tick standard resampling on import;
  player-2 events ignored (duals mirror P1); `MAX_IMPORT_TICKS = 240 × 3600`.
- CI golden test: `tools/gdr_selftest.gd` compares against `GOLDEN_HEX` produced by an
  independent implementation — the golden bytes embed the app version, so a version bump
  requires regenerating them.
- `ReplayPanelLoader` lists/imports/exports/deletes replays in `user://replays/` and migrates
  legacy saves (`_migrate_legacy_replays`, `_normalize_legacy_replay`).
- Practice mode: `LevelManager.practice_mode`, `practice_level_snapshots` (full level data per
  checkpoint), `Player.place_checkpoint()`, `Level._get_practice_data/_apply_practice_data`
  (velocity, replay slice to tick, elapsed time). `LevelManager.attempt` counts attempts;
  `GameScene` restarts restore the last snapshot.

## 8. HUD, percentage, and end-of-level

- `PercentageLayer` (`src/PercentageLayer.gd`) shows `%.2f%%` from
  `stopwatch.elapsed / level.duration` ("Infinite" when duration is 0), skipping identical
  strings to avoid label shaping.
- `Level.record_duration()` stores the level's length from the stopwatch.
- `EndLevelComponent` drives the finish animation; `Player.in_end_level_animation` gates input.
- Death/restart: `Player.dead`, kill colliders (`KillColliderSolid` layer 10,
  `KillColliderRectangularHazard` layer 3, `KillColliderCircularHazard` layer 12),
  `GameScene.restart_level()`.
- `TouchScreenControls` shows pause/left/right/down buttons based on
  `Config.is_touch_screen` and gamemode (`enable_platformer(wave)`).
