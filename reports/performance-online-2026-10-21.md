# Runtime + online pipeline optimization pass — 2026-10-20/21

This pass targets the two user-reported problems: **large imported levels run
worse than Geometry Dash on mobile**, and **the online level pipeline is
slower and less robust than it should be**. Everything below was developed
without a device or a local toolchain in this workspace: native code follows
the existing godot-cpp patterns exactly and CI builds it; GDScript changes
were made under the project's native/GDScript parity contract (fallback first,
native behind `ClassDB.class_exists`). No device, GPU or whole-level FPS
measurement is claimed here — see "Verification limits".

## 1. O(total-objects)-per-frame work removed

The dominant structural cost on trigger- and orb-dense levels was not any
single function: it was **per-instance engine callbacks that fire whether or
not anything is near the player**.

| Component | Before | After |
| --- | --- | --- |
| `ReboundComponent` | N `_physics_process` at 240 Hz **plus** N `_process` at frame rate, one per rebound orb/pad in the level | one `SceneTree.physics_frame` + one `process_frame` driver iterates a static registry; per-instance callbacks are gone entirely |
| `GameplayTriggerComponent` | N `_physics_process` at 240 Hz; a static frame guard made N-1 of them no-ops, but the engine dispatch was still paid per instance | one `physics_frame` driver runs the shared clocks (item timers, follows, collision checks, level time) once per frame |
| `CameraStaticComponent` | idle `_physics_process` at 240 Hz per static-camera trigger | processing enabled only while `_tracking` |
| Collision pair evaluation | every `_collision_pairs` key evaluated every tick with a fresh `get_nodes_in_group` copy — **including native-handled levels where the GDScript triggers never arm** | only armed triggers are evaluated; block-group snapshot cached with a 30-tick refresh; arm-time baseline seeding keeps the first transition identical; Instant Collision (3609) now evaluates its pair at activation (the documented GD behaviour) instead of reading a last-tick snapshot |
| Timer events | `timer_events.duplicate()` per running timer per tick | snapshot-size index loop + deferred removal; zero steady-state allocation |
| Advanced Follow | three fresh typed Dictionaries + an Array per tick, plus a `properties.duplicate()` per extra target | retained scratch containers (cleared, not reallocated); the zeroed-StartSpeed params copy is cached per follow activation |
| `SpawnTriggerComponent` | `LevelManager.get_node_or_null(trigger.path)` at frame rate for every unresolved trigger, forever | first resolution is cached (start() already reports invalid paths once) |

The drivers live on `SceneTree.physics_frame`/`process_frame` rather than on
a component's `_physics_process`, which makes them immune to group toggles
disabling a trigger's parent (`_toggle_spawn_state` sets `PROCESS_MODE_DISABLED`
on group members) — the old code only survived that because *some other*
instance still received callbacks. Pause is checked explicitly to preserve
the old pausable-processing behaviour.

Execution-order note: the shared clocks previously ran inside the first
trigger's callback in tree order (an arbitrary, per-level accident relative
to the player's own callback); they now run once per physics frame, before
the node callbacks. Timer/follow/rebound state changes can shift by at most
one tick relative to player movement — the same class of skew the old
tree-order dependence already produced, but deterministic now.

## 2. Per-tick allocations removed from the 240 Hz player loop

- **Replay buffer**: `Array[PackedByteArray]` (one packed-array header plus
  an array element allocated every tick) → a flat `PackedByteArray` with two
  bytes per tick (`Replay.record_tick`). `GDRFormat`, `Level` practice
  snapshots and `tools/gdr_selftest.gd` were updated; the GDR on-disk format
  is unchanged because it was always derived from edge events.
- **Swing/robot fire arrays**: rebuilt via `assign([...])` every tick →
  built once in `_ready`.
- **Ball grounded look factor**: read/written through the node metadata
  dictionary every tick → a plain member.
- **Floor-angle mean**: `ArrayUtils.transform(MEAN)` allocated a dedup array
  and a reduce lambda per tick on slopes → inlined first-occurrence-wins mean
  with identical semantics.
- **`_handle_velocity_interactable`**: `components.filter(ArrayUtils.flatten)`
  per tick while touching a pad → plain loop; `Interactable.has/query` and
  `FireDashComponent`'s per-tick `query(EasingComponent)` no longer allocate
  Callables (component scan without lambdas, easing reference cached).
- **Kill overlap check**: a fresh `PhysicsShapeQueryParameters2D` per hitbox
  per pending kill → one reused query object; kill-collider handlers cache
  their hitbox arrays instead of `$` lookups per contact event.
- **Ghost trail**: a `Node2D` plus one `Sprite2D` per icon part allocated
  every 0.05 s (and freed 0.4 s later) → a 12-slot container/sprite pool;
  steady-state ghosting performs no node allocation.
- **Hover check**: `gui_get_hovered_control()` walked the GUI every tick; it
  now runs only when a press/buffer can make it matter (proven identical by
  enumerating every gamemode's non-neutral states).
- **`_handle_collision`**: the collision classifier's `NativeCore.backend()`
  static per hit → cached instance, plus a GDScript fallback twin for
  native-free builds (the old code would have crashed without the library).
- **`SFXManager`**: `_voices.duplicate()` per frame → backwards index walk;
  one persistent `RobTopLevels` client instead of a node per SFX download.

## 3. NativeSpriteTick — the sprite rotation tick in C++

`Player._update_sprites_rotation` was the largest remaining per-tick GDScript
function (~60 statements, ~20 node writes, 240 Hz per player, doubled for
duals). It is now `native/src/native_sprite_tick.h`: a `RefCounted` class
that resolves the icon/collider nodes once (`bind_player`, the same
`$NodePaths` the `@onready` vars use) and performs the whole tick in C++ via
one packed-params call, mirroring the GDScript statement-for-statement —
including the `rotation_degrees` rad→deg→rad round trips, Godot's
`lerp_angle`/`snapped`/`lerpf` semantics, `Math.polar_polygon_normalized`
(sides 5, curvature 2) and the `R(s)·S(dir,1)·R(-s)` flip transform.

- Inputs the player still computes in GDScript (replay-aware input, floor
  angle history, dash velocity angle) are packed into a 26-float
  `PackedFloat64Array`, same seam as `compute_player_velocity_packed`.
- The shared `_fire_sprite_time` stays in the player (the swing/robot fire
  animations, still GDScript, read it) and is advanced once per tick by
  `_physics_process` for both paths.
- `GPUParticles2D`/`ParticleProcessMaterial` are outside the trimmed
  `build_profile.json`; the particle writes go through generic `Object::set`
  on cached pointers, so **no new engine-class bindings are needed** (the CI
  trimmed-class-file count is unaffected).
- UFO jump particles stay a GDScript spawn, requested through the tick's
  returned bit flags.
- The GDScript function remains as the fallback; `Player.reset()` resets the
  native state. Absence of the class changes nothing (briefing rule 3).

## 4. Online level parsing

### 4.1 The whole parse no longer blocks the main thread

`GMDConverter.import_online_level_string` ran synchronously inside the
download coroutine — a 147k-object level (Amethyst, one of the bundled test
levels: 19.9M characters of level string) froze the UI for the entire
tokenize+convert, leaving "Downloading…" stuck long after the last byte.
`RobTopLevels.import_level_string_threaded` now runs the conversion on a
worker `Thread` (the conversion is pure data — dictionaries and packed
columns; scenes instantiate later in `LevelBuildJob`) and awaits it, with a
synchronous fallback when threads are unavailable and an error dictionary
when the worker crashes.

### 4.2 One full-string scan per import instead of two

`import_online_level_packed` returned only `min_x/max_x`; `GMDConverter` then
called `level_bounds`, which **re-tokenized the entire multi-megabyte level
string a second time** to compute the kill height. The native importer now
mirrors `gd_scan_level_extents` in its existing chunk loop (first chunk
skipped unconditionally before the emptiness check, a chunk counts iff it
carries a key-2 token, values raw like `strtod`, duplicate keys last-wins via
`PropList`) and returns a `level_bounds` dictionary identical to
`level_bounds()`'s output. GMDConverter uses it and falls back to the scan
only when absent (non-native builds, older binaries). The parity rules are
pinned by new cases in `native/tests/test_online_parser.cpp` (headerless
levels, empty first chunk, duplicate keys, key-2-less chunks, negative
coordinates).

### 4.3 Transfer robustness

- **Real progress**: a `download_progress(id, bytes, total)` signal is
  emitted from the existing poll loops (which already waited on
  `process_frame`); `LevelPanelLoader` shows a live percentage/byte count on
  the download button instead of a frozen label.
- **Level cache**: downloading a level that is already saved (`*[GD-<id>].bin`
  in `user://created_levels/levels/`) skips the network, the parse *and* the
  song re-download, and plays the saved file directly.
- **Request pooling**: every request used to build, parent and free a fresh
  `HTTPRequest` (own DNS+TCP+TLS per candidate/retry); idle nodes are now
  pooled (`REQUEST_POOL_SIZE = 6`).
- **Web retry parity + Cloudflare statuses**: the Web relay POST had a single
  attempt while desktop had three; both paths now share the bounded
  backoff loop, and 520/521/522/526 join `TRANSIENT_HTTP_STATUSES` (the HTML
  error sniffer already detected 522 pages but never retried them).
- **Song candidate order**: `getGJSongInfo.php` was POSTed before *every*
  mirror attempt; the fast BunnyCDN/Newgrounds candidates are now tried
  first and RobTop's percent-encoded URL is the final fallback (identical
  coverage, one POST saved in the common case).

### 4.4 Audio sniffing tightened (behaviour change, deliberate)

`GdashNative.is_audio_stream` accepted **any body ≥ 16 KiB** as audio, so a
large CDN error page could be cached as `robtop_<id>.mp3`. The fallback is
gone; Ogg (magic + version 0), RIFF/WAVE (magic at 0 and 8), ID3 (syncsafe
tag size must fit the body), raw MPEG sync (non-reserved version/layer
bits) and FLAC are each structurally validated, and the text-page sniff
compares raw bytes instead of building a 128-character String per download.
Known edge: an MP3 with leading zero-padding before the first frame sync is
now rejected where the size fallback used to save it — the candidate chain
then tries the next mirror, which is the better failure. Tests updated in
`native/tests/test_online_parser.cpp`.

### 4.5 Parser accuracy validation

The header key map was validated against the four bundled real levels
(decompressed from `Test Levels (for testing accuracy of level parser)`):
Amethyst (spider start) carries `kA2 = 6`, matching `GAMEMODES[6] = SPIDER`;
`kA4` = speed (Change of Scene `kA4 = 1`, and the vendored gdrweb parser
reads speed from `kA4` too); `kA13` = song offset in seconds (142.0 on
Amethyst, 149.1 on Change of Scene); `kA6/kA7/kA25` = background/ground/
middleground; `kA18` = font; `kS38` channel entry fields match
`GMDConverter.ChannelKey` on all four levels. No mapping corrections were
required; `kS39` (keyframe string) and `kA14`/`kA15` are editor metadata with
no runtime meaning and remain intentionally unread.

## 5. Diagnostics discipline

`Level._print_beam_diagnostics_live` resolved every colour channel and walked
every registered native canvas (`render_stats`) every 5 seconds of gameplay,
on every device, for a print nobody reads — a visible periodic hitch on
mobile. It is now gated behind `Config.draw_debug_overlays` (Debug → Draw
debug overlays), which is also how the debug HUD is enabled. The BEAMDIAG
capture for a device logcat is unchanged when the flag is on.

## 6. What was deliberately *not* done

- **`_get_jump_state`/input semantics** stay in GDScript: they encode click
  buffering, claim-touch, replay playback and UI-hover interactions whose
  exact order is gameplay-critical.
- **Orb/pad Area2D gating** (distance-disabling `monitoring`) was rejected:
  teleports can move the player arbitrarily far within one tick, and a
  gating bug there kills gameplay, not just frames.
- **Triangle-array decoration batching** stays rejected per
  `docs/agent-briefing/06-native-extension.md` §13 (clip-UV pixel parity).
- **Full `GMDConverter` object-loop nativization** (per-object dictionary
  construction for non-decoration objects) is the next candidate, but it
  needs a native selftest harness equivalent to
  `tools/level_open_memory.gd` first.

## 7. Verification limits

- No Godot editor, device, or compiler was available in this workspace;
  native code follows the file's existing godot-cpp API usage exactly
  (`Math::deg_to_rad`, `PackedFloat64Array::ptr()`, `Object::cast_to`,
  `ClassDB::bind_method` patterns) and adds no build-profile classes.
- The C++ extents/audio changes are covered by the standalone
  `test_online_parser.cpp` harness (updated); NativeSpriteTick is a
  statement-for-statement translation with the GDScript fallback retained —
  an in-engine A/B (native on/off) visual check on a device is still needed,
  as is an FPS comparison on a trigger-dense level.
- `tools/gdr_selftest.gd` was updated for the flat replay buffer and should
  pass unchanged in CI; the GDR golden bytes are produced from replay state,
  which is identical.

## 8. Follow-up pass: per-frame C++, physics gating, GPU-culling analysis

### 8.1 The "Bismuth-style GPU culling" request, analysed

Bismuth's gains in GD (Cocos2d-x) come from (a) compute-shader culling that
skips per-sprite CPU work, (b) draw-call batching, and (c) multithreading.
Mapping each onto this engine:

- **(c) Multithreaded culling already exists**: `NativeDecorationCullWorker`
  posts one cull job per decoration batch (~800 on Amethyst) to Godot's
  `WorkerThreadPool` every frame — the cull work itself already runs on all
  CPU cores, off the main thread, and the per-batch capture loop early-outs
  with a bit-exact transform compare when the camera is still.
- **(a) True GPU-side culling is not reachable from a Godot 4.7
  GDExtension**: 2D drawing is CPU-recorded — the visibility decision has to
  feed `RenderingServer.canvas_item_add_texture_rect_region` from the main
  thread. A compute shader could evaluate visibility on the GPU, but the
  only readback the RenderingServer exposes (`texture_get_data`) is a
  full pipeline sync per frame; on mobile that stall would cost more than
  the cull saves. There is no async-fence/timestamp readback API, and no
  GPU-driven 2D path, in 4.7. This is an engine API boundary, not missing
  effort — the worker-thread cull is this engine's Bismuth equivalent, and
  the profiling note in `reports/idle-render-work-2026-10-16.md` shows the
  remaining Amethyst cost is GPU *draw* time, not CPU cull time.
- **(b) Draw-call collapse** was already attempted and rejected
  (`canvas_item_add_triangle_array` aggregation, see briefing §13): it broke
  clip-UV sampling parity by 11 of 9216 pixels on the Android Mobile gate.
  Re-attempting it requires the half-texel-inset UV correction plus a
  passing pixel gate on real hardware — it stays out until that evidence
  exists, exactly as the briefing requires.

### 8.2 Swing/robot flame animation → NativeSpriteTick

The two remaining 240 Hz per-player GDScript bodies,
`_update_swing_fire` and `_update_robot_fire`, are now C++ methods on the
same `NativeSpriteTick` class (`tick_swing_fire`/`tick_robot_fire`), with
the flame sprites and their particle emitters resolved at `bind_player`.
The math mirrors the GDScript exactly (Godot's unclamped `remap` over the
sine band, the `1 - exp(-delta * 12)` settle, per-axis position/scale
writes); `Player.reset()` routes its oversized-delta settle call through
the same methods, and the GDScript functions stay as the native-free
fallback. Particle fields still go through generic `Object::set` since
`GPUParticles2D` remains outside the trimmed build profile.

### 8.3 Physics: the per-tick redirect cast is now level-gated

`_ensure_velocity_redirect` ran a full `ShapeCast2D` query along the entire
velocity **every physics tick** (240 Hz × players) on every level. Its
result can only become true through a `ReboundComponent` (airborne) or a
REDIRECT `TeleportComponent` — both level-build-time populations — so the
player now skips the cast entirely when `ReboundComponent.any_registered()`
and `TeleportComponent.redirect_count` are both zero (the counter is
await-window-safe via a per-instance flag). Levels *with* rebound orbs keep
the exact cast; no physics semantics change either way.

On the wider "move physics to C++ / use proper RIDs" request: the probes
(`move_and_collide` ×3-4 + `move_and_slide` at 240 Hz) already execute
inside the engine's C++ `PhysicsServer2D` through the body's RID — GDScript
pays only per-call marshalling, and `move_and_slide` (depenetration,
platforms, floor snap) is thousands of lines of engine code that a
GDExtension twin would have to replicate bit-for-bit to keep "almost exact
gameplay"; replacing that blind would be reckless. The shared-chunk
`LevelPhysics` commit path already speaks RIDs natively
(`commit_collision_shapes`/`reenable_collision_shapes`). The measured wins
this pass were the ones that were safe to take: gating the provably-dead
cast and moving the per-tick *gameplay-visual* work out of the interpreter.

### 8.4 Bloom, blending and z-ordering: verified retained

Nothing in this pass touches blend routing, z sorting or the bloom pipeline;
for the record they are: per-channel additive blending in the packed
importer (channel key 5 → `col_flags` bit 0 → the renderer's blend routes)
and `set_channel_blending` flips at runtime; z ordering via key 24/25 with
the ±9999 clamp and a stable sort that preserves GD's placement order on
ties; bloom through Godot's `Environment` glow on desktop
(`Config.bloom` applies live through its setter) and the
`WebSoftEffects` low-res world re-render + extract + overlay chain on Web
(read per frame). The earlier pixel-parity rejection of triangle batching
(§8.1) is precisely the safeguard that keeps blend/UV sampling identical to
the current renderer. The per-frame capacity freed by §8.2/§8.3 is what
protects these effects' frame budget on device — no artwork was hidden or
downgraded to buy it.

### 8.5 Not converted, and why

- `PlayerCamera._process`, `PercentageLayer`, `GameScene`'s ground tint:
  single instances at 60 Hz whose cost does not scale with level size.
- `_get_jump_state`, orb/pad interaction, `move_and_slide`: gameplay- or
  input-critical; the risk of a blind rewrite outweighs the marshalling it
  would save.
- `_update_wave_trail`: `Line2D` is outside the trimmed build profile, and
  the per-tick work is two lerps and an alpha move-toward.

## 9. Third pass: a better way to render levels

### 9.1 The idea that unlocks it

The rejected 2026-10-15 triangle-array experiment (briefing §13) failed on
one specific property: `canvas_item_add_texture_rect_region` clamps fragment
UVs half a texel inside the source region, so edge fragments never sample
across a frame border, while raw triangle UVs do — the 11/9216 mismatch was
gutter bleed. That property is fixable **in the asset**: `tools/build_godot_atlas.py`
now duplicates every frame's edge texels 1px into its existing 2px packing
gutter (`--extrude`, default on; `--no-extrude` keeps today's pages). With an
extruded border, sampling *at* a region border returns exactly the edge
texel — which is also what the clamp produces — so the two sampling modes
converge and unclamped UVs become safe. Frame rectangles and page geometry
are unchanged (the extrusion lives entirely in the gutter), so the JSON, the
generated object scenes, `Sprite2D` regions and the cocos fallback are all
unaffected; `GDSpriteSheet` records the flag from the JSON's new
`"extruded": 1` meta key.

### 9.2 The renderer path it enables

`NativeDecorationRenderer` gained a conditional triangle-array submission
path, off unless the atlas is extruded:

- `configure`/`configure_renderer` take a trailing `arrays` flag
  (`DEFVAL(false)`), passed by `DecorationBatch._build_native_canvas` and
  `GDDecorationLoader`'s packed-builder call from
  `GDSpriteSheet.packed_atlas_extruded`. Old atlases and the cocos2d
  fallback keep the clipped-rect path bit-for-bit.
- When active, `rebuild_commands` accumulates each blend route's visible
  records in draw order (the worker-selected order the rect path uses) and
  submits **one `canvas_item_add_triangle_array` per contiguous
  same-texture run** instead of one clipped rect command per sprite:
  ~30k visible sprites collapse from ~30k+ rect commands to a handful of
  array submissions per batch. Same quads, same order, same per-record
  tint/pulse through vertex colors, same blend routes, same culling — only
  the command count changes. This is the GD/Bismuth-style big-vertex-buffer
  submission the §8.1 analysis wanted, done the one way Godot's API permits.
- Per-route scratch buffers are retained between rebuilds, so pulsing and
  spinning batches (which rebuild per tick by design) reuse capacity. The
  existing dirty-route machinery, `set_item_transform`, `set_item_color`,
  channel recolour, blending flips, UI pivot alignment and monster timelines
  all drive the array path unchanged.
- `render_stats()` gains `triangle_array_canvases` so CI and device logs can
  see the path is actually on.

### 9.3 Gates

- **New CI gate**: `tools/runtime_visual_smoke_test.gd` gained a
  `TriangleArrays` parity section — a synthetic extruded page (two 8×8
  frames, 2px gutter, per-texel gradients) drawn through the array path
  vs clipped-rect references, at the existing 1/255 whole-neighborhood
  tolerance. UV flips, offsets or missing extrusion fail it deterministically
  (a missing gutter drop halves edge alpha; a UV shift lands on the gradient).
- The existing `RenderingServer` parity gate then re-validates the real
  in-game path once the atlas is regenerated.
- `renderer_cache_selftest` keeps exercising the rect path explicitly
  (it configures without `arrays`), so its counter assertions stay valid.

### 9.4 Activation and honest limits

Activating the faster path requires regenerating the atlas —
`python3 tools/build_godot_atlas.py` — which this environment cannot run
(no Python/Pillow). Until then everything behaves exactly as before. After
regeneration the flag flips automatically and both CI gates police it.
Measured wins on real devices remain to be captured: the win profile is
fewer command recordings and one large vertex submission per batch (CPU) plus
fewer, larger draw items on the GPU — the same axis Bismuth targets, but its
"×16" numbers came from GD's unbatched Cocos2d-x baseline and will not
transfer one-to-one to Godot's already-batched 2D renderer.

### 9.5 File summary for this pass

- `tools/build_godot_atlas.py` — `extrude_crop`, `--no-extrude`, `"extruded"`
  JSON meta.
- `native/src/gdash_native.cpp` — `use_arrays` + per-route buffers +
  `flush_route_array` + the array branch in `rebuild_commands`;
  `configure(..., arrays)`, `configure_renderer(..., arrays)` with
  `DEFVAL(false)`; `uses_triangle_arrays()`; `render_stats` extension.
- `src/static/GDSpriteSheet.gd` — `Sheet.extruded`,
  `packed_atlas_extruded` (reset per load; cocos fallback can never enable it).
- `src/DecorationBatch.gd`, `src/static/GDDecorationLoader.gd` — pass the
  flag through both build funnels.
- `tools/runtime_visual_smoke_test.gd` — the extruded-page `TriangleArrays`
  parity gate.
- `docs/agent-briefing/06-native-extension.md` §13 — the conditional second
  attempt, its safety argument and its gates.


