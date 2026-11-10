import AgentBoardCore
import SwiftUI

/// Known models plus free text; nil means "inherit" (the caller names what that inherits from).
struct ModelPicker: View {
    let label: String
    let inheritLabel: String
    @Binding var model: String?

    private static let customTag = "__custom__"
    @State private var customText = ""

    private var selection: Binding<String> {
        Binding(
            get: {
                guard let model, !model.isEmpty else { return "" }
                return ModelCatalog.known.contains { $0.id == model } ? model : Self.customTag
            },
            set: { newValue in
                switch newValue {
                case "": model = nil
                case Self.customTag: model = customText.isEmpty ? nil : customText
                default: model = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(label, selection: selection) {
                Text(inheritLabel).tag("")
                ForEach(ModelCatalog.known) { option in
                    Text("\(option.name) (\(option.id))").tag(option.id)
                }
                Text("Custom id…").tag(Self.customTag)
            }
            if selection.wrappedValue == Self.customTag {
                TextField("Model id", text: $customText, prompt: Text("Model id"))
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onChange(of: customText) { _, text in
                        model = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text.trimmingCharacters(in: .whitespaces)
                    }
                    .onAppear {
                        if let model, !ModelCatalog.known.contains(where: { $0.id == model }) { customText = model }
                    }
            }
        }
    }
}

struct ModelChip: View {
    let model: String

    var body: some View {
        Text(ModelCatalog.displayName(for: model))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.purple.opacity(0.18)))
            .foregroundStyle(.purple)
            .help("Model override: \(model)")
    }
}

/// The five `claude --effort` levels; nil means "inherit", as with `ModelPicker` (SPEC §10).
struct EffortPicker: View {
    let label: String
    let inheritLabel: String
    @Binding var effort: Effort?

    var body: some View {
        Picker(label, selection: $effort) {
            Text(inheritLabel).tag(Effort?.none)
            ForEach(Effort.allCases, id: \.self) { level in
                Text(level.label).tag(Effort?.some(level))
            }
        }
    }
}

struct EffortChip: View {
    let effort: Effort

    var body: some View {
        Text(effort.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.teal.opacity(0.18)))
            .foregroundStyle(.teal)
            .help("Effort override: \(effort.rawValue)")
    }
}
