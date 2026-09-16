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

    public func updateSettings(_ id: String, _ settings: ProjectSettings) throws {
        try db.writer.write { db in
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

    public func delete(_ id: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM project_roster_agent WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM shutdown_order WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM token_grant WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM report WHERE project_id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM progress WHERE task_id IN (SELECT id FROM task WHERE project_id = ?)",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM agent_session WHERE project_id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM task_dep WHERE task_id IN (SELECT id FROM task WHERE project_id = ?)",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM note_link WHERE note_id IN (SELECT id FROM note WHERE project_id = ?)",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM note_section WHERE note_id IN (SELECT id FROM note WHERE project_id = ?)",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM note WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM task WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM epic WHERE project_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [id])
        }
    }

    public func observeAll() -> ValueObservation<ValueReducers.Fetch<[Project]>> {
        ValueObservation.tracking { db in
            try Project.fetchAll(db, sql: "SELECT * FROM project ORDER BY name COLLATE NOCASE, created_at")
        }
    }
}
