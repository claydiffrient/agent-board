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

    static let tables: [String] = [
        "project", "epic", "task", "task_dep", "agent_session", "token_grant",
        "progress", "report", "note", "note_section", "note_link", "note_fts", "hook_event",
        "approval", "shutdown_order", "shutdown_delivery", "workspace", "file_lock", "message",
        "roster_agent", "project_roster_agent",
    ]
}
