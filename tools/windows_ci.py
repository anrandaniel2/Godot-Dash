#!/usr/bin/env python3
"""Windows CI orchestration. Downloads/build outputs live outside source control."""
import argparse
import os
import pathlib
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
        result = subprocess.run([str(arg) for arg in args], cwd=ROOT, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(encoding="utf-8", errors="replace")
    print("\n".join(text.splitlines()[-35:]), flush=True)
    if result.returncode and not allow_failure:
        raise RuntimeError(f"{name}: exit {result.returncode}; see {log}")
    return text


def check_log(text: str) -> None:
    for marker in ("Parse Error", "Failed to load script", "SCRIPT ERROR"):
        if marker in text:
            raise RuntimeError(f"Unexpected {marker} in runtime/export log")


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
    shutil.copy2(ROOT / "src/refcounted/PackedIndexBuilder.gd", project)
    run([EDITOR, "--headless", "--path", project, "--editor", "--import"], "benchmark-import")
    for algorithm in ("parity", "old", "new"):
        text = run([EDITOR, "--headless", "--path", project, "--", f"--algorithm={algorithm}"],
                   f"benchmark-{algorithm}", timeout=300)
        check_log(text)
        expected = "CHANNEL_INDEX_PARITY result=PASS" if algorithm == "parity" else f"CHANNEL_INDEX_BENCH algorithm={algorithm}"
        if expected not in text:
            raise RuntimeError(f"Missing benchmark marker: {expected}")
        for line in text.splitlines():
            if line.startswith("CHANNEL_INDEX_"):
                print(f"::notice title=channel index::{line}")


def build() -> None:
    run([sys.executable, "-m", "SCons", "-C", ROOT / "native", "platform=windows",
         "target=template_release", "arch=x86_64", "api_version=4.7", "use_static_cpp=yes",
         "optimize=speed", "debug_symbols=no", "-j4"], "native-build", timeout=1800)
    check_pe(ROOT / "native/bin/windows" / DLL)


def export() -> None:
    pin(ROOT)
    # Prevent Godot from scanning a build-time dependency clone.
    (ROOT / "native/godot-cpp/.gdignore").touch()
    run([EDITOR, "--headless", "--path", ROOT, "--editor", "--import"], "import-warm", allow_failure=True)
    imported = run([EDITOR, "--headless", "--path", ROOT, "--editor", "--import"], "import-checked")
    # Match web CI: editor-only plugin runtime messages are not game failures.
    if "Parse Error" in imported or "Failed to load script" in imported:
        raise RuntimeError("Project scripts did not compile")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    text = run([EDITOR, "--headless", "--path", ROOT, "--rendering-method", "forward_plus",
                "--export-release", "Windows Desktop", OUTPUT / "godot-dash.exe"], "export", timeout=1200)
    check_log(text)
    check_pe(OUTPUT / "godot-dash.exe")
    if not (OUTPUT / "godot-dash.pck").is_file():
        raise RuntimeError("Exported PCK is missing")
    libraries = list(OUTPUT.rglob(DLL))
    if len(libraries) != 1:
        raise RuntimeError(f"Expected one exported native DLL, found {libraries}")
    check_pe(libraries[0])
    smoke = run([OUTPUT / "godot-dash.exe", "--headless", "--audio-driver", "Dummy", "--", "--native-smoke"],
                "exported-native-smoke", timeout=120)
    check_log(smoke)
    if "WINDOWS_NATIVE_SMOKE result=PASS configured_renderer=forward_plus" not in smoke:
        raise RuntimeError("Exported native smoke did not pass")
    for name in ("Profile-Windows.ps1", "README-Windows.txt"):
        shutil.copy2(ROOT / "tools/windows" / name, OUTPUT)
    sha = os.environ.get("GITHUB_SHA", "local")
    url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    (OUTPUT / "BUILD.txt").write_text(f"Commit: {sha}\nGodot: {VERSION}\nRenderer: Forward+ (Windows override)\nNative: {DLL}\nRun: {url}\n", encoding="utf-8")
    for name in ("benchmark-parity", "benchmark-old", "benchmark-new"):
        shutil.copy2(LOGS / f"{name}.log", OUTPUT)
    shutil.make_archive(str(ROOT / "export/godot-dash-windows-x86_64"), "zip", OUTPUT)
    print("Windows ZIP packaged; headless smoke is not a GPU/visual test.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("install", "benchmark", "build", "export"))
    stage = parser.parse_args().stage
    {"install": install, "benchmark": benchmark, "build": build, "export": export}[stage]()
