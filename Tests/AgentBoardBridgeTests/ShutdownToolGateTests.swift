import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoardBridge

/// A shutdown order stops dispatch, not the board: `spawn_worker` refuses, everything else works.
final class ShutdownToolGateTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        try f.setAutonomy(true)
    }

    private var shutdowns: ShutdownOrderStore { ShutdownOrderStore(f.db) }

    func testSpawnWorkerRefusesWithTheShutdownMessageAndSpawnsNothing() async throws {
        let task = try f.task("Wire it", column: .ready)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        await XCTAssertToolError(
            try await f.call("spawn_worker", ["task_id": .string(task.id)]),
            containing: ShutdownOrder.refusal
        )
        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
    }

    func testSpawnWorkerSucceedsOnceTheOrderIsCancelled() async throws {
        let task = try f.task("Wire it", column: .ready)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")
        await XCTAssertToolError(try await f.call("spawn_worker", ["task_id": .string(task.id)]))

        try f.board.cancelShutdown(projectId: f.project.id, by: "human")

        let result = try await f.call("spawn_worker", ["task_id": .string(task.id)])
        XCTAssertTrue(result.text.contains("session-for-\(task.id)"), result.text)
        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [task.id])
    }

    func testPromoteProposalAndTaskEditsStillWorkUnderAnOrder() async throws {
        let proposal = try f.task("Proposed work", column: .proposed)
        let groomed = try f.task("Groomed work", column: .ready)
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human")

        _ = try await f.call("promote_proposal", ["task_id": .string(proposal.id)])
        XCTAssertEqual(try f.tasks.get(proposal.id)?.column, .ready)

        _ = try await f.call("move_task", ["id": .string(groomed.id), "column": .string("review")])
        XCTAssertEqual(try f.tasks.get(groomed.id)?.column, .review)

        _ = try await f.call("update_task", ["id": .string(proposal.id), "title": .string("Renamed")])
        XCTAssertEqual(try f.tasks.get(proposal.id)?.title, "Renamed")

        let created = try await f.callJSON("create_task", ["title": .string("More work")])
        XCTAssertEqual(created["column"], .string("ready"))
    }

    func testTheOrchestratorReadsTheAnnouncementThroughListReports() async throws {
        try f.board.requestShutdown(projectId: f.project.id, requestedBy: "human", reason: "spend")

        let reports = try await f.callJSON("list_reports").arrayValue ?? []
        XCTAssertEqual(reports.count, 1)
        let body = try XCTUnwrap(reports.first?["body"]?.stringValue)
        XCTAssertEqual(reports.first?["kind"], .string("decision"))
        XCTAssertTrue(body.contains("shutdown order is active"), body)
        XCTAssertTrue(body.contains("No further spawns will succeed"), body)
        XCTAssertTrue(body.contains("spend"), body)
    }

    func testAnOrderOnAnotherProjectDoesNotGateThisOne() async throws {
        let other = try f.otherProject()
        let task = try f.task("Wire it", column: .ready)
        try f.board.requestShutdown(projectId: other.id, requestedBy: "human")

        _ = try await f.call("spawn_worker", ["task_id": .string(task.id)])
        let spawned = await f.control.spawned
        XCTAssertEqual(spawned, [task.id])
    }
}
