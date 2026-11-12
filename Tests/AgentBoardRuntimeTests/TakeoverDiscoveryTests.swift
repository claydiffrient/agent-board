import AgentBoardCore
@testable import AgentBoardRuntime
import Foundation
import XCTest

final class TakeoverDiscoveryTests: XCTestCase {
    private let settings = TakeoverSettings(
        enabled: true, triggerLabels: ["handoff-example", "ready example"], ackLabel: "taken-example"
    )
    private let cwd = URL(fileURLWithPath: "/nonexistent")

    func testTheSearchCarriesEveryTriggerLabelTheAckExclusionTheAssigneeAndTheRepository() throws {
        let (store, projectId) = try fixture()
        let gh = RecordingGh(search: "[]")

        _ = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        let search = try XCTUnwrap(gh.calls.first)
        XCTAssertEqual(Array(search.prefix(3)), ["search", "issues", "--include-prs"])
        XCTAssertTrue(search.contains("--state=open"))
        XCTAssertTrue(search.contains("--assignee=@me"))
        XCTAssertTrue(search.contains("--repo=example-org/app"))
        let keywords = Array(search.drop { $0 != "--" }.dropFirst())
        XCTAssertEqual(keywords, ["label:handoff-example", "label:ready example", "-label:taken-example"])
        XCTAssertEqual(gh.calls.count, 1, "a quiet poll with nothing recorded reads nothing else")
    }

    func testAnIssueAndItsLinkedPullRequestBecomeOnePullRequestRecord() throws {
        let (store, projectId) = try fixture()
        let gh = RecordingGh(
            search: Self.search([
                ("I_issue", 7, false, "https://github.com/example-org/app/issues/7"),
                ("PR_fix", 9, true, "https://github.com/example-org/app/pull/9"),
            ]),
            nodes: Self.nodes([
                Self.node("I_issue", typename: "Issue", linked: ["PR_fix"]),
                Self.node("PR_fix", typename: "PullRequest", linked: ["I_issue"]),
            ])
        )

        let result = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )
        _ = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        XCTAssertEqual(result.recorded.count, 1)
        let rows = try store.page(projectId: projectId)
        XCTAssertEqual(rows.map(\.kind), [.pr])
        XCTAssertEqual(rows.first?.number, 9)
        XCTAssertEqual(rows.first?.issueURL, "https://github.com/example-org/app/issues/7")
        XCTAssertEqual(rows.first?.state, .found)
    }

    func testARecordedItemThatLostATriggerLabelIsReleased() throws {
        let (store, projectId) = try fixture()
        let recorded = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
            githubNodeId: "I_kept", kind: .issue, number: 3, url: "https://github.com/example-org/app/issues/3",
            title: "Kept", author: "example-author"
        )))
        try store.acknowledge(recorded.id)
        let gh = RecordingGh(
            search: "[]",
            nodes: Self.nodes([Self.node("I_kept", typename: "Issue", labels: ["handoff-example", "taken-example"])])
        )

        let result = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        XCTAssertEqual(result.released.map(\.id), [recorded.id])
        XCTAssertEqual(try store.get(recorded.id)?.state, .released)
    }

    private func fixture() throws -> (TakeoverStore, String) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Example", repoPath: "/example", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil
        )
        return (TakeoverStore(db), project.id)
    }

    private static func search(_ hits: [(id: String, number: Int, isPR: Bool, url: String)]) -> String {
        json(hits.map {
            ["id": $0.id, "number": $0.number, "url": $0.url, "title": "Item \($0.number)",
             "isPullRequest": $0.isPR, "author": ["login": "example-author"]]
        })
    }

    private static func node(
        _ id: String, typename: String, labels: [String] = ["handoff-example", "ready example"],
        linked: [String] = []
    ) -> [String: Any] {
        let links = ["nodes": linked.map { ["id": $0] }]
        var node: [String: Any] = [
            "__typename": typename, "id": id, "state": "OPEN",
            "labels": ["nodes": labels.map { ["name": $0] }],
            "assignees": ["nodes": [["login": "example-user"]]],
        ]
        if typename == "PullRequest" {
            node["isCrossRepository"] = false
            node["closingIssuesReferences"] = links
        } else {
            node["closedByPullRequestsReferences"] = links
        }
        return node
    }

    private static func nodes(_ nodes: [[String: Any]]) -> String {
        json(["data": ["viewer": ["login": "example-user"], "nodes": nodes]])
    }

    private static func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

/// `gh` that records every call and answers `gh search` and `gh api` with canned output.
private final class RecordingGh: GhRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let search: String
    private let nodes: String?

    init(search: String, nodes: String? = nil) {
        self.search = search
        self.nodes = nodes
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], cwd: URL) throws -> CommandResult {
        lock.withLock { recorded.append(arguments) }
        switch arguments.first {
        case "search": return CommandResult(status: 0, stdout: search, stderr: "")
        case "api" where nodes != nil: return CommandResult(status: 0, stdout: nodes!, stderr: "")
        default: return CommandResult(status: 1, stdout: "", stderr: "no canned answer for \(arguments)")
        }
    }
}
