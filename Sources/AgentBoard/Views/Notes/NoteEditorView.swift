import AgentBoardCore
import GRDB
import SwiftUI

struct NoteEditorView: View {
    let project: Project
    let noteId: String
    let onDelete: () -> Void

    @Environment(AppEnvironment.self) private var env
    @State private var detail = Observed<NoteDetail?>(nil)
    @State private var tasks = Observed<[BoardTask]>([])
    @State private var epics = Observed<[Epic]>([])
    @State private var sessions = Observed<[AgentSession]>([])

    @State private var drafts: [Draft] = []
    @State private var baseVersion: Int64 = 0
    @State private var title = ""
    @State private var conflict: String?
    @State private var addingSection = false
    @State private var newHeading = ""
    @State private var newBody = ""
    @State private var confirmingDelete = false
    @State private var copiedHeading: String?
    @State private var errorMessage: String?

    private struct Draft: Identifiable, Equatable {
        let heading: String
        var body: String
        let original: String
        let writtenBy: String?

        var id: String { heading }
        var isDirty: Bool { body != original }
    }

    private var store: NoteStore { NoteStore(env.db) }

    var body: some View {
        Group {
            if let detail = detail.value {
                content(detail)
            } else {
                ContentUnavailableView("Note not found", systemImage: "questionmark.folder")
            }
        }
        .task(id: noteId) {
            await detail.run(store.observe(noteId: noteId), in: env.db.reader)
        }
        .task(id: project.id) {
            await tasks.run(TaskStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            await sessions.run(SessionStore(env.db).observe(projectId: project.id), in: env.db.reader)
        }
        .task(id: project.id) {
            let projectId = project.id
            let observation = ValueObservation.tracking { db -> [Epic] in
                try Epic.fetchAll(
                    db,
                    sql: "SELECT * FROM epic WHERE project_id = ? ORDER BY created_at",
                    arguments: [projectId]
                )
            }
            await epics.run(observation, in: env.db.reader)
        }
        .onChange(of: detail.value) { _, new in
            guard let new else { return }
            if drafts.isEmpty || !drafts.contains(where: \.isDirty) {
                adopt(new)
            } else if new.note.version != baseVersion {
                conflict = "Another writer changed this note (it is now at version \(new.note.version); you are editing version \(baseVersion)). Your unsaved text is untouched — copy anything you need, then reload."
            }
        }
        .task(id: copiedHeading) {
            guard copiedHeading != nil else { return }
            try? await _Concurrency.Task.sleep(for: .seconds(1.5))
            copiedHeading = nil
        }
        .errorAlert($errorMessage)
    }

    @ViewBuilder
    private func content(_ detail: NoteDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(detail)
                if let conflict {
                    conflictBanner(conflict)
                }
                attachments(detail)
                Divider()
                sectionsEditor(detail)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Delete \"\(detail.note.title)\"?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                perform {
                    try store.delete(noteId)
                    onDelete()
                }
            }
        } message: {
            Text("The note, its sections, and its attachments are removed. This cannot be undone.")
        }
    }

    private func header(_ detail: NoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Title", text: $title)
                    .font(.title2)
                    .textFieldStyle(.plain)
                    .onSubmit { rename() }
                Spacer()
                Toggle(isOn: pinBinding(detail)) {
                    Label(detail.note.pinned ? "Pinned" : "Pin", systemImage: detail.note.pinned ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .help("A pinned note is injected in full into every worker spawned on this project.")
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this note")
            }
            HStack(spacing: 8) {
                Text("version \(detail.note.version)")
                Text("·")
                Text("updated \(Format.relative(detail.note.updatedDate))")
                if title != detail.note.title {
                    Text("· unsaved title — press Return")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { if title.isEmpty { title = detail.note.title } }
    }

    private func conflictBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Write refused — nothing was saved")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reload (discards your edits)") {
                        perform { if let latest = try store.detail(noteId: noteId) { adopt(latest) } }
                    }
                    Button("Dismiss") { conflict = nil }
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5)))
    }

    // MARK: Attachments

    private func attachments(_ detail: NoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attached to")
                .font(.subheadline.weight(.semibold))
            if detail.links.isEmpty {
                Text("Nothing. Attach this note to a task or an epic and every worker spawned there is given it in full.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowRow(spacing: 6) {
                ForEach(Array(detail.links.enumerated()), id: \.offset) { _, link in
                    attachmentChip(link)
                }
            }
            HStack(spacing: 8) {
                Menu("Attach to Task…") {
                    let attached = Set(detail.links.compactMap(\.taskId))
                    let available = tasks.value.filter { !attached.contains($0.id) }
                    if available.isEmpty {
                        Text("No unattached tasks")
                    }
                    ForEach(available) { task in
                        Button(task.title) {
                            perform { try store.attach(noteId: noteId, taskId: task.id) }
                        }
                    }
                }
                .fixedSize()
                Menu("Attach to Epic…") {
                    let attached = Set(detail.links.compactMap(\.epicId))
                    let available = epics.value.filter { !attached.contains($0.id) }
                    if available.isEmpty {
                        Text("No unattached epics")
                    }
                    ForEach(available) { epic in
                        Button(epic.title) {
                            perform { try store.attach(noteId: noteId, epicId: epic.id) }
                        }
                    }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func attachmentChip(_ link: NoteLink) -> some View {
        let label: String = {
            if let taskId = link.taskId {
                return tasks.value.first { $0.id == taskId }?.title ?? "task \(taskId.prefix(8))"
            }
            if let epicId = link.epicId {
                return epics.value.first { $0.id == epicId }?.title ?? "epic \(epicId.prefix(8))"
            }
            return "(nothing)"
        }()
        HStack(spacing: 4) {
            Image(systemName: link.epicId != nil ? "square.stack.3d.up" : "checklist")
                .font(.caption)
            Text(label)
                .lineLimit(1)
            Button {
                perform { try store.detach(noteId: noteId, taskId: link.taskId, epicId: link.epicId) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Detach")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    // MARK: Sections

    private func sectionsEditor(_ detail: NoteDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sections")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    addingSection = true
                } label: {
                    Label("Add Section", systemImage: "plus")
                }
            }
            if addingSection {
                addSectionForm()
            }
            if drafts.isEmpty, !addingSection {
                Text("This note has no sections yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($drafts) { $draft in
                sectionEditor($draft)
            }
        }
    }

    private func sectionEditor(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(draft.wrappedValue.heading)
                    .font(.headline)
                Spacer()
                if draft.wrappedValue.isDirty {
                    Text("unsaved")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button {
                    NoteSectionClipboard.copy(heading: draft.wrappedValue.heading, body: draft.wrappedValue.body)
                    copiedHeading = draft.wrappedValue.heading
                } label: {
                    Image(systemName: copiedHeading == draft.wrappedValue.heading ? "checkmark" : "doc.on.doc")
                }
                .help("Copy this section's heading and text to the clipboard")
                Button("Save") { save(draft.wrappedValue) }
                    .disabled(!draft.wrappedValue.isDirty)
                Button("Revert") { revert(draft.wrappedValue.heading) }
                    .disabled(!draft.wrappedValue.isDirty)
                Button(role: .destructive) {
                    perform { try store.deleteSection(noteId: noteId, heading: draft.wrappedValue.heading) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this section")
            }
            TextEditor(text: draft.body)
                .font(.body.monospaced())
                .frame(minHeight: 110)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            Text("last written by \(writerLabel(draft.wrappedValue.writtenBy))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addSectionForm() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("New section heading", text: $newHeading)
            TextEditor(text: $newBody)
                .font(.body.monospaced())
                .frame(minHeight: 90)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Spacer()
                Button("Cancel") {
                    addingSection = false
                    newHeading = ""
                    newBody = ""
                }
                Button("Add") { addSection() }
                    .disabled(newHeading.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// A section written by an agent carries that agent's session id; the app writes nil for a
    /// human edit, which is the only way the two are told apart.
    private func writerLabel(_ sessionId: String?) -> String {
        guard let sessionId else { return "you, in Agent Board" }
        guard let session = sessions.value.first(where: { $0.sessionId == sessionId }) else {
            return "agent \(sessionId.prefix(8))"
        }
        let task = session.taskId.flatMap { id in tasks.value.first { $0.id == id }?.title }
        let role = session.role == .orchestrator ? "orchestrator" : "worker"
        return task.map { "\(role) \(session.displayShortId) on \"\($0)\"" } ?? "\(role) \(session.displayShortId)"
    }

    // MARK: Mutations

    private func pinBinding(_ detail: NoteDetail) -> Binding<Bool> {
        Binding(
            get: { detail.note.pinned },
            set: { pinned in perform { try store.pin(noteId, pinned) } }
        )
    }

    private func adopt(_ detail: NoteDetail) {
        drafts = detail.sections.map {
            Draft(heading: $0.heading, body: $0.body, original: $0.body, writtenBy: $0.writtenBy)
        }
        baseVersion = detail.note.version
        title = detail.note.title
        conflict = nil
    }

    private func revert(_ heading: String) {
        guard let index = drafts.firstIndex(where: { $0.heading == heading }) else { return }
        drafts[index].body = drafts[index].original
    }

    private func rename() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != detail.value?.note.title else { return }
        perform { try store.rename(noteId, title: trimmed) }
    }

    private func save(_ draft: Draft) {
        write {
            try store.replaceSection(
                noteId: noteId, heading: draft.heading, body: draft.body,
                ifVersion: baseVersion, writtenBy: nil
            )
        }
    }

    private func addSection() {
        write {
            try store.appendSection(
                noteId: noteId, heading: newHeading.trimmingCharacters(in: .whitespaces), body: newBody,
                ifVersion: baseVersion, writtenBy: nil
            )
            addingSection = false
            newHeading = ""
            newBody = ""
        }
    }

    /// Every write is pinned to the version the editor loaded. A refused write is shown, never
    /// retried without the version: silently re-saving would overwrite the writer we lost to.
    private func write(_ body: () throws -> Void) {
        do {
            try body()
            if let latest = try store.detail(noteId: noteId) { adopt(latest) }
        } catch let error as NoteError {
            conflict = NoteConflictText.describe(error)
        } catch {
            errorMessage = errorText(error)
        }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch let error as NoteError {
            conflict = NoteConflictText.describe(error)
        } catch {
            errorMessage = errorText(error)
        }
    }
}

enum NoteConflictText {
    static func describe(_ error: NoteError) -> String {
        switch error {
        case .noteNotFound:
            "This note no longer exists."
        case .versionConflict(_, let expected, let current):
            "You are editing version \(expected); another writer has since taken this note to version \(current). "
                + "Nothing was written. Reload to see their text — your edits stay on screen until you do."
        }
    }
}

/// Wraps chips onto as many rows as they need. `LazyVGrid` cannot size columns to content.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows: CGFloat = subviews.isEmpty ? 0 : 1
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                total += rowHeight + spacing
                rows += 1
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: total + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
