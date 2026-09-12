import AgentBoardCore
import SwiftUI

struct NewTaskSheet: View {
    let projectId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""
    @State private var acceptance = ""
    @State private var priority = ""
    @State private var column: TaskColumn = .backlog
    @State private var errorMessage: String?

    private static let priorities = ["", "high", "medium", "low"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $title)
                Picker("Priority", selection: $priority) {
                    ForEach(Self.priorities, id: \.self) { value in
                        Text(value.isEmpty ? "None" : value.capitalized).tag(value)
                    }
                }
                Picker("Column", selection: $column) {
                    ForEach(TaskColumn.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Body") {
                    TextEditor(text: $body_)
                        .font(.body)
                        .frame(minHeight: 100)
                }
                LabeledContent("Acceptance") {
                    TextEditor(text: $acceptance)
                        .font(.body)
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle("New Task")
        .errorAlert($errorMessage)
    }

    private func create() {
        do {
            try TaskStore(env.db).create(
                projectId: projectId,
                title: title.trimmingCharacters(in: .whitespaces),
                body: body_.isEmpty ? nil : body_,
                acceptance: acceptance.isEmpty ? nil : acceptance,
                priority: priority.isEmpty ? nil : priority,
                column: column,
                origin: .human,
                epicId: nil
            )
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }
}
