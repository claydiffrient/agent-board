import AgentBoardCore
import AgentBoardRuntime
import Foundation
import GRDB
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
        _ number: Int = 12, head: String = "c0ffee", decision: String? = "APPROVED", labels: [String] = [],
        checks: String? = "SUCCESS", required: [String] = [], reported: [[String: Any]] = [],
        threads: [[String: Any]] = [], reviews: [[String: Any]]? = nil, requests: [[String: Any]] = [],
        mergeable: String = "MERGEABLE", fork: String? = nil
    ) -> [String: Any] {
        let rollup: Any = checks.map { ["state": $0, "contexts": ["nodes": reported]] } ?? NSNull()
        let protection: Any = required.isEmpty ? NSNull() : ["requiredStatusCheckContexts": required]
        return [
            "number": number, "url": "https://github.com/\(repository)/pull/\(number)", "title": "Add widgets",
            "isDraft": false, "headRefName": "add-widgets", "headRefOid": head, "baseRefName": "main",
            "baseRef": ["refUpdateRule": protection, "rules": ["nodes": []]],
            "reviewDecision": decision ?? NSNull(), "mergeable": mergeable,
            "isCrossRepository": fork != nil,
            "headRepository": ["nameWithOwner": fork ?? repository],
            "labels": ["nodes": labels.map { ["name": $0] }],
            "commits": ["nodes": [["commit": ["statusCheckRollup": rollup]]]],
            "reviewThreads": ["nodes": threads],
            "reviews": ["nodes": reviews ?? [review("R_ok", by: "approver", state: "APPROVED", at: "2026-10-20T09:00:00Z")]],
            "timelineItems": ["nodes": requests],
        ]
    }

    private func review(_ id: String, by author: String, state: String, at submitted: String) -> [String: Any] {
        ["id": id, "state": state, "body": "", "url": "\(url)#\(id)", "submittedAt": submitted, "author": ["login": author]]
    }

    private func reviewRequest(of reviewer: String, at created: String, removed: Bool = false) -> [String: Any] {
        [
            "__typename": removed ? "ReviewRequestRemovedEvent" : "ReviewRequestedEvent",
            "createdAt": created, "requestedReviewer": ["login": reviewer],
        ]
    }

    private func checkRun(
        _ name: String, status: String = "COMPLETED", conclusion: String?, startedAt: String? = nil, required: Bool = false
    ) -> [String: Any] {
        [
            "name": name, "status": status, "conclusion": conclusion ?? NSNull(), "startedAt": startedAt ?? NSNull(),
            "isRequired": required,
        ]
    }

    private func statusContext(_ context: String, state: String, required: Bool = false) -> [String: Any] {
        ["context": context, "state": state, "isRequired": required]
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

    /// Branch protection's required counts and code owners live only in GitHub's decision.
    func testOneApprovalIsNotReadyWhileGitHubStillRequiresReview() async throws {
        try enable()
        answer(pullRequest(decision: "REVIEW_REQUIRED"))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching)
    }

    func testAReRequestedChangesRequestedWaitsOnReviewersWithoutBecomingReady() async throws {
        try enable()
        answer(pullRequest(
            head: "decaf0", decision: "CHANGES_REQUESTED",
            reviews: [
                review("R_ok", by: "approver", state: "APPROVED", at: "2026-10-20T09:00:00Z"),
                review("R_changes", by: "reviewer", state: "CHANGES_REQUESTED", at: "2026-10-20T10:00:00Z"),
            ],
            requests: [reviewRequest(of: "reviewer", at: "2026-10-20T11:00:00Z")]
        ))
        await fixture.supervisor.pollPRWatches()

        XCTAssertEqual(try onlyWatch().state, .watching)
        XCTAssertEqual(try watches.page(projectId: fixture.project.id).map(\.group), [.waitingOnReviewers])
    }

    /// With no review requirement GitHub's decision is null, and each reviewer's standing decides.
    func testWithNoReviewRequirementOneApprovalIsReadyUntilAReviewerBlocks() async throws {
        try enable()
        let approval = review("R_ok", by: "approver", state: "APPROVED", at: "2026-10-20T09:00:00Z")
        answer(pullRequest(decision: nil, reviews: [approval]))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)

        answer(pullRequest(
            decision: nil,
            reviews: [approval, review("R_changes", by: "reviewer", state: "CHANGES_REQUESTED", at: "2026-10-20T10:00:00Z")],
            requests: [reviewRequest(of: "reviewer", at: "2026-10-20T08:00:00Z")]
        ))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching, "a request older than the CHANGES_REQUESTED does not clear it")
    }

    func testRemovingAReRequestRestoresTheBlock() async throws {
        try enable()
        let reviews = [
            review("R_ok", by: "approver", state: "APPROVED", at: "2026-10-20T09:00:00Z"),
            review("R_changes", by: "reviewer", state: "CHANGES_REQUESTED", at: "2026-10-20T10:00:00Z"),
        ]
        let request = reviewRequest(of: "reviewer", at: "2026-10-20T11:00:00Z")
        answer(pullRequest(decision: nil, reviews: reviews, requests: [request]))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)

        answer(pullRequest(
            decision: nil, reviews: reviews,
            requests: [request, reviewRequest(of: "reviewer", at: "2026-10-20T12:00:00Z", removed: true)]
        ))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching)
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

    func testThePullRequestsOwnRequiredFlagsGateReadinessWhenProtectionReadsNothing() async throws {
        try enable()
        let unflagged = [
            checkRun("build", conclusion: "SUCCESS"), checkRun("lint", conclusion: "SUCCESS"),
            statusContext("manual-check", state: "PENDING"),
        ]
        answer(pullRequest(checks: "PENDING", reported: unflagged))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().checksState, "PENDING", "with nothing required, every check and the rollup count")

        answer(pullRequest(checks: "PENDING", reported: [
            checkRun("build", conclusion: "SUCCESS", required: true),
            checkRun("lint", conclusion: "SUCCESS", required: true),
            statusContext("manual-check", state: "PENDING"),
        ]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.checksState, "SUCCESS")
        XCTAssertEqual(watch.state, .readyToVerify)
    }

    func testARequiredCheckOnlyProtectionNamesIsPendingUntilItReports() async throws {
        try enable()
        answer(pullRequest(checks: "SUCCESS", required: ["deploy"], reported: [
            checkRun("build", conclusion: "SUCCESS", required: true),
        ]))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.checksState, "PENDING")
        XCTAssertEqual(watch.state, .watching)
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

    /// SPEC §13.1: a conflict is feedback keyed to its head, and it is handled once GitHub can merge the PR.
    func testAConflictingPullRequestGetsAConflictItemUntilItMergesCleanly() async throws {
        try enable()
        answer(pullRequest(mergeable: "CONFLICTING"))
        await fixture.supervisor.pollPRWatches()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .settling)
        let conflict = try XCTUnwrap(try watches.items(watchId: watch.id).first)
        XCTAssertEqual(conflict.kind, .conflict)
        XCTAssertEqual(conflict.githubNodeId, PRItem.conflictNodeId(head: "c0ffee"))
        XCTAssertEqual(conflict.state, .open)

        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try watches.items(watchId: watch.id).map(\.state), [.handled])
    }

    func testAForkPullRequestParksWithAReasonNamingTheFork() async throws {
        try enable()
        answer(pullRequest(threads: [thread("T_open", by: "reviewer")], fork: "someone/app"))
        await fixture.supervisor.pollPRWatches()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .parked)
        XCTAssertTrue(watch.parkedReason?.contains("`someone/app`") == true, watch.parkedReason ?? "")
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
