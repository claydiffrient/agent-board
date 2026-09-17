import AgentBoardCore
import AgentBoardRuntime
import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import AgentBoard

/// Mounts the wind-down sheet offscreen through `NSHostingView`.
///
/// What this proves: the sheet builds against a real database, its body evaluates, it reads the
/// supervisor's observable progress, and a change to `shutdown_delivery` re-renders it — so the
/// count advances off the database, not off a polling loop.
///
/// What it cannot prove: anything about the pixels or the rendered strings. SwiftUI draws its text
/// into backing layers rather than `NSTextField`s, and the accessibility elements it does publish
/// carry no label, title or value here. The wording and the state mapping are covered instead by
/// `ShutdownSheetTests` in AgentBoardCoreTests.
@MainActor
final class ShutdownSheetRenderTests: XCTestCase {
    private struct Mounted {
        let db: AppDatabase
        let project: Project
        let order: ShutdownOrder
        let supervisor: RenderStubSupervisor
        let window: NSWindow
        let host: NSView

        func settle(turns: Int = 40) {
            for _ in 0..<turns {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }
    }

    private func mount(
        workers: [(sessionId: String, deliveredAgo: Int64?, acknowledge: Bool, state: SessionState)],
        reported: ShutdownProgress
    ) throws -> Mounted {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        let order = try ShutdownOrderStore(db).request(projectId: project.id, requestedBy: "human")
        let now = Int64.nowMillis
        let deliveries = ShutdownDeliveryStore(db)
        for worker in workers {
            let task = try TaskStore(db).create(
                projectId: project.id, title: "Task for \(worker.sessionId)", body: nil, acceptance: nil,
                priority: nil, column: .running, origin: .human, epicId: nil
            )
            try SessionStore(db).insert(AgentSession(
                sessionId: worker.sessionId, shortId: String(worker.sessionId.prefix(8)),
                projectId: project.id, taskId: task.id, role: .worker, cwd: "/tmp",
                state: worker.state, startedAt: now - 600_000,
                endedAt: worker.state.isActive ? nil : now - 10_000
            ))
            try deliveries.enroll(orderId: order.id, sessionId: worker.sessionId, taskId: task.id, at: now - 600_000)
            if let deliveredAgo = worker.deliveredAgo {
                _ = try deliveries.claimDelivery(
                    orderId: order.id, sessionId: worker.sessionId, taskId: task.id, via: .hook,
                    at: now - deliveredAgo * 1000
                )
            }
            if worker.acknowledge {
                _ = try Board(db).acknowledgeShutdown(sessionId: worker.sessionId, note: "committed on its branch")
            }
        }

        let supervisor = RenderStubSupervisor(progress: [project.id: reported])
        let host = NSHostingView(
            rootView: ShutdownSheet(project: project, order: order, console: nil)
                .environment(AppEnvironment(db: db, supervisor: supervisor))
        )
        NSApplication.shared.setActivationPolicy(.accessory)
        // Borderless and far offscreen: AppKit constrains a `.titled` window back onto a screen,
        // which put this fixture in front of the human during unrelated test runs.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        return Mounted(db: db, project: project, order: order, supervisor: supervisor, window: window, host: host)
    }

    func testSheetMountsAndReadsTheObservableProgress() throws {
        let mounted = try mount(
            workers: [
                ("aaaaaaaa-0001", 400, true, .completed),
                ("bbbbbbbb-0002", 400, false, .running),
                ("cccccccc-0003", nil, false, .blocked),
            ],
            reported: ShutdownProgress(orderId: "x", total: 3, acknowledged: 1, overdue: ["bbbbbbbb-0002"])
        )
        mounted.settle()
        XCTAssertGreaterThan(
            mounted.supervisor.progressReads, 0,
            "the sheet's body never read the supervisor's observable progress"
        )
        XCTAssertEqual(mounted.host.frame.size, NSSize(width: 620, height: 520))
    }

    /// The count advances because the delivery table changed, not because anything polled: the stub
    /// supervisor never ticks, and the only other clock in the sheet is a per-row `TimelineView`,
    /// which cannot re-evaluate the parent body.
    func testAcknowledgingAWorkerReRendersTheSheet() throws {
        let mounted = try mount(
            workers: [
                ("aaaaaaaa-0001", 400, true, .completed),
                ("bbbbbbbb-0002", 400, false, .running),
            ],
            reported: ShutdownProgress(orderId: "x", total: 2, acknowledged: 1)
        )
        mounted.settle()
        let before = mounted.supervisor.progressReads
        XCTAssertGreaterThan(before, 0)

        _ = try Board(mounted.db).acknowledgeShutdown(sessionId: "bbbbbbbb-0002", note: "done")
        mounted.settle()

        XCTAssertGreaterThan(
            mounted.supervisor.progressReads, before,
            "an acknowledgment landing in the database did not re-render the sheet"
        )
    }

    /// Evidence that the rendered strings are unreadable here rather than merely absent, so a later
    /// reader does not mistake this suite for a claim about what the sheet displays.
    ///
    /// This asserted `AXIsProcessTrusted() == false` until 2026-09-17, when the flag flipped to
    /// true. Trust is attributed to whichever process is responsible for launching the test host,
    /// not to the host itself, so it is never the suite's to hold or revoke; the flag was only ever
    /// a proxy. The capability is asserted directly instead, and both halves still hold: the AX
    /// server refuses this process's queries against its own application element
    /// (`kAXErrorCannotComplete`, -25208), and the walk below interrogates every accessibility
    /// element the mounted hierarchy publishes, follows their child links, and recovers no string.
    /// If either opens up, this fails and the assertions above can be strengthened.
    func testRenderedTextIsNotReadableOnThisMachine() throws {
        let mounted = try mount(
            workers: [
                ("aaaaaaaa-0001", 400, true, .completed),
                ("bbbbbbbb-0002", 400, false, .running),
            ],
            reported: ShutdownProgress(orderId: "x", total: 2, acknowledged: 1)
        )
        mounted.settle()

        var windows: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows
        )
        XCTAssertNotEqual(
            status, .success,
            "this process can read its own AX window list now; the AX tree may be readable"
        )

        let walk = Self.walk(mounted.host)
        XCTAssertGreaterThan(walk.elements, 1, "the walk never interrogated the mounted hierarchy")
        XCTAssertGreaterThan(walk.childLinks, 0, "the walk never followed an accessibility child link")
        XCTAssertTrue(
            walk.strings.isEmpty,
            "the rendered text is readable now; assert on the sheet's wording directly"
        )
    }

    /// Walks both the view tree and the accessibility tree for anything that carries a string,
    /// counting what it interrogated so an empty result cannot pass for a walk that found nothing
    /// to ask.
    private static func walk(_ root: NSView) -> (strings: [String], elements: Int, childLinks: Int) {
        var found: [String] = []
        var elements = 0
        var childLinks = 0
        var queue: [Any] = [root]
        var visited = 0
        while let node = queue.popLast(), visited < 6000 {
            visited += 1
            if let text = node as? NSTextField { found.append(text.stringValue) }
            if let button = node as? NSButton { found.append(button.title) }
            if let element = node as? NSAccessibilityProtocol {
                elements += 1
                found.append(element.accessibilityLabel() ?? "")
                found.append(element.accessibilityTitle() ?? "")
                found.append(element.accessibilityValue() as? String ?? "")
                let children = element.accessibilityChildren() ?? []
                childLinks += children.count
                queue.append(contentsOf: children)
            }
            if let view = node as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return (found.filter { !$0.isEmpty }, elements, childLinks)
    }
}

@MainActor
@Observable
final class RenderStubSupervisor: WorkerSupervising {
    @ObservationIgnored private(set) var progressReads = 0
    @ObservationIgnored private(set) var consolesStopped = 0
    /// What `requestGlobalShutdown` answers with, so a sheet under test sees the orders its
    /// database already holds rather than an empty list.
    @ObservationIgnored var globalOrders: [ShutdownOrder] = []
    @ObservationIgnored private var progress: [String: ShutdownProgress]

    init(progress: [String: ShutdownProgress]) {
        self.progress = progress
    }

    var shutdownProgress: [String: ShutdownProgress] {
        progressReads += 1
        return progress
    }

    var serverPort: Int? { nil }
    var lastError: String? { nil }

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

    func shellConsole(projectId: String) throws -> ShellConsole { throw StubError.notWired }
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
    func isShuttingDown(projectId: String) -> Bool { true }
    func deliverShutdownOrder(projectId: String) async throws -> ShutdownProgress { throw StubError.notWired }
    func requestGlobalShutdown(requestedBy: String, reason: String?) async throws -> [ShutdownOrder] { globalOrders }
    func cancelGlobalShutdown(by: String) async throws -> [ShutdownOrder] { globalOrders }
    func stopOrchestratorConsoles() { consolesStopped += 1 }
}
