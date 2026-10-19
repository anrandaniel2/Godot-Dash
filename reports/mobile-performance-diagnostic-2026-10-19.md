# Mobile performance diagnostic — 2026-10-19

Why this build drops frames, heats and throttles, and gains input latency on Android while
playing smoothly on desktop. Everything below is read out of the checkout at `4fdd955` plus the
changes in §7. Line numbers are from the working tree after those changes; every claim names a
file, function and line.

**Evidence status.** Source-level findings only. There is no Godot binary and no Android device in
this environment, so no frame time, GPU time or temperature in this report comes from a run. Where
a number is arithmetic on shipped settings it is labelled as such. §8 is the device protocol that
would confirm or refute each item; §9 lists the changes I did not make because they are product
decisions.

## Findings at a glance

| # | Bottleneck | Where | Mobile-specific because | Shipped fix |
| --- | --- | --- | --- | --- |
| 1 | Desktop frame budget: `max_fps = 0` (VSync-paced at 90/120 Hz) on an HDR canvas with glow | `project.godot:100,471`; `scenes/GameScene.tscn:81-84`; `Config.gd:400` | A phone pays DRAM bandwidth and watts per frame; a desktop GPU does not, so only the phone throttles and only the phone's *input sampling rate* degrades with it | 60 FPS one-shot mobile cap; saved render scale now applied at boot |
| 2 | A spinning record outside the visible cells still dirties its batch, so the whole command stream is cleared and re-emitted | `gdash_native.cpp:11230` `advance_spinning_records` → `:10876` `rebuild_commands` | Main-thread CPU + allocator + `RenderingServer` queue on cores that are ~4× slower per thread | only selected records dirty a route (`:11183`) |
| 3 | One `WorkerThreadPool` group per frame (one job per batch, ~800) for a cell range that changes a handful of times per second | `gdash_native.cpp:11854` coordinator, `:11270` `capture_cull_job` | 60 wake-up-and-join cycles per second on 4–8 threads, competing with physics and render submission | prospective-range comparison before posting |

Measured non-findings: draw-call/batching (62 draws in the repo's own capture), GDExtension
marshalling (~80 KB/s on the player path), network (no per-frame polling).

---

## 1. Data flow

```
 GDScript (main)     Level.gd · GameScene.gd · Player.gd · ColorChannelWatcher.gd
                     DecorationBatch.gd  (one Node2D per batch, ~800 per level)
        │  Variant calls: tables, indices, colours          │ node transforms,
        │                                                   │ modulate, visible
        ▼                                                   ▼
 C++ GDExtension     NativeLevelRuntime    (NOTIFICATION_PROCESS / _PHYSICS_PROCESS)
 (main thread)       NativeDecorationRenderer × N  records · spatial index ·
                     command rebuild · WorkerThreadPool cull
                     NativeTriggerRuntime · NativeColorChannelIndex · NativeFrustumIndex
        │  RenderingServer::canvas_item_*   (driver/threads/thread_model=0, project.godot:458)
        ▼
 Engine              RendererCanvasCull → RendererCanvasRenderRD (batches quads by
                     texture/material/blend/clip) → RD (Mobile Vulkan) → TBDR GPU
```

Per process frame (all main thread):

| # | Where | Work |
| --- | --- | --- |
| 1 | `gdash_native.cpp:8088` `NativeLevelRuntime::NOTIFICATION_PROCESS` | frame entry |
| 2 | `:11854` `update_registered_decoration_renderers` | coordinator (once per process frame) |
| 3 | `:11866-11874` apply the previous frame's cull group | `apply_cull_job` per batch |
| 4 | `:11875` `advance_animation` for each animated batch | rotate spinning records, dirty routes |
| 5 | `:11878` `flush_commands` for each dirty batch | `canvas_item_clear` + re-emit |
| 6 | `:11900-11903` `capture_cull_job` for every batch | job per batch, then `add_group_task` |
| — | `:8093` `NOTIFICATION_PHYSICS_PROCESS` at 240 Hz | `tick` + `advance_player` |

Two things are already right and are *not* the problem: decoration is not a node per sprite
(`NativePackedDecorationBuilder`, `:11464`, hands `std::vector<Record>` straight to the renderer),
and the physics step is not a GDScript loop (`compute_player_velocity_packed`, `:10079`).

---

## 2. The four hypotheses, checked against the code

### 2.1 TBDR unfriendliness — real, and it is fill rate, not draw calls

- `canvas_item_add_texture_rect_region` (`:10934`) appends a `CommandRect`; Godot's
  `RendererCanvasRenderRD::_record_item_commands` merges consecutive rects with the same texture,
  material, blend and clip, and `canvas_item_add_set_transform` (`:10922`) does **not** break a
  batch (Godot 4.4, `renderer_canvas_render_rd.cpp`, `case Item::Command::TYPE_TRANSFORM`). The
  decoration atlas is one page, so a layer collapses into few GPU draws. The repository's own
  capture agrees: `performance-20261017-071452/frames.csv` has `draw_calls = 62` with 36,315 nodes.
  Aggregating quads into `canvas_item_add_triangle_array` would *increase* batch count (a batch's
  parent transform cannot be folded into a merged array) and was already reverted for Android
  pixel parity (`reports/decoration-node-and-draw-call-review-2026-10-15.md`).
- What *is* TBDR-hostile is the frame composition: an RGBA16F canvas
  (`project.godot:471 viewport/hdr_2d=true`), glow enabled (`scenes/GameScene.tscn:84`, set from
  `src/WorldEnvironment.gd:6`), and a background stack that covers the screen several times
  (`scenes/GameScene.tscn:96-123`: two 20480×4096 background sprites at `scale = 2`, plus ground
  layers at `scale = 2.5`, `:158`/`:195`). Every one of those pixels is alpha-blended into a
  format that is twice the traffic of RGBA8, before glow's downsample/upsample chain runs.

### 2.2 CPU↔GPU sync — the stall is command-list churn, not a blocking read

There is no `RenderingServer.sync()`, raster wait or texture readback in the gameplay path. The
CPU→GPU pressure is that the retained command stream for a batch is **discarded and rebuilt**
(`canvas_item_clear`, `:10892`; then one transform + one rect command per selected record,
`:10922` and `:10934`) whenever anything in that batch moves. §3.2 is the case where that happens for an
invisible reason.

### 2.3 GDExtension marshalling — measurable, but not a bottleneck per frame

| Crossing | Rate | Payload | Verdict |
| --- | --- | --- | --- |
| `Player._compute_velocity` → `compute_player_velocity_packed` (`Player.gd:941`, `:10079`) | 240/s | 31 doubles in (248 B), 11 doubles out (88 B) ≈ 80 KB/s total | Already batched; ~4 calls per rendered frame, not a bottleneck. The 11-element result array is one small allocation per tick — worth removing only with a replay-parity run |
| `FrustumCuller._update` (`FrustumCuller.gd:205`) | 60/s | 2 calls, 2 floats | negligible |
| `NativeLevelRuntime` trigger scheduler | 240/s, entirely native | none | correct design |
| `ColorChannelWatcher._refresh_native` (`:343`) | **every animation frame of a running colour pulse** | `get_nodes_in_group` returning a fresh `Array` of N pointers, plus two more group queries | real, §6.1 |

So "too many boundary crossings per frame" is not what makes this game slow on a phone; the
per-frame tree queries on a pulse are.

### 2.4 Network — clean

Every request is an `HTTPRequest` with a signal callback (`Levels/RobTopLevels.gd:725,767,862`),
retries use `create_timer` backoff (`:707`), and no `_process` polls an `HTTPClient`. Downloads and
SFX extraction happen before play. Nothing in the play frame touches the network.

**Physics** is where the rhythm-game risk actually is, and it is not the 240 Hz tick itself: it is
`max_physics_steps_per_frame = 12` (`project.godot:442`) applied to a frame that is already late.
A 50 ms hitch makes the engine run twelve 4.17 ms steps in one frame — exactly when the phone is
thermal-throttling. I did not change it: that alters catch-up semantics (§9).

---

## 3. Top 3 bottlenecks

### 3.1 B1 — The frame budget is a desktop budget: unlimited FPS × HDR × glow

**Files / lines.** `project.godot:100` (`window/vsync/vsync_mode=1`), `Config.gd:47` (`max_fps = 0`),
`Config.gd:400` `apply_frame_pacing`, `project.godot:471` (`hdr_2d`),
`scenes/GameScene.tscn:81-84` (`Environment`: `background_mode = 3`,
`background_canvas_max_layer = 50`, `glow_enabled = true`), `src/WorldEnvironment.gd:6`,
`scenes/GameScene.tscn:150,187` (ground sprites at `scale = 2.5`, `region_rect` 9600×240).

**Mechanism.** `max_fps = 0` means "no software cap". VSync then paces presentation, so a 90 Hz or
120 Hz phone renders 90 or 120 frames per second of a scene that is (a) an HDR canvas, (b) glow
post-processed, (c) several times overdraw. Geometry Dash's own simulation runs at 60; nothing in
this game needs 120 presented frames, and every extra frame is paid for in DRAM traffic and watts.

Order of magnitude, on the shipped settings: 1920×1080 RGBA16F is 16.6 MB per store, before the
glow chain's extra passes and before any overdraw from the background/ground stack. Twice the
refresh rate is twice that per second. A desktop GPU absorbs it; a phone GPU at the same
resolution spends its thermal budget on it and clocks down, which is precisely the reported
sequence: fine for a minute, then frames drop and touch latency rises (input is sampled per
frame — `Player._physics_process` reads `InputUtils` at `Player.gd:319`).

**Second defect in the same area.** `Config.render_scale` is saved (`Config.gd:441`) and read at
boot (`:234`), but the only code that applies it is the settings slider
(`SettingsMenu.gd:106-113`). A player who lowers render scale, quits and relaunches gets the
default back. Note also what that setting is: with `window/stretch/mode="canvas_items"`
(`project.godot:98`) it sets `Window.content_scale_factor` — a canvas transform. It changes layout
and zoom; it does **not** allocate a smaller framebuffer, so it is not a fill-rate lever on
Android.

**Fix shipped.** `src/static/MobileRenderBudget.gd` caps mobile at 60 once, only replacing the
value that means "unlimited", after the desktop pacing migrations so it cannot fight them;
`Config.apply_render_scale()` reapplies the saved scale at boot and the slider delegates to it.
No pixel changes.

### 3.2 B2 — A record that cannot be seen re-emits a batch's command stream

**Files / lines.** `:11875` `advance_animation` → `:11230` `advance_spinning_records` →
`:11236` `mark_routes_dirty` → `:11006` `flush_commands` → `:10876` `rebuild_commands` →
`:10892` `canvas_item_clear` → `:10934` `canvas_item_add_texture_rect_region`.

At `4fdd955`, every spinning record marked its blend route dirty unconditionally. The rebuild then
clears the canvas item and re-emits **every selected record** in the batch — a fresh `CommandRect`
(heap allocation + list growth) and, where transforms differ, a `CommandTransform`, per sprite.

The cost per batch depends on whether it straddles the screen:

- Batch entirely off-screen: `range_has_records` is false, so `rebuild_commands` clears three canvas
  items and returns (`:10899`). Still three `RenderingServer` calls, one `command_rebuilds`
  increment and a dirty-set insertion/erase **per spinner batch per frame**, for output that is
  identical to the previous frame.
- Batch that straddles the screen (common: a batch spans a section) with its spinner off-screen:
  the full re-emission runs. Hundreds of records re-allocated and re-submitted each frame because
  a sawblade the player cannot see is turning.

Nothing about this is cheap in proportion to what it changes: rotating a record changes 6 floats.

**Fix shipped.** `advance_spinning_records` still accumulates rotation for **every** spinning
record (rotation is incremental, so skipping it would desynchronise the pose), but only calls
`mark_routes_dirty` when the record is in the current selection
(`record_in_selection`, `:11183`, backed by `DecorationVisibilityCache::contains`,
`native/src/decoration_visibility_cache.h:71`, O(1) generation-stamp lookup). A range change
already calls `mark_all_routes_dirty()` in `apply_cull_job` (`:11325`), so a record that scrolls
into view is emitted with its accumulated transform on that same rebuild.

**Remaining ceiling, stated plainly:** a visible spinner still forces a full re-emit of its batch
each frame. Removing that needs either a second canvas item per batch for animated records
(reordering hazard: a canvas item's commands cannot be interleaved with a sibling's) or a
per-record item (reintroduces the object count this design exists to avoid). Neither is worth
shipping blind.

### 3.3 B3 — One WorkerThreadPool group is posted, and joined, every frame

**Files / lines.** `:11900-11903` (build the job vector), `:11906-11908` (`add_group_task`),
`:11866-11873` (`is_group_task_completed` + `wait_for_group_task_completion`),
`:11270` `capture_cull_job`, `:11328` `update_camera_range`, `:7957`
`NativeDecorationCullWorker::compute`.

`capture_cull_job` only declined a job when the screen transform was *bit-identical* to last
frame. The camera moves every frame, so every frame:

1. builds one `DecorationCullJob` per batch (~800) — each copy carries two `std::shared_ptr`s, i.e.
   two atomic refcount bumps, plus a `Transform2D`;
2. calls `WorkerThreadPool::add_group_task` (`:11906`), which allocates a `Group` and
   `threads.size()` `Task`s, takes `task_mutex`, and posts them. The pool then dispatches each
   element through a **Variant `Callable::call(index)`** (Godot 4.4 `worker_thread_pool.cpp:103`),
   ~800 per frame;
3. next frame checks completion and, if done, joins and applies all jobs — almost all of which
   `apply_cull_job` immediately discards at `:11315-11316` because the cell range did not change.

The result that can change is a 256 px bucket crossing (`BUCKET_WIDTH`,
`src/DecorationBatch.gd:38`), i.e. roughly `speed / 256` times per second (a handful), versus 60
group posts per second. On a 4–8 thread phone this is 60 wake-ups per second of a pool that is
otherwise idle, competing with the render thread and the 240 Hz physics tick for the little cores.

**Fix shipped.** `capture_cull_job` computes the prospective cell range on the main thread (four
corner transforms + `floor`, the same math as `NativeDecorationCullWorker::compute` at `:7960`) and
returns false when it equals the applied range (`cull_range_matches`, `:11255`). The worker keeps
the expensive part — `DecorationVisibilityCache::prepare` over the cell index — and is simply not
asked to redo a selection that cannot differ. Group posts drop from one per frame to one per cell
crossing.

---

## 4. Quantities

| Path | Before | After | Basis |
| --- | --- | --- | --- |
| Presented frames per second, 90/120 Hz phone | up to 90/120 | 60 | settings; halves per-second GPU, CPU and thermal load |
| Worker-pool group posts | 1 per frame (60/s) | 1 per 256 px of camera travel (≈5/s at 1329 px/s) | `BUCKET_WIDTH`, camera speed |
| Batch rebuilds caused by off-screen spin | 1 per spinner batch per frame | 0 | `contains()` gate |
| Physics tick rate, movement math, draw order, colours, z | unchanged | unchanged | by construction |

No frame-time figure is claimed. §8 is how to get one.

---

## 5. Rejected fixes

| Candidate | Why not |
| --- | --- |
| `canvas_item_add_triangle_array` (one command per batch) | Already few GPU draws (62 in the repo's own capture); arrays raise batch count and previously failed Android parity (9,216-pixel gate) |
| A canvas item per sprite, so transforms update in place | Reintroduces the object count batching avoids; sibling order is fixed at creation |
| Split each batch into static/animated streams | Order-preserving only for contiguous runs and requires per-range RID recreation; large change for part of B2's win |
| `physics_ticks_per_second` < 240 | Breaks 1:1 GD physics |
| `max_physics_steps_per_frame` < 12 | Changes catch-up/slow-motion behaviour (§9) |
| `content_scale_factor` as "render scale" | It is a canvas transform, not a resolution change (§3.1) |
| Dropping `clip_uv` from `:10934` | It suppresses atlas bleed by half a texel; the triangle-array attempt proved that bleed is visible |
| Disable glow/HDR on all platforms | Changes the game's look; see §9 |

---

## 6. Secondary findings

### 6.1 A colour pulse re-queries the SceneTree every animation frame

`ColorChannelWatcher.refresh_objects_color` (`src/ColorChannelWatcher.gd:105`) runs once per
animated frame while a colour trigger's easing is active
(`ColorChannelChangerComponent._on_easing_progressed`, `:291-327`). On the native path it then calls
`_refresh_native` (`:343`), which does

```gdscript
var members: Array = get_tree().get_nodes_in_group(_data.associated_group)   # :350
if _native_member_count != members.size() or _native_watcher_version != HSVWatcher.data_version:
```

`get_nodes_in_group` allocates an `Array` and copies N object pointers *even when the answer is
"unchanged"*, purely to read `.size()`. `_refresh_decoration_batches` (`:408`) then does a second
group query for the batch group (`:421`). For a pulse channel with thousands of watchers that is
thousands of pointer copies and two array allocations per frame, on top of the native `apply`
call that actually recolours.

The fix needs a membership generation counter (bumped from `HSVWatcher`'s group add/remove paths,
which `data_version` does not currently cover) so the arrays can be cached safely; shipping a
cache without it would leave stale watchers after an object is freed. Not shipped.

### 6.2 Player physics boundary

`Player._compute_velocity` (`Player.gd:878`) is already the packed form: 31 doubles filled into a
reused `PackedFloat64Array` (`_physics_params`, `:263/282`), one `Object.call` (`:941`). Only two
remaining allocations per tick: the returned 11-element array, and
`replay.data.append(PackedByteArray([...]))` (`:323`) — 240 tiny allocations per second that live
until death/restart. Both are safe to remove but need a replay-parity run to prove identical
recording; ~4 allocations per rendered frame is not what drops a frame.

### 6.3 Per-frame diagnostics

`Level._process` (`src/Level.gd:223`) calls `_print_beam_diagnostics_live` every frame; the
early-out is cheap but every 5 s it walks every colour channel and then prints (string formatting
+ logcat write). On device that is a small but real hitch twice per 10 s; gate it behind
`OS.is_debug_build()` or a config flag when profiling.

### 6.4 Blur

`src/BlurBackBuffer.gd` attaches a `BackBufferCopy` in `COPY_MODE_VIEWPORT` to every blurred
`Control` (`Config.gd:381` `node_added`) and re-syncs on `frame_pre_draw`. That is a full-viewport
copy per blurred control per frame — fine for the pause menu, worth checking that no gameplay HUD
control is in that set on mobile.

---

## 7. Changes made

| File | Change |
| --- | --- |
| `src/static/MobileRenderBudget.gd` | **new.** One-shot mobile FPS budget: returns the cap to adopt or -1 |
| `src/autoloads/Config.gd` | runs the budget after the frame-pacing migrations; `apply_render_scale()`; applies the saved scale in `_ready()` |
| `src/SettingsMenu.gd` | Render Scale slider now writes `Config.render_scale` and calls `Config.apply_render_scale()` (one owner) |
| `native/src/decoration_visibility_cache.h` | `contains()` — O(1) selection membership via generation stamps |
| `native/src/gdash_native.cpp` | `record_in_selection` gate in `advance_spinning_records`; `cull_range_matches` gate in `capture_cull_job`; `skipped_animation_rebuilds` / `skipped_cull_jobs` counters |
| `src/Level.gd` | `RENDERDIAG` prints `anim_skip` / `cull_skip` |
| `native/tests/test_decoration_visibility_cache.cpp` | membership, invalidation and `uint8_t` stamp-wraparound tests |
| `tools/benchmarks/runtime_safety/SafetyChecks.gd`, `tools/windows_ci.py` | headless policy tests for the budget; new script added to the standalone safety project |
| `docs/agent-briefing/02`, `07` | document the budget, the two gates, and what render scale is |

Constraints honoured: no physics, timing, collision, ordering, colour or transform change; no new
per-frame node or thread; the gates only skip work whose output is provably identical.

---

## 8. Verification status and device protocol

Run here:

- `gdparse` (gdtoolkit) on every changed GDScript file — clean. `gdformat --check` is clean on the
  new files; `Config.gd`/`SettingsMenu.gd` were already non-conforming at `4fdd955` and are left at
  that baseline rather than reformatted.
- `g++ -std=c++17 -O2 -Wall -Wextra -Werror native/tests/test_decoration_visibility_cache.cpp`
  → `DECORATION_CACHE_SUMMARY checks=9630 failed=0` (`--benchmark` → `checks=9645 failed=0`). The
  same suite at `4fdd955` reports `checks=8413`, so the new tests add 1,217 checks. This compiles
  and runs the **actual** cache header the renderer uses, including `contains()`.

Not run: the GDExtension build (needs the pinned `godot-cpp`, absent here), any Godot run, the
`renderer_cache_selftest`, the pixel gates, and any performance measurement.

Before this is called a win:

1. `python tools/windows_ci.py build` — compiles the extensions, runs native suites and
   `SafetyChecks` (the budget tests are in `SafetyChecks._test_mobile_budget`).
2. `res://tools/renderer_cache_selftest.tscn` and `res://tools/runtime_visual_smoke_test.tscn`
   must stay green; the reference-renderer comparison covers command content, not just counts.
3. Android Mobile pixel gate (the 9,216-pixel comparison used for the triangle-array attempt).
4. On device, same build/level/camera, `adb logcat | grep -E "RENDERDIAG|BEAMDIAG"`:
   `anim_skip` and `cull_skip` must be non-zero and climbing; `draws` must be **unchanged** at the
   same camera position — if it drops, the gates are hiding something that should be drawn.
5. `--perf-capture` before/after on the same phone for `frame_wall_ms`, `process_ms`,
   `render_gpu_ms`, plus surface temperature over 10 minutes.

---

## 9. Decisions left to you

- **Glow / HDR on mobile.** `src/WorldEnvironment.gd:6` disables glow for web because it is
  "several fullscreen passes"; Android keeps it. Making `glow_enabled` follow `Config.bloom` on
  mobile (default off, player can re-enable) is the largest remaining GPU win and has a precedent
  in this codebase, but it changes how every level looks. Three lines, needs a pixel gate.
- **`max_physics_steps_per_frame`.** Consider 6 instead of 12, with an explicit decision about
  slow-motion on a stalled frame, measured on a long level.
- **True render scale.** If the target phones are 1440p panels, a real resolution reduction needs a
  `SubViewport` pipeline. That is a rendering-architecture change, not a setting.
