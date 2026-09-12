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
   [--model <task.model ?? settings.defaultModel>]
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
  settings_json   TEXT NOT NULL,   -- caps, autoMode block, mcp allowlist, defaultModel, modelGuidance
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
  updated_at     INTEGER NOT NULL,
  model          TEXT              -- overrides project settings.defaultModel for this task's worker
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
  attempt        INTEGER NOT NULL DEFAULT 1,
  model          TEXT,
  last_tool      TEXT,
  stop_reason    TEXT
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
  kind        TEXT NOT NULL,         -- complete | failed | blocked | proposal | decision
  body        TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  consumed_at INTEGER               -- set when the orchestrator pulls it
);

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

The token is issued before spawn (it has to be in the generated config files)
and bound to the session afterwards; the SessionStart hook may arrive first and
bind it itself. `est_cost_usd` is a list-price estimate from transcript usage,
never a billed amount.

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
- `done` — you accept it. Every attempt's worktree is removed (firing the
  existing `WorktreeRemove` hook, which reclaims Bazel `output_base` on
  Derivita), and `agentboard/<task-id>` is deleted once it is merged into the
  base or epic branch. An unmerged branch, or a worktree with uncommitted
  changes, is kept and the reason surfaced in the status bar.

Reconcile also reaps worktrees under the project's worktree root that no active
session owns, and deletes merged `agentboard/*` branches that no longer have a
worktree. Anything dirty or unmerged is left alone and reported. Epic
integration worktrees and `agentboard/epic-*` branches are out of scope.

### 5.1 Completion protocol

A worker's closing instructions, injected at spawn:

1. Commit on the current branch. Message in imperative mood, no conventional
   commit prefix.
2. **Do not push. Do not open a PR.** Both are denied at the tool layer
   (`--disallowedTools` and the `PreToolUse` hook, §8); the instruction exists
   so the agent does not waste a turn discovering that.
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
| `PreToolUse` (matcher `Bash`) | Deny `git push`, `gh pr create`, `gh pr merge`; append an `error` progress row (§8) |
| `PostToolUse` | Bump `last_activity`; clear `blocked`; append a `tool` progress row |
| `Notification` | Set `blocked` + reason on the task and session; macOS notification; the task appears in the orchestrator's **Blocked** section (§10) |
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
notification message as `blocked_reason`, moves the session to `blocked`, files
a `blocked` report for the orchestrator, and raises a macOS notification titled
"Agent needs input". The next `PostToolUse` clears `blocked` again, so a worker
that was answered leaves the section without anyone pressing anything.

**Stall detection.** Some prompts fire no hook at all — a grandchild process
reading stdin (`cp -i`, `ssh` asking for a passphrase) belongs to neither
Claude Code nor Agent Board, so nothing is posted and `last_activity` simply
stops advancing. The metering tick (already running every 5s, already reading
`last_activity`) flags a `running` worker whose activity clock has not moved
for `caps.stallSeconds` — default 120s, deliberately below the 300s idle cap so
it surfaces before the cap kills it. A stall is a suspicion, not a reported
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
| Wall clock per agent | 30 min | Agent stopped, task flagged, Resume offered |
| Idle (no tool use, no output) | 5 min | Agent stopped, task flagged |
| Project session ceiling | configurable | Spawn refused |

- A stopped agent's task returns to `ready` with its `failure_reason` set, and a
  `failed` report goes to the orchestrator (§9.1). Leaving it in `running` with
  no session strands it: nothing can be spawned from `running`.

- The token cap counts uncached input plus output only. Cache reads recur every
  turn and cache writes re-cache the whole context on every resume (measured:
  200k+ per resume on an M2-sized worker), so neither is a measure of work done.
  Counting cache writes killed the first M2 worker twice in ten minutes; the cap
  is therefore off until a project sets it.
- **Autonomy is off on first run.** Every `spawn_worker` creates a pending
  approval until you turn it on. This is a setting, not a rebuild.
- **Stopping is not destructive.** Every session has a pinned `--session-id`, so
  a capped agent resumes exactly where it stopped.
- **Pause All** stops every managed session in the project via `claude stop`.
- **Integration always requires human approval**, autonomy setting regardless.
- **Workers never push.** Enforced twice, by two controls that fail
  independently:
  1. `--disallowedTools "Bash(git push*)" "Bash(gh pr create*)" "Bash(gh pr
     merge*)"` at spawn time, a CLI-level block.
  2. A `PreToolUse` hook (§7) matched to `Bash`. `IntegrationGuard` scans the
     command for `git push`, `gh pr create` and `gh pr merge` and Agent Board
     returns a deny from its own process, so the block does not depend on the
     session's permission mode. The scan tokenizes on shell punctuation as
     well as whitespace, so a chained, quoted, piped or env-prefixed
     invocation (`cd x && git push`, `git -C d push`) is caught too. Every
     denial appends an `error` progress row naming the blocked command, so the
     human sees the attempt on the task card.

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

---

## 9. Orchestrator

- One per project. Foreground PTY owned by the app (not `--bg`), pinned
  `--session-id`, cwd at the repo root, resumed lazily on first view so
  launching the app does not wake four orchestrators and spend tokens.
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
   the table below. The body lands in `report`, unconsumed.
2. The orchestrator's `Stop` hook fires when it finishes a turn.
3. If unconsumed reports exist, Agent Board writes **one fixed, app-authored
   line** into the orchestrator PTY:
   `[agent-board] N worker reports pending. Call list_reports.` terminated by
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

A worker session Agent Board ends itself never lands the task in `running` with
no session attached: the task returns to `ready` so it can be dispatched again
without a manual `move_task`. A cap or idle kill also sets `failed` and
`failure_reason` on the card; a human stop does not.

No agent-generated text is ever written into the orchestrator's user turn. The
orchestrator holds spawn, assign, and integration authority; a worker that echoes
a malicious file into its report must not be able to drive it.

---

## 10. Screens

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

**M1 — board. DONE 2026-09-11 (headless E2E: assign → report_complete → accept, 16/16 checks).** Project registration, SQLite store, Task Board, Status,
worktree creation with the `memory` symlink, manual assignment, spend metering,
caps. Useful without any orchestrator.

**M2 — orchestrator. DONE 2026-09-11 (report channel verified live: Stop → notice → `list_reports` → consumed).** Orchestrator PTY, per-scope MCP tokens, `spawn_worker`,
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
- **Fixed during M3:** `claude --bg` colorizes the `backgrounded · <id>` line
  even when stdout is a pipe, so `ClaudeCLI.parseShortId` rejected the hex id
  and every spawn failed with "exited 0 but no short id was found" while the
  session kept running orphaned. ANSI escapes are now stripped before parsing.
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
