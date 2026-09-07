# Godot Dash ↔ GD object pipeline unification — plan of record

Status: **in progress**. This file is the authoritative architecture document for
the restructuring requested by the user. Decisions marked *decided by user*
were answered through the clarification tool; everything else is design.

## Goal (user request)

1. Use the generated `scenes/gd_objects/gd_<id>.tscn` object scenes **in place of**
   the Godot Dash level-object scenes (`scenes/components/level_components/…`:
   solids, hazards, orbs, pads, portals, triggers, letter objects), **including in
   the editor**, and unify the code so the gd object scenes behave like the old
   scenes. Only those Godot Dash *object* scenes go away; the rest of Godot Dash
   stays.
2. Draw object art **only from the GD atlases**; delete the original Godot Dash
   SVG art used by those object scenes (menu/UI art stays).
3. **One physics body per whole level** (no per-object bodies); collision shapes
   added automatically at level build.
4. GD hitboxes on the gd scenes must be **PRISTINE** (exact GD metrics). Old
   scene hitboxes are only a starting reference and do not cover every GD object.

## Decisions locked with the user (2026-09)

- **Shared-physics scope**: merge the *static world* only — solids/slopes/ground
  into shared `StaticBody2D`s, rectangular hazards into one shared hazard
  `Area2D`, circular hazards into another shared `Area2D`. Interactables (orbs,
  pads, portals, triggers, endpoints, checkpoints) **keep their per-object
  Area2D**: their root Area2D is what the `Interactable` editor tab,
  components (`ReboundComponent`, …), and per-object `interacted` signals are
  built on, and each one must attribute its own touch event.
- **Lethal wall/ceiling hits**: keep today's visible behaviour via *per-shape*
  handling — disable that block's `CollisionShape2D` on the shared body, let the
  player's kill-collider death path trigger as today, re-enable on overlap-exit.
  (Today this is done by mutating the collided body's `collision_layer`
  per-object in `Player._handle_collision` / `_on_solid_overlap_check_body_exited`,
  which is impossible on a shared body.)
- **Saved-level migration**: *not required*. Old `.level` files referencing
  deleted component scenes are allowed to break; all new/imported content flows
  through the unified gd-scene pipeline.

## Current pipeline (facts on the ground)

- `Level.from_data` (src/Level.gd) makes two different kinds of node:
  - *decoration* entries (`"decoration": true`) → `instantiate_gd_object()` →
    `scenes/gd_objects/gd_<id>.tscn` (`GDObject` Node2D: Base/Detail atlas
    sprites + colour-channel watchers + optional `Collision` body +
    `EditorSelectionCollider`).
  - *gameplay* entries → `instantiate_object_from_data()` → old component
    scenes, with `GDArtSwap` overlaying atlas art afterwards.
- `GMDObjects.MAP` maps GD id → old scene path; `GMDConverter` stores
  `scene_file_path` on gameplay entries and `gd_object_id` on decoration
  entries; export reverses the mapping (`GMDObjects.get_gd_id`).
- Old interactable scenes: root `Area2D` + script (`OrbInteractable`,
  `PadInteractable`, `TriggerInteractable`, …) with component nodes as direct
  children named after their class; `EditorSelectionCollider` child (type/id);
  per-object physics (RigidBody2D freeze / Area2D).
- Player physics contracts (src/Player.gd, scenes/components/game_components/Player.tscn):
  - body `collision_mask = 122`; `platform_floor_layers` covers solids/ground/slope layers.
  - KillColliderSolid (Area2D, mask 512 = layer 10); KillColliderRectangularHazard
    (Area2D, mask 4 = layer 3); KillColliderCircularHazard (Area2D, mask 2048 =
    layer 12); SolidOverlapCheck (mask 512).
  - Layers (project.godot): 1 player · 2 solids · 3 rectangular_hazards ·
    4 interactables · 5 triggers · 6 ground · 7 slope_enablers ·
    8 editor · 9 editor_selection_colliders · 10 solid_overlap_check ·
    11 velocity_redirectors · 12 circular_hazards.
- Old scene roots by category: solids RigidBody2D frozen `layer 2` (slopes
  `layer 66` = 2|64); spikes/ground spikes Area2D `layer 4`; saws Area2D
  `layer 2048`; orbs/pads/portals Area2D `layer 8`; triggers Area2D (no
  gameplay layer, body_entered only); letter objects no physics.
- Units: 1 GD cell = 30 GD units; scene px per GD unit = `Constants.CELL_SIZE /
  GD_CELL_SIZE` = 128/30 (≈4.2667). Atlas is -hd: 2 atlas px per GD unit;
  generated art scale `ART_SCALE` = 128/30/2 ≈ 2.1333.
- `tools/build_gd_object_scenes.py` regenerates scenes from
  `object_frames.json` + atlas; it preserves the scene UID and any hand-authored
  `Collision` subtree, but today every scene ships the *placeholder* empty
  `Collision` (StaticBody2D layer 2 + empty `Hitbox`).

## Target architecture

### 1. Every gameplay object instantiates from its gd scene

Gameplay level entries become gd-scene entries that carry extra data:

```
{
  "scene_file_path": "scenes/gd_objects/gd_8.tscn",   # identity, replaces old path
  "gd_object_id": 8,                                   # kept on gameplay objects too
  "name", "transform", "groups", "color_channels", "hsv", ...  # as today
  "components"/"markers":  only interactables (unchanged format)
  "attributes"/"physics"/"texture_override": unchanged keys
}
```

- `GMDObjects.MAP` entries' `"scene"` switch to `scenes/gd_objects/gd_<id>.tscn`
  and `GMDObjects.get_gd_id()` learns the gd scene path family, so export keeps
  round-tripping.
- Imported decoration objects and gameplay objects then share one instantiation
  path (`Level.instantiate_gd_object` extended with gameplay setup), and
  `GDArtSwap` is deleted (its art is already the atlas; nothing left to swap).
- Fallback-block IDs (BLOCK_ID_RANGES) stop becoming `NinePatchBlock`
  placeholders: each has a real gd scene with its true atlas art.

### 2. Behaviour for interactable gd scenes

Static gd objects need no behaviour (groups/toggles act on the node generically).
Interactables keep an Area2D per object, so each gameplay gd scene for an
interactable ID carries a child behaviour subtree:

```
GD<id> (Node2D + GDObject: art, channels, groups)
├── Base/Detail …
├── Collision              (data; consumed by the level physics builder, freed at build)
└── Behaviour (Area2D + OrbInteractable/PadInteractable/TriggerInteractable…)
    ├── JumpBoostComponent …        (per-ID exports identical to old scenes)
    ├── Hitbox                      (PRISTINE touch hitbox)
    └── EditorSelectionCollider     (type INTERACTABLE + id)
```

- Editor: `InteractableEditor.player_to_interactable()` / `is_interactable()`
  and the few other `object is Interactable` tests learn to map a GDObject root
  to its `Behaviour` area, so the Interactable inspector tab keeps working on
  gd-scene objects.
- Old component code (src/interactables/*) is *kept* — only the old object
  scenes die.

### 3. One level physics body

New level-build pass (runs for both editor playtest and standalone play, at the
point where the Level node is assembled — `Level.use_data`/`from_data`) reads
every placed object's `Collision` data and emits a small fixed set of bodies on
the Level instead of per-object bodies:

- `StaticBody2D` for solids/slopes geometry. Collision layer bit is a per-body
  property, so slopes/ground/solids that need extra layers get **one body per
  distinct layer combination needed by the level** (at most a handful).
- `Area2D` (layer 3, rectangular hazards) for all spikes, shared.
- `Area2D` (layer 12, circular hazards) for all saws, shared.
- Interactables/triggers stay per-object Area2D (user decision).
- Per-object `CollisionShape2D`/`CollisionPolygon2D` nodes are removed from the
  tree after their data is harvested (per-shape keys kept so single-use/toggle
  disable paths can find their shape on the shared body).

Player death semantics after merge:
- Hazard overlap: identical (shared hazard areas emit area_entered).
- Lethal wall/ceiling: in `Player._handle_collision`, instead of flipping the
  collided body's layer, disable that object's shape on the shared body and
  trigger the same death path the kill collider used; re-enable when the
  overlap check exits (or on attempt reset).

### 4. Pristine hitboxes

`tools/gd_collision_specs.py` is the single source of per-object collision data
(scene-px geometry, layer/kind, provenance). Policy, in order:
1. IDs with an old-scene hitbox in `GMDObjects.MAP` reuse those numbers verbatim
   (user-sanctioned), expressed as rect/circle/polygon + position relative to
   the gd scene origin.
2. IDs in the solid-block ranges without an old equivalent get the exact
   content rect derived from the atlas frame source size (GD's own
   content-size hitbox rule): w = src_w_hd/2 GD units, converted at 128/30.
3. Everything else carries no gameplay collision (decoration).
The generator writes these into `Collision` and stamps the subtree with a
metadata marker so regenerations can update values but real hand edits still
win.

## Milestones

- **M1 — Collision data + generator** (this pass):
  `tools/gd_collision_specs.py` (spec table + auto block rule + provenance),
  generator emits real shapes for gameplay IDs into `Collision`, keeping the
  subtree replaceable-until-hand-edited. Runs for the static gameplay ID set;
  scenes for interactable IDs are filled in the same milestone where the old
  scene geometry exists (touch hitboxes) — nothing reads them yet.
- **M2 — Shared level body + Player per-shape death**: ✓ shipped 2026-09-07
  (`src/LevelPhysics.gd` + Level/Player/editor-session wiring; see notes below).
  Old scenes still drive gameplay art until M3.
- **M3 — Gameplay objects instantiate from gd scenes (static set)**: ◐
  import + level load/save paths shipped 2026-09-07 (see notes below); editor
  palette repoint + `GDArtSwap` retirement for statics still pending.
- **M4 — Interactables on gd scenes**: behaviour subtree generation, editor
  `Interactable` mapping, palette swap for orbs/pads/portals/triggers/letter
  objects/checkpoints, export round-trip verification.
- **M5 — Deletion & cleanup**: remove the old object scenes under
  `scenes/components/level_components/` (keeping shared/editor pieces:
  `EditorSelectionCollider.tscn`, …), remove their SVG art + `GDArtSwap`,
  update README/docs.

## Verification without a Godot binary in the sandbox

- Static: scene files parse; generator idempotent; `gd_<id>.tscn` diffs limited
  to intended IDs; export identity tables consistent.
- Manual (user-side): open/play a level, playtest from editor, import/export a
  `.gmd`, verify block/slope/spike/saw touchboxes and wall-kill behaviour.

## Known data-quality TODOs (pristine pass)

- 1202-1205 / 1220-1222 (`blockOutlineThick_*`): frame sources are thin bars,
  not squares — whether GD treats them as solid bars, hollow outlines or
  decoration needs GD hitbox-viewer confirmation; current table keeps their
  exact content boxes.
- Saw radii: copied from old scenes (140.36/96.1/64.0); sawblade_01's frame
  spans 167×164 hd px while its hitbox is ~0.8× that; needs GD measurement.
- Spike tip margins: old scenes use inset hitboxes (e.g. Spike 20×31 at y+27.5);
  kept verbatim, to be cross-checked against GD hitbox-viewer dumps.

## M2 implementation notes (2026-09-07) — carved-out decision now recorded

**Transform-changer carve-out (decided here, was the open question).** Solids
targeted by a move/rotate/scale trigger cannot be merged: those triggers
(`PositionChangerComponent`, `RotationChangerComponent`, `ScaleChangerComponent`)
resolve their target list at runtime from the scene tree via
`TargetGroupComponent.target_group` and animate node transforms — a merged
object's node transform would animate while its collision shape stayed on the
immobile shared body. Rule: an object whose group name matches the target of any
interactable carrying one of those three changers keeps its own body. The build
pass gathers those group names up front (`LevelPhysics._dynamic_transform_groups`)
and the per-object body is restored if a trigger targeting its group is added
between builds. Pushable/physics-edited solids (`SolidObject.physics_object`)
also keep their own bodies; hazard Area2D layers and per-shape wall/ceiling
disable are handled as planned.

**Shipped in this session (runtime collector, in GDScript, not a Python tool):**
`src/LevelPhysics.gd` — a level-owned container of a small fixed set of bodies
(`Solids` StaticBody2D layer 2, `Slopes` StaticBody2D layer 66, `RectHazards`
Area2D layer 4, `CircleHazards` Area2D layer 2048), harvesting per-object
`Collision` subtree / old-scene body geometry (rects, circles, convex polygons)
with shape positions expressed relative to each object root so rescale/rotation
between rebuilds stays correct. Merged objects' own bodies are neutralised
(layer/mask 0, shapes disabled, monitoring off) and snapshotted so the merge is
fully reversible.

Wiring:
- `Level.start_level()` calls `LevelPhysics.prepare()` before the player moves:
  full rebuild only when the level changed since the last build (layers tracked
  via `child_entered/exiting_tree` → dirty meta), otherwise just re-enables the
  shared shapes gameplay disabled on the previous attempt. Component data is
  always settled by then (level loads and `restart_level` already pass ≥1 frame
  after deserialization).
- `Player._handle_collision`: lethal wall/ceiling hit against a shared body
  disables the exact collided shape (resolved via the collision report's shape
  index) and plays the same `DeathAnimation` the kill collider triggers;
  spider-dash pass-through works because the shape is disabled. Per-object
  bodies keep the old layer-flip path. `_on_solid_overlap_check_body_exited`
  no-ops for shared bodies.
- Teardown on session end (not between attempts): `EditorScene.stop_playtest()`
  and `GameScene._on_leave_pressed()` restore every object's own collision and
  free the shared bodies, so editor editing/undo is unaffected.

Deviation from the M2 sketch above: merged shapes are *disabled and snapshotted*
rather than *removed from the tree*; this keeps gd scenes reusable and lets the
same object move between merged/per-object states across rebuilds (trigger-group
changes) without data loss. "Re-enable on overlap exit" is done per attempt in
`prepare()` (spider-dash hole persists only until the attempt ends, matching the
old exit-restore behaviour in every practical flow).

Runtime-untested in the sandbox (no Godot binary; see Verification).

## M3 implementation notes (2026-09-07) — import & load path shipped

Static gameplay objects (blocks, slopes, spikes, saws, and the fallback-block
families) now import and rebuild from their **generated gd scenes** instead of
the hand-made component scenes:

- `GMDObjects`: `is_static_gameplay_object()` (MAP entries whose scene lives
  under the solids/ or hazards/ dirs, i.e. no component behaviour) and
  `gd_scene_path()` (relative path of the generated scene, empty when the build
  lacks it).
- `GMDConverter._object_from_properties`: static gameplay entries write
  `scene_file_path = scenes/gd_objects/gd_<id>.tscn` (falling back to the old
  scene only when the gd scene is absent, e.g. 290/292 slopes). Everything else
  in the entry (transform, groups, color_channels, hsv, gd_object_id) is
  unchanged, so saved levels and export keep working.
- `GMDConverter.export_level_string`: exports by the recorded `gd_object_id`
  when present (static objects now live in per-ID scenes, and scene paths no
  longer identify them), falling back to `get_gd_id(scene_path)` for older
  entries. Pure decorations are still skipped.
- `Level`: generated-scene placements get one shared configuration path.
  `instantiate_gd_object()` grew a `_configure_gd_object()` helper (draw order,
  tints, Base/Detail colour-channel watchers, HSV, enter effect, attributes);
  gameplay instantiation of a GDObject-rooted scene calls the same helper and
  stamps the node with `GD_GAMEPLAY_META`. Decoration entries are untouched.
- `Level.serialize_gd_object` / `GDObject.to_gameplay_data`: gameplay
  placements serialize back in the gameplay entry format (scene path +
  gd_object_id + transform/groups/color_channels/hsv), so they rebuild through
  the gameplay path and are never treated as decoration (no low-detail culling,
  no batch collapsing). Decorations keep `to_data()`.
- Old hand-made scenes are still instantiated when a data entry references them
  (palette placements, older saved levels, interactables until M4), so this is
  a clean dual-path transition.

Remaining for M3 (next pass): repoint the editor block palette buttons at gd
scenes (with their texture-variation ids), and retire GDArtSwap usage for
static objects placed from the palette.

## Perf fix (2026-09-07) — batch decoration during play

Big imported levels showed 92,940 nodes / 23 ms scene-tree Process at 24 FPS.
Root cause: since M1 generated gd scenes for every object type,
`Level.from_data` instanced essentially all decoration as individual GDObject
nodes; the project's own DecorationBatch design exists precisely because a
node-per-object level "spends its whole frame on scene-tree and physics
bookkeeping" (its header doc). Fix: decoration entries are drawn by
DecorationBatch whenever not editing (standalone play); the editor keeps
per-node decoration so pieces stay selectable/editable. Gameplay objects
(per-object gd scenes) are unaffected. Batches join their objects' GD groups,
so triggers still drive decoration, and they draw from the same atlases.

## Perf fix 2 (2026-09-07) — free merged static bodies during play

The profile of a big level showed ~124k *physics objects*: every static
gd_object's own Collision body (StaticBody2D/Area2D) stayed registered in
the physics server even though LevelPhysics had disabled its layers and
shapes. A registered body costs a physics-server object and tree nodes no
matter what. LevelPhysics now frees the Collision child of merged gd-scene
objects after harvesting (its geometry is cached in DESCRIPTORS_META +
SNAPSHOT_META) and rebuilds an identical body (type, name, transform,
layers, shapes, monitoring flags) from that cache when the level stops
being played or an object becomes dynamic again. Hand-made scene roots
(their own body) keep the in-place disable path. Expected: physics objects
drop to ~zero per static gameplay object (shared bodies only).

## Perf fix 3 (2026-09-07) — RobTop-style draw batching + directional culling

- **LevelBatching (new)**: during play (including editor playtest of a live
  edited level), static GDObject placements nothing can drive individually
  (no GD group, no spin, no physics, no texture override) keep their node but
  hide their art and draw through shared DecorationBatches built from the
  placements' own data (GDObject.to_data + GDDecorationLoader.build_batches,
  which registers channel groups so colour triggers repaint batches). Batches
  are built once per play session at Level.start_level and persist across
  attempts (attempt resets re-hide placements use_data showed); teardown at
  playtest stop / level leave frees batches and restores every placement's art.
- **CullingManager**: batched placements are skipped (the batch self-culls);
  the visibility buffer is now asymmetric in scrolling levels - full buffer
  ahead of the camera where objects scroll in, only BEHIND_BUFFER_CELLS behind
  where they have already passed (platformer levels keep the symmetric
  buffer). Fewer objects stay live at once.
- Remaining candidate (not done): free per-node EditorSelectionCollider areas
  during editor playtest (kept now because editing needs them back on stop).

## Fix (2026-09-07) — community level list crash on large levels

The community list loader fully deserialized every `.bin` level (each a
tens-of-MB dictionary of ~100k+ objects) on worker threads just to show
title/creator/rating; a couple of large uploaded levels made it OOM-crash.
Every save/import now also writes a tiny `.meta` sidecar (JSON: name,
creator, description, rating, game_version, creation_date, flashing_lights)
via LevelOperationsHandler.write_level_and_meta; the list reads only the
sidecar (falling back to a full decode for old sidecar-less levels) and
level removal trashes the sidecar too.

## Fix (2026-09-07) — community list never decodes; chunked shared physics

- **Community list**: the list no longer decodes any level, ever. Sidecar-less
  files show a placeholder panel (name only, no version); sidecars are written
  opportunistically whenever a level is actually opened (GameScene.load_level,
  editor _load_level, community _edit_level) or imported/saved. Decoding a
  giant level to show a list row was killing Android (silent OOM force-close).
- **LevelPhysics chunking**: shared bodies are now one per (collision layer,
  horizontal CHUNK_CELLS=24 chunk) instead of one per layer spanning the whole
  level, so the physics broadphase only tests the chunks near the player.

## GD-model streaming of gameplay placements (2026-09-07) — "do it like GD"

Implements how Geometry Dash actually handles giant levels: keep every
object as resident *records*, instantiate real nodes only for a window
around the player, free what is left behind, and never duplicate the level.

- `LevelStream` (new): at play build (`Level.from_data(..., stream=true)`,
  which is the default when not in the editor) only decoration batches are
  built; non-decoration placements (blocks, spikes, orbs, pads, portals,
  triggers...) are indexed into horizontal 12-cell chunks and spawned around
  the player (3 chunks behind / 8 ahead), freed 12+ behind, respawned from
  records on every attempt. Each spawn uses the editor's own per-object
  instantiate+deserialize path, so collision, colour channels, attributes
  and components are identical. Physics (LevelPhysics.rebuild over the live
  window only) and CullingManager/LevelBatching are guarded to defer to the
  stream. Editor builds are unchanged (full tree).
- Restart (`GameScene.restart_level`) for streamed levels respawns the window
  from records instead of deserializing a snapshot over the whole tree -
  GD respawn semantics, and it also resets every one-shot object.
- Practice checkpoints no longer copy the level: `thin_practice_snapshot`
  stores only the respawn position + player state (velocity, replay tick,
  elapsed). The old full-snapshot path stays for editor playtests.

### Implementation notes (same pass)

- Chunk teardown frees nodes immediately (`free()`, not `queue_free()`): the
  physics rebuild for a window change runs in the same frame, and a node still
  pending deletion would have its geometry re-harvested into the shared bodies
  and linger as a ghost until the next chunk boundary. Immediate frees also
  release memory right away, which is the point of streaming on a phone.
- Gameplay chunks spawn through the exact full-build per-object pipeline
  (`Level.instantiate_object_from_data` + `deserialize_data_to_object(..., true)`)
  and are inserted before the layer's DecorationBatch children so decoration
  keeps drawing above gameplay, as in the full build.
- Colour correctness for late spawns: the level's ColorChannelWatchers run
  their one-shot `_ready` colour pass before any gameplay node exists, so every
  chunk spawn re-pushes the current channel colours
  (`LevelStream._refresh_new_node_colors`). Geometry caches
  (`DESCRIPTORS_META`) make repeated per-chunk physics rebuilds of
  already-merged objects cheap.
- `LevelPhysics.rebuild`'s first pass re-checks mergeability on every rebuild,
  so a move/rotate/scale trigger that enters the live window un-merges its
  group's objects before it animates them.
- CullingManager defers to the stream for streamed levels; LevelBatching is
  never prepared (nothing to batch: gameplay nodes draw their own gd art within
  the window). `restart_level` respawns the window via
  `Level.stream_restart_at`; physics is rebuilt on the following `start_level`
  (`LevelPhysics.prepare`), and mid-play window changes rebuild immediately.
- `GameScene.load_level` only builds from a practice snapshot when the snapshot
  is a full level (`has("layers")`); a thin snapshot there falls back to the
  resident cached data (mid-practice scene rebuilds otherwise cannot happen -
  every exit clears snapshots - but a crash on Android would be silent).

- Known scope limits (tracked for later): the Android *editor* (Godot's own
  APK) is a separate tool we cannot grant more heap and still builds full
  levels; grouped gameplay objects outside the live window are not
  transformed by far-away triggers (records keep their fields; GD moves
  records too - a later pass can apply trigger moves to records); toggled
  *decoration* batches persist their visual state across a streamed respawn.

## Why GD has no chunk-loading hitches, and the redesign that follows (2026-09-07)

Research findings on how Geometry Dash actually avoids spikes:

- **GD never creates objects mid-run.** All object instantiation happens once,
  when the level starts, behind a loading screen - RobTop added the loading
  bar in 2.2 specifically so heavy loads read as "loading, not lagging"
  (Geometry Dash Wiki, Update 2.2; Viprin, 2020). During play, zero nodes are
  created or freed.
- **GD's answer to scale is an object-count ceiling, not streaming.** The 2.2
  update removed the hard 40k/80k caps, but RobTop's own collaborators stated
  there are "no optimizations for large object amounts" - levels beyond the
  old limits are known to lag or crash even on desktop (e.g. Suga Song
  "completely unplayable until 2.11"). Levels over 80k get a warning icon.
- **Respawns don't rebuild anything.** Death starts a fixed ~1s respawn pause
  (hacks lower it; the game's own DeathAnimation is 1s at t=0/t=1) during
  which GD *resets* its existing objects in place. No allocation, no popping,
  no physics churn - which is why an "instant respawn" needs a mod.

Consequences for a windowed clone (can't keep 124k nodes resident on a phone):
the anti-hitch mechanics must be recreated explicitly, which is what this pass
does. Supersedes the "immediate free + full physics rebuild per window change"
approach of the earlier pass:

- **Per-frame work budget instead of mid-run bursts.** Chunks spawn on a
  node-count budget every frame (150/frame in play, far ahead of the player -
  8 chunks ≈ 12k px ≈ many seconds at 1x, so every slice is invisible). Only
  the chunk under the player is ever force-finished synchronously, and only
  when a drain fell behind (pathological density, same case where GD itself
  dies). Far-behind chunk teardown is likewise budgeted.
- **The 1-second death animation is the loading window.** The instant the
  player dies (`Player.dead`), LevelStream preloads the respawn window on a
  large budget (800 spawn / 900 free nodes per frame) while the death FX
  plays, tearing down the finished attempt's window farthest-from-camera
  first. By the time `restart_level` runs at t=1s the next window is already
  live, so attempts start without a hitch - GD hides its per-attempt reset in
  exactly the same pause.
- **Persistent shared bodies, incremental shapes.** `LevelPhysics.commit()`
  appends a finished chunk's shapes to the existing per-(layer,chunk) bodies;
  `LevelPhysics.release()` frees exactly the freed chunk's shapes. Bodies are
  never recreated at runtime, so there is no per-chunk allocation churn (the
  previous full-rebuild-per-crossing created/freed tens of thousands of
  CollisionShape2D per crossing on dense levels - GC/OOM pressure and hitch
  source on Android) and the player's contacts are never disturbed. Full
  rebuilds remain only for: a non-streamed level, a streamed level's first
  start, or when the dynamic trigger-group set changes (restores merged
  members of newly animated groups, then continues incrementally).
- `reset_to()` no longer frees-and-respawns the whole window synchronously:
  it guarantees the ground chunk under the respawn point, and everything else
  flows through the queues.
- Fixed a latent practice-respawn bug found while tracing restart:
  `prepare_external_data()` repositions the player at `level.start_position`
  on every `start_level`, so thin-snapshot checkpoints now also update
  `level.start_position` (as the legacy full-snapshot path did via use_data),
  and non-practice restarts restore the level's real start from cached data
  after practice had moved it.

Tuning knobs if device testing shows residual hitches: PLAY_SPAWN_BUDGET,
PRELOAD_*_BUDGET, CHUNK_CELLS, AHEAD_CHUNKS, FORCE_DISTANCE_CHUNKS in
src/LevelStream.gd.

Known scope limits (tracked for later): the Android *editor* (Godot's own
APK) is a separate tool we cannot grant more heap and still builds full
levels; grouped gameplay objects outside the live window are not transformed
by far-away triggers (records keep their fields; GD moves records too - a
later pass can apply trigger moves to records); toggled *decoration* batches
persist their visual state across a streamed respawn.

## Third pass (2026-09-07) — sliced everything + worker-thread scene loads

Device results after the second pass: Thinking Space II now opens and plays
(no OOM at open) but at sustained low FPS; a decoration-heavy level ("Orbit")
crashes; chunk-crossing lag spikes were unchanged. Code inspection found the
"budgeted" streamer still burst where it mattered, and the *resident data*
was never compacted GD-style. This pass fixes the bursts:

- **Whole-chunk bursts are gone everywhere.** Spawn, physics-shape commit and
  node teardown are each their own per-frame budgeted queue. A finished chunk
  no longer commits all its CollisionShape2D in one frame
  (LevelPhysics.commit is now called with 64-node slices per frame), and a
  freed chunk no longer rips all its shapes out at once (release happens per
  node right before that node frees, in slices).
- **Fair-share spawning.** The per-frame node budget is split across every
  pending chunk, so one dense chunk can no longer starve the rest of the
  window and complete far chunks stay many seconds ahead of the player.
  Only the chunk under the player is force-finished, as a correctness
  backstop.
- **Opening a level no longer builds its whole window.** `LevelStream.make`
  spawns only the start region (chunks start..start+2, START_SPAN_CHUNKS) at
  load; the rest of the window drains on the play budget once the attempt
  runs. The first `LevelPhysics.prepare()` (dirty by default) builds the
  shared physics from that small set. Full-rebuild bookkeeping:
  `prepare()` returns whether it rebuilt, and `Level.start_level` tells the
  streamer (`_mark_all_physics_committed`) so incremental commits never
  double-add shapes a rebuild already created.
- **Manual restarts tear down synchronously once** (a rare user action) so
  the new window is never blocked behind the slow free queue; death restarts
  keep the 1-second death-animation preload (budgeted teardown + rebuild).
- **Multithreading where Godot allows it**: Godot cannot create or free
  scene-tree nodes on worker threads (the engine is not thread-safe for the
  tree), so the instantiations themselves cannot move off the main thread -
  that is true of GD only because it is C++. What the engine *does* run on
  worker threads is resource loading: every gd scene a chunk will instantiate
  is handed to `ResourceLoader.load_threaded_request` the moment the chunk is
  queued (8 chunks ahead), and finished loads are drained into the cache a
  few per frame, so instantiation never blocks on disk or scene parsing.

Still open (honest status): resident per-object *data* is NOT yet compacted
GD-style - each record is still a full Dictionary (hundreds of bytes vs a
packed GD record of tens of bytes), so the "store ~10-50x less data" win the
project compared to a full node tree is only partly realised (nodes vs
records), not records vs packed arrays. That encoding is the next memory
phase for the levels that still crash at open (Orbit), along with finding out
where Orbit actually dies (open vs first start vs mid-play).

### Device feedback (2026-09-07, after the third pass) and where that leaves us

- "Orbit" crashes **while opening** -> the open-time memory peak (whole level
  decoded to Dictionaries + whole-level decoration batch build + start window)
  exceeds the device heap. Fix = the GD-style compact record encoding (packed
  records instead of per-object Dictionaries, ~5-15x), which is the confirmed
  next phase; a windowed (per-chunk) decoration batch build is the second
  lever if Orbit is decoration-heavy.
- Thinking Space II's low FPS is **constant across the whole level** (not
  worse in dense sections). DecorationBatch is viewport-bucket culled, so it
  is not redrawing the whole level every frame; the constant cost is being
  measured rather than guessed.
- Instrumentation: LevelStream.SHOW_STATS=true draws a top-left readout (FPS,
  live node count, stream drain ms/frame, spawn/commit/free queue depths, MB
  heap via Performance.MEMORY_STATIC). Numbers from that readout on TS2 (and
  a readout during Orbit's load, if it gets that far) will drive the tuning
  and tell us whether stream churn or something else owns the frame time.
