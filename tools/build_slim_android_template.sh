#!/usr/bin/env bash
# Build a Godot 4.7.2 arm64 release libgodot and splice it into the official
# Android export template. Official Java/Gradle/Swappy packaging is kept.
# Speed is not traded for size: production=yes, and Android forces lto=auto
# to none. Swappy must be linked or the script refuses to emit a template.
set -euo pipefail

GODOT_SRC="${GODOT_SRC:-godot-src}"
TEMPLATE_OUT="${TEMPLATE_OUT:-android-template-cache}"
GODOT_VERSION="${GODOT_VERSION:-4.7.2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TPZ_DIR="${TPZ_DIR:-$HOME/.local/share/godot/export_templates/${GODOT_VERSION}.stable}"
if [ ! -f "$TPZ_DIR/android_source.zip" ] || [ ! -f "$TPZ_DIR/android_release.apk" ]; then
  echo "official Android templates missing in $TPZ_DIR"
  ls -la "$TPZ_DIR" || true
  exit 1
fi
if [ ! -d "$GODOT_SRC/platform/android" ]; then
  echo "Godot source missing at $GODOT_SRC"
  exit 1
fi

if [ -d /usr/share/dotnet ]; then
  sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/share/boost /usr/share/swift || true
fi
df -h /

export ANDROID_HOME="${ANDROID_HOME:?ANDROID_HOME is required}"
SDKMANAGER="$(command -v sdkmanager || echo "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager")"
if [ ! -x "$SDKMANAGER" ]; then
  echo "sdkmanager not found at $SDKMANAGER"
  exit 1
fi

# platform/android/detect.py in 4.7.2 pins this NDK.
GODOT_NDK_VERSION="29.0.14206865"
if [ ! -d "$ANDROID_HOME/ndk/$GODOT_NDK_VERSION" ]; then
  yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" "ndk;$GODOT_NDK_VERSION"
fi
test -d "$ANDROID_HOME/ndk/$GODOT_NDK_VERSION"

export PATH="$HOME/.local/bin:$PATH"
cp "$ROOT/tools/godot_android_custom.py" "$GODOT_SRC/custom.py"
# The Swappy installer extracts relative to the current directory.
cd "$GODOT_SRC"
python3 misc/scripts/install_swappy_android.py
test -f thirdparty/swappy-frame-pacing/arm64-v8a/libswappy_static.a
# No generate_android_binaries: that Gradle task rebuilds every ABI. The
# official template already has the Java project; only the arm64 .so changes.
if ! scons platform=android target=template_release arch=arm64 \
    swappy=yes production=yes optimize=speed debug_symbols=no \
    -j"$(nproc)" > /tmp/scons_godot_android.log 2>&1; then
  echo "slim libgodot build failed; tail:"
  tail -n 80 /tmp/scons_godot_android.log
  exit 1
fi
tail -n 15 /tmp/scons_godot_android.log
if grep -q "Without Swappy" /tmp/scons_godot_android.log; then
  echo "Swappy was not linked; refusing to ship a stuttering template"
  exit 1
fi

SO="$(pwd)/platform/android/java/lib/libs/release/arm64-v8a/libgodot_android.so"
if [ ! -f "$SO" ]; then
  echo "built library missing; search:"
  find . -name 'libgodot_android.so' -o -name 'libgodot*.so' | head
  exit 1
fi
if ! strings "$SO" | grep -q -i swappy; then
  echo "built libgodot_android.so has no Swappy symbols"
  exit 1
fi
ls -lh "$SO"

cd "$ROOT"
mkdir -p "$TEMPLATE_OUT"
# Gradle export (use_gradle_build) reads android_source.zip, not the prebuilt
# APK. Leave android_release.apk official so its zipalign/signature stays valid.
cp "$TPZ_DIR/android_release.apk" "$TEMPLATE_OUT/android_release.apk"
python3 - "$SO" "$TPZ_DIR/android_source.zip" "$ROOT/$TEMPLATE_OUT/android_source.zip" <<'PY'
import sys, zipfile
from pathlib import Path

blob = Path(sys.argv[1]).read_bytes()
src = Path(sys.argv[2])
dest = Path(sys.argv[3])
tmp = dest.with_suffix(dest.suffix + ".tmp")
replaced = 0
with zipfile.ZipFile(src, "r") as zin, zipfile.ZipFile(tmp, "w") as zout:
    for info in zin.infolist():
        data = zin.read(info.filename)
        name = info.filename.replace("\\", "/")
        if name.endswith("arm64-v8a/libgodot_android.so"):
            data = blob
            replaced += 1
            info.file_size = len(data)
            info.CRC = zipfile.crc32(data) & 0xFFFFFFFF
        zout.writestr(info, data)
if replaced == 0:
    tmp.unlink(missing_ok=True)
    names = []
    with zipfile.ZipFile(src) as zin:
        names = [i.filename for i in zin.infolist() if i.filename.endswith(".so")]
    raise SystemExit("no arm64-v8a/libgodot_android.so in android_source.zip; .so entries:\n" + "\n".join(names[:40]))
tmp.replace(dest)
print(f"replaced {replaced} libgodot_android.so in android_source.zip")
PY
ls -lh "$TEMPLATE_OUT"
echo "slim Android template ready"
