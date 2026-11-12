import AgentBoardCore
import Foundation

public enum TakeoverAcknowledgment: Sendable, Equatable {
    case acknowledged(Takeover)
    /// The label is on and the row is `acknowledged`, but the comment did not post.
    case commentFailed(Takeover, detail: String)
    /// The acknowledgment label does not exist on the repository; nothing was written.
    case labelMissing(problem: String)
    /// The row is no longer `found`, so nothing was run.
    case skipped
}

/// Acknowledges a takeover on GitHub (SPEC §13.8): adds the acknowledgment label, records `acknowledged`,
/// then posts the comment. It never creates a label and never reads GitHub's comment text back.
/// Synchronous and blocking: call it off the main actor.
public struct TakeoverAcknowledger: Sendable {
    public var gh: any GhRunning

    public init(gh: any GhRunning = SystemGh()) {
        self.gh = gh
    }

    static func command(_ kind: TakeoverKind) -> String { kind == .pr ? "pr" : "issue" }

    public static func labelListArguments(label: String, repository: String) -> [String] {
        ["label", "list", "--repo", repository, "--search", label, "--json", "name", "--limit", "100"]
    }

    public static func addLabelArguments(_ takeover: Takeover, label: String) -> [String] {
        [command(takeover.kind), "edit", takeover.url, "--add-label", label]
    }

    public static func commentArguments(_ takeover: Takeover, body: String) -> [String] {
        [command(takeover.kind), "comment", takeover.url, "--body", body]
    }

    static let viewerArguments = ["api", "user", "--jq", ".login"]

    public static func render(_ template: String, assignee: String, takeover: Takeover) -> String {
        template
            .replacingOccurrences(of: "{assignee}", with: assignee)
            .replacingOccurrences(of: "{kind}", with: takeover.kind == .pr ? "pull request" : "issue")
            .replacingOccurrences(of: "{url}", with: takeover.url)
    }

    public static func missingLabelProblem(_ label: String, repository: String) -> String {
        "Takeover: the acknowledgment label “\(label)” does not exist on \(repository). Create it on GitHub; "
            + "Agent Board never creates labels. Takeovers wait until it exists."
    }

    /// `labelConfirmed` skips the `gh label list` check; pass true only once a check or an edit in this
    /// project has seen the label. A failed label edit throws and records nothing.
    public func acknowledge(
        _ takeover: Takeover, settings: TakeoverSettings, repository: String, labelConfirmed: Bool,
        store: TakeoverStore, cwd: URL, now: Int64 = .nowMillis
    ) throws -> TakeoverAcknowledgment {
        guard let label = settings.ackLabel, try store.get(takeover.id)?.state == .found else { return .skipped }
        let missing = TakeoverAcknowledgment.labelMissing(problem: Self.missingLabelProblem(label, repository: repository))
        if !labelConfirmed, try !labelExists(label, repository: repository, cwd: cwd) { return missing }
        let body = try settings.ackComment.map { template in
            let assignee = settings.assignee == TakeoverSettings.defaultAssignee
                && template.contains("{assignee}") ? try viewer(cwd: cwd) : settings.assignee
            return Self.render(template, assignee: assignee, takeover: takeover)
        }

        let edit = try gh.run(Self.addLabelArguments(takeover, label: label), cwd: cwd)
        guard edit.status == 0 else {
            let said = Self.said(edit)
            if said.localizedCaseInsensitiveContains("not found"),
               try !labelExists(label, repository: repository, cwd: cwd) {
                return missing
            }
            throw PullRequestCheckFailure("`gh \(Self.command(takeover.kind)) edit --add-label` failed: \(said)")
        }

        guard let acknowledged = try store.acknowledge(takeover.id, now: now) else { return .skipped }
        guard let body else { return .acknowledged(acknowledged) }
        let comment: CommandResult
        do {
            comment = try gh.run(Self.commentArguments(takeover, body: body), cwd: cwd)
        } catch {
            comment = CommandResult(status: -1, stdout: "", stderr: "\(error)")
        }
        guard comment.status == 0 else {
            let detail = "The acknowledgment comment did not post: \(Self.said(comment))"
            let noted = try store.noteProblem(acknowledged.id, detail: detail, now: now)
            return .commentFailed(noted ?? acknowledged, detail: detail)
        }
        return .acknowledged(acknowledged)
    }

    public func labelExists(_ label: String, repository: String, cwd: URL) throws -> Bool {
        let result = try gh.run(Self.labelListArguments(label: label, repository: repository), cwd: cwd)
        struct Row: Decodable { let name: String }
        guard result.status == 0,
              let rows = try? JSONDecoder().decode([Row].self, from: Data(result.stdout.utf8))
        else {
            throw PullRequestCheckFailure("`gh label list` failed: \(Self.said(result))")
        }
        return rows.contains { $0.name.caseInsensitiveCompare(label) == .orderedSame }
    }

    private func viewer(cwd: URL) throws -> String {
        let result = try gh.run(Self.viewerArguments, cwd: cwd)
        let login = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !login.isEmpty else {
            throw PullRequestCheckFailure("`gh api user` failed: \(Self.said(result))")
        }
        return login
    }

    private static func said(_ result: CommandResult) -> String {
        [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "exit \(result.status)"
    }
}
