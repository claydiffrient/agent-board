import SwiftUI

@main
struct AgentBoardApp: App {
    @State private var appEnvironment = AppComposition.make()

    init() {
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

        WindowGroup("Terminal", id: "terminal", for: String.self) { $sessionId in
            if let sessionId {
                TerminalWindow(sessionId: sessionId)
                    .environment(appEnvironment)
            } else {
                ContentUnavailableView("No session", systemImage: "terminal")
            }
        }
        .defaultSize(width: 1100, height: 750)
    }
}
