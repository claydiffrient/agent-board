import XCTest
@testable import AgentBoardCore

final class TaskSelectionTests: XCTestCase {
    func testTogglingSelectsWhenNothingIsSelected() {
        XCTAssertEqual(TaskSelection.toggled(current: nil, tapped: "a"), "a")
    }

    func testTogglingTheSelectedCardDeselects() {
        XCTAssertEqual(TaskSelection.toggled(current: "a", tapped: "a"), nil)
    }

    func testTogglingAnotherCardMovesTheSelection() {
        XCTAssertEqual(TaskSelection.toggled(current: "a", tapped: "b"), "b")
    }

    func testTogglingIsItsOwnInverseForTheSameCard() {
        let closed = TaskSelection.toggled(current: "a", tapped: "a")
        XCTAssertEqual(TaskSelection.toggled(current: closed, tapped: "a"), "a")
    }

    func testReconcileKeepsASelectionThatStillExists() {
        XCTAssertEqual(TaskSelection.reconciled(current: "a", availableIds: ["b", "a"]), "a")
    }

    func testReconcileDropsASelectionThatLeftTheBoard() {
        XCTAssertEqual(TaskSelection.reconciled(current: "a", availableIds: ["b", "c"]), nil)
    }

    func testReconcileNeverOpensTheTray() {
        XCTAssertEqual(TaskSelection.reconciled(current: nil, availableIds: ["a", "b"]), nil)
        XCTAssertEqual(TaskSelection.reconciled(current: nil, availableIds: []), nil)
    }
}
