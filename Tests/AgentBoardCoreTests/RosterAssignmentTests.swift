import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

/// The `roster_assignment` migration and what it makes possible: a session and a task that can both
/// say which rostered identity is on them.
final class RosterAssignmentSchemaTests: XCTestCase {
    private func columns(_ db: AppDatabase, of table: String) throws -> [String] {
        try db.reader.read { try $0.columns(in: table).map(\.name) }
    }

    func testAFreshDatabaseEndsWithBothRosterTablesAndBothAssignmentColumns() throws {
        let f = try Fixture.make()

        let applied = try f.db.writer.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        XCTAssertTrue(applied.contains("roster_assignment"))
        // `appliedIdentifiers` is a Set; registration order is what decides a fresh database, and
        // the ALTERs are invalid before the CREATE that roster carries.
        let registered = AppDatabase.migrator.migrations
        let roster = try XCTUnwrap(registered.firstIndex(of: "roster"))
        let assignment = try XCTUnwrap(registered.firstIndex(of: "roster_assignment"))
        XCTAssertLessThan(roster, assignment, "roster_assignment alters tables roster creates")

        XCTAssertTrue(try columns(f.db, of: "project_roster_agent").contains("ordering"))
        XCTAssertTrue(try columns(f.db, of: "roster_agent").contains("disallowed_tools"))
        XCTAssertFalse(try columns(f.db, of: "roster_agent").contains("tool_scope"))
        XCTAssertTrue(try columns(f.db, of: "agent_session").contains("roster_agent_id"))
        XCTAssertTrue(try columns(f.db, of: "task").contains("roster_agent_id"))
    }

    /// `a489688d` carried a second `shutdown_order` migration over a table main already ships with a
    /// different shape. It can never run, so it must not be here.
    func testShutdownOrderIsRegisteredExactlyOnce() {
        XCTAssertEqual(AppDatabase.migrator.migrations.filter { $0 == "shutdown_order" }.count, 1)
    }

    func testAnEmptyDisallowedListIsTheDefaultAndSurvivesARoundTrip() throws {
        let f = try Fixture.make()
        let agent = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        XCTAssertEqual(agent.disallowedTools, [])
        XCTAssertEqual(try f.roster.get(agent.id)?.disallowedTools, [])

        let narrowed = try f.roster.create(
            name: "Bee", role: "docs", systemPrompt: "p", disallowedTools: ["Bash", "Edit"]
        )
        XCTAssertEqual(try f.roster.get(narrowed.id)?.disallowedTools, ["Bash", "Edit"])
    }
}

final class RosterAssignmentTests: XCTestCase {
    private func agent(_ f: Fixture, name: String = "Ada", role: String = "frontend") throws -> RosterAgent {
        let agent = try f.roster.create(name: name, role: role, systemPrompt: "You own the front end.")
        try f.roster.enable(agentId: agent.id, forProject: f.project.id)
        return agent
    }

    func testAssignWritesTheRosterAgentOntoTheTaskAndTheSession() throws {
        let f = try Fixture.make()
        let ada = try agent(f)
        let task = try f.task("ship search", column: .ready)

        var row = f.session("s1", state: .setup, taskId: task.id)
        row.rosterAgentId = ada.id
        let recorded = try f.board.assign(taskId: task.id, session: row)

        XCTAssertEqual(recorded.rosterAgentId, ada.id)
        XCTAssertTrue(recorded.isRostered)
        XCTAssertEqual(try f.tasks.get(task.id)?.rosterAgentId, ada.id)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .running)
    }

    /// An anonymous worker leaves whoever was last on the task in place, so the card still says who
    /// did the previous pass.
    func testAnAnonymousWorkerDoesNotClearAPreviousAgent() throws {
        let f = try Fixture.make()
        let ada = try agent(f)
        let task = try f.task("ship search", column: .ready)

        var rostered = f.session("s1", state: .setup, taskId: task.id)
        rostered.rosterAgentId = ada.id
        try f.board.assign(taskId: task.id, session: rostered)
        try f.board.handOff(
            taskId: task.id, sessionId: "s1", summary: "did my half", nextRole: nil, filesChanged: []
        )

        try f.board.assign(taskId: task.id, session: f.session("s2", state: .setup, taskId: task.id))

        XCTAssertEqual(try f.tasks.get(task.id)?.rosterAgentId, ada.id)
    }

    func testUsableAgentRefusesADisabledAgentAndOneAnotherProjectOwns() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try agent(f)

        XCTAssertEqual(try f.roster.usableAgent(ada.id, forProject: f.project.id)?.id, ada.id)
        XCTAssertNil(try f.roster.usableAgent(ada.id, forProject: other.id))
        XCTAssertNil(try f.roster.usableAgent("no-such-agent", forProject: f.project.id))

        try f.roster.setEnabled(ada.id, false)
        XCTAssertNil(try f.roster.usableAgent(ada.id, forProject: f.project.id))
    }

    // MARK: assignReviewer

    private func completedTask(_ f: Fixture) throws -> BoardTask {
        let task = try f.task("ship search", column: .ready)
        try f.board.assign(taskId: task.id, session: f.session("worker", state: .running, taskId: task.id))
        _ = try f.board.complete(taskId: task.id, sessionId: "worker", summary: "done")
        return task
    }

    func testAssignReviewerWritesASessionAndLeavesTheTaskInReview() throws {
        let f = try Fixture.make()
        let task = try completedTask(f)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review)

        let reviewer = try agent(f, name: "Rae", role: "reviewer")
        var row = f.session("rev-1", state: .setup, taskId: task.id)
        row.rosterAgentId = reviewer.id
        let recorded = try f.board.assignReviewer(taskId: task.id, session: row)

        XCTAssertEqual(recorded.rosterAgentId, reviewer.id)
        XCTAssertEqual(recorded.state, .setup)
        XCTAssertEqual(try f.tasks.get(task.id)?.column, .review, "a review must not claim the task into running")
        // Only `assign` writes the task's agent: the reviewer is recorded in `reviewer_agent_id`.
        XCTAssertNil(try f.tasks.get(task.id)?.rosterAgentId)
    }

    func testAssignReviewerRefusesATaskThatIsNotInReview() throws {
        let f = try Fixture.make()
        let task = try f.task("ship search", column: .ready)
        XCTAssertThrowsError(
            try f.board.assignReviewer(taskId: task.id, session: f.session("rev-1", state: .setup, taskId: task.id))
        ) { error in
            XCTAssertEqual(error as? BoardError, .taskNotInReview(taskId: task.id, column: .ready))
        }
    }

    func testASecondReviewerIsRefusedWhileTheFirstIsStillActive() throws {
        let f = try Fixture.make()
        let task = try completedTask(f)
        try f.board.assignReviewer(taskId: task.id, session: f.session("rev-1", state: .setup, taskId: task.id))

        XCTAssertThrowsError(
            try f.board.assignReviewer(taskId: task.id, session: f.session("rev-2", state: .setup, taskId: task.id))
        ) { error in
            XCTAssertEqual(error as? BoardError, .taskAlreadyHeld(taskId: task.id, sessionId: "rev-1"))
        }
    }
}

final class OpeningPromptIdentityTests: XCTestCase {
    private func task(_ f: Fixture) throws -> BoardTask {
        try f.tasks.create(
            projectId: f.project.id, title: "Ship search", body: "Do it.", acceptance: "It works.",
            priority: nil, column: .ready, origin: .human, epicId: nil
        )
    }

    func testTheIdentitySectionLeadsThePromptAndCarriesTheSystemPrompt() throws {
        let f = try Fixture.make()
        let prompt = OpeningPrompt.compose(
            task: try task(f), branch: "agentboard/t1", attempt: 1,
            agent: AgentIdentity(name: "Ada", role: "frontend", systemPrompt: "You own the Lit components.")
        )

        XCTAssertTrue(prompt.hasPrefix("# You are Ada"), prompt.prefix(80).description)
        XCTAssertTrue(prompt.contains("Your specialty is frontend"))
        XCTAssertTrue(prompt.contains("You own the Lit components."))
        let identity = try XCTUnwrap(prompt.range(of: "# You are Ada"))
        let title = try XCTUnwrap(prompt.range(of: "# Task: Ship search"))
        XCTAssertLessThan(identity.lowerBound, title.lowerBound)
    }

    func testNoAgentLeavesThePromptExactlyAsItWas() throws {
        let f = try Fixture.make()
        let task = try task(f)
        XCTAssertEqual(
            OpeningPrompt.compose(task: task, branch: "agentboard/t1", attempt: 1, agent: nil),
            OpeningPrompt.compose(task: task, branch: "agentboard/t1", attempt: 1)
        )
    }

    func testAnEmptyRoleDropsTheSpecialtyClauseRatherThanNamingNothing() throws {
        let rendered = OpeningPrompt.renderIdentity(
            AgentIdentity(name: "Ada", role: "   ", systemPrompt: "p")
        )
        XCTAssertFalse(rendered.contains("Your specialty is"))
        XCTAssertTrue(rendered.contains("# You are Ada"))
    }
}
