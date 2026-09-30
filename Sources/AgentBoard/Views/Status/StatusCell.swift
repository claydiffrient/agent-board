import AgentBoardCore
import Foundation

/// Tooltips for the Status table's narrowed cells, which draw less than the session carries so the
/// table fits the minimum detail width (SPEC §10.1).
enum StatusCell {
    /// Cost, counted tokens against the cap when there is one, and cache reads. The cell shows cost only.
    static func spend(_ session: AgentSession, cap: Int?) -> String {
        let counted = cap.map { "\(Format.tokens(session.countedTokens)) / \(Format.tokens($0))" }
            ?? Format.tokens(session.countedTokens)
        return "\(Format.cost(session.estCostUSD)) · \(counted) · \(Format.tokens(session.cacheRead)) cached"
    }

    /// Both lines of the Last activity cell in full, for when either truncates.
    static func activity(_ session: AgentSession) -> String {
        let when = session.lastActivityDate.map(Format.relative) ?? "no activity yet"
        return session.lastTool.map { "\($0) · \(when)" } ?? when
    }
}
