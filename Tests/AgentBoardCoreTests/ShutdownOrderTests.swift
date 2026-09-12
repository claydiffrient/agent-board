import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

extension Fixture {
    var shutdowns: ShutdownOrderStore { ShutdownOrderStore(db) }
}

final class ShutdownOrderMigrationTests: XCTestCase {
    func testMigrationCreatesTableAndIndex() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            XCTAssertTrue(try db.tableExists("shutdown_order"))
            let columns = try db.columns(in: "shutdown_order")
            XCTAssertEqual(
                columns.map(\.name),
                ["id", "project_id", "requested_by", "reason", "requested_at", "resolved_at", "resolved_by"]
            )
            XCTAssertTrue(columns.contains { $0.name == "requested_by" && $0.isNotNull })
            XCTAssertTrue(columns.contains { $0.name == "requested_at" && $0.isNotNull })
            XCTAssertEqual(columns.first { $0.name == "resolved_at" }?.isNotNull, false)
            XCTAssertTrue(try db.indexes(on: "shutdown_order").map(\.name).contains("shutdown_order_outstanding"))
        }
    }

    func testOrderRequiresAnExistingProject() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(try f.shutdowns.request(projectId: "missing", requestedBy: "human")) { error in
            XCTAssertEqual(error as? BoardError, .projectNotFound("missing"))
        }
        XCTAssertNil(try f.shutdowns.outstanding(projectId: f.project.id))
    }
}

final class ShutdownOrderStoreTests: XCTestCase {
    func testRequestIsIdempotentWhileOutstanding() throws {
        let f = try Fixture.make()
        let first = try f.shutdowns.request(projectId: f.project.id, requestedBy: "human", reason: "spend")
        XCTAssertTrue(first.isOutstanding)
        XCTAssertEqual(first.requestedBy, "human")
        XCTAssertEqual(first.reason, "spend")
        XCTAssertNil(first.resolvedAt)

        let again = try f.shutdowns.request(projectId: f.project.id, requestedBy: "someone-else")
        XCTAssertEqual(again, first)
        XCTAssertEqual(try f.shutdowns.history(projectId: f.project.id).count, 1)
    }

    func testOrderIsScopedToItsProject() throws {
        let f = try Fixture.make()
        let other = try f.projects.register(name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        try f.shutdowns.request(projectId: f.project.id, requestedBy: "human")
        XCTAssertTrue(try f.shutdowns.isShuttingDown(projectId: f.project.id))
        XCTAssertFalse(try f.shutdowns.isShuttingDown(projectId: other.id))
    }

    func testCancelResolvesAndLeavesHistory() throws {
        let f = try Fixture.make()
        let order = try f.shutdowns.request(projectId: f.project.id, requestedBy: "human")
        let cancelled = try XCTUnwrap(f.shutdowns.cancel(projectId: f.project.id, by: "clay"))

        XCTAssertEqual(cancelled.id, order.id)
        XCTAssertFalse(cancelled.isOutstanding)
        XCTAssertEqual(cancelled.resolvedBy, "clay")
        XCTAssertNotNil(cancelled.resolvedAt)
        XCTAssertNil(try f.shutdowns.outstanding(projectId: f.project.id))
        XCTAssertEqual(try f.shutdowns.history(projectId: f.project.id).map(\.id), [order.id])

        XCTAssertNil(try f.shutdowns.cancel(projectId: f.project.id, by: "clay"), "nothing left to cancel")
    }

    func testASecondOrderCanBeRaisedAfterCancelling() throws {
        let f = try Fixture.make()
        let first = try f.shutdowns.request(projectId: f.project.id, requestedBy: "human")
        try f.shutdowns.cancel(projectId: f.project.id, by: "human")
        let second = try f.shutdowns.request(projectId: f.project.id, requestedBy: "human")

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(try f.shutdowns.outstanding(projectId: f.project.id)?.id, second.id)
        XCTAssertEqual(try f.shutdowns.history(projectId: f.project.id).map(\.id), [first.id, second.id])
    }
}

extension ShutdownOrderStoreTests {
    func testDeletingTheProjectTakesItsOrdersWithIt() throws {
        let f = try Fixture.make()
        try f.shutdowns.request(projectId: f.project.id, requestedBy: "human")
        try f.projects.delete(f.project.id)
        XCTAssertEqual(try f.shutdowns.history(projectId: f.project.id), [])
    }
}

final class ShutdownGateTests: XCTestCase {
    private var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture.make()
        try f.setAutonomy(true)
    }

    private func pending() throws -> [Report] {
        try f.reports.unconsumed(projectId: f.project.id)
    }

    func testSpawnIsRefusedWhileAnOrderIsOutstandingAndAllowedAfterCancelling() throws {
        let task = try f.task("t", column: .ready)
        XCTAssertEqual(try f.board.requestSpawn(taskId: task.id, requestedBy: "orch"), .proceed)

        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")
        guard case .refused(let reason) = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("expected a shutdown refusal")
        }
        XCTAssertEqual(reason, ShutdownOrder.refusal)

        try f.board.cancelShutdown(projectId: f.project.id, by: "human")
        XCTAssertEqual(try f.board.requestSpawn(taskId: task.id, requestedBy: "orch"), .proceed)
    }

    func testRefusalCreatesNoApprovalWithAutonomyOff() throws {
        try f.setAutonomy(false)
        let task = try f.task("t", column: .ready)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        guard case .refused = try f.board.requestSpawn(taskId: task.id, requestedBy: "orch") else {
            return XCTFail("expected a shutdown refusal")
        }
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])
    }

    func testAnOrderOnAnotherProjectDoesNotGateThisOne() throws {
        let other = try f.projects.register(name: "Other", repoPath: "/other", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil)
        let task = try f.task("t", column: .ready)
        try f.board.requestShutdown(projectId: other.id, requestedBy: "human")
        XCTAssertEqual(try f.board.requestSpawn(taskId: task.id, requestedBy: "orch"), .proceed)
    }

    func testRequestAnnouncesTheOrderOnceAndCancelAnnouncesTheRelease() throws {
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "clay", reason: "burning tokens")
        let announced = try pending()
        XCTAssertEqual(announced.count, 1)
        let report = try XCTUnwrap(announced.first)
        XCTAssertEqual(report.kind, .decision)
        XCTAssertNil(report.taskId)
        XCTAssertNil(report.sessionId)
        XCTAssertTrue(report.body.contains("shutdown order is active"), report.body)
        XCTAssertTrue(report.body.contains("spawn_worker"), report.body)
        XCTAssertTrue(report.body.contains("burning tokens"), report.body)
        XCTAssertTrue(report.body.contains("Requested by: clay"), report.body)

        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "clay")
        XCTAssertEqual(try pending().count, 1, "re-raising an outstanding order announces nothing")

        try f.board.cancelShutdown(projectId: f.project.id, by: "clay")
        let afterCancel = try pending()
        XCTAssertEqual(afterCancel.count, 2)
        XCTAssertTrue(try XCTUnwrap(afterCancel.last).body.contains("was cancelled"), afterCancel.last!.body)

        XCTAssertNil(try f.board.cancelShutdown(projectId: f.project.id, by: "clay"))
        XCTAssertEqual(try pending().count, 2, "cancelling nothing announces nothing")
    }

    func testTheBoardKeepsWorkingWhileShutDown() throws {
        let proposal = try f.task("proposed work", column: .proposed, origin: .workerProposal)
        let inReview = try f.task("finished work", column: .review)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        try f.board.promote(taskId: proposal.id)
        XCTAssertEqual(try f.tasks.get(proposal.id)?.column, .ready)

        try f.tasks.move(inReview.id, to: .done)
        XCTAssertEqual(try f.tasks.get(inReview.id)?.column, .done)

        var edited = try XCTUnwrap(f.tasks.get(proposal.id))
        edited.title = "renamed"
        try f.tasks.update(edited)
        XCTAssertEqual(try f.tasks.get(proposal.id)?.title, "renamed")

        let fresh = try f.task("new work", column: .ready)
        XCTAssertEqual(try f.tasks.get(fresh.id)?.column, .ready, "creating and grooming tasks is untouched")
    }

    func testCancelTouchesNothingButTheOrder() throws {
        let task = try f.task("t", column: .ready)
        let session = f.session("running-worker", state: .running, taskId: task.id)
        try f.sessions.insert(session)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        try f.board.cancelShutdown(projectId: f.project.id, by: "human")

        XCTAssertEqual(try f.sessions.get(session.sessionId)?.state, .running)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertEqual(try f.tasks.get(task.id)?.blocked, false)
        XCTAssertEqual(try f.tasks.get(task.id)?.failed, false)
    }
}
