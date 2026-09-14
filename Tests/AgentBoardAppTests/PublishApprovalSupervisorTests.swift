import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// The human's grant is what reaches the remote. The remote here is a bare repository the test
/// creates in its own scratch directory; nothing touches GitHub and no pull request is created.
@MainActor
final class PublishApprovalSupervisorTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private var remote: URL { fixture.supportDir.appendingPathComponent("remote.git") }

    private func addRemote() throws {
        try SupervisorFixture.git(["init", "--bare", "-q", remote.path], cwd: fixture.supportDir)
        try SupervisorFixture.git(["remote", "add", "origin", remote.path], cwd: fixture.repo)
    }

    private func remoteBranches() throws -> [String] {
        try SupervisorFixture.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: remote)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    @discardableResult
    private func pushApproval(branch: String, taskId: String? = nil) throws -> Approval {
        try fixture.board.requestPublish(
            projectId: fixture.project.id, kind: .push, request: PublishRequest(branch: branch),
            taskId: taskId, requestedBy: "orch-session", reason: "Push \(branch)."
        )
    }

    func testAPendingPushDoesNotReachTheRemoteUntilItIsApproved() async throws {
        try addRemote()
        try SupervisorFixture.git(["branch", "agentboard/epic-1"], cwd: fixture.repo)
        let approval = try pushApproval(branch: "agentboard/epic-1")

        XCTAssertTrue(try remoteBranches().isEmpty, "the request alone must push nothing")
        XCTAssertTrue(try fixture.approvals.get(approval.id)?.isPending == true)

        try await fixture.supervisor.approve(approvalId: approval.id)
        XCTAssertEqual(try remoteBranches(), ["agentboard/epic-1"])
        XCTAssertEqual(try fixture.approvals.get(approval.id)?.resolution, .approved)
    }

    func testAutonomyBeingOnDoesNotSkipTheApproval() async throws {
        try addRemote()
        try SupervisorFixture.git(["branch", "agentboard/epic-2"], cwd: fixture.repo)
        var settings = fixture.project.settings
        settings.autonomyEnabled = true
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        let approval = try pushApproval(branch: "agentboard/epic-2")
        XCTAssertTrue(try XCTUnwrap(fixture.approvals.get(approval.id)).isPending)
        XCTAssertTrue(try remoteBranches().isEmpty)
    }

    func testTheOutcomeIsWrittenToTheBoardAsProgressAndAReport() async throws {
        try addRemote()
        let task = try TaskStore(fixture.db).create(
            projectId: fixture.project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        try SupervisorFixture.git(["branch", "agentboard/\(task.id)"], cwd: fixture.repo)
        let approval = try pushApproval(branch: "agentboard/\(task.id)", taskId: task.id)

        try await fixture.supervisor.approve(approvalId: approval.id)

        let entry = try XCTUnwrap(ProgressStore(fixture.db).latest(taskId: task.id))
        XCTAssertEqual(entry.kind, .status)
        XCTAssertTrue(entry.text.contains("agentboard/\(task.id)"), entry.text)

        let bodies = try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id).map(\.body)
        XCTAssertTrue(bodies.contains { $0.contains("Push approved") }, "\(bodies)")
    }

    func testAProjectWithNoRemoteFailsNamingThatCauseAndRecordsIt() async throws {
        let task = try TaskStore(fixture.db).create(
            projectId: fixture.project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        try SupervisorFixture.git(["branch", "agentboard/\(task.id)"], cwd: fixture.repo)
        let approval = try pushApproval(branch: "agentboard/\(task.id)", taskId: task.id)

        do {
            try await fixture.supervisor.approve(approvalId: approval.id)
            XCTFail("expected the push to fail with no remote configured")
        } catch {
            XCTAssertEqual(error as? PublishFailure, .noRemote(name: "origin", repoPath: fixture.repo.path))
        }

        let entry = try XCTUnwrap(ProgressStore(fixture.db).latest(taskId: task.id))
        XCTAssertEqual(entry.kind, .error)
        XCTAssertTrue(entry.text.contains("no git remote"), entry.text)
    }

    func testABranchThatWasNeverCreatedFailsWithItsOwnCause() async throws {
        try addRemote()
        let approval = try pushApproval(branch: "agentboard/never-created")
        do {
            try await fixture.supervisor.approve(approvalId: approval.id)
            XCTFail("expected the push to fail on a branch that does not exist")
        } catch {
            XCTAssertEqual(error as? PublishFailure, .noSuchBranch("agentboard/never-created"))
        }
        XCTAssertTrue(try remoteBranches().isEmpty)
    }
}
