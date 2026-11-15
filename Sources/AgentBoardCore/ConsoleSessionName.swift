/// The `-n` names the app gives its interactive consoles so other sessions can address them (SPEC §9).
public enum ConsoleSessionName {
    public static let coordinator = "coordinator"

    /// The project name as the human typed it, each whitespace run collapsed to `-`; `claude` accepts any other character.
    public static func orchestrator(projectName: String) -> String {
        let words = projectName.split(whereSeparator: \.isWhitespace)
        return (words + ["orchestrator"]).joined(separator: "-")
    }
}
