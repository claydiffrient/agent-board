import Foundation

/// Whether this process is running from a `.app`. `README.md` documents `.build/debug/AgentBoard`
/// as the E2E entry point, and that binary has no `Info.plist` and no resource directory, so
/// anything that reads either has to ask first. `MacNotifier` and `ReleaseNotesLoader` share this
/// one answer rather than each inventing a test.
enum AppBundle {
    static func isAppBundle(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleIdentifier != nil && bundle.bundleURL.pathExtension == "app"
    }
}
