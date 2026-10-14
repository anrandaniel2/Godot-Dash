# Decoration renderer cache — first level-performance pass

## Scope

The hot path in `NativeDecorationRenderer::rebuild_commands` previously traversed
visible column/row maps and deduplicated records on every dirty redraw, including
color, pulse and spin changes with an unchanged cell range. The replacement caches
only the ordered IDs; every redraw still reads the current record values.

No geometry/effects are hidden. Culling bounds, first-occurrence drawing order,
worker scheduling, animation clocks, 240 Hz physics, collisions, replay semantics,
user data, and editor picking remain unchanged. No engine template edits.

Exactly equal color/blend/transform assignments no longer mark draw commands dirty;
no epsilon is used and earlier dirty state is never cleared by a no-op.

## Local CPU experiment (Linux sandbox, g++ -O2)

Production header vs previous generation-stamp traversal; 20,000 synthetic records,
2,000 redraws, median of five, alternating timing order. Same checksum/order required.
Times exclude Godot draw submission and GPU work. They are not per-frame FPS measurements.

| Visible range changes | Old selector total | Cached selector total | Additional retained ID capacity |
|---|---:|---:|---:|
| Never during sample | 21.504 ms | 0.972 ms | 4,096 bytes |
| Every 60 redraws | 19.468 ms | 1.145 ms | 8,192 bytes |
| Every redraw | 29.847 ms | 23.607 ms | 8,192 bytes |

Both selectors retain 80,000 bytes of generation stamps in this fixture. Additional
ID storage depends on the largest selected set; it can be larger in a dense real level.
This pass is a CPU optimisation, not a total editor-memory reduction claim.

6,026 checks passed with the benchmark; 6,011 functional checks passed under
AddressSanitizer + UndefinedBehaviorSanitizer. Includes 2,000 randomized ranges
(each cold and repeated), independent ordered-output oracle, stamp wrap with uint8,
same-size rebuild invalidation, empty/negative/extreme ranges, live values on a cache
hit, and exact mutation/dirty-state semantics.

## Reproduction

```sh
g++ -std=c++17 -O2 -Wall -Wextra -Werror native/tests/test_decoration_visibility_cache.cpp -o /tmp/cache-test
/tmp/cache-test --benchmark
g++ -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer native/tests/test_decoration_visibility_cache.cpp -o /tmp/cache-asan
/tmp/cache-asan
```

Windows CI runs the same header benchmark plus `tools/renderer_cache_selftest.tscn`
against the actual extension (live record state and dirty flags on the headless backend).
Results are published as Actions annotations and included in the installer payload logs.

## Still unverified

Real-level frame-time/FPS and GPU savings, pixel parity, total process/editor memory,
and startup delay on Windows hardware. No local Godot binary is available: its GitHub
release download redirects to a host blocked by this sandbox. The C++ experiment
cannot establish those results. Multi-monitor Duplicate/Extend presentation likewise
needs physical displays; the display policy tests only establish transition handling.

## Windows compiler result and trade-off

The first Windows CI run (`38647742225`, commit `c367c75`) compiled the extension and
passed all 6,026 selector checks plus 1,655 runtime-policy checks. MSVC medians:

| Range changes | Previous | Cache | Extra retained IDs |
|---|---:|---:|---:|
| Fixed | 18.108 ms | 1.670 ms | 5,688 bytes |
| Every 60 redraws | 17.853 ms | 2.023 ms | 5,688 bytes |
| Every redraw | 23.397 ms | 24.697 ms | 5,688 bytes |

Thus the all-miss case regressed ~5.6% on MSVC (about 0.65 microseconds per synthetic
redraw), while fixed/occasional ranges improved ~10.8x/~8.8x. Do not extrapolate the
Linux cold-path improvement to Windows or report either microbenchmark as game FPS.

The initial integration fixture failed because root-window viewport changes during
startup invalidated selection between the test's snapshots. The follow-up run
`38649019464` exposed the individual failed assertions; all 2,006 new batch-lifecycle
checks passed, but five counter assertions still included that unrelated rebuild.
The first hypothesis (invalid headless Canvas RIDs) was incorrect: headless Godot
retains canvas commands through RenderingServerDefault, even without GPU output.

The fixture now uses a fixed-size isolated SubViewport and invokes the production
flush method synchronously for exact command/cache counters. A separate asynchronous
sequence checks native state/dirty flags and the real coordinator consuming them.
These are command-submission/state tests, never pixel/GPU proof.

## Empty per-batch callbacks

The previous real-level census (Amethyst, profile run `38483883384`) reported 2,296
DecorationBatch nodes processing each frame. This contradicted the intended
pre-tree `set_process(false)`: Godot 4.7.2 `Node::NOTIFICATION_READY` automatically
enables an overridden `_process` before calling the script's `_ready`.
Source: https://github.com/godotengine/godot/blob/4.7.2-stable/scene/main/node.cpp#L255-L280

DecorationBatch now reapplies the intended flag in `_ready`. Only built monster
batches keep their GDScript callback; native code still owns all rendering/culling
and spinning. Rebuilds and late monster registration preserve the callback when
needed. The obsolete GDScript spinning-item list was removed; the native hot set
is unchanged. There is no visibility toggle and no animation-clock substitution.

The integration fixture tests 2,000 adopted static nodes after ready, an item-built
static batch, native spinning, and a monster's original clip clock through an
in-tree rebuild. It also times 100 headless frames with 2,000 callbacks explicitly
restored (old behavior) versus disabled (new behavior), median of three with
alternating order and settling frames excluded. This is an isolated callback
wall-time test, not a real-level/GPU benchmark.

A fresh full-level profile dispatch was attempted but GitHub's app permissions
rejected workflow_dispatch (403). Push-triggered builds and Level probe still run;
no fresh full-level FPS number is claimed.

The next Windows attempt (`38649913848`) stopped before integration at an intermittent
Inter.ttc generated-import-cache/theme load error; the font source itself is tracked
and unchanged. Windows CI now permits one additional import pass only for an existing
importable source referenced as missing. The final parse-error gate stays strict. No
font, theme or other artwork is replaced to work around this bootstrap issue.
