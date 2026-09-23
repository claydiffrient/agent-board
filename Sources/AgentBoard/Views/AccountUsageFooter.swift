import AgentBoardRuntime
import SwiftUI

/// SPEC §12: account headroom against the 5-hour and weekly caps, read from Claude Code's cache.
/// The reading can be hours old, so its age is always on screen and a stale one is visibly dimmed.
struct AccountUsageFooter: View {
    @State private var model: AccountUsageModel

    /// Rendered height with both windows, their reset lines and the age line, at the sidebar's width.
    /// Pinned by `PortsPanelCeilingTests`, which measures it.
    static let fullHeight: CGFloat = 143

    init(model: AccountUsageModel = AccountUsageModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = model.snapshot, snapshot.fiveHour != nil || snapshot.sevenDay != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let window = snapshot.fiveHour {
                        AccountUsageBar(label: "5h", window: window, now: model.observedAt, isStale: isStale(snapshot))
                    }
                    if let window = snapshot.sevenDay {
                        AccountUsageBar(label: "7d", window: window, now: model.observedAt, isStale: isStale(snapshot))
                    }
                    ageLabel(snapshot)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await model.run() }
    }

    private func isStale(_ snapshot: AccountUsageSnapshot) -> Bool {
        snapshot.isStale(at: model.observedAt)
    }

    @ViewBuilder
    private func ageLabel(_ snapshot: AccountUsageSnapshot) -> some View {
        let stale = isStale(snapshot)
        let age = snapshot.fetchedAt.map { "updated \(Format.relative($0))" } ?? "age unknown"
        Label(stale ? "stale · \(age)" : age, systemImage: stale ? "clock.badge.exclamationmark" : "clock")
            .font(.caption2)
            .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .help("Claude Code refreshes this cache when a session talks to the API; it is not read live.")
    }
}

struct AccountUsageBar: View {
    let label: String
    let window: AccountUsageWindow
    let now: Date
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                if window.percent >= AccountUsageBar.criticalPercent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                Spacer(minLength: 2)
                Text("\(window.percent)%")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: Double(window.percent), total: 100)
                .progressViewStyle(.linear)
                .tint(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(pressureColor))
                .opacity(isStale ? 0.45 : 1)
            if let resetsAt = window.resetsAt {
                Text("resets \(Format.resetTime(resetsAt, now: now))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityName(label))
        .accessibilityValue(accessibilityValue)
    }

    static let warningPercent = 70
    static let criticalPercent = 90

    private var pressureColor: Color {
        switch window.percent {
        case AccountUsageBar.criticalPercent...: .red
        case AccountUsageBar.warningPercent...: .orange
        default: .green
        }
    }

    private static func accessibilityName(_ label: String) -> String {
        label == "5h" ? "Five-hour account usage" : "Seven-day account usage"
    }

    private var accessibilityValue: String {
        var parts = ["\(window.percent) percent used"]
        if let resetsAt = window.resetsAt {
            parts.append("resets \(Format.resetTime(resetsAt, now: now))")
        }
        if isStale { parts.append("reading is stale") }
        return parts.joined(separator: ", ")
    }
}
