# Agent Board releases

What changed in each build, newest first. The app reads this file straight from
its bundle, so write it for whoever is running Agent Board, not for the commit log.

Format: one `## <version>` heading per release, optionally followed by ` — YYYY-MM-DD`,
with free Markdown beneath it. Everything above the first `## ` heading — this
paragraph included — is ignored. Headings must be versions: there is no
`Unreleased` section, because every entry is compared against the running version
to decide what a user has already seen.

## 0.1.0 — 2026-09-16

First release.

- **Task Board.** Projects, epics and tasks moving through Ready → Running →
  Review → Done, each task working in its own git branch and worktree so a
  retry picks up where the last attempt left off. Archive done work
  automatically — once its epic merges, after a number of days, or never — or
  archive it yourself; either way it can always be brought back. Finished with
  an epic before every task in it is done? Close it as done or abandon it by
  hand without losing whatever's left unfinished.
- **Status.** A live roster of every worker — state, elapsed time, and spend
  against whatever cap you set — plus your account's 5-hour and weekly Claude
  usage windows, marked stale once the reading is more than half an hour old.
  Idle and elapsed limits now correctly ignore time your Mac spends asleep, so
  closing the lid overnight no longer kills every worker the moment it wakes.
- **Approvals.** Spawning a worker, requesting an epic integration, and
  pushing a branch or opening a pull request all wait for you — autonomy is
  off until you turn it on, and a worker itself can never push or open a pull
  request. Reports and blocked-worker requests surface in the app instead of a
  terminal you had to remember to watch.
- **Terminal access.** Attach to a blocked worker's real terminal to answer
  whatever it's waiting on. Every project also gets its own always-on shell,
  independent of any task.
- **Notifications.** A banner when a worker needs you, when one may be stuck,
  or when a task finishes — click it to go straight there.
- **Stop All / Shut Down.** Wind workers down cleanly, one project or every
  project at once: in-progress work is committed and the task goes back to
  Ready with a note of where it stopped, never lost.
- **Notes.** A shared, searchable notes surface agents read and write across
  tasks and epics, with pinning and sectioned editing.
- **At a Glance.** One page across every project: what's running, what needs
  you, and where — with a sidebar organized into workspaces you can group
  projects into.
- **Cross-project messages.** One project's orchestrator can drop a note in
  another project's queue.
- **What's New.** This window, from the Help menu — and from now on, it opens
  itself once after an update that has notes for you.
