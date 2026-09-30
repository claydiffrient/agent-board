import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §5 "Resumed": a resumed worker in an epic has the epic branch merged into its worktree
/// first, and is told what that did.
@MainActor
final class ResumeEpicMergeTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    private var plainPrompt: String {
        "Agent Board resumed this session. Continue your task from where you left off; check `git status` and "
            + "`git log` first. When finished: commit on this branch, do not push, call `report_complete`. "
            + "If a resume or a compaction has left you without the instructions you were spawned with, "
            + "read the MCP resource `\(BriefingResourceURI.worker)` — it returns them in full."
    }

    private func stoppedWorker(inEpic: Bool) throws -> (session: AgentSession, worktree: URL, epic: Epic?) {
        let epic = inEpic ? try fixture.epics.create(projectId: fixture.project.id, title: "Epic", goal: nil) : nil
        if let epic { try fixture.git(["branch", epic.branch, "main"]) }
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Task", body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: epic?.id
        )
        let session = try fixture.worktreeWorker(task: task, state: .stopped)
        return (session, URL(fileURLWithPath: try XCTUnwrap(session.worktreePath)), epic)
    }

    /// A sibling's accepted work landing on `branch`, committed in a scratch worktree so the
    /// repository's own checkout never moves.
    @discardableResult
    private func land(on branch: String, file: String, contents: String, message: String) throws -> String {
        let scratch = fixture.supportDir.appendingPathComponent("scratch-\(UUID().uuidString)")
        try fixture.git(["worktree", "add", "--quiet", scratch.path, branch])
        try contents.write(to: scratch.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try fixture.git(["add", "."], cwd: scratch)
        try SupervisorFixture.commit(message, cwd: scratch)
        let sha = try head(scratch)
        try fixture.git(["worktree", "remove", "--force", scratch.path])
        return sha
    }

    private func head(_ worktree: URL) throws -> String {
        try fixture.git(["rev-parse", "HEAD"], cwd: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAncestor(_ commit: String, in worktree: URL) -> Bool {
        (try? fixture.git(["merge-base", "--is-ancestor", commit, "HEAD"], cwd: worktree)) != nil
    }

    private func resume(_ session: AgentSession) async throws -> String {
        try await fixture.supervisor.resume(sessionId: session.sessionId)
        let prompts = await fixture.runtime.resumePrompts
        return try XCTUnwrap(prompts.last)
    }

    func testResumeMergesTheEpicBranchASiblingAdvanced() async throws {
        let (session, worktree, epic) = try stoppedWorker(inEpic: true)
        try fixture.commitInto(worktree.path)
        let sibling = try land(
            on: try XCTUnwrap(epic).branch, file: "sibling.txt", contents: "sibling\n", message: "Add the sibling's piece"
        )

        let prompt = try await resume(session)

        XCTAssertTrue(isAncestor(sibling, in: worktree), "the sibling's commit is not in the resumed worktree")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("sibling.txt").path))
        XCTAssertEqual(
            try fixture.git(["log", "-1", "--format=%s"], cwd: worktree).trimmingCharacters(in: .whitespacesAndNewlines),
            "Merge Epic into Task",
            "the merge commit subject must come from titles, not branch names"
        )
        XCTAssertTrue(prompt.contains("\"Add the sibling's piece\""), prompt)
        XCTAssertTrue(prompt.contains("`sibling.txt`"), prompt)
    }

    func testATaskInNoEpicResumesWithNoMergeAndTheUnchangedPrompt() async throws {
        let (session, worktree, _) = try stoppedWorker(inEpic: false)
        let before = try head(worktree)
        try "main\n".write(to: fixture.repo.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try fixture.git(["add", "."])
        try SupervisorFixture.commit("Advance main", cwd: fixture.repo)
        let onMain = try head(fixture.repo)

        let prompt = try await resume(session)

        XCTAssertEqual(try head(worktree), before, "a task in no epic had something merged into it")
        XCTAssertFalse(isAncestor(onMain, in: worktree), "the primary branch reached a task branch")
        XCTAssertEqual(prompt, plainPrompt)
        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [session.sessionId])
    }

    func testAConflictedMergeStillResumesAndTellsTheWorkerTheConflictIsItsToResolve() async throws {
        let (session, worktree, epic) = try stoppedWorker(inEpic: true)
        try "mine\n".write(to: worktree.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try fixture.git(["add", "."], cwd: worktree)
        try SupervisorFixture.commit("Change the readme my way", cwd: worktree)
        try land(on: try XCTUnwrap(epic).branch, file: "README.md", contents: "theirs\n", message: "Change it their way")

        let prompt = try await resume(session)

        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [session.sessionId], "a conflict refused the resume")
        XCTAssertNoThrow(try fixture.git(["rev-parse", "--verify", "MERGE_HEAD"], cwd: worktree))
        XCTAssertEqual(
            try fixture.git(["diff", "--name-only", "--diff-filter=U"], cwd: worktree)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "README.md"
        )
        XCTAssertTrue(prompt.contains("Conflicted files: `README.md`"), prompt)
        XCTAssertTrue(prompt.contains("Resolving them is part of this task"), prompt)
        XCTAssertTrue(prompt.contains("not done until the tree builds and the test suite passes"), prompt)
        let notice = try XCTUnwrap(prompt.range(of: "Before you do anything else"))
        let carryOn = try XCTUnwrap(prompt.range(of: "Continue your task"))
        XCTAssertLessThan(notice.lowerBound, carryOn.lowerBound, "the conflict is not the first thing the worker reads")
    }

    func testAnEpicBranchAlreadyInTheTaskAddsNothingToThePrompt() async throws {
        let (session, worktree, _) = try stoppedWorker(inEpic: true)
        let before = try head(worktree)

        let prompt = try await resume(session)

        XCTAssertEqual(prompt, plainPrompt)
        XCTAssertEqual(try head(worktree), before)
    }

    /// Without the save, `git merge` refuses outright: the uncommitted edit is to a file the epic
    /// branch also changed.
    func testUncommittedWorkIsCommittedBeforeTheMergeAndNothingIsLost() async throws {
        let base = (1...10).map { "line \($0)" }
        try (base.joined(separator: "\n") + "\n")
            .write(to: fixture.repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try fixture.git(["commit", "--quiet", "-am", "Ten lines"])
        let (session, worktree, epic) = try stoppedWorker(inEpic: true)
        var mine = base
        mine[0] = "line 1, half-edited by the worker"
        try (mine.joined(separator: "\n") + "\n")
            .write(to: worktree.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "draft\n".write(to: worktree.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        var theirs = base
        theirs[9] = "line 10, from a sibling"
        try land(
            on: try XCTUnwrap(epic).branch, file: "README.md",
            contents: theirs.joined(separator: "\n") + "\n", message: "Edit the last line"
        )

        let prompt = try await resume(session)

        let readme = try String(contentsOf: worktree.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("line 1, half-edited by the worker"), readme)
        XCTAssertTrue(readme.contains("line 10, from a sibling"), readme)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("draft.txt"), encoding: .utf8), "draft\n")
        let saved = try fixture.git(
            ["log", "--format=%h", "--grep=\(ResumeMerge.savedWorkSubject)", "--fixed-strings", "HEAD"], cwd: worktree
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(saved.isEmpty, "no commit holds the uncommitted work")
        let savedFiles = try fixture.git(["show", "--name-only", "--format=", saved], cwd: worktree)
        XCTAssertEqual(Set(savedFiles.split(separator: "\n").map(String.init)), ["README.md", "draft.txt"])
        XCTAssertTrue(prompt.contains("committed them unchanged as `\(saved)`"), prompt)
    }
}
