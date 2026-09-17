import Foundation
import XCTest
@testable import AgentBoardCore

final class IntegrationPlanTests: XCTestCase {
    private let swiftCommands = VerificationCommands(build: "swift build", test: "swift test")

    private func epic(_ f: Fixture, title: String = "Ship search", goal: String? = "make it fast") throws -> Epic {
        try f.epics.create(projectId: f.project.id, title: title, goal: goal)
    }

    private func tasks(_ f: Fixture, _ specs: [NewEpicTask]) throws -> (Epic, [BoardTask]) {
        try f.board.createEpic(projectId: f.project.id, title: "Ship search", goal: "make it fast", tasks: specs)
    }

    // MARK: - order

    func testOrderPutsEveryTaskAfterWhatItDependsOn() throws {
        let f = try Fixture.make()
        let (_, created) = try tasks(f, [
            NewEpicTask(title: "ui", dependsOn: [2]),
            NewEpicTask(title: "schema"),
            NewEpicTask(title: "api", dependsOn: [1]),
        ])
        var deps: [String: [String]] = [:]
        for task in created { deps[task.id] = try f.tasks.deps(of: task.id) }

        let ordered = IntegrationPlan.order(created, deps: deps).map(\.title)

        XCTAssertEqual(ordered, ["schema", "api", "ui"])
    }

    func testOrderIgnoresDependenciesOutsideTheEpic() {
        let stranger = task("outsider")
        let only = task("inside")

        let ordered = IntegrationPlan.order([only], deps: [only.id: [stranger.id]])

        XCTAssertEqual(ordered.map(\.title), ["inside"])
    }

    func testOrderKeepsEveryTaskWhenDependenciesCycle() {
        let a = task("a")
        let b = task("b")

        let ordered = IntegrationPlan.order([a, b], deps: [a.id: [b.id], b.id: [a.id]])

        XCTAssertEqual(Set(ordered.map(\.title)), ["a", "b"])
        XCTAssertEqual(ordered.count, 2)
    }

    // MARK: - classify

    func testClassifySplitsMergedExistingAndMissingBranches() {
        let done = task("already in")
        let pending = task("to merge")
        let never = task("never started")

        let branches = IntegrationPlan.classify(
            [done, pending, never],
            facts: [
                done.id: TaskBranchFacts(branchExists: true, mergedIntoEpic: true),
                pending.id: TaskBranchFacts(branchExists: true),
                never.id: TaskBranchFacts(everDispatched: false),
            ]
        )

        XCTAssertEqual(branches.map(\.disposition), [.alreadyMerged, .merge, .missing])
        XCTAssertEqual(branches.map(\.branch), [done, pending, never].map { IntegrationPlan.branchName(taskId: $0.id) })
    }

    func testClassifyCallsAReapedBranchLandedRatherThanMissing() {
        let reaped = task("merged then reaped")

        let branches = IntegrationPlan.classify(
            [reaped],
            facts: [reaped.id: TaskBranchFacts(
                recordedBase: "aaaa", recordedTip: "bbbb", tipOnEpicBranch: true, ownCommits: 3
            )]
        )

        XCTAssertEqual(branches.map(\.disposition), [.landed])
        XCTAssertEqual(branches[0].commit, "bbbb")
    }

    func testClassifyCallsABranchThatCarriedNothingMissing() {
        let empty = task("worker committed nothing")

        let branches = IntegrationPlan.classify(
            [empty],
            facts: [empty.id: TaskBranchFacts(
                recordedBase: "aaaa", recordedTip: "aaaa", tipOnEpicBranch: true, ownCommits: 0
            )]
        )

        XCTAssertEqual(branches.map(\.disposition), [.missing])
    }

    func testClassifyWithholdsAVerdictWhenTheLedgerIsSilent() {
        let dispatched = task("ran, branch gone, no ledger")
        let offEpic = task("landed somewhere else")

        let branches = IntegrationPlan.classify(
            [dispatched, offEpic],
            facts: [
                dispatched.id: TaskBranchFacts(everDispatched: true),
                offEpic.id: TaskBranchFacts(
                    recordedBase: "aaaa", recordedTip: "cccc", tipOnEpicBranch: false, ownCommits: 2
                ),
            ]
        )

        XCTAssertEqual(branches.map(\.disposition), [.unknown, .unknown])
        XCTAssertNil(branches[0].commit)
        XCTAssertEqual(branches[1].commit, "cccc")
    }

    /// The branch's absence is not evidence either way, so a merged-then-deleted branch must never
    /// reach `nothingCommitted`, whatever else the ledger is missing.
    func testEvidenceNeverClaimsNothingWasCommittedWithoutSupport() {
        XCTAssertEqual(TaskBranchEvidence.read(TaskBranchFacts(everDispatched: true)), .unestablished)
        XCTAssertEqual(TaskBranchEvidence.read(TaskBranchFacts(everDispatched: false)), .nothingCommitted)
        XCTAssertEqual(
            TaskBranchEvidence.read(TaskBranchFacts(recordedTip: "bbbb", tipOnEpicBranch: true, everDispatched: false)),
            .unestablished,
            "a recorded tip with no recorded base cannot be called empty"
        )
    }

    // MARK: - compose

    func testPromptListsBranchesToMergeInOrderAndSkipsMergedOnes() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let schema = task("schema")
        let api = task("api")
        let ui = task("ui")
        let branches = [
            IntegrationBranch(taskId: schema.id, title: "schema", branch: "agentboard/\(schema.id)", disposition: .alreadyMerged),
            IntegrationBranch(taskId: api.id, title: "api", branch: "agentboard/\(api.id)", disposition: .merge),
            IntegrationBranch(taskId: ui.id, title: "ui", branch: "agentboard/\(ui.id)", disposition: .merge),
        ]

        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main", branches: branches, verification: swiftCommands
        )

        XCTAssertTrue(prompt.contains("1. `agentboard/\(api.id)` — api"), prompt)
        XCTAssertTrue(prompt.contains("2. `agentboard/\(ui.id)` — ui"), prompt)
        XCTAssertTrue(prompt.contains("Already merged into `\(epic.branch)` — skip these"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(schema.id)` — schema"), prompt)
        XCTAssertFalse(prompt.contains("1. `agentboard/\(schema.id)`"), "a merged branch is still in the merge list")
    }

    func testPromptDemandsGreenBuildCommitAndNoPush() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let only = task("api")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .merge)],
            verification: swiftCommands
        )

        XCTAssertTrue(prompt.contains("run `swift build` and then `swift test`"), prompt)
        XCTAssertTrue(prompt.contains("the final result of `swift build` and `swift test`"), prompt)
        XCTAssertTrue(prompt.contains("Do not push. Do not open a PR."), prompt)
        XCTAssertTrue(
            prompt.contains("The pull request from `\(epic.branch)` into `main` is opened outside this session"),
            prompt
        )
        XCTAssertTrue(prompt.contains("report_complete"), prompt)
        XCTAssertFalse(prompt.contains("git push"), prompt)
        XCTAssertFalse(prompt.contains("gh pr create"), prompt)
    }

    func testPromptSaysSoWhenEveryBranchIsAlreadyMerged() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let only = task("api")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .alreadyMerged)],
            verification: swiftCommands
        )

        XCTAssertTrue(prompt.contains("Nothing is left to merge."), prompt)
    }

    func testPromptTellsTheIntegratorALandedTaskNeedsNoAction() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let reaped = task("count the board")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(
                taskId: reaped.id, title: "count the board", branch: "agentboard/\(reaped.id)",
                disposition: .landed, commit: "2efcb12abcdef0123456"
            )],
            verification: swiftCommands
        )

        XCTAssertTrue(prompt.contains("their branches were deleted, nothing to do"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(reaped.id)` — count the board (landed as 2efcb12a)"), prompt)
        XCTAssertTrue(prompt.contains("do not report them as missing"), prompt)
        XCTAssertTrue(
            prompt.contains("Nothing listed in any other section is yours to merge."),
            "the merge instruction still points at everything listed above it:\n\(prompt)"
        )
        XCTAssertFalse(prompt.contains("Nothing was ever committed"), prompt)
        XCTAssertFalse(prompt.contains("No branch exists for these tasks"), prompt)
        XCTAssertFalse(prompt.contains("1. `agentboard/\(reaped.id)`"), "a landed task was handed over to be merged")
    }

    func testPromptSaysUnknownRatherThanAssertingEitherWay() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let unsure = task("no record")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(
                taskId: unsure.id, title: "no record", branch: "agentboard/\(unsure.id)",
                disposition: .unknown, commit: "cafebabe1234"
            )],
            verification: swiftCommands
        )

        XCTAssertTrue(prompt.contains("Branch gone, outcome unknown — check before you report on these"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(unsure.id)` — no record (last recorded tip cafebabe)"), prompt)
        XCTAssertTrue(prompt.contains("A missing branch is not evidence either way"), prompt)
        XCTAssertTrue(prompt.contains("git merge-base --is-ancestor <tip> \(epic.branch)"), prompt)
        XCTAssertFalse(prompt.contains("Nothing was ever committed"), prompt)
        XCTAssertFalse(prompt.contains("1. `agentboard/\(unsure.id)`"), "an unknown task was handed over to be merged")
    }

    func testPromptCallsOutTasksWithNoBranch() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let never = task("never started")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: never.id, title: "never started", branch: "agentboard/\(never.id)", disposition: .missing)],
            verification: swiftCommands
        )

        XCTAssertTrue(prompt.contains("No branch exists for these tasks"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(never.id)` — never started"), prompt)
    }

    func testPromptUsesTheProjectsOwnBuildAndTestCommands() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let only = task("api")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .merge)],
            verification: VerificationCommands(build: "pnpm build", test: "pnpm test")
        )

        XCTAssertTrue(prompt.contains("run `pnpm build` and then `pnpm test`"), prompt)
        XCTAssertTrue(prompt.contains("the final result of `pnpm build` and `pnpm test`"), prompt)
        XCTAssertFalse(prompt.contains("swift build"), prompt)
        XCTAssertFalse(prompt.contains("swift test"), prompt)
    }

    func testPromptTellsTheIntegratorToWorkOutVerificationWhenNoCommandsAreSet() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let only = task("api")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .merge)],
            verification: VerificationCommands()
        )

        XCTAssertTrue(prompt.contains("build and test this project"), prompt)
        XCTAssertTrue(prompt.contains("read its build files, scripts and CI config"), prompt)
        XCTAssertTrue(prompt.contains("Name in your report exactly what you ran."), prompt)
        XCTAssertTrue(prompt.contains("the build and test commands you ran, named exactly"), prompt)
        XCTAssertFalse(prompt.contains("swift build"), prompt)
        XCTAssertFalse(prompt.contains("swift test"), prompt)
    }

    func testPromptStillDemandsTheOtherHalfWhenOnlyOneCommandIsSet() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let only = task("api")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .merge)],
            verification: VerificationCommands(build: "cargo build")
        )

        XCTAssertTrue(prompt.contains("run `cargo build`, then run this project's tests"), prompt)
        XCTAssertTrue(prompt.contains("the build and test commands you ran, named exactly"), prompt)
    }

    func testBlankCommandsCountAsUnset() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let only = task("api")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .merge)],
            verification: VerificationCommands(build: "   ", test: "")
        )

        XCTAssertTrue(prompt.contains("build and test this project"), prompt)
    }

    // MARK: - epic state on completion

    /// Under `manual` the integration task lands in `review` for a human, as every worker report
    /// does. `afterEpicMerge` is the one policy that sends it straight to `done` — see
    /// `ArchiveSweepPolicyTests`.
    func testCompletingTheIntegrationTaskMovesTheEpicToDone() throws {
        let f = try Fixture.make()
        var settings = try XCTUnwrap(f.projects.get(f.project.id)?.settings)
        settings.archivePolicy = .manual
        try f.projects.updateSettings(f.project.id, settings)
        let epic = try epic(f)
        try f.epics.setState(epic.id, .integrating)
        let task = try f.board.createIntegrationTask(epicId: epic.id)
        let session = f.session(taskId: task.id)
        try f.sessions.insert(session)

        try f.board.complete(taskId: task.id, sessionId: session.sessionId, summary: "merged everything")

        XCTAssertEqual(try f.epics.get(epic.id)?.state, .done)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }

    func testCompletingAnOrdinaryEpicTaskLeavesTheEpicAlone() throws {
        let f = try Fixture.make()
        let (epic, created) = try tasks(f, [NewEpicTask(title: "api")])
        try f.epics.setState(epic.id, .active)
        let session = f.session(taskId: created[0].id)
        try f.sessions.insert(session)

        try f.board.complete(taskId: created[0].id, sessionId: session.sessionId, summary: "done")

        XCTAssertEqual(try f.epics.get(epic.id)?.state, .active)
    }

    func testIntegrationTaskIsTitledAfterItsEpicAndBelongsToIt() throws {
        let f = try Fixture.make()
        let epic = try epic(f, title: "Ship search")

        let task = try f.board.createIntegrationTask(epicId: epic.id)

        XCTAssertEqual(task.title, "Integrate epic Ship search")
        XCTAssertEqual(task.epicId, epic.id)
        XCTAssertEqual(task.origin, .integration)
        XCTAssertEqual(task.projectId, f.project.id)
    }

    // MARK: - a branch several tasks shared

    private var sharedEpic: Epic {
        Epic(
            id: "e1", projectId: "p", title: "Ship search", goal: nil, branch: "agentboard/epic-e1",
            state: .integrating, createdAt: .nowMillis
        )
    }

    func testTasksThatSharedABranchAreMergedAsOneBranchNamedOnce() throws {
        let shared = "agentboard/shared-epic-e1"
        let alpha = task("alpha")
        let beta = task("beta")

        let branches = IntegrationPlan.classify(
            [alpha, beta],
            facts: [
                alpha.id: TaskBranchFacts(branchExists: true, ownCommits: 2, sharedBranch: shared),
                beta.id: TaskBranchFacts(branchExists: true, ownCommits: 1, sharedBranch: shared),
            ]
        )
        let prompt = IntegrationPlan.compose(
            epic: sharedEpic,
            baseBranch: "main", branches: branches, verification: swiftCommands
        )

        XCTAssertEqual(branches.map(\.branch), [shared, shared])
        XCTAssertEqual(branches.map(\.disposition), [.merge, .merge])
        XCTAssertTrue(branches.allSatisfy(\.isShared))
        XCTAssertEqual(
            prompt.components(separatedBy: "1. `\(shared)`").count - 1, 1,
            "the shared branch is listed more than once in the merge list:\n\(prompt)"
        )
        XCTAssertFalse(prompt.contains("2. `\(shared)`"), prompt)
        XCTAssertTrue(prompt.contains("one branch shared by 2 tasks: alpha; beta"), prompt)
        XCTAssertTrue(prompt.contains("Agent-Board-Task:"), prompt)
    }

    /// A member that put no commit on the shared branch is not claimed as contributing to it, and
    /// the branch is still merged for whoever did.
    func testASharedMemberThatCommittedNothingIsReportedAsMissingNotAsABranchToMerge() throws {
        let shared = "agentboard/shared-epic-e1"
        let alpha = task("alpha")
        let idle = task("idle")

        let branches = IntegrationPlan.classify(
            [alpha, idle],
            facts: [
                alpha.id: TaskBranchFacts(branchExists: true, ownCommits: 2, sharedBranch: shared),
                idle.id: TaskBranchFacts(branchExists: true, ownCommits: 0, sharedBranch: shared),
            ]
        )

        XCTAssertEqual(branches.map(\.disposition), [.merge, .missing])
    }

    /// Once the shared branch is reaped, its members read from the ledger exactly as a worktree
    /// task does — what changes is that one branch answers for several of them.
    func testAReapedSharedBranchLandsRatherThanReadingAsUnknown() throws {
        let shared = "agentboard/shared-epic-e1"
        let alpha = task("alpha")

        let branches = IntegrationPlan.classify(
            [alpha],
            facts: [alpha.id: TaskBranchFacts(
                recordedBase: "base", recordedTip: "tip", tipOnEpicBranch: true, ownCommits: 2,
                sharedBranch: shared
            )]
        )
        let prompt = IntegrationPlan.compose(
            epic: sharedEpic,
            baseBranch: "main", branches: branches, verification: swiftCommands
        )

        XCTAssertEqual(branches.map(\.disposition), [.landed])
        XCTAssertTrue(prompt.contains("`\(shared)` (shared) — alpha"), prompt)
        XCTAssertFalse(prompt.contains("Branches to merge, in dependency order\n\n1."), prompt)
    }

    private func task(_ title: String) -> BoardTask {
        BoardTask(
            id: BoardId.new(), projectId: "p", epicId: nil, title: title, body: nil, acceptance: nil,
            priority: nil, column: .done, ordering: 1, origin: .orchestrator,
            createdAt: .nowMillis, updatedAt: .nowMillis
        )
    }
}
