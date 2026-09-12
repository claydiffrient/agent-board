import Foundation

extension SessionState {
    /// Terminal: the session will do no more work unless a human resumes it. `idle` is resumable on
    /// its own and `blocked` is waiting on a human, so neither counts as ended.
    public var isEnded: Bool { !isActive }
}

public struct SessionRoster: Sendable, Equatable {
    public var visible: [AgentSession]
    public var hiddenCount: Int

    public init(visible: [AgentSession], hiddenCount: Int) {
        self.visible = visible
        self.hiddenCount = hiddenCount
    }
}

/// Which sessions a roster shows. Ended sessions drop off after a grace window; nothing is deleted,
/// so `hiddenCount` is what the caller owes the reader.
public enum SessionVisibility {
    /// How long an ended session stays on the roster. The session that failed ninety seconds ago is
    /// the one being looked for.
    public static let endedGrace: TimeInterval = 3600

    /// The grace window as prose, for tool descriptions that have to state it.
    public static var endedGraceDescription: String { "\(Int(endedGrace / 60)) minutes" }

    /// `ended_at` is only written by the paths that stop a session; a session marked failed by a
    /// worker still running falls back to its last sign of life.
    public static func endedDate(of session: AgentSession) -> Date {
        session.endedDate ?? session.lastActivityDate ?? session.startedDate
    }

    public static func isWithinGrace(_ session: AgentSession, now: Date, grace: TimeInterval) -> Bool {
        now.timeIntervalSince(endedDate(of: session)) < grace
    }

    public static func roster(
        _ sessions: [AgentSession],
        now: Date,
        grace: TimeInterval = endedGrace,
        includeEnded: Bool = false
    ) -> SessionRoster {
        guard !includeEnded else { return SessionRoster(visible: sessions, hiddenCount: 0) }
        var visible: [AgentSession] = []
        var hidden = 0
        for session in sessions {
            if session.state.isEnded && !isWithinGrace(session, now: now, grace: grace) {
                hidden += 1
            } else {
                visible.append(session)
            }
        }
        return SessionRoster(visible: visible, hiddenCount: hidden)
    }
}
