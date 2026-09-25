import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5.2: an epic whose pull request is recorded is `pullRequestOpen` — it still takes work,
/// pushing its branch updates the same pull request, and the merge check settles it.
@MainActor
final class EpicPullRequestTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var remote: URL!
    private let url = "https://github.com/acme/widgets/pull/31"
    private let published = "clay/ship-search"

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        remote = fixture.supportDir.appendingPathComponent("remote.git")
        try SupervisorFixture.git(["init", "-q", "--bare", remote.path], cwd: fixture.supportDir)
        try fixture.git(["remote", "add", "origin", remote.path])
        var settings = fixture.project.settings
        settings.remoteBranchTemplate = "clay/{slug}"
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testAnEpicWithAnOpenPullRequestTakesWorkAndIsDoneWhenItMerges() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        let first = try await landTask("Index titles", in: epic, file: "index.txt")

        try await openPullRequest(for: epic)

        XCTAssertEqual(try reload(epic).state, .pullRequestOpen)
        let pr = try ApprovalStore(fixture.db).publishedEpicPullRequest(epicId: epic.id)
        XCTAssertEqual(EpicLane.stateLabel(state: .pullRequestOpen, pullRequest: pr), "PR #31 open")

        let second = try await landTask("Rank results", in: epic, file: "rank.txt")
        let accepted = try reload(second)
        XCTAssertEqual(accepted.landing, .landed, accepted.landingDetail ?? "")
        XCTAssertEqual(try reload(epic).state, .pullRequestOpen, "accepting a task moved the epic out of PR open")

        try await fixture.callOrchestratorTool("push_branch", arguments: .object(["branch": .string(epic.branch)]))
        let push = try XCTUnwrap(try pending(.push))
        XCTAssertEqual(try push.publishRequest().publishedBranch, published)
        try await fixture.supervisor.approve(approvalId: push.id)
        XCTAssertEqual(try remoteHeads(), [published: try head(epic.branch)], "the push did not update the PR's branch")

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "5eed1e55", head: try head(epic.branch))
        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        XCTAssertEqual(try reload(epic).state, .done)
        for task in [first, second] {
            let landed = try reload(task)
            XCTAssertEqual(landed.landing, .landed)
            XCTAssertTrue(try XCTUnwrap(landed.landingDetail).contains("5eed1e55"), landed.landingDetail ?? "")
        }
        XCTAssertTrue(try decisions().contains { $0.contains("pull request #31 merged") })
    }

    func testATaskAcceptedAfterTheLastPushIsNotLandedWhenThePullRequestMerges() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        let pushed = try await landTask("Index titles", in: epic, file: "index.txt")
        try await openPullRequest(for: epic)
        let pushedHead = try XCTUnwrap(try remoteHeads()[published])
        let late = try await landTask("Rank results", in: epic, file: "rank.txt")

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "5eed1e55", head: pushedHead)
        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        XCTAssertEqual(try reload(epic).state, .done)
        XCTAssertEqual(try reload(pushed).landing, .landed)
        XCTAssertEqual(try reload(late).landing, .unlanded, "a task the merged head lacks was marked landed")
        XCTAssertTrue(try decisions().contains {
            $0.contains(late.id) && $0.contains("accepted after the PR's last push; push the epic branch and open a follow-up PR")
        })
    }

    /// A suggestion applied on GitHub: the merged head is a commit only the remote has.
    func testAMergedHeadOnlyTheRemoteHasIsFetchedBeforeTasksAreJudged() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        let first = try await landTask("Index titles", in: epic, file: "index.txt")
        let second = try await landTask("Rank results", in: epic, file: "rank.txt")
        try await openPullRequest(for: epic)
        let clone = fixture.supportDir.appendingPathComponent("second-clone")
        try SupervisorFixture.git(["clone", "-q", "--branch", published, remote.path, clone.path], cwd: fixture.supportDir)
        try SupervisorFixture.git(["commit", "-q", "--allow-empty", "-m", "Apply suggestion"], cwd: clone)
        try SupervisorFixture.git(["push", "-q", "origin", published], cwd: clone)
        let remoteOnly = try XCTUnwrap(try remoteHeads()[published])
        XCTAssertThrowsError(try fixture.git(["cat-file", "-e", remoteOnly]), "the local repository already had the head")

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "5eed1e55", head: remoteOnly)
        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        XCTAssertEqual(try reload(epic).state, .done)
        for task in [first, second] {
            let landed = try reload(task)
            XCTAssertEqual(landed.landing, .landed, landed.landingDetail ?? "")
            XCTAssertTrue(try XCTUnwrap(landed.landingDetail).contains("5eed1e55"), landed.landingDetail ?? "")
        }
    }

    func testAHeadThatCannotBeReadChangesNoLandingAndSaysSo() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        let task = try await landTask("Index titles", in: epic, file: "index.txt")
        try await openPullRequest(for: epic)
        let before = try reload(task)

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "5eed1e55", head: String(repeating: "0", count: 40))
        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        XCTAssertEqual(try reload(epic).state, .done)
        let after = try reload(task)
        XCTAssertEqual(after.landing, .landed, after.landingDetail ?? "")
        XCTAssertEqual(after.landingDetail, before.landingDetail)
        XCTAssertTrue(try decisions().contains { $0.contains("could not be verified") })
    }

    func testALandedTaskWithNoTipLeftIsReportedUnverifiable() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        let task = try await landTask("Index titles", in: epic, file: "index.txt")
        try await openPullRequest(for: epic)
        for ref in ["refs/heads/agentboard/\(task.id)", TaskBranchLedger.tipRef(taskId: task.id)] {
            _ = try? fixture.git(["update-ref", "-d", ref])
        }
        XCTAssertEqual(try reload(task).landing, .landed)

        fixture.gh.answer(url, state: "MERGED", mergeCommit: "5eed1e55", head: try XCTUnwrap(try remoteHeads()[published]))
        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        XCTAssertEqual(try reload(task).landing, .pending, "a task nothing can verify kept its landed")
        XCTAssertTrue(try decisions().contains { $0.contains("Could not verify whether it carried \(task.id)") })
    }

    func testAPullRequestClosedUnmergedReturnsTheEpicToActive() async throws {
        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Ship search", goal: nil)
        _ = try await landTask("Index titles", in: epic, file: "index.txt")
        try await openPullRequest(for: epic)
        fixture.gh.answer(url, state: "CLOSED")

        await fixture.supervisor.refreshPullRequestLandings(projectId: fixture.project.id)

        XCTAssertEqual(try reload(epic).state, .active)
        XCTAssertTrue(try decisions().contains { $0.contains("closed without merging") && $0.contains(url) })
    }

    /// `create_task` into the epic, then the real spawn, a commit in its worktree, and the accept.
    private func landTask(_ title: String, in epic: Epic, file: String) async throws -> BoardTask {
        let created = try await fixture.callOrchestratorTool(
            "create_task",
            arguments: .object(["title": .string(title), "epic_id": .string(epic.id), "column": .string("ready")])
        )
        XCTAssertFalse(created.isError, created.text)
        let task = try XCTUnwrap(try fixture.tasks.list(projectId: fixture.project.id, epicId: epic.id).first { $0.title == title })
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let branch = "agentboard/\(task.id)"
        XCTAssertEqual(try head(branch), try head(epic.branch), "the task was not cut from the epic branch")
        let session = try XCTUnwrap(try fixture.sessions.forTask(task.id).first)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath), file: file)
        let tip = try head(branch)

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertNoThrow(try fixture.git(["merge-base", "--is-ancestor", tip, epic.branch]), "the accept did not merge into the epic branch")
        return task
    }

    /// `open_pull_request(epic_id:)`, then what an approved publish does: push under the published
    /// name and record the URL `gh pr create` printed. `gh pr create` itself has no seam to fake.
    private func openPullRequest(for epic: Epic) async throws {
        try await fixture.callOrchestratorTool(
            "open_pull_request", arguments: .object(["epic_id": .string(epic.id), "title": .string(epic.title)])
        )
        let approval = try XCTUnwrap(try pending(.pullRequest))
        let request = try approval.publishRequest()
        XCTAssertEqual(request.publishedBranch, published)
        let resolved = try fixture.board.resolveApproval(approval.id, approved: true, by: "human")
        _ = try BranchPublisher(repoPath: fixture.repo).push(branch: request.branch, publishedAs: request.publishedBranch)
        try fixture.board.recordPublished(
            approval: resolved, summary: "Pull request opened from \(published) (local \(epic.branch)) into main.", url: url
        )
    }

    private func pending(_ kind: ApprovalKind) throws -> Approval? {
        try ApprovalStore(fixture.db).pending(projectId: fixture.project.id).first { $0.kind == kind }
    }

    private func reload(_ epic: Epic) throws -> Epic {
        try XCTUnwrap(try fixture.epics.get(epic.id))
    }

    private func reload(_ task: BoardTask) throws -> BoardTask {
        try XCTUnwrap(try fixture.tasks.get(task.id, includeArchived: true))
    }

    private func head(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", "--verify", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remoteHeads() throws -> [String: String] {
        let listed = try SupervisorFixture.git(
            ["--git-dir", remote.path, "for-each-ref", "--format=%(refname:strip=2) %(objectname)", "refs/heads"],
            cwd: fixture.supportDir
        )
        return Dictionary(uniqueKeysWithValues: listed.split(separator: "\n").map {
            let parts = $0.split(separator: " ")
            return (String(parts[0]), String(parts[1]))
        })
    }

    private func decisions() throws -> [String] {
        try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).filter { $0.kind == .decision }.map(\.body)
    }
}
