import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// Delivering the order to real sessions and collecting what comes back: a busy worker is left to
/// the hook, an idle one is resumed with the same text, and a silent one is counted, never killed.
@MainActor
final class ShutdownDeliveryTests: XCTestCase {
    private var fixture: SupervisorFixture!

    private var shutdowns: ShutdownOrderStore { ShutdownOrderStore(fixture.db) }
    private var deliveries: ShutdownDeliveryStore { ShutdownDeliveryStore(fixture.db) }
    private var reports: ReportStore { ReportStore(fixture.db) }

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    @discardableResult
    private func order(reason: String? = nil) async throws -> ShutdownOrder {
        try await fixture.supervisor.requestShutdown(
            projectId: fixture.project.id, requestedBy: "human", reason: reason
        )
    }

    @discardableResult
    private func worker(_ title: String, state: SessionState) throws -> (task: BoardTask, sessionId: String) {
        let (task, sessionId, _) = try fixture.workerAtWork(title)
        try fixture.sessions.setState(sessionId, state)
        try fixture.tasks.move(task.id, to: .running)
        return (task, sessionId)
    }

    private var progress: ShutdownProgress? {
        fixture.supervisor.shutdownProgress[fixture.project.id]
    }

    func testAnIdleWorkerIsResumedWithTheOrderAndABusyOneIsNot() async throws {
        let idle = try worker("Idle work", state: .idle)
        let busy = try worker("Busy work", state: .running)
        let order = try await order(reason: "end of the day")

        try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)

        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [idle.sessionId], "the busy worker rides its next hook instead")
        let prompt = await fixture.runtime.resumePrompts.first
        let text = try XCTUnwrap(prompt)
        XCTAssertEqual(text, ShutdownOrder.windDownOrder(reason: "end of the day", via: .resume))
        XCTAssertTrue(text.contains("acknowledge_shutdown"), text)

        XCTAssertEqual(try deliveries.get(orderId: order.id, sessionId: idle.sessionId)?.deliveredVia, .resume)
        XCTAssertNil(try deliveries.get(orderId: order.id, sessionId: busy.sessionId)?.deliveredAt)
        XCTAssertEqual(progress?.total, 2, "both workers are ordered, even the one not yet reached")
        XCTAssertEqual(progress?.acknowledged, 0)
    }

    func testDeliveringStopsNoWorker() async throws {
        try worker("Idle work", state: .idle)
        try worker("Busy work", state: .running)
        try await order()

        try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [], "delivery tells workers to stop themselves; it never kills one")
        XCTAssertEqual(try fixture.sessions.active(projectId: fixture.project.id).count, 2)
    }

    func testDeliveringWithoutAnOrderThrows() async throws {
        try worker("Busy work", state: .running)

        do {
            try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? SupervisorError)?.errorDescription, "no shutdown order is outstanding on this project")
        }
    }

    func testAcknowledgingStopsTheSessionAndReturnsTheTaskToReady() async throws {
        let busy = try worker("Busy work", state: .running)
        let order = try await order()
        try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)
        _ = try deliveries.claimDelivery(orderId: order.id, sessionId: busy.sessionId, taskId: busy.task.id, via: .hook)

        try fixture.board.acknowledgeShutdown(sessionId: busy.sessionId, note: "Ported two of five callers.")
        await fixture.supervisor.workerAcknowledgedShutdown(projectId: fixture.project.id, sessionId: busy.sessionId)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["short-\(busy.sessionId)"])
        let session = try XCTUnwrap(fixture.sessions.get(busy.sessionId))
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(session.stopReason, "wound down for the project shutdown order and acknowledged")

        let task = try XCTUnwrap(fixture.tasks.get(busy.task.id))
        XCTAssertEqual(task.column, .ready, "unfinished work must not look accepted")
        XCTAssertFalse(task.failed)

        let queued = try reports.unconsumed(projectId: fixture.project.id)
        let windDown = try XCTUnwrap(queued.last)
        XCTAssertEqual(windDown.kind, .decision, "an orderly shutdown is not a failed report")
        XCTAssertTrue(windDown.body.contains("Ported two of five callers."), windDown.body)
        XCTAssertTrue(try fixture.grants.forSession(busy.sessionId).allSatisfy(\.isRevoked))
        XCTAssertEqual(progress?.acknowledged, 1)
        XCTAssertEqual(progress?.total, 1)
        XCTAssertEqual(progress?.unacknowledged, 0)
        XCTAssertEqual(progress?.isComplete, true)
    }

    func testAWorkerThatNeverAnswersIsCountedUnacknowledgedAndLeftRunning() async throws {
        try fixture.setGraceSeconds(1)
        let silent = try worker("Silent work", state: .running)
        let order = try await order()
        try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)

        XCTAssertEqual(progress?.unacknowledged, 1)
        XCTAssertEqual(progress?.overdue, [], "the grace period has not expired yet")

        try fixture.age(orderId: order.id, sessionId: silent.sessionId, bySeconds: 2)
        let expired = try deliveries.progress(orderId: order.id, graceSeconds: 1)

        XCTAssertEqual(expired.total, 1)
        XCTAssertEqual(expired.acknowledged, 0)
        XCTAssertEqual(expired.unacknowledged, 1)
        XCTAssertEqual(expired.overdue, [silent.sessionId])

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [], "killing a silent worker is the human's decision, not this one's")
        XCTAssertEqual(try fixture.sessions.get(silent.sessionId)?.state, .running)
        XCTAssertEqual(try fixture.tasks.get(silent.task.id)?.column, .running)
    }

    func testTheCountsTrackASecondWorkerAcrossTheWholeWindDown() async throws {
        let first = try worker("First", state: .running)
        let second = try worker("Second", state: .running)
        try await order()

        try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)
        XCTAssertEqual(progress?.total, 2)
        XCTAssertEqual(progress?.acknowledged, 0)
        XCTAssertEqual(progress?.unacknowledged, 2)

        try fixture.board.acknowledgeShutdown(sessionId: first.sessionId, note: "one")
        await fixture.supervisor.workerAcknowledgedShutdown(projectId: fixture.project.id, sessionId: first.sessionId)
        XCTAssertEqual(progress?.acknowledged, 1)
        XCTAssertEqual(progress?.unacknowledged, 1)
        XCTAssertEqual(progress?.isComplete, false)

        try fixture.board.acknowledgeShutdown(sessionId: second.sessionId, note: "two")
        await fixture.supervisor.workerAcknowledgedShutdown(projectId: fixture.project.id, sessionId: second.sessionId)
        XCTAssertEqual(progress?.acknowledged, 2)
        XCTAssertEqual(progress?.isComplete, true)

        try await fixture.supervisor.cancelShutdown(projectId: fixture.project.id, by: "human")
        XCTAssertNil(progress, "a cancelled order leaves nothing for the sheet to show")
    }

    /// The orchestrator is not a worker and is never told to wind down by this path.
    func testTheOrchestratorSessionIsNotOrdered() async throws {
        try worker("Busy work", state: .running)
        try fixture.sessions.insert(AgentSession(
            sessionId: "orch-session", shortId: "short-orch", projectId: fixture.project.id,
            role: .orchestrator, cwd: fixture.supportDir.path, state: .running
        ))
        try await order()

        let progress = try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)

        XCTAssertEqual(progress.total, 1)
        let order = try XCTUnwrap(shutdowns.outstanding(projectId: fixture.project.id))
        XCTAssertNil(try deliveries.get(orderId: order.id, sessionId: "orch-session"))
    }
}
