import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class WorktreeSweepTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    func testCleanUpRemovesFinishedWorkAndNamesWhatItKeeps() async throws {
        let doneTask = try task("Done", column: .done)
        let done = try worktree(for: doneTask, spelling: .symlink)
        let dirty = try task("Dirty", column: .done)
        let dirtyPath = try worktree(for: dirty)
        try "unsaved\n".write(toFile: dirtyPath + "/scratch.txt", atomically: true, encoding: .utf8)
        let live = try task("Live", column: .done)
        let livePath = try worktree(for: live, state: .running, spelling: .resolved)
        try record(task: try task("Own checkout", column: .closed), path: fixture.repo.path)

        let epic = try fixture.epics.create(projectId: fixture.project.id, title: "Epic", goal: nil)
        let epicCheckout = try fixture.manager.create(
            name: HeldWorktree.epicWorktreeName(epicId: epic.id), branch: epic.branch, base: fixture.project.baseBranch
        ).path
        try fixture.epics.setState(epic.id, .done)

        let stray = URL(fileURLWithPath: fixture.project.worktreeRoot).appendingPathComponent("stray").path
        try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)

        let result = try await fixture.supervisor.sweepFinishedWorktrees(projectId: fixture.project.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: done), "a done task's worktree was left on disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: epicCheckout), "a done epic's integration checkout was left on disk")
        for kept in [dirtyPath, livePath, fixture.repo.path, stray] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept), "\(kept) was removed")
        }
        let kept = result.kept.map(\.text)
        XCTAssertTrue(kept.contains { $0.contains(dirtyPath) && $0.contains("uncommitted changes") }, "\(kept)")
        XCTAssertTrue(kept.contains { $0.contains(livePath) && $0.contains("still running") }, "\(kept)")
        XCTAssertTrue(kept.contains { $0.contains(fixture.repo.path) && $0.contains("own checkout") }, "\(kept)")
        XCTAssertEqual(result.unknown, [stray])

        XCTAssertTrue(try fixture.manager.branchExists("agentboard/\(doneTask.id)"), "the sweep deleted a merged task branch")
        XCTAssertTrue(try fixture.manager.branchExists(epic.branch), "the sweep deleted the epic branch")

        let report = try XCTUnwrap(try fixture.reports.unconsumed(projectId: fixture.project.id).last)
        XCTAssertEqual(report.kind, .decision)
        XCTAssertTrue(report.body.contains(done) && report.body.contains(dirtyPath), report.body)
        let progress = try ProgressStore(fixture.db).list(taskId: dirty.id).map(\.text)
        XCTAssertTrue(progress.contains { $0.contains("uncommitted changes") }, "\(progress)")
    }

    func testTheProjectMenuOffersCleanUpWorktrees() {
        XCTAssertTrue(ProjectMenuItem.allCases.map(\.title).contains("Clean up worktrees"))
    }

    private func task(_ title: String, column: TaskColumn) throws -> BoardTask {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: title, body: nil, acceptance: nil,
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
        try fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE task SET column_name = ? WHERE id = ?", arguments: [column, task.id])
        }
        return task
    }

    private enum Spelling { case symlink, resolved }

    /// Git lists `/private/var/...`; `.symlink` records `/var/...`, `.resolved` records git's spelling.
    @discardableResult
    private func worktree(
        for task: BoardTask, state: SessionState = .completed, spelling: Spelling? = nil
    ) throws -> String {
        var path = try fixture.manager.create(
            name: task.id, branch: "agentboard/\(task.id)", base: fixture.project.baseBranch
        ).path
        if path.hasPrefix("/private/var/") { path = String(path.dropFirst("/private".count)) }
        if let spelling {
            XCTAssertTrue(path.hasPrefix("/var/"), path)
            if spelling == .resolved { path = "/private" + path }
        }
        try record(task: task, path: path, state: state)
        return path
    }

    private func record(task: BoardTask, path: String, state: SessionState = .completed) throws {
        try fixture.sessions.insert(AgentSession(
            sessionId: "session-\(UUID().uuidString)", projectId: fixture.project.id, taskId: task.id,
            role: .worker, worktreePath: path, branch: "agentboard/\(task.id)", cwd: path, state: state, attempt: 1
        ))
    }
}
