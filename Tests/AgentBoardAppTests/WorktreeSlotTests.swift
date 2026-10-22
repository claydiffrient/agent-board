import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §3.1 step 2, against a real git repository: a slot's whole point is what git leaves in it.
@MainActor
final class WorktreeSlotTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        await fixture.cleanUp()
        fixture = nil
    }

    private func useSlots(_ count: Int) throws {
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.worktreeSlots = count
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    private func spawn(_ title: String) async throws -> (task: BoardTask, worktree: String) {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let session = try XCTUnwrap(fixture.sessions.forTask(task.id).first)
        return (task, try XCTUnwrap(session.worktreePath))
    }

    private func slot(_ n: Int) -> String {
        URL(fileURLWithPath: fixture.project.worktreeRoot).appendingPathComponent("slot-\(n)").path
    }

    private func branch(at path: String) throws -> String {
        try SupervisorFixture.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: URL(fileURLWithPath: path))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTwoSpawnsLeaseDifferentSlotsAndAReleasedSlotIsReusedWithItsBuildOutput() async throws {
        try useSlots(2)
        try ".build/\n".write(
            to: fixture.repo.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8
        )

        let first = try await spawn("First")
        // The lease is the task's, so a worker that stopped without finishing still keeps its slot.
        let firstSession = try XCTUnwrap(fixture.sessions.forTask(first.task.id).first)
        try fixture.sessions.setState(firstSession.sessionId, .stopped, endedAt: .nowMillis)
        let second = try await spawn("Second")

        XCTAssertEqual(first.worktree, slot(1))
        XCTAssertEqual(second.worktree, slot(2))
        XCTAssertEqual(try branch(at: slot(1)), "agentboard/\(first.task.id)")
        XCTAssertEqual(try branch(at: slot(2)), "agentboard/\(second.task.id)")

        let build = URL(fileURLWithPath: slot(1)).appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "warm".write(to: build.appendingPathComponent("output"), atomically: true, encoding: .utf8)
        try await fixture.supervisor.discard(taskId: first.task.id)

        let third = try await spawn("Third")

        XCTAssertEqual(third.worktree, slot(1), "the released slot was not reused")
        XCTAssertEqual(try branch(at: slot(1)), "agentboard/\(third.task.id)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: build.appendingPathComponent("output").path),
            "releasing the slot deleted its ignored build output"
        )
    }

    func testEverySlotLeasedGivesTheSpawnAWorktreeOfItsOwn() async throws {
        try useSlots(1)

        let first = try await spawn("First")
        let second = try await spawn("Second")

        XCTAssertEqual(first.worktree, slot(1))
        let own = URL(fileURLWithPath: fixture.project.worktreeRoot).appendingPathComponent(second.task.id).path
        XCTAssertEqual(second.worktree, own)
        XCTAssertEqual(try branch(at: own), "agentboard/\(second.task.id)")
        XCTAssertEqual(try fixture.tasks.get(second.task.id)?.column, .running)
    }
}
