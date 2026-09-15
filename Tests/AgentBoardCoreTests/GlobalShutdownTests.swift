import XCTest
@testable import AgentBoardCore

/// The pure half of the cross-project wind-down: aggregation across projects, and the decision to
/// quit. Nothing here touches AppKit — `NSApplication.terminate` is the view's business, and the
/// only thing tested is the verdict that would trigger it.
final class GlobalShutdownTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000

    private func order(_ id: String, project: String) -> ShutdownOrder {
        ShutdownOrder(id: id, projectId: project, requestedBy: "human", reason: nil, requestedAt: now - 60_000)
    }

    private func delivery(
        _ sessionId: String, order: String, taskId: String? = nil, orderedAgo: Int64 = 300,
        deliveredAgo: Int64? = nil, acknowledgedAgo: Int64? = nil
    ) -> ShutdownDelivery {
        ShutdownDelivery(
            orderId: order,
            sessionId: sessionId,
            taskId: taskId,
            orderedAt: now - orderedAgo * 1000,
            deliveredAt: deliveredAgo.map { now - $0 * 1000 },
            deliveredVia: deliveredAgo == nil ? nil : .hook,
            acknowledgedAt: acknowledgedAgo.map { now - $0 * 1000 },
            note: nil
        )
    }

    private func session(_ id: String, project: String, state: SessionState, taskId: String? = nil) -> AgentSession {
        AgentSession(
            sessionId: id, shortId: String(id.prefix(8)), projectId: project, taskId: taskId,
            role: .worker, cwd: "/tmp", state: state, startedAt: now - 600_000,
            endedAt: state.isActive ? nil : now - 10_000
        )
    }

    /// Two projects, one grace period each, both lists in one sheet.
    private func twoProjects() -> GlobalShutdownSnapshot {
        GlobalShutdownSnapshot(
            orders: [order("o-alpha", project: "alpha"), order("o-beta", project: "beta")],
            deliveries: [
                delivery("a1", order: "o-alpha", taskId: "t1", deliveredAgo: 30),
                delivery("b1", order: "o-beta", taskId: "t2", deliveredAgo: 30),
                delivery("b2", order: "o-beta", taskId: "t3", deliveredAgo: 30, acknowledgedAgo: 5),
            ],
            sessions: [
                session("a1", project: "alpha", state: .running, taskId: "t1"),
                session("b1", project: "beta", state: .running, taskId: "t2"),
                session("b2", project: "beta", state: .completed, taskId: "t3"),
            ],
            projectNames: ["alpha": "Alpha", "beta": "Beta"],
            graceSeconds: ["alpha": 120, "beta": 20],
            taskTitles: ["t1": "Fix the header", "t2": "Ship search", "t3": "Rename the thing"]
        )
    }

    func testEveryProjectsSessionsLandInOneListWithTheProjectNamed() {
        let rows = GlobalShutdown.rows(twoProjects(), now: now)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(
            Dictionary(grouping: rows, by: { $0.projectName ?? "?" }).mapValues(\.count),
            ["Alpha": 1, "Beta": 2]
        )
        XCTAssertEqual(rows.first(where: { $0.sessionId == "a1" })?.taskTitle, "Fix the header")
        XCTAssertNil(rows.first { $0.projectName == nil }, "a cross-project row left its project unnamed")
    }

    /// The projects do not share a grace period. `a1` and `b1` were delivered at the same instant;
    /// only the project whose grace is 20s has expired.
    func testEachProjectIsMeasuredAgainstItsOwnGracePeriod() {
        let rows = GlobalShutdown.rows(twoProjects(), now: now)

        XCTAssertEqual(rows.first { $0.sessionId == "a1" }?.state, .closing)
        XCTAssertEqual(rows.first { $0.sessionId == "b1" }?.state, .notResponding)
    }

    func testTheCountIsTheTotalAcrossProjects() {
        let counts = GlobalShutdown.counts(rows: GlobalShutdown.rows(twoProjects(), now: now))

        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.closed, 1)
        XCTAssertEqual(counts.outstanding, 2)
        XCTAssertEqual(counts.notResponding, 1)
        XCTAssertFalse(counts.isComplete)
    }

    func testTheHeadlineNamesHowManyProjectsAreBeingWoundDown() {
        let counts = GlobalShutdown.counts(rows: GlobalShutdown.rows(twoProjects(), now: now))

        XCTAssertEqual(GlobalShutdown.headline(counts: counts, projects: 2), "Closing 1/3 agents across 2 projects")
        XCTAssertEqual(
            GlobalShutdown.headline(counts: ShutdownCounts(total: 0, closed: 0), projects: 5),
            "No workers were running across 5 projects"
        )
        XCTAssertEqual(
            GlobalShutdown.headline(counts: ShutdownCounts(total: 2, closed: 2), projects: 1),
            "2/2 agents closed on 1 project"
        )
    }

    /// An order with no worker behind it still belongs on the sheet's project count, and still
    /// refuses spawns — it just contributes no rows.
    func testAProjectWithNoWorkerContributesNoRowsAndBlocksNothing() {
        var snapshot = twoProjects()
        snapshot.orders.append(order("o-gamma", project: "gamma"))
        snapshot.projectNames["gamma"] = "Gamma"

        let rows = GlobalShutdown.rows(snapshot, now: now)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(snapshot.projectCount, 3)
    }

    /// The gap between raising the orders and the observation republishing: the snapshot is still
    /// empty, which counts as "every delivery closed". Quitting there would kill the app while
    /// every worker was still mid-turn.
    func testAStaleSnapshotDoesNotReadAsAFinishedWindDown() {
        let raised: Set<String> = ["o-alpha", "o-beta"]

        XCTAssertFalse(GlobalShutdown.ordersVisible(in: .empty, raised: raised))
        XCTAssertFalse(
            GlobalShutdown.ordersVisible(
                in: GlobalShutdownSnapshot(orders: [order("o-alpha", project: "alpha")]), raised: raised
            ),
            "one project's order had not landed in the snapshot yet"
        )
        XCTAssertTrue(GlobalShutdown.ordersVisible(in: twoProjects(), raised: raised))
        XCTAssertTrue(
            GlobalShutdown.ordersVisible(in: .empty, raised: []),
            "there were no projects to order, so there is nothing to wait for"
        )

        XCTAssertEqual(
            GlobalShutdown.decide(
                counts: GlobalShutdown.counts(rows: GlobalShutdown.rows(.empty, now: now)),
                ordersRaised: GlobalShutdown.ordersVisible(in: .empty, raised: raised)
            ),
            .wait
        )
    }

    func testTheDecisionIsToWaitUntilEveryOrderHasBeenRaised() {
        let empty = ShutdownCounts(total: 0, closed: 0)

        XCTAssertEqual(GlobalShutdown.decide(counts: empty, ordersRaised: false), .wait)
        XCTAssertEqual(
            GlobalShutdown.decide(counts: empty, ordersRaised: true), .quit,
            "nothing was running anywhere, so there is nothing to wait for"
        )
    }

    func testTheDecisionIsToQuitOnlyWhenEveryDeliveryHasClosed() {
        XCTAssertEqual(GlobalShutdown.decide(counts: ShutdownCounts(total: 3, closed: 2), ordersRaised: true), .wait)
        XCTAssertEqual(GlobalShutdown.decide(counts: ShutdownCounts(total: 3, closed: 3), ordersRaised: true), .quit)
    }

    /// A worker on a permission prompt cannot acknowledge until a human answers it, and a silent
    /// one past its grace period is not going to. Neither resolves on its own, so the sheet stops
    /// promising it will and offers Quit Anyway.
    func testAWindDownThatCannotFinishOnItsOwnReadsAsStuck() {
        let stuck = ShutdownCounts(total: 4, closed: 2, notResponding: 1, waitingOnHuman: 1)

        XCTAssertEqual(
            GlobalShutdown.decide(counts: stuck, ordersRaised: true),
            .stuck(waitingOnHuman: 1, notResponding: 1)
        )
        XCTAssertEqual(
            GlobalShutdown.decide(
                counts: ShutdownCounts(total: 4, closed: 1, notResponding: 1, waitingOnHuman: 1),
                ordersRaised: true
            ),
            .wait,
            "one worker is still inside its grace period, so this is not stuck yet"
        )
    }

    func testTheStuckDetailSaysQuitAnywayLeavesThoseSessionsRunning() {
        let stuck = ShutdownCounts(total: 2, closed: 0, notResponding: 1, waitingOnHuman: 1)
        let detail = GlobalShutdown.detail(
            counts: stuck, projects: 2, decision: GlobalShutdown.decide(counts: stuck, ordersRaised: true)
        )

        XCTAssertTrue(detail.contains("attach to clear it"), detail)
        XCTAssertTrue(detail.contains("past its grace period"), detail)
        XCTAssertTrue(detail.contains("Quit Anyway leaves those sessions running."), detail)
    }

    /// One list, not two concatenated ones: rows from both projects are interleaved by state, with
    /// everything still open ahead of everything closed.
    func testOpenRowsSortAheadOfClosedOnesAcrossProjects() {
        var snapshot = twoProjects()
        snapshot.deliveries.append(delivery("a2", order: "o-alpha", taskId: "t4", deliveredAgo: 30))
        snapshot.sessions.append(session("a2", project: "alpha", state: .running, taskId: "t4"))

        let rows = GlobalShutdown.rows(snapshot, now: now)

        XCTAssertEqual(rows.map(\.sessionId), ["a1", "a2", "b1", "b2"])
        XCTAssertEqual(rows.last?.state, .acknowledged, "the closed row did not sort last")
        XCTAssertEqual(rows.prefix(3).filter(\.isClosed), [])
    }
}
