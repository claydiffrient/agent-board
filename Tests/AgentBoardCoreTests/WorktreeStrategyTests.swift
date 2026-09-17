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

    func testTheGroupHoldsThreeAgentsByDefaultAndTakesItsSizeFromTheProject() {
        XCTAssertEqual(ProjectSettings().sharedCheckoutMaxAgents, 3)
        let defaultSized = SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1", "s2"])
        XCTAssertFalse(defaultSized.isFull)
        XCTAssertTrue(SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1", "s2", "s3"]).isFull)
        XCTAssertTrue(
            SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1"], maxMembers: 1).isFull,
            "a project that configures a group of one must still get a group of one"
        )
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
        let full = SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1"], maxMembers: 1)

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
                group: SharedCheckoutGroup(branch: looseBranch, memberSessionIds: ["s1"], maxMembers: 1)
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
        XCTAssertEqual(group.maxMembers, ProjectSettings().sharedCheckoutMaxAgents)
        XCTAssertFalse(group.isFull, "one member does not fill a group of \(group.maxMembers)")
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

    private func sharedPrompt(directory: String? = "/repos/demo") -> String {
        OpeningPrompt.compose(
            task: task(), branch: "agentboard/shared", attempt: 1,
            placement: .shared(branch: "agentboard/shared"), workingDirectory: directory
        )
    }

    func testAWorktreeWorkerIsToldItHasOneAndWhereItIs() {
        let prompt = OpeningPrompt.compose(
            task: task(), branch: "agentboard/x", attempt: 1, workingDirectory: "/worktrees/x"
        )

        XCTAssertTrue(prompt.contains("dedicated git worktree at `/worktrees/x` on branch `agentboard/x`"), prompt)
        XCTAssertTrue(prompt.contains("Commit on the current branch."), prompt)
        XCTAssertFalse(prompt.contains("commit_my_work"), prompt)
    }

    func testASharedWorkerIsNotToldItHasAWorktree() {
        let prompt = sharedPrompt()

        XCTAssertFalse(prompt.contains("dedicated git worktree"), prompt)
        XCTAssertTrue(prompt.contains("project's own checkout at `/repos/demo`"), prompt)
        XCTAssertTrue(prompt.contains("shared branch `agentboard/shared`"), prompt)
        XCTAssertTrue(prompt.contains("Do not push."), prompt)
    }

    func testASharedWorkerIsToldSiblingsAreInTheSameTree() {
        let prompt = sharedPrompt()

        XCTAssertTrue(prompt.contains("Other agents are working on their own tasks in this same tree"), prompt)
        XCTAssertTrue(prompt.contains("`git status` and `git diff` show their work next to yours"), prompt)
    }

    func testASharedWorkerIsToldItsWritesAreLockedAndMayWait() {
        let prompt = sharedPrompt()

        XCTAssertTrue(prompt.contains("first write to a file locks it for you"), prompt)
        XCTAssertTrue(prompt.contains("your write waits"), prompt)
        XCTAssertTrue(prompt.contains("\(Int(FileLockPolicy.waitTimeout))s"), prompt)
        XCTAssertTrue(prompt.contains("report_blocked"), prompt)
    }

    /// The worker must not learn that `git commit` is refused by running it.
    func testASharedWorkerIsToldHowItsCommitIsScopedBeforeItTriesGit() {
        let prompt = sharedPrompt()

        XCTAssertTrue(prompt.contains("`git commit` is refused here"), prompt)
        XCTAssertTrue(prompt.contains("commits exactly the files you have written"), prompt)
        XCTAssertTrue(prompt.contains("records the commit as yours"), prompt)
        XCTAssertTrue(prompt.contains("Commit by calling `commit_my_work(message)`"), prompt)
        XCTAssertFalse(
            prompt.contains("1. Commit on the current branch."),
            "the shared worker is still being told to commit with git"
        )
    }

    func testTheSharedPromptNamesEveryGitCommandThatIsRefusedInTheCheckout() {
        let prompt = sharedPrompt()
        for command in ["stash", "checkout", "switch", "reset", "clean", "rm", "merge", "rebase", "pull"] {
            XCTAssertTrue(prompt.contains("`git \(command)`"), "the prompt does not mention `git \(command)`")
        }
        XCTAssertTrue(prompt.contains("git restore -- <path>"), prompt)
        XCTAssertTrue(prompt.contains("locked"), prompt)
    }

    func testAWorktreePromptSaysNothingAboutRefusedGitCommands() {
        let prompt = OpeningPrompt.compose(
            task: task(), branch: "agentboard/t1", attempt: 1, placement: .worktree,
            workingDirectory: "/repos/wt"
        )
        XCTAssertFalse(prompt.contains("`git stash`"), prompt)
        XCTAssertFalse(prompt.contains("refused"), prompt)
    }

    func testAnUnknownDirectoryDegradesToAPhraseRatherThanAnEmptyBacktickPair() {
        let prompt = sharedPrompt(directory: nil)

        XCTAssertTrue(prompt.contains("project's own checkout at this directory"), prompt)
        XCTAssertFalse(prompt.contains("at ``"), prompt)
    }
}
