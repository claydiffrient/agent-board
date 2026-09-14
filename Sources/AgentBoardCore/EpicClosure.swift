import Foundation

/// The two terminal states a human can put an epic into by hand, without driving it through
/// integration. `done` is "I got what I needed out of this"; `abandoned` is "this was the wrong
/// idea". The board treats both as over; the difference is what the human meant, and the lane
/// badge already draws them apart.
public enum EpicClosure: String, Sendable, Equatable, CaseIterable {
    case done
    case abandoned

    public var state: EpicState {
        switch self {
        case .done: return .done
        case .abandoned: return .abandoned
        }
    }

    public var buttonLabel: String {
        switch self {
        case .done: return "Close as done"
        case .abandoned: return "Abandon"
        }
    }

    public var confirmLabel: String {
        switch self {
        case .done: return "Close as done"
        case .abandoned: return "Abandon epic"
        }
    }
}

/// One task left over when the epic closes, as the confirmation names it.
public struct EpicUnfinishedTask: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var column: TaskColumn

    public init(id: String, title: String, column: TaskColumn) {
        self.id = id
        self.title = title
        self.column = column
    }

    public var label: String { "\(title) (\(column.rawValue))" }
}

/// A worker still alive inside the epic, which is what makes closing refuse.
public struct EpicRunningWorker: Sendable, Equatable, Identifiable {
    public var sessionId: String
    public var shortId: String?
    public var taskTitle: String

    public init(sessionId: String, shortId: String?, taskTitle: String) {
        self.sessionId = sessionId
        self.shortId = shortId
        self.taskTitle = taskTitle
    }

    public var id: String { sessionId }
    public var label: String { "\(taskTitle) — \(shortId ?? String(sessionId.prefix(8)))" }
}

/// Everything closing an epic would and would not do, computed before the human commits to it, so
/// the dialog copy and `Board.closeEpic`'s guards read from one source rather than drifting apart.
public struct EpicClosurePlan: Sendable, Equatable {
    public var epicId: String
    public var epicTitle: String
    public var branch: String
    public var closure: EpicClosure
    /// Non-nil when the epic is already `done` or `abandoned`; closing it again is refused.
    public var alreadyClosed: EpicState?
    public var unfinished: [EpicUnfinishedTask]
    public var running: [EpicRunningWorker]

    public init(
        epicId: String,
        epicTitle: String,
        branch: String,
        closure: EpicClosure,
        alreadyClosed: EpicState? = nil,
        unfinished: [EpicUnfinishedTask] = [],
        running: [EpicRunningWorker] = []
    ) {
        self.epicId = epicId
        self.epicTitle = epicTitle
        self.branch = branch
        self.closure = closure
        self.alreadyClosed = alreadyClosed
        self.unfinished = unfinished
        self.running = running
    }

    public var isRefused: Bool { alreadyClosed != nil || !running.isEmpty }

    public var title: String {
        switch closure {
        case .done: return "Close \"\(epicTitle)\" as done?"
        case .abandoned: return "Abandon \"\(epicTitle)\"?"
        }
    }

    /// The whole body of the confirmation, refusal included: a refused plan says why instead of
    /// describing a close that will not happen.
    public var message: String {
        if let alreadyClosed {
            return "This epic is already \(alreadyClosed.rawValue), and closing is one way: done and "
                + "abandoned mean different things, so neither becomes the other. Work left inside it is "
                + "still on the board — take a task out of the epic if it still matters."
        }
        if !running.isEmpty {
            let listed = running.map { "- \($0.label)" }.joined(separator: "\n")
            return "\(running.count) worker\(running.count == 1 ? " is" : "s are") still running in this epic. "
                + "Closing now would leave \(running.count == 1 ? "it" : "them") working against a closed epic, so it is refused. "
                + "Stop \(running.count == 1 ? "it" : "them") first, from its card or from Stop All.\n\n\(listed)"
        }
        return [intent, unfinishedParagraph, branchParagraph].joined(separator: "\n\n")
    }

    private var intent: String {
        let verb = closure == .done
            ? "Marks this epic done on the board"
            : "Marks this epic abandoned on the board"
        return "\(verb). It does not merge \(branch), does not open a pull request, and does not "
            + "touch any task branch."
    }

    private var unfinishedParagraph: String {
        guard !unfinished.isEmpty else {
            return "Every task in this epic is already finished, so nothing is left over."
        }
        let one = unfinished.count == 1
        let listed = unfinished.map { "- \($0.label)" }.joined(separator: "\n")
        return "\(unfinished.count) unfinished task\(one ? "" : "s") stay\(one ? "s" : "") exactly where "
            + "\(one ? "it is" : "they are"), in this epic's lane. Nothing is deleted, moved out of the "
            + "epic, or archived; \(one ? "it keeps its" : "they keep their") card, "
            + "\(one ? "its" : "their") column and \(one ? "its" : "their") branch.\n\(listed)"
    }

    private var branchParagraph: String {
        "Every branch and worktree survives — \(branch) and each `agentboard/<task-id>` — exactly as a "
            + "done task keeps its branch until integration. The orchestrator is told the epic closed so "
            + "it stops planning work into it."
    }
}
