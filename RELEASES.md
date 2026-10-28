# Agent Board releases

What changed in each build, newest first. The app reads this file straight from
its bundle, so write it for whoever is running Agent Board, not for the commit log.

Format: one `## <version>` heading per release, optionally followed by ` — YYYY-MM-DD`,
with free Markdown beneath it. Everything above the first `## ` heading — this
paragraph included — is ignored. Headings must be versions: there is no
`Unreleased` section, because every entry is compared against the running version
to decide what a user has already seen.

## 0.9.0 — 2026-10-28

- **Pull requests.** Project Settings → PR Follow-Through → Verification's
  verify command gains an **Add board tools** button, which appends
  `--mcp-config {mcp_config}` to it. With that in the command, opening
  **Walk me through it** gives that session a narrow grant: it can propose
  a task, read this project's notes, and record a verify failure against
  the very pull request it's checking — nothing else, and the grant is
  revoked the moment the window's shell exits or the window closes. A task
  it proposes this way is labeled "From Walk me through it · owner/repo#N"
  on its card and in the inspector, so you can tell where it came from.
  Orchestrators can now ask to resume a parked pull request once they've
  dealt with the parked reason — it reaches you as a pending approval
  naming that reason alongside the orchestrator's own. PR Follow-Through →
  Watch gains **Minimum battery to start a round (%)**, 50 by default and
  blank for any charge — a settled round used to wait for AC power
  outright, rather than any charge above a threshold. Follow-through's
  automatic checks now read a pull request's current title and description
  before grading an item against them, instead of the stale copy from
  when the watch started, so an edit you made yourself no longer gets
  re-flagged as unfixed.
- **Sessions.** A worker whose turn was cut short by the Mac sleeping
  mid-response is now resumed automatically once the Mac is fully awake,
  instead of sitting idle until the 40-minute idle cap ends it — and it's
  now exempt from that cap while it waits for wake, instead of often being
  killed first on an overnight lid close. **Keep awake**, in each
  project's status footer, now holds the Mac awake only while a worker or
  reviewer is actually running, not for an idle or already-quit
  orchestrator console; a stray orchestrator session left showing as live
  after its console closed is now cleared at the next launch instead of
  sitting there indefinitely.
- **Projects.** Deleting a project whose tasks had any approvals no longer
  fails with a database error.
- **Reliability.** A long-running app could eventually fail to read a
  session it had just spawned and leave that session running untracked;
  both the leak behind it and the orphaned session are now fixed.

## 0.8.0 — 2026-10-25

- **Process management.** At a Glance gets a new Processes view, next to
  Projects, listing every process Agent Board started or still controls:
  each worker's, reviewer's, orchestrator's and the Coordinator's own
  `claude` process and everything running under it, a process a session
  left orphaned in its worktree after ending, shells and terminal windows
  opened from the app, and Agent Board's own helper commands. Rows are
  grouped by project and then by owner, and show CPU, memory, uptime and
  any ports a process is listening on; sorting by a column flattens the
  table, and Show Hierarchy brings the tree back. Selecting a row offers
  **Stop…**, which always confirms first and refuses anything outside
  what the view is allowed to touch — Agent Board itself, another
  session's `claude` process, an orchestrator's or the Coordinator's own
  console, or a process that's already changed. Separately, stopping a
  session anywhere in the app — a cap, a manual Stop, Pause All,
  shutdown, completion, or the background sweep for leaked sessions — now
  also ends that session's `claude` process even when the normal stop
  command itself fails, so a stopped session no longer leaves its process
  running behind it.
- **Pull requests.** Every reply PR Follow-Through posts on your behalf
  now ends with a line marking it as agent-written, so a factual reply
  about what fixed something doesn't read as something you typed
  yourself. A reviewer request that only you can act on — editing the
  PR's description or title, changing its labels or reviewers — now
  becomes a decision waiting on you right away instead of a fix round
  that fails three times before parking; a round that does end up
  parking now names the specific item that's stuck on its first line
  instead of just a failure count. A reviewer's empty change-request that
  was already handled by a feedback item you filed by hand is now
  recognized as already done instead of raising a duplicate decision for
  you. A fix round whose check couldn't run at all — the tool to spawn it
  failed, or its worktree went missing — is retried instead of being
  treated as a failure, so a commit it already made isn't quietly left
  unpushed; a genuine configuration problem (no server, no usable roster
  agent, not a git repository) still parks right away. Each pull
  request's row now lists its open items, each with a **Dismiss…**
  button that asks for a reason — handling something outside Agent Board
  no longer means stopping the whole pull request's watch just to clear
  it. Orchestrators can now answer questions about a watched pull
  request's state, items and parked reason directly, instead of you
  having to look it up yourself.

## 0.7.0 — 2026-10-22

- **Pull requests.** PR Follow-Through no longer acts on text a reviewer
  hid in an HTML comment — a bot review whose only visible text was a
  status banner could have a hidden finding acted on and the reply
  posted against text nobody could see. Hidden comments are now stripped
  before anything becomes an item, and feedback that turns out to ask
  for nothing once stripped gets no reply at all. A PR conversation
  comment posted after the pull request's head commit is now read as
  feedback too, and a change-requested review left with an empty body
  now opens an item pointing back at the reviewer's other comments,
  instead of leaving the pull request stuck on "waiting on reviewers"
  with nothing to act on. A new **Re-request reviews** setting, off by
  default, asks the authors of handled feedback to review again once a
  fix round is pushed — skipping anyone who already approved, the PR's
  author, bots, and anyone with a request already pending. Each row on
  the Pull Requests page now shows an attach button for every agent
  actively working that PR — Triage, Fixer or Reviewer — opening its
  live Claude session the same way the Status page's attach button does.
- **Reliability.** Commands Agent Board runs no longer hang for up to 60
  seconds or silently return empty output when several run at once —
  this hit PR polls, git calls, and `claude agents` listings under
  load. The cause was pipe reads scheduled on a shared dispatch queue
  starving each other once as many callers piled up as the Mac has
  cores; reads now happen on the calling thread instead. The same race
  could deadlock the very first batch of commands a project ran, since
  they all needed the login shell's PATH resolved at once; that lookup
  now runs once on its own thread while the rest wait on it instead of
  piling onto the same queue.

## 0.6.1 — 2026-10-22

- **Pull requests.** A pull request whose required checks had all passed
  could sit in "awaiting CI" indefinitely, because a pending check that
  wasn't actually required was still being counted against it — fixed by
  reading each check's own required flag from the pull request itself,
  unioned with what branch protection and rulesets name, and falling back
  to the old all-checks-pass rule only when nothing is required from
  either source. PR Follow-Through → Verification gains **Checks that
  wait on verification**, a list of check names to ignore when deciding
  whether CI passed, for a check that only goes green once you've
  verified the pull request yourself. Each group on the Pull Requests
  page now has its own **Refresh** button, which polls just that
  section's pull requests and joins a poll already running instead of
  starting a second one; every row also shows when it was last polled.
  **Walk me through it** now runs the verify command in an interactive
  login shell, the way your own terminal would, so anything on your
  terminal's PATH (including `claude`) works there now; typing a Claude
  slash command as the verify command gets a note in Project Settings
  with a button to rewrite it as `claude "…"`, and the Verify window
  shows the same hint if a slash-command-shaped command fails fast. The
  Orchestrator now gets a short update whenever PR Follow-Through
  finishes a milestone on one of your pull requests — ready to verify,
  parked, a new decision, a round's outcome, merged or closed.
- **Settings.** The Roles help text in PR Follow-Through settings said
  only Triage ran; it now names all four roles and says they all run.

## 0.6.0 — 2026-10-21

- **Pull requests.** A new pinned sidebar page, **Pull Requests**, watches
  every open, non-draft pull request you author in a project with PR
  Follow-Through turned on, polling GitHub roughly once a minute. Rows
  group into Ready to verify, Needs you, In progress, Waiting on
  reviewers, Verified and Parked, each showing the PR's title, round,
  open items, and when the watch last changed. Unresolved feedback is
  triaged automatically into a fix, an answer, an already-done note, a
  follow-up task, or a decision that lands in Needs you for you to pick
  an option or type a reply. A fix now runs end to end: a fixer session
  commits on a branch cut from the PR's head, a reviewer and a follow-up
  check grade the round, and a passing round is pushed for you
  (fast-forward only, never a force push) and watched through its checks;
  three failed rounds in a row parks the PR with the reason shown. A
  parked PR is actionable again — **Resume** puts it back in the loop and
  resets the round and failure counts, **Stop watching** drops it from
  the page for good — and a stale PR (its head moved mid-round) now says
  "restarted: head moved" instead of disappearing. A failed required
  check becomes its own item instead of waiting to be noticed, an
  unmergeable PR is fixed by merging the base branch in rather than
  rebasing, and **Send back** records what failed when you verify a PR by
  hand and reopens the loop (or, on an already-verified PR, becomes a
  decision waiting on you, since a verified PR is never pushed to again).
  **Mark verified** and **Walk me through it** (runs the project's
  configured verify command against the PR) sit alongside Open PR and
  Pause/Resume on each row. Project Settings gains a **PR Follow-Through**
  tab: Watch (on/off, settle window, round cap, daily budget),
  Verification (label, approval requirement, verify command), Roles (an
  agent and model for each of Triage, Fixer, Reviewer and Follow-up
  check) and a Publish guard for private terms. Separately, Ready to
  verify is stricter now: it waits for GitHub's actual per-reviewer review
  decision rather than just a tally of approvals, so re-requesting review
  after changes are requested keeps a PR out of Ready to verify until
  that reviewer re-reviews, even after you push a fix; it also won't go
  green before any check has reported, and a required check that fails
  and then passes on a rerun now clears instead of reading as failed
  forever.
- **Worktrees.** Project Settings → Isolation gains **Reusable worktree
  slots** (0 by default, meaning every task still gets its own worktree).
  Set it above 0 and workers take turns in that many worktrees that stay
  on disk between tasks, so build output inside them stays warm instead
  of every task paying for a cold checkout; a slot's teardown hook runs
  only when the count is lowered and a slot is retired. Several races
  around spawning, resuming and cleaning up worktrees under load are also
  fixed: a freshly cut task branch with no commits yet could be swept up
  as "already merged" and deleted out from under its own worker, a
  respawned integrator could land in an ordinary task worktree instead of
  its epic's checkout and never move the epic branch, and an orphaned
  worktree could be reaped away from a worker whose session row hadn't
  been written yet, or from a retry still waiting behind an earlier
  worktree's removal.
- **Sessions.** Resuming a stopped worker in a shared checkout now keeps
  the protection that stops two workers editing the same file at once —
  before, a resumed worker lost it. Resuming a reviewer no longer pulls
  its task back out of review, a reviewer whose task has already left
  review is refused outright, and so is resuming into a worktree or task
  another active session already holds. Starting or accepting a task no
  longer shows a false timeout while the work quietly continues in the
  background — a slow repository setup hook, an in-flight commit, or a
  tool-call accept's cleanup now all answer promptly and finish
  afterwards — and accepting or finishing a task while its own commit is
  still running is refused instead of risking a half-committed task.
- **Roster.** A rostered agent's sheet gains a **Plugin directories**
  field — one path per line, each passed as `--plugin-dir` when that
  agent is spawned.
- **Projects.** Deleting a project that had ever used the shared
  worktree strategy no longer fails with a database error.

## 0.5.0 — 2026-10-20

- **Tasks.** An orchestrator can now close a task it decides is obsolete,
  with a recorded reason, instead of leaving it to rot on the board or
  forcing it through review. A closed task moves to a new **Closed** column,
  doesn't count toward an epic's done tasks, and can only be reopened by a
  human, from the board.
- **Reviews.** A rostered reviewer that goes quiet now gets one automatic
  reminder before its review is marked "stopped without a verdict." Pending
  reviews gains a **Re-run review** action for one that stalled.
- **Epics.** An epic that ships by pull request now stays open after
  integration instead of closing immediately — it still takes tasks, and
  the orchestrator is told its next step is to open the pull request. The
  settings picker for this is now labeled "Integrate standalone tasks and
  epics by."
- **Worktrees.** A new task branch, and a new epic branch, are now cut from
  the remote's base when local `main` is behind it, instead of a stale local
  branch; a failed fetch falls back to the local base and warns. An optional
  per-project worktree teardown hook, set on Project Settings' Workflow tab,
  now runs before a worktree is removed — including, in the background,
  when a shared-branch accept triggers the removal, so the accept itself
  returns at once. Skipped cleanup is reported rather than silently dropped,
  and a closed epic now lists which worktrees it still holds.
  A project's worktree root that was still on the old Application Support
  default — which Project Settings already refuses as a new value — is moved
  to `~/.agentboard/worktrees/<id>` automatically at launch, once nothing is
  checked out under it. A root already stored starting with `~` is still
  honored and resolves against your home folder. A worktree root is now
  chosen with a folder picker (**Choose…** or **Use Default**) instead of
  typed by hand. The orchestrator's briefing now explains where its workers
  actually run — worktree, shared, or auto.
- **Sessions.** Ending a worker in Agent Board now revokes its access
  outright: a session Claude Code revives on its own after that is stopped
  again, and a report that arrives from it late changes nothing on the
  board.
- **Settings.** A new **Settings** window (Agent Board → Settings…, or ⌘,)
  has a Terminal pane for the font and colors every Agent Board terminal
  uses — the project Terminal screen, Orchestrator Command, and attach and
  worktree-shell windows all repaint together when you change it. It
  defaults to the Night Owl theme in Monaspace Neon at 12pt, replacing the
  previous white-on-dark Terminal.app palette.

## 0.4.0 — 2026-09-30

- **Reviews.** Under Agent review, a project can now route each task type —
  Code, Docs, Tests, Plan, Review, or unset (Default) — to its own reviewer
  instead of one reviewer for the whole project. Project Settings → Agents
  shows a Default row plus a row per type, each set to a named reviewer, Any
  reviewer, A person, or **Accept without review**; existing projects keep
  routing exactly as before until a row is edited. A typed task shows a chip
  on its card, in the inspector, and in Pending reviews, and the inspector
  gets a Type picker. A rostered reviewer is now limited to the task and its
  diff — it can no longer read the worker's own notes or report, project
  notes, or the board database, and a task with no diff to review goes
  straight to a person instead of spawning a reviewer with nothing to look
  at.
- **Epics.** Accepting an epic task now merges its branch before tearing down
  its worktree, with no checkout involved, instead of reporting the task
  ready before the merge has actually run. Starting a task that depends on
  another task in the same epic now refuses if that dependency's commit
  isn't on the epic branch yet, instead of spawning against a checkout
  that's missing it.
- **Worktrees.** A worktree's setup hooks (`post-checkout`, etc.) now run
  under your login shell's PATH instead of launchd's bare one, so a repo
  whose setup depends on Homebrew or `/usr/local/bin` tools no longer fails
  when Agent Board is launched from Finder or the Dock. A setup that fails
  now rolls back the worktree it created instead of leaving a half-set-up one
  behind for the next retry to silently adopt.
- **Main window.** The window now has a 981×600 minimum size, and the
  sidebar's bottom stack (Ports, Add Project…, the notifications-off notice,
  the usage footer) no longer draws on top of the project list when the
  window is short. The Status screen's session table now fits inside that
  minimum width instead of scrolling sideways — Elapsed time and the last
  tool used moved into captions under State and Last activity, and token
  counts, cap, and cache reads moved into Spend's tooltip.
- **Roster.** Agent definitions from `~/.claude/agents` and a project's own
  `.claude/agents` now show up on the Roster screen and in project settings
  as read-only archetypes, alongside board-local agents, and can be assigned
  or set as a reviewer the same way. A board-local agent's name always wins
  over a disk definition of the same name.
- **App menu.** A new **Preview Leaked-Agent Sweep…** item opens a read-only
  window showing what the sweep that stops leaked agent sessions would do on
  this launch, with a Run Again button, before anything is actually stopped.

## 0.3.0 — 2026-09-26

- **Install.** Installing is now a DMG drag: open `dist/AgentBoard-<version>.dmg`
  (or the one attached to a GitHub release) and drag Agent Board onto
  Applications, instead of running a script. On the first launch of a new
  build, the app backs up the database automatically before migrating it,
  keeping the newest three under `backups/`. It also now refuses to open a
  database a newer build already wrote, rather than silently skipping
  migrations it doesn't recognize — quit Agent Board through **Agent Board >
  Quit** first, so it can settle any running workers before you drag in the
  new copy.
- **Task comments.** Every task now has a comment thread in the task
  inspector that you and any agent working the task can both post to —
  ⌘Return or the Add Comment button to submit. Your own comments show as
  "You"; an agent's comment is labeled by kind (Orchestrator, a rostered
  reviewer's name, or "Worker <id>"). A comment you write while a worker or
  reviewer is already running reaches it on its very next tool call, and
  survives a `/clear`. A card on the Task Board shows a comment-count badge
  once it has any. Comments are append-only — no edit, no delete, for anyone.
- **Coordinator.** A new pinned sidebar item: a Claude Code session that
  belongs to no project, for planning across all of them. It reads every
  registered project's board, notes, and sessions but writes to none through
  its own tools — to get something changed, it sends a request to that
  project's orchestrator, which can accept, decline, or act on it within its
  own approvals and caps. It's told never to touch a registered repo
  directly, but nothing enforces that beyond instruction: a Bash command like
  `git commit` or `mv` inside one still runs. Its own page lists the request
  ledger, its plan notes, and session history; At a Glance shows its running
  spend.
- **Reviews.** A rostered reviewer's session now ends the moment it accepts
  or reopens a task, the same as a worker's does at completion, instead of
  sitting idle and later getting reported as stalled or failed. A reviewer is
  no longer refused over changes it didn't make: its baseline is now taken at
  spawn — HEAD plus a fingerprint of whatever the worker had already left
  uncommitted — so leftover worker edits stop tripping every verdict.
- **Epics and pull requests.** A standalone epic integrating by pull request
  now stays open for as long as that PR is open, instead of Agent Board
  treating it as settled the moment integration is requested. When the PR
  merges, only the tasks whose commits actually made it into the merged head
  are marked landed — one accepted after the PR's last push is called out by
  name instead of being marked landed on trust.
- **Cross-project messages.** A message between two projects' orchestrators
  can now be deleted once it's been acted on — from its own row, or in bulk
  for everything already read — instead of sitting there indefinitely.
- **Stability.** A session can no longer be revived once its task is already
  done or has gone back to Ready — Agent Board used to notice the process
  was still alive and set it running again; now it stops that process and
  reports the settled state instead of a false failure. Stopping a session
  now reaps its whole process tree, including anything it started with
  `run_in_background`, so a build or watcher a worker kicked off doesn't keep
  running after the session ends. Terminal consoles opened from the app — the
  orchestrator's console, a shell console, a task's terminal window — no
  longer hold on to Agent Board's own listening port after you quit; they used
  to inherit that socket without meaning to, which could keep the port bound
  until you closed those windows too.
- **Orchestrator.** The automatic `/compact` Agent Board sends between turns
  now actually runs — it used to arrive fast enough that Claude Code read it
  as one pasted block and dropped it.

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
