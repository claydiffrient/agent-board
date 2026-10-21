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
    private var collapse = IsolatedCollapseState()

    override func setUp() {
        super.setUp()
        collapse = IsolatedCollapseState()
    }

    override func tearDown() {
        collapse.remove()
        super.tearDown()
    }

    @MainActor
    private final class Mount {
        let window: NSWindow
        let host: NSView

        init(
            db: AppDatabase, supervisor: StubSupervisor, router: NotificationRouter,
            collapse: SidebarCollapseState
        ) {
            host = NSHostingView(
                rootView: MainWindow(collapseState: collapse)
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
        collapse.state.save([])

        let supervisor = StubSupervisor()
        let router = NotificationRouter()
        let mount = Mount(db: db, supervisor: supervisor, router: router, collapse: collapse.state)
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

    private func readyWatch(_ db: AppDatabase, _ project: Project, number: Int) throws -> PRWatch {
        let store = PRWatchStore(db)
        let watch = try store.upsert(projectId: project.id, snapshot: PRSnapshot(
            repoOwner: "example-org", repoName: "app", number: number,
            url: "https://github.com/example-org/app/pull/\(number)", title: "Change \(number)",
            headRef: "change-\(number)", headOid: "oid-\(number)", baseRef: "main"
        ))
        try store.setState(.readyToVerify, watchId: watch.id)
        return watch
    }

    /// Rows of the list in the detail pane, which sits right of the sidebar's list.
    private func detailRows(_ mount: Mount) -> Int? {
        var tables: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            view.subviews.forEach(walk)
        }
        walk(mount.host)
        return tables.first { $0.convert($0.bounds, to: nil).minX > MainWindowLayout.sidebarMinimumWidth }?
            .numberOfRows
    }

    private func routedPullRequestRows(to project: (Project, PRWatch), in db: AppDatabase) throws -> Int {
        let supervisor = StubSupervisor()
        let router = NotificationRouter()
        let mount = Mount(db: db, supervisor: supervisor, router: router, collapse: collapse.state)
        defer { mount.close() }
        mount.settle()

        router.open(NotificationRoute(projectId: project.0.id, subject: .pullRequest(project.1.id)))
        var rows: [Int?] = []
        while rows.count < 40, rows.count < 5 || rows.last == nil || Set(rows.suffix(5)).count > 1 {
            mount.settle(turns: 5)
            rows.append(detailRows(mount))
        }
        XCTAssertEqual(supervisor.focusedProjects.last, .some(nil), "the route must select Pull Requests through MainWindow.select")
        return try XCTUnwrap(rows.last ?? nil, "no list mounted in the detail pane")
    }

    /// SPEC §13.4: a Ready to verify banner opens Pull Requests filtered to its project. Alpha holds
    /// two ready PRs and Beta one, so each route's page is a row longer or shorter than the other's;
    /// an unfiltered page would list all three for both.
    func testAPullRequestRouteOpensPullRequestsFilteredToItsProject() throws {
        let db = try AppDatabase.inMemory()
        let alpha = try register(db, "Alpha")
        let beta = try register(db, "Beta")
        let alphaWatch = try readyWatch(db, alpha, number: 1)
        _ = try readyWatch(db, alpha, number: 2)
        let betaWatch = try readyWatch(db, beta, number: 3)
        collapse.state.save([])

        let alphaRows = try routedPullRequestRows(to: (alpha, alphaWatch), in: db)
        let betaRows = try routedPullRequestRows(to: (beta, betaWatch), in: db)

        XCTAssertEqual(alphaRows, betaRows + 1, "Alpha's page lists its two PRs and Beta's its one")
    }

    /// A banner for a project that has since been removed must not leave the sidebar pointing at a
    /// row that is not there.
    func testARouteToAnUnknownProjectSelectsNothing() throws {
        let db = try AppDatabase.inMemory()
        _ = try register(db, "Alpha")
        collapse.state.save([])

        let supervisor = StubSupervisor()
        let router = NotificationRouter()
        let mount = Mount(db: db, supervisor: supervisor, router: router, collapse: collapse.state)
        defer { mount.close() }
        mount.settle()

        router.open(NotificationRoute(projectId: "p-deleted", subject: .approvals))
        mount.settle(turns: 40)

        XCTAssertEqual(supervisor.focusedProjects, [], "a route to a missing project must be dropped")
    }
}
