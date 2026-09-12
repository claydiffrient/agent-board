import AgentBoardCore
import SwiftUI

struct NewEpicSheet: View {
    let projectId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var goal = ""
    @State private var drafts: [EpicTaskDraft] = []
    @State private var errorMessage: String?

    init(projectId: String, initialTasks: [EpicTaskDraft] = []) {
        self.projectId = projectId
        _drafts = State(initialValue: initialTasks)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }

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
                    editor("Goal", text: $goal, minHeight: 60)
                }
                Section {
                    if drafts.isEmpty {
                        Text("No initial tasks. The epic starts empty; add tasks to it later from the board.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($drafts) { $draft in
                        taskRow($draft)
                    }
                    Button {
                        drafts.append(EpicTaskDraft())
                    } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                } header: {
                    Text("Initial tasks")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle("New Epic")
        .errorAlert($errorMessage)
    }

    @ViewBuilder
    private func taskRow(_ draft: Binding<EpicTaskDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    fieldLabel("Task \(position(of: draft.wrappedValue))")
                    Spacer()
                    Button {
                        drafts.removeAll { $0.id == draft.wrappedValue.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this task")
                }
                TextField("", text: draft.title, prompt: Text("Title"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            Picker("Priority", selection: draft.priority) {
                ForEach(EpicTaskDraft.priorities, id: \.self) { value in
                    Text(value.isEmpty ? "None" : value.capitalized).tag(value)
                }
            }
            ModelPicker(label: "Model", inheritLabel: "Project default", model: draft.model)
            editor("Body", text: draft.body, minHeight: 60)
            editor("Acceptance", text: draft.acceptance, minHeight: 50)
        }
        .padding(.vertical, 4)
    }

    private func position(of draft: EpicTaskDraft) -> Int {
        (drafts.firstIndex { $0.id == draft.id } ?? 0) + 1
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
            try Board(env.db).createEpic(
                projectId: projectId,
                title: trimmedTitle,
                goal: goal.isEmpty ? nil : goal,
                tasks: EpicTaskDraft.specs(from: drafts)
            )
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }
}

struct EpicTaskDraft: Identifiable, Equatable {
    static let priorities = ["", "high", "medium", "low"]

    let id = UUID()
    var title = ""
    var body = ""
    var acceptance = ""
    var priority = ""
    var model: String?

    /// Drops rows the user added and left blank so a stray Add Task does not create an untitled task.
    static func specs(from drafts: [EpicTaskDraft]) -> [NewEpicTask] {
        drafts.compactMap { draft in
            let title = draft.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return NewEpicTask(
                title: title,
                body: draft.body.isEmpty ? nil : draft.body,
                acceptance: draft.acceptance.isEmpty ? nil : draft.acceptance,
                priority: draft.priority.isEmpty ? nil : draft.priority,
                model: draft.model,
                origin: .human
            )
        }
    }
}

#Preview("New Epic") {
    let preview = PreviewData.make()
    NewEpicSheet(
        projectId: preview.project.id,
        initialTasks: [EpicTaskDraft(title: "Extract cart model", priority: "high")]
    )
    .environment(preview.environment)
}
