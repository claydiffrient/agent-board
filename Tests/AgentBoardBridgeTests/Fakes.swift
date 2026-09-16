import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

actor RecordingEventSink: BoardEventSink {
    enum Event: Equatable {
        case notify(title: String, body: String)
        case orchestratorTurnEnded(projectId: String, sessionId: String)
        case reportQueued(projectId: String)
    }

    private(set) var events: [Event] = []

    func notify(title: String, body: String) async {
        events.append(.notify(title: title, body: body))
    }

    func orchestratorTurnEnded(projectId: String, sessionId: String) async {
        events.append(.orchestratorTurnEnded(projectId: projectId, sessionId: sessionId))
    }

    func reportQueued(projectId: String) async {
        events.append(.reportQueued(projectId: projectId))
    }
}

actor FakeWorkerControl: WorkerControl {
    private(set) var spawned: [String] = []
    private(set) var stopped: [String] = []
    private(set) var accepted: [(taskId: String, acceptedBy: TaskAcceptance)] = []
    /// Stands in for the supervisor: the bridge tests assert the board effects, and the supervisor's
    /// own side effects (grants, worktrees) are asserted in AgentBoardAppTests.
    private nonisolated let board: Board?

    init(board: Board? = nil) {
        self.board = board
    }

    func spawnWorker(taskId: String) async throws -> String {
        spawned.append(taskId)
        return "session-for-\(taskId)"
    }

    func stopWorker(sessionId: String) async throws {
        stopped.append(sessionId)
    }

    func accept(taskId: String, acceptedBy: TaskAcceptance) async throws {
        accepted.append((taskId, acceptedBy))
        try board?.accept(taskId: taskId, acceptedBy: acceptedBy)
    }
}

struct BridgeFixture {
    let db: AppDatabase
    let project: Project
    let events: RecordingEventSink
    let control: FakeWorkerControl
    let orchestrator: OrchestratorToolHandler
    let worker: WorkerToolHandler
    let reviewer: ReviewerToolHandler
    let scoped: ScopedToolHandler
    let hooks: StoreHookSink

    var projects: ProjectStore { ProjectStore(db) }
    var tasks: TaskStore { TaskStore(db) }
    var sessions: SessionStore { SessionStore(db) }
    var reports: ReportStore { ReportStore(db) }
    var approvals: ApprovalStore { ApprovalStore(db) }
    var notes: NoteStore { NoteStore(db) }
    var progress: ProgressStore { ProgressStore(db) }
    var board: Board { Board(db) }

    var orchestratorIdentity: TokenIdentity {
        TokenIdentity(token: "orch", scope: .orchestrator, projectId: project.id, sessionId: "orch-session")
    }

    static func make() throws -> BridgeFixture {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo",
            repoPath: "/tmp/demo-\(UUID().uuidString)",
            baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees",
            memoryDir: nil
        )
        let events = RecordingEventSink()
        let control = FakeWorkerControl(board: Board(db))
        let orchestrator = OrchestratorToolHandler(db: db, control: control, events: events)
        let worker = WorkerToolHandler(db: db, control: control, events: events)
        let reviewer = ReviewerToolHandler(db: db, control: control, events: events)
        return BridgeFixture(
            db: db,
            project: project,
            events: events,
            control: control,
            orchestrator: orchestrator,
            worker: worker,
            reviewer: reviewer,
            scoped: ScopedToolHandler(worker: worker, orchestrator: orchestrator, reviewer: reviewer),
            hooks: StoreHookSink(db: db, events: events)
        )
    }

    func otherProject() throws -> Project {
        try projects.register(
            name: "Other",
            repoPath: "/tmp/other-\(UUID().uuidString)",
            baseBranch: "main",
            worktreeRoot: "/tmp/other-worktrees",
            memoryDir: nil
        )
    }

    @discardableResult
    func task(_ title: String, column: TaskColumn = .backlog, in projectId: String? = nil) throws -> BoardTask {
        try tasks.create(
            projectId: projectId ?? project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: column, origin: .human, epicId: nil
        )
    }

    @discardableResult
    func session(
        _ id: String, role: SessionRole = .worker, state: SessionState = .running, taskId: String? = nil,
        worktreePath: String? = nil, shortId: String? = nil
    ) throws -> AgentSession {
        let session = AgentSession(
            sessionId: id, shortId: shortId, projectId: project.id, taskId: taskId, role: role,
            worktreePath: worktreePath, cwd: "/tmp", state: state
        )
        try sessions.insert(session)
        return session
    }

    @discardableResult
    func note(_ title: String, sections: [(heading: String, body: String)] = [], in projectId: String? = nil) throws -> Note {
        try notes.create(projectId: projectId ?? project.id, title: title, sections: sections)
    }

    @discardableResult
    func epic(_ title: String, in projectId: String? = nil) throws -> Epic {
        let epic = Epic(
            id: Epic.newId(), projectId: projectId ?? project.id, title: title, goal: nil,
            branch: "epic/\(title)", state: .active, createdAt: .nowMillis
        )
        try db.writer.write { db in try epic.insert(db) }
        return epic
    }

    func reviewerIdentity(sessionId: String, taskId: String?) -> TokenIdentity {
        TokenIdentity(
            token: "reviewer-\(sessionId)", scope: .reviewer, projectId: project.id,
            sessionId: sessionId, taskId: taskId
        )
    }

    func setReviewLevel(_ level: ReviewLevel) throws {
        var settings = project.settings
        settings.reviewLevel = level
        try projects.updateSettings(project.id, settings)
    }

    @discardableResult
    func rosterReviewer(_ name: String, role: String = "reviewer") throws -> RosterAgent {
        let roster = RosterStore(db)
        let agent = try roster.create(name: name, role: role, systemPrompt: "You review.")
        try roster.enable(agentId: agent.id, forProject: project.id)
        return agent
    }

    func workerIdentity(sessionId: String, taskId: String) -> TokenIdentity {
        TokenIdentity(token: "worker-\(sessionId)", scope: .worker, projectId: project.id, sessionId: sessionId, taskId: taskId)
    }

    func setAutonomy(_ enabled: Bool) throws {
        var settings = project.settings
        settings.autonomyEnabled = enabled
        try projects.updateSettings(project.id, settings)
    }

    func call(_ name: String, _ arguments: [String: JSONValue] = [:], as identity: TokenIdentity? = nil) async throws -> ToolResult {
        try await scoped.call(name, arguments: .object(arguments), identity: identity ?? orchestratorIdentity)
    }

    func callJSON(_ name: String, _ arguments: [String: JSONValue] = [:], as identity: TokenIdentity? = nil) async throws -> JSONValue {
        let result = try await call(name, arguments, as: identity)
        return try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    @discardableResult
    func hook(_ name: String, sessionId: String, identity: TokenIdentity, lastAssistantMessage: String? = nil) async -> HookDecision? {
        let event = HookEvent(name: name, sessionId: sessionId, lastAssistantMessage: lastAssistantMessage, rawJSON: "{}")
        return await hooks.handle(event, identity: identity)
    }

    func preToolUse(_ command: String, sessionId: String, identity: TokenIdentity, tool: String = "Bash") async -> HookDecision? {
        let event = HookEvent(name: "PreToolUse", sessionId: sessionId, toolName: tool, toolCommand: command, rawJSON: "{}")
        return await hooks.handle(event, identity: identity)
    }
}

func XCTAssertToolError<T>(
    _ expression: @autoclosure () async throws -> T,
    containing fragment: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected ToolError", file: file, line: line)
    } catch let error as ToolError {
        if let fragment {
            XCTAssertTrue(error.message.contains(fragment), "\"\(error.message)\" does not contain \"\(fragment)\"", file: file, line: line)
        }
    } catch {
        XCTFail("Expected ToolError, got \(error)", file: file, line: line)
    }
}
