#!/usr/bin/env python3
"""Fetch and select the pinned Rapier2D PhysicsServer GDExtension.

The upstream binary package is deliberately cached outside source control and
is verified before extraction. Web exports continue to use GodotPhysics2D.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import shutil
import urllib.request
import zipfile

RAPIER_VERSION = "v0.36.0"
RAPIER_ASSET = "godot-rapier-2d-single.zip"
RAPIER_URL = (
    "https://github.com/appsinacup/godot-rapier-physics/releases/download/"
    f"{RAPIER_VERSION}/{RAPIER_ASSET}"
)
RAPIER_SHA256 = "6c2c8ea8ac036ad9698ca511ab0117c873524d08d9f34e25c1873b71accf542a"
ADDON_RELATIVE = pathlib.Path("addons/godot-rapier2d")
ENGINE_NAMES = {"GodotPhysics2D", "Rapier2D"}


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _download_asset(cache_dir: pathlib.Path) -> pathlib.Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    archive = cache_dir / f"rapier-{RAPIER_VERSION}-{RAPIER_ASSET}"
    if archive.is_file() and sha256(archive) == RAPIER_SHA256:
        return archive
    archive.unlink(missing_ok=True)
    temporary = archive.with_suffix(archive.suffix + ".download")
    temporary.unlink(missing_ok=True)
    request = urllib.request.Request(
        RAPIER_URL,
        headers={"User-Agent": "Godot-Dash-Rapier-Build/1"},
    )
    with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output)
    actual = sha256(temporary)
    if actual != RAPIER_SHA256:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(f"Rapier package SHA-256 mismatch: {actual}")
    temporary.replace(archive)
    return archive


def install_addon(project_root: pathlib.Path, cache_dir: pathlib.Path) -> pathlib.Path:
    """Extract only the 2D addon from the pinned upstream release package."""
    project_root = project_root.resolve()
    destination = (project_root / ADDON_RELATIVE).resolve()
    addon_parent = (project_root / "addons").resolve()
    if not destination.is_relative_to(addon_parent):
        raise RuntimeError("Rapier addon destination escaped the project addons folder")

    archive = _download_asset(cache_dir)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)
    extracted = 0
    expected_prefix = ("addons", "godot-rapier2d")
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            parts = pathlib.PurePosixPath(member.filename).parts
            marker = next(
                (index for index in range(len(parts) - 1)
                 if parts[index:index + 2] == expected_prefix),
                None,
            )
            if marker is None:
                continue
            relative = pathlib.Path(*parts[marker + 2:])
            target = (destination / relative).resolve()
            if not target.is_relative_to(destination):
                raise RuntimeError(f"Unsafe path in Rapier package: {member.filename}")
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with package.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            extracted += 1

    extension = destination / "godot-rapier2d.gdextension"
    if not extension.is_file():
        shutil.rmtree(destination, ignore_errors=True)
        raise RuntimeError("Pinned Rapier release has no 2D GDExtension manifest")
    manifest = extension.read_text(encoding="utf-8")
    if 'compatibility_minimum = "4.7"' not in manifest:
        shutil.rmtree(destination, ignore_errors=True)
        raise RuntimeError("Rapier GDExtension is not pinned to the expected Godot 4.7 API")
    if extracted == 0:
        shutil.rmtree(destination, ignore_errors=True)
        raise RuntimeError("No Rapier addon files were extracted")
    return destination


def set_physics_engine(project_file: pathlib.Path, engine: str) -> None:
    if engine not in ENGINE_NAMES:
        raise ValueError(f"Unsupported 2D physics engine: {engine}")
    text = project_file.read_text(encoding="utf-8")
    lines = text.splitlines()
    in_physics = False
    found_section = False
    found_setting = False
    output: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_physics and not found_setting:
                output.append(f'2d/physics_engine="{engine}"')
                found_setting = True
            in_physics = stripped == "[physics]"
            found_section = found_section or in_physics
        if in_physics and stripped.startswith("2d/physics_engine="):
            output.append(f'2d/physics_engine="{engine}"')
            found_setting = True
        else:
            output.append(line)
    if in_physics and not found_setting:
        output.append(f'2d/physics_engine="{engine}"')
        found_setting = True
    if not found_section:
        if output and output[-1] != "":
            output.append("")
        output.extend(("[physics]", f'2d/physics_engine="{engine}"'))
    project_file.write_text("\n".join(output) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument(
        "--cache-dir",
        type=pathlib.Path,
        default=pathlib.Path(
            os.environ.get("RUNNER_TEMP", str(pathlib.Path.home() / ".cache"))
        )
        / "godot-dash-rapier",
    )
    parser.add_argument("--engine", choices=sorted(ENGINE_NAMES), default="Rapier2D")
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    addon = install_addon(project_root, args.cache_dir.resolve())
    set_physics_engine(project_root / "project.godot", args.engine)
    print(f"Installed Rapier {RAPIER_VERSION} at {addon}")
    print(f"Selected PhysicsServer2D backend: {args.engine}")


if __name__ == "__main__":
    main()
