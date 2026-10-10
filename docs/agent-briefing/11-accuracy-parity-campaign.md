# 11 — Accuracy campaign: parser, triggers, camera

This file changes the *job*, not the codebase description. The mission is no longer "document
what Godot Dash contains" but **"make an imported Geometry Dash level behave like Geometry
Dash"**, measured on one public acceptance level plus a set of regression levels. Three
subsystems carry almost all of the remaining error:

1. **the level-string parser** (objects, properties, colour channels, header keys),
2. **triggers that silently do nothing** (unsupported families, wrong key vocabulary, the
   native/component split),
3. **the camera** (trigger families and the base follow),
4. **the menu frost / blur shader** (`SimpleBlurMaterial`), which is wrong independently of the
   three above — see §7.

Gameplay, parser, trigger and camera fixes land in **C++/native first**: that is the code that
runs by default (§4.1).

Everything below was read out of the checkout or the linked decompilations. Where a statement
is a **hypothesis** rather than a verified fact it is marked `H:` — do not ship a fix on a bare
`H:` without the evidence named next to it.

---

## 0. Definition of done

A change counts as done when **all** of these hold:

- The symptom is reproduced on a named level at a named percentage, with the evidence
  captured (log line, screenshot pair, or a numeric dump — see §10).
- The fix touches the code path that actually ran (native vs component — see §4), and the
  *other* path is either fixed too or explicitly documented as untouched with a reason.
- The decompiled-source behaviour the fix reproduces is cited by **repo + file + function**
  (see §2), or the fix is labelled a workaround with the citation marked missing.
- `python3 -m py_compile tools/*.py` and `node tools/web_relay_worker_selftest.mjs` stay green.
- Nothing in `docs/agent-briefing/01`–`10` is contradicted; if it is, the pack is updated in
  the same change.
- Gameplay/parser/trigger/camera fixes exist in the **C++/native** implementation, with the
  GDScript twin updated in the same change (§4.1) — not the other way round.

---

## 1. Acceptance level: OuterSpace (`27732941`)

Everything in this table is from the level-history API record
(`https://history.geometrydash.eu/api/v1/level/27732941/`) or the level's GD metadata — treat
it as ground truth for reproduction, not as something to re-derive.

| Field | Value |
| --- | --- |
| Name / creator | OuterSpace / Nicki1202 |
| Online ID | **27732941** |
| Password | `1202` (the API record stores it as `1001202`) |
| Difficulty / length | 5 stars, featured, **long** |
| Coins | 3 (verified) |
| Song | *Space Battle* — F-777, song ID **661012** |
| First upload | 2017-02-27 (`level_version 1`, GD **2.0** era) |
| Current record | `level_version 2`, `cache_game_version **21**`, re-uploaded 2020-02-15 |
| Objects | **13,903** |
| Level string | 113,624 B compressed / **628,939 B** decompressed, `sha256 bccf093c…` / decompressed `376d6168…` |

### What this means for the brief — read before blaming camera triggers

**OuterSpace is stored as a GD 2.1 level.** Camera triggers (Zoom 1913, Static 1914, Offset
1916, Gameplay-Offset 2901, Rotate 2015, Edge 2062, Mode, Guide 2016) were introduced in **2.2**
— they cannot be present in a 2.1 level string. Therefore:

- its "movie letterbox bars", its boss and its multicolour section are **object/group driven**
  (sprites, alpha/pulse/move/scale/toggle triggers, colour channels), *not* `Camera*Trigger`
  objects;
- its camera feel comes from the **base follow** (`PlayerCamera`) and possibly from level
  objects that move the camera, not from camera triggers.

Camera-*trigger* parity is still in scope — 2.2 levels depend on it — but it must be verified on
2.2 levels, not on OuterSpace. Do not let a red herring send you into `Camera*Component.gd`.

### The four reported symptoms → where to look first

| Symptom (user's words) | First suspects, in order |
| --- | --- |
| "Colours look slightly off" in the multicolour section | channel resolution (§5): copy chains, HSV shifts, LBG (1007), inert pulse modes (§5 Known gaps), native-vs-GDScript divergence |
| "We just don't see the boss" | objects were **skipped at import** (unsupported ID, missing scene/atlas frame), hidden by an imported alpha/toggle, wrong z-layer/order, or culled — start from `ImportReport.skipped_ids` (§3) |
| "Cinematic black bars don't work" | geometry/layering, not camera triggers: giant scaled sprites, z-layer/order, `HIDE`/`TOGGLE` handling, `FrustumCuller` (`OVERSIZE_CELLS = 64`, `src/FrustumCuller.gd`), alpha/pulse state left at import default |
| "Camera follows differently than GD" | `PlayerCamera` constants and catch-up math vs GD's lead and per-step update (§6) |

---

## 2. Reference sources: decompiled Geometry Dash

Cite these by **repository + path + symbol**, with the version, because GD internals move
between updates. Reproduce the *behaviour*, never vendor the code.

| Source | Version / scope | What to read there | Caveats |
| --- | --- | --- | --- |
| [`Wyliemaster/GD-Decompiled`](https://github.com/Wyliemaster/GD-Decompiled) | **2.11** C++ decompilation; archived read-only 2025-12-17; MIT | `GD/code/src/EffectGameObject.cpp` (trigger `customSetup` — key→field mapping for every object trigger), `GD/code/src/GJBaseGameLayer.cpp`, `GD/code/src/ObjectToolbox.cpp`, `GD/code/headers/**` | **No 2.2 camera triggers** — anything with ID ≥ 1913 in the 2.2 family is absent. Name-mangled/partly reconstructed; not compilable |
| [`camila314/gdp`](https://github.com/camila314/gdp) | **2.2** decompilation of physics/gameplay; actively updated (last commit 2025-09) | `GJBaseGameLayer/GJBaseGameLayer_update.cpp`, `PlayLayer/PlayLayer_postUpdate.cpp`, `GameObject/`, `PlayerObject/`, `HardStreak/`, `Slerp2D.cpp` | Physics/loop only — no trigger setup code, no editor |
| `GD-Decompiled-2-2/cpp` (archived) · [`CallocGD/GD-2.205-Decompiled`](https://github.com/CallocGD/GD-2.205-Decompiled) | **2.2 / 2.205** | the 2.2-only object families: camera triggers, shader triggers, area triggers, `EffectGameObject` in a 2.2 build | completeness varies per dump; check before trusting |
| [`Wyliemaster/gddocs`](https://github.com/Wyliemaster/gddocs) | format documentation | level-string *format*, object IDs, key tables | documentation, **not** decompiled — label it as such |
| [`sergeymcorg/opengd`](https://github.com/sergeymcorg/opengd) | 1.0 reimplementation | none for parity bugs | a reimplementation, not a decompilation; citing it as GD behaviour is wrong |

### Verified GD facts already extracted (use these, do not re-derive)

From `gdp@2.2:GJBaseGameLayer/GJBaseGameLayer_update.cpp`:

- The sim is a **fixed-step loop**: `stepCount = fmax(1.0, (delta * 240.0) / fmin(m_timewarp, 1))`,
  i.e. **240 Hz nominal**, with time-warp dividing it. This matches this repo's 240-tick GDR
  format and the `120 Hz` question in `docs/agent-briefing/10` — GD's own loop is 240.
- The camera is stepped **inside** that loop, once per physics step:
  `this->updateCamera(physicsDelta * 60);` — note the argument is *60-unit seconds*, not 240.
- On level start: `m_cameraVelocity.x = ws.width * 0.5 + -75.0 + 15.0;` → the classic
  **75-unit lead** (plus 15) applied to a half-screen. Camera state lives in `m_cameraPos`,
  `m_cameraVelocity` (and `GJEffectManager::m_cameraVelocity`, `m_playerVelocity`), zoom in
  `m_gameState.zoomLevel`; `m_fixedStartCam` suppresses the initial camera kick.
- Screen flip (gravity-portal flip transition) mirrors the player about the camera:
  `flipMult = (cameraDist * -2 + visibleWidth) * flipAmt`, where
  `cameraDist = player.x - m_cameraPos.x` and `visibleWidth = ws.width / m_gameState.zoomLevel`.
- Shake is a countdown: `m_isShake = m_shakeCountdown > 0`.

From `gdp@2.2:PlayLayer/PlayLayer_postUpdate.cpp`: `GJBaseGameLayer::updateLevelColors` runs
every frame in `postUpdate`; checkpoint objects carry `m_centerGroupID` and resolve their target
via `GJBaseGameLayer::tryGetMainObject` — i.e. GD's "centre group" is a first-class concept, not
a Godot Dash invention.

### How to cite in a fix

```
parity: GD 2.11 EffectGameObject::customSetup (Wyliemaster/GD-Decompiled, GD/code/src/EffectGameObject.cpp)
parity: GD 2.2 GJBaseGameLayer::updateCamera (camila314/gdp, GJBaseGameLayer/GJBaseGameLayer_update.cpp)
```

If no decompiled source covers the behaviour (all of 2.2's camera triggers), say so explicitly
and cite the in-game observable instead (editor fields, level-string keys from real 2.2 levels).

---

## 3. The import pipeline, for locating a failure

```
.gmd file / RobTop API response        src/RobTopLevels.gd
      ↓ base64+gzip decode             src/static/GMD.gd
      ↓ level string → Godot data      src/static/GMDConverter.gd        ← parser lives here
      ↓ object tables / scenes         src/static/GMDObjects.gd, scenes/gd_objects/**, assets/textures/gd_atlas/object_frames.json
      ↓ build nodes                    src/Level.gd, src/Layer.gd, src/LevelBuildJob.gd
      ↓ play                           src/GameScene.gd, src/LevelManager.gd, src/PlayerCamera.gd
```

Start every investigation from the importer's own report — it already answers "what did the
parser drop?":

- `ImportReport` (`src/static/GMDConverter.gd`, `class ImportReport`): `skipped_ids`,
  `failed_ids`, `substituted_block_ids`, `decoration_ids`, `empty_target_groups`, and
  `skipped_breakdown()` which prints the top offenders. **`empty_target_groups` is the
  "trigger that does nothing" detector**: a group whose every member was skipped.
- `_parse_pairs` (`:1665`) routes through the **native** `parse_gd_pairs` when the C++ backend
  exists — a malformed pair handling difference between native and GDScript is a parser-accuracy
  bug by itself; check both.
- `_components_from_properties` is where per-ID key vocabularies live: if a trigger's fields
  are not read here, the trigger does nothing no matter how correct the runtime is.

---

## 4. Two execution paths — the single most common cause of "trigger doesn't work"

**`Config.use_native_core` is `true` by default** (`src/autoloads/Config.gd:94`). When the
GDExtension is present and `Editor.in_editor` is false, `_native_trigger_execution()`
(`src/static/GMDConverter.gd:1094`) packs these families as **records for the C++ runtime instead
of scenes**:

```
GMDObjects.NATIVE_EFFECT_TRIGGER_IDS (src/static/GMDObjects.gd:381):
  29, 30, 104, 105, 221, 717, 718, 743, 744, 899, 900, 901, 915, 1006, 1007, 1049, 1268,
  1346, 1347, 1520, 1585, 1611, 1612, 1613, 1616, 1811, 1817, 1913, 1916, 1935, 2015, 2067, 3022, 2913, 2919, 2920, 2921, 3613
```

Consequences, all verified in code:

- `NativeTriggerBridge.gd:64` additionally **disables the Area2D** of those triggers so touch
  variants cannot double-fire — so a family listed here but *not implemented* in C++ is a
  trigger that does **nothing**, silently, with no warning.
- The native colour parser reads the classic vocabulary (`7/8/9` RGB, `23` channel, `35`
  opacity, `50` copy, `15/16` player, `17` blending, `10` duration) — `parse_color_source`,
  `native/src/gdash_native.cpp`. Anything outside that vocabulary (see §5) is dropped on the
  native path while the component path might handle it.
- **Camera Static (1914) and Edge (2062) are deliberately *not* in the list**: they keep their
  scene and run their components (`GMDObjects.gd:375` comment; `Level.gd:740` folds the packed
  records back into the serialized layer so switching paths stays lossless).
- Native effect arms exist for `CAMERA_ZOOM` (key `371`, `/100` of `PlayerCamera.DEFAULT_ZOOM`),
  `CAMERA_OFFSET` (keys `28`/`29` × `CELLS_TO_PX`), `CAMERA_ROTATE` (`68` + `69`×360),
  `SHAKE` (`75`), `TIMEWARP` (`120`), `SCALE` (`150/151`), `ALPHA` (`35`), `TOGGLE` (`56`),
  `MOVE` (901), `ROTATE` (1346), shader triggers 2913/2919/2920/2921, UI (3613).
- Gravity portals (10/11/2926) are explicitly skipped by the bridge: registering them turned
  monitoring off and broke the portal (see the comment at `NativeTriggerBridge.gd:47`).

### Rules

1. **Always state which path the failing build took.** "It doesn't work" without this is not a
   bug report.
2. Reproduce on **both**: `use_native_core = true` (runtime) and `false` (components), plus the
   editor import (`Editor.in_editor` forces components). A family missing from one path is a
   bug in that path, not a design choice — unless §2/§5 says otherwise.
3. When adding a family to `NATIVE_EFFECT_TRIGGER_IDS`, implement it in C++ **in the same
   commit** or leave it out of the list; the Area2D removal makes an unimplemented entry a
   black hole.
4. The C++ runtime is optional per build (see `docs/agent-briefing/06`); GDScript components are
   the portable fallback and must stay correct on their own.

### 4.1 Placement rule: fix it in C++/native first

Because `use_native_core` is on by default, the code that actually runs for gameplay, parsing
and triggers is **`native/src/gdash_native.cpp`**. A fix written only in GDScript does not fix the
reported bug on the default configuration. Therefore:

1. **Implement the fix natively first** — the C++ path is the primary implementation, the
   GDScript component is the twin that must be updated to match in the same change.
2. **Wire the family through** if you add or repair one: `NATIVE_EFFECT_TRIGGER_IDS`
   (`GMDObjects.gd:381`) + a `TriggerEffectKind` arm + the `parse_trigger_effect` switch +
   execution in `advance`/`tick` + `register_trigger`/`register_packed_trigger` plumbing. Never
   list a family in `NATIVE_EFFECT_TRIGGER_IDS` without its C++ arm (§4).
3. **Entry points to look in** (all in `native/src/gdash_native.cpp`):
   - parser: `parse_gd_pairs`, `decode_level_string`, `extract_object_geometry`,
     `extract_level_sfx_ids`, `encode_level_string`;
   - triggers: `parse_trigger_effect` (ID → kind, key vocabulary), `parse_color_source`,
     `parse_copy_hsv`, the easing table, `TriggerRuntime::advance` / `tick` /
     `apply` / `activate_touch`, `pulse_envelope` (`45`/`46`/`47`), `finalize`;
   - colour: `live_special_color`, `resolve_channel_data_color`, `shift_copy_hsv`,
     `resolve_channel_data_alpha`, `NativeColorChannelIndex::{configure, set_group_members,
     apply_channel_color, set_channel_blending}`;
   - camera/level: the camera arms in `parse_trigger_effect` (`CAMERA_ZOOM` / `CAMERA_OFFSET` /
     `CAMERA_ROTATE` / `SHAKE` / `TIMEWARP`) and the camera reads/writes through
     `bind_context` (`NativeLevelRuntime`);
   - culling/build: `NativeFrustumIndex`, `NativeDecorationRenderer`,
     `NativeLevelBuildJob`, `NativeDecorationCullWorker`.
4. **Contract rules that still apply in C++**: no new dependencies; C++17; keep GDScript free of
   static native type references (`ClassDB` lookups only — `src/static/NativeCore.gd`); every
   native behaviour keeps a working GDScript fallback.
5. **Size budget**: CI fails if the stripped test-host `.so` exceeds **3,000,000 bytes**
   (`.github/workflows/main.yml`, "tripwire"). Do not template/bloat your way to a fix.
6. **Prove it in the native gates**: add the failing case to `native/tests/*.cpp` (pure math —
   `test_trigger_effect_parse.cpp`, `test_color_channel_math.cpp`, `test_online_parser.cpp`,
   `test_physics.cpp`, `test_gravity_portal.cpp`, `test_ui_trigger.cpp`; they need a local
   `native/godot-cpp` to build — see the `g++` line at the top of each file) **and/or** to the
   engine-hosted self-tests CI runs: `tools/gdr_selftest.tscn`,
   `tools/native_color_selftest.tscn`, `tools/runtime_visual_smoke_test.tscn`.
7. **Exception — do not force it**: rendering/shader work (the blur shader, §7) and pure
   editor/UI glue are GDScript + `.gdshader`. There is no native blur; do not add one.

---

## 5. Colour accuracy

### The pipeline

`kS38` header string → `_resolve_channel_styles()` (`GMDConverter.gd:1377`) → per-channel
`{color, alpha, blending}` (+ runtime copy link) → `_build_color_channels()` (`:1492`) →
`ColorChannelData` per used channel → runtime `ColorChannelWatcher` /
`NativeTriggerBridge.register_channel` → C++ resolver.

Verified key vocabulary:

| Key | Meaning | Where |
| --- | --- | --- |
| `kS38` entry keys | `1/2/3` RGB, `4` player colour, `5` blending, `6` channel id, `7` opacity, `9` copied channel, `10` copy HSV, `17` copy opacity | `ChannelKey`, `GMDConverter.gd:113` |
| Colour trigger | `7/8/9` RGB, `23` target channel, `35` opacity, `50` copied channel, `49` copy HSV, `60` copy opacity, `17` blending, `15/16` player colours | `Prop`, `LEGACY_COLOR_TRIGGER_CHANNELS` (`:151`) |
| Reserved channels | `1000` BG, `1001`/`1009` G1/G2, `1002` line, `1003` 3DL, `1004` obj, `1005` P1, `1006` P2, `1007` LBG, `1010` black, `1011` white, `1012` lighter, `1013`/`1014` MG | `:96` |
| Header aliases | `kA6` BG, `kA7` ground, `kA17` line, `kA2..kA13` gamemode/mini/speed/dual/start-pos/song-offset, `kA20` reverse, `kA22` platformer, `kA11` flip | `HeaderKey`, `:127` |

### Verified divergences between the two paths — check these first

These are real, in-tree, and each is a plausible "colours look slightly off" root cause:

1. ~~sRGB vs linear~~ — **retracted, verified false.** `Color8(r, g, b)` and
   `Color(r / 255.0, …)` are the same constructor in Godot 4: godot-cpp's
   `Color::from_rgba8` is literally `Color(p_r8 / 255.0f, …)`
   (`native/godot-cpp/src/variant/color.cpp`), and neither applies a linear conversion. The
   native and GDScript byte decodes are bit-identical; do not "fix" this.
2. **LBG (1007) is implemented twice, differently.** GDScript `_lighter_background()` (`:1581`)
   desaturates 0.2 and lerps toward the player colour by `background.v`; native
   `live_special_color(1007)` uses `bg.lightened(0.2f)`. Channels copying LBG will not match
   each other between paths.
3. **Copy/HSV has two implementations** — GDScript `_shift_hsv_string`/`_apply_copy_link`
   (`:1539`) and C++ `parse_copy_hsv`/`shift_copy_hsv`. Keep them identical or pick one owner.
4. **Blending is tri-state** (key `17` present vs absent) and both paths, plus the C++
   `parse_color_source`, carry comments explaining that a trigger without the checkbox must not
   revert an overlapping Blending flip. Preserve this when editing either side.
5. **Legacy families default a channel**: `LEGACY_COLOR_TRIGGER_CHANNELS` maps 29→BG, 30→G1,
   104→line, 105→obj, 221→1, 717→2, 718→3, 743→4, 744→3DL, 899→1, 900→G2, 915→line; a bare
   899 with no key 23 falls back to channel 1. Do not extend that table from memory: `901` is
   the *Move* trigger (native `case 901: MOVE`), and every ID in it must be verified against the
   2.11 `EffectGameObject::customSetup` before it is treated as a colour family.

### Known gaps (verified)

- `PULSE` (1006): **HSV-mode** channel pulses (`48` non-zero → colour = copied channel `50`
  shifted by `49`) are implemented on both paths (native `classify_pulse` + the PULSE arm;
  component `ColorChannelChangerComponent.pulse` via `GMDObjects.MAP[1006]`), cited to GD 2.11
  `EffectGameObject::customObjectSetup` case 1006. RGB mode reads only `7/8/9` (keys `15/16/50`
  are not pulse vocabulary). Still inert: **group pulses** (`52 == 1`, need a per-object tint
  the batched renderer lacks) and HSV pulses with no `50`; both are counted in
  `ImportReport.inert_trigger_ids`. Regression: `native/tests/test_trigger_effect_parse.cpp`.
- Every trigger on the inert `NativeGenericTrigger` shell that the native runtime does not
  execute on the current path — notably the 2.1 tools Touch 1595 and Collision 1815 — is a
  silent no-op on **both**
  paths; it is now counted in `ImportReport.inert_trigger_ids` (printed by
  `RobTopLevels` (both online paths), `LevelOperationsHandler` and `SubsceneManager`).
- **Follow (1347)** is implemented on both paths: native `TriggerEffectKind::FOLLOW`
  (`follow_step`: target group moves by the follow object's (key 71) per-tick movement × keys
  72/73, for key 10 seconds) and `PositionChangerComponent.Mode.FOLLOW` via
  `GMDObjects.MAP[1347]`. Vocabulary cited to GD 2.11 `customObjectSetup` case 1347; the
  per-tick law itself is not in any decompilation (editor-documented behaviour).
- **Item triggers (Pickup 1817, Count 1611, Instant Count 1811)** are implemented on both
  paths: native `PICKUP`/`COUNT`/`INSTANT_COUNT` (`item_counts`, armed Count list, kept in
  practice snapshots; helpers `item_compare` / `item_count_reached`) and `ToggleComponent`
  item modes via `GMDObjects.MAP`. Keys 80/77/51/56/104 are cited to GD 2.11
  `customObjectSetup`; key 88 (compare mode) and the firing rules (Count fires on arrival at
  the target; key 56 spawns the group, otherwise toggles it off) are editor-documented,
  i.e. a hypothesis until checked in GD. Not done: collectible items that change item IDs,
  and on the GDScript path, item counts are not saved in practice snapshots.
- **Group pulse (1006, key 52 = 1)** is implemented on both paths: native `pulse_group` →
  `apply_group_pulse` (batches: `NativeDecorationRenderer.set_group_pulse`, one colour+weight
  per renderer applied in the dirty rebuild only while weight > 0; node-drawn layers:
  `self_modulate = lerp(1, pulse/tint, w)`), GDScript `GroupPulse` + `pulse_group` on
  `ColorChannelChangerComponent`. Keys 65/66 (main/detail only) are not yet honoured.
- **Animate (1585) and monster animation**: `tools/build_monster_animations.py` derives
  `assets/textures/gd_atlas/monster_animations.json` from GD's objectDefinitions.plist and
  GJBeastNN_AnimDesc.plist (inputs not committed). Monsters (918/1327/1328/1584/2012) now
  play their default clip in the animated batches; native `ANIMATE` (key 76, cited to 2.11
  `customObjectSetup` case 1585) and `AnimateComponent` call
  `DecorationBatch.play_monster_animation`. ID tables for Beast/Bat are from the 2.1 help
  transcriptions; the Spikeball table and clip chaining are hypotheses; per-frame z changes
  are not applied.
- Online downloads (`import_online_level_string`: C++ `parse_online_level` normalisation, then
  the shared GDScript conversion loop) get every converter change above; guarded in
  `tools/runtime_visual_smoke_test.gd` ("pulse/follow modes").
- Player channels P1/P2 (1005/1006) are intentional no-ops in the trigger arms in both paths
  (matching the component). If a level recolours P1/P2 via a trigger, GD *does* apply it —
  decide deliberately which is right.
- `_is_colorable_channel()` (`:855`) synthesises never-defined custom channels as white so a later
  colour trigger can reach them; that is deliberate GD behaviour, not a bug.

### Bisect procedure for "slightly off"

1. Log the resolved table once per import: channel id → `color`, `alpha`, `blending`,
   `copy_source`, `copy_hsv`. Then log every colour trigger fire with `(gd_id, key 23, source,
   before, after)`.
2. Compare the **import-time** table against the level's `kS38` by hand for the section's
   channels. Off already at import → parser bug (§3 path). Correct at import, wrong after
   playing → trigger/`ColorChannelWatcher` bug (§4 path).
3. Run the same level with `use_native_core` true and false and diff the two logs. Any
   difference is one of the five divergences above, by construction.
4. Only then compare against GD (screen capture, same percentage, same channel).

---

## 6. Camera accuracy

### What the repo does today (`src/PlayerCamera.gd`)

```gdscript
const DEFAULT_ZOOM   := Vector2(0.8, 0.8)
const DEFAULT_OFFSET := Vector2(400.0, 0.0)
const MAX_DISTANCE   := Vector2(400.0, 300.0)
@export var position_smoothing := 0.1
@export var offset_smoothing   := 0.125
```

- `_process`: player/ground distance → rotate into gameplay space → vertical axis via
  `gd_vertical_step` (GD law from Wyliemaster/Geometry-Dash-1.0 `PlayLayer::updateCamera`:
  cube band 3 cells from the top / 4 from the bottom, swapped when flipped, 1/10 catch-up per
  60 Hz frame; fly modes chase the portal centre at 1/30; applied to all levels; that 2.1 keeps
  the 1.0 law is a hypothesis); platformer X still uses `local_target_distance_axis`
  (deadzone `MAX_DISTANCE / zoom`, 0.2 catch-up) → rotate back → apply
  per axis unless `static_factor` blocks that axis → clamp the view's bottom edge to
  `ground_down + 90 units` (GD 1.0 `cam.y >= 0`, hypothesis for 2.2; was `+ 160 px`) and the top to
  `ground_up - 160` → `offset = get_offset_target(≈delta*60)`.
- `get_offset_target()`: `(gameplay_offset / zoom) * gameplay_offset_factor * (1 - static_factor)
  + additional_offset + shake_offset`; `gameplay_offset` eases toward
  `DEFAULT_OFFSET.x * player.get_direction() * player_speed_sign` at 0.125 per 60 Hz frame.
- `reset()` restores zoom/offset/limits/rotation and clears `static_factor`,
  `gameplay_offset_factor`, `center_on_player_at_0x_speed`.

### What GD does (cited, §2)

- camera stepped **once per physics step inside the 240 Hz loop**, with a *60-unit* delta;
- horizontal lead from a half-screen **minus 75 (+15)**, not the 400 px offset here;
- camera velocity is a first-class `CCPoint` state; zoom is `m_gameState.zoomLevel`;
- screen flip mirrors the player about the camera; shake is a countdown.

`H:` the follow discrepancy is one of: (a) the lead value (`400 px / 0.8 zoom` vs GD's
`half-screen − 75`), (b) the catch-up law (linear `0.2·60·delta` here vs GD's velocity model),
(c) where the vertical deadzone comes from (`MAX_DISTANCE.y / zoom.y` here vs GD's view-derived
threshold), (d) the ground clamp (`±160` on `default_y` here vs GD's floor/ceiling from level
bounds), (e) camera updates running in `_process` (frame-rate dependent, `delta * 60`) rather
than in the physics step. **Measure, don't guess** — see §10.

### Camera trigger families (the table the rest of the work uses)

| ID | Trigger | Scene / component | Executed by |
| --- | --- | --- | --- |
| 1913 | Zoom | `CameraZoomTrigger` / `CameraZoomChangerComponent` | **native** (key `371`, % of `DEFAULT_ZOOM`) |
| 1914 | Static | `CameraStaticTrigger` / `CameraStaticComponent` | components (ENTER/EXIT via key `110`, centre group key `71`) |
| 1916 | Offset | `CameraOffsetTrigger` / `CameraOffsetChangerComponent` | **native** (keys `28/29` × cells) |
| 2015 | Rotate | `CameraRotateTrigger` / `CameraRotationChangerComponent` | **native** (key `68`, +`69`×360) |
| 2062 | Edge | `CameraEdgeTrigger` | components (`player_camera.limit_*`, reset ±10,000,000) |
| 2901 | Gameplay Offset | `CameraGameplayOffsetTrigger` / `...ChangerComponent` | components (`gameplay_offset_factor` = raw value / 25; default 25 = 75 units) |
| 2016 | Guide (editor-only) | `CameraGuide` in `GMDObjects.MAP` | editor |
| 1520 | Shake | `CameraShakeTrigger` | **native** (key `75`, `CameraShakeComponent` when not) |
| 2066 / 2900 | Gravity / gameplay rotate | `GravityTrigger`, `GameplayRotateTrigger` | components |

Known `H:` parity gaps to verify against a 2.2 level and the 2.2 decompiles:

- `1914` reads only key `110` and key `71`. GD's static trigger also has *Follow*, *X Only*,
  *Y Only* and *Smooth Velocity* options — if those keys are parsed nowhere, a non-following
  static trigger will still track its guide group here.
- `1916` applies `additional_offset += offset * CELLS_TO_PX` with **no Y negation**
  (`CameraOffsetChangerComponent`), and the native arm likewise keeps GD's +Y as Godot's +Y.
  GD's +Y is up, Godot's camera offset +Y is down — check the sign with a bidirectional offset
  test before changing anything.
- `2062`/`2901` are component-only: confirm they behave identically with the native core on.
- Zoom mode: both paths always behave as SET. Verify whether GD's zoom trigger has a
  relative/absolute option the strings encode before adding a mode arm.

### Round 2 (end of level)

- The height hold (`PlayerCamera.gd_end_holds_height`) starts when the camera centre reaches the
  end stop, not only in the end animation. Before this the view kept following the player up into
  the portal during the approach. Guard: `_test_camera_end_holds_height` in the visual smoke test.
- GP Offset (2901) scale: the component multiplied the raw value by 0.01 with a default of 100, so
  GD's default value 25 (gd_docs: 75 GD units ahead) gave a 19-unit look-ahead and pushed the player
  right on screen. Now factor = value / 25 (`CameraGameplayOffsetChangerComponent.gd_offset_factor`).
  Guard: `_test_camera_gp_offset_scale`. This is the only camera input that moves the look-ahead, so
  it is the likely cause of the "too far left" cutscene framing. Not confirmed in-game: it depends on a
  GP Offset trigger active before the cutscene.

---

## 7. Blur / menu frost (`SimpleBlurMaterial`)

The frosted-glass backdrop behind menus and pause panels. One material is shared by
`scenes/TitleScreen.tscn`, `GameScene.tscn`, `EditorScene.tscn`, and the `PauseMenu`,
`RenderModes`, `ReplaysMenu`, `SettingsMenu`, `Toast` components.

| Piece | File |
| --- | --- |
| Shader (desktop and web) | `resources/shaders/BackgroundBlur.gdshader` |
| Per-panel screen copy | `src/BlurBackBuffer.gd` (attached by `Config._ready()` via `node_added`) |
| Material | `resources/SimpleBlurMaterial.tres` (→ `BackgroundBlur.gdshader`) |
| Globals | `project.godot` `[shader_globals]` — `menu_blur`, `blur_strength`, `ui_color` |
| Settings push | `src/SettingsMenu.gd:19-21` (on ready), `:40-49` (on change) |

Status of the defects first listed here, re-checked against the checkout and the Godot
4.7.2 source (no Godot binary was available, so none is visually confirmed):

1. *Saved settings not applied until settings is opened* — **does not reproduce from code.**
   `SettingsMenu` is a static child of the main scene (`TitleScreen.tscn`, node
   `TitleScreen/Settings/MarginContainer/SettingsMenu`), and its `_ready()` pushes
   `menu_blur` / `blur_strength` / `ui_color` unconditionally at boot (Godot readies hidden
   nodes). Only a boot path that skips the title scene could show stale globals; none exists.
2. *Web shader samples an unset texture* — **obsolete.** The web viewport blur was removed;
   web uses the same shader as desktop.
3. *Mipmap-LOD blur absent on Compatibility* — **false for 4.7.** Desktop runs `mobile`
   (RD); RD generates back-buffer mipmaps when a shader samples the screen texture with a
   mipmap filter (`servers/rendering/renderer_rd/renderer_canvas_render_rd.cpp`), and so does
   GLES3 (`drivers/gles3/rasterizer_canvas_gles3.cpp`, `render_target_gen_back_buffer_mipmaps`),
   which `rendering_device/fallback_to_gl_compatibility=true` can select. `smoothstep(0, 1, …)`
   compiles: int constants convert for builtin args (`shader_language.cpp`, `convert_constant`).
4. *Bright panels never blurred* — **intended behaviour, misnamed.** The theme's panel
   styleboxes are black (`resources/Theme.tres`), and on the title screen text/icons inherit
   the material via `use_parent_material`; the `V <= 0.3` mask selects the frost fill and keeps
   bright foreground pixels. The variable is now `is_frost_fill` in both shaders.
5. **Panels hid UI drawn before them** — **fixed.** Godot copies the screen once per canvas
   layer, at the first `hint_screen_texture` reader. Later panels reused that copy, so UI drawn
   between them was missing from the blur and covered by the opaque fill (worst on the title
   screen). `BlurBackBuffer` now puts a rect `BackBufferCopy` before each blurred panel. On web
   the old SubViewport blur copied only background/ground/title-player sprites, so everything
   else vanished behind panels; the user dropped the "no screen texture on web" rule, and web
   now uses the same screen-texture blur. The look is a plain blur (3x3 tent on a mip of the
   screen, `blur_strength` = mip level), tinted by `ui_color` as before.

Acceptance for this workstream: the frost visibly blurs the backdrop on **desktop and web**;
toggling Menu Blur off persists across a restart without opening settings; nothing drawn
behind a panel disappears; the user asked for no CI step for blur.

---

## 8. Broken-trigger taxonomy (use this to triage any "trigger X does nothing")

1. **Not in `GMDObjects.MAP`** → the object is skipped at import (`report.skipped_ids`).
2. **In `MAP` but its key vocabulary is not read** in `_components_from_properties` → a scene
   exists, the trigger fires, nothing changes.
3. **In `NATIVE_EFFECT_TRIGGER_IDS` without a C++ arm** → Area2D removed *and* no effect.
   (#1 silent-failure cause on the default config.)
4. **Target group is empty** because every member was skipped → `report.empty_target_groups`;
   the runtime warns "target group doesn't contain any objects". A trigger on the inert generic
   shell, or in an unsupported mode (group pulse), → `report.inert_trigger_ids`.
5. **Correct effect, wrong state model** — e.g. blending tri-state, copy-opacity, spawn vs touch
   flags, `multi_trigger`, target-group vs centre-group (`71` vs `51`), `HIDE`/`TOGGLE`.
6. **Correct effect, wrong timing** — easing table (`_easing_to_tween`),
   `FADE_IN/HOLD/FADE_OUT` pulse envelope, 240 Hz step vs frame delta.

---

## 9. Working rules for this campaign

- **One symptom per change.** Reproduce → cite → fix → regression note. Do not bundle a
  camera change with a colour change.
- **Never "fix" a symptom by hiding it** (e.g. raising `culling_buffer_cells`, or forcing white
  channels to render). The bug is in the data path, not the threshold.
- The generated asset pipeline (`scenes/gd_objects/**`, 3,936 scenes, and
  `assets/textures/gd_atlas/object_frames.json`) is **generated**; regenerate rather than
  hand-edit, and check whether a missing sprite is a generator gap first.
- Keep both execution paths and the editor path in mind; the editor must keep importing scenes
  so objects stay editable (`_native_trigger_execution` already guards this).
- Pack numbering is pinned by `docs/agent-briefing/README.md`; if you add a doc, update that
  table.
- Do not commit downloaded level strings, GD assets or decompiled sources into the repo.

## 10. Evidence pack per fix (what to produce)

1. **Level + percentage + path** (`use_native_core`, editor/runtime, platform).
2. **The numbers**: for parser/colour, the resolved channel table before/after; for camera, a
   log of `(position, zoom, offset, static_factor, gameplay_offset_factor)` sampled per frame
   from `PlayerCamera` (add a temporary `--camera-trace` print, do not leave it on).
3. **The GD comparison**: same spot in GD (capture or a level-string dump of the trigger's
   properties) — or the cited decompiled function, if GD cannot be run.
4. **The regression guard**: a unit/self-test or a named level + percentage in
   `tools/`-based checks that fails before and passes after.
