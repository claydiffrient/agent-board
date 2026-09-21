import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class WorktreeCleanupTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - Accept

    func testAcceptDeletesTheTaskBranchOnceItIsMerged() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        try fixture.mergeIntoBase("agentboard/\(task.id)")

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(task.id)"))
        XCTAssertEqual(try worktreePaths(), [])
        XCTAssertNil(fixture.supervisor.lastError)
    }

    func testAcceptKeepsAnUnmergedBranchAndSaysWhy() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertTrue(
            try fixture.manager.branchExists("agentboard/\(task.id)"),
            "accept deleted a branch whose commits are not on main"
        )
        XCTAssertEqual(try worktreePaths(), [], "the worktree should still go even when the branch stays")
        let notice = try XCTUnwrap(fixture.supervisor.lastError)
        XCTAssertTrue(notice.contains("agentboard/\(task.id)"), notice)
        XCTAssertTrue(notice.contains("not merged into"), notice)
        XCTAssertTrue(notice.contains("main"), notice)
        XCTAssertEqual(
            try XCTUnwrap(try fixture.tasks.get(task.id)).landing, .unlanded,
            "the kept branch was not recorded on the task, so only the transient notice said so"
        )
    }

    func testAcceptRemovesEveryAttemptsWorktree() async throws {
        let task = try makeTask()
        let failed = try fixture.worktreeWorker(task: task, attempt: 1, state: .failed)
        let completed = try fixture.worktreeWorker(task: task, attempt: 2, state: .completed)
        XCTAssertEqual(try worktreePaths().count, 2)

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try worktreePaths(), [], "a retried task leaked an attempt's worktree")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(failed.worktreePath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(completed.worktreePath)))
    }

    /// `forTask` is newest-first, so a retry that never recorded a worktree used to mask the one that did.
    func testAcceptRemovesTheWorktreeWhenTheNewestSessionHasNone() async throws {
        let task = try makeTask()
        let withWorktree = try fixture.worktreeWorker(task: task)
        try fixture.sessions.insert(AgentSession(
            sessionId: "session-retry", projectId: fixture.project.id, taskId: task.id,
            role: .worker, cwd: fixture.supportDir.path, state: .failed, attempt: 2
        ))

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(withWorktree.worktreePath)))
    }

    func testAcceptKeepsADirtyWorktreeAndItsBranch() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task)
        let worktree = try XCTUnwrap(session.worktreePath)
        try fixture.commitInto(worktree)
        try fixture.mergeIntoBase("agentboard/\(task.id)")
        try "unsaved\n".write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent("scratch.txt"),
            atomically: true, encoding: .utf8
        )

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "accept destroyed uncommitted work")
        XCTAssertTrue(try fixture.manager.branchExists("agentboard/\(task.id)"))
        let notice = try XCTUnwrap(fixture.supervisor.lastError)
        XCTAssertTrue(notice.contains("uncommitted changes"), notice)
    }

    func testAcceptDeletesABranchMergedIntoItsEpicBranchRatherThanMain() async throws {
        let epic = try EpicStore(fixture.db).create(projectId: fixture.project.id, title: "Epic", goal: nil)
        let task = try makeTask(epicId: epic.id)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        try SupervisorFixture.git(
            ["branch", epic.branch, "agentboard/\(task.id)"],
            cwd: URL(fileURLWithPath: fixture.project.repoPath)
        )

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(task.id)"))
        XCTAssertTrue(try fixture.manager.branchExists(epic.branch))
    }

    // MARK: - Discard

    func testDiscardRemovesEveryAttemptsWorktree() async throws {
        let task = try makeTask()
        try fixture.worktreeWorker(task: task, attempt: 1, state: .failed)
        try fixture.worktreeWorker(task: task, attempt: 2, state: .stopped)

        try await fixture.supervisor.discard(taskId: task.id)

        XCTAssertEqual(try worktreePaths(), [])
    }

    // MARK: - Reaper

    func testReconcileReapsACleanOrphanedWorktree() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task, state: .failed)
        let worktree = try XCTUnwrap(session.worktreePath)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(task.id)"))
    }

    /// The worktree session `865f1c2d` hit: a directory whose session row is gone entirely.
    func testReconcileReapsAWorktreeWithNoSessionAtAll() async throws {
        let orphan = try fixture.manager.create(name: "865f1c2d", branch: "agentboard/865f1c2d", base: "main")

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(try fixture.manager.branchExists("agentboard/865f1c2d"))
    }

    func testReconcileSkipsADirtyOrphanAndSaysWhy() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task, state: .stopped)
        let worktree = try XCTUnwrap(session.worktreePath)
        try "half done\n".write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent("wip.txt"),
            atomically: true, encoding: .utf8
        )

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "the reaper destroyed uncommitted work")
        let notice = try XCTUnwrap(fixture.supervisor.lastError)
        XCTAssertTrue(notice.contains("uncommitted changes"), notice)
    }

    func testReconcileSkipsAnOrphanHoldingUnmergedCommits() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task, state: .completed)
        let worktree = try XCTUnwrap(session.worktreePath)
        try fixture.commitInto(worktree)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "the reaper threw away unreviewed work")
        XCTAssertTrue(try fixture.manager.branchExists("agentboard/\(task.id)"))
        let notice = try XCTUnwrap(fixture.supervisor.lastError)
        XCTAssertTrue(notice.contains("not in main"), notice)
    }

    func testReconcileLeavesALiveSessionsWorktreeAlone() async throws {
        let task = try makeTask()
        let session = try fixture.worktreeWorker(task: task, state: .running)
        let worktree = try XCTUnwrap(session.worktreePath)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
    }

    func testReconcileLeavesEpicIntegrationWorktreesAlone() async throws {
        let epic = try EpicStore(fixture.db).create(projectId: fixture.project.id, title: "Epic", goal: nil)
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let integration = try fixture.manager.createForBranch(name: "epic-\(epic.id)", branch: epic.branch)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: integration.path),
            "integration worktrees are torn down by the human's PR flow, not the reaper"
        )
        XCTAssertTrue(try fixture.manager.branchExists(epic.branch))
    }

    func testReconcileSweepsUpMergedBranchesLeftByEarlierAccepts() async throws {
        let manager = fixture.manager
        let stale = try manager.create(name: "stale", branch: "agentboard/stale-task", base: "main")
        try fixture.commitInto(stale.path)
        try fixture.mergeIntoBase("agentboard/stale-task")
        try manager.remove(path: stale)
        try manager.ensureBranch("agentboard/in-flight", from: "main")
        try SupervisorFixture.git(["branch", "keep-me", "main"], cwd: URL(fileURLWithPath: fixture.project.repoPath))

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertFalse(try manager.branchExists("agentboard/stale-task"), "a merged, worktree-less task branch survived")
        XCTAssertTrue(try manager.branchExists("keep-me"), "the sweep reached outside agentboard/")
        XCTAssertNil(fixture.supervisor.lastError)
    }

    func testReconcileKeepsATaskBranchThatIsStillCheckedOut() async throws {
        let task = try makeTask()
        try fixture.worktreeWorker(task: task, state: .running)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertTrue(try fixture.manager.branchExists("agentboard/\(task.id)"))
    }

    // MARK: - Helpers

    private func makeTask(epicId: String? = nil) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: epicId
        )
    }

    /// Every worktree except the repository's own checkout.
    private func worktreePaths() throws -> [String] {
        let root = URL(fileURLWithPath: fixture.project.worktreeRoot).resolvingSymlinksInPath().path
        return try fixture.manager.list()
            .map { $0.path.resolvingSymlinksInPath().path }
            .filter { $0.hasPrefix(root + "/") }
            .sorted()
    }
}
