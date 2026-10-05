# 07 — Platforms: web (WebGPU), Android, desktop, and CI

## 1. Export presets (`export_presets.cfg`, gitignored but tracked)

| # | Name | Platform | Notes |
| --- | --- | --- | --- |
| 0 | Windows Desktop | Windows | default template fields |
| 1 | Linux/X11 | Linux | |
| 2 | Android | Android | Gradle build, arm64-v8a only, native libs compressed |
| 3 | Web | Web | WebGPU (Mobile renderer), threads, extensions, shader baker |

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
   driver). `rendering_method.web = "mobile"`; if it were `gl_compatibility` the exporter would
   emit a WebGL build, which is explicitly not the shipping target.
2. **Templates**: the published hogdot web zips strip `Line2D`, physics shapes, MP3 and zip, so
   **CI compiles an unstripped threaded dlink template** from the same `HOGDOT_COMMIT`:

   ```bash
   cd hogdot-src
   scons platform=web target=template_release arch=wasm32 \
     webgpu=yes vulkan=no opengl3=no \
     production=yes optimize=speed threads=yes dlink_enabled=yes \
     initial_memory=256 -j"$(nproc)"
   ```

   then asserts the zip's wasm still contains `Line2D`. `tools/pin_webgpu_templates.py` writes
   the built zip paths into the Web preset's `custom_template/debug|release` fields (pointing
   debug at the same zip so a missing debug template cannot fail the preset).
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
   `index.wasm`, `index.side.wasm`, and `libgdash_native.web.template_release.wasm32.wasm`;
   `index.html` must mention `webgpu`; `index.side.wasm` must contain `Line2D`,
   `CircleShape2D` and `AudioStreamMP3`. A multi-thread export also emits worker/service-worker
   files.
6. **Browser support**: WebGPU browser (Chrome 113+, Edge, Firefox with WebGPU, Safari 18+),
   HTTPS (or localhost). It draws at browser resolution.
7. **Web-specific runtime behaviour**:
   - `WorldEnvironment` disables `Environment.glow` on web. Do **not** re-render the 2D world
     into a second SubViewport for bloom: sharing `world_2d` is a second full canvas pass and
     dropped OuterSpace to ~20 fps on WebGPU. `WebSoftEffects` is frost-only (title + pause).
     `SimpleBlurMaterial.tres` **ships** `BackgroundBlurWeb.gdshader` (no `hint_screen_texture`)
     so the shader baker cannot keep the desktop screen-copy pipeline; desktop swaps back in
     `Config._init`. Frost is half-res + separable 9-tap. Sawblade `FadeEnterEffect` uses
     `FadeEnterEffectWeb.gdshader` on web for the same reason. Root `use_hdr_2d` is off;
     `Engine.max_physics_steps_per_frame` is 4.
   - Frame pacing: `Config.apply_frame_pacing()` **always** sets `Engine.max_fps = 0` on web
     (also in `_init`). Threaded hogdot (`PROXY_TO_PTHREAD`) calls `OS::add_frame_delay`; any
     cap sleeps on a ~16 ms timer. rAF is the vsync. Console: `[gdash] build=web-frost-v2`
     and `[gdash] web pacing max_fps=0 hdr_2d=false`.
   - `html/head_include` wraps `navigator.gpu.requestAdapter` with `powerPreference:
     'high-performance'`. **Chrome on Windows ignores that hint** and always uses GPU 0
     (usually the iGPU) — crbug 369219127. An AMD CPU + Intel dGPU therefore logs
     `adapter=amd/rdna-2` until the user sets chrome.exe to High performance in Windows
     Graphics settings or enables `chrome://flags/#force-high-performance-gpu`. Keep
     `rendering_method.web = mobile` (WebGPU); do not fall back to `gl_compatibility`.
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

### `.github/workflows/web.yml` — "web-export"

1. Check the CORS relay Worker (`web_relay_worker_selftest.mjs`).
2. Install scons + Emscripten; build `gdash_native` for wasm32 (threads).
3. Download/cache the hogdot editor; build/caches the **unstripped threaded WebGPU template**;
   assert `Line2D` is present in the wasm.
4. Install the hogdot editor + `tint_convert_cli` (shader baker needs it) and system GL/Vulkan
   libraries (lavapipe).
5. `pin_webgpu_templates.py` → import project (two passes: warm cache, then checked) → export Web
   (`--rendering-method mobile`) → verify artifacts (§2.5) → zip → upload artifact → refresh the
   rolling `web-html5` release.

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
