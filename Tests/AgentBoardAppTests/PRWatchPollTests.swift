import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

private final class SteppedClock: SystemClock, @unchecked Sendable {
    var wallMillis: Int64 = .nowMillis
    var uptimeSeconds: TimeInterval = 10_000

    func advance(seconds: TimeInterval) {
        wallMillis += Int64(seconds * 1000)
        uptimeSeconds += seconds
    }
}

/// SPEC §13.1 phase 1: the PR follow-through poll, driven through `FakeGh`.
@MainActor
final class PRWatchPollTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var clock: SteppedClock!
    private let repository = "example-org/app"
    private let label = "verified-example"
    private var url: String { "https://github.com/\(repository)/pull/12" }
    private var watches: PRWatchStore { PRWatchStore(fixture.db) }
    private var banners: [(title: String, route: NotificationRoute?)] = []

    override func setUp() async throws {
        clock = SteppedClock()
        fixture = try SupervisorFixture.make(gitRepo: true, sleepLedger: SleepLedger(clock: clock))
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
        threads: [[String: Any]] = [], reviews: [[String: Any]] = []
    ) -> [String: Any] {
        let rollup: Any = checks.map { ["state": $0] } ?? NSNull()
        return [
            "number": number, "url": "https://github.com/\(repository)/pull/\(number)", "title": "Add widgets",
            "isDraft": false, "headRefName": "add-widgets", "headRefOid": head, "baseRefName": "main",
            "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
            "labels": ["nodes": labels.map { ["name": $0] }],
            "commits": ["nodes": [["commit": ["statusCheckRollup": rollup]]]],
            "reviewThreads": ["nodes": threads],
            "reviews": ["nodes": reviews],
        ]
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

    private func decideEveryOpenItem(_ watch: PRWatch) throws {
        try watches.setVerdicts(try watches.openItems(watchId: watch.id).map { item in
            PRVerdictInput(
                itemId: item.id!, verdict: .decision, approach: "Direction.",
                decisionQuestion: "Keep \(item.githubNodeId)?", decisionOptions: [.init(label: "Yes", verdict: .fix), .init(label: "No", verdict: .fix)]
            )
        }, watchId: watch.id)
    }

    /// SPEC §13.4: one banner per decision, routed to its row, however many polls see it open.
    func testEachDecisionBannersOnceAndRoutesToItsRow() async throws {
        try enable()
        answer(pullRequest(threads: [thread("T_1", by: "reviewer"), thread("T_2", by: "reviewer")]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        try decideEveryOpenItem(watch)
        await fixture.supervisor.pollPRWatches()
        await fixture.supervisor.pollPRWatches()

        XCTAssertEqual(
            banners.map(\.title), Array(repeating: "Pull request decision waiting — \(fixture.project.name)", count: 2)
        )
        XCTAssertEqual(banners.first?.route, NotificationRoute(projectId: fixture.project.id, subject: .pullRequest(watch.id)))
    }

    /// SPEC §13.1: a paused watch keeps following its pull request, and raises no banner, badge count
    /// or decision signal while paused.
    func testAPausedWatchStillTracksItsPullRequestButRaisesNothing() async throws {
        try enable()
        answer(pullRequest(checks: "PENDING", threads: [thread("T_1", by: "reviewer")]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        try watches.setPaused(true, watchId: watch.id)
        try decideEveryOpenItem(watch)
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching)
        XCTAssertNil(try ProjectAttentionStore(fixture.db).attention(projectId: fixture.project.id)?
            .cause(.pullRequestDecision))

        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)
        XCTAssertTrue(banners.isEmpty, banners.map(\.title).description)
        XCTAssertNil(try watches.badgeCounts()[fixture.project.id])
    }

    func testNoConfiguredChecksCountAsGreenButPendingChecksDoNot() async throws {
        try enable()
        answer(pullRequest(checks: nil))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)

        answer(pullRequest(checks: "PENDING"))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching)
    }

    func testAnUnresolvedThreadSettlesItWithOneOpenItem() async throws {
        try enable()
        answer(pullRequest(threads: [
            thread("T_open", by: "reviewer"),
            thread("T_resolved", by: "reviewer", resolved: true),
            thread("T_outdated", by: "reviewer", outdated: true),
            thread("T_mine", by: "me"),
        ]))
        await fixture.supervisor.pollPRWatches()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .settling)
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

    /// Only a missing `origin` skips a project quietly; one git cannot read counts as a failing poll.
    func testAnOriginGitCannotReadRaisesAttentionAfterRepeatedPolls() async throws {
        try enable()
        try fixture.breakOriginConfig()
        answer(pullRequest())
        let attention = ProjectAttentionStore(fixture.db)
        for _ in 1..<WorkerSupervisor.prWatchFailuresBeforeAttention {
            await fixture.supervisor.pollPRWatches()
        }
        XCTAssertEqual(try attention.attention(projectId: fixture.project.id)?.has(.prPollUnavailable), false)

        await fixture.supervisor.pollPRWatches()
        let cause = try XCTUnwrap(try attention.attention(projectId: fixture.project.id)?.cause(.prPollUnavailable))
        XCTAssertTrue(cause.text.contains("origin"), cause.text)
    }

    private var searches: Int {
        fixture.gh.calls.filter { $0 == PullRequestWatchReader.searchArguments }.count
    }

    func testMeteringTicksDuringASlowPollQueueNoPollBehindIt() async throws {
        try enable()
        answer(pullRequest())
        fixture.gh.holdSearch()
        await fixture.supervisor.meterTick()
        for _ in 0..<500 where searches == 0 { try await _Concurrency.Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(searches, 1)

        for _ in 0..<2 {
            clock.advance(seconds: TimeInterval(WorkerSupervisor.prWatchPollIntervalMillis / 1000) + 1)
            await fixture.supervisor.meterTick()
        }
        fixture.gh.releaseSearch()
        await fixture.supervisor.pollPRWatches()
        try await _Concurrency.Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(searches, 2, "only the direct call polled after the slow one")
    }
}
