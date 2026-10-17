# Idle per-frame work reduction — 2026-10-16

## Profile evidence

GitHub Actions runtime profile run `38655927478`, check run `116165554893`, published the following Amethyst real-level observations on the software-Vulkan runner:

- 851 nodes had `_process` enabled; 308 were `PulseWhite`, 254 `MusicScale`, and 192 `TextureRotationPinComponent` (754 combined).
- Median `process_ms` was 182.32 ms; median `physics_ms` was 4.36 ms.
- Median software-renderer GPU time was 158.7 ms at baseline. Hiding decoration reduced that to 67.0 ms (91.7 ms / 58% in this runner). This is a runner-specific toggle, not evidence of physical-GPU or device FPS gain.

This baseline identifies redundant per-frame work but does not establish an end-to-end speedup, compare Godot with GD, or represent current uncommitted workspace changes.

## Changes

- `PulseWhite` now disables `_process` while its pulse factor is idle/finished and re-enables it when an interaction starts a pulse. The existing decay and shader updates remain unchanged while active. The headless presentation self-test now checks idle disable, active re-enable, completion disable, and a subsequent pulse.
- `TextureRotationPinComponent` stops polling when its pinned CanvasItem is not visible in the tree and refreshes its transform when shown. While visible, it only queues deferred global rotation/scale/skew writes when the exact requested value differs.
- `MusicScale` skips unchanged scale setters and disables processing while its `disabled` flag is true. The out-of-range fast return is unchanged.
- `TargetLink.gd` (26 enabled nodes in the baseline) stops processing while locally hidden, clears cached points at the visibility transition, and resumes when shown.
- `GravityTextureFlip.gd` (15) now subscribes to `Player.gravity_flip_changed`; direct property assignments are observed by the setter, replacing its per-frame poll.
- `VariableFillColor.gd` (10) caches its sibling references and skips redundant `modulate` writes, while retaining its process cadence because runtime colors can also arrive through the native channel path.
- Hidden/inactive callbacks are gated in `HitboxDisplay`, `ToggleTriggerSprite`, `GameplayRotateTriggerSprite`, `GameplayRotateTriggerIndicator`, `ReplayPanelLoader`, `PercentageLayer`, and `SpawnTriggerComponent`. `SpawnTriggerComponent` polls only while its spawn timer is active.
- `TextureRotateComponent` stops processing at a zero rotation rate; nonzero rotations remain continuous. `GameScene` only processes after imported ground/middleground art exists.

The self-test covers pulse, hidden target links, gravity texture flips, variable-fill synchronization, zero-rate spinning, hidden texture pins, and hidden percentage-HUD processing. No frame-time benefit is claimed until the profile is rerun.

## Verification status

- `gdparse` passed on all 17 changed GDScript files, including the self-test.
- `gdformat --check` passed on nine focused component scripts; larger pre-existing files were parsed and diff-checked without whole-file reformatting.
- `git diff --check` passed for the scoped changes.
- Godot runtime self-test and a same-run before/after profile have not been run in this environment; no Godot executable is installed locally. Two attempts to dispatch `level-runtime-profile.yml` against `arena/ce99f0ac-godot-dash` were rejected with HTTP 403 `Resource not accessible by integration`. Rerunning the latest available profile (`38655927478`) was also refused because its workflow file may be broken. The latest profile remains run `38655927478` on `fc4fab6a1a1ed763a4d17512da59858f2bfaa28b`, before these uncommitted changes. Keep the measured speedup unverified until Actions dispatch permission and a runnable workflow are available.
