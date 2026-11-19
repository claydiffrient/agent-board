import AppKit
import Foundation
import Observation
import UserNotifications

/// Agent Board's end of Notification Center: one authorization request at launch, a click that
/// opens what the banner is about, and a remembered answer so a refusal is stated once.
///
/// `UNUserNotificationCenter.current()` traps unless the process is an app bundle, so every entry
/// point is guarded by `isAppBundle`; the bare SwiftPM binary and the test runner fall through.
@Observable
@MainActor
final class MacNotifier {
    enum Authorization: Equatable {
        /// Not an app bundle, so there is no notification centre to ask. Only a `swift run` build
        /// and the test runner see this.
        case unavailable
        case notAsked
        case granted
        case denied
        case failed(String)
    }

    static let shared = MacNotifier()

    private(set) var authorization: Authorization
    /// `UNUserNotificationCenter.delegate` is weak, so the delegate is held here.
    @ObservationIgnored private var responder: NotificationResponder?

    init() {
        authorization = Self.isAppBundle ? .notAsked : .unavailable
    }

    static var isAppBundle: Bool { AppBundle.isAppBundle() }

    /// Called from `AppComposition` at launch. Authorization is asked for only while the answer is
    /// still outstanding: asking again would re-prompt a user who has already said no.
    func start(router: NotificationRouter, answering: BannerAnswering) {
        guard Self.isAppBundle else { return }
        let responder = NotificationResponder(
            open: { [weak router] route in router?.open(route) },
            answer: { question, text in _ = await answering.answer(question, text: text) }
        )
        self.responder = responder
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(BannerQuestion.categories)
        center.delegate = responder
        guard Self.shouldRequest(authorization) else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            _Concurrency.Task { @MainActor in
                self.authorization = Self.outcome(granted: granted, error: error)
            }
        }
    }

    /// The three decisions the notification centre makes unreachable under `xctest`, as values.
    /// `UNUserNotificationCenter.current()` traps there, so the branches are asserted here instead.
    static func shouldRequest(_ authorization: Authorization) -> Bool { authorization == .notAsked }

    static func canPost(_ authorization: Authorization) -> Bool { authorization == .granted }

    static func outcome(granted: Bool, error: Error?) -> Authorization {
        if let error { return .failed(error.localizedDescription) }
        return granted ? .granted : .denied
    }

    /// Drops the banner unless authorization has already been granted, so a denial costs one early
    /// return per signal rather than a fresh request and a dropped post.
    func post(title: String, body: String, route: NotificationRoute? = nil) {
        guard Self.isAppBundle, Self.canPost(authorization) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let route { content.userInfo = route.userInfo }
        if let question = route?.question { content.categoryIdentifier = question.kind.categoryIdentifier }
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// What the window says when banners will not arrive. Nil while the answer is still outstanding,
    /// and for `unavailable`, which is a development build rather than something a user can fix.
    var offMessage: String? { Self.offMessage(authorization) }

    static func offMessage(_ authorization: Authorization) -> String? {
        switch authorization {
        case .denied:
            "Notifications are off for Agent Board. Turn them on in System Settings to be told when a project needs you."
        case .failed(let reason):
            "Notifications are unavailable: \(reason)"
        case .granted, .notAsked, .unavailable:
            nil
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
}

/// Split out because `UNUserNotificationCenterDelegate` is an `NSObject` protocol whose callbacks
/// arrive off the main actor.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let open: @MainActor (NotificationRoute) -> Void
    private let answer: @MainActor (BannerQuestion, String) async -> Void

    init(
        open: @escaping @MainActor (NotificationRoute) -> Void,
        answer: @escaping @MainActor (BannerQuestion, String) async -> Void
    ) {
        self.open = open
        self.answer = answer
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        _Concurrency.Task { @MainActor in
            await respond(to: response)
            completionHandler()
        }
    }

    /// A typed Deny or Reply answers in the background, without bringing the app forward (SPEC §15.6);
    /// any other response is a click that opens what the banner names.
    @MainActor
    func respond(to response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let typed = response as? UNTextInputNotificationResponse,
           let question = BannerQuestion(userInfo: userInfo),
           typed.actionIdentifier == question.kind.actionIdentifier {
            await answer(question, typed.userText)
            return
        }
        guard let route = NotificationRoute(userInfo: userInfo) else { return }
        NSApplication.shared.activate()
        open(route)
    }

    /// Without this macOS swallows a banner whenever Agent Board is frontmost. The supervisor
    /// already suppresses the project on screen; a different project's banner should still show.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
