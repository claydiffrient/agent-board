import AgentBoardCore
import AgentBoardServer
import Foundation

/// The capability a Walk me through it session holds (SPEC §6): propose a task into Proposed and
/// read notes, in the grant's project only. The pull request it names comes from the grant's
/// `pr_watch_id`, never from an argument.
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
        case "search_notes", "read_note":
            return try notes.call(name, arguments: arguments, identity: identity)
        default:
            throw ToolError("Unknown tool: \(name). A Walk me through it session can call propose_task, "
                + "search_notes and read_note.")
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

    private func source(_ identity: TokenIdentity) throws -> String {
        guard let watchId = try grants.lookup(token: identity.token)?.prWatchId,
              let watch = try watches.get(watchId), watch.projectId == identity.projectId
        else { return "From Walk me through it; its pull request is no longer watched." }
        return "From Walk me through it on \(watch.repoOwner)/\(watch.repoName)#\(watch.number)."
    }
}
