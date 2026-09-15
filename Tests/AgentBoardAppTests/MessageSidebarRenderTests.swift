import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Cross-project messages live in the orchestrator's right-hand sidebar, as a fifth section under
/// the four that already ask the human to act.
///
/// What this proves: the section is drawn, it holds one row per message in both directions, and a
/// message written after the mount reaches the list through its `ValueObservation` with nothing
/// polling.
///
/// What it cannot prove: that a row reads "From Beta", that the unread bar is orange, or anything
/// else about the pixels. SwiftUI draws `Text` into backing layers and `AXIsProcessTrusted()` is
/// false in an xctest process, so no string on this screen is readable on this machine.
@MainActor
final class MessageSidebarRenderTests: XCTestCase {
    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
    }

    /// Borderless and far offscreen: AppKit constrains a `.titled` window back onto a visible
    /// screen, and this machine has none.
    private func mount(_ db: AppDatabase, _ project: Project) -> Mounted {
        let root = AnyView(
            ApprovalsSidebar(project: project)
                .environment(AppEnvironment(db: db, supervisor: MessageStubSupervisor()))
                .frame(width: 320, height: 900)
        )
        let host = NSHostingView(rootView: root)
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        return Mounted(window: window, host: host)
    }

    private func settle(_ mounted: Mounted, turns: Int = 80) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            mounted.window.layoutIfNeeded()
            mounted.window.displayIfNeeded()
        }
    }

    private func counts(_ mounted: Mounted) -> [String: Int] {
        var result: [String: Int] = [:]
        var queue: [NSView] = [mounted.host]
        while let view = queue.popLast() {
            result[String(describing: type(of: view)), default: 0] += 1
            queue.append(contentsOf: view.subviews)
        }
        return result
    }

    private func projects() throws -> (AppDatabase, Project, Project) {
        let db = try AppDatabase.inMemory()
        let store = ProjectStore(db)
        let alpha = try store.register(
            name: "Alpha", repoPath: "/tmp/msg-alpha-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/msg-worktrees", memoryDir: nil
        )
        let beta = try store.register(
            name: "Beta", repoPath: "/tmp/msg-beta-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/msg-worktrees", memoryDir: nil
        )
        return (db, alpha, beta)
    }

    func testTheSidebarGainsAMessagesSectionWithAPlaceholderWhenThereIsNoTraffic() throws {
        let (db, alpha, _) = try projects()
        let mounted = mount(db, alpha)
        settle(mounted)

        let counts = counts(mounted)
        XCTAssertEqual(
            counts["ListTableHeaderView"], 5,
            "Blocked, Pending approvals, Pending reviews, Proposals, Messages"
        )
        XCTAssertEqual(counts["ListTableCellView"], 5, "one empty-state row per section")
    }

    func testBothDirectionsGetTheirOwnRow() throws {
        let (db, alpha, beta) = try projects()
        let messages = MessageStore(db)
        try messages.send(
            fromProjectId: alpha.id, fromSessionId: nil, toProjectId: beta.id, body: "outbound"
        )
        try messages.send(
            fromProjectId: beta.id, fromSessionId: nil, toProjectId: alpha.id, body: "inbound"
        )

        let mounted = mount(db, alpha)
        settle(mounted)

        XCTAssertEqual(
            counts(mounted)["ListTableCellView"], 6,
            "four empty-state rows plus one row for the sent message and one for the received"
        )
    }

    /// The observation, not a timer: both writes happen after the view is mounted and settled, and
    /// nothing in this view polls.
    ///
    /// Two messages, not one: the Messages placeholder row gives way to the first message, so a
    /// single arrival leaves the cell count at five and cannot be told apart from no update at all.
    func testMessagesSentAfterTheMountReachTheListWithoutPolling() throws {
        let (db, alpha, beta) = try projects()
        let mounted = mount(db, alpha)
        settle(mounted)
        XCTAssertEqual(counts(mounted)["ListTableCellView"], 5, "five empty-state rows, nothing else")

        let messages = MessageStore(db)
        try messages.send(
            fromProjectId: beta.id, fromSessionId: nil, toProjectId: alpha.id, body: "arrived late"
        )
        try messages.send(
            fromProjectId: alpha.id, fromSessionId: nil, toProjectId: beta.id, body: "and a reply"
        )
        settle(mounted, turns: 60)

        XCTAssertEqual(
            counts(mounted)["ListTableCellView"], 6,
            "four empty-state rows plus the two new messages, reached without a remount"
        )
    }
}

@MainActor
private final class MessageStubSupervisor: WorkerSupervising {
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
