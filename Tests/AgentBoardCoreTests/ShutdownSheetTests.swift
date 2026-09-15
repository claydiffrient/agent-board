import XCTest
@testable import AgentBoardCore

final class ShutdownSheetTests: XCTestCase {
    private let now: Int64 = 1_700_000_000_000
    private let grace = 120

    private func delivery(
        _ sessionId: String, taskId: String? = nil, orderedAgo: Int64, deliveredAgo: Int64? = nil,
        acknowledgedAgo: Int64? = nil, note: String? = nil
    ) -> ShutdownDelivery {
        ShutdownDelivery(
            orderId: "order-1",
            sessionId: sessionId,
            taskId: taskId,
            orderedAt: now - orderedAgo * 1000,
            deliveredAt: deliveredAgo.map { now - $0 * 1000 },
            deliveredVia: deliveredAgo == nil ? nil : .hook,
            acknowledgedAt: acknowledgedAgo.map { now - $0 * 1000 },
            note: note
        )
    }

    private func session(_ id: String, state: SessionState, taskId: String? = nil, endedAgo: Int64? = nil) -> AgentSession {
        AgentSession(
            sessionId: id, shortId: String(id.prefix(8)), projectId: "p", taskId: taskId, role: .worker,
            cwd: "/tmp", state: state, startedAt: now - 600_000,
            endedAt: endedAgo.map { now - $0 * 1000 }
        )
    }

    func testAcknowledgedWins() {
        let state = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 900, deliveredAgo: 880, acknowledgedAgo: 10),
            session: session("a", state: .running),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(state, .acknowledged)
        XCTAssertTrue(state.isClosed)
    }

    /// The grace period runs from delivery. A worker enrolled ten minutes ago whose next tool call
    /// has not happened yet was never told anything, so it is not "not responding".
    func testUndeliveredIsOrderedNotSilent() {
        let state = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 600),
            session: session("a", state: .running),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(state, .ordered)
        XCTAssertFalse(state.isClosed)
    }

    func testDeliveredInsideGraceIsClosing() {
        let state = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 600, deliveredAgo: 119),
            session: session("a", state: .running),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(state, .closing)
    }

    func testGraceBoundaryIsInclusive() {
        let atBoundary = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 600, deliveredAgo: 120),
            session: session("a", state: .running),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        let oneSecondShort = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 600, deliveredAgo: 119),
            session: session("a", state: .running),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(atBoundary, .notResponding)
        XCTAssertEqual(oneSecondShort, .closing)
    }

    /// The sheet's own grace deadline rides the same clock: a suspended worker is not labelled
    /// "not responding" on wake.
    func testASuspendedWorkerIsNotLabelledNotResponding() {
        let row = delivery("a", orderedAgo: 1_300, deliveredAgo: 1_200)
        let slept = ObservedSleep(endedAtMillis: now - 5_000, millis: 1_195_000)

        XCTAssertEqual(
            ShutdownSheetModel.rowState(
                row, session: session("a", state: .running), graceSeconds: grace, awake: .init(nowMillis: now)
            ),
            .notResponding
        )
        XCTAssertEqual(
            ShutdownSheetModel.rowState(
                row, session: session("a", state: .running), graceSeconds: grace,
                awake: .init(nowMillis: now, sleeps: [slept])
            ),
            .closing
        )
    }

    /// A blocked worker is sitting on a permission prompt: no hook fires, so nothing was delivered
    /// and nothing can be. Calling it "not responding" blames it for the human's unanswered prompt.
    func testBlockedSessionReadsAsWaitingOnHuman() {
        let longPastGrace = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 9_000, deliveredAgo: 8_000),
            session: session("a", state: .blocked),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(longPastGrace, .waitingOnHuman)
        XCTAssertFalse(longPastGrace.isClosed)
    }

    func testVanishedSessionCountsAsClosed() {
        let missing = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 600, deliveredAgo: 500),
            session: nil,
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        let dead = ShutdownSheetModel.rowState(
            delivery("b", orderedAgo: 600, deliveredAgo: 500),
            session: session("b", state: .failed, endedAgo: 30),
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(missing, .ended)
        XCTAssertEqual(dead, .ended)
        XCTAssertTrue(missing.isClosed)
        XCTAssertTrue(dead.isClosed)
    }

    func testVanishedSessionClockUsesItsEnd() {
        let rows = ShutdownSheetModel.rows(
            deliveries: [delivery("b", orderedAgo: 600, deliveredAgo: 500)],
            sessions: [session("b", state: .stopped, endedAgo: 30)],
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(rows.first?.since, (now - 30_000).asDate)
    }

    func testRowsCarryTitleShortIdAndNote() {
        let rows = ShutdownSheetModel.rows(
            deliveries: [delivery("3f9a1c2e-0000", taskId: "t1", orderedAgo: 60, deliveredAgo: 50, acknowledgedAgo: 5, note: "stopped after the schema migration")],
            sessions: [session("3f9a1c2e-0000", state: .completed, taskId: "t1", endedAgo: 5)],
            taskTitles: ["t1": "Add login form validation"],
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].taskTitle, "Add login form validation")
        XCTAssertEqual(rows[0].displayShortId, "3f9a1c2e")
        XCTAssertEqual(rows[0].note, "stopped after the schema migration")
        XCTAssertEqual(rows[0].state, .acknowledged)
    }

    func testRowsPutOutstandingWorkFirst() {
        let rows = ShutdownSheetModel.rows(
            deliveries: [
                delivery("done", orderedAgo: 600, deliveredAgo: 590, acknowledgedAgo: 400),
                delivery("silent", orderedAgo: 600, deliveredAgo: 590),
                delivery("blocked", orderedAgo: 600),
            ],
            sessions: [
                session("done", state: .completed, endedAgo: 400),
                session("silent", state: .running),
                session("blocked", state: .blocked),
            ],
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(rows.map(\.sessionId), ["silent", "blocked", "done"])
        XCTAssertEqual(rows.map(\.state), [.notResponding, .waitingOnHuman, .acknowledged])
    }

    func testCountsCloseOutADeadSessionTheReportedProgressStillCallsPending() {
        let rows = ShutdownSheetModel.rows(
            deliveries: [
                delivery("a", orderedAgo: 600, deliveredAgo: 590, acknowledgedAgo: 300),
                delivery("b", orderedAgo: 600, deliveredAgo: 590),
                delivery("c", orderedAgo: 600, deliveredAgo: 590),
            ],
            sessions: [
                session("a", state: .completed, endedAgo: 300),
                session("b", state: .failed, endedAgo: 20),
                session("c", state: .running),
            ],
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        let reported = ShutdownProgress(orderId: "order-1", total: 3, acknowledged: 1, overdue: ["b", "c"])
        let counts = ShutdownSheetModel.counts(rows: rows, reported: reported)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.closed, 2)
        XCTAssertEqual(counts.notResponding, 1)
        XCTAssertEqual(counts.outstanding, 1)
        XCTAssertFalse(counts.isComplete)
        XCTAssertEqual(counts.headline, "Closing 2/3 agents")
    }

    func testCountsCompleteWhenEveryRowIsClosed() {
        let rows = ShutdownSheetModel.rows(
            deliveries: (1...7).map { delivery("s\($0)", orderedAgo: 600, deliveredAgo: 590, acknowledgedAgo: 100) },
            sessions: (1...7).map { session("s\($0)", state: .completed, endedAgo: 100) },
            graceSeconds: grace,
            awake: .init(nowMillis: now)
        )
        let counts = ShutdownSheetModel.counts(
            rows: rows,
            reported: ShutdownProgress(orderId: "order-1", total: 7, acknowledged: 7)
        )
        XCTAssertTrue(counts.isComplete)
        XCTAssertEqual(counts.headline, "7/7 agents closed")
    }

    /// The order is raised before the deliveries land, so the sheet's first paint has a total and no
    /// rows. Trusting the row count alone would flash "0/0 agents closed" and offer Quit.
    func testReportedTotalWinsBeforeRowsArrive() {
        let counts = ShutdownSheetModel.counts(
            rows: [],
            reported: ShutdownProgress(orderId: "order-1", total: 4, acknowledged: 0)
        )
        XCTAssertEqual(counts.total, 4)
        XCTAssertEqual(counts.closed, 0)
        XCTAssertFalse(counts.isComplete)
        XCTAssertEqual(counts.headline, "Closing 0/4 agents")
    }

    func testNoWorkersIsCompleteAndSaysSo() {
        let counts = ShutdownSheetModel.counts(rows: [], reported: ShutdownProgress(orderId: "order-1", total: 0, acknowledged: 0))
        XCTAssertTrue(counts.isComplete)
        XCTAssertEqual(counts.headline, "No workers were running")
    }

    func testZeroGraceCallsAnUndeliveredRowOrderedNotSilent() {
        let state = ShutdownSheetModel.rowState(
            delivery("a", orderedAgo: 600),
            session: session("a", state: .running),
            graceSeconds: 0,
            awake: .init(nowMillis: now)
        )
        XCTAssertEqual(state, .ordered)
    }
}
