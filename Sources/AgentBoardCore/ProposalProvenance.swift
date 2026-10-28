import Foundation
import GRDB

/// Where a `verify_session` proposal came from (SPEC §10). The verifier's `propose_task` writes
/// `reportLine` into the proposal report, and the board reads the pull request back from it, so the
/// card keeps naming the PR after its watch row is deleted.
public enum ProposalProvenance {
    public static let walkMeThrough = "From Walk me through it"

    public static func reportLine(pullRequest: String?) -> String {
        guard let pullRequest else { return "\(walkMeThrough); its pull request is no longer watched." }
        return "\(walkMeThrough) on \(pullRequest)."
    }

    public static func pullRequest(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }

    /// The `owner/repo#N` a proposal report's `reportLine` names. Only the third paragraph, where
    /// `Board.propose` writes `source`, is read: the rest is verifier-written text that may echo the line.
    public static func pullRequest(inReport body: String) -> String? {
        let paragraphs = body.components(separatedBy: "\n\n")
        guard paragraphs.count > 2,
              paragraphs[0].hasPrefix("Proposed task: "), paragraphs[1].hasPrefix("Task id: "),
              let match = paragraphs[2].wholeMatch(of: #/From Walk me through it on ([^\s/]+/[^\s#]+#\d+)\./#)
        else { return nil }
        return String(match.1)
    }

    /// The card and detail line, or nil for every origin but `verify_session`.
    public static func label(origin: TaskOrigin, pullRequest: String?) -> String? {
        guard origin == .verifySession else { return nil }
        return pullRequest.map { "\(walkMeThrough) · \($0)" } ?? walkMeThrough
    }

    /// Each of the project's `verify_session` tasks mapped to the pull request its proposal report names.
    public static func observePullRequests(
        projectId: String
    ) -> ValueObservation<ValueReducers.Fetch<[String: String]>> {
        ValueObservation.tracking { db in try pullRequests(db, projectId: projectId) }
    }

    static func pullRequests(_ db: Database, projectId: String) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT report.task_id, report.body FROM report
            JOIN task ON task.id = report.task_id
            WHERE task.project_id = ? AND task.origin = ? AND report.kind = ?
            """,
            arguments: [projectId, TaskOrigin.verifySession, ReportKind.proposal]
        )
        var result: [String: String] = [:]
        for row in rows {
            let taskId: String = row["task_id"]
            if let pr = pullRequest(inReport: row["body"]) { result[taskId] = pr }
        }
        return result
    }
}
