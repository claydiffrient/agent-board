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

    func testAnIssueWhoseOneSameRepositoryPullRequestIsNoHitBecomesThatPullRequestsRecord() throws {
        let (store, projectId) = try fixture()
        let gh = RecordingGh(
            search: Self.search([
                ("I_one", 4, false, "https://github.com/example-org/app/issues/4"),
                ("I_fork", 5, false, "https://github.com/example-org/app/issues/5"),
                ("I_two", 6, false, "https://github.com/example-org/app/issues/6"),
            ]),
            nodes: Self.nodes([
                Self.node("I_one", typename: "Issue", prs: [Self.linkedPR("PR_lone", 40)]),
                Self.node("I_fork", typename: "Issue", prs: [Self.linkedPR("PR_fork", 50, fork: true)]),
                Self.node("I_two", typename: "Issue", prs: [Self.linkedPR("PR_a", 60), Self.linkedPR("PR_b", 61)]),
            ])
        )

        _ = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        let rows = try store.page(projectId: projectId).sorted { $0.number < $1.number }
        XCTAssertEqual(rows.map(\.kind), [.issue, .issue, .pr])
        XCTAssertEqual(rows.map(\.number), [5, 6, 40])
        let pr = try XCTUnwrap(rows.last)
        XCTAssertEqual(pr.githubNodeId, "PR_lone")
        XCTAssertEqual(pr.url, "https://github.com/example-org/app/pull/40")
        XCTAssertEqual(pr.issueNodeId, "I_one")
        XCTAssertEqual(pr.issueURL, "https://github.com/example-org/app/issues/4")
        XCTAssertTrue(pr.viaIssue)
        XCTAssertEqual(gh.calls.count, 2, "the linked pull request is read in the one nodes query")
    }

    func testAPullRequestTakenOverThroughItsIssueIsReleasedOnlyWhenTheIssueLosesItsLabels() throws {
        let (store, projectId) = try fixture()
        let row = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
            githubNodeId: "PR_lone", kind: .pr, number: 40, url: "https://github.com/example-org/app/pull/40",
            title: "Fix", author: "example-author", issueNodeId: "I_one",
            issueURL: "https://github.com/example-org/app/issues/4", viaIssue: true
        )))
        try store.acknowledge(row.id)
        let bare = Self.node("PR_lone", typename: "PullRequest", labels: [])
        func poll(issueLabels: [String]) throws -> TakeoverPollResult {
            let gh = RecordingGh(
                search: "[]",
                nodes: Self.nodes([bare, Self.node("I_one", typename: "Issue", labels: issueLabels)])
            )
            return try TakeoverDiscovery(gh: gh).poll(
                projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
            )
        }

        XCTAssertEqual(try poll(issueLabels: ["handoff-example", "ready example", "taken-example"]).released, [])
        XCTAssertEqual(try store.get(row.id)?.state, .acknowledged)

        XCTAssertEqual(try poll(issueLabels: ["handoff-example", "taken-example"]).released.map(\.id), [row.id])
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

    func testAPartialReadActsOnTheNodesItGotAndLeavesUnreadableItemsAlone() throws {
        let (store, projectId) = try fixture()
        var rows: [String: Takeover] = [:]
        for (number, id) in [(1, "I_gone"), (2, "I_lost"), (3, "I_partial")] {
            let row = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
                githubNodeId: id, kind: .issue, number: number,
                url: "https://github.com/example-org/app/issues/\(number)", title: id, author: "example-author"
            )))
            try store.acknowledge(row.id)
            rows[id] = row
        }
        var partial = Self.node("I_partial", typename: "Issue")
        partial["labels"] = NSNull()
        let response = Self.json([
            "data": ["viewer": ["login": "example-user"], "nodes": [
                NSNull(), Self.node("I_lost", typename: "Issue", labels: ["taken-example"]), NSNull(), partial,
            ]],
            "errors": [
                ["message": "Could not resolve to a node with the global id of 'I_gone'", "path": ["nodes", 0]],
                ["message": "Could not resolve to a node with the global id of 'I_new'", "path": ["nodes", 2]],
                ["message": "Resource not accessible", "path": ["nodes", 3, "labels"]],
            ],
        ])
        let gh = RecordingGh(
            search: Self.search([("I_new", 8, false, "https://github.com/example-org/app/issues/8")]),
            nodes: response, nodesStatus: 1
        )

        let result = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        XCTAssertEqual(result.released.map(\.id), [rows["I_lost"]?.id])
        XCTAssertEqual(result.recorded, [], "an unread hit waits for a poll that reads it")
        XCTAssertEqual(try store.get(XCTUnwrap(rows["I_gone"]).id)?.state, .acknowledged)
        XCTAssertEqual(try store.get(XCTUnwrap(rows["I_partial"]).id)?.state, .acknowledged)
    }

    func testAClosedItemEndsItsTakeoverDoneOrReleasedAsItsWatchWould() throws {
        let db = try AppDatabase.inMemory()
        let projectId = try ProjectStore(db).register(
            name: "Example", repoPath: "/example", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil
        ).id
        let store = TakeoverStore(db)
        let issue = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
            githubNodeId: "I_closed", kind: .issue, number: 3, url: "https://github.com/example-org/app/issues/3",
            title: "Closed", author: "example-author"
        )))
        let task = try XCTUnwrap(store.createTask(issue.id, issue: TakeoverIssue(
            number: 3, title: "Closed", url: issue.url, author: "example-author", body: ""
        )))
        try store.acknowledge(issue.id)
        try store.startWorking(issue.id, taskId: task.id)
        var pullRequests: [String: Takeover] = [:]
        for (number, id) in [(4, "PR_merged"), (5, "PR_closed")] {
            let row = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
                githubNodeId: id, kind: .pr, number: number, url: "https://github.com/example-org/app/pull/\(number)",
                title: id, author: "example-author"
            )))
            let watch = try XCTUnwrap(PRWatchStore(db).adopt(row))
            try store.acknowledge(row.id)
            try store.watch(row.id, watchId: watch.id)
            pullRequests[id] = row
        }
        let gh = RecordingGh(search: "[]", nodes: Self.nodes([
            Self.node("I_closed", typename: "Issue", state: "CLOSED"),
            Self.node("PR_merged", typename: "PullRequest", state: "MERGED"),
            Self.node("PR_closed", typename: "PullRequest", state: "CLOSED"),
        ]))

        _ = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        XCTAssertEqual(try store.get(issue.id)?.state, .done, "a closed issue is done, never released")
        XCTAssertEqual(try store.get(XCTUnwrap(pullRequests["PR_merged"]).id)?.state, .done)
        XCTAssertEqual(try store.get(XCTUnwrap(pullRequests["PR_closed"]).id)?.state, .released)
    }

    func testAFoundPullRequestThatClosedIsReleasedAndNothingIsPostedToIt() throws {
        let (store, projectId) = try fixture()
        let row = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
            githubNodeId: "PR_found", kind: .pr, number: 6, url: "https://github.com/example-org/app/pull/6",
            title: "Found", author: "example-author"
        )))
        let gh = RecordingGh(search: "[]", nodes: Self.nodes([Self.node("PR_found", typename: "PullRequest", state: "CLOSED")]))

        let result = try TakeoverDiscovery(gh: gh).poll(
            projectId: projectId, settings: settings, repository: "example-org/app", store: store, cwd: cwd
        )

        XCTAssertEqual(try store.get(row.id)?.state, .released)
        XCTAssertEqual(result.released.map(\.id), [row.id])
        XCTAssertFalse(gh.calls.contains { $0.contains("edit") || $0.contains("comment") })
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
        linked: [String] = [], prs: [[String: Any]] = [], state: String = "OPEN"
    ) -> [String: Any] {
        let links = ["nodes": linked.map { ["id": $0] as [String: Any] } + prs]
        var node: [String: Any] = [
            "__typename": typename, "id": id, "state": state,
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

    private static func linkedPR(_ id: String, _ number: Int, fork: Bool = false) -> [String: Any] {
        ["id": id, "number": number, "url": "https://github.com/example-org/app/pull/\(number)",
         "title": "Fix \(number)", "state": "OPEN", "isCrossRepository": fork, "author": ["login": "example-author"]]
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
    private let nodesStatus: Int32

    init(search: String, nodes: String? = nil, nodesStatus: Int32 = 0) {
        self.search = search
        self.nodes = nodes
        self.nodesStatus = nodesStatus
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], cwd: URL) throws -> CommandResult {
        lock.withLock { recorded.append(arguments) }
        switch arguments.first {
        case "search": return CommandResult(status: 0, stdout: search, stderr: "")
        case "api" where nodes != nil: return CommandResult(status: nodesStatus, stdout: nodes!, stderr: "")
        default: return CommandResult(status: 1, stdout: "", stderr: "no canned answer for \(arguments)")
        }
    }
}
