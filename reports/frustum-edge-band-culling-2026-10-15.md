# Static frustum edge-band culling — 2026-10-15

## Target

Reduce repeated CPU work in the play-frame culling path without loosening bounds or changing
visibility. `FrustumCuller._process` calls native `NativeFrustumIndex.set_view()` each frame;
when the viewport moves, the previous implementation traversed every spatial section under
both the old and new horizontal views. Most objects in the overlapping interior cannot have
changed visibility during a small camera step.

## Change

For overlapping old/new views, native code now visits only the section bands swept by the
old-to-new left edge and old-to-new right edge. Any static interval whose exact visibility
can change must cross one of those boundaries, and its full span is indexed into those
sections. If views are disjoint (e.g. a teleport), it visits the full old and new view ranges
instead of walking the potentially enormous gap. First reconciliation still checks every
entry. Every candidate still uses the original exact world-space `right >= left && left <=
right` test; no epsilon, bounds or culling policy changed. Repeated section candidates are
still generation-deduplicated.

Separately, `NativeFrustumIndex::update_dynamic()` now keeps its desired-visibility byte
vector between frames, resizing it only during `configure_dynamic()`. This removes one
allocation/free per active dynamic-culling update. We intentionally retained the second fresh
`ObjectDB` lookup when applying visibility: `set_visible()` can synchronously emit callbacks,
so carrying raw node pointers across the visibility pass could become unsafe if a callback
frees another node. Link Visible reduction and visibility restoration logic are unchanged.

## CPU measurements

GCC C++17 `-O2 -Wall -Wextra -Werror`, Linux sandbox; standalone production range-selection
header. Fixture: 20,000 intervals distributed across world sections, view width 1,920 units,
2,000 camera updates moving 5 units each, section width 1,024 units; median of five measured
pairs after one warm-up pair, alternating order. Timings include section-map traversal,
per-update dedup marks and exact interval state updates; exclude Godot `ObjectDB`, nodes,
RenderingServer, physics and GPU.

| Selector | Median time | Unique entry visits over 2,000 updates |
|---|---:|---:|
| Full old+new visible section ranges | 0.908–0.917 ms | 291,192 |
| Swept edge bands (production helper) | 0.507–0.517 ms | 233,174 |
| Difference | **1.76–1.81× faster** | **19.9% fewer** |

Both paths produced the same final checksum; independent parity checks compare each object
visibility after each transition. This is a static-culler microbenchmark, **not a whole-game
FPS multiplier**. Its frame-time benefit depends on static object density, view movement and
how much of the section map intersects the old/new views. The dynamic scratch allocation
reduction is not included in this benchmark.

## Verification

- **108,010/0** SDK-free checks: 12,000 varied old/new viewport transitions (including
  overlapping, disjoint/teleport, reversed endpoints, negative coordinates, exact section
  boundaries, zero-width views, narrow and very wide object spans) against a full-state oracle.
- Benchmark parity checksum matched between old and new traversal on every measured trial.
- Added actual-native smoke coverage for grouped/moving object visibility and Link Visible:
  entry, exit, movement, and repeated-update behavior.
- SDK-free renderer-cache harness built under `-O2 -Wall -Wextra -Werror`; visibility,
  compact-index, spin, and UI-alignment suites all passed.
- Current Linux x86-64 release native extension compiled and linked against pinned godot-cpp
  (Godot API 4.7, `lto=none`).
- Windows orchestration/unit suite: **34 Python tests passed**; new culling benchmark target
  is wired as a strict Windows CPU gate with a success marker and CI notice.
- GDScript formatter/parser and Python compile passed.
- No Godot executable is available locally: native smoke scene, Windows execution, real-level
  frame time, GPU time and device FPS remain unverified.

## Changed files

- `native/src/frustum_transition_ranges.h` (new transition-range selector)
- `native/src/gdash_native.cpp` (edge-band traversal and reusable dynamic scratch)
- `native/tests/test_frustum_transition_ranges.cpp` (new parity and benchmark)
- `tools/benchmarks/renderer_cache/SConstruct`
- `tools/windows_ci.py`, `tools/test_windows_export.py`
- `tools/runtime_visual_smoke_test.gd` (dynamic/Link Visible correctness cases)
- `docs/agent-briefing/06-native-extension.md`
- `docs/agent-briefing/09-conventions-invariants-verification.md`
- This report

No commit or push. Existing unrelated dirty files were preserved.

## Reproduce

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror \
  native/tests/test_frustum_transition_ranges.cpp -o /tmp/frustum-transition-test
/tmp/frustum-transition-test --benchmark

PYTHONPATH=/path/to/scons python3 -m SCons -f tools/benchmarks/renderer_cache/SConstruct \
  output=/tmp/renderer-cache
/tmp/renderer-cache/frustum-transition-test --benchmark

(cd native && python3 -m SCons platform=linux target=template_release arch=x86_64 \
  api_version=4.7 lto=none -j4)
```
