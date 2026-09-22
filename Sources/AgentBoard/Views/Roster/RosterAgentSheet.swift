import AgentBoardCore
import SwiftUI

struct RosterAgentDraft: Identifiable {
    var agent: RosterAgent?

    var id: String { agent?.id ?? "new" }

    static let blank = RosterAgentDraft(agent: nil)

    static func editing(_ agent: RosterAgent) -> RosterAgentDraft {
        RosterAgentDraft(agent: agent)
    }
}

struct RosterAgentSheet: View {
    let draft: RosterAgentDraft

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var role: String
    @State private var systemPrompt: String
    @State private var model: String?
    @State private var enabled: Bool
    @State private var errorMessage: String?

    init(draft: RosterAgentDraft) {
        self.draft = draft
        _name = State(initialValue: draft.agent?.name ?? "")
        _role = State(initialValue: draft.agent?.role ?? "")
        _systemPrompt = State(initialValue: draft.agent?.systemPrompt ?? "")
        _model = State(initialValue: draft.agent?.model)
        _enabled = State(initialValue: draft.agent?.enabled ?? true)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !role.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    field("Name", text: $name, prompt: "Ada")
                    field("Role", text: $role, prompt: "frontend")
                    Text("Role is free text. The handoff matches a task against it, so name the specialty the way you would say it out loud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ModelPicker(label: "Model", inheritLabel: "Project default", model: $model)
                    Toggle("Enabled", isOn: $enabled)
                }
                Section {
                    editor("System prompt", text: $systemPrompt, minHeight: 160)
                    Text("Injected at spawn as this agent's identity and specialty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.agent == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 520)
        .navigationTitle(draft.agent == nil ? "New Agent" : "Edit \(draft.agent?.name ?? "")")
        .errorAlert($errorMessage)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(label)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
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

    private func save() {
        let store = RosterStore(env.db)
        let name = name.trimmingCharacters(in: .whitespaces)
        let role = role.trimmingCharacters(in: .whitespaces)
        do {
            if var agent = draft.agent {
                agent.name = name
                agent.role = role
                agent.systemPrompt = systemPrompt
                agent.model = model
                agent.enabled = enabled
                try store.update(agent)
            } else {
                try store.create(
                    name: name, role: role, systemPrompt: systemPrompt, model: model, enabled: enabled
                )
            }
            dismiss()
        } catch {
            errorMessage = errorText(error)
        }
    }
}
