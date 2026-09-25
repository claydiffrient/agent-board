import Foundation
import XCTest
@testable import AgentBoardCore

final class FileLockKeyTests: XCTestCase {
    private let repo = "/tmp/demo-repo"

    func testAPathInsideTheRepositoryBecomesARepoRelativeKey() {
        XCTAssertEqual(FileLockPolicy.key(filePath: "/tmp/demo-repo/Sources/App.swift", repoPath: repo), "Sources/App.swift")
        XCTAssertEqual(FileLockPolicy.key(filePath: "Sources/App.swift", repoPath: repo), "Sources/App.swift")
        XCTAssertEqual(
            FileLockPolicy.key(filePath: "/tmp/demo-repo/Sources/../Sources/App.swift", repoPath: repo),
            "Sources/App.swift",
            "two spellings of one file must be one lock"
        )
    }

    func testAPathOutsideTheRepositoryTakesNoLock() {
        XCTAssertNil(FileLockPolicy.key(filePath: "/tmp/scratch/notes.txt", repoPath: repo))
        XCTAssertNil(FileLockPolicy.key(filePath: "/tmp/demo-repo-other/App.swift", repoPath: repo))
        XCTAssertNil(FileLockPolicy.key(filePath: nil, repoPath: repo))
        XCTAssertNil(FileLockPolicy.key(filePath: repo, repoPath: repo))
    }

    func testOnlyWriteToolsLock() {
        for tool in ["Write", "Edit", "MultiEdit", "NotebookEdit"] {
            XCTAssertTrue(FileLockPolicy.locks(toolName: tool), tool)
            XCTAssertTrue(FileLockPolicy.toolMatcher.contains(tool), FileLockPolicy.toolMatcher)
        }
        for tool in ["Bash", "Read", "Grep", nil] {
            XCTAssertFalse(FileLockPolicy.locks(toolName: tool), tool ?? "nil")
        }
    }

    /// The hook has to outlast the wait it performs, or Claude Code abandons the response and the
    /// write it was holding goes through unlocked.
    func testTheHookTimeoutOutlastsTheWait() {
        XCTAssertGreaterThan(TimeInterval(FileLockPolicy.hookTimeoutSeconds), FileLockPolicy.waitTimeout)
        XCTAssertLessThan(
            FileLockPolicy.waitTimeout, TimeInterval(Caps().stallSeconds),
            "a single wait must stay shorter than the stall threshold"
        )
    }
}

final class FileLockStoreTests: XCTestCase {
    private var f: Fixture!
    private var locks: FileLockStore!

    override func setUpWithError() throws {
        f = try Fixture.make()
        locks = FileLockStore(f.db)
    }

    private func insertSession(_ id: String, state: SessionState = .running, taskId: String? = nil) throws {
        try f.sessions.insert(f.session(id, state: state, taskId: taskId))
    }

    func testTheFirstClaimWinsAndTheSecondIsToldWhoHoldsIt() throws {
        try insertSession("s1")
        try insertSession("s2")

        guard case .acquired(let mine) = try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s1") else {
            return XCTFail("the first claim was refused")
        }
        XCTAssertEqual(mine.sessionId, "s1")

        guard case .heldBy(let holder) = try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s2") else {
            return XCTFail("a second session took a lock another session holds")
        }
        XCTAssertEqual(holder.sessionId, "s1")
        XCTAssertEqual(try locks.held(projectId: f.project.id).count, 1)
    }

    func testAHolderReclaimingItsOwnLockIsNotBlockedByItself() throws {
        try insertSession("s1")
        try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s1")
        guard case .acquired = try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s1") else {
            return XCTFail("a session was blocked by its own lock")
        }
    }

    func testTwoFilesAndTwoProjectsDoNotContend() throws {
        try insertSession("s1")
        try insertSession("s2")
        let other = try f.projects.register(
            name: "Other", repoPath: "/tmp/other", baseBranch: "main", worktreeRoot: "/tmp/other-wt", memoryDir: nil
        )
        try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s1")
        guard case .acquired = try locks.acquire(projectId: f.project.id, path: "Other.swift", sessionId: "s2") else {
            return XCTFail("a different file contended")
        }
        guard case .acquired = try locks.acquire(projectId: other.id, path: "App.swift", sessionId: "s2") else {
            return XCTFail("the same path in a different project contended")
        }
    }

    func testALockHeldByAnEndedSessionIsTakenRatherThanWaitedOn() throws {
        try insertSession("dead", state: .running)
        try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "dead")
        try f.sessions.setState("dead", .failed, endedAt: .nowMillis)
        try insertSession("s2")

        guard case .acquired(let taken) = try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s2") else {
            return XCTFail("a dead session's lock blocked a live one")
        }
        XCTAssertEqual(taken.sessionId, "s2")
        XCTAssertEqual(try locks.held(projectId: f.project.id).map(\.sessionId), ["s2"])
    }

    func testReleaseAllClearsEveryPathASessionHeldAndNobodyElseS() throws {
        try insertSession("s1")
        try insertSession("s2")
        try locks.acquire(projectId: f.project.id, path: "a.swift", sessionId: "s1")
        try locks.acquire(projectId: f.project.id, path: "b.swift", sessionId: "s1")
        try locks.acquire(projectId: f.project.id, path: "c.swift", sessionId: "s2")

        XCTAssertEqual(try locks.releaseAll(sessionId: "s1"), 2)
        XCTAssertEqual(try locks.held(projectId: f.project.id).map(\.path), ["c.swift"])
    }

    /// The launch sweep: rows written by a process that is gone, against session rows that are no
    /// longer active or no longer there at all.
    func testSweepStaleClearsLocksWhoseHolderIsNotRunningAndKeepsTheLiveOnes() throws {
        try insertSession("live")
        try insertSession("stopped", state: .stopped)
        try locks.acquire(projectId: f.project.id, path: "live.swift", sessionId: "live")
        try locks.acquire(projectId: f.project.id, path: "stopped.swift", sessionId: "stopped")
        try f.db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO file_lock (project_id, path, session_id, task_id, held_since) VALUES (?, ?, ?, NULL, ?)",
                arguments: [f.project.id, "ghost.swift", "no-such-session", Int64.nowMillis]
            )
        }

        let swept = try locks.sweepStale().map(\.path).sorted()
        XCTAssertEqual(swept, ["ghost.swift", "stopped.swift"])
        XCTAssertEqual(try locks.held(projectId: f.project.id).map(\.path), ["live.swift"])
    }

    func testCompletingASessionReleasesItsLocks() throws {
        let task = try f.task("t", column: .running)
        try insertSession("s1", taskId: task.id)
        try locks.acquire(projectId: f.project.id, path: "App.swift", sessionId: "s1", taskId: task.id)

        _ = try f.board.complete(taskId: task.id, sessionId: "s1", summary: "done")

        XCTAssertTrue(try locks.held(projectId: f.project.id).isEmpty)
    }

    func testEveryTerminationRouteReleasesLocksIncludingACapKill() throws {
        let causes: [SessionTermination] = [
            .capBreach("idle cap reached"), .stopped(by: .human), .vanished,
            .setupFailed("worktree"), .shutdownAcknowledged(note: nil),
        ]
        for (index, cause) in causes.enumerated() {
            let task = try f.task("t\(index)", column: .running)
            let id = "s\(index)"
            try insertSession(id, taskId: task.id)
            try locks.acquire(projectId: f.project.id, path: "shared-\(index).swift", sessionId: id, taskId: task.id)

            _ = try f.board.terminate(sessionId: id, cause: cause)

            XCTAssertTrue(
                try locks.held(projectId: f.project.id).allSatisfy { $0.sessionId != id },
                "\(cause) left a lock behind"
            )
        }
    }

    func testBlockingOnAFileLockReturnsTheTaskToReadyAndReleasesTheLocks() throws {
        let task = try f.task("t", column: .running)
        try insertSession("s1", taskId: task.id)
        try locks.acquire(projectId: f.project.id, path: "mine.swift", sessionId: "s1", taskId: task.id)

        _ = try f.board.blockOnFileLock(taskId: task.id, sessionId: "s1", reason: "App.swift is held")

        let after = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(after.column, .ready)
        XCTAssertTrue(after.blocked)
        XCTAssertEqual(try f.sessions.get("s1")?.state, .stopped)
        XCTAssertNil(try f.sessions.get("s1")?.blockedOnPath)
        XCTAssertTrue(try locks.held(projectId: f.project.id).isEmpty)
    }
}
