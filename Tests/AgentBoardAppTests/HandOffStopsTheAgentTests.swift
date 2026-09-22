import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// A hand-off ends its session as squarely as `report_complete` does, and it used to raise nothing:
/// the agent stayed resident until the next launch sweep. The task it handed back is in `ready` and
/// may be dispatched into that same worktree at once, so the resident process is not only memory —
/// it is a second `claude` in one checkout.
@MainActor
final class HandOffStopsTheAgentTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        await fixture.supervisor.start()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    @discardableResult
    private func handOff(
        _ worker: (task: BoardTask, sessionId: String, token: String), nextRole: String = "reviewer"
    ) async throws -> ToolResult {
        try await fixture.callWorkerTool(
            "hand_off",
            arguments: .object([
                "summary": .string("Wrote the query layer; the UI is untouched."),
                "next_role": .string(nextRole),
                "files_changed": .array([.string("Sources/Search.swift")]),
            ]),
            token: worker.token
        )
    }

    private func reportComplete(_ worker: (task: BoardTask, sessionId: String, token: String)) async throws {
        _ = try await fixture.callWorkerTool(
            "report_complete",
            arguments: .object([
                "summary": .string("did the thing"),
                "files_changed": .array([.string("Sources/Thing.swift")]),
                "tests_run": .string("swift test"),
                "caveats": .string("none"),
            ]),
            token: worker.token
        )
    }

    func testHandOffStopsTheSessionsAgentAtOnceRatherThanLeavingItToTheSweep() async throws {
        let worker = try fixture.workerAtWork()
        let shortId = try XCTUnwrap(fixture.sessions.get(worker.sessionId)?.shortId)
        // The session is written after `start()`, so the launch sweep never saw it and every stop
        // recorded from here can only have come from the hand-off itself.
        let beforeHandOff = await fixture.runtime.stopped
        XCTAssertEqual(beforeHandOff, [])

        try await handOff(worker)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [shortId], "the handed-off worker's agent was left for the periodic sweep")
        XCTAssertEqual(try fixture.sessions.get(worker.sessionId)?.state, .completed)
        XCTAssertEqual(try fixture.tasks.get(worker.task.id)?.column, .ready)
    }

    /// The stop must take neither the worktree nor the short id: D6 gives the next agent this same
    /// checkout, and a removed session loses the spawn options its resume would need.
    func testTheStopKeepsTheWorktreeAndTheShortIdForTheNextAgent() async throws {
        let worker = try fixture.workerAtWork()
        let worktreePath = try XCTUnwrap(fixture.sessions.get(worker.sessionId)?.worktreePath)

        try await handOff(worker)

        let removed = await fixture.runtime.removed
        XCTAssertEqual(removed, [], "the hand-off removed the session, stripping its saved spawn options")
        let session = try XCTUnwrap(fixture.sessions.get(worker.sessionId))
        XCTAssertEqual(session.worktreePath, worktreePath)
        XCTAssertNotNil(session.shortId, "nothing can address the session afterwards")
    }

    /// A row with no short id — a setup that never produced an agent — has nothing to stop, and the
    /// hand-off must not invent one.
    func testAnUnpromotedSessionRowStopsNothing() async throws {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Never launched", body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        let sessionId = "session-\(UUID().uuidString)"
        try fixture.sessions.insert(AgentSession(
            sessionId: sessionId, projectId: fixture.project.id, taskId: task.id, role: .worker,
            cwd: fixture.supportDir.path, state: .running
        ))
        let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: task.id)
        try fixture.grants.bind(token: grant.token, sessionId: sessionId)

        try await handOff((task: task, sessionId: sessionId, token: grant.token))

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .ready)
    }

    /// Both paths now stop their agent through the one signal. What separates them is board state,
    /// and this is the assertion that keeps it that way: same session state, different column,
    /// different report kind, different stop reason.
    func testAHandOffIsStillTellableApartFromACompletionAfterBothStopTheirAgent() async throws {
        let handed = try fixture.workerAtWork("Hand this one back")
        let finished = try fixture.workerAtWork("Finish this one")
        let handedShortId = try XCTUnwrap(fixture.sessions.get(handed.sessionId)?.shortId)
        let finishedShortId = try XCTUnwrap(fixture.sessions.get(finished.sessionId)?.shortId)

        try await handOff(handed)
        try await reportComplete(finished)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(Set(stopped), Set([handedShortId, finishedShortId]))

        XCTAssertEqual(try fixture.sessions.get(handed.sessionId)?.state, .completed)
        XCTAssertEqual(try fixture.sessions.get(finished.sessionId)?.state, .completed)
        XCTAssertEqual(try fixture.tasks.get(handed.task.id)?.column, .ready)
        XCTAssertEqual(try fixture.tasks.get(finished.task.id)?.column, .review)
        XCTAssertEqual(try fixture.reports.latest(taskId: handed.task.id)?.kind, .handoff)
        XCTAssertEqual(try fixture.reports.latest(taskId: finished.task.id)?.kind, .complete)
        XCTAssertEqual(try fixture.sessions.get(handed.sessionId)?.stopReason, "handed off to reviewer")
        XCTAssertNotEqual(try fixture.sessions.get(finished.sessionId)?.stopReason, "handed off to reviewer")
    }

    /// The cross-project status page counts a handed-off task as queued work, not as something
    /// waiting for a human, and its session stops counting against the concurrency cap — both of
    /// which follow from the column and the session state rather than from the stop.
    func testAHandedOffTaskCountsAsReadyAndFreesItsCapSlot() async throws {
        var settings = fixture.project.settings
        settings.caps.maxConcurrentWorkers = 1
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        let worker = try fixture.workerAtWork()
        XCTAssertFalse(try fixture.board.canSpawn(projectId: fixture.project.id).isAllowed)

        try await handOff(worker)

        XCTAssertTrue(try fixture.board.canSpawn(projectId: fixture.project.id).isAllowed)
        let glance = try GlanceStore(fixture.db).summary()
        let project = try XCTUnwrap(glance.projects.first { $0.id == fixture.project.id })
        XCTAssertEqual(project.ready, 1)
        XCTAssertEqual(project.review, 0)
        XCTAssertEqual(project.running, 0)
        XCTAssertEqual(glance.workingSessions, 0)
        XCTAssertEqual(glance.tasksInReview, 0)
    }
}
