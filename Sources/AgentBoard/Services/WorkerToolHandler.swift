import AgentBoardCore
import AgentBoardServer
import Foundation

final class WorkerToolHandler: ToolHandler {
    private let tasks: TaskStore
    private let sessions: SessionStore
    private let progress: ProgressStore
    private let board: Board

    init(db: AppDatabase) {
        tasks = TaskStore(db)
        sessions = SessionStore(db)
        progress = ProgressStore(db)
        board = Board(db)
    }

    static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "get_my_task",
            description: "Return the task assigned to you: id, title, body, acceptance criteria, priority, board column, "
                + "the tasks it depends on, and which attempt this is. Call it first if anything about the assignment is unclear.",
            inputSchema: schema(properties: [:], required: [])
        ),
        ToolDescriptor(
            name: "update_status",
            description: "Record a status change on your task. `working` is informational. `blocked` flags the task as "
                + "waiting on something you cannot resolve; `unblocked` clears that flag. `failed` marks the task as "
                + "not completable by you. Always include a short detail explaining the state.",
            inputSchema: schema(
                properties: [
                    "state": .object(["type": .string("string"), "enum": .array(["working", "blocked", "failed", "unblocked"].map(JSONValue.string))]),
                    "detail": .object(["type": .string("string"), "description": .string("One or two sentences of context.")]),
                ],
                required: ["state", "detail"]
            )
        ),
        ToolDescriptor(
            name: "log_progress",
            description: "Append a short progress note visible on the task card. Use sparingly: at meaningful milestones, "
                + "not after every step.",
            inputSchema: schema(
                properties: ["text": .object(["type": .string("string"), "maxLength": .number(4000)])],
                required: ["text"]
            )
        ),
        ToolDescriptor(
            name: "propose_task",
            description: "Propose follow-up work you discovered but should not do as part of your task. It lands in the "
                + "Proposed column for a human to review; it is not assigned to you.",
            inputSchema: schema(
                properties: [
                    "title": .object(["type": .string("string")]),
                    "body": .object(["type": .string("string"), "description": .string("What needs to be done and where.")]),
                    "rationale": .object(["type": .string("string"), "description": .string("Why this is worth doing.")]),
                ],
                required: ["title"]
            )
        ),
        ToolDescriptor(
            name: "report_complete",
            description: "Finish your task. Call this only after your work is committed on the current branch. Moves the "
                + "task to Review and ends your session; you will not be able to do more work afterwards.",
            inputSchema: schema(
                properties: [
                    "summary": .object(["type": .string("string"), "description": .string("What you did and how it meets the acceptance criteria.")]),
                    "files_changed": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                    "tests_run": .object(["type": .string("string"), "description": .string("Commands run and their results.")]),
                    "caveats": .object(["type": .string("string"), "description": .string("Anything the reviewer should know: skipped work, risks, open questions.")]),
                ],
                required: ["summary", "files_changed", "tests_run", "caveats"]
            )
        ),
        ToolDescriptor(
            name: "report_blocked",
            description: "Declare that you cannot make progress without a human decision or information you do not have. "
                + "State exactly what you need. The task is flagged blocked and a person is notified.",
            inputSchema: schema(
                properties: ["reason": .object(["type": .string("string")])],
                required: ["reason"]
            )
        ),
    ]

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    func tools(for identity: TokenIdentity) async -> [ToolDescriptor] {
        Self.descriptors
    }

    func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        let task = try ownedTask(identity)
        switch name {
        case "get_my_task":
            return try getMyTask(task, identity: identity)
        case "update_status":
            return try updateStatus(task, arguments: arguments, identity: identity)
        case "log_progress":
            let text = try requiredString("text", in: arguments)
            try progress.append(taskId: task.id, sessionId: identity.sessionId, kind: .note, text: text)
            return ToolResult(text: "Logged.")
        case "propose_task":
            let title = try requiredString("title", in: arguments)
            let proposed = try board.propose(
                projectId: identity.projectId,
                title: title,
                body: arguments["body"]?.stringValue,
                rationale: arguments["rationale"]?.stringValue,
                sessionId: identity.sessionId
            )
            return .json(.object(["id": .string(proposed.id), "column": .string(proposed.column.rawValue)]))
        case "report_complete":
            return try reportComplete(task, arguments: arguments, identity: identity)
        case "report_blocked":
            let reason = try requiredString("reason", in: arguments)
            try board.block(taskId: task.id, sessionId: try requiredSession(identity), reason: reason)
            MacNotifier.post(title: "Worker blocked: \(task.title)", body: reason)
            return ToolResult(text: "Task flagged blocked. A person has been notified; wait for direction.")
        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

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

    private func requiredString(_ key: String, in arguments: JSONValue) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw ToolError("Missing required argument: \(key)")
        }
        return value
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
            "body": task.body.map(JSONValue.string) ?? .null,
            "acceptance": task.acceptance.map(JSONValue.string) ?? .null,
            "priority": task.priority.map(JSONValue.string) ?? .null,
            "column": .string(task.column.rawValue),
            "epic_goal": .null,
            "dependencies": .array(dependencies),
            "attempt": .number(Double(attempt)),
        ]))
    }

    private func updateStatus(_ task: BoardTask, arguments: JSONValue, identity: TokenIdentity) throws -> ToolResult {
        let state = try requiredString("state", in: arguments)
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

    private func reportComplete(_ task: BoardTask, arguments: JSONValue, identity: TokenIdentity) throws -> ToolResult {
        let summary = try requiredString("summary", in: arguments)
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
        try board.complete(taskId: task.id, sessionId: try requiredSession(identity), summary: String(decoding: data, as: UTF8.self))
        return ToolResult(text: "Report recorded. The task is now in Review. Stop here; do not start further work.")
    }
}
