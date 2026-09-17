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

    /// The quit path leaves every order standing. A session that never acknowledged is a detached
    /// `claude --bg` process that outlives the app, and the order still on its project is the only
    /// thing that hands it the wind-down through `PreToolUse` on the next launch (SPEC §10).
    func testQuittingLeavesEveryShutdownOrderStanding() throws {
        let db = try AppDatabase.inMemory()
        let orders = ShutdownOrderStore(db)
        var projectIds: [String] = []
        var raised: [ShutdownOrder] = []
        for name in ["Alpha", "Beta"] {
            let project = try ProjectStore(db).register(
                name: name, repoPath: "/tmp/\(name)-\(UUID().uuidString)", baseBranch: "main",
                worktreeRoot: "/tmp/\(name)-worktrees", memoryDir: nil
            )
            projectIds.append(project.id)
            raised.append(try orders.request(projectId: project.id, requestedBy: "human"))
        }

        // No deliveries at all: nothing is left to wait for, which is the decision that quits.
        let supervisor = RenderStubSupervisor(progress: [:])
        supervisor.globalOrders = raised
        let quitter = FakeQuitter()
        mount(GlobalShutdownSheet(), in: AppEnvironment(db: db, supervisor: supervisor, quitter: quitter))

        XCTAssertEqual(quitter.requests, 1, "the sheet never asked the app to quit")
        XCTAssertEqual(supervisor.consolesStopped, 1)
        for projectId in projectIds {
            XCTAssertNotNil(
                try orders.outstanding(projectId: projectId),
                "quitting lifted the order on \(projectId); a detached worker now never hears it"
            )
        }
    }
}

/// The refusal has to be reported somewhere the human is still looking. By the time an attempt can
/// fail the sheet that asked for it is gone — AppKit will not terminate while it is up — so the
/// report lands on At a Glance, and a macOS alert is a sheet on that window.
@MainActor
final class QuitRefusalAlertTests: XCTestCase {
    func testARefusalPutsAnAlertOnAtAGlance() throws {
        XCTAssertNotNil(
            try attachedSheet(refusal: "macOS did not quit Agent Board when it was asked to."),
            "a refused quit reported nothing at all — the silent dead end this replaced"
        )
    }

    func testNoAlertWhenNothingWasRefused() throws {
        XCTAssertNil(try attachedSheet(refusal: nil))
    }

    /// The refusal arrives after the screen is already up, and it reaches the view through an
    /// `any AppQuitting` existential — so this is the case that actually decides whether the
    /// human ever sees it.
    func testARefusalRaisedAfterTheScreenIsUpStillShows() throws {
        let db = try AppDatabase.inMemory()
        let quitter = FakeQuitter()
        let window = mount(
            AtAGlanceView(projects: [], workspaces: [], attention: [], select: { _ in }),
            in: AppEnvironment(db: db, supervisor: RenderStubSupervisor(progress: [:]), quitter: quitter)
        )
        XCTAssertNil(window.attachedSheet)

        quitter.refusal = "macOS did not quit Agent Board when it was asked to."
        settle(window)
        XCTAssertNotNil(window.attachedSheet, "the refusal never reached the screen")
    }

    private func attachedSheet(refusal: String?) throws -> NSWindow? {
        let db = try AppDatabase.inMemory()
        let quitter = FakeQuitter()
        quitter.refusal = refusal
        let window = mount(
            AtAGlanceView(projects: [], workspaces: [], attention: [], select: { _ in }),
            in: AppEnvironment(db: db, supervisor: RenderStubSupervisor(progress: [:]), quitter: quitter)
        )
        return window.attachedSheet
    }
}

@Observable
@MainActor
final class FakeQuitter: AppQuitting {
    var refusal: String?
    private(set) var requests = 0

    func requestQuit() { requests += 1 }
    func dismissRefusal() { refusal = nil }
}

@MainActor
@discardableResult
func mount(_ view: some View, in environment: AppEnvironment, turns: Int = 60) -> NSWindow {
    let host = NSHostingView(rootView: view.environment(environment))
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = host
    window.orderFront(nil)
    settle(window, turns: turns)
    return window
}

@MainActor
func settle(_ window: NSWindow, turns: Int = 60) {
    for _ in 0..<turns {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }
}
