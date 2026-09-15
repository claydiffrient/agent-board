import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// What a banner click does to a mounted window. `MainWindow.select` is the only caller of
/// `WorkerSupervising.focusChanged`, so a recorded focus is evidence the route went through the
/// same funnel the sidebar's `List(selection:)` binding uses — which is what starts the project's
/// orchestrator.
///
/// What this cannot show: the banner, the click, or the screen the detail pane ends up drawing.
/// Notification Center is unreachable under `xctest` and nobody can read the rendered segment.
@MainActor
final class NotificationRoutingMountTests: XCTestCase {
    @MainActor
    private final class Mount {
        let window: NSWindow
        let host: NSView

        init(db: AppDatabase, supervisor: StubSupervisor, router: NotificationRouter) {
            host = NSHostingView(
                rootView: MainWindow()
                    .environment(AppEnvironment(db: db, supervisor: supervisor, router: router))
            )
            NSApplication.shared.setActivationPolicy(.accessory)
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 700),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            window.orderBack(nil)
        }

        func close() { window.orderOut(nil) }

        func settle(turns: Int = 80) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }
    }

    private func register(_ db: AppDatabase, _ name: String) throws -> Project {
        try ProjectStore(db).register(
            name: name, repoPath: "/tmp/route-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/route-worktrees", memoryDir: nil
        )
    }

    func testARoutedBannerSelectsItsProjectTheWayTheSidebarDoes() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")
        let beta = try register(db, "Beta")
        SidebarCollapseState.save([])

        let supervisor = StubSupervisor()
        let router = NotificationRouter()
        let mount = Mount(db: db, supervisor: supervisor, router: router)
        defer { mount.close() }
        mount.settle()
        XCTAssertEqual(supervisor.focusedProjects, [], "nothing is selected before the click")

        router.open(NotificationRoute(projectId: beta.id, subject: .approvals))
        mount.settle(turns: 40)

        XCTAssertEqual(
            supervisor.focusedProjects.last, beta.id,
            "the route must select its project through MainWindow.select, not around it"
        )
    }

    /// A banner for a project that has since been removed must not leave the sidebar pointing at a
    /// row that is not there.
    func testARouteToAnUnknownProjectSelectsNothing() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")
        SidebarCollapseState.save([])

        let supervisor = StubSupervisor()
        let router = NotificationRouter()
        let mount = Mount(db: db, supervisor: supervisor, router: router)
        defer { mount.close() }
        mount.settle()

        router.open(NotificationRoute(projectId: "p-deleted", subject: .approvals))
        mount.settle(turns: 40)

        XCTAssertEqual(supervisor.focusedProjects, [], "a route to a missing project must be dropped")
    }
}
