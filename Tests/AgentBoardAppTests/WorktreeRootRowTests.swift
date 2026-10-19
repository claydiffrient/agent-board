import AgentBoardCore
import XCTest
@testable import AgentBoard

final class WorktreeRootRowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/ada", isDirectory: true)

    func testChosenAndDefaultRootsAreStoredAsStandardizedAbsolutePaths() {
        let chosen = URL(fileURLWithPath: "/Users/ada/work/../roots/", isDirectory: true)
        XCTAssertEqual(WorktreeRootRow.storedPath(chosen), "/Users/ada/roots")

        XCTAssertEqual(
            WorktreeRootRow.defaultPath(projectId: "p1", environment: [:], home: home),
            "/Users/ada/.agentboard/worktrees/p1"
        )

        let spaced = WorktreeRootRow.storedPath(URL(fileURLWithPath: "/Users/ada/My Roots", isDirectory: true))
        XCTAssertEqual(spaced, "/Users/ada/My Roots")
        XCTAssertThrowsError(try WorktreeRootRule.validate(spaced)) {
            XCTAssertEqual($0 as? WorktreeRootError, .containsSpace(spaced))
        }
    }

    func testOnlyThePathUnderHomeIsAbbreviated() {
        XCTAssertEqual(WorktreeRootRow.displayPath("/Users/ada/.agentboard/worktrees/p1", home: home), "~/.agentboard/worktrees/p1")
        XCTAssertEqual(WorktreeRootRow.displayPath("/Users/ada", home: home), "~")
        XCTAssertEqual(WorktreeRootRow.displayPath("/Users/adam/roots", home: home), "/Users/adam/roots")
        XCTAssertEqual(WorktreeRootRow.displayPath("/tmp/roots", home: home), "/tmp/roots")
    }

    func testThePanelOpensAtTheNearestExistingFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-root-row-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(WorktreeRootRow.panelStart(for: base.path).path, base.standardizedFileURL.path)
        XCTAssertEqual(
            WorktreeRootRow.panelStart(for: base.appendingPathComponent("not/yet/made").path).path,
            base.standardizedFileURL.path
        )
        XCTAssertEqual(WorktreeRootRow.panelStart(for: "~/not-there-\(UUID().uuidString)", home: base).path,
                       base.standardizedFileURL.path)
    }
}
