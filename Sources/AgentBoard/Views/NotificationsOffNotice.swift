import SwiftUI

/// Says so when banners will not arrive, so a silent Agent Board reads as a setting rather than a
/// broken feature. Draws nothing in the two cases a user cannot act on: the answer is still
/// outstanding, or this is a `swift run` build with no notification centre at all.
struct NotificationsOffNotice: View {
    var notifier: MacNotifier = .shared

    var body: some View {
        if let message = notifier.offMessage {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Open Notification Settings", destination: MacNotifier.settingsURL)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
