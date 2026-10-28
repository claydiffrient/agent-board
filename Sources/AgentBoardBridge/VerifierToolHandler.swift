import AgentBoardCore
import AgentBoardServer
import Foundation

/// The capability a Walk me through it session holds (SPEC §6): propose a task into Proposed, record a
/// verify failure on its own pull request, and read notes, in the grant's project only. The pull request
/// comes from the grant's `pr_watch_id`, never from an argument.
public final class VerifierToolHandler: ToolHandler {
    private let grants: TokenGrantStore
    private let watches: PRWatchStore
    private let board: Board
    private let notes: NoteTools
    private let events: any BoardEventSink

    public init(db: AppDatabase, events: any BoardEventSink) {
        grants = TokenGrantStore(db)
        watches = PRWatchStore(db)
        board = Board(db)
        notes = NoteTools(db: db)
        self.events = events
    }

    public static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "propose_task",
            description: "Propose a task on Agent Board, the native macOS app that manages this project's board. The "
                + "task lands in the Proposed column and waits there for the human to promote it; nothing works on it "
                + "until then. It is recorded as coming from Walk me through it on the pull request this session is "
                + "verifying.",
            inputSchema: ToolSchema.object(
                properties: [
                    "title": ToolSchema.string(),
                    "body": ToolSchema.string("What needs to be done and where."),
                    "acceptance": ToolSchema.string("How the human will know it is done."),
                    "type": OrchestratorToolHandler.typeSchema,
                    "rationale": ToolSchema.string("Why this is worth doing."),
                ],
                required: ["title"]
            )
        ),
        ToolDescriptor(
            name: "add_pr_item",
            description: "Report a failure found while verifying the pull request this session is verifying, so "
                + "Agent Board's PR follow-through fixes it. The body becomes a `verify_failure` item on that pull "
                + "request and goes through triage like review feedback. A pull request that is ready to verify goes "
                + "back to settling; one already verified is frozen, so the failure waits as a decision for the "
                + "human instead of starting a fix round. It always lands on this session's pull request; no "
                + "argument names another. Refused once that pull request is merged, closed or no longer watched. "
                + "Say what you did, what you expected and what happened.",
            inputSchema: ToolSchema.object(
                properties: [
                    "body": ToolSchema.string(
                        "The failure, as a reviewer would write it.", maxLength: PRWatchStore.maxVerifyFailureLength
                    ),
                    "answers": ToolSchema.string(
                        "Optional: the review this item answers, as its GraphQL node id, or the reviewer's login. "
                            + "Nothing is read from the body."
                    ),
                ],
                required: ["body"]
            )
        ),
        ToolDescriptor(
            name: "search_notes",
            description: "Full-text search this project's shared notes on Agent Board and return the matches as id, "
                + "title and current version. Use read_note to see a match in full.",
            inputSchema: ToolSchema.object(
                properties: ["query": ToolSchema.string("Words to match. FTS5 syntax is accepted.")],
                required: ["query"]
            )
        ),
        ToolDescriptor(
            name: "read_note",
            description: "Read one of this project's notes in full: every section, plus the note's current version.",
            inputSchema: ToolSchema.object(
                properties: ["id": ToolSchema.string("Note id from search_notes.")],
                required: ["id"]
            )
        ),
    ]

    public func tools(for identity: TokenIdentity) async -> [ToolDescriptor] {
        Self.descriptors
    }

    public func call(_ name: String, arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        switch name {
        case "propose_task":
            return try await proposeTask(arguments, identity: identity)
        case "add_pr_item":
            return try addPRItem(arguments, identity: identity)
        case "search_notes", "read_note":
            return try notes.call(name, arguments: arguments, identity: identity)
        default:
            throw ToolError("Unknown tool: \(name). A Walk me through it session can call propose_task, "
                + "add_pr_item, search_notes and read_note.")
        }
    }

    private func proposeTask(_ arguments: JSONValue, identity: TokenIdentity) async throws -> ToolResult {
        let title = try ToolArguments.requiredString("title", in: arguments)
        let type = try OrchestratorToolHandler.parseType(in: arguments, label: "type")
        let proposed = try board.propose(
            projectId: identity.projectId,
            title: title,
            body: ToolArguments.optionalString("body", in: arguments),
            rationale: ToolArguments.optionalString("rationale", in: arguments),
            sessionId: nil,
            epicId: nil,
            acceptance: ToolArguments.optionalString("acceptance", in: arguments),
            type: type,
            origin: .verifySession,
            source: try source(identity)
        )
        await events.reportQueued(projectId: identity.projectId)
        return .json(.object([
            "id": .string(proposed.id),
            "column": .string(proposed.column.rawValue),
            "type": .optional(proposed.type?.rawValue),
        ]))
    }

    private func addPRItem(_ arguments: JSONValue, identity: TokenIdentity) throws -> ToolResult {
        let body = try ToolArguments.requiredString("body", in: arguments)
        guard let watch = try grantWatch(identity) else {
            throw ToolError("This session's pull request is no longer watched. Nothing was recorded.")
        }
        guard !watch.state.isTerminal else {
            throw ToolError("\(watch.repoOwner)/\(watch.repoName)#\(watch.number) is \(watch.state.rawValue). "
                + "Nothing was recorded.")
        }
        return try OrchestratorToolHandler.recordVerifyFailure(
            on: watch, body: body, arguments: arguments, watches: watches
        )
    }

    private func source(_ identity: TokenIdentity) throws -> String {
        guard let watch = try grantWatch(identity) else {
            return "From Walk me through it; its pull request is no longer watched."
        }
        return "From Walk me through it on \(watch.repoOwner)/\(watch.repoName)#\(watch.number)."
    }

    private func grantWatch(_ identity: TokenIdentity) throws -> PRWatch? {
        guard let watchId = try grants.lookup(token: identity.token)?.prWatchId,
              let watch = try watches.get(watchId), watch.projectId == identity.projectId
        else { return nil }
        return watch
    }
}
