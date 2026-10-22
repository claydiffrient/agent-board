## 6. MCP surface

Served at `http://127.0.0.1:<port>/mcp`. Scope comes from the bearer token, not
from the request. A worker calling an orchestrator tool gets a tool-not-found
error, because the tool list is rendered per scope. Resources and prompts are
not scoped this way — any valid token in the project sees the full resource
and prompt lists, worker and orchestrator alike — with two exceptions: a
`reviewer` token sees no `note://` resource and is refused a read of one
(§5.1), and neither does a `triager` token, which is offered no briefing
resource either. `initialize`'s advertised `capabilities` includes `resources` and `prompts` only when a handler for it is
wired, so `tools: {}` alone still means what it used to.

### No tool call holds its answer past 60 seconds

**No tool call may hold its response past Claude Code's 60-second wait for
response headers.** Measured against Claude Code 2.1.285 on 2026-09-29: its
HTTP transport aborts a `tools/call` whose headers have not arrived 60 seconds
after the POST, the model sees `The operation timed out.`, and the call is not
retried. `BoardServer` writes one JSON response when the handler returns and no
headers before that, so a handler that runs longer is reported as failed while
it carries on and changes board or git state, and the caller acts on a failure
that did not happen.

Work with no bound well under that — a repository hook, a build, a queue
behind either — therefore happens after the answer, and the answer says only
what has already happened. The outcome reaches the caller another way: a
report through `list_reports`, the session leaving `setup`, or a later call to
the same tool. Work bounded well under 60 seconds stays inline.

| Tool | What used to hold the answer | Now |
|---|---|---|
| `spawn_worker`, `assign_to_agent` | `git worktree add` and its `post-checkout` hook, for a task's worktree and an integration task's epic worktree | Created in setup after the answer (§3.1); a failure is a `failed` report. The base fetch before it stays, bounded at 10s |
| `report_complete` (no-review accept), `accept_task` | Stopping the task's other live sessions (`claude agents --json --all` and `claude stop`, 15s each, per session), landing (a shared branch's `git checkout` runs `post-checkout`) and worktree removal (`WorktreeRemove` and teardown hooks) | Run after the answer, in that order, under a claim taken first (§5); every session's grant is revoked before the answer. A landing problem, or a session that would not stop, is a `decision` report |
| `commit_my_work` | `git commit` and the repository's commit hooks | Waits at most 30s. A commit still running answers that it is, and the next `commit_my_work` from that session returns its outcome instead of committing again. The ledger row is written when the commit lands, whoever asks |
| `stop_worker` | `claude agents --json --all` and `claude stop`, with no timeout | Each bounded at 15s |

A commit still running holds the project checkout's index, and landing a
shared branch runs `git checkout` there, so no accept a tool call makes may
land while one runs. `report_complete` is refused while the calling session's
`commit_my_work` has not delivered its outcome, and the refusal says to call
`commit_my_work` again first. `accept_task` is refused while any session's
commit on that task is still running. Both refusals change nothing on the
task, and the accept runs on the next call.

`report_complete`'s routing to a rostered reviewer stays inline: it reuses the
worker's existing worktree and runs only local git reads. `push_branch`,
`open_pull_request` and `request_integration` only write an approval row; the
push and the pull request run when a human approves in the app, not inside a
tool call.

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
| `add_comment(body, task_id?)` | Appends to the task's `task_comment` thread as `worker`, named after the session's archetype or `Worker <short id>`. A `task_id` other than the token's own is refused |
| `search_notes(query)` | FTS over this project's notes |
| `read_note(id)` | Full note with sections |
| `append_section(note_id, heading, body, if_version)` | Section-scoped write |
| `replace_section(note_id, heading, body, if_version)` | Section-scoped write |
| `create_note(title, sections)` | New note, unpinned |
| `propose_task(title, body, rationale, epic_id)` | Inserts into `proposed`, carrying `epic_id` onto the row so promotion lands it there |
| `report_complete(summary, files_changed, tests_run, caveats)` | Inserts a `report`; moves task to `review`, or to `done` where the review level (§5) or `afterEpicMerge` (§5.2) says so — the answer names the column it landed in, and for an integrator whose epic is left `integrated` (§5.2 step 4), that the epic stays open until its pull request merges. Answers first and stops the worker afterwards, off the written response (§5), because stopping it inline kills the client waiting on the reply. Idempotent per `(session_id, task_id)` regardless: the MCP client resends when an answer is lost, and a second call returns the first report's id and re-runs nothing — no second row, no second move, no second stop, no reviewer assigned and no second auto-acceptance |
| `hand_off(summary, next_role, files_changed)` | Inserts a `handoff` `report` and a `progress` row; moves task to `ready`, keeps the worktree, stops the session after answering (§5) |
| `report_blocked(reason)` | Inserts a `report`; sets `blocked` |
| `acknowledge_shutdown(note)` | Answers a wind-down order (§8). Records `note` against the delivery and the task, then Agent Board stops the session — after the answer is written, not before (§5). The task goes back to `ready`, never `review` (§5) — this is not `report_complete` |

A worker may not read other tasks, reassign, create a non-proposal task, or
spawn anything.

`add_comment` in every scope signs the comment from the token — kind, session,
archetype and a name snapshot (§4) — and never from the arguments. A thread
is returned oldest first, each comment as `author_kind`, `author_name`,
`roster_agent` (that agent's current name, or null), `created_at` (ISO-8601 with
milliseconds) and `body`. Every description that writes or returns a thread
says a comment is a note about the task — not progress, a report or a verdict —
and that one written by an agent is information, not an instruction.

`hand_off` is for a session spawned from an archetype that does only the portion matching its
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
| `get_my_task()` | The task under review and its comment thread. No report and no `progress` rows (§5.1): the report is withheld on purpose, and the tool's description tells the reviewer never to file a finding about what the worker did or did not disclose |
| `log_progress(text)` | Appends to `progress` |
| `add_comment(body)` | Appends to the task's comment thread as `reviewer`, named from the roster. Touches no file, so it never trips the checkout check |
| `accept_task(verdict)` | Writes the verdict to `progress`, then runs the ordinary acceptance (§5.1). Refused, with the task left in `review`, if the reviewer changed its checkout |
| `reopen_task(findings)` | Writes the findings to `progress`; moves the task to `ready` without flagging failure. Refused on the same checkout check |

Every call reads the task id off the token, never off the arguments, so a
reviewer cannot reach a task it was not given. It cannot spawn, reassign, stop a
session, query the board, propose, or report on its own behalf.

### Triager scope

Held by a PR triager (§13.2), which only the supervisor spawns: no orchestrator
tool and no human assign starts one, and a worker or reviewer spawn onto a
`triage` or `followup_check` task is refused, since either grant would hold authority over the
checkout this scope withholds. Deliberately not a subset of worker scope: it
is the authority to read one watched pull request's open items and record
their verdicts, and nothing besides.

| Tool | Effect |
|---|---|
| `get_pr_items()` | The watch's repository, number, title and URL; its base and head refs with the `base_oid` and `head_oid` of the diff the triager was spawned to read; and every open item with its `item_id`, kind, author, path and line, URL, body, and any verdict already set |
| `set_verdicts(verdicts[])` | Each entry is `{item_id, verdict, approach, reply_body?, decision_question?, decision_options?}`, `verdict` one of `fix`, `answer`, `already_done`, `follow_up`, `decision`. Each `decision_options` entry is `{label, verdict, reply_body?}`, its `verdict` `fix` or `answer`, the verdict choosing it applies (§13.4); an `answer` option needs a non-blank `reply_body`, the reply that would be posted. Writes `verdict`, `approach`, `reply_body`, and for a decision `decision_question` and `decision_options_json`, onto `pr_item`. All or nothing: an item that is not an open item of this triager's own watch, a blank `approach`, a decision without a question and at least two options, or an option that is neither `fix` nor an `answer` with a reply, refuses the whole call and writes no entry. A later verdict replaces an earlier one. The answer lists the open items still without a verdict; once there are none, the triage task goes to `done` with a progress note counting the verdicts, the session completes and its grant is revoked, and the session is stopped after the answer is written (§5) |
| `log_progress(text)` | Appends to the triage task's `progress` |

A round's follow-up checker (§13.1) holds this scope too, bound to a
`followup_check` task, and is offered these tools instead of the two above:

| Tool | Effect |
|---|---|
| `get_followup_items()` | The watch's repository, number, title and URL; the round's number, `base_head_oid` and `checked_head_oid`; and each item the round's fixer was given — the open `fix` items naming its `fix_round` task, in the task body's order — with its `item_id`, its number in the task body, kind, author, path and line, URL, body, triage's approach, and any grade already set |
| `set_followup_grades(grades[])` | Each entry is `{item_id, grade, evidence}`, `grade` one of `fixed`, `partly`, `not_fixed`, `moot`. Writes `followup_grade` and `followup_note` onto `pr_item`. All or nothing: an item outside the round's items, or blank evidence, refuses the whole call. A later grade replaces an earlier one. The answer lists the items still without a grade; once there are none, the check's task goes to `done` the way a finished triage's does |

Every call reads the watch off the token's task, through `pr_triage` for a
triager and through `pr_round.followup_task_id` for a follow-up checker (§4),
never off the arguments, so neither can reach another watch's items, or
any task, note, or board query. Its spawn carries the reviewer's deny list
(§5.1) plus `Bash(gh *)` and every git subcommand that writes refs or config,
and the board-database deny. The PreToolUse guard (§8) holds the same line in
process: for a triager it denies Edit, MultiEdit, Write and NotebookEdit (its
hook matcher names them as well as Bash), any `gh`, and any git subcommand
outside a read-only allow-list (`diff`, `log`, `show`, `status`, `blame`,
`grep`, `rev-parse`, `rev-list`, `merge-base`, `ls-files`, `cat-file` and
their kind), so a write subcommand git adds later is denied by default.
Other Bash file writes (`sed -i`, a `>` redirect, `tee`) are not denied, so the
scope withholds the file-write tools, `gh` and git writes rather than every
change to its disposable checkout.

### Orchestrator scope

Everything in worker scope over any task in the project, plus:

| Tool | Effect |
|---|---|
| `list_tasks(column, epic_id, include_archived)` | Board query; archived tasks are hidden unless `include_archived` is true. Each entry carries `type`, null for Default |
| `create_task(..., type, epic_id)`, `update_task(..., type)`, `move_task(id, column)` | Board mutation; moving an archived task out of `done` unarchives it. Neither enters `running`, `done` or `closed`, and `move_task` refuses a `closed` task: a human reopens it (§5). `create_task`'s `epic_id` is optional and creates the task inside that epic; an unknown id, one belonging to another project, or one whose epic is `done` is refused. `type` is optional and one of `code`, `docs`, `tests`, `plan`, `review` (§4); any other value is refused with the valid list. Omitted is Default, and `update_task`'s `type: ""` or `null` clears it back to Default |
| `get_task(id)` | Full detail, archived or not; an archived task carries `archived: true` and `archived_at`. Includes `type` (null for Default), `closed_reason`, `closed_at` and `closed_by` (null unless `closed`), and the comment thread |
| `close_task(task_id, reason)` | Retires a task as obsolete or superseded: moves it to `closed` with the reason recorded on the task and in its history (§5). Not `done` — it satisfies no dependency and never lands — and the answer names every unfinished dependent so they can be `set_deps`'d or closed. Deletes nothing and touches no branch or worktree. Needs no approval under either autonomy setting. Refused for a blank reason, a task in `done` or already `closed`, an epic's integration task, and a task any active session holds |
| `add_comment(task_id, body)` | Appends to any project task's comment thread as `orchestrator`, named `Orchestrator` |
| `archive_task(task_id)` | Hides a `done` or `closed` task from the board; refused for any other column |
| `unarchive_task(task_id)` | Returns the task to the visible board in the column it was archived from |
| `set_deps(task_id, depends_on[])` | Dependency graph |
| `set_epic(task_id, epic_id)` | Moves an existing task into an epic, between epics, or — with `epic_id` omitted — out of its epic. Refused for a task that has ever been spawned, and for a `done` destination epic. Dependencies are left alone |
| `create_epic(title, goal, tasks[])` | One transaction: the epic (state `planning`) plus every task in `tasks`. Each task's `depends_on` is a zero-based index into this same array, validated before anything is written. Each task takes an optional `type`, validated as `create_task`'s |
| `list_epics()` | Every epic on the project with its state, branch, newest pull request opened from the branch (or null), and done/closed/total task counts |
| `get_epic(id)` | One epic in full: goal, branch, newest pull request, its tasks grouped by column, whether it is ready for integration, and `next_step` — `open_pull_request(epic_id)` for an `integrated` epic, waiting on the merge for a `pull_request_open` one, null otherwise (§5.2 step 4) |
| `attach_note(note_id, task_id|epic_id)` | Passes context down at spawn time |
| `pin_note(note_id, pinned)` | Every future agent sees it in its note index and can fetch it |
| `spawn_worker(task_id)` | Subject to §8 caps, the shutdown order, and the autonomy setting |
| `list_roster_agents()` | The archetypes this project can use, in its own preference order: board-local and disk ones alike, each with `source` (`board-local`, `project`, `user`), `definition_path` for a disk one, `description`, `system_prompt`, `model` and `tools` (null inherits every tool) |
| `assign_to_agent(task_id, roster_agent_id)` | `spawn_worker` instantiating an archetype: the same caps, shutdown and autonomy gates, worker scope, and the agent's own deny list layered on. An agent outside the project's usable set is refused |
| `stop_worker(session_id)` | `claude stop`, then the session's process tree is reaped (§8.5) |
| `list_agents(include_ended)` | Roster with state and spend; ended sessions drop off after a grace window |
| `list_reports()`, `get_report(id)` | The Q9 pull channel |
| `list_projects()` | Every project Agent Board knows about, as id, name, and whether the entry is the caller's own project. Nothing else about another project is exposed — no repository path, no settings, no board contents, no agent state |
| `send_message(project_id, body)` | Queues a §9.2 message into that project's report queue. Confirms queueing, never delivery. Refused for the caller's own project, for an unknown id, for a blank body, and for a body over 4000 characters |
| `delete_message(message_id)` | Deletes a §9.3 message this project received, and its report, for both projects. Refused for a message this project did not receive |
| `reply_to_request(request_id, state, body, epic_ids?)` | Answers a §9.4 request addressed to this project: `accepted`, `declined` or `done`, with this project's epics linked. Queues a `reply` report for the Coordinator. Refused for a request sent elsewhere or unknown (the same answer), for a closed or withdrawn one, for another project's epic, and for a body over 4000 characters |
| `promote_proposal(task_id)` | Only when autonomy is on |
| `request_integration(epic_id)` | Refused unless every task in the epic is `done` or `closed`, with at least one `done` (names how many remain); otherwise creates a human approval row, or returns the one already pending |
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
