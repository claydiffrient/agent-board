import AgentBoardCore
@testable import AgentBoardRuntime
import Foundation
import XCTest

final class TakeoverAcknowledgerTests: XCTestCase {
    private let settings = TakeoverSettings(
        enabled: true, assignee: "example-user", triggerLabels: ["handoff-example"], ackLabel: "taken-example",
        ackComment: "{assignee} took this {kind}: {url}"
    )
    private let cwd = URL(fileURLWithPath: "/nonexistent")
    private let repository = "example-org/app"

    func testTheLabelGoesOnBeforeAcknowledgedIsRecordedAndTheCommentFollowsOnlyAfterBoth() throws {
        let (store, projectId) = try fixture()
        let pr = try record(store, projectId, kind: .pr, number: 9)
        var stateAtComment: TakeoverState?
        let gh = ScriptedGh { arguments in
            switch Array(arguments.prefix(2)) {
            case ["label", "list"]: return .ok(#"[{"name":"Taken-Example"}]"#)
            case ["pr", "edit"]: return .ok("")
            case ["pr", "comment"]:
                stateAtComment = try store.get(pr.id)?.state
                return .failed("HTTP 502")
            default: return .failed("unexpected")
            }
        }
        let acknowledger = TakeoverAcknowledger(gh: gh)

        let outcome = try acknowledger.acknowledge(
            pr, settings: settings, repository: repository, labelConfirmed: false, store: store, cwd: cwd
        )

        XCTAssertEqual(gh.calls.map { Array($0.prefix(2)) }, [["label", "list"], ["pr", "edit"], ["pr", "comment"]])
        XCTAssertEqual(gh.calls[1], ["pr", "edit", pr.url, "--add-label", "taken-example"])
        XCTAssertEqual(gh.calls[2].last, "example-user took this pull request: \(pr.url)")
        XCTAssertEqual(stateAtComment, .acknowledged, "the comment posts only after acknowledged is recorded")
        let after = try XCTUnwrap(store.get(pr.id))
        XCTAssertEqual(after.state, .acknowledged, "a failed comment keeps the label's state")
        XCTAssertNotNil(after.failure)
        guard case .commentFailed = outcome else { return XCTFail("got \(outcome)") }

        _ = try acknowledger.acknowledge(
            after, settings: settings, repository: repository, labelConfirmed: true, store: store, cwd: cwd
        )
        XCTAssertEqual(gh.calls.count, 3, "a retry never re-adds the label")

        let issue = try record(store, projectId, kind: .issue, number: 7)
        let failing = ScriptedGh { arguments in
            arguments.prefix(2) == ["issue", "edit"] ? .failed("HTTP 502: Server Error") : .ok("")
        }
        XCTAssertThrowsError(try TakeoverAcknowledger(gh: failing).acknowledge(
            issue, settings: settings, repository: repository, labelConfirmed: true, store: store, cwd: cwd
        ))
        XCTAssertEqual(failing.calls.map { Array($0.prefix(2)) }, [["issue", "edit"]], "no comment after a failed label")
        XCTAssertEqual(try store.get(issue.id)?.state, .found)
        XCTAssertNil(try store.get(issue.id)?.failure)
    }

    func testAPullRequestTakenOverThroughItsIssueIsAcknowledgedOnTheIssueAlone() throws {
        let (store, projectId) = try fixture()
        let issueURL = "https://github.com/example-org/app/issues/4"
        let pr = try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
            githubNodeId: "PR_lone", kind: .pr, number: 40, url: "https://github.com/example-org/app/pull/40",
            title: "Fix", author: "example-author", issueNodeId: "I_one", issueURL: issueURL, viaIssue: true
        )))
        let gh = ScriptedGh { _ in .ok("") }

        _ = try TakeoverAcknowledger(gh: gh).acknowledge(
            pr, settings: settings, repository: repository, labelConfirmed: true, store: store, cwd: cwd
        )

        XCTAssertEqual(gh.calls, [
            ["issue", "edit", issueURL, "--add-label", "taken-example"],
            ["issue", "comment", issueURL, "--body", "example-user took this issue: \(issueURL)"],
        ])
    }

    func testAMissingLabelIsAProblemAndNothingIsEdited() throws {
        let (store, projectId) = try fixture()
        let issue = try record(store, projectId, kind: .issue, number: 7)
        let gh = ScriptedGh { arguments in
            arguments.prefix(2) == ["label", "list"] ? .ok(#"[{"name":"taken-example-old"}]"#) : .ok("")
        }

        let outcome = try TakeoverAcknowledger(gh: gh).acknowledge(
            issue, settings: settings, repository: repository, labelConfirmed: false, store: store, cwd: cwd
        )

        guard case .labelMissing(let problem) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(problem.contains("taken-example"))
        XCTAssertTrue(problem.contains("Create it"))
        XCTAssertEqual(gh.calls, [TakeoverAcknowledger.labelListArguments(label: "taken-example", repository: repository)])
        XCTAssertEqual(try store.get(issue.id)?.state, .found)
    }

    private func fixture() throws -> (TakeoverStore, String) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Example", repoPath: "/example", baseBranch: "main", worktreeRoot: "/w", memoryDir: nil
        )
        return (TakeoverStore(db), project.id)
    }

    private func record(_ store: TakeoverStore, _ projectId: String, kind: TakeoverKind, number: Int) throws -> Takeover {
        let path = kind == .pr ? "pull" : "issues"
        return try XCTUnwrap(store.record(projectId: projectId, TakeoverCandidate(
            githubNodeId: "N_\(number)", kind: kind, number: number,
            url: "https://github.com/example-org/app/\(path)/\(number)", title: "Item \(number)", author: "example-author"
        )))
    }
}

private extension CommandResult {
    static func ok(_ stdout: String) -> CommandResult { CommandResult(status: 0, stdout: stdout, stderr: "") }
    static func failed(_ stderr: String) -> CommandResult { CommandResult(status: 1, stdout: "", stderr: stderr) }
}

/// `gh` that records every call and answers each from `respond`.
private final class ScriptedGh: GhRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let respond: ([String]) throws -> CommandResult

    init(_ respond: @escaping ([String]) throws -> CommandResult) {
        self.respond = respond
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], cwd: URL) throws -> CommandResult {
        lock.withLock { recorded.append(arguments) }
        return try respond(arguments)
    }
}
