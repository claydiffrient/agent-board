## 8. Safety and limits

Per project, overridable:

| Cap | Default | On breach |
|---|---|---|
| Concurrent workers | 3 (lower for large repos — Derivita) | Spawn refused; orchestrator told why |
| Tokens per agent (uncached input + output) | off until set | Agent stopped, task flagged, Resume offered |
| Elapsed per agent, sleep excluded | 30 min | Agent stopped, task flagged, Resume offered |
| Idle (no tool use, no output), sleep excluded | 5 min (6× while a tool call is running) | Agent stopped, task flagged |
| Project session ceiling | configurable | Spawn refused |

- **A rostered session (`agent_session.roster_agent_id` set — a worker spawned
  by `assign_to_agent`, or a reviewer spawned under `agent` review) is exempt
  from the elapsed and idle caps.** `WorkerSupervisor.exempting` overrides both
  to `nil` before `CapEvaluator.evaluate` runs, so a session spawned from an archetype can neither
  stall out nor run long and be stopped for it. **This is deliberate, not an
  oversight** — the epic that built the roster decided no caps apply to it for
  now, on the reasoning that a durable, human-curated identity is not the same
  liability as an unattended one-off worker — and it is meant to be revisited,
  not treated as the final shape. The token cap is unchanged for a rostered
  session: it meters spend, not liveness, so it still applies when a project
  sets one. The concurrent-workers and session-ceiling caps are unaffected
  too, since both count on `role = 'worker'` in `agent_session`, which a
  rostered session still is.
- A stopped agent's task returns to `ready` with its `failure_reason` set, and a
  `failed` report goes to the orchestrator (§9.1). Leaving it in `running` with
  no session strands it: nothing can be spawned from `running`.

- The token cap counts uncached input plus output only. Cache reads recur every
  turn and cache writes re-cache the whole context on every resume (measured:
  200k+ per resume on an M2-sized worker), so neither is a measure of work done.
  Counting cache writes killed the first M2 worker twice in ten minutes; the cap
  is therefore off until a project sets it.
- **Every time cap is measured on a clock that stops while the machine sleeps.**
  Darwin's `CLOCK_UPTIME_RAW` excludes system sleep; `CLOCK_MONOTONIC` and
  `CLOCK_MONOTONIC_RAW` do not (measured: 20.3 days since `kern.boottime`,
  `CLOCK_MONOTONIC` 1_752_842s, `CLOCK_UPTIME_RAW` 666_698s — 12.6 days of
  sleep). `SleepLedger` samples both clocks on every metering tick and records
  each suspend it sees; `AwakeElapsed` subtracts those from a wall-clock
  interval. Both time caps, `caps.stallSeconds` and `caps.shutdownGraceSeconds`
  read it. Closing the lid for longer than the idle cap used to execute every
  running worker on wake — one of them holding finished, committed, green work
  — because a suspended `claude --bg` process makes no tool calls and the cap
  counted every sleeping minute against it. Archive retention
  (`ArchivePolicy.afterDays`) stays on the wall clock: it bounds calendar time,
  not work. So does the token cap, which is a count, not a duration.
- **A tool call that has started and not returned is not silence.** `PreToolUse`
  fires before a tool runs and `PostToolUse` only when it returns, so a single
  long command writes no hook for its whole duration. A cold `swift build` on
  Agent Board itself measures 544s, and a worker with 376 counted tokens and
  `Bash` as its last tool was executed mid-command for "no activity for 15
  minutes". `PreToolUse` records the start on the session row
  (`tool_started_at`, `tools_in_flight`) and `PostToolUse` clears it; an
  outstanding call then extends both the idle cap and the stall threshold by
  `ToolCallGrace.multiplier` — 6×, so 1800s and 720s at the defaults, the
  former exactly the default elapsed cap. The grace is finite by construction
  and is only ever consulted after a deadline has already been breached, so a
  command that never returns is still reaped, and a `tool_started_at` left
  behind by a lost `PostToolUse` costs a worker its grace rather than its life.
  `Stop` and `SessionEnd` clear the marker, bounding any lost `PostToolUse` to
  the turn it went missing in. `tools_in_flight` counts rather than flags
  because Claude runs parallel tool calls: the row keeps the oldest outstanding
  start, so a short call returning cannot end a long one's grace.
- **Autonomy is off on first run.** Every `spawn_worker` creates a pending
  approval until you turn it on. This is a setting, not a rebuild.
- **Stopping is not destructive.** Every session has a pinned `--session-id`, so
  a capped agent resumes exactly where it stopped.
- **Pause All** stops every managed session in the project via `claude stop`.
- **Integration always requires human approval**, autonomy setting regardless.
  So does every outward-facing publish: `push_branch` and `open_pull_request`
  (§6) create an approval row and return it. Both are visible to collaborators
  and CI the moment they happen and cannot be taken back, which is why neither
  is reachable through the autonomy setting.
- **Workers never push.** Unchanged by the D8 amendment (§1). Enforced twice, by
  two controls that fail independently:
  1. `--disallowedTools "Bash(git push*)" "Bash(gh pr create*)" "Bash(gh pr
     merge*)"` at spawn time, a CLI-level block.
  2. A `PreToolUse` hook (§7) matched to `Bash`. `IntegrationGuard` scans the
     command for `git push`, `gh pr create` and `gh pr merge` and Agent Board
     returns a deny from its own process, so the block does not depend on the
     session's permission mode. The scan tokenizes on shell punctuation as
     well as whitespace, so a chained, quoted, piped or env-prefixed
     invocation (`cd x && git push`, `git -C d push`) is caught too, and a
     token counts as `git` or `gh` when its trailing path component is, so
     `/usr/bin/git push` and `/opt/homebrew/bin/gh pr create` are caught as
     the bare spelling is. It remains a heuristic: an invocation assembled at
     runtime (`$G push`, an `eval` of an encoded string), reached through a
     wrapper script or an alias, or spelled in another case gets past it, and
     a merely mentioned `echo git push` is over-matched. Every denial appends
     an `error` progress row naming the blocked command, so the human sees the
     attempt on the task card.

  The verdict is scoped at the grant, not the prompt (D4): the guard reads
  `identity.scope`, and the deny text differs accordingly. An orchestrator grant
  is not denied the push and pull-request-create shapes — its authority to reach
  the remote is real, and is spent through `push_branch` and
  `open_pull_request` — but is still denied `gh pr merge`, because merging a pull
  request is the human's call and Agent Board has no tool for it. A worker grant
  is denied all three, and the text it gets still names workers; the text an
  orchestrator gets names the tool to call instead and never claims the caller
  is a worker.

  Either control alone stops the call; layer 2 exists so a dropped or
  misconfigured spawn flag is not a silent hole. Verified live: with
  `--disallowedTools` deliberately emptied, a worker's `git push -u origin
  HEAD` was denied by the hook and the bare remote stayed at its initial
  commit (§12).
- A project `autoMode` classifier rule is **not** a control for an unattended
  worker. Both `soft_deny` and `hard_deny` reach a `--bg` worker's effective
  config and neither stops a matching call under `--permission-mode auto`; see
  §12. The push/PR `soft_deny` rules shipped in the default `autoMode` block
  document intent and cost nothing, but the `PreToolUse` hook is what enforces.
- `autoMode.environment` is populated per project — repo visibility, trust
  boundary, org CLIs — so the classifier's single hard-deny rule (data
  exfiltration) has real boundaries to work with. Rule sets are run through
  `claude auto-mode critique` before shipping.

### 8.1 Shutdown order

A standing, project-wide order raised by **Stop All** (§10), not a per-worker
action. While one is outstanding: `spawn_worker` refuses (§6) before caps are
even checked, and a pending spawn or integration approval cannot be approved.
Raising and cancelling each queue a `decision` report so the orchestrator is
told rather than left to read the refusals as transient (§9.1). Raising the
order alone touches nothing else — no worker is stopped or signalled; the
board keeps working normally.

**Delivery** is a separate step: every worker still active is enrolled, then
handed the same wind-down text — commit what's in the worktree, call
`acknowledge_shutdown(note)`, then stop; do not call `report_complete`. A busy
worker gets it by having its next `PreToolUse` denied with the text, claimed
once per session so its following calls pass and it can actually commit; an
idle worker, which may never make another tool call, gets the same text as a
`--resume` prompt instead (§12). The integration guard (workers never push,
above) is checked first, so a push still gets denied and does not consume the
delivery claim.

Acknowledging carries `caps.shutdownGraceSeconds` (default 120s), but the
clock **starts at `delivered_at`, never `ordered_at`** — a worker that is
enrolled but has not yet been reached (still mid-turn, no `PreToolUse` fired
yet) has not failed to answer; it was never asked, so it is not counted as
unresponsive. Only a worker that was actually handed the order and then stayed
silent past the grace period counts as overdue. An overdue worker is
**reported, not killed** — stopping it, like any worker, is the human's call
from the progress sheet (§10).

### 8.2 Cross-project authority boundary

D4 binds every token grant to one project and one scope. On the orchestrator
surface that means every tool either never takes another project's id
(`list_tasks`, `create_task`, `list_agents`, and the rest of what reads or
writes only `identity.projectId`) or refuses one it is handed — `get_task`,
`spawn_worker`, `set_epic`, `request_integration`, the note tools, and every
other by-id tool answer a foreign id with a refusal naming it, never with the
foreign project's data or an empty result standing in for "not yours."
`CrossProjectBoundaryTests` classifies the whole orchestrator tool surface into
exactly these two sets and fails the moment a new tool ships unclassified or a
classified one moves sides, so the boundary is a property the test suite holds,
not a convention someone has to remember to preserve.

`list_projects` and `send_message` (§6, §9.2) are the one hole this epic opens,
and it is send-only. What a grant may do across the boundary: learn that
another project exists, by id and name only, and queue text into its report
queue. What stays denied, with no tool anywhere reaching it: reading another
project's tasks, epics, notes, approvals, sessions, or reports; spawning,
stopping, or otherwise acting on anything running there; mutating its board in
any way. `send_message`'s own refusals — no addressing yourself, unknown
project, blank or oversized body — narrow when the hole may be used without
widening what using it is allowed to do. `delete_message` (§9.3) reaches only a
message the caller's project received; the sender's panel loses the row
because the two projects share it, not because the tool reaches the sender.

The Coordinator is the one grant D4 does not bind to a project: scope
`coordinator` with `project_id` NULL, a pairing the `token_grant` CHECK holds
both ways. It is not a project row, so it is absent from `list_projects`, the
project list and every project-scoped query. Its authority is read everywhere, write
nowhere: board state in any project — tasks with their latest report and
comments, epics with their pull request, notes, agent sessions with spend, and
pending approvals (§6, Coordinator scope) — and no project's report queue or
messages, which are that orchestrator's inbox. Every tool that writes a board
refuses it; a §9.4 request queues a report rather than writing a board. What
it writes is its own plans: `note` rows with `project_id` NULL, which `note_fts`
indexes like any note. Every note query matches `project_id IS ?`, so a
project's list, search or by-id read never reaches a plan, and a plan query
never reaches a project's note. `CrossProjectBoundaryTests` classifies every
tool on every scope as a Coordinator read, the Coordinator's own queue and
ledger, a plan write, an inbox refusal, a write refusal, or not offered, and
fails on a tool it has not classified.

**The Coordinator's session.** It runs in the same console machinery as an
orchestrator (§9 — `OrchestratorConsole`, with a `CoordinatorSource` in place of
the project's), under these rules:

- **Folder.** cwd is `~/.agentboard/coordinator` (`<AGENTBOARD_SUPPORT_DIR>/coordinator`
  under the override), created on first start and seeded with a `CLAUDE.md`
  saying what the Coordinator is and is not. The file is written only when
  missing, so one the human has edited is never overwritten. Its memory is
  Claude Code's own for that folder.
- **File reach.** The launch adds `--add-dir ~`, so the home directory is
  writable, and `--disallowedTools` carries one `Edit(//<path>/**)` rule per
  registered project's repo path and worktree root (both spellings when a path
  resolves through a symlink). The list is rebuilt from the project list on
  every launch, so a project registered since takes effect at the next session
  start. Reads stay allowed. Claude Code applies an `Edit` deny to Write,
  MultiEdit and NotebookEdit, to the file commands it recognizes in Bash
  (`sed`, `tee`) and to redirection targets (`> file`). **What still gets
  through:** any Bash command that writes by other means — `git commit` or
  `git checkout` run in a repo, `mv`, `cp`, `rm`, an interpreter (`python -c`,
  `node -e`), a build tool, or a script. Claude Code's sandbox could close that
  gap but also isolates the network, which an ordinary session doing one-off
  jobs should not lose, so it is not enabled. The gap is accepted rather than
  closed: the seeded `CLAUDE.md` and the session's system prompt both instruct
  the Coordinator to never use those commands inside a registered repo or its
  worktree either, and to send that project's orchestrator a request instead.
- **Sessions.** One active session, pinned in `coordinator.active_session_id`
  and resumed by the next launch, including after the app restarts, the way a project pins
  `orch_session_id`. **New session** clears the pin and restarts the console, so
  the running session ends and a fresh one starts; the old row stays. The
  history offers the 10 most recent sessions other than the active one; resuming
  one pins it and restarts the console with `--resume`. Both switches revoke every
  live `coordinator` grant first, so the session switched away from can no longer
  call Coordinator tools; the next launch is issued its own. A `/clear` fork moves the
  pin to the fork (§7).
- **Model.** `coordinator.model`, NULL for Claude Code's default; set in the
  Coordinator settings sheet (§10), and read by the next launch.
- **Hooks and spend.** Its `agent_session` row has role `coordinator` and
  `project_id` NULL (read as `""`, like its `TokenIdentity`), so the hook sink
  binds its grant, adopts its forks and records its transcript like an
  orchestrator's, and every project-scoped query still misses it. The metering
  tick reads its spend after the projects', with no cap. Its `Stop` and
  compaction hooks reach its own console only from the session pinned in
  `active_session_id`; a stale session's are ignored. At launch, while no
  Coordinator console is running, every active `coordinator` row is marked
  stopped, as `reconcile` does for an orchestrator row with no console.

### 8.3 Sleep prevention

A Mac that sleeps with workers running kills them, and the idle cap counts the
sleeping minutes as silence — so twenty minutes of suspend reaps everything
that was running. While at least one `agent_session` row is in an active state
(§4), the app holds one `kIOPMAssertPreventUserIdleSystemSleep` assertion named
`Agent Board — an agent is running`, and releases it when the count reaches
zero, when the setting goes off, or when the app quits. The name is what
`pmset -g assertions` prints: the only place a human can see who is holding
their Mac awake.

The decision reads the observed session rows and nothing else — never a
spawn-side counter — so a worker that dies without reporting stops holding the
Mac awake the moment `reconcile` or the leaked-agent sweep (§8.6) flips its row
inactive. It is re-evaluated on the metering tick and immediately after `stop`,
`pauseAll` and `reconcile`.

**What it does not cover.** Idle system sleep only. Display sleep has its own
assertion type and is deliberately never asserted — a screen lit all night is
not what keeps a worker alive. A lid close is a different cause: measured on
this project's development Mac from `pmset -g log`, 2026-09-13 15:59:18, on AC
power with the display on and two live `PreventUserIdleSystemSleep` assertions,
closing the lid entered dark wake as `Clamshell Sleep` and slept five seconds
later. Only external power plus an external display keeps a closed laptop
running. The Status footer (§10) says so in its help text rather than implying
full coverage.

The setting lives in `UserDefaults` under `sleep.preventWhileRunning`, defaults
on, and is toggled from the Status footer, which also shows whether an
assertion is held right now.

### 8.4 Shared-checkout file locks

A `worktree` worker owns its whole tree and needs no lock. A `shared` or `auto`
worker (D6 amended, §1) stands in the project's own checkout alongside other
agents' co-resident work, so a second control exists for exactly that
placement, enforced the same way as everything else in this section: denying
`PreToolUse` (§7) before the tool runs, which is the only layer measured to
stop an unattended `--permission-mode auto` worker (§12). The same
`PreToolUse` handler checks `IntegrationGuard` (workers never push, above)
first, then the git-command guard below, then shutdown-order delivery, and
only then a file-lock claim — so a push is always denied ahead of a lock wait,
and a worker mid-wind-down is handed the order before it ever starts one.

**The lock.** `FileLockPolicy.lockedTools` is `Write`, `Edit`, `MultiEdit`,
`NotebookEdit` — deliberately not `Bash`, whose target is not knowable from
its command text the way `IntegrationGuard`'s push/PR scan already accepts.
The matcher that routes these tools through the lock check is written only
into a shared session's `--settings`, so a `worktree` worker's calls never
reach it at all. A session's first write to a repo-relative path claims
`file_lock` for it — one row per `(project, path)` — and holds it until the
session ends; every later write to that path by any other session waits.

**The wait.** Waiting is polling, not signalling: the holder may be a detached
`claude --bg` process in another app run, so there is no in-process release to
wake on. `FileLockPolicy.pollInterval` (0.5s) re-claims until
`FileLockPolicy.waitTimeout` (90s) runs out — comfortably under
`caps.stallSeconds` (120, §8) so a wait can never itself be read as a wedge,
and small enough that a holder settled in for half an hour does not silently
consume a contender's whole session. The waiting session moves to
`agent_session.state = waiting_on_lock` (§4) for the duration — active and
exempt from the idle and stall clocks, the same shape `setup` and `blocked`
already have, because a session doing exactly what it was told to do is not
silence. `agent_session.blocked_on_path` (§4) names what it is waiting on. A
wait that expires is refused with `FileLockPolicy.waitReason`, which tells the
worker to call `report_blocked` naming the path rather than retry the write
itself, returning the task to `ready`; a wait that succeeds resumes the tool
call as if it had never paused, and the waited seconds do not carry into the
next idle window.

**The rest of the checkout is guarded too, by a second, narrower control.**
`SharedCheckoutGuard` denies the git subcommands that reach past a session's
own locked files into the shared tree regardless of any lock — `git commit`
(a bare or `-a` commit would sweep a sibling's staged-but-uncommitted edit into
this task's commit), `stash`, `checkout`, `reset`, `clean`, `rm`,
`sparse-checkout`, `switch`, `merge`, `rebase`, `pull`, `cherry-pick`,
`revert`, `am`, and `bisect` — because each one either takes the whole working
tree or moves the branch every co-resident agent is committing to, and the
per-file lock does not cover a shell command's target. `git restore` is
allowed only as `git restore -- <path>`, one plain command naming paths the
session's own writes have locked; any wider form (no pathspec, a glob, another
session's file) is denied the same way. Reading the tree — `git status`,
`git diff`, `git log`, `git show` — is unrestricted. In place of `git commit`,
a shared worker commits by calling the `commit_my_work(message)` MCP tool
(§5.1): it commits exactly the paths this session's own locks name, taken from
`file_lock` rather than from the agent's memory of what it touched, and
records the commit's task in `task_commit` (§4) — the ledger that makes a
task's work on a shared branch reviewable on its own, and that acceptance
reads to decide whether every member is in (§5).

### 8.5 Session end reaps the process tree

**No process a worker session started outlives the session.** This holds for
every way Agent Board ends one: the caps, `stop_worker` and a human's Stop,
Pause All, discard, a vanished or failed session found by `reconcile`, a task
settled under a live session, an acknowledged shutdown, `report_complete`, and
the leaked-agent sweep. `claude stop` alone does not give it. Each Bash tool
command runs in a `zsh -c` that leads its own session and process group
(measured: sid = pgid = the shell's pid, while the host is in a session of its
own). A `run_in_background` command survives `claude stop` reparented to
launchd, with its children under it. A foreground command does not survive.
An idle-capped worker's `swift test` did survive and was found four hours
later, holding `.build/.lock` and more than fifty listening ports.

`SessionProcessReaper` picks the processes to signal from two rules:

1. **The host's tree.** The `claude` host's descendants are read from the
   process table before `claude stop`, while it still parents them.
2. **Orphans in the worktree.** These catch the paths where the host is
   already dead. A process qualifies when it is reparented to launchd, has no
   controlling terminal, has its cwd inside the session's own worktree, and
   started after the session did.

The rules also take in every current descendant of each process they
select. Everything selected gets SIGTERM, and whatever remains after 2s gets
SIGKILL. Each round re-reads the table and matches a pid only together with
its start time, so a reused pid is never signalled.

Nothing outside the session's own tree is signalled:

- Every process is matched to the session by one of those two rules. None is
  matched by name.
- The worktree rule is off for a shared checkout, which is the human's own
  repository. It is also off while another live session shares the worktree,
  as a rostered reviewer does.
- The following are never signalled: the app and its ancestors, every other
  live `claude` host listed by `claude agents` together with its ancestors
  and descendants, and any process whose executable is `claude` (the
  daemon).
- A human's terminal keeps its controlling tty. An app launched by launchd
  runs in `/`.

**A session the board ended stays stopped.** `claude stop` does not keep a
session down. Claude Code resumes a stopped `--bg` session by itself to deliver
a background command's task-notification, and killing those commands is exactly
what the reap does. This was measured on 2026-10-07 with integrator d44b3f51:

- 10:43:15: the idle cap stopped it (`SessionEnd`, reason `other`). Its two
  `run_in_background` commands were reaped and reported `exited with code 144`.
- 10:43:43: a `SessionStart` arrived with `source: resume`, followed by a
  `UserPromptSubmit` carrying their `<task-notification>`.
- It then worked for another 32 minutes under a `failed` row.

The row's `state` cannot say whether the board ended a session. The
`SessionEnd` that `claude stop` fires races `Board.terminate` and often writes
`stopped` first, so an idle-capped row can end `stopped` rather than `failed`,
the same state a session that merely exited leaves. So the board marks the
session itself: `Board.terminate` revokes the worker's token grants in the same
transaction, on every route through it (the caps, a human's Stop, Pause All, a
vanished or failed session, a settled task, an acknowledged shutdown). A
revived session then gets a 401 on every MCP tool call. Its hooks are still
heard on the revoked token (§7). A `SessionStart` on one does not revive the
row: the supervisor stops the process again (`endedSessionRestarted`) and logs
the stop on the task. A `SessionStart` on a worker row that is `failed` or
`completed` is handled the same way, since only the board writes those states.
That covers `report_complete`, which keeps its grant so that a resend still gets
its answer (§5.1).

Two restarts are exempt. A board resume issues a fresh grant before it starts
the process, so its `SessionStart` never arrives on the revoked one. A session a
human opened Attach on after it ended is left running too, since
`claude attach` also resumes a stopped session; its tool calls get the same 401.
Attach requests are held in memory, so one made before an app restart no longer
exempts the session after it. A `stopped` row with a live grant ended without
the board ending it, and keeps §7's rule.

Another process's environment is not readable on this macOS:
`KERN_PROCARGS2` returns argv but no environment for any pid but the caller's.
So the `CLAUDE_CODE_SESSION_ID` that Claude exports to every Bash command
cannot be used to find them.

### 8.6 The leaked-agent sweep

Every launch stops the `claude --bg` agent of each `agent_session` row that is
inactive but still holds a short id. The sweep decides from the rows alone
(`LeakedAgentSweep.plan`); the `claude agents` listing is read afterwards and
may only subtract a target, never add one, so a `claude` session the board has
no row for is never touched. A row whose registry entry carries no pid is kept:
there is no process to free.

**A row is examined until its agent is confirmed stopped.** Every successful
`claude stop` on a session — the sweep, `report_complete`, a human's Stop, the
caps — writes `agent_session.agent_stopped_at`, and the sweep plans only rows
where it is NULL. A trigger clears it the moment the row shows life again: its
state becomes active, or `last_activity` moves past the stop. The second rule
is for a session resumed on a settled task, whose `SessionStart` deliberately
does not revive the row (§7) but whose tool calls still bump `last_activity`.
Each life of a row therefore costs at most one successful `claude stop`, however
long the table grows, and the case of an unlistable runtime — where every
unmarked row is attempted — is paid once, not on every launch.

This is not an age horizon. A row that ended a year ago and was never
confirmed stopped is planned exactly like one that ended a minute ago, which is
the leak the sweep exists for. Nothing is marked on weaker evidence than a
`claude stop` that succeeded: a registry entry with no pid is not enough,
because the registry failing to report a resident session's pid is the one
failure that would otherwise hide a real leak forever. A marked row whose short
id the listing does show with a process is counted in the report rather than
stopped, because acting on it would let the listing add a target.

**Preview Leaked-Agent Sweep…** in the app menu runs the same sweep as a dry
run and shows its report in a window (§10). The dry run stops nothing and marks
nothing; `WorkerSupervising` exposes only the dry run, so no surface can reach
the real one.
