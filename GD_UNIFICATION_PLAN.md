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
- **M2 — Shared level body + Player per-shape death**:
  Level build pass harvesting `Collision` data into shared bodies; strip
  per-object bodies; `Player._handle_collision` per-shape disable; hazard merge;
  attempt-reset re-enable. Old scenes still drive gameplay art until M3.
- **M3 — Gameplay objects instantiate from gd scenes (static set)**:
  `GMDObjects`/`GMDConverter`/`Level.instantiate_object_from_data` switch to gd
  scenes for solids/slopes/hazards + fallback-block families; palette swap for
  those entries; delete `GDArtSwap` usage for them. Playtest/editor flows use
  the unified entry format (incl. `"gd_object_id"` on gameplay entries).
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
