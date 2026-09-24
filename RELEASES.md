# Agent Board releases

What changed in each build, newest first. The app reads this file straight from
its bundle, so write it for whoever is running Agent Board, not for the commit log.

Format: one `## <version>` heading per release, optionally followed by ` — YYYY-MM-DD`,
with free Markdown beneath it. Everything above the first `## ` heading — this
paragraph included — is ignored. Headings must be versions: there is no
`Unreleased` section, because every entry is compared against the running version
to decide what a user has already seen.

## 0.2.0 — 2026-09-24

- **Board.** A project can run every worker in its own checkout on one shared
  branch instead of a git worktree per task — set Project Settings → Workflow
  → Isolation → Worktree strategy to Shared or Auto; acceptance waits for
  every task on that branch before merging the whole thing into the epic at
  once. Epic lanes on the Task Board now sort by state (active, planning,
  integrating, done, then abandoned) instead of creation order, each with a
  disclosure control, and a done epic's lane starts collapsed. A standalone
  task (one in no epic) can integrate by opening a pull request instead of
  merging locally — set on Workflow → Publishing — and Agent Board tracks it
  to merged and lands the task itself once the PR is in. Launching Agent
  Board from Finder or the Dock no longer fails an orchestrator's first
  command with `claude: No such file or directory`.
- **Reviews.** Work can go to a rostered specialist agent instead of only a
  person: add, edit, and delete these agents from the new Roster screen in
  the sidebar, pick one for a task, or turn on Agent review for a project so
  every completed task routes to a named reviewer — choose which one in
  Project Settings → Agents. A rostered reviewer can only look, comment,
  accept, or reopen; it can't edit or push, and accept/reopen now refuse if
  the branch moved or a tracked file changed while it worked. The review
  column shows who's holding each pending review and how long they've been at
  it, and accepting or reopening a task stops any reviewer still working it
  first. Deleting an agent that has run sessions or reviews no longer fails —
  its past work stays on record with the reference cleared instead.
- **Status.** Each session's row now names the rostered agent that worked it,
  and which agent is reviewing. A "Keep awake" checkbox in the status
  footer, on by default, keeps the Mac from idle-sleeping while any worker is
  running and lets go the moment the last one finishes — it doesn't cover a
  closed lid.
- **Search.** One field now sits above the Task Board, Notes, and the Status
  pane (⌘F) and narrows whatever screen is in front to matching cards, notes,
  or sessions and ports as you type, with a running count beside it.
- **Terminal.** A second button beside Attach — on the Status pane and in the
  task inspector — opens a worktree shell: a plain login shell rooted at a
  session's own checkout, for poking around without dropping into its live
  Claude session. A terminal building at launch no longer freezes the UI
  while it waits on the login shell's PATH.
- **Ports.** A Ports panel in the sidebar lists every TCP port a process
  Agent Board started is listening on, who owns it, and lets you open or stop
  it. The same rows, filtered to one project, also show on that project's
  Status pane.
- **Cross-project messages.** The Orchestrator screen's sidebar now has a
  Messages section showing both directions of project-to-project notes —
  which project, when it arrived, and whether the receiving side has pulled
  it yet.
- **Notifications.** A banner now fires only for a pending approval or a
  blocked worker. A finished task with an unread report, or an overdue,
  unacknowledged shutdown, raises a new sidebar badge and an At a Glance dot
  instead — no banner. At a Glance's headline now shows how many projects
  need you, alongside the existing review-column count. Clicking a banner
  opens straight to what's waiting: the approvals sidebar, the blocked-task
  section, or Status when a session blocked with no task. Project Settings
  adds per-category banner toggles and a project-wide mute, timed or
  indefinite — muting only silences banners, not the badge or dot.
- **Settings.** Project Settings is six tabs instead of one long scrolling
  form, and the sheet is wider and shorter to fit. The autoMode classifier
  editor no longer silently turns a typed straight quote into a curly one
  that fails to parse as JSON. Opus 5.5 is in the model catalog and priced
  correctly, rather than being read as Opus 5.

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
