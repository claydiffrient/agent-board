import AgentBoardRuntime
import AppKit
import SwiftUI

/// The app's Settings window (⌘,). SPEC §10, Settings.
struct SettingsView: View {
    let terminalAppearance: TerminalAppearanceStore

    var body: some View {
        TabView {
            TerminalSettingsPane(store: terminalAppearance)
                .tabItem { Label("Terminal", systemImage: "apple.terminal") }
            CDRSettingsPane()
                .tabItem { Label("CDR", systemImage: "checkmark.bubble") }
        }
        .frame(width: 560, height: 760)
    }
}

enum CDRSettings {
    /// The path to CDR's `watcher/cli.mjs`; empty means auto-detect. SPEC §13.7.
    static let commandKey = "cdr.command"
}

struct CDRSettingsPane: View {
    @AppStorage(CDRSettings.commandKey) private var command = ""
    @State private var resolution = ""
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                TextField("CDR command", text: $command, prompt: Text("Auto-detect"))
                    .focused($editing)
                    .onSubmit { resolve() }
                    .onChange(of: editing) { if !editing { resolve() } }
            } footer: {
                Text(resolution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { resolve() }
    }

    /// Reads the plugin registry and stats a file, so it runs on appear and on commit, not per keystroke.
    private func resolve() {
        resolution = Self.resolution(configured: command)
    }

    private static func resolution(configured: String) -> String {
        guard let cli = CDRCommand.cliPath(configured: configured) else {
            return "CDR's watcher/cli.mjs was not found. Agent Board runs it with node to start and stop CDR."
        }
        return FileManager.default.fileExists(atPath: cli.path) ? "Using \(cli.path)" : "No file at \(cli.path)"
    }
}

struct TerminalSettingsPane: View {
    @Bindable var store: TerminalAppearanceStore
    @State private var families = TerminalAppearance.monospacedFamilies()

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $store.appearance.fontFamily) {
                    ForEach(familyChoices, id: \.self) { family in
                        Text(familyLabel(family)).tag(family)
                    }
                }
                Stepper(value: $store.appearance.fontSize, in: TerminalAppearance.fontSizes, step: 1) {
                    LabeledContent("Size", value: "\(Int(store.appearance.fontSize)) pt")
                }
            }
            Section("Colors") {
                colorPicker("Foreground", \.foreground)
                colorPicker("Background", \.background)
                colorPicker("Cursor", \.cursor)
                colorPicker("Cursor text", \.cursorText)
                colorPicker("Selection background", \.selectionBackground)
                colorPicker("Selection foreground", \.selectionForeground)
            }
            Section("ANSI colors") {
                paletteRow("Normal", 0..<8)
                paletteRow("Bright", 8..<16)
            }
            Section("Preview") {
                TerminalAppearancePreview(appearance: store.appearance)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { store.restoreDefaults() }
                    .disabled(store.appearance == .defaults)
            }
            Section {
                Toggle("Use GPU rendering (Metal)", isOn: $store.usesMetal)
            } header: {
                Text("Rendering")
            } footer: {
                if store.usesMetal, let failure = store.metalFailure {
                    Text("Metal did not start, so terminals are using CoreGraphics: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var familyChoices: [String] {
        let current = store.appearance.fontFamily
        return families.contains(current) ? families : [current] + families
    }

    private func familyLabel(_ family: String) -> String {
        families.contains(family) ? family : "\(family) (not installed)"
    }

    private func colorPicker(_ title: String, _ key: WritableKeyPath<TerminalAppearance, TerminalColor>) -> some View {
        ColorPicker(title, selection: colorBinding(key), supportsOpacity: false)
    }

    private func paletteRow(_ title: String, _ indices: Range<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(indices, id: \.self) { index in
                    ColorPicker(
                        "Color \(index)",
                        selection: colorBinding(\.palette[index]),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }
        }
    }

    private func colorBinding(_ key: WritableKeyPath<TerminalAppearance, TerminalColor>) -> Binding<SwiftUI.Color> {
        Binding(
            get: { SwiftUI.Color(nsColor: store.appearance[keyPath: key].nsColor) },
            set: { store.appearance[keyPath: key] = TerminalColor(NSColor($0)) }
        )
    }
}

private struct TerminalAppearancePreview: View {
    let appearance: TerminalAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("~/agent-board $ git status")
                .foregroundStyle(color(appearance.foreground))
            HStack(spacing: 0) {
                Text("modified: ").foregroundStyle(color(appearance.palette[1]))
                Text("Sources/App.swift ").foregroundStyle(color(appearance.palette[2]))
                Text("selected")
                    .foregroundStyle(color(appearance.selectionForeground))
                    .background(color(appearance.selectionBackground))
            }
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(color(appearance.foreground))
                Text(" ")
                    .foregroundStyle(color(appearance.cursorText))
                    .background(color(appearance.cursor))
            }
        }
        .font(SwiftUI.Font(appearance.font))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color(appearance.background), in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(_ color: TerminalColor) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: color.nsColor)
    }
}
