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
                                   -- reviewLevel, reviewRouting, buildCommand, testCommand, archivePolicy,
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
  state          TEXT NOT NULL,    -- planning | active | integrating | pull_request_open | done | abandoned
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
  unarchived_at  INTEGER,          -- a human pulled it back; no automatic policy touches it again
  type           TEXT              -- code|docs|tests|plan|review; NULL = Default. Picks its review row (§4)
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
  project_id     TEXT REFERENCES project(id),  -- NULL for a Coordinator session only (§8.2)
  task_id        TEXT REFERENCES task(id),
  role           TEXT NOT NULL,      -- orchestrator | worker | coordinator
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
  roster_agent_id TEXT REFERENCES roster_agent(id),  -- §10: the rostered identity this session runs as
  review_head    TEXT,               -- §5.1: HEAD (and uncommitted-change fingerprint) a rostered reviewer was spawned on
  agent_stopped_at INTEGER,         -- §8.6: a `claude stop` succeeded after the row's last sign of life; a trigger clears it
  CHECK ((role = 'coordinator') = (project_id IS NULL))
);

CREATE TABLE coordinator (           -- one row (§8.2)
  id                INTEGER PRIMARY KEY CHECK (id = 1),
  active_session_id TEXT REFERENCES agent_session(session_id),  -- resumed on the next launch; NULL starts a fresh one
  model             TEXT             -- Coordinator settings; NULL = Claude Code's default
);

CREATE TABLE token_grant (
  token       TEXT PRIMARY KEY,      -- random, per session
  session_id  TEXT REFERENCES agent_session(session_id),  -- NULL until `claude --bg` returns the id
  project_id  TEXT REFERENCES project(id),  -- NULL for the Coordinator's grant only (§8.2)
  scope       TEXT NOT NULL,         -- orchestrator | worker | reviewer | coordinator
  task_id     TEXT,                  -- worker: the only task it may mutate
  created_at  INTEGER NOT NULL,
  revoked_at  INTEGER,
  CHECK ((scope = 'coordinator') = (project_id IS NULL))
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
  project_id  TEXT REFERENCES project(id),  -- NULL: the Coordinator's queue (§9.1)
  task_id     TEXT REFERENCES task(id),
  session_id  TEXT REFERENCES agent_session(session_id),
  kind        TEXT NOT NULL,         -- complete | failed | blocked | proposal | decision | message | comment | request | reply
  body        TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  consumed_at INTEGER               -- set when the orchestrator pulls it
);
CREATE INDEX report_project_consumed ON report(project_id, consumed_at);

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

-- §9.4: the Coordinator's request ledger. plan_note_id has no foreign key: the plan
-- lives in the Coordinator's own notes and need not exist yet.
CREATE TABLE coordinator_request (
  id           INTEGER PRIMARY KEY,
  project_id   TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,  -- the target
  body         TEXT NOT NULL,     -- the Coordinator's text, unframed
  plan_note_id TEXT,
  state        TEXT NOT NULL,     -- sent | accepted | declined | done | withdrawn
  created_at   INTEGER NOT NULL,
  closed_at    INTEGER            -- set on declined | done | withdrawn; the sweep counts from it
);
CREATE INDEX coordinator_request_closed ON coordinator_request(closed_at);
CREATE TABLE request_event (      -- history: the send, each reply, a withdrawal
  id         INTEGER PRIMARY KEY,
  request_id INTEGER NOT NULL REFERENCES coordinator_request(id) ON DELETE CASCADE,
  state      TEXT NOT NULL,
  author     TEXT NOT NULL,       -- coordinator | orchestrator
  body       TEXT NOT NULL,
  report_id  INTEGER REFERENCES report(id) ON DELETE SET NULL,  -- the report this step queued
  created_at INTEGER NOT NULL
);
CREATE INDEX request_event_request ON request_event(request_id);
CREATE INDEX request_event_report ON request_event(report_id);
CREATE TABLE request_epic (
  request_id INTEGER NOT NULL REFERENCES coordinator_request(id) ON DELETE CASCADE,
  epic_id    TEXT NOT NULL REFERENCES epic(id) ON DELETE CASCADE,
  PRIMARY KEY (request_id, epic_id)
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
  project_id  TEXT REFERENCES project(id),  -- NULL: one of the Coordinator's plans (§8.2)
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

CREATE VIRTUAL TABLE note_fts USING fts5(title, body, content='');  -- keyed to note.rowid

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

-- A task's comment thread: the human and agents talking about the work, kept apart from the
-- `progress` activity stream. Append-only; a comment goes only when its task does.
CREATE TABLE task_comment (
  id                     INTEGER PRIMARY KEY,
  task_id                TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
  project_id             TEXT NOT NULL REFERENCES project(id),
  author_kind            TEXT NOT NULL,   -- human | orchestrator | worker | reviewer
  author_session_id      TEXT,            -- not a foreign key: sessions are deleted before tasks
  author_roster_agent_id TEXT REFERENCES roster_agent(id) ON DELETE SET NULL,
  author_name            TEXT NOT NULL,   -- snapshot at write time; 'human' for the human, shown as "You"
  body                   TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 10000),  -- trimmed
  created_at             INTEGER NOT NULL
);
CREATE INDEX task_comment_task_created ON task_comment(task_id, created_at);

-- Human comments waiting for a live worker's or reviewer's next PostToolUse (§7).
CREATE TABLE comment_delivery (
  session_id TEXT NOT NULL REFERENCES agent_session(session_id) ON DELETE CASCADE,
  comment_id INTEGER NOT NULL REFERENCES task_comment(id) ON DELETE CASCADE,
  PRIMARY KEY (session_id, comment_id)
);
```

Every `epic.state` value is written by exactly one place, and nothing writes one
that is not listed here:

| State | Written by | When |
|---|---|---|
| `planning` | `EpicStore.insert` | The epic is created; `create_epic` and the New Epic sheet both land here |
| `active` | `WorkerSupervisor.spawn`, `Board.accept`, `Board.reopenEpicAfterClosedPullRequest` | The first task in the epic is spawned, or accepted, while the epic is still `planning`, **or** its pull request closed without merging (§5.2 step 5) |
| `integrating` | `WorkerSupervisor.spawnIntegrator` | The integrator worker spawned successfully on the epic branch (§5.2 step 3) |
| `pull_request_open` | `Board.recordPublished` | An approved `open_pull_request(epic_id)` recorded its URL, from any state but `abandoned` (§5.2 step 5) |
| `done` | `Board.complete`, `Board.landEpicPullRequest`, `Board.closeEpic` | The integrator reported on an `integrating` epic, **or** its pull request merged, **or** a human closed the epic by hand (§10) |
| `abandoned` | `Board.closeEpic` | A human abandoned the epic by hand (§10) |

`done` and `abandoned` are terminal: `Board.closeEpic` refuses an epic that is
already in either, so one never silently becomes the other, and `create_task`
and `set_epic` refuse a terminal epic as a destination. The one reopen is a
pull request recorded for a `done` epic (§5.2 step 5); otherwise a closed epic stays closed, and work left inside one is freed with
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
rows and keeps its history: the tasks it worked or reviewed, its sessions, the
`progress` rows naming it and the comments it wrote all survive it. Their `roster_agent_id` and
`reviewer_agent_id` are set to NULL in the same transaction, because those columns
are foreign keys with no `ON DELETE` and a dangling id would fail the delete.
`task_comment.author_roster_agent_id` is `ON DELETE SET NULL`, so SQLite nulls it
in the same delete, and `author_name` still names the agent. The
store refuses (`BoardError.rosterAgentWorking`) while a live session still runs as
the agent, independently of the Roster screen's own guard (§10).

There is no `is_reviewer` flag. Under `agent` review (§5), who reviews a task
is its row in the project's review routing table, `settings_json.reviewRouting`
(`ReviewRoutingTable`): a Default row, plus an optional row for each
`task.type` (`TaskType`: `code`, `docs`, `tests`, `plan`, `review`). A type
with no row is **Same as Default**, and so is a task with no type.
`ReviewPolicy.agentRouting` resolves the row and routes by its value:

| Row value | A completed task |
|---|---|
| a named agent, `{"kind":"named","id":…,"name":…}` | `review`, held by that agent |
| Any reviewer, `anyReviewer` | `review`, held by the first usable role-matching reviewer |
| A person, `person` | `review`, waiting on a person, with no reason given |
| Accept without review, `acceptWithoutReview` | straight to `done`, as under `none` |

Any agent the project uses can be named, whatever its role says; the name is a
snapshot taken when it was chosen. If a named agent has since been deleted from
the roster, disabled, or dropped from the project, the task goes to a person
with a `progress` row naming the agent, the type row that named it (or the
project, for Default), and what happened to it — **never to
another agent**, since a silent substitute is what naming one exists to
prevent. The row is kept, not cleared, when the agent goes away, so the next
completion says the same thing.

Any reviewer is the pick every project had before the table existed: the
project's usable reviewers by `RosterAgent.isReviewer`
(`role.lowercased().contains("review")`, so "reviewer", "Reviewer" and "code
reviewer" all qualify), and `reviewers.first` — the first in
`project_roster_agent`'s own `ordering`. Settings written before the table held
a single `reviewAgent`; decoding puts it in the Default row (named stays named,
absent becomes Any reviewer) and every type row starts as Same as Default, so
no project routes differently on upgrade. `reviewAgent` is never written again.
A type row whose type or `kind` this build doesn't know is dropped, so that type
is Same as Default, and a Default row with an unknown `kind` reads as Any
reviewer; neither fails the rest of `settings_json`.
The table is read only under `agent`; the integration-task and shared-checkout
overrides (§5, §5.1) still apply over it, and there are no per-epic rows.

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

- **`manual`** archives nothing on its own; the Task Board's buttons are the
  only triggers — the toolbar's **Archive**, and a `done` epic lane's
  **Archive** (§10).
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
clock and the policy from scratch. A `done` epic lane's **Archive** runs the
same `ArchiveSweep.archiveEpic` as `afterEpicMerge`, so it too leaves a task a
human unarchived, and every task outside `done`, where it is. The picker for
the three modes lives in Project Settings, next to the day count it disables
outside `afterDays`; the Task Board's own archive controls are in §10.

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

### 4.1 Opening the database: newer-build refusal and launch backups

The database is `agentboard.sqlite` in the app support directory, or
`$AGENTBOARD_DB`. `AppDatabase.open` does two things before it migrates an
existing file, so they hold however the app was installed (DMG, hand copy,
`bundle.sh`):

- **Refuse a database from a newer build.** GRDB's migrator skips applied
  identifiers it does not register, so an older build would otherwise open a
  newer database silently and run against a schema it does not understand. If
  `grdb_migrations` holds any identifier this build does not register, open
  throws `AppDatabaseError.writtenByNewerBuild` before anything writes. The app
  shows a blocking alert saying the database was last used by a newer Agent
  Board, names the newest file in `backups/` if there is one, gives
  `sqlite3 '<db>' ".restore '<backup>'"` to restore it by hand, and quits.
- **Back up before a new build migrates.** The build is
  `CFBundleShortVersionString`, `CFBundleVersion` and `AgentBoardCommit` from the
  main bundle. A missing key is nil and equals only another nil, so relaunching
  one `bundle.sh` build (no commit) is not a new build, and `swift run` (no keys)
  is one build. When the build differs from the last one to open the database,
  or any registered migration is still pending, open copies the database with
  SQLite's online backup API into
  `backups/agentboard-<yyyyMMdd-HHmmss>-<version>[+<build>].sqlite` beside it.
  The label is the *previous* build's, the schema the copy fits;
  `unknown` when no build is recorded.
  The copy is written under a `.partial` name and renamed only once its page
  count matches the source, so an interrupted backup never carries a real name.
  Three are kept: the one just taken and the two newest others by name, so a
  clock set earlier than the existing stamps never prunes the new copy. A
  backup that fails or does not match stops the launch rather than migrating
  without one: open throws `AppDatabaseError.backupFailed`, and the app shows a
  blocking alert saying it did not open the board because it could not take a
  safe backup first, with the underlying error (a full disk, say) and the
  `backups/` path, and quits without writing to the database.

The last build to open the database is recorded in
`backups/last-opened-build.json` after migration succeeds, not in a table: a
migration list is pinned by tests and shared across branches, and the backup
name cannot hold it (it carries the previous build, and no commit). Nothing is
backed up when the file does not exist yet, for the in-memory database, or when
the caller passes no build — only the app passes one, so tests that open a
database under a temp path never write backups. A backup of the 293 MB board
took 1.3–1.5 s on this Mac, and it stays on the launch path.
