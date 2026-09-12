import XCTest
@testable import AgentBoardRuntime

final class TranscriptMeterTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func assistantLine(
        requestId: String?,
        timestamp: String,
        model: String = "claude-opus-5",
        input: Int, output: Int, cacheRead: Int = 0, creation: Int = 0,
        breakdown: (m5: Int, h1: Int)? = nil,
        content: [[String: Any]] = [["type": "text", "text": "hi"]]
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": creation,
        ]
        if let breakdown {
            usage["cache_creation"] = ["ephemeral_5m_input_tokens": breakdown.m5, "ephemeral_1h_input_tokens": breakdown.h1]
        }
        var object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["model": model, "id": "msg_\(UUID().uuidString)", "usage": usage, "content": content] as [String: Any],
        ]
        if let requestId { object["requestId"] = requestId }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testDedupesByRequestIdAndSkipsMalformedLines() throws {
        let lines = [
            #"{"type":"user","timestamp":"2026-09-11T10:00:00.000Z","message":{"role":"user","content":"go"}}"#,
            assistantLine(requestId: "req_A", timestamp: "2026-09-11T10:00:01.000Z", input: 10, output: 5, cacheRead: 100, breakdown: (m5: 7, h1: 3), content: [["type": "tool_use", "name": "Read", "id": "t1", "input": [:]]]),
            assistantLine(requestId: "req_A", timestamp: "2026-09-11T10:00:02.000Z", input: 10, output: 5, cacheRead: 100, breakdown: (m5: 7, h1: 3), content: [["type": "tool_use", "name": "Edit", "id": "t2", "input": [:]]]),
            "{this is not json",
            assistantLine(requestId: "req_B", timestamp: "2026-09-11T10:00:05.000Z", model: "claude-sonnet-5", input: 1, output: 2, creation: 40),
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let summary = try TranscriptMeter.summarize(transcriptAt: file)
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertEqual(summary.totals, UsageTotals(inputTokens: 11, outputTokens: 7, cacheReadTokens: 100, cacheWrite5mTokens: 47, cacheWrite1hTokens: 3))
        XCTAssertEqual(summary.totals.cacheWriteTokens, 50)
        XCTAssertEqual(summary.model, "claude-sonnet-5")
        XCTAssertEqual(summary.lastToolName, "Edit")
        XCTAssertEqual(summary.lastActivity, TranscriptAccumulator.parseTimestamp("2026-09-11T10:00:05.000Z"))
    }

    func testSameRequestIdWithDifferentUsageKeepsLast() throws {
        let lines = [
            assistantLine(requestId: "req_A", timestamp: "2026-09-11T10:00:01Z", input: 10, output: 5),
            assistantLine(requestId: "req_A", timestamp: "2026-09-11T10:00:02Z", input: 10, output: 50),
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let summary = try TranscriptMeter.summarize(transcriptAt: file)
        XCTAssertEqual(summary.messageCount, 1)
        XCTAssertEqual(summary.totals.outputTokens, 50)
    }

    func testMissingCacheCreationBreakdownCountsAs5m() {
        let totals = TranscriptAccumulator.parseUsage([
            "input_tokens": 1, "output_tokens": 2, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 40,
        ])
        XCTAssertEqual(totals.cacheWrite5mTokens, 40)
        XCTAssertEqual(totals.cacheWrite1hTokens, 0)
    }

    func testLinesWithoutRequestIdCountSeparately() throws {
        let lines = [
            assistantLine(requestId: nil, timestamp: "2026-09-11T10:00:01Z", input: 1, output: 1),
            assistantLine(requestId: nil, timestamp: "2026-09-11T10:00:02Z", input: 1, output: 1),
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try TranscriptMeter.summarize(transcriptAt: file).totals.inputTokens, 2)
    }

    func testTailerReturnsOnlyDeltasAndHandlesPartialLines() throws {
        let a = assistantLine(requestId: "req_A", timestamp: "2026-09-11T10:00:01Z", input: 10, output: 5)
        let b = assistantLine(requestId: "req_B", timestamp: "2026-09-11T10:00:02Z", input: 20, output: 6)
        try (a + "\n").write(to: file, atomically: true, encoding: .utf8)

        var tailer = TranscriptTailer(url: file)
        XCTAssertEqual(try tailer.poll(), UsageTotals(inputTokens: 10, outputTokens: 5))
        XCTAssertEqual(try tailer.poll(), .zero)
        XCTAssertEqual(tailer.summary.messageCount, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let split = b.index(b.startIndex, offsetBy: b.count / 2)
        try handle.write(contentsOf: Data(b[..<split].utf8))
        try handle.close()

        XCTAssertEqual(try tailer.poll(), .zero, "half a line must not be counted")

        let handle2 = try FileHandle(forWritingTo: file)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data((String(b[split...]) + "\n").utf8))
        try handle2.close()

        XCTAssertEqual(try tailer.poll(), UsageTotals(inputTokens: 20, outputTokens: 6))
        XCTAssertEqual(tailer.summary.totals, UsageTotals(inputTokens: 30, outputTokens: 11))
        XCTAssertEqual(tailer.summary.messageCount, 2)
        XCTAssertEqual(tailer.summary, try TranscriptMeter.summarize(transcriptAt: file))
    }

    func testTailerRestartsOnTruncation() throws {
        let a = assistantLine(requestId: "req_A", timestamp: "2026-09-11T10:00:01Z", input: 10, output: 5)
        try (a + "\n").write(to: file, atomically: true, encoding: .utf8)
        var tailer = TranscriptTailer(url: file)
        _ = try tailer.poll()

        let b = assistantLine(requestId: "req_B", timestamp: "2026-09-11T10:00:02Z", input: 1, output: 1)
        try (b + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try tailer.poll(), UsageTotals(inputTokens: -9, outputTokens: -4))
        XCTAssertEqual(tailer.summary.totals, UsageTotals(inputTokens: 1, outputTokens: 1))
    }
}
