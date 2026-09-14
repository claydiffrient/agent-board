import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// §3.1 steps 1-2: a task in an epic is cut from the epic branch, never from the project base.
@MainActor
final class EpicSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!

    private var epics: EpicStore { EpicStore(fixture.db) }

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func makeEpic(goal: String? = "Ship the epic.") throws -> Epic {
        try epics.create(projectId: fixture.project.id, title: "Epic", goal: goal)
    }

    private func makeTask(_ title: String, epicId: String?) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: "Do the thing.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: epicId
        )
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        try SupervisorFixture.git(args, cwd: URL(fileURLWithPath: fixture.project.repoPath))
    }

    private func head(_ ref: String) throws -> String {
        try git(["rev-parse", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Advances `branch` by one empty commit without checking it out, so the other branches stay put.
    private func advance(_ branch: String, message: String) throws {
        let tree = try git(["rev-parse", "\(branch)^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = try head(branch)
        let commit = try git([
            "-c", "user.email=test@example.com", "-c", "user.name=Test",
            "commit-tree", tree, "-p", parent, "-m", message,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["branch", "-f", branch, commit])
    }

    /// Where the task branch actually points, as a merge-base question: it is descended from the
    /// epic branch only if the epic branch is an ancestor.
    private func isAncestor(_ ancestor: String, of branch: String) throws -> Bool {
        (try? git(["merge-base", "--is-ancestor", ancestor, branch])) != nil
    }

    func testTaskInAnEpicBranchesFromTheEpicBranch() async throws {
        let epic = try makeEpic()
        let task = try makeTask("Epic work", epicId: epic.id)
        try git(["branch", epic.branch, "main"])
        try advance(epic.branch, message: "Epic groundwork")

        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()

        let taskBranch = "agentboard/\(task.id)"
        XCTAssertTrue(
            try isAncestor(epic.branch, of: taskBranch),
            "the task branch is not descended from \(epic.branch); spawn cut it from the project base"
        )
        XCTAssertEqual(try head(taskBranch), try head(epic.branch))
        XCTAssertNotEqual(try head(taskBranch), try head("main"))
    }

    func testTheEpicBranchIsCutFromTheProjectBaseWhenAbsent() async throws {
        let epic = try makeEpic()
        let task = try makeTask("First in epic", epicId: epic.id)
        XCTAssertThrowsError(try git(["rev-parse", "--verify", epic.branch]))

        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(try head(epic.branch), try head("main"))
    }

    /// The second task must land on whatever the first one left on the epic branch, not on a re-cut from main.
    func testAnExistingEpicBranchIsReusedNotRecut() async throws {
        let epic = try makeEpic()
        try git(["branch", epic.branch, "main"])
        try advance(epic.branch, message: "Epic groundwork")
        let epicHead = try head(epic.branch)
        XCTAssertNotEqual(epicHead, try head("main"), "the fixture failed to move the epic branch ahead of main")

        let task = try makeTask("Second in epic", epicId: epic.id)
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(try head(epic.branch), epicHead, "an existing epic branch was moved")
        XCTAssertEqual(
            try head("agentboard/\(task.id)"), epicHead,
            "the task branch did not start at the epic branch's tip"
        )
    }

    func testStandaloneTaskStillBranchesFromTheProjectBase() async throws {
        let task = try makeTask("No epic here", epicId: nil)

        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(try head("agentboard/\(task.id)"), try head("main"))
        XCTAssertTrue(
            try git(["branch", "--list", "agentboard/epic-*"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "a standalone task created an epic branch"
        )
    }

    func testFirstSpawnMovesTheEpicFromPlanningToActive() async throws {
        let epic = try makeEpic()
        XCTAssertEqual(epic.state, .planning)

        try await fixture.supervisor.assign(taskId: try makeTask("First", epicId: epic.id).id)
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(try epics.get(epic.id)?.state, .active)
    }

    func testLaterSpawnsLeaveANonPlanningEpicAlone() async throws {
        let epic = try makeEpic()
        try await fixture.supervisor.assign(taskId: try makeTask("First", epicId: epic.id).id)
        await fixture.supervisor.waitForSetup()
        try epics.setState(epic.id, .integrating)

        try await fixture.supervisor.assign(taskId: try makeTask("Second", epicId: epic.id).id)
        await fixture.supervisor.waitForSetup()

        XCTAssertEqual(try epics.get(epic.id)?.state, .integrating, "spawn dragged the epic back to active")
    }

    func testOpeningPromptCarriesTheEpicGoal() async throws {
        let epic = try makeEpic(goal: "Make the integrator merge epic branches unattended.")
        let task = try makeTask("Epic work", epicId: epic.id)

        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()

        let spawns = await fixture.runtime.spawns
        let prompt = try XCTUnwrap(spawns.last?.prompt)
        XCTAssertTrue(prompt.contains("## Epic goal"), prompt)
        XCTAssertTrue(prompt.contains("Make the integrator merge epic branches unattended."), prompt)
    }

    func testStandaloneTaskPromptHasNoEpicGoalSection() async throws {
        try await fixture.supervisor.assign(taskId: try makeTask("No epic here", epicId: nil).id)
        await fixture.supervisor.waitForSetup()

        let spawns = await fixture.runtime.spawns
        let prompt = try XCTUnwrap(spawns.last?.prompt)
        XCTAssertFalse(prompt.contains("## Epic goal"), prompt)
    }
}
