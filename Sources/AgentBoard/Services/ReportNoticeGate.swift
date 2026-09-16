import Foundation

/// The only gate between an app-authored injection and the orchestrator PTY (SPEC §9.1, §9.2).
///
/// Injection is destructive while the human has unsubmitted text in the prompt: the line appends
/// to what they were typing and its trailing carriage return submits the pair. So every trigger —
/// the `Stop` hook, a board change, the human's own Nudge, and the compaction the metering tick
/// asks for — comes through `request`, which holds the line until the prompt goes clean rather than
/// dropping it; an orchestrator that is never told about pending reports stops dispatching, and one
/// that is never compacted runs into Claude Code's own auto-compaction mid-dispatch.
@MainActor
final class ReportNoticeGate {
    typealias Pending = (count: Int, maxId: Int64)

    enum Request: Equatable {
        /// The board changed. Reports already announced are not announced again.
        case announce
        /// The human asked by hand, which re-announces reports already announced.
        case nudge
        /// Context pressure crossed the threshold. Never delivered mid-turn.
        case compact
        /// A compaction finished; the session is idle and has forgotten what it was doing.
        case reorient

        var isNotice: Bool { self == .announce || self == .nudge }
    }

    private let isRunning: () -> Bool
    private let promptIsDirty: () -> Bool
    private let pendingReports: () -> Pending?
    private let deliver: (Int) -> Void
    private let deliverCompaction: () -> Void
    private let deliverReorientation: () -> Void

    private(set) var lastAnnouncedReportId: Int64 = 0
    /// At most one notice kind and at most one of each app-authored line, compaction first: a held
    /// compaction and a held report notice must both survive, and the compaction is the one whose
    /// deadline is real.
    private(set) var heldRequests: [Request] = []
    private(set) var compactionInFlight = false
    /// Latches on the session's first `Stop` and stays latched: it is what tells a board change
    /// apart from a board change that arrived before the orchestrator had ever run.
    private var turnHasEnded = false
    /// Whether a turn is running right now — set by every line this gate writes (each ends in a
    /// carriage return, which submits) and by the human's own Enter, cleared by the next `Stop`.
    /// A fresh child counts as busy: it is booting, and it has finished nothing.
    private var turnInFlight = true

    init(
        isRunning: @escaping () -> Bool,
        promptIsDirty: @escaping () -> Bool,
        pendingReports: @escaping () -> Pending?,
        deliver: @escaping (Int) -> Void,
        deliverCompaction: @escaping () -> Void = {},
        deliverReorientation: @escaping () -> Void = {}
    ) {
        self.isRunning = isRunning
        self.promptIsDirty = promptIsDirty
        self.pendingReports = pendingReports
        self.deliver = deliver
        self.deliverCompaction = deliverCompaction
        self.deliverReorientation = deliverReorientation
    }

    /// A fresh child has a fresh, empty prompt: nothing is held for it and no turn has ended in it.
    func processRestarted() {
        heldRequests = []
        turnHasEnded = false
        turnInFlight = true
        compactionInFlight = false
    }

    func turnEnded() {
        turnHasEnded = true
        turnInFlight = false
        request(.announce)
    }

    func reportsChanged() {
        guard turnHasEnded else { return }
        request(.announce)
    }

    func nudge() {
        request(.nudge)
    }

    /// Context pressure crossed the threshold. Idempotent while a compaction is already in flight,
    /// because the tick keeps reading the same over-threshold transcript until the new one lands.
    func compactionNeeded() {
        guard !compactionInFlight, !heldRequests.contains(.compact) else { return }
        request(.compact)
    }

    /// `SessionStart` with `source: compact` arrived. A manual compaction leaves the session idle
    /// (measured, SPEC §2), so this is where the turn is considered over and the re-orientation
    /// goes out; an auto-compaction's turn continues by itself and gets no line from us.
    func compactionFinished(wasOurs: Bool) {
        compactionInFlight = false
        // An auto-compaction resumes the turn it interrupted, so it is still in flight and gets
        // nothing written into it; a manual one leaves the session idle, exactly like a resume.
        guard wasOurs else { return }
        turnHasEnded = true
        turnInFlight = false
        request(.reorient)
    }

    /// The prompt just emptied. An Enter starts a turn, so nothing that must not land mid-turn may
    /// go out until the next `Stop`; a cancel (`Ctrl-C`, `Ctrl-U`, `Esc`) starts nothing.
    func promptCleared(submitted: Bool) {
        if submitted { turnInFlight = true }
        flush()
    }

    private func request(_ kind: Request) {
        hold(kind)
        flush()
    }

    private func hold(_ kind: Request) {
        guard kind.isNotice else {
            if !heldRequests.contains(kind) { heldRequests.insert(kind, at: 0) }
            return
        }
        if let existing = heldRequests.firstIndex(where: \.isNotice) {
            heldRequests[existing] = Self.merge(heldRequests[existing], kind)
        } else {
            heldRequests.append(kind)
        }
    }

    private enum Outcome {
        /// Bytes went into the PTY, so a turn is now in flight and nothing else goes out this pass.
        case written
        /// Settled without writing — there was nothing left to say.
        case dropped
        /// Stays held for the next clean prompt or the next `turnEnded`.
        case held
    }

    /// At most one line per pass. Anything still held waits for the turn this one started to end,
    /// so a compaction and a report notice never arrive stacked on each other.
    private func flush() {
        guard isRunning(), !promptIsDirty() else { return }
        var remaining: [Request] = []
        var wrote = false
        for kind in heldRequests {
            guard !wrote else {
                remaining.append(kind)
                continue
            }
            switch send(kind) {
            case .written: wrote = true
            case .dropped: break
            case .held: remaining.append(kind)
            }
        }
        heldRequests = remaining
    }

    private func send(_ kind: Request) -> Outcome {
        switch kind {
        case .compact:
            guard !turnInFlight else { return .held }
            compactionInFlight = true
            turnInFlight = true
            deliverCompaction()
            return .written
        case .reorient:
            guard !turnInFlight else { return .held }
            turnInFlight = true
            deliverReorientation()
            return .written
        case .announce, .nudge:
            guard let pending = pendingReports(), pending.count > 0 else { return .dropped }
            if kind == .announce, pending.maxId <= lastAnnouncedReportId { return .dropped }
            turnInFlight = true
            deliver(pending.count)
            lastAnnouncedReportId = max(lastAnnouncedReportId, pending.maxId)
            return .written
        }
    }

    private static func merge(_ held: Request, _ incoming: Request) -> Request {
        if case .nudge = incoming { return .nudge }
        return held
    }
}
