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
| D8 | Workers commit and stop. They never push | Nothing reaches a shared remote unattended | Worker opens a draft PR |
| D9 | Reports queue in SQLite; app injects a fixed notice; orchestrator pulls | Worker text never enters the orchestrator's user-authority turn | Inject report text into PTY |
| D10 | Epics group tasks and own the integration branch | Merge scope becomes a lookup, not a judgment call | Flat tasks |
| D11 | One orchestrator per project | cwd determines which CLAUDE.md, skills, and MCP servers load | One global orchestrator |
| D12 | Notes are Agent Board's own store, Solo-scratchpad-shaped | Notes are a working surface, not Claude Code memory | View over `~/.claude/.../memory/` |
| D13 | Pinned notes + task/epic-attached notes injected at spawn; rest pull-only | Stops three workers rediscovering the same constraint | Seed every note title |
| D14 | Workers run `--permission-mode auto` | The shipped classifier already encodes 70 soft-deny rules | Hand-rolled PreToolUse denylist |
| D15 | Blocked agents are answered by attaching to their real terminal | Auto mode's prompt text is written to be read; don't reproduce it | Native approval dialog |
| D16 | Workers are `claude --bg` background sessions | Deletes process supervision, crash recovery, and scrollback from scope | App owns the PTYs |
| D17 | Swift + SwiftUI | Literal reading of "native Mac app" | Tauri |
| D18 | Runtime spike → board → orchestrator → epics → notes | The riskiest assumption is provable in 200 lines | Build everything |

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
- **No programmatic read of account-wide remaining subscription quota exists.**
  Every budget in this spec is a self-imposed ceiling over what Agent Board
  itself spawned, not a real-quota ceiling.
- `~/.claude/projects/<worktree-slug>/memory/` is created empty for each new
  worktree. The existing convention on this machine symlinks it to the canonical
  project memory dir (confirmed across ~20 Derivita checkouts).

---

## 3. Architecture

```
┌─ Agent Board.app (Swift / SwiftUI) ───────────────────────────┐
│                                                                │
│  UI: Orchestrator · Task Board · Status · Notes                │
│  Terminal: SwiftTerm                                           │
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

### 3.1 Spawn procedure

For a task `T` in project `P`:

1. Ensure the epic branch exists (`agentboard/epic-<epic-id>`, cut from `P`'s
   base branch) if `T` belongs to an epic.
2. `git worktree add <worktrees>/<task-id> -b agentboard/<task-id> <base>` where
   `<base>` is the epic branch, or the project base branch for a standalone task.
3. Symlink `~/.claude/projects/<worktree-slug>/memory` → the canonical project
   memory dir. **Skipping this makes every worker amnesiac.**
4. Generate `settings-<session>.json`: `http` hook definitions pointing at
   `/hooks?token=…` (a `command` + `curl` hook for `SessionStart`, see §2), plus
   the project's `autoMode` block. On resume, rewrite this file and the MCP
   config in place with the current port; `--bg --resume` reuses the paths.
5. Generate `mcp-<session>.json`: one HTTP server entry for `/mcp` with
   `Authorization: Bearer <token>`, where the token carries scope `worker` and
   is bound to `(session, task)`.
6. Compose the opening prompt: task title, body, acceptance criteria, epic goal,
   pinned notes in full, attached notes in full, and the completion protocol
   (commit, do not push, call `report_complete`).
7. `claude "<prompt>" --bg -n <task-slug> --permission-mode auto
   --strict-mcp-config --mcp-config <file> --settings <file>
   --disallowedTools "Bash(git push*)" "Bash(gh pr create*)" "Bash(gh pr merge*)"`
   with cwd set to the worktree. The prompt goes first because
   `--disallowedTools` is variadic and would swallow a trailing positional.
8. Parse the short id from stdout, look up the session uuid in
   `claude agents --json`, and record it with the worktree path, branch, and
   token in SQLite. The token grant is bound to the session at this point, not
   before spawn.

`--strict-mcp-config` is deliberate: without it a worker sees `repo-tasks`,
`solo`, and the other globally configured servers, and has two contradictory
task systems in its tool list. A per-project allowlist of extra servers to
merge back in (`mdn`, `caniuse`) is a project setting.

---

## 4. Data model

SQLite, GRDB. Language-neutral by intent (see §1 pivots).

```sql
CREATE TABLE project (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  repo_path       TEXT NOT NULL UNIQUE,
  base_branch     TEXT NOT NULL DEFAULT 'main',
  worktree_root   TEXT NOT NULL,
  memory_dir      TEXT,            -- canonical ~/.claude/projects/<slug>/memory
  orch_session_id TEXT,            -- pinned uuid, resumed lazily
  settings_json   TEXT NOT NULL,   -- caps, autoMode block, mcp allowlist
  created_at      INTEGER NOT NULL
);

CREATE TABLE epic (
  id             TEXT PRIMARY KEY,
  project_id     TEXT NOT NULL REFERENCES project(id),
  title          TEXT NOT NULL,
  goal           TEXT,
  branch         TEXT NOT NULL,    -- agentboard/epic-<id>
  state          TEXT NOT NULL,    -- planning | active | integrating | done | abandoned
  created_at     INTEGER NOT NULL
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
  origin         TEXT NOT NULL,    -- human | orchestrator | worker_proposal
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

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
  state          TEXT NOT NULL,      -- starting|running|idle|blocked|stopped|failed|completed
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  last_activity  INTEGER,
  transcript_path TEXT,
  tokens_in      INTEGER NOT NULL DEFAULT 0,
  tokens_out     INTEGER NOT NULL DEFAULT 0,
  cache_read     INTEGER NOT NULL DEFAULT 0,
  cache_write    INTEGER NOT NULL DEFAULT 0,
  est_cost_usd   REAL NOT NULL DEFAULT 0,
  attempt        INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE token_grant (
  token       TEXT PRIMARY KEY,      -- random, per session
  session_id  TEXT NOT NULL REFERENCES agent_session(session_id),
  scope       TEXT NOT NULL,         -- orchestrator | worker
  task_id     TEXT,                  -- worker: the only task it may mutate
  revoked_at  INTEGER
);

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
  kind        TEXT NOT NULL,         -- complete | failed | blocked | proposal
  body        TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  consumed_at INTEGER               -- set when the orchestrator pulls it
);

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
```

Notes are sectioned rather than a single body specifically so three concurrent
workers appending to one note do not silently lose each other's writes. Whole-
document replace is not offered.

---

## 5. Task lifecycle

```
proposed ──promote──> backlog ──deps met──> ready ──assign──> running
                                                                 │
                          ┌──────────────────────────────────────┤
                          ▼                                      ▼
                       review ──accept──> done              failed (flag)
                          │                                      │
                          └──────────── reopen ──────────────────┘
```

- `proposed` — created by a worker via `propose_task`. Neither the orchestrator
  nor a worker may promote a worker proposal without human approval when
  autonomy is off; with autonomy on, the orchestrator may promote.
- `ready` — **the only column the orchestrator may pull from.** A task becomes
  eligible when every row in `task_dep` points at a task in `done`.
- `running` — an `agent_session` row holds it. The board shows the agent, its
  spend, and elapsed time.
- `blocked` — a flag, not a column. Set by the `Notification` hook, cleared on
  the next `PostToolUse`. The card keeps its position and shows why.
- `review` — worker has committed on `agentboard/<task-id>` and called
  `report_complete`. The worktree is retained.
- `done` — you accept it. The worktree is removed (firing the existing
  `WorktreeRemove` hook, which reclaims Bazel `output_base` on Derivita). The
  branch is kept until its epic is integrated.

### 5.1 Completion protocol

A worker's closing instructions, injected at spawn:

1. Commit on the current branch. Message in imperative mood, no conventional
   commit prefix.
2. **Do not push. Do not open a PR.** Both are denied at the tool layer and by
   a project `autoMode` soft-deny rule; the instruction exists so the agent
   does not waste a turn discovering that.
3. Call `report_complete(summary, files_changed, tests_run, caveats)`.

### 5.2 Epic integration

Integration is the orchestrator's job and is gated on your approval regardless
of the autonomy setting.

1. All tasks in the epic reach `done`.
2. Orchestrator calls `request_integration(epic_id)`. This creates an approval
   row and a macOS notification. Nothing proceeds until you approve.
3. On approval, Agent Board creates an integration worktree on
   `agentboard/epic-<id>` and spawns an integrator worker whose job is to merge
   each `agentboard/<task-id>` into the epic branch, resolve conflicts, and get
   the build green.
4. The integrator reports. The PR from `agentboard/epic-<id>` → base is opened
   **by you**, from a button on the epic — not by an agent.

---

## 6. MCP surface

Served at `http://127.0.0.1:<port>/mcp`. Scope comes from the bearer token, not
from the request. A worker calling an orchestrator tool gets a tool-not-found
error, because the tool list is rendered per scope.

### Worker scope

| Tool | Effect |
|---|---|
| `get_my_task()` | The task bound to this token, plus its epic goal and dependency summaries |
| `update_status(state, detail)` | Appends to `progress`; sets `blocked`/`failed` flags |
| `log_progress(text)` | Appends to `progress` |
| `search_notes(query)` | FTS over this project's notes |
| `read_note(id)` | Full note with sections |
| `append_section(note_id, heading, body, if_version)` | Section-scoped write |
| `replace_section(note_id, heading, body, if_version)` | Section-scoped write |
| `create_note(title, sections)` | New note, unpinned |
| `propose_task(title, body, rationale)` | Inserts into `proposed` |
| `report_complete(summary, files_changed, tests_run, caveats)` | Inserts a `report`; moves task to `review` |
| `report_blocked(reason)` | Inserts a `report`; sets `blocked` |

A worker may not read other tasks, reassign, create a non-proposal task, or
spawn anything.

### Orchestrator scope

Everything in worker scope over any task in the project, plus:

| Tool | Effect |
|---|---|
| `list_tasks(column, epic_id)` | Board query |
| `create_task(...)`, `update_task(...)`, `move_task(id, column)` | Board mutation |
| `set_deps(task_id, depends_on[])` | Dependency graph |
| `create_epic(title, goal, tasks[])` | Records a decomposition; cuts the epic branch |
| `attach_note(note_id, task_id|epic_id)` | Passes context down at spawn time |
| `pin_note(note_id, pinned)` | Every future agent sees it in full |
| `spawn_worker(task_id)` | Subject to §8 caps and the autonomy setting |
| `stop_worker(session_id)` | `claude stop` |
| `list_agents()` | Roster with state and spend |
| `list_reports()`, `get_report(id)` | The Q9 pull channel |
| `promote_proposal(task_id)` | Only when autonomy is on |
| `request_integration(epic_id)` | Always creates a human approval row |

---

## 7. Hook contract

Generated into each managed session's `--settings`. All post to
`http://127.0.0.1:<port>/hooks?token=<session token>`.

| Event | Agent Board's reaction |
|---|---|
| `SessionStart` | Mark `agent_session.state = running`; record transcript path |
| `PostToolUse` | Bump `last_activity`; clear `blocked`; append a `tool` progress row |
| `Notification` | Set `blocked` + reason on the task and session; macOS notification |
| `Stop` | Mark session idle. **On the orchestrator, this is the trigger for the report notice** (§9) |
| `SessionEnd` | Mark stopped/completed; reconcile final spend from the transcript |
| `WorktreeRemove` | Chain to the user's existing hook, then clear the worktree row |

The handler must be synchronous and trivial — `PostToolUse` fires on every tool
call, and a slow handler is felt directly as agent latency. Anything expensive
goes on a queue.

Spend metering tails the session's JSONL transcript rather than relying on
hooks, since hooks do not carry `usage`.

---

## 8. Safety and limits

Per project, overridable:

| Cap | Default | On breach |
|---|---|---|
| Concurrent workers | 3 (lower for large repos — Derivita) | Spawn refused; orchestrator told why |
| Tokens per agent | 150,000 | Agent stopped, task flagged, Resume offered |
| Wall clock per agent | 30 min | Agent stopped, task flagged, Resume offered |
| Idle (no tool use, no output) | 5 min | Agent stopped, task flagged |
| Project session ceiling | configurable | Spawn refused |

- **Autonomy is off on first run.** Every `spawn_worker` creates a pending
  approval until you turn it on. This is a setting, not a rebuild.
- **Stopping is not destructive.** Every session has a pinned `--session-id`, so
  a capped agent resumes exactly where it stopped.
- **Pause All** stops every managed session in the project via `claude stop`.
- **Integration always requires human approval**, autonomy setting regardless.
- Workers never push. Enforced twice: `--disallowedTools` and a project
  `autoMode` soft-deny rule.
- `autoMode.environment` is populated per project — repo visibility, trust
  boundary, org CLIs — so the classifier's single hard-deny rule (data
  exfiltration) has real boundaries to work with. Rule sets are run through
  `claude auto-mode critique` before shipping.

---

## 9. Orchestrator

- One per project. Foreground PTY owned by the app (not `--bg`), pinned
  `--session-id`, cwd at the repo root, resumed lazily on first view so
  launching the app does not wake four orchestrators and spend tokens.
- Permission mode: your normal interactive default. It's the session you are
  watching.
- Its job description is injected with `--append-system-prompt`: the board
  vocabulary (project, epic, task, column), the rule that only `ready` is
  assignable, the completion and integration protocols, and the instruction to
  call `list_reports` when told to.

### 9.1 Report channel

1. A worker calls `report_complete` / `report_blocked` / `propose_task`. The
   body lands in `report`, unconsumed.
2. The orchestrator's `Stop` hook fires when it finishes a turn.
3. If unconsumed reports exist, Agent Board writes **one fixed, app-authored
   line** into the orchestrator PTY:
   `[agent-board] N worker reports pending. Call list_reports.`
4. The orchestrator pulls bodies through MCP, where they arrive as tool results.

No agent-generated text is ever written into the orchestrator's user turn. The
orchestrator holds spawn, assign, and integration authority; a worker that echoes
a malicious file into its report must not be able to drive it.

---

## 10. Screens

**Orchestrator Command** — the project's orchestrator terminal (SwiftTerm),
with a sidebar of pending approvals: spawns awaiting authorization, worker
proposals, and integration requests.

**Task Board** — columns from §5, swimlanes by epic. A card shows title, epic,
assigned agent, elapsed, spend, and its `blocked`/`failed` flag. Drag between
columns. Cards in `review` show the branch, worktree path, and a diffstat.

**Status** — the agent roster. Reconciled from `claude agents --json --all`
joined against `agent_session`, so a session that died outside the app is shown
as dead rather than phantom-running. Per agent: task, state, elapsed, spend
against cap, last tool used. A blocked agent's row opens its terminal, which is
how permission prompts get answered (D15).

**Notes** — list and full-text search, sectioned editor, pin toggle, and the set
of tasks/epics each note is attached to. Shows which agent last wrote each
section.

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

**M1 — board.** Project registration, SQLite store, Task Board, Status,
worktree creation with the `memory` symlink, manual assignment, spend metering,
caps. Useful without any orchestrator.

**M2 — orchestrator.** Orchestrator PTY, per-scope MCP tokens, `spawn_worker`,
the report channel, approvals sidebar, autonomy toggle.

**M3 — epics and integration.** Epic entity, epic branches, task branching from
epic branches, integration worktree and integrator, human-opened PR.

**M4 — notes.** Note store, section ops, FTS, pinning, attachment, spawn-time
injection.

Notes is last deliberately: it is the lowest-risk screen and it benefits most
from knowing how the agents actually behave first.

---

## 12. Open items

- **Verified by M0:** a healthy `claude --bg` session honors injected hooks and
  MCP config. Still unverified: that the `autoMode` block from `--settings` is
  applied (the spike ran with the shipped defaults).
- **Unresolved:** the localhost port is ephemeral per app launch, but
  `--bg --resume` reuses the saved `--settings`/`--mcp-config` paths. Either
  rewrite both files before every resume (current plan) or pick a stable
  per-project port.
- **Unresolved:** which globally configured MCP servers should be allowlisted
  back into workers past `--strict-mcp-config`. Starting position: none.
- **Unresolved:** whether the `PostToolUse` round trip is cheap enough to leave
  on permanently, or needs a matcher narrowing it to interesting tools.
- **Accepted limitation:** budgets meter only what Agent Board spawned. Account
  headroom against 5-hour and weekly caps is not readable programmatically, so a
  green budget does not mean you have quota left.
- **Accepted limitation:** "native Mac app" means native chrome around embedded
  terminals. The agent conversation is Claude Code's TUI, not a SwiftUI rendering
  of it.
