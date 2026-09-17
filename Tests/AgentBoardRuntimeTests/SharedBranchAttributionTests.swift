import AgentBoardCore
import XCTest
@testable import AgentBoardRuntime

/// Two tasks committing alternately into one checkout on one branch, against a real git repository.
/// Everything here is the thing acceptance reads: whose commit is whose, and what is in it.
final class SharedBranchAttributionTests: XCTestCase {
    private var sandbox: URL!
    private var repo: URL!
    private var manager: WorktreeManager!
    private var runner: ScopedCommitRunner!
    private var ledger: TaskCommitStore!

    private let branch = "agentboard/shared-epic-demo"
    private let alpha = "11111111-1111-1111-1111-111111111111"
    private let beta = "22222222-2222-2222-2222-222222222222"
    private let gamma = "33333333-3333-3333-3333-333333333333"

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-shared-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try git(["config", "commit.gpgsign", "false"])
        try write("README.md", "hello\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "Initial commit"])
        try git(["checkout", "-q", "-b", branch])

        ledger = TaskCommitStore(try AppDatabase.inMemory())
        manager = WorktreeManager(
            repoPath: repo, worktreeRoot: sandbox.appendingPathComponent("wt"), commitLedger: ledger
        )
        runner = ScopedCommitRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mirrors `commit_my_work`: the runner commits the body verbatim and the ledger row is written
    /// in the same step, which is what makes the commit attributable at all.
    @discardableResult
    private func commit(task: String, paths: [String], message: String) async throws -> ScopedCommitOutcome {
        let outcome = try await runner.commit(
            ScopedCommitRequest(
                repoPath: repo.path, branch: branch, taskId: task, paths: paths, message: message
            )
        )
        if case .committed(let sha, _) = outcome { try ledger.record(taskId: task, sha: sha) }
        return outcome
    }

    private func filesIn(_ sha: String) throws -> [String] {
        try git(["show", "--name-only", "--format=", sha])
            .split(separator: "\n").map(String.init).sorted()
    }

    /// The headline case: alternating commits, each holding only its own task's paths.
    func testTwoTasksCommittingAlternatelyKeepTheirCommitsToTheirOwnFiles() async throws {
        try write("alpha/one.txt", "a1\n")
        guard case .committed(let a1, _) = try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")
        else { return XCTFail("alpha's first commit did not land") }

        try write("beta/one.txt", "b1\n")
        guard case .committed(let b1, _) = try await commit(task: beta, paths: ["beta/one.txt"], message: "Add beta one")
        else { return XCTFail("beta's first commit did not land") }

        try write("alpha/two.txt", "a2\n")
        try write("alpha/one.txt", "a1 revised\n")
        guard case .committed(let a2, _) = try await commit(
            task: alpha, paths: ["alpha/one.txt", "alpha/two.txt"], message: "Revise alpha"
        ) else { return XCTFail("alpha's second commit did not land") }

        try write("beta/two.txt", "b2\n")
        guard case .committed(let b2, _) = try await commit(task: beta, paths: ["beta/two.txt"], message: "Add beta two")
        else { return XCTFail("beta's second commit did not land") }

        XCTAssertEqual(try filesIn(a1), ["alpha/one.txt"])
        XCTAssertEqual(try filesIn(a2), ["alpha/one.txt", "alpha/two.txt"])
        XCTAssertEqual(try filesIn(b1), ["beta/one.txt"])
        XCTAssertEqual(try filesIn(b2), ["beta/two.txt"])

        let attributed = try manager.attributedCommits(on: branch, since: "main")
        XCTAssertEqual(attributed.map(\.sha), [b2, a2, b1, a1])
        XCTAssertEqual(attributed.map(\.taskId), [beta, alpha, beta, alpha])

        XCTAssertEqual(try manager.commits(taskId: alpha, on: branch, since: "main"), [a2, a1])
        XCTAssertEqual(try manager.commits(taskId: beta, on: branch, since: "main"), [b2, b1])
    }

    /// The failure this whole task exists to prevent: a sibling mid-edit when someone else commits.
    func testASiblingsUncommittedEditsAreNeverSweptIntoAnotherTasksCommit() async throws {
        try write("alpha/one.txt", "a1\n")
        try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")
        try write("beta/one.txt", "b1\n")
        try await commit(task: beta, paths: ["beta/one.txt"], message: "Add beta one")

        // Beta is mid-task: one tracked file modified, one new file not yet known to git, and — the
        // nastiest shape — one of them already staged, which is what `git commit` without a pathspec
        // would pick up.
        try write("beta/one.txt", "b1 in progress\n")
        try write("beta/scratch.txt", "not ready\n")
        try git(["add", "beta/scratch.txt"])

        try write("alpha/one.txt", "a1 revised\n")
        guard case .committed(let sha, let paths) = try await commit(
            task: alpha, paths: ["alpha/one.txt"], message: "Revise alpha"
        ) else { return XCTFail("alpha's commit did not land") }

        XCTAssertEqual(paths, ["alpha/one.txt"])
        XCTAssertEqual(try filesIn(sha), ["alpha/one.txt"])

        // Beta's work is still exactly where beta left it, uncommitted.
        let status = try git(["status", "--porcelain"])
        XCTAssertTrue(status.contains("beta/one.txt"), status)
        XCTAssertTrue(status.contains("beta/scratch.txt"), status)
        XCTAssertEqual(
            try String(contentsOf: repo.appendingPathComponent("beta/one.txt"), encoding: .utf8),
            "b1 in progress\n"
        )
    }

    /// Attribution must not reach the commit object: on a work repository a task-id trailer is
    /// permanent and public in whatever repository the pull request lands in.
    func testTheCommitMessageIsExactlyTheBodyTheAgentGaveAndNamesNoTask() async throws {
        try write("alpha/one.txt", "a1\n")
        let body = "Add alpha one\n\nA second paragraph the agent wrote."
        guard case .committed(let sha, _) = try await commit(task: alpha, paths: ["alpha/one.txt"], message: body)
        else { return XCTFail("no commit") }

        let message = try git(["log", "-1", "--format=%B", sha])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(message, body)
        XCTAssertFalse(message.contains(alpha), message)
        XCTAssertFalse(message.contains("Agent-Board-Task"), message)

        XCTAssertEqual(try ledger.shas(taskId: alpha), [sha])
        XCTAssertEqual(
            try manager.attributedCommits(on: branch, since: "main"),
            [AttributedCommit(sha: sha, taskId: alpha)]
        )
    }

    /// A commit nothing recorded is nobody's work: it is dropped from every task's diff rather than
    /// falling into one of them.
    func testACommitWithNoLedgerRowBelongsToNoTask() async throws {
        try write("alpha/one.txt", "a1\n")
        guard case .committed(let mine, _) = try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")
        else { return XCTFail("no commit") }

        try write("human.txt", "by hand\n")
        try git(["add", "human.txt"])
        try git(["commit", "-q", "-m", "A hand-made commit"])
        let byHand = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(
            try manager.attributedCommits(on: branch, since: "main"),
            [AttributedCommit(sha: byHand, taskId: nil), AttributedCommit(sha: mine, taskId: alpha)]
        )
        XCTAssertEqual(try manager.commits(taskId: alpha, on: branch, since: "main"), [mine])
        XCTAssertFalse(try manager.diffstat(taskId: alpha, on: branch, since: "main").contains("human.txt"))
    }

    /// With no ledger at all, every commit reads as nobody's — never as somebody's guess.
    func testAManagerWithNoLedgerAttributesNothing() async throws {
        try write("alpha/one.txt", "a1\n")
        try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")

        let blind = WorktreeManager(repoPath: repo, worktreeRoot: sandbox.appendingPathComponent("wt"))
        let attributed = try blind.attributedCommits(on: branch, since: "main")
        XCTAssertEqual(attributed.count, 1)
        XCTAssertNil(attributed[0].taskId)
        XCTAssertEqual(try blind.commits(taskId: alpha, on: branch, since: "main"), [])
    }

    /// Branches committed before the ledger existed carry the old trailer. Reading it back once is
    /// what keeps their per-task diffs working; no commit is rewritten and none gains a trailer.
    func testTrailersOnPreLedgerCommitsAreReadBackIntoTheLedger() async throws {
        try write("alpha/one.txt", "a1\n")
        try git(["add", "alpha/one.txt"])
        try git(["commit", "-q", "-m", "Add alpha one\n\nAgent-Board-Task: \(alpha)"])
        let old = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        try write("beta/one.txt", "b1\n")
        guard case .committed(let new, _) = try await commit(task: beta, paths: ["beta/one.txt"], message: "Add beta one")
        else { return XCTFail("no commit") }

        XCTAssertNil(try manager.attributedCommits(on: branch, since: "main").last?.taskId)

        XCTAssertEqual(try manager.backfillFromTrailers(on: branch, since: "main"), 1)
        XCTAssertEqual(
            try manager.attributedCommits(on: branch, since: "main"),
            [AttributedCommit(sha: new, taskId: beta), AttributedCommit(sha: old, taskId: alpha)]
        )

        // Idempotent: a second pass finds nothing left to add.
        XCTAssertEqual(try manager.backfillFromTrailers(on: branch, since: "main"), 0)
        XCTAssertEqual(try ledger.shas(taskId: alpha), [old])
    }

    func testAPerTaskDiffShowsOnlyThatTasksCommits() async throws {
        try write("alpha/one.txt", "a\nb\nc\n")
        try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")
        try write("beta/one.txt", "1\n2\n3\n4\n5\n")
        try await commit(task: beta, paths: ["beta/one.txt"], message: "Add beta one")
        try write("alpha/one.txt", "a\nb\nc\nd\n")
        try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Extend alpha")

        let alphaStat = try manager.diffstat(taskId: alpha, on: branch, since: "main")
        XCTAssertTrue(alphaStat.contains("alpha/one.txt"), alphaStat)
        XCTAssertFalse(alphaStat.contains("beta/one.txt"), alphaStat)
        XCTAssertTrue(alphaStat.contains("1 file changed"), alphaStat)

        let betaStat = try manager.diffstat(taskId: beta, on: branch, since: "main")
        XCTAssertTrue(betaStat.contains("beta/one.txt"), betaStat)
        XCTAssertFalse(betaStat.contains("alpha/one.txt"), betaStat)

        // alpha's two commits touch one file, so it is one changed file with both commits' lines.
        XCTAssertEqual(
            try manager.diffSummary(taskId: alpha, on: branch, since: "main"),
            DiffSummary(filesChanged: 1, insertions: 4, deletions: 0)
        )
        XCTAssertEqual(
            try manager.diffSummary(taskId: beta, on: branch, since: "main"),
            DiffSummary(filesChanged: 1, insertions: 5, deletions: 0)
        )
    }

    /// A task that has committed nothing must read as empty, not as whatever its siblings did.
    func testATaskWithNoCommitsReadsAsEmptyRatherThanItsSiblingsWork() async throws {
        try write("alpha/one.txt", "a\n")
        try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")
        try write("beta/one.txt", "b\n")
        try await commit(task: beta, paths: ["beta/one.txt"], message: "Add beta one")

        XCTAssertEqual(try manager.commits(taskId: gamma, on: branch, since: "main"), [])
        XCTAssertEqual(try manager.diffstat(taskId: gamma, on: branch, since: "main"), "")
        XCTAssertEqual(try manager.diffSummary(taskId: gamma, on: branch, since: "main"), DiffSummary())
        XCTAssertTrue(try manager.diffSummary(taskId: gamma, on: branch, since: "main").isEmpty)
    }

    func testADeletionIsCommittedAsADeletionAndStaysScoped() async throws {
        try write("alpha/one.txt", "a\n")
        try write("alpha/gone.txt", "temporary\n")
        try await commit(task: alpha, paths: ["alpha/one.txt", "alpha/gone.txt"], message: "Add alpha")
        try write("beta/one.txt", "b\n")
        try await commit(task: beta, paths: ["beta/one.txt"], message: "Add beta")

        try FileManager.default.removeItem(at: repo.appendingPathComponent("alpha/gone.txt"))
        guard case .committed(let sha, _) = try await commit(
            task: alpha, paths: ["alpha/one.txt", "alpha/gone.txt"], message: "Drop the temporary file"
        ) else { return XCTFail("the deletion did not commit") }

        XCTAssertEqual(try filesIn(sha), ["alpha/gone.txt"])
        XCTAssertEqual(
            try manager.diffSummary(taskId: alpha, on: branch, since: "main"),
            DiffSummary(filesChanged: 2, insertions: 2, deletions: 1)
        )
    }

    func testClaimedPathsWithNothingToRecordCommitNothingRatherThanFailing() async throws {
        try write("alpha/one.txt", "a\n")
        try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Add alpha one")

        let outcome = try await commit(task: alpha, paths: ["alpha/one.txt"], message: "Nothing changed")
        guard case .nothingToCommit = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try manager.commits(taskId: alpha, on: branch, since: "main").count, 1)
    }

    /// A lock taken for a write that never landed names a path git has never heard of; it must not
    /// take the whole commit down with it.
    func testAClaimedPathThatWasNeverWrittenDoesNotFailTheCommit() async throws {
        try write("alpha/one.txt", "a\n")
        guard case .committed(let sha, let paths) = try await commit(
            task: alpha, paths: ["alpha/never.txt", "alpha/one.txt"], message: "Add alpha one"
        ) else { return XCTFail("the commit did not land") }
        XCTAssertEqual(paths, ["alpha/one.txt"])
        XCTAssertEqual(try filesIn(sha), ["alpha/one.txt"])
    }

    func testNoPathsAtAllIsRefusedRatherThanCommittingTheTree() async throws {
        try write("beta/one.txt", "b\n")
        do {
            _ = try await commit(task: alpha, paths: [], message: "Sweep the tree")
            XCTFail("an empty pathspec was accepted")
        } catch let error as ScopedCommitError {
            XCTAssertEqual(error, .noPathsHeld)
        }
        XCTAssertEqual(try manager.attributedCommits(on: branch, since: "main"), [])
    }
}
