import Foundation

extension AttentionCause {
    /// One clause, always leading with the count so it reads the same joined or alone.
    public var text: String {
        switch reason {
        case .pendingApproval:
            return count == 1 ? "1 approval waiting" : "\(count) approvals waiting"
        case .blockedWorker:
            if count == 1, let detail {
                return "1 worker blocked: \(detail)"
            }
            return count == 1 ? "1 worker blocked" : "\(count) workers blocked"
        case .strandedReports:
            let reports = count == 1 ? "1 report" : "\(count) reports"
            return "\(reports) waiting with no orchestrator running"
        case .overdueShutdown:
            return count == 1
                ? "1 agent has not acknowledged shutdown"
                : "\(count) agents have not acknowledged shutdown"
        }
    }
}

extension ProjectAttention {
    /// Every reason in severity order, as a sentence a notification body can carry verbatim.
    /// Nil when the project does not need the human, so "is there anything to say" and "what to
    /// say" are the same question.
    public var summary: String? {
        guard needsAttention else { return nil }
        return causes.map(\.text).joined(separator: ", ") + "."
    }

    /// What `.badge()` wants: nil rather than zero, so a quiet project shows no badge at all.
    public var badgeCount: Int? { needsAttention ? count : nil }
}
