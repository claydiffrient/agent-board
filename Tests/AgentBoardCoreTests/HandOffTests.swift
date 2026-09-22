import Foundation
import XCTest
@testable import AgentBoardCore

/// A rostered agent does its portion and returns the task to the queue. The invariant under test
/// throughout is that exactly one live session ever holds a worktree.
final class HandOffTests: XCTestCase {
    private func handedOff(_ f: Fixture, nextRole: String? = "reviewer") throws -> (task: BoardTask, report: Report) {
        let task = try f.task("ship search", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("s1", worktreePath: "/wt/\(task.id)", shortId: "alpha"))
        let report = try f.board.handOff(
            taskId: task.id, sessionId: "s1", summary: "Wrote the query layer; the UI is untouched.",
            nextRole: nextRole, filesChanged: ["Sources/Search.swift"]
        )
        return (task, report)
    }

    func testHandOffReturnsTheTaskToReadyWithoutFlaggingFailure() throws {
        let f = try Fixture.make()
        let (task, _) = try handedOff(f)

        let stored = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(stored.column, .ready)
        XCTAssertFalse(stored.failed)
        XCTAssertNil(stored.failureReason)
        XCTAssertFalse(stored.blocked)
    }

    func testHandOffClearsAFailureFlagRaisedEarlierInTheSameAttempt() throws {
        let f = try Fixture.make()
        let task = try f.task("ship search", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("s1", worktreePath: "/wt/a"))
        try f.tasks.setFailed(task.id, true, reason: "tests red")

        try f.board.handOff(taskId: task.id, sessionId: "s1", summary: "got the tests green", nextRole: nil, filesChanged: [])

        let stored = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertFalse(stored.failed)
        XCTAssertEqual(stored.column, .ready)
    }

    func testProgressRowNamesTheHandingAgentAndTheSuggestedNextRole() throws {
        let f = try Fixture.make()
        let (task, _) = try handedOff(f)

        let entry = try XCTUnwrap(f.progress.latest(taskId: task.id))
        XCTAssertEqual(entry.kind, .note)
        XCTAssertEqual(entry.sessionId, "s1")
        XCTAssertTrue(entry.text.contains("alpha"), entry.text)
        XCTAssertTrue(entry.text.contains("reviewer"), entry.text)
        XCTAssertTrue(entry.text.contains("Wrote the query layer"), entry.text)
    }

    func testTheReportIsUnconsumedAndCarriesTheSummaryAndFiles() throws {
        let f = try Fixture.make()
        let (task, report) = try handedOff(f)

        XCTAssertEqual(report.kind, .handoff)
        XCTAssertEqual(report.taskId, task.id)
        XCTAssertEqual(report.sessionId, "s1")
        XCTAssertTrue(report.body.contains("Sources/Search.swift"), report.body)
        XCTAssertEqual(try f.reports.unconsumed(projectId: f.project.id).map(\.id), [report.id])
    }

    func testAHandOffWithNoSuggestedRoleSaysSoRatherThanInventingOne() throws {
        let f = try Fixture.make()
        let (task, report) = try handedOff(f, nextRole: nil)

        XCTAssertTrue(report.body.contains("No next role suggested."), report.body)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
    }

    func testTheHandingSessionKeepsItsWorktreeRowAndReleasesItsHold() throws {
        let f = try Fixture.make()
        let (task, _) = try handedOff(f)

        let session = try XCTUnwrap(f.sessions.get("s1"))
        XCTAssertEqual(session.worktreePath, "/wt/\(task.id)")
        XCTAssertEqual(session.state, .completed)
        XCTAssertFalse(session.state.isActive)
        XCTAssertNotNil(session.endedAt)
        XCTAssertEqual(session.stopReason, "handed off to reviewer")
        XCTAssertNil(try f.sessions.activeHolder(taskId: task.id))
        XCTAssertNil(try f.sessions.activeHolder(worktreePath: "/wt/\(task.id)"))
    }

    func testTheNextAgentIsAssignedIntoTheSameWorktreeAsAFreshAttempt() throws {
        let f = try Fixture.make()
        let (task, _) = try handedOff(f)

        let second = try f.board.assign(
            taskId: task.id, session: f.session("s2", worktreePath: "/wt/\(task.id)")
        )
        XCTAssertEqual(second.attempt, 2)
        XCTAssertEqual(second.worktreePath, "/wt/\(task.id)")
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)
        XCTAssertEqual(try f.sessions.activeHolder(worktreePath: "/wt/\(task.id)")?.sessionId, "s2")
    }

    // MARK: One live session per worktree

    func testAssignRefusesWhileAnActiveSessionStillHoldsTheTask() throws {
        let f = try Fixture.make()
        let task = try f.task("ship search", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("s1", worktreePath: "/wt/a"))

        XCTAssertThrowsError(try f.board.assign(taskId: task.id, session: f.session("s2", worktreePath: "/wt/a"))) {
            XCTAssertEqual($0 as? BoardError, .taskAlreadyHeld(taskId: task.id, sessionId: "s1"))
        }
        XCTAssertNil(try f.sessions.get("s2"))
        XCTAssertEqual(try f.sessions.forTask(task.id).count, 1)
    }

    func testAssignRefusesAWorktreeAnotherTasksLiveSessionIsAlreadyIn() throws {
        let f = try Fixture.make()
        let held = try f.task("first", column: .ready)
        let other = try f.task("second", column: .ready)
        try f.board.assign(taskId: held.id, session: f.session("s1", worktreePath: "/wt/shared"))

        XCTAssertThrowsError(try f.board.assign(taskId: other.id, session: f.session("s2", worktreePath: "/wt/shared"))) {
            XCTAssertEqual($0 as? BoardError, .worktreeAlreadyHeld(path: "/wt/shared", sessionId: "s1"))
        }
        XCTAssertEqual(try f.tasks.get(other.id)?.column, .ready)
    }

    /// The 2026-09-12 failure exactly: the task is back in `ready`, so the column no longer says
    /// anyone is in the worktree — only the session state does.
    func testATaskBackInReadyIsStillRefusedWhileItsSessionIsAlive() throws {
        let f = try Fixture.make()
        let task = try f.task("ship search", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("s1", worktreePath: "/wt/a"))
        try f.tasks.move(task.id, to: .ready)

        XCTAssertThrowsError(try f.board.assign(taskId: task.id, session: f.session("s2", worktreePath: "/wt/a"))) {
            XCTAssertEqual($0 as? BoardError, .taskAlreadyHeld(taskId: task.id, sessionId: "s1"))
        }
    }

    func testOnlyOneOfManyConcurrentAssignmentsToAHandedOffTaskWins() throws {
        let f = try Fixture.make()
        let (task, _) = try handedOff(f)

        let outcomes = UnsafeSendableBox<[Result<AgentSession, Error>]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            let result = Result { try f.board.assign(taskId: task.id, session: f.session("c\(i)", worktreePath: "/wt/\(task.id)")) }
            outcomes.mutate { $0.append(result) }
        }

        let winners = outcomes.value.filter { if case .success = $0 { return true } else { return false } }
        XCTAssertEqual(winners.count, 1, "\(winners.count) sessions were let into one worktree")
        XCTAssertEqual(try f.sessions.active(projectId: f.project.id).count, 1)
    }

    // MARK: Who may hand off

    func testASessionBoundToAnotherTaskCannotHandOffThisOne() throws {
        let f = try Fixture.make()
        let mine = try f.task("mine", column: .ready)
        let theirs = try f.task("theirs", column: .ready)
        try f.board.assign(taskId: mine.id, session: f.session("s1", worktreePath: "/wt/mine"))
        try f.board.assign(taskId: theirs.id, session: f.session("s2", worktreePath: "/wt/theirs"))

        XCTAssertThrowsError(
            try f.board.handOff(taskId: mine.id, sessionId: "s2", summary: "not mine", nextRole: nil, filesChanged: [])
        ) {
            XCTAssertEqual($0 as? BoardError, .sessionNotOnTask(sessionId: "s2", taskId: mine.id))
        }
        XCTAssertEqual(try f.tasks.get(mine.id)?.column, .running)
    }

    /// The stale-token case: the first agent's token still resolves after the second is assigned.
    /// A second `hand_off` from it must not pull the task out from under whoever holds it now.
    func testAnAlreadyHandedOffSessionCannotHandOffAgain() throws {
        let f = try Fixture.make()
        let (task, _) = try handedOff(f)
        try f.board.assign(taskId: task.id, session: f.session("s2", worktreePath: "/wt/\(task.id)"))

        XCTAssertThrowsError(
            try f.board.handOff(taskId: task.id, sessionId: "s1", summary: "again", nextRole: nil, filesChanged: [])
        ) {
            XCTAssertEqual($0 as? BoardError, .sessionNotOnTask(sessionId: "s1", taskId: task.id))
        }
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)
        XCTAssertEqual(try f.sessions.activeHolder(taskId: task.id)?.sessionId, "s2")
    }

    func testHandOffOfAMissingTaskThrows() throws {
        let f = try Fixture.make()
        XCTAssertThrowsError(
            try f.board.handOff(taskId: "missing", sessionId: "s1", summary: "x", nextRole: nil, filesChanged: [])
        ) {
            XCTAssertEqual($0 as? BoardError, .taskNotFound("missing"))
        }
    }
}

/// XCTest has no async barrier for `concurrentPerform`; this is the smallest thing that makes the
/// accumulator safe to write from several threads.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()

    init(_ value: T) { storage = value }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
