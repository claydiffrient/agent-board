import Foundation

/// What a banner is about, as far as a human deciding "stop telling me about this" is concerned.
/// Coarser than `AttentionReason`: caps and stalls share a switch because they are the same
/// complaint about the same worker at two thresholds.
public enum NotificationCategory: String, Codable, Sendable, CaseIterable, Equatable, Identifiable {
    /// An orchestrator is waiting for a spawn or publish decision.
    case approvals
    /// A worker called `report_blocked`, or asked for input nothing else answers.
    case blockedWorkers
    /// A worker went quiet past its stall threshold, or was stopped at a cap.
    case capsAndStalls
    /// A session that never started, or ended in a way nothing else announces.
    case workerFailures

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .approvals: return "Approvals waiting"
        case .blockedWorkers: return "Blocked workers"
        case .capsAndStalls: return "Cap breaches and stalls"
        case .workerFailures: return "Worker failures"
        }
    }
}

/// A project-wide silence, on top of the per-category switches. Encoded as `{"mode":...}` with
/// `until` only for the timed case, the shape `ArchivePolicy` established.
public enum NotificationMute: Codable, Sendable, Equatable {
    case none
    /// Silent until this wall-clock millisecond, then loud again with no further action.
    case until(Int64)
    case indefinite

    enum CodingKeys: String, CodingKey {
        case mode
        case until
    }

    enum Mode: String, Codable {
        case none
        case until
        case indefinite
    }

    public func isActive(now: Int64) -> Bool {
        switch self {
        case .none: return false
        case .until(let deadline): return now < deadline
        case .indefinite: return true
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Mode.self, forKey: .mode) {
        case .none: self = .none
        case .until: self = .until(try c.decode(Int64.self, forKey: .until))
        case .indefinite: self = .indefinite
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try c.encode(Mode.none, forKey: .mode)
        case .until(let deadline):
            try c.encode(Mode.until, forKey: .mode)
            try c.encode(deadline, forKey: .until)
        case .indefinite:
            try c.encode(Mode.indefinite, forKey: .mode)
        }
    }
}

/// What this project is allowed to interrupt the human for. Every category defaults to on: a human
/// who has configured nothing still hears about an approval that is blocking work. This is a way
/// down from the default, never a silent default.
///
/// **It gates banners only.** The project's attention signal — `ProjectAttention`, the sidebar
/// badge, the At a Glance roll-up — is derived from the database and ignores this type entirely.
/// A muted project still shows what is waiting; otherwise muting would be hiding, and the human
/// would lose the way to find out.
public struct NotificationPreferences: Codable, Sendable, Equatable {
    public var approvals: Bool = true
    public var blockedWorkers: Bool = true
    public var capsAndStalls: Bool = true
    public var workerFailures: Bool = true
    /// One control for "I am deliberately letting this project run unattended", rather than four
    /// switches to flip down and four to remember to flip back.
    public var mute: NotificationMute = .none

    public init(
        approvals: Bool = true,
        blockedWorkers: Bool = true,
        capsAndStalls: Bool = true,
        workerFailures: Bool = true,
        mute: NotificationMute = .none
    ) {
        self.approvals = approvals
        self.blockedWorkers = blockedWorkers
        self.capsAndStalls = capsAndStalls
        self.workerFailures = workerFailures
        self.mute = mute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvals = try c.decodeIfPresent(Bool.self, forKey: .approvals) ?? true
        blockedWorkers = try c.decodeIfPresent(Bool.self, forKey: .blockedWorkers) ?? true
        capsAndStalls = try c.decodeIfPresent(Bool.self, forKey: .capsAndStalls) ?? true
        workerFailures = try c.decodeIfPresent(Bool.self, forKey: .workerFailures) ?? true
        mute = try c.decodeIfPresent(NotificationMute.self, forKey: .mute) ?? .none
    }

    public func isEnabled(_ category: NotificationCategory) -> Bool {
        switch category {
        case .approvals: return approvals
        case .blockedWorkers: return blockedWorkers
        case .capsAndStalls: return capsAndStalls
        case .workerFailures: return workerFailures
        }
    }

    public mutating func setEnabled(_ category: NotificationCategory, _ on: Bool) {
        switch category {
        case .approvals: approvals = on
        case .blockedWorkers: blockedWorkers = on
        case .capsAndStalls: capsAndStalls = on
        case .workerFailures: workerFailures = on
        }
    }

    public func isMuted(now: Int64 = .nowMillis) -> Bool { mute.isActive(now: now) }

    /// The whole decision: may this project raise a banner of this category right now.
    public func allows(_ category: NotificationCategory, now: Int64 = .nowMillis) -> Bool {
        !isMuted(now: now) && isEnabled(category)
    }
}

/// What the settings sheet offers for the project-wide mute. Lives here rather than in the view so
/// the round trip through `NotificationMute` is assertable without mounting anything.
public enum NotificationMuteChoice: String, CaseIterable, Sendable, Identifiable, Equatable {
    case off
    case oneHour
    case fourHours
    case indefinite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Not muted"
        case .oneHour: return "For 1 hour"
        case .fourHours: return "For 4 hours"
        case .indefinite: return "Until I turn it back on"
        }
    }

    var duration: Int64? {
        switch self {
        case .oneHour: return 3_600_000
        case .fourHours: return 4 * 3_600_000
        case .off, .indefinite: return nil
        }
    }

    /// An expired timed mute reads as `off`, so reopening the sheet after the hour is up shows the
    /// truth rather than an hour that is already over.
    public init(_ mute: NotificationMute, now: Int64 = .nowMillis) {
        switch mute {
        case .none:
            self = .off
        case .indefinite:
            self = .indefinite
        case .until(let deadline):
            guard now < deadline else { self = .off; return }
            self = deadline - now <= NotificationMuteChoice.oneHour.duration! ? .oneHour : .fourHours
        }
    }

    /// Saving the sheet without touching the picker must not restart a mute that is already
    /// running, so an unchanged timed choice keeps its original deadline.
    public func mute(now: Int64 = .nowMillis, existing: NotificationMute = .none) -> NotificationMute {
        switch self {
        case .off: return .none
        case .indefinite: return .indefinite
        case .oneHour, .fourHours:
            if case .until = existing, NotificationMuteChoice(existing, now: now) == self {
                return existing
            }
            return .until(now + duration!)
        }
    }
}
