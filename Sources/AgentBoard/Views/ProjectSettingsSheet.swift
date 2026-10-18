import AgentBoardCore
import AgentBoardRuntime
import GRDB
import SwiftUI

/// The sheet's tabs (SPEC §10, Project settings). Every `ProjectSettingsSection` belongs to exactly
/// one, which `ProjectSettingsTabTests` pins; a section in no tab is a setting with no UI.
enum ProjectSettingsTab: String, CaseIterable, Identifiable {
    case general, agents, limits, workflow, notifications, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .limits: "Limits"
        case .workflow: "Workflow"
        case .notifications: "Notifications"
        case .advanced: "Advanced"
        }
    }

    var sections: [ProjectSettingsSection] {
        switch self {
        case .general: [.repository, .workspace, .archive]
        case .agents: [.models, .review, .autonomy, .roster]
        case .limits: [.caps]
        case .workflow: [.verification, .teardown, .isolation, .publishing]
        case .notifications: [.notifications]
        case .advanced: [.autoMode, .extraMcpServers]
        }
    }
}

enum ProjectSettingsSection: String, CaseIterable, Identifiable {
    case repository, workspace, caps, models, review, verification, teardown, isolation, publishing
    case archive, notifications, autonomy, autoMode, extraMcpServers, roster

    var id: Self { self }

    var title: String {
        switch self {
        case .repository: "Repository"
        case .workspace: "Workspace"
        case .caps: "Caps"
        case .models: "Models"
        case .review: "Review"
        case .verification: "Verification"
        case .teardown: "Worktree teardown"
        case .isolation: "Isolation"
        case .publishing: "Publishing"
        case .archive: "Archive"
        case .notifications: "Notifications"
        case .autonomy: "Autonomy"
        case .autoMode: "Permission classifier (autoMode)"
        case .extraMcpServers: "Extra MCP servers"
        case .roster: "Roster"
        }
    }
}

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
    @State private var tab: ProjectSettingsTab
    @State private var confirmDelete = false
    @State private var roster = Observed<[RosterAgent]>([])
    @State private var archetypes: [Archetype] = []
    @State private var selectedAgentIds: Set<String> = []
    @State private var projectAgents: [RosterAgent] = []
    @State private var errorMessage: String?
    @State private var integrationDefault: StandaloneIntegration?

    init(
        project: Project,
        workspaces: [Workspace],
        initialTab: ProjectSettingsTab = .general,
        onDeleted: @escaping () -> Void
    ) {
        self.project = project
        self.workspaces = workspaces
        self.onDeleted = onDeleted
        let settings = project.settings
        _settings = State(initialValue: settings)
        _tab = State(initialValue: initialTab)
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
            TabView(selection: $tab) {
                ForEach(ProjectSettingsTab.allCases) { tab in
                    Form {
                        ForEach(tab.sections) { section in
                            Section(section.title) { content(for: section) }
                        }
                    }
                    .formStyle(.grouped)
                    .tabItem { Text(tab.title) }
                    .tag(tab)
                }
            }
            .padding([.horizontal, .top])
            .task {
                await roster.run(RosterStore(env.db).observe(), in: env.db.reader)
            }
            .task(id: roster.value) {
                reloadSelection()
            }

            HStack {
                Button("Delete Project…", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!autoModeJSONIsValid || baseBranch.isEmpty || worktreeRootComplaint != nil)
            }
            .padding()
        }
        .frame(minWidth: 780, minHeight: 480)
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

    static func defaultIntegrationTitle(_ resolved: StandaloneIntegration?) -> String {
        switch resolved {
        case .pullRequest: "Pull request (default: has origin)"
        case .localMerge: "Local merge (default: no origin)"
        case nil: "Default"
        }
    }

    @ViewBuilder
    private func content(for section: ProjectSettingsSection) -> some View {
        switch section {
        case .repository:
            LabeledContent("Path", value: project.repoPath)
            TextField("Base branch", text: $baseBranch)
            TextField("Worktree root", text: $worktreeRoot)
            if let complaint = worktreeRootComplaint {
                Text(complaint)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .workspace:
            Picker("Workspace", selection: $workspaceId) {
                Text("None").tag(String?.none)
                ForEach(workspaces) { workspace in
                    Text(workspace.name).tag(String?.some(workspace.id))
                }
            }
            Text("Groups this project in the sidebar. Optional \u{2014} an ungrouped project works the same.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .caps:
            TextField("Concurrent workers", value: $settings.caps.maxConcurrentWorkers, format: .number)
            TextField("Tokens per agent", value: $settings.caps.maxTokensPerAgent, format: .number, prompt: Text("Unlimited"))
            TextField("Wall clock per agent (seconds)", value: $settings.caps.maxWallClockSeconds, format: .number)
            TextField("Idle limit (seconds)", value: $settings.caps.maxIdleSeconds, format: .number)
            TextField("Stalled after (seconds)", value: $settings.caps.stallSeconds, format: .number)
            TextField("Project session ceiling", value: $settings.caps.sessionCeiling, format: .number, prompt: Text("Unlimited"))
        case .models:
            ModelPicker(label: "Default model", inheritLabel: "Claude Code default", model: $settings.defaultModel)
            VStack(alignment: .leading, spacing: 6) {
                Text("Model guidance")
                TextEditor(text: Binding(
                    get: { settings.modelGuidance ?? "" },
                    set: { settings.modelGuidance = $0.isEmpty ? nil : $0 }
                ))
                .font(.body)
                .frame(minHeight: 100)
                .accessibilityLabel("Model guidance")
            }
            Text("Read by the orchestrator when it picks a model per task, e.g. \"Sonnet 5 for docs and tests, Opus 5 for features.\" A task's own model overrides the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .review:
            Picker("Review level", selection: $settings.reviewLevel) {
                ForEach(ReviewLevel.allCases, id: \.self) { level in
                    Text(level.label).tag(level)
                }
            }
            Text(Self.reviewLevelBlurb(settings.reviewLevel))
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                routingRow(nil)
                ForEach(TaskType.allCases, id: \.self) { type in
                    routingRow(type)
                }
            }
            .disabled(settings.reviewLevel != .agent)
            Text("Who reviews each type of task. Applies only while Review level is Agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .verification:
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
        case .teardown:
            TextField("Teardown command", text: Binding(
                get: { settings.worktreeTeardownCommand ?? "" },
                set: { settings.worktreeTeardownCommand = $0.isEmpty ? nil : $0 }
            ), prompt: Text("e.g. [ \"$(bazel info workspace)\" = \"$PWD\" ] && bazel clean --expunge"))
            TextField("Teardown timeout (seconds)", value: $settings.worktreeTeardownTimeoutSeconds, format: .number)
            Text("Runs in a task's or epic's worktree, as its working directory, just before Agent Board removes it, to clean up what tools built for it elsewhere: a Bazel output base, a Docker volume. Left empty, removal deletes the worktree and nothing else. A failure or timeout never stops the removal; it is recorded on the task and in the decision report. It does not run on a worktree kept for uncommitted changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .isolation:
            Picker("Worktree strategy", selection: $settings.worktreeStrategy) {
                ForEach(WorktreeStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }
            TextField("Agents in the shared checkout", value: $settings.sharedCheckoutMaxAgents, format: .number)
            Text("A worktree per task is the default and always isolates. Shared runs workers in this project's own checkout on one branch, skipping a full repository setup per task; Auto shares only when a compatible group already holds the checkout. A task that cannot join gets a worktree. Co-resident agents take a per-file lock before every write, so a collision is a wait rather than an overwrite.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .publishing:
            Picker("Integrate standalone tasks and epics by", selection: $settings.standaloneIntegration) {
                Text(Self.defaultIntegrationTitle(integrationDefault)).tag(StandaloneIntegration?.none)
                ForEach(StandaloneIntegration.allCases, id: \.self) { integration in
                    Text(integration.title).tag(StandaloneIntegration?.some(integration))
                }
            }
            .task {
                let publisher = BranchPublisher(repoPath: URL(fileURLWithPath: project.repoPath))
                integrationDefault = await _Concurrency.Task.detached {
                    publisher.defaultStandaloneIntegration()
                }.value
            }
            TextField("Remote branch name", text: Binding(
                get: { settings.remoteBranchTemplate ?? "" },
                set: { settings.remoteBranchTemplate = $0.isEmpty ? nil : $0 }
            ), prompt: Text("e.g. clay/{slug}"))
            Text("The name a branch takes on the remote. \(RemoteBranchTemplate.slugToken) comes from the epic's or task's title; \(RemoteBranchTemplate.idToken) is an optional short id. The local branch stays agentboard/<id> either way. Left empty, the local name is what reaches the remote. By pull request, accepting a task in no epic merges nothing, and it is marked landed once its recorded pull request merges on GitHub; local merge merges it into the base branch on accept. The default is pull request when the repository has an origin remote and local merge when it has none. A task in an epic always merges into its epic branch. By pull request, an epic stays open after its integration and closes when its pull request merges; by local merge, its integration closes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .archive:
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
        case .notifications:
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
        case .autonomy:
            Toggle("Autonomy (spawn without approval)", isOn: $settings.autonomyEnabled)
            Text("Off by default. While off, every orchestrator spawn waits for your approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .autoMode:
            PlainTextEditor(text: $autoModeJSON)
                .frame(minHeight: 280)
            if !autoModeJSONIsValid {
                Text("Not valid JSON.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .extraMcpServers:
            TextField("Comma-separated server names", text: $extraServers)
            Text("Globally configured servers merged back into workers past --strict-mcp-config.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .roster:
            rosterSelection
        }
    }

    /// One row of the review routing table; `nil` is the Default row.
    private func routingRow(_ type: TaskType?) -> some View {
        let current = Self.routingAssignee(settings.reviewRouting, type: type)
        return Picker(type?.label ?? "Default", selection: Binding(
            get: { Self.reviewerChoice(current) },
            set: { choice in
                Self.setRouting(&settings.reviewRouting, type: type, to: choice, projectAgents: projectAgents)
            }
        )) {
            ForEach(Self.reviewerOptions(
                projectAgents: projectAgents, current: current?.namedChoice, sameAsDefault: type != nil
            )) { option in
                Text(option.title).tag(option.choice)
            }
        }
    }

    /// Every archetype this project could use, with a toggle each: on writes the project's opt-in,
    /// off writes the opt-out. Both land immediately rather than on Save, because they are
    /// per-project join rows and not part of the settings blob the Save button rewrites.
    @ViewBuilder
    private var rosterSelection: some View {
        if archetypes.isEmpty {
            Text("No archetypes yet. Add one in the Roster tab, or define one in ~/.claude/agents or this repository's .claude/agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let selected = archetypes.filter { selectedAgentIds.contains($0.agent.id) }
            ForEach(selected + archetypes.filter { !selectedAgentIds.contains($0.agent.id) }) { archetype in
                let agent = archetype.agent
                Toggle(isOn: Binding(
                    get: { selectedAgentIds.contains(agent.id) },
                    set: { setSelected(agent, $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.name)
                            if archetype.source.isEditable {
                                Text(agent.role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ArchetypeSourceChip(source: archetype.source)
                        }
                        ArchetypeProvenance(archetype: archetype)
                        if !agent.enabled {
                            Text("Disabled in the roster; this project will not spawn it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(archetype.shadowedBy != nil && !selectedAgentIds.contains(agent.id))
            }
            Text("\(selected.count) of \(archetypes.count) selected for \(project.name). Other projects are unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reloadSelection() {
        do {
            projectAgents = try env.roster.agents(forProject: project.id)
            selectedAgentIds = Set(projectAgents.map(\.id))
            archetypes = env.roster.archetypes(rows: roster.value, project: project).archetypes
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func setSelected(_ agent: RosterAgent, _ selected: Bool) {
        let store = env.roster
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
        updated.buildCommand = VerificationCommands(build: settings.buildCommand).build
        updated.testCommand = VerificationCommands(test: settings.testCommand).test
        updated.worktreeTeardownCommand = settings.worktreeTeardown?.command
        updated.worktreeTeardownTimeoutSeconds = WorktreeTeardownCommand.clampedTimeout(settings.worktreeTeardownTimeoutSeconds)
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

    /// A routing row's picker value. A named reviewer is tagged by id alone, so a rename or a departure
    /// from the roster still matches the stored choice.
    enum ReviewerChoice: Hashable {
        case sameAsDefault
        case named(agentId: String)
        case anyReviewer
        case person
        case acceptWithoutReview
    }

    struct ReviewerOption: Identifiable, Equatable {
        let choice: ReviewerChoice
        let title: String

        var id: ReviewerChoice { choice }
    }

    static let sameAsDefaultTitle = "Same as Default"
    static let anyReviewerTitle = "Any reviewer"
    static let personTitle = "A person"
    static let acceptWithoutReviewTitle = "Accept without review"

    /// The project's own agents in its roster order, then the fixed choices. A named reviewer the
    /// project no longer has stays listed, marked, so the picker shows what routing will act on
    /// rather than a blank.
    static func reviewerOptions(
        projectAgents: [RosterAgent], current: ReviewAgentChoice?, sameAsDefault: Bool
    ) -> [ReviewerOption] {
        var options = sameAsDefault ? [ReviewerOption(choice: .sameAsDefault, title: sameAsDefaultTitle)] : []
        options += projectAgents.map {
            ReviewerOption(choice: .named(agentId: $0.id), title: $0.enabled ? $0.name : "\($0.name) (disabled)")
        }
        if let current, !projectAgents.contains(where: { $0.id == current.id }) {
            options.append(ReviewerOption(choice: .named(agentId: current.id), title: "\(current.name) (not available)"))
        }
        options += [
            ReviewerOption(choice: .anyReviewer, title: anyReviewerTitle),
            ReviewerOption(choice: .person, title: personTitle),
            ReviewerOption(choice: .acceptWithoutReview, title: acceptWithoutReviewTitle),
        ]
        return options
    }

    /// A row's stored assignee; nil for a type row that is Same as Default.
    static func routingAssignee(_ table: ReviewRoutingTable, type: TaskType?) -> ReviewAssignee? {
        guard let type else { return table.defaultAssignee }
        return table.typeAssignees[type]
    }

    static func reviewerChoice(_ assignee: ReviewAssignee?) -> ReviewerChoice {
        switch assignee {
        case nil: .sameAsDefault
        case .named(let choice): .named(agentId: choice.id)
        case .anyReviewer: .anyReviewer
        case .person: .person
        case .acceptWithoutReview: .acceptWithoutReview
        }
    }

    static func setRouting(
        _ table: inout ReviewRoutingTable, type: TaskType?, to choice: ReviewerChoice, projectAgents: [RosterAgent]
    ) {
        let current = routingAssignee(table, type: type)?.namedChoice
        let assignee: ReviewAssignee?
        switch choice {
        case .sameAsDefault:
            assignee = nil
        case .named(let id):
            if let agent = projectAgents.first(where: { $0.id == id }) {
                assignee = .named(ReviewAgentChoice(id: agent.id, name: agent.name))
            } else if let current, current.id == id {
                assignee = .named(current)
            } else {
                return
            }
        case .anyReviewer:
            assignee = .anyReviewer
        case .person:
            assignee = .person
        case .acceptWithoutReview:
            assignee = .acceptWithoutReview
        }
        if let type {
            table.typeAssignees[type] = assignee
        } else if let assignee {
            table.defaultAssignee = assignee
        }
    }

    static func reviewLevelBlurb(_ level: ReviewLevel) -> String {
        switch level {
        case .none:
            return "A finished task goes straight to Done. Nobody reviews it."
        case .agent:
            return "A finished task goes where its type's row below sends it. A reviewer picks it up from "
                + "Review and either accepts it or sends it back with findings. Any agent this project uses "
                + "can be named, whatever its role; Any reviewer is the first whose role reads as reviewer. "
                + "If a named reviewer is missing, disabled or turned off here, the task waits for you and "
                + "its card says why."
        case .task:
            return "You accept every task. The default; leaving it here changes nothing."
        case .epic:
            return "A task inside an epic goes straight to Done; you review at the epic's integration "
                + "gate. A task outside an epic still waits for you."
        }
    }
}
