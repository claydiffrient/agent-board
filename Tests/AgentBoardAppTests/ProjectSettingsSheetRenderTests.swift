import AgentBoardCore
import SwiftUI
import XCTest
@testable import AgentBoard

/// Confirms the project settings sheet seeds its worktree-strategy picker from the project's
/// stored strategy.
///
/// On macOS 27, in this offscreen/non-active session, a SwiftUI `Picker` no longer constructs an
/// `NSPopUpButton` at all — not renamed, not empty, just absent from the AppKit view tree, even
/// mounted through a real, on-screen, `makeKeyAndOrderFront`-ed window (see the headless UI
/// verification note). So the seeded value is read directly off the constructed
/// `ProjectSettingsSheet` through `Mirror`, rather than off a rendered control — no mounting at all.
///
/// `testEachTabMountsOnlyItsOwnPickers`, which used to pin how many pop-ups each tab rendered, is
/// gone: that count cannot be reproduced from source, because `.agents`' seven review-routing
/// pickers come from one `Picker(...)` call site (`routingRow`) invoked in a loop, not seven
/// distinct call sites — a textual count would just be a different, weaker invariant wearing the
/// old one's name. `ProjectSettingsTabTests` already pins that every section lands in exactly one
/// tab and that `content(for:)` is an exhaustive switch, which was this test's other half.
@MainActor
final class ProjectSettingsSheetRenderTests: XCTestCase {
    private func seededStrategy(_ strategy: WorktreeStrategy) throws -> WorktreeStrategy? {
        let db = try AppDatabase.inMemory()
        let projects = ProjectStore(db)
        var project = try projects.register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        var settings = project.settings
        settings.worktreeStrategy = strategy
        try projects.updateSettings(project.id, settings)
        project = try XCTUnwrap(projects.get(project.id))

        let sheet = ProjectSettingsSheet(project: project, workspaces: [], initialTab: .workflow, onDeleted: {})
        let seeded: ProjectSettings? = seededState(sheet, "_settings")
        return seeded?.worktreeStrategy
    }

    func testTheStrategyPickerRendersOnTheProjectsStoredStrategy() throws {
        for strategy in WorktreeStrategy.allCases {
            XCTAssertEqual(
                try seededStrategy(strategy), strategy,
                "the worktree-strategy picker's seeded state did not carry \(strategy.title)"
            )
        }
    }
}
