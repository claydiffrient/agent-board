import AgentBoardCore
import SwiftUI

/// The Coordinator's one setting (SPEC §8.2): its model, which the next session launch uses. It
/// has no spend cap to set.
struct CoordinatorSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: String?
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ModelPicker(label: "Model", inheritLabel: "Claude Code default", model: $model)
                } footer: {
                    Text("Takes effect when the next Coordinator session starts or resumes.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try Self.save(model: model, db: env.db)
                        dismiss()
                    } catch {
                        errorMessage = errorText(error)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 220)
        .navigationTitle("Coordinator Settings")
        .task {
            do {
                model = try CoordinatorStore(env.db).model()
                loaded = true
            } catch {
                errorMessage = errorText(error)
            }
        }
        .errorAlert($errorMessage)
    }

    static func save(model: String?, db: AppDatabase) throws {
        try CoordinatorStore(db).setModel(model)
    }
}
