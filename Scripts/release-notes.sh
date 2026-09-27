#!/usr/bin/env bash
set -euo pipefail
invoked_from="$PWD"
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: Scripts/release-notes.sh <tag>
       Scripts/release-notes.sh --newest
       Scripts/release-notes.sh --versions <file>

Prints the body of RELEASES.md's section for the version <tag> names, without its
heading line. <tag> must be "v" followed by RELEASES.md's newest "## <version>"
heading, the version Scripts/release.sh stamps; any other tag fails.

--newest prints that newest version instead.

--versions prints the version of every "## " heading in <file>, a RELEASES.md from any
commit, newest first. A heading that isn't a version prints nothing.
USAGE
}

fail() { echo "release-notes.sh: $*" >&2; exit 1; }

# Same parse as release.sh's newest_version, so the tag is checked against the version it stamps.
heading_version() {
  sed -E 's/^## +//; s/ (—|–|-) .*$//; s/[[:space:]]+$//; s/^[vV]//'
}

newest_version() {
  local heading
  heading=$(grep -m1 -E '^## ' "$1" | heading_version) || true
  [[ "$heading" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  echo "$heading"
}

if [ "${1:-}" = --versions ]; then
  [ $# -eq 2 ] || { usage >&2; exit 2; }
  file="$2"
  [[ "$file" == /* ]] || file="$invoked_from/$file"
  [ -f "$file" ] || fail "no such file: $2"
  { grep -E '^## ' "$file" || true; } | heading_version | { grep -E '^[0-9]+(\.[0-9]+){0,2}$' || true; }
  exit 0
fi

[ $# -eq 1 ] || { usage >&2; exit 2; }
tag="$1"

newest=$(newest_version RELEASES.md) || fail "RELEASES.md's first '## ' heading is not '## <version>'"
if [ "$tag" = --newest ]; then
  echo "$newest"
  exit 0
fi
[[ "$tag" == v* ]] || fail "tag '$tag' does not start with 'v'; expected 'v$newest'"
version="${tag#v}"
[ "$version" = "$newest" ] ||
  fail "tag '$tag' names version $version, but RELEASES.md's newest heading is $newest; expected tag 'v$newest'"

# The first section is the newest one, which the check above pinned to $version.
body=$(awk '
  /^## / { if (seen) exit; seen = 1; next }
  seen { lines[++n] = $0 }
  END {
    first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
    last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
    for (i = first; i <= last; i++) print lines[i]
  }
' RELEASES.md)
[ -n "$body" ] || fail "RELEASES.md's section for $version has no notes"
printf '%s\n' "$body"
