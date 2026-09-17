import XCTest
@testable import AgentBoardCore

final class AttentionPresentationTests: XCTestCase {
    private func text(_ reason: AttentionReason, _ count: Int, detail: String? = nil) -> String {
        AttentionCause(reason: reason, count: count, detail: detail).text
    }

    private func attention(_ causes: [AttentionCause]) -> ProjectAttention {
        ProjectAttention(id: "p", name: "Demo", causes: causes)
    }

    func testEveryCauseReadsInBothSingularAndPlural() throws {
        XCTAssertEqual(text(.pendingApproval, 1), "1 approval waiting")
        XCTAssertEqual(text(.pendingApproval, 4), "4 approvals waiting")
        XCTAssertEqual(text(.blockedWorker, 1), "1 worker blocked")
        XCTAssertEqual(text(.blockedWorker, 2), "2 workers blocked")
        XCTAssertEqual(text(.strandedReports, 1), "1 report waiting with no orchestrator running")
        XCTAssertEqual(text(.strandedReports, 9), "9 reports waiting with no orchestrator running")
        XCTAssertEqual(text(.overdueShutdown, 1), "1 agent has not acknowledged shutdown")
        XCTAssertEqual(text(.overdueShutdown, 3), "3 agents have not acknowledged shutdown")
    }

    /// The task title only fits when there is exactly one blocked worker to attribute it to.
    func testASingleBlockedWorkerIsNamed() {
        XCTAssertEqual(text(.blockedWorker, 1, detail: "Wire the thing"), "1 worker blocked: Wire the thing")
        XCTAssertEqual(text(.blockedWorker, 2, detail: "Wire the thing"), "2 workers blocked")
    }

    func testSummaryJoinsEveryCauseIntoOneSentence() {
        let signal = attention([
            AttentionCause(reason: .pendingApproval, count: 2),
            AttentionCause(reason: .overdueShutdown, count: 1),
        ])
        XCTAssertEqual(signal.summary, "2 approvals waiting, 1 agent has not acknowledged shutdown.")
    }

    func testAQuietProjectHasNothingToSayAndNoBadge() {
        let signal = attention([])
        XCTAssertNil(signal.summary)
        XCTAssertNil(signal.badgeCount)
        XCTAssertFalse(signal.needsAttention)
    }

    func testTheBadgeCountsEveryWaitingThingNotEveryReason() {
        let signal = attention([
            AttentionCause(reason: .pendingApproval, count: 2),
            AttentionCause(reason: .strandedReports, count: 5),
        ])
        XCTAssertEqual(signal.badgeCount, 7)
    }

    /// Declaration order is the contract the store sorts by and the summary reads in.
    func testSeverityOrderPutsApprovalsFirstAndShutdownLast() {
        XCTAssertEqual(
            AttentionReason.allCases,
            [.pendingApproval, .blockedWorker, .strandedReports, .overdueShutdown]
        )
        XCTAssertLessThan(AttentionReason.pendingApproval.severity, AttentionReason.blockedWorker.severity)
        XCTAssertLessThan(AttentionReason.strandedReports.severity, AttentionReason.overdueShutdown.severity)
    }
}
