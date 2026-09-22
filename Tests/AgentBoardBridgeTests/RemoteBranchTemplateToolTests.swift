import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// What `push_branch` and `open_pull_request` record once a project names its remote branches.
/// Nothing here pushes: the approval payload is the contract the supervisor later executes.
final class RemoteBranchTemplateToolTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        try f.setAutonomy(true)
    }

    private func setTemplate(_ template: String?) throws {
        var project = try XCTUnwrap(f.projects.get(f.project.id))
        var settings = project.settings
        settings.remoteBranchTemplate = template
        try f.projects.updateSettings(project.id, settings)
        project = try XCTUnwrap(f.projects.get(f.project.id))
        XCTAssertEqual(project.settings.remoteBranchTemplate, template)
    }

    private func pending(_ kind: ApprovalKind) throws -> [Approval] {
        try f.approvals.pending(projectId: f.project.id).filter { $0.kind == kind }
    }

    private func request(_ kind: ApprovalKind) throws -> PublishRequest {
        try XCTUnwrap(try pending(kind).first).publishRequest()
    }

    // MARK: No template — today's behaviour, unchanged

    func testAProjectWithNoTemplatePublishesTheLocalName() async throws {
        let task = try f.task("Remove the jsdom escape hatch")
        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])

        let payload = try request(.push)
        XCTAssertEqual(payload.branch, "agentboard/\(task.id)")
        XCTAssertNil(payload.publishedBranch)
        XCTAssertEqual(payload.head, "agentboard/\(task.id)")
    }

    func testAProjectWithNoTemplateOpensThePullRequestFromTheLocalName() async throws {
        let epic = try f.epic("Ship the thing")
        _ = try await f.call("open_pull_request", ["epic_id": .string(epic.id), "title": .string("Ship it")])

        let payload = try request(.pullRequest)
        XCTAssertEqual(payload.branch, epic.branch)
        XCTAssertNil(payload.publishedBranch)
        XCTAssertEqual(payload.head, epic.branch)
    }

    // MARK: With a template

    func testATasksPublishedNameComesFromItsTitle() async throws {
        try setTemplate("clay/{slug}")
        let task = try f.task("Update CLAUDE.md")

        let result = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])

        let payload = try request(.push)
        XCTAssertEqual(payload.branch, "agentboard/\(task.id)")
        XCTAssertEqual(payload.publishedBranch, "clay/update-claude-md")
        XCTAssertEqual(payload.head, "clay/update-claude-md")
        XCTAssertTrue(result.text.contains("clay/update-claude-md"), result.text)
        XCTAssertFalse(payload.head.contains(task.id))
    }

    func testAnEpicsPublishedNameComesFromTheEpicTitle() async throws {
        try setTemplate("clay/{slug}")
        let epic = try f.epic("Push under a human-readable branch name")

        _ = try await f.call("open_pull_request", ["epic_id": .string(epic.id), "title": .string("Rename")])

        let payload = try request(.pullRequest)
        XCTAssertEqual(payload.branch, epic.branch)
        XCTAssertEqual(payload.publishedBranch, "clay/push-under-a-human-readable-branch-name")
        XCTAssertFalse(payload.head.contains(epic.id))
    }

    /// The acceptance criterion the pull request itself turns on: `gh` is handed the published head.
    func testThePullRequestsHeadIsThePublishedNameNotTheLocalOne() async throws {
        try setTemplate("clay/{slug}")
        let epic = try f.epic("Ship the rename")
        _ = try await f.call("open_pull_request", ["epic_id": .string(epic.id), "title": .string("Rename")])

        let payload = try request(.pullRequest)
        XCTAssertEqual(payload.head, "clay/ship-the-rename")
        XCTAssertNotEqual(payload.head, payload.branch)
        XCTAssertEqual(payload.base, "main")
        XCTAssertEqual(payload.branch, epic.branch, "the local branch is carried unchanged alongside it")
    }

    func testTheSameTaskAsksForTheSameBranchOnEveryCall() async throws {
        try setTemplate("clay/{slug}")
        let task = try f.task("Deterministic naming")

        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])
        let first = try request(.push).head
        try f.board.resolveApproval(try XCTUnwrap(try pending(.push).first).id, approved: false, by: "human")

        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])
        let second = try request(.push).head

        XCTAssertEqual(first, "clay/deterministic-naming")
        XCTAssertEqual(second, first)
    }

    func testTwoTasksWithTheSameTitleGetDistinctBranchesAndOneKeepsTheBareSlug() async throws {
        try setTemplate("clay/{slug}")
        let a = try f.task("Fix the flaky test")
        let b = try f.task("fix the flaky  test")

        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(a.id)")])
        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(b.id)")])

        let heads = try pending(.push).map { try $0.publishRequest().head }.sorted()
        XCTAssertEqual(heads.count, 2)
        XCTAssertEqual(Set(heads).count, 2, "\(heads)")
        XCTAssertEqual(heads.filter { $0 == "clay/fix-the-flaky-test" }.count, 1, "\(heads)")
        let suffixed = try XCTUnwrap(heads.first { $0 != "clay/fix-the-flaky-test" })
        XCTAssertTrue(suffixed.hasPrefix("clay/fix-the-flaky-test-"), suffixed)
    }

    func testATaskWithNoCollisionCarriesNoIdSuffix() async throws {
        try setTemplate("clay/{slug}")
        _ = try f.task("A different title entirely")
        let alone = try f.task("Only one of these")

        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(alone.id)")])

        XCTAssertEqual(try request(.push).head, "clay/only-one-of-these")
    }

    func testTheBaseBranchIsPublishedUnderItsOwnNameEvenWithATemplate() async throws {
        try setTemplate("clay/{slug}")
        _ = try await f.call("push_branch", ["branch": .string("main")])

        let payload = try request(.push)
        XCTAssertEqual(payload.branch, "main")
        XCTAssertNil(payload.publishedBranch)
    }

    func testAnUnusableTemplateIsRefusedRatherThanPublishedLiterally() async throws {
        try setTemplate("clay/{title}")
        let task = try f.task("Anything")
        await XCTAssertToolError(
            try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")]),
            containing: "not usable"
        )
        XCTAssertTrue(try pending(.push).isEmpty)
    }

    /// With a template set, an owned branch that matches nothing on the board has no title to name
    /// it from — publishing the local name there would put the id on the remote, which is the whole
    /// thing the template exists to prevent.
    func testAnOwnedBranchWithNoBoardRecordIsRefusedRatherThanLeakingTheId() async throws {
        try setTemplate("clay/{slug}")
        await XCTAssertToolError(
            try await f.call("push_branch", ["branch": .string("agentboard/not-a-real-id")]),
            containing: "matches no epic or task"
        )
        XCTAssertTrue(try pending(.push).isEmpty)
    }

    func testAnEmojiOnlyTitleFallsBackToAShortIdAndNotTheFullOne() async throws {
        try setTemplate("clay/{slug}")
        let task = try f.task("🚀🔥")

        _ = try await f.call("push_branch", ["branch": .string("agentboard/\(task.id)")])

        let head = try request(.push).head
        XCTAssertTrue(head.hasPrefix("clay/"), head)
        XCTAssertNotEqual(head, "clay/\(task.id)")
        XCTAssertLessThanOrEqual(head.count, "clay/".count + RemoteBranchNaming.shortIdLength)
    }

    /// The local guard is untouched: a template does not widen which local refs the tools accept.
    func testTheLocalOwnershipGuardStillRefusesAForeignBranch() async throws {
        try setTemplate("clay/{slug}")
        await XCTAssertToolError(
            try await f.call("push_branch", ["branch": .string("clay/update-claude-md")]),
            containing: "only push branches it owns"
        )
        XCTAssertTrue(try pending(.push).isEmpty)
    }
}
