import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// The lock as an agent meets it: a `PreToolUse` write that is stopped, held, or let through.
/// Nothing here asserts the store alone — every case goes through the hook the way a worker does.
final class FileLockEnforcementTests: XCTestCase {
    private var f: BridgeFixture!
    private var firstTask: BoardTask!
    private var secondTask: BoardTask!
    private var first: TokenIdentity!
    private var second: TokenIdentity!

    /// The shipped 90s wait is the point of the feature and the wrong thing to sit through here.
    private static let quickWait = FileLockWaitPolicy(timeout: 1.0, pollInterval: 0.05)

    override func setUpWithError() throws {
        f = try BridgeFixture.make(lockWait: Self.quickWait)
        firstTask = try f.task("First", column: .running)
        secondTask = try f.task("Second", column: .running)
        try f.session("holder", taskId: firstTask.id)
        try f.session("waiter", taskId: secondTask.id)
        first = f.workerIdentity(sessionId: "holder", taskId: firstTask.id)
        second = f.workerIdentity(sessionId: "waiter", taskId: secondTask.id)
    }

    private var locks: FileLockStore { FileLockStore(f.db) }

    func testAWriteToAFileAnotherSessionHoldsIsStoppedAtPreToolUse() async throws {
        let path = f.repoFile("Sources/App.swift")
        let taken = await f.preToolUseWrite(path, sessionId: "holder", identity: first)
        XCTAssertNil(taken)

        let denied = await f.preToolUseWrite(path, sessionId: "waiter", identity: second)

        XCTAssertEqual(denied?.permissionDecision, "deny")
        let reason = try XCTUnwrap(denied?.reason)
        XCTAssertTrue(reason.contains("Sources/App.swift"), reason)
        XCTAssertTrue(reason.contains("report_blocked"), reason)
        XCTAssertEqual(try locks.holder(projectId: f.project.id, path: "Sources/App.swift")?.sessionId, "holder")
    }

    func testAReleasedLockLetsTheWaiterThrough() async throws {
        let path = f.repoFile("Sources/App.swift")
        let taken = await f.preToolUseWrite(path, sessionId: "holder", identity: first)
        XCTAssertNil(taken)

        // The holder finishes part-way through the waiter's wait, which is the whole point of
        // waiting rather than denying on contact.
        let releaser = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(nanoseconds: 200_000_000)
            _ = try? self.f.board.complete(taskId: self.firstTask.id, sessionId: "holder", summary: "done")
        }

        let decision = await f.preToolUseWrite(path, sessionId: "waiter", identity: second)
        await releaser.value

        XCTAssertNil(decision, "the waiter was denied although the holder released the file")
        XCTAssertEqual(try locks.holder(projectId: f.project.id, path: "Sources/App.swift")?.sessionId, "waiter")
        XCTAssertEqual(try f.sessions.get("waiter")?.state, .running)
        XCTAssertNil(try f.sessions.get("waiter")?.blockedOnPath)
    }

    func testTheSameSessionWritingTheSameFileAgainIsNotBlockedByItself() async throws {
        let path = f.repoFile("Sources/App.swift")
        let firstWrite = await f.preToolUseWrite(path, sessionId: "holder", identity: first)
        let secondWrite = await f.preToolUseWrite(path, sessionId: "holder", identity: first, tool: "Write")
        XCTAssertNil(firstWrite)
        XCTAssertNil(secondWrite)
    }

    func testTwoSessionsWritingDifferentFilesNeverMeet() async throws {
        let a = await f.preToolUseWrite(f.repoFile("a.swift"), sessionId: "holder", identity: first)
        let b = await f.preToolUseWrite(f.repoFile("b.swift"), sessionId: "waiter", identity: second)
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    /// A worker in its own worktree cannot collide with anyone, so it takes no lock at all — and
    /// therefore is never held up by one another session has.
    func testAWorkerInItsOwnWorktreeTakesNoLockAndIsUnaffectedByOne() async throws {
        let isolatedTask = try f.task("Isolated", column: .running)
        try f.session("isolated", taskId: isolatedTask.id, worktreePath: "/tmp/demo-worktrees/isolated")
        let isolated = f.workerIdentity(sessionId: "isolated", taskId: isolatedTask.id)

        let taken = await f.preToolUseWrite(f.repoFile("Sources/App.swift"), sessionId: "holder", identity: first)
        XCTAssertNil(taken)
        let decision = await f.preToolUseWrite(
            "/tmp/demo-worktrees/isolated/Sources/App.swift", sessionId: "isolated", identity: isolated
        )

        XCTAssertNil(decision)
        XCTAssertEqual(
            try locks.held(projectId: f.project.id).map(\.sessionId), ["holder"],
            "an isolated worker took a lock"
        )
    }

    func testAWriteOutsideTheRepositoryTakesNoLock() async throws {
        let decision = await f.preToolUseWrite("/tmp/scratch/notes.txt", sessionId: "holder", identity: first)
        XCTAssertNil(decision)
        XCTAssertTrue(try locks.held(projectId: f.project.id).isEmpty)
    }

    func testBashIsNotLockedAndTheIntegrationGuardStillFires() async throws {
        let taken = await f.preToolUseWrite(f.repoFile("Sources/App.swift"), sessionId: "holder", identity: first)
        let build = await f.preToolUse("swift build", sessionId: "waiter", identity: second)
        let integration = await f.preToolUse("git push", sessionId: "waiter", identity: second)
        XCTAssertNil(taken)
        XCTAssertNil(build, "a Bash call was held by a file lock")
        XCTAssertEqual(integration?.permissionDecision, "deny")
        XCTAssertEqual(try locks.held(projectId: f.project.id).count, 1)
    }

    // MARK: - what a timed-out wait leaves behind

    func testTheDeniedWaiterSitsInWaitingOnLockForTheWaitAndComesBackToRunning() async throws {
        let path = f.repoFile("Sources/App.swift")
        _ = await f.preToolUseWrite(path, sessionId: "holder", identity: first)

        let waiting = _Concurrency.Task { await self.f.preToolUseWrite(path, sessionId: "waiter", identity: self.second) }
        try await _Concurrency.Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try f.sessions.get("waiter")?.state, .waitingOnLock)
        _ = await waiting.value

        XCTAssertEqual(try f.sessions.get("waiter")?.state, .running)
    }

    /// The waited seconds are not idleness: the activity clock is refreshed when the wait ends, so
    /// a worker that waited does not walk into the idle cap carrying the wait with it.
    func testTheWaitDoesNotCountTowardTheIdleClock() async throws {
        let stale = Int64.nowMillis - 290_000
        try f.sessions.recordActivity("waiter", at: stale, lastTool: "Edit")
        _ = await f.preToolUseWrite(f.repoFile("Sources/App.swift"), sessionId: "holder", identity: first)

        _ = await f.preToolUseWrite(f.repoFile("Sources/App.swift"), sessionId: "waiter", identity: second)

        let after = try XCTUnwrap(f.sessions.get("waiter")?.lastActivity)
        XCTAssertGreaterThan(after, stale, "the wait left the activity clock where it was")
        XCTAssertLessThan(Int64.nowMillis - after, 5_000)
    }

    func testAfterTheDenialReportBlockedReturnsTheTaskToReady() async throws {
        let path = f.repoFile("Sources/App.swift")
        _ = await f.preToolUseWrite(path, sessionId: "holder", identity: first)
        let denied = await f.preToolUseWrite(path, sessionId: "waiter", identity: second)
        XCTAssertEqual(denied?.permissionDecision, "deny")
        XCTAssertEqual(try f.sessions.get("waiter")?.blockedOnPath, "Sources/App.swift")

        let result = try await f.call(
            "report_blocked", ["reason": .string("Sources/App.swift is held by another agent")], as: second
        )

        XCTAssertTrue(result.text.contains("ready"), result.text)
        let task = try XCTUnwrap(f.tasks.get(secondTask.id))
        XCTAssertEqual(task.column, .ready)
        XCTAssertTrue(task.blocked)
        XCTAssertEqual(try f.sessions.get("waiter")?.state, .stopped)
    }

    /// An ordinary block — no lock involved — must keep behaving as it did: the task stays where it
    /// is and a human decides what happens next.
    func testAnOrdinaryReportBlockedStillLeavesTheTaskRunning() async throws {
        _ = try await f.call("report_blocked", ["reason": .string("I need a credential")], as: second)

        let task = try XCTUnwrap(f.tasks.get(secondTask.id))
        XCTAssertEqual(task.column, .running)
        XCTAssertTrue(task.blocked)
        XCTAssertEqual(try f.sessions.get("waiter")?.state, .blocked)
    }

    func testTheDenialAndTheTakenLockBothLandOnTheTaskCard() async throws {
        let path = f.repoFile("Sources/App.swift")
        _ = await f.preToolUseWrite(path, sessionId: "holder", identity: first)
        _ = await f.preToolUseWrite(path, sessionId: "waiter", identity: second)

        let entry = try XCTUnwrap(f.progress.latest(taskId: secondTask.id))
        XCTAssertEqual(entry.kind, .error)
        XCTAssertTrue(entry.text.contains("Sources/App.swift"), entry.text)
        XCTAssertTrue(entry.text.contains("holder"), entry.text)
    }

    func testSessionEndReleasesEveryLockTheSessionHeld() async throws {
        _ = await f.preToolUseWrite(f.repoFile("a.swift"), sessionId: "holder", identity: first)
        _ = await f.preToolUseWrite(f.repoFile("b.swift"), sessionId: "holder", identity: first)
        XCTAssertEqual(try locks.held(projectId: f.project.id).count, 2)

        await f.hook("SessionEnd", sessionId: "holder", identity: first)

        XCTAssertTrue(try locks.held(projectId: f.project.id).isEmpty)
    }
}
