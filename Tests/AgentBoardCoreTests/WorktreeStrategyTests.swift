import Foundation
import XCTest
@testable import AgentBoardCore

final class WorktreeStrategyTests: XCTestCase {
    func testDefaultsToWorktreeAndRoundTrips() {
        XCTAssertEqual(ProjectSettings().worktreeStrategy, .worktree)
        XCTAssertEqual(ProjectSettings.forNewProject().worktreeStrategy, .worktree)

        for strategy in WorktreeStrategy.allCases {
            var settings = ProjectSettings()
            settings.worktreeStrategy = strategy
            XCTAssertEqual(ProjectSettings.decode(settings.encoded()).worktreeStrategy, strategy)
        }
    }

    func testTheThreeValuesEncodeUnderTheirOwnNames() {
        XCTAssertEqual(WorktreeStrategy.allCases.map(\.rawValue), ["worktree", "shared", "auto"])
    }

    func testAnUnknownStrategyOnDiskFallsBackToEveryDefault() {
        let settings = ProjectSettings.decode(#"{"worktreeStrategy":"telepathy","autonomyEnabled":true}"#)

        XCTAssertEqual(settings.worktreeStrategy, .worktree)
        XCTAssertFalse(settings.autonomyEnabled, "a bad value should fail the whole decode, not half of it")
    }
}

final class SharedCheckoutGroupTests: XCTestCase {
    private let epicBranch = SharedCheckoutGroup.branch(epicId: "e1")
    private let looseBranch = SharedCheckoutGroup.branch(epicId: nil)

    func testGroupBranchNamesSeparateEpicsFromEachOtherAndFromNoEpic() {
        XCTAssertEqual(looseBranch, "agentboard/shared")
        XCTAssertEqual(epicBranch, "agentboard/shared-epic-e1")
        XCTAssertNotEqual(epicBranch, SharedCheckoutGroup.branch(epicId: "e2"))
    }

    func testTheGroupHoldsOneAgentUntilLockingLands() {
        XCTAssertEqual(SharedCheckoutGroup.maxMembers, 1)
        XCTAssertTrue(SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1"]).isFull)
        XCTAssertFalse(SharedCheckoutGroup(branch: looseBranch, memberSessionIds: []).isFull)
    }

    func testWorktreeStrategyNeverShares() {
        let groups: [SharedCheckoutGroup?] = [nil, SharedCheckoutGroup(branch: looseBranch, memberSessionIds: [])]
        for group in groups {
            XCTAssertEqual(
                WorkerPlacementDecision.decide(
                    strategy: .worktree, wantedSharedBranch: looseBranch, group: group
                ),
                .worktree
            )
        }
    }

    func testSharedTakesAnEmptyCheckout() {
        XCTAssertEqual(
            WorkerPlacementDecision.decide(strategy: .shared, wantedSharedBranch: looseBranch, group: nil),
            .shared(branch: looseBranch)
        )
    }

    func testSharedFallsBackToAWorktreeWhenTheGroupIsFull() {
        let full = SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1"])

        XCTAssertEqual(
            WorkerPlacementDecision.decide(strategy: .shared, wantedSharedBranch: looseBranch, group: full),
            .worktree
        )
    }

    /// The group's branch carries its base, so a task on a different base asks for a different
    /// branch and is refused even when the group has room.
    func testADifferentBaseIsNotAdmittedEvenWithRoom() {
        let roomy = SharedCheckoutGroup(branch: epicBranch, memberSessionIds: [])

        XCTAssertFalse(roomy.admits(looseBranch))
        for strategy in [WorktreeStrategy.shared, .auto] {
            XCTAssertEqual(
                WorkerPlacementDecision.decide(
                    strategy: strategy, wantedSharedBranch: looseBranch, group: roomy
                ),
                .worktree,
                "\(strategy.rawValue) co-located a task whose base differs from the group's"
            )
        }
    }

    /// With `maxMembers` at 1 a group that holds the checkout never has room, so `auto` isolates
    /// everything today. Raising the constant is what turns this on.
    func testAutoOnlyJoinsAGroupThatAlreadyHoldsTheCheckoutAndHasRoom() {
        XCTAssertEqual(
            WorkerPlacementDecision.decide(strategy: .auto, wantedSharedBranch: looseBranch, group: nil),
            .worktree
        )
        XCTAssertEqual(
            WorkerPlacementDecision.decide(
                strategy: .auto, wantedSharedBranch: looseBranch,
                group: SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1"])
            ),
            .worktree
        )
        XCTAssertEqual(
            WorkerPlacementDecision.decide(
                strategy: .auto, wantedSharedBranch: looseBranch,
                group: SharedCheckoutGroup(branch: looseBranch, memberSessionIds: [])
            ),
            .shared(branch: looseBranch),
            "auto must join a compatible group that has room"
        )
    }

    // MARK: - The group read back out of the database

    private func fixture() throws -> (AppDatabase, Project) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "p", repoPath: "/tmp/p", baseBranch: "main", worktreeRoot: "/tmp/w", memoryDir: nil
        )
        return (db, project)
    }

    @discardableResult
    private func insertSession(
        _ db: AppDatabase, _ project: Project, id: String, worktreePath: String?, branch: String,
        state: SessionState = .running, role: SessionRole = .worker
    ) throws -> AgentSession {
        let session = AgentSession(
            sessionId: id, projectId: project.id, taskId: nil, role: role,
            worktreePath: worktreePath, branch: branch, cwd: worktreePath ?? project.repoPath, state: state
        )
        try SessionStore(db).insert(session)
        return session
    }

    func testNoGroupWhenEveryWorkerHasItsOwnWorktree() throws {
        let (db, project) = try fixture()
        try insertSession(db, project, id: "s1", worktreePath: "/tmp/w/t1", branch: "agentboard/t1")

        XCTAssertNil(try SharedCheckoutGroup.current(db: db, projectId: project.id))
    }

    func testAWorkerWithNoWorktreeIsTheGroup() throws {
        let (db, project) = try fixture()
        try insertSession(db, project, id: "s1", worktreePath: nil, branch: looseBranch)

        let group = try XCTUnwrap(try SharedCheckoutGroup.current(db: db, projectId: project.id))
        XCTAssertEqual(group.branch, looseBranch)
        XCTAssertEqual(group.memberSessionIds, ["s1"])
        XCTAssertTrue(group.isFull)
    }

    /// A worker still being set up already owns the checkout; counting only running ones would let
    /// two spawns in a row both decide the checkout was free.
    func testASetupRowCountsAsAMember() throws {
        let (db, project) = try fixture()
        try insertSession(db, project, id: "s1", worktreePath: nil, branch: looseBranch, state: .setup)

        XCTAssertEqual(try SharedCheckoutGroup.current(db: db, projectId: project.id)?.memberSessionIds, ["s1"])
    }

    func testAFinishedMemberLeavesTheGroup() throws {
        let (db, project) = try fixture()
        try insertSession(db, project, id: "s1", worktreePath: nil, branch: looseBranch, state: .completed)

        XCTAssertNil(try SharedCheckoutGroup.current(db: db, projectId: project.id))
    }

    /// The orchestrator also runs in the repository with no worktree of its own; it is not a member.
    func testTheOrchestratorIsNotAMember() throws {
        let (db, project) = try fixture()
        try insertSession(db, project, id: "s1", worktreePath: nil, branch: "main", role: .orchestrator)

        XCTAssertNil(try SharedCheckoutGroup.current(db: db, projectId: project.id))
    }

    func testASharedBranchIsNotMistakenForATaskBranch() {
        XCTAssertNil(TaskBranchLedger.taskId(ofBranch: "agentboard/shared"))
        XCTAssertNil(TaskBranchLedger.taskId(ofBranch: "agentboard/shared-epic-e1"))
        XCTAssertEqual(TaskBranchLedger.taskId(ofBranch: "agentboard/t1"), "t1")
    }
}

final class OpeningPromptPlacementTests: XCTestCase {
    private func task() -> BoardTask {
        BoardTask(
            id: BoardId.new(), projectId: "p", epicId: nil, title: "t", body: nil, acceptance: nil,
            priority: nil, column: .ready, ordering: 1, origin: .human,
            createdAt: .nowMillis, updatedAt: .nowMillis
        )
    }

    func testAWorktreeWorkerIsToldItHasOne() {
        let prompt = OpeningPrompt.compose(task: task(), branch: "agentboard/x", attempt: 1)

        XCTAssertTrue(prompt.contains("You are in a dedicated git worktree on branch `agentboard/x`"), prompt)
    }

    func testASharedWorkerIsNotToldItHasAWorktree() {
        let prompt = OpeningPrompt.compose(
            task: task(), branch: "agentboard/shared", attempt: 1,
            placement: .shared(branch: "agentboard/shared")
        )

        XCTAssertFalse(prompt.contains("dedicated git worktree"), prompt)
        XCTAssertTrue(prompt.contains("project's own checkout on shared branch `agentboard/shared`"), prompt)
        XCTAssertTrue(prompt.contains("another agent may join this same checkout"), prompt)
        XCTAssertTrue(prompt.contains("Do not push."), prompt)
    }
}
