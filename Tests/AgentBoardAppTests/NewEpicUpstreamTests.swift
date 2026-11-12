import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §10: the New Epic sheet's Pull request field, and the lane header's link to that pull request.
@MainActor
final class NewEpicUpstreamTests: XCTestCase {
    func testTheSheetBuildsAnEpicOnAPullRequestThatTheLaneHeaderLinksFromCreation() async throws {
        let fixture = try SupervisorFixture.make(gitRepo: true)
        try fixture.git(["remote", "add", "origin", "git@github.com:example-org/app.git"])
        fixture.gh.answer(
            prefix: ["pr", "view", "13237", "--repo", "example-org/app"],
            stdout: #"{"headRefName":"feature/widgets","isCrossRepository":false,"number":13237,"state":"OPEN","#
                + #""url":"https://github.com/example-org/app/pull/13237"}"#
        )
        fixture.gh.answer(
            prefix: ["pr", "view", "7", "--repo", "example-org/app"],
            stdout: #"{"headRefName":"old","isCrossRepository":false,"number":7,"state":"MERGED","#
                + #""url":"https://github.com/example-org/app/pull/7"}"#
        )

        func create(_ pullRequest: String) async throws -> Epic {
            try await EpicCreation.create(
                db: fixture.db, gh: fixture.gh, projectId: fixture.project.id, title: "Widgets", goal: nil,
                tasks: [], pullRequest: pullRequest
            )
        }

        for refused in ["7", "abc"] {
            do {
                _ = try await create(refused)
                XCTFail("pull request \(refused) was not refused")
            } catch {
                XCTAssertTrue(error is EpicCreation.PullRequestRefusal, "\(refused): \(error)")
            }
        }
        XCTAssertTrue(try EpicStore(fixture.db).list(projectId: fixture.project.id).isEmpty)

        let epic = try await create("#13237")
        XCTAssertEqual(epic.upstream?.headRef, "feature/widgets")
        XCTAssertEqual(epic.state, .planning)

        let links = try await ApprovalStore(fixture.db).observeEpicPullRequests(projectId: fixture.project.id)
            .values(in: fixture.db.reader).first { _ in true }
        XCTAssertEqual(links?[epic.id]?.number, 13237)

        await fixture.cleanUp()
    }
}
