import Foundation
import XCTest
@testable import AgentBoardCore

/// The bug these cover: branch existence was trusted as a proxy for commit history, so a task whose
/// work merged and whose branch was then reaped was described to the integrator as never having
/// committed. Driven against a real repository — a fixture would let the same assumption back in.
final class IntegrationPlanRepositoryTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentboard-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "--initial-branch=main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try commit(file: "README.md", contents: "start")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testAReapedBranchWhoseWorkFastForwardedIsReportedAsLanded() throws {
        let epicBranch = "agentboard/epic-\(UUID().uuidString)"
        try git("branch", epicBranch, "main")
        let taskId = UUID().uuidString
        try cutTaskBranch(taskId, from: epicBranch)
        try checkout("agentboard/\(taskId)")
        try commit(file: "GlanceStore.swift", contents: "struct GlanceStore {}")

        try fastForward(epicBranch, to: "agentboard/\(taskId)")
        try reapTaskBranch(taskId)

        XCTAssertFalse(try branchExists("agentboard/\(taskId)"), "the branch under test still exists")
        let facts = try branchFacts(taskId: taskId, epicBranch: epicBranch)
        XCTAssertEqual(TaskBranchEvidence.read(facts), .landed(commit: try resolve(TaskBranchLedger.tipRef(taskId: taskId))))

        let prompt = try prompt(epicBranch: epicBranch, facts: [taskId: facts], titles: [taskId: "count the board"])
        XCTAssertTrue(prompt.contains("nothing to do"), prompt)
        XCTAssertTrue(prompt.contains("do not report them as missing"), prompt)
        XCTAssertFalse(prompt.contains("Nothing was ever committed"), prompt)
        XCTAssertFalse(prompt.contains("No branch exists for these tasks"), prompt)
        XCTAssertFalse(prompt.contains("1. `agentboard/\(taskId)`"), "a landed task was handed over to be merged")
    }

    func testAReapedBranchWhoseWorkWasMergedNoFFIsReportedAsLanded() throws {
        let epicBranch = "agentboard/epic-\(UUID().uuidString)"
        try git("branch", epicBranch, "main")
        let taskId = UUID().uuidString
        try cutTaskBranch(taskId, from: epicBranch)
        try checkout("agentboard/\(taskId)")
        try commit(file: "GlanceStore.swift", contents: "struct GlanceStore {}")
        // A sibling moves the epic branch on, so the merge below cannot fast-forward.
        try checkout(epicBranch)
        try commit(file: "Sibling.swift", contents: "struct Sibling {}")
        try git("merge", "--no-ff", "--no-edit", "-m", "Merge agentboard/\(taskId)", "agentboard/\(taskId)")
        try checkout("main")
        try reapTaskBranch(taskId)

        let facts = try branchFacts(taskId: taskId, epicBranch: epicBranch)
        XCTAssertEqual(facts.ownCommits, 1)
        XCTAssertEqual(facts.tipOnEpicBranch, true)

        let prompt = try prompt(epicBranch: epicBranch, facts: [taskId: facts], titles: [taskId: "count the board"])
        XCTAssertTrue(prompt.contains("nothing to do"), prompt)
        XCTAssertFalse(prompt.contains("Nothing was ever committed"), prompt)
    }

    func testABranchWhoseWorkerCommittedNothingKeepsTheNothingWasCommittedWording() throws {
        let epicBranch = "agentboard/epic-\(UUID().uuidString)"
        try git("branch", epicBranch, "main")
        let taskId = UUID().uuidString
        try cutTaskBranch(taskId, from: epicBranch)
        try reapTaskBranch(taskId)

        let facts = try branchFacts(taskId: taskId, epicBranch: epicBranch)
        XCTAssertEqual(facts.ownCommits, 0)
        XCTAssertEqual(TaskBranchEvidence.read(facts), .nothingCommitted)

        let prompt = try prompt(epicBranch: epicBranch, facts: [taskId: facts], titles: [taskId: "document it"])
        XCTAssertTrue(prompt.contains("No branch exists for these tasks"), prompt)
        XCTAssertTrue(prompt.contains("Nothing was ever committed on them."), prompt)
        XCTAssertFalse(prompt.contains("nothing to do"), prompt)
    }

    func testAnUnrecordedBranchIsReportedAsUnknownRatherThanMissing() throws {
        let epicBranch = "agentboard/epic-\(UUID().uuidString)"
        try git("branch", epicBranch, "main")
        let taskId = UUID().uuidString
        try git("branch", "agentboard/\(taskId)", epicBranch)
        try checkout("agentboard/\(taskId)")
        try commit(file: "Orphan.swift", contents: "struct Orphan {}")
        try checkout("main")
        // Deleted by hand, so neither ledger ref was ever written.
        try git("update-ref", "-d", "refs/heads/agentboard/\(taskId)")

        let facts = try branchFacts(taskId: taskId, epicBranch: epicBranch)
        XCTAssertNil(facts.recordedTip)
        XCTAssertEqual(TaskBranchEvidence.read(facts), .unestablished)

        let prompt = try prompt(epicBranch: epicBranch, facts: [taskId: facts], titles: [taskId: "hand-deleted"])
        XCTAssertTrue(prompt.contains("Branch gone, outcome unknown"), prompt)
        XCTAssertFalse(prompt.contains("Nothing was ever committed"), prompt)
    }

    func testAnExistingUnmergedBranchIsStillHandedOverToBeMerged() throws {
        let epicBranch = "agentboard/epic-\(UUID().uuidString)"
        try git("branch", epicBranch, "main")
        let taskId = UUID().uuidString
        try cutTaskBranch(taskId, from: epicBranch)
        try checkout("agentboard/\(taskId)")
        try commit(file: "Pending.swift", contents: "struct Pending {}")
        try checkout("main")

        let facts = try branchFacts(taskId: taskId, epicBranch: epicBranch)
        XCTAssertTrue(facts.branchExists)
        XCTAssertFalse(facts.mergedIntoEpic)

        let prompt = try prompt(epicBranch: epicBranch, facts: [taskId: facts], titles: [taskId: "still open"])
        XCTAssertTrue(prompt.contains("1. `agentboard/\(taskId)` — still open"), prompt)
    }

    // MARK: - The ledger, read back out of a real repository

    /// Mirrors `WorkerSupervisor.branchFacts`, against the same refs the supervisor writes.
    private func branchFacts(taskId: String, epicBranch: String) throws -> TaskBranchFacts {
        let branch = "agentboard/\(taskId)"
        var facts = TaskBranchFacts(
            branchExists: try branchExists(branch),
            mergedIntoEpic: try branchExists(branch)
                && isAncestor("refs/heads/\(branch)", of: "refs/heads/\(epicBranch)"),
            everDispatched: true
        )
        guard !facts.branchExists else { return facts }
        facts.recordedBase = try? resolve(TaskBranchLedger.baseRef(taskId: taskId))
        facts.recordedTip = try? resolve(TaskBranchLedger.tipRef(taskId: taskId))
        if let tip = facts.recordedTip {
            facts.tipOnEpicBranch = isAncestor(tip, of: "refs/heads/\(epicBranch)")
            if let base = facts.recordedBase {
                facts.ownCommits = Int(try run("rev-list", "--count", "\(base)..\(tip)").out) ?? 0
            }
        }
        return facts
    }

    private func cutTaskBranch(_ taskId: String, from base: String) throws {
        try git("branch", "agentboard/\(taskId)", base)
        try git("update-ref", TaskBranchLedger.baseRef(taskId: taskId), try resolve("refs/heads/\(base)"))
    }

    /// What `WorkerSupervisor` does when it reaps a merged task branch: record the tip, drop the ref.
    private func reapTaskBranch(_ taskId: String) throws {
        let tip = try resolve("refs/heads/agentboard/\(taskId)")
        try git("update-ref", TaskBranchLedger.tipRef(taskId: taskId), tip)
        try git("update-ref", "-d", "refs/heads/agentboard/\(taskId)")
    }

    private func fastForward(_ branch: String, to source: String) throws {
        try git("update-ref", "refs/heads/\(branch)", try resolve("refs/heads/\(source)"))
    }

    private func prompt(epicBranch: String, facts: [String: TaskBranchFacts], titles: [String: String]) throws -> String {
        let epic = Epic(
            id: "e1", projectId: "p", title: "At a Glance", goal: "see every project at once",
            branch: epicBranch, state: .integrating, createdAt: .nowMillis
        )
        let tasks = facts.keys.sorted().map { id in
            BoardTask(
                id: id, projectId: "p", epicId: epic.id, title: titles[id] ?? id, body: nil, acceptance: nil,
                priority: nil, column: .done, ordering: 1, origin: .orchestrator,
                createdAt: .nowMillis, updatedAt: .nowMillis
            )
        }
        return IntegrationPlan.compose(
            epic: epic, baseBranch: "main",
            branches: IntegrationPlan.classify(tasks, facts: facts),
            verification: VerificationCommands(build: "swift build", test: "swift test")
        )
    }

    // MARK: - git

    @discardableResult
    private func git(_ args: String...) throws -> String {
        let result = try run(args)
        guard result.status == 0 else {
            throw XCTSkip("git \(args.joined(separator: " ")) exited \(result.status): \(result.err)")
        }
        return result.out
    }

    private func checkout(_ branch: String) throws {
        try git("checkout", branch)
    }

    private func commit(file: String, contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git("add", file)
        try git("commit", "-m", "Add \(file)")
    }

    private func branchExists(_ branch: String) throws -> Bool {
        try run("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)").status == 0
    }

    private func resolve(_ ref: String) throws -> String {
        let result = try run("rev-parse", "--verify", "--quiet", "\(ref)^{commit}")
        guard result.status == 0, !result.out.isEmpty else {
            throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: "no such ref \(ref)"])
        }
        return result.out
    }

    private func isAncestor(_ ref: String, of other: String) -> Bool {
        ((try? run("merge-base", "--is-ancestor", ref, other).status) ?? 1) == 0
    }

    private func run(_ args: String...) throws -> (status: Int32, out: String, err: String) {
        try run(args)
    }

    private func run(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
