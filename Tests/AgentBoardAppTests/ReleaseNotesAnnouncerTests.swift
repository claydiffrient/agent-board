import AgentBoardCore
import Foundation
import XCTest

@testable import AgentBoard

/// The once-after-an-update rule. Every test drives the announcer against its own `UserDefaults`
/// suite, so a run can read back what the previous run wrote — which is the only way to tell
/// "shows once" from "shows every launch" — without the developer's own defaults being involved.
final class ReleaseNotesAnnouncerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "agentboard-release-notes-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func version(_ text: String) throws -> ReleaseVersion {
        try XCTUnwrap(ReleaseVersion(text))
    }

    /// A build whose `RELEASES.md` names `versions`, running as `running`.
    private func state(running: String, versions: [String]) throws -> ReleaseNotesState {
        .loaded(
            ReleaseNotes(
                appVersion: try version(running),
                entries: try versions.map { ReleaseNotesEntry(version: try version($0), body: "Notes for \($0).") }
            )
        )
    }

    private func announce(_ state: ReleaseNotesState) -> Bool {
        ReleaseNotesAnnouncer(state: state, defaults: defaults).announceOnLaunch()
    }

    private var recorded: String? { defaults.string(forKey: ReleaseNotesAnnouncer.key) }

    // MARK: the four cases the rule hinges on

    /// The case that costs every new user a window if it is read as an upgrade: no record at all
    /// means this install is new, not that a release went unseen.
    func testAFirstEverLaunchShowsNothingAndRecordsTheRunningVersion() throws {
        XCTAssertNil(recorded, "the suite was not empty before the first launch")
        XCTAssertFalse(announce(try state(running: "0.1.0", versions: ["0.1.0"])))
        XCTAssertEqual(recorded, "0.1.0")
    }

    /// The other half of that pair: a record from an older version is an upgrade, and an upgrade is
    /// the one case that shows anything.
    func testAnUpgradeShowsTheNotesOnceAndTheNextLaunchIsQuiet() throws {
        defaults.set("0.1.0", forKey: ReleaseNotesAnnouncer.key)
        let upgraded = try state(running: "0.2.0", versions: ["0.2.0", "0.1.0"])
        XCTAssertTrue(announce(upgraded), "the first launch after an update must show the notes")
        XCTAssertEqual(recorded, "0.2.0")
        XCTAssertFalse(announce(upgraded), "the notes came back at the same version")
        XCTAssertFalse(announce(upgraded), "the notes came back at the same version")
        XCTAssertEqual(recorded, "0.2.0")
    }

    /// `0.10.0` is above `0.9.0` numerically and below it as a string, so this also pins that the
    /// decision goes through `ReleaseVersion` and not a text compare.
    func testAnUpgradePastATenthMinorIsStillAnUpgrade() throws {
        defaults.set("0.9.0", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertTrue(announce(try state(running: "0.10.0", versions: ["0.10.0", "0.9.0"])))
        XCTAssertEqual(recorded, "0.10.0")
    }

    /// Running an older build does not un-show notes the human has already been given, and must not
    /// rewrite the record downward — doing so would show 0.3.0's notes a second time on the way back.
    func testADowngradeShowsNothingAndLeavesTheRecordAlone() throws {
        defaults.set("0.3.0", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertFalse(announce(try state(running: "0.2.0", versions: ["0.3.0", "0.2.0", "0.1.0"])))
        XCTAssertEqual(recorded, "0.3.0")
    }

    /// An upgrade the author wrote no entry for. Nothing to show, but the record still moves: left
    /// behind, this version would be re-decided on every launch until one with notes arrives.
    func testAVersionWithNoEntryShowsNothingButStillRecordsIt() throws {
        defaults.set("0.1.0", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertFalse(announce(try state(running: "0.2.0", versions: ["0.1.0"])))
        XCTAssertEqual(recorded, "0.2.0")
    }

    // MARK: the states that carry no trustworthy version

    /// The bare `AgentBoard` binary. No `CFBundleShortVersionString` and no bundled notes, so there
    /// is nothing to compare and nothing to write.
    func testAnUnbundledBuildDoesNothingAtAll() {
        XCTAssertFalse(announce(.unavailable))
        XCTAssertNil(recorded)
    }

    /// A bundled build whose notes will not parse. Recording here would swallow the notes for good:
    /// the next build fixes `RELEASES.md` and finds the version already marked as shown.
    func testAnUnreadableNotesFileLeavesTheRecordUntouched() {
        defaults.set("0.1.0", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertFalse(announce(.failed("RELEASES.md line 4: '## Unreleased' is not '## <version>'.")))
        XCTAssertEqual(recorded, "0.1.0")
    }

    /// A record this build cannot parse is treated as no record: silent, and overwritten with
    /// something readable. Showing the notes instead would fire on a value nobody can reason about.
    func testAnUnreadableRecordIsTreatedAsAFirstLaunch() throws {
        defaults.set("not-a-version", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertFalse(announce(try state(running: "0.2.0", versions: ["0.2.0"])))
        XCTAssertEqual(recorded, "0.2.0")
    }

    // MARK: the store itself

    /// The injected suite is the only thing written. `UserDefaults.standard` here is the xctest
    /// runner's own domain, and this asserts it comes out of a full upgrade run exactly as it went in.
    func testTheInjectedStoreIsUsedAndTheProcessDefaultsAreUntouched() throws {
        let before = UserDefaults.standard.object(forKey: ReleaseNotesAnnouncer.key)
        XCTAssertNil(before, "the process defaults already held the key; this test cannot prove anything")

        defaults.set("0.1.0", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertTrue(announce(try state(running: "0.2.0", versions: ["0.2.0", "0.1.0"])))

        XCTAssertEqual(defaults.string(forKey: ReleaseNotesAnnouncer.key), "0.2.0")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: ReleaseNotesAnnouncer.key),
            "the announcer wrote to the process defaults instead of the store it was handed"
        )
    }

    /// The suite is a real persistent domain, not a dictionary that forgets: a second announcer
    /// built over the same suite name reads what the first one wrote.
    func testTheRecordSurvivesANewAnnouncerOverTheSameStore() throws {
        let upgraded = try state(running: "0.2.0", versions: ["0.2.0", "0.1.0"])
        defaults.set("0.1.0", forKey: ReleaseNotesAnnouncer.key)
        XCTAssertTrue(ReleaseNotesAnnouncer(state: upgraded, defaults: defaults).announceOnLaunch())

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(ReleaseNotesAnnouncer(state: upgraded, defaults: reopened).lastShown, try version("0.2.0"))
        XCTAssertFalse(ReleaseNotesAnnouncer(state: upgraded, defaults: reopened).announceOnLaunch())
    }

    // MARK: the decision as a value

    /// `decide` is what the four cases above actually turn on, stated once as a table so a future
    /// change to `announceOnLaunch` cannot quietly move a branch.
    func testTheDecisionTable() throws {
        let running = try state(running: "0.2.0", versions: ["0.2.0", "0.1.0"])
        let noEntry = try state(running: "0.2.0", versions: ["0.1.0"])
        let two = try version("0.2.0")

        XCTAssertEqual(
            ReleaseNotesAnnouncer.decide(state: running, lastShown: nil),
            ReleaseNotesAnnouncement(opensNotes: false, records: two)
        )
        XCTAssertEqual(
            ReleaseNotesAnnouncer.decide(state: running, lastShown: try version("0.1.0")),
            ReleaseNotesAnnouncement(opensNotes: true, records: two)
        )
        XCTAssertEqual(
            ReleaseNotesAnnouncer.decide(state: running, lastShown: two), .quiet
        )
        XCTAssertEqual(
            ReleaseNotesAnnouncer.decide(state: running, lastShown: try version("0.3.0")), .quiet
        )
        XCTAssertEqual(
            ReleaseNotesAnnouncer.decide(state: noEntry, lastShown: try version("0.1.0")),
            ReleaseNotesAnnouncement(opensNotes: false, records: two)
        )
        XCTAssertEqual(ReleaseNotesAnnouncer.decide(state: .unavailable, lastShown: nil), .quiet)
        XCTAssertEqual(ReleaseNotesAnnouncer.decide(state: .failed("bad"), lastShown: nil), .quiet)
    }
}
