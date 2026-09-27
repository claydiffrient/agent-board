---
name: cut-release
description: Cut a new Agent Board version. `/cut-release [version]` compiles every uncompiled "Release notes:" note and the user-visible merges since the last cut into a new RELEASES.md entry, commits it, and marks those notes compiled. `/cut-release --build`, after that commit has merged, builds the DMG, refusing if the checkout doesn't contain the merged cut or the installed app is already that version. Use when asked to cut, compile or build a release.
argument-hint: "[version] | --build"
---

# /cut-release

Arguments: `$ARGUMENTS`

With `--build`, skip to [Build mode](#build-mode). Otherwise the argument, if any, is the version to cut.

Every refusal below ends the skill: say what was refused and why, and stop. Never work around one.

This skill never pushes, tags, opens a pull request, installs the app, or builds as part of a cut. Workers can't push, and Clay approves anything outward-facing.

## 1–3. Preconditions, last cut, next version

```
Scripts/cut-release.sh preflight [<version>]
```

It fetches origin and refuses unless no tracked file has changes and HEAD is `origin/main` (a branch created from it for the cut, with no commits of its own, passes). It refuses a version that isn't newer than `RELEASES.md`'s newest heading. On success it prints:

- `last`: the newest heading's version;
- `cut`: the commit that added that heading, the last cut;
- `next`: the version to cut. When no version was given it says it bumped the minor version; tell the user so;
- `since`: the first-parent commits on `origin/main` after the cut.

If it exits non-zero, relay its message and stop.

## 4. Gather the sources

### Release-notes notes

You need the `agent-board` MCP tools `search_notes` and `read_note`, and `append_section` for step 8. If this session has none of them, stop and say the cut needs a session connected to the agent-board MCP server. Never read the Agent Board database file directly, not even read-only.

1. `search_notes` for `"Release notes"`. It returns every matching note, titles included, so one search finds them all. Keep each note whose title starts with `Release notes:`.
2. `read_note` each one. Drop every note with a section headed exactly `Compiled`: it went into an earlier version. The rest are this cut's notes.
3. List the notes you kept and the ones you dropped as compiled, by title, before you write anything.

A note can be wrong. Some carry their own correction section, and some describe a branch that changed before it merged. Read the whole note.

### Merges since the cut

For each commit in preflight's `since` list:

- the squash subject ends in `(#<n>)`: `gh pr view <n> --json title,body`;
- no PR number, or `gh` is unavailable: `git log -1 --format=%B <sha>`.

Keep only what someone using Agent Board would notice: a new or changed screen, control, setting, or behavior, or a fixed bug they could have hit. Drop tests, CI, refactors, docs, internal tooling, and earlier `Cut x.y.z` commits. A merge can be what an epic's note describes. Write it up once.

### Check claims against the code

Check every claim you're about to write against the code on `origin/main`, not against a note's or PR's title or wording. That covers where a control lives, what it's labeled, defaults, and what a feature refuses. If a claim doesn't hold, leave it out or write what the code does. Never write a claim you haven't checked.

If no uncompiled note is left and no merge is user-visible, refuse: there is nothing to cut.

## 5. Write the entry

Add at the top of `RELEASES.md`, directly above the current newest `## ` heading:

```
## <version> — <today, YYYY-MM-DD>
```

The separator is an em dash. Match the entries below it:

- Bullets that open with a bold area and a period (`- **Reviews.** …`), prose after, wrapped near 78 columns with a two-space continuation indent. Reuse the earlier entries' area names where they fit.
- Written for whoever is running the app: what they'll see, where to find it, what it no longer does. Name menus and settings the way the app labels them.
- No task ids, commit SHAs, PR numbers, type or file names, test counts, or agent-internal plumbing a user never sees.
- Don't repeat anything an earlier entry already says. If this release changes something an earlier entry described, say what changed.

## 6. Verify

```
Scripts/release-notes.sh v<version>
swift test --filter ReleaseNotes
```

The first must exit 0 and print the new section. The second must pass. It builds the package first, about 9 minutes cold. Fix the entry and rerun both until they pass. Run them unpiped.

## 7. Commit

Stage only `RELEASES.md` and commit, imperative mood:

```
git add RELEASES.md
git commit -m "Cut <version>: <what the release carries, in a few words>"
git show --stat --format=%h HEAD
```

The stat must list `RELEASES.md` and nothing else. In an Agent Board shared checkout, commit through `commit_my_work`.

## 8. Mark the notes compiled

For every note step 5 drew on:

```
append_section(note_id, "Compiled", "Compiled into <version> (<short sha from step 7>).")
```

A `Compiled` section is the only record that a note is compiled, and step 4 filters on it. Mark only the notes you actually used. A note you read but left out stays unmarked; say why in the summary.

## 9. Print the next steps and stop

Print the version, the commit, and the notes you marked. Then print these steps and do none of them:

1. The pull request: Clay approves one for this branch, or the orchestrator calls `open_pull_request`.
2. When it merges, `.github/workflows/release.yml` tags the merge commit `v<version>` and creates a draft GitHub Release with the DMG attached. There's nothing to tag by hand.
3. Install (`docs/releasing.md` §4) from either:
   - a local build: `git fetch origin && git merge --ff-only origin/main`, then `/cut-release --build`;
   - the draft's DMG, once that workflow run finishes: `gh release download v<version> --pattern '*.dmg'`.
4. Publish the draft on GitHub.

## Build mode

`/cut-release --build`, run after the cut commit has merged and the checkout is on it:

```
Scripts/cut-release.sh build
```

It fetches origin, then refuses:

- unless `origin/main` has the commit that added `RELEASES.md`'s newest heading and HEAD contains it. A refusal means the cut hasn't merged, or the checkout is behind `origin/main` or still on the cut branch;
- unless that version is newer than the `CFBundleShortVersionString` in `/Applications/Agent Board.app/Contents/Info.plist`. A refusal means it's already installed. Rebuilding it would install the same version again, and What's New would show nothing.

Relay a refusal and stop.

Otherwise it prints an `install` line naming the app the build will replace and the version there now, runs `Scripts/release.sh`, and ends with a `dmg` line. Print that path and `docs/releasing.md` §4's install step: quit through **Agent Board > Quit**, open the DMG, drag Agent Board onto Applications. Don't install it yourself. If `release.sh` refuses, relay it. It refuses a dirty tree, for one; pass `--allow-dirty` to `Scripts/cut-release.sh build` only when the user asks for it.
