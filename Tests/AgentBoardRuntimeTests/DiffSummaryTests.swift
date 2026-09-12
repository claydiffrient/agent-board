import XCTest
@testable import AgentBoardRuntime

final class DiffSummaryTests: XCTestCase {
    func testEmptyDiff() {
        XCTAssertEqual(WorktreeManager.parseNumstat(""), DiffSummary())
        XCTAssertTrue(WorktreeManager.parseNumstat("\n").isEmpty)
    }

    func testMultipleFiles() {
        let output = """
        14\t3\tSources/AgentBoard/Views/Orchestrator/ApprovalsSidebar.swift
        200\t0\tSources/AgentBoardRuntime/WorktreeManager.swift
        0\t34\tSources/Legacy.swift
        """
        XCTAssertEqual(
            WorktreeManager.parseNumstat(output),
            DiffSummary(filesChanged: 3, insertions: 214, deletions: 37, binaryFiles: 0)
        )
    }

    func testBinaryFilesCountAsChangedWithoutLineCounts() {
        let output = """
        5\t1\tREADME.md
        -\t-\tassets/logo.png
        -\t-\tassets/icon.icns
        """
        XCTAssertEqual(
            WorktreeManager.parseNumstat(output),
            DiffSummary(filesChanged: 3, insertions: 5, deletions: 1, binaryFiles: 2)
        )
    }

    func testRenameIsOneFile() {
        let output = "2\t1\tSources/{Old.swift => New.swift}\n0\t0\tdocs/a.md => docs/b.md\n"
        XCTAssertEqual(
            WorktreeManager.parseNumstat(output),
            DiffSummary(filesChanged: 2, insertions: 2, deletions: 1, binaryFiles: 0)
        )
    }

    func testIgnoresMalformedLines() {
        let output = "garbage\n7\t2\tSources/Fine.swift\n1\t1\t\n"
        XCTAssertEqual(
            WorktreeManager.parseNumstat(output),
            DiffSummary(filesChanged: 1, insertions: 7, deletions: 2, binaryFiles: 0)
        )
    }

    func testDiffSummaryAgainstRealRepository() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-numstat-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        func git(_ args: [String]) throws {
            let result = try ProcessRunner.run(
                executable: URL(fileURLWithPath: WorktreeManager.gitPath), arguments: args, cwd: repo
            )
            guard result.status == 0 else { throw AgentRuntimeError("git \(args): \(result.stderr)") }
        }

        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "base"])
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "work"])

        let manager = WorktreeManager(
            repoPath: repo,
            worktreeRoot: sandbox.appendingPathComponent("worktrees"),
            hookSettingsURL: sandbox.appendingPathComponent("settings.json")
        )
        let summary = try manager.diffSummary(worktree: repo, against: "HEAD~1")
        XCTAssertEqual(summary, DiffSummary(filesChanged: 2, insertions: 3, deletions: 0, binaryFiles: 0))
    }
}
