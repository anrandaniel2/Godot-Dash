#!/usr/bin/env python3
"""Windows CI orchestration. Downloads/build outputs live outside source control."""
import argparse
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile

from pin_windows_extension import DLL, check_pe, pin

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = os.environ.get("GODOT_VERSION", "4.7.2")
CACHE = pathlib.Path(os.environ.get("RUNNER_TEMP", os.environ.get("TEMP", "."))) / "godot-windows"
LOGS = ROOT / "export/windows-logs"
OUTPUT = ROOT / "export/Windows"
EDITOR = CACHE / "editor" / f"Godot_v{VERSION}-stable_win64_console.exe"


def run(args: list[str], name: str, timeout: int = 600, allow_failure: bool = False) -> str:
    LOGS.mkdir(parents=True, exist_ok=True)
    log = LOGS / f"{name}.log"
    print(f"Running {name}", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        try:
            result = subprocess.run([str(arg) for arg in args], cwd=ROOT, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            result = subprocess.CompletedProcess(args, 124)
    text = log.read_text(encoding="utf-8", errors="replace")
    print("\n".join(text.splitlines()[-35:]), flush=True)
    if result.returncode and not allow_failure:
        check_log(text, name)
        errors = [line for line in text.splitlines() if re.search(r"error|fatal|failed|exception|_FAIL\b", line, re.I)]
        excerpt = "\n".join(errors[-12:] or text.splitlines()[-20:])[-12000:]
        escaped = excerpt.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title={name}::{escaped}", flush=True)
        raise RuntimeError(f"{name}: exit {result.returncode}; see {log}")
    return text


def check_log(text: str, stage: str = "runtime", include_runtime: bool = True) -> None:
    lines = text.splitlines()
    contexts = []
    markers = ("Parse Error", "Failed to load script", "SCRIPT ERROR") if include_runtime else ("Parse Error", "Failed to load script")
    for index, line in enumerate(lines):
        if any(marker in line for marker in markers):
            contexts.extend(lines[max(0, index - 1):index + 9])
    if contexts:
        excerpt = "\n".join(contexts[:70])[:14000]
        escaped = excerpt.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title={stage} script errors::{escaped}", flush=True)
        raise RuntimeError(f"Script errors in {stage}; see the annotated stack traces")


def download(url: str, path: pathlib.Path) -> None:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".download")
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(path)


def install() -> None:
    archive = CACHE / "editor.zip"
    download(f"https://github.com/godotengine/godot-builds/releases/download/{VERSION}-stable/Godot_v{VERSION}-stable_win64.exe.zip", archive)
    with zipfile.ZipFile(archive) as source:
        source.extractall(CACHE / "editor")
    if not EDITOR.is_file():
        raise RuntimeError(f"Missing {EDITOR}")
    templates = CACHE / "templates.tpz"
    download(f"https://github.com/godotengine/godot/releases/download/{VERSION}-stable/Godot_v{VERSION}-stable_export_templates.tpz", templates)
    destination = pathlib.Path(os.environ["APPDATA"]) / "Godot/export_templates" / f"{VERSION}.stable"
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(templates) as source:
        for target in ("debug", "release"):
            name = f"windows_{target}_x86_64.exe"
            (destination / name).write_bytes(source.read(f"templates/{name}"))
    run([EDITOR, "--version"], "version")


def benchmark() -> None:
    project = CACHE / "channel-index-benchmark"
    shutil.copytree(ROOT / "tools/benchmarks/channel_index", project, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".gdignore", ".godot"))
    run([EDITOR, "--headless", "--path", project, "--editor", "--import"], "benchmark-import")
    for algorithm in ("parity", "old", "new"):
        text = run([EDITOR, "--headless", "--path", project, "--", f"--algorithm={algorithm}"],
                   f"benchmark-{algorithm}", timeout=300)
        check_log(text, f"benchmark-{algorithm}")
        expected = "CHANNEL_INDEX_PARITY result=PASS" if algorithm == "parity" else f"CHANNEL_INDEX_BENCH algorithm={algorithm}"
        if expected not in text:
            raise RuntimeError(f"Missing benchmark marker: {expected}")
        for line in text.splitlines():
            if line.startswith("CHANNEL_INDEX_"):
                print(f"::notice title=channel index::{line}")


def safety() -> None:
    project = CACHE / "runtime-safety"
    shutil.copytree(ROOT / "tools/benchmarks/runtime_safety", project, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".gdignore", ".godot"))
    for path in ("src/static/FramePacingPolicy.gd", "src/static/RenderTimingRequests.gd",
                 "src/refcounted/Selection.gd", "src/BlurBackBuffer.gd",
                 "src/static/NativeDownloadPolicy.gd", "src/static/WindowsUpdatePolicy.gd",
                 "src/static/DisplayPacingState.gd"):
        shutil.copy2(ROOT / path, project)
    imported = run([EDITOR, "--headless", "--path", project, "--editor", "--import"], "safety-import")
    check_log(imported, "safety-import")
    text = run([EDITOR, "--headless", "--path", project], "runtime-safety", timeout=300)
    check_log(text, "runtime-safety")
    if not re.search(r"RUNTIME_SAFETY_SUMMARY checks=\d+ failed=0", text):
        raise RuntimeError("Runtime safety tests did not complete cleanly")
    for line in text.splitlines():
        if line.startswith(("RUNTIME_SAFETY_", "SELECTION_BENCH")):
            print(f"::notice title=runtime safety::{line}")


def build() -> None:
    run([sys.executable, "-m", "SCons", "-C", ROOT / "native", "platform=windows",
         "target=template_release", "arch=x86_64", "api_version=4.7", "use_static_cpp=yes",
         "optimize=speed", "lto=full", "dev_build=no", "debug_symbols=no", "-j4"], "native-build", timeout=1800)
    check_pe(ROOT / "native/bin/windows" / DLL)
    run([sys.executable, "-m", "SCons", "-f", ROOT / "tools/benchmarks/renderer_cache/SConstruct",
         f"output={CACHE / 'renderer-cache'}"], "renderer-cache-build")
    text = run([CACHE / "renderer-cache/visibility-test.exe", "--benchmark"], "renderer-cache")
    if not re.search(r"DECORATION_CACHE_SUMMARY checks=\d+ failed=0", text):
        raise RuntimeError("Decoration cache parity tests did not pass")
    for line in text.splitlines():
        if line.startswith(("DECORATION_CACHE_", "DECORATION_INDEX_")):
            print(f"::notice title=decoration cache::{line}")
    text = run([CACHE / "renderer-cache/ui-alignment-test.exe"], "ui-alignment")
    if "ALL UI TRIGGER TESTS PASSED" not in text:
        raise RuntimeError("Production UI alignment math failed")
    print("::notice title=UI alignment::Production UI alignment math passed (including Relative with every reference).")


def headless_project(text: str) -> str:
    # script-ide accesses a ScriptEditor tab in _enter_tree; that UI does not
    # exist in a headless exporter. It is already excluded from the package.
    # Disable only this editor plugin in CI, not game autoloads or rendering.
    return text.replace('"res://addons/script-ide/plugin.cfg", ', '', 1)


def windows_project(text: str, sha: str, build_number: str, branch: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or not build_number.isdecimal():
        raise ValueError("Invalid Windows build identity")
    channel = "windows-" + re.sub(r"[^A-Za-z0-9._-]", "-", branch)
    metadata = (f'config/windows_build_sha="{sha}"\n'
                f'config/windows_build_number={int(build_number)}\n'
                f'config/windows_update_channel="{channel}"\n')
    return headless_project(text).replace("[application]\n", "[application]\n" + metadata, 1)


def needs_asset_import_retry(text: str) -> bool:
    # A tracked .import can point at an as-yet unbuilt font/texture cache when
    # the project theme is loaded before the editor's first filesystem scan.
    # Retry only importable sources that actually exist; never suppress errors.
    pattern = r"Parse Error: \[ext_resource\] referenced non-existent resource at: (res://[^\r\n]+?)\.\s*$"
    for resource in re.findall(pattern, text, re.MULTILINE):
        source = (ROOT / resource.removeprefix("res://")).resolve()
        if source.is_relative_to(ROOT.resolve()) and source.is_file() and pathlib.Path(str(source) + ".import").is_file():
            return True
    return False


def export() -> None:
    # Only the ICO is LFS-tracked, and its object is unavailable on the mirror.
    # Generate a real Windows icon from the existing artwork, only in CI.
    icon = ROOT / "assets/logo/logo.ico"
    if icon.read_bytes().startswith(b"version https://git-lfs.github.com/spec/v1"):
        from PIL import Image
        with Image.open(ROOT / "assets/logo/logo.png") as image:
            image.save(icon, format="ICO", sizes=[(n, n) for n in (16, 32, 48, 64, 128, 256)])
    project = ROOT / "project.godot"
    project.write_text(windows_project(project.read_text(encoding="utf-8"),
        os.environ["GITHUB_SHA"], os.environ["GITHUB_RUN_NUMBER"], os.environ["GITHUB_REF_NAME"]), encoding="utf-8")
    pin(ROOT)
    # Prevent Godot from scanning a build-time dependency clone.
    (ROOT / "native/godot-cpp/.gdignore").touch()
    run([EDITOR, "--headless", "--path", ROOT, "--editor", "--import"], "import-warm", allow_failure=True)
    imported = run([EDITOR, "--headless", "--path", ROOT, "--editor", "--import"], "import-checked")
    if needs_asset_import_retry(imported):
        print("::notice title=asset import::Retrying one editor pass after a missing generated asset cache; final parse gate remains strict.")
        imported = run([EDITOR, "--headless", "--path", ROOT, "--editor", "--import"], "import-rechecked")
    # Match web CI: editor-only plugin runtime messages are not game failures.
    check_log(imported, "import-checked", include_runtime=False)
    text = run([EDITOR, "--headless", "--path", ROOT, "res://tools/renderer_cache_selftest.tscn"],
               "renderer-integration", timeout=120)
    check_log(text, "renderer-integration")
    if not re.search(r"RENDERER_CACHE_SELFTEST checks=\d+ failed=0", text):
        raise RuntimeError("Native renderer cache integration failed")
    for line in text.splitlines():
        if line.startswith(("RENDERER_CACHE_SELFTEST", "RENDERER_CACHE_NOTE", "BATCH_CALLBACK_BENCH", "RENDERER_COALESCE")):
            print(f"::notice title=renderer integration::{line}")
    text = run([EDITOR, "--headless", "--path", ROOT, "res://tools/gameplay_presentation_selftest.tscn"],
               "gameplay-presentation", timeout=120)
    check_log(text, "gameplay-presentation")
    if not re.search(r"PRESENTATION_SELFTEST checks=\d+ failed=0", text):
        raise RuntimeError("Gameplay/presentation regressions failed")
    for line in text.splitlines():
        if line.startswith("PRESENTATION_SELFTEST"):
            print(f"::notice title=gameplay presentation::{line}")
    text = run([EDITOR, "--headless", "--path", ROOT, "res://tools/color_refresh_selftest.tscn"],
               "color-refresh", timeout=120)
    check_log(text, "color-refresh")
    if not re.search(r"COLOR_REFRESH_SELFTEST checks=\d+ failed=0", text):
        raise RuntimeError("Channel refresh parity failed")
    for line in text.splitlines():
        if line.startswith(("COLOR_REFRESH_SELFTEST", "COLOR_REFRESH_BENCH")):
            print(f"::notice title=color refresh::{line}")
    text = run([EDITOR, "--headless", "--path", ROOT, "res://tools/monster_timeline_selftest.tscn"],
               "monster-timeline", timeout=120)
    check_log(text, "monster-timeline")
    if not re.search(r"MONSTER_TIMELINE_SELFTEST checks=\d+ failed=0", text):
        raise RuntimeError("Native monster timeline parity failed")
    for line in text.splitlines():
        if line.startswith(("MONSTER_TIMELINE_SELFTEST", "MONSTER_TIMELINE_BENCH")):
            print(f"::notice title=monster timeline::{line}")
    text = run([EDITOR, "--headless", "--path", ROOT, "res://tools/packed_trigger_origin_selftest.tscn"],
               "packed-trigger", timeout=120)
    check_log(text, "packed-trigger")
    if not re.search(r"PACKED_TRIGGER_SELFTEST_SUMMARY.*failed=0", text):
        raise RuntimeError("Packed trigger origin/schema parity failed")
    for line in text.splitlines():
        if line.startswith("PACKED_TRIGGER_SELFTEST_SUMMARY"):
            print(f"::notice title=packed triggers::{line}")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    text = run([EDITOR, "--headless", "--path", ROOT, "--rendering-method", "forward_plus",
                "--export-release", "Windows Desktop", OUTPUT / "Godot Dash.exe"], "export", timeout=1200)
    check_log(text, "export")
    check_pe(OUTPUT / "Godot Dash.exe")
    if not (OUTPUT / "Godot Dash.pck").is_file():
        raise RuntimeError("Exported PCK is missing")
    libraries = list(OUTPUT.rglob(DLL))
    if len(libraries) != 1:
        raise RuntimeError(f"Expected one exported native DLL, found {libraries}")
    check_pe(libraries[0])
    smoke = run([OUTPUT / "Godot Dash.exe", "--headless", "--audio-driver", "Dummy", "--", "--native-smoke"],
                "exported-native-smoke", timeout=120)
    check_log(smoke, "exported-native-smoke")
    if "WINDOWS_NATIVE_SMOKE result=PASS configured_renderer=forward_plus" not in smoke:
        raise RuntimeError("Exported native smoke did not pass")
    print("::notice title=Windows smoke::Exported x86-64 EXE loaded the native DLL; configured renderer is Forward+. Headless test only.")
    for name in ("Profile-Windows.ps1", "README-Windows.txt"):
        shutil.copy2(ROOT / "tools/windows" / name, OUTPUT)
    sha = os.environ.get("GITHUB_SHA", "local")
    url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    (OUTPUT / "BUILD.txt").write_text(f"Commit: {sha}\nGodot: {VERSION}\nRenderer: Forward+ (Windows override)\nNative: {DLL}\nRun: {url}\n", encoding="utf-8")
    for name in ("runtime-safety", "renderer-cache", "renderer-integration", "ui-alignment", "gameplay-presentation", "color-refresh", "monster-timeline", "packed-trigger"):
        shutil.copy2(LOGS / f"{name}.log", OUTPUT)
    shutil.make_archive(str(ROOT / "export/godot-dash-windows-x86_64"), "zip", OUTPUT)
    print("Windows ZIP packaged; headless smoke is not a GPU/visual test.")


def installer() -> None:
    compiler = shutil.which("ISCC") or str(pathlib.Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Inno Setup 6/ISCC.exe")
    if not pathlib.Path(compiler).is_file():
        raise RuntimeError("Inno Setup 6 compiler is missing from this Windows runner")
    number = int(os.environ["GITHUB_RUN_NUMBER"])
    sha = os.environ["GITHUB_SHA"][:8]
    script = ROOT / "tools/windows/GodotDash.iss"

    def compile_setup(destination: pathlib.Path, version: int) -> pathlib.Path:
        destination.mkdir(parents=True, exist_ok=True)
        run([compiler, f"/DPayloadDir={OUTPUT}", f"/DBuildVersion=1.0.{version}",
             f"/DBuildId={sha}", f"/O{destination}", script], f"installer-compile-{version}")
        exe = destination / "GodotDashSetup-x86_64.exe"
        check_pe(exe, (0x14C, 0x8664))  # Inno's bootstrapper is x86; payload remains x86-64.
        return exe

    published = compile_setup(ROOT / "export", number)
    upgrade = compile_setup(CACHE / "installer-upgrade", number + 1)
    installed = CACHE / "Installed Godot Dash"
    user_data = pathlib.Path(os.environ["APPDATA"]) / "godot-dash"
    sentinel = user_data / "ci-upgrade-proof/levels/example.bin"
    sentinel.parent.mkdir(parents=True, exist_ok=True)
    sentinel.write_bytes(b"user-created level: must survive install, upgrade and uninstall")
    def snapshot() -> dict[str, str]:
        return {str(p.relative_to(user_data)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in user_data.rglob("*") if p.is_file()}
    before = snapshot()  # Includes config.cfg written by the exported native smoke.
    assert "config.cfg" in before
    for label, setup in (("first", published), ("upgrade", upgrade)):
        args = [setup, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-",
                "/TASKS=", f"/LOG={LOGS / ('setup-' + label + '.log')}"]
        if label == "first":
            args.append(f"/DIR={installed}")
        # No /DIR for the upgrade: proves stable AppId reuses the registered path.
        run(args, "installer-" + label)
        if not (installed / "Godot Dash.exe").is_file() or snapshot() != before:
            raise RuntimeError(f"{label} changed user data or used the wrong install location")
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\GodotDash_is1",
            0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
            registered = pathlib.Path(winreg.QueryValueEx(key, "InstallLocation")[0])
            version = winreg.QueryValueEx(key, "DisplayVersion")[0]
            assert registered == installed
            assert version == f"1.0.{number if label == 'first' else number + 1}"
    smoke = run([installed / "Godot Dash.exe", "--headless", "--audio-driver", "Dummy", "--", "--native-smoke"],
                "installed-native-smoke", timeout=120)
    check_log(smoke, "installed-native-smoke")
    if "WINDOWS_NATIVE_SMOKE result=PASS" not in smoke:
        raise RuntimeError("Installed app failed native smoke")
    before = snapshot()
    run([installed / "unins000.exe", "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"], "installer-uninstall")
    if snapshot() != before:
        raise RuntimeError("Uninstall modified user data")
    print("::notice title=Installer upgrade::Install -> newer version in the same path -> installed native smoke -> uninstall PASS; user data hashes preserved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("install", "benchmark", "safety", "build", "export", "installer"))
    stage = parser.parse_args().stage
    try:
        {"install": install, "benchmark": benchmark, "safety": safety, "build": build, "export": export, "installer": installer}[stage]()
    except Exception as error:
        message = str(error).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=Windows {stage}::{message}", flush=True)
        raise
