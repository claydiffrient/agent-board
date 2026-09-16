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

- **Task Board.** Projects, epics and tasks in columns, with worker sessions
  started as `claude --bg` against a per-task git worktree.
- **Status.** Live session state, token spend against per-model pricing, and
  optional caps that stop a run before it burns the rest of a budget.
- **Approvals and reports.** A worker's permission requests and its final report
  surface in the app instead of a terminal you had to remember to watch.
- **Terminal attach.** Open a real terminal on a running session when a decision
  needs a human.
- **Notifications.** Banners for approvals waiting, blocked workers and finished
  tasks, with a click that opens what the banner is about.
