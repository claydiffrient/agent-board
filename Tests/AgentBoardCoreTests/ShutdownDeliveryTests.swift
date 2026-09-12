import Foundation
import XCTest
@testable import AgentBoardCore

/// The record-keeping half of the wind-down: who was ordered, who answered, and what an
/// acknowledged worker's termination does to its task.
final class ShutdownDeliveryTests: XCTestCase {
    private var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture.make()
    }

    private var deliveries: ShutdownDeliveryStore { ShutdownDeliveryStore(f.db) }

    @discardableResult
    private func runningWorker(_ title: String = "Do the thing") throws -> (task: BoardTask, session: AgentSession) {
        let task = try f.task(title, column: .running)
        let session = f.session(taskId: task.id)
        try f.sessions.insert(session)
        return (task, session)
    }

    @discardableResult
    private func order(reason: String? = nil) throws -> ShutdownOrder {
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human", reason: reason)
    }

    func testDeliveryIsClaimedExactlyOncePerSession() throws {
        let worker = try runningWorker()
        let order = try order()

        let first = try deliveries.claimDelivery(
            orderId: order.id, sessionId: worker.session.sessionId, taskId: worker.task.id, via: .hook
        )
        let second = try deliveries.claimDelivery(
            orderId: order.id, sessionId: worker.session.sessionId, taskId: worker.task.id, via: .hook
        )
        let third = try deliveries.claimDelivery(
            orderId: order.id, sessionId: worker.session.sessionId, taskId: worker.task.id, via: .resume
        )

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertFalse(third)
        let row = try XCTUnwrap(deliveries.get(orderId: order.id, sessionId: worker.session.sessionId))
        XCTAssertEqual(row.deliveredVia, .hook)
    }

    func testAReleasedClaimCanBeDeliveredAgain() throws {
        let worker = try runningWorker()
        let order = try order()

        XCTAssertTrue(try deliveries.claimDelivery(
            orderId: order.id, sessionId: worker.session.sessionId, taskId: worker.task.id, via: .resume
        ))
        try deliveries.releaseDelivery(orderId: order.id, sessionId: worker.session.sessionId)

        XCTAssertTrue(try deliveries.claimDelivery(
            orderId: order.id, sessionId: worker.session.sessionId, taskId: worker.task.id, via: .hook
        ))
    }

    func testAcknowledgeRecordsTheNoteAgainstTheOrderAndTheTask() throws {
        let worker = try runningWorker()
        let order = try order()

        let ack = try f.board.acknowledgeShutdown(sessionId: worker.session.sessionId, note: "Parser done; codegen untouched.")

        XCTAssertEqual(ack.order.id, order.id)
        XCTAssertEqual(ack.taskId, worker.task.id)
        XCTAssertEqual(ack.delivery.note, "Parser done; codegen untouched.")
        XCTAssertNotNil(ack.delivery.acknowledgedAt)
        let entries = try f.progress.list(taskId: worker.task.id)
        XCTAssertEqual(entries.first?.text, "Shutdown acknowledged: Parser done; codegen untouched.")
    }

    func testAcknowledgeWithoutAnOutstandingOrderThrows() throws {
        let worker = try runningWorker()

        XCTAssertThrowsError(try f.board.acknowledgeShutdown(sessionId: worker.session.sessionId, note: "n/a")) { error in
            XCTAssertEqual(error as? BoardError, .noShutdownOrder(f.project.id))
        }
    }

    func testTerminatingAnAcknowledgedWorkerReturnsTheTaskToReadyWithTheNote() throws {
        let worker = try runningWorker()
        try order()
        let ack = try f.board.acknowledgeShutdown(sessionId: worker.session.sessionId, note: "Stopped after the schema migration.")

        let report = try XCTUnwrap(f.board.terminate(
            sessionId: worker.session.sessionId, cause: .shutdownAcknowledged(note: ack.delivery.note)
        ))

        let task = try XCTUnwrap(f.tasks.get(worker.task.id))
        XCTAssertEqual(task.column, .ready, "an unfinished wind-down must not look accepted")
        XCTAssertFalse(task.failed, "an orderly shutdown is not a failure")
        XCTAssertEqual(try f.sessions.get(worker.session.sessionId)?.state, .stopped)
        XCTAssertEqual(report.kind, .decision)
        XCTAssertTrue(report.body.contains("wound down for the shutdown order"), report.body)
        XCTAssertTrue(report.body.contains("Stopped after the schema migration."), report.body)
        XCTAssertFalse(report.body.contains("ended without reporting"), report.body)
    }

    /// A cap kill and a human stop keep reading as such; the distinction is the whole point of the
    /// new cause when the task is picked back up.
    func testOtherTerminationCausesAreUnchanged() throws {
        let capped = try runningWorker("Capped")
        let killed = try runningWorker("Killed")

        let capReport = try XCTUnwrap(f.board.terminate(sessionId: capped.session.sessionId, cause: .capBreach("token cap reached")))
        let killReport = try XCTUnwrap(f.board.terminate(sessionId: killed.session.sessionId, cause: .stoppedByHuman))

        XCTAssertEqual(capReport.kind, .failed)
        XCTAssertTrue(capReport.body.contains("ended without reporting"), capReport.body)
        XCTAssertEqual(try f.tasks.get(capped.task.id)?.failed, true)
        XCTAssertEqual(killReport.kind, .failed)
        XCTAssertEqual(try f.tasks.get(killed.task.id)?.failed, false)
    }

    func testProgressCountsOrderedAcknowledgedAndOverdue() throws {
        let quick = try runningWorker("Quick")
        let slow = try runningWorker("Slow")
        let order = try order()
        let orderedAt = Int64.nowMillis

        for worker in [quick, slow] {
            try deliveries.enroll(
                orderId: order.id, sessionId: worker.session.sessionId, taskId: worker.task.id, at: orderedAt
            )
        }

        var progress = try deliveries.progress(orderId: order.id, graceSeconds: 120, now: orderedAt)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.acknowledged, 0)
        XCTAssertEqual(progress.unacknowledged, 2)
        XCTAssertEqual(progress.overdue, [])
        XCTAssertFalse(progress.isComplete)

        try f.board.acknowledgeShutdown(sessionId: quick.session.sessionId, note: "committed")

        progress = try deliveries.progress(orderId: order.id, graceSeconds: 120, now: orderedAt + 121_000)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.acknowledged, 1)
        XCTAssertEqual(progress.unacknowledged, 1)
        XCTAssertEqual(progress.overdue, [slow.session.sessionId])
        XCTAssertFalse(progress.isComplete)

        try f.board.acknowledgeShutdown(sessionId: slow.session.sessionId, note: "late but here")

        progress = try deliveries.progress(orderId: order.id, graceSeconds: 120, now: orderedAt + 300_000)
        XCTAssertEqual(progress.acknowledged, 2)
        XCTAssertEqual(progress.overdue, [])
        XCTAssertTrue(progress.isComplete)
    }

    func testTheWindDownTextIsTheSameOrderOnBothPaths() {
        let hook = ShutdownOrder.windDownOrder(reason: "spend", via: .hook)
        let resume = ShutdownOrder.windDownOrder(reason: "spend", via: .resume)

        for text in [hook, resume] {
            XCTAssertTrue(text.contains("acknowledge_shutdown"), text)
            XCTAssertTrue(text.contains("Do not push"), text)
            XCTAssertTrue(text.contains("ready, not review"), text)
            XCTAssertTrue(text.contains("spend"), text)
        }
        XCTAssertTrue(hook.contains("blocked to hand you the order"), hook)
        XCTAssertFalse(resume.contains("blocked to hand you the order"), resume)
    }

    func testTheGraceDefaultMatchesTheStallShape() {
        XCTAssertEqual(Caps().shutdownGraceSeconds, 120)
        XCTAssertEqual(ShutdownDeliveryStore.defaultGraceSeconds, 120)
        let decoded = ProjectSettings.decode(#"{"caps":{"shutdownGraceSeconds":45}}"#)
        XCTAssertEqual(decoded.caps.shutdownGraceSeconds, 45)
        XCTAssertEqual(ProjectSettings.decode("{}").caps.shutdownGraceSeconds, 120)
    }
}
