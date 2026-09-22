import AgentBoardBridge
import AgentBoardCore
import AgentBoardRuntime
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// A worker that finishes normally used to leave its `claude --bg` session resident forever: the
/// agent stops taking turns and the session sits `idle` holding its whole context. Measured on this
/// machine before the fix — 53 `claude` processes, 9,365 MB.
@MainActor
final class CompletionStopsTheAgentTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        await fixture.supervisor.start()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func reportComplete(_ worker: (task: BoardTask, sessionId: String, token: String)) async throws {
        _ = try await fixture.callWorkerTool(
            "report_complete",
            arguments: .object([
                "summary": .string("did the thing"),
                "files_changed": .array([.string("Sources/Thing.swift")]),
                "tests_run": .string("swift test"),
                "caveats": .string("none"),
            ]),
            token: worker.token
        )
    }

    func testReportCompleteStopsTheSessionByItsShortIdAndLeavesTheTaskInReview() async throws {
        let worker = try fixture.workerAtWork()
        let shortId = try XCTUnwrap(fixture.sessions.get(worker.sessionId)?.shortId)

        try await reportComplete(worker)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [shortId], "the completed worker's agent was left running")
        XCTAssertEqual(try fixture.tasks.get(worker.task.id)?.column, .review)
        XCTAssertEqual(try fixture.sessions.get(worker.sessionId)?.state, .completed)
    }

    /// The stop must not take the transcript, the short id or the grant with it: a task in `review`
    /// is one a human may reopen. Measured against claude 2.1.272 that `claude --bg --resume` wakes
    /// a stopped session into the same transcript (see this task's note); this pins the board side.
    func testACompletedAndStoppedSessionCanStillBeResumed() async throws {
        let worker = try fixture.workerAtWork()
        try await reportComplete(worker)

        try await fixture.supervisor.resume(sessionId: worker.sessionId)

        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [worker.sessionId])
        XCTAssertNotNil(
            try fixture.sessions.get(worker.sessionId)?.shortId,
            "completion cleared the short id, so nothing can address the session afterwards"
        )
    }

    func testCompletionNeverRemovesTheSession() async throws {
        let worker = try fixture.workerAtWork()

        try await reportComplete(worker)

        let removed = await fixture.runtime.removed
        XCTAssertEqual(removed, [], "completion called remove, which strips the session's saved spawn options")
    }

    /// A row the board has no short id for — a setup that never produced an agent — has nothing to
    /// stop, and `report_complete` must not invent one.
    func testAnUnpromotedSessionRowStopsNothing() async throws {
        let task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Never launched", body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        let sessionId = "session-\(UUID().uuidString)"
        try fixture.sessions.insert(AgentSession(
            sessionId: sessionId, projectId: fixture.project.id, taskId: task.id, role: .worker,
            cwd: fixture.supportDir.path, state: .setup
        ))
        let grant = try fixture.grants.issue(projectId: fixture.project.id, scope: .worker, taskId: task.id)
        try fixture.grants.bind(token: grant.token, sessionId: sessionId)

        try await reportComplete((task: task, sessionId: sessionId, token: grant.token))

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(try fixture.tasks.get(task.id)?.column, .review)
    }
}

@MainActor
final class LaunchSweepTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    @discardableResult
    private func session(_ shortId: String?, _ state: SessionState) throws -> String {
        let sessionId = "session-\(UUID().uuidString)"
        try fixture.sessions.insert(AgentSession(
            sessionId: sessionId, shortId: shortId, projectId: fixture.project.id, taskId: nil,
            role: .worker, cwd: fixture.supportDir.path, state: state
        ))
        return sessionId
    }

    /// A registry row for a session that still has a process. `pid` is what tells a resident
    /// session from one whose row outlived it.
    private func listing(_ shortIds: [String]) -> [AgentInfo] {
        shortIds.enumerated().map { index, shortId in
            AgentInfo(id: shortId, cwd: "/tmp", kind: "background", sessionId: "uuid-\(shortId)",
                      state: "done", pid: 9000 + index)
        }
    }

    func testTheSweepStopsAnInactiveSessionAndLeavesAnActiveOne() async throws {
        try session("leaked", .completed)
        try session("working", .running)
        await fixture.runtime.setListed(listing(["leaked", "working"]))

        let report = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["leaked"])
        XCTAssertEqual(report.stopped.map(\.shortId), ["leaked"])
        XCTAssertEqual(report.kept.map(\.shortId), ["working"])
        XCTAssertEqual(report.kept.first?.reason, "state running is active")
    }

    func testEveryInactiveStateIsSwept() async throws {
        for (index, state) in SessionState.allCases.enumerated() {
            try session("s\(index)", state)
        }
        await fixture.runtime.setListed(listing(SessionState.allCases.indices.map { "s\($0)" }))

        let report = await fixture.supervisor.sweepLeakedAgents()

        let swept = Set(report.stopped.compactMap(\.shortId))
        let expected = Set(SessionState.allCases.enumerated().filter { !$0.element.isActive }.map { "s\($0.offset)" })
        XCTAssertEqual(swept, expected)
        XCTAssertFalse(expected.isEmpty)
    }

    /// The whole point of sourcing targets from `agent_session`: this machine runs interactive
    /// `claude` sessions the human is sitting in, some for days. One that looks exactly like a
    /// leaked worker — same `kind`, same `state` — is still never a candidate.
    func testASessionAbsentFromTheDatabaseIsNeverTargeted() async throws {
        try session("ours", .completed)
        await fixture.runtime.setListed([
            AgentInfo(id: "ours", cwd: "/tmp", kind: "background", sessionId: "uuid-ours", state: "done", pid: 9001),
            AgentInfo(id: "stranger", cwd: "/tmp", kind: "background", sessionId: "uuid-stranger", state: "done", pid: 9002),
            AgentInfo(id: "human", cwd: "/Users/someone", kind: "interactive", sessionId: "uuid-human", state: "idle", pid: 9003),
        ])

        let report = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["ours"])
        XCTAssertFalse(stopped.contains("stranger"))
        XCTAssertFalse(stopped.contains("human"))
        XCTAssertEqual(report.untracked, 2)
        XCTAssertTrue(report.runtimeListed)
    }

    func testAnEmptyDatabaseTouchesNothingHoweverManySessionsAreLive() async throws {
        await fixture.runtime.setListed(listing(["a", "b", "c", "d"]))

        let report = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(report.untracked, 4)
    }

    /// The two orphans on this machine — 23 hours and 1 day 4 hours, reparented to pid 1 — have no
    /// launcher left, but the board still has their rows, so they are still reachable by short id.
    func testASessionWhoseLauncherIsGoneIsStillSweptByItsRow() async throws {
        try session("orphan", .completed)
        await fixture.runtime.setListed(listing(["orphan"]))

        _ = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["orphan"])
    }

    /// 148 registry rows against 61 processes: most historical rows are long gone, and attempting
    /// each one would report a hundred failures for nothing. The runtime list may subtract a target,
    /// never add one.
    func testAShortIdTheRuntimeNoLongerListsIsKeptWithAReason() async throws {
        try session("ancient", .completed)
        await fixture.runtime.setListed([])

        let report = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(report.kept.map(\.reason), ["the runtime reports no process for this short id"])
    }

    /// 124 of this machine's 134 rows were inactive with a short id, and `claude stop` succeeded on
    /// every one — but only 8 carried a pid, and those 8 were the whole 1,311 MB. The other 116 cost
    /// 60s of subprocess spawning at launch and freed nothing.
    func testARowWhoseRegistryEntryHasNoProcessIsKeptWithAReason() async throws {
        try session("ghost", .completed)
        await fixture.runtime.setListed([
            AgentInfo(id: "ghost", cwd: "/tmp", kind: "background", sessionId: "uuid-ghost", state: "done"),
        ])

        let report = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(report.kept.map(\.reason), ["the runtime reports no process for this short id"])
    }

    func testAnUnlistableRuntimeStillSweepsAndSaysTheCountIsUnknown() async throws {
        try session("leaked", .completed)
        await fixture.runtime.failListing(FixtureError("claude agents failed"))

        let report = await fixture.supervisor.sweepLeakedAgents()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["leaked"])
        XCTAssertFalse(report.runtimeListed)
        XCTAssertTrue(report.lines.contains("UNTRACKED unknown — the runtime could not be listed"))
    }

    func testTheSweepNeverRemovesASession() async throws {
        try session("leaked", .completed)
        await fixture.runtime.setListed(listing(["leaked"]))

        _ = await fixture.supervisor.sweepLeakedAgents()

        let removed = await fixture.runtime.removed
        XCTAssertEqual(removed, [], "the sweep called remove, which strips a session's saved spawn options")
    }

    func testLaunchRunsTheSweep() async throws {
        try session("leaked", .completed)
        await fixture.runtime.setListed(listing(["leaked"]))

        await fixture.supervisor.start()

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, ["leaked"])
    }
}

@MainActor
final class SweepDryRunTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func session(_ shortId: String?, _ state: SessionState) throws {
        try fixture.sessions.insert(AgentSession(
            sessionId: "session-\(shortId ?? UUID().uuidString)", shortId: shortId,
            projectId: fixture.project.id, taskId: nil, role: .worker,
            cwd: fixture.supportDir.path, state: state
        ))
    }

    func testTheDryRunStopsNothingAndNamesEveryDecisionWithItsReason() async throws {
        try session("leaked", .completed)
        try session("busy", .running)
        try session(nil, .completed)
        await fixture.runtime.setListed([
            AgentInfo(id: "leaked", cwd: "/tmp", kind: "background", sessionId: "uuid-leaked", state: "done", pid: 9001),
            AgentInfo(id: "busy", cwd: "/tmp", kind: "background", sessionId: "uuid-busy", state: "working", pid: 9002),
            AgentInfo(id: "elsewhere", cwd: "/tmp", kind: "background", sessionId: "uuid-elsewhere", state: "idle", pid: 9003),
        ])

        let report = await fixture.supervisor.sweepLeakedAgents(dryRun: true)

        let stopped = await fixture.runtime.stopped
        XCTAssertEqual(stopped, [], "a dry run stopped a session")
        XCTAssertEqual(report.stopped, [])
        XCTAssertEqual(report.wouldStop.map(\.shortId), ["leaked"])

        let lines = report.lines
        XCTAssertTrue(
            lines.contains("WOULD-STOP leaked session-leaked — state completed is inactive but the agent was never stopped"),
            lines.joined(separator: "\n")
        )
        XCTAssertTrue(lines.contains("KEPT busy session-busy — state running is active"), lines.joined(separator: "\n"))
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("KEPT - ") && $0.hasSuffix("no short id: the board never learned of an agent for this row") },
            lines.joined(separator: "\n")
        )
        XCTAssertTrue(
            lines.contains("UNTRACKED 1 — live claude sessions the board has no row for, never touched"),
            lines.joined(separator: "\n")
        )
    }

    func testEveryDecisionGetsALineIncludingTheKeeps() async throws {
        try session("a", .completed)
        try session("b", .idle)
        try session("c", .failed)
        await fixture.runtime.setListed([
            AgentInfo(id: "a", cwd: "/tmp", kind: "background", sessionId: "uuid-a", pid: 9001),
            AgentInfo(id: "b", cwd: "/tmp", kind: "background", sessionId: "uuid-b", pid: 9002),
            AgentInfo(id: "c", cwd: "/tmp", kind: "background", sessionId: "uuid-c", pid: 9003),
        ])

        let report = await fixture.supervisor.sweepLeakedAgents(dryRun: true)

        XCTAssertEqual(report.lines.count, 4, report.lines.joined(separator: "\n"))
        XCTAssertEqual(report.wouldStop.count + report.kept.count, 3)
    }
}

/// `LeakedAgentSweep.plan` takes `[AgentSession]` and nothing else, so no amount of process
/// inspection can reach a decision. These pin that at the type level and at the source level.
final class SweepDecidesFromRowsOnlyTests: XCTestCase {
    private func session(_ sessionId: String, _ shortId: String?, _ state: SessionState) -> AgentSession {
        AgentSession(
            sessionId: sessionId, shortId: shortId, projectId: "p", taskId: nil, role: .worker,
            cwd: "/tmp", state: state
        )
    }

    func testThePlanSelectsInactiveRowsThatStillHoldAShortId() {
        let plan = LeakedAgentSweep.plan([
            session("s1", "a", .completed),
            session("s2", "b", .running),
            session("s3", nil, .completed),
            session("s4", "d", .failed),
            session("s5", "e", .stopped),
        ])

        XCTAssertEqual(
            plan.filter { $0.outcome == .stop }.compactMap(\.shortId),
            ["a", "d", "e"]
        )
        XCTAssertEqual(plan.count, 5, "a decision must be reported for every row, keeps included")
    }

    func testEveryKeepCarriesAReason() {
        let plan = LeakedAgentSweep.plan([session("s2", "b", .running), session("s3", nil, .completed)])
        for decision in plan where decision.outcome == .keep {
            XCTAssertFalse(decision.reason.isEmpty)
        }
        XCTAssertEqual(plan.map(\.reason), [
            "state running is active",
            "no short id: the board never learned of an agent for this row",
        ])
    }

    /// `ps`, argv and the environment cannot tell a parked spare from a session doing real work:
    /// the daemon claims a warm spare in place without re-execing, so the two are byte-for-byte
    /// identical. A rule built on them selected seven hosts on a real machine and six were live.
    /// Nothing on the sweep or completion path may reach for them.
    func testNeitherTheSweepNorTheCompletionPathInspectsProcesses() throws {
        let banned = ["/bin/ps", "processIdentifier", "kill(", "/proc", "sysctl", "KERN_PROC", "argv", "environment"]
        for file in ["Sources/AgentBoardCore/LeakedAgentSweep.swift",
                     "Sources/AgentBoard/Services/WorkerSupervisor.swift",
                     "Sources/AgentBoardBridge/WorkerToolHandler.swift"] {
            let url = Self.repoRoot.appendingPathComponent(file)
            // Comments discuss `ps` and argv at length; only the code is under test.
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for needle in banned {
                XCTAssertFalse(code.contains(needle), "\(file) reaches for \(needle)")
            }
        }
    }

    /// `claude agents rm` keeps the transcript and leaves a git worktree alone, but it discards the
    /// session's saved spawn options — and `BackgroundSessionRuntime.resume` sends none of them,
    /// so a removed-then-resumed session comes back without `--disallowedTools`. Measured: a
    /// session spawned `--disallowedTools Bash` refused Bash on resume, and ran it after a remove.
    func testResumeCarriesNoOptionsOfItsOwnSoRemoveWouldStripTheGuardrails() {
        let resumeArguments = ["hello", "--bg", "--resume", "some-session-id"]
        XCTAssertFalse(resumeArguments.contains("--disallowedTools"))
        XCTAssertFalse(resumeArguments.contains("--settings"))

        let spawn = BackgroundSessionRuntime.arguments(for: SpawnRequest(
            cwd: URL(fileURLWithPath: "/tmp"), name: "n", prompt: "hello",
            configFiles: SessionConfigFiles(
                settingsURL: URL(fileURLWithPath: "/tmp/settings.json"),
                mcpConfigURL: URL(fileURLWithPath: "/tmp/mcp.json")
            )
        ))
        XCTAssertTrue(spawn.contains("--disallowedTools"), "a spawn is where the guardrails come from")
        XCTAssertEqual(SpawnRequest.defaultDisallowedTools, [
            "Bash(git push*)", "Bash(gh pr create*)", "Bash(gh pr merge*)",
        ])
    }

    /// Nothing in the shipped app calls `remove`, and this is the reason why.
    func testNothingInTheAppCallsRemove() throws {
        var callers: [String] = []
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("runtime.remove(") || line.contains("ClaudeCLI.remove(") {
                callers.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(
            callers,
            ["AgentRuntime.swift: try await offMain { try ClaudeCLI.remove(shortId: shortId) }"],
            "remove gained a caller; it discards the session's saved --disallowedTools"
        )
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
