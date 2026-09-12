import Foundation
import XCTest
@testable import AgentBoardCore

final class EpicLaneOrderTests: XCTestCase {
    private func epic(_ id: String, _ state: EpicState, createdAt: Int64) -> Epic {
        Epic(
            id: id, projectId: "p", title: id, goal: nil, branch: "epic/\(id)",
            state: state, createdAt: createdAt
        )
    }

    func testStatePrecedenceBeatsCreationDate() {
        let epics = [
            epic("oldest-done", .done, createdAt: 1),
            epic("newest-planning", .planning, createdAt: 400),
            epic("integrating", .integrating, createdAt: 300),
            epic("active", .active, createdAt: 2),
        ]
        XCTAssertEqual(
            EpicLaneOrder.sorted(epics).map(\.id),
            ["active", "newest-planning", "integrating", "oldest-done"]
        )
    }

    func testMostRecentFirstWithinAState() {
        let epics = [
            epic("a", .active, createdAt: 10),
            epic("c", .active, createdAt: 30),
            epic("b", .active, createdAt: 20),
        ]
        XCTAssertEqual(EpicLaneOrder.sorted(epics).map(\.id), ["c", "b", "a"])
    }

    func testAbandonedSinksBelowDone() {
        let epics = [
            epic("abandoned", .abandoned, createdAt: 99),
            epic("done", .done, createdAt: 1),
        ]
        XCTAssertEqual(EpicLaneOrder.sorted(epics).map(\.id), ["done", "abandoned"])
    }

    func testSameStateAndTimestampOrdersStably() {
        let epics = [epic("z", .active, createdAt: 5), epic("a", .active, createdAt: 5)]
        XCTAssertEqual(EpicLaneOrder.sorted(epics).map(\.id), ["a", "z"])
    }

    func testNoEpicLaneIsAlwaysFirst() {
        let epics = [epic("active", .active, createdAt: 1), epic("done", .done, createdAt: 900)]
        XCTAssertEqual(EpicLaneOrder.laneOrder(epics), ["no-epic", "active", "done"])
        XCTAssertEqual(EpicLaneOrder.laneOrder([]), ["no-epic"])
    }

    /// An epic with no tasks at all still takes its place by state — the archive flow leaves done
    /// epics empty, and an empty lane must not fall out of the ordering.
    func testEpicWithNoTasksStillOrdersByState() {
        let epics = [
            epic("empty-done", .done, createdAt: 500),
            epic("empty-active", .active, createdAt: 1),
        ]
        XCTAssertEqual(EpicLaneOrder.laneOrder(epics), ["no-epic", "empty-active", "empty-done"])
    }
}

final class EpicLaneCollapseTests: XCTestCase {
    func testDoneDefaultsCollapsed() {
        XCTAssertTrue(EpicLaneCollapse.isCollapsed(state: .done, userChoice: nil))
    }

    func testEveryOtherStateDefaultsExpanded() {
        for state in EpicState.allCases where state != .done {
            XCTAssertFalse(
                EpicLaneCollapse.isCollapsed(state: state, userChoice: nil),
                "\(state) should default expanded"
            )
        }
    }

    func testUserChoiceBeatsTheDefaultInBothDirections() {
        XCTAssertFalse(EpicLaneCollapse.isCollapsed(state: .done, userChoice: false))
        XCTAssertTrue(EpicLaneCollapse.isCollapsed(state: .active, userChoice: true))
    }
}

final class EpicCollapseStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "EpicCollapseStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func epic(_ id: String, _ state: EpicState) -> Epic {
        Epic(id: id, projectId: "p", title: id, goal: nil, branch: "b", state: state, createdAt: 1)
    }

    func testUnsetEpicFallsBackToTheStateDefault() {
        let store = EpicCollapseStore(defaults: defaults)
        XCTAssertNil(store.userChoice(epicId: "fresh"))
        XCTAssertFalse(store.isCollapsed(epic("fresh", .active)))
        XCTAssertTrue(store.isCollapsed(epic("shipped", .done)))
    }

    func testExpandingADoneEpicSticks() {
        let store = EpicCollapseStore(defaults: defaults)
        store.setUserChoice(false, epicId: "shipped")
        XCTAssertFalse(store.isCollapsed(epic("shipped", .done)))
        XCTAssertEqual(store.userChoice(epicId: "shipped"), false)
    }

    func testCollapsingAnActiveEpicSticks() {
        let store = EpicCollapseStore(defaults: defaults)
        store.setUserChoice(true, epicId: "busy")
        XCTAssertTrue(store.isCollapsed(epic("busy", .active)))
    }

    func testClearingRestoresTheDefault() {
        let store = EpicCollapseStore(defaults: defaults)
        store.setUserChoice(false, epicId: "shipped")
        store.clearUserChoice(epicId: "shipped")
        XCTAssertNil(store.userChoice(epicId: "shipped"))
        XCTAssertTrue(store.isCollapsed(epic("shipped", .done)))
    }

    func testChoicesAreScopedPerEpicId() {
        let store = EpicCollapseStore(defaults: defaults)
        store.setUserChoice(true, epicId: "one")
        XCTAssertNil(store.userChoice(epicId: "two"))
    }
}
