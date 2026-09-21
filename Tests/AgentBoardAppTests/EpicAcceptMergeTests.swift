import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5.2: accepting a task inside an epic merges its branch into the epic branch, so the next
/// sibling spawned branches from work that is already in.
@MainActor
final class EpicAcceptMergeTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testAcceptFastForwardsTheEpicBranchWithoutCreatingAWorktree() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let session = try epicWorker(task: task, epic: epic)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        let taskHead = try headOf("agentboard/\(task.id)")

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try headOf(epic.branch), taskHead, "the epic branch did not fast-forward onto the task branch")
        XCTAssertEqual(try mergeCommitCount(epic.branch), 0, "a fast-forward should not have made a merge commit")
        XCTAssertEqual(try worktreePaths(), [], "a fast-forward needed no worktree")
        XCTAssertEqual(try column(task.id), .done)
        XCTAssertEqual(try landing(task.id), .landed)
        XCTAssertEqual(try mergeReports(), [])
    }

    func testAcceptMergesThroughATemporaryWorktreeWhenTheEpicBranchHasMoved() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let session = try epicWorker(task: task, epic: epic)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath), file: "from-task.txt")
        try fixture.commitOn(branch: epic.branch, message: "Sibling work already on the epic branch")
        let epicHeadBefore = try headOf(epic.branch)
        let taskHead = try headOf("agentboard/\(task.id)")

        try await fixture.supervisor.accept(taskId: task.id)

        let epicHead = try headOf(epic.branch)
        XCTAssertNotEqual(epicHead, epicHeadBefore)
        XCTAssertNotEqual(epicHead, taskHead)
        XCTAssertEqual(try parents(epicHead), [epicHeadBefore, taskHead], "the epic branch did not get a real merge commit")
        XCTAssertTrue(try fixture.manager.branchExists(epic.branch), "the temporary worktree removal took the epic branch with it")
        XCTAssertEqual(try worktreePaths(), [], "the temporary merge worktree was left behind")
        XCTAssertEqual(try column(task.id), .done)
        XCTAssertEqual(try mergeReports(), [])
    }

    func testAConflictingMergeLeavesTheEpicBranchAloneAndReportsTheFiles() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let session = try epicWorker(task: task, epic: epic)
        let worktree = try XCTUnwrap(session.worktreePath)
        try write("task side\n", to: "schema.sql", in: worktree)
        try commitAll(in: worktree, message: "Add the task's schema")
        try conflictingCommitOnEpic(epic, file: "schema.sql", contents: "epic side\n")
        let epicHeadBefore = try headOf(epic.branch)
        let taskHead = try headOf("agentboard/\(task.id)")

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try headOf(epic.branch), epicHeadBefore, "a conflicting merge moved the epic branch")
        XCTAssertEqual(try worktreePaths(), [], "the temporary merge worktree survived the conflict")
        XCTAssertTrue(try fixture.manager.branchExists(epic.branch))
        XCTAssertEqual(try headOf("agentboard/\(task.id)"), taskHead, "the task branch was rewritten")
        XCTAssertEqual(try column(task.id), .done, "a conflict must not hold the task out of done")
        XCTAssertEqual(try landing(task.id), .unlanded, "a conflicted merge left no record that the work is out")

        let body = try XCTUnwrap(try mergeReports().first)
        XCTAssertTrue(body.contains(task.id), body)
        XCTAssertTrue(body.contains(epic.branch), body)
        XCTAssertTrue(body.contains("schema.sql"), body)
        let notice = try XCTUnwrap(fixture.supervisor.lastError)
        XCTAssertTrue(notice.contains("schema.sql"), notice)
    }

    func testAcceptingAnAlreadyMergedBranchIsANoOp() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let session = try epicWorker(task: task, epic: epic)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        try fixture.markMerged(epic: epic, branch: "agentboard/\(task.id)")
        let epicHeadBefore = try headOf(epic.branch)

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try headOf(epic.branch), epicHeadBefore)
        XCTAssertEqual(try worktreePaths(), [])
        XCTAssertEqual(try column(task.id), .done)
        XCTAssertEqual(try mergeReports(), [])
    }

    /// A reopen puts the task back in `ready`; accepting it again finds its branch already in.
    func testReAcceptingAfterAReopenIsANoOp() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let task = try makeTask(epicId: epic.id)
        let session = try epicWorker(task: task, epic: epic)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))

        try await fixture.supervisor.accept(taskId: task.id)
        let epicHead = try headOf(epic.branch)
        try await fixture.supervisor.reopen(taskId: task.id)
        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try headOf(epic.branch), epicHead, "the second accept moved the epic branch again")
        XCTAssertEqual(try column(task.id), .done)
        XCTAssertEqual(try mergeReports(), [])
    }

    /// A task in no epic targets the base branch, never some other epic's. Its own landing is
    /// `AcceptLandingTests`' subject; what matters here is that no epic branch moves for it.
    func testATaskWithNoEpicLeavesEveryEpicBranchAlone() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let epicHeadBefore = try headOf(epic.branch)
        let task = try makeTask(epicId: nil)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try headOf(epic.branch), epicHeadBefore)
        XCTAssertEqual(try column(task.id), .done)
    }

    /// `ensureBranch` normally cuts the epic branch at first spawn; a missing one must not crash.
    func testAMissingEpicBranchIsCreatedRatherThanCrashing() async throws {
        let epic = try makeEpic()
        let task = try makeTask(epicId: epic.id)
        let session = try fixture.worktreeWorker(task: task)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))
        XCTAssertFalse(try fixture.manager.branchExists(epic.branch))

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertTrue(try fixture.manager.branchExists(epic.branch))
        XCTAssertEqual(try headOf(epic.branch), try headOf("agentboard/\(task.id)"))
        XCTAssertEqual(try column(task.id), .done)
    }

    /// The epic is mid-integration: its worktree holds the branch, so the merge defers to the
    /// integrator instead of updating a ref out from under a live checkout.
    func testAnEpicBranchCheckedOutElsewhereIsLeftToItsHolder() async throws {
        let epic = try makeEpic()
        try fixture.manager.ensureBranch(epic.branch, from: "main")
        let integration = try fixture.manager.createForBranch(name: "epic-\(epic.id)", branch: epic.branch)
        let epicHeadBefore = try headOf(epic.branch)
        let task = try makeTask(epicId: epic.id)
        let session = try epicWorker(task: task, epic: epic)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath))

        try await fixture.supervisor.accept(taskId: task.id)

        XCTAssertEqual(try headOf(epic.branch), epicHeadBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: integration.path))
        XCTAssertEqual(try column(task.id), .done)
        let body = try XCTUnwrap(try mergeReports().first)
        XCTAssertTrue(body.contains(integration.path), body)
    }

    // MARK: - Helpers

    private func makeEpic() throws -> Epic {
        try EpicStore(fixture.db).create(projectId: fixture.project.id, title: "Roster", goal: "ship the roster")
    }

    private func makeTask(epicId: String?) throws -> BoardTask {
        try fixture.tasks.create(
            projectId: fixture.project.id, title: "Do the thing", body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: epicId
        )
    }

    /// What `spawn` leaves for a task inside an epic: a worktree cut from the epic branch.
    @discardableResult
    private func epicWorker(task: BoardTask, epic: Epic) throws -> AgentSession {
        let branch = "agentboard/\(task.id)"
        let worktree = try fixture.manager.create(name: task.id, branch: branch, base: epic.branch)
        let session = AgentSession(
            sessionId: "session-\(UUID().uuidString)", shortId: "short-1",
            projectId: fixture.project.id, taskId: task.id, role: .worker,
            worktreePath: worktree.path, branch: branch, cwd: worktree.path,
            state: .completed, attempt: 1
        )
        try fixture.sessions.insert(session)
        return session
    }

    private func write(_ contents: String, to file: String, in worktree: String) throws {
        try contents.write(
            to: URL(fileURLWithPath: worktree).appendingPathComponent(file), atomically: true, encoding: .utf8
        )
    }

    private func commitAll(in worktree: String, message: String) throws {
        let url = URL(fileURLWithPath: worktree)
        try SupervisorFixture.git(["add", "."], cwd: url)
        try SupervisorFixture.commit(message, cwd: url)
    }

    /// Commits a different `contents` at `file` on the epic branch, so the epic branch and the task
    /// branch both changed the same path and the merge must conflict.
    private func conflictingCommitOnEpic(_ epic: Epic, file: String, contents: String) throws {
        let scratch = try fixture.manager.createForBranch(name: "epic-side", branch: epic.branch)
        try write(contents, to: file, in: scratch.path)
        try commitAll(in: scratch.path, message: "Epic side of \(file)")
        try fixture.manager.remove(path: scratch)
    }

    private func headOf(_ ref: String) throws -> String {
        try trimmed(fixture.git(["rev-parse", "--verify", ref]))
    }

    private func parents(_ commit: String) throws -> [String] {
        Array(
            trimmed(try fixture.git(["rev-list", "--parents", "-n", "1", commit]))
                .split(separator: Character(" "))
                .map(String.init)
                .dropFirst()
        )
    }

    private func mergeCommitCount(_ ref: String) throws -> Int {
        Int(try trimmed(fixture.git(["rev-list", "--merges", "--count", ref]))) ?? 0
    }

    private func column(_ taskId: String) throws -> TaskColumn {
        try XCTUnwrap(try fixture.tasks.get(taskId)).column
    }

    private func landing(_ taskId: String) throws -> TaskLanding? {
        try XCTUnwrap(try fixture.tasks.get(taskId)).landing
    }

    /// Acceptance always queues its own `decision` report; only the merge failures name the branch.
    private func mergeReports() throws -> [String] {
        try ReportStore(fixture.db).unconsumed(projectId: fixture.project.id)
            .map(\.body)
            .filter { $0.contains("but its branch") }
    }

    private func worktreePaths() throws -> [String] {
        let root = URL(fileURLWithPath: fixture.project.worktreeRoot).resolvingSymlinksInPath().path
        return try fixture.manager.list()
            .map { $0.path.resolvingSymlinksInPath().path }
            .filter { $0.hasPrefix(root + "/") }
            .sorted()
    }

    private func trimmed(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
