import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Mounts the roster surfaces offscreen through `NSHostingView`.
///
/// What this proves: `RosterView` renders a row per rostered agent whose switch shows that agent's
/// stored `enabled`, and `ProjectSettingsSheet` grows exactly one extra toggle per rostered agent,
/// set from that project's opt-in. What it cannot prove: anything about pixels or rendered strings
/// — SwiftUI draws text into backing layers and this machine has no display — and nothing about
/// clicking, because `performClick` does not drive a SwiftUI binding offscreen.
@MainActor
final class RosterScreenRenderTests: XCTestCase {
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

        func collect<V: NSView>(_ type: V.Type) -> [V] {
            var found: [V] = []
            func walk(_ view: NSView) {
                if let match = view as? V { found.append(match) }
                view.subviews.forEach(walk)
            }
            walk(host)
            return found
        }
    }

    private func mount(_ view: some View, width: CGFloat = 700, height: CGFloat = 1400) -> Mounted {
        let host = NSHostingView(rootView: view)
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        return Mounted(window: window, host: host)
    }

    private func board() throws -> (AppDatabase, Project) {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        return (db, project)
    }

    private func environment(_ db: AppDatabase) -> AppEnvironment {
        AppEnvironment(db: db, supervisor: RenderStubSupervisor(progress: [:]))
    }

    /// `NSSwitch.performClick` does not drive a SwiftUI binding offscreen — the store is unchanged
    /// after it — so this pins the direction that is observable here: each agent gets a switch and
    /// its state is the agent's stored `enabled`.
    func testRosterViewRendersASwitchPerAgentShowingItsStoredEnabledState() throws {
        let (db, _) = try board()
        let roster = RosterStore(db)
        try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try roster.create(name: "Bee", role: "reviewer", systemPrompt: "p", enabled: false)

        let mounted = mount(RosterView().environment(environment(db)))
        mounted.settle()

        let switches = mounted.collect(NSSwitch.self)
        XCTAssertEqual(switches.count, 2, "one enabled switch per rostered agent")
        XCTAssertEqual(switches.map(\.state), [.on, .off], "enabled sorts above disabled")
    }

    /// The same roster with the enabled flag inverted must render inverted, which is what rules out
    /// a view that draws two switches regardless of what the store holds.
    func testTheSwitchesFollowTheStoreRatherThanAFixedLayout() throws {
        let (db, _) = try board()
        let roster = RosterStore(db)
        try roster.create(name: "Ada", role: "frontend", systemPrompt: "p", enabled: false)
        try roster.create(name: "Bee", role: "reviewer", systemPrompt: "p")

        let mounted = mount(RosterView().environment(environment(db)))
        mounted.settle()

        XCTAssertEqual(
            mounted.collect(NSSwitch.self).map(\.state), [.on, .off],
            "Bee is the enabled one now, so it sorts first and carries the on switch"
        )
    }

    func testAnEmptyRosterRendersNoSwitches() throws {
        let (db, _) = try board()
        let mounted = mount(RosterView().environment(environment(db)))
        mounted.settle()

        XCTAssertTrue(mounted.collect(NSSwitch.self).isEmpty)
    }

    /// The reachability question the acceptance criteria ask: does selecting Roster in the sidebar
    /// put `RosterView` on screen? Mounting `MainWindow` itself would need the whole app
    /// environment, so this pins the routing decision `MainWindow.body` makes.
    func testTheSidebarCarriesARosterSelectionThatIsNotAProject() {
        XCTAssertNil(SidebarSelection.roster.projectId)
        XCTAssertNotEqual(SidebarSelection.roster, SidebarSelection.atAGlance)
        XCTAssertNotEqual(SidebarSelection.roster, SidebarSelection.project("p-1"))
    }

    private func sheetSwitches(_ db: AppDatabase, _ project: Project) -> [NSControl.StateValue] {
        let mounted = mount(
            ProjectSettingsSheet(project: project, workspaces: [], initialTab: .agents, onDeleted: {})
                .environment(environment(db))
        )
        mounted.settle()
        return mounted.collect(NSSwitch.self).map(\.state)
    }

    /// The sheet carries its own toggles (autonomy, one per notification category), so a count is
    /// only meaningful as a difference: two rostered agents must add exactly two switches, and the
    /// one the project opted into must be the one that is on.
    func testTheProjectSettingsSheetGrowsOneTogglePerRosteredAgentSetFromTheProjectsOptIn() throws {
        let (db, project) = try board()
        let bare = sheetSwitches(db, project)

        let roster = RosterStore(db)
        let ada = try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try roster.create(name: "Bee", role: "reviewer", systemPrompt: "p")
        try roster.enable(agentId: ada.id, forProject: project.id)

        let withRoster = sheetSwitches(db, project)
        XCTAssertEqual(
            withRoster.count, bare.count + 2,
            "two rostered agents should add two toggles; bare \(bare.count), with roster \(withRoster.count)"
        )
        XCTAssertEqual(
            withRoster.filter { $0 == .off }.count, bare.filter { $0 == .off }.count + 1,
            "exactly one of the two new toggles — Bee, not opted in — should be off"
        )
        XCTAssertEqual(
            try roster.agents(forProject: project.id).map(\.name), ["Ada"],
            "the sheet must not have rewritten the project's selection just by rendering"
        )
    }

    /// A project that opted into nobody must show every agent's toggle off, which is what tells the
    /// opt-in apart from the agent's own roster-wide `enabled`.
    func testASecondProjectSeesTheSameRosterWithEveryToggleOff() throws {
        let (db, project) = try board()
        let other = try ProjectStore(db).register(
            name: "Other", repoPath: "/tmp/other-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/other-worktrees", memoryDir: nil
        )
        let roster = RosterStore(db)
        let ada = try roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try roster.enable(agentId: ada.id, forProject: project.id)

        let bareOther = sheetSwitches(db, other)
        XCTAssertEqual(try roster.agents(forProject: other.id).count, 0)
        XCTAssertEqual(
            bareOther.filter { $0 == .on }.count,
            sheetSwitches(db, project).filter { $0 == .on }.count - 1,
            "the other project should be short exactly the one agent this project opted into"
        )
    }
}
