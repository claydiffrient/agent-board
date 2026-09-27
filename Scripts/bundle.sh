#!/usr/bin/env bash
# Wraps the SwiftPM executable in a .app bundle so AppKit gets a bundle id (notifications need one).
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/assemble-app.sh
config="${1:-debug}"
swift build -c "$config" --product AgentBoard
app=".build/AgentBoard.app"
assemble_app "$config" "$app"
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
