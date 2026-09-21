import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// Two co-resident sessions in a real git repository. The guard is worth having only if the
/// commands it denies would actually destroy the sibling's work, so this asserts both halves: the
/// sibling's files survive the denied attempt, and the same commands run for real in an identical
/// repository take them away.
final class SharedCheckoutRealRepositoryTests: XCTestCase {
    private var sandbox: URL!
    private var repo: URL!
    private var f: BridgeFixture!
    private var mine: TokenIdentity!
    private var task: BoardTask!

    private let modified = "sibling-modified.txt"
    private let untracked = "sibling-untracked.txt"
    private let staged = "sibling-staged.txt"
    private let siblingWork = "the sibling's uncommitted work\n"

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-guard-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = try Self.makeRepository(at: sandbox.appendingPathComponent("repo"))
        try seedSiblingWork(in: repo)

        f = try BridgeFixture.make(repoPath: repo.path)
        task = try f.task("mine", column: .running)
        try f.sharedSession("w1", taskId: task.id)
        mine = f.workerIdentity(sessionId: "w1", taskId: task.id)

        let theirs = try f.task("theirs", column: .running)
        try f.sharedSession("w2", taskId: theirs.id)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testTheSiblingsUncommittedWorkSurvivesEveryDeniedCommand() async throws {
        for command in [
            "git stash",
            "git stash push -u",
            "git checkout .",
            "git checkout -- \(modified)",
            "git restore .",
            "git reset --hard",
            "git clean -fd",
            "git checkout -b somewhere-else",
            "git switch -c somewhere-else",
        ] {
            let decision = await f.preToolUse(command, sessionId: "w1", identity: mine)
            XCTAssertEqual(decision?.permissionDecision, "deny", command)
            try assertSiblingWorkIntact(in: repo, after: command)
        }
        XCTAssertEqual(try branch(of: repo), "agentboard/shared")
    }

    /// Without this the test above would pass against a guard that denies nothing dangerous.
    func testTheSameCommandsRunForRealTakeTheSiblingsWorkAway() throws {
        let lost: [(String, String)] = [
            ("git stash", modified),
            ("git checkout .", modified),
            ("git reset --hard", modified),
            ("git clean -fd", untracked),
            ("git stash push -u", untracked),
        ]
        for (command, victim) in lost {
            let control = try Self.makeRepository(at: sandbox.appendingPathComponent("control-\(UUID().uuidString)"))
            try seedSiblingWork(in: control)
            try Self.git(Array(command.split(separator: " ").dropFirst().map(String.init)), in: control)

            let survivor = try? String(contentsOf: control.appendingPathComponent(victim), encoding: .utf8)
            XCTAssertNotEqual(
                survivor, siblingWork,
                "`\(command)` left \(victim) alone, so denying it proves nothing"
            )
        }
    }

    func testAScopedRestoreOfThisSessionsOwnFileTouchesOnlyThatFile() async throws {
        let ownPath = "mine.txt"
        try write("committed\n", ownPath, in: repo)
        try Self.git(["add", ownPath], in: repo)
        // A partial commit, so the sibling's already-staged file stays staged.
        try Self.git(["commit", "-q", "-m", "Add mine.txt", "--", ownPath], in: repo)
        try write("edited by me\n", ownPath, in: repo)

        let write = await f.preToolUseWrite(repo.appendingPathComponent(ownPath).path, sessionId: "w1", identity: mine)
        XCTAssertNil(write as HookDecision?)
        let restore = await f.preToolUse("git restore -- \(ownPath)", sessionId: "w1", identity: mine)
        XCTAssertNil(restore as HookDecision?)

        // The hook allowed it, so run what the agent would have run.
        try Self.git(["restore", "--", ownPath], in: repo)
        XCTAssertEqual(try read(ownPath, in: repo), "committed\n")
        try assertSiblingWorkIntact(in: repo, after: "an allowed scoped restore")
    }

    func testARestoreThatWouldReachTheSiblingsFileIsDeniedBeforeGitSeesIt() async throws {
        let decision = await f.preToolUse("git restore -- \(modified)", sessionId: "w1", identity: mine)
        XCTAssertEqual(decision?.permissionDecision, "deny")
        try assertSiblingWorkIntact(in: repo, after: "a restore aimed at the sibling's file")
    }

    // MARK: - Repository

    private func seedSiblingWork(in repo: URL) throws {
        try write(siblingWork, modified, in: repo)
        try write(siblingWork, untracked, in: repo)
        try write(siblingWork, staged, in: repo)
        try Self.git(["add", staged], in: repo)
    }

    private func assertSiblingWorkIntact(in repo: URL, after command: String) throws {
        for path in [modified, untracked, staged] {
            XCTAssertEqual(try read(path, in: repo), siblingWork, "\(path) after `\(command)`")
        }
        XCTAssertTrue(
            try Self.git(["diff", "--cached", "--name-only"], in: repo).contains(staged),
            "\(staged) was unstaged by `\(command)`"
        )
    }

    private func write(_ contents: String, _ path: String, in repo: URL) throws {
        try contents.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in repo: URL) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    private func branch(of repo: URL) throws -> String {
        try Self.git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeRepository(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        try git(["config", "user.email", "test@example.com"], in: url)
        try git(["config", "user.name", "Test"], in: url)
        try git(["config", "commit.gpgsign", "false"], in: url)
        try "committed\n".write(
            to: url.appendingPathComponent("sibling-modified.txt"), atomically: true, encoding: .utf8
        )
        try git(["add", "."], in: url)
        try git(["commit", "-q", "-m", "Initial commit"], in: url)
        try git(["checkout", "-q", "-b", "agentboard/shared"], in: url)
        return url
    }

    @discardableResult
    private static func git(_ arguments: [String], in repo: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repo
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
