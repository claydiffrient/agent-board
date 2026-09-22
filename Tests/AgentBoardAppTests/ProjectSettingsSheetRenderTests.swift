import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Mounts the project settings sheet offscreen through `NSHostingView`.
///
/// What this proves: each tab's body evaluates and mounts only its own pickers, the strategy
/// picker is a real control in the rendered hierarchy, and the sheet starts on the project's
/// stored strategy.
///
/// What it cannot prove: anything about the pixels or the rendered strings. SwiftUI draws text into
/// backing layers rather than `NSTextField`s, and this machine has no display. Nobody has looked at
/// the section's wording, spacing or clipping.
@MainActor
final class ProjectSettingsSheetRenderTests: XCTestCase {
    private struct Mounted {
        let window: NSWindow
        let host: NSView

        func settle(turns: Int = 40) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }

        var popUpButtons: [NSPopUpButton] { Self.collect(host) }

        private static func collect(_ view: NSView) -> [NSPopUpButton] {
            var found: [NSPopUpButton] = []
            if let button = view as? NSPopUpButton { found.append(button) }
            for subview in view.subviews { found += collect(subview) }
            return found
        }
    }

    private func mount(strategy: WorktreeStrategy = .worktree, tab: ProjectSettingsTab) throws -> Mounted {
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

        let host = NSHostingView(
            rootView: ProjectSettingsSheet(project: project, workspaces: [], initialTab: tab, onDeleted: {})
                .environment(AppEnvironment(db: db, supervisor: RenderStubSupervisor(progress: [:])))
        )
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 780, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        return Mounted(window: window, host: host)
    }

    /// A SwiftUI `Picker` mounts as an `NSPopUpButton` whose `itemTitles` are empty offscreen —
    /// the menu is built on click. Its `title` is the selected option's label, which is what is
    /// readable here.
    func testTheStrategyPickerRendersOnTheProjectsStoredStrategy() throws {
        for strategy in WorktreeStrategy.allCases {
            let mounted = try mount(strategy: strategy, tab: .workflow)
            mounted.settle()

            let titles = mounted.popUpButtons.map(\.title)
            XCTAssertEqual(mounted.popUpButtons.count, 1, "rendered pop-ups: \(titles)")
            XCTAssertTrue(
                titles.contains(strategy.title),
                "no pop-up showed \(strategy.title); the sheet rendered \(titles)"
            )
        }
    }

    /// Only the selected tab is mounted, so pickers are counted per tab. The six were all on one
    /// page before the sheet was tabbed: Workspace, Archive, Default model, Review level, Worktree
    /// strategy, Mute.
    func testEachTabMountsOnlyItsOwnPickers() throws {
        let expected: [ProjectSettingsTab: Int] = [
            .general: 2, .agents: 2, .limits: 0, .workflow: 1, .notifications: 1, .advanced: 0,
        ]
        XCTAssertEqual(Set(expected.keys), Set(ProjectSettingsTab.allCases))
        XCTAssertEqual(expected.values.reduce(0, +), 6)

        for tab in ProjectSettingsTab.allCases {
            let mounted = try mount(tab: tab)
            mounted.settle()
            XCTAssertEqual(
                mounted.popUpButtons.count, expected[tab],
                "\(tab.title) rendered pop-ups \(mounted.popUpButtons.map(\.title))"
            )
        }
    }
}
