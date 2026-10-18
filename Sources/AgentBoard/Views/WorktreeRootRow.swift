import AgentBoardCore
import AgentBoardRuntime
import AppKit
import SwiftUI

/// Project settings' worktree root (SPEC §4). It is set only through a folder picker or the default,
/// never typed: typing is how `~` and space-containing roots were stored.
struct WorktreeRootRow: View {
    @Binding var root: String
    let projectId: String

    var body: some View {
        LabeledContent("Worktree root") {
            HStack {
                Text(Self.displayPath(root))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .help(root)
                Button("Choose\u{2026}", action: choose)
                Button("Use Default") { root = Self.defaultPath(projectId: projectId) }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder this project's worktrees are created in."
        panel.directoryURL = Self.panelStart(for: root)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        root = Self.storedPath(url)
    }

    static func storedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func defaultPath(
        projectId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        storedPath(SupportPaths.worktreeRoot(projectId: projectId, environment: environment, home: home))
    }

    static func displayPath(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// The root itself when it exists, else its nearest existing ancestor, so the panel never opens
    /// somewhere unrelated for a root that has not been created yet.
    static func panelStart(
        for root: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        var url = WorktreeRootRule.url(root, home: home).standardizedFileURL
        while url.path != "/" {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }
}
