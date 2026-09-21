import AgentBoardCore
import AgentBoardServer
import Foundation

public final class WorkerToolHandler: ToolHandler {
    private let tasks: TaskStore
    private let sessions: SessionStore
    private let progress: ProgressStore
    private let board: Board
    private let notes: NoteTools
    private let projects: ProjectStore
    private let locks: FileLockStore
    private let taskCommits: TaskCommitStore
    private let scopedCommits: (any ScopedCommitting)?
    private let events: any BoardEventSink

    public init(db: AppDatabase, events: any BoardEventSink, scopedCommits: (any ScopedCommitting)? = nil) {
        tasks = TaskStore(db)
        sessions = SessionStore(db)
        progress = ProgressStore(db)
        board = Board(db)
        notes = NoteTools(db: db)
        projects = ProjectStore(db)
        locks = FileLockStore(db)
        taskCommits = TaskCommitStore(db)
        self.scopedCommits = scopedCommits
        self.events = events
    }

    public static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "get_my_task",
            description: "Return the task assigned to you: id, title, body, acceptance criteria, priority, board column, "
                + "the tasks it depends on, and which attempt this is. Call it first if anything about the assignment is unclear.",
            inputSchema: ToolSchema.object(properties: [:], required: [])
        ),
        ToolDescriptor(
            name: "update_status",
            description: "Record a status change on your task. `working` is informational. `blocked` flags the task as "
                + "waiting on something you cannot resolve; `unblocked` clears that flag. `failed` marks the task as "
                + "not completable by you. Always include a short detail explaining the state.",
            inputSchema: ToolSchema.object(
                properties: [
                    "state": ToolSchema.enumeration(["working", "blocked", "failed", "unblocked"]),
                    "detail": ToolSchema.string("One or two sentences of context."),
                ],
                required: ["state", "detail"]
            )
        ),
        ToolDescriptor(
            name: "log_progress",
            description: "Append a short progress note visible on the task card. Use sparingly: at meaningful milestones, "
                + "not after every step.",
            inputSchema: ToolSchema.object(
                properties: ["text": ToolSchema.string(maxLength: 4000)],
                required: ["text"]
            )
        ),
        ToolDescriptor(
            name: "propose_task",
            description: "Propose follow-up work you discovered but should not do as part of your task. It lands in the "
                + "Proposed column for a human to review; it is not assigned to you. Name `epic_id` to say which epic "
                + "it belongs in — your own task's epic is in `get_my_task`\'s `epic_id` — and promoting the proposal "
                + "puts it there.",
            inputSchema: ToolSchema.object(
                properties: [
                    "title": ToolSchema.string(),
                    "body": ToolSchema.string("What needs to be done and where."),
                    "rationale": ToolSchema.string("Why this is worth doing."),
                    "epic_id": ToolSchema.string(
                        "Epic the proposal should land in when promoted. Any live epic in this project, "
                            + "your own task\'s included. Omit to leave placement to the human."
                    ),
                ],
                required: ["title"]
            )
        ),
        ToolDescriptor(
            name: "report_complete",
            description: "Finish your task. Call this only after your work is committed on the current branch. Moves the "
                + "task to Review and ends your session; you will not be able to do more work afterwards.",
            inputSchema: ToolSchema.object(
                properties: [
                    "summary": ToolSchema.string("What you did and how it meets the acceptance criteria."),
                    "files_changed": ToolSchema.stringArray(),
                    "tests_run": ToolSchema.string("Commands run and their results."),
                    "caveats": ToolSchema.string("Anything the reviewer should know: skipped work, risks, open questions."),
                ],
                required: ["summary", "files_changed", "tests_run", "caveats"]
            )
        ),
        ToolDescriptor(
            name: "acknowledge_shutdown",
            description: "Answer a wind-down order. Call it only after you have committed what is in your worktree. "
                + "The note is what the next worker on this task reads, so say where you stopped and what still "
                + "remains. Your task goes back to ready, not review, and Agent Board stops your session.",
            inputSchema: ToolSchema.object(
                properties: ["note": ToolSchema.string("Where you stopped and what remains.", maxLength: 4000)],
                required: ["note"]
            )
        ),
        ToolDescriptor(
            name: "report_blocked",
            description: "Declare that you cannot make progress without a human decision or information you do not have. "
                + "State exactly what you need. The task is flagged blocked and a person is notified.",
            inputSchema: ToolSchema.object(
                properties: ["reason": ToolSchema.string()],
                required: ["reason"]
            )
        ),
    ] + NoteTools.workerDescriptors

    /// Only a shared-checkout worker sees this. A worktree worker commits with plain git, because
    /// there is nobody else in its tree to scope a commit away from.
    public static let commitDescriptor = ToolDescriptor(
        name: "commit_my_work",
        description: "Commit your work in this shared checkout. Agent Board commits exactly the files you have "
            + "written — it knows them from the per-file locks your writes took — and records the commit as "
            + "yours, so a reviewer sees your changes apart from the other agents' in this same tree. Another "
            + "agent's edits are never swept in. Use this instead of `git commit`, which is refused here. You may "
            + "call it more than once.",
        inputSchema: ToolSchema.object(
            properties: ["message": ToolSchema.string("Imperative mood, no conventional-commit prefix.")],
            required: ["message"]
        )
    )

    public func tools(for identity: TokenIdentity) async -> [ToolDescriptor] {
        guard sharesCheckout(identity) else { return Self.descriptors }
        return Self.descriptors + [Self.commitDescriptor]
    }

    private func sharesCheckout(_ identity: TokenIdentity) -> Bool {
        guard scopedCommits != nil, let sessionId = identity.sessionId else { return false }
        guard let session = try? sessions.get(sessionId),
              let project = try? projects.get(session.projectId)
        else { return false }
        return SharedCheckoutGroup.isMember(session, of: project)
    }

    public func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        if Self.noteToolNames.contains(name) {
            return try notes.call(name, arguments: arguments, identity: identity)
        }
        let task = try ownedTask(identity)
        switch name {
        case "get_my_task":
            return try getMyTask(task, identity: identity)
        case "update_status":
            return try updateStatus(task, arguments: arguments, identity: identity)
        case "log_progress":
            let text = try ToolArguments.requiredString("text", in: arguments)
            try progress.append(taskId: task.id, sessionId: identity.sessionId, kind: .note, text: text)
            return ToolResult(text: "Logged.")
        case "propose_task":
            return try await proposeTask(arguments, identity: identity)
        case "commit_my_work":
            return try await commitMyWork(task, arguments: arguments, identity: identity)
        case "report_complete":
            let completion = try reportComplete(task, arguments: arguments, identity: identity)
            guard !completion.wasAlreadyComplete else { return Self.completionResult(completion) }
            if let sessionId = identity.sessionId {
                await events.workerCompleted(projectId: identity.projectId, sessionId: sessionId)
            }
            await events.reportQueued(projectId: identity.projectId)
            return Self.completionResult(completion)
        case "acknowledge_shutdown":
            let note = try ToolArguments.requiredString("note", in: arguments)
            let sessionId = try requiredSession(identity)
            do {
                _ = try board.acknowledgeShutdown(sessionId: sessionId, note: note)
            } catch BoardError.noShutdownOrder {
                throw ToolError("No shutdown order is outstanding on this project; keep working on your task.")
            }
            await events.workerAcknowledgedShutdown(projectId: identity.projectId, sessionId: sessionId)
            return ToolResult(text: "acknowledged — stop now")
        case "report_blocked":
            let reason = try ToolArguments.requiredString("reason", in: arguments)
            let sessionId = try requiredSession(identity)
            let lockedPath = try sessions.get(sessionId)?.blockedOnPath
            if let lockedPath {
                _ = try board.blockOnFileLock(
                    taskId: task.id, sessionId: sessionId,
                    reason: "\(reason)\n\nAgent Board gave up waiting for \(lockedPath), held by another agent in this shared checkout."
                )
            } else {
                try board.block(taskId: task.id, sessionId: sessionId, reason: reason)
            }
            await events.reportQueued(projectId: identity.projectId)
            guard let lockedPath else {
                return ToolResult(text: "Task flagged blocked. A person has been notified; wait for direction.")
            }
            return ToolResult(
                text: "Task flagged blocked and returned to ready; it will be dispatched again once "
                    + "\(lockedPath) is free. Stop now."
            )
        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

    private static let noteToolNames = Set(NoteTools.workerDescriptors.map(\.name))

    private func ownedTask(_ identity: TokenIdentity) throws -> BoardTask {
        guard let taskId = identity.taskId else {
            throw ToolError("This token is not bound to a task.")
        }
        guard let task = try tasks.get(taskId), task.projectId == identity.projectId else {
            throw ToolError("Task \(taskId) is not owned by this session.")
        }
        return task
    }

    private func requiredSession(_ identity: TokenIdentity) throws -> String {
        guard let sessionId = identity.sessionId else {
            throw ToolError("Session is still registering; retry in a moment.")
        }
        return sessionId
    }

    /// The epic is validated here rather than only at promotion so the worker is told at once,
    /// while it still has the context to pick another one. `Board.promote` checks again.
    private func proposeTask(_ arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        let title = try ToolArguments.requiredString("title", in: arguments)
        let epicId = ToolArguments.optionalString("epic_id", in: arguments).flatMap { $0.isEmpty ? nil : $0 }
        let proposed: BoardTask
        do {
            proposed = try board.propose(
                projectId: identity.projectId,
                title: title,
                body: arguments["body"]?.stringValue,
                rationale: arguments["rationale"]?.stringValue,
                sessionId: identity.sessionId,
                epicId: epicId
            )
        } catch let refusal as ProposalEpicRefusal {
            throw ToolError(refusal.reason)
        }
        await events.reportQueued(projectId: identity.projectId)
        return .json(.object([
            "id": .string(proposed.id),
            "column": .string(proposed.column.rawValue),
            "epic_id": .optional(proposed.epicId),
        ]))
    }

    private func getMyTask(_ task: BoardTask, identity: TokenIdentity) throws -> ToolResult {
        let dependencies: [JSONValue] = try tasks.deps(of: task.id).compactMap { depId in
            guard let dep = try tasks.get(depId) else { return nil }
            return .object(["id": .string(dep.id), "title": .string(dep.title), "column": .string(dep.column.rawValue)])
        }
        let attempt: Int
        if let sessionId = identity.sessionId, let session = try sessions.get(sessionId) {
            attempt = session.attempt
        } else {
            attempt = try max(sessions.forTask(task.id).count, 1)
        }
        return .json(.object([
            "id": .string(task.id),
            "title": .string(task.title),
            "body": .optional(task.body),
            "acceptance": .optional(task.acceptance),
            "priority": .optional(task.priority),
            "column": .string(task.column.rawValue),
            "epic_id": .optional(task.epicId),
            "epic_goal": .null,
            "dependencies": .array(dependencies),
            "attempt": .number(Double(attempt)),
        ]))
    }

    private func updateStatus(_ task: BoardTask, arguments: JSONValue, identity: TokenIdentity) throws -> ToolResult {
        let state = try ToolArguments.requiredString("state", in: arguments)
        let detail = arguments["detail"]?.stringValue ?? ""
        let sessionId = identity.sessionId
        switch state {
        case "working":
            break
        case "blocked":
            try tasks.setBlocked(task.id, true, reason: detail)
            if let sessionId { try sessions.setState(sessionId, .blocked) }
        case "unblocked":
            if let sessionId {
                try board.unblock(taskId: task.id, sessionId: sessionId)
            } else {
                try tasks.setBlocked(task.id, false, reason: nil)
            }
        case "failed":
            try tasks.setFailed(task.id, true, reason: detail)
            if let sessionId { try sessions.setState(sessionId, .failed) }
        default:
            throw ToolError("Unknown state '\(state)'. Use working, blocked, failed, or unblocked.")
        }
        let text = detail.isEmpty ? state : "\(state): \(detail)"
        try progress.append(taskId: task.id, sessionId: sessionId, kind: .status, text: text)
        return ToolResult(text: "Status recorded: \(text)")
    }

    /// The paths come from the lock store, never from the agent: a write tool in a shared checkout
    /// cannot run without first claiming its file, and the claim is held until the session ends, so
    /// the claims are exactly what this session has written.
    private func commitMyWork(_ task: BoardTask, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        guard let runner = scopedCommits else {
            throw ToolError("commit_my_work is not available in this session; commit with git.")
        }
        let sessionId = try requiredSession(identity)
        guard let session = try sessions.get(sessionId),
              let project = try projects.get(session.projectId)
        else { throw ToolError("Session is still registering; retry in a moment.") }
        guard SharedCheckoutGroup.isMember(session, of: project) else {
            throw ToolError("You are in your own worktree; commit with git on your branch.")
        }
        let message = try ToolArguments.requiredString("message", in: arguments)
        let paths = CommitScope.paths(try locks.held(projectId: identity.projectId), sessionId: sessionId)
        guard !paths.isEmpty else { throw ToolError(ScopedCommitError.noPathsHeld.description) }

        let outcome = try await runner.commit(
            ScopedCommitRequest(
                repoPath: project.repoPath,
                branch: session.branch ?? SharedCheckoutGroup.branch(epicId: task.epicId),
                taskId: task.id,
                paths: paths,
                message: message
            )
        )
        switch outcome {
        case .committed(let sha, let committed):
            // The ledger row is written here rather than swept up later: a crash between the commit
            // and a later pass would lose the attribution with nothing in the commit to rebuild it from.
            try taskCommits.record(taskId: task.id, sha: sha)
            let text = "Committed \(String(sha.prefix(8))) on \(session.branch ?? "the shared branch"), "
                + "recorded as this task's, containing only: "
                + committed.joined(separator: ", ")
            try progress.append(taskId: task.id, sessionId: sessionId, kind: .status, text: text)
            return .json(.object([
                "commit": .string(sha),
                "paths": .array(committed.map { .string($0) }),
            ]))
        case .nothingToCommit(let claimed):
            return ToolResult(
                text: "Nothing to commit: the files you have claimed (\(claimed.joined(separator: ", "))) "
                    + "hold no change git would record."
            )
        }
    }

    private func reportComplete(_ task: BoardTask, arguments: JSONValue, identity: TokenIdentity) throws -> Board.TaskCompletion {
        let summary = try ToolArguments.requiredString("summary", in: arguments)
        let files = arguments["files_changed"]?.arrayValue ?? []
        let body: JSONValue = .object([
            "summary": .string(summary),
            "files_changed": .array(files.filter { $0.stringValue != nil }),
            "tests_run": arguments["tests_run"] ?? .string(""),
            "caveats": arguments["caveats"] ?? .string(""),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(body)
        return try board.complete(
            taskId: task.id, sessionId: try requiredSession(identity), summary: String(decoding: data, as: UTF8.self)
        )
    }

    private static func completionResult(_ completion: Board.TaskCompletion) -> ToolResult {
        let id = completion.report.id.map(String.init) ?? "—"
        let recorded = completion.wasAlreadyComplete
            ? "Report \(id) was already recorded for this task; this call changed nothing."
            : "Report \(id) recorded."
        return ToolResult(
            text: "\(recorded) The task is now in \(completion.column.rawValue.capitalized). "
                + "Stop here; do not start further work."
        )
    }
}
