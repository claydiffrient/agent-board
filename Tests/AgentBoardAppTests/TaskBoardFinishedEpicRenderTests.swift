import AppKit
import SwiftUI
import XCTest
@testable import AgentBoard
@testable import AgentBoardCore

/// A done epic whose tasks are all archived leaves the Task Board until Show Archived is on (SPEC
/// §10). `Text` leaves no string in the view tree, so the title's presence is proved by pixels: two
/// boards that differ only in the epic's title must draw identically while the lane is hidden.
///
/// The offscreen window has no toolbar to click, so Show Archived is turned on the way a Coordinator
/// epic link turns it on for a hidden lane.
@MainActor
final class TaskBoardFinishedEpicRenderTests: XCTestCase {
    private static let epicId = "epic-finished-render"

    private var mounts: [OffscreenMount] = []

    override func tearDown() {
        mounts.forEach { $0.close() }
        mounts = []
        super.tearDown()
    }

    func testAFullyArchivedDoneEpicDrawsNoTitleUntilShowArchivedIsOn() throws {
        let ports = try mount(epicTitle: "Ports")
        let idle = try mount(epicTitle: "Idle cap")
        XCTAssertEqual(ports.diff(idle, columns: 0..<ports.width).count, 0,
                       "with Show Archived off the finished epic still drew its lane or rail entry")

        let portsShown = try mount(epicTitle: "Ports", showingArchivedOver: ports)
        let idleShown = try mount(epicTitle: "Idle cap", showingArchivedOver: idle)
        XCTAssertGreaterThan(portsShown.diff(idleShown, columns: 0..<portsShown.width).count, 0,
                             "with Show Archived on the lane must draw its title")
    }

    /// With `showingArchivedOver`, the board is routed to the epic and the capture waits until it
    /// differs from that unrouted capture of the same board.
    private func mount(epicTitle: String, showingArchivedOver hidden: Capture? = nil) throws -> Capture {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "finished", repoPath: "/tmp/board-finished-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/board-finished-worktrees", memoryDir: nil
        )
        try db.writer.write { db in
            try Epic(
                id: Self.epicId, projectId: project.id, title: epicTitle, goal: nil,
                branch: "agentboard/epic-finished", state: .done, createdAt: 1_000
            ).insert(db)
        }
        let task = try TaskStore(db).create(
            projectId: project.id, title: "Shipped", body: nil, acceptance: nil, priority: nil,
            column: .done, origin: .human, epicId: Self.epicId
        )
        try TaskStore(db).archive(ids: [task.id])
        _ = try TaskStore(db).create(
            projectId: project.id, title: "Port sweep", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: nil
        )

        let router = NotificationRouter()
        if hidden != nil {
            router.open(NotificationRoute(projectId: project.id, subject: .epic(Self.epicId)))
        }
        let mount = OffscreenMount(
            TaskBoardView(project: project).environment(renderEnvironment(db: db, router: router)),
            size: CGSize(width: 1900, height: 540)
        )
        mounts.append(mount)
        guard let hidden else { return try mount.capture() }
        return try mount.capture { $0.diff(hidden, columns: 0..<$0.width).count > 0 }
    }
}
