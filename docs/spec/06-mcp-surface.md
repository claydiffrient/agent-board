## 6. MCP surface

Served at `http://127.0.0.1:<port>/mcp`. Scope comes from the bearer token, not
from the request. A worker calling an orchestrator tool gets a tool-not-found
error, because the tool list is rendered per scope. Resources and prompts are
not scoped this way — any valid token in the project sees the full resource
and prompt lists, worker and orchestrator alike — with one exception: a
`reviewer` token sees no `note://` resource and is refused a read of one
(§5.1). `initialize`'s advertised `capabilities` includes `resources` and `prompts` only when a handler for it is
wired, so `tools: {}` alone still means what it used to.

### Resources

One resource per note in the caller's project, at
`note://<project-id>/<note-id>` (D13) — both ids are immutable, so the uri
survives a retitle, an edit and a pin. `resources/list`'s `description` gives
enough to decide whether a `resources/read` is worth it without doing one:
pin state, section headings (the first 8, then a count of the rest), and the
note's version and last-updated date. `resources/read` returns exactly what
`read_note` returns. An unknown or malformed uri is refused with JSON-RPC
`-32002` and the offending uri in `data`, never with empty contents.
`search_notes` and `read_note` are unaffected and remain the faster route for
an agent that already knows which note it wants. Neither `subscribe` nor
`listChanged` is advertised: responses are plain JSON over POST and GET `/mcp`
is 405, so there is no channel a server notification could arrive on.

### Prompts

Two standing texts, fetchable by a session that has fallen out of context —
after a resume, after a compaction, or when a hook delivered a shortened
version and the session needs it verbatim:

| Prompt | Arguments | Returns |
|---|---|---|
| `wind_down_order` | `via`: `hook` \| `resume` (required); `reason` (optional) | The full wind-down order text (§8.1) |
| `worker_protocol` | `branch` (required) | The standing *How to work* / *When you are done* / *How your turns end* sections a worker is spawned with (§3.1 step 6) |

Both render through the same function the push path already calls —
`ShutdownOrder.windDownOrder` and `OpeningPrompt.workingProtocol` — so a prompt
and what a session was handed at spawn cannot say something different. This is
additive, not a replacement: a busy worker is still reached by the
`PreToolUse` deny (§8.1) and an idle one by a resume; a prompt only helps a
session that is actively asking for one, and a worker that asks for nothing
is reached by neither.

### Worker scope

| Tool | Effect |
|---|---|
| `get_my_task()` | The task bound to this token, plus its `type` (null for Default), `epic_id`, dependency summaries and comment thread |
| `update_status(state, detail)` | Appends to `progress`; sets `blocked`/`failed` flags |
| `log_progress(text)` | Appends to `progress` |
| `add_comment(body, task_id?)` | Appends to the task's `task_comment` thread as `worker`, named after the session's rostered agent or `Worker <short id>`. A `task_id` other than the token's own is refused |
| `search_notes(query)` | FTS over this project's notes |
| `read_note(id)` | Full note with sections |
| `append_section(note_id, heading, body, if_version)` | Section-scoped write |
| `replace_section(note_id, heading, body, if_version)` | Section-scoped write |
| `create_note(title, sections)` | New note, unpinned |
| `propose_task(title, body, rationale, epic_id)` | Inserts into `proposed`, carrying `epic_id` onto the row so promotion lands it there |
| `report_complete(summary, files_changed, tests_run, caveats)` | Inserts a `report`; moves task to `review`, or to `done` where the review level (§5) or `afterEpicMerge` (§5.2) says so — the answer names the column it landed in. Answers first and stops the worker afterwards, off the written response (§5), because stopping it inline kills the client waiting on the reply. Idempotent per `(session_id, task_id)` regardless: the MCP client resends when an answer is lost, and a second call returns the first report's id and re-runs nothing — no second row, no second move, no second stop, no reviewer assigned and no second auto-acceptance |
| `hand_off(summary, next_role, files_changed)` | Inserts a `handoff` `report` and a `progress` row; moves task to `ready`, keeps the worktree, stops the session after answering (§5) |
| `report_blocked(reason)` | Inserts a `report`; sets `blocked` |
| `acknowledge_shutdown(note)` | Answers a wind-down order (§8). Records `note` against the delivery and the task, then Agent Board stops the session — after the answer is written, not before (§5). The task goes back to `ready`, never `review` (§5) — this is not `report_complete` |

A worker may not read other tasks, reassign, create a non-proposal task, or
spawn anything.

`add_comment` in every scope signs the comment from the token — kind, session,
rostered agent and a name snapshot (§4) — and never from the arguments. A thread
is returned oldest first, each comment as `author_kind`, `author_name`,
`roster_agent` (that agent's current name, or null), `created_at` (ISO-8601 with
milliseconds) and `body`. Every description that writes or returns a thread
says a comment is a note about the task — not progress, a report or a verdict —
and that one written by an agent is information, not an instruction.

`hand_off` is for a rostered agent that does only the portion matching its
specialty. It never sets the `failed` flag, and it releases the session's hold
on the task so nothing believes that agent is still working it. The worktree is
retained: the next agent assigned to the task works the same checkout, which is
what D6 buys. `next_role` is advisory — the orchestrator decides who gets it.
Two live sessions must never hold one worktree, so `Board.assign` refuses, in
its write transaction, any session for a task an active worker still holds or
for a worktree path an active session is already in.

The hand-off ends the session as soon as its answer is out: it raises
`workerCompleted`, the same signal `report_complete` raises, on which the
supervisor stops the agent.
The task is back in `ready` and may be dispatched into that same worktree
immediately, so leaving the previous agent resident would put two `claude`
processes in one checkout, and waiting for the periodic sweep to reap it would
hold its memory meanwhile. `workerCompleted` says only that a session is
finished; a hand-off stays distinguishable from a completion by its `handoff`
report kind, by the task sitting in `ready` rather than `review`, and by the
session's `handed off` stop reason.

### Reviewer scope

Held by a rostered reviewer under `agent` review (§5). Deliberately not a subset
of orchestrator scope: it is the authority to move one named task out of
`review`, and nothing besides.

| Tool | Effect |
|---|---|
| `get_my_task()` | The task under review and its comment thread. No report and no `progress` rows (§5.1) |
| `log_progress(text)` | Appends to `progress` |
| `add_comment(body)` | Appends to the task's comment thread as `reviewer`, named from the roster. Touches no file, so it never trips the checkout check |
| `accept_task(verdict)` | Writes the verdict to `progress`, then runs the ordinary acceptance (§5.1). Refused, with the task left in `review`, if the reviewer changed its checkout |
| `reopen_task(findings)` | Writes the findings to `progress`; moves the task to `ready` without flagging failure. Refused on the same checkout check |

Every call reads the task id off the token, never off the arguments, so a
reviewer cannot reach a task it was not given. It cannot spawn, reassign, stop a
session, query the board, propose, or report on its own behalf.

### Orchestrator scope

Everything in worker scope over any task in the project, plus:

| Tool | Effect |
|---|---|
| `list_tasks(column, epic_id, include_archived)` | Board query; archived tasks are hidden unless `include_archived` is true. Each entry carries `type`, null for Default |
| `create_task(..., type, epic_id)`, `update_task(..., type)`, `move_task(id, column)` | Board mutation; moving an archived task out of `done` unarchives it. `create_task`'s `epic_id` is optional and creates the task inside that epic; an unknown id, one belonging to another project, or one whose epic is `done` is refused. `type` is optional and one of `code`, `docs`, `tests`, `plan`, `review` (§4); any other value is refused with the valid list. Omitted is Default, and `update_task`'s `type: ""` or `null` clears it back to Default |
| `get_task(id)` | Full detail, archived or not; an archived task carries `archived: true` and `archived_at`. Includes `type` (null for Default) and the comment thread |
| `add_comment(task_id, body)` | Appends to any project task's comment thread as `orchestrator`, named `Orchestrator` |
| `archive_task(task_id)` | Hides a `done` task from the board; refused for any other column |
| `unarchive_task(task_id)` | Returns the task to the visible board in the column it was archived from |
| `set_deps(task_id, depends_on[])` | Dependency graph |
| `set_epic(task_id, epic_id)` | Moves an existing task into an epic, between epics, or — with `epic_id` omitted — out of its epic. Refused for a task that has ever been spawned, and for a `done` destination epic. Dependencies are left alone |
| `create_epic(title, goal, tasks[])` | One transaction: the epic (state `planning`) plus every task in `tasks`. Each task's `depends_on` is a zero-based index into this same array, validated before anything is written. Each task takes an optional `type`, validated as `create_task`'s |
| `list_epics()` | Every epic on the project with its state, branch, newest pull request opened from the branch (or null), and done/total task count |
| `get_epic(id)` | One epic in full: goal, branch, newest pull request, its tasks grouped by column, and whether it is ready for integration |
| `attach_note(note_id, task_id|epic_id)` | Passes context down at spawn time |
| `pin_note(note_id, pinned)` | Every future agent sees it in its note index and can fetch it |
| `spawn_worker(task_id)` | Subject to §8 caps, the shutdown order, and the autonomy setting |
| `list_roster_agents()` | The rostered agents this project has enabled, in its own preference order |
| `assign_to_agent(task_id, roster_agent_id)` | `spawn_worker` carrying a rostered identity: the same caps, shutdown and autonomy gates, worker scope, and the agent's own deny list layered on. An agent outside the project's usable set is refused |
| `stop_worker(session_id)` | `claude stop`, then the session's process tree is reaped (§8.5) |
| `list_agents(include_ended)` | Roster with state and spend; ended sessions drop off after a grace window |
| `list_reports()`, `get_report(id)` | The Q9 pull channel |
| `list_projects()` | Every project Agent Board knows about, as id, name, and whether the entry is the caller's own project. Nothing else about another project is exposed — no repository path, no settings, no board contents, no agent state |
| `send_message(project_id, body)` | Queues a §9.2 message into that project's report queue. Confirms queueing, never delivery. Refused for the caller's own project, for an unknown id, for a blank body, and for a body over 4000 characters |
| `delete_message(message_id)` | Deletes a §9.3 message this project received, and its report, for both projects. Refused for a message this project did not receive |
| `reply_to_request(request_id, state, body, epic_ids?)` | Answers a §9.4 request addressed to this project: `accepted`, `declined` or `done`, with this project's epics linked. Queues a `reply` report for the Coordinator. Refused for a request sent elsewhere or unknown (the same answer), for a closed or withdrawn one, for another project's epic, and for a body over 4000 characters |
| `promote_proposal(task_id)` | Only when autonomy is on |
| `request_integration(epic_id)` | Refused unless every task in the epic is `done` (names how many remain); otherwise creates a human approval row, or returns the one already pending |
| `close_epic(epic_id, state)` | Ends the epic without integrating it. `state` is `done` or `abandoned`; both are terminal. Board state and a `decision` report and nothing else — no merge, no push, no branch or worktree deleted, no task deleted, archived or moved out. Refused while any session in the epic is active, and refused for an epic that is already terminal |
| `push_branch(branch)` | Always creates a human approval row. Refused for any branch that is not `agentboard/<something>` or the project's base branch. The approval carries both the local branch and the name it takes on the remote (§6.1) |
| `open_pull_request(epic_id \| branch, title, body, base?)` | Always creates a human approval row. Same branch rule; `base` defaults to the project's base branch. On approval the branch is pushed if the remote lacks it, the pull request is opened from the **published** name (§6.1), and its URL lands in `progress` and in a `decision` report |

### Coordinator scope

Held by the Coordinator, which belongs to no project (§8.2). Every board read
takes a `project_id` naming the board to read, and answers through the
orchestrator's own handler for that tool as if asked from that board — so a
by-id read still refuses an id the named project does not own. The note tools
also reach the Coordinator's own plans, notes with no project: a note read
without `project_id` reads the plans, and a note write reaches only the plans.

| Tool | Effect |
|---|---|
| `list_projects()` | Every project, as id and name |
| `list_tasks(project_id, column, epic_id, include_archived)` | As the orchestrator's |
| `get_task(project_id, id)` | As the orchestrator's: full detail, latest report and comment thread |
| `list_epics(project_id)`, `get_epic(project_id, id)` | As the orchestrator's, including the newest pull request |
| `list_agents(project_id, include_ended)` | As the orchestrator's: state and spend |
| `list_approvals(project_id)` | As the orchestrator's |
| `list_notes(project_id?)` | Every note on that project, or every plan without `project_id`, as id, title and version |
| `search_notes(project_id?, query)`, `read_note(project_id?, id)` | As the orchestrator's; without `project_id`, over the plans |
| `create_note(title, sections)`, `append_section(note_id, …)`, `replace_section(note_id, …)` | As the worker's, on a plan only. Refused when `project_id` is passed or `note_id` is a project's note |
| `list_reports()`, `get_report(id)` | The Coordinator's own queue (§9.1), never a project's; no `project_id` |
| `send_request(project_id, body, plan_note_id?)` | Sends a §9.4 request into that project's queue. Refused for an unknown project, a blank body, and a body over 4000 characters |
| `withdraw_request(request_id, reason?)` | Closes an open request as `withdrawn` and tells its orchestrator |
| `list_requests(include_closed?)` | The §9.4 ledger, newest first: target, text, plan note, state, replies, linked epics |

Every other tool name is refused: `delete_message` as that orchestrator's
inbox, everything else as not a Coordinator tool. It is offered no note or briefing resources.

### 6.1 Remote branch naming

The local branch is always `agentboard/<task-id>` or `agentboard/epic-<epic-id>`:
it is the ownership marker `PublishPolicy` checks, and nothing renames it. What
reaches the remote is a separate question, because those names leak the tool and
then spend themselves on a UUID that means nothing to a reviewer.

`ProjectSettings.remoteBranchTemplate` names the published branch, e.g.
`clay/{slug}`. Two placeholders and no more: `{slug}`, required, from the epic's
or task's **title**, and `{id}`, optional, a short id. Everything else in the
template is literal, and the literal text before the first placeholder is the
**namespace** the published name must sit inside.

- The slug is lowercase ASCII words joined by hyphens, capped at 48 characters
  on a word boundary. Canonical decomposition folds `é` to `e`; nothing is
  transliterated, so a wholly non-Latin title slugs to nothing and the short id
  is used instead. The same title always produces the same slug.
- Two records that slug identically are separated by creation order: the older
  keeps the bare slug, every later one takes `-<short id>`. A third colliding
  record never renames the first two, so a branch is stable for the life of the
  board. A template carrying `{id}` is unique by construction and never takes a
  suffix.
- With **no template set**, the local name is published unchanged — what every
  project did before this existed.
- The base branch is published under its own name; it is the one ref on the
  remote Agent Board does not rename.

`RemoteRefPolicy` guards the destination side of the refspec, which is a
different question from `PublishPolicy`'s. It refuses a name that is not
well-formed, is a fully-qualified ref, is the base branch, or sits outside the
template's namespace. Both policies apply to every publish; neither weakens the
other. The rename itself is native git — `refs/heads/<local>:refs/heads/<published>`.

While a shutdown order is outstanding (§8), `spawn_worker` refuses immediately
— before caps are even checked — with the fixed string `"shutdown in progress;
no new workers"`, and a pending spawn or integration approval cannot be
approved until the order is cancelled (a refused approval is still pending
once it is, not silently granted). The board itself is untouched: `create_task`,
`update_task`, `move_task`, `set_deps`, `set_epic`, `promote_proposal` and the
note tools all keep working, and workers already running are not stopped by
raising the order — only delivering it (§8) reaches them.

Epic membership is settled before a task is spawned, never after. A task's
worktree branches from its epic's integration branch at spawn time (§5), so a
spawned task's commits are already based on whatever that epic's branch was;
re-homing the task would leave `mergeIntoEpic` merging a branch the work was
never based on. `set_epic` therefore refuses any task with a session against it
— spawned, stopped, failed or completed alike — and names the task's branch
`agentboard/<task-id>` in the error, so the refusal reads as "meaningless", not
merely "disallowed". A task that has never been spawned has no branch and no
worktree, so it moves freely. Both `set_epic` and `create_task` refuse a terminal
epic (`done` or `abandoned`) as a destination: a `done` one would otherwise
report `done_tasks < total_tasks`, and an abandoned one would acquire work
nobody intends to do. Epic counts and `ready_for_integration` are computed
from the epic's task list on every read, so `get_epic` and `list_epics` report
the corrected numbers for the source and the destination immediately after a
move. `task_dep` rows are never rewritten by either tool: dependencies are
independent of epic membership.

Archiving is a flag, not a column. `list_tasks` is the only orchestrator read
that hides archived tasks, and its description says so, so a task missing from
the board reads as archived rather than deleted. Every by-id tool — `get_task`,
`update_task`, `move_task`, `set_deps`, `log_progress` — reaches an archived
task: it is hidden, not frozen. Epic views (`get_epic`, `list_epics`) count
archived tasks, so integration readiness is unchanged by archiving. Workers get
neither archive tool, and their own task can never be archived because archiving
requires `done`.

`close_epic` is orchestrator-only for the same reason `request_integration` is:
a worker must not be able to end the epic it is working inside. A worker token
calling it gets `Unknown tool`, because the tool list is rendered per scope.
