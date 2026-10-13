GODOT DASH — Windows x86-64 / Forward+

Extract the entire ZIP, then run godot-dash.exe. Keep its PCK and DLL files
beside it in their exported locations. The native acceleration DLL is included;
no Godot installation is needed. The executable is unsigned: Windows may show
an unknown-publisher warning. Verify that the ZIP came from this project's
GitHub Actions/release before running it.

Forward+ requires a compatible graphics driver/GPU. This is NOT the web build.
A build-time native smoke check is headless; it cannot verify your GPU or visual
parity. On launch, the engine log should identify Forward+ and a native-loaded
message should appear when a level opens. Report startup errors verbatim.

PERFORMANCE CAPTURE (optional)
Open PowerShell in this extracted directory and run:
  powershell -ExecutionPolicy Bypass -File .\Profile-Windows.ps1

Read the script before running it if you prefer. It launches the game with
Forward+ explicitly selected and creates a performance-<timestamp> directory.
No LDM, effects, physics, collision or replay settings are changed.

Open ONE slow level and either play it or edit it. After 120 active warm-up
frames the game records 1800 frames. The CSV is written at the end (or at normal
exit), and the game remains open. A one-time file-write pause can occur at the
end; its finalize_ms is logged separately, outside the sampled frame times.
Close the game to finish the process-memory log.

Send game.log, frames.csv, memory.csv, your CPU/GPU, display resolution, frame
cap/vsync settings, level name/ID and whether you were playing or editing.
For before/after tests, use identical settings and the same camera/player route.
Recording uses GPU timestamps and has overhead: sampler_mean_us reports only
CPU sampling work, not all GPU instrumentation overhead. Normal launches do not
record or enable GPU timing. Do not compare an instrumented run to a normal run.

frame_wall_ms includes frame pacing; process/physics/GPU monitor timings can be
lagged and must not be added together as if they were the same frame's budget.
Release-engine static memory counters may be zero. memory.csv contains Windows
working set, private bytes and peak working set instead; none is GPU VRAM.
The launch-relative clocks in the two CSVs have slightly different origins.

FRAME PACING
Max FPS defaults to 0 (Unlimited), independent of VSync. A one-time migration
clears the old 60/monitor-refresh default caps; unrelated custom caps survive.
You can set an explicit cap again after this migration.
VSync Enabled asks Windows/the driver to synchronize to the active display.
If Enabled still holds 60 on a 240 Hz panel, try Exclusive Fullscreen and check
Windows Advanced Display and any per-game GPU-driver frame limiter. No app
setting can guarantee that the hardware/compositor presents at 240 Hz.
Physics remains 240 ticks/s even when rendering is uncapped.

No capture is required to use this build. Normal hidden diagnostics no longer
enable GPU timestamp queries. F3 detailed graphs and optional captures request
GPU timing only while needed. Gameplay effects and content are unchanged.

BUILD.txt identifies the commit. runtime-safety.log contains automated frame
policy, selection-order and profiler-ownership tests plus a selection build
microbenchmark. These are not real-level FPS measurements.
