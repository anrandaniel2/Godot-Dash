# Compact decoration spatial index — 2026-10-15

## Implemented

The renderer previously retained a nested ordered map and a separate growable ID
vector for every occupied spatial cell. After construction those contents are immutable.
`CompactDecorationSections` now retains sorted columns, contiguous row spans and exact-size
ID storage per column. Binary searches replace tree lookup on changing view ranges.

Construction still computes the same conservative circle/cell coverage in the same
ordered map. Compaction consumes one column at a time and frees that builder column
immediately. The previous compact index is released before reconfiguration builds its
replacement. No record is removed or reordered; duplicate per-cell references remain.

`DecorationVisibilityCache` keeps its existing generation stamps, first-occurrence
ordering, same-range fast path, invalidation and live-record emission. The original map
adapter remains for tests; the production renderer retains only compact storage.
Empty construction cells emit nothing and are omitted (production never creates an
empty cell). No culling-margin, animation, physics, picking, visual or platform change.

## Measurements

Local Linux x86-64, Intel Xeon @ 2.60 GHz, GCC 12.2.0, C++17, `-O3 -flto`.
All numbers below are synthetic index measurements, **not whole-game FPS or total
process/wasm/GPU memory**.

### Retained and peak requested allocation bytes

The test executable counts live/peak requested C++ allocation bytes, including map nodes
and vector capacity. It excludes its accounting prefixes, allocator metadata, fragmentation,
stack objects and RSS. The production allocator is unchanged. Empty builder destruction
is included before the retained sample (important for MSVC's map sentinel).

| 20,000-record fixture | Old retained | New retained | Reduction | Old construction peak | New construction peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary coverage: 3×3 cells each | 3,073,448 B | 1,867,200 B | 39.25% | 3,073,480 B | 3,098,168 B |
| Mixed: every tenth record covers 13×13 cells | 7,051,096 B | 4,532,064 B | 35.73% | 7,051,352 B | 7,076,032 B |
| Concentrated: all IDs in one cell | 262,296 B | 160,080 B | 38.97% | 393,368 B | 422,376 B |

The first two fixtures retain **1,206,248 B / 2,519,032 B less**, while construction
peaks increase by **24,688 B / 24,680 B** (0.80% / 0.35%). The concentrated fixture
increases peak by **29,008 B (7.37%)**; the old peak already includes vector growth.
These are fixture results, not a universal peak bound. A very large single column
still temporarily coexists with its replacement arrays.

An initial all-at-once flat-array candidate saved similar retained memory but raised
construction peaks to about 4.93 MB / 11.57 MB. It was replaced by the column-at-a-time
version before finishing production integration.

### Construction cost

Single local samples, with allocation accounting enabled; not medians or level-open times:

| Fixture | Existing map construction | Additional compaction, including column release |
| --- | ---: | ---: |
| Ordinary | 24.378 ms | 3.062 ms |
| Mixed | 50.757 ms | 4.600 ms |
| Concentrated | 0.095 ms | 0.010 ms |

Compaction adds work during construction; it does **not** improve these construction
times. Real-level pacing and Android open-time/peak-memory verification remain pending.
The additional pass creates no new per-frame budget/work-unit policy.

### Selection CPU

2,000 redraw/query iterations, 20,000 records, median of five measured pairs after
one warm-up pair; alternating order. Baseline is the frozen pre-compaction production
cache in `native/tests/reference/decoration_visibility_cache_before_compact.h`.
Checksums consume exact emitted ID order on every iteration. Construction is excluded.
Both old and new use the existing same-range selected-ID cache.

| Fixture | Range changes | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| Ordinary | Never | 0.851 ms | 0.829 ms | 1.03× |
| Ordinary | Every 60 iterations | 1.110 ms | 1.010 ms | 1.10× |
| Ordinary | Every iteration | 16.890 ms | 9.967 ms | 1.69× |
| Mixed | Never | 0.985 ms | 0.973 ms | 1.01× |
| Mixed | Every 60 iterations | 1.354 ms | 1.300 ms | 1.04× |
| Mixed | Every iteration | 26.245 ms | 19.822 ms | 1.32× |

Repeated runs showed the same changing-range improvement; warm-cache differences are
small/noisy, including a roughly 2% slowdown in one earlier mixed fixed-range run.
Do not claim an important warm-cache gain. Godot calls, draw submission, scene updates,
actual device cache behavior and GPU work are not included.

## Verification performed

- **15,052 correctness checks passed**, **15,094 with benchmark checks**. Independent
  set oracle verifies raw candidate order/duplicates, exact first-occurrence output,
  range existence, 3,000 varied queries, negative/extreme/reversed/empty ranges,
  repeated cache hits, uint8 generation wrap, 50 same-size/empty reconfigurations,
  builder destruction, live color data on cache hits, and clear/storage release.
- AddressSanitizer + UndefinedBehaviorSanitizer passed for the compact-index suite.
- Actual SDK-free SConstruct built all five executables with `-O2 -Wall -Wextra -Werror`.
- Existing visibility suite **8,411 checks**, spin-cache **7,380,199 checks**, parent-space
  spin suite and UI alignment suite passed.
- SDK-linked channel tint suite rebuilt against the shared header and passed
  **4,800,003 checks**.
- Full current native Linux x86-64 release extension compiled/linked successfully with
  pinned godot-cpp, API 4.7, speed optimization, `lto=none`.
- Windows staging/CI and production-policy Python suites: **34 tests passed**.
- Python/SConstruct syntax, scoped whitespace, and GDScript syntax checks passed.
  New GDScript test block is formatter-idempotent.

## CI and pending checks

Windows CI now builds/runs `compact-sections-test --benchmark`, requires its success
marker and prints memory/query measurements. Mocked orchestration tests check invocation
and failure on a missing marker. No timing threshold gates the build. Windows execution
has **not** run locally.

The existing real-native renderer scene adds synchronous tests for horizontal/vertical
filtering, empty columns, same-size spatial reconfiguration and color-only cache reuse.
No Godot executable is available locally, so these new cases remain unexecuted in-engine.
Full compilation is not runtime, pixel, browser, Android or physical-monitor proof.
The editor M1 gate is untouched; production picking order was not changed.

## Changed files

- `native/src/decoration_sections.h` (new compact index and map adapter)
- `native/src/decoration_visibility_cache.h` (representation-independent traversal)
- `native/src/gdash_native.cpp` (compact storage, construction and range-existence wiring)
- `native/tests/test_decoration_sections.cpp` (new)
- `native/tests/reference/decoration_visibility_cache_before_compact.h` (frozen baseline)
- `tools/benchmarks/renderer_cache/SConstruct`
- `tools/windows_ci.py`, `tools/test_windows_export.py`
- `tools/renderer_cache_selftest.gd`
- `docs/agent-briefing/{06-native-extension,09-conventions-invariants-verification}.md`
- This report

All generated binaries/build dependencies remain ignored or under `/home/user/.cache`.
No commit or push performed; unrelated working-tree changes preserved.

## Reproduce

```sh
mkdir -p /home/user/.cache/gdash-sections
python3 -m SCons -f tools/benchmarks/renderer_cache/SConstruct \
  output=/home/user/.cache/gdash-sections/scons
/home/user/.cache/gdash-sections/scons/compact-sections-test --benchmark

g++ -std=c++17 -O3 -flto -Wall -Wextra -Werror \
  native/tests/test_decoration_sections.cpp -o /home/user/.cache/gdash-sections/sections-test
/home/user/.cache/gdash-sections/sections-test --benchmark

g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  native/tests/test_decoration_sections.cpp -o /home/user/.cache/gdash-sections/sections-sanitize
/home/user/.cache/gdash-sections/sections-sanitize

(cd native && python3 -m SCons platform=linux target=template_release arch=x86_64 \
  api_version=4.7 lto=none -j4)
PYTHONPATH=tools python3 -m unittest tools.test_windows_export tools.test_production_build
```
