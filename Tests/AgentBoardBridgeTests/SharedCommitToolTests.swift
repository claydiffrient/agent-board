@testable import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// `commit_my_work` as an agent meets it: what it is handed, what it refuses, and who is offered it.
final class SharedCommitToolTests: XCTestCase {
    private var f: BridgeFixture!
    private var commits: RecordingScopedCommits!
    private var mine: BoardTask!
    private var theirs: BoardTask!
    private var me: TokenIdentity!
    private var them: TokenIdentity!

    override func setUpWithError() throws {
        commits = RecordingScopedCommits()
        f = try BridgeFixture.make(scopedCommits: commits)
        mine = try f.task("Mine", column: .running)
        theirs = try f.task("Theirs", column: .running)
        try f.sharedSession("mine", taskId: mine.id)
        try f.sharedSession("theirs", taskId: theirs.id)
        me = f.workerIdentity(sessionId: "mine", taskId: mine.id)
        them = f.workerIdentity(sessionId: "theirs", taskId: theirs.id)
    }

    /// The paths come from the locks the writes took, not from anything the agent says.
    func testTheCommitIsScopedToThePathsThisSessionLockedAndNothingElse() async throws {
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)
        _ = await f.preToolUseWrite(f.repoFile("Sources/AlsoMine.swift"), sessionId: "mine", identity: me)
        _ = await f.preToolUseWrite(f.repoFile("Sources/Theirs.swift"), sessionId: "theirs", identity: them)

        let result = try await f.callJSON("commit_my_work", ["message": .string("Add my work")], as: me)

        let request = try XCTUnwrap(commits.requests.first)
        XCTAssertEqual(request.paths, ["Sources/AlsoMine.swift", "Sources/Mine.swift"])
        XCTAssertFalse(request.paths.contains("Sources/Theirs.swift"))
        XCTAssertEqual(request.taskId, mine.id)
        XCTAssertEqual(request.repoPath, f.project.repoPath)
        XCTAssertNil(result["trailer"])
    }

    /// The commit object carries nothing: a task-id trailer would be permanent and public in
    /// whatever repository the pull request lands in. The ledger row is what attributes it.
    func testTheMessageIsCommittedVerbatimAndTheLedgerRecordsTheCommit() async throws {
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)
        let body = "Add my work\n\nA second paragraph."
        let result = try await f.callJSON("commit_my_work", ["message": .string(body)], as: me)

        let request = try XCTUnwrap(commits.requests.first)
        XCTAssertEqual(request.message, body)
        XCTAssertFalse(request.message.contains("Agent-Board-Task"), request.message)
        XCTAssertFalse(request.message.contains(mine.id), request.message)

        let sha = try XCTUnwrap(result["commit"]?.stringValue)
        XCTAssertEqual(try TaskCommitStore(f.db).taskIds(forShas: [sha]), [sha: mine.id])
    }

    /// The row lands only for the commit that happened; a refused or empty commit records nothing.
    func testNothingIsRecordedWhenThereWasNothingToCommit() async throws {
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)
        commits.outcome = .nothingToCommit(paths: ["Sources/Mine.swift"])
        _ = try await f.call("commit_my_work", ["message": .string("Add my work")], as: me)

        XCTAssertEqual(try TaskCommitStore(f.db).shas(taskId: mine.id), [])
    }

    func testASessionThatHasWrittenNothingIsRefusedRatherThanCommittingTheTree() async throws {
        _ = await f.preToolUseWrite(f.repoFile("Sources/Theirs.swift"), sessionId: "theirs", identity: them)

        await XCTAssertToolError(
            try await f.call("commit_my_work", ["message": .string("Grab everything")], as: me),
            containing: "has not written any file"
        )
        XCTAssertTrue(commits.requests.isEmpty)
    }

    func testAWorktreeWorkerIsNotOfferedTheToolAndCannotCallIt() async throws {
        try f.session("isolated", taskId: mine.id, worktreePath: "/tmp/wt/mine")
        let isolated = f.workerIdentity(sessionId: "isolated", taskId: mine.id)

        let names = await f.worker.tools(for: isolated).map(\.name)
        XCTAssertFalse(names.contains("commit_my_work"), "\(names)")

        await XCTAssertToolError(
            try await f.call("commit_my_work", ["message": .string("Commit")], as: isolated),
            containing: "own worktree"
        )
    }

    func testASharedWorkerIsOfferedTheTool() async throws {
        let names = await f.worker.tools(for: me).map(\.name)
        XCTAssertTrue(names.contains("commit_my_work"), "\(names)")
    }

    func testAProgressRowNamesTheCommitAndItsPaths() async throws {
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)
        _ = try await f.call("commit_my_work", ["message": .string("Add my work")], as: me)

        let rows = try f.progress.list(taskId: mine.id, limit: 50).map(\.text)
        XCTAssertTrue(rows.contains { $0.contains("Sources/Mine.swift") && $0.contains("Committed") }, "\(rows)")
    }
}

/// SPEC §6: a commit hook can outlast Claude Code's 60s wait for an answer.
final class SlowSharedCommitTests: XCTestCase {
    func testACommitStillInItsHooksAnswersPendingAndTheNextCallCollectsIt() async throws {
        let commits = RecordingScopedCommits()
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("commit-gate-\(UUID().uuidString)")
        commits.gate = gate
        let f = try BridgeFixture.make(scopedCommits: commits, commitAnswerWithin: .seconds(1))
        let mine = try f.task("Mine", column: .running)
        try f.sharedSession("mine", taskId: mine.id)
        let me = f.workerIdentity(sessionId: "mine", taskId: mine.id)
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)

        let pending = try await f.call("commit_my_work", ["message": .string("Add my work")], as: me)

        XCTAssertTrue(pending.text.contains("still running"), "commit_my_work waited for its commit hooks: \(pending.text)")
        XCTAssertEqual(try TaskCommitStore(f.db).shas(taskId: mine.id), [])
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: gate) }
        var polls = 0
        while try TaskCommitStore(f.db).shas(taskId: mine.id).isEmpty, polls < 300 {
            try await _Concurrency.Task.sleep(for: .milliseconds(100))
            polls += 1
        }
        XCTAssertEqual(
            try TaskCommitStore(f.db).shas(taskId: mine.id).count, 1,
            "the commit that finished after the answer was never recorded as this task's"
        )

        let collected = try await f.callJSON("commit_my_work", ["message": .string("Ignored")], as: me)

        XCTAssertNotNil(collected["commit"]?.stringValue, "\(collected)")
        XCTAssertEqual(commits.requests.map(\.message), ["Add my work"], "the collecting call started a second commit")
    }

    func testNoAcceptLandsTheTaskWhileItsCommitIsStillRunning() async throws {
        let commits = RecordingScopedCommits()
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("commit-gate-\(UUID().uuidString)")
        commits.gate = gate
        defer { try? FileManager.default.removeItem(at: gate) }
        let f = try BridgeFixture.make(scopedCommits: commits, commitAnswerWithin: .seconds(1))
        try f.setReviewLevel(.none)
        let mine = try f.task("Mine", column: .running)
        try f.sharedSession("mine", taskId: mine.id)
        let me = f.workerIdentity(sessionId: "mine", taskId: mine.id)
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)
        let pending = try await f.call("commit_my_work", ["message": .string("Add my work")], as: me)
        XCTAssertTrue(pending.text.contains("still running"), pending.text)

        let completing = await refusal(of: try await f.call("report_complete", ["summary": .string("Done.")], as: me))
        XCTAssertTrue(completing.contains("commit_my_work"), "report_complete was not refused for the running commit: \(completing)")
        try f.tasks.move(mine.id, to: .review)
        try f.session("rita", taskId: mine.id)
        let rita = f.reviewerIdentity(sessionId: "rita", taskId: mine.id)
        let accepting = await refusal(of: try await f.call("accept_task", ["verdict": .string("Fine.")], as: rita))
        XCTAssertTrue(accepting.contains("commit_my_work"), "accept_task was not refused for the running commit: \(accepting)")

        let accepted = await f.control.accepted
        XCTAssertEqual(accepted.map(\.taskId), [])
        XCTAssertEqual(try f.tasks.get(mine.id)?.column, .review)
    }

    private func refusal(of call: @autoclosure () async throws -> ToolResult) async -> String {
        do {
            return "answered: " + (try await call()).text
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    func testALateDeliveryLeavesTheSessionsNewerCommitInFlight() async throws {
        let inFlight = CommitsInFlight()
        let first = await inFlight.commit(sessionId: "mine", taskId: "task") { .nothingToCommit(paths: []) }
        _ = await first.commit.result
        await inFlight.delivered(sessionId: "mine", id: first.id)
        _ = await inFlight.commit(sessionId: "mine", taskId: "task") { .nothingToCommit(paths: []) }

        await inFlight.delivered(sessionId: "mine", id: first.id)

        let third = await inFlight.commit(sessionId: "mine", taskId: "task") { .nothingToCommit(paths: []) }
        XCTAssertFalse(third.started, "a late delivery of the first commit cleared the second, so a third ran beside it")
    }
}

/// The other half of the enforcement: plain `git commit` cannot reach the shared tree.
final class SharedCommitGuardTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var shared: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make(scopedCommits: RecordingScopedCommits())
        task = try f.task("Mine", column: .running)
        try f.sharedSession("shared", taskId: task.id)
        shared = f.workerIdentity(sessionId: "shared", taskId: task.id)
    }

    func testGitCommitIsDeniedForASharedWorkerAndNamesTheToolToUseInstead() async throws {
        let decision = await f.preToolUse("git commit -a -m 'everything'", sessionId: "shared", identity: shared)

        XCTAssertEqual(decision?.permissionDecision, "deny")
        let reason = try XCTUnwrap(decision?.reason)
        XCTAssertTrue(reason.contains("commit_my_work"), reason)
    }

    func testAChainedOrDirectoryScopedCommitIsCaughtToo() async throws {
        for command in ["cd Sources && git commit -m x", "git -C /repo commit -m x", "git -c user.name=X commit -m x"] {
            let decision = await f.preToolUse(command, sessionId: "shared", identity: shared)
            XCTAssertEqual(decision?.permissionDecision, "deny", command)
        }
    }

    func testReadingGitIsStillAllowed() async throws {
        for command in ["git log --oneline -5", "git status --porcelain", "git diff", "echo commit"] {
            let decision = await f.preToolUse(command, sessionId: "shared", identity: shared)
            XCTAssertNil(decision, command)
        }
    }

    func testAWorktreeWorkerMayStillCommitWithGit() async throws {
        try f.session("isolated", taskId: task.id, worktreePath: "/tmp/wt/mine")
        let isolated = f.workerIdentity(sessionId: "isolated", taskId: task.id)

        let decision = await f.preToolUse("git commit -m 'my work'", sessionId: "isolated", identity: isolated)
        XCTAssertNil(decision)
    }

    func testTheDenyIsRecordedOnTheTaskCard() async throws {
        _ = await f.preToolUse("git commit -am x", sessionId: "shared", identity: shared)
        let rows = try f.progress.list(taskId: task.id, limit: 20)
        XCTAssertTrue(rows.contains { $0.kind == .error && $0.text.contains("git commit") }, "\(rows.map(\.text))")
    }
}
