import AgentBoardCore
import Foundation
import SwiftUI

/// Identifies the sheet that names a workspace: `workspace` nil means "create".
struct WorkspaceEdit: Identifiable {
    let workspace: Workspace?

    var id: String { workspace?.id ?? "new" }

    static let create = WorkspaceEdit(workspace: nil)

    static func rename(_ workspace: Workspace) -> WorkspaceEdit {
        WorkspaceEdit(workspace: workspace)
    }
}

struct WorkspaceNameSheet: View {
    let edit: WorkspaceEdit
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(edit: WorkspaceEdit, onCommit: @escaping (String) -> Void) {
        self.edit = edit
        self.onCommit = onCommit
        _name = State(initialValue: edit.workspace?.name ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(edit.workspace == nil ? "New Workspace" : "Rename Workspace")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.workspace == nil ? "Create" : "Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

/// Which sidebar sections the viewer has collapsed. Per-viewer convenience, so it
/// lives in `UserDefaults` rather than the board database.
///
/// The key is a parameter because `UserDefaults.standard` under `xctest` resolves to
/// `com.apple.dt.xctest.tool` — one domain shared by every `swift test` process on the machine, and
/// several run at once here. Measured with four concurrent runs writing this key and reading it
/// straight back: 225-303 of 400 round trips came back as another process's value or empty. A test
/// gives itself a key no other process writes.
struct SidebarCollapseState {
    static let key = "sidebar.collapsedWorkspaces"
    static let standard = SidebarCollapseState()

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SidebarCollapseState.key) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func save(_ collapsed: Set<String>) {
        defaults.set(Array(collapsed).sorted(), forKey: key)
    }
}

/// What the sidebar has selected. There is no "nothing selected" case: deselecting falls back to
/// `atAGlance`, which is the app's landing view, so the detail pane is never empty.
enum SidebarSelection: Hashable {
    case atAGlance
    case project(String)

    var projectId: String? {
        if case .project(let id) = self { return id }
        return nil
    }
}
