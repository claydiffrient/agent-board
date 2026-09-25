import AgentBoardCore
import GRDB
import XCTest

/// SPEC §10: the Coordinator page's Requests rows, built from the real ledger.
final class CoordinatorLedgerTests: XCTestCase {
    func testRowsCarryEachRequestsStateLatestReplyAndLinkedEpics() throws {
        let f = try Fixture.make()
        let requests = RequestStore(f.db)
        let epic = Epic(
            id: "epic-dns-0000", projectId: f.project.id, title: "DNS cutover", goal: nil,
            branch: EpicStore.branchPrefix + "dns", state: .active, createdAt: .nowMillis
        )
        try f.db.writer.write { db in try epic.insert(db) }

        let shipped = try id(requests.send(toProjectId: f.project.id, body: "Plan the DNS cutover.\nDetails in the plan.", planNoteId: "plan-dns"))
        try requests.reply(requestId: shipped, fromProjectId: f.project.id, state: .accepted, body: "On it", epicIds: [epic.id])
        try requests.reply(requestId: shipped, fromProjectId: f.project.id, state: .done, body: "Cut over at noon")
        let declined = try id(requests.send(toProjectId: f.project.id, body: "Rewrite the parser", planNoteId: nil))
        try requests.reply(requestId: declined, fromProjectId: f.project.id, state: .declined, body: "No capacity this week")
        let withdrawn = try id(requests.send(toProjectId: f.project.id, body: "Bump the SDK", planNoteId: nil))
        try requests.withdraw(requestId: withdrawn, reason: "Changed plans")
        let open = try id(requests.send(toProjectId: f.project.id, body: "Audit the logs", planNoteId: nil))

        let rows = Dictionary(uniqueKeysWithValues: try requests.ledgerRows().map { ($0.id, $0) })

        func row(_ id: Int64, _ summary: String, _ state: RequestState, reply: String?, epics: [CoordinatorLedgerRow.EpicLink] = []) -> CoordinatorLedgerRow {
            CoordinatorLedgerRow(
                id: id, projectId: f.project.id, projectName: "Demo", summary: summary, state: state,
                latestReply: reply, epics: epics
            )
        }
        XCTAssertEqual(rows[shipped], row(
            shipped, "Plan the DNS cutover.", .done, reply: "Cut over at noon",
            epics: [.init(id: epic.id, title: "DNS cutover")]
        ))
        XCTAssertEqual(rows[declined], row(declined, "Rewrite the parser", .declined, reply: "No capacity this week"))
        XCTAssertEqual(rows[withdrawn], row(withdrawn, "Bump the SDK", .withdrawn, reply: nil), "a withdrawal is not a reply")
        XCTAssertEqual(rows[open], row(open, "Audit the logs", .sent, reply: nil))
        XCTAssertEqual(rows.count, 4)
    }

    private func id(_ sent: (request: CoordinatorRequest, report: Report)) throws -> Int64 {
        try XCTUnwrap(sent.request.id)
    }
}
