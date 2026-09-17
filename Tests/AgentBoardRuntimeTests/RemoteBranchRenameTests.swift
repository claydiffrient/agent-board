import AgentBoardRuntime
import Foundation
import XCTest

/// The rename half of publishing, proved against a bare repository this test creates. No real
/// remote and no `gh`: the pull-request side is asserted as command construction elsewhere.
final class RemoteBranchRenameTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var remote: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-rename-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try git(["init", "--initial-branch=main"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        try "hello\n".write(to: repo.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "Add hello"], in: repo)
        try git(["init", "--bare", remote.path], in: root)
        try git(["remote", "add", "origin", remote.path], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var publisher: BranchPublisher { BranchPublisher(repoPath: repo) }

    func testTheRefspecRenamesOnlyTheDestination() {
        XCTAssertEqual(
            PublishCommand.push(remote: "origin", branch: "agentboard/epic-7", published: "clay/ship-it"),
            ["push", "--set-upstream", "origin", "refs/heads/agentboard/epic-7:refs/heads/clay/ship-it"]
        )
        XCTAssertEqual(
            PublishCommand.push(remote: "origin", branch: "agentboard/epic-7"),
            PublishCommand.push(remote: "origin", branch: "agentboard/epic-7", published: nil)
        )
    }

    func testALocalAgentboardBranchLandsOnTheRemoteUnderThePublishedName() throws {
        let local = "agentboard/epic-6726f4c8-f7c7-488d-a510-9636ea034da6"
        try git(["branch", local], in: repo)
        let localSHA = try git(["rev-parse", local], in: repo)

        let result = try publisher.push(branch: local, publishedAs: "clay/update-claude-md")

        XCTAssertEqual(result, .pushed(branch: local, remote: "origin", published: "clay/update-claude-md"))
        XCTAssertEqual(try remoteBranches(), ["clay/update-claude-md"])
        XCTAssertEqual(try git(["rev-parse", "clay/update-claude-md"], in: remote), localSHA)

        XCTAssertEqual(try git(["rev-parse", local], in: repo), localSHA)
        XCTAssertTrue(try localBranches().contains(local))
        XCTAssertFalse(try localBranches().contains("clay/update-claude-md"))
    }

    func testTheCommitsOnTheRenamedRemoteRefAreTheLocalOnes() throws {
        let local = "agentboard/b5ec62a7"
        try git(["checkout", "-b", local], in: repo)
        try "one\n".write(to: repo.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "Add one"], in: repo)
        try "two\n".write(to: repo.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "Add two"], in: repo)

        _ = try publisher.push(branch: local, publishedAs: "clay/add-one-and-two")

        let localLog = try git(["log", "--format=%H %s", local], in: repo)
        let remoteLog = try git(["log", "--format=%H %s", "clay/add-one-and-two"], in: remote)
        XCTAssertEqual(remoteLog, localLog)
        XCTAssertTrue(localLog.contains("Add two"), localLog)
    }

    func testASecondPushOfTheSameNameIsUpToDateAndCreatesNoSecondRef() throws {
        let local = "agentboard/epic-1"
        try git(["branch", local], in: repo)

        _ = try publisher.push(branch: local, publishedAs: "clay/ship-it")
        let second = try publisher.push(branch: local, publishedAs: "clay/ship-it")

        XCTAssertEqual(second, .alreadyUpToDate(branch: local, remote: "origin", published: "clay/ship-it"))
        XCTAssertEqual(try remoteBranches(), ["clay/ship-it"])
    }

    func testWithNoPublishedNameTheLocalNameStillReachesTheRemote() throws {
        let local = "agentboard/epic-2"
        try git(["branch", local], in: repo)

        let result = try publisher.push(branch: local)

        XCTAssertEqual(result, .pushed(branch: local, remote: "origin"))
        XCTAssertEqual(result.summary, "pushed \(local) to origin")
        XCTAssertEqual(try remoteBranches(), [local])
    }

    func testTheSummaryNamesThePublishedNameOnlyWhenItDiffers() {
        XCTAssertEqual(
            PushResult.pushed(branch: "agentboard/x", remote: "origin", published: "clay/y").summary,
            "pushed agentboard/x to origin as clay/y"
        )
        XCTAssertEqual(
            PushResult.pushed(branch: "agentboard/x", remote: "origin", published: "agentboard/x").summary,
            "pushed agentboard/x to origin"
        )
    }

    private func remoteBranches() throws -> [String] {
        let listed = try git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: remote)
        return listed.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func localBranches() throws -> [String] {
        let listed = try git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
        return listed.split(whereSeparator: \.isNewline).map(String.init)
    }

    @discardableResult
    private func git(_ arguments: [String], in cwd: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
