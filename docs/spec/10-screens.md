## 10. Screens

**At a Glance** — the landing view, and what the detail pane shows whenever no
project is selected. A row pinned above the workspace sections in the sidebar
selects it; it stays visible when every section is collapsed, because it sits
outside them. A headline answers "is anything happening, and does anything need
me?" from one cross-project observation (`GlanceStore`) — how many agents are
working and how many tasks await review, worded so zero reads as rest
("Nothing running, and nothing is waiting on you.") rather than as a count of
absent things. When any project needs a human the headline leads with how many
do — "2 projects need you." — *beside* the review count rather than in place of
it: the review clause counts tasks in one board column, while attention counts
projects that cannot proceed, and a pending approval raises the second without
ever touching the first. Below it, one card per project — every project,
including idle ones — grouped into the same workspace sections in the same order
as the sidebar, so a project sits in the same relative place in both. A card
carries the project name and its running, in-review and ready counts, or reads
**Idle** when all three are zero. A project whose attention signal is raised
shows the same dot the sidebar row shows, beside its name, carrying the signal's
reason as its tooltip; it suppresses **Idle**, because a board with nothing on it
and an approval waiting is not idle. The page starts no observation of its own
for that: it is handed the one `ProjectAttentionStore.observeAll` the sidebar
already runs, so the two surfaces cannot disagree. Clicking anywhere on a card
selects that project through the same write the sidebar uses, landing on Orchestrator and starting
its console (§9) — which is the only way a console ever starts, so this page
itself costs nothing.

A **Coordinator** card sits above the project sections, showing the estimated
spend of every Coordinator session (§8.2) and the same unread-replies dot as its
sidebar row; clicking it opens the Coordinator page. A project card whose sessions
have spent anything shows its own total the same way, so the two read against
each other. Both are all-time sums of `agent_session.est_cost_usd`, ended sessions
included, and neither has a cap; the Coordinator total rides in the same
statement as the working-session count, so the page still runs two.

**Shut Down** — a button beside the At a Glance headline, for the wind-down
that quitting does not do on its own: workers are detached `claude --bg`
sessions that outlive the app, keep spending, and keep committing into
worktrees nothing is watching. It confirms first, naming how many agents are
working across how many projects, then raises a shutdown order (§8) on **every**
project — including ones with nothing running, so an orchestrator cannot spawn
into the gap — and only then delivers them all. One sheet shows every ordered
session from every project, each row naming its project and measured against
its own project's `shutdownGraceSeconds`, over a total that spans them
("Closing 3/5 agents across 4 projects"). It shares `ShutdownSheetBody` and
therefore the row states and wording with Stop All's sheet; the aggregation and
the decision to quit live in `AgentBoardCore.GlobalShutdown`, unit-tested apart
from SwiftUI.

The app quits once every delivery has closed. A wind-down whose remainder is
only permission prompts and silence cannot finish on its own, so **Quit Anyway**
is always offered. The orders are deliberately *not* lifted on quit: a session
that never acknowledged is still running detached, and the order standing on its
project is what hands it the wind-down through `PreToolUse` on the next launch.
**Cancel Shutdown** lifts every standing order, not only the ones this sheet
raised — a project left refusing spawns with nothing on screen explaining it is
the one outcome cancelling must not produce.

Orchestrator consoles are stopped deliberately before terminating rather than
left to die with the process, so each session is marked `stopped` instead of
looking active to the next launch. The sheet is then dismissed *before* the app
is asked to go, because AppKit refuses `NSApplication.terminate` silently while
a sheet is attached (§2) — a quit button living in a sheet cannot simply call
it. `AppQuit` waits for the detachment, and if the app is still running
afterwards it says so in an alert on At a Glance naming what is in the way,
with a Try Again that is not disabled by the failed attempt. A quit that cannot
happen is reported; it is never a button that does nothing. A session still in `setup` is untouched: the
wind-down never enrolls one (it has no agent to acknowledge), so it is still
sitting in `setup` when the app goes, and `failInterruptedSetups()` on the next
launch is what puts its task back in `ready`.

**Orchestrator Command** — the project's orchestrator terminal (SwiftTerm),
with a sidebar of everything waiting on the human, in the order it is urgent:

1. **Blocked** — workers that have stopped making progress. A task with
   `blocked = 1` joined to its newest active session, and any `running` worker
   past the stall threshold (§7), the two distinguished by a badge because one
   is a reported state and the other a suspicion. Each row shows the task
   title, the session short id, the reason (`blocked_reason`, or a note about
   stdin for a stall), and how long it has been that way. **Attach** opens the
   session's real terminal — D15, the only place a permission prompt is
   answered; **Stop** ends a worker that is wedged rather than asking.
2. **Pending approvals** — spawns awaiting authorization and integration
   requests.
3. **Pending reviews** — tasks in `review`, with branch, worktree and diffstat.
   Each row says who holds the review: `<reviewer> reviewing · <elapsed>` while
   a rostered reviewer's session is working, `<reviewer> stopped without a
   verdict` when its turn or session ended without one (§5.1), and `Waiting on you` otherwise, with the routing
   reason `Board.complete` wrote to `progress` when there is one. A typed task
   shows its type pill beside that line. While a
   reviewer is live, Accept and Reopen ask first ("Rita is reviewing this task.
   Accepting now stops Rita's review."), because either one stops the reviewer
   (§5).
4. **Proposals** — worker-proposed tasks awaiting promotion.
5. **Messages** — every §9.3 message this project sent or received, newest
   first, bold until the receiving orchestrator pulls it. Each row deletes on
   hover or from its context menu, read or not; **Clear read** in the header
   deletes every one whose report has been consumed. Deleting removes the
   message for both projects.

A blocked worker was previously invisible here: it sat in `running`, burned its
idle cap, and died with the only evidence being a `last_tool` that had stopped
moving on the Status screen.

**Stop All** — a destructive button beside Nudge/Restart/Stop in the console
footer. Confirms first, naming how many workers are running and that each is
told to commit its worktree and stop with its task going back to `ready` with
a resume note — nothing is lost. Confirming raises the shutdown order (§8),
delivers it to every running worker, and opens a modal progress sheet reading
"Closing X/Y agents" (all row-state and count logic lives in
`AgentBoardCore.ShutdownSheetModel`, unit-tested apart from SwiftUI). Each row
reads as one of:

- **ordered** — enrolled, not yet reached; its grace clock has not started.
- **closing** — handed the order, inside its grace period.
- **acknowledged** — answered `acknowledge_shutdown`.
- **not responding** — handed the order, then silent past the grace period
  (§8). Gets a Stop button; stopping it still returns its task to `ready`.
- **waiting on you** — sitting on a permission prompt. Nothing can reach it —
  no hook fires and no resume lands — so it gets **Attach** (D15) rather than
  being called unresponsive; the human answering the prompt is what unsticks
  it, in seconds rather than a kill.
- A session that ends on its own while enrolled reads **closed**, so a worker
  that dies mid-shutdown cannot hold the sheet at X/Y forever.

When every row is closed the header reads "Y/Y agents closed" and a **Quit
Agent Board** button appears, stopping the orchestrator console, dismissing the
sheet and terminating the app — in that order, for the reason above. **Cancel Shutdown** lifts the standing refusal so
spawning resumes; it restarts nothing — workers that already acknowledged
stay stopped, their tasks sitting in `ready` with their resume notes.

**Terminal** — one plain login shell per project, rooted at the project's repo
(`ShellConsole`, memoized on the supervisor beside the orchestrator consoles),
alive for as long as the app whether or not the screen is showing. Switching to
another screen or another project and back does not restart it: the segmented
control mounts and unmounts `TerminalScreenView`, but the console and its
retained `LocalProcessTerminalView` belong to the supervisor, not the view, so
nothing tears down. An exit is final and shown in the header's state dot rather
than silently respawned; **Start Again** (idle) or **Restart** (hang up and
relaunch — SIGHUP to the shell's process group, escalating to SIGKILL) is the
way back. It carries no board authority — D19 (§1).

A worker's worktree gets its own shell instead of using this screen: the
`apple.terminal` button beside the attach button on a session row opens a
`worktree-shell` window keyed by session id, its working directory the
session's recorded `worktree_path` — never composed from a worktree base,
since the default root has moved and older sessions still hold the old one. It is a separate window, not a tab on
this screen, because this screen's console is memoized for the app's lifetime,
which is wrong for a directory `accept_task` reaps out from under it; the
worktree-shell window instead disappears with the worktree, or, if the
directory vanishes while the window is still open, shows a banner over a shell
that keeps running so the human can `cd` out. A session recorded with no
worktree — it ran in the project's own checkout — points at this screen
instead.

The pair is `bubble.left.fill` for attach and `apple.terminal` for the worktree
shell, monochrome and unstyled — the same glyph the shell window itself shows
for a ready worktree, so the button and the window agree. They were one terminal
glyph twice until the symbols were split; `terminal` and `apple.terminal` are in
fact the same image on macOS 26, so the old pair was indistinguishable rather
than merely similar. The two sites differ deliberately: Status's Actions column
is width-constrained and shows icons only (a title truncates to `Ag…` there),
while the task inspector's session rows show **Agent** and **Shell**. Because
the Status column carries no visible label, the buttons' accessibility labels —
"Attach to agent session" and "Open shell in worktree", divergent from the first
word, since VoiceOver reads them consecutively along the row — are the only
thing naming them there.

**Task Board** — columns from §5, swimlanes by epic. A card shows title, epic,
assigned agent, elapsed, spend, its `blocked`/`failed` flag, and a comment count
when it has comments — one per-project count query for the whole board, not one
per card. A `done` card whose landing (§5) asks for attention shows it as a pill —
"not landed", "landing unknown", "PR pending", or "PR #N open" once a pull request
is recorded — with the landing detail, including why a merge check could not run,
as its tooltip. Drag between columns. Cards in `review` show the branch, worktree
path, and a diffstat. A typed task (§4) shows its type — Code, Docs, Tests, Plan,
Review — as a small pill beside its priority and model; a Default task shows none.
The inspector's **Type** picker (Default plus the five types) saves through the
same task update as its body and model. Changing it doesn't touch a review
already under way; the task's next completion routes by the new type.

The task inspector shows a **Comments** thread above the Progress log, oldest
first. Each comment names its author in words — `You`, `Orchestrator`,
`Rita · reviewer`, `Rita · worker`, or `Worker 3f9a1c2e` / `Reviewer 3f9a1c2e`
for an agent with no roster agent — using the roster's current name, and the
`author_name` snapshot once the agent is deleted (§4). No column records that a
comment's roster reference was ever set, so a deleted agent is told from an
unrostered one by its snapshot: one that is not the form `add_comment` writes for
an unrostered agent (§6: `Worker <short id>`; a reviewer's bare session id) is
shown as `<snapshot> · <kind>`.
The time is relative, with the absolute date and time on hover; the body is
selectable and wraps. The human's comments sit on an accent tint; agents' sit on
neutral grey behind an icon for their kind. A composer under the thread adds a
`human` comment with **Add Comment** or ⌘↩ and refuses a blank body, then tells
the orchestrator console of the `comment` report at once (§9.1). Its draft
belongs to the task it was typed on: selecting another task shows that task's own
draft, and returning restores the first.

The toolbar's **Archive** button names its target set in its label — "Archive
23 Done Tasks" — and confirms before acting; it is offered under every archive
policy (§4), because the automatic modes save the human from remembering, not
from deciding. With the **Show Archived** toggle off (its state at every
launch) an archived card is hidden and each column that is hiding one says so
in a small per-column count — "3 archived" — rather than letting the work
disappear silently. Turning the toggle on draws archived cards back into the
columns they actually sit in (always `done`), dimmed to 55% opacity with a
dashed border and an "archived `<when>`" line; from there a card's context menu
or the inspector unarchives it.

**Finished epics leave the board.** With Show Archived off, a `done` or
`abandoned` epic whose tasks are all archived, or that has no tasks, gets no
lane and no jump-rail entry, and the rail itself is dropped when no epic has a
lane. Every other epic state keeps its lane, even when empty. Turning Show
Archived on brings those lanes back, collapsed by default like every `done`
lane. Nothing records this: it is derived from the epic's state and its tasks'
`archived_at` (`EpicLaneVisibility`), with no flag, state or column of its own.
A Coordinator epic link to a hidden lane turns Show Archived on, so the link
still lands. A `done` epic's lane header carries **Archive N Done Tasks** while
it holds a `done` task the archive sweep would take; it archives every one of
them in one transaction, the synthetic `integration` task included, through the
same `ArchiveSweep.archiveEpic` `afterEpicMerge` uses (§4). It is offered under
every policy, and is how a `manual` or `afterDays` project clears a finished
epic in one click.

**Searching the board** — a search field heads the board, filtering in place:
a matching card stays in its own column and lane, and nothing is regrouped
into a results list. Every whitespace-separated term must appear, case- and
diacritic-insensitively, in one of the task's title, body, acceptance criteria,
epic title, model (id or display name), type name (§4), or the name of the
rostered agent that last worked or reviewed it; the task id is not searched. While a query is
active an epic lane with no match vanishes, header and rail entry included,
and a collapsed lane with a match is drawn open without changing its saved
state. The lane header's done/total tally and actions still count the whole
epic. Search does not reach past **Show Archived**: an archived match stays
hidden, but its lane stays with the per-column "1 archived" notice — a
finished epic's hidden lane comes back for it — and the
summary beside the field says "1 archived match hidden". The summary reads "3
of 41 tasks", or "No tasks match “idle cap”" in place of an empty-result
screen. ⌘F (**Edit ▸ Find…**) focuses the field of whichever screen is showing
and is disabled on a screen without one; Escape in the field clears it. The same
field (`SearchField`) is the one Notes and Status use, so that wording and ⌘F
are decided once. The filter is in memory over rows the board already observes,
with no FTS table. Each task's searchable text is folded once into an in-memory
index, rebuilt only when the tasks, epic titles or agent names change; a render
with no query builds none. Measured on the largest real board, 235 tasks and
793 KB of text, in a debug build: folding costs 17 ms and matching over folded
text 2.5 ms, so one board layout costs 0.7–1.0 ms with no query, 3.4–3.7 ms per
keystroke, and 20–22 ms when a task changes under an active query.

**Ending an epic by hand** — the epic lane header carries a `…` menu with
**Close as done** and **Abandon**. Integration (§5.2) is how an epic ends when
it is *finished*; these are how it ends when *you* are finished with it —
"I got what I needed out of this" and "this was the wrong idea" respectively.
Both are terminal, the lane badge already draws them apart (green and red), and
neither is offered on an epic that is already in one.

Closing is a board state change and nothing else. It does not merge
`agentboard/epic-<id>`, does not open a pull request, and does not touch a task
branch. **No branch and no worktree is deleted** — exactly as a `done` task
keeps its branch until integration. Unfinished tasks stay exactly where they
are: same lane, same column, same `epic_id`, not deleted, not archived, not
re-homed. Silently rewriting a human's unfinished work is not what "I am done
with this epic" asks for, and the epic is the record of what that work was for.
Work left in a closed epic is freed with `set_epic(task_id)` and no `epic_id`
when it still matters, which the `decision` report says in so many words.

The confirmation names all of it before the human commits: the state being
written, the specific leftover tasks and their columns, that they stay put, and
that the branches and worktrees survive. Its copy and the write's guards read
the same `EpicClosurePlan` (`AgentBoardCore.EpicClosure`, unit-tested apart
from SwiftUI), so the dialog cannot promise something `Board.closeEpic` refuses.

Closing is **refused**, not forced, while any session in the epic is still
active — the integrator's included, since it is bound to a synthetic task inside
the epic. The refusal names each live worker by task and short id, the way the
Stop All sheet does, and stops nothing itself: a live session is never orphaned
against a closed epic, and the human stops it from its card or from Stop All and
closes afterwards. `close_epic` (§6) does the same thing for the orchestrator
under the same guards; workers get no such tool.

**Status** — the agent roster. Reconciled from `claude agents --json --all`
joined against `agent_session`, so a session that died outside the app is shown
as dead rather than phantom-running. A session listed as running on a task in
`done`, or in `ready` with no other session on it, is not set running again:
`reconcile` stops its process, and a row still active is ended with the
settled-task `decision` report (§5.1), never a `failed` one. Per agent: role,
task, state, elapsed, spend
against cap, last tool used. A blocked agent's row opens its terminal, which is
how permission prompts get answered (D15).

The role names the roster agent a session runs as: `reviewer · Rita`,
`worker · Rita`, or plain `worker` with no roster agent. A reviewer on a typed
task carries the type too: `reviewer · Rita · Code`. Reviewing is read from
the scope of the first grant bound to the session — the scope it launched
under, which a resume does not erase — or, before any grant is bound, from the
task naming that agent as its reviewer. Under review level `agent`, a line
above the roster says where `ReviewPolicy` sends finished tasks by the routing
table's Default row (§4): the agent, a person (with the reason when there is
one), or accepted without review. Beneath it, one compact line lists each type
row whose value differs from Default's, e.g. `Plan: no review · Review: Roscoe`,
with any person-routing reason as its tooltip; a row set to the same value as
Default is not listed. Under any other level there is no line.

Below the roster, the ports **this project** holds — the same rows the sidebar
panel draws, in the same `PortRow`, filtered to this project rather than swept
again. The pane starts no sweep and carries no refresh button of its own: the
panel that owns both is on screen beside it, and a second timer over the same
process table would double the cost and let the two surfaces disagree between
ticks. A port belonging to another project is absent here and still present in
the sidebar.

An **orphan appears here whenever its ended session still names a project**.
`agent_session` and `task` outlive the process, so a ledger-sourced row resolves
a `project_id` and lands on that project's pane — the dev server whose session
ended an hour ago is exactly the row this is for. When this project holds no ports the
section draws nothing: the sidebar panel keeps its header line when empty because
that line carries the refresh button, and this section has no button to keep.

**Searching the Status pane** — the same `SearchField` as the board, heading
the pane, narrows the roster and the ports section together: `:3000` finds a
port, `idle cap` finds a session's task and the port that session holds. Terms
match as on the board, every one somewhere in a single row. A session row
matches on its short id, task title, role label (so the rostered agent's name),
state as drawn and as stored (`setting up`, `setup`), and model id or display
name; not on its last tool, which changes under the query while the session
works, nor its full session id. A port row matches on `:<port>`, its command,
and its owner's title — the task, `Session …`, or `Terminal`; not on the project
name, which every port on one project's pane shares. As an epic lane does on
the board, a ports section with no match disappears, header and divider
included. The roster table keeps its column headers with no rows, and its
"No Sessions" placeholder still describes the unsearched roster. Search does
not reach past **Show ended**, the way the board's does not reach past Show
Archived: the summary counts ended matches instead — "No sessions match “idle”
· 1 ended match hidden · 1 of 2 ports". Filtering reads the rows the sidebar
panel's sweep already holds, so a query starts no sweep.

**Roster** — the cross-project register of specialists (§4), and the one screen
not scoped to a project: a `Roster` row in the sidebar beside `At a Glance` and
above the workspace sections, so it does not join Task Board and Status inside a
project. Per agent: name, role, model, an enabled switch, and the task it is
mid-way through. Add, edit and delete; the editor covers name, role, system
prompt, model and enabled. Deleting an agent that is working is **refused**, and
the confirmation names the task holding it, because deleting would leave a live
session with no identity behind it. Which agents a project uses is chosen in
that project's settings sheet, one toggle per rostered agent, writing
`project_roster_agent` immediately rather than on Save — those are join rows,
not part of the settings blob the Save button rewrites.

Enabled agents sort above disabled ones, then by name case-insensitively, then
by id so the order is stable. "Working" means a live `agent_session` carrying
that agent's `roster_agent_id` (`RosterStore.assignments`); a session that has
ended does not count, or a finished pass would strand its agent undeletable.

**Coordinator** — the Coordinator's page (§8.2), and the third pinned sidebar
row, directly below `Roster` (`SidebarSelection.pinned`). The row carries a gear
for the **Coordinator settings** sheet — one `ModelPicker`, defaulting to
**Claude Code default**, saved through `CoordinatorStore.setModel` — and the
attention dot while `reply` reports wait unread in the Coordinator's queue (§9.1).
The page is laid out as a project's Orchestrator screen: the console, with the
same header minus **Stop All**, started when the page opens, beside a sidebar of
three sections:

- **Requests** — the ledger (§9.4), newest first: target project, the request's
  first line, its state (`sent`, `accepted`, `declined`, `done`, `withdrawn`), the
  latest text an orchestrator replied with, and one link per linked epic. A link
  selects that project on its Task Board and scrolls to the epic's lane, through
  the same route a banner click uses (`NotificationRoute.Subject.epic`). Each
  click routes once: the board returning to view later does not scroll again.
- **Plans** — the Coordinator's notes (project NULL). Each opens read-only in a
  sheet; the Coordinator writes them through its note tools.
- **Sessions** — **New Session**, the active session, and the history; clicking
  a history entry resumes it. Each shows its start and its spend.

**Notes** — list and full-text search, sectioned editor, pin toggle, and the set
of tasks/epics each note is attached to. Shows which agent last wrote each
section. Each section header carries a copy button that puts that section on the
clipboard as `## heading` followed by the text on screen — unsaved edits
included, since that is what the human is looking at.

**Searching notes** — the shared `SearchField` (see *Searching the board*)
heads the Notes screen and filters the list in place through
`NoteStore.search`, the same FTS5 query `search_notes` runs; there is no
second search path. A note matches on its title or on any section's heading
or text, since `note_fts.body` is every section joined. The field's text is
not FTS5 syntax: each whitespace-separated term becomes a quoted literal
matched as a token prefix, all terms required (`NoteSearch.ftsQuery`), so
"idl" already finds "idle", and `cap:`, `AND` or an unbalanced quote are
searched for rather than parsed — a half-typed query cannot raise a syntax
error. A term with no letter or digit is dropped, and text with nothing left
leaves the list unfiltered rather than empty. Matching is by token prefix,
not substring: "dle" does not find "idle", unlike the Task Board. The list
keeps its own order (pinned first, then most recently updated) while
filtered and ignores the bm25 rank, so a note does not jump as the query is
typed out and is where it was when the query is cleared. An empty result is
said beside the field ("No notes match “…”"), not in place of the list. A
selected note stays open in the editor even when the query hides its row.

**Project sidebar** — projects grouped into workspaces. Each workspace is a
collapsible section in `workspace.ordering` order holding the projects whose
`workspace_id` names it; projects with no workspace (or one that has since been
deleted) fall into a trailing **Ungrouped** section, which is hidden when empty
and loses its header entirely when no workspaces exist. An empty workspace still
shows, so it can be dragged into. Grouping is optional — an ungrouped project
works end to end.

Workspaces are created, renamed, reordered and deleted from a menu beside
**Add Project…**; deleting one never deletes its projects, they become
ungrouped. A project is assigned from its settings sheet (a picker of the
workspaces plus **None**) or by dragging its row onto a section header. Which
sections the viewer has collapsed is a per-viewer convenience and lives in
`UserDefaults`, not the database.

**Ports** — a panel directly above **Add Project…**, listing every TCP socket
in `LISTEN` that a process Agent Board started is holding. A row is the port
number, the command holding it, and who it belongs to: the task title and
project of the session that opened it, or **Terminal** and the project for the
per-project shell console. **A port is drawn only when the board can name that
owner** — a session `agent_session` records, live or ended, or a project's shell
console. A socket nothing names, or one pinned on a session this board has no
row for, is not drawn: ControlCenter, Steam, an editor, an interactive `claude`
session's dev server and a second Agent Board instance's server port all look
like that, and Agent Board has no evidence it started any of them. The
consequence is stated rather than hidden: a dev server orphaned between two
sweeps, or one whose project was deleted, has no row. `BoardServer`'s own port
is never a row — it is excluded inside the sweep, not by this panel.

The panel is never taller than twice the account-usage footer beneath it,
header included: 286 points against the full two-window footer's measured 143.
The ceiling tracks the footer's live height, and falls back to that 143 when the
footer has no reading to draw. It is also never taller than the room the sidebar
has left once the project list keeps its reserve (§10.1), so in a short window
the panel gives way before the list does. Below the ceiling the panel is as tall
as its rows; at it, the rows scroll under a header that stays put, because the
header carries the only refresh button and the collapse chevron. The sidebar's
bottom stack grows upward, so every point the panel claims comes out of the
project list.

Two link targets in a row, going to different places on purpose. The number
opens `http://localhost:<port>` in the default browser. The owner name opens the
session, through `NotificationRouter` and `MainWindow.select` — the same funnel a
clicked notification uses, so a port row starts a project's orchestrator exactly
as a sidebar click does. A session-owned port routes to Status, a shell-console
port to Terminal. A session that has *ended* still keeps its name and its route: `agent_session` and
`task` hold the title after the process is gone, and that row — the dev server
whose session ended an hour ago — is the one a human otherwise finds only with
`lsof -i :3000` and guesswork.

Each row also carries a **stop** button. It signals a process *group*, not the
listening pid: `kill(-n, …)` addresses the group whose id is `n`, and a measured
`npm run dev` puts the listening `node` in its parent `npm`'s group without
leading one, so its own pid names no group at all. The stop reads the listener's
`pbi_pgid` and signals that group only when the group leader is the listener
itself or one of its ancestors *and* no member of the group is a process the
board runs long-term — its own pid and process group, every `claude` session
host the registry lists, and every shell console's shell. When either condition
fails it signals the listening pid alone and accepts that a supervisor above it
may respawn, because the alternative is a stop button beside a dev server that
kills an agent. SIGHUP first, matching what a closing terminal window sends and
what `ShellConsole.hangUp()` already does; SIGKILL after a two-second grace as a
backstop.

`BoardServer`'s own port is refused before anything else happens — before the
process table is read — even when the stop is handed it directly. The sweep
already excludes it so no row can exist for it; this is the second wall, because
a stop path that could ever take that port is a path that kills every agent on
the machine.

A stop sweeps again on completion, so the row goes rather than waiting for the
hourly refresh. A port still held after the escalation keeps its row and says
so: silently dropping a row for a process that is still listening would hide it
until the human found it again with `lsof`.

Only a port owned by a session running *right now* asks first, and its
confirmation names the task. An accidental click on an orphan costs a dev server
the human can restart, and a dialog on the row this panel exists for is friction
on the common case; a live session's port may be load-bearing for work in
flight, and a worker that starts failing because its dev server vanished reads
as a bug rather than as a consequence. The shell console is deliberately in the
no-confirmation group — the human typed the command that opened the socket.

The list is swept hourly, on the panel's refresh button, after a stop, and when
the panel is opened. When nothing is listening the panel is its header line and
nothing else:
no empty box, because the sidebar already holds every project and the space is
not free. The header still costs that one line rather than collapsing to zero,
because it carries the refresh button — the sweep is hourly, and a panel that
vanished entirely would leave nobody to ask about a port that appeared since.

**Project settings** — a sheet from the sidebar row's gear, in six tabs:
**General** (Repository, Workspace, Archive), **Agents** (Models, Review,
Autonomy, Roster), **Limits** (Caps), **Workflow** (Verification, Isolation,
Publishing), **Notifications**, and **Advanced** (the `autoMode` classifier JSON,
Extra MCP servers). Tabs group by what a setting governs, not by how often it is
touched. Every section is in exactly one tab; a section in none would be a stored
setting with no UI. **Delete Project…** sits outside the tabs, at the left of the
Cancel/Save row, so it is reachable from every tab. The sheet is at least 780pt
wide: that is where the grouped form stops widening its rows (~665pt), so the
classifier editor holds 77 monospaced columns and a wider sheet adds only margin.
Both multi-line editors span the full row: model guidance sits under its label
(at least 100pt tall), and the classifier is a plain-text editor at least 280pt
tall, enough for the shipped default without scrolling, with smart quotes, smart
dashes and text replacement off so typed JSON parses. Every section's help text
is the last row of that section, in every tab. Limits keeps a tab of its own: its
six caps fit one page, while Agents and Workflow already scroll at the sheet's
minimum height.

Agents' **Review** section holds review level (§5), captioned with what each
option does to a finished task, and below it — disabled outside `agent` — the
review routing table (§4): a Default row, then one for each of Code, Docs,
Tests, Plan and Review. Every row is a picker of the project's own roster
agents in roster order (one disabled roster-wide is still pickable, suffixed
`(disabled)`, since routing only checks at completion time, §4), then Any
reviewer, A person and Accept without review; a type row lists Same as Default
first. A row's currently-named agent that has left the project entirely —
deleted from the roster or opted out — stays listed anyway, suffixed
`(not available)`, so the picker shows what routing will actually do rather
than silently dropping the choice. A caption beneath the table repeats that it
takes effect only while Review level is Agent.

**What's New in Agent Board** — the release notes, opened from the Help menu and
once on their own after an update installs. A `Window` scene rather than a
`WindowGroup`, so choosing the menu item again — or a second launch that decides
to show them — brings the open window forward instead of stacking a second one;
resizable, scrollable, closed with ⌘W, and never a sheet, because notes are read
beside the board rather than in front of it. Every release in the bundled
`RELEASES.md` is in one scroll, newest first, with the running version marked —
three entries need no navigation, and a version list beside a detail pane is what
this wants once there are twenty.

`RELEASES.md` at the repo root is the one source: one `## <version>` heading per
release, optionally ` — YYYY-MM-DD`, free Markdown beneath, newest first, with
everything above the first heading a preamble `ReleaseNotesParser` skips.
`Scripts/bundle.sh` copies it byte for byte into `Contents/Resources` alongside
`Info.plist` and the icon — nothing about the file is generated or rewritten at
build time. `Scripts/release.sh` copies it the same way and stamps the bundle's
`CFBundleShortVersionString` from the file's newest heading (with the commit count
as `CFBundleVersion` and the sha as `AgentBoardCommit`), then checks the stamped
plist against the bundled file before it packages anything, so a release cannot
ship notes that disagree with its own version. A `bundle.sh` dev build still
reports whatever `Resources/Info.plist` hard-codes. `AppBundle.isAppBundle` (a bundle identifier and a `.app` path
extension) gates every read: the `.build/debug/AgentBoard` binary `README.md`
documents for E2E runs has neither, so `ReleaseNotesLoader` returns
`.unavailable` before it looks for a version or a file at all. That is a
deliberate silence, not a hidden error — the same predicate `MacNotifier`
already used for the same reason — and the Help item still opens the window,
which says plainly that this run has no notes to show rather than pretending
the menu item isn't there.

Markdown is rendered by splitting each release body into blocks
(`ReleaseNotesMarkdown`) and handing only the inline markup of each block to
`AttributedString(markdown:)`. Passing a whole body instead loses every block
boundary: measured, a paragraph, a two-item list and a heading come back as one
run-on line with the bullets and hashes stripped, because `Text` does not consume
the `presentationIntent` attributes the parser writes.

The menu item is always present and always opens the window. A build that ships
no readable notes — the bare `AgentBoard` binary, or an `.app` whose
`RELEASES.md` will not parse — gets a window saying which of those it is. Hiding
the item would read as "this app has no release notes", and a disabled item gives
no reason at all.

**Shown once, after an update.** `UserDefaults` holds the last version whose
notes were shown — per-user app state, so not the database, and not worth a
schema migration for one string. On launch the window opens by itself when the
running version is above that record *and* `RELEASES.md` has an entry for it;
the record then moves to the running version. Shown counts as shown whether or
not the human read it: whether the window was looked at is not something to
detect, and trying would mean showing it again to someone who closed it on
purpose.

The two cases this hinges on are **no record** and **a record from an older
version**. No record is a first ever install: it records the running version and
stays silent, because someone opening the app for the first time wants the app,
not a changelog of a product they have never used. Reading it as an upgrade
instead would greet every new user with a release-notes window.

A **downgrade** — running a build older than the record — shows nothing and
leaves the record alone; the record names the newest notes a human has been
given, and running an older build does not un-give them. An **upgrade the author
wrote no entry for** shows nothing but still records, so the decision is not
re-made on every launch until a version with notes arrives. The `.unavailable`
and unparsable-`RELEASES.md` states do nothing at all, record included: burning
the record on a build whose notes will not parse would swallow those notes for
good once the file is fixed.

It opens **last in the launch sequence**, after `supervisor.start()` has returned
— the server bind, the stale-lock sweep and the worktree-root migration — and
with the board already on screen. Each of those writes to the board the human is
about to be shown, and a window over the middle of that hides work still
settling.

It does **not** stand aside for a board that already needs a human. Deferring has
no later that is better: holding the record back starves the notes on every
launch that has an approval waiting, and releasing it mid-session puts the window
over whatever the human is then doing rather than over a board they have not
touched yet. The notes are a separate, non-modal, ⌘W-closable window, and every
attention signal is still standing behind it when it is closed or ignored.

The Help menu is added to with `CommandGroup(after: .help)`, never
`replacing:`. The `.help` group holds two items in this app — **AgentBoard Help**
and **Toggle Sidebar** (⌃⌘S), which SwiftUI files under Help because the View
menu is empty — and replacing the group deletes both, taking the shortcut with
it. Neither placement affects the Help search field: AppKit adds that to whatever
menu is `NSApp.helpMenu` when the menu opens, and it is never an item in the
built menu.

### 10.1 Main window size

**The rule: at or above the minimum window size and the minimum detail width,
every main-window screen lays out with no view drawn over another and no text
clipped.** A table or board that scrolls sideways is laid out, not clipped; a
label cut off by its container is not. Below the minimum the window does not
resize: the scene declares `.windowResizability(.contentMinSize)` and
`MainWindow` carries a matching minimum frame, so AppKit refuses the drag rather
than SwiftUI squeezing a screen past its own minimums. The screens the rule
covers are At a Glance, Roster, Coordinator, a project's Orchestrator, Task
Board, Status and Notes, and the project settings sheet over them.

| | Minimum | Why |
|---|---|---|
| Detail pane width | 761pt | The Orchestrator and Coordinator screens are the widest fixed layouts: a 480pt console, the split's 1pt divider and a 280pt approvals or requests sidebar. At 760 the sidebar's trailing point is cut off. |
| Sidebar width | 180pt, 220pt ideal | Unchanged. The bottom stack holds its measured heights at 180 (the usage footer is 143pt at both widths). |
| Window width | 981pt | The sidebar's 220pt ideal plus the 761pt detail minimum, so the default sidebar never pushes a screen below its own minimum. It also holds the 780pt project settings sheet. |
| Window height | 600pt | The tallest fixed stack a screen needs is the sidebar's: the project list's reserve plus Add Project, the notifications-off notice and the usage footer. Measured at the 180pt sidebar: 44 + 86 + 143 = 273pt, plus 224 for the list, is 497pt of the 548 a 600pt window leaves under a 52pt toolbar (the unified
toolbar's usual height, assumed: an offscreen test window has no toolbar). The remainder goes to the Ports panel's header and rows. 600 also holds the settings sheet's 480pt minimum under the toolbar. |

**The sidebar list always keeps seven rows' worth of height** (224pt, at the
sidebar's 32pt row pitch: the three pinned rows, a section header and three
projects), and scrolls within it. The bottom stack — Ports panel, Add Project…,
the notifications-off notice and the usage footer — sits *below* the list, not
in a `safeAreaInset` over it: an inset lets the list scroll beneath it, so any
row past the fold is painted under the stack's text at every window height, not
only a short one. The Ports panel is the only part of the stack that shrinks. Its
ceiling (§10) is also bounded by the column's height less the list's reserve and
the rest of the stack, down to its header line. The usage footer never collapses,
because it is the one element whose reading has no other place in the window, and
the notice and Add Project are one or two lines each.

Measured at the minimum, rendered offscreen at 761×548 for a detail pane under
the toolbar: At a Glance fits three card columns; Roster, Orchestrator, Notes and
Coordinator lay out at their own minimums; the Task Board scrolls sideways
through fixed 250pt columns, which it does at any width. Status is the one screen
the minimum does not serve well. Its session table's column minimums alone sum
to 760pt before cell padding, so it scrolls sideways at any detail width below
about 920pt, and Actions starts out of view. That is a column redesign rather
than a size, and it is filed as its own proposal rather than folded into this
rule.
