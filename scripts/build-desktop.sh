#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/build/Clippy.app"
module_cache="${TMPDIR:-/tmp}/clippy-swift-module-cache"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$module_cache"
architecture="$(uname -m)"
xcrun swiftc -swift-version 5 -O \
  -target "$architecture-apple-macosx14.2" \
  -module-cache-path "$module_cache" \
  -framework AppKit -framework AVFoundation -framework Speech -framework WebKit -framework Carbon \
  "$project_dir/desktop/SelectionSummary.swift" "$project_dir/desktop/DrawingSettings.swift" "$project_dir/desktop/WakeSound.swift" "$project_dir/desktop/ComposerSurface.swift" "$project_dir/desktop/IslandLayout.swift" "$project_dir/desktop/IslandGoo.swift" "$project_dir/desktop/IslandLiquid.swift" "$project_dir/desktop/SelectionEditor.swift" "$project_dir/desktop/main.swift" -o "$app_dir/Contents/MacOS/Clippy"
cp "$project_dir/desktop/Resources/wake-chime.wav" "$project_dir/desktop/Resources/mascot-gpt.png" "$project_dir/desktop/Resources/mascot-claude.png" "$app_dir/Contents/Resources/"
cp "$project_dir/shared/drawing-models.json" "$app_dir/Contents/Resources/"
cp "$project_dir/desktop/Info.plist" "$app_dir/Contents/Info.plist"
python3 - "$project_dir" "$(command -v node)" "$project_dir/node_modules/.bin/codex" "$app_dir/Contents/Resources/runtime.json" "$(command -v claude || true)" <<'PYCONFIG'
import json,sys
with open(sys.argv[4], 'w') as f: json.dump({'project':sys.argv[1], 'node':sys.argv[2], 'codex':sys.argv[3], 'claude':sys.argv[5]},f)
PYCONFIG
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
echo "Built $app_dir (not installed or launched). Open it when ready; it starts its own local server if needed."
