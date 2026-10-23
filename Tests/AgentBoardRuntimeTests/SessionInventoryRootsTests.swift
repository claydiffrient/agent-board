import AgentBoardCore
import AgentBoardRuntime
import Darwin
import XCTest

final class SessionInventoryRootsTests: XCTestCase {
    func testHostsAreRootsByPidAndOnlyAnUnoccupiedEndedWorktreeIsClaimed() {
        func session(
            _ id: String, short: String? = nil, task: String? = nil, state: SessionState, worktree: String? = nil,
            reviewing: Bool = false
        ) -> AgentSession {
            var row = AgentSession(
                sessionId: id, shortId: short, projectId: "p-1", taskId: task, role: .worker, cwd: "/tmp",
                state: state, startedAt: 5_000
            )
            row.worktreePath = worktree
            row.reviewHead = reviewing ? "abc123" : nil
            return row
        }
        let sessions = [
            session("s-live", task: "t-1", state: .running, worktree: "/wt/a"),
            session("s-short", short: "short1", task: "t-2", state: .running, reviewing: true),
            session("s-ended-free", task: "t-3", state: .completed, worktree: "/wt/b"),
            session("s-ended-cotenant", task: "t-1", state: .stopped, worktree: "/wt/a"),
            session("s-ended-gone", state: .failed, worktree: "/wt/removed"),
            session("s-ended-shared", state: .completed),
            session("s-setup", state: .setup, worktree: "/wt/c"),
        ]
        let listing = [
            AgentInfo(cwd: "/wt/a", kind: "bg", sessionId: "s-live", pid: 300),
            AgentInfo(id: "short1", cwd: "/repo", kind: "bg", pid: 310),
            AgentInfo(cwd: "/elsewhere", kind: "interactive", sessionId: "not-ours", pid: 999),
        ]

        let roots = SessionInventoryRoots.roots(listing: listing, sessions: sessions) { $0 != "/wt/removed" }

        XCTAssertEqual(roots, [
            InventoryRoot(pid: 300, owner: ProcessOwner(role: .worker, projectId: "p-1", taskId: "t-1", sessionId: "s-live")),
            InventoryRoot(pid: 310, owner: ProcessOwner(role: .reviewer, projectId: "p-1", taskId: "t-2", sessionId: "s-short")),
            InventoryRoot(
                pid: nil, owner: ProcessOwner(role: .worker, projectId: "p-1", taskId: "t-3", sessionId: "s-ended-free"),
                worktree: WorktreeClaim(path: "/wt/b", startedAtMicros: 5_000_000)
            ),
        ])
    }
}
