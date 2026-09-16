import Foundation
import XCTest
@testable import AgentBoardCore

struct Fixture {
    let db: AppDatabase
    let project: Project

    var projects: ProjectStore { ProjectStore(db) }
    var tasks: TaskStore { TaskStore(db) }
    var sessions: SessionStore { SessionStore(db) }
    var tokens: TokenGrantStore { TokenGrantStore(db) }
    var progress: ProgressStore { ProgressStore(db) }
    var reports: ReportStore { ReportStore(db) }
    var hooks: HookEventStore { HookEventStore(db) }
    var notes: NoteStore { NoteStore(db) }
    var board: Board { Board(db) }

    static func make() throws -> Fixture {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo",
            repoPath: "/tmp/demo-\(UUID().uuidString)",
            baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees",
            memoryDir: nil
        )
        return Fixture(db: db, project: project)
    }

    @discardableResult
    func task(_ title: String, column: TaskColumn = .backlog, origin: TaskOrigin = .human) throws -> BoardTask {
        try tasks.create(
            projectId: project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: column, origin: origin, epicId: nil
        )
    }

    func session(
        _ id: String = BoardId.new(), role: SessionRole = .worker, state: SessionState = .running,
        taskId: String? = nil, worktreePath: String? = nil, shortId: String? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: id, shortId: shortId, projectId: project.id, taskId: taskId, role: role,
            worktreePath: worktreePath, cwd: "/tmp", state: state
        )
    }
}
