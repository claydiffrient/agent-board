import Foundation
import XCTest

@testable import AgentBoardCore

final class ReleaseVersionTests: XCTestCase {
    /// The pair that orders correctly under semantic-version rules and wrongly under string
    /// comparison, which is why `ReleaseVersion` exists.
    func testTenSortsAboveNineAndAboveOne() {
        let ten = ReleaseVersion(major: 0, minor: 10, patch: 0)
        let nine = ReleaseVersion(major: 0, minor: 9, patch: 0)
        let one = ReleaseVersion(major: 0, minor: 1, patch: 0)
        XCTAssertGreaterThan(ten, nine)
        XCTAssertGreaterThan(ten, one)
        XCTAssertLessThan("0.10.0", "0.9.0", "string comparison is still the wrong tool; that is the point")
        XCTAssertEqual([one, ten, nine].sorted(by: >), [ten, nine, one])
    }

    func testParsesOneToThreeComponentsAndAnOptionalVPrefix() {
        XCTAssertEqual(ReleaseVersion("1.2.3"), ReleaseVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(ReleaseVersion("0.1"), ReleaseVersion(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(ReleaseVersion("2"), ReleaseVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(ReleaseVersion("v0.10.0"), ReleaseVersion(major: 0, minor: 10, patch: 0))
        XCTAssertEqual(ReleaseVersion("0.10.0")?.description, "0.10.0")
    }

    func testRejectsEverythingThatIsNotThreeNumbers() {
        for text in ["", "1.2.3.4", "1..2", "1.2.x", "one", "1.2.3-beta", "1.2.3+build", "-1.0.0", "１.０.０"] {
            XCTAssertNil(ReleaseVersion(text), "\(text) parsed as a version")
        }
    }

    func testOrderingRunsMajorThenMinorThenPatch() {
        XCTAssertGreaterThan(ReleaseVersion("1.0.0")!, ReleaseVersion("0.99.99")!)
        XCTAssertGreaterThan(ReleaseVersion("1.2.10")!, ReleaseVersion("1.2.9")!)
        XCTAssertEqual(ReleaseVersion("1.2")!, ReleaseVersion("1.2.0")!)
    }
}

final class ReleaseNotesParserTests: XCTestCase {
    private func day(_ text: String) -> Date {
        guard let date = ReleaseNotesParser.calendarDay(text) else {
            XCTFail("fixture date \(text) did not parse")
            return .distantPast
        }
        return date
    }

    func testSeveralReleasesComeBackNewestFirstWithDatesAndBodies() throws {
        let markdown = """
        # Agent Board releases

        Preamble nobody parses.

        ## 0.9.0 — 2026-08-01

        - Older release, written first on purpose.

        ## 0.10.0 — 2026-09-16

        The newest one.

        ### A subheading stays in the body

        More body.

        ## 0.1.0

        The first release, with no date recorded.
        """

        let entries = try ReleaseNotesParser.parse(markdown)

        XCTAssertEqual(entries.map(\.version), [
            ReleaseVersion(major: 0, minor: 10, patch: 0),
            ReleaseVersion(major: 0, minor: 9, patch: 0),
            ReleaseVersion(major: 0, minor: 1, patch: 0),
        ])
        XCTAssertEqual(entries.map(\.date), [day("2026-09-16"), day("2026-08-01"), nil])
        XCTAssertEqual(entries[0].body, """
        The newest one.

        ### A subheading stays in the body

        More body.
        """)
        XCTAssertEqual(entries[1].body, "- Older release, written first on purpose.")
        XCTAssertEqual(entries[2].body, "The first release, with no date recorded.")
    }

    func testAllThreeDashSeparatorsAndAVPrefixedHeadingAreAccepted() throws {
        let markdown = """
        ## v3.0.0 - 2026-03-03
        em
        ## 2.0.0 – 2026-02-02
        en
        ## 1.0.0 — 2026-01-01
        hyphen
        """
        let entries = try ReleaseNotesParser.parse(markdown)
        XCTAssertEqual(entries.map { "\($0.version)" }, ["3.0.0", "2.0.0", "1.0.0"])
        XCTAssertEqual(entries.map(\.date), [day("2026-03-03"), day("2026-02-02"), day("2026-01-01")])
    }

    func testAHeadingInsideAFencedCodeBlockIsBodyNotARelease() throws {
        let markdown = """
        ## 1.0.0 — 2026-01-01

        Write a release like this:

        ```
        ## 2.0.0 — 2026-02-02
        ```
        """
        let entries = try ReleaseNotesParser.parse(markdown)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].version, ReleaseVersion(major: 1, minor: 0, patch: 0))
        XCTAssertTrue(entries[0].body.contains("## 2.0.0"))
    }

    // MARK: malformed files

    /// A mistyped heading is the failure this whole error type exists for: it must name the line,
    /// not produce a file with one fewer release in it.
    func testAMistypedHeadingFailsWithItsLineNumber() {
        let markdown = """
        # Agent Board releases

        ## 0.2.0 — 2026-09-16

        Fine.

        ## Unreleased

        Not fine.
        """
        XCTAssertThrowsError(try ReleaseNotesParser.parse(markdown)) { error in
            XCTAssertEqual(
                error as? ReleaseNotesParseError,
                .unreadableHeading(line: 7, heading: "Unreleased")
            )
            XCTAssertEqual(
                "\(error as! ReleaseNotesParseError)",
                "RELEASES.md line 7: '## Unreleased' is not '## <version>' or '## <version> — YYYY-MM-DD'."
            )
        }
    }

    func testABadDateFailsRatherThanBeingDropped() {
        for text in ["16-09-2026", "2026-9-16", "2026-13-01", "2026-02-30", "yesterday"] {
            let markdown = "## 1.0.0 — \(text)\n\nBody.\n"
            XCTAssertThrowsError(try ReleaseNotesParser.parse(markdown), text) { error in
                XCTAssertEqual(
                    error as? ReleaseNotesParseError,
                    .unreadableDate(line: 1, version: "1.0.0", date: text)
                )
            }
        }
    }

    func testAFileWithNoHeadingsFails() {
        XCTAssertThrowsError(try ReleaseNotesParser.parse("")) {
            XCTAssertEqual($0 as? ReleaseNotesParseError, .noReleases)
        }
        XCTAssertThrowsError(try ReleaseNotesParser.parse("# Releases\n\nComing soon.\n")) {
            XCTAssertEqual($0 as? ReleaseNotesParseError, .noReleases)
        }
    }

    func testARepeatedVersionFails() {
        let markdown = "## 1.0.0\n\nOne.\n\n## 1.0.0\n\nTwo.\n"
        XCTAssertThrowsError(try ReleaseNotesParser.parse(markdown)) {
            XCTAssertEqual($0 as? ReleaseNotesParseError, .duplicateVersion(line: 5, version: "1.0.0"))
        }
    }

    /// A heading with nothing under it is the empty window in file form.
    func testAReleaseWithNoNotesFails() {
        XCTAssertThrowsError(try ReleaseNotesParser.parse("## 1.0.0 — 2026-01-01\n\n\n")) {
            XCTAssertEqual($0 as? ReleaseNotesParseError, .emptyBody(line: 1, version: "1.0.0"))
        }
    }

    func testEveryErrorDescribesItselfInASentence() {
        let errors: [ReleaseNotesParseError] = [
            .noReleases,
            .unreadableHeading(line: 3, heading: "Unreleased"),
            .unreadableDate(line: 3, version: "1.0.0", date: "nope"),
            .duplicateVersion(line: 9, version: "1.0.0"),
            .emptyBody(line: 9, version: "1.0.0"),
        ]
        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
            XCTAssertTrue(error.description.hasSuffix("."), error.description)
            XCTAssertTrue(error.description.contains("RELEASES.md"), error.description)
        }
    }

    // MARK: purity

    /// The parser is a string in and entries out. If it ever grew a file read, it would leave an
    /// open descriptor here — which is evidence, not proof, since an open/close pair nets to zero.
    /// `testTheParserSourceNamesNoFileSystemAPI` covers the rest.
    func testParsingLeavesTheFileDescriptorTableUnchanged() throws {
        let markdown = "## 1.0.0 — 2026-01-01\n\nBody.\n"
        _ = try ReleaseNotesParser.parse(markdown)
        let before = Self.openDescriptors()
        _ = try ReleaseNotesParser.parse(markdown)
        XCTAssertEqual(Self.openDescriptors(), before)
    }

    func testTheParserSourceNamesNoFileSystemAPI() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AgentBoardCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/AgentBoardCore/ReleaseNotes.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw XCTSkip("running outside the checkout: \(source.path) is not readable")
        }
        let code = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for api in ["FileManager", "Bundle", "contentsOfFile", "contentsOf:", "FileHandle", "URLSession", "fopen"] {
            XCTAssertFalse(code.contains(api), "\(api) appeared in the parser, which must stay pure")
        }
    }

    private static func openDescriptors() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { total, fd in
            if fcntl(fd, F_GETFD) != -1 { total += 1 }
        }
    }
}
