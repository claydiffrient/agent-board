import Foundation

public struct ModelOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The window Claude Code budgets against, read from its own `autocompact: … effectiveWindow=`
    /// debug line rather than from the model's advertised context length.
    public var effectiveContextWindow: Int
}

/// Ids accepted by `claude --model`; the picker offers these plus free text.
public enum ModelCatalog {
    public static let known: [ModelOption] = [
        ModelOption(id: "claude-fable-5-1", name: "Fable 5.1", effectiveContextWindow: 980_000),
        ModelOption(id: "claude-opus-5-5", name: "Opus 5.5", effectiveContextWindow: 980_000),
        ModelOption(id: "claude-opus-5", name: "Opus 5", effectiveContextWindow: 980_000),
        ModelOption(id: "claude-sonnet-5", name: "Sonnet 5", effectiveContextWindow: 980_000),
        ModelOption(id: "claude-haiku-4-5", name: "Haiku 4.5", effectiveContextWindow: fallbackContextWindow),
    ]

    /// Every model measured (2.1.272; Opus 5.5 on 2.1.280) reported the same window, so an id we have not measured —
    /// including Haiku 4.5 and anything typed as free text — is read as that rather than guessed at.
    public static let fallbackContextWindow = 980_000

    /// Claude Code matches `--model` loosely, so a dated id like `claude-haiku-4-5-20251001`
    /// resolves to the catalog entry it starts with. The longest prefix wins, so `claude-opus-5-5`
    /// is its own entry and not `claude-opus-5`'s.
    public static func option(for id: String?) -> ModelOption? {
        guard let id, !id.isEmpty else { return nil }
        if let exact = known.first(where: { $0.id == id }) { return exact }
        return known.filter { id.hasPrefix($0.id) }.max { $0.id.count < $1.id.count }
    }

    public static func effectiveContextWindow(for id: String?) -> Int {
        option(for: id)?.effectiveContextWindow ?? fallbackContextWindow
    }

    public static func displayName(for id: String) -> String {
        known.first { $0.id == id }?.name ?? id
    }
}
