import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5: in a project that integrates standalone tasks by pull request, accepting one merges
/// nothing, and the task is marked landed when GitHub reports its recorded pull request merged.
/// A squash merge puts a new commit on the base branch, so git ancestry can never settle this.
@MainActor
final class PullRequestLandingTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private let url = "https://github.com/acme/widgets/pull/16"

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testAcceptWaitsForAPullRequestAndItsMergeLandsTheTask() async throws {
        XCTAssertEqual(fixture.project.settings.standaloneIntegration, .pullRequest, "a new project must default to pull request")
        XCTAssertEqual(try fixture.manager.currentBranch(at: fixture.repo), "main")
        let task = try acceptableTask()
        let mainBefore = try headOf("main")
        let taskHead = try headOf("agentboard/\(task.id)")

        try await fixture.supervisor.accept(taskId: task.id)

        let accepted = try reload(task)
        XCTAssertEqual(accepted.column, .done)
        XCTAssertEqual(accepted.landing, .awaitingPullRequest)
        XCTAssertEqual(accepted.landingLabel, "PR pending")
        XCTAssertTrue(accepted.needsLanding, "the card must show the pill")
        XCTAssertEqual(try headOf("main"), mainBefore, "the accept merged into the base branch")
        XCTAssertEqual(try headOf("agentboard/\(task.id)"), taskHead, "the task branch was not kept")
        XCTAssertEqual(try fixture.git(["status", "--porcelain"], cwd: fixture.repo), "")
        let report = try XCTUnwrap(try landingReports().first)
        XCTAssertTrue(report.contains("open_pull_request"), report)
        XCTAssertFalse(report.contains("checked out"), report)

        try recordPullRequest(for: task)
        let opened = try reload(task)
        XCTAssertEqual(opened.landing, .pullRequestOpen)
        XCTAssertEqual(opened.landingLabel, "PR #16 open")
        XCTAssertEqual(try landingReports().count, 1, "an open pull request queued a second decision report")

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "c0b0bdeb6b63")
        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        let landed = try reload(task)
        XCTAssertEqual(landed.landing, .landed)
        XCTAssertFalse(landed.needsLanding)
        XCTAssertTrue(try XCTUnwrap(landed.landingDetail).contains("c0b0bdeb6b63"), landed.landingDetail ?? "")
        XCTAssertEqual(fixture.gh.calls, [PullRequestStateReader.arguments(url: url)])
        XCTAssertEqual(try headOf("main"), mainBefore, "landing by pull request moved the local base branch")
    }

    func testAPullRequestClosedWithoutMergingGoesBackToUnlanded() async throws {
        let task = try acceptableTask()
        try await fixture.supervisor.accept(taskId: task.id)
        try recordPullRequest(for: task)
        fixture.gh.answer(url, state: "CLOSED")

        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        let closed = try reload(task)
        XCTAssertEqual(closed.landing, .unlanded)
        let detail = try XCTUnwrap(closed.landingDetail)
        XCTAssertTrue(detail.contains("closed without merging"), detail)
        XCTAssertTrue(detail.contains(url), detail)
        XCTAssertTrue(try landingReports().contains { $0.contains("closed without merging") })

        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)
        XCTAssertEqual(fixture.gh.calls.count, 1, "a closed pull request was checked again")
        XCTAssertEqual(try reload(task).landing, .unlanded)
    }

    func testAGhFailureLeavesTheLandingAndSaysWhyOnTheCard() async throws {
        let task = try acceptableTask()
        try await fixture.supervisor.accept(taskId: task.id)
        try recordPullRequest(for: task)
        fixture.gh.fail(url, stderr: "To get started with GitHub CLI, please run:  gh auth login")

        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        let unchecked = try reload(task)
        XCTAssertEqual(unchecked.landing, .pullRequestOpen)
        XCTAssertEqual(unchecked.landingLabel, "PR #16 open")
        XCTAssertTrue(try XCTUnwrap(unchecked.landingDetail).contains("gh auth login"), unchecked.landingDetail ?? "")

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "abc123")
        await fixture.supervisor.refreshPullRequestLandings(taskId: task.id)
        XCTAssertEqual(try reload(task).landing, .landed, "a failed check stuck")
    }

    /// The one-time cleanup: a task accepted before this existed sits in `done` as `unlanded` with
    /// the old false message, and its pull request is recorded only as a progress row.
    func testAnUnlandedTaskWithARecordedPullRequestIsSettledOnce() async throws {
        let task = try acceptableTask()
        try fixture.tasks.move(task.id, to: .done)
        try fixture.tasks.setLanding(
            task.id, .unlanded,
            detail: "`agentboard/\(task.id)` was not merged into `main`: that branch is checked out at \(fixture.repo.path)."
        )
        _ = try ProgressStore(fixture.db).append(
            taskId: task.id, sessionId: nil, kind: .status,
            text: "Pull request opened from agentboard/\(task.id) into main.\n\(url)"
        )
        fixture.gh.answer(url, state: "MERGED", mergeCommit: "1389758c")

        await fixture.supervisor.refreshPullRequestLandings()

        XCTAssertEqual(try reload(task).landing, .landed)
        await fixture.supervisor.refreshPullRequestLandings()
        XCTAssertEqual(fixture.gh.calls.count, 1)
    }

    private func acceptableTask() throws -> BoardTask {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .review, origin: .human, epicId: nil
        )
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        return task
    }

    /// What `WorkerSupervisor.publish` writes once an approved `open_pull_request` has run `gh`.
    private func recordPullRequest(for task: BoardTask) throws {
        let branch = "agentboard/\(task.id)"
        let approval = try fixture.board.requestPublish(
            projectId: fixture.project.id, kind: .pullRequest,
            request: PublishRequest(branch: branch, base: "main", title: task.title, body: ""),
            taskId: task.id, requestedBy: "orchestrator"
        )
        try fixture.board.recordPublished(
            approval: approval, summary: "Pull request opened from \(branch) into main.", url: url
        )
    }

    private func reload(_ task: BoardTask) throws -> BoardTask {
        try XCTUnwrap(try fixture.tasks.get(task.id))
    }

    private func headOf(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", "--verify", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func landingReports() throws -> [String] {
        try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id)
            .map(\.body)
            .filter { $0.contains("but its branch") }
    }
}
