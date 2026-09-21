import Foundation
import XCTest
@testable import AgentBoard

final class SidebarCollapseStateTests: XCTestCase {
    private var collapse = IsolatedCollapseState()

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        super.tearDown()
    }

    func testRoundTripsThroughUserDefaults() {
        collapse.state.save(["w-work", "w-personal"])
        XCTAssertEqual(collapse.state.load(), ["w-personal", "w-work"])
    }

    func testLoadsEmptyWhenNothingSaved() {
        XCTAssertEqual(collapse.state.load(), [])
    }

    func testSavingEmptyClearsEverything() {
        collapse.state.save(["w-personal"])
        collapse.state.save([])
        XCTAssertEqual(collapse.state.load(), [])
    }

    /// The isolation the rest of this target depends on: a store built on its own domain must not
    /// see, and must not write, the process-wide `UserDefaults.standard` key — which under `xctest`
    /// is `com.apple.dt.xctest.tool`, shared by every `swift test` running on the machine.
    func testAStoreOfItsOwnNeitherReadsNorWritesTheSharedDomain() {
        defer { UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key) }
        UserDefaults.standard.set(["w-from-another-process"], forKey: SidebarCollapseState.key)

        XCTAssertEqual(collapse.state.load(), [], "the shared domain must not reach an isolated store")

        collapse.state.save(["w-mine"])
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: SidebarCollapseState.key),
            ["w-from-another-process"],
            "an isolated store must not write back into the shared domain"
        )
    }

    /// Two stores are two domains. Without this, `IsolatedCollapseState` could hand every test the
    /// same suite name and the isolation would be a no-op that nothing noticed.
    func testTwoIsolatedStoresDoNotShareAValue() {
        let other = IsolatedCollapseState()
        defer { other.remove() }

        collapse.state.save(["w-mine"])
        other.state.save(["w-theirs"])

        XCTAssertEqual(collapse.state.load(), ["w-mine"])
        XCTAssertEqual(other.state.load(), ["w-theirs"])
    }
}
