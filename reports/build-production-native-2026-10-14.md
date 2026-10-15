# Build efficiency, production audit and native monster clocks

Baseline code: d15e8de5. Scope: Windows/Android/Web shipping settings and build
redundancy; per-frame monster animation scheduling; restore packed-trigger eligibility.
No physics/replay/cutscene clock, renderer, texture/artwork, user-data-directory or
picking-order changes. No engine template/source changes (both hogdot cache keys retained).

## Baseline measurements (GitHub job step timestamps)

| Previous job | Wall time | Relevant steps |
| --- | ---: | --- |
| Windows 38660171800 | 285 s | native + standalone tests 30 s; import/tests/export/package 139 s |
| Web 38660171790 | 330 s | two native targets 48 s; import 41 s; export 38 s; browser smoke 106 s |
| Android 38660171706 | 613 s, FAILED | Linux native 62 s; ARM native 52 s; probe 240 s; replay 90 s; color 90 s |

The Android CPU tests completed but waited out their shutdown backstops under Xvfb.
Its final failure was the visual gate's real packed-trigger-schema assertion. That
failed run is not a baseline for a successful complete APK export.

## Build changes

- Remove the redundant Web debug native compile. Workspace-only, validated/idempotent
  descriptor staging maps all Web selectors to the one release wasm64 module. Linux
  hogdot editor import never used the Web debug binary. No renamed debug binary ships.
- Content/build-policy native cache keys plus restore prefixes allow new objects to be
  saved; save immediately after compilation, not only if the entire job succeeds.
- Remove Linux host clean before Android compilation (SCons tracks changed commands;
  godot-cpp objects have platform/target suffixes). Pin actual NDK to cache identity.
- Use available Linux cores for extension compiles (engine already did this).
- Extract only Android templates, and persist the downloaded template archive before
  tests even when downstream tests fail.
- Four Android CPU/script scenes run headlessly rather than Xvfb/GLES. Their assertions
  and completion gates stay; the script probe's runtime-error gate is strengthened.
  Visual smoke still runs under Xvfb. No sleeps/timeouts/checks shortened to fake a gain.
- Avoid recompressing ZIP/APK/installer payloads during Actions artifact upload.

## Production settings

All platforms already exported release engine templates. Native speed optimization,
trimmed godot-cpp bindings, hidden symbols, disabled C++ exceptions, no hot reload and
no deprecated bindings were already defaults; these are not invented new gains.

| Platform | Shipping configuration |
| --- | --- |
| Windows | Stock release engine, Forward+, x64 release extension, /O2, **explicit full LTO**, static CRT, no debug symbols/dev build |
| Android | Stock release engine, Mobile, arm64 release extension, -O3, **explicit ThinLTO**, stripped shipping .so; matching unstripped copy for crash decoding |
| Web | Existing production/speed hogdot template; wasm64/threaded/WebGPU-first + GLES fallback; speed/full-LTO release side module, no debug symbols/dev build |

MSVC and Android previously resolved godot-cpp's `lto=auto` to **none**. Explicit LTO
is a production candidate, not proof of runtime speedup; it can increase cold link
cost. No fast-math/changed floating-point semantics. Android's historical debug tag
and signing key do not mean debug code. All three retain compiled GDScript and shader
baking; tools/native source/docs/reports excluded. No speculative engine-module pruning.

Production checks run on all three; Windows exported EXE checks it is not a debug
build. Native SConstruct prints resolved settings. Size/timing conclusions need CI
artifacts rather than inferring them from flags.

## Native conversion

`NativeMonsterTimeline` batches the per-frame monster clock loop in C++, caching
clip metadata once per definition. It returns only changed frame indices for the
existing sprite-placement path. Public Monster clocks remain mirrored. Repeated
subtraction, remainder across next/default clips, frame-boundary placement, callback
order and GDScript fallback remain unchanged. Build/register/restart/Animate and
fallback switching invalidate the native snapshot. No additional processing node,
thread, or clock, and no removal of visible animation work.

Strict engine fixture compares against the frozen d15e8de scheduler: real clip tables,
zero/negative/large deltas, next/default/loop transitions, missing/empty clips, restart,
native/fallback switching, same-size reconfigure and sprite transforms. Benchmark:
2000 tracks × 240 ticks, warmup, median of three alternating-order trials, placement
included, configure excluded. No FPS claim; only levels with these animated objects
can benefit from this kernel.

## Packed-trigger correction

`extended_collision` was added to imported entries without updating PackedTriggers'
exact-key gate, so every such trigger fell back to dictionaries. The optional byte
column preserves absent/false/true separately, accepts older tables without the
column, and restores packing without losing fields. Unknown keys still refuse to
pack. Real-import, exact round-trip, legacy-table and non-mutation-on-rejection tests
extend the existing packed-trigger origin gate. Raw GD properties, native activation
semantics and collision logic are untouched.

## Verification at initial commit

- Linux optimized API 4.7 extension compile/link: PASS (new C++ translation unit).
- Production/staging Python tests: 5 PASS; Windows packaging Python tests: 12 PASS.
- GDScript syntax, Python compile, workflow YAML parsing and diff whitespace: PASS.
- No local Godot executable: runtime parity/benchmark and platform builds pending CI.
- No measured artifact-size reduction, full-level FPS, GPU/pixel, physical VSync or
  total-memory claim. Report actual CI timings before accepting the native kernel.

## First CI observations — 55e37b09

- Windows 38662859067 **SUCCESS**: new timeline **96,049/0**, packed-origin/schema
  **27/0**, color **11,527/0**, renderer **2,166/0**, presentation **54/0**;
  exported release check and install/upgrade/uninstall/data hashes passed.
- Timeline benchmark: legacy **1242.703 ms**, native **232.424 ms** for 2000 tracks ×
  240 updates, placement included: **81.3% less CPU time / 5.35× faster** in this
  synthetic workload. Both paths ran in the same process; no total FPS multiplier.
  Follow-up coverage preserves initial non-default clips instead of resetting them
  at tick zero. The production clock algorithm is unchanged in that follow-up.
- Web 38662859079 **SUCCESS**, **300 s vs 330 s** previous job (single samples,
  runner/cache variance applies). Native step **49 s vs 48 s**, so the first new-key
  run does not demonstrate faster compilation yet. Template cache was hit.
- Windows first full-LTO run took **369 s vs 285 s**; native/test step **62 s vs 30 s**.
  It also includes new tests and a cold set of LTO objects, on a different runner.
  No Windows build-time or LTO runtime-speed improvement claimed.
- Web ZIP **48,160,077 vs 48,152,409 bytes**; Windows ZIP **69,246,182 vs 69,201,891**;
  installer **64,316,471 vs 64,249,383**. Essentially flat/slightly larger, not a
  package-size win. Optimized release configuration is confirmed, not new size savings.
- Android Linux native **48 vs 62 s**, ARM native **28 vs 52 s**, template extraction
  **3 vs 12 s** in this run. These are observed steps, not a controlled LTO experiment.
  Its headless script probe still took **240 s**: the renderer change alone did NOT
  resolve the shutdown stall. Do not credit a seven-minute saving.
- Follow-up CPU-scene experiment allows a complete first frame/deferred startup work
  before requesting shutdown; assertions/error gates and shutdown remain enabled.
  Its effect is pending, not a diagnosed/fixed engine teardown bug.
- The Web browser smoke is **report-only and not clean**: this run logged failed
  pack/resource loads for `ToggleOn.svg.import`. Previous d15e8de smoke logged WebGPU
  device loss/buffer errors instead. Neither green workflow proves a working browser
  runtime; no browser fix claimed. Engine template and memory64 contract unchanged.
- Level probe again failed at download, before producing measurements. Android was
  still running at inspection and was superseded by the CPU-scene follow-up.
