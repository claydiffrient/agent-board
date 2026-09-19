import AgentBoardCore
import AppKit
import XCTest
@testable import AgentBoard

/// The sidebar a mount draws must come from the store the test handed it, and from nothing else.
///
/// `UserDefaults.standard` under `xctest` resolves to `com.apple.dt.xctest.tool`, one preferences
/// domain shared by every `swift test` process on the machine. Several agent-board workers run the
/// suite at once here, so while `MainWindow` read that domain a second run could clear or overwrite
/// `sidebar.collapsedWorkspaces` between a test's `save` and the mount's `load`. Measured: four
/// concurrent `xctest` processes writing that key and reading it straight back lost 225-303 of 400
/// round trips to each other, and three of four concurrent runs of `SidebarAttentionLiveTests` then
/// failed — the collapsed section rendered expanded, drawing a row that should have been hidden,
/// which is what turned a 14-point badge diff into a whole-sidebar one.
///
/// These two mounts stage that interference deliberately, in one process, so a regression to the
/// shared domain fails here and by itself rather than intermittently somewhere else.
@MainActor
final class SidebarCollapseIsolationTests: XCTestCase {
    private var collapse = IsolatedCollapseState()

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)
        super.tearDown()
    }

    private static let sidebar = 0..<230

    /// One workspace holding one project, so the sidebar draws two rows expanded and one collapsed.
    private func board() throws -> (AppDatabase, String) {
        let db = try AppDatabase.inMemory()
        let workspace = try WorkspaceStore(db).create(name: "Alpha")
        let project = try ProjectStore(db).register(
            name: "Hidden", repoPath: "/tmp/collapse-isolation-\(UUID().uuidString)",
            baseBranch: "main", worktreeRoot: "/tmp/collapse-isolation-worktrees", memoryDir: nil
        )
        try WorkspaceStore(db).assign(projectId: project.id, workspaceId: workspace.id)
        return (db, workspace.id)
    }

    private func mount(_ db: AppDatabase) throws -> OffscreenMount {
        let mounted = OffscreenMount(
            MainWindow(collapseState: collapse.state).environment(renderEnvironment(db: db))
        )
        _ = try mounted.capture(points: Self.sidebar)
        return mounted
    }

    /// What a second `swift test` process does in `tearDown`.
    func testAForeignClearOfTheSharedKeyCannotExpandACollapsedSection() throws {
        let (db, workspaceId) = try board()
        collapse.state.save([workspaceId])
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)

        let mounted = try mount(db)
        defer { mounted.close() }
        XCTAssertEqual(
            mounted.viewCount(ofClassNamed: "ListTableCellView"), 1,
            "only the pinned At a Glance row may be drawn: the section this test collapsed stayed collapsed"
        )
    }

    /// And the other direction, which would hide a row a test is about to assert about.
    func testAForeignWriteToTheSharedKeyCannotCollapseAnExpandedSection() throws {
        let (db, workspaceId) = try board()
        collapse.state.save([])
        UserDefaults.standard.set([workspaceId], forKey: SidebarCollapseState.key)

        let mounted = try mount(db)
        defer { mounted.close() }
        XCTAssertEqual(
            mounted.viewCount(ofClassNamed: "ListTableCellView"), 2,
            "At a Glance and the project row: the section this test left expanded stayed expanded"
        )
    }
}
