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
    private func prompt(previousStop: String? = nil) -> String {
        WorkerSupervisor.resumePrompt(previousStop: previousStop)
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
            OpeningPrompt.workingProtocol(branch: "agentboard/\(task.id)"),
            "the uri the resume prompt names did not return the protocol"
        )
        let listed = try await resources.resources(for: identity)
        XCTAssertTrue(
            listed.contains { $0.uri == uri },
            "the uri the resume prompt names is not discoverable in resources/list"
        )
    }
}
