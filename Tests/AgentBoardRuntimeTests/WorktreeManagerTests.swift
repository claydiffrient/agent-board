import AgentBoardCore
import XCTest
@testable import AgentBoardRuntime

final class WorktreeManagerTests: XCTestCase {
    private var sandbox: URL!
    private var repo: URL!
    private var worktrees: URL!
    private var hookSettings: URL!
    private var manager: WorktreeManager!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-wt-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = sandbox.appendingPathComponent("repo")
        worktrees = sandbox.appendingPathComponent("worktrees")
        hookSettings = sandbox.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try git(["init", "-q", "-b", "main"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: repo)
        try commit("Initial commit", cwd: repo)

        manager = WorktreeManager(repoPath: repo, worktreeRoot: worktrees, hookSettingsURL: hookSettings)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func git(_ args: [String], cwd: URL) throws -> String {
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, cwd: cwd)
        guard result.status == 0 else {
            throw AgentRuntimeError("git \(args) failed: \(result.stderr)")
        }
        return result.stdout
    }

    private func commit(_ message: String, cwd: URL) throws {
        try git(["-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false", "commit", "-q", "-m", message], cwd: cwd)
    }

    func testMoveRelocatesTheCheckoutAndGitsOwnRecordOfIt() throws {
        let path = try manager.create(name: "task-1", branch: "agentboard/task-1", base: "main")
        try "line\n".write(to: path.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: path)
        try commit("Add new file", cwd: path)
        let commit = try manager.headCommit(worktree: path)

        let destination = sandbox.appendingPathComponent("moved/task-1")
        try manager.move(worktree: path, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new.txt").path))
        let listed = try manager.list()
        XCTAssertNotNil(listed.first { WorktreeManager.samePath($0.path, destination) }, "\(listed)")
        XCTAssertNil(listed.first { WorktreeManager.samePath($0.path, path) })
        XCTAssertEqual(try manager.headCommit(worktree: destination), commit)
        XCTAssertFalse(try manager.hasUncommittedChanges(worktree: destination))
    }

    func testCreateListDiffstatAndRemove() throws {
        let path = try manager.create(name: "task-1", branch: "agentboard/task-1", base: "main")
        XCTAssertEqual(path.path, worktrees.appendingPathComponent("task-1").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("README.md").path))

        let listed = try manager.list()
        XCTAssertEqual(listed.count, 2)
        let entry = try XCTUnwrap(listed.first { WorktreeManager.samePath($0.path, path) })
        XCTAssertEqual(entry.branch, "agentboard/task-1")
        XCTAssertEqual(entry.head?.count, 40)
        XCTAssertEqual(try manager.headCommit(worktree: path), entry.head)

        XCTAssertFalse(try manager.hasUncommittedChanges(worktree: path))
        try "line\n".write(to: path.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try manager.hasUncommittedChanges(worktree: path))
        XCTAssertEqual(try manager.diffstat(worktree: path, against: "main"), "")

        try git(["add", "."], cwd: path)
        try commit("Add new file", cwd: path)
        XCTAssertFalse(try manager.hasUncommittedChanges(worktree: path))
        let stat = try manager.diffstat(worktree: path, against: "main")
        XCTAssertTrue(stat.contains("new.txt"), stat)
        XCTAssertTrue(stat.contains("1 file changed"), stat)
        XCTAssertNotEqual(try manager.headCommit(worktree: path), entry.head)

        let report = try manager.remove(path: path)
        XCTAssertEqual(report.hookDiagnostics, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try manager.list().count, 1)
        XCTAssertEqual(
            try manager.deleteBranchIfMerged("agentboard/task-1", into: ["main"]),
            .kept(branch: "agentboard/task-1", reason: "it is not merged into main")
        )
        XCTAssertTrue(try manager.branchExists("agentboard/task-1"))
    }

    func testRetryReusesExistingBranch() throws {
        let first = try manager.create(name: "attempt-1", branch: "agentboard/task-2", base: "main")
        try "wip\n".write(to: first.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: first)
        try commit("Work in progress", cwd: first)
        let wipHead = try manager.headCommit(worktree: first)
        try manager.remove(path: first)
        XCTAssertTrue(try manager.branchExists("agentboard/task-2"))

        let second = try manager.create(name: "attempt-2", branch: "agentboard/task-2", base: "main")
        XCTAssertEqual(try manager.headCommit(worktree: second), wipHead)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("wip.txt").path))
    }

    // MARK: - The ledger a reaped branch leaves behind

    func testDeletingAMergedBranchRecordsWhereItStood() throws {
        let epic = "agentboard/epic-ledger"
        try manager.ensureBranch(epic, from: "main")
        let worktree = try manager.create(name: "task-ledger", branch: "agentboard/task-ledger", base: epic)
        try "work\n".write(to: worktree.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: worktree)
        try commit("Do the work", cwd: worktree)
        let tip = try manager.headCommit(worktree: worktree)
        let epicBase = try git(["rev-parse", epic], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["branch", "-f", epic, "agentboard/task-ledger"], cwd: repo)
        try manager.remove(path: worktree)

        XCTAssertEqual(try manager.deleteBranchIfMerged("agentboard/task-ledger", into: [epic]), .deleted("agentboard/task-ledger"))

        XCTAssertFalse(try manager.branchExists("agentboard/task-ledger"))
        XCTAssertEqual(try manager.refCommit(TaskBranchLedger.baseRef(taskId: "task-ledger")), epicBase)
        XCTAssertEqual(try manager.refCommit(TaskBranchLedger.tipRef(taskId: "task-ledger")), tip)
        XCTAssertEqual(try manager.commitCount(from: epicBase, to: tip), 1)
        XCTAssertTrue(try manager.isMerged(commit: tip, into: "refs/heads/\(epic)"))
    }

    func testTheLedgerSeparatesABranchThatCarriedNothingFromOneThatDid() throws {
        let epic = "agentboard/epic-ledger"
        try manager.ensureBranch(epic, from: "main")
        let worktree = try manager.create(name: "task-silent", branch: "agentboard/task-silent", base: epic)
        try manager.remove(path: worktree)

        XCTAssertEqual(try manager.deleteBranchIfMerged("agentboard/task-silent", into: [epic]), .deleted("agentboard/task-silent"))

        let base = try XCTUnwrap(manager.refCommit(TaskBranchLedger.baseRef(taskId: "task-silent")))
        let tip = try XCTUnwrap(manager.refCommit(TaskBranchLedger.tipRef(taskId: "task-silent")))
        XCTAssertEqual(try manager.commitCount(from: base, to: tip), 0)
    }

    func testABranchOutsideTheTaskNamespaceGetsNoLedger() throws {
        try manager.ensureBranch("keep-me", from: "main")

        XCTAssertEqual(try manager.deleteBranchIfMerged("keep-me", into: ["main"]), .deleted("keep-me"))

        XCTAssertNil(try manager.refCommit(TaskBranchLedger.baseRef(taskId: "keep-me")))
        XCTAssertNil(try manager.refCommit(TaskBranchLedger.tipRef(taskId: "keep-me")))
    }

    func testEnsureBranchIsIdempotent() throws {
        XCTAssertFalse(try manager.branchExists("agentboard/epic-1"))
        try manager.ensureBranch("agentboard/epic-1", from: "main")
        XCTAssertTrue(try manager.branchExists("agentboard/epic-1"))
        try manager.ensureBranch("agentboard/epic-1", from: "main")
        XCTAssertEqual(try git(["rev-parse", "agentboard/epic-1"], cwd: repo), try git(["rev-parse", "main"], cwd: repo))
    }

    func testCreateForBranchChecksOutExistingBranch() throws {
        try manager.ensureBranch("agentboard/epic-7", from: "main")
        let before = try git(["branch", "--format=%(refname:short)"], cwd: repo)

        let path = try manager.createForBranch(name: "epic-7", branch: "agentboard/epic-7")
        XCTAssertEqual(path.path, worktrees.appendingPathComponent("epic-7").path)
        XCTAssertEqual(
            try git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path).trimmingCharacters(in: .whitespacesAndNewlines),
            "agentboard/epic-7"
        )
        XCTAssertEqual(try git(["branch", "--format=%(refname:short)"], cwd: repo), before)
    }

    func testCreateForBranchFailsForMissingBranch() {
        XCTAssertThrowsError(try manager.createForBranch(name: "epic-none", branch: "agentboard/epic-none")) { error in
            XCTAssertTrue("\(error)".contains("agentboard/epic-none"), "\(error)")
        }
    }

    func testMergeStatusReportsMergedUnmergedAndMissingBranches() throws {
        try manager.ensureBranch("agentboard/epic-8", from: "main")

        let merged = try manager.create(name: "merged", branch: "agentboard/task-merged", base: "main")
        try "merged\n".write(to: merged.appendingPathComponent("merged.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: merged)
        try commit("Add merged work", cwd: merged)

        let unmerged = try manager.create(name: "unmerged", branch: "agentboard/task-unmerged", base: "main")
        try "unmerged\n".write(to: unmerged.appendingPathComponent("unmerged.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: unmerged)
        try commit("Add unmerged work", cwd: unmerged)

        let epic = try manager.createForBranch(name: "epic-8", branch: "agentboard/epic-8")
        try git(["-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false", "merge", "--no-ff", "-q", "-m", "Merge task", "agentboard/task-merged"], cwd: epic)

        let status = try manager.mergeStatus(
            worktree: epic,
            branches: ["agentboard/task-merged", "agentboard/task-unmerged", "agentboard/task-ghost"]
        )
        XCTAssertEqual(status, [
            "agentboard/task-merged": true,
            "agentboard/task-unmerged": false,
            "agentboard/task-ghost": false,
        ])
    }

    // MARK: - mergeIntoEpic

    func testMergeIntoEpicFastForwardsWithoutAWorktree() throws {
        try manager.ensureBranch("agentboard/epic-1", from: "main")
        let work = try manager.create(name: "task", branch: "agentboard/task", base: "agentboard/epic-1")
        try addCommit("feature.txt", in: work)
        let taskHead = try manager.headCommit(worktree: work)
        try manager.remove(path: work)

        let outcome = try manager.mergeIntoEpic(
            taskBranch: "agentboard/task", epicBranch: "agentboard/epic-1", worktreeName: "merge"
        )

        XCTAssertEqual(outcome, .fastForwarded(head: taskHead))
        XCTAssertEqual(try revParse("agentboard/epic-1"), taskHead)
        XCTAssertEqual(try manager.list().count, 1, "a fast-forward should not have cut a worktree")
    }

    func testMergeIntoEpicUsesATemporaryWorktreeAndKeepsTheBranch() throws {
        try manager.ensureBranch("agentboard/epic-1", from: "main")
        let work = try manager.create(name: "task", branch: "agentboard/task", base: "agentboard/epic-1")
        try addCommit("feature.txt", in: work)
        try manager.remove(path: work)
        let sibling = try manager.create(name: "sibling", branch: "agentboard/epic-1-side", base: "agentboard/epic-1")
        try addCommit("sibling.txt", in: sibling)
        try git(["branch", "-f", "agentboard/epic-1", "agentboard/epic-1-side"], cwd: repo)
        try manager.remove(path: sibling)
        let epicBefore = try revParse("agentboard/epic-1")

        let outcome = try manager.mergeIntoEpic(
            taskBranch: "agentboard/task", epicBranch: "agentboard/epic-1", worktreeName: "merge"
        )

        guard case .merged(let head) = outcome else { return XCTFail("expected a merge, got \(outcome)") }
        XCTAssertEqual(try revParse("agentboard/epic-1"), head)
        XCTAssertNotEqual(head, epicBefore)
        XCTAssertTrue(try manager.branchExists("agentboard/epic-1"))
        XCTAssertEqual(try manager.list().count, 1, "the temporary merge worktree was left behind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktrees.appendingPathComponent("merge").path))
    }

    func testMergeIntoEpicAbortsAndNamesConflictingFiles() throws {
        try manager.ensureBranch("agentboard/epic-1", from: "main")
        let work = try manager.create(name: "task", branch: "agentboard/task", base: "agentboard/epic-1")
        try addCommit("schema.sql", in: work, contents: "task side\n")
        try manager.remove(path: work)
        let sibling = try manager.create(name: "sibling", branch: "agentboard/epic-1-side", base: "agentboard/epic-1")
        try addCommit("schema.sql", in: sibling, contents: "epic side\n")
        try git(["branch", "-f", "agentboard/epic-1", "agentboard/epic-1-side"], cwd: repo)
        try manager.remove(path: sibling)
        let epicBefore = try revParse("agentboard/epic-1")

        let outcome = try manager.mergeIntoEpic(
            taskBranch: "agentboard/task", epicBranch: "agentboard/epic-1", worktreeName: "merge"
        )

        XCTAssertEqual(outcome, .conflicted(files: ["schema.sql"]))
        XCTAssertEqual(try revParse("agentboard/epic-1"), epicBefore, "a conflict moved the epic branch")
        XCTAssertTrue(try manager.branchExists("agentboard/epic-1"))
        XCTAssertEqual(try manager.list().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktrees.appendingPathComponent("merge").path))
    }

    func testMergeIntoEpicIsANoOpForAnAlreadyMergedBranch() throws {
        let work = try manager.create(name: "task", branch: "agentboard/task", base: "main")
        try addCommit("feature.txt", in: work)
        try manager.remove(path: work)
        try git(["branch", "agentboard/epic-1", "agentboard/task"], cwd: repo)
        let epicBefore = try revParse("agentboard/epic-1")

        XCTAssertEqual(
            try manager.mergeIntoEpic(
                taskBranch: "agentboard/task", epicBranch: "agentboard/epic-1", worktreeName: "merge"
            ),
            .alreadyMerged
        )
        XCTAssertEqual(try revParse("agentboard/epic-1"), epicBefore)
    }

    func testMergeIntoEpicReportsAMissingTaskBranchAndACheckedOutEpicBranch() throws {
        try manager.ensureBranch("agentboard/epic-1", from: "main")
        XCTAssertEqual(
            try manager.mergeIntoEpic(
                taskBranch: "agentboard/never-ran", epicBranch: "agentboard/epic-1", worktreeName: "merge"
            ),
            .nothingToMerge
        )

        let work = try manager.create(name: "task", branch: "agentboard/task", base: "agentboard/epic-1")
        try addCommit("feature.txt", in: work)
        try manager.remove(path: work)
        let integration = try manager.createForBranch(name: "epic-1", branch: "agentboard/epic-1")

        let outcome = try manager.mergeIntoEpic(
            taskBranch: "agentboard/task", epicBranch: "agentboard/epic-1", worktreeName: "merge"
        )
        guard case .skippedCheckedOut(let path) = outcome else {
            return XCTFail("expected the merge to defer to the checkout, got \(outcome)")
        }
        XCTAssertTrue(WorktreeManager.samePath(URL(fileURLWithPath: path), integration), path)
    }

    func testMergeIntoEpicRefusesAMissingEpicBranch() throws {
        let work = try manager.create(name: "task", branch: "agentboard/task", base: "main")
        try addCommit("feature.txt", in: work)
        try manager.remove(path: work)

        XCTAssertThrowsError(
            try manager.mergeIntoEpic(
                taskBranch: "agentboard/task", epicBranch: "agentboard/epic-missing", worktreeName: "merge"
            )
        )
    }

    private func addCommit(_ file: String, in worktree: URL, contents: String = "work\n") throws {
        try contents.write(to: worktree.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", "."], cwd: worktree)
        try commit("Add \(file)", cwd: worktree)
    }

    private func revParse(_ ref: String) throws -> String {
        try git(["rev-parse", "--verify", ref], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testCreateFailsForMissingBase() {
        XCTAssertThrowsError(try manager.create(name: "x", branch: "agentboard/x", base: "no-such-branch"))
    }

    func testParsePorcelain() {
        let output = """
        worktree /repo
        HEAD 0123456789abcdef0123456789abcdef01234567
        branch refs/heads/main

        worktree /repo/.claude/worktrees/t1
        HEAD fedcba9876543210fedcba9876543210fedcba98
        branch refs/heads/agentboard/t1
        locked

        worktree /repo/detached
        HEAD 1111111111111111111111111111111111111111
        detached

        """
        let infos = WorktreeManager.parsePorcelain(output)
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(infos[0].branch, "main")
        XCTAssertEqual(infos[1].path.path, "/repo/.claude/worktrees/t1")
        XCTAssertEqual(infos[1].branch, "agentboard/t1")
        XCTAssertTrue(infos[2].isDetached)
        XCTAssertNil(infos[2].branch)
    }

    func testWorktreeRemoveHooksReceivePayloadAndFailuresAreCollected() throws {
        let capture = sandbox.appendingPathComponent("hook-stdin.json")
        let settings: [String: Any] = [
            "hooks": [
                "WorktreeRemove": [
                    ["hooks": [
                        ["type": "command", "command": "cat > '\(capture.path)'"],
                        ["type": "http", "url": "http://127.0.0.1:1/ignored"],
                        ["type": "command", "command": "echo boom >&2; exit 3"],
                    ]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: hookSettings)

        XCTAssertEqual(WorktreeManager.worktreeRemoveHooks(settingsAt: hookSettings).map(\.command), ["cat > '\(capture.path)'", "echo boom >&2; exit 3"])

        let path = try manager.create(name: "hooked", branch: "agentboard/hooked", base: "main")
        let report = try manager.remove(path: path)

        XCTAssertEqual(report.hookDiagnostics.count, 1)
        XCTAssertTrue(report.hookDiagnostics[0].contains("exited 3"))
        XCTAssertTrue(report.hookDiagnostics[0].contains("boom"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: String])
        XCTAssertEqual(payload["hook_event_name"], "WorktreeRemove")
        XCTAssertEqual(payload["worktree_path"], path.path)
        XCTAssertEqual(payload["cwd"], repo.path)
    }

    func testMissingHookSettingsRunsNoHooks() throws {
        XCTAssertEqual(WorktreeManager.worktreeRemoveHooks(settingsAt: sandbox.appendingPathComponent("nope.json")), [])
        let path = try manager.create(name: "plain", branch: "agentboard/plain", base: "main")
        XCTAssertEqual(try manager.remove(path: path).hookDiagnostics, [])
    }

    /// The whole mechanism end to end: `git worktree add` fires the repository's `post-checkout`
    /// hook, the hook's setup interpolates the new worktree path into a shell command unquoted, and
    /// git exits with the hook's status.
    func testAPostCheckoutSetupThatSplitsTheWorktreePathIsExplained() throws {
        try installPostCheckoutSetup("""
        /bin/sh $1/scripts/preinstall.sh
        echo "setup: build step 2"
        exit 1
        """)
        let spaced = WorktreeManager(
            repoPath: repo,
            worktreeRoot: sandbox.appendingPathComponent("Agent Board/worktrees"),
            hookSettingsURL: hookSettings
        )

        let error = try XCTUnwrapError {
            _ = try spaced.create(name: "task-1", branch: "agentboard/task-1", base: "main")
        }

        let message = String(describing: error)
        let headline = try XCTUnwrap(message.split(separator: "\n", omittingEmptySubsequences: false).first)
        XCTAssertTrue(headline.contains("a space"), message)
        XCTAssertTrue(headline.contains(sandbox.appendingPathComponent("Agent").path), message)
        XCTAssertTrue(message.contains("setup: build step 2"), "the hook's own output must survive: \(message)")
        XCTAssertTrue(message.contains("No such file or directory"), message)
    }

    func testAPostCheckoutSetupThatFailsForAnotherReasonIsNotExplained() throws {
        try installPostCheckoutSetup("""
        echo "setup: no such target //:lint-staged" >&2
        exit 1
        """)
        let spaced = WorktreeManager(
            repoPath: repo,
            worktreeRoot: sandbox.appendingPathComponent("Agent Board/worktrees"),
            hookSettingsURL: hookSettings
        )

        let error = try XCTUnwrapError {
            _ = try spaced.create(name: "task-1", branch: "agentboard/task-1", base: "main")
        }

        let message = String(describing: error)
        XCTAssertTrue(message.hasPrefix("git worktree add "), message)
        XCTAssertTrue(message.contains("no such target //:lint-staged"), message)
    }

    private func installPostCheckoutSetup(_ body: String) throws {
        let hooks = repo.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("post-checkout")
        try """
        #!/bin/sh
        [ "$3" = "1" ] || exit 0
        cd "$(git rev-parse --show-toplevel)"
        set -- "$PWD"
        \(body)
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    private func XCTUnwrapError(_ body: () throws -> Void) throws -> Error {
        do {
            try body()
        } catch {
            return error
        }
        throw AgentRuntimeError("expected the worktree creation to fail")
    }

    func testExpandTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(WorktreeManager.expandTilde("~/bin/hook.sh --flag"), "\(home)/bin/hook.sh --flag")
        XCTAssertEqual(WorktreeManager.expandTilde("echo ~"), "echo ~")
        XCTAssertEqual(WorktreeManager.expandTilde("~user/x"), "~user/x")
    }
}
