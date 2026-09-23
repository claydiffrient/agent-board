import AgentBoardCore
import AgentBoardServer
import Foundation

/// The standing texts a session needs back once its opening prompt has fallen out of context,
/// served as resources because that is the only one of MCP's two fetch routes an unattended
/// session can reach: measured against Claude Code 2.1.272, a `claude --bg` worker's client calls
/// `prompts/list` in its handshake and exposes neither the result nor `prompts/get` to the agent.
///
/// Both briefings are rendered on every read from the same functions the spawn path calls, so a
/// session that fetches one cannot be handed text that has drifted from what it was spawned with.
public struct BriefingResourceHandler: ResourceHandler {
    private let projects: ProjectStore
    private let sessions: SessionStore

    public init(db: AppDatabase) {
        projects = ProjectStore(db)
        sessions = SessionStore(db)
    }

    public func resources(for identity: TokenIdentity) async throws -> [ResourceDescriptor] {
        switch identity.scope {
        case .worker:
            guard identity.taskId != nil else { return [] }
            return [ResourceDescriptor(
                uri: BriefingResourceURI.worker,
                name: "Worker protocol",
                description: "The standing How to work, When you are done and How your turns end sections you were spawned with — "
                    + "where you are working and on which branch, when to search notes, and the completion protocol. "
                    + "Read it after a resume or a compaction, when those instructions are no longer in context.",
                mimeType: Self.mimeType
            )]
        case .orchestrator:
            return [ResourceDescriptor(
                uri: BriefingResourceURI.orchestrator,
                name: "Orchestrator briefing",
                description: "The briefing you were launched with — vocabulary, epics, the rules you dispatch under, "
                    + "and this project's model settings. Read it after a compaction; it is composed when you read it, "
                    + "so it reflects the project's settings as they stand now.",
                mimeType: Self.mimeType
            )]
        case .reviewer:
            // Nothing spawns a rostered reviewer yet, so there is no briefing it was launched with
            // to hand back. `read` refuses both uris for this scope through its `default` arm.
            return []
        }
    }

    public func read(_ uri: String, identity: TokenIdentity) async throws -> [ResourceContents] {
        switch (uri, identity.scope) {
        case (BriefingResourceURI.worker, .worker):
            guard let taskId = identity.taskId else {
                throw ResourceError(uri: uri, message: "This token is not bound to a task, so it has no branch to render.")
            }
            guard let project = try projects.get(identity.projectId) else {
                throw ResourceError(uri: uri, message: "No project \(identity.projectId).")
            }
            let standing = WorkerStanding.recorded(
                session: try callerSession(identity, taskId: taskId), project: project, taskId: taskId
            )
            return [contents(uri, OpeningPrompt.workingProtocol(
                branch: standing.branch,
                placement: standing.placement,
                workingDirectory: standing.workingDirectory
            ))]
        case (BriefingResourceURI.orchestrator, .orchestrator):
            guard let project = try projects.get(identity.projectId) else {
                throw ResourceError(uri: uri, message: "No project \(identity.projectId).")
            }
            return [contents(uri, OrchestratorPrompt.systemPrompt(project: project))]
        default:
            throw ResourceError(uri: uri, message: Self.refusal(for: identity))
        }
    }

    /// The token is bound to the session once the worker is spawned; before that it is bound only
    /// to the task, and the newest row for the task is the one that was just written for it.
    private func callerSession(_ identity: TokenIdentity, taskId: String) throws -> AgentSession? {
        if let sessionId = identity.sessionId, let session = try sessions.get(sessionId) {
            return session
        }
        return try sessions.forTask(taskId).first
    }

    static let mimeType = "text/markdown"

    private func contents(_ uri: String, _ text: String) -> ResourceContents {
        ResourceContents(uri: uri, mimeType: Self.mimeType, text: text)
    }

    /// Names only the briefing this caller is allowed to read, so an orchestrator asking for the
    /// worker protocol is refused the same way an unknown uri is.
    static func refusal(for identity: TokenIdentity) -> String {
        let mine = identity.scope == .worker ? BriefingResourceURI.worker : BriefingResourceURI.orchestrator
        return "Not a briefing you can read. The one addressed to you is \(mine)."
    }
}

/// `BoardServer` takes one resource handler; notes and briefings are two. Reads route on the uri's
/// scheme, which is why each family's uris are minted from a single place.
public struct CompositeResourceHandler: ResourceHandler {
    private let handlers: [(scheme: String, handler: any ResourceHandler)]

    public init(_ handlers: [(scheme: String, handler: any ResourceHandler)]) {
        self.handlers = handlers
    }

    public func resources(for identity: TokenIdentity) async throws -> [ResourceDescriptor] {
        var all: [ResourceDescriptor] = []
        for (_, handler) in handlers {
            all += try await handler.resources(for: identity)
        }
        return all
    }

    public func read(_ uri: String, identity: TokenIdentity) async throws -> [ResourceContents] {
        guard let scheme = URLComponents(string: uri)?.scheme,
              let match = handlers.first(where: { $0.scheme == scheme })
        else {
            let known = handlers.map { "\($0.scheme)://" }.joined(separator: ", ")
            throw ResourceError(uri: uri, message: "Unknown uri scheme. This server serves: \(known).")
        }
        return try await match.handler.read(uri, identity: identity)
    }
}
