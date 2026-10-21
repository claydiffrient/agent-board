import Foundation

/// What GitHub says about a pull request, reduced to what decides a task's landing.
public enum PullRequestState: Sendable, Equatable {
    case open
    case closed
    /// `head` is the pull request's head commit as merged: what the pull request actually carried.
    case merged(commit: String?, head: String?)
}

public struct PullRequestHead: Sendable, Equatable {
    public var isOpen: Bool
    public var oid: String
    public var labels: [String]

    public init(isOpen: Bool, oid: String, labels: [String]) {
        self.isOpen = isOpen
        self.oid = oid
        self.labels = labels
    }
}

public struct PullRequestCheckFailure: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Runs `gh` from `cwd`. The seam a test replaces with canned output.
public protocol GhRunning: Sendable {
    func run(_ arguments: [String], cwd: URL) throws -> CommandResult
}

public struct SystemGh: GhRunning {
    public init() {}

    public func run(_ arguments: [String], cwd: URL) throws -> CommandResult {
        guard let gh = PullRequestOpener.ghExecutable() else {
            throw PullRequestCheckFailure("the GitHub CLI (`gh`) is not installed; install it with `brew install gh`.")
        }
        return try ProcessRunner.run(
            executable: gh, arguments: arguments, cwd: cwd,
            environment: ChildEnvironment.sanitized()
                .merging(["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]) { _, new in new }
        )
    }
}

/// Reads a pull request's state with `gh pr view`. Synchronous and blocking: call it off the main actor.
public struct PullRequestStateReader: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    public static func arguments(url: String) -> [String] {
        ["pr", "view", url, "--json", "state,mergedAt,mergeCommit,headRefOid"]
    }

    public func state(of url: String, cwd: URL) throws -> PullRequestState {
        let stdout = try view(Self.arguments(url: url), cwd: cwd)
        guard let state = Self.parse(stdout) else {
            throw PullRequestCheckFailure("`gh pr view` printed no state: \(stdout)")
        }
        return state
    }

    public static func headArguments(url: String) -> [String] {
        ["pr", "view", url, "--json", "state,headRefOid,labels"]
    }

    /// The pull request's head and labels as GitHub has them now, for publishing's re-read (SPEC §13.1).
    public func head(of url: String, cwd: URL) throws -> PullRequestHead {
        let stdout = try view(Self.headArguments(url: url), cwd: cwd)
        guard let head = Self.parseHead(stdout) else {
            throw PullRequestCheckFailure("`gh pr view` printed no head: \(stdout)")
        }
        return head
    }

    private func view(_ arguments: [String], cwd: URL) throws -> String {
        let result = try gh.run(arguments, cwd: cwd)
        guard result.status == 0 else {
            let said = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            throw PullRequestCheckFailure("`gh pr view` failed (is `gh` logged in? `gh auth login`): \(said)")
        }
        return result.stdout
    }

    public static func parseHead(_ json: String) -> PullRequestHead? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String, let oid = object["headRefOid"] as? String
        else { return nil }
        let labels = (object["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return PullRequestHead(isOpen: state.uppercased() == "OPEN", oid: oid, labels: labels)
    }

    public static func parse(_ json: String) -> PullRequestState? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String
        else { return nil }
        switch state.uppercased() {
        case "MERGED":
            return .merged(
                commit: (object["mergeCommit"] as? [String: Any])?["oid"] as? String,
                head: object["headRefOid"] as? String
            )
        case "CLOSED": return .closed
        case "OPEN": return .open
        default: return nil
        }
    }
}
