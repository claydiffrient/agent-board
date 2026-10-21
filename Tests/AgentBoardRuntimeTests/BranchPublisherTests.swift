import AgentBoardRuntime
import Foundation
import XCTest

final class BranchPublisherCommandTests: XCTestCase {
    func testPushNamesAFullyQualifiedRefspecOnBothSides() {
        XCTAssertEqual(
            PublishCommand.push(remote: "origin", branch: "agentboard/epic-7"),
            ["push", "--set-upstream", "origin", "refs/heads/agentboard/epic-7:refs/heads/agentboard/epic-7"]
        )
    }

    func testBranchExistenceIsCheckedAgainstRefsHeadsNotAnAmbiguousName() {
        XCTAssertEqual(PublishCommand.branchExists("main"), ["rev-parse", "--verify", "--quiet", "refs/heads/main"])
    }

    func testPullRequestPassesTitleAndBodyAsSeparateArguments() {
        let arguments = PublishCommand.pullRequestCreate(
            base: "main", head: "agentboard/epic-7", title: "Ship it", body: "Body with a --flag in it"
        )
        XCTAssertEqual(
            arguments,
            ["pr", "create", "--base", "main", "--head", "agentboard/epic-7", "--title", "Ship it",
             "--body", "Body with a --flag in it"]
        )
    }

    func testTheAuthCheckIsGhAuthStatus() {
        XCTAssertEqual(PublishCommand.ghAuthStatus, ["auth", "status"])
    }

    func testTheURLIsTakenFromTheFirstHttpsLineAmongTheNoise() {
        let output = """
        Warning: 3 uncommitted changes
        https://github.com/acme/widgets/pull/42
        """
        XCTAssertEqual(PublishCommand.pullRequestURL(in: output), "https://github.com/acme/widgets/pull/42")
        XCTAssertNil(PublishCommand.pullRequestURL(in: "Creating pull request...\n"))
    }

    func testAnExistingPullRequestIsReadOutOfGhsListJSON() {
        XCTAssertEqual(
            PublishCommand.firstURL(inListJSON: #"[{"url":"https://github.com/acme/widgets/pull/9"}]"#),
            "https://github.com/acme/widgets/pull/9"
        )
        XCTAssertNil(PublishCommand.firstURL(inListJSON: "[]"))
        XCTAssertNil(PublishCommand.firstURL(inListJSON: "not json"))
    }

    func testEveryFailureNamesItsOwnCause() {
        XCTAssertTrue(PublishFailure.noRemote(name: "origin", repoPath: "/repo").description.contains("no git remote"))
        XCTAssertTrue(PublishFailure.ghMissing.description.contains("not installed"))
        XCTAssertTrue(PublishFailure.ghNotAuthenticated(detail: "x").description.contains("gh auth login"))
        XCTAssertTrue(PublishFailure.noSuchBranch("b").description.contains("No branch named"))

        let descriptions = [
            PublishFailure.noRemote(name: "origin", repoPath: "/repo"),
            .ghMissing,
            .ghNotAuthenticated(detail: "x"),
        ].map(\.description)
        XCTAssertEqual(Set(descriptions).count, 3)
    }
}

/// End to end against a bare repository this test creates itself. Nothing here touches a real
/// remote, and `gh` is never invoked — the pull-request half is asserted as command construction.
final class BranchPublisherRepoTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var remote: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("branch-publisher-\(UUID().uuidString)")
        repo = root.appendingPathComponent("repo")
        remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try git(["init", "--initial-branch=main"], in: repo)
        try git(["config", "user.email", "test@example.com"], in: repo)
        try git(["config", "user.name", "Test"], in: repo)
        try "hello\n".write(to: repo.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "Add hello"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func addRemote() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--bare", remote.path], in: root)
        try git(["remote", "add", "origin", remote.path], in: repo)
    }

    private var publisher: BranchPublisher { BranchPublisher(repoPath: repo) }

    func testAProjectWithNoRemoteFailsWithThatCauseAndNotAGenericOne() throws {
        XCTAssertThrowsError(try publisher.push(branch: "main")) { error in
            guard case PublishFailure.noRemote(let name, _)? = error as? PublishFailure else {
                return XCTFail("expected noRemote, got \(error)")
            }
            XCTAssertEqual(name, "origin")
            XCTAssertTrue("\(error)".contains("local-only"), "\(error)")
        }
    }

    func testABranchThatDoesNotExistFailsBeforeAnythingLeavesTheMachine() throws {
        try addRemote()
        XCTAssertThrowsError(try publisher.push(branch: "agentboard/never-created")) { error in
            XCTAssertEqual(error as? PublishFailure, .noSuchBranch("agentboard/never-created"))
        }
        XCTAssertTrue(try remoteBranches().isEmpty)
    }

    func testPushingPutsTheBranchOnTheRemoteAndASecondPushIsUpToDate() throws {
        try addRemote()
        try git(["branch", "agentboard/epic-1"], in: repo)

        XCTAssertEqual(try publisher.push(branch: "agentboard/epic-1"), .pushed(branch: "agentboard/epic-1", remote: "origin"))
        XCTAssertEqual(try remoteBranches(), ["agentboard/epic-1"])

        XCTAssertEqual(
            try publisher.push(branch: "agentboard/epic-1"),
            .alreadyUpToDate(branch: "agentboard/epic-1", remote: "origin")
        )
    }

    func testPushingABranchThatIsNotCheckedOutStillWorks() throws {
        try addRemote()
        try git(["branch", "agentboard/side"], in: repo)
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "main")

        _ = try publisher.push(branch: "agentboard/side")
        XCTAssertEqual(try remoteBranches(), ["agentboard/side"])
        XCTAssertEqual(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo), "main")
    }

    func testTheRemoteCheckPassesOnceARemoteExists() throws {
        try addRemote()
        XCTAssertEqual(try publisher.requireRemote(), remote.path)
    }

    private func commit(_ file: String, _ contents: String, message: String) throws {
        try contents.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", message], in: repo)
    }

    func testAPushWhoseDiffNamesAPrivateTermIsRefusedAndReachesNothing() throws {
        try addRemote()
        try git(["checkout", "-q", "-b", "agentboard/feature"], in: repo)
        try commit("config.txt", "endpoint = api.ZebraCorp.internal\n", message: "Add config")

        let guarded = BranchPublisher(repoPath: repo, privateTerms: ["zebracorp"])
        XCTAssertThrowsError(try guarded.push(branch: "agentboard/feature", base: "main")) { error in
            XCTAssertEqual(error as? PublishFailure, .privateTerm(term: "zebracorp", site: .file("config.txt", commit: "Add config")))
        }
        XCTAssertTrue(try remoteBranches().isEmpty)
    }

    func testATermAddedAndLaterRemovedIsRefusedAndNamesTheCommitThatAddedIt() throws {
        try addRemote()
        try git(["checkout", "-q", "-b", "agentboard/feature"], in: repo)
        try commit("config.txt", "endpoint = api.zebracorp.internal\n", message: "Add config")
        try commit("config.txt", "endpoint = api.example.internal\n", message: "Scrub config")

        let guarded = BranchPublisher(repoPath: repo, privateTerms: ["zebracorp"])
        XCTAssertThrowsError(try guarded.push(branch: "agentboard/feature", base: "main")) { error in
            XCTAssertEqual(error as? PublishFailure, .privateTerm(term: "zebracorp", site: .file("config.txt", commit: "Add config")))
        }
        XCTAssertTrue(try remoteBranches().isEmpty)
    }

    func testATermInsideAFileGitTreatsAsBinaryIsRefused() throws {
        try addRemote()
        _ = try publisher.push(branch: "main")
        try git(["checkout", "-q", "-b", "agentboard/feature"], in: repo)
        try XCTUnwrap("names\nzebracorp\n".data(using: .utf16LittleEndian))
            .write(to: repo.appendingPathComponent("names.txt"))
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "Add names"], in: repo)

        let guarded = BranchPublisher(repoPath: repo, privateTerms: ["zebracorp"])
        XCTAssertThrowsError(try guarded.push(branch: "agentboard/feature", base: "main")) { error in
            XCTAssertEqual(error as? PublishFailure, .privateTerm(term: "zebracorp", site: .file("names.txt", commit: "Add names")))
        }
    }

    func testALineAddedToACRLFFileWithAQuotedPathIsRefusedUnderItsRealName() throws {
        try addRemote()
        _ = try publisher.push(branch: "main")
        try git(["checkout", "-q", "-b", "agentboard/feature"], in: repo)
        try git(["config", "core.autocrlf", "false"], in: repo)
        try commit("say \"hi\".txt", "one\r\ntwo\r\n", message: "Add greeting")
        try commit("say \"hi\".txt", "one\r\ntwo\r\nzebracorp\r\n", message: "Extend greeting")

        let guarded = BranchPublisher(repoPath: repo, privateTerms: ["zebracorp"])
        XCTAssertThrowsError(try guarded.push(branch: "agentboard/feature", base: "main")) { error in
            XCTAssertEqual(
                error as? PublishFailure,
                .privateTerm(term: "zebracorp", site: .file("say \"hi\".txt", commit: "Extend greeting"))
            )
        }
    }

    func testATermAlreadyOnTheRemoteBaseDoesNotRefuseABranchThatAddsNoneOfItsOwn() throws {
        try addRemote()
        try commit("legacy.txt", "zebracorp\n", message: "Add legacy")
        _ = try publisher.push(branch: "main")
        try git(["checkout", "-q", "-b", "agentboard/feature"], in: repo)
        try commit("other.txt", "unrelated\n", message: "Add other")

        let guarded = BranchPublisher(repoPath: repo, privateTerms: ["zebracorp"])
        _ = try guarded.push(branch: "agentboard/feature", base: "main")
        XCTAssertEqual(try remoteBranches(), ["agentboard/feature", "main"])
    }

    func testBlankTermsGuardNothing() throws {
        try addRemote()
        try git(["branch", "agentboard/feature"], in: repo)
        _ = try BranchPublisher(repoPath: repo, privateTerms: ["", "  "]).push(branch: "agentboard/feature", base: "main")
        XCTAssertEqual(try remoteBranches(), ["agentboard/feature"])
    }

    func testAPullRequestTitleNamingAPrivateTermIsRefused() throws {
        try addRemote()
        try git(["branch", "agentboard/feature"], in: repo)
        let guarded = BranchPublisher(repoPath: repo, privateTerms: ["zebracorp"])
        XCTAssertThrowsError(
            try guarded.refusePrivateTerms(
                branch: "agentboard/feature", base: "main", title: "Port the ZEBRACORP importer", body: ""
            )
        ) { error in
            XCTAssertEqual(error as? PublishFailure, .privateTerm(term: "zebracorp", site: .pullRequestTitle))
        }
    }

    private func remoteBranches() throws -> [String] {
        let listed = try git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: remote)
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
