import Foundation
import XCTest
@testable import AgentBoardCore

private func agent(
    _ id: String, _ name: String, role: String = "frontend", enabled: Bool = true, created: Int64 = 1
) -> RosterAgent {
    RosterAgent(
        id: id, name: name, role: role, systemPrompt: "prompt", model: nil, toolScope: [],
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
