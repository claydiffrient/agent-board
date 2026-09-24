import AgentBoardCore
import AgentBoardServer
import Foundation

/// The capability a rostered reviewer holds under agent review: move the one task it was given out of
/// `review`, and nothing else. Deliberately not orchestrator scope — there is no spawn, no reassign,
/// no board query, and every call is pinned to `identity.taskId`.
public final class ReviewerToolHandler: ToolHandler {
    private let tasks: TaskStore
    private let progress: ProgressStore
    private let roster: RosterStore
    private let board: Board
    private let control: any WorkerControl
    private let events: any BoardEventSink

    public init(db: AppDatabase, control: any WorkerControl, events: any BoardEventSink) {
        tasks = TaskStore(db)
        progress = ProgressStore(db)
        roster = RosterStore(db)
        board = Board(db)
        self.control = control
        self.events = events
    }

    public static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "get_my_task",
            description: "Return the task you are reviewing: id, title, body, acceptance criteria, the worker's "
                + "report, and the progress recorded against it. Call it first.",
            inputSchema: ToolSchema.object(properties: [:], required: [])
        ),
        ToolDescriptor(
            name: "log_progress",
            description: "Append a note to the task you are reviewing. Use it for anything you want on the record "
                + "that is not your verdict.",
            inputSchema: ToolSchema.object(
                properties: ["text": ToolSchema.string(maxLength: 4000)],
                required: ["text"]
            )
        ),
        ToolDescriptor(
            name: "accept_task",
            description: "Accept the task into Done. Your verdict is recorded on the task, so the human who never "
                + "saw it can read who approved it and why. State what you checked, not just that you approve. "
                + "Ends your review; do not continue afterwards.",
            inputSchema: ToolSchema.object(
                properties: [
                    "verdict": ToolSchema.string("What you checked and why the work is acceptable."),
                ],
                required: ["verdict"]
            )
        ),
        ToolDescriptor(
            name: "reopen_task",
            description: "Send the task back to Ready with your findings. Use it when anything must change; do "
                + "not fix it yourself. Your findings are recorded on the task and reach the next worker's opening "
                + "prompt verbatim, so be specific about what is wrong and where. Ends your review.",
            inputSchema: ToolSchema.object(
                properties: [
                    "findings": ToolSchema.string("What is wrong, where, and what would make it acceptable."),
                ],
                required: ["findings"]
            )
        ),
    ]

    public func tools(for identity: TokenIdentity) async -> [ToolDescriptor] {
        Self.descriptors
    }

    public func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        let task = try assignedTask(identity)
        switch name {
        case "get_my_task":
            return try getMyTask(task)
        case "log_progress":
            let text = try ToolArguments.requiredString("text", in: arguments)
            try progress.append(taskId: task.id, sessionId: identity.sessionId, kind: .note, text: text)
            return ToolResult(text: "Logged.")
        case "accept_task":
            let verdict = try ToolArguments.requiredString("verdict", in: arguments)
            try requireUnderReview(task)
            try await requireUntouchedCheckout(task, identity: identity, then: "Stop here; do not start further work.")
            let name = try reviewerName(task, identity: identity)
            try board.recordReviewVerdict(
                taskId: task.id, sessionId: identity.sessionId, reviewerName: name, verdict: verdict
            )
            try await control.accept(
                taskId: task.id,
                acceptedBy: .reviewer(name: name, verdict: verdict, sessionId: identity.sessionId)
            )
            await events.reportQueued(projectId: identity.projectId)
            return ToolResult(
                text: "Accepted into Done. Your verdict is on the task. Stop here; do not start further work."
            )
        case "reopen_task":
            let findings = try ToolArguments.requiredString("findings", in: arguments)
            try requireUnderReview(task)
            try await requireUntouchedCheckout(
                task, identity: identity,
                then: "Record your findings with log_progress so the person sees them, then stop."
            )
            try board.reviewReopen(
                taskId: task.id, sessionId: identity.sessionId,
                reviewerName: try reviewerName(task, identity: identity), findings: findings
            )

            await events.reportQueued(projectId: identity.projectId)
            return ToolResult(
                text: "Sent back to Ready with your findings. Stop here; do not start further work."
            )
        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

    private func assignedTask(_ identity: TokenIdentity) throws -> BoardTask {
        guard let taskId = identity.taskId else {
            throw ToolError("This token is not bound to a task.")
        }
        guard let task = try tasks.get(taskId), task.projectId == identity.projectId else {
            throw ToolError("Task \(taskId) is not owned by this session.")
        }
        return task
    }

    private func requireUnderReview(_ task: BoardTask) throws {
        guard task.column == .review else {
            throw ToolError("Task \(task.id) is in \(task.column.rawValue), not review; there is nothing to decide.")
        }
    }

    /// SPEC §5.1: a reviewer changes nothing. A refused verdict leaves the task in `review` for a
    /// person, with the reason on its card.
    private func requireUntouchedCheckout(_ task: BoardTask, identity: TokenIdentity, then next: String) async throws {
        let change: String?
        do {
            change = try await control.reviewCheckoutChange(taskId: task.id, sessionId: identity.sessionId)
        } catch {
            change = "The checkout could not be read: \(error)"
        }
        guard let change else { return }
        let reason = "Agent review refused: \(change)\nA reviewer changes nothing, so this verdict was not "
            + "recorded and the task stays in Review for a person."
        _ = try? progress.append(taskId: task.id, sessionId: identity.sessionId, kind: .error, text: reason)
        await events.notify(
            projectId: identity.projectId, sessionId: identity.sessionId,
            title: "Agent review refused", body: "\(task.title): \(change)"
        )
        throw ToolError("\(reason) \(next)")
    }

    private func reviewerName(_ task: BoardTask, identity: TokenIdentity) throws -> String {
        if let agentId = task.reviewerAgentId, let agent = try roster.get(agentId) {
            return agent.name
        }
        return identity.sessionId ?? "an unnamed reviewer"
    }

    private func getMyTask(_ task: BoardTask) throws -> ToolResult {
        let rows: [JSONValue] = try progress.list(taskId: task.id).map { row in
            .object([
                "at": .number(Double(row.at)),
                "kind": .string(row.kind.rawValue),
                "text": .string(row.text),
            ])
        }
        return .json(.object([
            "id": .string(task.id),
            "title": .string(task.title),
            "body": .optional(task.body),
            "acceptance": .optional(task.acceptance),
            "priority": .optional(task.priority),
            "column": .string(task.column.rawValue),
            "progress": .array(rows),
        ]))
    }
}
