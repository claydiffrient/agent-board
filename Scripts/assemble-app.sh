# Sourced by bundle.sh and release.sh so both lay out the .app identically.
assemble_app() {
  local config="$1" app="$2"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp ".build/$config/AgentBoard" "$app/Contents/MacOS/AgentBoard"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  cp RELEASES.md "$app/Contents/Resources/RELEASES.md"
  for bundle in .build/"$config"/*.bundle; do
    if [ -e "$bundle" ]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
  done
}
