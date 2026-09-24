import Foundation

/// What GitHub says about a pull request, reduced to what decides a task's landing.
public enum PullRequestState: Sendable, Equatable {
    case open
    case closed
    case merged(commit: String?)
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
        ["pr", "view", url, "--json", "state,mergedAt,mergeCommit"]
    }

    public func state(of url: String, cwd: URL) throws -> PullRequestState {
        let result = try gh.run(Self.arguments(url: url), cwd: cwd)
        guard result.status == 0 else {
            let said = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(result.status)"
            throw PullRequestCheckFailure("`gh pr view` failed (is `gh` logged in? `gh auth login`): \(said)")
        }
        guard let state = Self.parse(result.stdout) else {
            throw PullRequestCheckFailure("`gh pr view` printed no state: \(result.stdout)")
        }
        return state
    }

    public static func parse(_ json: String) -> PullRequestState? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String
        else { return nil }
        switch state.uppercased() {
        case "MERGED": return .merged(commit: (object["mergeCommit"] as? [String: Any])?["oid"] as? String)
        case "CLOSED": return .closed
        case "OPEN": return .open
        default: return nil
        }
    }
}
