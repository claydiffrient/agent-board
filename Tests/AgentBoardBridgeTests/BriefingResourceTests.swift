import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// The briefings a session fetches for itself. A `claude --bg` worker cannot reach `prompts/get`
/// (measured: Claude Code 2.1.272 exposes no route to it), so `resources/read` is the only one of
/// the two these texts can arrive by, and these tests hold that route open.
final class BriefingResourceTests: XCTestCase {
    private var f: BridgeFixture!
    private var resources: BriefingResourceHandler!
    private var worker: TokenIdentity!
    private var taskId: String!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        resources = BriefingResourceHandler(db: f.db)
        let task = try f.task("t", column: .running)
        taskId = task.id
        try f.session("s1", taskId: task.id)
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    private func read(_ uri: String, as identity: TokenIdentity) async throws -> String {
        let contents = try await resources.read(uri, identity: identity)
        XCTAssertEqual(contents.count, 1)
        let first = try XCTUnwrap(contents.first)
        XCTAssertEqual(first.uri, uri)
        return first.text
    }

    private func setSettings(_ mutate: (inout ProjectSettings) -> Void) throws {
        var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
        mutate(&settings)
        try f.projects.updateSettings(f.project.id, settings)
    }

    // MARK: The worker protocol

    func testTheWorkerProtocolResourceIsByteIdenticalToTheTextASpawnComposes() async throws {
        let served = try await read(BriefingResourceURI.worker, as: worker)
        XCTAssertEqual(served, OpeningPrompt.workingProtocol(branch: "agentboard/\(taskId!)"))
    }

    func testTheProtocolIsRenderedForTheCallersOwnBranch() async throws {
        let other = try f.task("other", column: .running)
        try f.session("s2", taskId: other.id)
        let served = try await read(BriefingResourceURI.worker, as: f.workerIdentity(sessionId: "s2", taskId: other.id))

        XCTAssertTrue(served.contains("agentboard/\(other.id)"), "the protocol named someone else's branch")
        XCTAssertFalse(served.contains(taskId), "the protocol named someone else's branch")
    }

    func testAWorkerListsTheProtocolAndNotTheOrchestratorBriefing() async throws {
        let listed = try await resources.resources(for: worker)
        XCTAssertEqual(listed.map(\.uri), [BriefingResourceURI.worker])
        XCTAssertEqual(listed.first?.mimeType, "text/markdown")
        XCTAssertEqual(listed.first?.name, "Worker protocol")
    }

    func testAWorkerCannotReadTheOrchestratorBriefing() async throws {
        do {
            _ = try await resources.read(BriefingResourceURI.orchestrator, identity: worker)
            XCTFail("a worker read the orchestrator's briefing")
        } catch let error as ResourceError {
            XCTAssertEqual(error.uri, BriefingResourceURI.orchestrator)
            XCTAssertTrue(error.message.contains(BriefingResourceURI.worker), "the refusal did not name the worker's own uri")
        }
    }

    // MARK: The orchestrator briefing

    func testTheOrchestratorBriefingIsByteIdenticalToTheTextALaunchComposes() async throws {
        let project = try XCTUnwrap(f.projects.get(f.project.id))
        let served = try await read(BriefingResourceURI.orchestrator, as: f.orchestratorIdentity)
        XCTAssertEqual(served, OrchestratorPrompt.systemPrompt(project: project))
    }

    /// The point of serving this rather than capturing a copy: an orchestrator that compacts after
    /// the human changes a setting must read back what the project says now, not what it said at
    /// launch. A stale briefing is worse than none.
    func testTheBriefingIsComposedAtFetchTimeFromCurrentProjectSettings() async throws {
        try setSettings { $0.defaultModel = "claude-sonnet-5" }
        let before = try await read(BriefingResourceURI.orchestrator, as: f.orchestratorIdentity)
        XCTAssertTrue(before.contains("Workers run on `claude-sonnet-5`"), before)

        try setSettings { $0.defaultModel = "claude-opus-5" }
        let after = try await read(BriefingResourceURI.orchestrator, as: f.orchestratorIdentity)

        XCTAssertNotEqual(before, after, "the briefing did not change when the project's settings did")
        XCTAssertTrue(after.contains("Workers run on `claude-opus-5`"), after)
        XCTAssertFalse(after.contains("claude-sonnet-5"), "the briefing still carries the old default model")
    }

    func testModelGuidanceTheHumanAddsAfterLaunchReachesTheServedBriefing() async throws {
        let before = try await read(BriefingResourceURI.orchestrator, as: f.orchestratorIdentity)
        XCTAssertFalse(before.contains("Model guidance from the human"))

        try setSettings { $0.modelGuidance = "Use Haiku for anything mechanical." }
        let after = try await read(BriefingResourceURI.orchestrator, as: f.orchestratorIdentity)

        XCTAssertTrue(after.contains("## Model guidance from the human"), after)
        XCTAssertTrue(after.contains("Use Haiku for anything mechanical."), after)
    }

    func testTheBriefingTellsTheOrchestratorWhereToReadItBack() async throws {
        let served = try await read(BriefingResourceURI.orchestrator, as: f.orchestratorIdentity)
        XCTAssertTrue(served.contains(BriefingResourceURI.orchestrator), "the briefing does not name its own uri")
    }

    func testAnOrchestratorListsItsBriefingAndNotTheWorkerProtocol() async throws {
        let listed = try await resources.resources(for: f.orchestratorIdentity)
        XCTAssertEqual(listed.map(\.uri), [BriefingResourceURI.orchestrator])
        XCTAssertEqual(listed.first?.name, "Orchestrator briefing")
    }

    // MARK: Routing

    func testAnUnknownBriefingUriIsRefusedRatherThanServed() async throws {
        do {
            _ = try await resources.read("briefing://something-else", identity: worker)
            XCTFail("an unknown briefing uri was served")
        } catch let error as ResourceError {
            XCTAssertEqual(error.uri, "briefing://something-else")
        }
    }

    func testNotesAndBriefingsAreBothServedThroughTheCompositeHandler() async throws {
        let note = try f.note("Build gotchas", sections: [("The trap", "merge then compile")])
        let composite = CompositeResourceHandler([
            (NoteResourceURI.scheme, NoteResourceHandler(db: f.db)),
            (BriefingResourceURI.scheme, BriefingResourceHandler(db: f.db)),
        ])

        let listed = try await composite.resources(for: worker)
        XCTAssertEqual(
            Set(listed.map(\.uri)),
            [NoteResourceURI.uri(projectId: f.project.id, noteId: note.id), BriefingResourceURI.worker]
        )

        let protocolText = try await composite.read(BriefingResourceURI.worker, identity: worker)
        XCTAssertEqual(protocolText.first?.text, OpeningPrompt.workingProtocol(branch: "agentboard/\(taskId!)"))

        let noteText = try await composite.read(
            NoteResourceURI.uri(projectId: f.project.id, noteId: note.id), identity: worker
        )
        XCTAssertTrue(try XCTUnwrap(noteText.first).text.contains("merge then compile"))
    }

    func testAUriInNoServedSchemeNamesTheSchemesThatAreServed() async throws {
        let composite = CompositeResourceHandler([
            (NoteResourceURI.scheme, NoteResourceHandler(db: f.db)),
            (BriefingResourceURI.scheme, BriefingResourceHandler(db: f.db)),
        ])
        do {
            _ = try await composite.read("file:///etc/passwd", identity: worker)
            XCTFail("a foreign scheme was routed somewhere")
        } catch let error as ResourceError {
            XCTAssertTrue(error.message.contains("note://"), error.message)
            XCTAssertTrue(error.message.contains("briefing://"), error.message)
        }
    }
}
