# Agent Board — Specification

A native macOS app that manages work for Claude Code agents: an orchestrator you
talk to, a board of tasks it decomposes work into, a roster of running agents,
and a shared notes surface those agents read and write.

Status: pre-implementation. Derived from `IDEA.md` by decision interview.

---

## 1. Decisions

Each decision below was made explicitly. The rationale is one line; the
alternative named is the one worth reconsidering if the decision goes wrong.

| # | Decision | Rationale | Rejected |
|---|---|---|---|
| D1 | Standalone app; owns its own state | Solo's MCP surface is a tool API for agents, not a query API for a UI | Front-end over Solo |
| D2 | PTY for interaction, hooks + transcript for state | Terminal gives full Claude Code fidelity; hooks make Status honest | Headless `-p` only |
| D3 | Agent Board owns tasks in its own store | Self-contained; no coupling to `repo-tasks` file format | `repo-tasks` as backing store |
| D4 | Tiered authority enforced at the token | Prompts are not a permission system | Flat authority |
| D5 | Budgeted autonomy with caps | Recorded session ids + `--resume` make cap-kills non-destructive | Manual gate on every spawn |
| D6 | Worktree per task, branch bound to task id | A retry sees what the previous attempt built | Worktree per agent session |
| D7 | Fixed columns: Proposed → Backlog → Ready → Running → Review → Done | The orchestrator must be told which column is assignable | User-defined columns |
| D8 | Workers commit and stop. They never push. The orchestrator may push and open a pull request, but only through named tools that each wait on a human approval | Nothing reaches a shared remote unattended; the last step of an epic stops being manual without handing an agent a shell it can aim anywhere | Worker opens a draft PR; unblocking `gh` in Bash for the orchestrator |
| D9 | Reports queue in SQLite; app injects a fixed notice; orchestrator pulls | Worker text never enters the orchestrator's user-authority turn | Inject report text into PTY |
| D10 | Epics group tasks and own the integration branch | Merge scope becomes a lookup, not a judgment call | Flat tasks |
| D11 | One orchestrator per project | cwd determines which CLAUDE.md, skills, and MCP servers load | One global orchestrator |
| D12 | Notes are Agent Board's own store, Solo-scratchpad-shaped | Notes are a working surface, not Claude Code memory | View over `~/.claude/.../memory/` |
| D13 | Task/epic-attached notes injected in full at spawn; every other note indexed by title and `note://` uri, fetched on demand | Stops three workers rediscovering the same constraint without charging every worker for every pinned note | Inject pinned notes in full too |
| D14 | Workers run `--permission-mode auto` | The shipped classifier already encodes 70 soft-deny rules | Hand-rolled PreToolUse denylist |
| D15 | Blocked agents are answered by attaching to their real terminal | Auto mode's prompt text is written to be read; don't reproduce it | Native approval dialog |
| D16 | Workers are `claude --bg` background sessions | Deletes process supervision, crash recovery, and scrollback from scope | App owns the PTYs |
| D17 | Swift + SwiftUI | Literal reading of "native Mac app" | Tauri |
| D18 | Runtime spike → board → orchestrator → epics → notes | The riskiest assumption is provable in 200 lines | Build everything |
| D19 | The Terminal screen and worktree shells (§10) run with the human's own authority: `IntegrationGuard` and `--disallowedTools` deliberately do not gate them, and no Agent Board grant token may reach the shell's environment | A human typing `git push` is entitled to push — those mechanisms bound what an unattended agent may do under `--permission-mode auto`, and there is no agent here; a shell holding a grant token would let anything running in it act with that session's authority over the board | Route the shell through a worker-scoped grant |
| D20 | A cross-project roster of specialized agents (§4), assigned a task with `assign_to_agent` and returned to the queue with `hand_off` (§6) | A rostered identity outlives any single task, and mediating handoff through the board queue keeps D6's worktree-per-task model instead of building a second coordination path | Hive's model: every agent works on `main`, and a privileged orchestrator arbitrates conflicts between them |

**D6 amended.** As first written, D6 said every task gets its own worktree and
its own branch bound to the task id. That now holds only under
`worktreeStrategy: worktree` (§4) — the default, so no existing project changes
on upgrade. Under `shared`, a task instead runs in the project's own checkout,
co-resident with up to `sharedCheckoutMaxAgents` others, all committing to one
branch named for their shared base rather than to `agentboard/<task-id>`
(§3.1). A task under `shared` no longer owns a branch; it owns an attributed
range of commits on a branch it shares, recorded in `task_commit` (§4) rather
than in the branch name, and acceptance waits for every task on that branch
before any of it is merged into the epic (§5). `auto` picks between the two per
spawn — share only when a compatible group already holds the checkout with
room, worktree otherwise (§3.1) — and starts no group of its own.

Two costs are the deliberate price of `shared`, not a gap in it. Per-task
revert is gone: rejecting a task after a sibling on the same branch has already
been accepted means unpicking commits, and Agent Board does not do that — the
branch waits for every member to be accepted before any of it merges (§5),
which is the epic's answer, not a fix for it. And a shared-checkout agent is
editing the human's own working copy: its writes land in whatever editor
already has that checkout open, and the branch under it moves as siblings
commit, not only as the human's own tools move it.

What the amendment leaves untouched: a worker still commits and stops — through
`commit_my_work` rather than `git commit` under `shared` (§8), but a commit
either way — and still never pushes, still refused by `IntegrationGuard` at the
`PreToolUse` layer, regardless of placement. D8 governs that refusal and is
unchanged by this amendment.

**D8 amended.** As first written, D8 said the pull request was opened by the
human and by nobody else, and §5.2 step 5 said the same. The orchestrator half
of that is now relaxed: the orchestrator may call `push_branch` and
`open_pull_request` (§6), each of which creates an approval row and stops there.
Nothing reaches the remote until a human grants it, autonomy setting regardless,
so "nothing reaches a shared remote unattended" is unchanged — what changed is
who may ask. The refusal the amendment is careful *not* to relax: unblocking
`gh` in Bash for orchestrator sessions would have been one line, and would have
granted every GitHub operation the user's token can reach, on every repository,
with no record on the board. The tools are narrow on purpose — `push_branch`
refuses any branch that is not `agentboard/<something>` or the project's base
branch, and there is no tool that merges a pull request.

**The worker half of D8 is untouched.** Workers commit on their branch and stop.
They never push, never open a pull request, and the two controls in §8 that
enforce it are unchanged for them.

Pivots named at decision time, to be designed for but not built:

- **D16 → owned PTYs.** All process interaction goes through an `AgentRuntime`
  protocol. `BackgroundSessionRuntime` ships; `OwnedPtyRuntime` is the pivot.
- **D17 → Tauri.** This is a rewrite, not a swap. The only hedge worth building
  is keeping two artifacts language-neutral: the SQLite schema (§4) and the
  localhost HTTP/MCP contract (§6, §7). A Tauri build inherits both.

---

## 2. Platform facts this spec depends on

Verified against Claude Code **2.1.269** on macOS. Items marked *M0* were
proven by the runtime spike in `spike/` on 2026-09-11.

- `claude --bg` backgrounds a session and prints a short id. `claude agents`,
  `attach`, `logs`, `stop`, `rm`, `respawn` manage them. The supervisor is a
  per-cwd daemon with a control socket at `/tmp/cc-daemon-<uid>/<hash>/control.sock`.
- `claude agents --json --all` returns `{id, cwd, kind, startedAt, sessionId,
  name, status|state}` per session — interactive and background.
- *M0:* `--bg` with `--settings`, `--mcp-config`, `--strict-mcp-config`,
  `--permission-mode auto`, `--disallowedTools` and `-n` together starts a
  healthy session that honors the injected hooks and MCP config. Stdout is
  `backgrounded · <short-id> · <name>`; the short id is the first 8 hex chars of
  the session uuid, and `claude agents --json` lists the full uuid immediately.
- *M0:* **`--bg` ignores `--session-id`** (`warning: --bg manages the session
  id`). The id is therefore recorded after spawn, not assigned before it.
  `claude --bg --resume <uuid>` wakes a stopped session under the same id and
  **reuses its saved options** (`-n`, `--permission-mode`, `--strict-mcp-config`,
  `--mcp-config`, `--settings`, `--disallowedTools`, `--model`) by path. The
  per-session config files must stay at their original paths and be rewritten
  with the current server port before a resume, or the woken worker talks to a
  dead port.
- *M0:* Hooks of `type: "http"` fire from a background session for
  `PostToolUse`, `Notification`, `Stop` and `SessionEnd`. **`SessionStart`
  silently skips `http` hooks** (foreground and background); a `command` hook
  that pipes stdin to `curl` fires and is the workaround.
- **`/clear` forks the session under a new id.** The old id gets `SessionEnd`,
  and ~18s later a new id gets `SessionStart` with `"source": "fork"`. The fork
  payload does not name its parent — no parent session id anywhere in it — so
  the hook token grant is the only link back. `StoreHookSink` treats an unknown
  payload `session_id` on a live grant bound to a known session as the fork
  signal: it inserts a row for the new id, rebinds the grant, and re-pins
  `project.orch_session_id` for an orchestrator grant. The old row keeps its
  terminal state and its spend — the fork writes its own transcript, and
  metering reads transcripts.
- *M0:* The MCP client sends a non-standard `server/discover` request before
  `initialize`; answering it with JSON-RPC `-32601` is fine. `tools/list` is
  fetched at startup and the tool is callable in the first turn.
- *M0:* `claude attach <id>` renders the full TUI inside a SwiftTerm
  `LocalProcessTerminalView` (truecolor, layout, status line). Closing the
  window sends SIGTERM to the attach client (exit 143); the background session
  is still listed afterwards. SwiftTerm logs unhandled DECSET 2031 (theme
  change queries), harmless.
- MCP supports `--transport http` with per-server `--header`, so one server can
  identify callers by bearer token.
- Permission mode `auto` runs a classifier: 17 allow rules, 70 soft-deny
  (ask-the-user), 1 hard-deny (data exfiltration across the trust boundary),
  and a 21-rule environment block. Configurable under the `autoMode` settings
  key. `claude auto-mode critique` reviews a custom rule set.
- Session transcripts are JSONL under `~/.claude/projects/<slug>/`, carrying
  per-message `usage` with `input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`, `service_tier`.
- **`/compact` does not fork the session id.** Measured 2026-09-12 by driving a
  real `claude` PTY with hooks pointed at a scratch `hook_event` table. Manual
  `/compact` emits, all under the *same* `session_id` and the same
  `transcript_path`, and with no `SessionEnd`:
  `PreCompact {"trigger":"manual"}` → `SessionStart {"source":"compact"}`.
  Re-measured 2026-09-15 on 2.1.272 with the same result. `/clear` forks and
  `/compact` does not, so there is no fork to adopt: the `agent_session` row,
  its bound grant and `project.orch_session_id` all survive untouched, and
  Agent Board's whole reaction to that `SessionStart` is to tell the console
  (`CompactedSessionTests` pins each of those three).
- **Claude Code auto-compacts on its own, mid-turn.** Measured with
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=3` to pull the threshold down to a reachable
  value: `UserPromptSubmit` → `PreCompact {"trigger":"auto"}` → (later)
  `SessionStart {"source":"compact"}` → `Stop`, same session id throughout. The
  turn *continues by itself* after an auto-compaction. A manual `/compact` at
  rest does not: it ends with a `Notification {"notification_type":
  "idle_prompt","message":"Claude is waiting for your input"}` and the session
  sits there, exactly like a resume (§9). An app-driven compaction therefore
  has to send the next turn itself.
- **Auto-compact fires very late.** From the 2.1.269 binary: the trigger is
  `contextWindow - 20000 - 13000` tokens, i.e. 13k of headroom below the
  effective window; `blocked` is 3k below that. `--debug` on a Fable 5.1
  session logs `autocompact: tokens=… level=ok effectiveWindow=980000` at each
  turn start, so the window is 1M and the auto trigger is 967k. `/autocompact`,
  the `autoCompactWindow` setting, `--autocompact <auto|tokens>` and
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` move it; `DISABLE_COMPACT` turns it off.
  Agent Board compacting at a chosen fraction fires *before* this and at a
  moment it picks, rather than mid-dispatch.
- **`effectiveWindow` is 980,000 for every model measured.** Measured
  2026-09-15 on 2.1.272 by running one turn per model under `--debug` and
  grepping the debug file (`~/.claude/debug/<session>.txt`, *not* the PTY) for
  `autocompact: tokens=… level=ok effectiveWindow=`:

  | Model | `effectiveWindow` |
  |---|---|
  | `claude-fable-5-1` | 980000 |
  | `claude-opus-5` | 980000 |
  | `claude-opus-5-5` | 980000 (measured 2026-09-22 on 2.1.280, `claude -p --debug`) |
  | `claude-sonnet-5` | 980000 |
  | `claude-haiku-4-5` | not measured — the run died on `Error: Refresh token is invalid or has already been claimed by another client` before any turn completed |

  `ModelCatalog.effectiveContextWindow(for:)` carries the four measured values
  and reads anything else, Haiku included, as the same 980,000 rather than
  guessing a smaller one.
- **A slash command injected into a PTY needs its Enter as a separate write.**
  Measured 2026-09-15, three runs in the same harness. Writing
  `"/compact <instructions>\r"` as **one** burst leaves the carriage return in
  the prompt as a literal `^M`: no compaction fires, and the following
  injection is appended to it — the `PreCompact` payload that eventually
  arrived carried
  `custom_instructions: "…write this down'.^MReply with only the word mango."`.
  Writing the text and then `"\r"` as **two** writes fires it cleanly, with
  `custom_instructions` exactly the instruction text and the next turn its own
  `UserPromptSubmit`. It is the leading slash, not the length: a 470-character
  plain message with a trailing `\r` in one burst submitted normally, while a
  short `"/compact keep decisions\r"` in one burst produced no `PreCompact` at
  all — only `Notification {"notification_type":"idle_prompt"}`. Claude Code's
  slash-command autocomplete consumes the Enter. The existing report notice
  (§9.1) has no leading slash and is unaffected, but `OrchestratorConsole`
  splits every injection the same way so nothing depends on remembering this.
- **Context pressure = `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens` of the last assistant message.** Calibrated
  against the TUI's own `N% until auto-compact` readout on a session started
  with `--autocompact 100k` (threshold 67,000 = 100k − 20k − 13k). Before
  compaction the readout said 10% (implying 59,995–60,664 tokens) and the last
  assistant message carried `in=2 cr=60,173 cc=69` → 60,244. After compaction
  it said 19% (implying 53,935–54,605) and the message carried
  `in=2 cr=32,593 cc=21,624` → 54,219. Dropping `cache_creation_input_tokens`
  gives 32,595 there — 40% low, and outside the band. `TranscriptMeter` already
  parses all three fields.
- **A session started as a child of another Claude session writes no
  transcript.** `CLAUDE_CODE_CHILD_SESSION=1` in the environment turns
  persistence off (the TUI says so in its banner) and no
  `~/.claude/projects/<slug>/<id>.jsonl` ever appears, while
  `transcript_path` in the hook payload still points at the file that is never
  written. `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` overrides it. Agent Board
  is not a Claude child so this does not bite in production, but any harness
  that spawns `claude` from inside `claude` must scrub the marker or it will
  measure nothing.
- **No programmatic read of account-wide remaining subscription quota exists.**
  Every budget in this spec is a self-imposed ceiling over what Agent Board
  itself spawned, not a real-quota ceiling.
- `~/.claude/projects/<worktree-slug>/memory/` is created empty for each new
  worktree. The existing convention on this machine symlinks it to the canonical
  project memory dir (confirmed across ~20 Derivita checkouts).
- **A worker survives its board endpoint going away, and recovers with no
  handshake.** Measured 2026-09-16 against 2.1.273 by `spike/outage-probe/`.
  With the port refused an MCP tool call returns `is_error` in ~3s carrying
  `Unable to connect. Is the computer able to access the url?`; with the socket
  accepted but never answered it hangs ~62s and returns `The operation timed
  out.`. The session stays `busy`/`working` through either, the model records
  the error and moves to its next step without retrying the call or abandoning
  the task, and the first call after the endpoint returns succeeds. The client
  handshakes once and reuses the `Mcp-Session-Id` it was given before the outage
  for the life of the session; `BoardServer` writes that header and never reads
  it, so no board restart invalidates a live worker, and adding validation would
  break every worker alive across one.
- **An unreachable hook endpoint fails open exactly like a slow one**, and every
  hook posted during an outage is lost with none replayed. A hook held open is
  abandoned at its declared `timeout` and the tool then runs, so a blackholed
  endpoint costs 5s per `PreToolUse` and 5s per `PostToolUse` — and
  `FileLockPolicy.hookTimeoutSeconds` (120) twice per write in a shared
  checkout, with the lock not actually held. A refused endpoint costs nothing
  measurable.
- **AppKit refuses `NSApplication.terminate` while any window has an attached
  sheet, and says nothing about it.** Measured 2026-09-17 against the shipped
  binary by `QuitProbe` (`AGENTBOARD_QUIT_PROBE`, the same shape as the
  `AGENTBOARD_E2E_REPO` hook). No delegate is consulted — this app implements no
  `applicationShouldTerminate` — no `NSApplication.willTerminateNotification` is
  posted, nothing is logged, and the call returns as if it had worked. It is the
  attached sheet specifically: a second ordinary window does not block, and the
  same app quits once the sheet has ended. A SwiftUI sheet cannot be cleared
  with `endSheet` behind its binding's back — it re-attaches while
  `isPresented` is still true, and the refusal stands; only dismissing it
  through the binding clears the way. So any control that quits the app from
  inside a sheet must dismiss first and wait for the detachment.

---

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

A rostered agent (§4) is not a third kind of process: it is one of the same
`Workers (N, capped)` boxes, spawned through the same `AgentRuntime`, just
carrying a `RosterAgent` identity that names it in the opening prompt and
narrows its `--disallowedTools` (§3.1). A rostered reviewer under `agent`
review (§5) is the same worker box again, holding a `reviewer`-scoped token
instead of `worker`, spawned into the same task's worktree rather than a new
one. Neither gets a dedicated column in the diagram above; `role` in
`agent_session` is still only `orchestrator` or `worker` for both.

### 3.1 Spawn procedure

For a task `T` in project `P`:

1. Ensure the epic branch exists (`agentboard/epic-<epic-id>`, cut from `P`'s
   base branch) if `T` belongs to an epic.
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
     the epic branch, or the project base branch for a standalone task. This
     is every project's behavior from before this setting existed.
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
after the fixed push/PR block. `assign_to_agent` under `reviewer` scope (used
only to start a rostered reviewer, §5.1) skips the `running` transition step 8
would otherwise make — the task stays in `review` — and lands the reviewer in
the *worker's own* worktree rather than cutting one, since it is keyed on the
same task id.

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

`--strict-mcp-config` is deliberate: without it a worker sees `repo-tasks`,
`solo`, and the other globally configured servers, and has two contradictory
task systems in its tool list. A per-project allowlist of extra servers to
merge back in (`mdn`, `caniuse`) is a project setting.

---

## 4. Data model

SQLite, GRDB. Language-neutral by intent (see §1 pivots).

```sql
CREATE TABLE workspace (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  ordering   REAL NOT NULL,    -- sidebar order
  created_at INTEGER NOT NULL
);

CREATE TABLE project (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  repo_path       TEXT NOT NULL UNIQUE,
  base_branch     TEXT NOT NULL DEFAULT 'main',
  worktree_root   TEXT NOT NULL,
  memory_dir      TEXT,            -- canonical ~/.claude/projects/<slug>/memory
  orch_session_id TEXT,            -- pinned uuid, resumed lazily
  settings_json   TEXT NOT NULL,   -- caps, autoMode block, mcp allowlist, defaultModel, modelGuidance,
                                   -- reviewLevel, buildCommand, testCommand, archivePolicy,
                                   -- worktreeStrategy, sharedCheckoutMaxAgents, rosterAgentIds
  created_at      INTEGER NOT NULL,
  workspace_id    TEXT REFERENCES workspace(id)  -- null = ungrouped; optional organization only
);

CREATE TABLE epic (
  id             TEXT PRIMARY KEY,
  project_id     TEXT NOT NULL REFERENCES project(id),
  title          TEXT NOT NULL,
  goal           TEXT,
  branch         TEXT NOT NULL,    -- agentboard/epic-<id>
  state          TEXT NOT NULL,    -- planning | active | integrating | done | abandoned
  created_at     INTEGER NOT NULL,
  review_level   TEXT              -- none|agent|task|epic for this epic's tasks; NULL inherits the project's
);

CREATE TABLE task (
  id             TEXT PRIMARY KEY,
  project_id     TEXT NOT NULL REFERENCES project(id),
  epic_id        TEXT REFERENCES epic(id),
  title          TEXT NOT NULL,
  body           TEXT,
  acceptance     TEXT,
  priority       TEXT,
  column_name    TEXT NOT NULL,    -- proposed|backlog|ready|running|review|done
  blocked        INTEGER NOT NULL DEFAULT 0,
  blocked_reason TEXT,
  failed         INTEGER NOT NULL DEFAULT 0,
  failure_reason TEXT,
  ordering       REAL NOT NULL,
  origin         TEXT NOT NULL,    -- human | orchestrator | worker_proposal | integration
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  model          TEXT,             -- overrides project settings.defaultModel for this task's worker
  reviewer_agent_id TEXT REFERENCES roster_agent(id),  -- the rostered reviewer holding it in `review`
  roster_agent_id TEXT REFERENCES roster_agent(id),    -- the rostered agent that last worked it
  archived_at    INTEGER,          -- non-null = archived: hidden from the board, never deleted
  done_at        INTEGER,          -- entered done; cleared on leaving. The afterDays clock
  unarchived_at  INTEGER           -- a human pulled it back; no automatic policy touches it again
);
CREATE INDEX task_project_archived ON task(project_id, archived_at);
CREATE INDEX task_project_done_at ON task(project_id, done_at);

CREATE TABLE task_dep (
  task_id     TEXT NOT NULL REFERENCES task(id),
  depends_on  TEXT NOT NULL REFERENCES task(id),
  PRIMARY KEY (task_id, depends_on)
);

CREATE TABLE agent_session (
  session_id     TEXT PRIMARY KEY,   -- the pinned uuid
  short_id       TEXT,               -- claude --bg short id
  project_id     TEXT NOT NULL REFERENCES project(id),
  task_id        TEXT REFERENCES task(id),
  role           TEXT NOT NULL,      -- orchestrator | worker
  worktree_path  TEXT,
  branch         TEXT,
  cwd            TEXT NOT NULL,
  state          TEXT NOT NULL,      -- setup|starting|running|idle|blocked|waiting_on_lock|stopped|
                                     -- failed|completed
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  last_activity  INTEGER,
  transcript_path TEXT,
  tokens_in      INTEGER NOT NULL DEFAULT 0,
  tokens_out     INTEGER NOT NULL DEFAULT 0,
  cache_read     INTEGER NOT NULL DEFAULT 0,
  cache_write    INTEGER NOT NULL DEFAULT 0,
  est_cost_usd   REAL NOT NULL DEFAULT 0,
  attempt        INTEGER NOT NULL DEFAULT 1,
  model          TEXT,
  last_tool      TEXT,
  stop_reason    TEXT,
  tool_started_at INTEGER,           -- oldest tool call not yet seen to return
  tools_in_flight INTEGER NOT NULL DEFAULT 0,
  blocked_on_path TEXT,               -- §8.4: the shared-checkout file lock this session is waiting on
  roster_agent_id TEXT REFERENCES roster_agent(id)  -- §10: the rostered identity this session runs as
);

CREATE TABLE token_grant (
  token       TEXT PRIMARY KEY,      -- random, per session
  session_id  TEXT REFERENCES agent_session(session_id),  -- NULL until `claude --bg` returns the id
  project_id  TEXT NOT NULL REFERENCES project(id),
  scope       TEXT NOT NULL,         -- orchestrator | worker
  task_id     TEXT,                  -- worker: the only task it may mutate
  created_at  INTEGER NOT NULL,
  revoked_at  INTEGER
);

-- §8.4: one file in a project's own checkout, claimed by the session editing it. Only a
-- shared-checkout session takes these — a worktree worker cannot collide with anyone.
CREATE TABLE file_lock (
  project_id TEXT NOT NULL REFERENCES project(id),
  path       TEXT NOT NULL,    -- repo-relative, so two absolute spellings of one file are one lock
  session_id TEXT NOT NULL,
  task_id    TEXT,
  held_since INTEGER NOT NULL,
  PRIMARY KEY (project_id, path)
);
CREATE INDEX file_lock_session ON file_lock(session_id);

-- Which task made which commit on a shared branch (§5, §8.4). Not a commit trailer: that would
-- publish the task's UUID into whatever repository the pull request lands in, permanently (as
-- §6.1 already avoids for branch names). The cost is that a cherry-picked or rebased commit is a
-- new object this table does not know, and attribution is no longer rebuildable from the
-- repository alone.
CREATE TABLE task_commit (
  task_id TEXT NOT NULL,
  sha     TEXT NOT NULL,
  PRIMARY KEY (task_id, sha)
);
CREATE INDEX task_commit_sha ON task_commit(sha);

CREATE TABLE progress (
  id          INTEGER PRIMARY KEY,
  task_id     TEXT NOT NULL REFERENCES task(id),
  session_id  TEXT REFERENCES agent_session(session_id),
  at          INTEGER NOT NULL,
  kind        TEXT NOT NULL,         -- note | status | error | tool
  text        TEXT NOT NULL
);

CREATE TABLE report (
  id          INTEGER PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES project(id),
  task_id     TEXT REFERENCES task(id),
  session_id  TEXT REFERENCES agent_session(session_id),
  kind        TEXT NOT NULL,         -- complete | failed | blocked | proposal | decision | message
  body        TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  consumed_at INTEGER               -- set when the orchestrator pulls it
);

-- Text one project's orchestrator sent to another (§9.2). The recipient never sees this row:
-- delivery writes a framed `message` report into its queue, which it pulls like any other.
CREATE TABLE message (
  id              INTEGER PRIMARY KEY,
  from_project_id TEXT NOT NULL REFERENCES project(id),
  to_project_id   TEXT NOT NULL REFERENCES project(id),
  from_session_id TEXT REFERENCES agent_session(session_id),
  body            TEXT NOT NULL,     -- the sender's text, unframed
  created_at      INTEGER NOT NULL,
  delivered_at    INTEGER,           -- set when the `message` report is written
  report_id       INTEGER REFERENCES report(id)
);
CREATE INDEX message_to_project_delivered ON message(to_project_id, delivered_at);

CREATE TABLE approval (
  id           TEXT PRIMARY KEY,
  project_id   TEXT NOT NULL REFERENCES project(id),
  kind         TEXT NOT NULL,            -- spawn | integration
  task_id      TEXT REFERENCES task(id),
  epic_id      TEXT REFERENCES epic(id),
  requested_by TEXT NOT NULL,            -- session_id of the requester, or 'human'
  reason       TEXT,
  created_at   INTEGER NOT NULL,
  resolved_at  INTEGER,
  resolution   TEXT                      -- approved | denied
);
CREATE INDEX approval_pending ON approval(project_id, resolved_at);

CREATE TABLE note (
  id          TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL REFERENCES project(id),
  title       TEXT NOT NULL,
  pinned      INTEGER NOT NULL DEFAULT 0,
  version     INTEGER NOT NULL DEFAULT 1,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE note_section (
  note_id     TEXT NOT NULL REFERENCES note(id),
  heading     TEXT NOT NULL,
  body        TEXT NOT NULL,
  ordering    REAL NOT NULL,
  written_by  TEXT,             -- session_id of the agent that last wrote it; NULL if a human wrote it in the app
  PRIMARY KEY (note_id, heading)
);

CREATE TABLE note_link (
  note_id  TEXT NOT NULL REFERENCES note(id),
  task_id  TEXT REFERENCES task(id),
  epic_id  TEXT REFERENCES epic(id)
);

CREATE VIRTUAL TABLE note_fts USING fts5(title, body, content='');

CREATE TABLE hook_event (
  id          INTEGER PRIMARY KEY,
  session_id  TEXT,
  event       TEXT NOT NULL,
  payload     TEXT NOT NULL,
  at          INTEGER NOT NULL
);

-- The roster is cross-project: no project_id. Projects opt in below.
CREATE TABLE roster_agent (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  role          TEXT NOT NULL,          -- free-text specialty: frontend | reviewer | ...
  system_prompt TEXT NOT NULL,          -- identity and specialty, injected at spawn
  model         TEXT,                   -- overrides project settings.defaultModel
  disallowed_tools TEXT NOT NULL DEFAULT '[]',  -- JSON array of extra --disallowedTools patterns;
                                                -- a deny-list, so empty = a full worker's authority
  enabled       INTEGER NOT NULL DEFAULT 1,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE project_roster_agent (
  project_id      TEXT NOT NULL REFERENCES project(id),
  roster_agent_id TEXT NOT NULL REFERENCES roster_agent(id),
  ordering        REAL NOT NULL,        -- the project's preference order for the orchestrator
  PRIMARY KEY (project_id, roster_agent_id)
);
CREATE INDEX project_roster_agent_order ON project_roster_agent(project_id, ordering);
```

Every `epic.state` value is written by exactly one place, and nothing writes one
that is not listed here:

| State | Written by | When |
|---|---|---|
| `planning` | `EpicStore.insert` | The epic is created; `create_epic` and the New Epic sheet both land here |
| `active` | `WorkerSupervisor.spawn`, `Board.accept` | The first task in the epic is spawned, or accepted, while the epic is still `planning` |
| `integrating` | `WorkerSupervisor.spawnIntegrator` | The integrator worker spawned successfully on the epic branch (§5.2 step 3) |
| `done` | `Board.complete`, `Board.closeEpic` | The integrator reported and the epic merged, **or** a human closed the epic by hand (§10) |
| `abandoned` | `Board.closeEpic` | A human abandoned the epic by hand (§10) |

`done` and `abandoned` are terminal: `Board.closeEpic` refuses an epic that is
already in either, so one never silently becomes the other, and `create_task`
and `set_epic` refuse a terminal epic as a destination. There is no reopen —
a closed epic stays closed, and work left inside one is freed with
`set_epic(task_id)` and no `epic_id` rather than by reviving the epic.

The token is issued before spawn (it has to be in the generated config files)
and bound to the session afterwards; the SessionStart hook may arrive first and
bind it itself. `est_cost_usd` is a list-price estimate from transcript usage,
never a billed amount.

Notes are sectioned rather than a single body specifically so three concurrent
workers appending to one note do not silently lose each other's writes. Whole-
document replace is not offered.

`roster_agent.disallowed_tools` is a **deny-list**, not an allow-list: its
patterns are appended to the worker default `--disallowedTools` at spawn, so a
rostered agent can only ever have *less* authority than a plain worker and can
never grant itself anything. That is why `NOT NULL DEFAULT '[]'` is the right
default — an empty list is exactly a full worker's authority, which is the status
quo for an unrostered one.

`roster_agent.role` is a plain string, not an enum: the roster is user-defined,
so adding a specialty must not need a migration. A project's *usable* set is
`project_roster_agent` joined to `roster_agent` where `enabled = 1` — disabling
an agent roster-wide takes it out of every project's rotation without removing
anyone's selection. Deleting a rostered agent clears its `project_roster_agent`
rows and nothing else: the tasks it worked, its sessions, and the `progress`
rows naming it all survive it.

There is no `is_reviewer` flag. `RosterAgent.isReviewer` reads
`role.lowercased().contains("review")` — a "reviewer", "Reviewer", or "code
reviewer" role all qualify, because the roster is user-defined text and a
second field would just be a second way to say the same thing. Under `agent`
review (§5), `ReviewPolicy.routing` takes the project's usable, enabled
reviewers and picks `reviewers.first` — the first in `project_roster_agent`'s
own `ordering`, not by task type, workload, or rotation. One project with two
reviewer-role agents always routes to whichever sorts first; there is no way
to route different tasks to different reviewers today.

`settings_json.reviewLevel` is one of `none`, `agent`, `task` or `epic` and
defaults to **`task`**, so a project that predates the setting behaves exactly as
it did. `epic.review_level` overrides it for that epic's tasks; NULL inherits.
Nothing else reads either value — the level is resolved once, on completion (§5).

`archived_at` is a flag on a task, not a seventh column — D7 fixes the six, and
`blocked`/`failed` are the precedent. Only a task in `done` may be archived;
unarchiving is always allowed. Archiving hides a task from the default board
query and does nothing else: no branch, worktree, session row, report or
progress row is removed or altered by it. `settings_json.archivePolicy` says
when a done task is archived automatically — `{"mode":"manual"}`,
`{"mode":"afterDays","days":N}`, or `{"mode":"afterEpicMerge"}`, the default for
a project with no archive key stored.

The three modes fire on two different things, so they have two entry points
(`ArchiveSweep`):

- **`manual`** archives nothing on its own; the Task Board button is the only
  trigger.
- **`afterDays(N)`** archives a task once `now - done_at` is *strictly greater*
  than N days — at exactly N it stays. It rides `WorkerSupervisor`'s existing
  metering tick, throttled to one sweep every 5 minutes rather than the 5-second
  metering cadence, and there is no second timer. `done_at` rather than
  `updated_at` measures time-in-done, because archiving, reordering, blocking and
  every other edit move `updated_at`.
- **`afterEpicMerge`** archives every `done` task of an epic inside the same
  `Board.complete` transaction that moves the epic to `done` (§5.2 step 4),
  including the synthetic `integration` task. Under this policy alone that task
  lands in `done` rather than `review`: the epic reaching `done` is its
  acceptance. A task of the epic parked outside `done` is skipped, not an error.

A done task with no epic has no merge event, so under `afterEpicMerge` it never
archives automatically; it stays on the board until archived by hand. There is
deliberately no age fallback — a policy that quietly behaves like a different
policy is worse than one that does nothing.

Automatic archiving never fights a human: `unarchive` stamps `unarchived_at`,
and while that is set no policy re-archives the task. Moving a task out of `done`
clears `done_at` and `unarchived_at` together, so a reopened task starts both the
clock and the policy from scratch. The picker for the three modes lives in
Project Settings, next to the day count it disables outside `afterDays`; the
Task Board's own archive controls are in §10.

`worktreeStrategy` (D6 amended, §1) is `worktree`, `shared`, or `auto`;
`sharedCheckoutMaxAgents` bounds how many workers may be co-resident in a
`shared` or `auto` checkout at once, defaulting to `caps.maxConcurrentWorkers`
(3) so shared mode adds no second, tighter ceiling to discover. Neither setting
gets its own table: the co-resident group they describe is nothing persisted,
only read back from `agent_session` rows with `role = worker` and no
`worktree_path`, sharing one `branch` — a detached worker that outlives the app
is still found in it on the next launch, with no separate row to fall out of
sync with the sessions it describes.

`file_lock` exists only for that group: a worktree worker cannot collide with
anyone, so it never takes one. A lock is claimed by a session's first write to
a path and held until the session ends; `agent_session.blocked_on_path` records
what a session is waiting on while it holds (§8.4). `task_commit` is the
companion ledger for a branch several tasks commit to — the only way, once
commits from different tasks interleave on one ref, to say afterwards which
task made which commit, since the branch name can no longer carry that the way
`agentboard/<task-id>` does.

---

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
| `agent` | waits in `review`, assigned to a rostered reviewer | that agent |
| `task` | waits in `review` | you (**the default**) |
| `epic` | inside an epic, goes straight to `done`; standalone, waits in `review` | you, at the epic's integration gate |

The level is resolved on completion: the task's epic's `review_level` if it has
one, otherwise the project's. Two rules override it unconditionally. An epic's
integration task (`origin = integration`) always waits for a person, at every
level — §5.2's gate is not weakened by this setting. And `agent` with no usable
rostered reviewer falls back to `task` and says so in a `progress` row, rather
than accepting work nobody reviewed.

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
  eligible when every row in `task_dep` points at a task in `done`.
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
- **Handed off** — a rostered agent that did only the portion matching its
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
  rostered reviewer does. Every attempt's worktree is removed (firing the
  existing `WorktreeRemove` hook, which reclaims Bazel `output_base` on
  Derivita), and `agentboard/<task-id>` is deleted once it is merged into the
  base or epic branch. An unmerged branch, or a worktree with uncommitted
  changes, is kept and the reason surfaced in the status bar.

  The accept then merges the task's branch into the branch meant to carry it:
  `agentboard/epic-<id>` for a task in an epic (§5.2), so the next sibling
  spawned into the epic branches from work that is already in, and the project's
  base branch for a task in none. The merge runs after the acceptance
  transaction and off the main actor: nothing it does can hold the task out of
  `done`. When the target branch is an ancestor of the task branch the ref is
  advanced directly; otherwise a temporary worktree on the target branch carries
  the merge and is removed afterwards, keeping the branch. A conflict aborts and
  leaves the target branch where it was. The merge commit's subject is
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
  be accepted, and none still `isLive` (a worker of theirs still standing in
  the checkout). Short of that, acceptance queues a `decision` report naming
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
  `unlanded`, and that merge marks every member `landed` at once.

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

  `pending` and `unlanded` show as a badge on the card and in the inspector, and
  queue a `decision` report naming the task, the branch, the target and the
  reason, so the orchestrator can dispatch a fix rather than discover the
  divergence at integration time. The board can therefore never say `done` while
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

A rostered reviewer under `agent` review gets its own token scope (§6), narrower
than a worker's: `get_my_task`, `log_progress`, `accept_task(verdict)` and
`reopen_task(findings)` over the one task its token names, and nothing else — no
spawn, no reassign, no other task. `accept_task` writes the verdict to `progress`
and then takes that same acceptance path; `reopen_task` puts the findings on the
task and returns it to `ready` without flagging a failure. The verdict on the
task is the point: a person reading a task that reached `done` without them can
see who approved it and why.

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
   throws leaves the epic `active` rather than stranded mid-integration. The
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
5. The PR from the epic branch → base is opened either **by you**, from
   the button on the epic, or by the orchestrator calling `open_pull_request`
   (§6) — which does not open one either. It creates an approval row, exactly
   as `request_integration` does, and the branch is pushed and the pull request
   opened only once you grant it, autonomy setting regardless (D8 amended, §1).
   The resulting URL is written to `progress` against the epic's integrator
   task, so the board records that the pull request exists without anyone
   reading a terminal, and reaches the orchestrator as a `decision` report.

   The pull request's head is the **published** name (§6.1), not the local
   `agentboard/epic-<id>`, on both routes — the button's compare page and the
   approved `open_pull_request` aim at the same ref.

   An epic whose tasks are not all `done` is **not** refused here, unlike
   `request_integration`. Opening a pull request early for review is a real
   workflow and the approval is already a human gate; the approval row names
   how many tasks are unfinished, so the mistake is visible to the person
   deciding rather than pre-empted for them.

---

## 6. MCP surface

Served at `http://127.0.0.1:<port>/mcp`. Scope comes from the bearer token, not
from the request. A worker calling an orchestrator tool gets a tool-not-found
error, because the tool list is rendered per scope. Resources and prompts are
not scoped this way — any valid token in the project sees the full resource
and prompt lists, worker and orchestrator alike. `initialize`'s advertised
`capabilities` includes `resources` and `prompts` only when a handler for it is
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
| `worker_protocol` | `branch` (required) | The standing *How to work* / *When you are done* sections a worker is spawned with (§3.1 step 6) |

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
| `get_my_task()` | The task bound to this token, plus its `epic_id` and dependency summaries |
| `update_status(state, detail)` | Appends to `progress`; sets `blocked`/`failed` flags |
| `log_progress(text)` | Appends to `progress` |
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
| `get_my_task()` | The task under review and its `progress` rows |
| `log_progress(text)` | Appends to `progress` |
| `accept_task(verdict)` | Writes the verdict to `progress`, then runs the ordinary acceptance (§5.1) |
| `reopen_task(findings)` | Writes the findings to `progress`; moves the task to `ready` without flagging failure |

Every call reads the task id off the token, never off the arguments, so a
reviewer cannot reach a task it was not given. It cannot spawn, reassign, stop a
session, query the board, propose, or report on its own behalf.

### Orchestrator scope

Everything in worker scope over any task in the project, plus:

| Tool | Effect |
|---|---|
| `list_tasks(column, epic_id, include_archived)` | Board query; archived tasks are hidden unless `include_archived` is true |
| `create_task(..., epic_id)`, `update_task(...)`, `move_task(id, column)` | Board mutation; moving an archived task out of `done` unarchives it. `create_task`'s `epic_id` is optional and creates the task inside that epic; an unknown id, one belonging to another project, or one whose epic is `done` is refused |
| `get_task(id)` | Full detail, archived or not; an archived task carries `archived: true` and `archived_at` |
| `archive_task(task_id)` | Hides a `done` task from the board; refused for any other column |
| `unarchive_task(task_id)` | Returns the task to the visible board in the column it was archived from |
| `set_deps(task_id, depends_on[])` | Dependency graph |
| `set_epic(task_id, epic_id)` | Moves an existing task into an epic, between epics, or — with `epic_id` omitted — out of its epic. Refused for a task that has ever been spawned, and for a `done` destination epic. Dependencies are left alone |
| `create_epic(title, goal, tasks[])` | One transaction: the epic (state `planning`) plus every task in `tasks`. Each task's `depends_on` is a zero-based index into this same array, validated before anything is written |
| `list_epics()` | Every epic on the project with its state, branch, and done/total task count |
| `get_epic(id)` | One epic in full: goal, branch, its tasks grouped by column, and whether it is ready for integration |
| `attach_note(note_id, task_id|epic_id)` | Passes context down at spawn time |
| `pin_note(note_id, pinned)` | Every future agent sees it in its note index and can fetch it |
| `spawn_worker(task_id)` | Subject to §8 caps, the shutdown order, and the autonomy setting |
| `list_roster_agents()` | The rostered agents this project has enabled, in its own preference order |
| `assign_to_agent(task_id, roster_agent_id)` | `spawn_worker` carrying a rostered identity: the same caps, shutdown and autonomy gates, worker scope, and the agent's own deny list layered on. An agent outside the project's usable set is refused |
| `stop_worker(session_id)` | `claude stop` |
| `list_agents(include_ended)` | Roster with state and spend; ended sessions drop off after a grace window |
| `list_reports()`, `get_report(id)` | The Q9 pull channel |
| `list_projects()` | Every project Agent Board knows about, as id, name, and whether the entry is the caller's own project. Nothing else about another project is exposed — no repository path, no settings, no board contents, no agent state |
| `send_message(project_id, body)` | Queues a §9.2 message into that project's report queue. Confirms queueing, never delivery. Refused for the caller's own project, for an unknown id, for a blank body, and for a body over 4000 characters |
| `promote_proposal(task_id)` | Only when autonomy is on |
| `request_integration(epic_id)` | Refused unless every task in the epic is `done` (names how many remain); otherwise creates a human approval row, or returns the one already pending |
| `close_epic(epic_id, state)` | Ends the epic without integrating it. `state` is `done` or `abandoned`; both are terminal. Board state and a `decision` report and nothing else — no merge, no push, no branch or worktree deleted, no task deleted, archived or moved out. Refused while any session in the epic is active, and refused for an epic that is already terminal |
| `push_branch(branch)` | Always creates a human approval row. Refused for any branch that is not `agentboard/<something>` or the project's base branch. The approval carries both the local branch and the name it takes on the remote (§6.1) |
| `open_pull_request(epic_id \| branch, title, body, base?)` | Always creates a human approval row. Same branch rule; `base` defaults to the project's base branch. On approval the branch is pushed if the remote lacks it, the pull request is opened from the **published** name (§6.1), and its URL lands in `progress` and in a `decision` report |

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

---

## 7. Hook contract

Generated into each managed session's `--settings`. All post to
`http://127.0.0.1:<port>/hooks?token=<session token>`.

| Event | Agent Board's reaction |
|---|---|
| `SessionStart` | Mark `agent_session.state = running`; record transcript path |
| `PreToolUse` (matcher `Bash`) | Deny `git push`, `gh pr create`, `gh pr merge`; append an `error` progress row (§8) |
| `PostToolUse` | Bump `last_activity`; clear `blocked`; append a `tool` progress row |
| `Notification` | Set `blocked` + reason on the task and session; the task appears in the orchestrator's **Blocked** section (§10) and raises the project's attention signal, which posts the banner |
| `Stop` | Mark session idle. **On the orchestrator, this is the trigger for the report notice** (§9) |
| `SessionEnd` | Mark stopped/completed; reconcile final spend from the transcript |
| `WorktreeRemove` | Chain to the user's existing hook, then clear the worktree row |

The handler must be synchronous and trivial — `PostToolUse` fires on every tool
call, and a slow handler is felt directly as agent latency. Anything expensive
goes on a queue. `PreToolUse` is matched to `Bash` alone so the round trip is
not paid on every tool call.

A `PreToolUse` reply denies by returning both shapes in one body — the current
`hookSpecificOutput.permissionDecision`/`permissionDecisionReason` pair and the
legacy `decision: "block"`/`reason` pair — so the block lands whichever the
installed CLI reads. Every other event replies `{}`.

Spend metering tails the session's JSONL transcript rather than relying on
hooks, since hooks do not carry `usage`.

The blocking `Notification` types are `permission_prompt`, `agent_needs_input`,
and anything prefixed `elicitation`. Each sets `task.blocked` with the
notification message as `blocked_reason`, moves the session to `blocked`, and
files a `blocked` report for the orchestrator. The banner comes from the
attention signal below rather than from the hook, so the badge and the banner
cannot disagree; a session with no task cannot raise that signal, and only that
case still posts its own "Agent needs input" banner. The next `PostToolUse`
clears `blocked` again, so a worker that was answered leaves the section without
anyone pressing anything.

**Attention banners.** A pending approval and a blocked worker each stop work
outright, so both notify. Both are read from `ProjectAttentionStore` — the same
per-project signal behind the sidebar badge — on the metering tick, and
`AttentionNotifier` posts each one only on the transition into that condition,
keyed by project and reason. A queue nobody has answered does not banner every
5s; a growing queue is a bigger badge, not a second banner. The key clears when
the condition clears, so the same condition occurring again notifies again, and
a relaunch re-announces whatever is still waiting. Stranded reports and an
unacknowledged shutdown badge without interrupting. Nothing notifies for the
project the human has open while Agent Board is frontmost. Every banner Agent
Board raises names its project.

**Stall detection.** Some prompts fire no hook at all — a grandchild process
reading stdin (`cp -i`, `ssh` asking for a passphrase) belongs to neither
Claude Code nor Agent Board, so nothing is posted and `last_activity` simply
stops advancing. The metering tick (already running every 5s, already reading
`last_activity`) flags a `running` worker whose activity clock has not moved
for `caps.stallSeconds` — default 120s, deliberately below the 300s idle cap so
it surfaces before the cap kills it. A worker inside a tool call that has
started and not returned is excused for 6 × `caps.stallSeconds` (720s at the
default), because `PostToolUse` fires only on return and one command can
legitimately run for minutes (§8); past that the command itself is what looks
wedged and the stall is raised. A stall is a suspicion, not a reported
state: nothing is written to the task, nothing is killed, one macOS
notification ("Worker may be stuck") is raised on the transition, and the
sidebar shows the row until activity resumes or the human acts.

---

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
  to `nil` before `CapEvaluator.evaluate` runs, so a rostered agent can neither
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
widening what using it is allowed to do.

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
Mac awake the moment `reconcile` or the leaked-agent sweep (§3) flips its row
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

---

## 9. Orchestrator

- One per project. Foreground PTY owned by the app (not `--bg`), pinned
  `--session-id`, cwd at the repo root, resumed when the human selects the
  project in the sidebar — Orchestrator is the project's first screen (§10),
  so opening a project is what starts its session. No project is selected at
  launch — the sidebar lands on At a Glance (§10), which is not a project — so
  launching the app wakes nothing: the cost is one orchestrator per project the
  human actually opens, not four on every launch.
- Permission mode: your normal interactive default. It's the session you are
  watching.
- Its job description is injected with `--append-system-prompt`: the board
  vocabulary (project, epic, task, column), the rule that only `ready` is
  assignable, the completion and integration protocols, the instruction to
  call `list_reports` when told to, and the project's `modelGuidance` text so
  it can set `model` on the tasks it creates. The orchestrator itself runs on
  `settings.defaultModel` when set.
- Resume sends a fixed app-authored first turn ("Agent Board resumed this
  session; continue from where you left off") because a resumed background
  session otherwise waits for input until the idle cap stops it.

### 9.1 Report channel

1. A worker calls `report_complete` / `report_blocked` / `propose_task`, **or the
   app itself changes the board in a way the orchestrator cannot observe** — see
   the table below — **or another project's orchestrator sends a message** (§9.2).
   The body lands in `report`, unconsumed. The notice counts items, not workers:
   a queue holding a `message` is not a queue of worker reports.
2. The orchestrator's `Stop` hook fires when it finishes a turn.
3. If unconsumed reports exist, Agent Board writes **one fixed, app-authored
   line** into the orchestrator PTY:
   `[agent-board] N reports pending. Call list_reports.` terminated by
   a carriage return (`\r`); Claude Code's TUI submits on Enter and treats
   `\n` as a literal newline inside the prompt.
4. The orchestrator pulls bodies through MCP, where they arrive as tool results.

**Injection is withheld while the human has unsubmitted text in the prompt.**
The notice is bytes in the same PTY the human types into: written mid-sentence
it appends to their half-written message and its `\r` submits the pair, sending
one garbled prompt and destroying what they wrote. Observed 2026-09-12.

So the console classifies every byte on its way to the child and tracks whether
the prompt is dirty — printable text and pasted text dirty it; `\r`, `\n`,
`Ctrl-C`, `Ctrl-U` and a lone `Esc` clear it; cursor keys, backspace and any
other escape sequence leave it as it was. Every trigger — the `Stop` hook, a
board change, and the human's manual Nudge — passes through one gate, and a
notice refused while the prompt is dirty is **held, not dropped**: an
orchestrator that is never told about pending reports holds a stale board and
stops dispatching. It goes out at the next submit or cancel, with the pending
count re-read at that moment because more reports may have queued while it
waited, and the high-water mark of announced report ids advances only when a
notice is actually written.

The classification is a heuristic over a TUI whose input model Agent Board does
not own, so it is biased to read as dirty: an unrecognized sequence delays a
notice, which is harmless, rather than overwriting a human's typing, which is
not.

Every board change the orchestrator did not itself make queues a report; an
orchestrator that is not told holds a stale board and cannot dispatch what just
became ready.

| App-side change | Report kind | Body carries |
|---|---|---|
| Human accepts a task into `done` | `decision` | Accepted task, and the ids that became `ready` |
| Human reopens a task | `decision` | Task, now back in `ready` |
| Human discards a task | `decision` | Deleted task id (the task row is gone) |
| Human promotes a proposal | `decision` | Proposal, and the ids that became `ready` |
| Human approves or denies an approval | `decision` | Approval, outcome, reason |
| Cap or idle kill | `failed` | Task, session, `failure_reason` |
| Human stops a worker, or Pause All | `failed` | Task, session, that a human stopped it |
| `reconcile` finds a session gone | `failed` | Task, session, that Agent Board did not stop it |

A task in `running` that no active session owns is always moved out of it,
whatever path the session death took, so it never needs a manual `move_task`.
Where it lands depends on what the worker left on `agentboard/<task-id>`:

- No commits the branch's recorded base does not have — back to `ready`, the
  report saying so, ready to be dispatched again.
- Commits ahead of that base — into `review`, with the commit count in the
  report. The report never calls that work finished: no worker vouched for it
  and Agent Board builds nothing. Routing it to `ready` instead would tell an
  orchestrator to re-dispatch work that is already written, and a retry reuses
  the same branch, so the second worker would redo it on top of itself.

Two clocks enforce this, because one of them only runs while a screen is open:
the metering tick sweeps every project, and `reconcile` sweeps the project it
was called for. The sweep re-checks the strand inside its write, so a task that
has since moved or gained a session is left alone. It exists because
`terminate` cannot reach a death that left no session row at all, and because
`SessionEnd` can write `stopped` before a cap kill or `reconcile` gets there.

A cap or idle kill also sets `failed` and `failure_reason` on the card; a human
stop does not. A wind-down acknowledgment keeps its own contract — `ready` with
a resume note — whatever is on the branch.

No agent-generated text is ever written into the orchestrator's user turn. The
orchestrator holds spawn, assign, and integration authority; a worker that echoes
a malicious file into its report must not be able to drive it.

### 9.2 Compaction

The orchestrator is a long-lived session whose context only grows. Claude Code
compacts it eventually — at `effectiveWindow - 33000`, about 96.6% — but it does
so mid-turn, at whatever moment it happens to reach, which for an orchestrator is
usually mid-dispatch. Agent Board compacts earlier and at a moment it chooses.

**Trigger.** The metering tick already reads every session's transcript every 5s
(§7). For the orchestrator it also computes
`ContextPressure(used: last assistant message's input + cache_read + cache_write,
limit: ModelCatalog.effectiveContextWindow(for: model))` and asks the gate to
compact once that passes `OrchestratorCompaction.threshold` — 0.80. No new timer,
and no per-project setting: the window is a property of the model, not of the
project, and nothing about a project changes where the safe margin is.

**Injection.** The compaction command goes through `ReportNoticeGate`, the same
gate as the report notice and for the same reason — it is bytes in the PTY the
human types into (§9.1). The gate holds at most one notice and at most one of
each app-authored line, so a held compaction and a held report notice both
survive; it writes **at most one line per pass**, compaction first, and whatever
is left waits out the turn that line started.

**Never mid-turn.** `Stop` clears the gate's in-flight flag; the human's Enter
and every line the gate writes set it. A compaction is refused while it is set
and delivered at the next `Stop`, so it can never land part-way through a
dispatch.

**Instructions.** `/compact` takes free-form instructions and the default
summariser keeps the wrong half for an orchestrator — the narrative of what
happened rather than the decisions that shaped it. Almost everything an
orchestrator appears to know is in SQLite and comes back from `list_tasks`,
`list_epics`, `list_agents`, `list_reports` and `get_task`; what is
unrecoverable is the conversation with the human. So
`OrchestratorCompaction.instructions` preserves eight things — standing
instructions, decisions with their reasons, unanswered questions, anything
suspending normal behaviour, facts established by measurement, corrections, git
state the board does not show, and failure modes — deletes every enumeration and
every tool result outright, and ends with a section headed "unrecorded — write
this down" whose job is to convert conversational knowledge into durable board
state before the next pass eats it.

**Re-orientation.** A manual compaction leaves the session idle waiting for
input, exactly like a resume (§2), so the gate follows it with one fixed
app-authored line pointing the session back at the board. An **auto**-compaction
resumes its own turn, so it gets nothing written into it: `PreCompact.trigger`
distinguishes the two, and the trigger of the most recent `PreCompact` row is
what `SessionStart {"source":"compact"}` is read against.

Both lines are fixed constants. No agent text enters the orchestrator's
user-authority turn here any more than in §9.1 (D9).

**Visibility.** The orchestrator header shows the current context percentage,
amber once it is over the threshold, and how long ago the last compaction was,
with its tooltip saying whether Agent Board or Claude Code did it and how many
there have been. A session that silently forgot what it was doing is worse than
one that says so.

### 9.3 Cross-project messages

An orchestrator may send text to another project's orchestrator. The sender is
itself an orchestrator, with real authority over its own project — but that
authority does not travel with the text. To the recipient, what arrived is
agent-authored text from outside its board, no different in standing from a
worker's report, and D9 forbids exactly that from entering an orchestrator's
user-authority turn. §9.1 keeps `OrchestratorConsole` the only writer into that
PTY, so nothing this epic built could put the message there without reopening
the hole D9 exists to close. Instead it is **delivered into the recipient's
`report` queue** as a `message` report and pulled through `list_reports`
exactly like a worker report, on the recipient's own schedule rather than
whenever the sender happened to call `send_message`.

The stored `message` row keeps the sender's text verbatim. The delivered report
body wraps it: the sending project's name and id, a statement that the text
carries no authority over this board and is information rather than an
instruction, and begin/end delimiters around the sender's own words. The report
names no task and no session — a message from outside cannot hand the reader
something in this project to act on.

A message to a project that does not exist is refused, as is an empty one.

An orchestrator addresses a peer with `list_projects`, which returns ids and
names and nothing else, and sends with `send_message(project_id, body)`. The
tool's own refusals are narrower than the store's: it will not address the
caller's own project — a message to yourself arrives in the queue you are
already reading — and it caps the body at 4000 characters, because the body is a
prompt fragment spent from the recipient's context budget rather than the
sender's. The tool confirms only that the message was queued: the receiving
orchestrator may not be running, nothing tells the sender when or whether it
pulls, and there is no reply channel. These two tools are the whole
cross-project surface; there is no way to read another project's messages, list
its tasks, or spawn into it.

---

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
4. **Proposals** — worker-proposed tasks awaiting promotion.

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
assigned agent, elapsed, spend, and its `blocked`/`failed` flag. Drag between
columns. Cards in `review` show the branch, worktree path, and a diffstat.

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
as dead rather than phantom-running. Per agent: task, state, elapsed, spend
against cap, last tool used. A blocked agent's row opens its terminal, which is
how permission prompts get answered (D15).

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

**Notes** — list and full-text search, sectioned editor, pin toggle, and the set
of tasks/epics each note is attached to. Shows which agent last wrote each
section. Each section header carries a copy button that puts that section on the
clipboard as `## heading` followed by the text on screen — unsaved edits
included, since that is what the human is looking at.

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
build time. `AppBundle.isAppBundle` (a bundle identifier and a `.app` path
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

---

## 11. Milestones

**M0 — runtime spike. Swift, no UI. PASSED 2026-09-11, see `spike/`.** A throwaway Swift package — Hummingbird
server, SwiftTerm, no SwiftUI — that spawns `claude --bg` with a generated
`--settings` (hooks → localhost) and `--mcp-config` (one tool, bearer token),
and proves three things:

1. Hooks fire from a background session and reach the server.
2. The HTTP MCP server's tools appear in the session's tool list.
3. `claude attach <id>` renders correctly inside a SwiftTerm PTY, and detaching
   does not kill the session.

If (1) fails, D16 flips to owned PTYs. If (3) fails, D17 comes back into
question before any SwiftUI is written. **Nothing else is built until this
passes.** Written in Swift specifically so (3) is a real test rather than a
deferred assumption.

**M1 — board. DONE 2026-09-11 (headless E2E: assign → report_complete → accept, 16/16 checks).** Project registration, SQLite store, Task Board, Status,
worktree creation with the `memory` symlink, manual assignment, spend metering,
caps. Useful without any orchestrator.

**M2 — orchestrator. DONE 2026-09-11 (report channel verified live: Stop → notice → `list_reports` → consumed).** Orchestrator PTY, per-scope MCP tokens, `spawn_worker`,
the report channel, approvals sidebar, autonomy toggle.

**M3 — epics and integration. DONE 2026-09-12 (418/418 tests pass; the
approve → spawn → merge → report → PR flow verified in `EpicIntegrationTests`
against a fixture runtime — real worktrees and git operations, a fake
`claude --bg` process): approving an integration request spawns exactly one
integrator on the epic branch with the standard worker guards
(`--permission-mode auto`, `--strict-mcp-config`, the push/PR
`--disallowedTools`); its prompt lists task branches in dependency order and
skips ones already merged into the epic branch; the epic moves `active` →
`integrating` on spawn and to `done` in the same transaction as its
`report_complete`; and nothing on the path pushes or opens a PR).** Epic
entity, epic branches cut lazily at first task spawn into them, task
branches from the epic branch, integration worktree and integrator, human-
opened PR.

**M4 — notes. DONE 2026-09-15 (70 tests across `NoteStoreTests`,
`OpeningPromptNoteTests`, `OpeningPromptNoteWritingTests`, `NoteResourceTests`,
`WorkerNoteToolTests`, `SpawnNoteIndexTests`).** Note store, section ops, FTS,
pinning, attachment, spawn-time injection.

Notes is last deliberately: it is the lowest-risk screen and it benefits most
from knowing how the agents actually behave first.

---

## 12. Open items

- **Verified by M0:** a healthy `claude --bg` session honors injected hooks and
  MCP config.
- **Verified by M3, with a known limitation:** the project `autoMode` block
  passed via `--settings` does reach the effective config of a spawned
  `--bg` worker, but a `soft_deny` rule in it does not stop or pause a
  matching tool call in that worker — it just runs.

  Method: registered a project whose `settings_json.autoModeJSON` was
  `{"soft_deny": ["AgentBoard Canary M3 [named+specifics]: any command whose
  text contains the exact token AGENTBOARD_CANARY_9f3d2c17 is always a
  soft-deny requiring approval, with no exceptions, regardless of any other
  rule in this policy."]}`, then ran the headless E2E path (§ below,
  `AGENTBOARD_E2E_REPO` against a throwaway fixture repo) with the task body
  changed to run `echo AGENTBOARD_CANARY_9f3d2c17` before the usual
  hello.txt step. Two independent checks:

  1. `SessionConfigWriter.write` embeds `autoModeJSON` verbatim under the
     `"autoMode"` key of `settings-<session>.json` (confirmed by reading the
     file the real spawn below generated). To check the CLI actually loads
     that key, ran the same shape standalone:
     ```
     $ claude --settings test-settings.json auto-mode config > with-settings.json
     $ grep -n AGENTBOARD_CANARY_9f3d2c17 with-settings.json
     95:    "AgentBoard Canary M3 [named+specifics]: any command whose text contains the exact token AGENTBOARD_CANARY_9f3d2c17 is always a soft-deny requiring approval, with no exceptions, regardless of any other rule in this policy."
     ```
     where `test-settings.json` was `{"autoMode": {"soft_deny": [<the same
     rule>]}}`. The rule shows up appended to the 70 shipped `soft_deny`
     defaults — the `--settings` file's `autoMode` key is honored by
     `auto-mode config`.
  2. The real worker's `PostToolUse` hook payload, captured by Agent Board's
     `/hooks` endpoint and read back from the `hook_event` table:
     ```
     "hook_event_name": "PostToolUse",
     "tool_name": "Bash",
     "permission_mode": "auto",
     "tool_input": { "command": "echo AGENTBOARD_CANARY_9f3d2c17", ... },
     "tool_response": { "stdout": "AGENTBOARD_CANARY_9f3d2c17", ... },
     "duration_ms": 294
     ```
     No ask, no denial, no distinguishing field — the command ran exactly
     like any other Bash call. The task went on to `report_complete` and
     `E2E PASS`.

  **Known limitation:** a project `autoMode.soft_deny` rule is not a working
  safety control for an unattended `claude --bg --permission-mode auto`
  worker — there is no user for the classifier to ask, and the match does
  not fall back to a deny. `autoMode` is still expressive for the interactive
  orchestrator session (which has a user to ask), but a project should not add
  a rule expecting it to stop a worker.
- **Verified by M3: `hard_deny` does not stop the call either.** The same
  canary method, with the rule moved to `hard_deny`. The rule reached the
  effective config — `claude --settings <file> auto-mode config` listed it
  under `hard_deny` alongside the shipped Data Exfiltration rule, the
  `"$defaults"` sentinel expanding in place exactly as it does for
  `soft_deny` — and the worker ran the command anyway:
  (This run predates the `PreToolUse` hook, so `PostToolUse` was the only
  evidence available — and it shows the call completed.)
  ```
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "permission_mode": "auto",
  "tool_input":    { "command": "echo AGENTBOARD_HARDDENY_4b81e2", ... },
  "tool_response": { "stdout": "AGENTBOARD_HARDDENY_4b81e2", "interrupted": false, ... }
  ```
  The worker then reported `Ran echo AGENTBOARD_HARDDENY_4b81e2; output was
  AGENTBOARD_HARDDENY_4b81e2` and the run ended `E2E PASS`. So neither
  classifier severity is a usable control for a `--bg` worker; the
  `PreToolUse` hook is.
- **Verified by M3: the `PreToolUse` push block works.** Spawned one real
  worker with `--disallowedTools` deliberately emptied, against a fixture repo
  whose `origin` was a local bare clone — so a working push would have
  succeeded and been visible. Task body required `git push -u origin HEAD`.
  The hook payload Agent Board denied:
  ```
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "permission_mode": "auto",
  "tool_input": { "command": "git push -u origin HEAD 2>&1; echo \"exit=$?\"",
                  "description": "Push current branch to origin as the task requires" }
  ```
  The worker's own report: *"the push was blocked at the tool layer with the
  message 'Agent Board blocks pushes from workers. Commit on your branch and
  call report_complete; a human integrates it.' Nothing was pushed."* The bare
  remote still held only `6cee47b Initial commit` on `main` afterwards, with
  no `agentboard/<task>` branch, and the task card carried the progress row
  `error: Blocked push: git push -u origin HEAD 2>&1; echo "exit=$?"`. The
  unrelated Bash call in the same session (the `hello.txt` commit) was allowed
  through and completed.
- **Not verified live: the shutdown delivery mechanism.** The wind-down order
  (§8) reaches a worker by one of two paths — a busy `--bg` worker only by
  denying its next `PreToolUse`, an idle one only by `--resume` with a prompt
  — and **neither was exercised against a real spawned worker.** Both are
  unit-tested only, against fixtures: `AgentBoardBridgeTests/ShutdownWindDownTests`
  drives the `PreToolUse` deny path through a `BridgeFixture`, and
  `AgentBoardAppTests/ShutdownDeliveryTests` drives the resume path against a
  stub runtime. The progress sheet (§10) fares no better: it was mounted
  offscreen via `NSHostingView` and proven to re-render off the database, but
  its rendered text could not be read back on this machine at all —
  the accessibility elements SwiftUI publishes offscreen carry no label, title
  or value, so the tree comes back empty — and the human click-through steps its own report wrote out (open
  the console, click Stop All, watch rows move `ordered` → `closing` →
  `acknowledged`, let one go overdue, attach to a blocked one, quit) were
  explicitly never run. Unlike the M3 push-block verification above, which
  ran a real worker against a real bare remote, no part of the shutdown
  feature has been seen working end to end.
- **Known gap: a `blocked` worker is enrolled and counted but never receives
  the order.** `deliverShutdownOrder` resumes only sessions in `idle`; nothing
  can reach a session sitting on a permission prompt — no hook fires, and
  resuming into a pending prompt is untested behavior nobody wanted to rely
  on. It shows as **waiting on you** in the progress sheet (§10), never
  miscounted as unresponsive, and the fix is a human answering the prompt (or
  Attach), not automatic delivery.
- **Fixed during M3:** `claude --bg` colorizes the `backgrounded · <id>` line
  even when stdout is a pipe, so `ClaudeCLI.parseShortId` rejected the hex id
  and every spawn failed with "exited 0 but no short id was found" while the
  session kept running orphaned. ANSI escapes are now stripped before parsing.
- **Resolved: abandoning an epic is built.** `EpicState.abandoned`, present
  since M3's schema, is now reachable: `Board.closeEpic(epicId:as:)` writes
  it, exposed both as the `close_epic` MCP tool (`state: "abandoned"`) and as
  the epic lane header's **Abandon** menu action (§10, §5.2). A decomposition
  that turns out wrong has a real path off the board instead of its tasks
  sitting unfinished forever. See `EpicClosureTests`, `CloseEpicToolTests`,
  `EpicCloseTests`, `EpicLaneTests`.
- **Resolved: the port problem is solved by rewriting config files before
  every resume, plus a persisted preferred port.** `WorkerSupervisor`'s
  private `resume(_:prompt:)` calls `SessionConfigWriter.write` with the
  session's current `serverPort` immediately before every `claude --bg
  --resume`, so a worker's `--settings`/`--mcp-config` paths always point at
  wherever the server is actually listening this launch, regardless of where
  it listened when the worker was spawned. `BoardServer.start(preferredPort:)`
  additionally persists the last bound port to an `appSupportDir`-relative
  `server-port` file and tries that port first on the next app launch, falling
  back to an ephemeral one only if it's taken — so the port is usually stable
  across relaunches, and the resume rewrite covers it when it isn't. See
  `SessionConfigTests.testRewriteOverwritesInPlaceWithNewPort`.
- **Unresolved:** which globally configured MCP servers should be allowlisted
  back into workers past `--strict-mcp-config`. Starting position: none — and
  still none reach a worker in practice. `ProjectSettings.extraMcpServers` and
  a matching Project Settings field exist, and `SessionConfigWriter.write` can
  merge named servers into a worker's `mcpServers` block, but every real
  spawn/resume call site (`WorkerSupervisor`'s `launch` and `resume`,
  `OrchestratorConsole`'s session start) hardcodes `extraMcpServers: nil`, so
  the setting is stored and rendered but never consumed. The policy question
  is still open; only the plumbing for acting on an answer has been started.
- **Unresolved:** whether the `PostToolUse` round trip is cheap enough to leave
  on permanently, or needs a matcher narrowing it to interesting tools.
- **Was an accepted limitation, now readable:** budgets still meter only what
  Agent Board spawned, but account headroom against the 5-hour and weekly caps
  *is* readable programmatically. Claude Code caches it in the
  `cachedUsageUtilization` block of `~/.claude.json`: `utilization.five_hour`
  and `utilization.seven_day`, each carrying a 0-100 `utilization` percentage
  and an RFC3339 `resets_at`, under a `fetchedAtMs` stamp. Sibling keys
  (`seven_day_opus`, `nimbus_quill`, `limits`, and others) are usually null and
  are ignored. `AccountUsageReader` parses it and the sidebar shows both windows
  below "Add Project…". The two numbers answer different questions — a green
  budget with a 90% five-hour bar means the account cap, not the budget, is what
  stops the next spawn.

  **The caveat is staleness.** That block is a cache, not a live reading:
  Claude Code refetches it on its own TTL, and ordinary session traffic does not
  keep it warm (measured below), so it can be hours old. Every reading
  therefore carries its age on screen, and one older than 30 minutes
  (`AccountUsageSnapshot.staleAfter`) is dimmed and labelled `stale` rather than
  presented as current. A block with no `fetchedAtMs` counts as stale —
  freshness has to be proven, not assumed.
- **Verified 2026-09-12: `claude -p "/usage"` does refresh the cache, and only
  when it is already stale.** Three measurements on this machine:

  | cache age before | after `claude -p "/usage"` |
  |---|---|
  | 1265 s | 0.7 s — refetched |
  | 869 s  | fresh — refetched |
  | 21 s / 28 s | unchanged — no-op |

  The run reports `num_turns: 0` and `total_cost_usd: 0`: `/usage` is a local
  command, so it costs no inference. Claude Code applies its own TTL before
  refetching, so an eager call on a fresh cache is simply a wasted process.
  `AccountUsageRefresher` therefore fires only past the 30-minute staleness
  threshold, at most once every 10 minutes, doubling that wait per consecutive
  failure up to 80 minutes. It runs `claude -p`, never `--bg`, so it writes no
  `agent_session` row, is never metered as project spend, and never appears in
  `claude agents --json --all`. It runs detached from the UI, and a failure
  leaves the stale reading and its age on screen rather than blanking the bars.

  **Unexpected, and the reason the fallback earns its place:** ordinary session
  traffic does *not* keep the cache warm. A Claude Code session making API calls
  continuously for 21 minutes left `fetchedAtMs` untouched the whole time — the
  cache moved only when `/usage` forced it. So "workers are running" is not a
  reason to expect a fresh reading.
- **Accepted limitation:** "native Mac app" means native chrome around embedded
  terminals. The agent conversation is Claude Code's TUI, not a SwiftUI rendering
  of it.
- **Partly solved: a child process blocking on stdin.** Observed 2026-09-12 —
  session `b2b3848d` on task `61da923d` ran `cp -i` (the shell's interactive
  alias) inside its worktree and wedged waiting for a y/n that never arrived.
  The prompt belonged to a grandchild process, not to Claude Code, so no
  `Notification` hook fired, `blocked` was never set, and the session looked
  healthy until the idle cap killed it.

  **Solved:** it is now visible. The metering tick flags a `running` worker
  whose `last_activity` has not moved for `caps.stallSeconds` and the
  orchestrator's Blocked section shows it as `stalled`, with a macOS
  notification on the transition (§7). **Still unsolved:** the signal is a
  heuristic, not a report — a worker legitimately inside one very long tool
  call is indistinguishable from a wedged one, so the threshold trades false
  positives against how late the wedge is caught. And there is no way to answer
  a grandchild's prompt from Agent Board: the only remedy is Attach (D15) or
  Stop. A `PreToolUse` matcher that rejected known-interactive commands
  (`cp -i`, `rm -i`, `ssh` without `BatchMode`) would prevent the class rather
  than detect it, but has not been built.
- **Deliberate gap: a standalone `done` task never auto-archives under
  `afterEpicMerge`.** That policy's only trigger is `Board.complete` merging an
  epic (§5.2); a task with no `epic_id` has no merge event to ride, so it
  accumulates on the board until archived by hand with the Task Board button.
  There is intentionally no age fallback for this case — a policy that quietly
  behaves like a different policy (`afterDays`) is worse than one that does
  nothing, per the workers' own reasoning in `bf81e80`. If this project's done
  work is mostly standalone rather than epic-scoped, `afterEpicMerge`'s default
  archives almost nothing automatically; `afterDays` is the policy that fits.
- **Not built: any UI for the `afterDays` sweep's cadence or backlog.** The
  sweep only runs while the app is open (it rides `WorkerSupervisor`'s existing
  metering tick, throttled to once per 5 minutes) and there is no indicator of
  when it last ran or how many tasks are currently past their threshold and
  waiting for the next tick — you only see the effect once a card disappears.
- **Landed late, and what that cost: the Roster screen (§10).** Task
  `53622b86` ("Add the Roster tab and per-project agent selection") showed
  `done` like every other task in the Agent roster epic, but its commit
  `46bd2e6` was never merged into the epic branch, by that task or by any task
  after it. For the length of the epic the roster's data model, spawn path,
  hand-off and agent-review routing all shipped and were exercised by tests
  while there was no way — in the app or over MCP — to create a rostered agent
  or enable one for a project. `46bd2e6` has since been merged rather than
  rebuilt, and the screen is reachable.
  Two things survive that gap. A task reading `done` can mean "committed on a
  branch nobody merged", which only an audit of `git branch --contains` finds,
  not the board. And `46bd2e6` was written against a `MainWindow` that has
  since gained workspaces and At a Glance, so the `Projects`/`Roster` segmented
  switch it specified became a `SidebarSelection.roster` row instead — porting
  a view that sat unmerged costs a rewrite of its host, not just a merge.
- **Settled by reasoning, not by measurement: which `roster_agent` schema to
  keep, and what its deny-list column means.** Two epic tasks independently
  built incompatible schemas for `roster_agent`/`project_roster_agent` (one
  with `ordering REAL`, one with an orderless `opted_in` boolean; one
  documenting `tool_scope` as an allow-list, one treating it as a deny-list in
  working code) before either was merged. The reconciliation
  (commit `3df54d5`) picked a side by reading which behavior was already
  wired — `ReviewPolicy.routing` needs `ordering` to pick a reviewer
  deterministically, and only the deny-list interpretation has a consumer
  (`WorkerSupervisor` appending `disallowed_tools` to `--disallowedTools`) —
  not by running both and observing a difference. No database had ever
  applied either migration, which is what made the choice cheap rather than a
  live-data migration; had one been live, "which one matches production" would
  have been the actual answer, and reasoning about the code would not have
  been enough. See the "two roster_agent schemas" project note for the full
  comparison.
