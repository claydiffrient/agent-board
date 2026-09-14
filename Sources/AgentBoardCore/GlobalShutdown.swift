import Foundation

/// Everything the cross-project wind-down sheet reads, gathered in one pass so the sheet holds a
/// single observation rather than one per project.
public struct GlobalShutdownSnapshot: Sendable, Equatable {
    /// One per project with an order still standing. A project whose order was lifted drops out,
    /// which is how Cancel empties the sheet.
    public var orders: [ShutdownOrder]
    public var deliveries: [ShutdownDelivery]
    public var sessions: [AgentSession]
    public var projectNames: [String: String]
    public var graceSeconds: [String: Int]
    public var taskTitles: [String: String]

    public init(
        orders: [ShutdownOrder] = [],
        deliveries: [ShutdownDelivery] = [],
        sessions: [AgentSession] = [],
        projectNames: [String: String] = [:],
        graceSeconds: [String: Int] = [:],
        taskTitles: [String: String] = [:]
    ) {
        self.orders = orders
        self.deliveries = deliveries
        self.sessions = sessions
        self.projectNames = projectNames
        self.graceSeconds = graceSeconds
        self.taskTitles = taskTitles
    }

    public static let empty = GlobalShutdownSnapshot()

    public var projectCount: Int { orders.count }
}

/// What the wind-down should do next.
public enum ShutdownQuitDecision: Sendable, Equatable {
    /// Something is still moving on its own, or the orders have not all been raised yet.
    case wait
    /// Every delivery closed. Nothing is left to wait for, so the app can go.
    case quit
    /// Nothing left is going to answer by itself: what remains is a permission prompt or silence,
    /// and neither clears without a human. Quit Anyway is the way out.
    case stuck(waitingOnHuman: Int, notResponding: Int)
}

/// The pure half of the cross-project wind-down: snapshot in, rows, counts and a quit decision out.
public enum GlobalShutdown {
    /// Every ordered session across every project, each row carrying the project it belongs to and
    /// measured against that project's own grace period — the projects do not share one.
    public static func rows(_ snapshot: GlobalShutdownSnapshot, now: Int64) -> [ShutdownRow] {
        let projectByOrder = Dictionary(
            snapshot.orders.map { ($0.id, $0.projectId) }, uniquingKeysWith: { first, _ in first }
        )
        let byProject = Dictionary(grouping: snapshot.deliveries) { projectByOrder[$0.orderId] ?? "" }
        let sessionsByProject = Dictionary(grouping: snapshot.sessions, by: \.projectId)
        return byProject
            .flatMap { projectId, deliveries in
                ShutdownSheetModel.rows(
                    deliveries: deliveries,
                    sessions: sessionsByProject[projectId] ?? [],
                    taskTitles: snapshot.taskTitles,
                    graceSeconds: snapshot.graceSeconds[projectId] ?? ShutdownDeliveryStore.defaultGraceSeconds,
                    now: now,
                    projectName: snapshot.projectNames[projectId]
                )
            }
            .sorted(by: ShutdownSheetModel.precedes)
    }

    /// No supervisor progress is folded in here. On one project that reported total covers a worker
    /// enrolled before the sheet opened; across every project the delivery rows already are the
    /// enrolment, and mixing the two would double-count.
    public static func counts(rows: [ShutdownRow]) -> ShutdownCounts {
        ShutdownSheetModel.counts(rows: rows)
    }

    /// True once the snapshot has caught up with the orders that were raised. The observation
    /// republishes after the write, so between the two the snapshot still holds no deliveries at
    /// all — and an empty snapshot counts as "everything closed". Without this the app would quit
    /// in the gap, while every worker was still mid-turn.
    public static func ordersVisible(in snapshot: GlobalShutdownSnapshot, raised: Set<String>) -> Bool {
        raised.isSubset(of: Set(snapshot.orders.map(\.id)))
    }

    /// `ordersRaised` is `ordersVisible`: false until the snapshot shows every order that was
    /// raised, so a stale read cannot be mistaken for a finished wind-down.
    public static func decide(counts: ShutdownCounts, ordersRaised: Bool) -> ShutdownQuitDecision {
        guard ordersRaised else { return .wait }
        if counts.isComplete { return .quit }
        let blocked = counts.waitingOnHuman + counts.notResponding
        guard blocked >= counts.outstanding else { return .wait }
        return .stuck(waitingOnHuman: counts.waitingOnHuman, notResponding: counts.notResponding)
    }

    public static func headline(counts: ShutdownCounts, projects: Int) -> String {
        if counts.total == 0 { return "No workers were running\(across(projects))" }
        if counts.isComplete { return "\(counts.closed)/\(counts.total) agents closed\(across(projects))" }
        return "Closing \(counts.closed)/\(counts.total) agents\(across(projects))"
    }

    public static func detail(counts: ShutdownCounts, projects: Int, decision: ShutdownQuitDecision) -> String {
        if counts.total == 0 {
            return "No worker was running on any project. Spawning is refused everywhere until you cancel or quit."
        }
        if case .quit = decision {
            return "Every worker committed its worktree and stopped. Their unfinished tasks are back in ready with resume notes. Quitting now."
        }
        var lines = ["Each worker commits what it has, leaves its task resumable, and acknowledges. Nothing is killed on its own."]
        if counts.waitingOnHuman > 0 {
            lines.append("\(counts.waitingOnHuman) is stopped on a permission prompt and cannot be reached until you answer it — attach to clear it.")
        }
        if counts.notResponding > 0 {
            lines.append("\(counts.notResponding) is past its grace period. Stop it to kill the process; its task still goes back to ready.")
        }
        if case .stuck = decision {
            lines.append("Nothing here will close on its own. Quit Anyway leaves those sessions running.")
        }
        return lines.joined(separator: " ")
    }

    private static func across(_ projects: Int) -> String {
        switch projects {
        case 0: ""
        case 1: " on 1 project"
        default: " across \(projects) projects"
        }
    }
}
