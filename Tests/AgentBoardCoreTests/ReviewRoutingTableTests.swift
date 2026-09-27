import Foundation
import XCTest
@testable import AgentBoardCore

/// SPEC §4: under `agent` review a task's type picks its row in the project's routing table.
final class ReviewRoutingTableTests: XCTestCase {
    private var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture.make()
    }

    @discardableResult
    private func agent(_ name: String, role: String) throws -> RosterAgent {
        let agent = try RosterStore(f.db).create(name: name, role: role, systemPrompt: "You review.")
        try RosterStore(f.db).enable(agentId: agent.id, forProject: f.project.id)
        return agent
    }

    private func setSettings(_ edit: (inout ProjectSettings) -> Void) throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        edit(&settings)
        try f.projects.updateSettings(f.project.id, settings)
    }

    private func task(_ type: TaskType?, origin: TaskOrigin = .human, epicId: String? = nil) throws -> BoardTask {
        try f.tasks.create(
            projectId: f.project.id, title: "work", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: origin, epicId: epicId, type: type
        )
    }

    private func routing(_ task: BoardTask) throws -> ReviewRouting {
        try f.db.writer.read { try ReviewPolicy.routing($0, task: task) }
    }

    func testOldSettingsWithAndWithoutReviewAgentRouteAsBefore() throws {
        let rowan = try agent("Rowan", role: "reviewer")
        let roscoe = try agent("Roscoe", role: "go")
        let cases: [(String, RosterAgent)] = [
            (#"{"reviewLevel":"agent","reviewAgent":{"id":"\#(roscoe.id)","name":"Roscoe"}}"#, roscoe),
            (#"{"reviewLevel":"agent"}"#, rowan),
        ]
        for (json, expected) in cases {
            try f.db.writer.write { db in
                try db.execute(sql: "UPDATE project SET settings_json = ? WHERE id = ?", arguments: [json, f.project.id])
            }
            for type in [nil, TaskType.plan] {
                XCTAssertEqual(
                    try routing(task(type)), .agentReview(agentId: expected.id, agentName: expected.name), json
                )
            }
            let reencoded = try XCTUnwrap(f.projects.get(f.project.id)).settings.encoded()
            XCTAssertFalse(reencoded.contains("reviewAgent"), reencoded)
            XCTAssertEqual(ProjectSettings.decode(reencoded), ProjectSettings.decode(json))
        }
    }

    func testEachRowValueRoutesItsTypeAndEverythingElseUsesDefault() throws {
        let rowan = try agent("Rowan", role: "reviewer")
        let roscoe = try agent("Roscoe", role: "go")
        let reese = try agent("Reese", role: "writer")
        try setSettings {
            $0.reviewLevel = .agent
            $0.reviewRouting = ReviewRoutingTable(
                defaultAssignee: .named(ReviewAgentChoice(id: roscoe.id, name: roscoe.name)),
                typeAssignees: [
                    .docs: .named(ReviewAgentChoice(id: reese.id, name: reese.name)),
                    .code: .anyReviewer,
                    .review: .person,
                    .plan: .acceptWithoutReview,
                ]
            )
        }

        XCTAssertEqual(try routing(task(.docs)), .agentReview(agentId: reese.id, agentName: "Reese"))
        XCTAssertEqual(try routing(task(.code)), .agentReview(agentId: rowan.id, agentName: "Rowan"))
        XCTAssertEqual(try routing(task(.review)), .humanReview(reason: nil))
        XCTAssertEqual(try routing(task(.plan)), .autoAccept)
        XCTAssertEqual(try routing(task(.tests)), .agentReview(agentId: roscoe.id, agentName: "Roscoe"))
        XCTAssertEqual(try routing(task(nil)), .agentReview(agentId: roscoe.id, agentName: "Roscoe"))
    }

    func testTheTableIsIgnoredOutsideAgentReviewAndYieldsToTheIntegrationGate() throws {
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Epic", goal: nil)
        let everyRow: (ReviewAssignee) -> ReviewRoutingTable = { assignee in
            ReviewRoutingTable(
                defaultAssignee: assignee,
                typeAssignees: Dictionary(uniqueKeysWithValues: TaskType.allCases.map { ($0, assignee) })
            )
        }
        let cases: [(ReviewLevel, ReviewAssignee, ReviewRouting)] = [
            (.task, .acceptWithoutReview, .humanReview(reason: nil)),
            (.none, .person, .autoAccept),
            (.epic, .person, .autoAccept),
        ]
        for (level, assignee, expected) in cases {
            try setSettings {
                $0.reviewLevel = level
                $0.reviewRouting = everyRow(assignee)
            }
            XCTAssertEqual(try routing(task(.plan, epicId: epic.id)), expected, "level \(level)")
        }

        try setSettings {
            $0.reviewLevel = .agent
            $0.reviewRouting = everyRow(.acceptWithoutReview)
        }
        XCTAssertEqual(
            try routing(task(.plan, origin: .integration, epicId: epic.id)), .humanReview(reason: nil)
        )
    }
}
