import AgentBoardBridge
import AgentBoardCore
import Foundation
import XCTest
@testable import AgentBoard

/// SPEC §8: every worker idle-out in 0.8.0 was a turn Claude Code ended on this `StopFailure` after
/// a lid close cut off its model request, left idle until the idle cap killed it.
@MainActor
final class SleepCutTurnTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
        await fixture.supervisor.start()
        try XCTSkipIf(fixture.supervisor.serverPort == nil, "the board server could not bind a port")
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    func testATurnCutBySleepGetsOneContinuationPerStallAndOtherTurnEndsGetNone() async throws {
        let port = try XCTUnwrap(fixture.supervisor.serverPort)
        let (_, finished, finishedToken) = try fixture.workerAtWork("Finishes normally")
        let (task, cut, cutToken) = try fixture.workerAtWork("Cut off by sleep")
        let sleep: [String: String] = [
            "hook_event_name": "StopFailure", "session_id": cut,
            "error": "server_error", "last_assistant_message": SleepCutTurn.message,
        ]

        for payload in [
            ["hook_event_name": "Stop", "session_id": finished, "last_assistant_message": "Done for now."],
            [
                "hook_event_name": "StopFailure", "session_id": finished,
                "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached",
            ],
        ] {
            let status = try await Self.hook(payload, port: port, token: finishedToken)
            XCTAssertEqual(status, 200)
        }
        let first = try await Self.hook(sleep, port: port, token: cutToken)
        XCTAssertEqual(first, 200)
        _ = try await resumes(reaching: 1)
        let second = try await Self.hook(sleep, port: port, token: cutToken)
        XCTAssertEqual(second, 200)
        _ = try await resumes(reaching: 2, within: .seconds(1))

        let resumed = await fixture.runtime.resumed
        XCTAssertEqual(resumed, [cut], "expected one continuation, to the sleep-cut session only")
        let prompts = await fixture.runtime.resumePrompts
        XCTAssertEqual(prompts, [SleepCutTurn.continuation])
        let logged = try ProgressStore(fixture.db).list(taskId: task.id).filter { $0.text.contains("one continuation") }
        XCTAssertEqual(logged.count, 1)
    }

    private func resumes(reaching count: Int, within limit: Duration = .seconds(10)) async throws -> [String] {
        let deadline = ContinuousClock.now + limit
        while await fixture.runtime.resumePrompts.count < count, ContinuousClock.now < deadline {
            try await _Concurrency.Task.sleep(for: .milliseconds(50))
        }
        return await fixture.runtime.resumePrompts
    }

    private nonisolated static func hook(_ payload: [String: String], port: Int, token: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks?token=\(token)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
