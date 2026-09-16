import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// The handoff seen from the spawn side: the second rostered agent works the checkout the first one
/// left behind, and nothing can put two live sessions into it.
@MainActor
final class HandOffSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func readyTask(_ title: String = "Ship search") throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do the thing.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    private func handOff(_ task: BoardTask, sessionId: String, nextRole: String) throws {
        try fixture.board.handOff(
            taskId: task.id, sessionId: sessionId, summary: "Did the \(nextRole) groundwork.",
            nextRole: nextRole, filesChanged: ["work.txt"]
        )
    }

    func testTheSecondRosteredAgentGetsTheWorktreeTheFirstOneLeft() async throws {
        let task = try readyTask()
        try await fixture.supervisor.assign(taskId: task.id)
        let first = try XCTUnwrap(fixture.sessions.forTask(task.id).first)
        let worktree = try XCTUnwrap(first.worktreePath)
        try fixture.commitInto(worktree)
        let headAfterFirst = try trimmed(SupervisorFixture.git(["rev-parse", "HEAD"], cwd: URL(fileURLWithPath: worktree)))

        try handOff(task, sessionId: first.sessionId, nextRole: "reviewer")
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)

        try await fixture.supervisor.assign(taskId: task.id)

        let sessions = try fixture.sessions.forTask(task.id)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.compactMap(\.worktreePath)), [worktree])
        let second = try XCTUnwrap(sessions.first { $0.sessionId != first.sessionId })
        XCTAssertEqual(second.attempt, 2)
        XCTAssertEqual(second.branch, "agentboard/\(task.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(
            try trimmed(SupervisorFixture.git(["rev-parse", "HEAD"], cwd: URL(fileURLWithPath: worktree))),
            headAfterFirst,
            "the second agent must see the first agent's commit"
        )
        XCTAssertEqual(try fixture.sessions.active(projectId: fixture.project.id).map(\.sessionId), [second.sessionId])
    }

    func testAssigningATaskItsOwnLiveSessionStillHoldsIsRefusedBeforeAnythingSpawns() async throws {
        let task = try readyTask()
        try await fixture.supervisor.assign(taskId: task.id)
        let first = try XCTUnwrap(fixture.sessions.forTask(task.id).first)
        // The state a hand-off would leave if it released the task without releasing the session.
        try fixture.tasks.move(task.id, to: .ready)

        do {
            try await fixture.supervisor.assign(taskId: task.id)
            XCTFail("a second agent was spawned into \(first.worktreePath ?? "?")")
        } catch let error as SupervisorError {
            guard case .taskAlreadyHeld(_, let holder) = error else {
                return XCTFail("expected taskAlreadyHeld, got \(error)")
            }
            XCTAssertEqual(holder, first.sessionId)
        }

        XCTAssertEqual(try fixture.sessions.forTask(task.id).count, 1)
        await fixture.supervisor.waitForSetup()
        let spawns = await fixture.runtime.spawns.count
        XCTAssertEqual(spawns, 1, "the refused assignment still launched a process")
    }

    func testTwoTasksCannotBeSpawnedIntoOneCheckout() async throws {
        let held = try readyTask("First")
        try await fixture.supervisor.assign(taskId: held.id)
        let holder = try XCTUnwrap(fixture.sessions.forTask(held.id).first)
        let worktree = try XCTUnwrap(holder.worktreePath)

        let other = try readyTask("Second")
        XCTAssertThrowsError(
            try fixture.board.assign(
                taskId: other.id,
                session: AgentSession(
                    sessionId: "intruder", projectId: fixture.project.id, taskId: other.id, role: .worker,
                    worktreePath: worktree, cwd: worktree, state: .running
                )
            )
        ) {
            XCTAssertEqual($0 as? BoardError, .worktreeAlreadyHeld(path: worktree, sessionId: holder.sessionId))
        }
        XCTAssertEqual(try fixture.tasks.get(other.id)?.column, .ready)
    }

    /// World A of the spike's finding: the handing process is still alive. Reconcile sees it running
    /// and must leave the released row alone, or the task could never be assigned to anyone again.
    func testReconcileDoesNotPutAHandedOffSessionBackToWork() async throws {
        let task = try readyTask()
        try await fixture.supervisor.assign(taskId: task.id)
        let first = try XCTUnwrap(fixture.sessions.forTask(task.id).first)
        try handOff(task, sessionId: first.sessionId, nextRole: "reviewer")

        await fixture.runtime.setListed([
            AgentInfo(
                id: first.shortId, cwd: first.worktreePath ?? "/tmp", kind: "agent",
                sessionId: first.sessionId, state: "running", status: "running"
            ),
        ])
        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertEqual(try fixture.sessions.get(first.sessionId)?.state, .completed)
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
        XCTAssertNil(try fixture.sessions.activeHolder(taskId: task.id))

        try await fixture.supervisor.assign(taskId: task.id)
        XCTAssertEqual(try fixture.sessions.forTask(task.id).count, 2)
    }

    private func trimmed(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
