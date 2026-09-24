import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5: in a project that integrates standalone tasks by pull request — the default once the
/// repository has an `origin` — accepting one merges nothing, and the task is marked landed when
/// GitHub reports its recorded pull request merged. A squash merge puts a new commit on the base
/// branch, so git ancestry can never settle this.
@MainActor
final class PullRequestLandingTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private let url = "https://github.com/acme/widgets/pull/16"

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        try fixture.git(["remote", "add", "origin", "https://github.com/acme/widgets.git"])
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testAcceptWaitsForAPullRequestAndItsMergeLandsTheTask() async throws {
        XCTAssertNil(fixture.project.settings.standaloneIntegration, "a new project must leave the choice to the origin check")
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
    /// the old false message, and its pull request was opened before the accept.
    func testAnUnlandedTaskWithARecordedPullRequestIsSettledOnce() async throws {
        let task = try acceptableTask()
        try recordPullRequest(for: task)
        try fixture.tasks.move(task.id, to: .done)
        try fixture.tasks.setLanding(
            task.id, .unlanded,
            detail: "`agentboard/\(task.id)` was not merged into `main`: that branch is checked out at \(fixture.repo.path)."
        )
        fixture.gh.answer(url, state: "MERGED", mergeCommit: "1389758c")

        await fixture.supervisor.refreshPullRequestLandings()

        XCTAssertEqual(try reload(task).landing, .landed)
        await fixture.supervisor.refreshPullRequestLandings()
        XCTAssertEqual(fixture.gh.calls.count, 1)
    }

    /// A worker's `update_status` detail is a `status` row too, and a grant not yet bound to its
    /// session writes it with no session id, so neither the kind nor a NULL session marks a publish.
    func testAPullRequestLinkAWorkerReportsIsNotTheTasksPullRequest() async throws {
        let (task, session) = try acceptableTaskAndSession()
        let upstream = "https://github.com/upstream/lib/pull/9"
        for bound in [true, false] {
            let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: task.id)
            if bound { try fixture.grants.bind(token: grant.token, sessionId: session.sessionId) }
            try await fixture.callWorkerTool(
                "update_status",
                arguments: .object(["state": .string("working"), "detail": .string("Following \(upstream) for the fix")]),
                token: grant.token
            )
        }
        let linked = try ProgressStore(fixture.db).list(taskId: task.id).filter { $0.text.contains(upstream) }
        XCTAssertEqual(Set(linked.map(\.sessionId)), [session.sessionId, nil])
        XCTAssertTrue(linked.allSatisfy { $0.kind == .status })
        fixture.gh.answer(upstream, state: "MERGED", mergeCommit: "0badc0de")

        try await fixture.supervisor.accept(taskId: task.id)
        XCTAssertEqual(try reload(task).landing, .awaitingPullRequest, "the accept bound a worker's link as the task's PR")
        await fixture.supervisor.refreshPullRequestLandings()

        XCTAssertEqual(try reload(task).landing, .awaitingPullRequest)
        XCTAssertEqual(fixture.gh.calls, [], "the merge check read a worker's link")
    }

    /// An epic's pull request writes its progress row onto a task in the epic. A task whose merge
    /// into the epic branch conflicted is `done` and `unlanded`, and the epic PR merging says
    /// nothing about where its commits are.
    func testAnEpicTaskIsNeverAdoptedOrBoundToAPullRequest() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Widgets", goal: nil)
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Part of the epic", body: nil, acceptance: nil,
            priority: nil, column: .review, origin: .human, epicId: epic.id
        )
        try fixture.tasks.move(task.id, to: .done)
        let conflicted = "`agentboard/\(task.id)` could not be merged into `\(epic.branch)`: work.txt conflicted."
        try fixture.tasks.setLanding(task.id, .unlanded, detail: conflicted)
        let epicURL = "https://github.com/acme/widgets/pull/21"
        let epicApproval = try fixture.board.requestPublish(
            projectId: fixture.project.id, kind: .pullRequest,
            request: PublishRequest(branch: epic.branch, base: "main", title: epic.title, body: ""),
            epicId: epic.id, requestedBy: "orchestrator"
        )
        try fixture.board.recordPublished(
            approval: epicApproval, summary: "Pull request opened from \(epic.branch) into main.", url: epicURL
        )
        XCTAssertTrue(
            try ProgressStore(fixture.db).list(taskId: task.id).contains { $0.text.contains(epicURL) },
            "the epic's publish row must be on this task for the test to mean anything"
        )
        let branchURL = "https://github.com/acme/widgets/pull/22"
        let branchApproval = try fixture.board.requestPublish(
            projectId: fixture.project.id, kind: .pullRequest,
            request: PublishRequest(branch: "agentboard/\(task.id)", base: "main", title: task.title, body: ""),
            taskId: task.id, epicId: epic.id, requestedBy: "orchestrator"
        )
        try fixture.board.recordPublished(
            approval: branchApproval, summary: "Pull request opened from agentboard/\(task.id) into main.", url: branchURL
        )
        fixture.gh.answer(epicURL, state: "MERGED", mergeCommit: "e91c")
        fixture.gh.answer(branchURL, state: "MERGED", mergeCommit: "b7a2")

        await fixture.supervisor.refreshPullRequestLandings()

        let settled = try reload(task)
        XCTAssertEqual(settled.landing, .unlanded)
        XCTAssertEqual(settled.landingDetail, conflicted)
        XCTAssertNil(try fixture.tasks.recordedPullRequest(taskId: task.id))
        XCTAssertEqual(fixture.gh.calls, [PullRequestStateReader.arguments(url: epicURL)], "only the epic's PR was checked, never the task-branch PR inside it")
    }

    /// With no stored choice, `origin` decides: none means the accept merges into the base branch as
    /// it did before pull requests existed, and one means the task waits for its pull request.
    func testWithNoStoredChoiceTheOriginRemoteDecidesHowAStandaloneTaskIntegrates() async throws {
        XCTAssertNil(try XCTUnwrap(try ProjectStore(fixture.db).get(fixture.project.id)).settings.standaloneIntegration)
        try fixture.git(["remote", "remove", "origin"])
        try fixture.git(["checkout", "-q", "--detach"], cwd: fixture.repo)
        let local = try acceptableTask()
        let localHead = try headOf("agentboard/\(local.id)")

        try await fixture.supervisor.accept(taskId: local.id)

        let merged = try reload(local)
        XCTAssertEqual(merged.landing, .landed, merged.landingDetail ?? "")
        XCTAssertEqual(try headOf("main"), localHead, "with no origin the accept must merge locally")

        try fixture.git(["remote", "add", "origin", "https://github.com/acme/widgets.git"])
        let byPR = try acceptableTaskAndSession(file: "second.txt").task
        let mainBefore = try headOf("main")

        try await fixture.supervisor.accept(taskId: byPR.id)

        XCTAssertEqual(try reload(byPR).landing, .awaitingPullRequest)
        XCTAssertEqual(try headOf("main"), mainBefore, "with an origin the accept must merge nothing")
    }

    private func acceptableTask() throws -> BoardTask {
        try acceptableTaskAndSession().task
    }

    private func acceptableTaskAndSession(file: String = "work.txt") throws -> (task: BoardTask, session: AgentSession) {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .review, origin: .human, epicId: nil
        )
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath), file: file)
        return (task, session)
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
