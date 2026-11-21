import AgentBoardCore
import Foundation
import XCTest

final class IssueReferenceTests: XCTestCase {
    func testNumbersAreNotGroupedInAGroupingLocale() {
        let enUS = Locale(identifier: "en_US")
        XCTAssertEqual(13408.formatted(.number.locale(enUS)), "13,408")
        XCTAssertEqual(IssueReference.short(13408), "#13408")
        XCTAssertEqual(IssueReference.full(owner: "owner", repo: "repo", 13408), "owner/repo#13408")
    }

    /// Fails on a `#\(…number)` interpolation in `Sources/`: such a string reaching a SwiftUI literal
    /// renders `#13,408`. Display text goes through `IssueReference` instead.
    func testSourcesInterpolateNoIssueNumberOutsideTheHelper() throws {
        let allowed: Set<String> = [
            #"WorkerSupervisor.swift: func key(_ repository: String, _ number: Int) -> String { "\(repository.lowercased())#\(number)" }"#,
        ]
        let pattern = try NSRegularExpression(pattern: #"#\\\((?:[\w$]+\.)*\w*(?:[nN]umber|pr|prNumber)\b"#)
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                guard pattern.firstMatch(in: line, range: range) != nil else { continue }
                let entry = "\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))"
                if !allowed.contains(entry) { offenders.append(entry) }
            }
        }
        XCTAssertEqual(offenders, [], "Use IssueReference.short or .full for a displayed PR or issue number")
    }
}
