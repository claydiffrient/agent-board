import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoardBridge

/// Delivering the order through the one channel a busy `--bg` worker has — the `PreToolUse` deny —
/// and collecting the answer through `acknowledge_shutdown`.
final class ShutdownWindDownTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    private var deliveries: ShutdownDeliveryStore { ShutdownDeliveryStore(f.db) }

    private func worker(_ title: String = "Do the thing") throws -> (task: BoardTask, sessionId: String, identity: TokenIdentity) {
        let task = try f.task(title, column: .running)
        let sessionId = "session-\(UUID().uuidString)"
        try f.workerSession(sessionId, taskId: task.id)
        return (task, sessionId, f.workerIdentity(sessionId: sessionId, taskId: task.id))
    }

    func testTheNextToolCallIsDeniedWithTheOrderExactlyOnce() async throws {
        let worker = try worker()
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human", reason: "spend")

        let first = await f.preToolUse("swift build", sessionId: worker.sessionId, identity: worker.identity)

        let decision = try XCTUnwrap(first, "the busy worker was never handed the order")
        XCTAssertEqual(decision.permissionDecision, "deny")
        let reason = try XCTUnwrap(decision.reason)
        XCTAssertTrue(reason.contains("acknowledge_shutdown"), reason)
        XCTAssertTrue(reason.contains("Commit whatever is in your worktree"), reason)
        XCTAssertTrue(reason.contains("spend"), reason)

        for command in ["git add -A", "git commit -m wip", "git status"] {
            let next = await f.preToolUse(command, sessionId: worker.sessionId, identity: worker.identity)
            XCTAssertNil(next, "\"\(command)\" was blocked; the worker could not commit")
        }
    }

    func testTheDenyIsPerSessionNotPerProject() async throws {
        let first = try worker("First")
        let second = try worker("Second")
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        let toFirst = await f.preToolUse("swift build", sessionId: first.sessionId, identity: first.identity)
        let toSecond = await f.preToolUse("swift build", sessionId: second.sessionId, identity: second.identity)

        XCTAssertNotNil(toFirst)
        XCTAssertNotNil(toSecond)
        let order = try XCTUnwrap(ShutdownOrderStore(f.db).outstanding(projectId: f.project.id))
        let progress = try deliveries.progress(orderId: order.id)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.acknowledged, 0)
    }

    func testNoOrderMeansNoDeny() async throws {
        let worker = try worker()

        let decision = await f.preToolUse("swift build", sessionId: worker.sessionId, identity: worker.identity)

        XCTAssertNil(decision)
    }

    func testACancelledOrderStopsDelivering() async throws {
        let worker = try worker()
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")
        try f.board.cancelShutdown(projectId: f.project.id, by: "human")

        let decision = await f.preToolUse("swift build", sessionId: worker.sessionId, identity: worker.identity)

        XCTAssertNil(decision)
    }

    /// A push stays blocked while the order is outstanding: the wind-down never unlocks D8.
    func testTheIntegrationGuardStillWinsOverTheWindDownDeny() async throws {
        let worker = try worker()
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        let pushed = await f.preToolUse("git push origin HEAD", sessionId: worker.sessionId, identity: worker.identity)
        let decision = try XCTUnwrap(pushed)

        XCTAssertEqual(decision.permissionDecision, "deny")
        let reason = try XCTUnwrap(decision.reason)
        XCTAssertFalse(reason.contains("acknowledge_shutdown"), reason)
        let order = try XCTUnwrap(ShutdownOrderStore(f.db).outstanding(projectId: f.project.id))
        XCTAssertNil(try deliveries.get(orderId: order.id, sessionId: worker.sessionId)?.deliveredAt)
    }

    func testAcknowledgeShutdownRecordsTheNoteAndTellsAgentBoardToStopTheSession() async throws {
        let worker = try worker()
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")
        _ = await f.preToolUse("swift build", sessionId: worker.sessionId, identity: worker.identity)

        let result = try await f.call(
            "acknowledge_shutdown", ["note": .string("Committed the parser; codegen not started.")], as: worker.identity
        )

        XCTAssertEqual(result.text, "acknowledged — stop now")
        let order = try XCTUnwrap(ShutdownOrderStore(f.db).outstanding(projectId: f.project.id))
        let delivery = try XCTUnwrap(deliveries.get(orderId: order.id, sessionId: worker.sessionId))
        XCTAssertEqual(delivery.note, "Committed the parser; codegen not started.")
        XCTAssertTrue(delivery.isAcknowledged)
        let events = await f.events.events
        XCTAssertTrue(
            events.contains(.workerAcknowledgedShutdown(projectId: f.project.id, sessionId: worker.sessionId)),
            "\(events)"
        )
    }

    /// The tool records the note and hands off; moving the task is the supervisor's half, and it
    /// must never land in review the way `report_complete` does.
    func testAcknowledgeShutdownDoesNotSendTheTaskToReview() async throws {
        let worker = try worker()
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        _ = try await f.call("acknowledge_shutdown", ["note": .string("half done")], as: worker.identity)

        XCTAssertEqual(try f.tasks.get(worker.task.id)?.column, .running)
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).filter { $0.kind == .complete }.count, 0)
    }

    func testAcknowledgeShutdownRefusesWithoutAnOrder() async throws {
        let worker = try worker()

        await XCTAssertToolError(try await f.call("acknowledge_shutdown", ["note": .string("n/a")], as: worker.identity))
    }

    func testAcknowledgeShutdownIsOnTheWorkerScopeOnly() async throws {
        let names = await Set(f.scoped.tools(for: f.orchestratorIdentity).map(\.name))
        XCTAssertFalse(names.contains("acknowledge_shutdown"))

        let worker = try worker()
        let workerNames = await Set(f.scoped.tools(for: worker.identity).map(\.name))
        XCTAssertTrue(workerNames.contains("acknowledge_shutdown"))
    }
}
