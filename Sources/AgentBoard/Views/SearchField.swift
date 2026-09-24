import SwiftUI

/// The search field the Task Board, Notes and Status share, so the prompt, the clear control, ⌘F
/// and the result wording are decided once. It filters its screen in place and never replaces it
/// (SPEC §10, Searching the board).
///
/// A `TextField` in the screen's own header rather than `.searchable`: on a `NavigationSplitView`
/// detail pane `.searchable` becomes a titlebar `NSSearchToolbarItem` for every placement, including
/// `.sidebar`, away from the content it narrows.
struct SearchField: View {
    let noun: SearchNoun
    @Binding var text: String
    /// What the screen draws with the query applied, and what it would draw without it.
    let shown: Int
    let total: Int
    /// Screen-specific context appended to the summary, such as matches the screen is hiding.
    var note: String?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(noun.prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onKeyPress(.escape) {
                        guard !text.isEmpty else { return .ignored }
                        text = ""
                        return .handled
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            if let summary = SearchSummary.text(query: text, shown: shown, total: total, noun: noun, note: note) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .focusedSceneValue(\.findInScreen, FindInScreen { focused = true })
    }
}

struct SearchNoun: Equatable {
    let one: String
    let many: String
    /// "Search <many>" unless the screen searches more than the rows it counts.
    let prompt: String

    init(one: String, many: String, prompt: String? = nil) {
        self.one = one
        self.many = many
        self.prompt = prompt ?? "Search \(many)"
    }

    static let tasks = SearchNoun(one: "task", many: "tasks")

    func counted(_ count: Int) -> String { count == 1 ? one : many }
}

enum SearchSummary {
    /// Nil while there is no query. An empty result is said here, beside the field, so the screen
    /// keeps its columns, list or table rather than swapping them for a placeholder.
    static func text(query: String, shown: Int, total: Int, noun: SearchNoun, note: String? = nil) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = shown == 0
            ? "No \(noun.many) match “\(trimmed)”"
            : "\(shown) of \(total) \(noun.counted(total))"
        return [head, note].compactMap(\.self).joined(separator: " · ")
    }
}

/// Focuses the search field of whichever screen is showing in the key window. Only a mounted
/// `SearchField` publishes one, so Find is disabled on a screen without search.
struct FindInScreen {
    let focus: () -> Void
}

private struct FindInScreenKey: FocusedValueKey {
    typealias Value = FindInScreen
}

extension FocusedValues {
    var findInScreen: FindInScreen? {
        get { self[FindInScreenKey.self] }
        set { self[FindInScreenKey.self] = newValue }
    }
}

struct FindCommand: View {
    static let title = "Find…"

    @FocusedValue(\.findInScreen) private var find

    var body: some View {
        Button(Self.title) { find?.focus() }
            .keyboardShortcut("f")
            .disabled(find == nil)
    }
}
