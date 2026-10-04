# 11 — Accuracy campaign: parser, triggers, camera

This file changes the *job*, not the codebase description. The mission is no longer "document
what Godot Dash contains" but **"make an imported Geometry Dash level behave like Geometry
Dash"**, measured on one public acceptance level plus a set of regression levels. Three
subsystems carry almost all of the remaining error:

1. **the level-string parser** (objects, properties, colour channels, header keys),
2. **triggers that silently do nothing** (unsupported families, wrong key vocabulary, the
   native/component split),
3. **the camera** (trigger families and the base follow).

Everything below was read out of the checkout or the linked decompilations. Where a statement
is a **hypothesis** rather than a verified fact it is marked `H:` — do not ship a fix on a bare
`H:` without the evidence named next to it.

---

## 0. Definition of done

A change counts as done when **all** of these hold:

- The symptom is reproduced on a named level at a named percentage, with the evidence
  captured (log line, screenshot pair, or a numeric dump — see §9).
- The fix touches the code path that actually ran (native vs component — see §4), and the
  *other* path is either fixed too or explicitly documented as untouched with a reason.
- The decompiled-source behaviour the fix reproduces is cited by **repo + file + function**
  (see §2), or the fix is labelled a workaround with the citation marked missing.
- `python3 -m py_compile tools/*.py` and `node tools/web_relay_worker_selftest.mjs` stay green.
- Nothing in `docs/agent-briefing/01`–`10` is contradicted; if it is, the pack is updated in
  the same change.

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
| "Colours look slightly off" in the multicolour section | channel resolution (§5): copy chains, HSV shifts, LBG (1007), `Color8` vs `Color/255` linear mismatch, native-vs-GDScript divergence |
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
  `inert_trigger_ids` is its sibling for the trigger itself: families that imported onto the
  component-less `NativeGenericTrigger.tscn` shell with no C++ arm behind them
  (`GMDObjects.has_native_effect`), record-only families that will not run in this build, and
  group-targeted pulses. A trigger in that list plays no sound, moves nothing and logs nothing.
- `_parse_pairs` (`:1934`) routes through the **native** `parse_gd_pairs` when the C++ backend
  exists — a malformed pair handling difference between native and GDScript is a parser-accuracy
  bug by itself; check both. The portable branch then applies
  `_normalize_legacy_properties` so a chunked import lands on the same object IDs, keys and
  groups the native bulk parser produces (the native parser rewrites inside
  `validate_and_record_object`; the rewrite must stay idempotent for re-imports of
  already-normalised data).
- `_components_from_properties` is where per-ID key vocabularies live: if a trigger's fields
  are not read here, the trigger does nothing no matter how correct the runtime is.

**Verified design facts — do not "fix" these** (checked 2026-10-04):

- Decoration (objects with no `GMDObjects.MAP` scene) is drawn by batched `DecorationBatch`
  nodes, and a batch is keyed by *group set + z layer + blend mode*
  (`GDDecorationLoader.add_object`), joining those groups itself
  (`GDDecorationLoader.gd:605`, "Joining the groups is what lets triggers move this batch").
  `NativeLevelRuntime::snapshot_effect_groups` collects the `Node2D` members of every
  effect-referenced group at level start, so a Move/Rotate/Scale/Toggle/Alpha trigger does act
  on decoration - as long as the objects sharing the group also share the rest of the key. That
  is why objects that move together always land in one batch and objects that move differently
  never merge. It also means group membership is *not* node-per-object for decoration.
- `GdashNative::parse_channel_styles`'s `channel_styles` output has **no consumer**: the import
  table used by the runtime is GDScript `_resolve_channel_styles` (the only other
  `channel_styles` hits are its own doc comment and the `parse_online_level` result dictionary).
  Keep the two formulas in step anyway - the native one is one call away from being consumed,
  and the 1007/1012 divergences above existed precisely because it was not.

---

## 4. Two execution paths — the single most common cause of "trigger doesn't work"

**`Config.use_native_core` is `true` by default** (`src/autoloads/Config.gd:94`). When the
GDExtension is present and `Editor.in_editor` is false, `_native_trigger_execution()`
(`src/static/GMDConverter.gd:1165`) packs these families as **records for the C++ runtime instead
of scenes**:

```
GMDObjects.NATIVE_EFFECT_TRIGGER_IDS (src/static/GMDObjects.gd:381):
  29, 30, 104, 105, 221, 717, 718, 743, 744, 899, 900, 901, 915, 1006, 1007, 1049, 1268,
  1346, 1520, 1612, 1613, 1616, 1913, 1916, 1935, 2015, 2067, 3022, 2913, 2919, 2920, 2921, 3613
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
   scene and run their components (`GMDObjects.gd:375` comment; `Level.gd:745` folds the packed
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

---

## 5. Colour accuracy

### The pipeline

`kS38` header string → `_resolve_channel_styles()` (`GMDConverter.gd:1459`) → per-channel
`{color, alpha, blending}` (+ runtime copy link) → `_build_color_channels()` (`:1577`) →
`ColorChannelData` per used channel → runtime `ColorChannelWatcher` /
`NativeTriggerBridge.register_channel` → C++ resolver.

Verified key vocabulary:

| Key | Meaning | Where |
| --- | --- | --- |
| `kS38` entry keys | `1/2/3` RGB, `4` player colour, `5` blending, `6` channel id, `7` opacity, `9` copied channel, `10` copy HSV, `17` copy opacity | `ChannelKey`, `GMDConverter.gd:139` |
| Colour trigger | `7/8/9` RGB, `23` target channel, `35` opacity, `50` copied channel, `49` copy HSV, `60` copy opacity, `17` blending, `15/16` player colours | `Prop`, `LEGACY_COLOR_TRIGGER_CHANNELS` (`:177`) |
| Reserved channels | `1000` BG, `1001`/`1009` G1/G2, `1002` line, `1003` 3DL, `1004` obj, `1005` P1, `1006` P2, `1007` LBG, `1010` black, `1011` white, `1012` lighter, `1013`/`1014` MG | `:103` |
| `kS38` keys `11`-`16` | `11/12/13` ToColour RGB, `14` DeltaTime, `15` ToOpacity, `16` Duration — a level-start From→To transition of a channel. **Read by neither path** (nor by GDRweb's `parseStartColor`); GD only writes them for pre-2.0 levels | Wyliemaster/gddocs, *Client Color String* |
| Header aliases | `kA6` BG, `kA7` ground, `kA17` line, `kA2..kA13` gamemode/mini/speed/dual/start-pos/song-offset, `kA20` reverse, `kA22` platformer, `kA11` flip | `HeaderKey`, `:153` |

### Verified divergences between the two paths — check these first

These are real, in-tree, and each is a plausible "colours look slightly off" root cause:

1. ~~**sRGB vs linear.**~~ **Retracted — the two paths agree.** The claim was that
   `Color8(...)` and `Color(r / 255.0, …)` build different colours. They do not:
   `Color::from_rgba8` *is* `Color(r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f)`
   (`godotengine/godot` 4.4, `core/math/color.cpp`), and `Color::html` divides by 255 the same
   way. There is no sRGB decode anywhere in the pipeline; both paths produce the identical
   float. Do not "fix" this — a change here would introduce the divergence it claims to remove.
2. ~~**LBG (1007) is implemented twice, differently.**~~ **Fixed — one formula, three call
   sites.** There were three: GDScript `lighter_background()` (desaturate 0.2, `lerp` towards
   player colour 1 by `background.v`), the watcher's `live_special_color(1007)`
   (`lightened(0.2)`), and native `live_special_color(1007)`/`resolve_copied_channel`/
   `resolve_channel_data_color` (`lightened(0.2)`). GD's own wording is "This copies the
   background color, except lighter and **with blending enabled**, but the color is tinted to
   player color 1 as the background gets darker" (gdcreatorschool.com, *Using Channels* — that
   site is documentation, not a decompilation; the same model is what GDRweb's
   `ColorManager.getLBG` encodes, and its `blend(P1, desaturatedBG, v/100)` only differs by a
   units slip). All sites now call `GMDConverter.lighter_background` /
   `gdash_native.cpp::lighter_background`, and 1007's channel default is **blending = true**
   in both style tables. Note LBG is the *default base channel* of a large object family
   (`GMDDefaultChannels.BASE`: 157-159, 227-235, 279-285, 406-420, 448, 767, 1050-1055,
   1099-1120, 1752-1757, 1830-1834, …), so this is a common colour, not a corner case.
   **Still open:** LBG is now a live derived channel in **GDScript** (1007 is in
   `SPECIAL_CHANNELS`, `Constants.SpecialColorChannel.LBG`, refreshed from the background
   setters) but the native *style seed* in `parse_channel_styles` cannot see `Config`, and its
   `channel_styles` output has no consumer today — reconcile it or delete it before relying on
   it. P1/P2 (1005/1006) are *not* defaulted to blending, although the same doc page claims
   they are: GDRweb defaults them off (`parseStartColor`, key 5 default false), so the two
   sources disagree. Verify on a device before changing that.
3. **Copy/HSV had four implementations; the C++ side is now one.** GDScript
   `_shift_hsv_string`/`_apply_copy_link` (`:1650`) and `ColorChannelWatcher._shift_copy_hsv`
   stay separate from C++ because they must work without the extension. On the C++ side,
   `parse_copy_hsv`/`shift_copy_hsv`, the copy branch of `resolve_source_color`, the pulse's
   `resolve_target_color` and the inline block in `NativeDecorationRenderer::apply_channel_color`
   now all call `native/src/hsv_shift.h` (`apply_hsv_shift`), which `native/tests/test_hsv_shift.cpp`
   exercises directly with plain g++. **Two different "neutral" rules live in that header and both
   are needed**: an all-zero shift is GD's "HSV enabled but the sliders were never touched"
   encoding and must be a no-op *inside* `apply_hsv_shift` (GDRweb's `HSVShift.shiftColor`
   returns early on it; applying the zeros paints objects black, which is what
   `tools/runtime_visual_smoke_test.gd` asserts against on both render paths), while
   `HSVShift::is_identity()` is GDRweb's flag-aware `isEmpty()` and answers *false* for that same
   shift. Folding the callers onto `is_identity()` alone is exactly the regression CI's Android
   job caught on `3e12d64`; do not remove the all-zero guard to "simplify" this.
4. **Blending is tri-state** (key `17` present vs absent) and both paths, plus the C++
   `parse_color_source`, carry comments explaining that a trigger without the checkbox must not
   revert an overlapping Blending flip. Preserve this when editing either side.
5. ~~**"Lighter" (1012) is derived twice, differently / frozen at import.**~~ **Fixed — one
   formula, live copy of Obj.** Both languages share `GMDConverter.lighter_object` /
   `hsv_shift.h`'s `lighter_object_rgb` (HSV saturation −0.2, value +0.2; covered by
   `native/tests/test_hsv_shift.cpp`). Wyliemaster/gddocs (*Level Colors*) names 1012 ("A
   lighter version of the primary color in objects. Used in the white small blocks found in
   build tab 2 on page 6") but gives no amount, and GD's colour resolver (`GJEffectManager`)
   is in no public decompilation, so **the 0.2 step is our extrapolation — the citation for
   the amount is missing**. 1012 is the default *detail* channel of the block008/block009 sets
   (`GMDDefaultChannels.DETAIL`: 850-896). A header kS38 entry for 1012 still wins. Without
   one, both style tables now store a live copy of Obj (`copy_source = 1004`,
   `LIGHTER_COPY_HSV = "0a-0.2a0.2a1a1"`) so a colour trigger that recolours Obj drags 1012
   through the watcher fan-out; `_include_copy_sources` pulls Obj into the runtime table
   whenever 1012 is used. 1012 is **not** in `SPECIAL_CHANNELS` — a special-copy would drop
   the header entry. The same reserved-table arm (1003/1004/1012/1013/1014) in
   `ColorChannelWatcher.live_special_color` (`:209`) now matches gdash_native: copies of
   those ids used to resolve white in GDScript while native read the channel table.
   Regression: `tools/runtime_visual_smoke_test.gd` `_test_reserved_channel_resolution`.
6. **Legacy families default a channel**: `LEGACY_COLOR_TRIGGER_CHANNELS` maps 29→BG, 30→G1,
   104→line, 105→obj, 221→1, 717→2, 718→3, 743→4, 744→3DL, 899→1, 900→G2, 915→line; a bare
   899 with no key 23 falls back to channel 1. Do not extend that table from memory: `901` is
   the *Move* trigger (native `case 901: MOVE`), and every ID in it must be verified against the
   2.11 `EffectGameObject::customSetup` before it is treated as a colour family.

### Known gaps (verified)

- `PULSE` (1006) is still inert when `key 52 == 1` (object-group target) — `gdash_native.cpp`,
  `case TriggerEffectKind::PULSE`. A group pulse recolours each member's own sprite, which needs
  per-object colour overrides this engine does not model; GDRweb does not implement it either
  (`ColorManager.getTrackListForTrigger` returns null for a group pulse), so there is no
  reference implementation to port. On 2.0/2.1 effect levels this changes the look.
  **HSV-mode pulses (`key 48 == 1`) were implemented** in the same change as this note: key 49
  is the pulse's own HSV shift, key 50 the colour it pulses from, and the shift is applied to
  the channel's live colour (`resolve_target_color`), matching GDRweb's
  `PulseHSVEntry.applyToColor` + `HSVShift.shiftColor`. **A Pulse never changes opacity**: GDRweb
  puts the input colour's alpha back on the pulsed colour
  (`third_party/gdrweb/src/pulse/pulse-entry.ts`: `fullColor.a = color.a`) and the 2.11 1006 key
  table has no key 35. The native arm used to read key 35 as a pulse's opacity, which snapped
  every semi-transparent channel a pulse touched back to 1.0 - it now keeps the channel's own
  alpha (`capture_color_target`, `const bool pulse = ...`). The component path still has no pulse at
  all: 1006 has no `GMDObjects.MAP` entry, so it imports as the component-less
  `NativeGenericTrigger.tscn` shell. That path is unchanged and remains a known gap — the
  editor and any build without the extension still do not pulse colours.
- Player channels P1/P2 (1005/1006) are intentional no-ops in the trigger arms in both paths
  (matching the component). If a level recolours P1/P2 via a trigger, GD *does* apply it —
  decide deliberately which is right.
- `_is_colorable_channel()` (`:926`) synthesises never-defined custom channels as white so a later
  colour trigger can reach them; that is deliberate GD behaviour, not a bug.
- **The two legacy normalisers are mutually exclusive and both idempotent** (checked 2026-10-04,
  no fix needed). The portable chunk path only runs when the native bulk parse produced nothing
  (`if not native_parsed: chunks = level_string.split(";", false)`), so `_normalize_legacy_properties`
  can never re-apply a rewrite the native `validate_and_record_object` already made; and every rule
  in both is written as "only when the modern key is absent" (104→915 sets key 17 only when it has
  no key 17, the 19→21 map only when key 21 is absent, keys 26/33 only when key 57 does not already
  contain the group, 32→128/129 only when both are absent or zero). Keep that shape when adding a
  rule — a normaliser that rewrites unconditionally turns a second pass into a different level.
- **`kS38` key 7 vs 17**: gddocs documents key 7 as FromOpacity and key 17 as CopyOpacity; the
  importer follows that (`ChannelKey`), while GDRweb's `ColorManager.parseStartColor` reads key 7
  twice (`let a = rd.number(7, 1)` and `copyOpacity = rd.bool(7, false)`). That is a GDRweb bug —
  do not "align" the importer with it.

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

- `_physics_process` → `_step_camera(delta * 60)`: player/ground distance → rotate into gameplay
  space → `local_target_distance_axis` (deadzone at `MAX_DISTANCE / zoom`, then
  `* 0.2 * framerate_compensation` catch-up) → rotate back → apply per axis unless
  `static_factor` blocks that axis → clamp the view to `ground_down + 160` / `ground_up - 160`
  → `offset = get_offset_target(framerate_compensation)`. This is the fix for divergence (e)
  below: the follow previously ran in `_process` and multiplied the *render* delta by 60, so the
  lead and catch-up scaled with the frame rate. Only the debug overlay's `queue_redraw` and the
  render-frame `snap_view` step remain in `_process`.
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
bounds), ~~(e) camera updates running in `_process`~~ — **(e) is now fixed**: the follow runs on
the physics tick with a 60-unit step, so it is no longer frame-rate dependent. (a)–(d) remain
open hypotheses. **Measure, don't guess** — see §9.

`updateCamera()`'s body itself is still unfetched: `camila314/gdp` puts it outside
`GJBaseGameLayer/GJBaseGameLayer_update.cpp`, and only the call site (`updateCamera(physicsDelta
* 60)` inside the fixed-step loop) is verified. Do not describe the follow as "matching GD"
until the lead and catch-up law are read from that function.

Re-verified 2026-10-04, do not repeat: the `camila314/gdp` tree on branch `2.2` contains only
`GJBaseGameLayer/GJBaseGameLayer_update.cpp` (11 kB) under that folder, and
`CallocGD/GD-2.205-Decompiled`'s `GD/code/src/GJBaseGameLayer.cpp` is 28.5 kB of constructors,
capacity setup and layer creation — no `updateCamera`. Its `EffectGameObject.cpp` is a 235-line
stub whose only trigger case is `case 1007: // Alpha Trigger`, so there is no colour-resolver
source there either. **The camera follow's citation is missing, not merely unfetched**; treat
(a)-(d) as hypotheses that need a device measurement, and keep any change behind the numbers in
§9 rather than "fixing" the lead or the catch-up law from memory.

### Camera trigger families (the table the rest of the work uses)

| ID | Trigger | Scene / component | Executed by |
| --- | --- | --- | --- |
| 1913 | Zoom | `CameraZoomTrigger` / `CameraZoomChangerComponent` | **native** (key `371`, % of `DEFAULT_ZOOM`) |
| 1914 | Static | `CameraStaticTrigger` / `CameraStaticComponent` | components (ENTER/EXIT via key `110`, centre group key `71`) |
| 1916 | Offset | `CameraOffsetTrigger` / `CameraOffsetChangerComponent` | **native** (keys `28/29` × cells) |
| 2015 | Rotate | `CameraRotateTrigger` / `CameraRotationChangerComponent` | **native** (key `68`, +`69`×360) |
| 2062 | Edge | `CameraEdgeTrigger` | components (`player_camera.limit_*`, reset ±10,000,000) |
| 2901 | Gameplay Offset | `CameraGameplayOffsetTrigger` / `...ChangerComponent` | components (`gameplay_offset_factor`, %) |
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

---

## 7. Broken-trigger taxonomy (use this to triage any "trigger X does nothing")

1. **Not in `GMDObjects.MAP`** → the object is skipped at import (`report.skipped_ids`).
2. **In `MAP` but its key vocabulary is not read** in `_components_from_properties` → a scene
   exists, the trigger fires, nothing changes.
3. **In `NATIVE_EFFECT_TRIGGER_IDS` without a C++ arm** → Area2D removed *and* no effect.
   (#1 silent-failure cause on the default config.)
4. **Target group is empty** because every member was skipped → `report.empty_target_groups`;
   the runtime warns "target group doesn't contain any objects".
5. **Correct effect, wrong state model** — e.g. blending tri-state, copy-opacity, spawn vs touch
   flags, `multi_trigger`, target-group vs centre-group (`71` vs `51`), `HIDE`/`TOGGLE`.
6. **Correct effect, wrong timing** — easing table (`_easing_to_tween`),
   `FADE_IN/HOLD/FADE_OUT` pulse envelope, 240 Hz step vs frame delta.

---

## 8. Working rules for this campaign

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

## 9. Evidence pack per fix (what to produce)

1. **Level + percentage + path** (`use_native_core`, editor/runtime, platform).
2. **The numbers**: for parser/colour, the resolved channel table before/after; for camera, a
   log of `(position, zoom, offset, static_factor, gameplay_offset_factor)` sampled per frame
   from `PlayerCamera` (add a temporary `--camera-trace` print, do not leave it on).
3. **The GD comparison**: same spot in GD (capture or a level-string dump of the trigger's
   properties) — or the cited decompiled function, if GD cannot be run.
4. **The regression guard**: a unit/self-test or a named level + percentage in
   `tools/`-based checks that fails before and passes after.
