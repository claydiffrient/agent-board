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
    private let otherRepository = "other-org/widgets"
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

    /// A second project with its own repository and PR follow-through on, for the tests that check a
    /// Refresh keeps another project's watches and failures out of its own section.
    private func registerProjectB() throws -> Project {
        let repoPath = fixture.supportDir.appendingPathComponent("repoB")
        try SupervisorFixture.initRepo(at: repoPath)
        try fixture.git(["remote", "add", "origin", "git@github.com:\(otherRepository).git"], cwd: repoPath)
        let project = try ProjectStore(fixture.db).register(
            name: "Other", repoPath: repoPath.path, baseBranch: "main",
            worktreeRoot: fixture.supportDir.appendingPathComponent("worktreesB").path,
            memoryDir: fixture.supportDir.appendingPathComponent("memoryB").path
        )
        var settings = project.settings
        settings.prFollowThrough = PRFollowThroughSettings(enabled: true, verificationLabel: label)
        try ProjectStore(fixture.db).updateSettings(project.id, settings)
        return project
    }

    private func pullRequest(
        _ number: Int = 12, repository: String? = nil, head: String = "c0ffee", decision: String? = "APPROVED",
        labels: [String] = [],
        checks: String? = "SUCCESS", required: [String] = [], reported: [[String: Any]] = [],
        threads: [[String: Any]] = [], reviews: [[String: Any]]? = nil, requests: [[String: Any]] = [],
        comments: [[String: Any]] = [], committedAt: String = "2026-10-20T08:00:00Z",
        mergeable: String = "MERGEABLE", fork: String? = nil
    ) -> [String: Any] {
        let repo = repository ?? self.repository
        let rollup: Any = checks.map { ["state": $0, "contexts": ["nodes": reported]] } ?? NSNull()
        let protection: Any = required.isEmpty ? NSNull() : ["requiredStatusCheckContexts": required]
        return [
            "number": number, "url": "https://github.com/\(repo)/pull/\(number)", "title": "Add widgets",
            "isDraft": false, "headRefName": "add-widgets", "headRefOid": head, "baseRefName": "main",
            "baseRef": ["refUpdateRule": protection, "rules": ["nodes": []]],
            "reviewDecision": decision ?? NSNull(), "mergeable": mergeable,
            "isCrossRepository": fork != nil,
            "headRepository": ["nameWithOwner": fork ?? repo],
            "labels": ["nodes": labels.map { ["name": $0] }],
            "commits": ["nodes": [["commit": ["committedDate": committedAt, "statusCheckRollup": rollup]]]],
            "reviewThreads": ["nodes": threads],
            "reviews": ["nodes": reviews ?? [review("R_ok", by: "approver", state: "APPROVED", at: "2026-10-20T09:00:00Z")]],
            "timelineItems": ["nodes": requests],
            "comments": ["nodes": comments],
        ]
    }

    private func comment(_ id: String, by author: String, body: String = "Make this the default.", at created: String) -> [String: Any] {
        ["id": id, "author": ["login": author], "body": body, "url": "\(url)#\(id)", "createdAt": created]
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

    private func thread(
        _ id: String, by author: String, body: String = "Rename this.", resolved: Bool = false, outdated: Bool = false,
        at created: String? = nil
    ) -> [String: Any] {
        var comment: [String: Any] = [
            "author": ["login": author], "body": body, "url": "\(url)#\(id)", "path": "Sources/App.swift", "line": 3,
        ]
        if let created { comment["createdAt"] = created }
        return ["id": id, "isResolved": resolved, "isOutdated": outdated, "comments": ["nodes": [comment]]]
    }

    private func answer(_ pr: [String: Any]) {
        fixture.gh.answerSearch([AuthoredPullRequest(repository: repository, number: 12, url: url, title: "Add widgets")])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [pr])
    }

    /// A blank CHANGES_REQUESTED review is an item; this stands in for the triage that handled it.
    private func handleEveryItemAndPoll() async throws {
        try await fixture.db.writer.write {
            try $0.execute(sql: "UPDATE pr_item SET state = 'handled', verdict = 'answer', handled_at = ?", arguments: [Int64.nowMillis])
        }
        await fixture.supervisor.pollPRWatches()
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
        try await handleEveryItemAndPoll()

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
        try await handleEveryItemAndPoll()
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
        try await handleEveryItemAndPoll()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify)

        answer(pullRequest(
            decision: nil, reviews: reviews,
            requests: [request, reviewRequest(of: "reviewer", at: "2026-10-20T12:00:00Z", removed: true)]
        ))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try onlyWatch().state, .watching)
    }

    /// SPEC §13.1: conversation comments newer than the head commit, and blank change requests, are feedback.
    func testConversationCommentsAfterTheHeadCommitAndBlankChangeRequestsBecomeItems() async throws {
        try enable()
        let comments = [
            comment("C_after", by: "reviewer", at: "2026-10-22T21:51:59Z"),
            comment("C_before", by: "reviewer", at: "2026-10-22T19:00:00Z"),
            comment("C_mine", by: "me", at: "2026-10-22T21:55:00Z"),
            comment("C_hidden", by: "reviewer", body: "<!-- bot state -->\n", at: "2026-10-22T21:56:00Z"),
        ]
        let reviews = [
            review("R_changes", by: "reviewer", state: "CHANGES_REQUESTED", at: "2026-10-22T22:03:05Z"),
            review("R_comment", by: "commenter", state: "COMMENTED", at: "2026-10-22T22:04:00Z"),
        ]
        answer(pullRequest(
            decision: "CHANGES_REQUESTED", reviews: reviews, comments: comments, committedAt: "2026-10-22T20:00:00Z"
        ))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()
        let items = try watches.items(watchId: watch.id)

        XCTAssertEqual(items.map(\.githubNodeId).sorted(), ["C_after", "R_changes"])
        XCTAssertEqual(items.first { $0.githubNodeId == "C_after" }?.kind, .comment)
        XCTAssertEqual(
            items.first { $0.githubNodeId == "R_changes" }?.body,
            PRSnapshotItem.emptyChangeRequestBody(author: "reviewer")
        )

        answer(pullRequest(
            head: "decaf0", decision: "CHANGES_REQUESTED", reviews: reviews, comments: comments,
            committedAt: "2026-10-22T23:00:00Z"
        ))
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(
            try watches.items(watchId: watch.id).first { $0.githubNodeId == "C_after" }?.state, .open,
            "a push past the comment does not handle it untriaged"
        )
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

    /// SPEC §13.1: a push outdating a thread keeps the fix or triage owed on it; the viewer's own reply retires an untriaged item.
    func testAnOutdatedThreadKeepsItsItemOpenWhileTheViewersReplyRetiresAnUntriagedOne() async throws {
        try enable()
        answer(pullRequest(threads: [
            thread("T_fix", by: "reviewer"), thread("T_moved", by: "reviewer"), thread("T_replied", by: "reviewer"),
        ]))
        await fixture.supervisor.pollPRWatches()
        try await fixture.db.writer.write {
            try $0.execute(sql: "UPDATE pr_item SET verdict = 'fix' WHERE github_node_id = 'T_fix'")
        }

        answer(pullRequest(head: "decaf0", threads: [
            thread("T_fix", by: "reviewer", outdated: true), thread("T_moved", by: "reviewer", outdated: true),
            thread("T_replied", by: "me", body: "Won't fix."),
        ]))
        await fixture.supervisor.pollPRWatches()

        let items = Dictionary(uniqueKeysWithValues: try watches.items(watchId: try onlyWatch().id).map { ($0.githubNodeId, $0) })
        XCTAssertEqual(items["T_fix"]?.state, .open)
        XCTAssertEqual(items["T_fix"]?.verdict, .fix)
        XCTAssertEqual(items["T_moved"]?.state, .open)
        XCTAssertEqual(items["T_replied"]?.state, .handled)
    }

    /// SPEC §13.1: triage never sees what a reviewer hid from humans in an HTML comment.
    func testHiddenHTMLCommentsAreStrippedAndFeedbackWithNothingVisibleIsNoItem() async throws {
        try enable()
        var hidden = review("R_hidden", by: "bot", state: "COMMENTED", at: "2026-10-20T10:00:00Z")
        hidden["body"] = "<!-- bot {\"findings\": [\"rename x\"]} -->\n  \n"
        var visible = review("R_visible", by: "reviewer", state: "COMMENTED", at: "2026-10-20T10:00:00Z")
        visible["body"] = "Please add a test.\n<!-- bot\n{\"findings\": []}\n-->"
        answer(pullRequest(threads: [thread("T_hidden", by: "bot", body: "<!-- bot {} -->")], reviews: [hidden, visible]))
        await fixture.supervisor.pollPRWatches()

        let items = try watches.items(watchId: try onlyWatch().id)
        XCTAssertEqual(items.map(\.githubNodeId), ["R_visible"])
        XCTAssertEqual(items.first?.body.contains("<!--"), false)
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

    /// SPEC §13.4 Refresh: a section's button reads only that section's pull requests and applies
    /// what they now say without waiting for a tick.
    func testRefreshingASectionPollsOnlyItsWatchesAndAppliesTheirTransition() async throws {
        try enable()
        let numbers = [12, 13]
        fixture.gh.answerSearch(numbers.map {
            AuthoredPullRequest(repository: repository, number: $0, url: "https://github.com/\(repository)/pull/\($0)", title: "Add widgets")
        })
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: numbers.map { pullRequest($0, checks: "PENDING") })
        await fixture.supervisor.pollPRWatches()
        let live = try watches.live(projectId: fixture.project.id)
        let waiting = try XCTUnwrap(live.first { $0.number == 12 })
        let elsewhere = try XCTUnwrap(live.first { $0.number == 13 })
        try watches.setState(.settling, watchId: elsewhere.id)
        try await fixture.db.writer.write {
            try $0.execute(sql: "UPDATE pr_watch SET last_polled_at = 1 WHERE id = ?", arguments: [elsewhere.id])
        }

        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: numbers.map { pullRequest($0) })
        try await fixture.supervisor.pollPRWatches(watchIds: [waiting.id])

        XCTAssertEqual(try watches.get(waiting.id)?.state, .readyToVerify)
        let untouched = try XCTUnwrap(watches.get(elsewhere.id))
        XCTAssertEqual(untouched.state, .settling)
        XCTAssertEqual(untouched.lastPolledAt, 1)
        XCTAssertEqual(
            fixture.gh.calls.last { $0.first == "api" },
            PullRequestWatchReader.graphQLArguments(owner: "example-org", name: "app", numbers: [12])
        )
    }

    func testARefreshDuringATickPollJoinsItAndStillAppliesItsResult() async throws {
        try enable()
        answer(pullRequest(checks: "PENDING"))
        await fixture.supervisor.pollPRWatches()
        let watch = try onlyWatch()

        answer(pullRequest())
        fixture.gh.holdSearch()
        await fixture.supervisor.meterTick()
        for _ in 0..<500 where searches == 1 { try await _Concurrency.Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(searches, 2)
        XCTAssertTrue(fixture.supervisor.isPollingPRWatches)

        let refresh = _Concurrency.Task { try await fixture.supervisor.pollPRWatches(watchIds: [watch.id]) }
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        fixture.gh.releaseSearch()
        try await refresh.value

        XCTAssertEqual(searches, 2, "the refresh joined the tick's poll")
        XCTAssertEqual(try watches.get(watch.id)?.state, .readyToVerify)
        XCTAssertFalse(fixture.supervisor.isPollingPRWatches)
    }

    /// SPEC §13.4 Refresh: a Refresh that joins a wider poll keeps only the failures for its own
    /// projects (Rita's review of cfd04afd). Project A's `origin` is unreadable throughout; a Refresh
    /// for project B's section, joining the tick poll that read both, must not see A's failure — while
    /// A's own repeated failures still raise its attention exactly as an unscoped poll would.
    func testARefreshJoiningATickPollDropsAnotherProjectsOriginFailure() async throws {
        try enable()
        let projectB = try registerProjectB()

        fixture.gh.answerSearch([AuthoredPullRequest(
            repository: otherRepository, number: 7, url: "https://github.com/\(otherRepository)/pull/7", title: "Add gadgets"
        )])
        fixture.gh.answerGraphQL(
            repository: otherRepository, viewer: "me", pullRequests: [pullRequest(7, repository: otherRepository)]
        )
        await fixture.supervisor.pollPRWatches()
        let watchB = try XCTUnwrap(try watches.live(projectId: projectB.id).first)

        try fixture.breakOriginConfig()
        fixture.gh.holdSearch()
        await fixture.supervisor.meterTick()
        for _ in 0..<500 where searches == 1 { try await _Concurrency.Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(searches, 2)
        XCTAssertTrue(fixture.supervisor.isPollingPRWatches)

        let refresh = _Concurrency.Task { try await fixture.supervisor.pollPRWatches(watchIds: [watchB.id]) }
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        fixture.gh.releaseSearch()
        try await refresh.value

        let attention = ProjectAttentionStore(fixture.db)
        for _ in 1..<WorkerSupervisor.prWatchFailuresBeforeAttention {
            await fixture.supervisor.pollPRWatches()
        }
        let cause = try XCTUnwrap(try attention.attention(projectId: fixture.project.id)?.cause(.prPollUnavailable))
        XCTAssertTrue(cause.text.contains("origin"), cause.text)
    }

    /// SPEC §13.4 Refresh: the advance step is scoped too, not only the read (Rita's review of
    /// cfd04afd). A settling watch whose settle window has already passed is ready to start triage the
    /// moment `advancePRWatches` reaches it; a Refresh for a different watch must still leave it alone.
    func testARefreshDoesNotAdvanceASettledWatchOutsideItsScope() async throws {
        try enable()
        fixture.supervisor.isOnACPower = { true }

        let numbers = [12, 13]
        fixture.gh.answerSearch(numbers.map {
            AuthoredPullRequest(repository: repository, number: $0, url: "https://github.com/\(repository)/pull/\($0)", title: "Add widgets")
        })
        fixture.gh.answerGraphQL(
            repository: repository, viewer: "me", pullRequests: numbers.map { pullRequest($0, threads: [thread("T_\($0)", by: "reviewer")]) }
        )
        await fixture.supervisor.pollPRWatches()
        let live = try watches.live(projectId: fixture.project.id)
        let inScope = try XCTUnwrap(live.first { $0.number == 12 })
        let outOfScope = try XCTUnwrap(live.first { $0.number == 13 })
        XCTAssertEqual(outOfScope.state, .settling)
        XCTAssertEqual(outOfScope.round, 0)

        // The settle window just passed for every watch, so advancePRWatches is now ready to start a
        // triage round for anything in its scope.
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.prFollowThrough.settleMinutes = 0
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        fixture.gh.answerGraphQL(
            repository: repository, viewer: "me", pullRequests: numbers.map { pullRequest($0, threads: [thread("T_\($0)", by: "reviewer")]) }
        )
        try await fixture.supervisor.pollPRWatches(watchIds: [inScope.id])

        let touched = try XCTUnwrap(watches.get(inScope.id))
        XCTAssertEqual(touched.round, 1, "the in-scope watch should have started a triage round, proving the window had passed")
        let untouched = try XCTUnwrap(watches.get(outOfScope.id))
        XCTAssertEqual(untouched.round, 0, "advancePRWatches must not start a round for a watch outside the Refresh's scope")
        XCTAssertEqual(untouched.state, .settling)
    }

    // MARK: - Takeover adoption (SPEC §13.8)

    private func adoptedWatch(author: String = "colleague", recordedAt: Int64 = .nowMillis) throws -> PRWatch {
        let takeover = try XCTUnwrap(TakeoverStore(fixture.db).record(projectId: fixture.project.id, TakeoverCandidate(
            githubNodeId: "PR_12", kind: .pr, number: 12, url: url, title: "Add widgets", author: author
        ), now: recordedAt))
        return try XCTUnwrap(watches.adopt(takeover))
    }

    func testAnAdoptedWatchIsPolledAndAdvancesThoughTheAuthorSearchDoesNotReturnIt() async throws {
        try enable()
        let adopted = try adoptedWatch()
        fixture.gh.answerSearch([])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [pullRequest()])

        await fixture.supervisor.pollPRWatches()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.id, adopted.id)
        XCTAssertEqual(watch.headOid, "c0ffee")
        XCTAssertEqual(watch.state, .readyToVerify)
        XCTAssertFalse(watch.authored)
        XCTAssertTrue(watch.adopted)
    }

    /// The viewer's own open feedback from before the takeover is the takeover round's work, and feedback
    /// written after it or with no date is not; once that round has started, a new comment of the viewer's
    /// is ignored as on any watch.
    func testRoundOneOfAnAdoptedWatchTakesTheViewersOpenThreadAndALaterRoundIgnoresANewOne() async throws {
        try enable()
        let takenOver = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z"))
        let adopted = try adoptedWatch(recordedAt: Int64(takenOver.timeIntervalSince1970 * 1000))
        let mine = thread("T_mine", by: "me", at: "2026-10-20T09:00:00.250Z")
        fixture.gh.answerSearch([])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [
            pullRequest(
                threads: [mine, thread("T_undated", by: "me", body: "Undated.")],
                comments: [comment("C_ack", by: "me", body: "Taking this over.", at: "2026-10-20T11:00:00Z")]
            ),
        ])
        await fixture.supervisor.pollPRWatches()
        XCTAssertEqual(try watches.items(watchId: adopted.id).map(\.githubNodeId), ["T_mine"])

        try await fixture.db.writer.write {
            try $0.execute(sql: "UPDATE pr_watch SET round = 1, state = 'watching' WHERE id = ?", arguments: [adopted.id])
        }
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [
            pullRequest(threads: [mine, thread("T_new", by: "me", body: "Also rename that.")]),
        ])
        await fixture.supervisor.pollPRWatches()

        let items = try watches.items(watchId: adopted.id)
        XCTAssertEqual(items.map(\.githubNodeId), ["T_mine"])
        XCTAssertEqual(items.first?.state, .open, "the takeover round's item stays while the viewer's comment is still the latest")
    }

    func testATakenOverForkIsMarkedFailedAndNothingIsPosted() async throws {
        try enable()
        let takeover = TakeoverSettings(
            enabled: true, triggerLabels: ["handoff-example"], ackLabel: "taken-example", ackComment: "Taking this over."
        )
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.takeover = takeover
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        fixture.gh.answer(
            arguments: TakeoverDiscovery.searchArguments(takeover, repository: repository),
            stdout: #"[{"id":"PR_12","number":12,"url":"\#(url)","title":"Add widgets","isPullRequest":true,"author":{"login":"colleague"}}]"#
        )
        fixture.gh.answer(
            arguments: TakeoverDiscovery.nodesArguments(ids: ["PR_12"]),
            stdout: #"{"data":{"viewer":{"login":"me"},"nodes":[{"__typename":"PullRequest","id":"PR_12","state":"OPEN","isCrossRepository":true,"labels":{"nodes":[{"name":"handoff-example"}]},"assignees":{"nodes":[{"login":"me"}]},"closingIssuesReferences":{"nodes":[]}}]}}"#
        )

        await fixture.supervisor.pollTakeovers()

        let row = try XCTUnwrap(TakeoverStore(fixture.db).page(projectId: fixture.project.id).first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertTrue(row.failure?.contains("fork") == true, row.failure ?? "")
        XCTAssertEqual(try watches.live(projectId: fixture.project.id), [])
        XCTAssertEqual(fixture.gh.calls.map { Array($0.prefix(2)) }, [["search", "issues"], ["api", "graphql"]])
    }

    func testATakenOverPRWhoseWatchWasStoppedWaitsAndReleasingTheHumansOwnKeepsItsFollowThrough() async throws {
        try enable()
        answer(pullRequest())
        await fixture.supervisor.pollPRWatches()
        let own = try onlyWatch()
        XCTAssertTrue(own.authored)
        try await fixture.db.writer.write {
            try $0.execute(sql: "UPDATE pr_watch SET state = 'stopped' WHERE id = ?", arguments: [own.id])
        }
        let takeover = TakeoverSettings(
            enabled: true, triggerLabels: ["handoff-example"], ackLabel: "taken-example", ackComment: "Taking this over."
        )
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.takeover = takeover
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
        fixture.gh.answer(
            arguments: TakeoverDiscovery.searchArguments(takeover, repository: repository),
            stdout: #"[{"id":"PR_12","number":12,"url":"\#(url)","title":"Add widgets","isPullRequest":true,"author":{"login":"me"}}]"#
        )
        func answerNode(labels: String) {
            fixture.gh.answer(
                arguments: TakeoverDiscovery.nodesArguments(ids: ["PR_12"]),
                stdout: #"{"data":{"viewer":{"login":"me"},"nodes":[{"__typename":"PullRequest","id":"PR_12","state":"OPEN","isCrossRepository":false,"labels":{"nodes":[\#(labels)]},"assignees":{"nodes":[{"login":"me"}]},"closingIssuesReferences":{"nodes":[]}}]}}"#
            )
        }
        answerNode(labels: #"{"name":"handoff-example"}"#)
        fixture.gh.answer(prefix: ["label", "list"], stdout: #"[{"name":"taken-example"}]"#)
        fixture.gh.answer(prefix: ["pr", "edit"], stdout: "")
        fixture.gh.answer(prefix: ["pr", "comment"], stdout: "")
        let takeovers = TakeoverStore(fixture.db)

        await fixture.supervisor.pollTakeovers()

        var row = try XCTUnwrap(takeovers.page(projectId: fixture.project.id).first)
        XCTAssertEqual(row.state, .found)
        XCTAssertTrue(row.failure?.contains("stopped") == true, row.failure ?? "")
        XCTAssertEqual(try onlyWatch().state, .stopped)
        XCTAssertFalse(try onlyWatch().adopted)
        XCTAssertFalse(fixture.gh.calls.contains { $0.starts(with: ["pr", "edit"]) }, "nothing is acknowledged")

        _ = try watches.resume(watchId: own.id)
        await fixture.supervisor.pollTakeovers()
        row = try XCTUnwrap(takeovers.get(row.id))
        XCTAssertEqual(row.state, .watched)
        XCTAssertNil(row.failure)
        XCTAssertTrue(try onlyWatch().adopted)

        answerNode(labels: "")
        await fixture.supervisor.pollTakeovers()
        await fixture.supervisor.pollPRWatches()

        XCTAssertEqual(try takeovers.get(row.id)?.state, .released)
        let after = try onlyWatch()
        XCTAssertNotEqual(after.state, .stopped, "the human's own pull request keeps its follow-through")
        XCTAssertFalse(after.adopted)
        XCTAssertNil(after.takeoverId)
    }

    // MARK: - Manual adoption (SPEC §13.8)

    private func answerView(state: String = "OPEN", fork: Bool = false) {
        fixture.gh.answer(
            arguments: PullRequestAdopter.arguments(number: 12, repository: repository),
            stdout: #"{"number":12,"url":"\#(url)","title":"Add widgets","state":"\#(state)","isCrossRepository":\#(fork)}"#
        )
    }

    private func decisions() throws -> [String] {
        try fixture.reports.unconsumed(projectId: fixture.project.id).filter { $0.kind == .decision }.map(\.body)
    }

    /// A granted `watch_pr` adopts with no takeover row: the human's earlier feedback is round 1's work, nothing is
    /// posted on GitHub, no release sweep touches it, and only Stop watching lets it go.
    func testAGrantedWatchPRAdoptsAnOpenPullRequestThatOnlyStopWatchingReleases() async throws {
        try enable()
        answerView()
        fixture.gh.answerSearch([])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [
            pullRequest(threads: [thread("T_mine", by: "me", at: "2026-10-20T09:00:00Z")]),
        ])
        let approval = try fixture.board.requestWatchAdoption(
            projectId: fixture.project.id, number: 12, reason: "Reassigned to the human.", requestedBy: "orchestrator"
        )

        try await fixture.supervisor.approve(approvalId: approval.id)

        let watch = try onlyWatch()
        XCTAssertTrue(watch.isManualAdoption)
        XCTAssertFalse(watch.authored)
        XCTAssertEqual(watch.headOid, "c0ffee", "adopting polls the new watch at once")
        XCTAssertEqual(try watches.items(watchId: watch.id).map(\.githubNodeId), ["T_mine"])
        XCTAssertEqual(try decisions(), ["#12 Add widgets adopted into follow-through: Reassigned to the human."])
        XCTAssertEqual(Set(fixture.gh.calls.map { Array($0.prefix(2)) }), [["pr", "view"], ["search", "prs"], ["api", "graphql"]])

        try watches.stopReleasedAdoptions(projectId: fixture.project.id)
        XCTAssertNotEqual(try onlyWatch().state, .stopped)
        try await fixture.db.writer.write {
            try $0.execute(sql: "UPDATE pr_watch SET state = 'settling' WHERE id = ?", arguments: [watch.id])
        }
        try watches.stopWatching(watchId: watch.id)
        XCTAssertEqual(try watches.get(watch.id)?.state, .stopped)
    }

    func testAForkOrClosedPullRequestIsRefusedFromThePageAndFromAGrant() async throws {
        try enable()
        answerView(state: "CLOSED")
        do {
            try await fixture.supervisor.watchPullRequest(number: 12, projectId: fixture.project.id)
            XCTFail("a closed pull request was adopted")
        } catch {
            XCTAssertTrue(errorText(error).contains("closed"), errorText(error))
        }

        answerView(fork: true)
        let approval = try fixture.board.requestWatchAdoption(
            projectId: fixture.project.id, number: 12, reason: "Reassigned to the human.", requestedBy: "orchestrator"
        )
        do {
            try await fixture.supervisor.approve(approvalId: approval.id)
            XCTFail("a fork's pull request was adopted")
        } catch {}

        XCTAssertEqual(try watches.live(projectId: fixture.project.id), [])
        let reports = try decisions()
        XCTAssertEqual(reports.count, 1, "\(reports)")
        XCTAssertTrue(reports.first?.hasPrefix("#12 was not adopted: #12 comes from a fork.") == true, "\(reports)")
    }
}
