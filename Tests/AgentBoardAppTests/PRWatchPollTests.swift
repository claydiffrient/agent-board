import AgentBoardCore
import AgentBoardRuntime
import Foundation
import GRDB
import XCTest
@testable import AgentBoard

/// SPEC §13.1 phase 1: the PR follow-through poll, driven through `FakeGh`.
@MainActor
final class PRWatchPollTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private let repository = "example-org/app"
    private let label = "verified-example"
    private var url: String { "https://github.com/\(repository)/pull/12" }
    private var watches: PRWatchStore { PRWatchStore(fixture.db) }
    private var banners: [(title: String, route: NotificationRoute?)] = []

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        try fixture.git(["remote", "add", "origin", "git@github.com:\(repository).git"])
        banners = []
        fixture.supervisor.postBanner = { [weak self] title, _, route in self?.banners.append((title, route)) }
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    private func enable() throws {
        var settings = fixture.project.settings
        settings.prFollowThrough = PRFollowThroughSettings(enabled: true, verificationLabel: label)
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    private func pullRequest(
        _ number: Int = 12, head: String = "c0ffee", labels: [String] = [], checks: String? = "SUCCESS",
        required: [String] = [], reported: [[String: Any]] = [], threads: [[String: Any]] = [],
        reviews: [[String: Any]] = []
    ) -> [String: Any] {
        let rollup: Any = checks.map { ["state": $0, "contexts": ["nodes": reported]] } ?? NSNull()
        let protection: Any = required.isEmpty ? NSNull() : ["requiredStatusCheckContexts": required]
        return [
            "number": number, "url": "https://github.com/\(repository)/pull/\(number)", "title": "Add widgets",
            "isDraft": false, "headRefName": "add-widgets", "headRefOid": head, "baseRefName": "main",
            "baseRef": ["refUpdateRule": protection, "rules": ["nodes": []]],
            "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
            "labels": ["nodes": labels.map { ["name": $0] }],
            "commits": ["nodes": [["commit": ["statusCheckRollup": rollup]]]],
            "reviewThreads": ["nodes": threads],
            "reviews": ["nodes": reviews],
        ]
    }

    private func checkRun(
        _ name: String, status: String = "COMPLETED", conclusion: String?, startedAt: String? = nil
    ) -> [String: Any] {
        ["name": name, "status": status, "conclusion": conclusion ?? NSNull(), "startedAt": startedAt ?? NSNull()]
    }

    private func backdateHeadPastTheChecksGracePeriod() throws {
        try fixture.db.writer.write {
            try $0.execute(
                sql: "UPDATE pr_watch SET head_changed_at = ?",
                arguments: [Int64.nowMillis - PRWatchTransition.checksGraceMillis]
            )
        }
    }

    private func thread(_ id: String, by author: String, resolved: Bool = false, outdated: Bool = false) -> [String: Any] {
        [
            "id": id, "isResolved": resolved, "isOutdated": outdated,
            "comments": ["nodes": [[
                "author": ["login": author], "body": "Rename this.", "url": "\(url)#\(id)",
                "path": "Sources/App.swift", "line": 3,
            ]]],
        ]
    }

    private func answer(_ pr: [String: Any]) {
        fixture.gh.answerSearch([AuthoredPullRequest(repository: repository, number: 12, url: url, title: "Add widgets")])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [pr])
    }

    private func onlyWatch() throws -> PRWatch {
        let live = try watches.live(projectId: fixture.project.id)
        XCTAssertEqual(live.count, 1)
        return try XCTUnwrap(live.first)
    }

    func testApprovedGreenPullRequestIsReadyToVerifyUntilTheLabelMarksItVerified() async throws {
        try enable()
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)

        answer(pullRequest(labels: [label]))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .verified)
    }

    /// SPEC §13.4: once per head oid. A PR that stays ready, or drops out and comes back on the same
    /// head, says nothing more; a push it is ready on again announces it again.
    func testReadyToVerifyBannersOncePerHeadOidAndRoutesToItsRow() async throws {
        try enable()
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        XCTAssertEqual(banners.map(\.title), ["Pull request ready to verify — \(fixture.project.name)"])
        XCTAssertEqual(banners.first?.route, NotificationRoute(projectId: fixture.project.id, subject: .pullRequest(watch.id)))

        await fixture.supervisor.pollPRWatches()
        answer(pullRequest(checks: "PENDING"))
        await fixture.supervisor.pollPRWatches()
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)
        XCTAssertEqual(banners.count, 1, "the same head stayed or came back ready")

        answer(pullRequest(head: "decaf0"))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(banners.count, 2, "a new head that is ready announces itself again")
    }

    func testReadyToVerifyBannerHonorsTheProjectsNotificationSettings() async throws {
        try enable()
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.notifications.setEnabled(.prReadyToVerify, false)
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()

        XCTAssertEqual(try onlyWatch().state, .readyToVerify)
        XCTAssertTrue(banners.isEmpty)
    }

    func testNoChecksAtAllCountAsGreenOnlyOnceTheGracePeriodHasPassed() async throws {
        try enable()
        answer(pullRequest(checks: nil))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching, "CI may not have registered its checks yet")

        try backdateHeadPastTheChecksGracePeriod()
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)
    }

    func testAnApprovedPullRequestRightAfterAPushIsNotReadyWhileItsRequiredChecksHaveNotReported() async throws {
        try enable()
        answer(pullRequest(checks: nil, required: ["build"]))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching)
        XCTAssertTrue(banners.isEmpty)

        try backdateHeadPastTheChecksGracePeriod()
        answer(pullRequest(checks: "SUCCESS", required: ["build"], reported: [checkRun("lint", conclusion: "SUCCESS")]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .watching)
        XCTAssertEqual(watch.checksState, "PENDING")
    }

    func testOnlyTheBaseBranchesRequiredChecksGateReadiness() async throws {
        try enable()
        answer(pullRequest(checks: "FAILURE", required: ["build"], reported: [
            checkRun("build", conclusion: "SUCCESS"),
            checkRun("lint", conclusion: "FAILURE"),
        ]))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)
    }

    func testAPassingRerunClearsTheFailedRunOfTheSameRequiredCheck() async throws {
        try enable()
        answer(pullRequest(checks: "FAILURE", required: ["build"], reported: [
            checkRun("build", conclusion: "SUCCESS", startedAt: "2026-10-21T12:30:00Z"),
            checkRun("build", conclusion: "FAILURE", startedAt: "2026-10-21T12:00:00Z"),
        ]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.checksState, "SUCCESS")
        XCTAssertEqual(watch.state, .readyToVerify)
    }

    func testANeutralCheckIsAFailureThatOutweighsAPendingOne() async throws {
        try enable()
        answer(pullRequest(checks: "PENDING", reported: [
            checkRun("build", status: "IN_PROGRESS", conclusion: nil),
            checkRun("lint", conclusion: "NEUTRAL"),
        ]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .watching)
        XCTAssertEqual(watch.checksState, "FAILURE")
    }

    func testAnUnresolvedThreadKeepsItWatchingWithOneOpenItem() async throws {
        try enable()
        answer(pullRequest(threads: [
            thread("T_open", by: "reviewer"),
            thread("T_resolved", by: "reviewer", resolved: true),
            thread("T_outdated", by: "reviewer", outdated: true),
            thread("T_mine", by: "me"),
        ]))
        await fixture.supervisor.pollPRWatches()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .watching)
        let open = try watches.items(watchId: watch.id).filter { $0.state == .open }
        XCTAssertEqual(open.map(\.githubNodeId), ["T_open"])
    }

    func testADraftIsIgnored() async throws {
        try enable()
        fixture.gh.answerSearch([AuthoredPullRequest(repository: repository, number: 12, url: url, title: "WIP", isDraft: true)])
        await fixture.supervisor.pollPRWatches()

        XCTAssertEqual(try watches.live(projectId: fixture.project.id), [])
        XCTAssertEqual(fixture.gh.calls, [PullRequestWatchReader.searchArguments])
    }

    func testAPullRequestConvertedBackToDraftStopsBeingWatched() async throws {
        try enable()
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        _ = try onlyWatch()

        fixture.gh.answerSearch([AuthoredPullRequest(repository: repository, number: 12, url: url, title: "Add widgets", isDraft: true)])
        let before = fixture.gh.calls.count
        await fixture.supervisor.pollPRWatches()

        XCTAssertEqual(try watches.live(projectId: fixture.project.id), [])
        XCTAssertEqual(Array(fixture.gh.calls.dropFirst(before)), [PullRequestWatchReader.searchArguments])
    }

    func testNoEnabledProjectRunsNoGhCommand() async throws {
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(fixture.gh.calls, [])
    }

    func testAPullRequestThatLeftTheOpenListSettlesByItsState() async throws {
        try enable()
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()

        fixture.gh.answerSearch([])
        fixture.gh.answer(url, state: "MERGED", mergeCommit: "5eed1e55")
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try watches.get(watch.id)?.state, .merged)
    }

    func testUnauthenticatedGhRaisesOneAttentionReasonUntilItIsFixed() async throws {
        try enable()
        fixture.gh.failSearch(status: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login")
        await fixture.supervisor.pollPRWatches()
        await fixture.supervisor.pollPRWatches()

        let attention = ProjectAttentionStore(fixture.db)
        let cause = try XCTUnwrap(try attention.attention(projectId: fixture.project.id)?.cause(.prPollUnavailable))
        XCTAssertEqual(cause.count, 1)
        XCTAssertTrue(cause.text.contains("gh auth login"), cause.text)

        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try attention.attention(projectId: fixture.project.id)?.has(.prPollUnavailable), false)
    }

    func testRepeatedSearchFailuresRaiseAttentionThatSaysItIsFailing() async throws {
        try enable()
        let attention = ProjectAttentionStore(fixture.db)
        fixture.gh.failSearch(status: 1, stderr: "API rate limit exceeded")
        for _ in 1..<WorkerSupervisor.prWatchFailuresBeforeAttention {
            await fixture.supervisor.pollPRWatches()
        }
        XCTAssertEqual(try attention.attention(projectId: fixture.project.id)?.has(.prPollUnavailable), false)

        await fixture.supervisor.pollPRWatches()
        let cause = try XCTUnwrap(try attention.attention(projectId: fixture.project.id)?.cause(.prPollUnavailable))
        XCTAssertTrue(cause.text.contains("failed"), cause.text)
        XCTAssertFalse(cause.text.contains("gh auth login"), cause.text)

        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try attention.attention(projectId: fixture.project.id)?.has(.prPollUnavailable), false)
    }
}
