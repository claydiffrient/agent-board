import Foundation
import XCTest
@testable import AgentBoardCore

/// §5: where a completed task lands is the project's review level's decision, or its epic's if the
/// epic overrides it.
final class ReviewLevelTests: XCTestCase {
    private var f: Fixture!

    override func setUpWithError() throws {
        f = try Fixture.make()
    }

    private func setProjectLevel(_ level: ReviewLevel, in fixture: Fixture? = nil) throws {
        let fixture = fixture ?? f!
        var settings = try XCTUnwrap(fixture.projects.get(fixture.project.id)).settings
        settings.reviewLevel = level
        try fixture.projects.updateSettings(fixture.project.id, settings)
    }

    private func setArchivePolicy(_ policy: ArchivePolicy, in fixture: Fixture? = nil) throws {
        let fixture = fixture ?? f!
        var settings = try XCTUnwrap(fixture.projects.get(fixture.project.id)).settings
        settings.archivePolicy = policy
        try fixture.projects.updateSettings(fixture.project.id, settings)
    }

    private func complete(_ task: BoardTask, session: String = "w1") throws -> Board.CompletionOutcome {
        try f.board.assign(taskId: task.id, session: f.session(session, state: .running, taskId: task.id))
        return try f.board.complete(taskId: task.id, sessionId: session, summary: "done")
    }

    /// The session a rostered reviewer runs in once it has been spawned onto a task in `review`.
    @discardableResult
    private func reviewerSession(_ id: String, on task: BoardTask) throws -> AgentSession {
        let session = f.session(id, state: .running, taskId: task.id)
        try f.sessions.insert(session)
        return session
    }

    @discardableResult
    private func reviewer(_ name: String, role: String = "reviewer", enabled: Bool = true) throws -> RosterAgent {
        let agent = try RosterStore(f.db).create(
            name: name, role: role, systemPrompt: "You review.", enabled: enabled
        )
        try RosterStore(f.db).enable(agentId: agent.id, forProject: f.project.id)
        return agent
    }

    // MARK: The setting itself

    func testTaskReviewIsTheDefaultSoAnExistingProjectIsUnchanged() throws {
        XCTAssertEqual(ProjectSettings().reviewLevel, .task)
        XCTAssertEqual(ProjectSettings.decode("{}").reviewLevel, .task)
        XCTAssertEqual(ProjectSettings.forNewProject().reviewLevel, .task)
        XCTAssertEqual(try XCTUnwrap(f.projects.get(f.project.id)).settings.reviewLevel, .task)
    }

    func testTheLevelSurvivesAnEncodeDecodeRoundTrip() throws {
        for level in ReviewLevel.allCases {
            var settings = ProjectSettings()
            settings.reviewLevel = level
            XCTAssertEqual(ProjectSettings.decode(settings.encoded()).reviewLevel, level)
        }
    }

    // MARK: Routing

    func testTaskReviewLeavesTheTaskForAHuman() throws {
        try setProjectLevel(.task)
        let task = try f.task("write the parser", column: .ready)

        let outcome = try complete(task)

        XCTAssertEqual(outcome.routing, .humanReview(reason: nil))
        XCTAssertFalse(outcome.autoAccept)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
    }

    func testNoReviewAsksTheCallerToAcceptAndTheAcceptLandsItInDone() throws {
        try setProjectLevel(.none)
        let task = try f.task("rename a symbol", column: .ready)

        let outcome = try complete(task)
        XCTAssertTrue(outcome.autoAccept)
        XCTAssertEqual(outcome.level, .none)

        try f.board.accept(taskId: task.id, acceptedBy: .policy(outcome.level))
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .done)
    }

    func testAgentReviewHandsTheTaskToARosteredReviewerAndSaysSoOnTheCard() throws {
        try setProjectLevel(.agent)
        let agent = try reviewer("Rowan")
        let task = try f.task("write the parser", column: .ready)

        let outcome = try complete(task)

        XCTAssertEqual(outcome.routing, .agentReview(agentId: agent.id, agentName: "Rowan"))
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertEqual(try f.tasks.get(task.id)?.reviewerAgentId, agent.id)
        let rows = try f.progress.list(taskId: task.id).map(\.text)
        XCTAssertTrue(rows.contains { $0.contains("Rowan") }, "\(rows)")
    }

    func testAgentReviewWithNoRosteredReviewerFallsBackToAHumanAndRecordsWhy() throws {
        try setProjectLevel(.agent)
        try reviewer("Dana", role: "frontend")
        let task = try f.task("write the parser", column: .ready)

        let outcome = try complete(task)

        guard case .humanReview(let reason) = outcome.routing else {
            return XCTFail("expected human review, got \(outcome.routing)")
        }
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)
        XCTAssertNil(try f.tasks.get(task.id)?.reviewerAgentId)
        let explained = try XCTUnwrap(reason)
        XCTAssertTrue(explained.contains("no rostered agent"), explained)
        XCTAssertTrue(try f.progress.list(taskId: task.id).contains { $0.text.contains("no rostered agent") })
    }

    func testADisabledOrUnselectedReviewerIsNotUsable() throws {
        try setProjectLevel(.agent)
        let disabled = try RosterStore(f.db).create(name: "Off", role: "reviewer", systemPrompt: "x", enabled: false)
        try RosterStore(f.db).enable(agentId: disabled.id, forProject: f.project.id)
        // On the roster and a reviewer, but this project never opted into it.
        try RosterStore(f.db).create(name: "Elsewhere", role: "reviewer", systemPrompt: "x")
        let task = try f.task("write the parser", column: .ready)

        let outcome = try complete(task)

        guard case .humanReview = outcome.routing else {
            return XCTFail("expected human review, got \(outcome.routing)")
        }
        XCTAssertEqual(try RosterStore(f.db).reviewers(forProject: f.project.id).count, 0)
    }

    func testARoleReadingAsAReviewerCountsWhateverItsCasing() throws {
        for role in ["reviewer", "Reviewer", "code reviewer", "REVIEW"] {
            XCTAssertTrue(
                RosterAgent(id: "a", name: "n", role: role, systemPrompt: "p", createdAt: 0, updatedAt: 0).isReviewer,
                role
            )
        }
        for role in ["frontend", "integrator", "go"] {
            XCTAssertFalse(
                RosterAgent(id: "a", name: "n", role: role, systemPrompt: "p", createdAt: 0, updatedAt: 0).isReviewer,
                role
            )
        }
    }

    // MARK: Epic override

    func testAnEpicOverrideBeatsTheProjectSetting() throws {
        try setProjectLevel(.task)
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Parser", goal: nil)
        try EpicStore(f.db).setReviewLevel(epic.id, ReviewLevel.none)
        let task = try f.tasks.create(
            projectId: f.project.id, title: "lexer", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: epic.id
        )

        XCTAssertTrue(try complete(task).autoAccept, "the epic's no-review should beat the project's task review")
    }

    func testAnEpicWithoutAnOverrideInheritsTheProjectSetting() throws {
        try setProjectLevel(.none)
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Parser", goal: nil)
        XCTAssertNil(try EpicStore(f.db).get(epic.id)?.reviewLevel)
        let task = try f.tasks.create(
            projectId: f.project.id, title: "lexer", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: epic.id
        )

        XCTAssertTrue(try complete(task).autoAccept)
    }

    func testClearingAnEpicOverrideGoesBackToInheriting() throws {
        try setProjectLevel(.task)
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Parser", goal: nil)
        try EpicStore(f.db).setReviewLevel(epic.id, ReviewLevel.none)
        try EpicStore(f.db).setReviewLevel(epic.id, nil)
        let task = try f.tasks.create(
            projectId: f.project.id, title: "lexer", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: epic.id
        )

        XCTAssertFalse(try complete(task).autoAccept)
    }

    func testEpicReviewAcceptsATaskInsideAnEpicAndHoldsOneOutsideOneForAHuman() throws {
        try setProjectLevel(.epic)
        let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Parser", goal: nil)
        let inEpic = try f.tasks.create(
            projectId: f.project.id, title: "lexer", body: nil, acceptance: nil, priority: nil,
            column: .ready, origin: .human, epicId: epic.id
        )
        let standalone = try f.task("unrelated chore", column: .ready)

        XCTAssertTrue(try complete(inEpic, session: "w1").autoAccept)

        let outcome = try complete(standalone, session: "w2")
        XCTAssertFalse(outcome.autoAccept)
        guard case .humanReview(let reason) = outcome.routing else {
            return XCTFail("expected human review, got \(outcome.routing)")
        }
        let explained = try XCTUnwrap(reason)
        XCTAssertTrue(explained.contains("no epic"), explained)
    }

    // MARK: The epic's own integration gate (SPEC §5.2)

    /// Two independent axes decide where a completed integration task lands, and only the review
    /// level is this suite's subject. The level never routes it to an agent or auto-accepts it — that
    /// is §5's unconditional override. The column is the archive policy's call: `afterEpicMerge`
    /// (the default) sends it to `done` because the epic reaching `done` in the same transaction is
    /// its acceptance (§5.2 step 4); every other policy leaves it in `review`.
    func testAnEpicIntegrationTaskWaitsForAHumanAtEveryLevel() throws {
        for level in ReviewLevel.allCases {
            for policy in [ArchivePolicy.manual, .afterDays(7), .afterEpicMerge] {
                let f = try Fixture.make()
                try setProjectLevel(level, in: f)
                try setArchivePolicy(policy, in: f)
                _ = try RosterStore(f.db).create(name: "Rowan", role: "reviewer", systemPrompt: "x")
                try RosterStore(f.db).enable(
                    agentId: try XCTUnwrap(RosterStore(f.db).list().first).id, forProject: f.project.id
                )
                let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Parser", goal: nil)
                try EpicStore(f.db).setState(epic.id, .integrating)
                let integration = try f.tasks.create(
                    projectId: f.project.id, title: "Integrate Parser", body: nil, acceptance: nil, priority: nil,
                    column: .ready, origin: .integration, epicId: epic.id
                )
                try f.board.assign(
                    taskId: integration.id, session: f.session("i1", state: .running, taskId: integration.id)
                )

                let outcome = try f.board.complete(taskId: integration.id, sessionId: "i1", summary: "merged")
                let where_ = "level \(level), policy \(policy)"

                XCTAssertEqual(outcome.routing, .humanReview(reason: nil), where_)
                XCTAssertEqual(
                    try f.tasks.get(integration.id)?.column,
                    policy == .afterEpicMerge ? .done : .review,
                    where_
                )
                XCTAssertNil(try f.tasks.get(integration.id)?.reviewerAgentId, where_)
            }
        }
    }

    func testRequestingIntegrationStillCreatesAHumanApprovalAtEveryLevel() throws {
        for level in ReviewLevel.allCases {
            let f = try Fixture.make()
            var settings = try XCTUnwrap(f.projects.get(f.project.id)).settings
            settings.reviewLevel = level
            settings.autonomyEnabled = true
            try f.projects.updateSettings(f.project.id, settings)
            let epic = try EpicStore(f.db).create(projectId: f.project.id, title: "Parser", goal: nil)
            try EpicStore(f.db).setReviewLevel(epic.id, level)

            let approval = try f.board.requestIntegration(epicId: epic.id, requestedBy: "orch")

            XCTAssertEqual(approval.kind, .integration, "level \(level)")
            XCTAssertNil(approval.resolvedAt, "level \(level): integration must wait on a person")
            XCTAssertNil(approval.resolution, "level \(level)")
        }
    }

    // MARK: A reviewer's verdict on the record

    func testAcceptingAfterAgentReviewNamesTheReviewerOnTheTaskAndInTheReport() throws {
        try setProjectLevel(.agent)
        try reviewer("Rowan")
        let task = try f.task("write the parser", column: .ready)
        try complete(task)
        try reviewerSession("rev-1", on: task)

        try f.board.recordReviewVerdict(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan",
            verdict: "Ran swift test; the parser handles the empty input case."
        )
        try f.board.accept(
            taskId: task.id,
            acceptedBy: .reviewer(name: "Rowan", verdict: "Ran swift test; the parser handles the empty input case.")
        )

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .done)
        let notes = try f.progress.list(taskId: task.id).filter { $0.kind == .note }.map(\.text)
        XCTAssertTrue(notes.contains { $0.contains("Rowan") && $0.contains("empty input case") }, "\(notes)")
        let decision = try XCTUnwrap(
            f.reports.unconsumed(projectId: f.project.id).first { $0.kind == .decision }
        )
        XCTAssertTrue(decision.body.contains("rostered reviewer Rowan"), decision.body)
        XCTAssertTrue(decision.body.contains("empty input case"), decision.body)
    }

    func testAReviewerReopenPutsTheFindingsOnTheTaskAndReturnsItToReady() throws {
        try setProjectLevel(.agent)
        try reviewer("Rowan")
        let task = try f.task("write the parser", column: .ready)
        try complete(task)
        try reviewerSession("rev-1", on: task)

        let report = try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan",
            findings: "The empty input case throws; see Parser.swift:41."
        )

        XCTAssertEqual(try f.tasks.get(task.id)?.column, .ready)
        XCTAssertNil(try f.tasks.get(task.id)?.reviewerAgentId)
        XCTAssertFalse(try XCTUnwrap(f.tasks.get(task.id)).failed, "a reopen is not a failure")
        XCTAssertTrue(report.body.contains("Parser.swift:41"), report.body)
        XCTAssertTrue(try f.progress.list(taskId: task.id).contains { $0.text.contains("Parser.swift:41") })
    }

    func testAReviewerCannotDecideATaskThatIsNotInReview() throws {
        let task = try f.task("write the parser", column: .ready)

        XCTAssertThrowsError(try f.board.recordReviewVerdict(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan", verdict: "fine"
        ))
        XCTAssertThrowsError(try f.board.reviewReopen(
            taskId: task.id, sessionId: "rev-1", reviewerName: "Rowan", findings: "nope"
        ))
    }
}
