import AgentBoardCore
import AgentBoardRuntime
import Foundation
import XCTest
@testable import AgentBoard

@MainActor
final class TranscriptMeteringTests: XCTestCase {
    private var fixture: SupervisorFixture!

    override func setUp() async throws {
        fixture = try SupervisorFixture.make()
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    private func assistantLine(requestId: String, input: Int, output: Int, cacheRead: Int, creation: Int) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "requestId": requestId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": [
                "model": "claude-opus-5",
                "id": "msg_\(UUID().uuidString)",
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": creation,
                ],
                "content": [["type": "text", "text": "hi"]],
            ] as [String: Any],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A streamed response's later chunk can land a tick after its first, so `req_B` spans two.
    func testSpendMeteredAcrossAppendingTicksMatchesAFullRead() async throws {
        let transcript = fixture.supportDir.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        let session = AgentSession(
            sessionId: "session-tail", projectId: fixture.project.id, role: .worker,
            cwd: fixture.repo.path, state: .running, transcriptPath: transcript.path
        )
        try fixture.sessions.insert(session)

        let ticks = [
            [assistantLine(requestId: "req_A", input: 3, output: 40, cacheRead: 1_000, creation: 200)],
            [
                assistantLine(requestId: "req_B", input: 5, output: 10, cacheRead: 2_000, creation: 50),
                assistantLine(requestId: "req_C", input: 7, output: 90, cacheRead: 3_000, creation: 0),
            ],
            [assistantLine(requestId: "req_B", input: 5, output: 75, cacheRead: 2_000, creation: 50)],
            [assistantLine(requestId: "req_D", input: 2, output: 8, cacheRead: 4_000, creation: 600)],
        ]
        for lines in ticks {
            let handle = try FileHandle(forWritingTo: transcript)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
            try handle.close()

            await fixture.supervisor.meter(
                session,
                limits: CapLimits(maxTokens: nil, maxWallClockSeconds: nil, maxIdleSeconds: nil),
                stallSeconds: 100_000,
                awake: .init(nowMillis: .nowMillis)
            )

            let full = try TranscriptMeter.summarize(transcriptAt: transcript).totals
            let row = try XCTUnwrap(fixture.sessions.get(session.sessionId))
            XCTAssertEqual(
                UsageTotals(
                    inputTokens: row.tokensIn, outputTokens: row.tokensOut,
                    cacheReadTokens: row.cacheRead, cacheWrite5mTokens: row.cacheWrite
                ),
                full
            )
        }
    }
}
