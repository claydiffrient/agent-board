import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// SPEC §9: launching the app wakes zero orchestrators, because nothing auto-selects a project.
/// At a Glance replaced the empty detail pane, and a page that started consoles would quietly cost
/// one session per project on every launch — so the property is asserted rather than assumed.
///
/// What this proves: `MainWindow`, mounted offscreen against a real database holding projects,
/// never asks the supervisor for a console; and the same recorder does fire when a project detail
/// view is mounted, so the negative is not vacuous.
///
/// What it cannot prove: anything about the rendered text or layout. SwiftUI draws into backing
/// layers and `AXIsProcessTrusted()` is false here, so no string is readable — the wording and
/// grouping are covered by `GlancePresentationTests` in AgentBoardCoreTests instead.
@MainActor
final class AtAGlanceLaunchCostTests: XCTestCase {
    private struct Mounted {
        let window: NSWindow
        let host: NSView
        let supervisor: ConsoleRecordingSupervisor

        func settle(turns: Int = 60) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }
    }

    private func projects(_ db: AppDatabase, _ names: [String]) throws -> [Project] {
        try names.map { name in
            try ProjectStore(db).register(
                name: name, repoPath: "/tmp/glance-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/glance-worktrees", memoryDir: nil
            )
        }
    }

    /// Borderless and far offscreen. A `.titled` window is constrained back onto a visible screen
    /// by AppKit, which would put the app on a display this machine does not have.
    private func mount(_ view: some View, db: AppDatabase, supervisor: ConsoleRecordingSupervisor) -> Mounted {
        let host = NSHostingView(rootView: view.environment(AppEnvironment(db: db, supervisor: supervisor)))
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        return Mounted(window: window, host: host, supervisor: supervisor)
    }

    func testLaunchingWithNothingSelectedStartsNoOrchestrator() throws {
        let db = try AppDatabase.inMemory()
        _ = try projects(db, ["Alpha", "Beta", "Gamma"])
        let mounted = mount(MainWindow(), db: db, supervisor: ConsoleRecordingSupervisor())
        mounted.settle()

        XCTAssertEqual(
            mounted.supervisor.consoleRequests, [],
            "the landing view woke an orchestrator; launching must cost zero sessions (SPEC §9)"
        )
    }

    /// The positive control for the assertion above: the recorder does fire when a project is open,
    /// so an empty `consoleRequests` means "nothing asked", not "nothing is wired".
    func testOpeningAProjectDoesStartItsOrchestrator() throws {
        let db = try AppDatabase.inMemory()
        let project = try XCTUnwrap(try projects(db, ["Alpha"]).first)
        let mounted = mount(ProjectDetailView(project: project), db: db, supervisor: ConsoleRecordingSupervisor())
        mounted.settle()

        XCTAssertEqual(mounted.supervisor.consoleRequests, [project.id])
    }

    func testTheGlancePageMountsAndReadsOneSummaryForEveryProject() throws {
        let db = try AppDatabase.inMemory()
        let all = try projects(db, ["Alpha", "Beta"])
        try TaskStore(db).create(
            projectId: all[0].id, title: "running one", body: nil, acceptance: nil,
            priority: nil, column: .running, origin: .human, epicId: nil
        )
        var selected: [SidebarSelection] = []
        let page = AtAGlanceView(projects: all, workspaces: [], select: { selected.append($0) })
        let mounted = mount(page, db: db, supervisor: ConsoleRecordingSupervisor())
        mounted.settle()

        XCTAssertEqual(mounted.supervisor.consoleRequests, [], "the page must not open any project's console")
        XCTAssertTrue(selected.isEmpty, "nothing was clicked, so nothing may have been selected")
        XCTAssertGreaterThan(mounted.host.subviews.count, 0, "the page body never evaluated")
    }
}

final class SidebarSelectionTests: XCTestCase {
    func testNothingChosenIsAtAGlanceRatherThanNoSelection() {
        XCTAssertNil(SidebarSelection.atAGlance.projectId)
    }

    func testAProjectSelectionCarriesItsId() {
        XCTAssertEqual(SidebarSelection.project("p-1").projectId, "p-1")
        XCTAssertNotEqual(SidebarSelection.project("p-1"), SidebarSelection.project("p-2"))
    }
}

@MainActor
@Observable
private final class ConsoleRecordingSupervisor: WorkerSupervising {
    @ObservationIgnored private(set) var consoleRequests: [String] = []

    func orchestratorConsole(projectId: String) throws -> OrchestratorConsole {
        consoleRequests.append(projectId)
        throw StubError.notWired
    }

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
    func approve(approvalId: String) async throws {}
    func deny(approvalId: String, reason: String?) async throws {}
    func promote(taskId: String) async throws {}
    func requestIntegration(epicId: String) async throws {}
    func epicClosurePlan(epicId: String, as closure: EpicClosure) throws -> EpicClosurePlan { throw StubError.notWired }
    func closeEpic(epicId: String, as closure: EpicClosure) async throws { throw StubError.notWired }
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
