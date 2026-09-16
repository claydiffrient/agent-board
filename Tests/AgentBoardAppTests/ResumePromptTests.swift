import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest
@testable import AgentBoard

/// A resumed or compacted worker has lost its opening prompt. The resume prompt used to send it
/// back to "your original instructions", which is exactly what it no longer has. These tests hold
/// it to naming a route that a real `claude --bg` session can actually take — measured against
/// Claude Code 2.1.272, that is `resources/read`, never `prompts/get`.
@MainActor
final class ResumePromptTests: XCTestCase {
    private func prompt(previousStop: String? = nil, placement: WorkerPlacement = .worktree) -> String {
        WorkerSupervisor.resumePrompt(previousStop: previousStop, placement: placement)
    }

    func testTheResumePromptNamesTheResourceThatHoldsTheProtocol() {
        XCTAssertTrue(prompt().contains(BriefingResourceURI.worker), prompt())
    }

    func testTheResumePromptDoesNotSendTheWorkerBackToInstructionsItNoLongerHas() {
        let text = prompt()
        XCTAssertFalse(
            text.contains("original instructions"),
            "the resume prompt still refers the worker to instructions it no longer holds: \(text)"
        )
        XCTAssertTrue(text.contains("report_complete"), "the resume prompt dropped the completion step")
        XCTAssertTrue(text.contains("do not push"), "the resume prompt dropped the no-push rule")
    }

    func testTheReasonAWorkerWasStoppedStillReachesIt() {
        XCTAssertTrue(prompt(previousStop: "the human wound the project down").contains("the human wound the project down"))
    }

    /// `git commit` is refused in a shared checkout, so the resume prompt cannot keep telling every
    /// worker to run it.
    func testAResumedSharedCheckoutWorkerIsSentAtTheCommitToolRatherThanGitCommit() {
        let text = prompt(placement: .shared(branch: "agentboard/shared"))
        XCTAssertTrue(text.contains(OpeningPrompt.commitToolName), text)
        XCTAssertFalse(text.contains("commit on this branch"), text)
        XCTAssertTrue(prompt().contains("commit on this branch"), "a worktree worker still commits itself")
    }

    /// The assertion that matters: the uri in the resume prompt is not a plausible-looking string,
    /// it is one the server answers. A rename on either side fails here.
    func testTheUriTheResumePromptNamesIsOneTheServerActuallyServes() async throws {
        let db = try AppDatabase.inMemory()
        let project = try ProjectStore(db).register(
            name: "Demo", repoPath: "/tmp/demo-\(UUID().uuidString)", baseBranch: "main",
            worktreeRoot: "/tmp/demo-worktrees", memoryDir: nil
        )
        let task = try TaskStore(db).create(
            projectId: project.id, title: "t", body: nil, acceptance: nil, priority: nil,
            column: .running, origin: .human, epicId: nil
        )
        let session = AgentSession(
            sessionId: "s1", projectId: project.id, taskId: task.id, role: .worker,
            worktreePath: "/tmp/demo-worktrees/\(task.id)", branch: TaskStore.branchName(for: task.id),
            cwd: "/tmp/demo-worktrees/\(task.id)", state: .running
        )
        try SessionStore(db).insert(session)
        let identity = TokenIdentity(
            token: "w", scope: .worker, projectId: project.id, sessionId: "s1", taskId: task.id
        )
        let resources = CompositeResourceHandler([
            (NoteResourceURI.scheme, NoteResourceHandler(db: db)),
            (BriefingResourceURI.scheme, BriefingResourceHandler(db: db)),
        ])

        let uri = try XCTUnwrap(
            prompt().split(separator: "`").first { $0.hasPrefix("\(BriefingResourceURI.scheme)://") }.map(String.init),
            "the resume prompt names no briefing uri at all"
        )
        let contents = try await resources.read(uri, identity: identity)

        XCTAssertEqual(
            contents.first?.text,
            OpeningPrompt.workingProtocol(
                branch: try XCTUnwrap(session.branch), placement: .worktree, workingDirectory: session.cwd
            ),
            "the uri the resume prompt names did not return the protocol"
        )
        let listed = try await resources.resources(for: identity)
        XCTAssertTrue(
            listed.contains { $0.uri == uri },
            "the uri the resume prompt names is not discoverable in resources/list"
        )
    }
}
