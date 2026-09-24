import AgentBoardCore
import GRDB
import SwiftUI

struct TaskInspectorView: View {
    let task: BoardTask
    let allTasks: [BoardTask]
    let sessions: [AgentSession]
    let drafts: TaskDraftCache
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var draftBody = ""
    @State private var draftAcceptance = ""
    @State private var draftModel: String?
    @State private var deps = Observed<[String]>([])
    @State private var progress = Observed<[ProgressEntry]>([])
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    private var otherTasks: [BoardTask] {
        allTasks.filter { $0.id != task.id }
    }

    private var savedDraft: TaskDraft {
        TaskDraft(body: task.body ?? "", acceptance: task.acceptance ?? "", model: task.model)
    }

    private var currentDraft: TaskDraft {
        TaskDraft(body: draftBody, acceptance: draftAcceptance, model: draftModel)
    }

    private var hasEdits: Bool {
        currentDraft != savedDraft
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                editor("Body", text: $draftBody, minHeight: 120)
                editor("Acceptance", text: $draftAcceptance, minHeight: 80)
                ModelPicker(label: "Model", inheritLabel: "Project default", model: $draftModel)
                HStack {
                    Spacer()
                    Button("Revert") { resetDrafts() }
                        .disabled(!hasEdits)
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!hasEdits)
                }
                dependencies
                sessionList
                progressLog
                HStack {
                    if task.isArchived {
                        Button("Unarchive") { unarchive() }
                            .help("Put this task back on the board")
                    } else if task.column == .done {
                        Button("Archive") { archive() }
                            .help("Hide this task from the board. Nothing is deleted.")
                    }
                    Spacer()
                    Button("Delete Task…", role: .destructive) { confirmDelete = true }
                }
                .confirmationDialog("Delete \"\(task.title)\"?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) {
                        run { try await env.supervisor.discard(taskId: task.id) }
                    }
                } message: {
                    Text("Stops any running worker and removes its worktree. The branch is kept.")
                }
            }
            .padding()
        }
        .onChange(of: task.id, initial: true) { previousId, newId in
            if previousId != newId { retainDrafts(for: previousId) }
            loadDrafts()
        }
        .onDisappear { retainDrafts(for: task.id) }
        .onExitCommand(perform: onClose)
        .toolbar {
            ToolbarItem {
                Button(action: onClose) {
                    Label("Close Inspector", systemImage: "sidebar.trailing")
                }
                .help("Close the inspector (unsaved edits are kept)")
            }
        }
        .task(id: task.id) {
            let taskId = task.id
            let observation = ValueObservation.tracking { db -> [String] in
                try String.fetchAll(
                    db,
                    sql: "SELECT depends_on FROM task_dep WHERE task_id = ? ORDER BY depends_on",
                    arguments: [taskId]
                )
            }
            await deps.run(observation, in: env.db.reader)
        }
        .task(id: task.id) {
            await progress.run(ProgressStore(env.db).observe(taskId: task.id, limit: 200), in: env.db.reader)
        }
        .task(id: task.id) {
            guard task.column == .done, task.landing == .pullRequestOpen || task.landing == .unlanded else { return }
            await (env.supervisor as? WorkerSupervisor)?.refreshPullRequestLandings(taskId: task.id)
        }
        .errorAlert($errorMessage)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                Text(task.column.title)
                if let priority = task.priority, !priority.isEmpty {
                    PriorityChip(priority: priority)
                }
                if let model = task.model { ModelChip(model: model) }
                Text(task.origin.rawValue)
                if task.blocked { FlagBadge(text: "blocked") }
                if task.failed { FlagBadge(text: "failed") }
                if task.needsLanding { FlagBadge(text: task.landingLabel) }
                if let archived = task.archivedDate {
                    Label("archived \(Format.relative(archived))", systemImage: "archivebox")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let reason = task.blockedReason ?? task.failureReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            // Shown for every landing a `done` task has, not only the alarming ones: "nothing to
            // land" has to be readable as its own answer, or a task that never had a branch looks
            // the same as one whose branch went missing.
            if task.column == .done, let landing = task.landing {
                Text(task.landingDetail ?? landing.label)
                    .font(.caption)
                    .foregroundStyle(landing.needsAttention ? .red : .secondary)
                    .textSelection(.enabled)
            }
            Text(task.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func editor(_ label: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: minHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
        }
    }

    private var dependencies: some View {
        DisclosureGroup("Dependencies (\(deps.value.count))") {
            if otherTasks.isEmpty {
                Text("No other tasks in this project.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(otherTasks) { other in
                        Toggle(isOn: dependencyBinding(other.id)) {
                            HStack {
                                Text(other.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(other.column.title)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(.subheadline)
    }

    private func dependencyBinding(_ otherId: String) -> Binding<Bool> {
        Binding(
            get: { deps.value.contains(otherId) },
            set: { on in
                var updated = Set(deps.value)
                if on { updated.insert(otherId) } else { updated.remove(otherId) }
                do {
                    let store = TaskStore(env.db)
                    try store.setDeps(task.id, dependsOn: Array(updated))
                    try store.refreshReadiness(projectId: task.projectId)
                } catch {
                    errorMessage = errorText(error)
                }
            }
        )
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions (\(sessions.count))")
                .font(.subheadline.weight(.semibold))
            if sessions.isEmpty {
                Text("No agent has worked on this task.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ForEach(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.displayShortId)
                                .monospaced()
                            Text(session.state.label)
                                .foregroundStyle(session.state.color)
                            Text("attempt \(session.attempt)")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(Format.cost(session.estCostUSD)) · \(Format.tokens(session.totalTokens)) tok")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Spacer()
                    if session.state.isActive {
                        Button("Stop") { run { try await env.supervisor.stop(sessionId: session.sessionId) } }
                    } else {
                        Button("Resume") { run { try await env.supervisor.resume(sessionId: session.sessionId) } }
                    }
                    SessionActionButtons(session: session, showsTitle: true)
                }
                .controlSize(.small)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private var progressLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Progress")
                .font(.subheadline.weight(.semibold))
            if progress.value.isEmpty {
                Text("No progress recorded.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ForEach(progress.value) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Text(entry.kind.rawValue)
                        .foregroundStyle(entry.kind == .error ? .red : .secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(entry.text)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text(entry.date, style: .time)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
    }

    private func resetDrafts() {
        apply(savedDraft)
        drafts.clear(task.id)
    }

    /// Restores whatever was typed before the tray was last closed, falling back to the saved task.
    private func loadDrafts() {
        apply(drafts.draft(for: task.id) ?? savedDraft)
    }

    private func apply(_ draft: TaskDraft) {
        draftBody = draft.body
        draftAcceptance = draft.acceptance
        draftModel = draft.model
    }

    private func retainDrafts(for taskId: String) {
        let saved = taskId == task.id
            ? savedDraft
            : allTasks.first { $0.id == taskId }.map {
                TaskDraft(body: $0.body ?? "", acceptance: $0.acceptance ?? "", model: $0.model)
            }
        guard let saved else { return }
        drafts.retain(currentDraft, for: taskId, ifDifferentFrom: saved)
    }

    private func save() {
        var updated = task
        updated.body = draftBody.isEmpty ? nil : draftBody
        updated.acceptance = draftAcceptance.isEmpty ? nil : draftAcceptance
        updated.model = draftModel
        do {
            try TaskStore(env.db).update(updated)
            drafts.clear(task.id)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func archive() {
        do {
            try TaskStore(env.db).archive(task.id)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func unarchive() {
        do {
            try TaskStore(env.db).unarchive(task.id)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        _Concurrency.Task {
            do {
                try await operation()
            } catch {
                errorMessage = errorText(error)
            }
        }
    }
}
