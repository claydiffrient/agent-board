#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/assemble-app.sh

usage() {
  cat <<'USAGE'
Usage: Scripts/release.sh [--allow-dirty]
       Scripts/release.sh --check <path/to/Agent Board.app>
       Scripts/release.sh --check-structure <path/to/Agent Board.app>

Builds a release-configuration Agent Board.app and packages it as
dist/AgentBoard-<version>.zip, with the unzipped .app beside it.

  - The version is the newest "## <version>" heading in RELEASES.md, stamped into
    the bundle's CFBundleShortVersionString. CFBundleVersion is the number of
    commits reachable from HEAD; AgentBoardCommit is HEAD's sha, suffixed -dirty
    when built with --allow-dirty from a tree with uncommitted changes.
  - arm64 only: the host architecture swift build produces. Not universal.
  - Signed ad hoc unless AGENTBOARD_SIGN_IDENTITY names a codesign identity.
  - The bundle is verified after assembly and again after unzipping the artifact;
    any failed check fails the release.

  --allow-dirty   build even when tracked files have uncommitted changes
  --check APP     run only the bundle checks against APP, expecting the version,
                  build number and commit of the current checkout
  --check-structure APP
                  run the bundle checks against APP without comparing it to the
                  checkout: the plist keys must be present, and the version
                  checked against the bundled RELEASES.md is APP's own
USAGE
}

fail() { echo "release.sh: $*" >&2; exit 1; }

# The first "## " heading, minus any " — YYYY-MM-DD", as ReleaseNotesParser reads it.
newest_version() {
  local heading
  heading=$(grep -m1 -E '^## ' "$1" | sed -E 's/^## +//; s/ (—|–|-) .*$//; s/[[:space:]]+$//; s/^[vV]//') || true
  [[ "$heading" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  echo "$heading"
}

plist_value() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# An empty build or commit means "any non-empty value", for --check-structure.
check_bundle() {
  local app="$1" version="$2" build="$3" commit="$4"
  local resources="$app/Contents/Resources" binary="$app/Contents/MacOS/AgentBoard"
  local problems=() actual bundle name

  if [ ! -f "$binary" ]; then
    problems+=("binary missing: Contents/MacOS/AgentBoard")
  elif [ ! -x "$binary" ]; then
    problems+=("binary not executable: Contents/MacOS/AgentBoard")
  else
    actual=$(lipo -archs "$binary" 2>/dev/null || true)
    [ "$actual" = arm64 ] || problems+=("binary architectures are '$actual', expected 'arm64'")
  fi

  actual=$(plist_value "$app" CFBundleShortVersionString)
  [ "$actual" = "$version" ] || problems+=("Info.plist CFBundleShortVersionString is '$actual', expected '$version'")
  actual=$(plist_value "$app" CFBundleVersion)
  if [ -z "$build" ]; then
    [ -n "$actual" ] || problems+=("Info.plist CFBundleVersion is missing")
  else
    [ "$actual" = "$build" ] || problems+=("Info.plist CFBundleVersion is '$actual', expected '$build'")
  fi
  actual=$(plist_value "$app" AgentBoardCommit)
  if [ -z "$commit" ]; then
    [[ "$actual" =~ ^[0-9a-f]{40}(-dirty)?$ ]] || problems+=("Info.plist AgentBoardCommit is '$actual', expected a commit sha")
  else
    [ "$actual" = "$commit" ] || problems+=("Info.plist AgentBoardCommit is '$actual', expected '$commit'")
  fi

  if [ ! -f "$resources/RELEASES.md" ]; then
    problems+=("missing from Contents/Resources: RELEASES.md")
  else
    actual=$(newest_version "$resources/RELEASES.md" || echo "<unreadable>")
    [ "$actual" = "$version" ] || problems+=("bundled RELEASES.md's newest heading is '$actual', expected '$version'")
  fi
  [ -f "$resources/AppIcon.icns" ] || problems+=("missing from Contents/Resources: AppIcon.icns")
  # Structure mode leaves missing resources to codesign's seal below: which bundles the checkout
  # builds today says nothing about an artifact built from another commit.
  for bundle in .build/release/*.bundle; do
    [ -e "$bundle" ] && [ -n "$build" ] || continue
    name=$(basename "$bundle")
    [ -d "$resources/$name" ] || problems+=("missing from Contents/Resources: $name")
  done

  if ! actual=$(codesign --verify --deep --strict "$app" 2>&1); then
    problems+=("codesign --verify --deep --strict failed: ${actual//$'\n'/ }")
  fi

  if [ ${#problems[@]} -gt 0 ]; then
    echo "release.sh: bundle check FAILED for $app" >&2
    printf '  - %s\n' "${problems[@]}" >&2
    return 1
  fi
  echo "bundle check passed: $app"
}

allow_dirty=false
check_only=""
check_structure=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty) allow_dirty=true ;;
    --check) [ $# -ge 2 ] || fail "--check needs an app path"; check_only="$2"; shift ;;
    --check-structure) [ $# -ge 2 ] || fail "--check-structure needs an app path"; check_structure="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$check_structure" ]; then
  version=$(plist_value "$check_structure" CFBundleShortVersionString)
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "$check_structure: Info.plist CFBundleShortVersionString is '$version', expected a version"
  check_bundle "$check_structure" "$version" "" ""
  exit
fi

version=$(newest_version RELEASES.md) || fail "RELEASES.md's first '## ' heading is not '## <version>'"
build=$(git rev-list --count HEAD)
commit=$(git rev-parse HEAD)
dirty=$(git status --porcelain --untracked-files=no)
[ -z "$dirty" ] || commit="$commit-dirty"

if [ -n "$check_only" ]; then
  check_bundle "$check_only" "$version" "$build" "$commit"
  exit
fi

if [ -n "$dirty" ] && ! $allow_dirty; then
  echo "release.sh: refusing to build: tracked files have uncommitted changes (pass --allow-dirty to override)" >&2
  echo "$dirty" >&2
  exit 1
fi
[ "$(uname -m)" = arm64 ] || fail "this script builds arm64 only; host is $(uname -m)"

identity="${AGENTBOARD_SIGN_IDENTITY:--}"
app="dist/Agent Board.app"
zip="dist/AgentBoard-$version.zip"

swift build -c release --product AgentBoard
mkdir -p dist
assemble_app release "$app"

plist="$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build" "$plist"
plutil -replace AgentBoardCommit -string "$commit" "$plist"

codesign --force --sign "$identity" "$app" || fail "codesign --sign '$identity' failed"
check_bundle "$app" "$version" "$build" "$commit"

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

unzipped=$(mktemp -d)
trap 'rm -rf "$unzipped"' EXIT
ditto -x -k "$zip" "$unzipped"
check_bundle "$unzipped/$(basename "$app")" "$version" "$build" "$commit"

echo
echo "version  $version (build $build, commit $commit)"
if [ "$identity" = - ]; then echo "signed   ad hoc"; else echo "signed   $identity"; fi
echo "app      $app"
echo "artifact $zip ($(du -h "$zip" | cut -f1 | tr -d ' '))"
