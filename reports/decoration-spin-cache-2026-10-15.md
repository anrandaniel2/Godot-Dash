# Decoration spin coefficient reuse — 2026-10-15

## Change and boundaries

The native decoration animation loop previously calculated sine and cosine for every
spinning sprite. Consecutive parts of a composite object can share exactly the same
float spin rate. They now reuse those coefficients, **not their transforms**.

- `native/src/decoration_spin.h`: separates the original parent-space formula from
  coefficient calculation; adds an exact-bit, one-entry coefficient cache and a run profile.
- `NativeDecorationRenderer::index_records`: profiles the ordered spinning subset once.
  Selects reuse only if at least half its records repeat the preceding speed.
- `advance_animation`: selects one of two compiled loops once per call. Low-reuse
  batches use the uncached formula without per-record cache probes. Cache lifetime is
  one animation call, so changing delta cannot leave stale coefficients.
- Both configuration entry paths rebuild the profile. Spin speeds/order are immutable
  between configurations; any future rate-mutation API must refresh the profile.
- Each record still reads its current transform and pivot. Operation order, float
  storage conversions, mirrored/scaled/skewed bases, origin orbits, nonpositive-delta
  guard, record order and dirty flag semantics are preserved.
- No additional per-record persistent allocation, pose cache, sorting, approximate
  trigonometry, skipped animation, culling change or new processing callback.
- GDScript animation, physics, replay, cutscenes, textures and platform contracts unchanged.

### Candidate rejected before finishing

Unconditionally probing the cache was promising at `-O2`, but `-O3 -flto` exposed
approximately 7–8% higher time for alternating/unique rates. That unconditional
implementation was not retained. The configuration-time profile and separate uncached
loop avoid those per-record probes for low-reuse data. They do not guarantee zero
end-to-end overhead on every compiler/device; results below include bypass cases.

## Correctness and build checks actually run

Linux x86-64 sandbox, Intel Xeon @ 2.60 GHz, GCC 12.2.0 (Debian).

- `test_decoration_spin_cache.cpp`: **7,380,199 checks, zero failures** without timing;
  **7,380,235 checks, zero failures** with all benchmark checksum checks.
  - Independent pre-change formula, not a call through the refactored helper.
  - Finite transform components compared bit-for-bit within each build. NaN results
    compared by NaN classification, not payload identity.
  - Signed zero, adjacent representable rates, subnormal/maximum rates, infinities/NaN;
    repeated and mixed rates; changing deltas; mirrors/skew/pivots; external pose resets.
  - 1,024 records over 600 incremental frames for both float-round-trip and double
    storage; each frame alternates repeated-speed and mixed-speed input patterns.
  - Profile empty/single/equal-pair/alternating/runs/signed-zero/near-equal cases.
- Same standalone parity suite passed AddressSanitizer + UndefinedBehaviorSanitizer.
- Existing parent-space decoration spin tests passed.
- Existing decoration visibility cache suite: **8,411 checks, zero failures**.
- Existing UI alignment suite passed.
- All four standalone executables built successfully through the actual renderer-cache
  SConstruct using SCons 4.10.1, C++17, `-O2 -Wall -Wextra -Werror`.
- Windows staging/CI orchestration Python suite: **14 tests passed**. New mocked checks
  verify both spin executables are invoked and missing success markers fail the build.
- Production configuration/import-policy Python suite: **20 tests passed**.
- Changed Python files and SConstruct compiled as Python. Updated renderer selftest
  parsed with gdtoolkit; this is syntax validation, **not Godot type/runtime validation**.

## Synthetic CPU benchmark

`test_decoration_spin_cache --benchmark`: 20,000 synthetic records × 240 frames,
changing delta, float-round-trip storage, five measured trials after one warm-up pair.
Execution order alternates; each pair starts from identical fixture data and checks
full-output checksums. Reported times are medians, in milliseconds for all 240 frames.
Fixture construction, profile building and checksum calculation are outside timing.
This uses the production coefficient/cache/profile helpers but a simulated record
layout and direct vector iteration—not Godot's indexed records or complete renderer.

Latest complete local runs:

| Speed pattern | O2 before ms | O2 after ms | Speedup | O3+LTO before ms | O3+LTO after ms | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| All equal | 83.330 | 30.162 | 2.76× | 71.898 | 29.827 | 2.41× |
| Equal runs of four | 77.352 | 47.203 | 1.64× | 72.716 | 46.749 | 1.56× |
| Equal pairs (50% hits) | 78.954 | 59.847 | 1.32× | 72.537 | 57.982 | 1.25× |
| Sparse repeats (25%; bypass) | 110.013 | 110.757 | 0.99× | 106.882 | 106.259 | 1.01× |
| Alternating (bypass) | 78.646 | 80.111 | 0.98× | 72.607 | 75.484 | 0.96× |
| Unique (bypass) | 80.575 | 81.575 | 0.99× | 74.363 | 76.043 | 0.98× |

The repeated-speed cases show a useful reduction in this narrowly scoped CPU work.
The bypass cases range from approximately 0.6% faster to 4% slower in the O3+LTO run;
these are small but not zero differences, despite retaining the uncached inner math.
Shared-host noise/compiler layout and the outer dispatch are not isolated here.
No claim of a speedup for low-reuse batches. Earlier runs varied; these are not
cross-device confidence intervals or a guaranteed performance floor.

**Not measured:** full-level FPS/frame time, real-level hit distributions, GPU time,
physical-monitor presentation, native extension end-to-end performance, configuration
cost or Android/Web/Windows performance. This does not demonstrate 240 FPS.

## CI and remaining validation

`tools/benchmarks/renderer_cache/SConstruct` now builds the original spin regression
suite plus the new cache suite. `tools/windows_ci.py` runs both, fails on missing
success markers and prints the benchmark results. No timing threshold gates a build.
This wiring was checked locally; the revised Windows job has **not** run.

`tools/renderer_cache_selftest.gd` adds actual-native coverage for same-size
reconfiguration between cached/uncached/static/pair-run inputs, different pivots,
mirrored/skewed transforms, zero/negative/changing deltas, and direct transform writes
between calls. Existing packed `DecorationBatch` spin coverage remains.

No local Godot executable or full godot-cpp build was available. The new in-engine
checks and full native extension compilation remain pending, along with device and
real-level measurements. No commit or push was performed.

## Reproduce standalone checks

Place generated files outside source control (example output directory below):

```sh
mkdir -p /home/user/.cache/gdash-spin
python3 -m SCons -f tools/benchmarks/renderer_cache/SConstruct \
  output=/home/user/.cache/gdash-spin/scons
/home/user/.cache/gdash-spin/scons/spin-test
/home/user/.cache/gdash-spin/scons/spin-cache-test --benchmark
/home/user/.cache/gdash-spin/scons/visibility-test
/home/user/.cache/gdash-spin/scons/ui-alignment-test

g++ -std=c++17 -O3 -flto -Wall -Wextra -Werror \
  native/tests/test_decoration_spin_cache.cpp \
  -o /home/user/.cache/gdash-spin/spin-cache-lto
/home/user/.cache/gdash-spin/spin-cache-lto --benchmark

g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  native/tests/test_decoration_spin_cache.cpp \
  -o /home/user/.cache/gdash-spin/spin-cache-sanitize
/home/user/.cache/gdash-spin/spin-cache-sanitize

PYTHONPATH=tools python3 -m unittest tools.test_windows_export tools.test_production_build
```
