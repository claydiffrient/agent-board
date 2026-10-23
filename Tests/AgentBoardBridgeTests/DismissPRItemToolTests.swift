import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6 `dismiss_pr_item`: the orchestrator only asks; the human's grant is what dismisses.
final class DismissPRItemToolTests: XCTestCase {
    private func watch(_ f: BridgeFixture, number: Int, in projectId: String) throws -> (PRWatch, Int64) {
        let watches = PRWatchStore(f.db)
        let watch = try watches.upsert(projectId: projectId, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Change \(number)",
            headRef: "feature-\(number)", headOid: String(repeating: "a", count: 40), baseRef: "main",
            items: [PRSnapshotItem(githubNodeId: "T\(number)", kind: .thread, author: "reviewer", body: "Edit the description.")]
        ))
        return (watch, try XCTUnwrap(watches.items(watchId: watch.id).first?.id))
    }

    func testDismissPRItemWaitsOnTheHumansGrantAndAnotherProjectsItemIsNotFound() async throws {
        let f = try BridgeFixture.make()
        let watches = PRWatchStore(f.db)
        let (ours, itemId) = try watch(f, number: 12, in: f.project.id)
        let (theirs, theirItemId) = try watch(f, number: 13, in: try f.otherProject().id)

        let result = try await f.call("dismiss_pr_item", [
            "number": .number(12), "item_id": .number(Double(itemId)), "reason": .string("Edited with gh pr edit."),
        ])

        XCTAssertTrue(result.text.contains("pending"), result.text)
        let approval = try XCTUnwrap(f.approvals.pending(projectId: f.project.id).first)
        XCTAssertEqual(approval.kind, .prItemDismissal)
        XCTAssertEqual(try watches.items(watchId: ours.id).map(\.state), [.open])

        try f.board.resolveApproval(approval.id, approved: true, by: "human")
        try f.board.applyItemDismissal(approval)
        let dismissed = try XCTUnwrap(watches.items(watchId: ours.id).first)
        XCTAssertEqual(dismissed.state, .dismissed)
        XCTAssertEqual(dismissed.dismissReason, "Edited with gh pr edit.")

        await XCTAssertToolError(
            try await f.call("dismiss_pr_item", [
                "number": .number(12), "item_id": .number(Double(theirItemId)), "reason": .string("Mine now."),
            ]),
            containing: "not found"
        )
        await XCTAssertToolError(
            try await f.call("dismiss_pr_item", [
                "watch_id": .string(theirs.id), "item_id": .number(Double(theirItemId)), "reason": .string("Mine now."),
            ]),
            containing: "not found"
        )
        XCTAssertEqual(try watches.items(watchId: theirs.id).map(\.state), [.open])
        XCTAssertEqual(try f.approvals.pending(projectId: f.project.id), [])
    }
}
