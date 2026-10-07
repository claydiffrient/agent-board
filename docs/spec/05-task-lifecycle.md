## 5. Task lifecycle

```
proposed ──promote──> backlog ──deps met──> ready ──assign──> running
                                                                 │
                          ┌──────────────────────────────────────┤
                          ▼                                      ▼
                       review ──accept──> done              failed (flag)
                          │                  ▲                   │
                          │                  │                   │
                          │      no review / epic review:        │
                          │      complete goes straight here     │
                          └──────────── reopen ──────────────────┘
```

Which of those two edges a completed task takes is the **review level** (§4), a
project setting an epic may override for its own tasks:

| Level | A completed task | Who decides |
|---|---|---|
| `none` | goes straight to `done` | nobody looks |
| `agent` | goes where its type's row in the routing table (§4) says: to a rostered reviewer, a person, or `done` | that row |
| `task` | waits in `review` | you (**the default**) |
| `epic` | inside an epic, goes straight to `done`; standalone, waits in `review` | you, at the epic's integration gate |

The level is resolved on completion: the task's epic's `review_level` if it has
one, otherwise the project's. Two rules override it unconditionally. An epic's
integration task (`origin = integration`) always waits for a person, at every
level — §5.2's gate is not weakened by this setting. And `agent` with no usable
rostered reviewer — or with a routing row naming an agent (§4) that is no longer usable —
falls back to `task` and says so in a `progress` row, rather than accepting work
nobody reviewed.

- `proposed` — created by a worker via `propose_task`. Neither the orchestrator
  nor a worker may promote a worker proposal without human approval when
  autonomy is off; with autonomy on, the orchestrator may promote.
  A proposal may name the epic it should land in (`propose_task(epic_id)`), any
  live epic in the same project — a planning task's own epic being the case the
  parameter exists for. The epic is checked when the proposal is written, so
  the worker learns at once, and again when it is promoted, because an epic can
  close while a proposal waits: a proposal whose epic is gone, closed, or in
  another project by then is promoted into **no** epic, and the decision report
  says which rule it broke. Promotion never drops an unfinished task into a
  finished epic, and never fails over it. The same rule governs both promotion
  paths — `promote_proposal` and the human's Promote button — because both run
  through `Board.promote`.
- `ready` — **the only column the orchestrator may pull from.** A task becomes
  eligible when every row in `task_dep` points at a task in `done`. Readiness
  does not wait for the dependency's landing: it moves inside the acceptance
  transaction, before git has run, and a landing cannot see a hand merge or a
  reset of the target branch. What is enforced instead is the cut. A spawn that
  would cut a new worktree for a task in an epic from its epic branch refuses
  while any sibling it depends on is in `done` with a commit that branch lacks
  — the dependency's branch tip, the tip the ledger kept when that branch was
  reaped, or a commit `task_commit` attributes to it — naming the dependency,
  the commit, the branch and the landing. The accept's merge may still be
  running, or may have failed or been skipped; a worker cut then would start
  without the work it builds on. A merge that succeeds queues no report, so the
  refusal promises none: while the landing is unsettled it says to spawn again
  once `git merge-base --is-ancestor <commit> <branch>` exits 0, and for an
  `unlanded` dependency, or one whose landing the branch contradicts, it says to
  merge the commit into the branch first. A task whose branch already exists, a
  shared placement and a reviewer cut nothing and are not checked.
- `running` — an `agent_session` row holds it. The board shows the agent, its
  spend, and elapsed time.
- **Wound down** — a task whose worker was told to wind down (the shutdown
  order, §8) and answered `acknowledge_shutdown` goes back to `ready` with a
  resume note on the queued report, **never to `review`**: the work is
  unfinished, not accepted. This is a third termination cause alongside a cap
  kill and a human stop, and it is deliberately shaped differently from both —
  the task is **not** flagged `failed`, and the report queued for the
  orchestrator is a `decision` (carrying the worker's note under "Where the
  worker stopped and what remains"), not a `failed` report. A worker that
  vanishes or is cap-killed still gets the old `failed` shape; only an
  acknowledged wind-down gets this one.
- **Handed off** — a session spawned from an archetype that did only the portion matching its
  specialty calls `hand_off` (§6) instead of `report_complete`. Like a
  wind-down, the task goes back to `ready`, **never to `review`**, and
  `failed` is never set; unlike a wind-down, nothing asked it to stop — it
  decided its part was done. The worktree and branch are kept, so the next
  agent assigned works the same checkout (D6), and `Board.assign` refuses a
  second session into a task or worktree an active one still holds. This is
  the fourth termination shape alongside a cap kill, a human stop, and an
  acknowledged wind-down; each is distinguishable by report kind
  (`handoff`, `failed`, none, `decision`) and by the session's `stop_reason`.
- `blocked` — a flag, not a column. Set by the `Notification` hook, cleared on
  the next `PostToolUse`. The card keeps its position and shows why.
- `review` — worker has committed and called `report_complete`, and the review
  level (§5) says someone must look. Under `worktree` that means a commit on
  `agentboard/<task-id>`, and the worktree is retained; under `shared` it means
  an attributed commit — via `commit_my_work`, never `git commit` (§8.4) — on
  the branch the task shared with its co-resident siblings, and there is no
  per-task worktree to retain. Under the `agent` review level the task carries
  `reviewer_agent_id`, the rostered reviewer holding it; under `task` it waits
  on you.
- `done` — you accept it, or, under `none`/`epic`/`agent`, the review level or a
  rostered reviewer does. Every live session on the task is stopped first,
  through the same path as a human Stop, because a rostered reviewer runs in the
  worker's own worktree; the one exception is the reviewer whose `accept_task`
  is doing the accepting. A human reopen stops them the same way. A session
  whose process is already gone — absent from `claude agents`, or `starting`
  with no short id and nothing listed under its id — is ended as vanished and
  does not block the decision; only an agent still listed as live that refuses
  to stop aborts the accept or reopen before anything is written. The accept
  then lands the task's branch, below, and only after that is every attempt's
  worktree removed (firing the
  existing `WorktreeRemove` hook, which reclaims Bazel `output_base` on
  Derivita), with `agentboard/<task-id>` deleted once it is merged into the
  base or epic branch. An unmerged branch, or a worktree with uncommitted
  changes, is kept and the reason surfaced in the status bar. Landing comes
  first because removing a large worktree can take over a minute, and until the
  merge runs a dependent cut from the target branch lacks this work. A member of
  a shared branch has no worktree to remove, so its teardown still runs first.

  The merge takes the task's branch into the branch meant to carry it:
  `agentboard/epic-<id>` for a task in an epic (§5.2), so the next sibling
  spawned into the epic branches from work that is already in, and the project's
  base branch for a task in none — unless the project integrates standalone
  tasks by pull request, below, when a task in none merges nothing. The merge runs after the acceptance
  transaction and off the main actor: nothing it does can hold the task out of
  `done`. Nothing is checked out, so no repository checkout hook runs: when the
  target branch is an ancestor of the task branch the ref is advanced directly;
  otherwise `git merge-tree --write-tree` builds the merged tree, `commit-tree`
  makes the merge commit with both parents, and `update-ref` moves the target
  only if it is still where the merge started. `merge-tree --write-tree` needs
  git 2.38; macOS 14, the oldest the app supports, ships 2.39. A temporary
  worktree was used before, and it fired `post-checkout`: Derivita's runs its
  setup script, which fails under launchd's `PATH`, so every non-fast-forward
  merge there failed and left its worktree holding the epic branch. Merges into
  one target branch run one at a time, in the order their accepts arrived, so
  each builds on the one before rather than losing the race on the guarded
  `update-ref`; this covers a shared branch's merge below too. A conflict
  leaves the target branch where it was and the report lists the conflicted
  files. The merge commit's subject is
  `Merge <task title> into <epic title or base branch name>` — titles, never
  `agentboard/<id>` branch names, because this commit is on the branch a pull
  request is opened from and those names would publish the task and epic
  identifiers into that repository's history permanently (§6.1 renames the
  branch, not commits already made). Nothing here pushes: it is a local
  branch-to-branch merge.

  **A task accepted off a shared branch (D6 amended, §1) does not merge or
  remove anything by itself.** Its branch carries every co-resident sibling's
  commits interleaved on one ref, so there is no range that is this task's
  work alone — accepting it only marks this task accepted and checks whether
  it was the last one still owed: every task that ever ran on the branch must
  be accepted. No member's worker can still be standing in the checkout by
  then, because each accept stopped its own task's sessions and nothing sets a
  session on a task in `done` running again (§7, §10 Status), so a reviewer's
  own accept on the last member no longer waits for its own session to end. Short of that,
  acceptance queues a `decision` report naming
  what the branch is still waiting on and merges nothing. Once it holds, the
  branch's attribution is written to `task_commit` for every member (backfilling
  from any pre-ledger `Agent-Board-Task` trailer first, since this is the last
  moment before the ref disappears), the whole branch is merged into the epic
  branch exactly as a task branch is, and the project's checkout is moved off
  it before the branch is deleted — a dirty checkout at that moment keeps the
  branch rather than losing anything. A conflict or a branch still checked out
  elsewhere reports the same way a task branch's would, naming that the one
  merge carries every task on it. The members' landings are written together, by
  the one merge that carries them: until it runs, each accepted member is
  `unlanded`, and that merge marks every member `landed` at once. A shared
  branch already gone when its last member is accepted merges nothing and
  writes no ledger, so each member's landing is read from git instead: `landed`
  only when the epic branch contains every commit `task_commit` attributes to
  it and the ledger's tip for it, `no_branch` when it has neither, and
  `unlanded`, with a report listing the missing commits, otherwise.

  Two things the merge will not do. It never cuts a missing base branch — a
  project whose base branch does not exist is misconfigured, and creating one
  would land the work on a ref nobody pulls. And it never advances a branch that
  a working tree holds, which is the ordinary case for the base branch: the
  human's own checkout is on it. `git update-ref` does not refuse such a branch;
  it moves the ref and leaves that working tree reporting every newly-merged
  file as deleted. So the accept defers instead.

  Because the accept therefore cannot always land the work, every task carries a
  **landing**, written by the accept and cleared when the task leaves `done`:

  - `pending` — armed on entry to `done`, by any route including a human
    dragging the card, and overwritten as soon as git answers. It survives only
    when the app died in between, which is precisely when the board must not
    claim the work landed.
  - `no_branch` — the task committed nothing. A task with no code to land
    finishes here and is not stranded; this is a separate value from `unlanded`
    for exactly that reason.
  - `landed` — the target branch contains the task's commits.
  - `unlanded` — the task has commits and the target branch does not contain
    them. The work is reachable only from `agentboard/<task-id>`.
  - `awaiting_pull_request` — a task in no epic, accepted in a project that
    integrates standalone tasks by pull request; nothing was merged and the
    task branch is kept.
  - `pull_request_open` — a pull request is recorded for the task and has not
    merged. `landing_detail` leads with its URL.

  **Integrating standalone tasks by pull request.** Workflow → Publishing's
  "Integrate standalone tasks by" is *Pull request* or *Local merge*. A project
  that never chose stores neither, and the accept resolves it by running
  `git remote get-url origin` off the main actor: a repository with an `origin`
  integrates by pull request, and one without — or a missing repository or
  git — by local merge. The picker's first entry is that default, labelled with
  what it resolved to ("Pull request (default: has origin)"); a stored choice
  always wins. Only `gh` opens and checks pull requests, so an `origin` on a
  host other than GitHub still resolves to *Pull request*: its tasks wait at
  `awaiting_pull_request`, and an approved `open_pull_request` pushes the
  branch to that `origin` and then fails with `gh`'s "none of the git remotes
  configured for this repository point to a known GitHub host", so such a
  project should choose *Local merge*. Under *Pull
  request* the accept of a task in no epic does no local merge: a task with no
  branch is still `no_branch`, and one whose branch the base branch already
  contains is still `landed`; any other is `awaiting_pull_request`, or
  `pull_request_open` when a pull request was recorded before the accept.
  Tasks in an epic merge into their epic branch either way, and nothing below
  ever applies to one: an epic's pull request carries the epic branch, which
  says nothing about a member whose merge into it conflicted. `push_branch` and
  `open_pull_request` keep their human approval. A task's pull request is the
  URL an approved `open_pull_request` naming that task recorded on its
  `approval` row (`published_url`) — never text read off the card, where a
  worker's `update_status` detail is a `status` row too, written with no
  session id until its grant is bound. When that URL is recorded against a
  `done` task that has not landed, the task moves to `pull_request_open`. The
  merge check then asks
  `gh pr view <url> --json state,mergedAt,mergeCommit,headRefOid`, off the main
  actor, on the first metering tick after launch, every 10 minutes after that,
  and when the inspector opens the task: `MERGED` makes it `landed` with the
  merge commit in `landing_detail` — ancestry cannot settle this, since a
  squash merge puts a new commit on the base branch — and `CLOSED` makes it
  `unlanded`, naming the pull request, with a `decision` report. A `gh` that
  is missing, logged out or failing leaves the landing as it was and puts the
  reason in its detail. The same check adopts a `done`, `unlanded` task whose
  recorded pull request its detail does not already name, which clears the
  tasks accepted before this existed; for those, the `published_url` migration
  recovered the URL from the progress row the publish wrote. A closed pull
  request's detail names it, so each is checked once: one reopened and merged
  afterwards is not re-adopted, and the human lands that task by hand or opens
  a new pull request.

  `pending`, `unlanded`, `awaiting_pull_request` and `pull_request_open` show as
  a badge on the card and in the inspector. All but `pull_request_open` queue a
  `decision` report naming the task, the branch, the target and the
  reason — for `awaiting_pull_request`, that a pull request is owed — so the
  orchestrator can dispatch a fix rather than discover the
  divergence at integration time. An accept whose merge found no branch to
  merge queues one too, though it asks for no attention: `no_branch` says
  nothing was merged, and a `landed` whose branch was already gone — a sweep
  reaped it after some other hand merged it — says this accept merged nothing
  and names the reaped tip the target contains, so neither reads as the board
  having put the work there. The board can therefore never say `done` while
  silently meaning "done, and the work is nowhere": reaching `done` writes a
  landing, and the default value is the one that asks for attention.

  A landing recorded before this existed is `NULL`, which claims nothing either
  way; it is not rendered as an alarm.
- `archived` — also a flag, not a column, with `blocked` and `failed` as the
  precedent: D7's six columns (`proposed`/`backlog`/`ready`/`running`/`review`/
  `done`) are unchanged by the archive feature. Only a `done` task can be
  archived (§4), and archiving does not move it — an archived task is still a
  `done` task, just hidden from the default board query.

Reconcile also reaps worktrees under the project's worktree root that no active
session owns, and deletes merged `agentboard/*` branches that no longer have a
worktree. Anything dirty or unmerged is left alone and reported. Epic
integration worktrees and `agentboard/epic-*` branches are out of scope. So is
a shared branch (`agentboard/shared*`): it has no worktree under this reaping
either way, and it is deleted only by acceptance finding it fully accepted and
idle, above — never by reconcile's orphan sweep, which has no notion of "every
member" to check.

### 5.1 Completion protocol

A worker's closing instructions, injected at spawn, worded per placement
(`OpeningPrompt.closeout(placement:)`):

1. Commit. Message in imperative mood, no conventional commit prefix. Under
   `worktree`, this is `git commit` on the current branch, as it always was.
   Under `shared`, `git commit` is refused (§8.4) and the worker is told to
   call `commit_my_work(message)` instead, which commits exactly the files its
   own writes have locked — never a sibling's — and may be called more than
   once.
2. **Do not push. Do not open a PR.** Both are denied at the tool layer
   (`--disallowedTools` and the `PreToolUse` hook, §8); the instruction exists
   so the agent does not waste a turn discovering that.
3. Call `report_complete(summary, files_changed, tests_run, caveats)`.

`report_complete` records the report and then resolves the review level. Where
the level accepts the task, it runs **the same acceptance a human Accept runs** —
the newly-ready announcement, the grant revocation and the worktree removal are
one code path (`WorkerControl.accept`), not a second one that has to be kept in
step. The worker's return text tells it which happened.

Under `agent` review the reviewer is **started**, not merely recorded:
`report_complete` resolves the routing, writes `reviewer_agent_id`, and then
spawns the reviewer through `WorkerControl.assignAgent(taskId:rosterAgentId:
scope:)` with `reviewer` scope. The spawn is keyed on the task id, so the
reviewer lands in the worker's own worktree on the worker's branch — the work is
there to read with no merge and no checkout of its own — and it is the one spawn
that does **not** move the task to `running`: a review must stay in `review` or
its own `accept_task` has nothing to decide. A reviewer that cannot be started
leaves the task in `review` for a person and says so in a `progress` row, which
is where `task` review would have parked it anyway.

The stop comes after the answer, not before it. `workerCompleted` runs `claude
stop` on the session that is waiting on this very call, so awaiting it inline
killed the MCP client mid-request: measured on the live board 2026-09-21, 64 of
183 completing sessions never received their answer and every one of them resent
the call, while the 118 that did receive it resent nothing. The handler now hands
the stop back on the `ToolResult` (`afterResponse`) and `BoardServer` runs it
once the response body has been written to the channel. `hand_off` and
`acknowledge_shutdown`, which end their own session the same way, defer it the
same way.

None of that runs twice even so. `report_complete` is idempotent per
`(session_id, task_id)`: a dropped connection or a stopped worker can still cost
the answer, and the MCP client resends. `Board.complete` reads the session's
existing `complete` report inside its own write transaction and returns it
untouched — before the routing, the reviewer write, the acceptance and the
spawn are reached — so a resend inserts no second row, moves no task, sets no
reviewer, starts no second reviewer and fires no second event. The answer names
the first report's id and the column the task actually sits in.

**A report from a session Agent Board already ended moves nothing.** A session
the board failed, stopped or completed can still be running, because Claude Code
resumes a stopped `--bg` session by itself (§8.5), and by the time it reports
another session may have finished the task. A session `Board.terminate` ended
has its grant revoked, so its `report_complete` gets a 401 and never reaches
the board. For the rest, `Board.complete` reads the session row inside the same
transaction. When the row is no longer active, the report is
kept as a `decision` headed "Late report_complete from a session Agent Board had
already ended", and the task's column, landing, archive state, review routing and
epic are left as they are. The answer says the session had already ended and
names the column the task stays in, and the stop still follows it. A resend finds
that decision report and inserts no second one. On 2026-10-07 the idle-capped
first integrator of task 006dfd78 reported two minutes after the second
integrator had closed the epic and archived the task, and pulled the archived
task back into `review` with its landing cleared.

A rostered reviewer under `agent` review gets its own token scope (§6), narrower
than a worker's: `get_my_task`, `log_progress`, `accept_task(verdict)` and
`reopen_task(findings)` over the one task its token names, and nothing else — no
spawn, no reassign, no other task. `accept_task` writes the verdict to `progress`
and then takes that same acceptance path, which spares that reviewer's own
session; `reopen_task` puts the findings on the
task and returns it to `ready` without flagging a failure. Either verdict marks
the reviewer's session `completed` and, like `report_complete`, stops it once the
answer is written (`afterResponse`). The verdict on the
task is the point: a person reading a task that reached `done` without them can
see who approved it and why.

A reviewer whose turn ends (its `Stop` hook) with the task still in `review` gave
no verdict. Nothing accepts the task: its Pending reviews row reads `<reviewer>
stopped without a verdict` (§10), and one `blocked` report per reviewer session
tells the orchestrator. The session is left idle, not stopped, because a turn can
end while a build the reviewer started in the background still runs; the
orchestrator can message it or `stop_worker` it.

A session that ends on a task already in `done`, or back in `ready` with a
reviewer's findings or with no other session on it, left nothing unfinished:
`Board.terminate` queues a
`decision` report headed "Session ended after its task was settled: <reason>",
with no branch-salvage line and no failure flag. A stop's reason names who asked
for it — a human, the orchestrator's `stop_worker`, or the acceptance that ran
it — and `close_epic`'s report names its closer the same way.

A reviewer is review-only: it reads `git diff <base>...HEAD`, may build and run
tests, and changes nothing — a defect goes back through `reopen_task`, never
into a commit of its own. Its opening prompt, which carries the task's comment
thread (§3.1 step 6), says so (`ReviewPrompt`, served
again as `briefing://reviewer` and as its post-compaction brief), and its
`--disallowedTools` denies edits and branch-changing git commands (§3.1). Both
verdict tools then check the checkout through `WorkerControl.reviewCheckoutChange`
against the baseline spawn recorded in `review_head` (`ReviewCheckout.baseline`:
the HEAD, plus a fingerprint of `git status --porcelain` and `git diff HEAD` when
the worker left uncommitted tracked changes): if HEAD has moved, the tracked
changes differ from that baseline, or no `review_head` was recorded, the verdict
is refused, an `error` row names why — saying so when the tree was already dirty
at spawn, so the worker's leftovers are not blamed on the reviewer — and the task
stays in `review` for a person. Work finished in the shared checkout never
reaches a reviewer: co-resident workers move its HEAD and dirty its tree, and
`<base>...HEAD` carries their commits, so `ReviewPolicy.routing(completedBy:)`
sends it to a person with that reason, and a reviewer's spawn ignores the
worktree strategy. The next worker spawned on a reopened
task gets the reviewer's `progress` note verbatim in its opening prompt, and in
its post-compaction brief, until a later review passes, a human reopens the task,
or it is accepted (`Board.closeReviewFindings`).

A reviewer's inputs are the task — title, body, acceptance criteria and its
comment thread — and the diff on the task's branch. Nothing else: not the
worker's report, not the task's `progress` rows (the worker's own notes and any
hand-off summary), not project notes, not the board database. It checks the
worker's claims by reading and running the code. `ReviewPrompt` says so; its
`get_my_task` returns the task and its comments and nothing from `report` or
`progress`; its scope has no note tools, and `NoteResourceHandler` lists no
`note://` resource to a `reviewer` token and refuses to read one.

The database is denied through the same `--disallowedTools` list as its writes,
by `SpawnRequest.reviewerBoardDeny`: `Read(//**/agentboard.sqlite*)` and
`Bash(*agentboard.sqlite*)` for the database file and its `-wal`/`-shm` wherever
it is spelled from, and, for the support directory itself, `Read(/<dir>/**)`
plus `Bash(*<dir>*)` under its absolute, symlink-resolved and `~` spellings,
each also with its spaces backslash-escaped. Measured against Claude Code
2.1.283 on 2026-09-26: those rules denied the Read tool, `cat` (absolute, after
`cd`, quoted and escaped), `cp … && cat`, `sqlite3` and a `python3 -c` naming
the file. The gap, like the Coordinator's (§8.2), is a command that never names
the path: a recursive search from an ancestor directory (the Grep tool, or
`grep -r` from `~` or `~/Library`), or a path assembled at run time. It stops
accident, not an adversarial reviewer, and a database moved by `AGENTBOARD_DB`
to another filename outside the support directory is not covered at all.

A reviewer judges a diff, so a task whose branch has no diff against its base —
one whose whole deliverable is an Agent Board note, such as release notes — has
nothing for it to decide, and `reopen_task` would send correct work back.
`assignAgent(scope: .reviewer)` runs `git diff --quiet <base>...HEAD` in the
worktree before it writes a session row and throws `NothingToReview` when it
is empty. `report_complete` then leaves the task in `review` for a person
(`Board.leaveReviewToPerson`: `reviewer_agent_id` cleared, the reason in a
`status` row, exactly as `humanReview` routing parks it) and tells the worker
so. No reviewer starts and nothing is flagged as an error.

### 5.2 Epic integration

Integration is gated on your approval regardless of the autonomy setting, and
can be requested two ways that land on the same row: the orchestrator's
`request_integration(epic_id)` tool, or the epic lane's **Request integration**
button. The tool refuses until `epicReadyForIntegration` holds — the epic is
non-empty and every task in it is `done` — naming how many tasks remain; the
button only appears once that is already true, so neither path can jump the
gate. Either call reaches `Board.requestIntegration`; a repeat request while
one is already pending returns the existing approval rather than queuing a
second.

This is the path that ends an epic by *finishing* it. §10's **Close as done**
and **Abandon** are the other way out, for an epic you are finished with rather
than one that is finished; they merge nothing and are not part of this sequence.

1. All tasks in the epic reach `done`.
2. Orchestrator calls `request_integration(epic_id)`. This creates an approval
   row and a macOS notification. Nothing proceeds until you approve.
3. On approval, Agent Board creates an integration worktree on
   `agentboard/epic-<id>` and spawns an integrator worker. The epic moves to
   `integrating` in `WorkerSupervisor.spawnIntegrator`, after the integrator's
   session row is written and before its process is launched, so a spawn that
   throws leaves the epic `active` rather than stranded mid-integration. An
   epic already `pull_request_open` (step 5) stays so: its pull request, not
   the integrator, decides when it is done. The
   integrator's job is to merge
   each `agentboard/<task-id>` into the epic branch, resolve conflicts, and get
   the build green. The epic branch accumulates accepted work as it goes (§5),
   so by this point most task branches are already in and the integrator's real
   job is the leftovers — a branch whose merge conflicted, or one accepted while
   the epic branch was checked out here — plus getting the build green across
   the whole epic. Both cases arrive as `decision` reports before integration is
   requested; integration is no longer the first time task branches meet.
   A task branch that is gone is not reported as missing. Agent Board writes two
   refs outside `refs/heads` — `refs/agentboard/base/<task-id>` when the branch
   is cut and `refs/agentboard/reaped/<task-id>` before the ref is dropped — so
   the plan can tell a branch deleted *because* its work merged from one that
   never carried a commit. `IntegrationPlan.classify` reads them into three
   claims: work on the epic branch and the branch gone ("nothing to do"),
   nothing ever committed (the existing wording), and anything the ledger cannot
   settle, which is reported as unknown with an instruction to check rather than
   asserted either way. None of this changes which branches the integrator is
   told to merge; the prompt's merge instruction names that section rather
   than pointing at everything listed above it.
   "Green" is the project's own `settings_json.buildCommand` and `testCommand`
   (§4), interpolated into the prompt. When either is unset the prompt does not
   drop verification: it tells the integrator to work out how this project
   builds and tests itself, run both, and name in its report exactly what it
   ran. Nothing in the prompt assumes a language or a build tool.
   `spawnIntegrator` runs the same launch path as any task worker (§3.1 steps
   3-8: memory symlink, generated `--settings`/`--mcp-config`, a worker-scoped
   token, `--permission-mode auto`, `--strict-mcp-config`, the push/PR
   `--disallowedTools`), bound to the epic instead of a task. The worktree is
   `<worktree-root>/epic-<epic-id>` via `WorktreeManager.createForBranch`,
   reused if a previous attempt already created it rather than cut fresh. The
   epic's tasks — excluding any earlier integration task — are ordered so each
   is listed after every task it depends on before their branches are
   classified. A synthetic task titled `Integrate epic <title>` with
   `origin = integration` is created and the session assigned to it, so the
   integrator gets a real board card, token scope and report channel like any
   worker; if the spawn fails, that task is deleted and the epic is left where
   it was.
4. The integrator reports. Under the default `afterEpicMerge` archive policy
   (§4), the epic's merge is itself the trigger: `Board.complete` moves the
   epic to `done` and archives every `done` task of it, the synthetic
   `origin=integration` task included, inside the same transaction. **That
   integration task lands directly in `done`, not `review`** — the epic
   reaching `done` is its acceptance, and a task about to be archived has no
   business sitting in the review queue. This is a real trade-off, not an
   implementation detail: under the default policy, the integrator's own
   completion produces no review-queue entry. Every other archive policy
   leaves it in `review` for a human, exactly as before this feature existed.
   `Board.complete` does this only for an epic still `integrating`; an
   integrator finishing on a `pull_request_open` epic leaves the epic there and
   its task in `review`, so approving integration never marks an epic `done`
   while its pull request is unmerged.
5. The PR from the epic branch → base is opened either **by you**, from
   the button on the epic, or by the orchestrator calling `open_pull_request`
   (§6) — which does not open one either. It creates an approval row, exactly
   as `request_integration` does, and the branch is pushed and the pull request
   opened only once you grant it, autonomy setting regardless (D8 amended, §1).
   The resulting URL is written to `progress` against the epic's integrator
   task, so the board records that the pull request exists without anyone
   reading a terminal, and reaches the orchestrator as a `decision` report.
   It is also kept on the approval (`published_url`), and recording it moves
   the epic to `pull_request_open` from any state but `abandoned` — whether or
   not `request_integration` ran first, and including a `done` epic.

   A `pull_request_open` epic is not closed. `create_task` and `set_epic`
   accept it, its new tasks branch from the epic branch, and accepting one
   merges into the epic branch as in `active`. `push_branch` on the epic
   branch publishes under the same name the pull request's head has (§6.1
   names are stable for the life of the board), so it updates the open pull
   request; a second approved `open_pull_request` finds the open one and
   records the same URL rather than opening another. The lane's state badge
   reads "PR #N open".

   The merge check that settles standalone tasks (§5) also reads each
   `pull_request_open` epic's newest recorded pull request with `gh pr view`,
   on launch, every 10 minutes, and never for a task-branch pull request inside
   the epic. `MERGED` makes the epic `done`, marks `landed` with the merge
   commit every `done` task whose branch or reaped tip is an ancestor of the
   pull request's merged head (`headRefOid`), not of the local epic branch; a
   task only the epic branch carries, accepted after the last push, is marked
   `unlanded` and named in the report with "push the epic branch and open a
   follow-up PR". A head the repository lacks, such as a suggestion applied on
   GitHub, is fetched from `origin` first; if it still cannot be read, no task's
   landing changes and the report says carriage could not be verified. A task
   with neither branch nor reaped tip lands if a commit its `landing_detail`
   names is in the head; one still marked `landed` otherwise becomes `pending`
   and is named in the report as unverifiable. It archives under
   `afterEpicMerge`, and queues a `decision` report naming any task that was
   not done. `CLOSED` returns the epic to `active` and queues a `decision`
   report with the reason. A `gh` failure changes nothing.

   The pull request's head is the **published** name (§6.1), not the local
   `agentboard/epic-<id>`, on both routes — the button's compare page and the
   approved `open_pull_request` aim at the same ref.

   An epic whose tasks are not all `done` is **not** refused here, unlike
   `request_integration`. Opening a pull request early for review is a real
   workflow and the approval is already a human gate; the approval row names
   how many tasks are unfinished, so the mistake is visible to the person
   deciding rather than pre-empted for them.
