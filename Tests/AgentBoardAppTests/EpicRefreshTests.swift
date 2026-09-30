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

        let text = try await refresh().text

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

        let message = try await refusal()

        XCTAssertEqual(try head(epic.branch), epicBefore, "a refresh that failed to build moved the epic branch")
        XCTAssertTrue(message.contains("exited 3"), "the build did not run on the merge result: \(message)")
        XCTAssertTrue(message.contains("was not moved"), message)
        XCTAssertTrue(message.contains("error: no member named foo"), message)
        XCTAssertFalse(message.contains("`true` passed"), "the tests ran after the build failed: \(message)")
        XCTAssertEqual(try worktreeCount(), 1, "the scratch checkout the build ran in survived")
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

    private func setCommands(build: String?, test: String?) throws {
        var settings = fixture.project.settings
        settings.buildCommand = build
        settings.testCommand = test
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
