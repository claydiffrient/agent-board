import Foundation
import GRDB

public struct ProjectStore: Sendable {
    let db: AppDatabase

    public init(_ db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func register(name: String, repoPath: String, baseBranch: String, worktreeRoot: String, memoryDir: String?) throws -> Project {
        try WorktreeRootRule.validate(worktreeRoot)
        let project = Project(
            id: Project.newId(),
            name: name,
            repoPath: repoPath,
            baseBranch: baseBranch,
            worktreeRoot: worktreeRoot,
            memoryDir: memoryDir,
            orchSessionId: nil,
            settingsJSON: ProjectSettings.forNewProject().encoded(),
            createdAt: .nowMillis
        )
        try db.writer.write { db in
            try project.insert(db)
        }
        return project
    }

    public func list() throws -> [Project] {
        try db.reader.read { db in
            try Project.fetchAll(db, sql: "SELECT * FROM project ORDER BY name COLLATE NOCASE, created_at")
        }
    }

    public func get(_ id: String) throws -> Project? {
        try db.reader.read { db in
            try Project.fetchOne(db, key: id)
        }
    }

    public func byRepoPath(_ path: String) throws -> Project? {
        try db.reader.read { db in
            try Project.fetchOne(db, sql: "SELECT * FROM project WHERE repo_path = ?", arguments: [path])
        }
    }

    public func updateSettings(_ id: String, _ settings: ProjectSettings, now: Int64 = .nowMillis) throws {
        try db.writer.write { db in
            var settings = settings
            let stored = try Project.fetchOne(db, key: id)?.settings.prFollowThrough
            let replies = settings.prFollowThrough.postFactualReplies
            settings.prFollowThrough.postFactualRepliesSince = !replies ? nil
                : stored?.postFactualReplies == true ? stored?.postFactualRepliesSince : now
            try db.execute(
                sql: "UPDATE project SET settings_json = ? WHERE id = ?",
                arguments: [settings.encoded(), id]
            )
        }
    }

    public func setOrchestratorSession(_ id: String, sessionId: String?) throws {
        try db.writer.write { db in
            try db.execute(
                sql: "UPDATE project SET orch_session_id = ? WHERE id = ?",
                arguments: [sessionId, id]
            )
        }
    }

    /// Every foreign key into a project's rows is `NO ACTION`, so each referencing row is deleted or
    /// unlinked here first, including other projects' rows that point at this one (SPEC §4).
    public func delete(_ id: String) throws {
        let tasks = "SELECT id FROM task WHERE project_id = :id"
        let epics = "SELECT id FROM epic WHERE project_id = :id"
        let sessions = "SELECT session_id FROM agent_session WHERE project_id = :id"
        let notes = "SELECT id FROM note WHERE project_id = :id"
        let reports = "SELECT id FROM report WHERE project_id = :id OR task_id IN (\(tasks))"
        try db.writer.write { db in
            func run(_ sql: String) throws {
                try db.execute(sql: sql, arguments: ["id": id])
            }
            try run("DELETE FROM project_roster_agent WHERE project_id = :id")
            try run("DELETE FROM shutdown_delivery WHERE order_id IN (SELECT id FROM shutdown_order WHERE project_id = :id)")
            try run("DELETE FROM shutdown_order WHERE project_id = :id")
            try run("DELETE FROM approval WHERE project_id = :id OR task_id IN (\(tasks)) OR epic_id IN (\(epics))")
            try run("DELETE FROM message WHERE from_project_id = :id OR to_project_id = :id")
            try run("UPDATE message SET from_session_id = NULL WHERE from_session_id IN (\(sessions))")
            try run("UPDATE message SET report_id = NULL WHERE report_id IN (\(reports))")
            try run("UPDATE coordinator SET active_session_id = NULL WHERE active_session_id IN (\(sessions))")
            try run("DELETE FROM token_grant WHERE project_id = :id")
            try run("UPDATE token_grant SET session_id = NULL WHERE session_id IN (\(sessions))")
            try run("DELETE FROM report WHERE project_id = :id OR task_id IN (\(tasks))")
            try run("UPDATE report SET session_id = NULL WHERE session_id IN (\(sessions))")
            try run("DELETE FROM file_lock WHERE project_id = :id")
            try run("DELETE FROM progress WHERE task_id IN (\(tasks))")
            try run("UPDATE progress SET session_id = NULL WHERE session_id IN (\(sessions))")
            try run("DELETE FROM agent_session WHERE project_id = :id")
            try run("UPDATE agent_session SET task_id = NULL WHERE task_id IN (\(tasks))")
            try run("DELETE FROM task_dep WHERE task_id IN (\(tasks)) OR depends_on IN (\(tasks))")
            try run("DELETE FROM note_link WHERE note_id IN (\(notes)) OR task_id IN (\(tasks)) OR epic_id IN (\(epics))")
            for noteId in try String.fetchAll(db, sql: notes, arguments: ["id": id]) {
                try NoteStore.unindex(db, noteId: noteId)
            }
            try run("DELETE FROM note_section WHERE note_id IN (\(notes))")
            try run("DELETE FROM note WHERE project_id = :id")
            try run("DELETE FROM task_comment WHERE project_id = :id")
            try run("UPDATE task SET epic_id = NULL WHERE epic_id IN (\(epics))")
            try run("DELETE FROM task WHERE project_id = :id")
            try run("DELETE FROM epic WHERE project_id = :id")
            try run("DELETE FROM project WHERE id = :id")
        }
    }

    public func observeAll() -> ValueObservation<ValueReducers.Fetch<[Project]>> {
        ValueObservation.tracking { db in
            try Project.fetchAll(db, sql: "SELECT * FROM project ORDER BY name COLLATE NOCASE, created_at")
        }
    }
}
