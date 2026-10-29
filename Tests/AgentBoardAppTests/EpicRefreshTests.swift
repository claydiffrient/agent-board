import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5.2: `refresh_epic` merges the base branch into an epic branch on request, verified before
/// the branch moves, and `get_epic` reports how far the two have drifted.
@MainActor
final class EpicRefreshTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var epic: Epic!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        epic = try EpicStore(fixture.db).create(projectId: fixture.project.id, title: "Roster", goal: nil)
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    func testARefreshPutsTheBasesNewCommitsOnTheEpicBranchOnceItsBuildAndTestsPass() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("epic\n", to: "from-epic.txt", on: epic.branch)
        try commit("main\n", to: "from-main.txt", on: "main")
        try setCommands(build: "test -f from-main.txt && test -f from-epic.txt", test: "true")
        let epicBefore = try head(epic.branch)
        let mainHead = try head("main")

        let text = try await refreshReport()

        XCTAssertTrue(try isAncestor(mainHead, of: epic.branch), "the base's commit is not on the epic branch")
        XCTAssertTrue(try isAncestor(epicBefore, of: epic.branch), "the epic's own commit was lost")
        XCTAssertTrue(text.contains("`test -f from-main.txt && test -f from-epic.txt` passed, then `true` passed"), text)
        XCTAssertFalse(text.contains("NOT VERIFIED"), text)
        XCTAssertEqual(try worktreeCount(), 1, "the scratch checkout the build ran in survived")
    }

    func testARefreshWithNoConfiguredCommandsSaysItVerifiedNothing() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("epic\n", to: "from-epic.txt", on: epic.branch)
        try commit("main\n", to: "from-main.txt", on: "main")
        let epicBefore = try head(epic.branch)

        let text = try await refresh().text

        XCTAssertTrue(try isAncestor(try head("main"), of: epic.branch))
        XCTAssertTrue(text.contains("NOT VERIFIED: this project configures no build or test command"), text)
        XCTAssertTrue(text.contains(String(epicBefore.prefix(12))), "the answer does not say where the branch was: \(text)")
        XCTAssertFalse(text.contains("passed"), text)
    }

    func testARefreshUnderCIVerifiesRunsTheBuildAndLeavesTheTestsToCI() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        try setCommands(build: "test -f from-main.txt", test: "exit 7", integration: .ciVerifies)

        let started = try await refresh().text
        XCTAssertFalse(started.contains("exit 7"), "the refresh says it will run the tests: \(started)")
        let report = try await awaitRefreshReport()

        XCTAssertTrue(try isAncestor(try head("main"), of: epic.branch), "the tests ran and failed the refresh: \(report)")
        XCTAssertTrue(report.contains("`test -f from-main.txt` passed"), report)
        XCTAssertTrue(report.contains("No tests ran"), report)
    }

    func testARefreshUnderBuildOnlyWithNoBuildCommandRunsNothingAndSaysSo() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        try setCommands(build: nil, test: "true", integration: .buildOnly)

        let text = try await refresh().text

        XCTAssertTrue(text.contains("NOT VERIFIED: this project configures no build command"), text)
        XCTAssertTrue(text.contains("No tests ran"), text)
        XCTAssertFalse(text.contains("passed"), text)
    }

    func testAConflictingRefreshLeavesTheEpicBranchAsItWasAndNamesTheFiles() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("epic side\n", to: "schema.sql", on: epic.branch)
        try commit("main side\n", to: "schema.sql", on: "main")
        try setCommands(build: "true", test: "true")
        let epicBefore = try head(epic.branch)

        let message = try await refusal()

        XCTAssertEqual(try head(epic.branch), epicBefore, "a conflicting refresh moved the epic branch")
        XCTAssertTrue(message.contains("conflicts in 1 file(s): schema.sql"), message)
        XCTAssertTrue(message.contains("human's call"), message)
        XCTAssertEqual(try worktreeCount(), 1)
    }

    func testARefreshThatMergesCleanlyButFailsToBuildIsAFailureAndLeavesTheBranchAlone() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("epic\n", to: "from-epic.txt", on: epic.branch)
        try commit("main\n", to: "from-main.txt", on: "main")
        try setCommands(build: "test -f from-main.txt || exit 9; echo 'error: no member named foo'; exit 3", test: "true")
        let epicBefore = try head(epic.branch)

        let message = try await refreshReport()

        XCTAssertEqual(try head(epic.branch), epicBefore, "a refresh that failed to build moved the epic branch")
        XCTAssertTrue(message.contains("exited 3"), "the build did not run on the merge result: \(message)")
        XCTAssertTrue(message.contains("was not moved"), message)
        XCTAssertTrue(message.contains("error: no member named foo"), message)
        XCTAssertFalse(message.contains("`true` passed"), "the tests ran after the build failed: \(message)")
        XCTAssertEqual(try worktreeCount(), 1, "the scratch checkout the build ran in survived")
    }

    /// `BoundedCommandTests` covers the process-group kill itself; this covers what `refresh_epic`
    /// does around it — the settings floor at `VerificationCommands.timeoutRange` (60s) means a real
    /// project can't reach this through settings, so the test drives it through
    /// `refreshCheckTimeoutOverride` instead.
    func testARefreshWhoseBuildTimesOutLeavesTheBranchAloneAndCleansUpTheScratchCheckout() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        try setCommands(build: "sleep 60", test: "true")
        fixture.supervisor.refreshCheckTimeoutOverride = 1
        let epicBefore = try head(epic.branch)

        let message = try await refreshReport()

        XCTAssertTrue(message.contains("timed out after 1s"), message)
        XCTAssertEqual(try head(epic.branch), epicBefore, "a refresh whose build timed out moved the epic branch")
        XCTAssertEqual(try worktreeCount(), 1, "the scratch checkout the build ran in survived")
    }

    func testASecondRefreshOfTheSameEpicIsRefusedWhileTheFirstBuildsAndTheFirstStillPasses() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        try setCommands(build: "sleep 2; test -f from-main.txt", test: "true")

        let first = try await refresh().text
        XCTAssertTrue(first.contains("Refresh started"), first)
        let second = try await refusal()

        XCTAssertTrue(second.contains("already running"), second)
        let report = try await awaitRefreshReport()
        XCTAssertTrue(report.contains("`sleep 2; test -f from-main.txt` passed"), report)
        XCTAssertTrue(try isAncestor(try head("main"), of: epic.branch))
    }

    /// An epic with no commits of its own fast-forwards, so the check's scratch checkout sits on the
    /// base head, which an orphan reap reads as merged.
    func testAnOrphanReapDuringAFastForwardRefreshLeavesTheScratchCheckoutAlone() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-gate-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: gate) }
        try setCommands(build: "until [ -f '\(gate.path)' ]; do sleep 0.1; done; test -f from-main.txt", test: "true")

        let started = try await refresh().text
        XCTAssertTrue(started.contains("Refresh started"), started)
        var waited = 0
        while try worktreeCount() < 2, waited < 300 {
            try await _Concurrency.Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        await fixture.supervisor.reconcile(projectId: fixture.project.id)
        try Data().write(to: gate)

        let report = try await awaitRefreshReport()
        XCTAssertTrue(report.contains("passed, then `true` passed"), report)
        XCTAssertTrue(try isAncestor(try head("main"), of: epic.branch))
    }

    func testTheRefreshCheckoutRunsTheRepositorysPostCheckoutHook() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        let hook = fixture.repo.appendingPathComponent(".git/hooks/post-checkout")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch .setup-done\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try setCommands(build: "test -f .setup-done", test: nil)

        let report = try await refreshReport()

        XCTAssertTrue(report.contains("`test -f .setup-done` passed"), report)
    }

    func testARefreshIsRefusedWhileAWorktreeHoldsTheEpicBranchAndNamesTheHolder() async throws {
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("main\n", to: "from-main.txt", on: "main")
        let holder = try fixture.manager.createForBranch(name: "integrate-\(epic.id)", branch: epic.branch)
        try fixture.sessions.insert(AgentSession(
            sessionId: "integrator-session", projectId: fixture.project.id, role: .worker,
            worktreePath: holder.path, branch: epic.branch, cwd: holder.path, state: .running
        ))
        let epicBefore = try head(epic.branch)

        let message = try await refusal()

        XCTAssertEqual(try head(epic.branch), epicBefore)
        XCTAssertTrue(message.contains("/worktrees/\(holder.lastPathComponent) by worker session integrator-session"), message)
    }

    /// An epic cut from `origin/main` while local `main` lags reads as current against local `main`.
    func testDriftAndRefreshUseOriginsBaseWhenLocalMainIsBehindIt() async throws {
        let remote = fixture.supportDir.appendingPathComponent("remote.git")
        try SupervisorFixture.git(["init", "-q", "--bare", remote.path], cwd: fixture.supportDir)
        try fixture.git(["remote", "add", "origin", remote.path])
        try fixture.git(["push", "-q", "origin", "main"])
        let cut = try pushFromAnotherClone(remote, file: "cut.txt")
        try fixture.git(["fetch", "-q", "origin"])
        try fixture.git(["branch", epic.branch, cut])
        let newer = try pushFromAnotherClone(remote, file: "newer.txt")
        try fixture.git(["fetch", "-q", "origin"])

        let drift = try await baseDrift()
        XCTAssertEqual(drift["against"] as? String, "origin/main", "\(drift)")
        XCTAssertEqual(drift["behind"] as? Int, 1, "\(drift)")

        try commit("epic\n", to: "from-epic.txt", on: epic.branch)
        let unfetched = try pushFromAnotherClone(remote, file: "unfetched.txt")
        let text = try await refresh().text
        XCTAssertTrue(try isAncestor(newer, of: epic.branch), "the refresh missed origin's newer commit: \(text)")
        XCTAssertTrue(try isAncestor(unfetched, of: epic.branch), "the refresh did not fetch origin: \(text)")
        XCTAssertTrue(text.contains("Merged origin/main into \(epic.branch)"), text)
        let subject = try fixture.git(["log", "-1", "--format=%s", epic.branch])
        XCTAssertTrue(subject.hasPrefix("Merge origin/main into"), subject)
    }

    func testGetEpicCountsCommitsBehindAndAheadOfTheBase() async throws {
        let drift = try await baseDrift()
        XCTAssertEqual(drift["behind"] as? NSNull, NSNull())
        XCTAssertTrue((drift["unavailable"] as? String)?.contains("does not exist yet") == true, "\(drift)")

        try fixture.manager.ensureBranch(epic.branch, from: "main")
        try commit("epic\n", to: "from-epic.txt", on: epic.branch)
        try commit("one\n", to: "one.txt", on: "main")
        try commit("two\n", to: "two.txt", on: "main")
        let measured = try await baseDrift()
        XCTAssertEqual(measured["behind"] as? Int, 2)
        XCTAssertEqual(measured["ahead"] as? Int, 1)
        XCTAssertEqual(measured["base"] as? String, "main")

        try fixture.git(["branch", "-m", "main", "trunk"])
        let noBase = try await baseDrift()
        XCTAssertEqual(noBase["ahead"] as? NSNull, NSNull())
        XCTAssertTrue((noBase["unavailable"] as? String)?.contains("base branch main does not exist") == true, "\(noBase)")
    }

    func testDriftRaisesNoAttentionAndPostsNoNotification() async throws {
        var banners: [String] = []
        fixture.supervisor.isFrontmost = { false }
        fixture.supervisor.postBanner = { title, _, _ in banners.append(title) }
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        for index in 0..<5 { try commit("\(index)\n", to: "main-\(index).txt", on: "main") }

        let drift = try await baseDrift()

        XCTAssertEqual(drift["behind"] as? Int, 5)
        let attention = try ProjectAttentionStore(fixture.db).attention(projectId: fixture.project.id)
        XCTAssertEqual(attention?.causes.count ?? 0, 0, "drift raised attention: \(String(describing: attention))")
        XCTAssertEqual(banners, [])
    }

    // MARK: Helpers

    private func refresh() async throws -> ToolResult {
        try await fixture.callOrchestratorTool("refresh_epic", arguments: .object(["epic_id": .string(epic.id)]))
    }

    /// Starts a refresh that has a command to run and waits for the report carrying its outcome.
    private func refreshReport() async throws -> String {
        let started = try await refresh().text
        XCTAssertTrue(started.contains("Refresh started"), started)
        return try await awaitRefreshReport()
    }

    private func awaitRefreshReport() async throws -> String {
        let reports = ReportStore(fixture.db)
        for _ in 0..<300 {
            if let report = try reports.unconsumed(projectId: fixture.project.id).first(where: { $0.kind == .refresh }) {
                return report.body
            }
            try await _Concurrency.Task.sleep(for: .milliseconds(100))
        }
        XCTFail("no refresh report arrived")
        return ""
    }

    private func refusal() async throws -> String {
        do {
            let result = try await refresh()
            XCTFail("refresh_epic succeeded: \(result.text)")
            return result.text
        } catch let error as ToolError {
            return error.message
        }
    }

    private func baseDrift() async throws -> [String: Any] {
        let result = try await fixture.callOrchestratorTool("get_epic", arguments: .object(["id": .string(epic.id)]))
        let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
        return try XCTUnwrap(object?["base_drift"] as? [String: Any], result.text)
    }

    private func setCommands(
        build: String?, test: String?, integration: IntegrationVerification = .buildAndTest
    ) throws {
        var settings = fixture.project.settings
        settings.buildCommand = build
        settings.testCommand = test
        settings.integrationVerification = integration
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    /// `main` is checked out in the repository itself; any other branch is committed through a
    /// scratch worktree that is removed again, so nothing is left holding it.
    private func commit(_ contents: String, to file: String, on branch: String) throws {
        let isMain = branch == "main"
        let checkout = isMain ? fixture.repo : try fixture.manager.createForBranch(name: "scratch", branch: branch)
        try contents.write(to: checkout.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", "."], cwd: checkout)
        try SupervisorFixture.commit("Change \(file) on \(branch)", cwd: checkout)
        if !isMain { try fixture.manager.remove(path: checkout) }
    }

    private func pushFromAnotherClone(_ remote: URL, file: String) throws -> String {
        let clone = fixture.supportDir.appendingPathComponent("clone-\(file)")
        try SupervisorFixture.git(["clone", "-q", remote.path, clone.path], cwd: fixture.supportDir)
        try "merged\n".write(to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try SupervisorFixture.git(["add", file], cwd: clone)
        try SupervisorFixture.commit("Merge \(file) on the remote", cwd: clone)
        try SupervisorFixture.git(["push", "-q", "origin", "main"], cwd: clone)
        return try SupervisorFixture.git(["rev-parse", "HEAD"], cwd: clone).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func head(_ ref: String) throws -> String {
        try fixture.git(["rev-parse", "--verify", ref]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAncestor(_ commit: String, of ref: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: WorktreeManager.gitPath)
        process.arguments = ["merge-base", "--is-ancestor", commit, ref]
        process.currentDirectoryURL = fixture.repo
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func worktreeCount() throws -> Int {
        try fixture.manager.list().count
    }
}
