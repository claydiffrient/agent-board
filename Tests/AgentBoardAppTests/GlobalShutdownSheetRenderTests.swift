import AgentBoardCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard

/// Mounts the cross-project wind-down sheet offscreen through `NSHostingView`.
///
/// What this proves: the sheet builds against a real database, its body evaluates, and its single
/// observation picks up the orders and deliveries of more than one project. It also proves the
/// quit path did not fire — `stopOrchestratorConsoles` is the last thing before
/// `NSApplication.terminate`, and the fixture is arranged so the decision is `.wait`.
///
/// What it cannot prove: anything about the pixels or the rendered strings, for the reasons set
/// out in `ShutdownSheetRenderTests`. The wording and the quit decision are covered by
/// `GlobalShutdownTests` in AgentBoardCoreTests.
@MainActor
final class GlobalShutdownSheetRenderTests: XCTestCase {
    func testTheSheetMountsAgainstTwoProjectsAndDoesNotQuit() throws {
        let db = try AppDatabase.inMemory()
        let orders = ShutdownOrderStore(db)
        let deliveries = ShutdownDeliveryStore(db)
        var raised: [ShutdownOrder] = []
        for name in ["Alpha", "Beta"] {
            let project = try ProjectStore(db).register(
                name: name, repoPath: "/tmp/\(name)-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil
            )
            let order = try orders.request(projectId: project.id, requestedBy: "human")
            raised.append(order)
            let task = try TaskStore(db).create(
                projectId: project.id, title: "Work on \(name)", body: nil, acceptance: nil,
                priority: nil, column: .running, origin: .human, epicId: nil
            )
            let sessionId = "session-\(name)"
            try SessionStore(db).insert(AgentSession(
                sessionId: sessionId, shortId: String(name.prefix(4)), projectId: project.id,
                taskId: task.id, role: .worker, cwd: "/tmp", state: .running
            ))
            try deliveries.enroll(orderId: order.id, sessionId: sessionId, taskId: task.id)
        }

        let supervisor = RenderStubSupervisor(progress: [:])
        supervisor.globalOrders = raised
        let host = NSHostingView(
            rootView: GlobalShutdownSheet().environment(AppEnvironment(db: db, supervisor: supervisor))
        )
        NSApplication.shared.setActivationPolicy(.accessory)
        // Borderless and far offscreen: AppKit constrains a `.titled` window back onto a screen.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }

        let snapshot = try GlobalShutdownStore(db).snapshot()
        XCTAssertEqual(snapshot.projectCount, 2)
        XCTAssertEqual(GlobalShutdown.rows(snapshot, awake: .init(nowMillis: .nowMillis)).count, 2)
        XCTAssertEqual(
            supervisor.consolesStopped, 0,
            "the sheet took the quit path while two workers were still winding down"
        )
        XCTAssertEqual(host.frame.size, NSSize(width: 620, height: 520))
    }
}
