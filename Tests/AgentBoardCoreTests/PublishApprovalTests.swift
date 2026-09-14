import AgentBoardCore
import Foundation
import XCTest

final class PublishPolicyTests: XCTestCase {
    private func validate(_ branch: String, base: String = "main") throws -> String {
        try PublishPolicy.validate(branch: branch, baseBranch: base)
    }

    func testTheProjectsOwnBranchesAndItsBaseBranchAreAccepted() throws {
        XCTAssertEqual(try validate("agentboard/epic-7"), "agentboard/epic-7")
        XCTAssertEqual(try validate("agentboard/38fd0a98"), "agentboard/38fd0a98")
        XCTAssertEqual(try validate("main"), "main")
        XCTAssertEqual(try validate("trunk", base: "trunk"), "trunk")
        XCTAssertEqual(try validate("  agentboard/epic-7  "), "agentboard/epic-7")
    }

    func testAnyOtherBranchIsRefusedWithBothNamesInTheMessage() {
        for branch in ["develop", "release/2.0", "main2", "origin/main", "refs/heads/agentboard/x", "agentboard"] {
            XCTAssertThrowsError(try validate(branch), branch) { error in
                XCTAssertEqual(error as? PublishPolicyError, .outsideProject(branch: branch, baseBranch: "main"))
                XCTAssertTrue("\(error)".contains("main"), "\(error)")
            }
        }
    }

    func testTheBareOwnedPrefixIsNotABranch() {
        XCTAssertFalse(PublishPolicy.isOwned("agentboard/"))
        XCTAssertTrue(PublishPolicy.isOwned("agentboard/a"))
    }

    func testRefspecsOptionsAndMalformedRefsAreRefusedBeforeOwnership() {
        let malformed = [
            "agentboard/a:refs/heads/main", "-agentboard/a", "--delete", "agentboard/a b",
            "agentboard/a..b", "agentboard//a", "agentboard/a.lock", "agentboard/a.", "agentboard/a~1",
            "agentboard/a^", "agentboard/a?", "agentboard/a*", "agentboard/a[0]", "agentboard/a\\b",
            "agentboard/a@{0}", "agentboard/a/", "/agentboard/a", "agentboard/a\nmain",
        ]
        for branch in malformed {
            XCTAssertThrowsError(try validate(branch), branch) { error in
                XCTAssertEqual(error as? PublishPolicyError, .malformed(branch.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    func testAnEmptyBranchIsItsOwnRefusal() {
        XCTAssertThrowsError(try validate("   ")) { XCTAssertEqual($0 as? PublishPolicyError, .empty) }
    }

    func testThePayloadSurvivesARoundTrip() throws {
        let request = PublishRequest(branch: "agentboard/epic-7", base: "main", title: "Ship it", body: "Why")
        XCTAssertEqual(try PublishRequest.decode(try request.encoded()), request)
        XCTAssertEqual(try PublishRequest.decode(try PublishRequest(branch: "main").encoded()).remote, "origin")
        XCTAssertThrowsError(try PublishRequest.decode(nil)) {
            XCTAssertEqual($0 as? PublishPolicyError, .missingPayload)
        }
    }
}

final class PublishApprovalTests: XCTestCase {
    private var db: AppDatabase!
    private var board: Board!
    private var project: Project!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
        board = Board(db)
        project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/wt", memoryDir: nil
        )
    }

    private func request(_ kind: ApprovalKind, branch: String, epicId: String? = nil, taskId: String? = nil) throws -> Approval {
        try board.requestPublish(
            projectId: project.id, kind: kind, request: PublishRequest(branch: branch, base: "main", title: "T", body: "B"),
            taskId: taskId, epicId: epicId, requestedBy: "orch-session", reason: "because"
        )
    }

    func testAPublishApprovalIsPendingAndCarriesItsBranch() throws {
        let approval = try request(.pullRequest, branch: "agentboard/epic-1", epicId: nil)
        XCTAssertTrue(approval.isPending)
        XCTAssertEqual(approval.kind, .pullRequest)
        XCTAssertEqual(try approval.publishRequest().branch, "agentboard/epic-1")
        XCTAssertEqual(try approval.publishRequest().title, "T")
        XCTAssertEqual(try ApprovalStore(db).pending(projectId: project.id).count, 1)
    }

    func testThePayloadSurvivesTheDatabase() throws {
        let created = try request(.push, branch: "agentboard/a")
        let loaded = try XCTUnwrap(try ApprovalStore(db).get(created.id))
        XCTAssertEqual(try loaded.publishRequest(), try created.publishRequest())
    }

    func testTheSameBranchAndKindIsNotDuplicated() throws {
        let first = try request(.push, branch: "agentboard/a")
        let second = try request(.push, branch: "agentboard/a")
        XCTAssertEqual(first.id, second.id)

        let otherBranch = try request(.push, branch: "agentboard/b")
        let otherKind = try request(.pullRequest, branch: "agentboard/a")
        XCTAssertNotEqual(first.id, otherBranch.id)
        XCTAssertNotEqual(first.id, otherKind.id)
        XCTAssertEqual(try ApprovalStore(db).pending(projectId: project.id).count, 3)
    }

    func testAResolvedRequestDoesNotBlockTheNextOne() throws {
        let first = try request(.push, branch: "agentboard/a")
        _ = try board.resolveApproval(first.id, approved: true, by: "human")
        let second = try request(.push, branch: "agentboard/a")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testTheURLIsRecordedAgainstTheTaskAndReachesTheOrchestratorAsAReport() throws {
        let task = try TaskStore(db).create(
            projectId: project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        let approval = try request(.pullRequest, branch: "agentboard/\(task.id)", taskId: task.id)
        try board.recordPublished(
            approval: approval, summary: "Pull request opened from agentboard/\(task.id) into main.",
            url: "https://github.com/acme/widgets/pull/42"
        )

        let entry = try XCTUnwrap(try ProgressStore(db).latest(taskId: task.id))
        XCTAssertEqual(entry.kind, .status)
        XCTAssertTrue(entry.text.contains("https://github.com/acme/widgets/pull/42"), entry.text)

        let report = try XCTUnwrap(try ReportStore(db).unconsumed(projectId: project.id).last)
        XCTAssertEqual(report.kind, .decision)
        XCTAssertTrue(report.body.contains("https://github.com/acme/widgets/pull/42"), report.body)
    }

    func testAnEpicScopedURLLandsOnTheEpicsIntegratorTask() throws {
        let epic = try board.createEpic(
            projectId: project.id, title: "E", goal: nil,
            tasks: [NewEpicTask(title: "one", dependsOn: [])]
        ).0
        let integrator = try board.createIntegrationTask(epicId: epic.id)

        let approval = try request(.pullRequest, branch: epic.branch, epicId: epic.id)
        try board.recordPublished(approval: approval, summary: "Pull request opened.", url: "https://example.com/pr/1")

        let entry = try XCTUnwrap(try ProgressStore(db).latest(taskId: integrator.id))
        XCTAssertTrue(entry.text.contains("https://example.com/pr/1"), entry.text)
    }

    func testAnEpicWithNoIntegratorFallsBackToOneOfItsTasks() throws {
        let (epic, tasks) = try board.createEpic(
            projectId: project.id, title: "E", goal: nil,
            tasks: [NewEpicTask(title: "one", dependsOn: []), NewEpicTask(title: "two", dependsOn: [])]
        )
        let approval = try request(.pullRequest, branch: epic.branch, epicId: epic.id)
        try board.recordPublished(approval: approval, summary: "Pull request opened.", url: "https://example.com/pr/2")

        let landed = try tasks.compactMap { try ProgressStore(db).latest(taskId: $0.id) }
        XCTAssertEqual(landed.count, 1)
        XCTAssertTrue(try XCTUnwrap(landed.first).text.contains("https://example.com/pr/2"))
    }

    func testAFailureIsRecordedAsAnErrorRowNamingItsCause() throws {
        let task = try TaskStore(db).create(
            projectId: project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .review, origin: .human, epicId: nil
        )
        let approval = try request(.push, branch: "agentboard/\(task.id)", taskId: task.id)
        try board.recordPublished(
            approval: approval,
            summary: "push failed for agentboard/\(task.id): This project has no git remote named \"origin\".",
            failed: true
        )
        let entry = try XCTUnwrap(try ProgressStore(db).latest(taskId: task.id))
        XCTAssertEqual(entry.kind, .error)
        XCTAssertTrue(entry.text.contains("no git remote"), entry.text)
    }

    func testAnApprovalWithNoTaskOrEpicStillProducesAReport() throws {
        let approval = try request(.push, branch: "main")
        try board.recordPublished(approval: approval, summary: "Push approved: pushed main to origin.")
        XCTAssertEqual(try ReportStore(db).unconsumed(projectId: project.id).count, 1)
    }
}
