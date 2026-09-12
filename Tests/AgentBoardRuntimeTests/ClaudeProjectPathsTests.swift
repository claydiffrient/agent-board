import XCTest
@testable import AgentBoardRuntime

final class ClaudeProjectPathsTests: XCTestCase {
    private var root: URL!
    private var canonical: URL!
    private let worktree = "/Users/x/Derivita/.claude/worktrees/a"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        canonical = root.appendingPathComponent("-Users-x-Derivita/memory")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSlug() {
        XCTAssertEqual(ClaudeProjectPaths.slug(forPath: worktree), "-Users-x-Derivita--claude-worktrees-a")
        XCTAssertEqual(ClaudeProjectPaths.slug(forPath: "/Users/x/Derivita"), "-Users-x-Derivita")
        XCTAssertEqual(ClaudeProjectPaths.slug(forPath: "/tmp/agent.board/v1.2"), "-tmp-agent-board-v1-2")
    }

    func testProjectAndMemoryDirs() {
        XCTAssertEqual(ClaudeProjectPaths.projectDir(forPath: worktree, projectsRoot: root).path, root.appendingPathComponent("-Users-x-Derivita--claude-worktrees-a").path)
        XCTAssertEqual(ClaudeProjectPaths.memoryDir(forPath: worktree, projectsRoot: root).lastPathComponent, "memory")
        XCTAssertTrue(ClaudeProjectPaths.projectDir(forPath: "/a").path.hasSuffix(".claude/projects/-a"))
    }

    private var memory: URL { ClaudeProjectPaths.memoryDir(forPath: worktree, projectsRoot: root) }

    private func assertLinkedToCanonical(file: StaticString = #filePath, line: UInt = #line) throws {
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: memory.path)
        XCTAssertEqual(URL(fileURLWithPath: dest).resolvingSymlinksInPath().path, canonical.resolvingSymlinksInPath().path, file: file, line: line)
    }

    func testLinksWhenMissing() throws {
        XCTAssertEqual(try ClaudeProjectPaths.linkMemory(worktreePath: worktree, to: canonical, projectsRoot: root), .linked)
        try assertLinkedToCanonical()
        XCTAssertEqual(try ClaudeProjectPaths.linkMemory(worktreePath: worktree, to: canonical, projectsRoot: root), .alreadyLinked)
    }

    func testReplacesSymlinkPointingElsewhere() throws {
        let other = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: memory, withDestinationURL: other)

        XCTAssertEqual(try ClaudeProjectPaths.linkMemory(worktreePath: worktree, to: canonical, projectsRoot: root), .relinked(previousTarget: other.path))
        try assertLinkedToCanonical()
    }

    func testReplacesEmptyRealDirectory() throws {
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        XCTAssertEqual(try ClaudeProjectPaths.linkMemory(worktreePath: worktree, to: canonical, projectsRoot: root), .replacedEmptyDirectory)
        try assertLinkedToCanonical()
    }

    func testLeavesNonEmptyDirectoryInPlace() throws {
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try "notes".write(to: memory.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)

        let result = try ClaudeProjectPaths.linkMemory(worktreePath: worktree, to: canonical, projectsRoot: root)
        guard case .leftInPlace(let reason) = result else {
            return XCTFail("expected leftInPlace, got \(result)")
        }
        XCTAssertTrue(reason.contains("non-empty"))
        let attrs = try FileManager.default.attributesOfItem(atPath: memory.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory.appendingPathComponent("MEMORY.md").path))
    }

    func testCreatesMissingCanonicalTarget() throws {
        let fresh = root.appendingPathComponent("fresh/memory")
        XCTAssertEqual(try ClaudeProjectPaths.linkMemory(worktreePath: worktree, to: fresh, projectsRoot: root), .linked)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
