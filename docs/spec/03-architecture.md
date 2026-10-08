## 3. Architecture

```
┌─ Agent Board.app (Swift / SwiftUI) ───────────────────────────┐
│                                                                │
│  UI: Orchestrator · Terminal · Task Board · Status · Notes     │
│  Terminals: SwiftTerm (orchestrator, project shell, attach,    │
│    worktree shell)                                             │
│  Store: SQLite via GRDB                                        │
│                                                                │
│  Localhost HTTP server (Hummingbird), 127.0.0.1 only           │
│    /mcp    — MCP over HTTP, bearer-token scoped                │
│    /hooks  — hook callbacks from managed sessions              │
│                                                                │
│  AgentRuntime (protocol)                                       │
│    └─ BackgroundSessionRuntime → claude --bg / attach / stop   │
└────────────────────────────────────────────────────────────────┘
        │ spawn                          ▲ hooks + MCP
        ▼                                │
┌─ Orchestrator (1 per project) ─┐  ┌─ Workers (N, capped) ──────┐
│ foreground PTY, owned by app   │  │ claude --bg                │
│ pinned --session-id            │  │ pinned --session-id        │
│ cwd = repo root                │  │ cwd = per-task worktree    │
│ scope: orchestrator            │  │ scope: worker              │
│ permission mode: user default  │  │ permission mode: auto      │
└────────────────────────────────┘  └────────────────────────────┘
```

The server binds `127.0.0.1` on an ephemeral port chosen at launch. The port and
each session's token are written into that session's generated `--mcp-config`
and `--settings` files, so nothing is discoverable by a process that wasn't
spawned by Agent Board.

A session spawned from an archetype (§4) is not a third kind of process: it is
one of the same `Workers (N, capped)` boxes, spawned through the same
`AgentRuntime`, just carrying a `RosterAgent` identity that names it in the
opening prompt and narrows its tools (§3.1). A rostered reviewer under `agent`
review (§5) is the same worker box again, holding a `reviewer`-scoped token
instead of `worker`, spawned into the same task's worktree rather than a new
one. Neither gets a dedicated column in the diagram above; `role` in
`agent_session` is still only `orchestrator` or `worker` for both.

### 3.1 Spawn procedure

For a task `T` in project `P`:

1. Ensure the epic branch exists (`agentboard/epic-<epic-id>`, cut from `P`'s
   base branch) if `T` belongs to an epic.
   A branch cut **from the base** — a standalone task's new branch, or a new
   epic branch — first runs `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>`,
   because work integrates by pull request and local `<base>` falls behind
   until a human pulls. When local `<base>` is an ancestor of
   `origin/<base>` (behind or equal) the branch is cut from the remote's
   commit; when local has commits the remote lacks (ahead or diverged) it is
   cut from local `<base>`, which holds the human's unpushed work. Local
   `<base>` itself is never moved: it is usually checked out in the human's
   own checkout. The fetch never fails a spawn. A project with no `origin`
   (the remote `BranchPublisher` pushes to, §6.1) skips it; a fetch that
   fails or outlives `WorktreeManager.baseFetchTimeout` falls back to local
   `<base>` and returns a spawn warning naming the problem. It runs off the
   main thread under `ChildEnvironment.sanitized()` with
   `GIT_TERMINAL_PROMPT=0`, like every other git call. Whatever start point
   is chosen is what `refs/agentboard/base/<task-id>` records, and a
   standalone task's diff, and its reviewer's (§5.1), reads against that
   record while local `<base>` is still behind it, so commits the remote had
   are not shown as the task's.
   **A task inside an epic always branches from the local epic branch as it
   stands**: no fetch, no comparison with any remote. An existing epic branch
   is local integration state its tasks must see each other's merged work on,
   and it is never fetched into, moved or rebased. Reusing an existing task
   branch or worktree, and adopting a shared checkout (step 2), fetch nothing
   either.
2. Decide where `T`'s worker runs: `WorkerPlacementDecision.decide(strategy:
   project.settings.worktreeStrategy, wantedSharedBranch:
   SharedCheckoutGroup.branch(epicId:), group: SharedCheckoutGroup.current(...))`.
   `wantedSharedBranch` is `agentboard/shared`, or `agentboard/shared-epic-<id>`
   inside an epic — a shared branch is cut once per base, so a task based on a
   different epic (or no epic) never joins one already running. The group
   itself is nothing persisted: it is read back from `agent_session` rows with
   `role = worker` and no `worktree_path`, carrying a shared branch (§4), so a
   detached `claude --bg` worker that outlives the app is still found on the
   next launch.
   - **`worktree`** always places, and always worktrees: `git worktree add
     <worktrees>/<task-id> -b agentboard/<task-id> <base>` where `<base>` is
     the epic branch, or for a standalone task the start point step 1 chose
     from the project base branch. This
     is every project's behavior from before this setting existed. Git exits
     with the `post-checkout` hook's status and leaves the new worktree on
     disk when it fails, while a spawn adopts any worktree already at its
     path; so a failed `git worktree add` removes the worktree it created
     (keeping the branch), and the retry runs the hook afresh instead of
     starting a worker in a checkout whose setup never finished.
   - **`shared`** places in the project's own checkout — `P`'s repository root,
     not a path under `<worktrees>` — checking the wanted branch out there
     (`git checkout <branch>`, or `git checkout -b <branch> <base>` the first
     time) instead of adding a worktree. No `git worktree add` runs, so the
     post-checkout hook this setting exists to stop paying per spawn never
     fires for a shared task; a repository whose hook installs packages and
     builds pays that cost once for the whole co-resident group, not once per
     task. A group already at `sharedCheckoutMaxAgents` (§4), or built on a
     branch this task is not based on, is not joined — the task worktrees
     instead, exactly as `worktree` would place it.
   - **`auto`** worktrees unless a compatible group already holds the checkout
     with room; it never starts a group itself, only joins one `shared` or an
     earlier `auto` task already started.
   - Whichever is chosen, a git failure adopting the shared branch — the
     checkout is dirty, the branch is held by another worktree — degrades to
     `worktree` rather than failing the spawn, and queues a notice naming why.
3. Symlink `~/.claude/projects/<worktree-slug>/memory` → the canonical project
   memory dir. **Skipping this makes every worker amnesiac.** For a shared
   placement the "worktree" is the project's own checkout, so every co-resident
   worker resolves to the same slug and re-links the same already-correct
   symlink; the step is idempotent and costs nothing extra.
4. Generate `settings-<session>.json`: `http` hook definitions pointing at
   `/hooks?token=…` (a `command` + `curl` hook for `SessionStart`, see §2), plus
   the project's `autoMode` block. On resume, rewrite this file and the MCP
   config in place with the current port; `--bg --resume` reuses the paths.
5. Generate `mcp-<session>.json`: one HTTP server entry for `/mcp` with
   `Authorization: Bearer <token>`, where the token carries scope `worker` and
   is bound to `(session, task)`.
6. Compose the opening prompt: task title, body, acceptance criteria, epic goal,
   task- and epic-attached notes in full, a one-line index of every other note in
   the project naming its `note://` resource uri, the project's build and test
   commands when `settings_json` records them, and the completion protocol
   (commit, record one durable finding as a note, do not push, call
   `report_complete`). Injection alone left D13 half-built: notes flowed in and
   nothing flowed back, so the prompt also points at `search_notes` in *How to
   work* and asks for a note before `report_complete` in *When you are done*,
   with the bar stated and `append_section` preferred over a second note on a
   subject that already has one.
   Each attached note sits between marker lines carrying one random id per
   note, so a closing marker forged inside a note body does not end the fence.
   The task's comment thread follows the epic goal under *Comments*, oldest
   first, fenced the same way, each opening marker naming the author and the
   time. A comment from the human is labelled as the human speaking; an
   agent's is labelled as information written by an agent, not instructions.
   The thread keeps the newest comments within 4,000 characters, since Claude
   Code cuts any one hook's injected text at 10,000 and the post-compaction
   brief rides a hook; it cuts an oversize newest comment short rather than
   drop it, and says how many older ones it left out and
   that `get_my_task` has them all. The post-compaction brief and the
   reviewer's prompt (§5.1) carry the same section. In the brief the task text
   leaves the thread at least 2,000 characters, or its whole size if smaller,
   and the thread shrinks to whatever room the task text left, so a long task
   never drops the newest comment.
   The prompt ends with *How your turns end*: the early stops an unattended
   worker must not make, and the three stops it should.
7. `claude "<prompt>" --bg -n <task-slug> --permission-mode auto
   --strict-mcp-config --mcp-config <file> --settings <file>
   [--model <task.model ?? settings.defaultModel>]
   --disallowedTools "Bash(git push*)" "Bash(gh pr create*)" "Bash(gh pr merge*)"`
   with cwd set to the worktree. The prompt goes first because
   `--disallowedTools` is variadic and would swallow a trailing positional.
8. Parse the short id from stdout, look up the session uuid in
   `claude agents --json`, and resolve the setup row into it, carrying the
   worktree path, branch and attempt across — nil for the worktree path under a
   shared placement, since there is no per-task worktree to record. The token
   grant is bound to the session at this point, not before spawn.

`assign_to_agent` (§6) runs this same procedure with a `RosterAgent` resolved
up front against `RosterStore.usableAgent` (refused if the agent is not
enabled and selected for this project) and threaded through three of the
steps above rather than a fourth path of its own: step 6's prompt gains an
identity section before the task body (`OpeningPrompt.renderIdentity` — name,
role, and the agent's own system prompt, "this identity is yours across every
task you are given"); step 6's `--model` becomes `task.model ?? agent.model ??
project default`, most specific override wins; and step 7's
`--disallowedTools` gains the agent's own `disallowed_tools` patterns appended
after the fixed push/PR block, and a disk archetype's `tools` list becomes
`--tools` (§4). Neither can widen anything: `--tools` narrows built-in tools
only, and every deny above still applies to a tool it names. `assign_to_agent` under `reviewer` scope (used
only to start a rostered reviewer, §5.1) skips the `running` transition step 8
would otherwise make — the task stays in `review` — and lands the reviewer in
the *worker's own* worktree rather than cutting one, since it is keyed on the
same task id. It records the checkout's baseline in `agent_session.review_head`, opens
with `ReviewPrompt.compose` in place of the worker prompt, and step 7 adds
`SpawnRequest.reviewerDisallowedTools` (file edits and every git command that
changes a branch or the index, plus `rm` and `mv`) and
`SpawnRequest.reviewerBoardDeny` (reads of the board database and the support
directory, §5.1) after the push/PR block. It refuses a branch with no diff
against its base before any of that runs (§5.1).

Steps 1-2 are synchronous; `spawn_worker` answers between step 2 and step 3,
with a row in `agent_session` under a placeholder id and state `setup`, and the
task already in `running`. Steps 3-8 finish in the background, because on a
large repository they outlast the MCP call — a timeout an orchestrator cannot
tell from a failure turns every dispatch into a guess. A session in `setup`
holds a concurrency slot but does no work, is exempt from the idle cap (the
clock is measuring setup, not the agent), and is skipped by `reconcile`, whose
join against `claude agents --json` cannot see a placeholder id. A failure in
steps 3-8 has nowhere to be thrown: it terminates the session, puts the task
back in `ready` flagged failed, and queues a `failed` report, which is also what
happens to a setup still running when Agent Board quits.

**Removing a worktree.** Every path that removes a task or epic worktree goes
through `WorktreeManager.remove`: accepting a task, discarding one, the
orphan reaper `reconcile` runs, and **Remove worktrees** on a done or
abandoned epic's lane (§5.2). Archiving removes nothing, and closing an epic
removes nothing, so neither runs anything. Before git deletes the directory,
`remove` runs the project's **teardown hook** (`worktreeTeardownCommand`, §4)
when one is set: `/bin/zsh -c <command>` with the worktree as its working
directory and `PWD`, under `ChildEnvironment.sanitized()`, off the main
thread, as the leader of its own process group (`BoundedCommand`). It exists
because a tool that builds for a worktree outside it leaves that build behind
when only the directory goes: on Derivita, Bazel's output base under
`/private/var/tmp/_bazel_<user>/<md5 of the workspace path>`, 2–12 GB per
worktree. Agent Board knows nothing about Bazel; Derivita sets
`[ "$(bazel info workspace)" = "$PWD" ] && bazel clean --expunge`, whose guard
stops `--expunge` wiping the main checkout's output base if it ever ran there.
With no hook set, removal is exactly what it was. Claude Code's own
`WorktreeRemove` hooks from `~/.claude/settings.json` still run after it.

A hook never decides whether the worktree goes. One that exits non-zero, or
cannot start, is recorded and removal continues; one that outlives
`worktreeTeardownTimeoutSeconds` (default 600, clamped to 1 second through 24
hours) has its whole process group sent `SIGTERM`, then `SIGKILL` five seconds
later, and removal continues. The deadline is measured on `CLOCK_UPTIME_RAW`,
so a sleeping Mac does not use it up. Ten minutes covers `bazel clean
--expunge` deleting a 12 GB output base with room to spare, and still ends a
hook that waits forever, as Bazel does on an output base another command
holds. A hook that leaves files in a worktree that was clean before it ran is
forced past (`git worktree remove --force`), so its leftovers cannot be what
keeps the worktree; a worktree that was dirty before is never forced. The
failure, with the end of the hook's output, goes on the task's progress and
into the decision report for the removal (§5).

The hook does not run where `remove` does not: on a worktree kept for
uncommitted changes (§5), and on the rollback of a failed `git worktree add`
(step 2), which removes with `git worktree remove --force` directly. That
worktree's setup never finished, so the hook has nothing reliable to read —
`bazel info workspace` in a half-checked-out tree can start a server and
create the very output base it is meant to remove — and the retry adopts the
branch, not anything the hook would clean.

The hook lives in Project settings, not in a file in the repository. A repo
file is read from whichever branch is checked out, so any branch — including
one a worker wrote — could choose a command the board runs with the human's
privileges on removal, and run it in a checkout the human never reviewed. The
setting is entered by the human in the app and is the only source.

`--strict-mcp-config` is deliberate: without it a worker sees `repo-tasks`,
`solo`, and the other globally configured servers, and has two contradictory
task systems in its tool list. A per-project allowlist of extra servers to
merge back in (`mdn`, `caniuse`) is a project setting.

### 3.2 Listening ports

A worker is a detached `claude --bg` session that outlives the app, and its
children outlive it in turn — a dev server one of them started has no owning
window, no Dock icon, nothing but a socket. `ListeningPortSweep`
(`AgentBoardRuntime`) exists to make that socket visible: every TCP port in
`LISTEN` on the machine, whether opened by a worker session, an orchestrator
session, or the human typing into a project's shell console. Not "agents" —
the shell console counts because a human running `npm run dev` there is
exactly who needs the row.

**Enumeration** is `libproc` (`proc_listpids` + `PROC_PIDLISTFDS` +
`PROC_PIDFDSOCKETINFO`, reached through `import Darwin` with no bridging
header), chosen over shelling out to `lsof -i -P -n` by measurement: on this
machine's 1,059 processes both returned the identical 36 rows, libproc in
10.0 ms best / 11.5 ms mean against lsof's 152.0 ms / 161.2 ms — neither run
as root, so this is proven complete for the current user's processes, not for
the machine. One `proc_listpids` call builds the whole pid→ppid map that both
the socket walk and the attribution walk below reuse, so a sweep is linear in
processes rather than in sockets, and a socket is never dropped because its
own `proc_pidinfo` lookup failed — it is reported unattributed instead.

**One port is one row.** A descriptor that is not close-on-exec stays open in
every process below the one that bound it, and SwiftTerm's `forkpty` closes
nothing before `execve`. The board marks its own listener close-on-exec, which
keeps it out of the orchestrator and shell consoles; before that it was seen
under `AgentBoard`, three `claude` hosts and a shell console — six rows for one
port — and a dev server a worker starts has no such guarantee. The sweep groups holders by port and gives the row to the holder
that started first, which is the binder, since nothing can inherit a
descriptor before the process holding it exists; a pid whose start time could
not be read sorts last, and the lower pid breaks a tie. The binder's
attribution names the row, never an inheritor's. Every holder's chain is still
recorded in the ledger below, so a child that outlives the binder stays
nameable.

**Attribution** walks the listening pid's parent chain looking for a pid the
caller recognizes: a worker or orchestrator host's pid from
`ClaudeCLI.listAgents()` (`agent_session` itself stores no pid), or the
project shell console's `shellPid`. The registry is machine-wide — it lists
every interactive session the human is sitting in and every other board's
workers — so `ListeningPortModel` hands the sweep only the hosts whose session
id `agent_session` records. This is reliable exactly as far as the
chain is intact, and no further: macOS has no subreaper, so a reparented
grandchild's `ppid` becomes 1, and the session that spawned it is not
recoverable from the process table at all, for that socket, permanently. A
socket whose chain reaches pid 1 or a process the board never launched is
reported with its pid and command and a nil owner. The sweep reports it; the
panel does not draw it (§10), because a nil owner is no evidence the board
started the process — every system daemon on the machine looks exactly like
that.

To still name the orphan's *previous* owner, the sweep persists what it
learned while the chain was still whole: `sweepResult` returns every pid
walked through to reach an attributed session (not just the listener, so a
shell that outlives the session under it still carries the id), and
`PIDSessionLedger` — a JSON file in Application Support, not a table, because
a pid is machine-local and invalid after a reboot, unlike the migrated state
in `agentboard.sqlite` — records them keyed on `(pid, process start time)`
read from the same `proc_bsdinfo` struct the sweep already reads for `ppid`,
so a reused pid does not match a stale entry. A sweep tries the live chain
first and the ledger only when the chain answers nothing, because the chain
is self-evidently true and the ledger is a claim about the past. **This is
attribution's stated limit, not an edge case**: an orphan is only ever named
if some earlier sweep observed its chain intact before it broke. A dev server
that starts and is orphaned entirely between two hourly sweeps is recorded
nowhere, so it has no owner and draws no row, and no better chain walk
recovers it after the fact.

`BoardServer`'s own port is dropped inside the sweep itself, before any
attribution runs, not by a caller — it is the port every worker's MCP
connection and every hook round trip goes through, deliberately held stable
across relaunches (§3.1's per-session config rewrite on resume depends on
it), and a row for it would be a row with a stop button that kills every
agent on the machine. `PortStop` (§10) refuses it a second time regardless,
for a caller that reaches the stopper directly.

**Refresh** is hourly, on demand (the panel's button, the panel opening, and
after a stop, §10), and deliberately *not* on the 5-second metering tick
(§7): the tick is real work already running on the wall clock, and a
sweep is a full pass over every process on the machine for information that
moves on the order of minutes, not seconds. The hourly wait is
`Task.sleep(for:)`, measured on `ContinuousClock`, which keeps running
through a system suspend — a lid closed for three hours wakes straight into a
sweep rather than one hours stale. Unlike `AwakeClock` (§8.3), which discounts
sleep from a worker's idle budget, this clock deliberately counts it: sleeping
minutes are exactly when processes exit and sockets close, so counting
through sleep is what keeps the list current rather than what would make it
stale. One `ListeningPortModel` sweeps for both
surfaces — the sidebar panel's full list and a project's Status pane, filtered
from the same array — so mounting both costs one sweep, not two disagreeing
timers.
