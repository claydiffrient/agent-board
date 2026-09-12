/// Selection rules for the task board's inspector tray.
public enum TaskSelection {
    /// Tapping the already-selected card clears the selection; any other card becomes the selection.
    public static func toggled(current: String?, tapped: String) -> String? {
        current == tapped ? nil : tapped
    }

    /// Drops a selection whose task is no longer on the board, so a refresh cannot leave an empty tray open.
    public static func reconciled(current: String?, availableIds: some Sequence<String>) -> String? {
        guard let current, availableIds.contains(current) else { return nil }
        return current
    }
}
