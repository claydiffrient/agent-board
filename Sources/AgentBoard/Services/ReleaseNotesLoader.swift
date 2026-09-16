import AgentBoardCore
import Foundation

/// The running version and every release the build ships notes for, newest first.
struct ReleaseNotes: Equatable {
    let appVersion: ReleaseVersion
    let entries: [ReleaseNotesEntry]

    /// The entry for the version that is actually running, if the author wrote one.
    var current: ReleaseNotesEntry? { entries.first { $0.version == appVersion } }
}

/// What the app has to show for release notes.
enum ReleaseNotesState: Equatable {
    /// Not running from a `.app`, so there is no `CFBundleShortVersionString` and no bundled
    /// `RELEASES.md`. This is the documented `.build/debug/AgentBoard` E2E run: nothing to show and
    /// nothing wrong. Callers hide the entry point rather than opening an empty window.
    case unavailable
    /// A bundled build whose notes could not be read. The string is a sentence naming the line, and
    /// must be displayed — a build that ships an unparsable file has to say so.
    case failed(String)
    case loaded(ReleaseNotes)
}

enum ReleaseNotesLoader {
    static let resourceName = "RELEASES"
    static let resourceExtension = "md"

    static func load(from bundle: Bundle = .main) -> ReleaseNotesState {
        guard AppBundle.isAppBundle(bundle) else { return .unavailable }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let short, let appVersion = ReleaseVersion(short) else {
            return .failed(
                "Info.plist has no readable CFBundleShortVersionString"
                    + (short.map { " (found '\($0)')" } ?? "") + "."
            )
        }
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            return .failed("This build ships no \(resourceName).\(resourceExtension).")
        }
        let markdown: String
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return .failed("\(resourceName).\(resourceExtension) could not be read: \(error.localizedDescription)")
        }
        do {
            return .loaded(ReleaseNotes(appVersion: appVersion, entries: try ReleaseNotesParser.parse(markdown)))
        } catch let error as ReleaseNotesParseError {
            return .failed(error.description)
        } catch {
            return .failed("\(resourceName).\(resourceExtension) could not be parsed: \(error)")
        }
    }
}
