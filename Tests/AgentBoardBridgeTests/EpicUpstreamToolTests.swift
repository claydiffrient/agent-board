import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

final class EpicUpstreamToolTests: XCTestCase {
    private var f: BridgeFixture!
    private let upstream = EpicUpstream(
        headRef: "feature/widgets",
        pullRequest: PullRequestReference(url: "https://github.com/example-org/app/pull/13237", number: 13237)
    )
    private let expected: JSONValue = .object([
        "number": .number(13237),
        "url": .string("https://github.com/example-org/app/pull/13237"),
        "head_ref": .string("feature/widgets"),
    ])

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
    }

    private func create(pullRequest: Int) async throws -> ToolResult {
        try await f.call("create_epic", [
            "title": .string("Widgets"),
            "pull_request": .number(Double(pullRequest)),
            "tasks": .array([.object(["title": .string("finish the widgets")])]),
        ])
    }

    func testCreateEpicOnAPullRequestCarriesItAndShowsItInEveryEpicRead() async throws {
        await f.control.setUpstream(13237, .success(upstream))
        let created = try JSONDecoder().decode(JSONValue.self, from: Data(try await create(pullRequest: 13237).text.utf8))
        let epicId = try XCTUnwrap(created["epic_id"]?.stringValue)

        XCTAssertEqual(try EpicStore(f.db).get(epicId)?.upstream, upstream)
        XCTAssertEqual(created["upstream"], expected)
        let one = try await f.callJSON("get_epic", ["id": .string(epicId)])
        let all = try await f.callJSON("list_epics")
        XCTAssertEqual(one["upstream"], expected)
        XCTAssertEqual(all.arrayValue?.first?["upstream"], expected)
    }

    func testARefusedLookupCreatesNothingAndSaysWhy() async throws {
        await f.control.setUpstream(7, .failure(.init(description: "Pull request #7 is merged, not open")))
        await XCTAssertToolError(try await create(pullRequest: 7), containing: "Pull request #7 is merged, not open")

        await f.control.setUpstream(13237, .success(upstream))
        _ = try await create(pullRequest: 13237)
        await XCTAssertToolError(try await create(pullRequest: 13237), containing: "already builds on pull request")
        XCTAssertEqual(try EpicStore(f.db).list(projectId: f.project.id).count, 1)
    }

    func testOpenPullRequestIsRefusedForAnUpstreamEpicByIdOrBranch() async throws {
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Widgets", goal: nil, upstream: upstream)
        for target: (String, String) in [("epic_id", epic.id), ("branch", epic.branch)] {
            await XCTAssertToolError(
                try await f.call("open_pull_request", [target.0: .string(target.1), "title": .string("Widgets")]),
                containing: "\(upstream.pullRequest.url)), which already exists"
            )
        }
        XCTAssertTrue(try f.approvals.pending(projectId: f.project.id).isEmpty)
    }
}
