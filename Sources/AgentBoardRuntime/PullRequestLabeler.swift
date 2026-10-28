import Foundation

/// Mark verified (SPEC §13.4): adds the project's verification label to a pull request.
/// Synchronous and blocking: call it off the main actor.
public struct PullRequestLabeler: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    public static func arguments(url: String, label: String) -> [String] {
        ["pr", "edit", url, "--add-label", label]
    }

    public func addLabel(_ label: String, to url: String, cwd: URL) throws {
        let result = try gh.run(Self.arguments(url: url, label: label), cwd: cwd)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PullRequestCheckFailure("`gh pr edit --add-label \(label)` failed: \(detail.isEmpty ? "exit \(result.status)" : detail)")
        }
    }
}
