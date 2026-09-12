/// The board split into what it draws and what it is hiding.
public struct ArchivePartition: Sendable, Equatable {
    public var visible: [BoardTask]
    public var hidden: [BoardTask]

    public init(visible: [BoardTask], hidden: [BoardTask]) {
        self.visible = visible
        self.hidden = hidden
    }
}

/// Board-side archive rules. Everything here is a pure read over tasks the view already holds;
/// the writes live in `TaskStore.archive` / `unarchive`.
public enum TaskArchive {
    /// What the Archive button would hide: unarchived tasks sitting in `done`, in the order given.
    /// Independent of `ArchivePolicy` — the automatic modes save the human from remembering, they
    /// do not take the button away.
    public static func archivable(_ tasks: some Sequence<BoardTask>) -> [BoardTask] {
        tasks.filter { $0.column == .done && !$0.isArchived }
    }

    /// With the toggle off an archived task is hidden; with it on the board draws it in place,
    /// still flagged by `isArchived` so it can be rendered as archived rather than as ordinary work.
    public static func partition(_ tasks: some Sequence<BoardTask>, showArchived: Bool) -> ArchivePartition {
        guard !showArchived else { return ArchivePartition(visible: Array(tasks), hidden: []) }
        var visible: [BoardTask] = []
        var hidden: [BoardTask] = []
        for task in tasks {
            if task.isArchived { hidden.append(task) } else { visible.append(task) }
        }
        return ArchivePartition(visible: visible, hidden: hidden)
    }

    /// Most recently archived first; ties and missing stamps fall back to task id so the order is total.
    public static func newestFirst(_ tasks: some Sequence<BoardTask>) -> [BoardTask] {
        tasks.sorted { left, right in
            let l = left.archivedAt ?? 0
            let r = right.archivedAt ?? 0
            return l == r ? left.id < right.id : l > r
        }
    }

    public static func buttonTitle(count: Int) -> String {
        switch count {
        case 0: return "Archive Done Tasks"
        case 1: return "Archive 1 Done Task"
        default: return "Archive \(count) Done Tasks"
        }
    }

    public static func confirmationTitle(count: Int) -> String {
        count == 1 ? "Archive 1 done task?" : "Archive \(count) done tasks?"
    }

    /// What the `done` column says about the work it is not drawing. Nil when it is hiding nothing.
    public static func hiddenNotice(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 archived"
        default: return "\(count) archived"
        }
    }
}
