import AgentBoardCore
import SwiftUI

/// The roster is cross-project, so this screen hangs off the window rather than off a project.
struct RosterView: View {
    var activity: any RosterActivityReporting = NoRosterActivity()

    @Environment(AppEnvironment.self) private var env
    @State private var agents = Observed<[RosterAgent]>([])
    @State private var editing: RosterAgentDraft?
    @State private var pendingDelete: RosterListEntry?
    @State private var errorMessage: String?

    private var entries: [RosterListEntry] {
        RosterListing.entries(agents: agents.value, assignments: activity.assignments())
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .overlay {
            if agents.value.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "person.2",
                    description: Text("Add a specialist and pick it per project in that project's settings.")
                )
            }
        }
        .navigationTitle("Roster")
        .toolbar {
            ToolbarItem {
                Button {
                    editing = .blank
                } label: {
                    Label("Add Agent", systemImage: "plus")
                }
                .help("Add a rostered agent")
            }
        }
        .task {
            await agents.run(RosterStore(env.db).observe(), in: env.db.reader)
        }
        .sheet(item: $editing) { draft in
            RosterAgentSheet(draft: draft)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let entry = pendingDelete, RosterListing.deleteDecision(for: entry).isAllowed {
                Button("Delete Agent", role: .destructive) { delete(entry.agent) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .errorAlert($errorMessage)
    }

    private func row(_ entry: RosterListEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.agent.name)
                        .font(.headline)
                    Text(entry.agent.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let model = entry.agent.model {
                        ModelChip(model: model)
                    }
                }
                if let assignment = entry.assignment {
                    Label("Working on \(assignment.taskTitle)", systemImage: "hammer")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(entry.agent.enabled ? "Idle" : "Disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { entry.agent.enabled },
                set: { setEnabled(entry.agent, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(entry.agent.enabled ? "Enabled everywhere" : "Disabled everywhere")
            Button("Edit") { editing = .editing(entry.agent) }
                .buttonStyle(.borderless)
            Button("Delete", role: .destructive) { pendingDelete = entry }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit…") { editing = .editing(entry.agent) }
            Button("Delete…", role: .destructive) { pendingDelete = entry }
        }
    }

    private var deleteTitle: String {
        guard let entry = pendingDelete else { return "" }
        return RosterListing.deleteDecision(for: entry).isAllowed
            ? "Delete \(entry.agent.name)?"
            : "\(entry.agent.name) is working"
    }

    private var deleteMessage: String {
        guard let entry = pendingDelete else { return "" }
        switch RosterListing.deleteDecision(for: entry) {
        case .allowed:
            return """
            Removes \(entry.agent.name) from the roster and from every project that selected it. \
            Its past tasks, sessions, and progress entries are kept.
            """
        case .refused(let taskTitle):
            return """
            \(entry.agent.name) is mid-task on "\(taskTitle)". Deleting now would orphan that \
            session, so it is refused. Stop the session on the task board, then delete.
            """
        }
    }

    private func setEnabled(_ agent: RosterAgent, _ enabled: Bool) {
        do {
            try RosterStore(env.db).setEnabled(agent.id, enabled)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func delete(_ agent: RosterAgent) {
        do {
            try RosterStore(env.db).delete(agent.id)
            pendingDelete = nil
        } catch {
            errorMessage = errorText(error)
        }
    }
}
