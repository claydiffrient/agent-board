#!/usr/bin/env bash
# Wraps the SwiftPM executable in a .app bundle so AppKit gets a bundle id (notifications need one).
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-debug}"
swift build -c "$config" --product AgentBoard
app=".build/AgentBoard.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/$config/AgentBoard" "$app/Contents/MacOS/AgentBoard"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for bundle in .build/"$config"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
