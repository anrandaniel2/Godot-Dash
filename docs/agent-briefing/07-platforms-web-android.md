# 07 — Platforms: web (WebGPU), Android, desktop, and CI

## 1. Export presets (`export_presets.cfg`, gitignored but tracked)

| # | Name | Platform | Notes |
| --- | --- | --- | --- |
| 0 | Windows Desktop | Windows | x86-64 Forward+, native release DLL staged by Windows CI |
| 1 | Linux/X11 | Linux | |
| 2 | Android | Android | Gradle build, arm64-v8a only, native libs compressed |
| 3 | Web | Web | WebGPU (Mobile renderer) on a wasm64 threaded template, WebGL 2 fallback, extensions, shader baker |

### Web preset (key fields)

```ini
export_filter="all_resources"
include_filter="assets/textures/gd_atlas/*.json,assets/textures/gd_atlas/source/*.plist"
exclude_filter="native/src/*,native/tests/*,native/godot-cpp/*,native/scons-cache/*,tools/*,
                assets/textures/gd_atlas/source/*.png,addons/script-ide/*,scenes/tests/*"

[preset.3.options]
custom_template/debug=""          # rewritten by tools/pin_webgpu_templates.py in CI
custom_template/release=""
variant/extensions_support=true
variant/thread_support=true
vram_texture_compression/for_desktop=true
vram_texture_compression/for_mobile=true
shader_baker/enabled=true
html/export_icon=true
html/head_include="<script>…</script>"   # swallows orientation/fullscreen promise rejections
html/canvas_resize_policy=2
html/focus_canvas_on_start=true
html/experimental_virtual_keyboard=false
progressive_web_app/enabled=false
progressive_web_app/ensure_cross_origin_isolation_headers=true
threads/emscripten_pool_size=8
threads/godot_pool_size=4
progressive_web_app/background_color=Color(0, 0, 0, 1)
```

Reminder: `include_filter` keeps the atlas JSON/plists in the export (the runtime can fall back
to plist parsing), and `exclude_filter` keeps tools/native sources out. **Any new runtime data
file must be checked against both filters.**

### Android preset (key fields)

```ini
gradle_build/use_gradle_build=true
gradle_build/compress_native_libraries=true
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
permissions/access_wifi_state=true      # online levels; no other permissions enabled
```

## 2. Web build — how it actually works

1. **Renderer**: WebGPU via the hogdot fork (a Godot 4.7.2 port of dwalter's GodotWebGPU
   driver). `rendering_method.web = "mobile"`. The template is also built with `opengl3=yes`, and
   `misc/web/shell.html` starts the Compatibility (WebGL 2) renderer only when the browser cannot
   create a WebGPU device. WebGPU is the target; WebGL is a fallback, and it is not the only web
   path. The CI check refuses to publish an export whose `index.html` does not mention `webgpu`.
2. **Templates and memory model**: the published hogdot web zips strip `Line2D`, physics shapes,
   MP3 and zip, so **CI compiles an unstripped threaded dlink template** from the same
   `HOGDOT_COMMIT` (`8927aa079d1d93ae1d5fc138c0148f648eee8fa3`, tag `cg-v4.7.2-r19`),
   with emsdk `EM_VERSION` 6.0.8 to match the template.
   The web build is **wasm64**, with a 16 GB maximum memory, so the level editor can go past the
   4 GB wasm32 ceiling. Both the engine and the side module must use wasm64, or they will not load
   together. The memory limits are set by the template link flags, not by `export_presets.cfg`.

   Before the build, CI patches the sources:
   - `tools/godot_cpp_wasm64.py` patches the pinned godot-cpp (`6cceaf6`, wasm32 only on the web),
     so `native/` can build the wasm64 `gdash_native` library (§5).
   - `tools/hogdot_wasm64.py` patches the hogdot source. It replaces the hard-coded
     `-sWASM_MEM_MAX=2048MB` in `platform/web/detect.py` (applied after `-sMAXIMUM_MEMORY`, which
     would otherwise be overridden), and it retypes the JavaScript `__sig` pointer letters from `i`
     to `p`. Without that, pointers reach the JS libraries as BigInts. The script rewrites 71
     signatures at the pinned commit. It refuses to run if a source anchor does not match.

   The engine is then built with `scons platform=web target=template_release arch=wasm64`,
   `webgpu=yes vulkan=no opengl3=yes`, `production=yes optimize=speed threads=yes dlink_enabled=yes`,
   `initial_memory=256`, `ccflags="-fwasm-exceptions"` and
   `linkflags="-sMAXIMUM_MEMORY=16GB -fwasm-exceptions"`. CI then asserts the zip's wasm still
   contains `Line2D`. `tools/pin_webgpu_templates.py` writes the built zip paths into the Web
   preset's `custom_template/debug|release` fields (pointing debug at the same zip so a missing
   debug template cannot fail the preset).
3. **Cross-origin isolation**: threaded builds need `SharedArrayBuffer`, hence COOP/COEP.
   `tools/serve_web.py` (default port 8060, host `0.0.0.0`) serves
   `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`,
   plus a `/cors-proxy?url=` endpoint.
4. **CORS relay**: browsers cannot call RobTop/GDHistory/song CDNs (no CORS headers;
   boomlings returns 403 to the `Origin` header). Search still works through GDBrowser, but
   downloads need a server-side relay:
   - local export → `serve_web.py` (`/cors-proxy`), auto-detected from localhost;
   - hosted → the Cloudflare Worker `tools/web_relay_worker.js`, configured by
     `network/cors_proxy` (shipped value
     `https://gddash.anrandaniel2.workers.dev/?url=`) or `Config.cors_proxy` per user.
   - Without a relay the build explains the limitation in-game (`WEB_RELAY_REQUIRED`,
   `WEB_RELAY_HINT`) instead of throwing console CORS errors.
   `tools/web_relay_worker_selftest.mjs` (Node, no deps) tests the Worker logic in CI.
5. **Export verification (CI)**: the export must contain `index.html`, `index.js`, `index.pck`,
   `index.wasm`, `index.side.wasm`, and `libgdash_native.web.template_release.wasm64.wasm`.
   `tools/check_wasm64.py` checks each memory import for a memory64 type with a maximum
   above 4 GiB; files without memory imports are accepted (it does not inspect defined memories).
   `tools/check_wasm_engine.mjs` calls Node 24's `WebAssembly.validate`: this checks binary
   validity, not instantiation, dynamic linking, JS pointer conversions, or browser startup.
   A wasm32 memory import fails the architecture check. `index.html` must mention `webgpu`;
   `index.side.wasm` must contain `Line2D`, `CircleShape2D` and `AudioStreamMP3`. A multi-thread export also emits
   worker/service-worker files.
6. **Browser support**: wasm64 needs memory64 in the browser. Safari cannot load the build at all
   (the `web.yml` header says "Browsers without memory64 (Safari at the time of writing) cannot load
   it"), so Safari has no web support. Browsers with memory64 run the WebGPU renderer, and browsers
   without WebGPU fall back to the WebGL 2 renderer in the same build. The site needs HTTPS (or
   localhost). It draws at browser resolution.
7. **Web-specific runtime behaviour**:
   - `WorldEnvironment` disables `Environment.glow` on web; `WebSoftEffects` implements a soft
     bloom with `WebGlowExtract`/`WebGlowOverlay` shaders. Menu blur is the same
     screen-texture shader as desktop (`BackgroundBlur.gdshader` + `BlurBackBuffer`).
   - `Config` forces `WINDOWED` (browsers require a user gesture for fullscreen) and runs a
     one-time bloom migration (`web_soft_glow`).
   - `UpdateManager` reports `DISABLED` (Codeberg sends no CORS headers; the host owns updates).
   - `NativeCore.backend()` skips the manifest diagnostic on web (`OS.has_feature("web")`).
8. **Local export helper**: `tools/export_web.sh [godot_binary] [out_dir]` wraps
   `--headless --export-release "Web"`.

## 3. Android build

Preset: Gradle build with the stock build template installed by CI, then patched:

- `android:largeHeap="true"` added to `AndroidManifest.xml`, app category set to game.
- `export_presets.cfg` uses `gradle_build/compress_native_libraries=true` so the download is not
  an uncompressed copy of libgodot.
- The native arm64 `.so` is bundled twice: through the exporter path
  (`native/bin/gdash_native.gdextension`) **and** copied straight into the Gradle project's
  release `jniLibs` so the APK contains it even if the exporter path fails.
- CI verifies the APK is arm64-v8a only and contains `gdash_native`.
- KD/JDK: JDK 17 (Temurin), Android SDK with build-tools 35.0.1 / platform 35, NDK
  `28.1.13356709`, scons installed via pip.
- Rolling release tag `android-debug` gives a constant download URL
  (`releases/download/android-debug/godot-dash-android-debug.apk`); a `release*` tag creates a
  stable release.
- Triggers: push to `main`, `master`, `arena/**`, any `release*` tag, or manual dispatch.

Runtime constraints on Android that show up in code:

- Opening a level is paced (`Config.paced_level_open`, `level_open_frame_budget_ms = 40`) so
  Android never shows an ANR dialog.
- Image import stays lossless (ETC2 + mipmaps would take the APK from ~7 MB of PNGs to ~40 MB);
  `textures/vram_compression/import_etc2_astc=true` is required for the exporter.
- `driver/threads/thread_model = 0` (Safe): the experimental Separate model stalled texture
  uploads at startup on at least one device (Samsung Xclipse 540).
- Memory diagnostics (`GameScene._print_process_memory`, `[gdash-mem]`) exist because the app was
  killed by lmkd on large levels.

## 4. Desktop

- Windows selects `renderer/rendering_method.windows="forward_plus"`; mobile/web keep Mobile.
  The renderer change is user-requested, not a measured performance win.
- `.github/workflows/windows.yml` (**Build Windows Forward+**) builds on Windows 2022 using
  the pinned godot-cpp, `platform=windows target=template_release arch=x86_64 api_version=4.7
  use_static_cpp=yes optimize=speed debug_symbols=no`. `tools/windows_ci.py` installs matching
  editor/templates outside the project, benchmarks channel-index construction, imports,
  exports, validates PE x86-64 artifacts and runs the exported EXE's headless native smoke.
- `tools/pin_windows_extension.py` stages Windows debug/release mappings to the release DLL
  in the build workspace; generated descriptor changes and binaries are not committed.
- The ZIP is an Actions artifact and commit-specific `windows-<sha8>` prerelease. Extract all
  files. Forward+ GPU startup, visual parity and real-level performance need device testing.
- The opt-in `Profile-Windows.ps1` included in the ZIP records process RSS/private memory;
  `src/debug/PerformanceCapture.gd` records frame intervals/CPU/GPU timings. Normal launches
  disable its process callback. Debug flags never hide content or alter physics/settings.
  CSV writing is outside the sample window; its diagnostic pause is logged as `finalize_ms`.

- Linux/Windows presets; `dist/linux/install.sh` registers the MIME type
  (`x-godot-dash.xml` → `application-x-godot-dash-level`), a 512×512 icon, and a
  `.desktop` entry with the binary path as `Exec`.
- `run/max_fps = 0`; `Config.max_fps` defaults to the detected panel refresh rate.
- Windows native icon `res://assets/logo/logo.ico` (LFS-tracked).

## 5. CI workflows — what "done" means

### `.github/workflows/main.yml` — "Build Android APK" (991 lines)

Runs on push to `main`/`master`/`arena/**`, `release*` tags and manual dispatch.

Order of significance:

1. Godot 4.7.2 binary + export templates (cached).
2. Android SDK/JDK/keystore setup; NDK install.
3. Build `gdash_native` for **linux debug** (kept symbols) then **android arm64 release**;
   asserts the trimmed build profile and a size tripwire.
4. Install the Android build template; patch the manifest (`largeHeap`, game category); drop the
   `.so` into Gradle `jniLibs`.
5. `godot --headless --path . --import` (import errors surface here).
6. **GDScript load probe**: `xvfb-run -a godot --path . --rendering-method gl_compatibility
   --audio-driver Dummy res://tools/gdscript_probe.tscn` — gate: `^PROBE_SUMMARY` present, no
   `^PROBE FAIL`. (Scene-run shape because a `--script` SceneTree probe hung in CI.)
7. **GDR replay codec self-test**: `res://tools/gdr_selftest.tscn` — gate
   `GDR_SELFTEST_SUMMARY … failed=0`.
8. **Native colour-trigger chain self-test**: `res://tools/native_color_selftest.tscn` — gate
   `NATIVE_COLOR_SELFTEST_SUMMARY … failed=0`.
9. **Renderer smoke test**: `res://tools/runtime_visual_smoke_test.tscn` — gate
   `VISUAL_SMOKE size=` plus no assertion failures; a post-success teardown segfault (exit 139)
   is tolerated and captures a backtrace.
10. **Amethyst boot test** through the native runtime (device crash repro).
11. Amethyst glow analysis (level data) → `reports/amethyst_glow.md` (best-effort; downloads can
    fail).
12. Export the Android release APK (Gradle), verify contents, upload artifact, update the rolling
    release.

### `.github/workflows/web.yml` — "Build Web HTML5" (job `web-export`)

1. Check the CORS relay Worker (`web_relay_worker_selftest.mjs`).
2. Install scons + Emscripten 6.0.8; patch the pinned godot-cpp for wasm64
   (`tools/godot_cpp_wasm64.py`); build `gdash_native` for wasm64 (threads), release and debug.
3. Download/cache the hogdot editor; patch the hogdot source (`tools/hogdot_wasm64.py`); build/cache
   the **unstripped threaded WebGPU template** (wasm64, 16 GB maximum memory); assert `Line2D` is
   present in the wasm.
4. Install the hogdot editor + `tint_convert_cli` (shader baker needs it) and system GL/Vulkan
   libraries (lavapipe).
5. `pin_webgpu_templates.py` → import project (two passes: warm cache, then checked) → export Web
   (`--rendering-method mobile`) → verify artifacts (§2.5) → zip → upload artifact → refresh the
   rolling `web-html5` release. Before packaging, a headless Chrome smoke step reports console
   errors but has `continue-on-error: true`; green CI does not establish browser correctness.

### Local equivalents

```bash
# Import + probe (needs Godot 4.7)
godot --headless --path . --import
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/gdscript_probe.tscn

# Self-tests (same shape)
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/gdr_selftest.tscn
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/native_color_selftest.tscn
xvfb-run -a godot --path . --rendering-method gl_compatibility --audio-driver Dummy \
  res://tools/runtime_visual_smoke_test.tscn
```

## 6. Platform-specific code to respect

| Concern | Where |
| --- | --- |
| Web feature checks | `OS.has_feature("web")` in `Config`, `WorldEnvironment`, `UpdateManager`, `WebSoftEffects`, `NativeCore`, `RobTopLevels` |
| Android file picking | `LevelPanelLoader._import_level_from_android_picker`, `ReplayPanelLoader._import_replay_from_android_picker` |
| Touch controls | `src/TouchScreenControls.gd`, `Config.touch_screen_mode`/`is_touch_screen` |
| Memory diagnostics | `GameScene._print_process_memory` (`/proc/self/status`) |
| Threading model | `project.godot [rendering] driver/threads/thread_model = 0` (Safe) |
| Detection of the local dev server | `RobTopLevels._served_from_dev_server()` |

## 7. Release hygiene

- Rolling pre-releases `android-debug` and `web-html5` carry the newest build at stable URLs;
  stable releases come from `release*` tags (with generated release notes).
- The public project page/releases live on Codeberg; GitHub Actions publishes the CI artifacts.
- The web zip is named `godot-dash-web-html5-<sha>.zip` and documented as "unzip and host on any
  static hosting".
