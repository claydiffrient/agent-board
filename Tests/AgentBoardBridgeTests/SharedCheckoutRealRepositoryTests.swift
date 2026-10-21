import Foundation
import XCTest

/// The negative control for `SharedCheckoutWorkingTreeGuardTests`' denial table: proof, against a
/// real git repository, that each denied command would actually have destroyed the sibling's
/// uncommitted work if it had been allowed to run. Without this, that guard's test would pass just
/// as well against a denial list that happened to block nothing dangerous.
final class SharedCheckoutRealRepositoryTests: XCTestCase {
    private var sandbox: URL!

    private let modified = "sibling-modified.txt"
    private let untracked = "sibling-untracked.txt"
    private let staged = "sibling-staged.txt"
    private let siblingWork = "the sibling's uncommitted work\n"

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-board-guard-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

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

    // MARK: - Repository

    private func seedSiblingWork(in repo: URL) throws {
        try write(siblingWork, modified, in: repo)
        try write(siblingWork, untracked, in: repo)
        try write(siblingWork, staged, in: repo)
        try Self.git(["add", staged], in: repo)
    }

    private func write(_ contents: String, _ path: String, in repo: URL) throws {
        try contents.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
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
