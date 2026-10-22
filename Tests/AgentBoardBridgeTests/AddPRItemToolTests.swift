import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// SPEC §6 and §13.1: `add_pr_item` feeds a verification failure back into follow-through.
final class AddPRItemToolTests: XCTestCase {
    private var f: BridgeFixture!
    private var watches: PRWatchStore!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        watches = PRWatchStore(f.db)
    }

    private func snapshot(_ number: Int) -> PRSnapshot {
        PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Change \(number)",
            headRef: "feature-\(number)", headOid: String(repeating: "b", count: 40), baseRef: "main"
        )
    }

    private func watch(_ number: Int, in state: PRWatchState) throws -> PRWatch {
        let watch = try watches.upsert(projectId: f.project.id, snapshot: snapshot(number))
        try watches.setState(state, watchId: watch.id)
        return watch
    }

    func testAReadyPRGetsTheItemAndGoesToSettlingAndTheNextPollKeepsIt() async throws {
        let pr = try watch(1, in: .readyToVerify)

        _ = try await f.call("add_pr_item", [
            "pr_url": .string(pr.url), "body": .string("Saving the form drops the second field."),
        ])

        let items = try watches.items(watchId: pr.id)
        XCTAssertEqual(items.map(\.kind), [.verifyFailure])
        XCTAssertEqual(items.map(\.state), [.open])
        XCTAssertNil(items.first?.verdict)
        XCTAssertEqual(try watches.get(pr.id)?.state, .settling)

        try watches.upsert(projectId: f.project.id, snapshot: snapshot(1))
        XCTAssertEqual(try watches.items(watchId: pr.id).map(\.state), [.open])
    }

    func testAVerifiedPRGetsADecisionAndNoRound() async throws {
        let pr = try watch(2, in: .verified)

        _ = try await f.call("add_pr_item", [
            "pr_url": .string(pr.url), "body": .string("The empty state never shows."),
        ])

        let items = try watches.items(watchId: pr.id)
        XCTAssertEqual(items.map(\.kind), [.verifyFailure])
        XCTAssertEqual(items.map(\.isOpenDecision), [true])
        let after = try XCTUnwrap(try watches.get(pr.id))
        XCTAssertEqual(after.state, .verified)
        XCTAssertEqual(after.round, 0)
        XCTAssertNil(try watches.currentRound(watchId: pr.id))
    }

    func testAnUnknownPRURLIsRefused() async throws {
        let pr = try watch(3, in: .readyToVerify)

        await XCTAssertToolError(
            try await self.f.call("add_pr_item", [
                "pr_url": .string("https://github.com/example-org/app/pull/99"), "body": .string("Broken."),
            ]),
            containing: "not an open pull request this project watches"
        )
        XCTAssertEqual(try watches.items(watchId: pr.id), [])
        XCTAssertEqual(try watches.get(pr.id)?.state, .readyToVerify)
    }
}
