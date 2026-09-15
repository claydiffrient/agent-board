import Foundation
import XCTest
@testable import AgentBoardCore

/// Which branch a worker is on, answered from its session row. Deriving it from the task id is
/// right for a worktree and wrong for a shared checkout, and nothing downstream can tell the
/// difference once the wrong answer has been rendered into a briefing.
final class WorkerStandingTests: XCTestCase {
    private let project = Project(
        id: "p", name: "Demo", repoPath: "/tmp/demo", baseBranch: "main",
        worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil, orchSessionId: nil,
        settingsJSON: ProjectSettings().encoded(), createdAt: 0
    )

    private func session(
        worktreePath: String?, branch: String?, cwd: String, role: SessionRole = .worker
    ) -> AgentSession {
        AgentSession(
            sessionId: "s", projectId: project.id, taskId: "t1", role: role,
            worktreePath: worktreePath, branch: branch, cwd: cwd, state: .running
        )
    }

    func testAWorktreeSessionStandsOnItsTaskBranch() {
        let standing = WorkerStanding.recorded(
            session: session(
                worktreePath: "/tmp/demo-worktrees/t1", branch: "agentboard/t1", cwd: "/tmp/demo-worktrees/t1"
            ),
            project: project, taskId: "t1"
        )

        XCTAssertEqual(standing.branch, "agentboard/t1")
        XCTAssertEqual(standing.placement, .worktree)
        XCTAssertEqual(standing.workingDirectory, "/tmp/demo-worktrees/t1")
    }

    func testASharedSessionStandsOnTheGroupsBranchAndNotTheTaskBranch() {
        let shared = SharedCheckoutGroup.branch(epicId: "e1")
        let standing = WorkerStanding.recorded(
            session: session(worktreePath: nil, branch: shared, cwd: project.repoPath),
            project: project, taskId: "t1"
        )

        XCTAssertEqual(standing.branch, shared)
        XCTAssertEqual(standing.placement, .shared(branch: shared))
        XCTAssertNotEqual(standing.branch, TaskStore.branchName(for: "t1"))
    }

    /// The same pair `SharedCheckoutGroup.isMember` insists on: no worktree path alone is not
    /// enough, or a worker standing somewhere else entirely is read as co-resident.
    func testARowWithNoWorktreePathSomewhereElseIsNotSharedButKeepsItsBranch() {
        let standing = WorkerStanding.recorded(
            session: session(worktreePath: nil, branch: "agentboard/t1", cwd: "/tmp/elsewhere"),
            project: project, taskId: "t1"
        )

        XCTAssertEqual(standing.placement, .worktree)
        XCTAssertEqual(standing.branch, "agentboard/t1")
    }

    func testAnOrchestratorRowIsNeverReadAsASharedMember() {
        let standing = WorkerStanding.recorded(
            session: session(
                worktreePath: nil, branch: SharedCheckoutGroup.branchPrefix, cwd: project.repoPath,
                role: .orchestrator
            ),
            project: project, taskId: "t1"
        )

        XCTAssertEqual(standing.placement, .worktree)
    }

    /// Nothing is recorded before a spawn, so the task-id branch is the only answer there is.
    func testNoSessionFallsBackToTheTaskBranch() {
        let standing = WorkerStanding.recorded(session: nil, project: project, taskId: "t1")

        XCTAssertEqual(standing.branch, "agentboard/t1")
        XCTAssertEqual(standing.placement, .worktree)
        XCTAssertNil(standing.workingDirectory)
    }

    func testARowWithNoBranchFallsBackToTheTaskBranch() {
        let standing = WorkerStanding.recorded(
            session: session(worktreePath: nil, branch: nil, cwd: project.repoPath),
            project: project, taskId: "t1"
        )

        XCTAssertEqual(standing.branch, "agentboard/t1")
        XCTAssertEqual(standing.placement, .worktree)
    }
}
