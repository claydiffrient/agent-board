import Observation

/// Carries a clicked banner's route from the notification delegate into the window. The views read
/// it; nothing else writes it.
@Observable
@MainActor
final class NotificationRouter {
    private(set) var route: NotificationRoute?
    /// Bumped on every open, so clicking the same banner twice routes twice. Views key their
    /// `task(id:)` on this rather than on the route.
    private(set) var sequence = 0

    func open(_ route: NotificationRoute) {
        self.route = route
        sequence += 1
    }
}
