import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §13.1 phase 2: settling waits out `settleMinutes` and its holds, then starts one triager per
/// round, whose verdicts become backlog tasks once and only once; a triage that ends without them is
/// retried, and the third in a row parks the watch. Driven through `FakeGh`.
@MainActor
final class PRFollowThroughLoopTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var head = ""
    private var onAC = true
    private let repository = "example-org/app"
    private var url: String { "https://github.com/\(repository)/pull/12" }
    private var watches: PRWatchStore { PRWatchStore(fixture.db) }

    /// `origin` names GitHub, so the poll maps it, while a fake ssh serves a local bare clone, so the
    /// triager's base fetch works. The PR head is a commit the repository already has.
    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        let remote = fixture.supportDir.appendingPathComponent("remote.git")
        try SupervisorFixture.git(["clone", "-q", "--bare", fixture.repo.path, remote.path], cwd: fixture.supportDir)
        let ssh = fixture.supportDir.appendingPathComponent("fake-ssh")
        try "#!/bin/sh\nexec git upload-pack '\(remote.path)'\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        _ = try fixture.git(["remote", "add", "origin", "git@github.com:\(repository).git"])
        _ = try fixture.git(["config", "core.sshCommand", ssh.path])
        _ = try fixture.git(["checkout", "-q", "-b", "add-widgets"])
        _ = try fixture.git(["commit", "-q", "--allow-empty", "-m", "Add widgets"])
        head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["checkout", "-q", "main"])
        onAC = true
        fixture.supervisor.isOnACPower = { [unowned self] in self.onAC }
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        await fixture.supervisor.waitForTeardowns()
        await fixture.cleanUp()
        fixture = nil
    }

    private func enable(settleMinutes: Int = 0, budget: Double? = nil) throws {
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.prFollowThrough = PRFollowThroughSettings(
            enabled: true, settleMinutes: settleMinutes, dailyBudgetUSD: budget,
            roles: PRFollowThroughRoles(fixer: PRFollowThroughRole(model: "fixer-model"))
        )
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)
    }

    private func thread(_ id: String, body: String = "Rename this.") -> [String: Any] {
        [
            "id": id, "isResolved": false, "isOutdated": false,
            "comments": ["nodes": [[
                "author": ["login": "reviewer"], "body": body, "url": "\(url)#\(id)",
                "path": "Sources/App.swift", "line": 3,
            ]]],
        ]
    }

    private func answer(threads: [[String: Any]]) {
        fixture.gh.answerSearch([AuthoredPullRequest(repository: repository, number: 12, url: url, title: "Add widgets")])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [[
            "number": 12, "url": url, "title": "Add widgets", "isDraft": false, "headRefName": "add-widgets",
            "headRefOid": head, "baseRefName": "main", "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
            "labels": ["nodes": []], "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
            "reviewThreads": ["nodes": threads], "reviews": ["nodes": []],
        ]])
    }

    private func poll() async {
        await fixture.supervisor.pollPRWatches()
        await fixture.supervisor.waitForSetup()
        await fixture.supervisor.waitForTeardowns()
    }

    private func onlyWatch() throws -> PRWatch {
        try XCTUnwrap(try watches.live(projectId: fixture.project.id).first)
    }

    /// Moves the settle window's clock back without waiting it out.
    private func age(minutes: Int) throws {
        try fixture.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_watch SET last_feedback_at = last_feedback_at - ?", arguments: [Int64(minutes) * 60_000]
            )
        }
    }

    private var spawnCount: Int {
        get async { await fixture.runtime.spawns.count }
    }

    private func triageTasks() throws -> [BoardTask] {
        try fixture.tasks.list(projectId: fixture.project.id, includeArchived: true).filter { $0.origin == .triage }
    }

    private func runningTriager() throws -> AgentSession {
        let task = try XCTUnwrap(try triageTasks().first { $0.column == .running })
        return try XCTUnwrap(try fixture.sessions.forTask(task.id).first { $0.state.isActive })
    }

    func testTwoThreadsStartOneTriagerOnceTheSettleWindowHasPassedSinceTheLastComment() async throws {
        try enable(settleMinutes: 10)
        answer(threads: [thread("T_1"), thread("T_2")])
        await poll()
        XCTAssertEqual(try onlyWatch().state, .settling)

        try age(minutes: 9)
        answer(threads: [thread("T_1"), thread("T_2"), thread("T_3")])
        await poll()
        try age(minutes: 9)
        await poll()
        XCTAssertEqual(try onlyWatch().state, .settling, "a comment during settling restarts the window")
        let waited = await spawnCount
        XCTAssertEqual(waited, 0)

        try age(minutes: 1)
        await poll()
        await poll()
        let spawned = await spawnCount
        XCTAssertEqual(spawned, 1)
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .triaging)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.number), [1])
        XCTAssertEqual(try watches.rounds(watchId: watch.id).first?.baseHeadOid, head)
    }

    func testVerdictsBecomeBacklogTasksOnceAndTheWatchGoesBackToWatching() async throws {
        try enable()
        answer(threads: [
            thread("T_fix", body: "Rename this."), thread("T_later", body: "Extract a helper someday."),
            thread("T_question", body: "Why 3?"), thread("T_choice", body: "Should this be async?"),
        ])
        await poll()
        let session = try runningTriager()
        let items = Dictionary(uniqueKeysWithValues: try watches.items(watchId: try onlyWatch().id).map {
            ($0.githubNodeId, Double($0.id ?? 0))
        })
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        let grant = try XCTUnwrap(fixture.grants.forSession(session.sessionId).first)
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_verdicts",
            arguments: .object(["verdicts": .array([
                .object(["item_id": .number(items["T_fix"]!), "verdict": .string("fix"), "approach": .string("Rename it to count.")]),
                .object(["item_id": .number(items["T_later"]!), "verdict": .string("follow_up"), "approach": .string("A refactor.")]),
                .object([
                    "item_id": .number(items["T_question"]!), "verdict": .string("answer"),
                    "approach": .string("Factual."), "reply_body": .string("Three retries."),
                ]),
                .object([
                    "item_id": .number(items["T_choice"]!), "verdict": .string("decision"), "approach": .string("Direction."),
                    "decision_question": .string("Make it async?"), "decision_options": .array([
                        .object(["label": .string("Yes"), "verdict": .string("fix")]),
                        .object(["label": .string("No"), "verdict": .string("answer"), "reply_body": .string("It stays sync.")]),
                    ]),
                ]),
            ])]),
            identity: try await fixture.identity(token: grant.token)
        )
        await result.afterResponse?()
        await poll()
        await poll()
        await poll()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .watching)
        let made = try fixture.tasks.list(projectId: fixture.project.id).filter { $0.origin == .followThrough }
        XCTAssertEqual(made.count, 2, made.map(\.title).description)
        let fix = try XCTUnwrap(made.first { $0.type == .code })
        XCTAssertEqual(fix.column, .backlog)
        XCTAssertEqual(fix.model, "fixer-model")
        for part in ["Rename this.", "Sources/App.swift:3", "\(url)#T_fix", "Rename it to count.", url] {
            XCTAssertTrue(fix.body?.contains(part) == true, "\(part) is missing from:\n\(fix.body ?? "")")
        }
        let followUp = try XCTUnwrap(made.first { $0.id != fix.id })
        XCTAssertEqual(followUp.column, .backlog)
        XCTAssertTrue(followUp.title.hasPrefix("Follow-up from #12"), followUp.title)

        let byNode = Dictionary(uniqueKeysWithValues: try watches.items(watchId: watch.id).map { ($0.githubNodeId, $0) })
        XCTAssertEqual(byNode["T_fix"]?.state, .open)
        XCTAssertEqual(byNode["T_fix"]?.fixTaskId, fix.id)
        XCTAssertEqual(byNode["T_later"]?.state, .handled)
        XCTAssertEqual(byNode["T_question"]?.state, .handled)
        XCTAssertEqual(byNode["T_question"]?.replyBody, "Three retries.")
        XCTAssertEqual(byNode["T_choice"]?.isOpenDecision, true)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["triaged"])
        let spawned = await spawnCount
        XCTAssertEqual(spawned, 1)
    }

    /// The third failure in a row parks the watch and raises the project's attention, naming it.
    func testATriagerThatEndsWithoutVerdictsLeavesNothingBehindAndIsRetriedUntilTheWatchParks() async throws {
        try enable()
        answer(threads: [thread("T_1")])
        await poll()
        for attempt in 1...PRWatchStore.failedTriagesBeforePark {
            let session = try runningTriager()
            let worktree = try XCTUnwrap(session.worktreePath)
            try await fixture.supervisor.stop(sessionId: session.sessionId)
            await fixture.supervisor.waitForTeardowns()
            XCTAssertFalse(try triageTasks().contains { $0.column == .ready || $0.column == .running })
            XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "attempt \(attempt) kept its checkout")

            await poll()
            if attempt < PRWatchStore.failedTriagesBeforePark {
                XCTAssertEqual(try onlyWatch().state, .settling)
                await poll()
                let spawned = await spawnCount
                XCTAssertEqual(spawned, attempt + 1, "the watch retries with a new round")
            }
        }

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .parked)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), Array(repeating: "triage_failed", count: 3))
        let cause = try XCTUnwrap(try ProjectAttentionStore(fixture.db).attention(projectId: fixture.project.id)?
            .cause(.parkedPullRequest))
        XCTAssertTrue(cause.text.contains("#12") && cause.text.contains("3 times"), cause.text)
        await poll()
        let spawned = await spawnCount
        XCTAssertEqual(spawned, PRWatchStore.failedTriagesBeforePark)
    }

    func testBatteryPowerAndASpentDailyBudgetKeepASettledWatchSettling() async throws {
        try enable()
        onAC = false
        answer(threads: [thread("T_1")])
        await poll()
        await poll()
        XCTAssertEqual(try onlyWatch().state, .settling)
        let onBattery = await spawnCount
        XCTAssertEqual(onBattery, 0)

        onAC = true
        await poll()
        let session = try runningTriager()
        try fixture.sessions.updateSpend(
            session.sessionId, tokensIn: 0, tokensOut: 0, cacheRead: 0, cacheWrite: 0, estCostUSD: 5, model: nil
        )
        try await fixture.supervisor.stop(sessionId: session.sessionId)
        await poll()
        try enable(budget: 5)
        await poll()
        await poll()
        XCTAssertEqual(try onlyWatch().state, .settling)
        let overBudget = await spawnCount
        XCTAssertEqual(overBudget, 1)

        try enable(budget: 10)
        await poll()
        let underBudget = await spawnCount
        XCTAssertEqual(underBudget, 2)
    }

    func testAShutdownOrderStopsARunningTriagerAtOnceAndItsRoundIsRetriedUncountedAfterward() async throws {
        try enable()
        answer(threads: [thread("T_1")])
        await poll()
        let session = try runningTriager()

        try await fixture.supervisor.requestShutdown(projectId: fixture.project.id)
        let progress = try await fixture.supervisor.deliverShutdownOrder(projectId: fixture.project.id)
        await fixture.supervisor.waitForTeardowns()
        XCTAssertEqual(progress.total, 0, "a triager has no acknowledge_shutdown to wait for")
        XCTAssertFalse(try XCTUnwrap(fixture.sessions.get(session.sessionId)).state.isActive)
        XCTAssertEqual(try fixture.tasks.get(try XCTUnwrap(session.taskId))?.column, .closed)

        await poll()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .settling)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["interrupted"])
        let held = await spawnCount
        XCTAssertEqual(held, 1)

        try await fixture.supervisor.cancelShutdown(projectId: fixture.project.id)
        await poll()
        let retried = await spawnCount
        XCTAssertEqual(retried, 2)
    }
}
