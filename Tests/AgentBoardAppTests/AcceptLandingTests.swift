import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5: accepting a task records where its work went, so `done` can never quietly mean
/// "done, and the work is nowhere". Seven tasks reached `done` with their commits on no other
/// branch before this existed, and nothing on the board said so.
@MainActor
final class AcceptLandingTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    /// The case behind every incident: a standalone task, accepted while the branch it should land
    /// on is checked out in the project's own repository.
    func testAcceptingAStandaloneTaskWhoseBaseBranchIsCheckedOutMarksItUnlanded() async throws {
        XCTAssertEqual(try currentBranchOfPrimaryCheckout(), "main", "the fixture must start with main checked out")
        let task = try makeTask(epicId: nil)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        let mainBefore = try headOf("main")
        let taskHead = try headOf("agentboard/\(task.id)")

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.column, .done, "a git refusal must not hold the task out of done")
        XCTAssertEqual(accepted.landing, .unlanded, "the accept left no record that the work is stranded")
        XCTAssertTrue(accepted.needsLanding)
        let detail = try XCTUnwrap(accepted.landingDetail)
        XCTAssertTrue(detail.contains(fixture.repo.path), detail)
        XCTAssertTrue(detail.contains("agentboard/\(task.id)"), detail)

        XCTAssertEqual(try headOf("main"), mainBefore, "the accept moved a branch a working tree holds")
        XCTAssertEqual(try headOf("agentboard/\(task.id)"), taskHead, "the work is no longer on its own branch")
        XCTAssertEqual(try currentBranchOfPrimaryCheckout(), "main", "the accept switched the primary checkout")
        XCTAssertEqual(try fixture.git(["status", "--porcelain"], cwd: fixture.repo), "")

        XCTAssertEqual(try awaitingLandingIds(), [task.id])
        let report = try XCTUnwrap(try landingReports().first)
        XCTAssertTrue(report.contains(task.id), report)
        XCTAssertTrue(report.contains("checked out at"), report)
    }

    /// Same task, same accept, with nothing holding the base branch: the work lands and the board
    /// says nothing, because there is nothing to say.
    func testAcceptingAStandaloneTaskLandsItWhenNothingHoldsTheBaseBranch() async throws {
        let task = try makeTask(epicId: nil)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        let taskHead = try headOf("agentboard/\(task.id)")
        try detachPrimaryCheckout()

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.column, .done)
        XCTAssertEqual(accepted.landing, .landed)
        XCTAssertFalse(accepted.needsLanding)
        XCTAssertEqual(try headOf("main"), taskHead, "the base branch did not take the work")
        XCTAssertEqual(try awaitingLandingIds(), [])
        XCTAssertEqual(try landingReports(), [])
    }

    /// The non-code case the notes epic is separately working out: no branch is not stranded, and
    /// the board must not light up for it.
    func testATaskThatCommittedNothingLandsAsNoBranchRatherThanUnlanded() async throws {
        let task = try makeTask(epicId: nil)

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.column, .done)
        XCTAssertEqual(accepted.landing, .noBranch, "a task with nothing to land must be its own state")
        XCTAssertNotEqual(accepted.landing, .unlanded)
        XCTAssertFalse(accepted.needsLanding)
        XCTAssertEqual(try awaitingLandingIds(), [])
        XCTAssertEqual(try landingReports(), [])
    }

    /// Teardown reaps a branch whose work is already in, so by the time the merge looks there is no
    /// branch left. That must read as landed, not as "nothing to land": the ledger tip ref outlives
    /// the branch and says which it was.
    func testABranchReapedBecauseItsWorkWasAlreadyInReadsAsLanded() async throws {
        let task = try makeTask(epicId: nil)
        try fixture.worktreeWorker(task: task)

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertFalse(try fixture.manager.branchExists("agentboard/\(task.id)"), "teardown was expected to reap it")
        XCTAssertEqual(accepted.landing, .landed)
        XCTAssertFalse(accepted.needsLanding)
        XCTAssertEqual(try awaitingLandingIds(), [])
    }

    /// The worst shape of the bug: the branch is gone and the target does not carry its tip, so the
    /// commit is reachable from nothing. It must not be filed as "nothing to land".
    func testABranchReapedWithItsWorkStillOutOfTheTargetReadsAsUnlanded() async throws {
        let task = try makeTask(epicId: nil)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        let tip = try headOf("agentboard/\(task.id)")
        try fixture.manager.setRef(TaskBranchLedger.tipRef(taskId: task.id), to: tip)
        try fixture.git(["worktree", "remove", "--force", try XCTUnwrap(session.worktreePath)], cwd: fixture.repo)
        try fixture.git(["branch", "-D", "agentboard/\(task.id)"], cwd: fixture.repo)

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.column, .done)
        XCTAssertEqual(accepted.landing, .unlanded)
        XCTAssertTrue(try XCTUnwrap(accepted.landingDetail).contains(tip))
        XCTAssertEqual(try awaitingLandingIds(), [task.id])
    }

    func testAnEpicTaskThatMergesIsRecordedAsLanded() async throws {
        let epic = try EpicStore(fixture.db).create(projectId: fixture.project.id, title: "Roster", goal: nil)
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let worktree = try fixture.manager.create(
            name: task.id, branch: "agentboard/\(task.id)", base: epic.branch
        )
        try fixture.sessions.insert(
            AgentSession(
                sessionId: "session-\(UUID().uuidString)", shortId: "short-1",
                projectId: fixture.project.id, taskId: task.id, role: .worker,
                worktreePath: worktree.path, branch: "agentboard/\(task.id)", cwd: worktree.path,
                state: .completed, attempt: 1
            )
        )
        try fixture.commitInto(worktree.path)

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.landing, .landed)
        XCTAssertEqual(try headOf(epic.branch), try headOf("agentboard/\(task.id)"))
        XCTAssertEqual(try awaitingLandingIds(), [])
    }

    /// An epic accept is not immune either — three of the thirteen tasks found stranded were in an
    /// epic whose branch the integrator held.
    func testAnEpicTaskWhoseBranchIsHeldIsRecordedAsUnlanded() async throws {
        let epic = try EpicStore(fixture.db).create(projectId: fixture.project.id, title: "Roster", goal: nil)
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let worktree = try fixture.manager.create(
            name: task.id, branch: "agentboard/\(task.id)", base: epic.branch
        )
        try fixture.sessions.insert(
            AgentSession(
                sessionId: "session-\(UUID().uuidString)", shortId: "short-1",
                projectId: fixture.project.id, taskId: task.id, role: .worker,
                worktreePath: worktree.path, branch: "agentboard/\(task.id)", cwd: worktree.path,
                state: .completed, attempt: 1
            )
        )
        try fixture.commitInto(worktree.path)
        let integration = try fixture.manager.createForBranch(name: "epic-\(epic.id)", branch: epic.branch)

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertEqual(accepted.column, .done)
        XCTAssertEqual(accepted.landing, .unlanded)
        XCTAssertTrue(try XCTUnwrap(accepted.landingDetail).contains(integration.path))
        XCTAssertEqual(try awaitingLandingIds(), [task.id])
    }

    /// Reopening takes the task out of `done`, so the landing it was carrying no longer describes
    /// anything and must not outlive it on the card.
    func testReopeningClearsTheLanding() async throws {
        let task = try makeTask(epicId: nil)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        try await fixture.supervisor.accept(taskId: task.id)
        XCTAssertEqual(try XCTUnwrap(try fixture.tasks.get(task.id)).landing, .unlanded)

        try await fixture.supervisor.reopen(taskId: task.id)

        let reopened = try XCTUnwrap(try fixture.tasks.get(task.id))
        XCTAssertNil(reopened.landing)
        XCTAssertNil(reopened.landingDetail)
        XCTAssertFalse(reopened.needsLanding)
        XCTAssertEqual(try awaitingLandingIds(), [])
    }

    // MARK: - Helpers

    private func makeTask(epicId: String?) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .review, origin: .human, epicId: epicId
        )
    }

    /// Frees `main` without moving it, so the same accept can be run against a base branch nothing
    /// holds — the difference the incidents turned on.
    private func detachPrimaryCheckout() throws {
        try fixture.git(["checkout", "--detach", "--quiet", "main"], cwd: fixture.repo)
    }

    private func currentBranchOfPrimaryCheckout() throws -> String? {
        try fixture.manager.currentBranch(at: fixture.repo)
    }

    private func headOf(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", "--verify", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func awaitingLandingIds() throws -> [String] {
        try fixture.tasks.awaitingLanding(projectId: fixture.project.id).map(\.id)
    }

    private func landingReports() throws -> [String] {
        try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id)
            .map(\.body)
            .filter { $0.contains("but its branch") }
    }
}
