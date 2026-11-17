import AgentBoardBridge
import AgentBoardCore
import AgentBoardServer
import Foundation
import XCTest

/// The reviewer scope: enough authority to move one task out of `review`, and nothing else.
final class ReviewScopeTests: XCTestCase {
    private var f: BridgeFixture!
    private var task: BoardTask!
    private var worker: TokenIdentity!

    override func setUpWithError() throws {
        f = try BridgeFixture.make()
        task = try f.task("ship search", column: .ready)
        try f.board.assign(
            taskId: task.id,
            session: AgentSession(
                sessionId: "s1", shortId: "alpha", projectId: f.project.id, taskId: task.id, role: .worker,
                worktreePath: "/wt/\(task.id)", branch: "agentboard/\(task.id)", cwd: "/wt/\(task.id)", state: .running
            )
        )
        worker = f.workerIdentity(sessionId: "s1", taskId: task.id)
    }

    private func reportComplete() async throws -> ToolResult {
        try await f.call(
            "report_complete",
            [
                "summary": .string("Wrote the query layer."),
                "files_changed": .array([.string("Sources/Search.swift")]),
                "tests_run": .string("swift test"),
                "caveats": .string("none"),
            ],
            as: worker
        )
    }

    /// A reviewer that has been spawned onto the task the way agent review leaves it.
    private func reviewerOnTask() async throws -> TokenIdentity {
        try f.session("rev-1", state: .running, taskId: task.id)
        return f.reviewerIdentity(sessionId: "rev-1", taskId: task.id)
    }

    // MARK: The scope boundary

    func testTheReviewerScopeIsFiveToolsAndHasNoSpawnOrReassign() async {
        let names = Set(await f.scoped.tools(for: f.reviewerIdentity(sessionId: "rev-1", taskId: task.id)).map(\.name))
        XCTAssertEqual(names, ["get_my_task", "log_progress", "add_comment", "accept_task", "reopen_task"])
        for forbidden in ["spawn_worker", "assign_to_agent", "move_task", "create_task", "update_task",
                          "list_tasks", "set_deps", "stop_worker", "promote_proposal", "request_integration",
                          "hand_off", "report_complete", "propose_task"] {
            XCTAssertFalse(names.contains(forbidden), forbidden)
        }
    }

    func testAcceptAndReopenAreNotInTheWorkerOrOrchestratorScope() async {
        let workerTools = await f.scoped.tools(for: worker).map(\.name)
        let orchestratorTools = await f.scoped.tools(for: f.orchestratorIdentity).map(\.name)
        for tool in ["accept_task", "reopen_task"] {
            XCTAssertFalse(workerTools.contains(tool), tool)
            XCTAssertFalse(orchestratorTools.contains(tool), tool)
        }
    }

    func testAReviewerCannotSpawnAWorkerEvenByNamingTheTool() async throws {
        let reviewer = try await reviewerOnTask()
        await XCTAssertThrowsErrorAsync(try await f.call("spawn_worker", ["task_id": .string(self.task.id)], as: reviewer))
        let spawned = await f.control.spawned
        XCTAssertTrue(spawned.isEmpty)
    }

    func testAReviewerCannotTouchATaskItWasNotGiven() async throws {
        let other = try f.task("someone else's work", column: .review)
        try f.session("rev-1", state: .running, taskId: other.id)
        // The token is bound to `task`; naming the other task in the arguments changes nothing,
        // because every call reads the id off the identity.
        let reviewer = f.reviewerIdentity(sessionId: "rev-1", taskId: task.id)
        _ = try await reportComplete()

        _ = try await f.call(
            "accept_task", ["verdict": .string("fine"), "task_id": .string(other.id)], as: reviewer
        )

        XCTAssertEqual(try f.tasks.get(other.id)?.column, .review, "the untouched task must not move")
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .done)
    }

    func testATokenWithNoTaskAndOneFromAnotherProjectAreBothRefused() async throws {
        await XCTAssertThrowsErrorAsync(
            try await f.call("get_my_task", as: self.f.reviewerIdentity(sessionId: "rev-1", taskId: nil))
        )
        let foreign = try f.otherProject()
        let foreignTask = try f.task("not ours", column: .review, in: foreign.id)
        let identity = TokenIdentity(
            token: "reviewer-x", scope: .reviewer, projectId: f.project.id,
            sessionId: "rev-1", taskId: foreignTask.id
        )
        await XCTAssertThrowsErrorAsync(try await f.call("get_my_task", as: identity))
    }

    func testAReviewerCannotDecideATaskThatIsNotInReview() async throws {
        let reviewer = try await reviewerOnTask()
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)

        await XCTAssertThrowsErrorAsync(try await f.call("accept_task", ["verdict": .string("ok")], as: reviewer))
        await XCTAssertThrowsErrorAsync(try await f.call("reopen_task", ["findings": .string("no")], as: reviewer))
    }

    // MARK: Moving the task out of review

    func testAcceptTaskSendsItToDoneThroughTheOneAcceptancePath() async throws {
        try f.setReviewLevel(.agent)
        let agent = try f.rosterReviewer("Rowan")
        _ = try await reportComplete()
        XCTAssertEqual(try f.tasks.get(task.id)?.reviewerAgentId, agent.id)
        let reviewer = try await reviewerOnTask()

        _ = try await f.call(
            "accept_task",
            ["verdict": .string("Ran swift test; the empty query case is covered.")],
            as: reviewer
        )

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .done)
        let accepted = await f.control.accepted
        XCTAssertEqual(accepted.count, 1, "acceptance must go through WorkerControl.accept, not a second path")
        XCTAssertEqual(accepted.first?.taskId, task.id)
        XCTAssertEqual(accepted.first?.acceptedBy, .reviewer(
            name: "Rowan", verdict: "Ran swift test; the empty query case is covered.", sessionId: "rev-1"
        ), "the acceptance must name the reviewer's own session so the supervisor does not stop it")
    }

    func testTheVerdictIsOnTheTaskSoAHumanCanSeeWhoApprovedItAndWhy() async throws {
        try f.setReviewLevel(.agent)
        try f.rosterReviewer("Rowan")
        _ = try await reportComplete()
        let reviewer = try await reviewerOnTask()

        _ = try await f.call(
            "accept_task",
            ["verdict": .string("Ran swift test; the empty query case is covered.")],
            as: reviewer
        )

        let notes = try f.progress.list(taskId: task.id).filter { $0.kind == .note }.map(\.text)
        XCTAssertTrue(
            notes.contains { $0.contains("Rowan") && $0.contains("empty query case") },
            "expected the reviewer's verdict on the task, got \(notes)"
        )
    }

    func testReopenTaskSendsItBackToReadyWithTheFindings() async throws {
        try f.setReviewLevel(.agent)
        try f.rosterReviewer("Rowan")
        _ = try await reportComplete()
        let reviewer = try await reviewerOnTask()

        _ = try await f.call(
            "reopen_task",
            ["findings": .string("The empty query throws; see Sources/Search.swift:41.")],
            as: reviewer
        )

        let stored = try XCTUnwrap(f.tasks.get(task.id))
        XCTAssertEqual(stored.column, .ready)
        XCTAssertFalse(stored.failed)
        XCTAssertNil(stored.reviewerAgentId)
        let accepted = await f.control.accepted
        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(try f.progress.list(taskId: task.id).contains { $0.text.contains("Sources/Search.swift:41") })
    }

    // MARK: Review rounds

    /// A reviewer `rev-<round>` spawned onto the task, which is in `review` again.
    private func reviewer(round: Int) throws -> TokenIdentity {
        if try f.tasks.get(task.id)?.column != .review { try f.tasks.move(task.id, to: .review) }
        try f.session("rev-\(round)", state: .running, taskId: task.id)
        return f.reviewerIdentity(sessionId: "rev-\(round)", taskId: task.id)
    }

    private func grade(_ finding: Int, _ grade: String = "not_fixed") -> JSONValue {
        .object([
            "finding": .number(Double(finding)), "grade": .string(grade),
            "evidence": .string("Sources/Search.swift:41 still throws."),
        ])
    }

    func testTheReopenThatReachesTheRoundCapLeavesTheTaskInReviewForAPerson() async throws {
        try f.setReviewLevel(.agent)
        _ = try await reportComplete()
        _ = try await f.call("reopen_task", ["findings": .array([.string("The empty query throws.")])], as: try reviewer(round: 1))
        _ = try await f.call(
            "reopen_task",
            ["findings": .array([.string("The empty query still throws.")]), "grades": .array([grade(1)])],
            as: try reviewer(round: 2)
        )
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready, "a reopen below the cap goes back to ready as before")

        let answer = try await f.call(
            "reopen_task",
            ["findings": .array([.string("Round three: the empty query throws.")]), "grades": .array([grade(1, "partly_fixed")])],
            as: try reviewer(round: 3)
        )

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review, answer.text)
        let progress = try f.progress.list(taskId: task.id)
        XCTAssertTrue(progress.contains {
            $0.text.hasPrefix(Board.reviewRoundCapLead) && $0.text.contains("Round three: the empty query throws.")
        }, "\(progress.map(\.text))")
        XCTAssertTrue(progress.contains { $0.text.contains("Finding 1: partly_fixed") }, "the grading is on the task")
        let decisions = try f.reports.unconsumed(projectId: f.project.id).filter { $0.kind == .decision }
        XCTAssertTrue(decisions.contains { $0.body.hasPrefix(Board.reviewRoundCapLead) }, "\(decisions.map(\.body))")
        let notified = await f.events.events.contains {
            if case .notify(_, let title, let body) = $0 { return title == Board.reviewRoundCapLead && body.contains("Round three") }
            return false
        }
        XCTAssertTrue(notified)
    }

    func testARereviewThatLeavesAPreviousFindingUngradedIsRefused() async throws {
        try f.setReviewLevel(.agent)
        _ = try await reportComplete()
        _ = try await f.call(
            "reopen_task",
            ["findings": .array([.string("The empty query throws."), .string("No test covers paging.")])],
            as: try reviewer(round: 1)
        )
        let second = try reviewer(round: 2)

        let refused = await refusal(of: try await f.call(
            "accept_task", ["verdict": .string("Fixed."), "grades": .array([grade(1, "fixed")])], as: second
        ))

        XCTAssertTrue(refused.contains("finding 2"), refused)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        let accepted = await f.control.accepted
        XCTAssertTrue(accepted.isEmpty)
    }

    private func refusal(of call: @autoclosure () async throws -> ToolResult) async -> String {
        do {
            return "answered: " + (try await call()).text
        } catch let error as ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// SPEC §5.1: the reviewer's inputs are the task and the diff — no worker report, no progress, no notes.
    func testTheReviewerGetsTheTaskButNoWorkerReportProgressOrNotes() async throws {
        try f.setReviewLevel(.agent)
        try f.rosterReviewer("Rowan")
        _ = try await f.call("log_progress", ["text": .string("Worker aside: the cache is safe.")], as: worker)
        _ = try await reportComplete()
        let reviewer = try await reviewerOnTask()
        let note = try f.note("Search internals", sections: [(heading: "Cache", body: "Invalidated on write.")])

        let result = try await f.call("get_my_task", as: reviewer)

        XCTAssertTrue(result.text.contains(task.id), result.text)
        for leaked in ["Wrote the query layer.", "Worker aside"] {
            XCTAssertFalse(result.text.contains(leaked), leaked)
        }
        let resources = NoteResourceHandler(db: f.db)
        let listed = try await resources.resources(for: reviewer)
        XCTAssertEqual(listed.map(\.uri), [])
        await XCTAssertThrowsErrorAsync(
            try await resources.read(NoteResourceHandler.uri(projectId: self.f.project.id, noteId: note.id), identity: reviewer)
        )
    }

    // MARK: report_complete under each level

    func testTaskReviewLeavesTheTaskInReviewAndNeverAccepts() async throws {
        try f.setReviewLevel(.task)

        let result = try await reportComplete()

        XCTAssertTrue(result.text.contains("now in Review"), result.text)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        let accepted = await f.control.accepted
        XCTAssertTrue(accepted.isEmpty)
    }

    func testNoReviewAcceptsThroughTheSameCallTheAcceptButtonMakes() async throws {
        try f.setReviewLevel(.none)

        let result = try await reportComplete()

        XCTAssertTrue(result.text.contains("straight to Done"), result.text)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .done)
        let accepted = await f.control.accepted
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.acceptedBy, .policy(.none))
    }

    func testAgentReviewParksTheTaskOnTheRosteredReviewerRatherThanAccepting() async throws {
        try f.setReviewLevel(.agent)
        let agent = try f.rosterReviewer("Rowan")

        _ = try await reportComplete()

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertEqual(try f.tasks.get(task.id)?.reviewerAgentId, agent.id)
        let accepted = await f.control.accepted
        XCTAssertTrue(accepted.isEmpty)
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "expected an error",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {}
}
