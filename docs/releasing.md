# Releasing Agent Board

This Mac only: an ad-hoc-signed build installed locally. No Developer ID
signing, notarization, or public distribution.

## 1. Write the RELEASES.md entry

Add a new `## <version> — YYYY-MM-DD` heading at the top of `RELEASES.md`
(newest first — the app's Help-menu window renders the whole file in that
order). Write it for whoever is running the app, not the commit log: what
changed, in plain language, grouped however reads best.

There is deliberately no `Unreleased` section. Every heading is compared
against the running version — both to decide what to show in the Help menu
and, at build time, to stamp `CFBundleShortVersionString` — so a heading has
to be a real, already-decided version the moment it's written.

Per-epic release notes are **not** kept in `RELEASES.md` as epics land. Each
epic writes its own note on the `agent-board` project instead, titled
`Release notes: <epic>`. Find the ones written since the last cut with
`search_notes("Release notes:")` on that project; none of them are marked
"already compiled," so check each one against what the current top heading in
`RELEASES.md` already says before folding it in — an epic's note sometimes
describes work that a still-open earlier entry already covered in different
words. Once you've gathered the notes for everything not yet reflected, write
the new heading and commit `RELEASES.md`.

## 2. Build

```
Scripts/release.sh [--allow-dirty]
```

Builds a release-configuration `Agent Board.app` and packages it. What it
refuses:

- **A dirty tree.** Any tracked file with uncommitted changes fails the build
  unless you pass `--allow-dirty`.
- **A non-arm64 host.** The binary is arm64 only, not universal.
- **A `RELEASES.md` whose newest heading isn't a version.** It's parsed the
  same way the app parses it — up to three dot-separated integers, optional
  `— date` suffix stripped.

What it stamps into the bundle: `CFBundleShortVersionString` from that
heading, `CFBundleVersion` from `git rev-list --count HEAD`, and
`AgentBoardCommit` from `git rev-parse HEAD` (suffixed `-dirty` when built
with `--allow-dirty` over a dirty tree). It signs ad hoc unless
`AGENTBOARD_SIGN_IDENTITY` names a codesign identity — there isn't one
installed on this Mac today. It verifies the assembled bundle, then verifies
it again after round-tripping through the zip; either failing fails the
release.

The artifact lands at `dist/Agent Board.app` (unzipped, for local install)
and `dist/AgentBoard-<version>.zip` (for the GitHub Release).

`--check <app>` and `--check-structure <app>` run the same bundle checks
against an existing app without rebuilding — `--check` also compares it to
the current checkout's version/build/commit, `--check-structure` only checks
the bundle is internally consistent. `Scripts/install.sh` uses
`--check-structure` on whatever it's about to install.

## 3. Publish

```
git tag -a v<version> -m "..."
git push origin v<version>
```

`<version>` must be exactly `RELEASES.md`'s newest heading — that's what
`Scripts/release-notes.sh v<version>` checks, and it's what
`.github/workflows/release.yml` runs on every `v*` tag push. The workflow:

1. Checks the tag against `RELEASES.md` with `Scripts/release-notes.sh` and
   uses that version's section, verbatim, as the release body (with a line
   up top noting the build is ad hoc signed).
2. Refuses if a release for that tag already exists — draft or published,
   checked against the releases listing rather than the by-tag endpoint,
   because the latter doesn't see drafts.
3. Runs `Scripts/release.sh` and attaches `dist/AgentBoard-<version>.zip` to a
   **draft** GitHub Release.

Review the draft on GitHub, edit if needed, and publish it by hand — the
workflow never does that step.

Because the build is ad hoc signed, Gatekeeper blocks the zip on any other
Mac until its quarantine flag is cleared. Tell anyone downloading it to run
`Scripts/install.sh` rather than unzipping and opening the `.app` directly.

## 4. Install

```
Scripts/install.sh [--allow-downgrade] [--open] [--dest DIR] [<Agent Board.app | AgentBoard-<version>.zip>]
```

With no artifact named, installs the newest `dist/AgentBoard-*.zip`. To
install a published release instead of a local build:

```
gh release download v<version> --pattern '*.zip' --dir <dir>
Scripts/install.sh <dir>/AgentBoard-<version>.zip
```

What it does, in order:

- **Refuses while any process named `AgentBoard` is running**, from any path.
  It never quits or kills one — quit from inside the app (Agent Board > Quit)
  so its shutdown sheet settles running workers first, then install.
- **Backs up the database** with `sqlite3 .backup` to
  `backups/agentboard-<timestamp>-<version>[+<build>].sqlite` beside it, and
  keeps the newest five.
- **Refuses a downgrade** — an older version, or an older build of the same
  version (a build number that can't be compared as an integer on either
  side counts as older too) — unless you pass `--allow-downgrade`. With that
  flag it explains the consequence (GRDB silently skips migrations the older
  build doesn't know, rather than refusing the newer schema) and names the
  newest backup known to fit the build you're installing.
- **Clears quarantine** from the extracted bundle and moves it into place.
  Launches the app only if you pass `--open`.

To restore a backup after an intentional downgrade:

```
sqlite3 '<db>' ".restore '<backup>'"
```

This discards anything the board recorded since that backup.

## 5. Versioning

Nothing here enforces a major/minor/patch policy — the scripts only require
`RELEASES.md`'s newest heading to parse as up to three dot-separated integers
and the git tag to match it exactly. 0.1.0 → 0.2.0 bumped minor for a release
carrying nine epics' worth of features; use whichever segment fits the size
of what's shipping.
