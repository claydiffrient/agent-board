import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6 `resume_pr_watch`: the orchestrator only asks; the human's grant is what resumes.
final class ResumePRWatchToolTests: XCTestCase {
    private func watch(_ f: BridgeFixture, number: Int, in projectId: String, parked: Bool = true) throws -> PRWatch {
        let watch = try PRWatchStore(f.db).upsert(projectId: projectId, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Change \(number)",
            headRef: "feature-\(number)", headOid: String(repeating: "a", count: 40), baseRef: "main", items: []
        ))
        if parked {
            try f.db.writer.write { db in
                try db.execute(
                    sql: "UPDATE pr_watch SET state = 'parked', parked_reason = ? WHERE id = ?",
                    arguments: ["Hit the round cap of 2.", watch.id]
                )
            }
        }
        return try XCTUnwrap(PRWatchStore(f.db).get(watch.id))
    }

    func testResumePRWatchWaitsOnTheHumansGrantAndRefusesAnUnparkedOrForeignWatch() async throws {
        let f = try BridgeFixture.make()
        let watches = PRWatchStore(f.db)
        let ours = try watch(f, number: 12, in: f.project.id)
        let unparked = try watch(f, number: 14, in: f.project.id, parked: false)
        let theirs = try watch(f, number: 13, in: try f.otherProject().id)

        let result = try await f.call("resume_pr_watch", [
            "number": .number(12), "reason": .string("Raised the round cap."),
        ])

        XCTAssertTrue(result.text.contains("pending"), result.text)
        let approval = try XCTUnwrap(f.approvals.pending(projectId: f.project.id).first)
        XCTAssertEqual(approval.kind, .prWatchResume)
        XCTAssertEqual(try PRWatchResumeRequest.decode(approval.payload), PRWatchResumeRequest(
            watchId: ours.id, number: 12, title: "Change 12", parkedReason: "Hit the round cap of 2.",
            reason: "Raised the round cap."
        ))
        XCTAssertEqual(try watches.get(ours.id)?.state, .parked)

        await XCTAssertToolError(
            try await f.call("resume_pr_watch", ["watch_id": .string(unparked.id), "reason": .string("Fixed.")]),
            containing: "not parked"
        )
        await XCTAssertToolError(
            try await f.call("resume_pr_watch", ["watch_id": .string(theirs.id), "reason": .string("Fixed.")]),
            containing: "not found"
        )
        XCTAssertEqual(try watches.get(theirs.id)?.state, .parked)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [approval])
    }

    func testGrantingResumesTheWatchAndAWatchNoLongerParkedIsReportedNotThrown() throws {
        let f = try BridgeFixture.make()
        let watches = PRWatchStore(f.db)
        let parked = try watch(f, number: 12, in: f.project.id)
        let resumedByHand = try watch(f, number: 14, in: f.project.id)
        let first = try f.board.requestWatchResume(
            projectId: f.project.id, watchId: parked.id, reason: "Raised the round cap.", requestedBy: "orchestrator"
        )
        let second = try f.board.requestWatchResume(
            projectId: f.project.id, watchId: resumedByHand.id, reason: "Fixed the fork.", requestedBy: "orchestrator"
        )

        try f.board.resolveApproval(first.id, approved: true, by: "human")
        XCTAssertEqual(try f.board.applyWatchResume(first)?.state, .settling)
        XCTAssertEqual(try watches.get(parked.id)?.state, .settling)

        try watches.resume(watchId: resumedByHand.id)
        try f.board.resolveApproval(second.id, approved: true, by: "human")
        XCTAssertNil(try f.board.applyWatchResume(second))

        let reports = try f.reports.unconsumed(projectId: f.project.id).filter { $0.kind == .decision }
        XCTAssertEqual(reports.count, 2, reports.map(\.body).joined(separator: "\n"))
        XCTAssertTrue(reports[0].body.hasPrefix("#12 resumed, now settling"), reports[0].body)
        XCTAssertTrue(reports[1].body.contains("#14 was not resumed: it is no longer parked (it is settling)"), reports[1].body)
    }
}
