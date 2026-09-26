#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage: Scripts/release-notes.sh <tag>

Prints the body of RELEASES.md's section for the version <tag> names, without its
heading line. <tag> must be "v" followed by RELEASES.md's newest "## <version>"
heading, the version Scripts/release.sh stamps; any other tag fails.
USAGE
}

fail() { echo "release-notes.sh: $*" >&2; exit 1; }

# Same parse as release.sh's newest_version, so the tag is checked against the version it stamps.
newest_version() {
  local heading
  heading=$(grep -m1 -E '^## ' "$1" | sed -E 's/^## +//; s/ (—|–|-) .*$//; s/[[:space:]]+$//; s/^[vV]//') || true
  [[ "$heading" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  echo "$heading"
}

[ $# -eq 1 ] || { usage >&2; exit 2; }
tag="$1"

newest=$(newest_version RELEASES.md) || fail "RELEASES.md's first '## ' heading is not '## <version>'"
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
