import AgentBoardCore
import GRDB
import SwiftUI

struct ProjectSettingsSheet: View {
    let project: Project
    let onDeleted: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ProjectSettings
    @State private var baseBranch: String
    @State private var worktreeRoot: String
    @State private var autoModeJSON: String
    @State private var extraServers: String
    @State private var confirmDelete = false
    @State private var roster = Observed<[RosterAgent]>([])
    @State private var selectedAgentIds: Set<String> = []
    @State private var errorMessage: String?

    init(project: Project, onDeleted: @escaping () -> Void) {
        self.project = project
        self.onDeleted = onDeleted
        let settings = project.settings
        _settings = State(initialValue: settings)
        _baseBranch = State(initialValue: project.baseBranch)
        _worktreeRoot = State(initialValue: project.worktreeRoot)
        _autoModeJSON = State(initialValue: settings.autoModeJSON ?? "")
        _extraServers = State(initialValue: settings.extraMcpServers.joined(separator: ", "))
    }

    private var autoModeJSONIsValid: Bool {
        let trimmed = autoModeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Repository") {
                    LabeledContent("Path", value: project.repoPath)
                    TextField("Base branch", text: $baseBranch)
                    TextField("Worktree root", text: $worktreeRoot)
                }

                Section("Caps") {
                    TextField("Concurrent workers", value: $settings.caps.maxConcurrentWorkers, format: .number)
                    TextField("Tokens per agent", value: $settings.caps.maxTokensPerAgent, format: .number, prompt: Text("Unlimited"))
                    TextField("Wall clock per agent (seconds)", value: $settings.caps.maxWallClockSeconds, format: .number)
                    TextField("Idle limit (seconds)", value: $settings.caps.maxIdleSeconds, format: .number)
                    TextField("Stalled after (seconds)", value: $settings.caps.stallSeconds, format: .number)
                    TextField("Project session ceiling", value: $settings.caps.sessionCeiling, format: .number, prompt: Text("Unlimited"))
                }

                Section("Models") {
                    ModelPicker(label: "Default model", inheritLabel: "Claude Code default", model: $settings.defaultModel)
                    LabeledContent("Model guidance") {
                        TextEditor(text: Binding(
                            get: { settings.modelGuidance ?? "" },
                            set: { settings.modelGuidance = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.body)
                        .frame(minHeight: 80)
                    }
                    Text("Read by the orchestrator when it picks a model per task, e.g. \"Sonnet 5 for docs and tests, Opus 5 for features.\" A task's own model overrides the default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Autonomy") {
                    Toggle("Autonomy (spawn without approval)", isOn: $settings.autonomyEnabled)
                    Text("Off by default. While off, every orchestrator spawn waits for your approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Permission classifier (autoMode)") {
                    TextEditor(text: $autoModeJSON)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                    if !autoModeJSONIsValid {
                        Text("Not valid JSON.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Extra MCP servers") {
                    TextField("Comma-separated server names", text: $extraServers)
                    Text("Globally configured servers merged back into workers past --strict-mcp-config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Roster") {
                    rosterSelection
                }

                Section {
                    Button("Delete Project…", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
            .task {
                await roster.run(RosterStore(env.db).observe(), in: env.db.reader)
            }
            .task(id: roster.value.map(\.id)) {
                reloadSelection()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!autoModeJSONIsValid || baseBranch.isEmpty || worktreeRoot.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 620)
        .navigationTitle("\(project.name) Settings")
        .confirmationDialog(
            "Delete \(project.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) { deleteProject() }
        } message: {
            Text("Removes the project, its tasks, and session records from Agent Board. Worktrees and branches on disk are left alone.")
        }
        .errorAlert($errorMessage)
    }

    /// The whole roster with a toggle each: on writes the project's opt-in, off writes the opt-out.
    /// Both land immediately rather than on Save, because they are per-project join rows and not
    /// part of the settings blob the Save button rewrites.
    @ViewBuilder
    private var rosterSelection: some View {
        if roster.value.isEmpty {
            Text("No rostered agents yet. Add them in the Roster tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let split = RosterListing.partition(roster: roster.value, selectedIds: selectedAgentIds)
            ForEach(split.selected + split.available) { agent in
                Toggle(isOn: Binding(
                    get: { selectedAgentIds.contains(agent.id) },
                    set: { setSelected(agent, $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                            Text(agent.role)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !agent.enabled {
                            Text("Disabled in the roster; this project will not spawn it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("\(split.selected.count) of \(roster.value.count) selected for \(project.name). Other projects are unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadSelection() {
        do {
            selectedAgentIds = Set(try RosterStore(env.db).agents(forProject: project.id).map(\.id))
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func setSelected(_ agent: RosterAgent, _ selected: Bool) {
        let store = RosterStore(env.db)
        do {
            if selected {
                try store.enable(agentId: agent.id, forProject: project.id)
            } else {
                try store.disable(agentId: agent.id, forProject: project.id)
            }
            reloadSelection()
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func save() {
        var updated = settings
        let trimmedJSON = autoModeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.autoModeJSON = trimmedJSON.isEmpty ? nil : trimmedJSON
        updated.extraMcpServers = extraServers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try ProjectStore(env.db).updateSettings(project.id, updated)
            try env.db.writer.write { db in
                try db.execute(
                    sql: "UPDATE project SET base_branch = ?, worktree_root = ? WHERE id = ?",
                    arguments: [baseBranch, worktreeRoot, project.id]
                )
            }
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func deleteProject() {
        do {
            try ProjectStore(env.db).delete(project.id)
            onDeleted()
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }
}
