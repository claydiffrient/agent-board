import XCTest
@testable import AgentBoardCore

final class ModelCatalogTests: XCTestCase {
    func testEachFamilyAliasResolvesToItsNewestModel() {
        XCTAssertEqual(ModelCatalog.resolve(alias: "fable"), "claude-fable-5-2")
        XCTAssertEqual(ModelCatalog.resolve(alias: "opus"), "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.resolve(alias: "sonnet"), "claude-sonnet-5-5")
        XCTAssertEqual(ModelCatalog.resolve(alias: "haiku"), "claude-haiku-5-5")
    }
}
