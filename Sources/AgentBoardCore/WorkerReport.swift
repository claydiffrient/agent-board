import Foundation

/// The JSON object a worker submits to `report_complete`, stored as a report body.
public struct WorkerReport: Codable, Sendable, Equatable {
    public var summary: String
    public var filesChanged: [String]
    public var testsRun: String
    public var caveats: String

    enum CodingKeys: String, CodingKey {
        case summary
        case filesChanged = "files_changed"
        case testsRun = "tests_run"
        case caveats
    }

    public init(summary: String, filesChanged: [String] = [], testsRun: String = "", caveats: String = "") {
        self.summary = summary
        self.filesChanged = filesChanged
        self.testsRun = testsRun
        self.caveats = caveats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        filesChanged = try container.decodeIfPresent([String].self, forKey: .filesChanged) ?? []
        testsRun = try container.decodeIfPresent(String.self, forKey: .testsRun) ?? ""
        caveats = try container.decodeIfPresent(String.self, forKey: .caveats) ?? ""
    }

    public static func decode(body: String) -> WorkerReport? {
        try? JSONDecoder().decode(WorkerReport.self, from: Data(body.utf8))
    }

    /// Prose for a triage glance: the report's `summary`, or the whole body when it does not decode.
    public static func summaryText(body: String, sentenceLimit: Int = 3) -> String {
        let text = decode(body: body)?.summary ?? body
        return firstSentences(of: text, limit: sentenceLimit)
    }

    /// A terminator only ends a sentence when whitespace or the end of the text follows it,
    /// so decimals and version numbers stay intact.
    public static func firstSentences(of text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        var sentences = 0
        var end = trimmed.endIndex
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(after: index)
            if trimmed[index] == "." || trimmed[index] == "!" || trimmed[index] == "?",
               next == trimmed.endIndex || trimmed[next].isWhitespace {
                sentences += 1
                if sentences == limit {
                    end = next
                    break
                }
            }
            index = next
        }
        return String(trimmed[trimmed.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
