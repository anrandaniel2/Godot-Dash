GODOT DASH — Windows x86-64 / Forward+

INSTALL / UPDATE (recommended)
Run GodotDashSetup-x86_64.exe. The desktop shortcut is preselected by default;
the installer also creates a Start-menu shortcut. It installs per-user under
%LOCALAPPDATA%\Programs\Godot Dash and does not require administrator rights.
Run a newer installer to update the SAME writable installation, not a second app.
If an older machine-wide install is inaccessible, setup falls back to the per-user
folder and explains that the old copy may need separate removal. Saved levels,
settings and replays remain in %APPDATA%\godot-dash.
Close the game first (save any edits). Only one setup instance can run at a time.
The title screen checks this build's branch-specific GitHub update channel and
links to the installer when a newer build exists. Downloads/installations remain
user-confirmed; nothing silently runs a downloaded executable.

SECURITY / ANTIVIRUS
These GitHub builds are currently unsigned. Windows SmartScreen or antivirus may
warn about an unknown publisher and scan the installer's temporary extraction files.
Do not turn off antivirus or add an exclusion. Verify the download came from this
project's GitHub release. A trusted Authenticode signature is required to improve
publisher reputation and reduce those warnings; scanning cannot safely be disabled
by the installer.

YOUR FILES
All versions keep using %APPDATA%\godot-dash for user://. Changing the app title
or EXE name does not move that directory. Settings, levels, songs, replays,
keybinds and other user files are neither overwritten by setup nor removed by
uninstall. Keep your normal backups. Old manually extracted ZIP folders are not
automatically deleted; setup cannot safely guess which folders belong to you.

PORTABLE ZIP (optional)
Extract the entire ZIP and run Godot Dash.exe. Keep Godot Dash.pck and all DLLs
in their exported locations. This uses the same user directory as the installer.
No Godot installation is needed. These builds are unsigned: Windows may show
an unknown-publisher warning. Verify the download came from this project's
GitHub release before running it.

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
FPS limit defaults to 0 (no software limit), independent of VSync. A one-time migration
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

DOWNLOADS AND DISPLAY TROUBLESHOOTING
Windows retries blocked public level/archive/audio requests once through the
same configured HTTPS relay used by Web, where supported. No account login or
credentials are relayed. A failed direct request can add up to 15 seconds for a
level/text request or 30 seconds for audio before the fallback. A server outage
or unsupported/deleted level can still fail; include the level ID and error.

The temporary monitor/refresh text remains removed. Saved VSync/FPS preferences
are applied at startup; Godot handles display transitions. The experimental
display-polling/VSync-reapply hook is disconnected after a wavy-distortion report.
The game never chooses a renderer from monitor Hz, adds a monitor-derived FPS cap,
or changes your Windows display configuration. Physical-display retesting is needed.
Duplicate mode can share a presentation rate across monitors. For independent
maximum refresh rates, choose Extend in Windows and select each monitor's
highest supported rate in Advanced Display. The app cannot override clone-mode
presentation limits; this needs real multi-monitor testing.

The stale blur-copy visibility risk in paused menus is addressed, but
whole-screen black flicker and 60-FPS VSync still require device verification.
No rendering effects, physics, replay timing or level content were removed.

Fullscreen -> Exclusive Fullscreen now briefly passes through windowed mode to
work around Godot 4.7.2 retaining normal fullscreen's oversized bounds. It keeps
the active monitor and your chosen mode. A brief transition flash is possible;
continuous flickering is not expected or considered verified fixed by this change.

LEVEL RENDERER OPTIMISATION
Decoration redraws reuse the ordered visible-record list until the visible
cells or spatial index change. Colors, transforms, pulses and blending are
still read live; no visual effects, geometry or collision data are removed.
Exactly unchanged color/blend/transform updates no longer dirty draw commands.
renderer-cache.log reports an isolated CPU selector benchmark and ordered-ID
parity checks, not whole-game FPS. renderer-integration.log checks the real
native renderer's live data, dirty flags and retained commands, not pixels/GPU output.

Static/spinning batches also no longer run empty GDScript callbacks after entering
the tree. Native spin/rendering continues unchanged; monster callbacks remain on.
The integration log includes a 2,000-node callback microbenchmark, not game FPS.
