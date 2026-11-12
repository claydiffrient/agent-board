import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6 `watch_pr`: the orchestrator only asks; the human's grant is what adopts.
final class WatchPRToolTests: XCTestCase {
    func testWatchPRWaitsOnTheHumansGrantAndIsRefusedWhileFollowThroughIsOff() async throws {
        let f = try BridgeFixture.make()
        await XCTAssertToolError(
            try await f.call("watch_pr", ["number": .number(12), "reason": .string("Reassigned to the human.")]),
            containing: "needs PR follow-through"
        )
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])

        var settings = f.project.settings
        settings.prFollowThrough.enabled = true
        try ProjectStore(f.db).updateSettings(f.project.id, settings)
        let result = try await f.call("watch_pr", ["number": .number(12), "reason": .string("Reassigned to the human.")])
        _ = try await f.call("watch_pr", ["number": .number(12), "reason": .string("Asked again.")])

        XCTAssertTrue(result.text.contains("pending"), result.text)
        let approval = try XCTUnwrap(f.approvals.pending(projectId: f.project.id).first)
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [approval])
        XCTAssertEqual(approval.kind, .prWatchAdopt)
        XCTAssertEqual(
            try PRWatchAdoptionRequest.decode(approval.payload),
            PRWatchAdoptionRequest(number: 12, reason: "Reassigned to the human.")
        )
        XCTAssertEqual(try PRWatchStore(f.db).live(projectId: f.project.id), [])
    }
}
