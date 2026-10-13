#!/usr/bin/env python3
"""Windows CI orchestration. Downloads/build outputs live outside source control."""
import argparse
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
        result = subprocess.run([str(arg) for arg in args], cwd=ROOT, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(encoding="utf-8", errors="replace")
    print("\n".join(text.splitlines()[-35:]), flush=True)
    if result.returncode and not allow_failure:
        errors = [line for line in text.splitlines() if re.search(r"error|fatal|failed|exception", line, re.I)]
        excerpt = "\n".join(errors[-12:] or text.splitlines()[-20:])[-12000:]
        escaped = excerpt.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title={name}::{escaped}", flush=True)
        raise RuntimeError(f"{name}: exit {result.returncode}; see {log}")
    return text


def check_log(text: str, stage: str = "runtime") -> None:
    lines = text.splitlines()
    contexts = []
    for index, line in enumerate(lines):
        if any(marker in line for marker in ("Parse Error", "Failed to load script", "SCRIPT ERROR")):
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


def build() -> None:
    run([sys.executable, "-m", "SCons", "-C", ROOT / "native", "platform=windows",
         "target=template_release", "arch=x86_64", "api_version=4.7", "use_static_cpp=yes",
         "optimize=speed", "debug_symbols=no", "-j4"], "native-build", timeout=1800)
    check_pe(ROOT / "native/bin/windows" / DLL)


def export() -> None:
    # Only the ICO is LFS-tracked, and its object is unavailable on the mirror.
    # Generate a real Windows icon from the existing artwork, only in CI.
    icon = ROOT / "assets/logo/logo.ico"
    if icon.read_bytes().startswith(b"version https://git-lfs.github.com/spec/v1"):
        from PIL import Image
        with Image.open(ROOT / "assets/logo/logo.png") as image:
            image.save(icon, format="ICO", sizes=[(n, n) for n in (16, 32, 48, 64, 128, 256)])
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
    check_log(text, "export")
    check_pe(OUTPUT / "godot-dash.exe")
    if not (OUTPUT / "godot-dash.pck").is_file():
        raise RuntimeError("Exported PCK is missing")
    libraries = list(OUTPUT.rglob(DLL))
    if len(libraries) != 1:
        raise RuntimeError(f"Expected one exported native DLL, found {libraries}")
    check_pe(libraries[0])
    smoke = run([OUTPUT / "godot-dash.exe", "--headless", "--audio-driver", "Dummy", "--", "--native-smoke"],
                "exported-native-smoke", timeout=120)
    check_log(smoke, "exported-native-smoke")
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
    try:
        {"install": install, "benchmark": benchmark, "build": build, "export": export}[stage]()
    except Exception as error:
        message = str(error).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error title=Windows {stage}::{message}", flush=True)
        raise
