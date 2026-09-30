import AgentBoardCore
import AppKit
import SwiftUI

/// The roster is cross-project, so this screen hangs off the window rather than off a project.
/// Board-local archetypes are edited here; disk ones are listed read-only with their file (SPEC §4).
struct RosterView: View {
    var activity: any RosterActivityReporting = NoRosterActivity()

    @Environment(AppEnvironment.self) private var env
    @State private var agents = Observed<[RosterAgent]>([])
    @State private var listing = ArchetypeListing.empty
    @State private var editing: RosterAgentDraft?
    @State private var pendingDelete: RosterListEntry?
    @State private var errorMessage: String?

    private var rows: [(archetype: Archetype, entry: RosterListEntry)] {
        let byAgent = Dictionary(activity.assignments().map { ($0.agentId, $0) }, uniquingKeysWith: { first, _ in first })
        return listing.archetypes.map { ($0, RosterListEntry(agent: $0.agent, assignment: byAgent[$0.agent.id])) }
    }

    var body: some View {
        List {
            ForEach(rows, id: \.archetype.id) { row in
                self.row(row.archetype, row.entry)
            }
            if !listing.diagnostics.isEmpty {
                Section("Skipped definition files") {
                    ForEach(listing.diagnostics, id: \.path) { diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(diagnostic.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if listing.archetypes.isEmpty && listing.diagnostics.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "person.2",
                    description: Text("Add a specialist, or define one in ~/.claude/agents, and pick it per project in that project's settings.")
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
        .task(id: agents.value) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
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

    private func row(_ archetype: Archetype, _ entry: RosterListEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.agent.name)
                        .font(.headline)
                    if archetype.source.isEditable {
                        Text(entry.agent.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ArchetypeSourceChip(source: archetype.source)
                    if let model = entry.agent.model {
                        ModelChip(model: model)
                    }
                }
                ArchetypeProvenance(archetype: archetype)
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
            if let path = archetype.source.path {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.borderless)
                    .help("Read-only here. Edit the file; the next spawn reads it.")
            } else {
                Button("Edit") { editing = .editing(entry.agent) }
                    .buttonStyle(.borderless)
                Button("Delete", role: .destructive) { pendingDelete = entry }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let path = archetype.source.path {
                Button("Open Definition File") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            } else {
                Button("Edit…") { editing = .editing(entry.agent) }
                Button("Delete…", role: .destructive) { pendingDelete = entry }
            }
        }
    }

    private func reload() {
        do {
            listing = try env.roster.allArchetypes(rows: agents.value)
        } catch {
            errorMessage = errorText(error)
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
            try env.roster.setEnabled(agent.id, enabled)
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

struct ArchetypeSourceChip: View {
    var source: Archetype.Source

    var body: some View {
        Text(source.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .help(source.isEditable ? "Stored in Agent Board; editable here" : "Read from its file on every spawn; edit the file")
    }
}

/// Where a disk archetype comes from and how it fared in a name clash, in plain words.
struct ArchetypeProvenance: View {
    var archetype: Archetype

    var body: some View {
        if let path = archetype.source.path {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        if !archetype.description.isEmpty {
            Text(archetype.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if let winner = archetype.shadowedBy {
            Label(
                "Not usable: the board-local agent \(winner) has this name, and board-local wins. Rename one to use both.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        ForEach(archetype.shadows, id: \.self) { path in
            Label("Hides the definition at \(path), which has the same name.", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let replaced = archetype.overrides {
            Label("In its project, replaces the user-level definition at \(replaced).", systemImage: "arrow.triangle.swap")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(archetype.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
