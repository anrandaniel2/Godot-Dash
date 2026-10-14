# Gameplay and presentation corrections — 2026-10-14

## Changes and evidence

- **Installed version:** UpdateChecker retains `UpdateManager.display_version()` in
  every status. Windows displays project version, CI build number and short build SHA
  from the existing export metadata. Available updates remain clickable; status/error
  details use the tooltip. Existing bottom-left title/pause layout is unchanged.
- **Display regression mitigation:** disconnect Config's experimental display watcher
  and remove forced VSync reapplication. Saved VSync/FPS settings and explicit changes
  remain; Godot handles display/swapchain changes. No automatic renderer selection,
  monitor-derived cap or Windows display-topology changes. The reported wavy distortion
  has **not** been reproduced or verified fixed on physical hardware.
- **Normal death:** delete the default-on freeze branch, red marker class, stack logging
  and probe freeze override. Existing sprite/particles/SFX and the one-second animation
  restart callback now run normally. Default sprite effect is shorter than that track;
  practice checkpoints and editor restart branches are unchanged.
- **Hide/Show Player:** native effects now call Level -> GDLevelOptions, sharing both-slot
  state with Options. Append component-twin enum entries (no old enum renumbering), map
  both imported IDs, and initialize late-created duals from the same state. Hidden
  players do not emit visible ghost siblings; existing ghosts hide immediately.
  GameScene's existing reset restores visibility. No collision/physics changes.
- **End wall:** synthetic GD end entries lacked `EndLevelComponent.gd_import`, so the
  component selected authored BOTH-axis camera easing. Set the flag and recognize old
  saved converter end nodes narrowly by exact layer/name/self-target path. Imported
  ends use the existing X-only path; authored end behavior stays unchanged.
- **UI cutscenes:** Relative alignment previously did nothing with Center/Default;
  it now overrides every reference on the expanded axis. Move the shared production
  math to `native/src/ui_alignment.h`; tests no longer duplicate the implementation.
  Batch origins are not object origins: align each retained record's **object pivot**,
  preserving composite sprite offsets, scale, spin and monster record updates. UI-only
  offsets leave original records untouched. UI batches bypass the now-invalid world
  spatial index (the previous `_cull` property write no longer controlled the retained
  renderer). Other batches retain existing culling. Viewport resize recomputes layout
  while preserving live transforms; restart restores parent/pose and world culling.

Semantics reference: [GD UI trigger documentation](https://github.com/UHDanke/gd_docs/blob/main/docs/triggers/visual/ui.md)
and [Show/Hide Player](https://github.com/UHDanke/gd_docs/blob/main/docs/triggers/player/show_hide_player.md).

## Verification

Local:
- Pinned godot-cpp 6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918, API 4.7:
  Linux release extension compilation/link **PASS** (generated binaries ignored).
- Production UI alignment math: **PASS**, including Relative with every reference,
  3:2, 16:9, wider landscape and taller viewports.
- Decoration selector regression: **6,011 checks, zero failures** (without benchmarks).
- Python Windows staging/installer/config tests: **12 PASS**.
- Changed GDScript files: gdparse **PASS**; syntax checking is not engine execution.
- `git diff --check`: **PASS**.

Added Windows headless gate `tools/gameplay_presentation_selftest.tscn` checks actual
native/component visibility, version statuses, death effects/restart track, synthetic +
legacy + authored end/static easing, and native UI reparenting/draw transforms across
1920/2560 widths, resize with live move/scale, multi-part spin and restoration. It uses
production code, not a replacement gameplay model. CI must report its completion marker
and no script errors before packaging. Integration execution is pending at this report's
initial commit; a passing local parser is not reported as a passing headless run.

## Limits and preserved invariants

There is no downloaded/validated full Amethyst run here. These are concrete UI-path fixes
and synthetic edge-coverage checks, **not** full-cutscene/pixel parity proof. Broader UI
features such as group-parent alignment/ambiguous guide semantics are not newly implemented.
Physical multi-monitor/VRR/VSync behavior and browser GPU runtime remain unverified.
No whole-level FPS gain is claimed. UI batching remains intact; no artwork is hidden or
uniformly stretched as a workaround. No cutscene timing changes.

Windows remains Forward+; Web remains wasm64, threads, WebGPU-first/mobile with shell
WebGL2 fallback. No engine template edits/cache-key bump required. App identity, installer
identity, user data directory, replay version/ticks, 240 Hz physics and player mask 122
remain unchanged. M1 picking-order gate is still blocked on real-level zero mismatches.
