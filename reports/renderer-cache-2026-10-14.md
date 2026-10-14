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
against the actual extension (live record state, redraw counters, cache invalidation).
Results are published as Actions annotations and included in the installer payload logs.

## Still unverified

Real-level frame-time/FPS and GPU savings, pixel parity, total process/editor memory,
and startup delay on Windows hardware. No local Godot binary is available: its GitHub
release download redirects to a host blocked by this sandbox. The C++ experiment
cannot establish those results. Multi-monitor Duplicate/Extend presentation likewise
needs physical displays; the display policy tests only establish transition handling.
