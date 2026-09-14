import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// The At a Glance row is pinned outside every workspace section, so collapsing all of them leaves
/// it — and only it — on the list.
///
/// What this proves: with two workspaces holding four projects between them, an all-collapsed
/// sidebar renders two section headers and exactly one row, and expanding restores all five. The
/// row therefore cannot be inside a collapsible section.
///
/// What it cannot prove: that the row reads "At a Glance", or anything else about the pixels.
/// SwiftUI draws text into backing layers and `AXIsProcessTrusted()` is false here, so no string is
/// readable on this machine.
@MainActor
final class AtAGlanceRowRenderTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SidebarCollapseState.key)
        super.tearDown()
    }

    private struct Sidebar {
        let rows: Int
        let headers: Int
    }

    private func mountSidebar(collapsingEverything: Bool) throws -> Sidebar {
        let db = try AppDatabase.inMemory()
        let workspaces = WorkspaceStore(db)
        let alpha = try workspaces.create(name: "Alpha")
        let beta = try workspaces.create(name: "Beta")
        for (name, workspace) in [("one", alpha), ("two", alpha), ("three", beta), ("four", beta)] {
            let project = try ProjectStore(db).register(
                name: name, repoPath: "/tmp/glance-row-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/glance-row-worktrees", memoryDir: nil
            )
            try workspaces.assign(projectId: project.id, workspaceId: workspace.id)
        }
        // Read by `SidebarCollapseState.load()` when `MainWindow`'s state initializes, so it has to
        // be in place before the mount.
        SidebarCollapseState.save(collapsingEverything ? [alpha.id, beta.id] : [])

        let host = NSHostingView(
            rootView: MainWindow().environment(AppEnvironment(db: db, supervisor: RowStubSupervisor()))
        )
        NSApplication.shared.setActivationPolicy(.accessory)
        // Borderless and far offscreen: AppKit constrains a `.titled` window back onto a visible
        // screen, and this machine has none.
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<80 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }

        var counts: [String: Int] = [:]
        var queue: [NSView] = [host]
        while let view = queue.popLast() {
            counts[String(describing: type(of: view)), default: 0] += 1
            queue.append(contentsOf: view.subviews)
        }
        return Sidebar(rows: counts["ListTableCellView"] ?? 0, headers: counts["ListTableHeaderView"] ?? 0)
    }

    func testTheRowSurvivesCollapsingEveryWorkspaceSection() throws {
        let sidebar = try mountSidebar(collapsingEverything: true)
        XCTAssertEqual(sidebar.headers, 2, "both workspace headers must still be drawn")
        XCTAssertEqual(sidebar.rows, 1, "only At a Glance may remain when every section is collapsed")
    }

    func testExpandingTheSectionsBringsBackTheProjectRowsBesideIt() throws {
        let sidebar = try mountSidebar(collapsingEverything: false)
        XCTAssertEqual(sidebar.headers, 2)
        XCTAssertEqual(sidebar.rows, 5, "four project rows plus the pinned At a Glance row")
    }
}

@MainActor
private final class RowStubSupervisor: WorkerSupervising {
    var serverPort: Int? { nil }
    var lastError: String? { nil }
    var shutdownProgress: [String: ShutdownProgress] { [:] }

    func registerProject(repoPath: URL, name: String?, baseBranch: String?) async throws -> Project {
        throw StubError.notWired
    }
    func assign(taskId: String) async throws {}
    func waitForSetup() async {}
    func stop(sessionId: String) async throws {}
    func resume(sessionId: String) async throws {}
    func pauseAll(projectId: String) async throws {}
    func accept(taskId: String) async throws {}
    func reopen(taskId: String) async throws {}
    func discard(taskId: String) async throws {}
    func reconcile(projectId: String) async {}
    func attachCommand(sessionId: String) -> (executable: String, arguments: [String])? { nil }
    func worktreeDiffstat(taskId: String) async -> String? { nil }
    func worktreeDiffSummary(taskId: String) async -> DiffSummary? { nil }
    func orchestratorConsole(projectId: String) throws -> OrchestratorConsole { throw StubError.notWired }
    func approve(approvalId: String) async throws {}
    func deny(approvalId: String, reason: String?) async throws {}
    func promote(taskId: String) async throws {}
    func requestIntegration(epicId: String) async throws {}
    func openPullRequest(epicId: String) async throws -> PullRequestOutcome { throw StubError.notWired }
    func requestShutdown(projectId: String, requestedBy: String, reason: String?) async throws -> ShutdownOrder {
        throw StubError.notWired
    }
    func cancelShutdown(projectId: String, by: String) async throws -> ShutdownOrder? { nil }
    func isShuttingDown(projectId: String) -> Bool { false }
    func deliverShutdownOrder(projectId: String) async throws -> ShutdownProgress { throw StubError.notWired }
    func requestGlobalShutdown(requestedBy: String, reason: String?) async throws -> [ShutdownOrder] { [] }
    func cancelGlobalShutdown(by: String) async throws -> [ShutdownOrder] { [] }
    func stopOrchestratorConsoles() {}
}
