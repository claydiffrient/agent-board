import AgentBoardCore
import Foundation

/// What a launch does about the release notes: whether the window opens on its own, and what to
/// write down afterwards. `records` is nil when the record must be left exactly as it was.
struct ReleaseNotesAnnouncement: Equatable {
    let opensNotes: Bool
    let records: ReleaseVersion?

    static let quiet = ReleaseNotesAnnouncement(opensNotes: false, records: nil)
}

/// Shows the release notes once after an update and never again for that version. SPEC §10.
///
/// The store is injected because the rule is only testable by driving it twice, and the second run
/// has to see what the first wrote without either run touching the developer's own defaults.
struct ReleaseNotesAnnouncer {
    /// Per-user app state, so `UserDefaults` rather than the board database: one string does not
    /// justify a schema migration, and this is not something a second machine should inherit.
    static let key = "releaseNotesLastShownVersion"

    let state: ReleaseNotesState
    let defaults: UserDefaults

    init(state: ReleaseNotesState = ReleaseNotesLoader.load(), defaults: UserDefaults = .standard) {
        self.state = state
        self.defaults = defaults
    }

    /// Nil for a first ever launch — and equally for a record this build cannot parse, which is
    /// treated as no record rather than as something to reason about.
    var lastShown: ReleaseVersion? {
        defaults.string(forKey: Self.key).flatMap(ReleaseVersion.init)
    }

    /// SPEC §10, as a value so every branch is assertable without a window or a scene.
    ///
    /// Nothing at all for `.unavailable` and `.failed`, the record included: neither carries a
    /// version worth trusting, and burning the record on a build whose `RELEASES.md` will not
    /// parse would swallow those notes for good once the file is fixed.
    static func decide(
        state: ReleaseNotesState, lastShown: ReleaseVersion?
    ) -> ReleaseNotesAnnouncement {
        guard case let .loaded(notes) = state else { return .quiet }
        let running = notes.appVersion
        // No record is a first ever install, never an unseen upgrade: silent, and recorded.
        guard let lastShown else {
            return ReleaseNotesAnnouncement(opensNotes: false, records: running)
        }
        // Equal is quiet; below is a downgrade, which must not rewrite the record downward.
        guard lastShown < running else { return .quiet }
        return ReleaseNotesAnnouncement(opensNotes: notes.current != nil, records: running)
    }

    /// Applies the decision and answers whether to open the window. Shown counts as shown the
    /// moment this returns true — whether the window was read is not something to detect.
    func announceOnLaunch() -> Bool {
        let announcement = Self.decide(state: state, lastShown: lastShown)
        if let version = announcement.records {
            defaults.set("\(version)", forKey: Self.key)
        }
        return announcement.opensNotes
    }
}
