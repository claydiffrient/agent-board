import XCTest
@testable import AgentBoardRuntime

final class PullRequestLaunchTests: XCTestCase {
    func testArgumentsOpenTheWebFormAndNeverCreateDirectly() {
        let args = PullRequestLaunch.ghArguments(baseBranch: "main", headBranch: "agentboard/epic-abc123")
        XCTAssertEqual(args, ["pr", "create", "--web", "--base", "main", "--head", "agentboard/epic-abc123"])
        XCTAssertTrue(args.contains("--web"), "without --web gh would create the PR non-interactively")
        XCTAssertFalse(args.contains("--fill"))
        XCTAssertFalse(args.contains("--title"))
        XCTAssertFalse(args.contains("--body"))
        XCTAssertFalse(args.contains("push"))
    }

    func testArgumentsCarryTheProjectBaseBranch() {
        XCTAssertEqual(
            PullRequestLaunch.ghArguments(baseBranch: "develop", headBranch: "agentboard/epic-1"),
            ["pr", "create", "--web", "--base", "develop", "--head", "agentboard/epic-1"]
        )
    }

    func testSlugFromEveryRemoteForm() {
        XCTAssertEqual(PullRequestLaunch.githubSlug(remoteURL: "git@github.com:acme/widgets.git"), "acme/widgets")
        XCTAssertEqual(PullRequestLaunch.githubSlug(remoteURL: "git@github.com:acme/widgets"), "acme/widgets")
        XCTAssertEqual(PullRequestLaunch.githubSlug(remoteURL: "https://github.com/acme/widgets.git"), "acme/widgets")
        XCTAssertEqual(PullRequestLaunch.githubSlug(remoteURL: "https://user@github.com/acme/widgets"), "acme/widgets")
        XCTAssertEqual(PullRequestLaunch.githubSlug(remoteURL: "ssh://git@github.com/acme/widgets.git"), "acme/widgets")
        XCTAssertEqual(PullRequestLaunch.githubSlug(remoteURL: "  git@github.com:acme/widgets.git\n"), "acme/widgets")
    }

    func testSlugRejectsNonGitHubAndMalformedRemotes() {
        XCTAssertNil(PullRequestLaunch.githubSlug(remoteURL: "git@gitlab.com:acme/widgets.git"))
        XCTAssertNil(PullRequestLaunch.githubSlug(remoteURL: "https://example.com/acme/widgets.git"))
        XCTAssertNil(PullRequestLaunch.githubSlug(remoteURL: "/Users/me/local/repo"))
        XCTAssertNil(PullRequestLaunch.githubSlug(remoteURL: "https://github.com/acme"))
        XCTAssertNil(PullRequestLaunch.githubSlug(remoteURL: "https://github.com/acme/widgets/extra"))
        XCTAssertNil(PullRequestLaunch.githubSlug(remoteURL: ""))
    }

    func testCompareURLFallback() {
        XCTAssertEqual(
            PullRequestLaunch.compareURL(
                remoteURL: "git@github.com:acme/widgets.git",
                baseBranch: "main",
                headBranch: "agentboard/epic-abc123"
            )?.absoluteString,
            "https://github.com/acme/widgets/compare/main...agentboard/epic-abc123?expand=1"
        )
    }

    func testCompareURLEscapesBranchesButKeepsPathSeparators() {
        let url = PullRequestLaunch.compareURL(
            remoteURL: "https://github.com/acme/widgets",
            baseBranch: "release/2.0",
            headBranch: "agentboard/epic-a b"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://github.com/acme/widgets/compare/release/2.0...agentboard/epic-a%20b?expand=1"
        )
    }

    func testCompareURLIsNilForANonGitHubRemote() {
        XCTAssertNil(
            PullRequestLaunch.compareURL(remoteURL: "git@bitbucket.org:acme/widgets.git", baseBranch: "main", headBranch: "x")
        )
    }

    func testFallbackUsesTheRepoRemoteWhenGhIsAbsent() throws {
        let repo = try TemporaryGitRepo(remote: "git@github.com:acme/widgets.git")
        defer { repo.cleanUp() }
        let opener = PullRequestOpener(repoPath: repo.path)

        XCTAssertEqual(try opener.remoteURL(), "git@github.com:acme/widgets.git")
        let url = PullRequestLaunch.compareURL(
            remoteURL: try opener.remoteURL(), baseBranch: "main", headBranch: "agentboard/epic-abc123"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://github.com/acme/widgets/compare/main...agentboard/epic-abc123?expand=1"
        )
    }

    func testRemoteURLThrowsWhenThereIsNoOrigin() throws {
        let repo = try TemporaryGitRepo(remote: nil)
        defer { repo.cleanUp() }
        XCTAssertThrowsError(try PullRequestOpener(repoPath: repo.path).remoteURL())
    }
}

private struct TemporaryGitRepo {
    let path: URL

    init(remote: String?) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentboard-pr-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try git(["init", "-q"])
        if let remote {
            try git(["remote", "add", "origin", remote])
        }
    }

    private func git(_ args: [String]) throws {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: WorktreeManager.gitPath), arguments: args, cwd: path
        )
        XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.stderr)")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: path)
    }
}
