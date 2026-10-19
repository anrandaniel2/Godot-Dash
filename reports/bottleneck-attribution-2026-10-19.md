# Bottleneck attribution — 2026-10-19

The question: on Android, what is actually the bottleneck? This document separates what the
repository can prove from what only a device run can prove, corrects a measurement error the
earlier reports were built on, and adds the instrumentation that answers the question in one
5-second log line.

---

## 0. Short answer

**Not determinable from anything in this repository, and one of the numbers that looked like the
answer is not what everyone assumed it was.** §1 shows the recorded `process_ms` is the *worst
single frame in the preceding ~1 second*, not a per-frame mean, so the "182 ms of process work per
frame" figure that earlier analysis leaned on is an artifact of a level load or a script compile,
not the cost of a playing frame. Fixing that mistake is the most useful thing in this document,
because every ranking of "CPU vs GPU" so far inherited it.

The evidence that does exist points at **fill rate / presentation**, not script CPU, and §3 ranks
the candidates with the measurement that would confirm or kill each one. §4 ships the measurement.

---

## 1. Correction: what `process_ms` in `frames.csv` actually measures

`src/debug/PerformanceCapture.gd:69` records
`Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0`. In Godot 4.4
(`main/main.cpp:4417` and `:4547-4563` — line numbers from 4.4-stable):

```cpp
frame += ticks_elapsed;                 // accumulates microseconds of frame time
...
if (frame > 1000000) {                  // i.e. every ~1 second of wall-clock frames
    ...
    performance->set_process_time(USEC_TO_SEC(process_max));
    process_max = 0;
    frame %= 1000000;
}
```

`process_ticks` itself is measured from `process_begin` to **after `RenderingServer::draw()`**
(`main.cpp:4502` → `:4530`), and `process_max` is a `MAX()` over that window. So
`Performance.TIME_PROCESS` is *the slowest frame's process-plus-draw time during the last ~1 s*,
and it includes the `RenderingServer::sync()` / `draw()` submission path.

Verified empirically against the captures in this repository:

| Capture | Mean FPS | Median plateau length of `process_ms` | = wall time | First plateau |
| --- | --- | --- | --- | --- |
| `…071452` | 143.8 | **144 rows** | **exactly 1.00 s** | 168.171 |
| `…200114` | 143.8 | **144 rows** | **exactly 1.00 s** | 17.383 |
| `…200354` | 39.3 | 26 rows | ~1 s | 42.027 |

Each plateau is one reporting window; the value is the window's worst frame. In `…071452` the
first window contains the level build and reports 168.171 ms, then drops to 7.6 ms for the rest of
the run. A per-frame *mean* cannot fall by 22× in one frame boundary and cannot sit in 13–64
distinct values across 1,800 frames. This also explains why `frame_wall_ms` and `process_ms` are
uncorrelated in every clean run (r = −0.02 to −0.01): they measure different things.

Consequences:

- `reports/idle-render-work-2026-10-16.md` cites "median `process_ms` 182.32" as evidence of
  per-frame GDScript cost. That number is a per-second *maximum* from a run whose first window
  contained level loading. It says nothing about steady-state per-frame script cost, and the
  "821 idle `_process` nodes" it motivated cannot be sized from it.
- Any future capture on Android must not use `process_ms` for attribution. `frame_wall_ms` is
  sound (measured as the interval between two `_process` calls), and so is
  `viewport_get_measured_render_time_cpu/gpu` — those are per-frame means over the
  `rendering/server/rendering_info` window, not maxima.

---

## 2. What the four desktop captures establish

All four are the same machine (Intel Arc B580, Vulkan 1.4, Forward+, 144 Hz), same level
(Amethyst, 36,315 nodes), same build. They are **not** device data: there is no Android capture,
no logcat, no `simpleperf`/`perfetto`, no thermal log anywhere in the repository.

Established:

1. **A 144 Hz display-lock.** `…071452` mean 6.96 ms against a 6.944 ms period; 94.9% of frames
   fall within 0.6 ms of a 144 Hz multiple, and `frame_wall_ms` does not correlate with render CPU
   (r = −0.03). Frames finish early and wait for presentation. **Any desktop capture taken this
   way cannot rank CPU vs GPU** — both have slack.
2. **The decoration submission path dominates when it is allowed to.** `…200114` (culling on:
   95–147 draw calls, 2,296 canvases) ran at 7.01 ms against `…200354` (culling off: 2,236–4,748
   draw calls) at 35.25 ms — same scene, same GPU, same build. The added ~2,200 GPU draw calls
   cost ~28 ms of frame time. That is the only real sensitivity measurement in the repository,
   and it says the cost scales with *draw calls actually issued*, i.e. with how badly batching
   degrades, not with the number of records (~242,036 in both runs).
3. **Batching is not the shipped path's problem.** The culled run merges ~6,600 submitted records
   into 62 draw calls (`RENDERDIAG draws=…` in `…071452`: 2,143–13,232 submitted → 41–76 draws,
   a 100:1 merge ratio). The unculled run only reaches 6 records per draw.
4. Nothing about Android. Zero frames in this repository were rendered on a phone.

---

## 3. Candidate bottlenecks, ranked, each with its falsifier

Ranked by what the evidence implies — not asserted as fact. Every entry states the mechanism, the
prediction it makes, and the measurement that kills it.

### Candidates

**C1 — GPU fill rate / bandwidth (glow + HDR canvas + overdraw at native resolution).**
`project.godot:471` `hdr_2d=true`, `scenes/GameScene.tscn:84` `glow_enabled=true`, background and
ground sprites at `scale = 2`/`2.5` (`GameScene.tscn:96-123`, `:158`, `:195`) stacked under the
play area. Mechanism: on a TBDR phone every one of those layers is a full-screen alpha blend into
an RGBA16F target, then glow's downsample/blur/upsample chain flushes tiles to DRAM. The same
pixels cost an Arc B580 ~1.6 ms of GPU time; a phone GPU has roughly a tenth of the bandwidth and
must also hold the frame in tile memory it cannot keep while glow is on.
*Predicts:* `frame_ms` well above the CPU phase sum; `render_gpu_ms` scaling with resolution and
with glow on/off; frame time improving markedly at a 30 FPS cap (fewer full-frame blits per
second) without the CPU phases changing; heat rising monotonically over minutes.
*Falsified if:* `frame_ms ≈ coordinator_total + other measured CPU` and turning glow off changes
frame time by a few percent.

**C2 — Main-loop CPU per frame, outside the decoration coordinator.**
`Player._physics_process` at 240 Hz (`Player.gd:302`, ~80 KB/s of Variant traffic, §2.3 of the
diagnostic report), `GameScene._process` (`GameScene.gd:496`) calling
`NativeTriggerBridge.live_channel_color` 4–6× per frame (each call = channel lookup + several
`Object::get` property reads, `gdash_native.cpp:5169`), `FrustumCuller._process`
(`FrustumCuller.gd:200`), `Level._process` (`Level.gd:223`), the pulse path
(`ColorChannelWatcher.gd:343` re-querying `get_nodes_in_group` per pulse frame), and the 851
enabled `_process` nodes counted in `reports/idle-render-work-2026-10-16.md`.
*Predicts:* `frame_ms` tracking `coordinator_total_us` plus a measurable non-coordinator CPU
budget; visible frame drops in sections with many pulse triggers or monsters; the 30 FPS cap
changing `frame_ms` little.
*Falsified if:* CPU phases stay small while frames are still slow.

**C3 — Command re-emission inside a batch (the B2 item from the diagnostic report).**
`advance_spinning_records` (`gdash_native.cpp:11233`) accumulating rotation for every spinning
record; `rebuild_commands` (`:10918`) clearing and re-submitting a batch's selected records
whenever one visible record moves.
*Predicts:* the new `flush_us` phase dominating `coordinator_total_us`, and `anim_skip` climbing
alongside it.
*Falsified if:* `flush_us` is a small fraction of the frame.

**C4 — Cull/pool overhead (the B3 item).**
One `WorkerThreadPool` group per frame before the range gate, ~800 jobs.
*Predicts:* `capture_us` + `post_us` large, `groups` ≈ `coordinator_frames` before the gate.
*Falsified if:* those phases are already small with the gate in place.

**C5 — Thermal throttling, as an amplifier rather than a cause.**
`project.godot:442` `max_physics_steps_per_frame = 12`, and `max_fps = 0` before this week's
change: an uncapped, thermally loaded phone runs more steps per late frame, which makes the next
frame later. This is why the symptom is "fine, then degrading", not "slow from the first frame".
*Predicts:* frame time and the per-frame CPU phases both growing over a 10-minute session while
the scene stays the same.

**C6 — Network / physics sync.** Ruled out for the play frame: `HTTPRequest` + signal callbacks
only (`RobTopLevels.gd:725/767/862`), retry via `create_timer` (`:707`), no frame-time polling; the
240 Hz tick is native and measured at 0.5–1.1 ms (`frames.csv physics_ms`, and that column is also
a per-second max, so the true mean is lower).

### Where the balance of evidence sits

C1 first, C2 second, C3/C4 third. The reasoning:

- the desktop runs show a *rendering-shaped* cost curve (§2.2) and 3.7 ms of GPU+CPU render work
  for 6,600 submitted records on a desktop GPU — the same work on a phone GPU is the one term that
  cannot be bounded by reading code;
- everything the CPU does per frame in the shipped configuration is either native (trigger
  scheduler, collision pairs, packed player physics) or proportional to *visible* objects, which
  the batch design reduced from ~170k nodes to ~800 canvases;
- the reported symptom — smooth at first, degrading with heat, with input latency rising — is the
  signature of a device at its **power/bandwidth** limit, not of a fixed per-frame CPU cost, which
  would be equally slow from the first frame.

This is a ranking, not a conclusion. §4 makes it one 5-second log line on the next device run.

---

## 4. Instrumentation added so the next run answers it

### Native, per phase (`native/src/gdash_native.cpp`)

`DecorationCoordinatorTimers` (declared at `:8007`) brackets the coordinator's five main-thread
phases with one clock read each (≈8 `get_ticks_usec` calls per frame, tens of ns each):

| Phase | What it covers |
| --- | --- |
| `apply_us` | `wait_for_group_task_completion` + `apply_cull_job` for every batch (i.e. joining last frame's pool work) |
| `anim_us` | `advance_animation` over every animated batch |
| `flush_us` | `flush_commands` → `canvas_item_clear` + re-emit for every dirty batch |
| `capture_us` | `capture_cull_job` for every registered batch |
| `post_us` | `WorkerThreadPool::add_group_task` |

`registered_decoration_stats()` reports them as `coordinator_*_avg_us` (mean over the interval
since the previous read), plus `coordinator_frames`, `coordinator_jobs_posted`,
`cull_groups_posted`, and `*_last_us` for the most recent frame. Reading the stats resets the
accumulators, so each `RENDERDIAG` print is self-contained.

### GDScript, frame pacing (`src/Level.gd`)

The same 5-second block now also prints real pacing measured from `_delta` — the one number in the
log that cannot lie:

```
RENDERDIAG phases fps=57.9 frame_ms=17.27 jitter_ms=12.40/41.20 apply_us=180.2 anim_us=95.4 flush_us=2100.6 capture_us=210.3 post_us=45.1 total_us=2631.6 jobs=812 groups=52
```

### Decision table — read the first line that matches

| Observation on device | Bottleneck | Next lever |
| --- | --- | --- |
| `frame_ms` ≈ 1000/refresh and `total_us` < 0.5 × frame_ms | CPU has slack; the device is waiting on presentation or GPU fill | C1: glow/HDR, resolution, overdraw — `Config.bloom` off is the 3-line test |
| `flush_us` ≥ 50% of `total_us` and `total_us` ≥ 0.3 × frame_ms | C3: command re-emission | the B2 fix already shipped; measure `anim_skip`, then consider per-batch animated RID splitting |
| `capture_us + post_us` ≥ 50% of `total_us` | C4: cull jobs/pool | the range gate shipped; lower `BUCKET_WIDTH` or cull less often |
| `apply_us` ≥ 50% of `total_us` | cull results are not ready when applied → pool starvation | raise `add_group_task` priority or drop the group (it is already skipped when the range is unchanged) |
| `frame_ms` and `total_us` both fall/rise together, `coordinator_frames` ≈ `fps` | C2: main-loop CPU outside the coordinator | profile with `simpleperf`/Perfetto; check pulse triggers and the 851 `_process` nodes |
| all phases small, `frame_ms` grows across a 10-minute run at fixed scene | C5: thermal | cap at 45/60, then C1 |

### How to collect it

```sh
# gameplay, 2 minutes per section, three sections: light / decoration-dense / pulse-heavy
adb logcat -c && adb logcat | grep -E "RENDERDIAG|GLOWDIAG" > /tmp/run.log
# the physics catch-up amplifier (C5)
adb shell "while true; do cat /sys/class/thermal/thermal_zone*/temp; sleep 30; done" > /tmp/thermal.log
# frame/jank distribution from the compositor, independent of the game's own counters
adb shell dumpsys gfxinfo <package> framestats > /tmp/gfxinfo.txt
```

Two controls make the result conclusive rather than suggestive:

1. **30 FPS cap run.** If `frame_ms` becomes ~33 ms with `total_us` still ~2 ms, the device is
   GPU/presentation bound (C1). If `frame_ms` stays ~40 ms and `total_us` does not move, the CPU
   is (C2/C3).
2. **Glow off run** (Settings → Bloom off). Same camera, same section. The delta is the cost of
   the glow chain and the HDR canvas in milliseconds — the only way to price C1 without a
   profiler.

---

## 5. Status

Written and checked here: `gdparse` clean on `src/Level.gd`; brace/balance check on
`gdash_native.cpp`; the timing arithmetic re-derived from Godot 4.4 `main/main.cpp`. **Not**
compiled against `godot-cpp` and not run: no extension toolchain and no device in this sandbox.
The counters are additive and read-only; if the build fails they can be dropped without touching
renderer behaviour.
