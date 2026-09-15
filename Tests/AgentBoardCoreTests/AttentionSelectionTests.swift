import Foundation
import XCTest
@testable import AgentBoardCore

final class AttentionSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func task(
        _ id: String,
        column: TaskColumn = .running,
        blocked: Bool = false,
        reason: String? = nil,
        updatedAt: Int64 = 0
    ) -> BoardTask {
        BoardTask(
            id: id, projectId: "p", epicId: nil, title: "task \(id)", body: nil, acceptance: nil,
            priority: nil, column: column, blocked: blocked, blockedReason: reason, ordering: 1,
            origin: .human, createdAt: 0, updatedAt: updatedAt
        )
    }

    private func session(
        _ id: String,
        taskId: String?,
        role: SessionRole = .worker,
        state: SessionState = .running,
        startedAt: Date,
        lastActivity: Date? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: id, shortId: String(id.prefix(8)), projectId: "p", taskId: taskId, role: role,
            cwd: "/tmp", state: state, startedAt: startedAt.millis, lastActivity: lastActivity?.millis
        )
    }

    // MARK: - The stalled predicate

    func testStalledExactlyAtTheThreshold() {
        XCTAssertTrue(
            AttentionSelection.isStalled(
                lastActivity: now.addingTimeInterval(-120), startedAt: now.addingTimeInterval(-600),
                awake: .init(now: now), threshold: 120
            )
        )
    }

    func testIdleButNotYetStalledOneSecondShortOfTheThreshold() {
        XCTAssertFalse(
            AttentionSelection.isStalled(
                lastActivity: now.addingTimeInterval(-119), startedAt: now.addingTimeInterval(-600),
                awake: .init(now: now), threshold: 120
            )
        )
    }

    func testNeverActiveSessionIsMeasuredFromItsStart() {
        XCTAssertTrue(
            AttentionSelection.isStalled(
                lastActivity: nil, startedAt: now.addingTimeInterval(-300), awake: .init(now: now), threshold: 120
            )
        )
        XCTAssertFalse(
            AttentionSelection.isStalled(
                lastActivity: nil, startedAt: now.addingTimeInterval(-30), awake: .init(now: now), threshold: 120
            )
        )
    }

    func testNonPositiveThresholdNeverStalls() {
        XCTAssertFalse(
            AttentionSelection.isStalled(
                lastActivity: nil, startedAt: now.addingTimeInterval(-99_999), awake: .init(now: now), threshold: 0
            )
        )
    }

    /// The stall suspicion is measured on the same clock as the cap, so waking the machine does
    /// not fill the sidebar with workers accused of being stuck.
    func testASuspendedWorkerIsNotStalled() {
        let slept = ObservedSleep(endedAtMillis: Int64(now.timeIntervalSince1970 * 1000) - 5_000, millis: 1_195_000)
        XCTAssertTrue(
            AttentionSelection.isStalled(
                lastActivity: now.addingTimeInterval(-1200), startedAt: now.addingTimeInterval(-1800),
                awake: .init(now: now), threshold: 120
            )
        )
        XCTAssertFalse(
            AttentionSelection.isStalled(
                lastActivity: now.addingTimeInterval(-1200), startedAt: now.addingTimeInterval(-1800),
                awake: .init(now: now, sleeps: [slept]), threshold: 120
            )
        )
    }

    // MARK: - Section membership

    func testBlockedTaskAppearsWithItsActiveSession() {
        let blocked = task("t1", blocked: true, reason: "Claude needs your permission", updatedAt: now.addingTimeInterval(-90).millis)
        let session = session("f9047594-aaaa", taskId: "t1", state: .blocked, startedAt: now.addingTimeInterval(-600), lastActivity: now.addingTimeInterval(-90))

        let items = AttentionSelection.needingAttention(
            tasks: [blocked, task("t2")], sessions: [session], awake: .init(now: now), stallThreshold: 120
        )

        XCTAssertEqual(items.map(\.id), ["t1"])
        XCTAssertEqual(items[0].kind, .blocked)
        XCTAssertEqual(items[0].reason, "Claude needs your permission")
        XCTAssertEqual(items[0].session?.sessionId, "f9047594-aaaa")
        XCTAssertEqual(items[0].since, now.addingTimeInterval(-90))
    }

    func testHealthyRunningWorkerIsAbsent() {
        let session = session("s1", taskId: "t1", startedAt: now.addingTimeInterval(-600), lastActivity: now.addingTimeInterval(-10))
        let items = AttentionSelection.needingAttention(
            tasks: [task("t1")], sessions: [session], awake: .init(now: now), stallThreshold: 120
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testWedgedWorkerSurfacesAsStalledNotBlocked() {
        let session = session("b2b3848d-bbbb", taskId: "t1", startedAt: now.addingTimeInterval(-600), lastActivity: now.addingTimeInterval(-400))

        let items = AttentionSelection.needingAttention(
            tasks: [task("t1")], sessions: [session], awake: .init(now: now), stallThreshold: 120
        )

        XCTAssertEqual(items.map(\.kind), [.stalled])
        XCTAssertNil(items[0].reason)
        XCTAssertEqual(items[0].since, now.addingTimeInterval(-400))
    }

    func testABlockedTaskIsReportedOnceEvenWhenItsSessionAlsoLooksStalled() {
        let blocked = task("t1", blocked: true, reason: "Claude needs your permission", updatedAt: now.addingTimeInterval(-500).millis)
        let session = session("s1", taskId: "t1", startedAt: now.addingTimeInterval(-900), lastActivity: now.addingTimeInterval(-500))

        let items = AttentionSelection.needingAttention(
            tasks: [blocked], sessions: [session], awake: .init(now: now), stallThreshold: 120
        )

        XCTAssertEqual(items.map(\.kind), [.blocked])
    }

    func testOnlyRunningSessionsCanStall() {
        for state in [SessionState.idle, .starting, .stopped, .completed, .failed] {
            let session = session("s-\(state.rawValue)", taskId: "t1", state: state, startedAt: now.addingTimeInterval(-900))
            let items = AttentionSelection.needingAttention(
                tasks: [task("t1")], sessions: [session], awake: .init(now: now), stallThreshold: 120
            )
            XCTAssertTrue(items.isEmpty, "\(state.rawValue) should not be reported as stalled")
        }
    }

    func testOrchestratorSessionIsNeverReported() {
        let session = session("orch", taskId: "t1", role: .orchestrator, startedAt: now.addingTimeInterval(-900))
        let items = AttentionSelection.needingAttention(
            tasks: [task("t1")], sessions: [session], awake: .init(now: now), stallThreshold: 120
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testBlockedTaskWithNoLiveSessionStillShowsWithoutOne() {
        let blocked = task("t1", blocked: true, reason: "stopped mid-prompt", updatedAt: now.addingTimeInterval(-60).millis)
        let dead = session("s1", taskId: "t1", state: .stopped, startedAt: now.addingTimeInterval(-900))

        let items = AttentionSelection.needingAttention(
            tasks: [blocked], sessions: [dead], awake: .init(now: now), stallThreshold: 120
        )

        XCTAssertEqual(items.map(\.kind), [.blocked])
        XCTAssertNil(items[0].session)
    }

    func testBlockedSortsAboveStalledAndLongestWaitFirstWithin() {
        let tasks = [
            task("stale-new", updatedAt: 0),
            task("stale-old", updatedAt: 0),
            task("blocked-new", blocked: true, reason: "b", updatedAt: now.addingTimeInterval(-30).millis),
            task("blocked-old", blocked: true, reason: "a", updatedAt: now.addingTimeInterval(-600).millis),
        ]
        let sessions = [
            session("s1", taskId: "stale-new", startedAt: now.addingTimeInterval(-900), lastActivity: now.addingTimeInterval(-200)),
            session("s2", taskId: "stale-old", startedAt: now.addingTimeInterval(-900), lastActivity: now.addingTimeInterval(-800)),
            session("s3", taskId: "blocked-new", state: .blocked, startedAt: now.addingTimeInterval(-900)),
            session("s4", taskId: "blocked-old", state: .blocked, startedAt: now.addingTimeInterval(-900)),
        ]

        let items = AttentionSelection.needingAttention(tasks: tasks, sessions: sessions, awake: .init(now: now), stallThreshold: 120)

        XCTAssertEqual(items.map(\.id), ["blocked-old", "blocked-new", "stale-old", "stale-new"])
    }

    func testTheNewestAttemptIsTheSessionOffered() {
        let first = session("attempt-1", taskId: "t1", startedAt: now.addingTimeInterval(-900), lastActivity: now.addingTimeInterval(-880))
        let second = session("attempt-2", taskId: "t1", startedAt: now.addingTimeInterval(-400), lastActivity: now.addingTimeInterval(-390))

        let items = AttentionSelection.needingAttention(
            tasks: [task("t1")], sessions: [first, second], awake: .init(now: now), stallThreshold: 120
        )

        XCTAssertEqual(items.map(\.session?.sessionId), ["attempt-2"])
    }
}

private extension Date {
    var millis: Int64 { Int64(timeIntervalSince1970 * 1000) }
}
