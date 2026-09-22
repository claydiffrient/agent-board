import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

private func agent(
    _ id: String, _ name: String, role: String = "frontend", enabled: Bool = true, created: Int64 = 1
) -> RosterAgent {
    RosterAgent(
        id: id, name: name, role: role, systemPrompt: "prompt", model: nil, disallowedTools: [],
        enabled: enabled, createdAt: created, updatedAt: created
    )
}

final class RosterListingOrderTests: XCTestCase {
    func testEnabledAgentsSortAboveDisabledOnes() {
        let ordered = RosterListing.ordered([
            agent("1", "Ada", enabled: false),
            agent("2", "Zoe", enabled: true),
        ])
        XCTAssertEqual(ordered.map(\.id), ["2", "1"])
    }

    func testNameOrderIgnoresCase() {
        let ordered = RosterListing.ordered([
            agent("1", "bravo"),
            agent("2", "Alpha"),
            agent("3", "Charlie"),
        ])
        XCTAssertEqual(ordered.map(\.name), ["Alpha", "bravo", "Charlie"])
    }

    func testIdBreaksTiesSoOrderIsStable() {
        let ordered = RosterListing.ordered([
            agent("b", "Same"),
            agent("a", "same"),
        ])
        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
    }

    func testDisabledAgentsAreStillSortedAmongThemselves() {
        let ordered = RosterListing.ordered([
            agent("1", "Zed", enabled: false),
            agent("2", "Mid", enabled: true),
            agent("3", "Abe", enabled: false),
        ])
        XCTAssertEqual(ordered.map(\.name), ["Mid", "Abe", "Zed"])
    }

    func testOrderingAnEmptyRosterIsEmpty() {
        XCTAssertTrue(RosterListing.ordered([]).isEmpty)
    }

    func testEntriesAttachAssignmentsAndKeepDisplayOrder() {
        let entries = RosterListing.entries(
            agents: [agent("1", "Zoe"), agent("2", "Ada")],
            assignments: [RosterAssignment(agentId: "1", taskId: "t9", taskTitle: "Fix the picker")]
        )
        XCTAssertEqual(entries.map(\.id), ["2", "1"])
        XCTAssertFalse(entries[0].isWorking)
        XCTAssertEqual(entries[1].assignment?.taskTitle, "Fix the picker")
    }

    func testAnAssignmentForAnAgentNoLongerInTheRosterIsIgnored() {
        let entries = RosterListing.entries(
            agents: [agent("1", "Ada")],
            assignments: [RosterAssignment(agentId: "gone", taskId: "t1", taskTitle: "Orphan")]
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isWorking)
    }
}

final class RosterProjectPartitionTests: XCTestCase {
    private let roster = [
        agent("1", "Zoe"),
        agent("2", "Ada"),
        agent("3", "Mo", enabled: false),
    ]

    func testSelectedAndAvailableSplitOnMembership() {
        let split = RosterListing.partition(roster: roster, selectedIds: ["2"])
        XCTAssertEqual(split.selected.map(\.name), ["Ada"])
        XCTAssertEqual(split.available.map(\.name), ["Zoe", "Mo"])
    }

    func testBothHalvesKeepDisplayOrder() {
        let split = RosterListing.partition(roster: roster, selectedIds: ["1", "2", "3"])
        XCTAssertEqual(split.selected.map(\.name), ["Ada", "Zoe", "Mo"])
        XCTAssertTrue(split.available.isEmpty)
    }

    func testSelectingNobodyLeavesTheWholeRosterAvailable() {
        let split = RosterListing.partition(roster: roster, selectedIds: [])
        XCTAssertTrue(split.selected.isEmpty)
        XCTAssertEqual(split.available.count, 3)
    }

    func testAStaleSelectionForAMissingAgentIsDropped() {
        let split = RosterListing.partition(roster: roster, selectedIds: ["2", "deleted"])
        XCTAssertEqual(split.selected.map(\.id), ["2"])
        XCTAssertEqual(split.selected.count + split.available.count, roster.count)
    }

    func testADisabledAgentTheProjectPickedStaysSelected() {
        let split = RosterListing.partition(roster: roster, selectedIds: ["3"])
        XCTAssertEqual(split.selected.map(\.name), ["Mo"])
    }

    func testTheProjectSelectionNeverMutatesTheRoster() {
        _ = RosterListing.partition(roster: roster, selectedIds: ["1"])
        XCTAssertEqual(roster.map(\.id), ["1", "2", "3"])
    }
}

final class RosterDeleteDecisionTests: XCTestCase {
    func testAnIdleAgentCanBeDeleted() {
        let entry = RosterListEntry(agent: agent("1", "Ada"))
        XCTAssertEqual(RosterListing.deleteDecision(for: entry), .allowed)
    }

    func testAWorkingAgentIsRefusedAndNamesItsTask() {
        let entry = RosterListEntry(
            agent: agent("1", "Ada"),
            assignment: RosterAssignment(agentId: "1", taskId: "t4", taskTitle: "Port the roster tab")
        )
        XCTAssertEqual(
            RosterListing.deleteDecision(for: entry), .refused(taskTitle: "Port the roster tab")
        )
        XCTAssertFalse(RosterListing.deleteDecision(for: entry).isAllowed)
    }
}

/// The path the Roster screen and the project settings sheet actually take: `RosterStore.create`,
/// then `enable(agentId:forProject:)`, then read the project's selection back. Written against the
/// `disallowed_tools` deny-list schema the epic settled on, not the dropped `tool_scope` one.
final class RosterScreenStorePathTests: XCTestCase {
    func testCreatingAnAgentAndOptingAProjectInIsReadableBackThroughTheStore() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()

        let ada = try f.roster.create(
            name: "Ada", role: "frontend", systemPrompt: "You own the view layer.",
            model: "claude-opus-5", disallowedTools: ["Bash"]
        )
        XCTAssertEqual(try f.roster.list().map(\.id), [ada.id])

        // Created but opted into nothing: visible in the roster, usable by no project.
        XCTAssertTrue(try f.roster.agents(forProject: f.project.id).isEmpty)

        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [ada.id])
        XCTAssertEqual(try f.roster.usableAgents(forProject: f.project.id).map(\.id), [ada.id])
        XCTAssertTrue(try f.roster.agents(forProject: other.id).isEmpty)

        let stored = try XCTUnwrap(f.roster.get(ada.id))
        XCTAssertEqual(stored.disallowedTools, ["Bash"])
        XCTAssertEqual(stored.model, "claude-opus-5")

        // What the settings sheet renders from: the toggle is on for the one it opted into.
        let split = RosterListing.partition(
            roster: try f.roster.list(),
            selectedIds: try f.roster.agents(forProject: f.project.id).map(\.id)
        )
        XCTAssertEqual(split.selected.map(\.name), ["Ada"])
        XCTAssertTrue(split.available.isEmpty)
    }

    func testTheColumnIsTheDenyListOneAndTheDroppedNameIsGone() throws {
        let f = try Fixture.make()
        let columns = try f.db.reader.read { try $0.columns(in: "roster_agent").map(\.name) }
        XCTAssertTrue(columns.contains("disallowed_tools"))
        XCTAssertFalse(columns.contains("tool_scope"))
    }

    func testOptingBackOutLeavesTheAgentInTheRosterAndOtherProjectsAlone() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")

        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        try f.roster.enable(agentId: ada.id, forProject: other.id)
        try f.roster.disable(agentId: ada.id, forProject: f.project.id)

        XCTAssertTrue(try f.roster.agents(forProject: f.project.id).isEmpty)
        XCTAssertEqual(try f.roster.agents(forProject: other.id).map(\.id), [ada.id])
        XCTAssertEqual(try f.roster.list().map(\.id), [ada.id])
    }

    /// The delete guard is only honest if `assignments()` reports a live session and stops
    /// reporting it once the session ends.
    func testAssignmentsReportALiveRosteredSessionAndDropItWhenTheSessionEnds() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        let task = try f.task("ship search", column: .ready)

        XCTAssertTrue(try f.roster.assignments().isEmpty)

        var rostered = f.session("s1", state: .setup, taskId: task.id)
        rostered.rosterAgentId = ada.id
        try f.board.assign(taskId: task.id, session: rostered)

        let working = try f.roster.assignments()
        XCTAssertEqual(working.map(\.agentId), [ada.id])
        XCTAssertEqual(working.first?.taskTitle, "ship search")
        XCTAssertEqual(working.first?.projectName, f.project.name)
        XCTAssertEqual(
            RosterListing.deleteDecision(
                for: RosterListEntry(agent: ada, assignment: working.first)
            ),
            .refused(taskTitle: "ship search")
        )

        try f.sessions.setState("s1", .completed, endedAt: .nowMillis)
        XCTAssertTrue(try f.roster.assignments().isEmpty)
    }

    /// An anonymous worker carries no rostered identity, so it must not badge anyone.
    func testAnUnrosteredSessionProducesNoAssignment() throws {
        let f = try Fixture.make()
        let task = try f.task("ship search", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("s1", state: .setup, taskId: task.id))

        XCTAssertTrue(try f.roster.assignments().isEmpty)
    }
}
