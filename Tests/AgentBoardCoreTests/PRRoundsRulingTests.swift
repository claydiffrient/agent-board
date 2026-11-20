import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

/// SPEC §13.4: the fixer's prompt reads the author's answer from their ruling, never from `approach`.
final class PRRoundsRulingTests: XCTestCase {
    func testAFixerPromptBuiltAfterANewReplyResetTheItemStillQuotesTheAuthor() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let (watch, items) = try PRRulingFixtures.watch(f, threads: ["ASK"])
        let id = try XCTUnwrap(items.first?.id)
        try PRRulingFixtures.ask(f, itemId: id)
        try f.board.answerDecision(itemId: id, choice: .option("Rename it everywhere"))

        try store.upsert(
            projectId: f.project.id,
            snapshot: PRRulingFixtures.snapshot([PRRulingFixtures.thread("ASK", body: "Rename this, and the docs.")]),
            now: 2_000
        )
        try store.setState(.settling, watchId: watch.id)
        XCTAssertNotNil(try store.beginTriageRound(watchId: watch.id))
        try f.db.writer.write { db in
            try db.execute(
                sql: "UPDATE pr_item SET verdict = 'fix', approach = 'Delete the alias.' WHERE id = ?", arguments: [id]
            )
        }
        XCTAssertEqual(try f.board.applyVerdicts(watchId: watch.id), .fixing)

        let body = try XCTUnwrap(f.board.createFixRoundTask(watchId: watch.id, model: nil)?.body)
        XCTAssertTrue(
            body.contains("The pull request author's answer to \"Rename it?\":\nRename it everywhere"), body
        )
        XCTAssertFalse(body.contains("Delete the alias."), body)
    }
}
