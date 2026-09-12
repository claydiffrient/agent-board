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
    @State private var model: String?
    @State private var errorMessage: String?

    private static let priorities = ["", "high", "medium", "low"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Title")
                        TextField("", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(Self.priorities, id: \.self) { value in
                            Text(value.isEmpty ? "None" : value.capitalized).tag(value)
                        }
                    }
                    Picker("Column", selection: $column) {
                        ForEach(TaskColumn.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    ModelPicker(label: "Model", inheritLabel: "Project default", model: $model)
                }
                Section {
                    editor("Body", text: $body_, minHeight: 100)
                    editor("Acceptance", text: $acceptance, minHeight: 80)
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

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
    }

    private func editor(_ label: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: minHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
        }
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
                epicId: nil,
                model: model
            )
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }
}
