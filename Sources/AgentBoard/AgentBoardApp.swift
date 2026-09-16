import SwiftUI

@main
struct AgentBoardApp: App {
    @State private var appEnvironment = AppComposition.make()

    init() {
        MenuProbe.runIfRequested()
        if let repo = ProcessInfo.processInfo.environment["AGENTBOARD_E2E_REPO"] {
            let environment = appEnvironment
            _Concurrency.Task { await E2E.run(environment, repo: URL(fileURLWithPath: repo)) }
        }
    }

    var body: some Scene {
        WindowGroup("Agent Board") {
            MainWindow()
                .environment(appEnvironment)
        }
        .commands {
            // `after:`, not `replacing:`. Measured through `MenuProbe`: this app's `.help` group
            // holds two items, "AgentBoard Help" and "Toggle Sidebar" (⌃⌘S) — SwiftUI puts the
            // sidebar command here rather than in View, which is empty — and `replacing:` deletes
            // both, taking a working keyboard shortcut with it.
            CommandGroup(after: .help) {
                ReleaseNotesMenuItem()
            }
        }

        Window(ReleaseNotesScene.title, id: ReleaseNotesScene.id) {
            ReleaseNotesWindow(state: appEnvironment.releaseNotes.state)
        }
        .defaultSize(width: 620, height: 680)

        WindowGroup("Terminal", id: "terminal", for: String.self) { $sessionId in
            if let sessionId {
                TerminalWindow(sessionId: sessionId)
                    .environment(appEnvironment)
            } else {
                ContentUnavailableView("No session", systemImage: "terminal")
            }
        }
        .defaultSize(width: 1100, height: 750)

        WindowGroup("Worktree Shell", id: "worktree-shell", for: String.self) { $sessionId in
            if let sessionId {
                WorktreeShellWindow(sessionId: sessionId)
                    .environment(appEnvironment)
            } else {
                ContentUnavailableView("No session", systemImage: "apple.terminal")
            }
        }
        .defaultSize(width: 1000, height: 700)
    }
}

/// A `Window` rather than a `WindowGroup`: the scene type is what makes a second `openWindow(id:)`
/// bring the existing window forward instead of stacking another copy.
enum ReleaseNotesScene {
    static let id = "release-notes"
    /// macOS convention for this item — Apple's own apps put "What's New in <App>" in Help, and it
    /// is what someone scans the menu for after an update. "Release Notes" reads as a build artifact.
    static let title = "What's New in Agent Board"
}

private struct ReleaseNotesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(ReleaseNotesScene.title) { openWindow(id: ReleaseNotesScene.id) }
    }
}
