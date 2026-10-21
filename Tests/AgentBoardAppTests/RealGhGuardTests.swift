import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// No test reaches the user's GitHub account: every real `gh` exec refuses under XCTest, and the
/// fixture supervisor's PR poll and the Pull Requests page's Mark verified both land on `FakeGh`.
@MainActor
final class RealGhGuardTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    func testAStartedFixtureSupervisorAndThePullRequestsPageRunNoRealGh() async throws {
        try fixture.git(["remote", "add", "origin", "git@github.com:example-org/app.git"])
        var settings = fixture.project.settings
        settings.prFollowThrough = PRFollowThroughSettings(enabled: true, verificationLabel: "verified")
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        let project = try XCTUnwrap(try ProjectStore(fixture.db).get(fixture.project.id))
        await fixture.supervisor.start()

        let repo = fixture.repo
        let execs: [() throws -> Void] = [
            { _ = try SystemGh().run(["auth", "status"], cwd: repo) },
            { _ = try PullRequestOpener(repoPath: repo).open(baseBranch: "main", headBranch: "x") },
            { _ = try BranchPublisher(repoPath: repo).requireGh() },
        ]
        for exec in execs {
            XCTAssertThrowsError(try exec()) { XCTAssertTrue($0 is RealGhRefusedUnderTest, "\($0)") }
        }

        await fixture.supervisor.pollPRWatches()
        XCTAssertTrue(fixture.gh.calls.contains(PullRequestWatchReader.searchArguments), "\(fixture.gh.calls)")

        let watches = PRWatchStore(fixture.db)
        let watch = try watches.upsert(projectId: project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: 12,
            url: "https://github.com/example-org/app/pull/12", title: "Add widgets",
            headRef: "add-widgets", headOid: "c0ffee", baseRef: "main", items: []
        ))
        try watches.setState(.readyToVerify, watchId: watch.id)
        let env = renderEnvironment(db: fixture.db)
        let pageGh = try XCTUnwrap(env.gh as? FakeGh, "the Pull Requests page would run \(type(of: env.gh))")
        pageGh.answer(watch.url, state: "OPEN")
        try await PullRequestActions(db: env.db, gh: env.gh).markVerified(watch, project: project)
        XCTAssertEqual(pageGh.calls, [["pr", "edit", watch.url, "--add-label", "verified"]])
    }
}
