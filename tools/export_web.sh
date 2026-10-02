#!/usr/bin/env bash
set -euo pipefail

# Exports the Godot project for the Web (HTML5) platform.
# Options configured in export_presets.cfg:
#   - Multi-threading enabled (variant/thread_support=true)
#   - PWA Cross-Origin Isolation headers enabled
#   - Compatibility renderer on web (project.godot: renderer/rendering_method.web="gl_compatibility")
#
# Online level/music downloads need a CORS relay when the build is hosted
# somewhere other than localhost: see the "Web (HTML5) builds" section of the
# README, tools/web_relay_worker.js (deployable Cloudflare Worker) and
# tools/serve_web.py (local server with the same relay on /cors-proxy).
#
# Usage: ./tools/export_web.sh [godot_binary] [output_dir]

GODOT_BIN="${1:-godot}"
OUTPUT_DIR="${2:-export/Web}"
OUTPUT_HTML="${OUTPUT_DIR}/index.html"

mkdir -p "$OUTPUT_DIR"

echo "=== Exporting Godot Dash Web HTML5 Build ==="
echo "Godot binary : $GODOT_BIN"
echo "Output HTML  : $OUTPUT_HTML"

"$GODOT_BIN" --headless --export-release "Web" "$OUTPUT_HTML" || \
"$GODOT_BIN" --headless --export-debug "Web" "$OUTPUT_HTML"

echo "=== Export complete ==="
ls -lh "$OUTPUT_DIR"
