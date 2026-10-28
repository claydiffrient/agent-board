import AgentBoardCore
import XCTest
@testable import AgentBoard

@MainActor
final class RosterAgentSheetSaveTests: XCTestCase {
    func testPluginDirsSaveOnePerLineOnAddAndOnEdit() throws {
        let store = RosterStore(try AppDatabase.inMemory())

        try RosterAgentSheet.save(
            .blank, name: "Ada", role: "checks", systemPrompt: "Check.", model: nil,
            pluginDirs: "  /opt/plugins/checks \n\n~/plugins/follow-up\n", enabled: true, to: store
        )
        let added = try XCTUnwrap(store.list().first)
        XCTAssertEqual(added.pluginDirs, ["/opt/plugins/checks", "~/plugins/follow-up"])

        try RosterAgentSheet.save(
            .editing(added), name: "Ada", role: "checks", systemPrompt: "Check.", model: nil,
            pluginDirs: "/opt/plugins/other", enabled: true, to: store
        )
        XCTAssertEqual(try store.get(added.id)?.pluginDirs, ["/opt/plugins/other"])
    }
}
