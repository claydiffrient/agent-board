import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

/// SPEC §13.2: the author's ruling on an item outranks triage's verdict.
final class PRTriageRulingTests: XCTestCase {
    func testSetVerdictsAppliesARulingAcrossAResetAndRefusesAnyOtherVerdict() throws {
        let f = try Fixture.make()
        let store = PRWatchStore(f.db)
        let (watch, items) = try PRRulingFixtures.watch(f, threads: ["ASK", "NEW"])
        let (asked, untriaged) = (try XCTUnwrap(items[0].id), try XCTUnwrap(items[1].id))
        try PRRulingFixtures.ask(f, itemId: asked)
        try f.board.answerDecision(itemId: asked, choice: .option("Keep the name"))
        try store.upsert(
            projectId: f.project.id,
            snapshot: PRRulingFixtures.snapshot([
                PRRulingFixtures.thread("ASK", body: "Rename this, edited"), PRRulingFixtures.thread("NEW"),
            ]),
            now: 2_000
        )

        for wrong in [
            PRVerdictInput(
                itemId: asked, verdict: .alreadyDone, approach: "Done.", replyBody: "The old name is public API."
            ),
            PRVerdictInput(itemId: asked, verdict: .answer, approach: "Factual.", replyBody: "Renaming later."),
        ] {
            XCTAssertThrowsError(try store.setVerdicts([
                wrong, PRVerdictInput(itemId: untriaged, verdict: .answer, approach: "Factual.", replyBody: "Yes."),
            ], watchId: watch.id)) {
                let reason = ($0 as? PRVerdictRejection)?.reason ?? "\($0)"
                XCTAssertTrue(reason.contains("The old name is public API."), reason)
            }
        }
        XCTAssertEqual(try store.items(watchId: watch.id).map(\.verdict), [nil, nil])

        try store.setVerdicts([
            PRVerdictInput(
                itemId: asked, verdict: .answer, approach: "Same request.", replyBody: "The old name is public API."
            ),
        ], watchId: watch.id)
        let applied = try XCTUnwrap(store.items(watchId: watch.id).first)
        XCTAssertEqual(applied.verdict, .answer)
        XCTAssertEqual(applied.replyBody, "The old name is public API.")
        XCTAssertEqual(applied.approach, "Keep the name")
    }
}

enum PRRulingFixtures {
    static func watch(_ f: Fixture, threads: [String]) throws -> (PRWatch, [PRItem]) {
        let store = PRWatchStore(f.db)
        let watch = try store.upsert(
            projectId: f.project.id, snapshot: snapshot(threads.map { thread($0) }), now: 1_000
        )
        return (watch, try store.items(watchId: watch.id))
    }

    static func snapshot(_ items: [PRSnapshotItem]) -> PRSnapshot {
        PRSnapshot(
            repoOwner: "octo", repoName: "example", number: 7, url: "https://github.com/octo/example/pull/7",
            title: "Add a widget", headRef: "feature/widget", headOid: "abc123", baseRef: "main",
            reviewDecision: "REVIEW_REQUIRED", checksState: "SUCCESS", mergeable: "MERGEABLE", labels: [],
            items: items
        )
    }

    static func thread(_ id: String, body: String = "Rename this") -> PRSnapshotItem {
        PRSnapshotItem(
            githubNodeId: id, kind: .thread, author: "reviewer", body: body, path: "Sources/A.swift", line: 12,
            url: "https://github.com/octo/example/pull/7#discussion_\(id)", isResolved: false
        )
    }

    static func ask(_ f: Fixture, itemId: Int64) throws {
        let options = PRWatchStore.encodeOptions([
            PRDecisionOption(label: "Rename it everywhere", verdict: .fix),
            PRDecisionOption(label: "Keep the name", verdict: .answer, replyBody: "The old name is public API."),
        ])
        try f.db.writer.write { db in
            try db.execute(
                sql: """
                UPDATE pr_item SET verdict = 'decision', approach = 'Direction.', decision_question = 'Rename it?',
                decision_options_json = ? WHERE id = ?
                """,
                arguments: [options, itemId]
            )
        }
    }
}
