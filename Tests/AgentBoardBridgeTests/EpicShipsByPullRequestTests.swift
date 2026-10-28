import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §5.2 step 4: in a project that ships epics by pull request, integration leaves the epic open.
final class EpicShipsByPullRequestTests: XCTestCase {
    private var f: BridgeFixture!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    func testIntegrationLeavesTheEpicOpenUntilItsPullRequestMerges() async throws {
        let epic = try f.epic("Ship search", state: .integrating)
        try EpicStore(f.db).setShipsByPullRequest(epic.id, true)
        let member = try f.task("index", epicId: epic.id)
        try f.tasks.move(member.id, to: .done)
        let integration = try f.board.createIntegrationTask(epicId: epic.id)
        try f.session("w1", taskId: integration.id)

        let completion = try await f.scoped.call(
            "report_complete",
            arguments: .object(["summary": .string("merged everything"), "files_changed": .array([])]),
            identity: f.workerIdentity(sessionId: "w1", taskId: integration.id)
        )

        XCTAssertFalse(completion.isError, completion.text)
        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .integrated)
        XCTAssertNil(try f.tasks.get(member.id)?.archivedAt, "the integration archived a task nothing has shipped")
        let openPullRequest = "open_pull_request(epic_id: \"\(epic.id)\""
        let told = try f.reports.unconsumed(projectId: f.project.id).filter { $0.kind == .decision }
        XCTAssertTrue(told.contains { $0.body.contains(openPullRequest) }, told.map(\.body).description)
        let summary = try await f.callJSON("get_epic", ["id": .string(epic.id)])
        XCTAssertTrue(summary["next_step"]?.stringValue?.contains(openPullRequest) == true, "\(summary)")

        let added = try await f.call("create_task", ["title": .string("review fix"), "epic_id": .string(epic.id)])
        XCTAssertFalse(added.isError, added.text)

        let approval = try f.board.requestPublish(
            projectId: f.project.id, kind: .pullRequest,
            request: PublishRequest(branch: epic.branch, base: "main", title: "Ship search", body: ""),
            epicId: epic.id, requestedBy: "orch-session", reason: nil
        )
        _ = try f.board.resolveApproval(approval.id, approved: true, by: "human")
        try f.board.recordPublished(
            approval: approval, summary: "Pull request opened.", url: "https://github.com/acme/widgets/pull/7"
        )
        let pullRequest = try XCTUnwrap(f.board.epicPullRequestChecks(epicId: epic.id).first?.pullRequest)
        XCTAssertTrue(try f.board.landEpicPullRequest(
            epicId: epic.id, pullRequest: pullRequest, commit: nil, carriage: EpicCarriage(landed: [member.id])
        ))

        XCTAssertEqual(try EpicStore(f.db).get(epic.id)?.state, .done)
        XCTAssertNotNil(try f.tasks.get(member.id)?.archivedAt)
    }
}
