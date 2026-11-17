import AgentBoardCore
import XCTest
@testable import AgentBoardRuntime

final class ReviewCheckoutTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-review-checkout-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try git(["config", "commit.gpgsign", "false"])
        try write(".gitignore", "CLAUDE.local.md\n*.local.json\nbuild/\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "Initial commit"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    /// SPEC §5.1: committed, untracked and gitignored review-rule files all reach the guard, except an
    /// ignored one setup left and nobody has changed since.
    func testListsCommittedUntrackedAndNewIgnoredRuleFilesButNotOnesSetupLeft() throws {
        try write(".claude/settings.local.json", "{\"from\": \"setup\"}\n")
        let baseline = try ReviewCheckout.ignoredReviewRules(in: repo)

        try git(["checkout", "-q", "-b", "task"])
        try write("pkg/CLAUDE.md", "nested rules\n")
        try git(["add", "pkg/CLAUDE.md"])
        try git(["commit", "-q", "-m", "Add nested rules"])
        try write(".claude/x", "untracked\n")
        try write("CLAUDE.local.md", "ignored, written by the worker\n")
        try write("build/out.txt", "ignored, not a rule file\n")

        XCTAssertEqual(
            try ReviewCheckout.changedFiles(against: "main", in: repo, ignoredBaseline: baseline).sorted(),
            [".claude/x", "CLAUDE.local.md", "pkg/CLAUDE.md"]
        )

        try write(".claude/settings.local.json", "{\"from\": \"worker\"}\n")
        XCTAssertTrue(
            try ReviewCheckout.changedFiles(against: "main", in: repo, ignoredBaseline: baseline)
                .contains(".claude/settings.local.json")
        )
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, cwd: repo
        )
        guard result.status == 0 else { throw AgentRuntimeError("git \(args) failed: \(result.stderr)") }
        return result.stdout
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
