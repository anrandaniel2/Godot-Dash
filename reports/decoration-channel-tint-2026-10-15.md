# Decoration channel tint reuse — 2026-10-15

## Implemented

`NativeDecorationRenderer::apply_channel_color` previously obtained hue, saturation
and value from the same incoming RGB separately for every HSV-enabled record.
It now uses `DecorationChannelTint<Color>` to obtain those three values once, lazily
at the first enabled record, within that call only.

The neutral branch remains outside the helper. Empty/invalid selections and neutral
records never ask for decomposition. Each enabled record still performs its own
shift, hue wrap, saturation/value clamp and `Color::from_hsv`. Base alpha and the
existing exact dirty-value assignment remain in the caller in their original order.
There is no output-color cache, persistent state, allocation or invalidation protocol.
A direct item-color write is still overwritten by the next applicable channel update.

No changes to the sequential s/v/h algorithm in `NativeColorChannelIndex`, the
GDScript fallback, draw order, callback timing, physics, visual content, texture policy,
platform configuration or user-data layout.

## Measurements

Local Linux x86-64, Intel Xeon @ 2.60 GHz, GCC 12.2.0. Production helper and **actual
pinned godot-cpp Color implementation**, not a mock/reimplementation of Color math.
Pin: `6cceaf6a5f8b0d78ac5d71c139fd7fabba43b918`.

Final SCons harness uses `-O3 -flto` for the test and Color source. This gives the
compiler visibility into both the old and new color operations; it does not charge
only the baseline opaque SDK calls. The frozen old loop is directly inside its
benchmark loop, rather than an extra non-inlined reference call per record.

20,000 synthetic records × 240 changing-channel updates; five measured pairs after
one warm-up pair; alternating execution order; identical starting data; all-output
checksum comparisons. Fixtures and checksums are outside timing. The resulting dirty
flag is consumed each update. Cache construction and actual color assignments are
inside timing. Medians are milliseconds for all 240 updates:

| Non-neutral HSV records | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| 100% | 114.133 ms | 83.097 ms | 1.37× |
| 50% | 63.359 ms | 43.350 ms | 1.46× |
| 1% | 8.463 ms | 7.837 ms | 1.08× |
| 0% | 7.310 ms | 6.421 ms | 1.14× |

For the first two cases this is approximately 27% and 32% less scoped CPU time.
A second release-style run before the final SCons invocation measured 1.41×/1.49×
for the same cases. These are shared-host measurements, not confidence intervals.
The neutral-only difference cannot be attributed to saved HSV conversions (there
were none); source layout/compiler code generation can affect those timings.

Early non-LTO measurements showed much larger neutral/sparse differences; they are
not used as the performance headline. An earlier helper owning the neutral/alpha
branches showed a small sparse-case regression with LTO. The retained version leaves
those branches in the caller; the table is from that final structure.

**Scope:** synthetic recolor-loop CPU work only. Not full renderer submission, native
Variant-call overhead, real-level batch-size/distribution measurements, GPU time or
whole-game FPS. No 240 FPS, Android, Web or Windows-device gain is established.

## Verification actually run

- **4,800,003 checks, zero failures** in the new math/laziness/dirty-value suite;
  **4,800,027** including benchmark output checks.
  - Exact finite RGBA-bit comparisons against the frozen previous formula using
    the pinned SDK's Color on both sides.
  - 20,000 incoming colors × 24 record variations, black/white, negative/HDR RGB,
    signed zero/subnormals, mixed additive/multiplicative shifts, hue wrapping,
    clamping, neutral classification and varied alpha.
  - No decomposition at construction, exactly three getter reads for 100 shifted
    records within one context, and recomputation in a new context.
  - Identical assignments stay clean; direct external color edits are restored.
- AddressSanitizer + UndefinedBehaviorSanitizer passed with the test and actual
  Color source instrumented (`ASAN_ENABLED` is required by godot-cpp). The rest of
  the SDK support archive was not sanitizer-instrumented.
- **Full native Linux x86-64 release compilation passed**, both before integration
  and after this change, with the pinned SDK, API 4.7, speed optimization, `lto=none`.
  This compiles the complete current working-tree extension, including the previous
  spin optimization. It is compilation/link verification, not an engine run.
- New SDK-linked SCons harness built with warnings as errors on Linux and ran cleanly.
- Existing spin checks, **7,380,199** spin-cache checks, **8,411** visibility-cache
  checks and UI alignment checks passed again.
- Windows CI/staging and production-policy Python suites: **34 tests passed**.
  Mocked build tests now include invocation and fail-closed markers for the tint gate.
- Changed Python/SConstruct syntax checks and scoped whitespace checks passed.
- Updated renderer integration test parsed with gdtoolkit; Godot type checking and
  execution are still pending.

## CI and integration tests

`tools/benchmarks/channel_tint/SConstruct` is separate from the SDK-free renderer-cache
harness. It uses the already-built pinned release SDK. Windows matches static CRT,
optimization and LTO settings. `tools/windows_ci.py` builds/runs it and requires
`CHANNEL_TINT_TEST checks=... failed=0`; benchmark times are informational, not gates.
The revised Windows job has not run here.

`tools/renderer_cache_selftest.gd` now checks the actual native API for mixed modes,
base alpha, HDR/black/white channel changes, same-size reconfiguration, duplicate and
invalid indices, empty selections and a direct item-color write between channel calls.
These state checks run even without a valid canvas RID. No local Godot executable was
available; they remain unexecuted in-engine, not claimed as passing.

The source archive, SDK tree, generated headers, native library, test binaries and
build logs are cache/ignored outputs. No assets regenerated, no commit, no push.

## Files changed for this pass

- `native/src/decoration_channel_tint.h` (new), `native/src/gdash_native.cpp`
- `native/tests/test_decoration_channel_tint.cpp` (new)
- `tools/benchmarks/channel_tint/{SConstruct,.gdignore}` (new)
- `tools/windows_ci.py`, `tools/test_windows_export.py`
- `tools/renderer_cache_selftest.gd`
- `docs/agent-briefing/{06-native-extension,10-task-playbooks-and-reference}.md`
- This report

## Reproduce

With the pinned SDK installed at `native/godot-cpp` and SCons available:

```sh
(cd native && python3 -m SCons platform=linux target=template_release arch=x86_64 \
  api_version=4.7 lto=none -j4)
python3 -m SCons -f tools/benchmarks/channel_tint/SConstruct \
  output=/home/user/.cache/gdash-color/scons
/home/user/.cache/gdash-color/scons/channel-tint-test --benchmark

# Instrument the actual Color source as well as the test:
g++ -std=c++17 -O1 -g -DASAN_ENABLED -fsanitize=address,undefined \
  -fno-omit-frame-pointer -isystem native/godot-cpp/include \
  -isystem native/godot-cpp/gen/include -isystem native/godot-cpp/gdextension \
  native/tests/test_decoration_channel_tint.cpp native/godot-cpp/src/variant/color.cpp \
  native/godot-cpp/bin/libgodot-cpp.linux.template_release.x86_64.a -pthread \
  -o /home/user/.cache/gdash-color/tint-sanitize
/home/user/.cache/gdash-color/tint-sanitize

PYTHONPATH=tools python3 -m unittest tools.test_windows_export tools.test_production_build
```
