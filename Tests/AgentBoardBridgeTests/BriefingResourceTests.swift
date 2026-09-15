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
        try f.worktreeSession("s1", taskId: task.id)
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

    /// Against the branch the session row actually carries, not a second computation of
    /// `agentboard/<task-id>`: the bug this replaced was that the resource and its test derived the
    /// branch the same way, so both were wrong together for a shared-checkout worker and the test
    /// still passed.
    func testTheWorkerProtocolResourceIsByteIdenticalToTheTextASpawnComposes() async throws {
        let session = try XCTUnwrap(f.sessions.get("s1"))
        let recorded = try XCTUnwrap(session.branch)
        let served = try await read(BriefingResourceURI.worker, as: worker)

        XCTAssertEqual(
            served,
            OpeningPrompt.workingProtocol(branch: recorded, placement: .worktree, workingDirectory: session.cwd)
        )
    }

    func testTheProtocolIsRenderedForTheCallersOwnBranch() async throws {
        let other = try f.task("other", column: .running)
        try f.worktreeSession("s2", taskId: other.id)
        let served = try await read(BriefingResourceURI.worker, as: f.workerIdentity(sessionId: "s2", taskId: other.id))

        XCTAssertTrue(served.contains("agentboard/\(other.id)"), "the protocol named someone else's branch")
        XCTAssertFalse(served.contains(taskId), "the protocol named someone else's branch")
    }

    // MARK: Which branch the worker is actually on

    func testAWorktreeWorkerIsServedItsOwnTaskBranch() async throws {
        let served = try await read(BriefingResourceURI.worker, as: worker)

        XCTAssertTrue(served.contains("`agentboard/\(taskId!)`"), served)
        XCTAssertTrue(served.contains("dedicated git worktree"), served)
        XCTAssertFalse(served.contains(SharedCheckoutGroup.branchPrefix), served)
    }

    /// A shared branch is cut once per base and its name carries that base, so a co-resident worker
    /// is never on `agentboard/<task-id>`. Telling it to commit there names a branch that does not
    /// exist and, if it did, is not the one under its feet.
    func testASharedCheckoutWorkerIsServedTheSharedBranchItIsStandingOn() async throws {
        let epic = try f.epic("Shared work")
        let task = try f.task("co-resident", column: .running, epicId: epic.id)
        let shared = SharedCheckoutGroup.branch(epicId: epic.id)
        try f.sharedSession("s-shared", taskId: task.id, branch: shared)

        let served = try await read(
            BriefingResourceURI.worker, as: f.workerIdentity(sessionId: "s-shared", taskId: task.id)
        )

        XCTAssertTrue(served.contains("`\(shared)`"), served)
        XCTAssertFalse(
            served.contains("agentboard/\(task.id)"),
            "the protocol named the task-id branch, which a shared-checkout worker is not on"
        )
    }

    /// The branch is only half of what the placement decides; a shared worker that follows the
    /// worktree closeout runs `git commit`, which the checkout refuses.
    func testASharedCheckoutWorkerIsServedTheSharedCheckoutProtocolAndNotTheWorktreeOne() async throws {
        let task = try f.task("co-resident", column: .running)
        try f.sharedSession("s-shared", taskId: task.id)

        let served = try await read(
            BriefingResourceURI.worker, as: f.workerIdentity(sessionId: "s-shared", taskId: task.id)
        )

        XCTAssertTrue(served.contains("commit_my_work"), served)
        XCTAssertTrue(served.contains("This is not a worktree of your own"), served)
        XCTAssertFalse(served.contains("dedicated git worktree"), served)
    }

    /// The resource is read back after a compaction, when the session has been resumed and the
    /// token is bound to the resumed session rather than the setup row.
    func testTheProtocolFollowsTheSessionTheTokenIsBoundTo() async throws {
        let task = try f.task("moved", column: .running)
        try f.worktreeSession("isolated", taskId: task.id)
        try f.sharedSession("co-resident", taskId: task.id, branch: "agentboard/shared-epic-abc")

        let isolated = try await read(
            BriefingResourceURI.worker, as: f.workerIdentity(sessionId: "isolated", taskId: task.id)
        )
        let coResident = try await read(
            BriefingResourceURI.worker, as: f.workerIdentity(sessionId: "co-resident", taskId: task.id)
        )

        XCTAssertTrue(isolated.contains("`agentboard/\(task.id)`"), isolated)
        XCTAssertTrue(coResident.contains("`agentboard/shared-epic-abc`"), coResident)
        XCTAssertNotEqual(isolated, coResident)
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

        let session = try XCTUnwrap(f.sessions.get("s1"))
        let protocolText = try await composite.read(BriefingResourceURI.worker, identity: worker)
        XCTAssertEqual(
            protocolText.first?.text,
            OpeningPrompt.workingProtocol(
                branch: try XCTUnwrap(session.branch), placement: .worktree, workingDirectory: session.cwd
            )
        )

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
