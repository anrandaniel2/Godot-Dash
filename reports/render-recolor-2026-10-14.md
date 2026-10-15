# Render/recolor CPU pass — 2026-10-14

Baseline: f9f76fb2 (Windows Build 15). No detail, culling bounds, physics, replay,
cutscene clocks, saved data, renderer settings or picking-order changes.

## Shipped candidate changes

1. **Coalesce completed culling with animation/color command emission.** Previously
   the coordinator advanced spin/flushed dirty canvases, then a completed worker
   result could clear and rebuild those same commands again for a different range.
   A worker result now updates the range/visibility and marks dirty. The coordinator
   consumes completed results first, then advances the same animation delta and
   flushes once. Unfinished jobs never block animation. Teardown still drains and
   flushes before releasing workers/renderers. Direct synchronous range updates retain
   their existing behavior. No candidate records are dropped or reordered.
2. **Channel-wide work outside per-object loops.** NativeColorChannelIndex applies
   the common channel S/V/H round trips once, not once per watcher. The portable
   ColorChannelWatcher also resolves copy color/opacity once and assigns the final
   watcher modulate once instead of sending three intermediate CanvasItem writes.
   Per-object HSV, intensity/alpha, editor highlights and copy-cycle budget remain.
3. **Classify immutable native HSV snapshots once.** Configure/index build records
   the exact previous neutral-HSV predicate. Native channel and decoration recolors
   no longer re-evaluate it per object per pulse. No epsilon, HSV reassociation,
   color cache across changing channels, or stale snapshot across reconfigure.
   GDScript continues to read live object fields as before.
4. **Unblock the Android script probe correctly.** The collector honors `.gdignore`
   boundaries around standalone benchmark projects with different `res://` roots.
   Ordinary runtime/test scripts and strict parse/error checks are not skipped.
   This addresses the Build 15 probe failure, not a claim that Android export passed.

## Rejected experiments (not in production)

- Adaptive visibility-cache admission used stamp-only traversal after repeated misses.
  Linux sample: 32.9903 ms vs the Build 15 eager cache's 26.3229 ms per 2000 cold
  redraws. Rejected, despite lower cache-write traffic.
- Sorted flat column/row arrays initially looked faster, but rotating benchmark order
  and repeated runs exposed regressions (e.g. 33.1021 vs 27.7306 ms cold).
- A fully contiguous reference buffer reduced fixture reference capacity from 5,657,528
  to 4,000,000 bytes and removed 21,620 tree nodes, but added roughly 5 ms freeze work
  and did not consistently improve CPU across workloads/build layouts. Not shipped.
- The production visibility-cache/index algorithm remains unchanged, including its
  known all-miss trade-off. Existing `DECORATION_CACHE_BENCH` output compares that cache
  to the older stamp traversal; it is **not** a before/after metric for this pass.

No extra data files, new runtime settings, serialized-field changes or engine template
edits. Web stays wasm64/threads/WebGPU-first/mobile with WebGL2 shell fallback. Windows
stays Forward+. Native outputs and godot-cpp are ignored, not committed.

## Verification

Local:
- Pinned godot-cpp/API 4.7 Linux optimized extension build/link: PASS.
- Production cache + neutral predicate: 8,411 checks, zero failures; 8,426 with the
  unchanged selector benchmark. AddressSanitizer + UndefinedBehaviorSanitizer: PASS.
- UI alignment tests: PASS.
- Windows packaging/configuration Python tests: 12 PASS.
- Changed GDScript syntax (gdparse), Python compile, whitespace checks: PASS.
- No local Godot executable; no local engine/GPU run claimed.

Windows headless gates added/extended:
- Real coordinator: simultaneous range changes, native spin and group pulses, at most
  one command rebuild per frame, exercised range changes and retained visible records.
- Retained renderer: neutral/non-neutral HSV and same-size reconfiguration.
- Real HSVWatcher/ColorChannelWatcher/native index: portable result bit-exact against
  the frozen Build 15 refresh loop, native approximate parity reflecting its existing
  float grouping, mirrored base values, HDR/copy chains/cycles/opacity, highlights,
  object reconfiguration and empty channels.
- Synchronous benchmark: 2000 watchers, 60 updates, three trials with rotated order,
  separate legacy portable/current portable/current native timings. Native timing is
  current-only: a speedup versus GDScript is not a new native before/after gain.
- Script-probe boundary checks prove ignored standalone projects are excluded and
  ordinary runtime/reference scripts remain discoverable.
- Existing 54 presentation checks and installer/user-data gates remain mandatory.

CI execution/timings are pending at the initial commit of this report. These tests
measure CPU operations/state, not whole-level FPS, physical VSync, pixel/GPU equivalence,
full Amethyst performance or total application memory. M1's real-level zero-mismatch
picking gate is unchanged; M2/M3 still need their real-level/editor measurements.
