import Foundation

public struct UsageTotals: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int

    public var cacheWriteTokens: Int { cacheWrite5mTokens + cacheWrite1hTokens }

    public static let zero = UsageTotals()

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWrite5mTokens: Int = 0,
        cacheWrite1hTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
    }

    public static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWrite5mTokens: lhs.cacheWrite5mTokens + rhs.cacheWrite5mTokens,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens
        )
    }

    public static func - (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(
            inputTokens: lhs.inputTokens - rhs.inputTokens,
            outputTokens: lhs.outputTokens - rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens - rhs.cacheReadTokens,
            cacheWrite5mTokens: lhs.cacheWrite5mTokens - rhs.cacheWrite5mTokens,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens - rhs.cacheWrite1hTokens
        )
    }

    public static func += (lhs: inout UsageTotals, rhs: UsageTotals) {
        lhs = lhs + rhs
    }
}

public struct TranscriptSummary: Sendable, Equatable {
    public var totals: UsageTotals
    /// The usage of the last assistant message alone. `totals` sums the whole session and answers
    /// "what has this cost"; this one answers "how full is the context right now", which after a
    /// compaction is a far smaller number than the sum.
    public var lastMessage: UsageTotals
    public var model: String?
    public var lastActivity: Date?
    public var lastToolName: String?
    /// Distinct assistant API responses (streamed chunks sharing a `requestId` count once).
    public var messageCount: Int

    /// Everything the model re-reads on the next request: the fresh input plus whatever the cache
    /// serves and whatever this turn wrote into it. Dropping the cache write reads ~40% low
    /// immediately after a compaction, which is exactly when the trigger matters (SPEC §2).
    public var contextTokens: Int {
        lastMessage.inputTokens + lastMessage.cacheReadTokens + lastMessage.cacheWriteTokens
    }

    public init(
        totals: UsageTotals = .zero,
        lastMessage: UsageTotals = .zero,
        model: String? = nil,
        lastActivity: Date? = nil,
        lastToolName: String? = nil,
        messageCount: Int = 0
    ) {
        self.totals = totals
        self.lastMessage = lastMessage
        self.model = model
        self.lastActivity = lastActivity
        self.lastToolName = lastToolName
        self.messageCount = messageCount
    }
}

public enum TranscriptMeter {
    /// Full re-read of the transcript. Use `TranscriptTailer` to poll a growing file incrementally.
    public static func summarize(transcriptAt url: URL) throws -> TranscriptSummary {
        var accumulator = TranscriptAccumulator()
        let data = try Data(contentsOf: url)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            accumulator.ingest(line: line)
        }
        return accumulator.summary
    }
}

/// Remembers the byte offset between polls and folds only new lines into the running summary.
public struct TranscriptTailer: Sendable {
    public let url: URL
    public private(set) var offset: UInt64 = 0
    public private(set) var summary = TranscriptSummary()
    private var partialLine = Data()
    private var accumulator = TranscriptAccumulator()

    public init(url: URL) {
        self.url = url
    }

    /// Returns the change in usage since the previous poll. A truncated file restarts from zero.
    @discardableResult
    public mutating func poll() throws -> UsageTotals {
        let before = accumulator.summary.totals
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        if size < offset {
            offset = 0
            partialLine = Data()
            accumulator = TranscriptAccumulator()
        }
        try handle.seek(toOffset: offset)
        guard let chunk = try handle.readToEnd(), !chunk.isEmpty else {
            summary = accumulator.summary
            return .zero
        }
        offset += UInt64(chunk.count)

        var buffer = partialLine + chunk
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            accumulator.ingest(line: line)
            buffer = buffer[buffer.index(after: newline)...]
        }
        partialLine = Data(buffer)

        summary = accumulator.summary
        return summary.totals - before
    }
}

struct TranscriptAccumulator: Sendable {
    private var usageByKey: [String: UsageTotals] = [:]
    private var activityByKey: [String: Date] = [:]
    private var model: String?
    private var lastToolName: String?
    private var lastActivity: Date?
    private var anonymousCount = 0
    /// Transcript order, not timestamp order: the last `usage` in the file is the current context.
    private var lastMessage: UsageTotals = .zero

    var summary: TranscriptSummary {
        TranscriptSummary(
            totals: usageByKey.values.reduce(.zero, +),
            lastMessage: lastMessage,
            model: model,
            lastActivity: lastActivity,
            lastToolName: lastToolName,
            messageCount: usageByKey.count
        )
    }

    mutating func ingest(line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any]
        else { return }

        if let m = message["model"] as? String { model = m }
        if let ts = object["timestamp"] as? String, let date = Self.parseTimestamp(ts) {
            if lastActivity.map({ date > $0 }) ?? true { lastActivity = date }
        }
        if let content = message["content"] as? [[String: Any]] {
            for block in content where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { lastToolName = name }
            }
        }

        guard let usage = message["usage"] as? [String: Any] else { return }
        let key: String
        if let requestId = object["requestId"] as? String {
            key = requestId
        } else if let messageId = message["id"] as? String {
            key = "msg:" + messageId
        } else {
            anonymousCount += 1
            key = "anon:\(anonymousCount)"
        }
        let parsed = Self.parseUsage(usage)
        usageByKey[key] = parsed
        lastMessage = parsed
    }

    static func parseUsage(_ usage: [String: Any]) -> UsageTotals {
        func int(_ key: String, in dict: [String: Any]) -> Int {
            (dict[key] as? NSNumber)?.intValue ?? 0
        }
        let creation = int("cache_creation_input_tokens", in: usage)
        var write5m = creation
        var write1h = 0
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            write5m = int("ephemeral_5m_input_tokens", in: breakdown)
            write1h = int("ephemeral_1h_input_tokens", in: breakdown)
            if write5m + write1h == 0 { write5m = creation }
        }
        return UsageTotals(
            inputTokens: int("input_tokens", in: usage),
            outputTokens: int("output_tokens", in: usage),
            cacheReadTokens: int("cache_read_input_tokens", in: usage),
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h
        )
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}
