import AgentBoardCore
import Foundation
import os

/// One row of the discovery search.
public struct TakeoverSearchHit: Sendable, Equatable {
    public var nodeId: String
    public var kind: TakeoverKind
    public var number: Int
    public var url: String
    public var title: String
    public var author: String?

    public init(nodeId: String, kind: TakeoverKind, number: Int, url: String, title: String, author: String?) {
        self.nodeId = nodeId
        self.kind = kind
        self.number = number
        self.url = url
        self.title = title
        self.author = author
    }
}

/// What GitHub says now about one searched or recorded item.
public struct TakeoverNode: Sendable, Equatable {
    public var nodeId: String
    public var isOpen: Bool
    public var labels: [String]
    public var assignees: [String]
    public var isCrossRepository: Bool
    /// A pull request's closing issues, or the open pull requests that close an issue.
    public var linkedNodeIds: [String]
}

public struct TakeoverPollResult: Sendable, Equatable {
    public var recorded: [Takeover]
    public var released: [Takeover]
}

/// Finds the issues and pull requests a project takes over, records new ones and releases the ones
/// that no longer qualify (SPEC §13.8). Synchronous and blocking: call it off the main actor.
public struct TakeoverDiscovery: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    static let searchFields = "id,number,url,title,isPullRequest,author"
    /// GitHub's cap on `nodes(ids:)`.
    static let nodesPerQuery = 100
    private static let logger = Logger(subsystem: "AgentBoard", category: "takeover")

    /// One search for open issues and pull requests in `repository` assigned to `assignee`, carrying
    /// every trigger label and not the acknowledgment label. Labels go in as query keywords after `--`,
    /// which `gh` quotes, rather than through `--label`, which splits on commas.
    public static func searchArguments(_ settings: TakeoverSettings, repository: String) -> [String] {
        var arguments = [
            "search", "issues", "--include-prs", "--state=open", "--assignee=\(settings.assignee)",
            "--repo=\(repository)", "--json", searchFields, "--limit", "1000", "--",
        ]
        arguments += settings.triggerLabels.map { "label:\($0)" }
        if let ack = settings.ackLabel { arguments.append("-label:\(ack)") }
        return arguments
    }

    public static func nodesArguments(ids: [String]) -> [String] {
        let quoted = ids.map { "\"\($0)\"" }.joined(separator: ", ")
        let query = """
        query {
          viewer { login }
          nodes(ids: [\(quoted)]) {
            __typename
            ... on Issue {
              id state
              labels(first: 100) { nodes { name } }
              assignees(first: 100) { nodes { login } }
              closedByPullRequestsReferences(first: 25, includeClosedPrs: false) { nodes { id } }
            }
            ... on PullRequest {
              id state isCrossRepository
              labels(first: 100) { nodes { name } }
              assignees(first: 100) { nodes { login } }
              closingIssuesReferences(first: 25) { nodes { id } }
            }
          }
        }
        """
        return ["api", "graphql", "-f", "query=\(query)"]
    }

    /// One poll of one project. A quiet poll with nothing recorded costs the search alone; otherwise one
    /// `nodes` read covers every new hit and every live row at once.
    public func poll(
        projectId: String, settings: TakeoverSettings, repository: String, store: TakeoverStore, cwd: URL,
        now: Int64 = .nowMillis
    ) throws -> TakeoverPollResult {
        let reader = PullRequestWatchReader(gh: gh)
        let stdout = try reader.run(Self.searchArguments(settings, repository: repository), cwd: cwd, what: "gh search issues")
        guard let hits = Self.parseSearch(stdout) else {
            throw PullRequestWatchFailure("`gh search issues` printed no list: \(stdout)", ghUnavailable: false)
        }
        let recorded = try store.recordedNodeIds(projectId: projectId)
        let live = try store.live(projectId: projectId)
        let fresh = hits.filter { !recorded.contains($0.nodeId) }
        let ids = Array(Set(fresh.map(\.nodeId) + live.map(\.githubNodeId))).sorted().filter(Self.isNodeId)
        guard !ids.isEmpty else { return TakeoverPollResult(recorded: [], released: []) }

        var nodes: [String: TakeoverNode] = [:]
        var viewer: String?
        for start in stride(from: 0, to: ids.count, by: Self.nodesPerQuery) {
            let chunk = Array(ids[start..<min(start + Self.nodesPerQuery, ids.count)])
            let out = try reader.launch(Self.nodesArguments(ids: chunk), cwd: cwd)
            guard let parsed = Self.parseNodes(out.stdout) else {
                guard out.status == 0 else { throw PullRequestWatchReader.failure(out, what: "gh api graphql") }
                throw PullRequestWatchFailure("`gh api graphql` printed no nodes: \(out.stdout)", ghUnavailable: false)
            }
            let unread = Set(chunk).subtracting(parsed.nodes.map(\.nodeId))
            if !unread.isEmpty {
                Self.logger.notice(
                    "takeover nodes read left out \(unread.sorted().joined(separator: ","), privacy: .public): \(out.stderr, privacy: .public)"
                )
            }
            viewer = viewer ?? parsed.viewer
            for node in parsed.nodes { nodes[node.nodeId] = node }
        }

        var result = TakeoverPollResult(recorded: [], released: [])
        let owning = Set(live.flatMap { [$0.githubNodeId, $0.issueNodeId].compactMap { $0 } })
        let read = fresh.filter { nodes[$0.nodeId] != nil }
        for candidate in Self.candidates(fresh: read, nodes: nodes, owning: owning) {
            if let row = try store.record(projectId: projectId, candidate, now: now) { result.recorded.append(row) }
        }
        for row in Self.releasable(live, nodes: nodes, settings: settings, viewer: viewer) {
            if let released = try store.release(row.id, now: now) { result.released.append(released) }
        }
        return result
    }

    /// The new hits to record. An issue whose open pull request is found with it is folded into that
    /// pull request's row, and a hit linked to a live row is left to that row.
    static func candidates(
        fresh: [TakeoverSearchHit], nodes: [String: TakeoverNode], owning: Set<String>
    ) -> [TakeoverCandidate] {
        func links(_ id: String) -> Set<String> { Set(nodes[id]?.linkedNodeIds ?? []) }
        let prs = fresh.filter { $0.kind == .pr }.sorted { $0.number < $1.number }
        let issues = fresh.filter { $0.kind == .issue }.sorted { $0.number < $1.number }
        var folded: [String: TakeoverSearchHit] = [:]
        var claimed: Set<String> = []
        for pr in prs {
            for issue in issues where !claimed.contains(issue.nodeId)
                && (links(pr.nodeId).contains(issue.nodeId) || links(issue.nodeId).contains(pr.nodeId)) {
                claimed.insert(issue.nodeId)
                if folded[pr.nodeId] == nil { folded[pr.nodeId] = issue }
            }
        }
        return (prs + issues).compactMap { hit in
            guard !claimed.contains(hit.nodeId), links(hit.nodeId).isDisjoint(with: owning) else { return nil }
            let issue = folded[hit.nodeId]
            return TakeoverCandidate(
                githubNodeId: hit.nodeId, kind: hit.kind, number: hit.number, url: hit.url, title: hit.title,
                author: hit.author, isCrossRepository: nodes[hit.nodeId]?.isCrossRepository ?? false,
                issueNodeId: issue?.nodeId, issueURL: issue?.url
            )
        }
    }

    /// Live rows whose item is still open but has lost a trigger label or the assignment. A closed or
    /// unreadable item is left alone.
    static func releasable(
        _ live: [Takeover], nodes: [String: TakeoverNode], settings: TakeoverSettings, viewer: String?
    ) -> [Takeover] {
        let assignee = settings.assignee == TakeoverSettings.defaultAssignee ? viewer : settings.assignee
        return live.filter { row in
            guard let node = nodes[row.githubNodeId], node.isOpen else { return false }
            let labelled = settings.triggerLabels.allSatisfy { wanted in
                node.labels.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            }
            let assigned = assignee.map { who in
                node.assignees.contains { $0.caseInsensitiveCompare(who) == .orderedSame }
            } ?? true
            return !labelled || !assigned
        }
    }

    static func isNodeId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-=".contains($0)) }
    }

    public static func parseSearch(_ json: String) -> [TakeoverSearchHit]? {
        struct Row: Decodable {
            struct Author: Decodable { let login: String? }
            let id: String
            let number: Int
            let url: String
            let title: String
            let isPullRequest: Bool?
            let author: Author?
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(json.utf8)) else { return nil }
        return rows.map {
            TakeoverSearchHit(
                nodeId: $0.id, kind: $0.isPullRequest == true ? .pr : .issue, number: $0.number, url: $0.url,
                title: $0.title, author: $0.author?.login
            )
        }
    }

    static func parseNodes(_ json: String) -> (viewer: String?, nodes: [TakeoverNode])? {
        struct Names: Decodable { struct Name: Decodable { let name: String }; let nodes: [Name?] }
        struct Logins: Decodable { struct Login: Decodable { let login: String? }; let nodes: [Login?] }
        struct Ids: Decodable { struct Id: Decodable { let id: String }; let nodes: [Id?] }
        struct Node: Decodable {
            let id: String?
            let state: String?
            let isCrossRepository: Bool?
            let labels: Names?
            let assignees: Logins?
            let closedByPullRequestsReferences: Ids?
            let closingIssuesReferences: Ids?
        }
        enum PathStep: Decodable {
            case field(String), index(Int)
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let index = try? value.decode(Int.self) {
                    self = .index(index)
                } else {
                    self = .field(try value.decode(String.self))
                }
            }
        }
        struct Problem: Decodable { let path: [PathStep]? }
        struct Response: Decodable {
            struct Data: Decodable {
                struct Viewer: Decodable { let login: String }
                let viewer: Viewer?
                let nodes: [Node?]?
            }
            let data: Data?
            let errors: [Problem]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)),
              let nodes = response.data?.nodes
        else { return nil }
        let errored = Set((response.errors ?? []).compactMap { problem -> Int? in
            guard let path = problem.path, path.count >= 2, case .field("nodes") = path[0],
                  case .index(let index) = path[1] else { return nil }
            return index
        })
        let parsed = nodes.enumerated().compactMap { offset, node -> TakeoverNode? in
            guard !errored.contains(offset), let node, let id = node.id else { return nil }
            let linked = (node.closingIssuesReferences ?? node.closedByPullRequestsReferences)?.nodes.compactMap { $0?.id }
            return TakeoverNode(
                nodeId: id, isOpen: node.state == "OPEN",
                labels: node.labels?.nodes.compactMap { $0?.name } ?? [],
                assignees: node.assignees?.nodes.compactMap { $0?.login } ?? [],
                isCrossRepository: node.isCrossRepository ?? false, linkedNodeIds: linked ?? []
            )
        }
        return (response.data?.viewer?.login, parsed)
    }
}
