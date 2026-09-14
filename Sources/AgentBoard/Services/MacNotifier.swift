import Foundation
import UserNotifications

/// `UNUserNotificationCenter` traps unless the process is an app bundle, so the bare SwiftPM
/// binary and the test runner silently drop notifications; the .app bundle shows them.
enum MacNotifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
