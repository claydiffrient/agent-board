import AgentBoardBridge
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
        XCTAssertEqual(result["trailer"]?.stringValue, "Agent-Board-Task: \(mine.id)")
    }

    func testTheMessageCarriesTheTaskTrailer() async throws {
        _ = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "mine", identity: me)
        _ = try await f.call("commit_my_work", ["message": .string("Add my work")], as: me)

        let request = try XCTUnwrap(commits.requests.first)
        XCTAssertEqual(request.message, "Add my work\n\nAgent-Board-Task: \(mine.id)")
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
        XCTAssertTrue(rows.contains { $0.contains("Sources/Mine.swift") && $0.contains("Agent-Board-Task") }, "\(rows)")
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
