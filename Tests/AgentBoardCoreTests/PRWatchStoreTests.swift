import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

final class PRWatchStoreTests: XCTestCase {
    private func snapshot(number: Int = 7, head: String = "abc123", items: [PRSnapshotItem]) -> PRSnapshot {
        PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Add a widget",
            headRef: "feature/widget", headOid: head, baseRef: "main", reviewDecision: "REVIEW_REQUIRED",
            checksState: "SUCCESS", mergeable: "MERGEABLE", labels: ["needs-review"], items: items
        )
    }

    private func thread(_ id: String, body: String = "Rename this", resolved: Bool = false) -> PRSnapshotItem {
        PRSnapshotItem(
            githubNodeId: id, kind: .thread, author: "reviewer", body: body, path: "Sources/A.swift", line: 12,
            url: "https://github.com/example-org/app/pull/7#discussion_r1", isResolved: resolved
        )
    }

    func testUpsertIsIdempotentAndHandlesResolvedOrVanishedItems() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let first = snapshot(items: [thread("T1"), thread("T2", body: "Why not a set?")])

        let created = try store.upsert(projectId: f.project.id, snapshot: first, now: 1_000)
        let itemsAfterFirst = try store.items(watchId: created.id)
        XCTAssertEqual(itemsAfterFirst.map(\.state), [.open, .open])
        XCTAssertEqual(created.lastFeedbackAt, 1_000)
        XCTAssertEqual(created.labels, ["needs-review"])

        let again = try store.upsert(projectId: f.project.id, snapshot: first, now: 2_000)
        var expected = created
        expected.lastPolledAt = 2_000
        XCTAssertEqual(again, expected)
        XCTAssertEqual(try store.get(created.id), expected)
        XCTAssertEqual(try store.items(watchId: created.id), itemsAfterFirst)

        try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1", resolved: true)]), now: 3_000
        )
        let states = Dictionary(uniqueKeysWithValues: try store.items(watchId: created.id).map { ($0.githubNodeId, $0.state) })
        XCTAssertEqual(states, ["T1": .handled, "T2": .handled])

        try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1", body: "Still not renamed")]), now: 4_000
        )
        let reopened = try XCTUnwrap(store.items(watchId: created.id).first { $0.githubNodeId == "T1" })
        XCTAssertEqual(reopened.state, .open)
        XCTAssertEqual(try store.get(created.id)?.lastFeedbackAt, 4_000)
    }

    func testANewHeadOidStampsHeadChangedAtAndAnUnchangedSnapshotLeavesItAlone() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let created = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: []), now: 1_000)
        XCTAssertNil(created.headChangedAt, "the head was already there when watching began")

        let pushed = try store.upsert(projectId: f.project.id, snapshot: snapshot(head: "def456", items: []), now: 2_000)
        XCTAssertEqual(pushed.headChangedAt, 2_000)

        let polled = try store.upsert(projectId: f.project.id, snapshot: snapshot(head: "def456", items: []), now: 3_000)
        XCTAssertEqual(polled.headChangedAt, 2_000)
        XCTAssertEqual(try store.get(created.id)?.headChangedAt, 2_000)
    }

    @discardableResult
    private func triage(_ f: Fixture, watchId: String, as verdict: PRItemVerdict) throws -> PRWatchState? {
        let store = PRWatchStore(f.db)
        try store.setState(.settling, watchId: watchId)
        XCTAssertNotNil(try store.beginTriageRound(watchId: watchId))
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET verdict = ?, approach = 'Rename it.' WHERE watch_id = ?",
                arguments: [verdict, watchId]
            )
        }
        return try f.board.applyVerdicts(watchId: watchId)
    }

    private func enableFollowThrough(_ f: Fixture, _ enabled: Bool) throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        settings.prFollowThrough.enabled = enabled
        try f.projects.updateSettings(f.project.id, settings)
    }

    func testStartingAFixRoundHoldsEveryFixItemAndClosesTheWatchsStaleBacklogFixTasks() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1"), thread("T2", body: "Use a set.")]), now: 1_000
        )
        let stale = try f.db.writer.write { db in
            let task = try TaskStore.insert(
                db, projectId: f.project.id, title: "Fix from #7: Rename this", body: nil, acceptance: nil,
                priority: nil, column: .backlog, origin: .followThrough, epicId: nil, type: .code
            )
            try db.execute(sql: "UPDATE pr_item SET fix_task_id = ? WHERE github_node_id = 'T1'", arguments: [task.id])
            return task
        }
        XCTAssertEqual(try triage(f, watchId: watch.id, as: .fix), .fixing)

        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: "fixer-model"))
        XCTAssertNil(try f.board.createFixRoundTask(watchId: watch.id, model: nil), "one task per round")
        XCTAssertEqual(task.column, .ready)
        XCTAssertEqual(task.origin, .fixRound)
        XCTAssertEqual(task.model, "fixer-model")
        for part in ["Rename this", "Use a set.", "Sources/A.swift:12", "Rename it.", "agentboard/pr-7-r1"] {
            XCTAssertTrue(task.body?.contains(part) == true, "\(part) is missing from:\n\(task.body ?? "")")
        }
        XCTAssertEqual(try store.rounds(watchId: watch.id).map(\.fixTaskId), [task.id])
        XCTAssertEqual(try store.items(watchId: watch.id).map(\.fixTaskId), [task.id, task.id])
        let closed = try XCTUnwrap(f.tasks.get(stale.id))
        XCTAssertEqual(closed.column, .closed)
        XCTAssertTrue(closed.closedReason?.contains("round 1") == true, closed.closedReason ?? "")
    }

    /// SPEC §13.1 parked: three fixer sessions ending without a report park the watch `fixer_failed`,
    /// naming the last stop reason. A shutdown wind-down sandwiched between them is not a failure and
    /// does not count toward the three. Also covers Board.terminate: a stranded fix_round task always
    /// returns to `ready`, even when its branch carries commits that would otherwise land in `review`.
    func testThreeFailedFixerSessionsParkTheWatchAndIgnoreAShutdownWindDown() throws {
        let f = try Fixture.make()
        try enableFollowThrough(f, true)
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))

        func failFixerSession(_ id: String, cause: SessionTermination, commitsAheadOfBase: Int) throws {
            try f.board.assign(taskId: task.id, session: f.session(id))
            try f.sessions.setState(id, .running)
            let salvage = BranchSalvage(branch: "agentboard/\(task.id)", commitsAheadOfBase: commitsAheadOfBase)
            _ = try f.board.terminate(sessionId: id, cause: cause, salvage: salvage)
            XCTAssertEqual(
                try f.tasks.get(task.id)?.column, .ready,
                "a stranded fix_round task must go back to ready, never review"
            )
        }

        try failFixerSession("fixer-1", cause: .vanished, commitsAheadOfBase: 0)
        try failFixerSession(
            "fixer-2", cause: .shutdownAcknowledged(note: "wound down mid-fix"), commitsAheadOfBase: 2
        )
        try failFixerSession("fixer-3", cause: .vanished, commitsAheadOfBase: 0)
        try failFixerSession("fixer-4", cause: .capBreach("idle cap reached"), commitsAheadOfBase: 4)

        XCTAssertTrue(try f.board.parkIfFixersFailing(watchId: watch.id))
        let parked = try XCTUnwrap(store.get(watch.id))
        XCTAssertEqual(parked.state, .parked)
        XCTAssertTrue(parked.parkedReason?.contains("ended without a report 3 times in a row") == true, parked.parkedReason ?? "")
        XCTAssertTrue(parked.parkedReason?.contains("idle cap reached") == true, parked.parkedReason ?? "")
        XCTAssertEqual(try store.rounds(watchId: watch.id).first?.outcome, PRRoundOutcome.fixerFailed.rawValue)
        let reports = try ReportStore(f.db).unconsumed(projectId: f.project.id).filter { $0.kind == .prFollowThrough }
        XCTAssertEqual(reports.map { $0.body.split(separator: "\n").last.map(String.init) }, [
            "round_fixer_failed: round 1 ended without a fix: its fixer kept stopping without a report",
            "parked: \(parked.parkedReason ?? "")",
        ])
    }

    @discardableResult
    private func checkRound(
        _ f: Fixture, watchId: String, taskId: String, attempt: Int, grade: (PRItem) -> PRFollowupGrade
    ) throws -> PRWatchState? {
        let store = PRWatchStore(f.db)
        let fixer = "fixer-\(attempt)"
        try f.board.assign(taskId: taskId, session: f.session(fixer))
        try f.sessions.setState(fixer, .running)
        try f.board.complete(taskId: taskId, sessionId: fixer, summary: "Fixed.")
        let check = try XCTUnwrap(f.board.createFollowupCheckTask(watchId: watchId, headOid: "tip-\(attempt)"))
        let round = try XCTUnwrap(store.currentRound(watchId: watchId))
        try store.setFollowupGrades(
            store.checkItems(round: round).map { PRGradeInput(itemId: $0.id ?? 0, grade: grade($0), note: "Still named n.") },
            taskId: check.id
        )
        try f.board.finishTriage(taskId: check.id, sessionId: nil, summary: "Graded.")
        try f.board.recordRoundReview(taskId: taskId, sessionId: nil, reviewerName: "Rita", accepted: true, text: "Fine.")
        return try f.board.settleCheck(watchId: watchId)
    }

    /// SPEC §13.1 parked: the Pull Requests page and the orchestrator's report show only the first line.
    func testAThirdFailedCheckParksWithTheFailingItemOnTheReasonsFirstLine() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        let itemId = try XCTUnwrap(store.items(watchId: watch.id).first?.id)

        for attempt in 1...PRWatchStore.failedChecksBeforePark {
            try checkRound(f, watchId: watch.id, taskId: task.id, attempt: attempt) { _ in .notFixed }
        }

        let parked = try XCTUnwrap(store.get(watch.id))
        XCTAssertEqual(parked.state, .parked)
        XCTAssertEqual(
            parked.parkedReason?.split(separator: "\n").first.map(String.init),
            "Round 1 failed its check 3 times: item \(itemId) not fixed (Rename it.)"
        )
        XCTAssertTrue(parked.parkedReason?.contains("Still named n.") == true, parked.parkedReason ?? "")
    }

    /// SPEC §13.1 dismissed items: a round left with nothing to check ends instead of failing its check.
    func testDismissingTheOnlyFixItemOfACheckingRoundEndsTheRound() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        try f.board.assign(taskId: task.id, session: f.session("fixer"))
        try f.sessions.setState("fixer", .running)
        try f.board.complete(taskId: task.id, sessionId: "fixer", summary: "Edited the description with gh.")
        let check = try XCTUnwrap(f.board.createFollowupCheckTask(watchId: watch.id, headOid: "tip"))
        let itemId = try XCTUnwrap(store.items(watchId: watch.id).first?.id)

        let after = try store.dismissItem(itemId: itemId, reason: "Done with gh pr edit.", by: PRWatchStore.humanDismissal)

        XCTAssertEqual(after.state, .watching)
        let round = try XCTUnwrap(store.currentRound(watchId: watch.id))
        XCTAssertEqual(round.outcome, PRRoundOutcome.triaged.rawValue)
        XCTAssertEqual(try store.checkItems(round: round), [])
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .closed)
        XCTAssertEqual(try f.tasks.get(check.id)?.column, .closed)
        let item = try XCTUnwrap(store.items(watchId: watch.id).first)
        XCTAssertEqual(item.state, .dismissed)
        XCTAssertEqual(item.dismissReason, "Done with gh pr edit.")

        try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1", body: "Rename this. And again.")]), now: 2_000
        )
        let reopened = try XCTUnwrap(store.items(watchId: watch.id).first)
        XCTAssertEqual(reopened.state, .open)
        XCTAssertNil(reopened.dismissReason)
    }

    /// SPEC §13.1 dismissed items: a park its failing items caused lifts once they are dismissed, and the
    /// orchestrator hears why. A park for another cause, here a refused push, stays.
    func testDismissingTheLastFailingItemUnparksACheckFailedWatchButNotARefusedPushPark() throws {
        let f = try Fixture.make()
        try enableFollowThrough(f, true)
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        for attempt in 1...PRWatchStore.failedChecksBeforePark {
            try checkRound(f, watchId: watch.id, taskId: task.id, attempt: attempt) { _ in .notFixed }
        }
        XCTAssertEqual(try store.get(watch.id)?.state, .parked)
        let itemId = try XCTUnwrap(store.items(watchId: watch.id).first?.id)

        let unparked = try store.dismissItem(itemId: itemId, reason: "Done with gh pr edit.", by: PRWatchStore.humanDismissal)

        XCTAssertEqual(unparked.state, .watching)
        XCTAssertNil(unparked.parkedReason)
        let reports = try ReportStore(f.db).unconsumed(projectId: f.project.id).filter { $0.kind == .prFollowThrough }
        XCTAssertEqual(
            reports.last?.body.split(separator: "\n").last.map(String.init),
            "unparked: item \(itemId) dismissed: Done with gh pr edit.; now watching"
        )

        let refused = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(number: 8, items: [thread("T2")]), now: 2_000
        )
        try triage(f, watchId: refused.id, as: .fix)
        let refusedTask = try XCTUnwrap(f.board.createFixRoundTask(watchId: refused.id, model: nil))
        XCTAssertEqual(try checkRound(f, watchId: refused.id, taskId: refusedTask.id, attempt: 4) { _ in .fixed }, .publishing)
        try f.board.parkPublishing(watchId: refused.id, reason: "The push was refused.")
        let refusedItem = try XCTUnwrap(store.items(watchId: refused.id).first?.id)

        let still = try store.dismissItem(itemId: refusedItem, reason: "Not needed.", by: PRWatchStore.humanDismissal)

        XCTAssertEqual(still.state, .parked)
        XCTAssertEqual(still.parkedReason, "The push was refused.")
    }

    /// SPEC §13.1 dismissed items: a fixer still running when its task closed reports into a closed task.
    func testAReportFromAFixerStillRunningOnADismissedRoundLeavesItsTaskClosed() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        try f.board.assign(taskId: task.id, session: f.session("fixer"))
        try f.sessions.setState("fixer", .running)
        let itemId = try XCTUnwrap(store.items(watchId: watch.id).first?.id)
        try store.dismissItem(itemId: itemId, reason: "Done with gh pr edit.", by: PRWatchStore.humanDismissal)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .closed)

        let outcome = try f.board.complete(taskId: task.id, sessionId: "fixer", summary: "Renamed it.")

        XCTAssertTrue(outcome.closedUnderSession)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .closed)
    }

    /// SPEC §13.1: an item only the author can do on GitHub goes to them, and the rest of the round passes.
    func testANeedsAuthorGradeBecomesADecisionInsteadOfFailingTheCheck() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id,
            snapshot: snapshot(items: [thread("T1"), thread("T2", body: "Update the PR description.")]), now: 1_000
        )
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))

        let state = try checkRound(f, watchId: watch.id, taskId: task.id, attempt: 1) {
            $0.githubNodeId == "T2" ? .needsAuthor : .fixed
        }

        XCTAssertEqual(state, .publishing)
        XCTAssertEqual(try store.currentRound(watchId: watch.id)?.checkFailures, 0)
        let handed = try XCTUnwrap(store.items(watchId: watch.id).first { $0.githubNodeId == "T2" })
        XCTAssertTrue(handed.isOpenDecision)
        XCTAssertEqual(handed.decisionOptions.map(\.verdict), [.answer, .answer])
        XCTAssertEqual(try store.claimDecisionNotifications(watchId: watch.id).map(\.id), [handed.id])
    }

    func testAFixRoundSkipsSpawnApprovalOnlyWhereFollowThroughIsOn() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]))
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))

        try enableFollowThrough(f, true)
        XCTAssertEqual(try f.board.requestSpawn(taskId: task.id, requestedBy: "follow-through"), .proceed)
        try enableFollowThrough(f, false)
        guard case .approvalPending = try f.board.requestSpawn(taskId: task.id, requestedBy: "follow-through") else {
            return XCTFail("a disabled project's fix round waits for approval")
        }
    }

    func testAStackedPullRequestParksInsteadOfFixing() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        var stacked = snapshot(items: [thread("T1")])
        stacked.baseRef = "feature/lower-layer"
        let watch = try store.upsert(projectId: f.project.id, snapshot: stacked)

        XCTAssertEqual(try triage(f, watchId: watch.id, as: .fix), .parked)
        XCTAssertTrue(try store.get(watch.id)?.parkedReason?.contains("feature/lower-layer") == true)
        XCTAssertNil(try f.board.createFixRoundTask(watchId: watch.id, model: nil))
    }

    /// SPEC §13.1: the cap counts the rounds run since the last resume, so Resume allows a fresh set.
    func testRunningPastTheRoundCapParksWithAReasonAndResumeStartsANewCap() throws {
        let f = try Fixture.make()
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        settings.prFollowThrough.roundCap = 2
        try f.projects.updateSettings(f.project.id, settings)
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: []), now: 1_000)
        for now: Int64 in [2_000, 3_000] {
            try store.setState(.settling, watchId: watch.id, now: now)
            XCTAssertNotNil(try store.beginTriageRound(watchId: watch.id, now: now))
            XCTAssertEqual(try f.board.applyVerdicts(watchId: watch.id, now: now), .watching)
        }

        try store.setState(.settling, watchId: watch.id, now: 4_000)
        XCTAssertNil(try store.beginTriageRound(watchId: watch.id, now: 4_000))
        let parked = try XCTUnwrap(store.get(watch.id))
        XCTAssertEqual(parked.state, .parked)
        XCTAssertTrue(parked.parkedReason?.contains("round cap of 2") == true, parked.parkedReason ?? "")

        XCTAssertEqual(try store.resume(watchId: watch.id, now: 5_000)?.state, .settling)
        XCTAssertNotNil(try store.beginTriageRound(watchId: watch.id, now: 6_000))
    }

    /// SPEC §13.1: a round whose check never ran keeps its items through its park and Resume, since their
    /// fixes are in its unpushed commit.
    func testAResumedRoundWhoseCheckNeverRanIsCheckedAgainRatherThanSuperseded() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]))
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        try f.tasks.move(task.id, to: .review)
        try store.setState(.checking, watchId: watch.id)
        for _ in 1..<PRWatchStore.unavailableChecksBeforePark {
            XCTAssertEqual(try f.board.recordUnavailableCheck(watchId: watch.id, tip: .commit("f57a3f1c"), reason: "spawn failed"), .checking)
        }
        XCTAssertEqual(try f.board.recordUnavailableCheck(watchId: watch.id, tip: .commit("f57a3f1c"), reason: "spawn failed"), .parked)
        let reason = try XCTUnwrap(store.get(watch.id)?.parkedReason)
        XCTAssertTrue(reason.hasPrefix("Round 1's commit f57a3f1c on `agentboard/pr-7-r1` is unpushed"), reason)
        XCTAssertEqual(try store.rounds(watchId: watch.id).map(\.outcome), [PRRoundOutcome.checkUnavailable.rawValue])
        XCTAssertEqual(try store.rounds(watchId: watch.id).first?.checkFailures, 0)

        let items = try store.items(watchId: watch.id)
        XCTAssertEqual(try store.resume(watchId: watch.id)?.state, .checking)
        XCTAssertEqual(try store.rounds(watchId: watch.id).map(\.outcome), [nil])
        XCTAssertEqual(try store.items(watchId: watch.id).map(\.round), items.map(\.round))
        XCTAssertEqual(try store.items(watchId: watch.id).map(\.fixTaskId), [task.id])
    }

    /// SPEC §13.1: reviewers whose setup failed count toward the park through their sessions, only those
    /// started since the watch was last resumed.
    func testTheThirdReviewerSetupFailureSinceResumeParksTheWatch() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]))
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        try f.tasks.move(task.id, to: .review)
        try store.setState(.checking, watchId: watch.id)
        func setupFailed(at startedAt: Int64) throws -> PRWatchState? {
            try f.sessions.insert(AgentSession(
                sessionId: "setup-\(startedAt)", projectId: f.project.id, taskId: task.id, role: .worker,
                cwd: "/tmp/review", state: .stopped, startedAt: startedAt,
                stopReason: "\(SessionTermination.setupFailedLead) hook exited 1", reviewHead: "abc123"
            ))
            return try f.board.recordUnavailableCheck(
                watchId: watch.id, tip: .commit("f57a3f1c"), counted: false, reason: "never started", now: startedAt
            )
        }
        XCTAssertEqual(try setupFailed(at: 1_000), .checking)
        XCTAssertEqual(try setupFailed(at: 2_000), .checking)
        XCTAssertEqual(try setupFailed(at: 3_000), .parked)
        XCTAssertEqual(try store.resume(watchId: watch.id, now: 4_000)?.state, .checking)

        XCTAssertEqual(try setupFailed(at: 5_000), .checking)
        XCTAssertEqual(try setupFailed(at: 6_000), .checking)
        XCTAssertEqual(try setupFailed(at: 7_000), .parked)
        let reason = try XCTUnwrap(store.get(watch.id)?.parkedReason)
        XCTAssertTrue(reason.hasPrefix("Round 1's commit f57a3f1c on `agentboard/pr-7-r1` is unpushed: its check could not run 3 times"), reason)
        XCTAssertEqual(try store.currentRound(watchId: watch.id)?.unavailableChecks, 0)
    }

    func testAResumedWatchsNextFailedTriageDoesNotParkItAgain() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try store.setState(.settling, watchId: watch.id, now: 1_000)
        for attempt in 1...PRWatchStore.failedSessionsBeforePark {
            let now = Int64(1_000 + attempt * 1_000)
            XCTAssertNotNil(try store.beginTriageRound(watchId: watch.id, now: now))
            try store.abandonTriageRound(watchId: watch.id, failure: "the session vanished", now: now)
        }
        XCTAssertEqual(try store.get(watch.id)?.state, .parked)

        XCTAssertEqual(try store.resume(watchId: watch.id, now: 10_000)?.state, .settling)
        XCTAssertNotNil(try store.beginTriageRound(watchId: watch.id, now: 11_000))
        XCTAssertEqual(try store.abandonTriageRound(watchId: watch.id, failure: "the session vanished", now: 11_000), .settling)
    }

    func testAReplyOnADecisionClearsItsVerdictAndAnswerWhetherItWasHandledOrStillOpen() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("Answered"), thread("Waiting")]), now: 1_000
        )
        try f.db.writer.write { db in
            try db.execute(sql: """
                UPDATE pr_item SET verdict = 'decision', decision_question = 'Async?', decision_options_json = '["Yes"]',
                  decision_answer = 'Yes', reply_body = 'Done.'
                """)
            try db.execute(sql: "UPDATE pr_item SET state = 'handled' WHERE github_node_id = 'Answered'")
        }

        try store.upsert(
            projectId: f.project.id,
            snapshot: snapshot(items: [thread("Answered", body: "Reconsider."), thread("Waiting", body: "Reconsider.")]),
            now: 2_000
        )
        for item in try store.items(watchId: watch.id) {
            XCTAssertEqual(item.state, .open, item.githubNodeId)
            XCTAssertNil(item.verdict, item.githubNodeId)
            XCTAssertNil(item.decisionQuestion, item.githubNodeId)
            XCTAssertNil(item.decisionAnswer, item.githubNodeId)
            XCTAssertNil(item.replyBody, item.githubNodeId)
        }
    }

    /// SPEC §13.1: a body stored before the reader stripped HTML comments must not reopen a handled item.
    func testABodyThatDiffersOnlyByHiddenCommentsIsRewrittenWithoutReopeningTheItem() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(items: [thread("T1", body: "Rename this<!-- bot {} -->")]),
            now: 1_000
        )
        try f.db.writer.write { db in
            try db.execute(sql: """
                UPDATE pr_item SET state = 'handled', handled_at = 1500, verdict = 'answer', reply_body = 'Done.',
                  reply_url = 'https://github.com/example-org/app/pull/7#r1'
                """)
        }

        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 2_000)
        let item = try XCTUnwrap(store.items(watchId: watch.id).first)
        XCTAssertEqual(item.state, .handled)
        XCTAssertEqual(item.handledAt, 1_500)
        XCTAssertEqual(item.verdict, .answer)
        XCTAssertEqual(item.replyURL, "https://github.com/example-org/app/pull/7#r1")
        XCTAssertEqual(item.body, "Rename this")
        XCTAssertEqual(try store.get(watch.id)?.lastFeedbackAt, 1_000)
    }

    func testPageGroupsWatchesAndBadgeCountsReadyAndDecisions() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let store = PRWatchStore(f.db)
        var settings = f.project.settings
        settings.prFollowThrough.enabled = true
        try ProjectStore(f.db).updateSettings(f.project.id, settings)
        let ready = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 1, items: []))
        let decided = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 2, items: [thread("D1")]))
        let waiting = try store.upsert(projectId: other.id, snapshot: snapshot(number: 3, items: []))
        let merged = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 4, items: []))
        let stopped = try store.upsert(projectId: f.project.id, snapshot: snapshot(number: 5, items: [thread("D2")]))
        try store.setState(.readyToVerify, watchId: ready.id)
        try store.setState(.merged, watchId: merged.id)
        try store.setState(.stopped, watchId: stopped.id)
        try f.db.writer.write { db in
            try db.execute(sql: "UPDATE pr_item SET verdict = 'decision' WHERE github_node_id IN ('D1', 'D2')")
        }
        try store.setPaused(true, watchId: waiting.id)

        let page = try store.page()
        XCTAssertEqual(page.map(\.group), [.readyToVerify, .needsYou, .waitingOnReviewers, .stopped])
        XCTAssertEqual(page.map { $0.listings.map(\.watch.id) }, [[ready.id], [decided.id], [waiting.id], [stopped.id]])
        XCTAssertEqual(page[1].listings[0].openItems, 1)
        XCTAssertEqual(page[1].listings[0].openDecisions, 1)
        XCTAssertEqual(page[2].listings[0].watch.paused, true)
        XCTAssertEqual(try store.page(projectId: other.id).map(\.group), [.waitingOnReviewers])

        XCTAssertEqual(try store.badgeCounts(), [f.project.id: PRBadgeCount(readyToVerify: 1, openDecisions: 1)])
    }

    func testTheObservedPageListsAnActiveTriageSessionUntilItEnds() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: []))
        let task = try f.board.createTriageTask(watchId: watch.id, baseOid: "base", headOid: "abc123")
        try f.sessions.insert(f.session("triager", taskId: task.id))

        let sessions = PageSessions()
        let ended = expectation(description: "the page drops the ended session")
        let cancellable = store.observePage().start(
            in: f.db.reader,
            scheduling: .immediate,
            onError: { XCTFail("observation failed: \($0)") },
            onChange: { page in
                sessions.values.append(page.flatMap(\.listings).flatMap(\.sessions))
                if sessions.values.count == 2 { ended.fulfill() }
            }
        )
        defer { cancellable.cancel() }
        try f.sessions.setState("triager", .completed, endedAt: .nowMillis)
        wait(for: [ended], timeout: 5)

        XCTAssertEqual(sessions.values, [[PRListingSession(sessionId: "triager", role: .triage)], []])
    }

    private final class PageSessions: @unchecked Sendable {
        var values: [[PRListingSession]] = []
    }

    private func setReplies(_ f: Fixture, _ on: Bool, now: Int64) throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        settings.prFollowThrough.postFactualReplies = on
        try f.projects.updateSettings(f.project.id, settings, now: now)
    }

    private func answer(_ f: Fixture, _ nodeId: String) throws {
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET verdict = 'answer', reply_body = 'Three retries.' WHERE github_node_id = ?",
                arguments: [nodeId]
            )
        }
    }

    func testTurningRepliesOnOwesNoReplyForAnItemHandledBeforeThen() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1"), thread("T2")]), now: 1_000)
        try answer(f, "T1")
        try answer(f, "T2")
        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T2")]), now: 2_000)

        try setReplies(f, true, now: 3_000)
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), [])

        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: []), now: 4_000)
        try setReplies(f, true, now: 5_000)
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), ["T2"])
    }

    /// The round's fix task is deleted after its push, which nulls `fix_task_id` on both the round and the item.
    func testAPushedFixWhoseTaskWasDeletedStillOwesItsReplyAndAReopenedItemOwesAFreshOne() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        try setReplies(f, true, now: 500)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try triage(f, watchId: watch.id, as: .fix)
        let task = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil))
        try store.setState(.publishing, watchId: watch.id)
        try f.board.recordRoundPublished(watchId: watch.id, pushedHeadOid: "def456", now: 2_000)
        try f.tasks.delete(task.id)

        let fixed = try XCTUnwrap(try store.pendingReplies(watchId: watch.id).first)
        try store.recordReply(itemId: try XCTUnwrap(fixed.id), url: "https://github.com/example-org/app/pull/7#r1")
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), [])

        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1", body: "Still not renamed")]), now: 3_000)
        try answer(f, "T1")
        try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1", resolved: true)]), now: 4_000)
        XCTAssertEqual(try store.pendingReplies(watchId: watch.id).map(\.githubNodeId), ["T1"])
    }

    func testFollowThroughTablesMigrateOntoAnExistingDatabase() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue, upTo: "task_closed")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO project (id, name, repo_path, worktree_root, settings_json, created_at) VALUES ('p1', 'p1', '/repo/p1', '/w', '{}', 0)"
            )
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w1', 'p1', 'example-org', 'app', 1, 'u', 't', 'h', 'oid', 'main', 'watching', 0, 0)
                """)
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO pr_watch (id, project_id, repo_owner, repo_name, number, url, title, head_ref, head_oid,
                  base_ref, state, created_at, updated_at)
                VALUES ('w2', 'p1', 'example-org', 'app', 1, 'u', 't', 'h', 'oid', 'main', 'watching', 0, 0)
                """))
            XCTAssertEqual(try PRWatch.fetchOne(db, key: "w1")?.state, .watching)
        }
    }

    func testFollowThroughSettingsDefaultOffAndRoundTrip() throws {
        let absent = ProjectSettings.decode("{}").prFollowThrough
        XCTAssertEqual(absent, PRFollowThroughSettings())
        XCTAssertFalse(absent.enabled)
        XCTAssertNil(absent.verificationLabel)
        XCTAssertTrue(absent.requireApproval)
        XCTAssertEqual(absent.settleMinutes, 10)
        XCTAssertEqual(absent.roundCap, 3)
        XCTAssertNil(absent.dailyBudgetUSD)
        XCTAssertEqual(absent.minBatteryPercent, 50)
        XCTAssertNil(absent.verifyCommand)
        XCTAssertFalse(absent.postFactualReplies)
        XCTAssertEqual(absent.roles, PRFollowThroughRoles())
        XCTAssertEqual(absent.privateTerms, [])

        XCTAssertEqual(
            ProjectSettings.decode(#"{"prFollowThrough":{"enabled":true}}"#).prFollowThrough,
            PRFollowThroughSettings(enabled: true)
        )

        var settings = ProjectSettings()
        settings.prFollowThrough = PRFollowThroughSettings(
            enabled: true, verificationLabel: "verified-example", requireApproval: false, settleMinutes: 5,
            roundCap: 2, dailyBudgetUSD: 4.5, minBatteryPercent: nil, verifyCommand: "open {url}", postFactualReplies: true,
            roles: PRFollowThroughRoles(fixer: PRFollowThroughRole(rosterAgentId: "agent-1", model: "sonnet")),
            privateTerms: ["example-org"]
        )
        XCTAssertEqual(ProjectSettings.decode(settings.encoded()), settings)
    }

    func testAVerifyFailureSentBackMidRoundLeavesTheRoundAlone() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(projectId: f.project.id, snapshot: snapshot(items: [thread("T1")]), now: 1_000)
        try store.setState(.settling, watchId: watch.id)
        XCTAssertEqual(try store.beginTriageRound(watchId: watch.id, now: 2_000)?.number, 1)
        XCTAssertEqual(try store.get(watch.id)?.state, .triaging)

        let item = try store.addVerifyFailure(watchId: watch.id, body: "Still broken in prod.", now: 3_000)

        let after = try XCTUnwrap(store.get(watch.id))
        XCTAssertEqual(after.state, .triaging, "a send-back mid-round must not force the watch to settling")
        XCTAssertEqual(after.round, 1, "the round must not be disturbed")
        XCTAssertEqual(item.round, 1, "the item carries the round in progress")
        XCTAssertEqual(after.lastFeedbackAt, 3_000)
    }

    func testVerifyCommandFillsInTheURLAndRefusesOneAShellWouldParse() {
        var settings = PRFollowThroughSettings()
        let url = "https://github.com/example-org/app/pull/7"
        XCTAssertNil(settings.verifyCommand(for: url), "no template, no command")

        settings.verifyCommand = "verify-example --pr {url}"
        XCTAssertEqual(settings.verifyCommand(for: url), "verify-example --pr \(url)")
        XCTAssertNil(settings.verifyCommand(for: url + ";touch x"))

        settings.verifyCommand = #"claude "/review:verify {url}" --mcp-config {mcp_config}"#
        XCTAssertEqual(
            settings.verifyCommand(for: url, mcpConfig: "/support/it's/verify-1.json"),
            #"claude "/review:verify \#(url)" --mcp-config '/support/it'\''s/verify-1.json'"#
        )
    }

    func testAddBoardToolsAppliesOnlyToAClaudeTemplateWithoutThePlaceholderAndOnlyOnce() {
        let added = PRFollowThroughSettings.withBoardTools(#"claude "/review:verify {url}""#)
        XCTAssertEqual(added, #"claude "/review:verify {url}" --mcp-config {mcp_config}"#)
        XCTAssertNil(PRFollowThroughSettings.withBoardTools(added ?? ""))
        XCTAssertNil(PRFollowThroughSettings.withBoardTools("open {url}"))
        XCTAssertNil(PRFollowThroughSettings.withBoardTools("claudette {url}"))
    }

    func testASlashCommandGetsItsClaudeFormAndAPathOrAClaudeCallDoesNot() {
        XCTAssertEqual(
            PRFollowThroughSettings.claudeForm(ofSlashCommand: " /review:verify {url} "),
            #"claude "/review:verify {url}" --mcp-config {mcp_config}"#
        )
        XCTAssertEqual(PRFollowThroughSettings.claudeForm(ofSlashCommand: #"/review "$x""#), #"claude "/review \"\$x\"" --mcp-config {mcp_config}"#)
        XCTAssertNil(PRFollowThroughSettings.claudeForm(ofSlashCommand: "/usr/local/bin/verify {url}"))
        XCTAssertNil(PRFollowThroughSettings.claudeForm(ofSlashCommand: #"claude "/review:verify {url}""#))
        XCTAssertNil(PRFollowThroughSettings.claudeForm(ofSlashCommand: "/ {url}"))
    }

    func testEveryPostedBodyEndsWithTheAgentMark() {
        let review = "https://github.com/example-org/app/pull/7#pullrequestreview-1"
        var fix = PRItem(
            id: nil, watchId: "w", githubNodeId: "T_1", kind: .thread, author: "reviewer", body: "Rename this",
            path: nil, line: nil, url: nil, state: .handled, round: 1, createdAt: 0, updatedAt: 0
        )
        fix.verdict = .fix
        var answer = fix
        answer.kind = .review
        answer.url = review
        answer.verdict = .answer
        answer.replyBody = "Three retries."

        XCTAssertEqual(
            fix.postedBody(pushedHeadOid: "9b22ce8f00d"), "Fixed in 9b22ce8.\n\n**Posted by PR follow-through agent**"
        )
        XCTAssertEqual(
            answer.postedBody(pushedHeadOid: nil),
            "In reply to \(review):\n\nThree retries.\n\n**Posted by PR follow-through agent**"
        )
    }
}
