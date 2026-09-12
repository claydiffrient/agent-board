import Foundation

public struct ModelOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
}

/// Ids accepted by `claude --model`; the picker offers these plus free text.
public enum ModelCatalog {
    public static let known: [ModelOption] = [
        ModelOption(id: "claude-fable-5-1", name: "Fable 5.1"),
        ModelOption(id: "claude-opus-5", name: "Opus 5"),
        ModelOption(id: "claude-sonnet-5", name: "Sonnet 5"),
        ModelOption(id: "claude-haiku-4-5", name: "Haiku 4.5"),
    ]

    public static func displayName(for id: String) -> String {
        known.first { $0.id == id }?.name ?? id
    }
}
