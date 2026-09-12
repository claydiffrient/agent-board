/// `ArchivePolicy` flattened for a segmented picker, which can only bind to a value without a payload.
public enum ArchivePolicyMode: String, CaseIterable, Sendable, Equatable {
    case manual
    case afterDays
    case afterEpicMerge

    public var title: String {
        switch self {
        case .manual: return "Manually"
        case .afterDays: return "After days in done"
        case .afterEpicMerge: return "After the epic merges"
        }
    }
}

extension ArchivePolicy {
    /// Used when the picker moves to `afterDays` from a mode that carried no day count.
    public static let defaultDays = 14

    public var mode: ArchivePolicyMode {
        switch self {
        case .manual: return .manual
        case .afterDays: return .afterDays
        case .afterEpicMerge: return .afterEpicMerge
        }
    }

    public var days: Int? {
        guard case .afterDays(let days) = self else { return nil }
        return days
    }

    /// Rebuilds the policy from the picker's two controls. `days` is read only for `afterDays`, and
    /// a zero or negative count would archive done work the moment it lands, so it is floored at 1.
    public static func make(mode: ArchivePolicyMode, days: Int) -> ArchivePolicy {
        switch mode {
        case .manual: return .manual
        case .afterDays: return .afterDays(max(1, days))
        case .afterEpicMerge: return .afterEpicMerge
        }
    }
}
