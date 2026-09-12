import Foundation

/// The only gate between a pending-report notice and the orchestrator PTY (SPEC §9.1).
///
/// Injection is destructive while the human has unsubmitted text in the prompt: the notice appends
/// to what they were typing and its trailing carriage return submits the pair. So every trigger —
/// the `Stop` hook, a board change, and the human's own Nudge — comes through `request`, which
/// holds the notice until the prompt goes clean rather than dropping it; an orchestrator that is
/// never told about pending reports stops dispatching.
@MainActor
final class ReportNoticeGate {
    typealias Pending = (count: Int, maxId: Int64)

    enum Request {
        /// The board changed. Reports already announced are not announced again.
        case announce
        /// The human asked by hand, which re-announces reports already announced.
        case nudge
    }

    private let isRunning: () -> Bool
    private let promptIsDirty: () -> Bool
    private let pendingReports: () -> Pending?
    private let deliver: (Int) -> Void

    private(set) var lastAnnouncedReportId: Int64 = 0
    private(set) var deferredRequest: Request?
    private var turnHasEnded = false

    init(
        isRunning: @escaping () -> Bool,
        promptIsDirty: @escaping () -> Bool,
        pendingReports: @escaping () -> Pending?,
        deliver: @escaping (Int) -> Void
    ) {
        self.isRunning = isRunning
        self.promptIsDirty = promptIsDirty
        self.pendingReports = pendingReports
        self.deliver = deliver
    }

    /// A fresh child has a fresh, empty prompt: nothing is held for it and no turn has ended in it.
    func processRestarted() {
        deferredRequest = nil
        turnHasEnded = false
    }

    func turnEnded() {
        turnHasEnded = true
        request(.announce)
    }

    func reportsChanged() {
        guard turnHasEnded else { return }
        request(.announce)
    }

    func nudge() {
        request(.nudge)
    }

    /// The prompt just emptied — a submit or a cancel. Anything held goes out now, re-reading the
    /// count because more reports may have queued while we waited.
    func promptCleared() {
        guard let held = deferredRequest else { return }
        deferredRequest = nil
        request(held)
    }

    private func request(_ kind: Request) {
        guard isRunning() else { return }
        guard !promptIsDirty() else {
            deferredRequest = Self.merge(deferredRequest, kind)
            return
        }
        guard let pending = pendingReports(), pending.count > 0 else { return }
        if case .announce = kind, pending.maxId <= lastAnnouncedReportId { return }
        deliver(pending.count)
        lastAnnouncedReportId = max(lastAnnouncedReportId, pending.maxId)
    }

    private static func merge(_ held: Request?, _ incoming: Request) -> Request {
        if case .nudge = incoming { return .nudge }
        return held ?? incoming
    }
}
