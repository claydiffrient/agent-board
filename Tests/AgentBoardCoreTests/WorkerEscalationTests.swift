import XCTest
@testable import AgentBoardCore

/// SPEC §5 retries: Opus moves up to Fable only when the project allows it.
final class WorkerEscalationTests: XCTestCase {
    func testOpusAtExtraHighMovesToFableOnlyWithTheSettingOn() {
        let resolved = WorkerModelChoice(
            model: "claude-opus-5-5", modelSource: .typeTable, effort: .medium, effortSource: .typeTable
        )
        let prior = WorkerEscalation.Prior(attempt: 3, model: "claude-opus-5-5", effort: .xhigh, shortfall: .failed)

        let off = WorkerEscalation.escalate(resolved, after: prior, attempt: 4, allowsFable: false)
        XCTAssertEqual(off.model, "claude-opus-5-5")
        XCTAssertEqual(off.effort, .xhigh, "the top of the ladder keeps the effort the last attempt reached")

        let on = WorkerEscalation.escalate(resolved, after: prior, attempt: 4, allowsFable: true)
        XCTAssertEqual(on.model, "claude-fable-5-2")
        XCTAssertEqual(on.effort, .medium)
    }

    func testARetryRunsOnADefaultTheHumanRaisedAfterTheFailure() {
        let raised = WorkerModelChoice(
            model: "claude-opus-5-5", modelSource: .projectDefault, effort: .medium, effortSource: .typeTable
        )
        let prior = WorkerEscalation.Prior(attempt: 1, model: "claude-sonnet-5-5", effort: .medium, shortfall: .failed)
        XCTAssertEqual(WorkerEscalation.escalate(raised, after: prior, attempt: 2, allowsFable: false), raised)

        let lowered = WorkerModelChoice(
            model: "claude-sonnet-5-5", modelSource: .projectDefault, effort: .medium, effortSource: .typeTable
        )
        let after = WorkerEscalation.escalate(lowered, after: prior, attempt: 2, allowsFable: false)
        XCTAssertEqual(after.effort, .high, "an unchanged default still escalates")
    }

    private func session(
        _ attempt: Int, state: SessionState, started: Int64, stopReason: String? = nil
    ) -> AgentSession {
        AgentSession(
            sessionId: "s\(attempt)", projectId: "p", taskId: "t", role: .worker, cwd: "/tmp", state: state,
            startedAt: started, attempt: attempt, model: "claude-sonnet-5-5", effort: .medium, stopReason: stopReason
        )
    }

    func testAReviewReopenAtOrAfterTheSessionStartedIsAShortfall() {
        let sessions = [session(1, state: .completed, started: 1_000)]
        for at in [Int64(1_000), 2_000] {
            let prior = WorkerEscalation.prior(sessions: sessions, reviewReopenedAt: at, cutBySleep: { _ in false })
            XCTAssertEqual(prior?.shortfall, .reviewReopened, "reopened at \(at)")
        }
    }

    func testAReviewReopenBeforeTheSessionStartedIsNotAShortfall() {
        let sessions = [session(1, state: .completed, started: 1_000)]
        XCTAssertNil(WorkerEscalation.prior(sessions: sessions, reviewReopenedAt: 999, cutBySleep: { _ in false }))
    }

    func testAFailedSessionCutBySleepIsSkipped() {
        let sessions = [
            session(2, state: .failed, started: 2_000, stopReason: "cap"),
            session(1, state: .failed, started: 1_000, stopReason: "cap"),
        ]
        let prior = WorkerEscalation.prior(
            sessions: sessions, reviewReopenedAt: nil, cutBySleep: { $0.attempt == 2 }
        )
        XCTAssertEqual(prior?.attempt, 1)
    }
}
