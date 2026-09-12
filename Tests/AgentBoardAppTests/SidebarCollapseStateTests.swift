import Foundation
import XCTest
@testable import AgentBoard

final class SidebarCollapseStateTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)
        super.tearDown()
    }

    func testRoundTripsThroughUserDefaults() {
        SidebarCollapseState.save(["w-work", "w-personal"])
        XCTAssertEqual(SidebarCollapseState.load(), ["w-personal", "w-work"])
    }

    func testLoadsEmptyWhenNothingSaved() {
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)
        XCTAssertEqual(SidebarCollapseState.load(), [])
    }

    func testSavingEmptyClearsEverything() {
        SidebarCollapseState.save(["w-personal"])
        SidebarCollapseState.save([])
        XCTAssertEqual(SidebarCollapseState.load(), [])
    }
}
