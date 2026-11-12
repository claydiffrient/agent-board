import Foundation
import XCTest
@testable import AgentBoardCore

final class EpicUpstreamTests: XCTestCase {
    private let upstream = EpicUpstream(
        headRef: "feature/widgets",
        pullRequest: PullRequestReference(url: "https://github.com/example-org/app/pull/42", number: 42)
    )

    func testASecondOpenEpicOnTheSamePullRequestIsRefusedNamingTheFirst() throws {
        let f = try Fixture.make()
        let first = try f.epics.create(projectId: f.project.id, title: "Widgets", goal: nil, upstream: upstream)
        XCTAssertEqual(try f.epics.get(first.id)?.upstream, upstream)

        XCTAssertThrowsError(try f.epics.create(projectId: f.project.id, title: "Again", goal: nil, upstream: upstream)) {
            XCTAssertEqual(
                $0 as? EpicUpstreamError,
                .alreadyAdopted(pullRequest: 42, epicId: first.id, title: "Widgets")
            )
        }

        try f.epics.setState(first.id, .abandoned)
        XCTAssertNoThrow(try f.epics.create(projectId: f.project.id, title: "Again", goal: nil, upstream: upstream))
    }

    func testAnUpstreamEpicPublishesToItsHeadRefWithOrWithoutATemplate() throws {
        let f = try Fixture.make()
        let epic = try f.epics.create(projectId: f.project.id, title: "Widgets", goal: nil, upstream: upstream)
        let resolver = RemoteBranchResolver(f.db)

        XCTAssertEqual(try resolver.publishedName(branch: epic.branch, project: f.project), "feature/widgets")

        var settings = f.project.settings
        settings.remoteBranchTemplate = "someone/{slug}"
        try f.projects.updateSettings(f.project.id, settings)
        let templated = try XCTUnwrap(f.projects.get(f.project.id))
        XCTAssertEqual(try resolver.publishedName(branch: epic.branch, project: templated), "feature/widgets")
        XCTAssertNil(try resolver.publishedName(branch: "main", project: templated))
    }

    func testTheUpstreamPullRequestMergingLandsTheEpicFromAnyOpenState() throws {
        let f = try Fixture.make()
        let epic = try f.epics.create(projectId: f.project.id, title: "Widgets", goal: nil, upstream: upstream)
        try f.epics.setState(epic.id, .active)

        let check = try XCTUnwrap(f.board.epicPullRequestChecks(epicId: epic.id).first)
        XCTAssertEqual(check.pullRequest, upstream.pullRequest)
        XCTAssertTrue(try f.board.landEpicPullRequest(
            epicId: epic.id, pullRequest: check.pullRequest, commit: nil, carriage: EpicCarriage()
        ))
        XCTAssertEqual(try f.epics.get(epic.id)?.state, .done)
        XCTAssertTrue(try f.board.epicPullRequestChecks(epicId: epic.id).isEmpty)
    }
}
