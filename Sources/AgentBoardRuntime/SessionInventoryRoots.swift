import AgentBoardCore
import Darwin

/// The session part of SPEC §8.7's roots: `claude agents` rows matched to `agent_session` rows the
/// way the reaper finds a host, by session id or short id.
public enum SessionInventoryRoots {
    /// A session with a host is a root by pid. An ended one is passed with no pid and its worktree,
    /// for the orphan rule, unless the worktree is gone or another session still occupies it.
    public static func roots(
        listing: [AgentInfo],
        sessions: [AgentSession],
        worktreeExists: (String) -> Bool
    ) -> [InventoryRoot] {
        var bySession: [String: pid_t] = [:]
        var byShortId: [String: pid_t] = [:]
        for info in listing {
            guard let pid = info.pid, pid > 0 else { continue }
            if let sessionId = info.sessionId { bySession[sessionId] = pid_t(pid) }
            if let id = info.id { byShortId[id] = pid_t(pid) }
        }
        func host(_ session: AgentSession) -> pid_t? {
            bySession[session.sessionId] ?? session.shortId.flatMap { byShortId[$0] }
        }

        let occupied = Set(sessions.filter { $0.state.isActive || host($0) != nil }.compactMap(\.worktreePath))
        return sessions.compactMap { session in
            if let pid = host(session) { return InventoryRoot(pid: pid, owner: owner(of: session)) }
            guard !session.state.isActive, let path = session.worktreePath, !occupied.contains(path),
                  worktreeExists(path)
            else { return nil }
            return InventoryRoot(
                pid: nil, owner: owner(of: session),
                worktree: WorktreeClaim(path: path, startedAtMicros: session.startedAt * 1000)
            )
        }
    }

    /// Only a rostered reviewer records the checkout it was spawned on; its row's role says worker.
    public static func owner(of session: AgentSession) -> ProcessOwner {
        let role: ProcessOwner.Role = switch session.role {
        case .orchestrator: .orchestrator
        case .coordinator: .coordinator
        case .worker: session.reviewHead != nil ? .reviewer : .worker
        }
        return ProcessOwner(
            role: role,
            projectId: session.projectId.isEmpty ? nil : session.projectId,
            taskId: session.taskId,
            sessionId: session.sessionId
        )
    }
}
