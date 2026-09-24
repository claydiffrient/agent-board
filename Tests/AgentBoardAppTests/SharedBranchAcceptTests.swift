import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// Accepting tasks that shared one branch, against a real git repository: nothing is merged or
/// reaped until the last member is accepted, and then both happen exactly once.
@MainActor
final class SharedBranchAcceptTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var epic: Epic!
    private var branch: String!
    private var alpha: BoardTask!
    private var beta: BoardTask!
    /// Where the shared branch was cut: the epic branch's head before anyone committed on it.
    private var branchBase: String!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        try fixture.setWorktreeStrategy(.shared, maxAgents: 2)
        epic = try EpicStore(fixture.db).create(
            projectId: fixture.project.id, title: "Roster", goal: "ship the roster"
        )
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        branch = SharedCheckoutGroup.branch(epicId: epic.id)
        try SupervisorFixture.git(["checkout", "-q", "-b", branch, epic.branch], cwd: fixture.repo)
        branchBase = try headOf(epic.branch)
        alpha = try makeTask("Alpha")
        beta = try makeTask("Beta")
        try sharedSession("alpha-session", task: alpha)
        try sharedSession("beta-session", task: beta)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    // MARK: - The defect

    /// The whole sequence: one accept moves nothing, the second moves everything once. The epic
    /// branch is moved on first so the merge is a real merge commit rather than a fast-forward,
    /// which is what makes "exactly once" countable.
    func testAcceptingOneMemberMergesNothingAndAcceptingTheLastMergesOnce() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")
        try write("alpha.txt", "a\na2\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Extend alpha")
        try fixture.commitOn(branch: epic.branch, message: "Sibling work already on the epic branch")
        let epicHeadBefore = try headOf(epic.branch)
        let sharedHead = try headOf(branch)

        try await fixture.supervisor.accept(taskId: alpha.id)

        XCTAssertEqual(try headOf(epic.branch), epicHeadBefore, "accepting one member merged the shared branch early")
        XCTAssertTrue(try fixture.manager.branchExists(branch), "the shared branch was reaped with a member unaccepted")
        XCTAssertEqual(try headOf(branch), sharedHead, "the shared branch moved")
        for sha in try attributedCommits(of: alpha) {
            XCTAssertFalse(try isAncestor(sha, of: epic.branch), "alpha's \(sha) reached the epic branch early")
        }

        try await fixture.supervisor.accept(taskId: beta.id)

        XCTAssertEqual(try parents(try headOf(epic.branch)), [epicHeadBefore, sharedHead], "the epic branch did not get one merge of the shared branch")
        XCTAssertFalse(try fixture.manager.branchExists(branch), "the shared branch was not reaped")
        XCTAssertEqual(try mergeCommitCount(epic.branch), 1, "the shared branch was merged more than once")
    }

    /// The acceptance criterion in its own right: a co-resident task's commits, selected by the
    /// commit ledger, are on the epic branch once the branch is accepted.
    func testAnAcceptedCoResidentTasksOwnCommitsLandOnTheEpicBranch() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")
        let alphaCommits = try attributedCommits(of: alpha)
        XCTAssertEqual(alphaCommits.count, 1)

        try await fixture.supervisor.accept(taskId: alpha.id)
        try await fixture.supervisor.accept(taskId: beta.id)

        for sha in alphaCommits {
            XCTAssertTrue(try isAncestor(sha, of: epic.branch), "alpha's \(sha) never reached \(epic.branch)")
        }
        for sha in try attributedCommits(of: beta, on: epic.branch) {
            XCTAssertTrue(try isAncestor(sha, of: epic.branch), "beta's \(sha) never reached \(epic.branch)")
        }
        XCTAssertTrue(
            try fileExistsOnBranch("alpha.txt", epic.branch),
            "the epic branch does not carry alpha's file"
        )
        XCTAssertTrue(try fileExistsOnBranch("beta.txt", epic.branch))
    }

    /// Both accepts see every member accepted, so both reach the merge; only one may run it.
    func testTwoConcurrentLastAcceptsMergeTheSharedBranchOnce() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")
        try fixture.commitOn(branch: epic.branch, message: "Sibling work already on the epic branch")
        let sharedHead = try headOf(branch)

        let supervisor = fixture.supervisor
        async let alphaAccept: Void = supervisor.accept(taskId: alpha.id)
        async let betaAccept: Void = supervisor.accept(taskId: beta.id)
        _ = try await (alphaAccept, betaAccept)

        XCTAssertTrue(try isAncestor(sharedHead, of: epic.branch), "the shared branch never reached the epic branch")
        XCTAssertEqual(try mergeCommitCount(epic.branch), 1, "the shared branch was merged more than once")
        XCTAssertEqual(try fixture.tasks.get(alpha.id)?.landing, .landed)
        XCTAssertEqual(try fixture.tasks.get(beta.id)?.landing, .landed)
        XCTAssertEqual(try mergeReports(), [])
    }

    // MARK: - Reaping

    /// `reconcile`'s sweep is the second path that drops merged `agentboard/*` branches.
    func testReconcileDoesNotReapASharedBranchWithAnUnacceptedMember() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try await fixture.supervisor.accept(taskId: alpha.id)

        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertTrue(try fixture.manager.branchExists(branch), "reconcile reaped a shared branch mid-flight")
    }

    /// Even with every member accepted, the branch's own merge is what reaps it — never a sweep
    /// that has no way to know the work reached the epic branch.
    func testASharedBranchIsReapedExactlyOnce() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")

        try await fixture.supervisor.accept(taskId: alpha.id)
        try await fixture.supervisor.accept(taskId: beta.id)
        let epicHead = try headOf(epic.branch)
        await fixture.supervisor.reconcile(projectId: fixture.project.id)

        XCTAssertFalse(try fixture.manager.branchExists(branch))
        XCTAssertEqual(try headOf(epic.branch), epicHead, "a second pass moved the epic branch again")
        XCTAssertEqual(try commitCount(from: branchBase, to: epic.branch), 2, "the shared commits landed twice")
    }

    /// The checkout has to come off the shared branch before it can be deleted, and the project's
    /// own repository must be left somewhere sensible.
    func testReapingLeavesTheCheckoutOnTheEpicBranch() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try await fixture.supervisor.accept(taskId: alpha.id)
        try await fixture.supervisor.accept(taskId: beta.id)

        XCTAssertEqual(try fixture.manager.currentBranch(at: fixture.repo), epic.branch)
    }

    /// What happens when one member is rejected while its siblings are accepted: the branch waits
    /// for that task to be redone on it. Its commits are interleaved with everyone else's, so there
    /// is no range to leave out and Agent Board does not unpick commits.
    func testARejectedMemberHoldsTheBranchForItsSiblings() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")
        let epicHeadBefore = try headOf(epic.branch)

        try await fixture.supervisor.accept(taskId: beta.id)
        try await fixture.supervisor.reopen(taskId: beta.id)
        try await fixture.supervisor.accept(taskId: alpha.id)

        XCTAssertEqual(try headOf(epic.branch), epicHeadBefore, "a reopened member's branch was merged anyway")
        XCTAssertTrue(try fixture.manager.branchExists(branch))

        try await fixture.supervisor.accept(taskId: beta.id)

        XCTAssertNotEqual(try headOf(epic.branch), epicHeadBefore, "redoing the rejected member never released the branch")
        XCTAssertFalse(try fixture.manager.branchExists(branch))
    }

    /// The accepted-but-not-merged case is not silent: the report names the branch and what it is
    /// still waiting for.
    func testTheReportNamesWhatTheSharedBranchIsWaitingFor() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")

        try await fixture.supervisor.accept(taskId: alpha.id)

        let body = try XCTUnwrap(try mergeReports().first)
        XCTAssertTrue(body.contains(branch), body)
        XCTAssertTrue(body.contains(beta.id), body)
        XCTAssertTrue(body.contains("does not unpick commits"), body)
    }

    // MARK: - Locks and the group record

    func testAcceptingTheLastMemberLeavesNoLockHeldAndNoGroup() async throws {
        let locks = FileLockStore(fixture.db)
        try locks.acquire(projectId: fixture.project.id, path: "alpha.txt", sessionId: "alpha-session", taskId: alpha.id)
        try locks.acquire(projectId: fixture.project.id, path: "beta.txt", sessionId: "beta-session", taskId: beta.id)
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")

        try await fixture.supervisor.accept(taskId: alpha.id)
        XCTAssertEqual(try locks.held(projectId: fixture.project.id).map(\.path), ["beta.txt"])

        try await fixture.supervisor.accept(taskId: beta.id)

        XCTAssertEqual(try locks.held(projectId: fixture.project.id), [])
        XCTAssertNil(try SharedCheckoutGroup.current(db: fixture.db, projectId: fixture.project.id))
    }

    /// A member still running holds the checkout; nothing may be reaped out from under it. An accept
    /// stops every live session on its task but the one doing the accepting, so that is the one left.
    func testALiveMemberKeepsTheSharedBranch() async throws {
        try fixture.sessions.setState("beta-session", .running)
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")

        try await fixture.supervisor.accept(taskId: alpha.id)
        try await fixture.supervisor.accept(
            taskId: beta.id, acceptedBy: .reviewer(name: "Rae", verdict: "ok", sessionId: "beta-session")
        )

        XCTAssertTrue(try fixture.manager.branchExists(branch), "a live member's branch was reaped")
    }

    // MARK: - The ledger

    func testTheLedgerRecordsEachMembersOwnTipRatherThanTheBranchTip() async throws {
        try write("alpha.txt", "a\n")
        try await commit(alpha, paths: ["alpha.txt"], message: "Add alpha")
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")
        let alphaTip = try XCTUnwrap(try attributedCommits(of: alpha).first)
        let sharedTip = try headOf(branch)
        XCTAssertNotEqual(alphaTip, sharedTip)

        try await fixture.supervisor.accept(taskId: alpha.id)
        try await fixture.supervisor.accept(taskId: beta.id)

        let recorded = try fixture.manager.refCommit(TaskBranchLedger.tipRef(taskId: alpha.id))
        XCTAssertEqual(recorded, alphaTip, "the ledger claimed the branch tip as alpha's own")
        XCTAssertEqual(
            try fixture.manager.refCommit(TaskBranchLedger.baseRef(taskId: alpha.id)),
            branchBase,
            "the recorded base is not where the shared branch was cut"
        )
    }

    /// A member that committed nothing is recorded as having committed nothing, not as unknown.
    func testAMemberThatCommittedNothingIsRecordedAsSuch() async throws {
        try write("beta.txt", "b\n")
        try await commit(beta, paths: ["beta.txt"], message: "Add beta")

        try await fixture.supervisor.accept(taskId: alpha.id)
        try await fixture.supervisor.accept(taskId: beta.id)

        let base = try XCTUnwrap(try fixture.manager.refCommit(TaskBranchLedger.baseRef(taskId: alpha.id)))
        let tip = try XCTUnwrap(try fixture.manager.refCommit(TaskBranchLedger.tipRef(taskId: alpha.id)))
        XCTAssertEqual(base, tip, "a member with no commits should record a tip equal to its base")
        XCTAssertEqual(
            TaskBranchEvidence.read(
                TaskBranchFacts(recordedBase: base, recordedTip: tip, tipOnEpicBranch: true, ownCommits: 0)
            ),
            .nothingCommitted
        )
    }

    // MARK: - Helpers

    private func makeTask(_ title: String) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: epic.id
        )
    }

    private func sharedSession(_ id: String, task: BoardTask) throws {
        try fixture.sessions.insert(
            AgentSession(
                sessionId: id, shortId: id, projectId: fixture.project.id, taskId: task.id, role: .worker,
                worktreePath: nil, branch: branch, cwd: fixture.repo.path, state: .completed
            )
        )
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = fixture.repo.appendingPathComponent(path)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// What `commit_my_work` does: commit the body verbatim, then record the sha against the task.
    private func commit(_ task: BoardTask, paths: [String], message: String) async throws {
        let outcome = try await ScopedCommitRunner().commit(
            ScopedCommitRequest(
                repoPath: fixture.repo.path, branch: branch, taskId: task.id, paths: paths,
                message: message
            )
        )
        guard case .committed(let sha, _) = outcome else {
            return XCTFail("\(task.title) did not commit: \(outcome)")
        }
        try TaskCommitStore(fixture.db).record(taskId: task.id, sha: sha)
    }

    private func attributedCommits(of task: BoardTask, on ref: String? = nil) throws -> [String] {
        try fixture.manager.commits(taskId: task.id, on: ref ?? branch, since: "main")
    }

    private func headOf(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", "--verify", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAncestor(_ commit: String, of ref: String) throws -> Bool {
        (try? fixture.git(["merge-base", "--is-ancestor", commit, ref])) != nil
    }

    private func fileExistsOnBranch(_ path: String, _ ref: String) throws -> Bool {
        (try? fixture.git(["cat-file", "-e", "\(ref):\(path)"])) != nil
    }

    /// Acceptance always queues its own `decision` report; only the merge notices name the branch.
    private func mergeReports() throws -> [String] {
        try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id)
            .map(\.body)
            .filter { $0.contains("but its branch") }
    }

    private func parents(_ commit: String) throws -> [String] {
        Array(
            try fixture.git(["rev-list", "--parents", "-n", "1", commit])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .map(String.init)
                .dropFirst()
        )
    }

    private func commitCount(from base: String, to ref: String) throws -> Int {
        Int(try fixture.git(["rev-list", "--count", "\(base)..\(ref)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func mergeCommitCount(_ ref: String) throws -> Int {
        Int(try fixture.git(["rev-list", "--merges", "--count", ref])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
