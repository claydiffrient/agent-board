import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §13.1 phases 2 and 3: settling waits out `settleMinutes` and its holds, then starts one
/// triager per round, whose fix verdicts start one fixer on the round's branch, which the reviewer and
/// follow-up check roles then check; a triage that ends without verdicts is retried, and the third in a
/// row parks the watch; a round that passes its check is fast-forwarded onto the PR's head ref.
/// Driven through `FakeGh`.
@MainActor
final class PRFollowThroughLoopTests: XCTestCase {
    private var fixture: SupervisorFixture!
    private var head = ""
    private var onAC = true
    private let repository = "example-org/app"
    private var url: String { "https://github.com/\(repository)/pull/12" }
    private var watches: PRWatchStore { PRWatchStore(fixture.db) }
    private var remote: URL { fixture.supportDir.appendingPathComponent("remote.git") }

    /// `origin` names GitHub, so the poll maps it, while a fake ssh serves a local bare clone, so the
    /// triager's and fixer's fetches and publishing's push work. The PR head is a commit the repository
    /// already has.
    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        try SupervisorFixture.git(["clone", "-q", "--bare", fixture.repo.path, remote.path], cwd: fixture.supportDir)
        let ssh = fixture.supportDir.appendingPathComponent("fake-ssh")
        try """
        #!/bin/sh
        case "$*" in
          *receive-pack*) exec git receive-pack '\(remote.path)' ;;
          *) exec git upload-pack '\(remote.path)' ;;
        esac

        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        _ = try fixture.git(["remote", "add", "origin", "git@github.com:\(repository).git"])
        _ = try fixture.git(["config", "core.sshCommand", ssh.path])
        _ = try fixture.git(["checkout", "-q", "-b", "add-widgets"])
        _ = try fixture.git(["commit", "-q", "--allow-empty", "-m", "Add widgets"])
        head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try fixture.git(["checkout", "-q", "main"])
        _ = try fixture.git(["push", "-q", remote.path, "add-widgets"])
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

    private func enable(
        settleMinutes: Int = 0, budget: Double? = nil, label: String? = nil, replies: Bool = false,
        roles: PRFollowThroughRoles = PRFollowThroughRoles(fixer: PRFollowThroughRole(model: "fixer-model"))
    ) throws {
        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.prFollowThrough = PRFollowThroughSettings(
            enabled: true, verificationLabel: label, settleMinutes: settleMinutes, dailyBudgetUSD: budget,
            postFactualReplies: replies, roles: roles
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

    private func answer(threads: [[String: Any]], checks: String = "SUCCESS") {
        fixture.gh.answerSearch([AuthoredPullRequest(repository: repository, number: 12, url: url, title: "Add widgets")])
        fixture.gh.answerGraphQL(repository: repository, viewer: "me", pullRequests: [[
            "number": 12, "url": url, "title": "Add widgets", "isDraft": false, "headRefName": "add-widgets",
            "headRefOid": head, "baseRefName": "main", "reviewDecision": "APPROVED", "mergeable": "MERGEABLE",
            "labels": ["nodes": []], "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": checks]]]]],
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

    func testFixVerdictsStartOneFixerOnTheRoundBranchAtTheFetchedHeadWithNoApproval() async throws {
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
        XCTAssertEqual(watch.state, .fixing)
        let followUp = try XCTUnwrap(try fixture.tasks.list(projectId: fixture.project.id).first { $0.origin == .followThrough })
        XCTAssertTrue(followUp.title.hasPrefix("Follow-up from #12"), followUp.title)
        let fixer = try XCTUnwrap(try fixture.tasks.list(projectId: fixture.project.id).first { $0.origin == .fixRound })
        XCTAssertEqual(fixer.model, "fixer-model")
        XCTAssertEqual(try ApprovalStore(fixture.db).pending(projectId: fixture.project.id), [])

        let worktree = URL(fileURLWithPath: try XCTUnwrap(
            try fixture.sessions.forTask(fixer.id).first { $0.state.isActive }?.worktreePath
        ))
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/remotes/origin/add-widgets"]).trimmingCharacters(in: .whitespacesAndNewlines), head)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], cwd: worktree).trimmingCharacters(in: .whitespacesAndNewlines), head)
        XCTAssertEqual(
            try fixture.git(["symbolic-ref", "--short", "HEAD"], cwd: worktree).trimmingCharacters(in: .whitespacesAndNewlines),
            "agentboard/pr-12-r1"
        )
        let spawns = await fixture.runtime.spawns
        XCTAssertEqual(spawns.count, 2)
        XCTAssertEqual(spawns.last?.cwd.resolvingSymlinksInPath().path, worktree.resolvingSymlinksInPath().path)
        XCTAssertTrue(spawns.last?.disallowedTools.contains("Bash(git commit*--amend*)") == true)

        let byNode = Dictionary(uniqueKeysWithValues: try watches.items(watchId: watch.id).map { ($0.githubNodeId, $0) })
        XCTAssertEqual(byNode["T_fix"]?.state, .open)
        XCTAssertEqual(byNode["T_fix"]?.fixTaskId, fixer.id)
        XCTAssertEqual(byNode["T_later"]?.state, .handled)
        XCTAssertEqual(byNode["T_later"]?.fixTaskId, followUp.id)
        XCTAssertEqual(byNode["T_question"]?.state, .handled)
        XCTAssertEqual(byNode["T_question"]?.replyBody, "Three retries.")
        XCTAssertEqual(byNode["T_choice"]?.isOpenDecision, true)
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

    // MARK: - Checking

    private let gradingPlugin = "/plugins/grading"

    /// A reviewer role and a follow-up check role, each a board-local roster agent.
    private func enableChecking(label: String? = nil, replies: Bool = false) throws {
        let store = RosterStore(fixture.db)
        let rita = try store.create(name: "Rita", role: "reviewer", systemPrompt: "You review for correctness.")
        let gail = try store.create(
            name: "Gail", role: "follow-up checker", systemPrompt: "Grade with the house lens.", pluginDirs: [gradingPlugin]
        )
        try store.enable(agentId: rita.id, forProject: fixture.project.id)
        try store.enable(agentId: gail.id, forProject: fixture.project.id)
        try enable(label: label, replies: replies, roles: PRFollowThroughRoles(
            fixer: PRFollowThroughRole(model: "fixer-model"), reviewer: PRFollowThroughRole(rosterAgentId: rita.id),
            followupCheck: PRFollowThroughRole(rosterAgentId: gail.id)
        ))
    }

    private var sink: LateBoundSink {
        let sink = LateBoundSink()
        sink.target = fixture.supervisor
        return sink
    }

    private func activeSession(on taskId: String) throws -> AgentSession {
        try XCTUnwrap(try fixture.sessions.forTask(taskId).first { $0.state.isActive })
    }

    private func identity(of session: AgentSession) async throws -> TokenIdentity {
        try await fixture.identity(token: try XCTUnwrap(fixture.grants.forSession(session.sessionId).first).token)
    }

    /// One `fix` thread, triaged, with its round's fixer running; with `question`, an `answer` thread too.
    private func runningFixer(question: Bool = false) async throws -> BoardTask {
        answer(threads: [thread("T_fix")] + (question ? [thread("T_question", body: "Why 3?")] : []))
        await poll()
        let ids = Dictionary(uniqueKeysWithValues: try watches.items(watchId: try onlyWatch().id).map {
            ($0.githubNodeId, Double($0.id ?? 0))
        })
        var verdicts: [JSONValue] = [.object([
            "item_id": .number(ids["T_fix"]!), "verdict": .string("fix"), "approach": .string("Rename n to count."),
        ])]
        if question {
            verdicts.append(.object([
                "item_id": .number(ids["T_question"]!), "verdict": .string("answer"),
                "approach": .string("Factual."), "reply_body": .string("Three retries."),
            ]))
        }
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_verdicts",
            arguments: .object(["verdicts": .array(verdicts)]),
            identity: try await identity(of: try runningTriager())
        )
        await result.afterResponse?()
        await poll()
        await poll()
        return try XCTUnwrap(try fixture.tasks.list(projectId: fixture.project.id).first { $0.origin == .fixRound })
    }

    private func completeFixer(_ fixer: BoardTask, file: String) async throws {
        let session = try activeSession(on: fixer.id)
        try fixture.commitInto(try XCTUnwrap(session.worktreePath), file: file)
        let result = try await WorkerToolHandler(db: fixture.db, control: sink, events: sink).call(
            "report_complete",
            arguments: .object([
                "summary": .string("Renamed it."), "files_changed": .array([.string(file)]),
                "tests_run": .string("none"), "caveats": .string(""),
            ]),
            identity: try await identity(of: session)
        )
        await result.afterResponse?()
    }

    private func review(_ fixer: BoardTask, accept: Bool, text: String = "Ran the tests; they pass.") async throws {
        let reviewer = try activeSession(on: fixer.id)
        XCTAssertNotNil(reviewer.reviewHead)
        let result = try await ReviewerToolHandler(db: fixture.db, control: sink, events: sink).call(
            accept ? "accept_task" : "reopen_task",
            arguments: .object([accept ? "verdict" : "findings": .string(text)]),
            identity: try await identity(of: reviewer)
        )
        await result.afterResponse?()
    }

    private func grade(_ grade: String, evidence: String) async throws {
        let round = try XCTUnwrap(try watches.currentRound(watchId: try onlyWatch().id))
        let checker = try activeSession(on: try XCTUnwrap(round.followupTaskId))
        let item = try XCTUnwrap(try watches.checkItems(round: round).first)
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_followup_grades",
            arguments: .object(["grades": .array([.object([
                "item_id": .number(Double(item.id ?? 0)), "grade": .string(grade), "evidence": .string(evidence),
            ])])]),
            identity: try await identity(of: checker)
        )
        await result.afterResponse?()
    }

    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    func testACompletedFixerIsCheckedOnTheRoundBranchAndPassesToPublishingWithNoMerge() async throws {
        try enableChecking()
        let fixer = try await runningFixer()
        let worktree = URL(fileURLWithPath: try XCTUnwrap(try activeSession(on: fixer.id).worktreePath))
        let mainBefore = try fixture.git(["rev-parse", "main"])

        try await completeFixer(fixer, file: "fix.txt")
        XCTAssertEqual(try onlyWatch().state, .checking)
        XCTAssertEqual(try fixture.tasks.get(fixer.id)?.column, .review)
        do {
            try await fixture.supervisor.accept(taskId: fixer.id)
            XCTFail("a fix round must never take the ordinary accept path")
        } catch SupervisorError.fixRoundNotAcceptable {}

        await poll()
        let spawns = await fixture.runtime.spawns
        let reviewer = spawns[spawns.count - 2]
        let checker = try XCTUnwrap(spawns.last)
        let tip = try fixture.git(["rev-parse", "HEAD"], cwd: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(resolved(reviewer.cwd), resolved(worktree), "the reviewer reads the fixer's own worktree")
        XCTAssertTrue(reviewer.prompt.contains("on branch `agentboard/pr-12-r1`"), reviewer.prompt)
        XCTAssertTrue(reviewer.prompt.contains("`git diff \(head)...HEAD`"), reviewer.prompt)
        XCTAssertEqual(checker.pluginDirs, [gradingPlugin])
        XCTAssertTrue(checker.prompt.contains("`git diff \(head)..\(tip)`"), checker.prompt)
        XCTAssertTrue(checker.disallowedTools.contains { $0.hasPrefix("Bash(gh") }, "the follow-up check is read-only")

        try await review(fixer, accept: true)
        await poll()
        XCTAssertEqual(try onlyWatch().state, .checking, "an acceptance waits for the follow-up check")
        try await grade("fixed", evidence: "App.swift:3 now says count.")
        await poll()

        XCTAssertEqual(try onlyWatch().state, .publishing)
        XCTAssertEqual(try fixture.tasks.get(fixer.id)?.column, .done)
        XCTAssertEqual(try fixture.git(["rev-parse", "main"]), mainBefore)
        XCTAssertEqual(try fixture.git(["branch", "--list", "agentboard/\(fixer.id)"]), "")
        XCTAssertEqual(try watches.currentRound(watchId: try onlyWatch().id)?.checkedHeadOid, tip)
    }

    func testANotFixedGradeReopensTheFixerWithTheFindingAndTheThirdFailedCheckParks() async throws {
        try enableChecking()
        let fixer = try await runningFixer()
        for failure in 1...PRWatchStore.failedChecksBeforePark {
            try await completeFixer(fixer, file: "fix-\(failure).txt")
            await poll()
            try await review(fixer, accept: true)
            try await grade("not_fixed", evidence: "n is still named n at App.swift:\(failure).")
            await poll()
            guard failure < PRWatchStore.failedChecksBeforePark else { break }
            XCTAssertEqual(try onlyWatch().state, .fixing)
            XCTAssertEqual(try fixture.tasks.get(fixer.id)?.column, .ready)
            await poll()
            let spawns = await fixture.runtime.spawns
            let respawn = try XCTUnwrap(spawns.last)
            XCTAssertTrue(respawn.prompt.contains("n is still named n at App.swift:\(failure)."), respawn.prompt)
            XCTAssertTrue(respawn.disallowedTools.contains("Bash(git commit*--amend*)"), "the respawn must be a fixer")
        }

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .parked)
        XCTAssertTrue(watch.parkedReason?.contains("3 times") == true, watch.parkedReason ?? "")
        XCTAssertEqual(try fixture.tasks.get(fixer.id)?.column, .closed)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["check_failed"])
        let parked = await spawnCount
        await poll()
        let after = await spawnCount
        XCTAssertEqual(after, parked)
    }

    func testAFixingRoundWhoseFixItemIsResolvedBeforeItsFixerStartsEndsAndReturnsToWatching() async throws {
        try enable()
        answer(threads: [thread("T_fix")])
        await poll()
        let item = try XCTUnwrap(try watches.items(watchId: try onlyWatch().id).first)
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_verdicts",
            arguments: .object(["verdicts": .array([.object([
                "item_id": .number(Double(item.id ?? 0)), "verdict": .string("fix"), "approach": .string("Rename it."),
            ])])]),
            identity: try await identity(of: try runningTriager())
        )
        await result.afterResponse?()
        await poll()
        XCTAssertEqual(try onlyWatch().state, .fixing)

        answer(threads: [])
        await poll()
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .watching)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["triaged"])
        XCTAssertFalse(try fixture.tasks.list(projectId: fixture.project.id).contains { $0.origin == .fixRound })
    }

    /// A decision answered with a fix option starts the next round's fixer without a second triage.
    func testADecisionAnsweredAsAFixStartsTheNextRoundsFixerWithNoTriage() async throws {
        try enable()
        answer(threads: [thread("T_choice", body: "Should this be async?")])
        await poll()
        let item = try XCTUnwrap(try watches.items(watchId: try onlyWatch().id).first)
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_verdicts",
            arguments: .object(["verdicts": .array([.object([
                "item_id": .number(Double(item.id ?? 0)), "verdict": .string("decision"), "approach": .string("Direction."),
                "decision_question": .string("Make it async?"), "decision_options": .array([
                    .object(["label": .string("Yes"), "verdict": .string("fix")]),
                    .object(["label": .string("No"), "verdict": .string("answer"), "reply_body": .string("It stays sync.")]),
                ]),
            ])])]),
            identity: try await identity(of: try runningTriager())
        )
        await result.afterResponse?()
        await poll()
        XCTAssertEqual(try onlyWatch().state, .watching)

        try fixture.board.answerDecision(itemId: try XCTUnwrap(item.id), choice: .option("Yes"))
        await poll()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .fixing)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.number), [1, 2])
        XCTAssertEqual(try triageTasks().count, 1)
        let fixer = try XCTUnwrap(try fixture.tasks.list(projectId: fixture.project.id).first { $0.origin == .fixRound })
        XCTAssertTrue(fixer.body?.contains("Make it async?") == true, fixer.body ?? "")
        XCTAssertEqual(try watches.items(watchId: watch.id).first?.fixTaskId, fixer.id)
        XCTAssertFalse(try fixture.tasks.list(projectId: fixture.project.id).contains { $0.origin == .followThrough })
        XCTAssertTrue(try fixture.sessions.forTask(fixer.id).contains { $0.state.isActive })
    }

    // MARK: - Publishing

    private func rev(_ ref: String, in directory: URL? = nil) throws -> String {
        try fixture.git(["rev-parse", ref], cwd: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A round that has passed its check, with GitHub reporting the PR open at `remoteHead` (default
    /// `head`) carrying `labels` and accepting replies. Everything is staged before the check passes,
    /// since the metering tick may poll on its own and publish. Returns the round branch's tip and the
    /// round's worktree.
    private func passedRound(
        label: String? = nil, replies: Bool = false, question: Bool = false, labels: [String] = [],
        remoteHead: String? = nil, repliesGone: Bool = false
    ) async throws -> (tip: String, worktree: String) {
        try enableChecking(label: label, replies: replies)
        fixture.gh.answer(url, state: "OPEN", head: remoteHead ?? head, labels: labels)
        if repliesGone { fixture.gh.failRepliesAsGone() } else { fixture.gh.answerReplies(url: "\(url)#discussion_r1") }
        let fixer = try await runningFixer(question: question)
        let worktree = try XCTUnwrap(try activeSession(on: fixer.id).worktreePath)
        try await completeFixer(fixer, file: "fix.txt")
        await poll()
        try await review(fixer, accept: true)
        try await grade("fixed", evidence: "App.swift:3 now says count.")
        await poll()
        return (try rev("HEAD", in: URL(fileURLWithPath: worktree)), worktree)
    }

    func testAPassedRoundFastForwardsOntoThePRHeadRefAndPostsNoReplyWhileRepliesAreOff() async throws {
        let (tip, worktree) = try await passedRound()
        await poll()

        XCTAssertEqual(try rev("refs/heads/add-widgets", in: remote), tip)
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .awaitingCI)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["published"])
        XCTAssertEqual(try watches.rounds(watchId: watch.id).first?.pushedHeadOid, tip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(fixture.gh.calls.contains { $0.contains { $0.hasPrefix("body=") } }, "\(fixture.gh.calls)")

        head = tip
        answer(threads: [])
        await poll()
        XCTAssertEqual(try onlyWatch().state, .readyToVerify, "green checks on the pushed head end the wait")
    }

    func testRedChecksOnThePushedHeadKeepTheirChecksItemOpenAcrossPollsWhileTheyStayRed() async throws {
        let (tip, _) = try await passedRound()
        await poll()
        XCTAssertEqual(try onlyWatch().state, .awaitingCI)

        head = tip
        answer(threads: [], checks: "FAILURE")
        await poll()
        await poll()

        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .watching)
        let checks = try watches.items(watchId: watch.id).filter { $0.kind == .check }
        XCTAssertEqual(checks.map(\.githubNodeId), [PRItem.checksNodeId(head: tip)])
        XCTAssertEqual(checks.first?.isOpenDecision, true, "a head that stays red keeps its checks item")
    }

    func testWithRepliesOnEachHandledThreadGetsItsFactualReplyAndNoThreadIsResolved() async throws {
        let (tip, _) = try await passedRound(replies: true, question: true)
        await poll()

        let replies = fixture.gh.calls.filter { $0.contains { $0.hasPrefix("query=mutation") } }
        XCTAssertEqual(replies.map { $0.first { $0.hasPrefix("thread=") } }, ["thread=T_fix", "thread=T_question"])
        XCTAssertEqual(replies.map(\.last), ["body=Fixed in \(tip.prefix(7)).", "body=Three retries."])
        XCTAssertFalse(fixture.gh.calls.joined().contains { $0.contains("resolveReviewThread") })
        XCTAssertEqual(Set(try watches.items(watchId: try onlyWatch().id).map(\.replyURL)), ["\(url)#discussion_r1"])
    }

    /// GitHub still reports the round's base, so the push is tried and git refuses it as a non-fast-forward.
    func testAHeadRefThatMovedUnderTheRoundGoesStaleAndIsNotPushedOver() async throws {
        _ = try fixture.git(["checkout", "-q", "--detach", head])
        _ = try fixture.git(["commit", "-q", "--allow-empty", "-m", "Push from elsewhere"])
        let moved = try rev("HEAD")
        _ = try fixture.git(["checkout", "-q", "main"])
        _ = try fixture.git(["push", "-q", remote.path, "\(moved):refs/heads/add-widgets"])
        let (_, worktree) = try await passedRound()
        await poll()

        XCTAssertEqual(try rev("refs/heads/add-widgets", in: remote), moved)
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .settling)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["stale"])
        XCTAssertNil(try watches.items(watchId: watch.id).first?.verdict, "the item goes back to triage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    private var replyCalls: [[String]] { fixture.gh.calls.filter { $0.contains { $0.hasPrefix("query=mutation") } } }

    /// A round that goes stale at publishing, since `gh pr view` already reports a head that is neither
    /// its base nor its tip.
    private func staleRound(repliesGone: Bool = false) async throws -> PRWatch {
        _ = try fixture.git(["checkout", "-q", "--detach", head])
        _ = try fixture.git(["commit", "-q", "--allow-empty", "-m", "Push from elsewhere"])
        let moved = try rev("HEAD")
        _ = try fixture.git(["checkout", "-q", "main"])
        _ = try await passedRound(replies: true, question: true, remoteHead: moved, repliesGone: repliesGone)
        await poll()
        return try onlyWatch()
    }

    /// Re-triages the stale round's fix as an answer, which is the next posting point.
    private func answerStaleFix(_ watch: PRWatch) async throws {
        await poll()
        let fix = try XCTUnwrap(try watches.items(watchId: watch.id).first { $0.githubNodeId == "T_fix" })
        let result = try await TriagerToolHandler(db: fixture.db, events: sink).call(
            "set_verdicts",
            arguments: .object(["verdicts": .array([.object([
                "item_id": .number(Double(fix.id ?? 0)), "verdict": .string("answer"),
                "approach": .string("Factual."), "reply_body": .string("It was renamed upstream."),
            ])])]),
            identity: try await identity(of: try runningTriager())
        )
        await result.afterResponse?()
        await poll()
    }

    /// No push is tried. The round's answer is still replied to, once, and its fix, never pushed, claims nothing.
    func testAStaleRoundStillPostsItsAnswerReplyExactlyOnce() async throws {
        let watch = try await staleRound()

        XCTAssertEqual(try rev("refs/heads/add-widgets", in: remote), head, "nothing is pushed")
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["stale"])
        XCTAssertEqual(replyCalls.map { $0.first { $0.hasPrefix("thread=") } }, ["thread=T_question"])
        XCTAssertEqual(replyCalls.map(\.last), ["body=Three retries."])

        try await answerStaleFix(watch)

        XCTAssertEqual(try onlyWatch().state, .watching)
        XCTAssertEqual(replyCalls.map { $0.first { $0.hasPrefix("thread=") } }, ["thread=T_question", "thread=T_fix"])
        XCTAssertEqual(replyCalls.map(\.last), ["body=Three retries.", "body=It was renamed upstream."])
    }

    func testAReplyToAThreadGitHubNoLongerHasIsTriedOnceAndRecordedNotRetriedAtTheNextPostingPoint() async throws {
        let watch = try await staleRound(repliesGone: true)
        XCTAssertEqual(replyCalls.map { $0.first { $0.hasPrefix("thread=") } }, ["thread=T_question"])

        try await answerStaleFix(watch)

        XCTAssertEqual(replyCalls.map { $0.first { $0.hasPrefix("thread=") } }, ["thread=T_question", "thread=T_fix"])
        let question = try XCTUnwrap(try watches.items(watchId: watch.id).first { $0.githubNodeId == "T_question" })
        XCTAssertNil(question.replyURL)
        XCTAssertNotNil(question.replyAbandonedAt)
        XCTAssertTrue(question.replyError?.contains("Could not resolve to a node") == true, question.replyError ?? "")
    }

    func testAVerificationLabelOnThePRBlocksThePushAndFreezesTheRoundsItemsAsDecisions() async throws {
        _ = try await passedRound(label: "verified-example", replies: true, labels: ["verified-example"])
        await poll()

        XCTAssertEqual(try rev("refs/heads/add-widgets", in: remote), head)
        let watch = try onlyWatch()
        XCTAssertEqual(watch.state, .verified)
        XCTAssertEqual(try watches.rounds(watchId: watch.id).map(\.outcome), ["frozen"])
        XCTAssertEqual(try watches.items(watchId: watch.id).first?.isOpenDecision, true)
        XCTAssertFalse(fixture.gh.calls.contains { $0.contains { $0.hasPrefix("body=") } })
    }
}
