import AgentBoardCore
import GRDB
import SwiftUI

struct ProjectSettingsSheet: View {
    let project: Project
    let workspaces: [Workspace]
    let onDeleted: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ProjectSettings
    @State private var baseBranch: String
    @State private var worktreeRoot: String
    @State private var autoModeJSON: String
    @State private var extraServers: String
    @State private var archiveMode: ArchivePolicyMode
    @State private var archiveDays: Int
    @State private var workspaceId: String?
    @State private var muteChoice: NotificationMuteChoice
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    init(project: Project, workspaces: [Workspace], onDeleted: @escaping () -> Void) {
        self.project = project
        self.workspaces = workspaces
        self.onDeleted = onDeleted
        let settings = project.settings
        _settings = State(initialValue: settings)
        _baseBranch = State(initialValue: project.baseBranch)
        _worktreeRoot = State(initialValue: project.worktreeRoot)
        _autoModeJSON = State(initialValue: settings.autoModeJSON ?? "")
        _extraServers = State(initialValue: settings.extraMcpServers.joined(separator: ", "))
        _archiveMode = State(initialValue: settings.archivePolicy.mode)
        _archiveDays = State(initialValue: settings.archivePolicy.days ?? ArchivePolicy.defaultDays)
        _muteChoice = State(initialValue: NotificationMuteChoice(settings.notifications.mute))
        let assigned = project.workspaceId
        _workspaceId = State(initialValue: workspaces.contains { $0.id == assigned } ? assigned : nil)
    }

    private var worktreeRootComplaint: String? {
        do {
            try WorktreeRootRule.validate(worktreeRoot)
            return nil
        } catch {
            return errorText(error)
        }
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
                    if let complaint = worktreeRootComplaint {
                        Text(complaint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Workspace") {
                    Picker("Workspace", selection: $workspaceId) {
                        Text("None").tag(String?.none)
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(String?.some(workspace.id))
                        }
                    }
                    Text("Groups this project in the sidebar. Optional \u{2014} an ungrouped project works the same.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section("Verification") {
                    TextField("Build command", text: Binding(
                        get: { settings.buildCommand ?? "" },
                        set: { settings.buildCommand = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("e.g. swift build"))
                    TextField("Test command", text: Binding(
                        get: { settings.testCommand ?? "" },
                        set: { settings.testCommand = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("e.g. swift test"))
                    Text("How this project builds and tests itself. Handed to every worker and to the integrator; left empty, they work it out from the repo and report what they ran.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Isolation") {
                    Picker("Worktree strategy", selection: $settings.worktreeStrategy) {
                        ForEach(WorktreeStrategy.allCases, id: \.self) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    TextField("Agents in the shared checkout", value: $settings.sharedCheckoutMaxAgents, format: .number)
                    Text("A worktree per task is the default and always isolates. Shared runs workers in this project's own checkout on one branch, skipping a full repository setup per task; Auto shares only when a compatible group already holds the checkout. A task that cannot join gets a worktree. Co-resident agents take a per-file lock before every write, so a collision is a wait rather than an overwrite.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Publishing") {
                    TextField("Remote branch name", text: Binding(
                        get: { settings.remoteBranchTemplate ?? "" },
                        set: { settings.remoteBranchTemplate = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("e.g. clay/{slug}"))
                    Text("The name a branch takes on the remote. \(RemoteBranchTemplate.slugToken) comes from the epic's or task's title; \(RemoteBranchTemplate.idToken) is an optional short id. The local branch stays agentboard/<id> either way. Left empty, the local name is what reaches the remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Archive") {
                    Picker("Archive done tasks", selection: $archiveMode) {
                        ForEach(ArchivePolicyMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    TextField("Days in done", value: $archiveDays, format: .number)
                        .disabled(archiveMode != .afterDays)
                        .foregroundStyle(archiveMode == .afterDays ? .primary : .secondary)
                    Text("Archived tasks are hidden from the board, never deleted. The Task Board's Archive button works under every mode; turn on Show Archived there to bring them back into view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    ForEach(NotificationCategory.allCases) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { settings.notifications.isEnabled(category) },
                            set: { settings.notifications.setEnabled(category, $0) }
                        ))
                    }
                    Picker("Mute this project", selection: $muteChoice) {
                        ForEach(NotificationMuteChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    Text("Every category is on by default. Turning one off, or muting the project, stops the banner only — this project keeps its sidebar badge and its place in At a Glance, so you can still find what is waiting.")
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

                Section {
                    Button("Delete Project…", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!autoModeJSONIsValid || baseBranch.isEmpty || worktreeRootComplaint != nil)
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

    private func save() {
        var updated = settings
        updated.buildCommand = VerificationCommands(build: settings.buildCommand).build
        updated.testCommand = VerificationCommands(test: settings.testCommand).test
        updated.archivePolicy = ArchivePolicy.make(mode: archiveMode, days: archiveDays)
        updated.notifications.mute = muteChoice.mute(existing: settings.notifications.mute)
        let trimmedJSON = autoModeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.autoModeJSON = trimmedJSON.isEmpty ? nil : trimmedJSON
        updated.extraMcpServers = extraServers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try WorktreeRootRule.validate(worktreeRoot)
            try ProjectStore(env.db).updateSettings(project.id, updated)
            try WorkspaceStore(env.db).assign(projectId: project.id, workspaceId: workspaceId)
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
