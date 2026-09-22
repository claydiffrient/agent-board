import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// The commands that destroy a co-resident agent's uncommitted work, denied at `PreToolUse` — and
/// only for an agent that is actually co-resident.
final class SharedCheckoutWorkingTreeGuardTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var shared: TokenIdentity!

    /// One of each denied family, exercised through the whole hook rather than the guard alone.
    private static let destructive = [
        "git stash",
        "git stash push -u",
        "git checkout .",
        "git checkout -- Sources/Sibling.swift",
        "git checkout main",
        "git switch main",
        "git restore .",
        "git reset --hard",
        "git reset --hard HEAD~1",
        "git clean -fd",
        "git rm -r Sources",
        "git sparse-checkout set Sources",
        "git merge main",
        "git rebase main",
        "git pull",
        "git cherry-pick abc1234",
        "git revert HEAD",
        "git am patch.mbox",
        "git bisect start",
        "git commit -am wip",
        "cd Sources && git stash",
        "git -C . reset --hard",
        "git -c core.hooksPath=/dev/null checkout .",
    ]

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        task = try f.task("t", column: .running)
        try f.sharedSession("w1", taskId: task.id)
        shared = f.workerIdentity(sessionId: "w1", taskId: task.id)
    }

    func testEveryDestructiveGitCommandIsDeniedForACoResidentWorker() async throws {
        for command in Self.destructive {
            let decision = await f.preToolUse(command, sessionId: "w1", identity: shared)
            XCTAssertEqual(decision?.permissionDecision, "deny", command)
            XCTAssertTrue(
                (decision?.reason ?? "").contains("shared checkout"),
                "\(command) was denied without saying why: \(decision?.reason ?? "")"
            )
        }
        let errors = try f.progress.list(taskId: task.id).filter { $0.kind == .error }
        XCTAssertEqual(errors.count, Self.destructive.count)
        XCTAssertTrue(errors.contains { $0.text.contains("git stash") }, errors.map(\.text).joined())
    }

    func testEveryDenialTellsTheAgentWhatToRunInstead() async throws {
        for command in Self.destructive {
            let decision = await f.preToolUse(command, sessionId: "w1", identity: shared)
            let reason = try XCTUnwrap(decision?.reason, command)
            XCTAssertTrue(
                reason.contains("commit_my_work")
                    || reason.contains("git restore -- <path>")
                    || reason.contains("git status --porcelain")
                    || reason.contains("git ls-files"),
                "\(command) was refused without an alternative: \(reason)"
            )
        }
    }

    func testAWorktreeWorkerKeepsEveryOneOfTheseCommands() async throws {
        let other = try f.task("own worktree", column: .running)
        try f.session("w2", taskId: other.id, worktreePath: "/tmp/wt-w2")
        let identity = f.workerIdentity(sessionId: "w2", taskId: other.id)
        for command in Self.destructive {
            let decision = await f.preToolUse(command, sessionId: "w2", identity: identity)
            XCTAssertNil(decision as HookDecision?, "\(command) was denied to a worker that owns its tree")
        }
        XCTAssertTrue(try f.progress.list(taskId: other.id).isEmpty)
    }

    /// The trap from task 64df6cb7: a row with no worktree path is not by itself a shared worker.
    func testAWorkerStandingSomewhereElseEntirelyIsNotJudgedShared() async throws {
        let other = try f.task("elsewhere", column: .running)
        try f.session("w3", taskId: other.id, cwd: "/tmp/not-the-repo")
        let identity = f.workerIdentity(sessionId: "w3", taskId: other.id)
        let decision = await f.preToolUse("git stash", sessionId: "w3", identity: identity)
        XCTAssertNil(decision as HookDecision?)
    }

    func testAnOrchestratorIsNotJudgedByThisGuard() async throws {
        let decision = await f.preToolUse("git stash", sessionId: "orch-session", identity: f.orchestratorIdentity)
        XCTAssertNil(decision as HookDecision?)
    }

    func testReadingTheTreeIsNeverDenied() async throws {
        for command in ["git status --porcelain", "git diff", "git log --oneline", "git show HEAD"] {
            let decision = await f.preToolUse(command, sessionId: "w1", identity: shared)
            XCTAssertNil(decision as HookDecision?, command)
        }
    }

    /// The prompt lives in Core and the guard in Server, so nothing but this stops the two lists
    /// drifting apart and leaving an agent surprised by a deny it was never warned about.
    func testTheOpeningPromptNamesEveryCommandTheGuardRefuses() {
        let prompt = OpeningPrompt.compose(
            task: task, branch: "agentboard/shared", attempt: 1,
            placement: .shared(branch: "agentboard/shared"), workingDirectory: f.project.repoPath
        )
        for violation in SharedCheckoutGuard.Violation.allCases {
            XCTAssertTrue(
                prompt.contains("`git \(violation.gitCommand)`"),
                "a shared worker is never told `git \(violation.gitCommand)` is refused"
            )
        }
    }

    // MARK: - The one allowed scoped form

    func testARestoreScopedToThisSessionsOwnLockedPathIsAllowed() async throws {
        let write = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "w1", identity: shared)
        XCTAssertNil(write as HookDecision?)
        let restore = await f.preToolUse("git restore -- Sources/Mine.swift", sessionId: "w1", identity: shared)
        XCTAssertNil(restore as HookDecision?)
        XCTAssertTrue(try f.progress.list(taskId: task.id).filter { $0.kind == .error }.isEmpty)
    }

    func testARestoreReachingASiblingsFileIsDeniedAndNamesTheFile() async throws {
        let sibling = try f.task("sibling", column: .running)
        try f.sharedSession("w2", taskId: sibling.id)
        let theirs = f.workerIdentity(sessionId: "w2", taskId: sibling.id)
        let theirWrite = await f.preToolUseWrite(f.repoFile("Sources/Theirs.swift"), sessionId: "w2", identity: theirs)
        XCTAssertNil(theirWrite as HookDecision?)
        let myWrite = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "w1", identity: shared)
        XCTAssertNil(myWrite as HookDecision?)

        let decision = await f.preToolUse(
            "git restore -- Sources/Mine.swift Sources/Theirs.swift", sessionId: "w1", identity: shared
        )
        XCTAssertEqual(decision?.permissionDecision, "deny")
        let reason = try XCTUnwrap(decision?.reason)
        XCTAssertTrue(reason.contains("Sources/Theirs.swift"), reason)
        XCTAssertFalse(reason.contains("Sources/Mine.swift"), reason)
    }

    func testARestoreOfAFileNobodyHasWrittenIsDenied() async throws {
        let decision = await f.preToolUse("git restore -- Sources/Untouched.swift", sessionId: "w1", identity: shared)
        XCTAssertEqual(decision?.permissionDecision, "deny")
        XCTAssertTrue((decision?.reason ?? "").contains("Sources/Untouched.swift"), decision?.reason ?? "")
    }

    func testARestoreReachingOutsideTheRepositoryIsDenied() async throws {
        let decision = await f.preToolUse("git restore -- /etc/hosts", sessionId: "w1", identity: shared)
        XCTAssertEqual(decision?.permissionDecision, "deny")
    }

    func testAnAbsolutePathInsideTheRepositoryResolvesToTheSameLock() async throws {
        let write = await f.preToolUseWrite(f.repoFile("Sources/Mine.swift"), sessionId: "w1", identity: shared)
        XCTAssertNil(write as HookDecision?)
        let restore = await f.preToolUse(
            "git restore -- \(f.repoFile("Sources/Mine.swift"))", sessionId: "w1", identity: shared
        )
        XCTAssertNil(restore as HookDecision?)
    }

    func testAWorktreeWorkerMayRestoreAnythingWithoutHoldingALock() async throws {
        let other = try f.task("own worktree", column: .running)
        try f.session("w4", taskId: other.id, worktreePath: "/tmp/wt-w4")
        let identity = f.workerIdentity(sessionId: "w4", taskId: other.id)
        let decision = await f.preToolUse("git restore -- Sources/Anything.swift", sessionId: "w4", identity: identity)
        XCTAssertNil(decision as HookDecision?)
    }
}
