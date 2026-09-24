import AgentBoardCore
import GRDB
import SwiftUI

struct NotesView: View {
    let project: Project

    @Environment(AppEnvironment.self) private var env
    @State private var notes = Observed<[Note]>([])
    @State private var query = ""
    @State private var matchIds: Set<String>?
    @State private var selectedNoteId: String?
    @State private var newNoteTitle: String?
    @State private var errorMessage: String?

    private var store: NoteStore { NoteStore(env.db) }

    /// The list's own order, narrowed: a query filters the notes in place rather than re-ranking
    /// them, so a note keeps its position while the query is typed out and after it is cleared.
    private var visible: [Note] {
        guard let matchIds else { return notes.value }
        return notes.value.filter { matchIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(noun: .notes, text: $query, shown: visible.count, total: notes.value.count)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: project.id) {
            await notes.run(store.observe(projectId: project.id), in: env.db.reader)
        }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: notes.value) { _, _ in if !query.isEmpty { runSearch() } }
        .toolbar {
            ToolbarItem {
                Button {
                    newNoteTitle = ""
                } label: {
                    Label("New Note", systemImage: "plus")
                }
                .help("Create a note")
            }
        }
        .sheet(isPresented: Binding(get: { newNoteTitle != nil }, set: { if !$0 { newNoteTitle = nil } })) {
            NewNoteSheet(projectId: project.id) { created in
                selectedNoteId = created.id
            }
        }
        .errorAlert($errorMessage)
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(visible, selection: $selectedNoteId) { note in
                row(note).tag(note.id)
            }
            .overlay {
                if notes.value.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Notes you and your agents write show up here. Pinned notes go to every worker at spawn.")
                    )
                }
            }
            Divider()
            HStack {
                Text("\(visible.count) note\(visible.count == 1 ? "" : "s")")
                Spacer()
                Text("\(notes.value.filter(\.pinned).count) pinned")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func row(_ note: Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: note.pinned ? "pin.fill" : "note.text")
                .foregroundStyle(note.pinned ? Color.orange : Color.secondary)
                .help(note.pinned ? "Pinned: injected into every worker on this project" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .lineLimit(1)
                Text("v\(note.version) · \(Format.relative(note.updatedDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedNoteId, visible.contains(where: { $0.id == selectedNoteId }) || notes.value.contains(where: { $0.id == selectedNoteId }) {
            NoteEditorView(project: project, noteId: selectedNoteId) {
                self.selectedNoteId = nil
            }
            .id(selectedNoteId)
        } else {
            ContentUnavailableView(
                "No Note Selected",
                systemImage: "note.text",
                description: Text("Choose a note on the left, or create one.")
            )
        }
    }

    /// Section headings and text are searched too: `note_fts.body` is every section's heading and
    /// body. A failure leaves the last result on screen rather than emptying the list.
    private func runSearch() {
        guard let match = NoteSearch.ftsQuery(query) else {
            matchIds = nil
            return
        }
        do {
            matchIds = Set(try store.search(projectId: project.id, query: match).map(\.id))
        } catch {
            errorMessage = errorText(error)
        }
    }
}

private struct NewNoteSheet: View {
    let projectId: String
    let onCreate: (Note) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var heading = "Context"
    @State private var body_ = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Note").font(.headline)
            TextField("Title", text: $title)
            TextField("First section heading", text: $heading)
            TextEditor(text: $body_)
                .font(.body.monospaced())
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .errorAlert($errorMessage)
    }

    private func create() {
        do {
            let sections = heading.trimmingCharacters(in: .whitespaces).isEmpty
                ? []
                : [(heading: heading, body: body_)]
            let note = try NoteStore(env.db).create(projectId: projectId, title: title, sections: sections)
            onCreate(note)
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }
}

#Preview("Notes") {
    let preview = PreviewData.make()
    NotesView(project: preview.project)
        .environment(preview.environment)
        .frame(width: 1100, height: 700)
}
