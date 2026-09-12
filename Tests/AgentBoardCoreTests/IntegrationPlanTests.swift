import Foundation
import XCTest
@testable import AgentBoardCore

final class IntegrationPlanTests: XCTestCase {
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
            merged: [IntegrationPlan.branchName(taskId: done.id): true],
            exists: [
                IntegrationPlan.branchName(taskId: done.id),
                IntegrationPlan.branchName(taskId: pending.id),
            ]
        )

        XCTAssertEqual(branches.map(\.disposition), [.alreadyMerged, .merge, .missing])
        XCTAssertEqual(branches.map(\.branch), [done, pending, never].map { IntegrationPlan.branchName(taskId: $0.id) })
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

        let prompt = IntegrationPlan.compose(epic: epic, baseBranch: "main", branches: branches)

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
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .merge)]
        )

        XCTAssertTrue(prompt.contains("swift build"), prompt)
        XCTAssertTrue(prompt.contains("swift test"), prompt)
        XCTAssertTrue(prompt.contains("Do not push. Do not open a PR."), prompt)
        XCTAssertTrue(prompt.contains("A human opens the pull request from `\(epic.branch)` into `main`."), prompt)
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
            branches: [IntegrationBranch(taskId: only.id, title: "api", branch: "agentboard/\(only.id)", disposition: .alreadyMerged)]
        )

        XCTAssertTrue(prompt.contains("Nothing is left to merge."), prompt)
    }

    func testPromptCallsOutTasksWithNoBranch() throws {
        let f = try Fixture.make()
        let epic = try epic(f)
        let never = task("never started")
        let prompt = IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: [IntegrationBranch(taskId: never.id, title: "never started", branch: "agentboard/\(never.id)", disposition: .missing)]
        )

        XCTAssertTrue(prompt.contains("No branch exists for these tasks"), prompt)
        XCTAssertTrue(prompt.contains("- `agentboard/\(never.id)` — never started"), prompt)
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

    private func task(_ title: String) -> BoardTask {
        BoardTask(
            id: BoardId.new(), projectId: "p", epicId: nil, title: title, body: nil, acceptance: nil,
            priority: nil, column: .done, ordering: 1, origin: .orchestrator,
            createdAt: .nowMillis, updatedAt: .nowMillis
        )
    }
}
