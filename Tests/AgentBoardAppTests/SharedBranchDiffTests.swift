import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// What the task card and the approvals sidebar read for a shared-branch task, against a real git
/// repository holding two tasks' interleaved commits.
@MainActor
final class SharedBranchDiffTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private let branch = "agentboard/shared"
    private var alpha: BoardTask!
    private var beta: BoardTask!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        try SupervisorFixture.git(["checkout", "-q", "-b", branch], cwd: fixture.repo)
        alpha = try makeTask("Alpha")
        beta = try makeTask("Beta")
        try sharedSession("alpha-session", task: alpha)
        try sharedSession("beta-session", task: beta)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func makeTask(_ title: String) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
    }

    /// A shared worker's row: no worktree of its own, cwd is the project's checkout.
    private func sharedSession(_ id: String, task: BoardTask) throws {
        try fixture.sessions.insert(
            AgentSession(
                sessionId: id, projectId: fixture.project.id, taskId: task.id, role: .worker,
                worktreePath: nil, branch: branch, cwd: fixture.repo.path, state: .running
            )
        )
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = fixture.repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ task: BoardTask, paths: [String], message: String) async throws {
        let outcome = try await ScopedCommitRunner().commit(
            ScopedCommitRequest(
                repoPath: fixture.repo.path, branch: branch, taskId: task.id, paths: paths,
                message: CommitAttribution.message(message, taskId: task.id)
            )
        )
        guard case .committed = outcome else { return XCTFail("\(task.title) did not commit: \(outcome)") }
    }

    func testEachTasksDiffHoldsOnlyItsOwnFiles() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")
        try write("alpha.txt", "a\na2\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Extend alpha")

        let alphaDiff = await fixture.supervisor.worktreeDiffstat(taskId: alpha.id)
        let betaDiff = await fixture.supervisor.worktreeDiffstat(taskId: beta.id)
        let alphaStat = try XCTUnwrap(alphaDiff)
        let betaStat = try XCTUnwrap(betaDiff)
        let alphaSummary = await fixture.supervisor.worktreeDiffSummary(taskId: alpha.id)
        let betaSummary = await fixture.supervisor.worktreeDiffSummary(taskId: beta.id)

        XCTAssertTrue(alphaStat.contains("alpha.txt"), alphaStat)
        XCTAssertFalse(alphaStat.contains("beta.txt"), alphaStat)
        XCTAssertTrue(betaStat.contains("beta.txt"), betaStat)
        XCTAssertFalse(betaStat.contains("alpha.txt"), betaStat)
        XCTAssertEqual(alphaSummary, DiffSummary(filesChanged: 1, insertions: 2, deletions: 0))
        XCTAssertEqual(betaSummary, DiffSummary(filesChanged: 1, insertions: 1, deletions: 0))
    }

    /// The failure worth naming: before attribution this read as the sibling's whole branch.
    func testATaskThatHasCommittedNothingReadsAsEmpty() async throws {
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")

        let stat = await fixture.supervisor.worktreeDiffstat(taskId: alpha.id)
        let summary = await fixture.supervisor.worktreeDiffSummary(taskId: alpha.id)

        XCTAssertEqual(stat, "")
        XCTAssertEqual(summary, DiffSummary())
        XCTAssertEqual(summary?.isEmpty, true)
    }

    /// A commit made outside Agent Board — the human's own, or a merge — belongs to no task.
    func testAnUntaggedCommitOnTheSharedBranchIsNobodysWork() async throws {
        try write("human.txt", "by hand\n")
        try SupervisorFixture.git(["add", "human.txt"], cwd: fixture.repo)
        try SupervisorFixture.git(["commit", "-q", "-m", "A hand-made commit"], cwd: fixture.repo)

        let alphaStat = await fixture.supervisor.worktreeDiffstat(taskId: alpha.id)
        let betaStat = await fixture.supervisor.worktreeDiffstat(taskId: beta.id)

        XCTAssertEqual(alphaStat, "")
        XCTAssertEqual(betaStat, "")
    }

    /// The worktree path has to keep working; nothing here may change what an isolated task reads.
    func testAWorktreeTaskStillDiffsItsWholeBranch() async throws {
        let isolated = try makeTask("Isolated")
        let manager = WorktreeManager(
            repoPath: fixture.repo, worktreeRoot: fixture.supportDir.appendingPathComponent("worktrees")
        )
        let path = try manager.create(name: isolated.id, branch: "agentboard/\(isolated.id)", base: "main")
        try "x\n".write(to: path.appendingPathComponent("isolated.txt"), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", "."], cwd: path)
        try SupervisorFixture.git(["commit", "-q", "-m", "Add isolated"], cwd: path)
        try fixture.sessions.insert(
            AgentSession(
                sessionId: "isolated-session", projectId: fixture.project.id, taskId: isolated.id,
                role: .worker, worktreePath: path.path, branch: "agentboard/\(isolated.id)",
                cwd: path.path, state: .running
            )
        )

        let diff = await fixture.supervisor.worktreeDiffstat(taskId: isolated.id)
        let stat = try XCTUnwrap(diff)

        XCTAssertTrue(stat.contains("isolated.txt"), stat)
        XCTAssertTrue(stat.contains("1 file changed"), stat)
    }
}
