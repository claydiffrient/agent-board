enum Schema {
    static let v1 = """
    CREATE TABLE project (
      id              TEXT PRIMARY KEY,
      name            TEXT NOT NULL,
      repo_path       TEXT NOT NULL UNIQUE,
      base_branch     TEXT NOT NULL DEFAULT 'main',
      worktree_root   TEXT NOT NULL,
      memory_dir      TEXT,
      orch_session_id TEXT,
      settings_json   TEXT NOT NULL,
      created_at      INTEGER NOT NULL
    );

    CREATE TABLE epic (
      id             TEXT PRIMARY KEY,
      project_id     TEXT NOT NULL REFERENCES project(id),
      title          TEXT NOT NULL,
      goal           TEXT,
      branch         TEXT NOT NULL,
      state          TEXT NOT NULL,
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
      column_name    TEXT NOT NULL,
      blocked        INTEGER NOT NULL DEFAULT 0,
      blocked_reason TEXT,
      failed         INTEGER NOT NULL DEFAULT 0,
      failure_reason TEXT,
      ordering       REAL NOT NULL,
      origin         TEXT NOT NULL,
      created_at     INTEGER NOT NULL,
      updated_at     INTEGER NOT NULL
    );

    CREATE TABLE task_dep (
      task_id     TEXT NOT NULL REFERENCES task(id),
      depends_on  TEXT NOT NULL REFERENCES task(id),
      PRIMARY KEY (task_id, depends_on)
    );

    CREATE TABLE agent_session (
      session_id     TEXT PRIMARY KEY,
      short_id       TEXT,
      project_id     TEXT NOT NULL REFERENCES project(id),
      task_id        TEXT REFERENCES task(id),
      role           TEXT NOT NULL,
      worktree_path  TEXT,
      branch         TEXT,
      cwd            TEXT NOT NULL,
      state          TEXT NOT NULL,
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
      token       TEXT PRIMARY KEY,
      session_id  TEXT REFERENCES agent_session(session_id),
      project_id  TEXT NOT NULL REFERENCES project(id),
      scope       TEXT NOT NULL,
      task_id     TEXT,
      created_at  INTEGER NOT NULL,
      revoked_at  INTEGER
    );

    CREATE TABLE progress (
      id          INTEGER PRIMARY KEY,
      task_id     TEXT NOT NULL REFERENCES task(id),
      session_id  TEXT REFERENCES agent_session(session_id),
      at          INTEGER NOT NULL,
      kind        TEXT NOT NULL,
      text        TEXT NOT NULL
    );

    CREATE TABLE report (
      id          INTEGER PRIMARY KEY,
      project_id  TEXT NOT NULL REFERENCES project(id),
      task_id     TEXT REFERENCES task(id),
      session_id  TEXT REFERENCES agent_session(session_id),
      kind        TEXT NOT NULL,
      body        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      consumed_at INTEGER
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

    CREATE INDEX task_project_column ON task(project_id, column_name);
    CREATE INDEX agent_session_project_state ON agent_session(project_id, state);
    CREATE INDEX agent_session_task ON agent_session(task_id);
    CREATE INDEX token_grant_session ON token_grant(session_id);
    CREATE INDEX report_project_consumed ON report(project_id, consumed_at);
    CREATE INDEX progress_task_at ON progress(task_id, at);
    CREATE INDEX hook_event_session_at ON hook_event(session_id, at);
    """

    static let approval = """
    CREATE TABLE approval (
      id           TEXT PRIMARY KEY,
      project_id   TEXT NOT NULL REFERENCES project(id),
      kind         TEXT NOT NULL,
      task_id      TEXT REFERENCES task(id),
      epic_id      TEXT REFERENCES epic(id),
      requested_by TEXT NOT NULL,
      reason       TEXT,
      created_at   INTEGER NOT NULL,
      resolved_at  INTEGER,
      resolution   TEXT
    );
    CREATE INDEX approval_pending ON approval(project_id, resolved_at);
    """

    static let roster = """
    CREATE TABLE roster_agent (
      id               TEXT PRIMARY KEY,
      name             TEXT NOT NULL,
      role             TEXT NOT NULL,
      system_prompt    TEXT NOT NULL,
      model            TEXT,
      disallowed_tools TEXT NOT NULL DEFAULT '[]',
      enabled          INTEGER NOT NULL DEFAULT 1,
      created_at       INTEGER NOT NULL,
      updated_at       INTEGER NOT NULL
    );

    CREATE TABLE project_roster_agent (
      project_id      TEXT NOT NULL REFERENCES project(id),
      roster_agent_id TEXT NOT NULL REFERENCES roster_agent(id),
      ordering        REAL NOT NULL,
      PRIMARY KEY (project_id, roster_agent_id)
    );
    CREATE INDEX project_roster_agent_order ON project_roster_agent(project_id, ordering);
    """

    /// Split from `roster` rather than folded into it: `roster` is already merged, and GRDB skips a
    /// migration whose identifier is recorded, so rewriting one that has shipped can never re-run.
    static let rosterAssignment = """
    ALTER TABLE agent_session ADD COLUMN roster_agent_id TEXT REFERENCES roster_agent(id);
    ALTER TABLE task ADD COLUMN roster_agent_id TEXT REFERENCES roster_agent(id);
    """

    /// `epic.review_level` is nullable on purpose: NULL means "inherit the project's level", which is
    /// what every epic that predates the setting has.
    static let reviewLevel = """
    ALTER TABLE epic ADD COLUMN review_level TEXT;
    ALTER TABLE task ADD COLUMN reviewer_agent_id TEXT REFERENCES roster_agent(id);
    """

    static let approvalPayload = """
    ALTER TABLE approval ADD COLUMN payload TEXT;
    """

    static let shutdownOrder = """
    CREATE TABLE shutdown_order (
      id           TEXT PRIMARY KEY,
      project_id   TEXT NOT NULL REFERENCES project(id),
      requested_by TEXT NOT NULL,
      reason       TEXT,
      requested_at INTEGER NOT NULL,
      resolved_at  INTEGER,
      resolved_by  TEXT
    );
    CREATE INDEX shutdown_order_outstanding ON shutdown_order(project_id, resolved_at);
    """

    static let shutdownDelivery = """
    CREATE TABLE shutdown_delivery (
      order_id        TEXT NOT NULL REFERENCES shutdown_order(id),
      session_id      TEXT NOT NULL,
      task_id         TEXT,
      ordered_at      INTEGER NOT NULL,
      delivered_at    INTEGER,
      delivered_via   TEXT,
      acknowledged_at INTEGER,
      note            TEXT,
      PRIMARY KEY (order_id, session_id)
    );
    CREATE INDEX shutdown_delivery_session ON shutdown_delivery(session_id);
    """

    static let workspace = """
    CREATE TABLE workspace (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      ordering   REAL NOT NULL,
      created_at INTEGER NOT NULL
    );

    ALTER TABLE project ADD COLUMN workspace_id TEXT REFERENCES workspace(id);
    """

    static let fileLock = """
    CREATE TABLE file_lock (
      project_id TEXT NOT NULL REFERENCES project(id),
      path       TEXT NOT NULL,
      session_id TEXT NOT NULL,
      task_id    TEXT,
      held_since INTEGER NOT NULL,
      PRIMARY KEY (project_id, path)
    );
    CREATE INDEX file_lock_session ON file_lock(session_id);

    ALTER TABLE agent_session ADD COLUMN blocked_on_path TEXT;
    """

    static let message = """
    CREATE TABLE message (
      id              INTEGER PRIMARY KEY,
      from_project_id TEXT NOT NULL REFERENCES project(id),
      to_project_id   TEXT NOT NULL REFERENCES project(id),
      from_session_id TEXT REFERENCES agent_session(session_id),
      body            TEXT NOT NULL,
      created_at      INTEGER NOT NULL,
      delivered_at    INTEGER,
      report_id       INTEGER REFERENCES report(id)
    );
    CREATE INDEX message_to_project_delivered ON message(to_project_id, delivered_at);
    """

    /// `project_id` becomes nullable on both tables (SQLite cannot drop NOT NULL in place, so each is
    /// rebuilt). A NULL grant is the Coordinator's and nothing else's; a NULL report is in its queue.
    static let coordinator = """
    CREATE TABLE token_grant_new (
      token       TEXT PRIMARY KEY,
      session_id  TEXT REFERENCES agent_session(session_id),
      project_id  TEXT REFERENCES project(id),
      scope       TEXT NOT NULL,
      task_id     TEXT,
      created_at  INTEGER NOT NULL,
      revoked_at  INTEGER,
      CHECK ((scope = 'coordinator') = (project_id IS NULL))
    );
    INSERT INTO token_grant_new (token, session_id, project_id, scope, task_id, created_at, revoked_at)
      SELECT token, session_id, project_id, scope, task_id, created_at, revoked_at FROM token_grant;
    DROP TABLE token_grant;
    ALTER TABLE token_grant_new RENAME TO token_grant;
    CREATE INDEX token_grant_session ON token_grant(session_id);

    CREATE TABLE report_new (
      id          INTEGER PRIMARY KEY,
      project_id  TEXT REFERENCES project(id),
      task_id     TEXT REFERENCES task(id),
      session_id  TEXT REFERENCES agent_session(session_id),
      kind        TEXT NOT NULL,
      body        TEXT NOT NULL,
      created_at  INTEGER NOT NULL,
      consumed_at INTEGER
    );
    INSERT INTO report_new (id, project_id, task_id, session_id, kind, body, created_at, consumed_at)
      SELECT id, project_id, task_id, session_id, kind, body, created_at, consumed_at FROM report;
    DROP TABLE report;
    ALTER TABLE report_new RENAME TO report;
    CREATE INDEX report_project_consumed ON report(project_id, consumed_at);
    """

    /// `note.project_id` becomes nullable: a NULL note is one of the Coordinator's plans (SPEC §8.2).
    /// Rowids are copied, not reassigned, because `note_fts` is keyed to them and holds no text of its own.
    static let coordinatorNotes = """
    CREATE TABLE note_new (
      id          TEXT PRIMARY KEY,
      project_id  TEXT REFERENCES project(id),
      title       TEXT NOT NULL,
      pinned      INTEGER NOT NULL DEFAULT 0,
      version     INTEGER NOT NULL DEFAULT 1,
      updated_at  INTEGER NOT NULL
    );
    INSERT INTO note_new (rowid, id, project_id, title, pinned, version, updated_at)
      SELECT rowid, id, project_id, title, pinned, version, updated_at FROM note;
    DROP TABLE note;
    ALTER TABLE note_new RENAME TO note;
    """

    /// The Coordinator's session gets a row with no project, so hooks can bind its grant and the
    /// metering tick can read its spend (SPEC §8.2). `coordinator` is its one row of state: the
    /// session it resumes and the model it runs on, NULL for Claude Code's default.
    static let coordinatorSession = """
    CREATE TABLE agent_session_new (
      session_id      TEXT PRIMARY KEY,
      short_id        TEXT,
      project_id      TEXT REFERENCES project(id),
      task_id         TEXT REFERENCES task(id),
      role            TEXT NOT NULL,
      worktree_path   TEXT,
      branch          TEXT,
      cwd             TEXT NOT NULL,
      state           TEXT NOT NULL,
      started_at      INTEGER NOT NULL,
      ended_at        INTEGER,
      last_activity   INTEGER,
      transcript_path TEXT,
      tokens_in       INTEGER NOT NULL DEFAULT 0,
      tokens_out      INTEGER NOT NULL DEFAULT 0,
      cache_read      INTEGER NOT NULL DEFAULT 0,
      cache_write     INTEGER NOT NULL DEFAULT 0,
      est_cost_usd    REAL NOT NULL DEFAULT 0,
      attempt         INTEGER NOT NULL DEFAULT 1,
      model           TEXT,
      last_tool       TEXT,
      stop_reason     TEXT,
      roster_agent_id TEXT REFERENCES roster_agent(id),
      blocked_on_path TEXT,
      tool_started_at INTEGER,
      tools_in_flight INTEGER NOT NULL DEFAULT 0,
      review_head     TEXT,
      CHECK ((role = 'coordinator') = (project_id IS NULL))
    );
    INSERT INTO agent_session_new
      SELECT session_id, short_id, project_id, task_id, role, worktree_path, branch, cwd, state,
             started_at, ended_at, last_activity, transcript_path, tokens_in, tokens_out, cache_read,
             cache_write, est_cost_usd, attempt, model, last_tool, stop_reason, roster_agent_id,
             blocked_on_path, tool_started_at, tools_in_flight, review_head
      FROM agent_session;
    DROP TABLE agent_session;
    ALTER TABLE agent_session_new RENAME TO agent_session;
    CREATE INDEX agent_session_project_state ON agent_session(project_id, state);
    CREATE INDEX agent_session_task ON agent_session(task_id);

    CREATE TABLE coordinator (
      id                INTEGER PRIMARY KEY CHECK (id = 1),
      active_session_id TEXT REFERENCES agent_session(session_id),
      model             TEXT
    );
    INSERT INTO coordinator (id) VALUES (1);
    """

    static let taskCommit = """
    CREATE TABLE task_commit (
      task_id TEXT NOT NULL,
      sha     TEXT NOT NULL,
      PRIMARY KEY (task_id, sha)
    );
    CREATE INDEX task_commit_sha ON task_commit(sha);
    """

    /// `author_session_id` is deliberately not a foreign key: `ProjectStore.delete` removes sessions
    /// before tasks, and the cascade from `task` is what removes a project's comments.
    static let taskComment = """
    CREATE TABLE task_comment (
      id                     INTEGER PRIMARY KEY,
      task_id                TEXT NOT NULL REFERENCES task(id) ON DELETE CASCADE,
      project_id             TEXT NOT NULL REFERENCES project(id),
      author_kind            TEXT NOT NULL,
      author_session_id      TEXT,
      author_roster_agent_id TEXT REFERENCES roster_agent(id) ON DELETE SET NULL,
      author_name            TEXT NOT NULL,
      body                   TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND \(TaskComment.maxBodyLength)),
      created_at             INTEGER NOT NULL
    );
    CREATE INDEX task_comment_task_created ON task_comment(task_id, created_at);
    """

    /// Human comments waiting for a live session's next `PostToolUse` (SPEC §7). A row goes when it
    /// is delivered, when its session ends, or with its session or comment.
    static let commentDelivery = """
    CREATE TABLE comment_delivery (
      session_id TEXT NOT NULL REFERENCES agent_session(session_id) ON DELETE CASCADE,
      comment_id INTEGER NOT NULL REFERENCES task_comment(id) ON DELETE CASCADE,
      PRIMARY KEY (session_id, comment_id)
    );
    """

    /// The Coordinator's request ledger (SPEC §9.4). `plan_note_id` has no foreign key: a plan note
    /// lives in the Coordinator's own note space and need not exist yet. `request_event` is the
    /// history — the send, each reply, a withdrawal — with the report each one queued.
    static let coordinatorRequest = """
    CREATE TABLE coordinator_request (
      id           INTEGER PRIMARY KEY,
      project_id   TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      body         TEXT NOT NULL,
      plan_note_id TEXT,
      state        TEXT NOT NULL,
      created_at   INTEGER NOT NULL,
      closed_at    INTEGER
    );
    CREATE INDEX coordinator_request_closed ON coordinator_request(closed_at);

    CREATE TABLE request_event (
      id         INTEGER PRIMARY KEY,
      request_id INTEGER NOT NULL REFERENCES coordinator_request(id) ON DELETE CASCADE,
      state      TEXT NOT NULL,
      author     TEXT NOT NULL,
      body       TEXT NOT NULL,
      report_id  INTEGER REFERENCES report(id) ON DELETE SET NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX request_event_request ON request_event(request_id);
    CREATE INDEX request_event_report ON request_event(report_id);

    CREATE TABLE request_epic (
      request_id INTEGER NOT NULL REFERENCES coordinator_request(id) ON DELETE CASCADE,
      epic_id    TEXT NOT NULL REFERENCES epic(id) ON DELETE CASCADE,
      PRIMARY KEY (request_id, epic_id)
    );
    """

    /// SPEC §8.6. The trigger, not each writer, clears the mark, so no revival path can forget to.
    /// A rebuild of `agent_session` drops it and must recreate it.
    static var sessionAgentStoppedAt: String {
        """
        ALTER TABLE agent_session ADD COLUMN agent_stopped_at INTEGER;

        CREATE TRIGGER agent_session_alive_again
        AFTER UPDATE OF state, last_activity ON agent_session
        WHEN NEW.agent_stopped_at IS NOT NULL
          AND (NEW.state IN (\(SessionStore.activeStatesSQL)) OR NEW.last_activity > NEW.agent_stopped_at)
        BEGIN
          UPDATE agent_session SET agent_stopped_at = NULL WHERE session_id = NEW.session_id;
        END;
        """
    }

    static let taskClosed = """
    ALTER TABLE task ADD COLUMN closed_at INTEGER;
    ALTER TABLE task ADD COLUMN closed_reason TEXT;
    ALTER TABLE task ADD COLUMN closed_by TEXT;
    """

    /// PR follow-through (SPEC §4). Items are keyed by GitHub node id so a poll is idempotent.
    static let prFollowThrough = """
    CREATE TABLE pr_watch (
      id               TEXT PRIMARY KEY,
      project_id       TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      repo_owner       TEXT NOT NULL,
      repo_name        TEXT NOT NULL,
      number           INTEGER NOT NULL,
      url              TEXT NOT NULL,
      title            TEXT NOT NULL,
      is_draft         INTEGER NOT NULL DEFAULT 0,
      head_ref         TEXT NOT NULL,
      head_oid         TEXT NOT NULL,
      base_ref         TEXT NOT NULL,
      state            TEXT NOT NULL,
      round            INTEGER NOT NULL DEFAULT 0,
      review_decision  TEXT,
      checks_state     TEXT,
      mergeable        TEXT,
      labels_json      TEXT NOT NULL DEFAULT '[]',
      paused           INTEGER NOT NULL DEFAULT 0,
      last_polled_at   INTEGER,
      last_feedback_at INTEGER,
      verified_at      INTEGER,
      est_cost_usd     REAL NOT NULL DEFAULT 0,
      created_at       INTEGER NOT NULL,
      updated_at       INTEGER NOT NULL,
      UNIQUE (project_id, repo_owner, repo_name, number)
    );
    CREATE INDEX pr_watch_state ON pr_watch(state);

    CREATE TABLE pr_item (
      id                    INTEGER PRIMARY KEY,
      watch_id              TEXT NOT NULL REFERENCES pr_watch(id) ON DELETE CASCADE,
      github_node_id        TEXT NOT NULL,
      kind                  TEXT NOT NULL,
      author                TEXT,
      body                  TEXT NOT NULL,
      path                  TEXT,
      line                  INTEGER,
      url                   TEXT,
      state                 TEXT NOT NULL,
      verdict               TEXT,
      approach              TEXT,
      decision_question     TEXT,
      decision_options_json TEXT,
      decision_answer       TEXT,
      fix_task_id           TEXT REFERENCES task(id) ON DELETE SET NULL,
      followup_grade        TEXT,
      reply_body            TEXT,
      reply_url             TEXT,
      round                 INTEGER NOT NULL DEFAULT 0,
      created_at            INTEGER NOT NULL,
      updated_at            INTEGER NOT NULL,
      UNIQUE (watch_id, github_node_id)
    );
    CREATE INDEX pr_item_watch_state ON pr_item(watch_id, state);

    CREATE TABLE pr_round (
      id              INTEGER PRIMARY KEY,
      watch_id        TEXT NOT NULL REFERENCES pr_watch(id) ON DELETE CASCADE,
      number          INTEGER NOT NULL,
      base_head_oid   TEXT NOT NULL,
      pushed_head_oid TEXT,
      outcome         TEXT,
      started_at      INTEGER NOT NULL,
      ended_at        INTEGER,
      UNIQUE (watch_id, number)
    );
    """

    /// One row per enabled project whose last PR poll could not run `gh` (SPEC §13.1).
    static let prPollProblem = """
    CREATE TABLE pr_poll_problem (
      project_id TEXT PRIMARY KEY REFERENCES project(id) ON DELETE CASCADE,
      detail     TEXT NOT NULL,
      since      INTEGER NOT NULL
    );
    """

    /// When a watched PR's head last moved, and the head whose Ready to verify banner already fired.
    static let prWatchHead = """
    ALTER TABLE pr_watch ADD COLUMN head_changed_at INTEGER;
    ALTER TABLE pr_watch ADD COLUMN ready_notified_oid TEXT;
    """

    /// The task a triager session is bound to, the watch it triages, and the diff it was given.
    static let prTriage = """
    CREATE TABLE pr_triage (
      task_id    TEXT PRIMARY KEY REFERENCES task(id) ON DELETE CASCADE,
      watch_id   TEXT NOT NULL REFERENCES pr_watch(id) ON DELETE CASCADE,
      base_oid   TEXT NOT NULL,
      head_oid   TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX pr_triage_watch ON pr_triage(watch_id);
    """

    /// The round each triage was spawned for, and why a watch is parked.
    static let prTriageRound = """
    ALTER TABLE pr_triage ADD COLUMN round INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE pr_watch ADD COLUMN parked_reason TEXT;
    """

    static let prItemDecisionNotified = """
    ALTER TABLE pr_item ADD COLUMN decision_notified_at INTEGER;
    """

    /// The fixer task a round's fix items went to.
    static let prRoundFixTask = """
    ALTER TABLE pr_round ADD COLUMN fix_task_id TEXT REFERENCES task(id) ON DELETE SET NULL;
    """

    /// A round's check (SPEC §13.1): the reviewer's verdict, the follow-up check task, the head they
    /// judged, how many checks have failed, and each item's grade note.
    static let prRoundCheck = """
    ALTER TABLE pr_round ADD COLUMN check_failures INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE pr_round ADD COLUMN review_verdict TEXT;
    ALTER TABLE pr_round ADD COLUMN review_findings TEXT;
    ALTER TABLE pr_round ADD COLUMN followup_task_id TEXT REFERENCES task(id) ON DELETE SET NULL;
    ALTER TABLE pr_round ADD COLUMN checked_head_oid TEXT;
    ALTER TABLE pr_item ADD COLUMN followup_note TEXT;
    """

    /// When an item became handled, which bounds the replies turning `postFactualReplies` on may post,
    /// and the last failed post, with when one was given up on (SPEC §13.2).
    static let prItemReplyBounds = """
    ALTER TABLE pr_item ADD COLUMN handled_at INTEGER;
    ALTER TABLE pr_item ADD COLUMN reply_error TEXT;
    ALTER TABLE pr_item ADD COLUMN reply_abandoned_at INTEGER;
    """

    /// When the human last resumed a parked watch (SPEC §13.1).
    static let prWatchResumed = """
    ALTER TABLE pr_watch ADD COLUMN resumed_at INTEGER;
    """

    /// One row per pooled worktree slot that has ever been leased (SPEC §3.1 step 2, §4).
    static let worktreeSlot = """
    CREATE TABLE worktree_slot (
      project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
      slot       INTEGER NOT NULL,
      task_id    TEXT,
      leased_at  INTEGER,
      PRIMARY KEY (project_id, slot)
    );
    CREATE UNIQUE INDEX worktree_slot_task ON worktree_slot(task_id) WHERE task_id IS NOT NULL;
    """

    static let tables: [String] = [
        "project", "epic", "task", "task_dep", "agent_session", "token_grant",
        "progress", "report", "note", "note_section", "note_link", "note_fts", "hook_event",
        "approval", "shutdown_order", "shutdown_delivery", "workspace", "file_lock", "message",
        "task_commit",
        "roster_agent", "project_roster_agent", "task_comment", "comment_delivery", "coordinator",
        "coordinator_request", "request_event", "request_epic", "pr_watch", "pr_item", "pr_round",
        "pr_poll_problem", "pr_triage", "worktree_slot",
    ]
}
