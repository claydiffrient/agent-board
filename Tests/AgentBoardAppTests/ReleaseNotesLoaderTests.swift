import AgentBoardCore
import Foundation
import XCTest

@testable import AgentBoard

final class ReleaseNotesLoaderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("release-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The `.build/debug/AgentBoard` case `README.md` documents for E2E: no `Info.plist`, no
    /// resource directory. The test runner is the same shape, so `Bundle.main` here is the real
    /// thing rather than a stand-in. The answer must be `.unavailable` — nothing to show, nothing
    /// wrong — and never `.loaded` with an empty list.
    func testAnUnbundledBinaryHasNoNotesAndNoError() {
        XCTAssertFalse(
            AppBundle.isAppBundle(),
            "the test runner became an app bundle; this test no longer covers the unbundled case"
        )
        XCTAssertEqual(ReleaseNotesLoader.load(), .unavailable)
    }

    func testTheUnbundledCaseIsDecidedBeforeAnythingIsRead() throws {
        let bundle = try makeAppBundle(plist: nil, notes: nil)
        XCTAssertEqual(ReleaseNotesLoader.load(from: bundle), .unavailable)
    }

    func testABundledBuildLoadsItsVersionAndItsReleases() throws {
        let bundle = try makeAppBundle(
            version: "0.10.0",
            notes: """
            # Releases

            ## 0.9.0 — 2026-08-01

            Older.

            ## 0.10.0 — 2026-09-16

            Newer.
            """
        )
        guard case let .loaded(notes) = ReleaseNotesLoader.load(from: bundle) else {
            return XCTFail("a well-formed bundle did not load")
        }
        XCTAssertEqual(notes.appVersion, ReleaseVersion(major: 0, minor: 10, patch: 0))
        XCTAssertEqual(notes.entries.map { "\($0.version)" }, ["0.10.0", "0.9.0"])
        XCTAssertEqual(notes.current?.body, "Newer.")
    }

    /// A version the notes do not mention is not a failure: the caller shows the list, not nothing.
    func testAVersionWithNoEntryStillLoadsTheList() throws {
        let bundle = try makeAppBundle(version: "0.11.0", notes: "## 0.10.0\n\nNewer.\n")
        guard case let .loaded(notes) = ReleaseNotesLoader.load(from: bundle) else {
            return XCTFail("a well-formed bundle did not load")
        }
        XCTAssertNil(notes.current)
        XCTAssertEqual(notes.entries.count, 1)
    }

    func testAMalformedFileFailsWithTheParsersSentence() throws {
        let bundle = try makeAppBundle(version: "0.1.0", notes: "# Releases\n\n## Unreleased\n\nOops.\n")
        guard case let .failed(message) = ReleaseNotesLoader.load(from: bundle) else {
            return XCTFail("a malformed RELEASES.md did not fail")
        }
        XCTAssertEqual(
            message,
            ReleaseNotesParseError.unreadableHeading(line: 3, heading: "Unreleased").description
        )
    }

    func testABundleWithNoNotesFileFails() throws {
        let bundle = try makeAppBundle(version: "0.1.0", notes: nil)
        guard case let .failed(message) = ReleaseNotesLoader.load(from: bundle) else {
            return XCTFail("a bundle with no RELEASES.md did not fail")
        }
        XCTAssertTrue(message.contains("RELEASES.md"), message)
    }

    func testAnUnreadableVersionFails() throws {
        let bundle = try makeAppBundle(version: "not-a-version", notes: "## 0.1.0\n\nBody.\n")
        guard case let .failed(message) = ReleaseNotesLoader.load(from: bundle) else {
            return XCTFail("an unreadable CFBundleShortVersionString did not fail")
        }
        XCTAssertTrue(message.contains("CFBundleShortVersionString"), message)
    }

    /// The file that actually ships. A heading mistyped in the repo is caught here rather than by
    /// whoever opens the window after the release.
    func testTheShippedReleasesFileParsesAndCoversTheShippedVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let markdown = try? String(contentsOf: root.appendingPathComponent("RELEASES.md"), encoding: .utf8),
              let plist = try? Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        else {
            throw XCTSkip("running outside the checkout")
        }
        let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        let shipped = try XCTUnwrap(ReleaseVersion(try XCTUnwrap(info?["CFBundleShortVersionString"] as? String)))
        let entries = try ReleaseNotesParser.parse(markdown)
        XCTAssertTrue(
            entries.contains { $0.version == shipped },
            "RELEASES.md has no entry for the shipped version \(shipped)"
        )
        XCTAssertEqual(entries, entries.sorted { $0.version > $1.version })
    }

    // MARK: fixture

    private func makeAppBundle(version: String, notes: String?) throws -> Bundle {
        try makeAppBundle(
            plist: [
                "CFBundleIdentifier": "dev.clayd.agentboard.test",
                "CFBundleExecutable": "AgentBoard",
                "CFBundleName": "Agent Board",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": "1",
            ],
            notes: notes
        )
    }

    private func makeAppBundle(plist: [String: String]?, notes: String?) throws -> Bundle {
        let app = scratch.appendingPathComponent("Agent Board.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if let plist {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        if let notes {
            try notes.write(
                to: resources.appendingPathComponent("RELEASES.md"), atomically: true, encoding: .utf8
            )
        }
        return try XCTUnwrap(Bundle(url: app), "Bundle(url:) refused the fixture at \(app.path)")
    }
}
