import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §4: a task's `effort`, then the project's `defaultEffort`, reaches `claude --effort`.
@MainActor
final class EffortSpawnTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make(gitRepo: true)
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.supervisor.waitForSetup()
        await fixture.cleanUp()
        fixture = nil
    }

    private func spawnArguments(effort: Effort?) async throws -> (args: [String], session: AgentSession?) {
        var task = try fixture.tasks.create(
            projectId: fixture.project.id, title: "Effort \(effort?.rawValue ?? "none")", body: "Do it.",
            acceptance: nil, priority: nil, column: .ready, origin: .human, epicId: nil
        )
        task.effort = effort
        try fixture.tasks.update(task)
        try await fixture.supervisor.assign(taskId: task.id)
        await fixture.supervisor.waitForSetup()
        let spawns = await fixture.runtime.spawns
        let request = try XCTUnwrap(spawns.last)
        return (BackgroundSessionRuntime.arguments(for: request), try fixture.sessions.forTask(task.id).first)
    }

    private func effortFlag(_ args: [String]) -> String? {
        args.firstIndex(of: "--effort").map { args[$0 + 1] }
    }

    func testTaskEffortWinsOverTheProjectDefaultAndNoneOfEitherPassesNoFlag() async throws {
        let unset = try await spawnArguments(effort: nil)
        XCTAssertNil(effortFlag(unset.args), "no task or project effort must leave Claude Code's default")

        var settings = try XCTUnwrap(ProjectStore(fixture.db).get(fixture.project.id)).settings
        settings.defaultEffort = .low
        try ProjectStore(fixture.db).updateSettings(fixture.project.id, settings)

        let taskWins = try await spawnArguments(effort: .high)
        XCTAssertEqual(effortFlag(taskWins.args), "high")
        XCTAssertEqual(taskWins.session?.effort, .high, "the session row records the effort it ran at")

        let projectDefault = try await spawnArguments(effort: nil)
        XCTAssertEqual(effortFlag(projectDefault.args), "low")
    }
}
