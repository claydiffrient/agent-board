#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: Scripts/cut-release.sh preflight [<version>]
       Scripts/cut-release.sh build [release.sh options...]

The mechanical halves of /cut-release (.claude/skills/cut-release/SKILL.md).

  preflight   Fetches origin, then refuses unless no tracked file has changes and
              HEAD is origin/main. Prints RELEASES.md's newest version, the commit
              that added its heading, the version to cut (<version>, or the next
              minor when omitted), and the first-parent commits on origin/main
              since that cut. Refuses a <version> not newer than the newest heading.
  build       Fetches origin, then refuses unless origin/main has the commit that
              added RELEASES.md's newest heading and HEAD contains it, and unless
              that version is newer than the installed app's
              CFBundleShortVersionString. Prints the install path it's taking, then
              runs Scripts/release.sh with the given options. The installed app is
              /Applications/Agent Board.app unless AGENTBOARD_INSTALLED_APP names
              another; with none installed there is nothing to compare, and it builds.
USAGE
}

fail() { echo "cut-release.sh: $*" >&2; exit 1; }

# Same parse as release.sh's newest_version.
newest_version() {
  local heading
  heading=$(grep -m1 -E '^## ' "$1" | sed -E 's/^## +//; s/ (—|–|-) .*$//; s/[[:space:]]+$//; s/^[vV]//') || true
  [[ "$heading" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  echo "$heading"
}

# Missing segments count as 0, so 0.3 and 0.3.0 are the same version.
segments() {
  local IFS=. major minor patch
  read -r major minor patch <<<"$1"
  echo "$((10#${major:-0})) $((10#${minor:-0})) $((10#${patch:-0}))"
}

newer_than() {
  local a1 a2 a3 b1 b2 b3
  read -r a1 a2 a3 <<<"$(segments "$1")"
  read -r b1 b2 b3 <<<"$(segments "$2")"
  ((a1 != b1)) && { ((a1 > b1)); return; }
  ((a2 != b2)) && { ((a2 > b2)); return; }
  ((a3 > b3))
}

# The commit on origin/main that added the heading for version $1.
cut_commit() {
  git log -n1 --format=%H -S"## $1" origin/main -- RELEASES.md
}

preflight() {
  [ $# -le 1 ] || { usage >&2; exit 2; }

  git fetch origin --quiet || fail "git fetch origin failed"
  local dirty head main
  dirty=$(git status --porcelain --untracked-files=no)
  [ -z "$dirty" ] || fail "tracked files have uncommitted changes:
$dirty"
  head=$(git rev-parse HEAD)
  main=$(git rev-parse origin/main)
  if [ "$head" != "$main" ]; then
    if git merge-base --is-ancestor HEAD origin/main; then
      fail "HEAD ($(git rev-parse --short HEAD)) is behind origin/main ($(git rev-parse --short origin/main)); run: git merge --ff-only origin/main"
    fi
    fail "HEAD ($(git rev-parse --short HEAD)) is not origin/main ($(git rev-parse --short origin/main)); cut from origin/main, or from a branch created from it with no commits of its own"
  fi

  local last cut next how
  last=$(newest_version RELEASES.md) || fail "RELEASES.md's first '## ' heading is not '## <version>'"
  cut=$(cut_commit "$last")
  [ -n "$cut" ] || fail "no commit on origin/main adds the heading '## $last'"

  if [ $# -eq 1 ]; then
    next="${1#v}"
    [[ "$next" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "'$1' is not a version: expected up to three dot-separated integers"
    how="given"
  else
    local major minor _
    read -r major minor _ <<<"$(segments "$last")"
    next="$major.$((minor + 1)).0"
    how="no version given: bumped the minor version of $last"
  fi
  newer_than "$next" "$last" || fail "version $next is not newer than RELEASES.md's newest heading, $last"

  echo "last     $last"
  echo "cut      $(git log -1 --format='%h %s' "$cut")"
  echo "next     $next ($how)"
  echo "since    first-parent commits on origin/main after the cut:"
  git log --first-parent --format='         %h %s' "$cut..origin/main"
}

build() {
  local app="${AGENTBOARD_INSTALLED_APP:-/Applications/Agent Board.app}" newest installed cut
  newest=$(newest_version RELEASES.md) || fail "RELEASES.md's first '## ' heading is not '## <version>'"

  git fetch origin --quiet || fail "git fetch origin failed"
  cut=$(cut_commit "$newest")
  [ -n "$cut" ] || fail "refusing to build: RELEASES.md's newest heading is $newest, but no commit on origin/main adds it. Merge the cut first, then run: git fetch origin && git merge --ff-only origin/main"
  git merge-base --is-ancestor "$cut" HEAD ||
    fail "refusing to build: HEAD ($(git rev-parse --short HEAD)) does not contain $(git rev-parse --short "$cut"), the commit on origin/main that cut $newest. Build from origin/main: git merge --ff-only origin/main, or git switch --detach origin/main from a cut branch"

  installed=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" 2>/dev/null) || installed=""
  if [ -n "$installed" ] && ! newer_than "$newest" "$installed"; then
    fail "refusing to build: RELEASES.md's newest heading is $newest, and $app is already $installed. Cut a newer version first (/cut-release), and build once it has merged."
  fi
  echo "install  local build of $newest, dragged over $app (${installed:-nothing} installed there now)"
  Scripts/release.sh "$@"
  echo "dmg      $PWD/dist/AgentBoard-$newest.dmg"
}

[ $# -ge 1 ] || { usage >&2; exit 2; }
command="$1"
shift
case "$command" in
  preflight) preflight "$@" ;;
  build) build "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
