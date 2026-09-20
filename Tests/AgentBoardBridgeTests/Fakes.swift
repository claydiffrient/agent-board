import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

actor RecordingEventSink: BoardEventSink {
    enum Event: Equatable {
        case notify(projectId: String, title: String, body: String)
        case orchestratorTurnEnded(projectId: String, sessionId: String)
        case reportQueued(projectId: String)
        case orchestratorCompacted(projectId: String, sessionId: String, manual: Bool)
        case workerAcknowledgedShutdown(projectId: String, sessionId: String)
        case workerCompleted(projectId: String, sessionId: String)
    }

    private(set) var events: [Event] = []

    func notify(projectId: String, title: String, body: String) async {
        events.append(.notify(projectId: projectId, title: title, body: body))
    }

    func orchestratorTurnEnded(projectId: String, sessionId: String) async {
        events.append(.orchestratorTurnEnded(projectId: projectId, sessionId: sessionId))
    }

    func reportQueued(projectId: String) async {
        events.append(.reportQueued(projectId: projectId))
    }

    func orchestratorCompacted(projectId: String, sessionId: String, manual: Bool) async {
        events.append(.orchestratorCompacted(projectId: projectId, sessionId: sessionId, manual: manual))
    }

    func workerAcknowledgedShutdown(projectId: String, sessionId: String) async {
        events.append(.workerAcknowledgedShutdown(projectId: projectId, sessionId: sessionId))
    }

    func workerCompleted(projectId: String, sessionId: String) async {
        events.append(.workerCompleted(projectId: projectId, sessionId: sessionId))
    }
}

actor FakeWorkerControl: WorkerControl {
    private(set) var spawned: [String] = []
    private(set) var assigned: [(taskId: String, rosterAgentId: String, scope: AgentBoardCore.TokenScope)] = []
    private(set) var stopped: [String] = []
    /// Set to make `assignAgent` throw, which is how the reviewer-spawn failure path is driven.
    var assignFailure: Error?
    private(set) var accepted: [(taskId: String, acceptedBy: TaskAcceptance)] = []
    /// Stands in for the supervisor: the bridge tests assert the board effects, and the supervisor's
    /// own side effects (grants, worktrees) are asserted in AgentBoardAppTests.
    private nonisolated let board: Board?

    init(board: Board? = nil) {
        self.board = board
    }

    func spawnWorker(taskId: String) async throws -> WorkerSpawn {
        spawned.append(taskId)
        return WorkerSpawn(
            setupSessionId: "setup-for-\(taskId)",
            worktreePath: "/tmp/worktrees/\(taskId)",
            branch: "agentboard/\(taskId)"
        )
    }

    func assignAgent(
        taskId: String, rosterAgentId: String, scope: AgentBoardCore.TokenScope
    ) async throws -> WorkerSpawn {
        if let assignFailure { throw assignFailure }
        assigned.append((taskId, rosterAgentId, scope))
        return WorkerSpawn(
            setupSessionId: "setup-for-\(taskId)-\(rosterAgentId)",
            worktreePath: "/tmp/worktrees/\(taskId)",
            branch: "agentboard/\(taskId)"
        )
    }

    func setAssignFailure(_ error: Error?) {
        assignFailure = error
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
    var commits: RecordingScopedCommits?

    var projects: ProjectStore { ProjectStore(db) }
    var tasks: TaskStore { TaskStore(db) }
    var sessions: SessionStore { SessionStore(db) }
    var reports: ReportStore { ReportStore(db) }
    var approvals: ApprovalStore { ApprovalStore(db) }
    var notes: NoteStore { NoteStore(db) }
    var progress: ProgressStore { ProgressStore(db) }
    var hookEvents: HookEventStore { HookEventStore(db) }
    var board: Board { Board(db) }

    var orchestratorIdentity: TokenIdentity {
        TokenIdentity(token: "orch", scope: .orchestrator, projectId: project.id, sessionId: "orch-session")
    }

    static func make(
        lockWait: FileLockWaitPolicy = .default, scopedCommits: RecordingScopedCommits? = nil
    ) throws -> BridgeFixture {
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
        let worker = WorkerToolHandler(db: db, control: control, events: events, scopedCommits: scopedCommits)
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
            hooks: StoreHookSink(db: db, events: events, lockWait: lockWait),
            commits: scopedCommits
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
    func task(
        _ title: String, column: TaskColumn = .backlog, epicId: String? = nil, in projectId: String? = nil
    ) throws -> BoardTask {
        try tasks.create(
            projectId: projectId ?? project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: column, origin: .human, epicId: epicId
        )
    }

    @discardableResult
    func session(
        _ id: String, role: SessionRole = .worker, state: SessionState = .running, taskId: String? = nil,
        worktreePath: String? = nil, shortId: String? = nil, cwd: String? = nil, branch: String? = nil
    ) throws -> AgentSession {
        let session = AgentSession(
            sessionId: id, shortId: shortId, projectId: project.id, taskId: taskId, role: role,
            worktreePath: worktreePath, branch: branch, cwd: cwd ?? worktreePath ?? "/tmp", state: state
        )
        try sessions.insert(session)
        return session
    }

    /// A worker co-resident in the project's own checkout: no worktree, standing in the repo.
    @discardableResult
    func sharedSession(
        _ id: String, taskId: String, state: SessionState = .running,
        branch: String = SharedCheckoutGroup.branch(epicId: nil)
    ) throws -> AgentSession {
        try session(id, role: .worker, state: state, taskId: taskId, cwd: project.repoPath, branch: branch)
    }

    /// A worker in its own worktree, recorded the way a spawn records one: a path of its own and
    /// the task branch cut for it.
    @discardableResult
    func worktreeSession(_ id: String, taskId: String, state: SessionState = .running) throws -> AgentSession {
        try session(
            id, role: .worker, state: state, taskId: taskId,
            worktreePath: "/tmp/demo-worktrees/\(taskId)", branch: TaskStore.branchName(for: taskId)
        )
    }

    @discardableResult
    func note(_ title: String, sections: [(heading: String, body: String)] = [], in projectId: String? = nil) throws -> Note {
        try notes.create(projectId: projectId ?? project.id, title: title, sections: sections)
    }

    @discardableResult
    func epic(_ title: String, state: EpicState = .active, in projectId: String? = nil) throws -> Epic {
        let id = Epic.newId()
        let epic = Epic(
            id: id, projectId: projectId ?? project.id, title: title, goal: nil,
            branch: EpicStore.branchPrefix + id, state: state, createdAt: .nowMillis
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

    func workerIdentity(sessionId: String, taskId: String?) -> TokenIdentity {
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

    func workerSession(_ id: String, taskId: String, state: SessionState = .running) throws -> AgentSession {
        try session(id, role: .worker, state: state, taskId: taskId)
    }

    func preToolUse(_ command: String, sessionId: String, identity: TokenIdentity, tool: String = "Bash") async -> HookDecision? {
        let event = HookEvent(name: "PreToolUse", sessionId: sessionId, toolName: tool, toolCommand: command, rawJSON: "{}")
        return await hooks.handle(event, identity: identity)
    }

    /// A write the way Claude Code reports one: the tool name plus the file it is about to touch.
    func preToolUseWrite(
        _ filePath: String, sessionId: String, identity: TokenIdentity, tool: String = "Edit"
    ) async -> HookDecision? {
        let event = HookEvent(
            name: "PreToolUse", sessionId: sessionId, toolName: tool, toolFilePath: filePath, rawJSON: "{}"
        )
        return await hooks.handle(event, identity: identity)
    }

    func repoFile(_ relative: String) -> String {
        project.repoPath + "/" + relative
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


/// Stands in for `ScopedCommitRunner`, which lives in AgentBoardRuntime — a target this one does
/// not depend on. What matters here is the request the tool builds, not what git does with it.
final class RecordingScopedCommits: ScopedCommitting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ScopedCommitRequest] = []
    var outcome: ScopedCommitOutcome?

    var requests: [ScopedCommitRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func commit(_ request: ScopedCommitRequest) async throws -> ScopedCommitOutcome {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return outcome ?? .committed(sha: String(repeating: "a", count: 40), paths: request.paths)
    }
}
