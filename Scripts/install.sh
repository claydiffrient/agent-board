#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
keep_backups=3

usage() {
  cat <<USAGE
Usage: Scripts/install.sh [--allow-downgrade] [--open] [--dest DIR] [<Agent Board.app | AgentBoard-<version>.zip>]

Installs a release artifact from Scripts/release.sh as /Applications/Agent Board.app.
With no artifact named, installs the newest dist/AgentBoard-*.zip.

  - Refuses while any Agent Board is running, from any path. Quit it from inside the
    app, so its shutdown sheet decides what happens to running workers.
  - Checks the incoming bundle with release.sh --check-structure.
  - Backs up the database with sqlite3 .backup into backups/ beside it, named with the
    installed version and a timestamp, and keeps the newest $keep_backups.
  - Refuses to install an older version than the installed one, or an older build of
    the same version. Within one version, a build number that is missing or not an
    integer on either side cannot be ordered, so that install is refused too.
  - Copies into a temporary name beside the destination, then renames it into place.

The database is \$AGENTBOARD_DB if set, else agentboard.sqlite in \$AGENTBOARD_SUPPORT_DIR
if set, else in ~/Library/Application Support/AgentBoard, as the app resolves it.

  --allow-downgrade  install even when the incoming version or build is older
  --open             launch the app after installing
  --dest DIR         install into DIR instead of /Applications, for testing; requires
                     AGENTBOARD_SUPPORT_DIR or AGENTBOARD_DB, and narrows the running
                     check to instances launched from DIR or holding that database open
USAGE
}

fail() { echo "install.sh: $*" >&2; exit 1; }

plist_value() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }

# Exit status 0 when $1 is an older version than $2; missing components count as 0.
version_older() {
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    (( ${a[i]:-0} < ${b[i]:-0} )) && return 0
    (( ${a[i]:-0} > ${b[i]:-0} )) && return 1
  done
  return 1
}

# Exit status 0 when build $1 of version $2 is older than build $3 of version $4. Within one
# version, a build that is missing or not an integer cannot be ordered and counts as older.
release_older() {
  version_older "$2" "$4" && return 0
  version_older "$4" "$2" && return 1
  [[ "$1" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] || return 0
  (( 10#$1 < 10#$3 ))
}

release_label() { echo "$1 (build ${2:-missing})"; }

# Every process named AgentBoard is an instance: the release bundle, the dev bundle and
# `swift run` all run an executable of that name. pgrep, ps and lsof read the process
# table, so none of this needs assistive access.
running_instances() {
  local pid exe
  for pid in $(pgrep -x AgentBoard || true); do
    exe=$(ps -o comm= -p "$pid" 2>/dev/null) || continue
    if [ -n "$dest_given" ]; then
      case "$exe" in
        "$dest"/*) ;;
        *) lsof -a -p "$pid" -- "$db" >/dev/null 2>&1 || continue ;;
      esac
    fi
    echo "  pid $pid  $exe"
  done
}

refuse_if_running() {
  local found
  found=$(running_instances)
  [ -z "$found" ] && return
  {
    echo "install.sh: refusing to install: Agent Board is running."
    echo "$found"
    echo "Quit it from inside the app (Agent Board > Quit), let the shutdown sheet settle its"
    echo "workers, then run this again. This script never quits or kills a running board."
  } >&2
  exit 1
}

downgrade_consequence() {
  cat <<EOF
An older build does not refuse a newer database. GRDB's DatabaseMigrator skips
migration ids it does not know and runs nothing, so $incoming_label starts against a
schema it was never written for. Tables and columns added after it are ignored, and a
change it cannot work with (a new NOT NULL column without a default, a renamed or
rebuilt table) fails only when a query reaches it. Nothing warns first, and reinstalling
the newer build later does not rerun its migrations over what the older one wrote.
EOF
}

# The newest backup taken while a release no newer than build $1 of version $2 was installed:
# the last state of the board that build's schema is known to fit. A backup labeled with a
# version alone has no known build, so it never fits a build of that same version.
restorable_backup() {
  local i
  for (( i = ${#existing_backups[@]} - 1; i >= 0; i-- )); do
    [[ "${existing_backups[i]}" =~ /agentboard-[0-9]{8}-[0-9]{6}-([0-9.]+)(\+([0-9]+))?\.sqlite$ ]] || continue
    release_older "$1" "$2" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" || { echo "${existing_backups[i]}"; return 0; }
  done
  return 0
}

# Ascending by name, which is by time: the timestamp leads.
list_backups() {
  existing_backups=()
  local f
  for f in "$backups"/agentboard-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.sqlite; do
    if [ -f "$f" ]; then existing_backups+=("$f"); fi
  done
}

# Removing an xattr needs write permission, and the SwiftPM resource bundles are copied in read-only.
clear_quarantine() {
  local f
  find "$1" -xattrname com.apple.quarantine -print0 | while IFS= read -r -d '' f; do
    if [ -w "$f" ]; then
      xattr -d com.apple.quarantine "$f"
    else
      chmod u+w "$f" && xattr -d com.apple.quarantine "$f" && chmod u-w "$f"
    fi
  done
  [ -z "$(find "$1" -xattrname com.apple.quarantine)" ] || fail "could not clear com.apple.quarantine from $1"
}

allow_downgrade=false
open_after=false
dest=/Applications
dest_given=""
artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-downgrade) allow_downgrade=true ;;
    --open) open_after=true ;;
    --dest) [ $# -ge 2 ] || fail "--dest needs a directory"; dest="$2"; dest_given=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$artifact" ] || { usage >&2; exit 2; }; artifact="$1" ;;
  esac
  shift
done

if [ -n "$dest_given" ] && [ -z "${AGENTBOARD_SUPPORT_DIR:-}" ] && [ -z "${AGENTBOARD_DB:-}" ]; then
  fail "--dest is for testing: set AGENTBOARD_SUPPORT_DIR to a scratch directory so the real board's database is not backed up"
fi
mkdir -p "$dest"
dest=$(cd "$dest" && pwd -P)
target="$dest/Agent Board.app"

support="${AGENTBOARD_SUPPORT_DIR:-$HOME/Library/Application Support/AgentBoard}"
db="${AGENTBOARD_DB:-$support/agentboard.sqlite}"
backups="$(dirname "$db")/backups"

refuse_if_running

if [ -z "$artifact" ]; then
  for zip in "$repo"/dist/AgentBoard-*.zip; do
    [ -f "$zip" ] || continue
    if [ -z "$artifact" ] || [ "$zip" -nt "$artifact" ]; then artifact="$zip"; fi
  done
  [ -n "$artifact" ] || fail "no dist/AgentBoard-*.zip; run Scripts/release.sh or name an artifact"
fi
artifact="${artifact%/}"
[ -e "$artifact" ] || fail "no such artifact: $artifact"

for stale in "$dest"/.install-agent-board.*; do
  if [ -e "$stale" ]; then rm -rf "$stale"; fi
done
staging=$(mktemp -d "$dest/.install-agent-board.XXXXXX")
partial=""
cleanup() {
  [ -z "$partial" ] || rm -f "$partial" "$partial-journal"
  if [ -d "$staging/previous.app" ] && [ ! -e "$target" ]; then mv "$staging/previous.app" "$target"; fi
  rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
incoming="$staging/Agent Board.app"
case "$artifact" in
  *.zip)
    ditto -x -k "$artifact" "$staging"
    [ -d "$incoming" ] || fail "$artifact does not contain Agent Board.app"
    ;;
  *.app) ditto "$artifact" "$incoming" ;;
  *) fail "expected a .app or .zip from Scripts/release.sh: $artifact" ;;
esac
clear_quarantine "$incoming"
"$repo/Scripts/release.sh" --check-structure "$incoming" >/dev/null || fail "$artifact failed the bundle check; nothing was installed"

incoming_version=$(plist_value "$incoming" CFBundleShortVersionString)
incoming_build=$(plist_value "$incoming" CFBundleVersion)
incoming_commit=$(plist_value "$incoming" AgentBoardCommit)
incoming_label=$(release_label "$incoming_version" "$incoming_build")
installed_version=""
installed_build=""
if [ -d "$target" ]; then
  installed_version=$(plist_value "$target" CFBundleShortVersionString)
  installed_build=$(plist_value "$target" CFBundleVersion)
  [ -n "$installed_version" ] || fail "$target has no CFBundleShortVersionString; move it aside by hand"
fi

downgrade=false
if [ -n "$installed_version" ] && release_older "$incoming_build" "$incoming_version" "$installed_build" "$installed_version"; then
  downgrade=true
  if ! $allow_downgrade; then
    {
      echo "install.sh: refusing to downgrade $(release_label "$installed_version" "$installed_build") to $incoming_label (pass --allow-downgrade to override)."
      if [ "$incoming_version" = "$installed_version" ] && ! [[ "$incoming_build" =~ ^[0-9]+$ && "$installed_build" =~ ^[0-9]+$ ]]; then
        echo "The build numbers cannot be ordered, so this counts as a downgrade."
      fi
      echo
      downgrade_consequence
    } >&2
    exit 1
  fi
fi

backup=""
if [ -f "$db" ]; then
  mkdir -p "$backups"
  while :; do
    stamp=$(date +%Y%m%d-%H%M%S)
    compgen -G "$backups/agentboard-$stamp-*.sqlite" >/dev/null || break
    sleep 1
  done
  backup_label="${installed_version:-none}"
  if [[ -n "$installed_version" && "$installed_build" =~ ^[0-9]+$ ]]; then backup_label+="+$installed_build"; fi
  backup="$backups/agentboard-$stamp-$backup_label.sqlite"
  # An interrupted .backup leaves a file that opens as a valid, empty database; only a finished
  # one gets the name that pruning and restoring look for.
  rm -f "$backups"/.agentboard-*.partial "$backups"/.agentboard-*.partial-journal
  partial="$backups/.agentboard-$stamp.partial"
  sqlite3 "file:$db?mode=ro" ".backup '$partial'" || fail "sqlite3 .backup of $db failed; nothing was installed"
  [ "$(sqlite3 "$partial" "PRAGMA page_count")" = "$(sqlite3 "file:$db?mode=ro" "PRAGMA page_count")" ] \
    || fail "the backup of $db does not match it page for page; nothing was installed"
  mv "$partial" "$backup"
  partial=""
  list_backups
  for (( i = 0; i < ${#existing_backups[@]} - keep_backups; i++ )); do
    rm -f "${existing_backups[i]}"
  done
fi
list_backups

refuse_if_running
if [ -d "$target" ]; then
  mv "$target" "$staging/previous.app"
  if ! mv "$incoming" "$target"; then
    mv "$staging/previous.app" "$target"
    fail "could not move the new app into place; $target is unchanged"
  fi
else
  mv "$incoming" "$target"
fi

echo "installed $target"
if [ -n "$installed_version" ]; then
  echo "version   $installed_version (build $installed_build) -> $incoming_version (build $incoming_build)"
else
  echo "version   none -> $incoming_version (build $incoming_build)"
fi
echo "commit    $incoming_commit"
if [ -n "$backup" ]; then echo "backup    $backup"; else echo "backup    none: no database at $db"; fi

if $downgrade; then
  echo
  downgrade_consequence
  restore=$(restorable_backup "$incoming_build" "$incoming_version")
  echo
  if [ -n "$restore" ]; then
    echo "The newest backup taken under $incoming_label or older is $restore. To go back to it,"
    echo "before launching: sqlite3 '$db' \".restore '$restore'\""
    echo "That discards everything the board recorded since that backup."
  else
    echo "No backup here was taken under $incoming_label or older, so there is no known-good"
    echo "database for it."
  fi
fi

if $open_after; then open "$target"; fi
