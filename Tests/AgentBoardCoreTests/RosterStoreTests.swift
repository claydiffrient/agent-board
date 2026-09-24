import Foundation
import GRDB
import XCTest
@testable import AgentBoardCore

extension Fixture {
    var roster: RosterStore { RosterStore(db) }
}

final class RosterStoreTests: XCTestCase {
    func testCreateRoundTripsEveryColumn() throws {
        let f = try Fixture.make()
        let agent = try f.roster.create(
            name: "Ada", role: "frontend", systemPrompt: "You own the Lit components.",
            model: "claude-opus-5", disallowedTools: ["Read", "Edit"]
        )

        XCTAssertEqual(agent.name, "Ada")
        XCTAssertEqual(agent.role, "frontend")
        XCTAssertEqual(agent.systemPrompt, "You own the Lit components.")
        XCTAssertEqual(agent.model, "claude-opus-5")
        XCTAssertEqual(agent.disallowedTools, ["Read", "Edit"])
        XCTAssertTrue(agent.enabled)
        XCTAssertGreaterThan(agent.createdAt, 0)
        XCTAssertEqual(agent.updatedAt, agent.createdAt)
        XCTAssertEqual(try f.roster.get(agent.id), agent)
    }

    func testCreateDefaultsModelAndDisallowedTools() throws {
        let f = try Fixture.make()
        let agent = try f.roster.create(name: "Basic", role: "reviewer", systemPrompt: "Review.")
        XCTAssertNil(agent.model)
        XCTAssertEqual(agent.disallowedTools, [])
        XCTAssertEqual(try f.roster.get(agent.id)?.disallowedTools, [])
    }

    func testRosterIsNotScopedToAProject() throws {
        let f = try Fixture.make()
        try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")

        XCTAssertEqual(try f.roster.list().map(\.id).sorted(), [ada.id, bob.id].sorted())
    }

    func testListIsOrderedByNameCaseInsensitively() throws {
        let f = try Fixture.make()
        try f.roster.create(name: "zoe", role: "qa", systemPrompt: "p")
        try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.create(name: "bob", role: "backend", systemPrompt: "p")

        XCTAssertEqual(try f.roster.list().map(\.name), ["Ada", "bob", "zoe"])
    }

    func testGetReturnsNilForUnknownId() throws {
        let f = try Fixture.make()
        XCTAssertNil(try f.roster.get("missing"))
    }

    func testUpdateWritesEveryFieldAndBumpsUpdatedAt() throws {
        let f = try Fixture.make()
        var agent = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let createdAt = agent.createdAt
        agent.name = "Ada L."
        agent.role = "reviewer"
        agent.systemPrompt = "You hold review authority."
        agent.model = "claude-sonnet-5"
        agent.disallowedTools = ["Read"]
        agent.updatedAt = 0
        try f.roster.update(agent)

        let stored = try XCTUnwrap(try f.roster.get(agent.id))
        XCTAssertEqual(stored.name, "Ada L.")
        XCTAssertEqual(stored.role, "reviewer")
        XCTAssertEqual(stored.systemPrompt, "You hold review authority.")
        XCTAssertEqual(stored.model, "claude-sonnet-5")
        XCTAssertEqual(stored.disallowedTools, ["Read"])
        XCTAssertEqual(stored.createdAt, createdAt)
        XCTAssertGreaterThanOrEqual(stored.updatedAt, createdAt)
    }

    func testUpdateAndSetEnabledThrowForUnknownAgent() throws {
        let f = try Fixture.make()
        let ghost = RosterAgent(
            id: "missing", name: "n", role: "r", systemPrompt: "p", createdAt: 1, updatedAt: 1
        )
        XCTAssertThrowsError(try f.roster.update(ghost)) {
            XCTAssertEqual($0 as? BoardError, .rosterAgentNotFound("missing"))
        }
        XCTAssertThrowsError(try f.roster.setEnabled("missing", false)) {
            XCTAssertEqual($0 as? BoardError, .rosterAgentNotFound("missing"))
        }
    }

    func testSetEnabledTogglesTheRosterWideFlag() throws {
        let f = try Fixture.make()
        let agent = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")

        try f.roster.setEnabled(agent.id, false)
        XCTAssertEqual(try f.roster.get(agent.id)?.enabled, false)
        try f.roster.setEnabled(agent.id, true)
        XCTAssertEqual(try f.roster.get(agent.id)?.enabled, true)
    }

    func testDeleteRemovesTheAgentFromTheRoster() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")

        try f.roster.delete(ada.id)

        XCTAssertNil(try f.roster.get(ada.id))
        XCTAssertEqual(try f.roster.list().map(\.id), [bob.id])
    }

    func testDeletingAnUnknownAgentIsANoOp() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.delete("missing")
        XCTAssertEqual(try f.roster.list().map(\.id), [ada.id])
    }

    // MARK: per-project selection

    func testEnablingForOneProjectDoesNotEnableItForAnother() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")

        try f.roster.enable(agentId: ada.id, forProject: f.project.id)

        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [ada.id])
        XCTAssertEqual(try f.roster.agents(forProject: other.id), [])
        XCTAssertEqual(try f.roster.list().map(\.id), [ada.id])
    }

    func testDisablingForOneProjectLeavesTheOtherProjectAndTheRosterAlone() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        try f.roster.enable(agentId: ada.id, forProject: other.id)

        try f.roster.disable(agentId: ada.id, forProject: f.project.id)

        XCTAssertEqual(try f.roster.agents(forProject: f.project.id), [])
        XCTAssertEqual(try f.roster.agents(forProject: other.id).map(\.id), [ada.id])
        XCTAssertNotNil(try f.roster.get(ada.id))
    }

    func testEnableIsIdempotentAndKeepsThePosition() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        try f.roster.enable(agentId: bob.id, forProject: f.project.id)

        try f.roster.enable(agentId: ada.id, forProject: f.project.id)

        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [ada.id, bob.id])
    }

    func testEnableRejectsUnknownAgentAndUnknownProject() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")

        XCTAssertThrowsError(try f.roster.enable(agentId: "missing", forProject: f.project.id)) {
            XCTAssertEqual($0 as? BoardError, .rosterAgentNotFound("missing"))
        }
        XCTAssertThrowsError(try f.roster.enable(agentId: ada.id, forProject: "missing")) {
            XCTAssertEqual($0 as? BoardError, .projectNotFound("missing"))
        }
    }

    func testAgentsForProjectFollowTheProjectOrderNotTheRosterOrder() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        let cy = try f.roster.create(name: "Cy", role: "reviewer", systemPrompt: "p")
        for id in [cy.id, ada.id, bob.id] {
            try f.roster.enable(agentId: id, forProject: f.project.id)
        }

        XCTAssertEqual(try f.roster.list().map(\.id), [ada.id, bob.id, cy.id])
        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [cy.id, ada.id, bob.id])
    }

    func testSetOrderRewritesPreferenceAndIsPerProject() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        let cy = try f.roster.create(name: "Cy", role: "reviewer", systemPrompt: "p")
        for id in [ada.id, bob.id, cy.id] {
            try f.roster.enable(agentId: id, forProject: f.project.id)
            try f.roster.enable(agentId: id, forProject: other.id)
        }

        try f.roster.setOrder(forProject: f.project.id, agentIds: [cy.id, bob.id, ada.id])

        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [cy.id, bob.id, ada.id])
        XCTAssertEqual(try f.roster.agents(forProject: other.id).map(\.id), [ada.id, bob.id, cy.id])
    }

    func testSetOrderIgnoresUnlistedIdsAndAppendsTheRest() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        let cy = try f.roster.create(name: "Cy", role: "reviewer", systemPrompt: "p")
        let unused = try f.roster.create(name: "Dee", role: "qa", systemPrompt: "p")
        for id in [ada.id, bob.id, cy.id] {
            try f.roster.enable(agentId: id, forProject: f.project.id)
        }

        try f.roster.setOrder(forProject: f.project.id, agentIds: [cy.id, unused.id])

        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [cy.id, ada.id, bob.id])
    }

    func testDisabledAgentIsExcludedFromTheUsableSetButStaysInTheRoster() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        try f.roster.enable(agentId: bob.id, forProject: f.project.id)

        try f.roster.setEnabled(ada.id, false)

        XCTAssertEqual(try f.roster.usableAgents(forProject: f.project.id).map(\.id), [bob.id])
        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [ada.id, bob.id])
        XCTAssertEqual(try f.roster.list().map(\.id), [ada.id, bob.id])
        XCTAssertEqual(try f.roster.get(ada.id)?.enabled, false)
    }

    func testUsableAgentsKeepsThePerProjectOrder() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        try f.roster.enable(agentId: bob.id, forProject: f.project.id)
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)

        XCTAssertEqual(try f.roster.usableAgents(forProject: f.project.id).map(\.id), [bob.id, ada.id])
    }

    // MARK: delete leaves history intact

    func testDeleteClearsJoinRowsAndLeavesProjectsAndHistoryIntact() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        for project in [f.project.id, other.id] {
            try f.roster.enable(agentId: ada.id, forProject: project)
            try f.roster.enable(agentId: bob.id, forProject: project)
        }

        let task = try f.task("ported by Ada")
        let session = f.session(taskId: task.id)
        try f.sessions.insert(session)
        try f.progress.append(taskId: task.id, sessionId: session.sessionId, kind: .note, text: "Ada did the frontend slice")

        try f.roster.delete(ada.id)

        XCTAssertNil(try f.roster.get(ada.id))
        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [bob.id])
        XCTAssertEqual(try f.roster.agents(forProject: other.id).map(\.id), [bob.id])
        XCTAssertEqual(try f.projects.list().count, 2)
        XCTAssertNotNil(try f.projects.get(f.project.id))
        XCTAssertNotNil(try f.tasks.get(task.id))
        XCTAssertNotNil(try f.sessions.get(session.sessionId))
        XCTAssertEqual(try f.progress.list(taskId: task.id).map(\.text), ["Ada did the frontend slice"])

        let orphans = try f.db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_roster_agent WHERE roster_agent_id = ?", arguments: [ada.id])
        }
        XCTAssertEqual(orphans, 0)
    }

    func testDeleteKeepsSessionsAndTasksThatNameTheAgentAndNullsTheirReferences() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let bob = try f.roster.create(name: "Bob", role: "reviewer", systemPrompt: "p")
        let worked = try f.task("worked by Ada")
        let reviewed = try f.task("reviewed by Ada")
        let untouched = try f.task("worked by Bob")
        var session = f.session(state: .completed, taskId: worked.id)
        session.rosterAgentId = ada.id
        try f.sessions.insert(session)
        var bobSession = f.session(state: .completed, taskId: untouched.id)
        bobSession.rosterAgentId = bob.id
        try f.sessions.insert(bobSession)
        try f.tasks.setRosterAgent(worked.id, ada.id)
        try f.tasks.setReviewer(worked.id, bob.id)
        try f.tasks.setReviewer(reviewed.id, ada.id)
        try f.tasks.setRosterAgent(untouched.id, bob.id)

        try f.roster.delete(ada.id)

        XCTAssertNil(try f.roster.get(ada.id))
        XCTAssertNil(try f.sessions.get(session.sessionId)?.rosterAgentId)
        XCTAssertEqual(try f.sessions.get(session.sessionId)?.state, .completed)
        XCTAssertNil(try f.tasks.get(worked.id)?.rosterAgentId)
        XCTAssertEqual(try f.tasks.get(worked.id)?.reviewerAgentId, bob.id)
        XCTAssertNil(try f.tasks.get(reviewed.id)?.reviewerAgentId)
        XCTAssertEqual(try f.tasks.get(reviewed.id)?.title, "reviewed by Ada")
        XCTAssertEqual(try f.sessions.get(bobSession.sessionId)?.rosterAgentId, bob.id)
        XCTAssertEqual(try f.tasks.get(untouched.id)?.rosterAgentId, bob.id)
    }

    func testDeleteIsRefusedWhileALiveSessionRunsAsTheAgent() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        let task = try f.task("in flight", column: .running)
        var live = f.session(state: .running, taskId: task.id)
        live.rosterAgentId = ada.id
        try f.sessions.insert(live)
        try f.tasks.setRosterAgent(task.id, ada.id)

        XCTAssertThrowsError(try f.roster.delete(ada.id)) {
            XCTAssertEqual($0 as? BoardError, .rosterAgentWorking(agentId: ada.id, sessionId: live.sessionId))
        }
        XCTAssertNotNil(try f.roster.get(ada.id))
        XCTAssertEqual(try f.roster.agents(forProject: f.project.id).map(\.id), [ada.id])
        XCTAssertEqual(try f.sessions.get(live.sessionId)?.rosterAgentId, ada.id)
        XCTAssertEqual(try f.tasks.get(task.id)?.rosterAgentId, ada.id)
    }

    func testDeletingAProjectClearsItsRosterSelectionWithoutTouchingTheAgents() throws {
        let f = try Fixture.make()
        let other = try f.otherProject()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        try f.roster.enable(agentId: ada.id, forProject: other.id)

        try f.projects.delete(f.project.id)

        XCTAssertNotNil(try f.roster.get(ada.id))
        XCTAssertEqual(try f.roster.agents(forProject: other.id).map(\.id), [ada.id])
    }

    // MARK: observation

    func testObserveEmitsRosterChanges() throws {
        let f = try Fixture.make()
        let sawSecond = expectation(description: "saw second agent")
        let cancellable = f.roster.observe().start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { agents in
                if agents.map(\.name) == ["Ada", "Bob"] { sawSecond.fulfill() }
            }
        )
        try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        try f.roster.create(name: "Bob", role: "backend", systemPrompt: "p")
        wait(for: [sawSecond], timeout: 2)
        cancellable.cancel()
    }

    func testObserveProjectEmitsWhenAnAgentIsEnabledForIt() throws {
        let f = try Fixture.make()
        let ada = try f.roster.create(name: "Ada", role: "frontend", systemPrompt: "p")
        let sawAda = expectation(description: "saw Ada on the project")
        let cancellable = f.roster.observe(projectId: f.project.id).start(
            in: f.db.writer,
            onError: { XCTFail("\($0)") },
            onChange: { agents in
                if agents.map(\.id) == [ada.id] { sawAda.fulfill() }
            }
        )
        try f.roster.enable(agentId: ada.id, forProject: f.project.id)
        wait(for: [sawAda], timeout: 2)
        cancellable.cancel()
    }
}
