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

any column but running/done ──close_task(reason)──> closed ──human Reopen──> ready
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
- **Resumed** — before a stopped worker in its own worktree is woken, a task in
  an epic has `agentboard/epic-<id>` merged into its branch, in that worktree,
  so it sees what siblings accepted since it last ran. Only the epic branch,
  never the project's base; a task in no epic, a shared placement, a reviewer
  and a wind-down delivery (§8.1) merge nothing, and spawn never merges — it
  already cuts from the epic head. An epic branch already in the task's
  history does nothing and says nothing. Uncommitted work the previous run left
  is first committed, unchanged and hook-free, as `Save uncommitted work left
  by an interrupted run`: a stash would go on the stack every worktree of the
  repository shares, and git refuses to reapply one over a conflicted merge,
  which is exactly when it matters. The merge commit is titled from the epic's
  and task's titles, never branch names (§5.2). A conflict never refuses the
  resume and is never resolved by the board: the worker wakes in the
  conflicted tree, and the resume prompt says before anything else that the
  epic branch was merged, which files conflicted, that resolving them is part
  of the task (D21), and that it is not done until the tree builds and the
  suite passes. A clean merge names the commits and files it brought in; a merge
  still unresolved from an earlier resume is reported again rather than
  retried; a merge git refused tells the worker to merge the epic branch
  itself. The prompt names any commit made of the worker's uncommitted work.
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
  to stop aborts the accept or reopen before anything is written. An accept a
  tool call makes (`report_complete` under no review, `accept_task`) is the
  exception to that order: it moves the task to `done` and revokes every
  session's grant before answering, and stops the live sessions after the
  answer (§6). There a session that refuses to stop leaves the task in `done`
  with `landing` `unlanded` and its worktree kept, reported as a `decision`.
  The accept then lands the task's branch, below, and only after that is every attempt's
  worktree removed, running the project's teardown hook first (§3.1, "Removing
  a worktree") and then any `WorktreeRemove` hook in `~/.claude/settings.json`,
  with `agentboard/<task-id>` deleted once it is merged into the
  base or epic branch. An unmerged branch is kept and the reason surfaced in
  the status bar. Landing comes
  first because removing a large worktree can take over a minute, and until the
  merge runs a dependent cut from the target branch lacks this work. A task's
  newest attempt that carries a branch decides which branch lands: a task whose
  newest attempt ran on a shared branch lands as that branch's member, and one
  retried from a shared branch into a worktree lands `agentboard/<task-id>`. A
  shared member has no worktree of its own on that branch, so the removal of
  any earlier attempt's worktree starts first.

  A worktree with uncommitted changes is kept — the teardown hook does not run
  in it — and so is one git refuses to remove. Whenever that happens, for any
  reason, or a teardown hook fails or times out, the acceptance's `decision`
  report says so under **Worktree cleanup:**, naming the worktree and, for a
  dirty one, its uncommitted paths (the first 20, then a count), so the
  orchestrator can act on a leftover like a `yarn.lock` its setup wrote. The
  same lines go on the task's progress. An accept that answers an MCP call
  (`report_complete` under a no-review level, a rostered reviewer's
  `accept_task`) returns once the task is in `done` and its grants are
  revoked; the landing and the removal run after it (§6). Landing a shared
  branch moves the project's checkout off it with `git checkout`, which runs
  the repository's `post-checkout` hook, and removal runs `WorktreeRemove`
  hooks, so neither has a bound the answer could wait out. The worktrees are
  claimed before the answer, so no reap takes one for an orphan while the
  landing runs, and a landing that goes wrong still arrives as its `decision`
  report. A human's Accept lands inline. With a teardown hook set, the
  removal runs after the accept returns in every case, on a shared branch too,
  because the hook may run for minutes. Its findings are appended to the acceptance
  report while the orchestrator has not read it, and otherwise queued as a
  `decision` report of their own. With no hook, a human's Accept removes the
  worktrees inside the accept. Discarding a task removes its worktrees the same
  way before the task is deleted; the task's progress goes with it, so its
  findings are kept only in the discard's `decision` report. A discard that
  lands while a spawn of the task is still setting up (§3.1) cancels that setup
  and waits for it to end before looking for worktrees: a setup cancelled before
  `git worktree add` creates nothing, and one already running its hook finishes,
  so the removal finds its worktree. That setup's end queues no report. A spawn
  that is still computing its checkout when the discard begins has no session
  for the discard to find, so the spawn checks for the discard itself: it is
  refused if the discard is under way when it would write its `setup` row, and
  a reviewer's spawn, which creates its worktree before any row, is refused if
  the task is being discarded or gone once it is past the teardown's claim.

  A task leased a worktree slot (§3.1 step 2) has it *released* instead of
  removed, by accept and discard alike: `git switch --detach` at its last
  commit, so its branch is no longer checked out and can be merged or deleted
  like any other, then `git clean -fd` — never `-x`, which would delete the
  ignored build output the slot is kept for. No teardown hook runs, and the
  repository's `post-checkout` hook is skipped for the detach, which changes
  no file. A slot with uncommitted changes stays leased, out of the pool,
  reported under **Worktree cleanup:** like a kept worktree, until a person
  resolves it; `reconcile` then releases it, as it does any lease an accept
  or discard did not get to.

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
  worktree was used before, and it fired `post-checkout`: on a work project this runs its
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
  file as deleted. So the accept defers instead. "Holds" is decided the way the
  reaper below decides it, from git's admin files: a worktree whose `HEAD`, an
  in-progress rebase or an in-progress bisect names the branch. When any of
  those files cannot be read the merge refuses, and the task is `unlanded` with
  the unreadable directory named, rather than trusting `git worktree list`.

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
  "Integrate standalone tasks and epics by" is *Pull request* or *Local merge*. A project
  that never chose stores neither, and the accept resolves it by running
  `git remote get-url origin` off the main actor: a repository with an `origin`
  integrates by pull request, and only one git explicitly reports has none
  (exit 2, "No such remote") by local merge. Any other read — no repository,
  no git, an unreadable config, no pipe to read git's output through, or exit 0
  with an empty URL — is a failure and never means local merge: the accept keeps the answer it
  last resolved for that project in this run, and with none it merges nothing,
  leaving the task `unlanded` with git's exit status and stderr in its detail;
  an integrator spawn is refused with the same error and tells the orchestrator
  to call `request_integration` again or choose an integration in Publishing.
  Each derived answer, and each refusal, is logged (subsystem `AgentBoard`,
  category `integration`) with git's exit status and stderr. The picker's first entry is that default, labelled with
  what it resolved to ("Pull request (default: has origin)"); a stored choice
  always wins. The same resolved choice decides whether an integrated epic
  waits on its pull request (§5.2 step 4), which is why the picker reads
  "Integrate standalone tasks and epics by". Only `gh` opens and checks pull requests, so an `origin` on a
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
- `closed` — a terminal column beside `done` for a task retired without being
  finished: its work was done some other way, it was superseded, or it is no
  longer wanted. Only the orchestrator's `close_task(task_id, reason)` (§6)
  enters it, through `Board.close`, and the reason is required. The reason, the
  time and who closed it are written to `closed_reason`, `closed_at` and
  `closed_by` (§4) and to a `progress` row, so the history keeps them after a
  reopen. Nothing else moves: no branch, worktree, session row, report or
  comment is touched.

  `closed` is not `done` and nothing that reads `done` reads it. A closed task
  does **not** satisfy a dependency — readiness asks for `done`, so a dependent
  stays in `backlog` — and `close_task`'s answer names every unfinished
  dependent so the orchestrator can `set_deps` it or close it too. There is
  deliberately no option to let a closed task satisfy its dependents: whether a
  dependent still needs the work is a per-dependent judgement that `set_deps`
  already records exactly, and a second meaning of `closed` would be one more
  thing every reader of the dependency graph has to check. A closed task never
  has a landing (`landing` is cleared on leaving `done` and never armed for
  `closed`), is never merged by the accept path or listed for the integrator,
  is not in At a Glance's counts, and never counts towards an epic's done
  tally. An epic is ready for integration (§5.2) when every task it holds is
  `done` or `closed` and at least one is `done`, so a retired task cannot hold
  an epic open.

  Refused, by `Board.close`: a blank reason; a task in `done` (it is already
  finished — accepted work is not retired after the fact); a task already
  `closed`; an epic's integration task (`origin = integration`) while its epic
  is still open, since §5.2's own path or `close_epic` ends it; and any task an
  active session holds, worker or rostered reviewer — stop it first. Once the
  epic is `done` or `abandoned` its integration task can be closed like any
  other: nothing else will ever end it. A stranded task in `running` with no live
  session can be closed. No spawn takes a closed task, and a session on one is
  settled: `reconcile` and `SessionStart` never revive it (§7). A spawn
  approval still waiting for the task is resolved `denied` in the same
  transaction, so the human queue does not keep an item nobody can approve.

  An epic that ends any way but through its own integration task completing —
  its pull request merging (§5.2 step 5) or `close_epic` — closes that
  integration task in the same transaction, from any column but `review`,
  `done` and `closed`, with a reason naming how the epic ended ("Epic … is
  done: its pull request #N merged." or "Epic … was closed as abandoned."). One
  in `review` finished its work and waits for a person, so it is left for an
  accept or a `close_task`. One an active session holds is left where it is,
  and the epic's `decision` report names it and its session; stop the worker,
  then `close_task` it. Without this an integration task whose integrator
  failed sat in `ready` forever after its epic's pull request merged, refused
  by `close_task` and with no integration left to run.

  Closing needs no human approval, with autonomy on or off. It deletes,
  publishes and spends nothing, a human reverses it in one click, and the card
  stays on the board in its own column with the reason on it rather than being
  hidden. Gating it would put back the problem it solves — obsolete tasks sitting
  in `ready`, one mistaken spawn from running — until a human got to the queue.

  A human reopens a closed task from the board (the card's or inspector's
  **Reopen**). `Board.reopen` clears the `closed_*` fields and any archive, moves it to `ready`
  — or `backlog`, if a dependency is no longer `done` — and queues a `decision`
  report quoting the reason it had been closed for. The orchestrator cannot
  reopen one: `move_task` refuses a closed task, so the human stays the judge of
  retired work. Neither a human drag nor `move_task` can enter `closed`; only
  `close_task` writes a reason.
- `archived` — also a flag, not a column, with `blocked` and `failed` as the
  precedent: D7's columns are unchanged by the archive feature. Only a `done`
  or `closed` task can be archived (§4), and archiving does not move it — an
  archived task is still in its terminal column, just hidden from the default
  board query.

Reconcile also reaps worktrees under the project's worktree root that no active
session owns, and deletes merged `agentboard/*` branches that no longer have a
worktree. Reconcile runs only while a project's Status view is open, so the
supervisor's metering tick runs the same reap on every project every three
minutes as well, the first one three minutes after launch, keeping the
worktrees of the sessions whose rows are active. The two are serialized per
project: a reconcile waits for a tick reap in progress, and the tick skips a
project whose reconcile is running. The tick starts each project's reap and
does not wait for it, so metering, cap and stall checks are never held up by
git removals. A spawn's new worktree is clean and at its base until its
worker commits. The spawn marks the worktree's path before it touches git and
clears the mark when its setup ends (§3.1), and a reap keeps every marked path
as well as every path an active row names, the `setup` row included. Because a
reap's list of active sessions predates its git scan, it rereads the active
rows and the marks after the scan and claims its orphans in the same step, with
no suspension point between, so a spawn or resume either marked its path first
or waits on the claim. Resuming a stopped session marks its worktree the same
way until the session is active again, and is refused when a reap or teardown
has already claimed that worktree: the removal is already running, and a
session resumed there would lose its checkout. A resume is also refused while
another active session holds the task or the worktree, as a spawn is: resuming
a worker whose rostered reviewer is still reviewing would put two agents in one
checkout. A resumed session keeps what it was spawned as, read from its grant's
scope rather than its row's role: a reviewer gets a `reviewer` grant back and its
task stays in `review`, where a worker's task moves to `running`. A reviewer whose
task has left `review` since it stopped is refused, since its verdict would land
on a task nobody asked it to judge. The other direction holds as well: a respawn
reuses the task's worktree when it is still on disk, but not one a reap or
teardown has already claimed for removal (§3.1). The spawn waits for that
removal to finish and then creates a fresh worktree at the same path. It waits
only on a claim for its own path, so it is never held up by removals of other
worktrees. Anything dirty or unmerged is left alone and reported. A task branch
cut moments ago sits exactly at its base, so it reads as merged until its
worker's first commit. Once its worktree exists the worktree check protects it;
before that, the branch sweep skips `agentboard/<task-id>` while the spawn's
mark is on `<root>/<task-id>`, and claims that path, as a teardown would, for
every other task branch with no worktree there until its delete is done, so a
spawn that marks the path afterwards waits on the claim before `git worktree
add`. Without the claim, a worktree added between the sweep's check and its
delete would lose its new branch. The worktree check
reads each worktree's `HEAD` (and an in-progress rebase's `head-name` or
bisect's `BISECT_START`) from git's own admin files and keeps the branch when
any of them cannot be read: `git worktree list` exits 0 in that case while
leaving the worktree, or its branch, out of the list, and a sweep that trusted
it deleted a running task's branch. A dead registration holds nothing and is
pruned before the check: one that is not locked and whose `gitdir` is missing
or names a `.git` file that is gone, which is what `git worktree prune` removes.
Left in place, git would keep refusing to delete its branch or check it out
anywhere else. A `gitdir` that cannot be read is not dead but unreadable, since
whether its worktree is gone is unknown. The same holds when the admin entry or
the worktree directory cannot be searched, and when `.git/worktrees` can be
listed but not searched, so its entries cannot be told apart from stray files:
only a positive "no such file" makes a registration dead or drops an entry. A linked entry with no `HEAD`
names no branch, as git reads it. One unreadable record blocks every branch's
check, so the sweep names that directory once in the status bar, with how many
branches it kept. The delete itself is guarded by the tip that was checked. The teardown
hook runs before each removal (§3.1); a failure goes on the progress of the
task whose session held the worktree, in a `decision` report of its own, since
no other report marks the removal. A kept orphan stays a status-bar notice:
the reaper finds it again on every pass. With a hook set, the removals run in
the background after `reconcile` has decided what to remove, so a pass that
finds orphans returns at once instead of waiting up to the hook timeout for
each; the next pass skips whatever is still being removed (§3.1, "A hook runs
at most once"). Epic
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

The spawn answers once the reviewer's setup row exists, so a setup that fails
after that, launching `claude` or reading back its session, takes the same
route as a worker's (§3.1): the row ends `failed` with a "Worker never started"
report to the orchestrator and a notification, or "Worker started, then stopped"
when the failure came after `claude --bg` launched it, or "Worker started; stop
not confirmed" when that agent could not be confirmed stopped. All three count as
a setup failure wherever §13 counts one. The task stays in `review`, and
because the failed row is the newest session and names the reviewer, its Pending
reviews row reads `<reviewer> stopped without a verdict` and offers Re-run
review (§10), the one way it is retried; nothing retries it automatically. A session `claude --bg`
started whose id `claude agents --json` then does not return is stopped before
setup fails, because the board never records it and it would otherwise review
the same worktree alongside the retry. `attempt` counts every session on the
task, worker and reviewer alike, so a reviewer's attempt number is not a count
of reviews.

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
that decision report and inserts no second one. A session whose row is still
active but which no longer holds the task, because a newer active session is
working it, is refused outright: the call errors, nothing is recorded, and the
task stays where the newer session has it. On 2026-10-07 the idle-capped
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
no verdict. The first time that happens in a reviewer session, the hook answers
with `hookSpecificOutput.additionalContext` carrying `ReviewPrompt.verdictOwed`,
which continues the turn: give the verdict now, read whatever a background
command has written instead of waiting for it, and name what did not finish.
A `status` row headed "Reviewer's turn ended without a verdict." records the
reminder and makes it once per session (`Board.remindReviewerOfVerdict`). If the
turn ends again with no verdict, nothing accepts the task: its Pending reviews
row reads `<reviewer> stopped without a verdict` (§10), and one `blocked` report
per reviewer session tells the orchestrator. The session is left idle, not
stopped; the orchestrator can message it or `stop_worker` it, and the human can
Accept, Re-run review or Reopen from the row.

Every missing verdict measured before the reminder existed had one cause. Seven
reviews between 2026-09-29 and 2026-10-08 each ended on a text-only "still
waiting on the tests" message while a `swift test` ran in the background: started with
`run_in_background`, or a foreground run that outlasted the Bash timeout (120 s
default, 600 s maximum) and was moved to the background, after which the
reviewer waited with `ScheduleWakeup`, a `Monitor` or `sleep`. A full run of this
suite outlasts the 600 s ceiling, so "run it in the foreground" alone cannot
hold a full run in one tool call. `ReviewPrompt` therefore tells the reviewer to
run builds and tests in the foreground, filtered to the suites that cover the
diff and never the whole suite, never to wait on a backgrounded command, and to
give the verdict and name what did not finish when a check cannot finish; the
reviewer's `--disallowedTools` also denies `ScheduleWakeup`, `Monitor` and
`CronCreate`.

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
worker's claims by reading and running the code. The report is withheld on
purpose, so the review does not lean on the worker's own account; because the
reviewer cannot see what the report disclosed, `ReviewPrompt` and the reviewer's
`get_my_task` description tell it never to file a finding about what the worker
did or did not disclose. `ReviewPrompt` says so; its
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
is empty. For a standalone task `<base>` is `WorktreeManager.diffBase`: the
recorded cut point while local base is still behind it (§3.1 step 1), so a
branch cut from the remote's base is not read as carrying the remote's
commits. The same `<base>` goes into the reviewer's prompt and is stored in
`agent_session.review_base`, which `briefing://reviewer` and the
post-compaction brief rebuild from. `report_complete` then leaves the task in `review` for a person
(`Board.leaveReviewToPerson`: `reviewer_agent_id` cleared, the reason in a
`status` row, exactly as `humanReview` routing parks it) and tells the worker
so. No reviewer starts and nothing is flagged as an error.

### 5.2 Epic integration

Integration is gated on your approval regardless of the autonomy setting, and
can be requested two ways that land on the same row: the orchestrator's
`request_integration(epic_id)` tool, or the epic lane's **Request integration**
button. The tool refuses until `epicReadyForIntegration` holds — every task in
the epic is `done` or `closed` (§5) and at least one is `done` — naming how many
tasks remain; the
button only appears once that is already true, so neither path can jump the
gate. Either call reaches `Board.requestIntegration`; a repeat request while
one is already pending returns the existing approval rather than queuing a
second.

This is the path that ends an epic by *finishing* it. §10's **Close as done**
and **Abandon** are the other way out, for an epic you are finished with rather
than one that is finished; they merge nothing and are not part of this sequence.

1. All tasks in the epic reach `done`, or are retired to `closed`. A closed
   task's branch is not listed for the integrator.
2. Orchestrator calls `request_integration(epic_id)`. This creates an approval
   row and a macOS notification. Nothing proceeds until you approve.
3. On approval, Agent Board creates an integration worktree on
   `agentboard/epic-<id>` and spawns an integrator worker. As for any task
   (§3.1), the worktree is created in setup, after the spawn has answered, so
   `spawn_worker` on an integration task does not wait out the repository's
   `post-checkout` hook. The epic moves to
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
   How much of that the integrator runs is `settings_json.integrationVerification`
   (§4). **Build and test**, the default, is the above. **Build only** runs the
   build — the command, or one worked out — and no tests. **None: CI verifies**
   runs neither: for every branch it merged or found already merged it checks
   `git merge-base --is-ancestor <branch> <epic branch>`, checks that the
   epic's diff against the base branch adds no `<<<<<<<` or `>>>>>>>` line, and
   says in its report that the build and tests were left to CI. The prompt's
   opening line drops "leave the build green" under that policy. Under it a
   conflict the integrator resolved by hand still gets the narrowest build that
   compiles the resolved files, and no tests: that resolution is code no worker
   compiled and no reviewer saw, while every other line on the epic branch was
   tested by its worker. The policy exists because a whole-tree suite on the
   board's machine re-verifies already-tested commits while competing with live
   workers for CPU and disk, and the epic's pull request runs it in CI anyway.
   It tells the integrator never to end its turn to wait for a command, and
   ends with the same *How your turns end* section a worker's prompt does
   (§3.1 step 6). Without them an integrator with nothing to merge started its
   full test run in the background, ended its turn to wait, and was stopped by
   the idle cap four times without ever reporting.
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
   Respawning that task — `spawn_worker` on it once an idle cap or a stop has
   ended its integrator, or a spawn approval for it — goes through
   `spawnIntegrator` too, never the ordinary task spawn: the same epic
   checkout on the epic branch, the same task with the next attempt number,
   and a prompt recomposed from the branches as they stand. A failed respawn
   keeps the task. `assign_to_agent` on an integration task is refused, with
   guidance to call `spawn_worker` or `request_integration` instead:
   integrators are not rostered, and a roster spawn would take the ordinary
   path. Before `git worktree add`, `WorktreeManager` prunes a dead
   registration (§5) of the path it is about to create, since git refuses
   that path and does not prune it itself; an epic checkout whose directory
   is gone but still registered is recreated rather than refused.
4. The integrator reports. What its report does to the epic depends on how
   the project ships an epic to its base branch. That is the same choice that
   decides standalone tasks (§5, "Integrating standalone tasks by pull
   request"): the stored setting, or, when none is stored, whether the
   repository has an `origin`. `spawnIntegrator` resolves it — the `origin`
   check runs git, which `Board` cannot — and records it on the epic as
   `ships_by_pull_request` (§4), so the report is settled by what was true when
   the integrator started. A respawned integrator, or a fresh one for an epic
   already set to ship by pull request, keeps it so without resolving again: a
   later answer never turns the flag back to local merge.

   **A project that ships epics by pull request.** Integration only merged the
   task branches into the epic branch; nothing has reached the base branch and
   nobody has reviewed it. `Board.complete` moves the epic to `integrated`, not
   `done`, and archives nothing. The integration task goes to `review` and is
   routed like any other completion. An `integrated` epic is open in every
   sense a `pull_request_open` one is: `create_task` and `set_epic` accept it,
   its new tasks branch from the epic branch, accepting one merges into that
   branch, its lane stays on the board, and it can be integrated again. The
   orchestrator is told the next step in two places: a `decision` report from
   the same transaction says the epic is integrated, that it stays open, and
   to call `open_pull_request(epic_id)`; and `get_epic` returns that step as
   `next_step` for as long as the epic is `integrated` (for a
   `pull_request_open` epic, `next_step` says to wait for the merge and to
   `push_branch` anything accepted since). The integrator's own
   `report_complete` answer says the epic stays open. Step 5 takes it from
   there: recording the pull request moves it to `pull_request_open`, and the
   merge makes it `done` and runs the `afterEpicMerge` archive. The lane offers
   **Open PR** on an `integrated` epic. Before this, integration closed the
   epic in these projects too: it refused new tasks before its branch was
   pushed, archived tasks that had not reached `main`, and hid the lane.

   **A project that merges epics locally**, and any epic whose integrator
   predates `ships_by_pull_request`, behaves as follows. Under the default
   `afterEpicMerge` archive policy
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
   its task in `review`, whichever way the project ships, so approving
   integration never marks an epic `done` while its pull request is unmerged.
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
   not `request_integration` ran first, and including an `integrated` or a
   `done` epic.

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
   not done. It closes the epic's unfinished integration task (§5, `closed`)
   and names it in that report. `CLOSED` returns the epic to `active` and queues a `decision`
   report with the reason. A `gh` failure changes nothing.

   The pull request's head is the **published** name (§6.1), not the local
   `agentboard/epic-<id>`, on both routes — the button's compare page and the
   approved `open_pull_request` aim at the same ref.

   An epic whose tasks are not all `done` is **not** refused here, unlike
   `request_integration`. Opening a pull request early for review is a real
   workflow and the approval is already a human gate; the approval row names
   how many tasks are unfinished, so the mistake is visible to the person
   deciding rather than pre-empted for them.

**The epic branch's lifecycle, in one place.** An epic branch is cut from the
project's base branch the first time one of its tasks is spawned or accepted
(§3.1 step 1); every task branch inside it is cut from the epic branch, never
from the base directly (§3.1 step 2). A task branch catches the epic branch
back up only on resume (above), and only with the epic branch — never with the
project's base branch directly. D21 is the rule everything else here follows
from, scoped to that moment: an agent working a ticket owns making its own
work mergeable into the epic branch, so a conflict a sibling's already-accepted
work left in its path when its own task resumes is still that agent's to
resolve. The board never resolves one for it — a resumed worker wakes inside
the conflict rather than having the resume refused (above) — and nothing here
defers that resume-time conflict to a timer.

D21 does not reach into step 3's job above: a branch whose merge into the epic
branch conflicted during integration is not a resuming agent's conflict to
find, because no task is resumed to find it, and resolving it stays the
integrator's leftover work exactly as step 3 assigns it. The two are a single
rule read at two points in a task's life — while an agent is still working a
ticket, a sibling's conflict in its path is its own; once a branch is already
accepted and the agent is gone, the conflict is the integrator's.

**Drift and refresh.** An epic branch advances only when a task is accepted
into it or when you ask the orchestrator to refresh it — never on spawn, never
on a timer. `get_epic` reports `base_drift` next to `ready_for_integration`:
`behind` (the base branch's commits the epic branch lacks) and `ahead` (the
epic's own), from one `git rev-list --left-right --count` per call, measured
under 10ms on this repository. The count is taken against
`refs/remotes/origin/<base>` as the last fetch left it, when that ref exists and
local `<base>` is behind or equal to it, and against local `<base>` otherwise —
the rule §3.1 step 1 cuts epic branches by, so an epic cut from `origin/main`
is not read as current against a lagging local `main`. `get_epic` never
fetches, since orchestrators call it constantly and a fetch can take 10
seconds, so `against` names the ref counted from (`origin/main` or `main`) and
a count can be read as only as fresh as the last fetch. An epic branch not cut
yet, or a missing base branch, reports `behind` and `ahead` as null with
`unavailable` saying which. Drift is reporting only: it raises no attention
badge and no notification.

`refresh_epic(epic_id)` merges the project's freshest base branch into the epic
branch: it fetches `origin/<base>` as §3.1 step 1 does and merges the fetched
tip when local `<base>` is behind or equal to it, local `<base>` otherwise. A
failed fetch falls back to local `<base>`, and the answer says so. Every answer
names the ref merged (`Merged origin/main into …`, `already has every commit on
origin/main`).
The merge commit is built with `merge-tree --write-tree` and `commit-tree` on
no ref, as an accept's merge is (§5), and its subject names that same ref
(`Merge origin/main into <epic title>`). Which commands a refresh runs follows
`integrationVerification` (§4), as the integrator's do (step 3): **Build and
test** runs the build and test commands; **Build only** and **None: CI
verifies** run the build only, and their answers say no tests ran because the
epic's pull request CI runs them. Neither skips the build: CI never sees the
task branches that resume from the refreshed epic, so the build is all that
stops a worker resuming on a branch that does not compile. If the project
configures a command its policy runs, the commit is checked out detached in a
scratch worktree (`<worktree-root>/refresh-<epic-id>-<random>`, removed
afterwards) and those commands run there, build first; the epic branch moves,
by an `update-ref` guarded by its old head and serialized with accepts' merges,
only once every one of them passes. A command the policy runs but the project
does not configure is never guessed at: the refresh applies and its answer says
`NOT VERIFIED`, names what was not run, tells the orchestrator to work it out
and run it — the integrator's Build and test wording (step 3) — and gives the
head the branch had before. So a **Build only** project with a test command and
no build command runs nothing, and its answer says both that nothing was built
and that no tests ran. A
conflict, a failing command, or an accept landing on the epic branch while the
build ran leaves the branch exactly as it was; a conflict names its files, and
both a conflict and a failure say that fixing it by hand or by a dispatched
task is the human's call. Refused for a `done` or `abandoned` epic, for a
missing base branch, and while any working tree has the epic branch checked
out — naming the path and, when one is on record, the session working there —
because moving a checked-out branch leaves that tree showing the merged files
as deleted.

*It answers before anything is built.* Claude Code 2.1.285 abandons a call to
an HTTP MCP server whose response headers have not arrived 60 seconds after the
request (measured: a stub server that answered in 5s returned, one that took
90s got "The operation timed out." at 60s), and the board answers a tool call
only once it is done. A cold `swift build` in a checkout with no `.build` takes
about 9 minutes here. So with a command to run, `refresh_epic` answers as
soon as the merge commit exists: the commit, the commands and the timeout, and
that the branch stays where it is until they pass. The verdict — every outcome
above — is queued later as a `refresh` report (§9.1) and announced like any
other. With no command to run nothing needs to wait, and the answer is the
verdict.

*One refresh per epic at a time.* A second `refresh_epic` for an epic whose
check is still running is refused, naming the commit being verified; nothing
new starts. Each check's scratch worktree also has a name of its own, and
leftovers a crash stranded under `refresh-<epic-id>` are removed before a new
check starts — safe only because no other check of that epic can be running.
An orphan reap (§5) leaves a running check's scratch worktree alone; an epic
with no commits of its own fast-forwards, so that worktree sits on the base
head and would otherwise read as merged.

*Each step is bounded.* Creating the scratch worktree, the build and the test
are each stopped once they run past the project's verification timeout
(`verificationTimeoutSeconds`, default 30 minutes — over three times a cold
build here; the settings sheet takes it in minutes, and §4 gives its range).
Time is counted on `CLOCK_UPTIME_RAW`, so a Mac asleep mid-build does not use
it up. A step past
its timeout gets SIGTERM for its whole process group, then SIGKILL 5 seconds
later; anything left in the group when the command exits is killed too. The
branch does not move and the report says "timed out after" the timeout.

*The checkout runs the repository's hooks.* `git worktree add` fires
`post-checkout` for the scratch worktree, exactly as it does for a task's
worktree (§3.1 step 2), because the check is meant to say whether the merge
builds the way a task spawned from it will — and for a repository whose hook
is its setup (one project's runs a full `setup.sh`), a build without it fails for
a reason that has nothing to do with the merge. The cost is the hook's full
runtime on every check, inside the same timeout.

*A failure the board caused is never a verdict.* A scratch worktree that cannot
be set up (including a failing or timed-out hook) and Agent Board quitting
mid-check both report that the refresh did not finish, that the branch did not
move, and that no build or test failed — never that the merge is broken.

**Worktrees a closed epic leaves behind.** Nothing reaps an epic's integration
worktree (`<worktree-root>/epic-<epic-id>`, on the epic branch), and a task
worktree kept for uncommitted changes stays where it is. Once an epic is
`done` or `abandoned` nothing will push from its branch again, so whatever is
still on disk for it is a leak: on a work project, an integration worktree whose work
moved to another epic held an 11.5 GB output base. `Board.heldWorktrees`
lists them: every recorded `worktree_path` of a session on a task in the epic,
its integration task included, plus the epic's integration checkout, each kept
only while the directory exists and never the project's own checkout. The
`decision` report `close_epic` and the lane's close write, the one the
merge check writes when the epic's pull request merges, and the one an
integration task's `report_complete` writes when it takes the epic to `done`
by direct merge, list them with their paths and owning tasks. That last report
leaves out the integration checkout while the integration task goes to
`review`, because accepting it removes that checkout and reports anything it
keeps; under `afterEpicMerge` the task is archived instead of accepted, so the
checkout is listed. `get_epic` returns them as `held_worktrees` for a
`done` or `abandoned` epic. The human removes them with **Remove worktrees** on
the epic lane's menu (§10): each goes through `WorktreeManager.remove`, so the
teardown hook runs first. One a live session holds, or one with uncommitted
changes, is kept and named; no branch is deleted. A `decision` report lists
what was removed and what was not, and each finding also goes on its task's
progress.
