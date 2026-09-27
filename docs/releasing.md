# Releasing Agent Board

This Mac only: an ad-hoc-signed build installed locally. No Developer ID
signing, notarization, or public distribution.

## 1. Write the RELEASES.md entry

Run `/cut-release [version]` in a Claude Code session in this repo, connected
to the `agent-board` MCP server (`.claude/skills/cut-release/SKILL.md`). It
checks you're on `origin/main`, gathers every `Release notes: <epic>` note not
yet compiled and every user-visible merge since the last cut, writes the new
entry, verifies it, commits `RELEASES.md` alone, and marks each note it used
with a `Compiled` section. It never pushes, tags or opens a pull request;
merging the cut tags it (§3). With
no version it bumps the minor version.

To do it by hand instead: add a new `## <version> — YYYY-MM-DD` heading at the
top of `RELEASES.md` (newest first — the app's Help-menu window renders the
whole file in that order). Write it for whoever is running the app, not the
commit log: what changed, in plain language, grouped however reads best.

There is deliberately no `Unreleased` section. Every heading is compared
against the running version — both to decide what to show in the Help menu
and, at build time, to stamp `CFBundleShortVersionString` — so a heading has
to be a real, already-decided version the moment it's written.

Per-epic release notes are **not** kept in `RELEASES.md` as epics land. Each
epic writes its own note on the `agent-board` project instead, titled
`Release notes: <epic>`. Find the ones written since the last cut with
`search_notes("Release notes:")` on that project and skip every note that has
a `Compiled` section — that section, "Compiled into <version> (<sha>).", is the
only record that a note already went into a release. Check the rest against
the code on `main`, fold them in, commit `RELEASES.md`, then `append_section`
a `Compiled` section onto each note you used.

## 2. Build

Once the cut has merged and your checkout is on it, run `/cut-release --build`
(`Scripts/cut-release.sh build`). It refuses unless `origin/main` has the
commit that added `RELEASES.md`'s newest heading and HEAD contains it, so an
unmerged cut branch can't be built. It also refuses unless that version is
newer than the installed `/Applications/Agent Board.app`, so an
already-installed version can't be rebuilt and reinstalled with nothing new
for What's New to show. Then it prints which app it will replace, runs
`release.sh`, and prints the DMG path. Instead of building, you can download
the draft release's DMG (§3, §4).

By hand:

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
it again inside the mounted DMG; either failing fails the release.

The artifact lands at `dist/Agent Board.app` and `dist/AgentBoard-<version>.dmg`
— a disk image holding the app and an `Applications` symlink to drag it onto.
`release.sh` mounts the DMG read-only and re-runs the bundle check against the
copy inside it before deleting the mountpoint; either the assembled app or the
mounted one failing the check deletes the DMG and fails the release.

`--check <app>` and `--check-structure <app>` run the same bundle checks
against an existing app without rebuilding — `--check` also compares it to
the current checkout's version/build/commit, `--check-structure` only checks
the bundle is internally consistent.

## 3. Publish

Merging the cut is the whole step. `.github/workflows/release.yml` runs on
every push to `main` that changes `RELEASES.md`. It reads the newest heading's
version and, if `origin` has no tag `v<version>` and no release (draft or
published) exists for it, in that one run:

1. Checks the version's section with `Scripts/release-notes.sh` and uses it,
   verbatim, as the release body (with a notice up top giving the Gatekeeper
   step below).
2. Runs `Scripts/release.sh`.
3. Tags the pushed commit `v<version>` (annotated) and pushes the tag.
4. Attaches `dist/AgentBoard-<version>.dmg` to a **draft** GitHub Release.

If the tag or a release already exists it logs why and does nothing, so an
ordinary edit to `RELEASES.md` releases nothing. Releases are checked against
the releases listing rather than the by-tag endpoint, because the latter
doesn't see drafts.

The fallback, when that run didn't happen or failed before creating the
release, is pushing the tag yourself:

```
git tag -a v<version> -m "Agent Board <version>" <merge commit>
git push origin v<version>
```

`<version>` must be exactly `RELEASES.md`'s newest heading. A `v*` tag push
runs the same job, minus the tagging, and fails rather than skips if a release
for the tag already exists. If the merge run failed after pushing its tag,
delete the tag on `origin` first and push it again.

Review the draft on GitHub, edit if needed, and publish it by hand — the
workflow never does that step.

The release notice gives this Gatekeeper wording verbatim:

> Install by opening the DMG and dragging Agent Board into Applications. This
> build is ad-hoc signed, so on macOS 15 and later Gatekeeper blocks the first
> open of a downloaded copy. Allow it under System Settings > Privacy &
> Security > Open Anyway (the button appears for about an hour after the
> blocked open), or clear the flag with
> `xattr -dr com.apple.quarantine "/Applications/Agent Board.app"`.

## 4. Install

Quit Agent Board first if it's running, through **Agent Board > Quit** — that
lets its shutdown sheet settle any running workers before you replace the
bundle. There's no installer standing guard over this the way there used to
be, so quitting first is on you.

Then open `dist/AgentBoard-<version>.dmg` (or, for a draft or published release,
`gh release download v<version> --pattern '*.dmg' --dir <dir>` and open the
downloaded one), drag **Agent Board** onto the **Applications** shortcut
inside it, and relaunch from `/Applications`.

Because the build is ad hoc signed, macOS 15 and later blocks the first open
of a downloaded copy with Gatekeeper. Allow it under System Settings >
Privacy & Security > Open Anyway (the button appears for about an hour after
the blocked open), or clear the flag yourself:

```
xattr -dr com.apple.quarantine "/Applications/Agent Board.app"
```

The database is protected on launch now, not by the install step. Every
launch, before migrating an existing database, the app checks it for
migrations this build doesn't recognize:

- **A build newer than the one you just installed wrote the database.** The
  app refuses to open it, shows a blocking alert saying so, names the newest
  file under `backups/` (beside the database) if one fits, gives the
  `sqlite3 ... .restore` command below to restore it, and quits without
  writing anything. This is what used to happen silently — an older build
  opening a newer database and skipping migrations it didn't know — now it
  stops you instead.
- **Otherwise**, if this build differs from the last one to open the
  database, the app backs it up first: a full copy in
  `backups/agentboard-<timestamp>-<version>[+<build>].sqlite`, verified
  page-for-page against the source before it gets that name, keeping the
  newest three. Each backup is about 290 MB today, so three take under 1 GB.
  A normal upgrade needs nothing from you here — this happens on the next
  launch, automatically.

To restore a backup by hand:

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
